//! snappy.Writer: a compressing `Io.Writer` producing the framed snappy
//! stream (README.md, "Streaming").
//!
//! Uncompressed writes accumulate in the caller-provided `Buffer` (one full
//! block). As the buffer fills, `drain` compresses whole `max_block_size`
//! blocks and emits them; `flush`/`finish` emit the partial tail. The
//! compressed-output scratch is a comptime-sized stack local, so the full
//! encode path allocates nothing.
//!
//! Framing (the package's canonical stream format):
//! ```text
//! stream := block*
//! block  := u32-le compressed_length, raw-snappy-block
//! ```

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const common = @import("common.zig");
const readInt = common.readInt;
const writeInt = common.writeInt;
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const golden = @import("golden.zig");
const Reader = @import("Reader.zig");

/// The caller-provided uncompressed accumulation buffer: one full block.
pub const Buffer = [encode.max_block_size]u8;

/// The compressed-output scratch size: the exact worst case for one block.
pub const scratch_len = encode.maxCompressedLength(encode.max_block_size);

const Writer = @This();

writer: Io.Writer,
output: *Io.Writer,

const vtable: Io.Writer.VTable = .{
    .drain = drain,
    .flush = flush,
    .rebase = rebase,
};

/// Wrap `output` (the compressed-stream sink) with `buffer` as the
/// uncompressed accumulation buffer. Write through `&w.writer`; complete the
/// stream with `finish`.
pub fn init(output: *Io.Writer, buffer: *Buffer) Writer {
    return .{
        .writer = .{
            .buffer = buffer,
            .end = 0,
            .vtable = &vtable,
        },
        .output = output,
    };
}

/// Complete the stream: emit the final partial block, then flush `output`.
/// Terminal — the writer is poisoned afterwards, and a failed or finished
/// writer reports `error.WriteFailed` instead of a false success.
pub fn finish(w: *Writer) Io.Writer.Error!void {
    if (w.writer.vtable != &vtable) return error.WriteFailed;
    defer w.writer = .failing;
    try w.emitBlock();
    try w.output.flush();
}

/// Compress `bytes` (a region of the accumulation buffer) into stack
/// scratch and emit it with the `u32-le` length prefix. A no-op when empty.
fn emit(w: *Writer, bytes: []const u8) Io.Writer.Error!void {
    if (bytes.len == 0) return;
    assert(bytes.len <= encode.max_block_size);
    var scratch: [scratch_len]u8 = undefined;
    // `scratch` is sized to the exact worst case for any block.
    const n = encode.compressBlock(bytes, &scratch) catch unreachable;
    var prefix: [4]u8 = undefined;
    writeInt(u32, &prefix, @intCast(n));
    try w.output.writeAll(&prefix);
    try w.output.writeAll(scratch[0..n]);
}

/// Emit the whole buffered block and empty the buffer.
fn emitBlock(w: *Writer) Io.Writer.Error!void {
    try w.emit(w.writer.buffer[0..w.writer.end]);
    w.writer.end = 0;
    // Postcondition: the block is fully emitted and the buffer is empty.
    assert(w.writer.end == 0);
}

/// The buffer is full: emit it as one block, then accept the front of
/// `data` into the freed buffer. The caller re-slices the remainder and
/// calls again, so full blocks stay maximal — only `flush`/`finish` emit
/// partial ones.
fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    errdefer w.* = .failing;
    const parent: *Writer = @fieldParentPtr("writer", w);
    // Top up the buffered block from the front of `data` (the last slice
    // repeats `splat` times). `drain` only runs when `data` does not fit, so
    // the top-up fills the buffer: every emitted block but the last is full.
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
    // A full buffer is one maximal block; a degenerate call that accepted
    // nothing still makes progress by emitting what is buffered.
    if (w.end == w.buffer.len or consumed == 0) try parent.emitBlock();
    return consumed;
}

/// Copy at most the buffer's remaining space from the front of `bytes` to
/// `buffer[end..]`, returning the bytes taken.
fn accept(w: *Io.Writer, bytes: []const u8) usize {
    const n = @min(bytes.len, w.buffer.len - w.end);
    fastmem.copy(u8, w.buffer[w.end..][0..n], bytes[0..n]);
    w.end += n;
    return n;
}

fn flush(w: *Io.Writer) Io.Writer.Error!void {
    errdefer w.* = .failing;
    const parent: *Writer = @fieldParentPtr("writer", w);
    try parent.emitBlock();
    try parent.output.flush();
}

/// Everything buffered except the last `preserve` bytes is written data:
/// emit it as a block, then slide the preserved tail to the front. (A
/// consumer can ask for a direct writable slice into the buffer via
/// `writableSliceGreedy`; when the buffer is full, that call lands here —
/// discarding instead of emitting would silently drop a whole block.)
fn rebase(w: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
    errdefer w.* = .failing;
    assert(preserve + capacity <= w.buffer.len);
    const parent: *Writer = @fieldParentPtr("writer", w);
    const keep = @min(preserve, w.end);
    try parent.emit(w.buffer[0 .. w.end - keep]);
    fastmem.move(u8, w.buffer[0..keep], w.buffer[w.end - keep ..][0..keep]);
    w.end = keep;
}

test "Writer: empty input produces an empty stream" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.finish();
    try testing.expectEqual(0, out.written().len);
}

test "Writer: partial tail is emitted at finish" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.writer.writeAll("hello, snappy");
    try w.finish();
    // One block: a 4-byte prefix + the raw block (varint 13 + literal tag +
    // 13 bytes = 15).
    try testing.expectEqual(19, out.written().len);
    try testing.expectEqual(@as(u32, 15), readInt(u32, out.written()[0..4]));
}

test "Writer: writes past one block split into full blocks" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.writer.writeAll("a" ** (3 * encode.max_block_size + 1));
    try w.finish();
    // Four blocks: three full (64K each) plus a one-byte tail.
    try testing.expectEqual(4, countBlocks(out.written()));
}

test "Writer: writableSliceGreedy on a full buffer emits, never drops" {
    // The File.Reader simple-mode stream feeds a Writer through
    // `writableSliceGreedy` + `advance` (a direct write into the buffer),
    // which lands on `rebase` when the buffer is full. A regression: rebase
    // once freed space by discarding the buffered block instead of
    // emitting it, silently dropping a whole block of input.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);

    // Fill the buffer exactly, without forcing a drain.
    try w.writer.writeAll("a" ** encode.max_block_size);
    // The direct-slice read: fills the (freshly emitted) whole buffer.
    const dest = try w.writer.writableSliceGreedy(1);
    try testing.expectEqual(encode.max_block_size, dest.len);
    fastmem.set(u8, dest, 0x62);
    w.writer.advance(dest.len);
    // More writes past the second block, then finish.
    try w.writer.writeAll("c" ** 1000);
    try w.finish();

    // Three blocks: 'a' x 65536, 'b' x 65536, 'c' x 1000.
    try testing.expectEqual(3, countBlocks(out.written()));
    var rbuf: Reader.Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(out.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    while (true) {
        _ = r.reader.stream(&plain.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
    }
    try testing.expectEqual(2 * encode.max_block_size + 1000, plain.written().len);
    try testing.expect(plain.written()[0] == 'a');
    try testing.expect(plain.written()[encode.max_block_size] == 'b');
    try testing.expect(plain.written()[2 * encode.max_block_size] == 'c');
}

test "Writer: golden decoded outputs encode to streams the block decoder verifies" {
    // Encode each golden `want` through Writer, then decode the framed stream
    // with the block decoder (the golden-verified path), independent of
    // Reader: the framing must parse and every block must reproduce its
    // input bytes.
    const gpa = testing.allocator;
    var d_buf: [encode.max_block_size]u8 = undefined;
    for (golden.golden_decode_cases) |tc| {
        if (tc.want_err) continue; // Corrupt sources have no output.

        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var buf: Buffer = undefined;
        var w: Writer = .init(&out.writer, &buf);
        try w.writer.writeAll(tc.want);
        try w.finish();

        var plain: Io.Writer.Allocating = .init(gpa);
        defer plain.deinit();
        const stream = out.written();
        var pos: usize = 0;
        while (pos < stream.len) {
            const block_len = readInt(u32, stream[pos..][0..4].ptr[0..4]);
            pos += 4;
            const block = stream[pos..][0..block_len];
            pos += block_len;
            const d_len = try decode.decompressedBlockLength(block);
            const n = try decode.decompressBlock(block, d_buf[0..d_len]);
            try plain.writer.writeAll(d_buf[0..n]);
        }
        try testing.expectEqualSlices(u8, tc.want, plain.written());
    }
}

test "Writer: a failed or finished writer never reports a false success" {
    // `finish` after a failed write, after `finish`, and writes after
    // `finish` must all report `error.WriteFailed` — a truncated stream must
    // not be reported as complete.
    const gpa = testing.allocator;

    // Finish after a failed write: the write buffers fine (it fits the
    // accumulation buffer), the emit fails into the full fixed output, and
    // `finish` must report it — twice, not a false success the second time.
    var small: [8]u8 = undefined;
    var fixed_out: Io.Writer = .fixed(&small);
    var buf: Buffer = undefined;
    var w: Writer = .init(&fixed_out, &buf);
    try w.writer.writeAll("a" ** 4096);
    try testing.expectError(error.WriteFailed, w.finish());
    try testing.expectError(error.WriteFailed, w.finish());

    // Write and finish after finish.
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w2: Writer = .init(&out.writer, &buf);
    try w2.writer.writeAll("hello, snappy");
    try w2.finish();
    try testing.expectError(error.WriteFailed, w2.writer.writeAll("more"));
    try testing.expectError(error.WriteFailed, w2.finish());
    try testing.expectEqual(1, countBlocks(out.written()));
}

test "Writer: random write machinery sequences stay correct" {
    // Mixed writeSplatAll/writeVecAll/splatBytesAll/writableSliceGreedy+advance/
    // writeByte/flush sequences: this is the driver class that catches drain
    // accounting under the full vtable contract (multi-slice data with splat,
    // partial straddling takes, direct-slice writes onto a full buffer).
    const gpa = testing.allocator;
    var rng: DefaultPrng = .init(99);
    const rand = rng.random();

    var iter: usize = 0;
    while (iter < 200) : (iter += 1) {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var expect: std.ArrayList(u8) = .empty;
        defer expect.deinit(gpa);
        var buf: Buffer = undefined;
        var w: Writer = .init(&out.writer, &buf);

        var ops: usize = 0;
        while (ops < 12) : (ops += 1) {
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
                    // buffer, which lands on `rebase` when the buffer is full.
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

        var rbuf: Reader.Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(out.written());
        var r: Reader = .init(&fixed_in, &rbuf);
        const got = try r.reader.allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try testing.expectEqual(expect.items.len, got.len);
        try testing.expectEqualSlices(u8, expect.items, got);
    }
}

test "Writer: flush mid-stream emits the partial block" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.writer.writeAll("hello, ");
    try w.writer.flush();
    try testing.expectEqual(1, countBlocks(out.written()));
    try w.writer.writeAll("snappy");
    try w.finish();
    try testing.expectEqual(2, countBlocks(out.written()));
}

/// Count the framed blocks in a stream produced by `Writer`.
fn countBlocks(stream: []const u8) usize {
    var n: usize = 0;
    var pos: usize = 0;
    while (pos < stream.len) {
        const block_len = readInt(u32, stream[pos..][0..4]);
        pos += 4 + block_len;
        n += 1;
    }
    return n;
}

/// Stream everything from `r` through one snappy `Writer` into `w`,
/// returning the bytes consumed and encoded. Consumes `r` exactly through
/// its end, then finishes the stream (the final partial block + flush). The
/// writer and its buffer live on this stack frame; zero allocation.
pub fn streamAll(r: *Io.Reader, w: *Io.Writer) error{ ReadFailed, WriteFailed }!usize {
    var n: usize = 0;
    var buf: Buffer = undefined;
    var ww: Writer = .init(w, &buf);
    while (true) {
        n += r.stream(&ww.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => {
                try ww.finish();
                return n;
            },
            else => return @errorCast(err),
        };
    }
}
