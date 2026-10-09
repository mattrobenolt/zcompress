//! flate.Writer: a compressing `Io.Writer` producing a raw deflate stream
//! (README.md, "Streaming").
//!
//! Uncompressed writes accumulate in the caller-provided `Buffer`, whose
//! front is the retained match history and whose remainder is the
//! accumulation block. As the block fills, `drain` emits whole
//! `max_block_size` blocks through the encoder's per-block path
//! (`encode.compressBlockStream`, the streaming half of the shared block
//! encoder the one-shot `compress` uses); the compressed-output scratch is a
//! comptime-sized stack local and the finder table a Writer field, so the
//! full encode path allocates nothing.
//!
//! History reaches back across emitted blocks (`§3.2.3`): a block's finder
//! window is the retained 32-KiB tail of the previously emitted bytes
//! followed by the block itself. History is a ratio input on this side, never
//! a correctness one — a rebase the caller's capacity request leaves no room
//! for simply drops it (README, "Streaming").
//!
//! The stream's bit offset carries across blocks: the pending partial byte
//! lives in `bits`/`bit_count` between emissions, so a block's first header
//! bit continues where the previous block's last bit ended (`§3.1.1`). Every
//! stream ends with the final empty fixed block `encode.writeFinalEmptyBlock`
//! emits — the one-shot encoder's own ending (README, "Divergences" T4).

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("internal");
const sentinel = internal.sentinel;
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const max_block_size = encode.max_block_size;
const history_len = encode.history_len;
const flate_reader = @import("Reader.zig");
const golden = @import("golden.zig");

/// The caller-provided buffer: the uncompressed accumulation block
/// (`max_block_size`) plus the retained match history (`history_len`). The
/// history sits at the front and the block after it, so the encoder's window
/// — history followed by block — is one contiguous slice.
pub const Buffer = [max_block_size + history_len]u8;

/// The compressed-output scratch for one block: the exact worst case
/// (`maxCompressedLength(max_block_size)`), so the encoder cannot run out of
/// room.
const scratch_len = encode.maxCompressedLength(max_block_size);

/// The tail scratch for the final empty fixed block: its 10 bits plus the
/// up-to-7 pending bits of the previous block, rounded up to whole bytes.
const ending_len = (7 + 10 + 7) / 8;

const Writer = @This();

writer: Io.Writer,
output: *Io.Writer,
options: encode.Options,
/// The caller's buffer in full: `buffer[0..block_start]` is the retained
/// history, `buffer[block_start..]` the accumulating block. The embedded
/// `Io.Writer`'s own `buffer`/`end` are the block region alone.
buffer: *Buffer,
/// The match-finder table, persistent across the stream's blocks
/// (`encode.FinderTable`): entries are absolute stream positions, so a block
/// pays a strided priming pass over its history, never a 128-KiB re-zero.
/// Absent until the first compressed block — a stored-only stream never pays
/// for it at all.
table: ?encode.FinderTable = null,
/// The absolute stream position of `buffer[0]` (wrapping u32, matching the
/// table entries): `compact` advances it by the bytes it drops from the
/// window's front.
window_base: u32 = 0,
/// Where the buffered block begins — the history length, since the history
/// is exactly the bytes before the block.
block_start: usize = 0,
/// The stream's pending bits, LSB first, carried across blocks so each
/// block's bits continue at the previous block's bit offset.
bits: u64 = 0,
/// Valid bits in `bits` (0-7 between emissions).
bit_count: u6 = 0,

const vtable: Io.Writer.VTable = .{
    .drain = drain,
    .flush = flush,
    .rebase = rebase,
};

/// Wrap `output` (the compressed-stream sink) with `buffer` as the
/// accumulation window. Write through `&w.writer`; complete the stream with
/// `finish`.
/// Wrap `output` (the compressed-stream sink) with `buffer` as the
/// accumulation window and `options` fixed for the stream's lifetime — the
/// level is not re-read mid-stream (changing `options` on the struct is not
/// a supported operation).
pub fn init(output: *Io.Writer, buffer: *Buffer, options: encode.Options) Writer {
    // The reserved seat: `.ratio` is Unimplemented, never silent aliasing
    // (README, "API"). Poisoning the interface makes every write and finish
    // report `error.WriteFailed`, matching `streamAll`'s rejection.
    if (options.level == .ratio) {
        return .{
            .writer = .failing,
            .output = output,
            .buffer = buffer,
            .options = options,
        };
    }
    return .{
        .writer = .{
            .buffer = buffer[0..max_block_size],
            .end = 0,
            .vtable = &vtable,
        },
        .output = output,
        .buffer = buffer,
        .options = options,
    };
}

/// Complete the stream: emit the buffered partial block, then the final empty
/// fixed block, then flush `output`. Terminal — the writer is poisoned
/// afterwards, and a failed or finished writer reports `error.WriteFailed`
/// instead of a false success.
pub fn finish(w: *Writer) Io.Writer.Error!void {
    if (w.writer.vtable != &vtable) return error.WriteFailed;
    defer w.writer = .failing;
    try w.emitBlock(w.writer.end);

    // README, "Divergences" T4 — BFINAL=1, BTYPE=01, end-of-block, at the
    // stream's current bit offset: the same ending the one-shot encoder
    // emits, from the same function.
    var tail: [ending_len]u8 = undefined;
    var bw: encode.BitWriter = .{
        .target = &tail,
        .bits = w.bits,
        .bit_count = w.bit_count,
    };
    encode.writeFinalEmptyBlock(&bw) catch unreachable;
    bw.finish() catch unreachable;
    w.bits = 0;
    w.bit_count = 0;
    try w.output.writeAll(tail[0..bw.pos]);
    try w.output.flush();
}

/// Emit the first `emit_len` bytes of the buffered block as one deflate
/// block, then slide the window past them: the emitted bytes become history,
/// so nothing moves until the block region runs out of room behind
/// `max_block_size` (`compact`). A no-op when `emit_len` is zero.
fn emitBlock(w: *Writer, emit_len: usize) Io.Writer.Error!void {
    assert(emit_len <= w.writer.end);
    if (emit_len == 0) return;
    const block_end = w.block_start + emit_len;
    var scratch: [scratch_len]u8 = undefined;
    var bw: encode.BitWriter = .{
        .target = &scratch,
        .bits = w.bits,
        .bit_count = w.bit_count,
    };
    // The finder's window is the block's 32-KiB history followed by the
    // block itself, so a match crosses block boundaries exactly as `§3.2.3`
    // allows. The stored-only level (`§3.2.4`) skips the finder entirely.
    if (w.options.level == .@"0") {
        encode.emitStoredBlock(&bw, w.buffer[w.block_start..block_end]) catch unreachable;
    } else {
        if (w.table == null) {
            w.table = undefined;
            fastmem.set(u32, &w.table.?, 0);
        }
        encode.compressBlockStream(
            w.buffer[0..block_end],
            w.block_start,
            block_end,
            &bw,
            &w.table.?,
            w.window_base,
        ) catch unreachable;
    }
    w.bits = bw.bits;
    w.bit_count = bw.bit_count;
    try w.output.writeAll(scratch[0..bw.pos]);

    w.writer.end -= emit_len;
    w.block_start += emit_len;
    if (w.block_start + max_block_size > w.buffer.len) w.compact();
    w.writer.buffer = w.buffer[w.block_start..][0..max_block_size];
}

/// Slide the history and the buffered block to the front of the window,
/// trimming the history to `history_len` (README, "Streaming": history is a
/// ratio input here, so a request that leaves no room for it drops it). The
/// caller re-derives the block region from `block_start`.
fn compact(w: *Writer) void {
    const block_len = w.writer.end;
    const keep = @min(w.block_start, history_len);
    fastmem.move(u8, w.buffer[0..keep], w.buffer[w.block_start - keep ..][0..keep]);
    fastmem.move(u8, w.buffer[keep..][0..block_len], w.buffer[w.block_start..][0..block_len]);
    // The dropped front bytes advance the window's absolute base, keeping
    // the persistent table's stream positions honest.
    w.window_base +%= @as(u32, @truncate(w.block_start - keep));
    w.block_start = keep;
}

/// The block region is full: emit it as one maximal block, then accept the
/// front of `data` into the freed region. The caller re-slices the remainder
/// and calls again, so full blocks stay maximal — only `flush`, `finish`,
/// and `rebase` emit partial ones.
fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    errdefer w.* = .failing;
    const parent: *Writer = @alignCast(@fieldParentPtr("writer", w));
    // Top up the buffered block from the front of `data` (the last slice
    // repeats `splat` times). `drain` only runs when `data` does not fit, so
    // the top-up fills the region: every emitted block but the last is full.
    var consumed: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        consumed += accept(w, bytes);
        if (w.end == w.buffer.len) break;
    }
    const pattern = data[data.len - 1];
    if (pattern.len != 0) {
        for (0..splat) |_| {
            if (w.end == w.buffer.len) break;
            consumed += accept(w, pattern);
        }
    }
    // A full block is one maximal block; a degenerate call that accepted
    // nothing still makes progress by emitting what is buffered.
    if (w.end == w.buffer.len or consumed == 0) try parent.emitBlock(w.end);
    return consumed;
}

/// Copy at most the block region's remaining space from the front of
/// `bytes`, returning the bytes taken.
fn accept(w: *Io.Writer, bytes: []const u8) usize {
    const n = @min(bytes.len, w.buffer.len - w.end);
    fastmem.copy(u8, w.buffer[w.end..][0..n], bytes[0..n]);
    w.end += n;
    return n;
}

/// Emit the buffered partial block and flush `output`, keeping the writer
/// usable: no data block carries BFINAL, so a mid-stream flush is always safe
/// (README, "Divergences" T4).
fn flush(w: *Io.Writer) Io.Writer.Error!void {
    errdefer w.* = .failing;
    const parent: *Writer = @alignCast(@fieldParentPtr("writer", w));
    try parent.emitBlock(w.end);
    try parent.output.flush();
}

/// Everything buffered except the last `preserve` bytes is written data:
/// emit it as a block, then leave the preserved tail as the block. (A
/// consumer can ask for a direct writable slice into the block region via
/// `writableSliceGreedy`; when the region is full, that call lands here —
/// discarding instead of emitting would silently drop input.)
fn rebase(w: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
    errdefer w.* = .failing;
    assert(preserve + capacity <= w.buffer.len);
    const parent: *Writer = @alignCast(@fieldParentPtr("writer", w));
    const keep = @min(preserve, w.end);
    try parent.emitBlock(w.end - keep);
    // The preserved tail is now the block, with the emitted bytes as history
    // behind it: `end` is already `keep`, and the freed room is at least the
    // requested capacity.
    assert(w.end == keep);
    assert(w.buffer.len - w.end >= capacity);
}

// ---------------------------------------------------------------------------
// Tests. Every decode goes through the landed one-shot decoder (decode.zig),
// with the sentinel overrun rule: the target is pre-filled and the bytes past
// the decoded length must be untouched.
// ---------------------------------------------------------------------------

/// Encode `source` through `Writer`, decode with the one-shot decoder, expect
/// identity with the sentinel rule enforced.
fn roundTrip(source: []const u8) !void {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    try golden.expectFinalEmptyBlock(out.written());

    const target = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(target);
    sentinel.fill(target);
    const n = try decode.decompress(out.written(), target);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, target[0..n]);
    try sentinel.expect(target, n);
}

test "Writer: empty input is the final empty block" {
    // Spec: rfc1951-deflate.txt §3.2.3 — "BFINAL is set if and only if this
    // is the last block of the data set"; README "Divergences" T4 — the
    // stream ends with the empty fixed block `03 00`, the same bytes the
    // one-shot `compress("")` emits.
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.finish();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x00 }, out.written());
}

test "Writer: no data block carries BFINAL" {
    // Spec: rfc1951-deflate.txt §3.2.3 — BFINAL marks the last block, and
    // README "Divergences" T4 keeps it off every data block: the stream's
    // first block header has BFINAL clear, and the stream still decodes.
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.writer.writeAll("the quick brown fox jumps over the lazy dog. " ** 40);
    try w.finish();
    try testing.expect(out.written().len > 2);
    try testing.expectEqual(@as(u8, 0), out.written()[0] & 0b1);
    try golden.expectFinalEmptyBlock(out.written());
    try roundTrip("the quick brown fox jumps over the lazy dog. " ** 40);
}

test "Writer: round trips across block boundaries" {
    // The 65535-byte split (`§3.2.4`'s stored LEN cap) and the sizes around
    // it, where the second block's matches may reach back into the first
    // (`§3.2.3`: "the backward distance may cross one or more block
    // boundaries").
    const gpa = testing.allocator;
    const sizes = [_]usize{ 0, 1, 4, 13, 1000, 65534, 65535, 65536, 65537, 131071 };
    for (sizes) |len| {
        inline for (.{ Shape.text, Shape.random, Shape.rle }) |shape| {
            const source = try makeShape(gpa, shape, len);
            defer gpa.free(source);
            roundTrip(source) catch |err| {
                std.debug.print("FAIL: {s} len {d}\n", .{ @tagName(shape), len });
                return err;
            };
        }
    }
}

test "Writer: blocks are maximal and the split follows the block size" {
    // "Full blocks stay maximal" (README, "Streaming"): incompressible input
    // cannot beat the stored form, so sixteen exactly-full blocks are stored
    // and the stream is exactly `input + 5 * blocks + 2` — which only holds if
    // the split is exactly `max_block_size`.
    const gpa = testing.allocator;
    const source = try makeShape(gpa, .random, 16 * max_block_size);
    defer gpa.free(source);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.writer.writeAll(source);
    try w.finish();
    try testing.expectEqual(source.len + 5 * 16 + 2, out.written().len);

    // The split follows the block size, not the caller's write boundaries: the
    // same bytes in odd-sized chunks produce the same stream (README,
    // "Encoder": the streaming split follows the caller's writes *and
    // flushes*, and neither carries a flush here).
    var chunked: Io.Writer.Allocating = .init(gpa);
    defer chunked.deinit();
    var w2: Writer = .init(&chunked.writer, &buf, .{});
    var pos: usize = 0;
    var step: usize = 1;
    while (pos < source.len) {
        const n = @min(source.len - pos, step);
        try w2.writer.writeAll(source[pos..][0..n]);
        pos += n;
        step = (step * 3 + 1) % 40_000;
    }
    try w2.finish();
    try testing.expectEqualSlices(u8, out.written(), chunked.written());
    try roundTrip(source);
}

test "Writer: history reaches back across emitted blocks" {
    // A block that is a copy of the tail of the previously emitted bytes is
    // compressible only through the retained history: without it the block is
    // incompressible and costs a stored block (`§3.2.3`).
    const gpa = testing.allocator;
    const copy_from = max_block_size - history_len + 1000;
    const source = try gpa.alloc(u8, max_block_size + (max_block_size - copy_from));
    defer gpa.free(source);
    var rng: DefaultPrng = .init(0xBADD_CAFE);
    for (source[0..max_block_size]) |*b| b.* = rng.random().int(u8);
    fastmem.copy(u8, source[max_block_size..], source[copy_from..max_block_size]);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.writer.writeAll(source);
    try w.finish();
    // The first block is incompressible (stored: 65540 bytes); the second is
    // one match of 31768 bytes, so the stream is far below the stored cost of
    // the whole input.
    try testing.expect(out.written().len > 65540);
    try testing.expect(out.written().len < 67000);
    try roundTrip(source);
}

test "Writer: flush mid-stream emits the partial block and stays usable" {
    // README, "Streaming": "`flush` mid-stream emits the buffered partial
    // block and keeps the writer usable. It is always safe, because no data
    // block carries BFINAL."
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.writer.writeAll("hello, ");
    try w.writer.flush();
    const first = out.written().len;
    try testing.expect(first > 0);
    try w.writer.writeAll("flate");
    try w.finish();
    try testing.expect(out.written().len > first);
    // Two blocks plus the ending: the flushed partial block is not merged into
    // the later one, and the whole stream still decodes.
    try golden.expectFinalEmptyBlock(out.written());

    const target = try gpa.alloc(u8, 64);
    defer gpa.free(target);
    sentinel.fill(target);
    const n = try decode.decompress(out.written(), target);
    try testing.expectEqualStrings("hello, flate", target[0..n]);
    try sentinel.expect(target, n);
}

test "Writer: writableSliceGreedy on a full block emits, never drops" {
    // The `File.Reader` simple-mode stream feeds a Writer through
    // `writableSliceGreedy` + `advance` (a direct write into the block
    // region), which lands on `rebase` when the region is full. A regression:
    // rebase once freed space by discarding the buffered block instead of
    // emitting it, silently dropping a whole block of input.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});

    // Fill the region exactly, without forcing a drain.
    try w.writer.writeAll("a" ** max_block_size);
    // The direct-slice read: fills the (freshly emitted) whole region.
    const dest = try w.writer.writableSliceGreedy(1);
    try testing.expectEqual(max_block_size, dest.len);
    fastmem.set(u8, dest, 0x62);
    w.writer.advance(dest.len);
    // More writes past the second block, then finish.
    try w.writer.writeAll("c" ** 1000);
    try w.finish();

    const target = try gpa.alloc(u8, 2 * max_block_size + 1000 + sentinel.len);
    defer gpa.free(target);
    sentinel.fill(target);
    const n = try decode.decompress(out.written(), target);
    try testing.expectEqual(2 * max_block_size + 1000, n);
    try testing.expectEqual(@as(u8, 'a'), target[0]);
    try testing.expectEqual(@as(u8, 'b'), target[max_block_size]);
    try testing.expectEqual(@as(u8, 'c'), target[2 * max_block_size]);
    try testing.expectEqual(@as(u8, 'c'), target[n - 1]);
    try sentinel.expect(target, n);
}

test "Writer: a stream crossing the 4-GiB window-base wrap round-trips" {
    // The table's entries are absolute wrapping positions; these streams
    // preset window_base near maxInt(u32) so every compact crosses the
    // wrap. The decode asserts correctness, not byte-identity: a
    // zero-initialized slot at base X aliases differently than at base 0.
    const gpa = testing.allocator;
    const bases = [_]u32{
        std.math.maxInt(u32),
        std.math.maxInt(u32) - 1,
        std.math.maxInt(u32) - history_len,
        std.math.maxInt(u32) - max_block_size,
        std.math.maxInt(u32) - 200_000,
        std.math.maxInt(u32) - 400_000,
        0x8000_0000,
    };
    for (bases) |base| {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var buf: Buffer = undefined;
        var w: Writer = .init(&out.writer, &buf, .{});
        w.window_base = base;

        // Mixed input: repeated phrases (long matches that cross compacts)
        // and random runs, with flushes between chunks.
        var rng: DefaultPrng = .init(base);
        const phrase = "the quick brown fox jumps over the lazy dog. ";
        var chunk: [30_000]u8 = undefined;
        var total: usize = 0;
        while (total < 700_000) {
            const phrase_len = (rng.random().uintLessThan(usize, 3)) * 10_000;
            if (phrase_len > 0) {
                var j: usize = 0;
                while (j < phrase_len) : (j += phrase.len) {
                    const n = @min(phrase.len, phrase_len - j);
                    try w.writer.writeAll(phrase[0..n]);
                }
            } else {
                rng.random().bytes(&chunk);
                try w.writer.writeAll(&chunk);
            }
            if (rng.random().uintLessThan(u8, 4) == 0) try w.writer.flush();
            total += phrase_len + chunk.len;
        }
        try w.finish();

        var rbuf: flate_reader.Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(out.written());
        var r = flate_reader.init(&fixed_in, &rbuf);
        const got = try r.reader.allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try testing.expect(got.len > 0);
    }
}

test "Writer: the stored-only level emits stored blocks through the stream" {
    // Spec: rfc1951-deflate.txt §3.2.4 (stored blocks). The stored-only
    // level through the streaming Writer: every data block is stored, the
    // length is exactly maxCompressedLength (the stored bound, tight), and
    // the first block's BTYPE is 00.
    const gpa = testing.allocator;
    const input_len = 3 * max_block_size + 17;
    const input = try gpa.alloc(u8, input_len);
    defer gpa.free(input);
    var rng: DefaultPrng = .init(0x5700D0);
    rng.random().bytes(input);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{ .level = .@"0" });
    try w.writer.writeAll(input);
    try w.finish();

    try testing.expectEqual(encode.maxCompressedLength(input_len), out.written().len);
    // BFINAL=0, BTYPE=00, then pad: the first header byte is 0x00.
    try testing.expectEqual(@as(u8, 0), out.written()[0]);

    var d_buf: [input_len + 1]u8 = undefined;
    sentinel.fill(&d_buf);
    const n = try decode.decompress(out.written(), d_buf[0..input_len]);
    try testing.expectEqualSlices(u8, input, d_buf[0..n]);
    try sentinel.expect(&d_buf, n);
}

test "Writer: the ratio level is rejected, never silently aliased" {
    // The reserved seat: `.ratio` poisons the writer at init (README,
    // "API"): every write and finish report `error.WriteFailed`.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{ .level = .ratio });
    try testing.expectError(error.WriteFailed, w.writer.writeAll("hello, flate"));
    try testing.expectError(error.WriteFailed, w.finish());
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

test "Writer: a failed or finished writer never reports a false success" {
    // `finish` after a failed write, after `finish`, and writes after
    // `finish` must all report `error.WriteFailed` — a truncated stream must
    // not be reported as complete.
    const gpa = testing.allocator;

    // Finish after a failed write: the write buffers fine (it fits the
    // accumulation block), the emit fails into the full fixed output, and
    // `finish` must report it — twice, not a false success the second time.
    var small: [8]u8 = undefined;
    var fixed_out: Io.Writer = .fixed(&small);
    var buf: Buffer = undefined;
    var w: Writer = .init(&fixed_out, &buf, .{});
    try w.writer.writeAll("a" ** 4096);
    try testing.expectError(error.WriteFailed, w.finish());
    try testing.expectError(error.WriteFailed, w.finish());

    // Write and finish after finish.
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w2: Writer = .init(&out.writer, &buf, .{});
    try w2.writer.writeAll("hello, flate");
    try w2.finish();
    try testing.expectError(error.WriteFailed, w2.writer.writeAll("more"));
    try testing.expectError(error.WriteFailed, w2.finish());
    try golden.expectFinalEmptyBlock(out.written());
}

test "Writer: random write machinery sequences stay correct" {
    // Mixed writeSplatAll/writeVecAll/splatBytesAll/writableSliceGreedy+
    // advance/writeByte/flush sequences: the driver class that catches drain
    // and rebase accounting under the full vtable contract (multi-slice data
    // with splat, partial straddling takes, direct-slice writes onto a full
    // block region).
    const gpa = testing.allocator;
    var rng: DefaultPrng = .init(99);
    const rand = rng.random();

    var iter: usize = 0;
    while (iter < 60) : (iter += 1) {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var expect: std.ArrayList(u8) = .empty;
        defer expect.deinit(gpa);
        var buf: Buffer = undefined;
        var w: Writer = .init(&out.writer, &buf, .{});

        var ops: usize = 0;
        while (ops < 10) : (ops += 1) {
            var a: [3000]u8 = undefined;
            var b: [40000]u8 = undefined;
            var pattern: [7]u8 = undefined;
            rand.bytes(&a);
            rand.bytes(&b);
            rand.bytes(&pattern);
            const a_len = rand.uintAtMost(usize, a.len);
            const b_len = rand.uintAtMost(usize, b.len);
            const p_len = rand.intRangeAtMost(usize, 1, pattern.len);
            const splat = rand.uintAtMost(usize, 30000);
            switch (rand.uintLessThan(u8, 5)) {
                0 => {
                    var data = [_][]const u8{ a[0..a_len], b[0..b_len], pattern[0..p_len] };
                    try w.writer.writeSplatAll(&data, splat);
                    try expect.appendSlice(gpa, a[0..a_len]);
                    try expect.appendSlice(gpa, b[0..b_len]);
                    for (0..splat) |_| try expect.appendSlice(gpa, pattern[0..p_len]);
                },
                1 => {
                    var data = [_][]const u8{ a[0..a_len], b[0..b_len] };
                    try w.writer.writeVecAll(&data);
                    try expect.appendSlice(gpa, a[0..a_len]);
                    try expect.appendSlice(gpa, b[0..b_len]);
                },
                2 => {
                    try w.writer.splatBytesAll(pattern[0..p_len], splat);
                    for (0..splat) |_| try expect.appendSlice(gpa, pattern[0..p_len]);
                },
                3 => {
                    // The File.Reader simple-mode path: a direct write into the
                    // block region, which lands on `rebase` when it is full.
                    const dest = try w.writer.writableSliceGreedy(1);
                    const n = @min(dest.len, b_len);
                    for (dest[0..n], b[0..n]) |*d, x| d.* = x;
                    w.writer.advance(n);
                    try expect.appendSlice(gpa, b[0..n]);
                },
                else => {
                    try w.writer.writeByte(pattern[0]);
                    try expect.append(gpa, pattern[0]);
                    if (rand.boolean()) try w.writer.flush();
                },
            }
        }
        try w.finish();

        // Decode with the landed one-shot decoder — independent of Reader.
        const target = try gpa.alloc(u8, expect.items.len + sentinel.len);
        defer gpa.free(target);
        sentinel.fill(target);
        const n = try decode.decompress(out.written(), target);
        try testing.expectEqual(expect.items.len, n);
        try testing.expectEqualSlices(u8, expect.items, target[0..n]);
        try sentinel.expect(target, n);
    }
}

test "Writer: golden decoded outputs encode to streams the decoder verifies" {
    // Encode each golden `want` through Writer and decode it with the landed
    // one-shot decoder (the golden-verified path), independent of Reader: the
    // framing must parse and the bytes must reproduce.
    for (golden.stream_cases) |tc| {
        const want = switch (tc.expect) {
            .ok => |bytes| bytes,
            else => continue, // Reject cases have no output.
        };
        roundTrip(want) catch |err| {
            std.debug.print("\nFAIL: {s}\n", .{tc.desc});
            return err;
        };
    }
    for (golden.micro_cases) |tc| {
        roundTrip(tc.want) catch |err| {
            std.debug.print("\nFAIL: {s}\n", .{tc.desc});
            return err;
        };
    }
    for (golden.deflate_cases) |tc| {
        roundTrip(tc.want) catch |err| {
            std.debug.print("\nFAIL: deflateTests input len {d}\n", .{tc.want.len});
            return err;
        };
    }
}

test "Writer: every length and distance code round trips through the stream" {
    // Sweep the encodable space across block boundaries: a pattern repeated
    // at every distance class, then runs of every length — through the
    // streaming Writer and the one-shot decoder.
    const gpa = testing.allocator;
    const source = try gpa.alloc(u8, 200_000);
    defer gpa.free(source);
    var rng: DefaultPrng = .init(0x1234_5678);
    for (source[0..4096]) |*b| b.* = rng.random().int(u8);
    for (4096..source.len) |i| source[i] = source[i - 4096];
    try roundTrip(source);

    for (3..259) |length| {
        const run = try gpa.alloc(u8, length + 1);
        defer gpa.free(run);
        fastmem.set(u8, run, 0x7E);
        try roundTrip(run);
    }
}

/// Corpus shapes, the same set the encoder and bench use: repetitive text,
/// PRNG bytes (incompressible, so the stored fallback runs), a single-byte
/// run.
const Shape = enum { text, random, rle };

fn makeShape(gpa: std.mem.Allocator, shape: Shape, len: usize) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    switch (shape) {
        .text => {
            const phrase = "the quick brown fox jumps over the lazy dog. ";
            var i: usize = 0;
            while (i < len) {
                const n = @min(phrase.len, len - i);
                fastmem.copy(u8, buf[i..][0..n], phrase[0..n]);
                i += n;
            }
        },
        .random => {
            var rng: DefaultPrng = .init(0xC0FFEE);
            for (buf) |*b| b.* = rng.random().int(u8);
        },
        .rle => fastmem.set(u8, buf, 0x41),
    }
    return buf;
}

/// Stream everything from `r` through one flate `Writer` into `w`,
/// returning the bytes consumed and encoded. Consumes `r` exactly through
/// its end, then finishes the stream (the `03 00` ending + flush). The
/// writer and its window live on this stack frame; zero allocation.
pub fn streamAll(
    r: *Io.Reader,
    w: *Io.Writer,
    options: encode.Options,
) Io.Reader.StreamRemainingError!usize {
    if (options.level == .ratio) return error.ReadFailed;
    var buf: Buffer = undefined;
    var ww: Writer = .init(w, &buf, options);
    const n = try r.streamRemaining(&ww.writer);
    // The stream is not done until finish: the final partial block and the
    // `03 00` ending are load-bearing (README, "Divergences" T4).
    try ww.finish();
    return n;
}
