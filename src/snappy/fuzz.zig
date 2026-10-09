//! Fuzz targets for the snappy module, one per layer of the decode surface:
//!
//!   - `fuzzBlockDecode`: arbitrary bytes into `decompressBlock`, with the
//!     golden-vector sentinel overrun check and a re-encode round trip on
//!     every successful decode.
//!   - `fuzzBlockRoundTrip`: structured shapes through `compressBlock` ->
//!     `decompressBlock`, identity plus an overrun check on the decode.
//!   - `fuzzStreamRoundTrip`: `Writer` -> `Reader` identity over framed
//!     streams, both sides through `Io.Writer.Allocating`.
//!   - `fuzzStreamMachinery`: Smith-chosen `Io.Writer` operation sequences
//!     against an expected-bytes model, then decoded and compared.
//!   - `fuzzFramingCorruption`: truncations, byte flips, and poked length
//!     prefixes on valid streams; `Reader` must fail closed (stickily) or
//!     serve exactly what an independent framing parse of the same bytes
//!     says — never panic, hang, or write outside its buffer.
//!
//! Run with `just fuzz <budget>` (ReleaseSafe only: a Debug-mode fuzz run
//! hits ziglang/zig#30655). Every target caps its per-iteration input
//! (`source_max`, `block_max`, `stream_max`, `framing_max`) so a budget run
//! finishes. The codec allocates nothing; the only allocation is the
//! `Io.Writer.Allocating` harness, which the runner's per-input leak check
//! covers.
//!
//! Spec: docs/research/specs/snappy-format-description.txt (§1 varint
//! preamble, §2 tags). Framing: src/snappy/README.md, "Streaming".

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;
const Smith = testing.Smith;

const fastmem = @import("fastmem");

const common = @import("common.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const Reader = @import("Reader.zig");
const Writer = @import("Writer.zig");

/// The sentinel byte range [0xa0, 0xc5) from the golden vectors: buffers are
/// pre-filled with these cycling, and every byte past the decoded length must
/// be untouched afterward. Period 37 (prime) so a mis-copied byte lands at an
/// unrelated phase, where a power of two could mask an 8-byte-off copy.
const sentinel_base: u8 = 0xa0;
const sentinel_len: usize = 37;

/// Bytes past the decoded length checked on every decode: an out-of-bounds
/// write (a 16-byte SIMD store, a 64-byte copy chunk) lands in this region.
const guard_len: usize = 256;

/// Block-decode output window: 96 KiB, so a block may declare and produce
/// more than one block's worth of output — the copy-4 large-offset path the
/// golden fixtures cover at 65545 bytes.
const decode_window_len: usize = 96 * 1024;

/// Per-iteration input caps. A decoded block expands at most ~13x from its
/// source (a 5-byte copy-4 tag yields 64 bytes), and a stream is block-framed,
/// so these cover every path without unbounded work.
const source_max: usize = 32 * 1024;
const block_max: usize = encode.max_block_size;
const stream_max: usize = 256 * 1024;
const framing_max: usize = 32 * 1024;

/// The worst-case compressed size of one block — the stack scratch `Writer`
/// itself uses (`snappy.scratch_len`).
const scratch_max: usize = Writer.scratch_len;

/// The sentinel cycle, materialized once so fills are chunked copies.
const sentinel_pattern: [sentinel_len]u8 = blk: {
    var pattern: [sentinel_len]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = sentinel_base + @as(u8, @intCast(i));
    break :blk pattern;
};

/// The sentinel byte that must sit at absolute index `i`.
fn sentinelAt(i: usize) u8 {
    return sentinel_base + @as(u8, @intCast(i % sentinel_len));
}

/// A Smith-chosen value in `[at_least, at_most]`. `Smith.valueRangeAtMost`
/// rejects `usize` (no fixed bitsize), so bounded lengths go through a `u32`
/// and widen here; every call site is inside a per-iteration cap.
fn rangeAtMost(smith: *Smith, at_least: usize, at_most: usize) usize {
    assert(at_least <= at_most);
    assert(at_most <= std.math.maxInt(u32));
    return smith.valueRangeAtMost(u32, @intCast(at_least), @intCast(at_most));
}

/// Pre-fill `buf` with the cycling sentinel, from index 0: the phase is the
/// absolute buffer index, so a partial fill must start there.
fn fillSentinels(buf: []u8) void {
    var i: usize = 0;
    while (i + sentinel_len <= buf.len) : (i += sentinel_len) {
        fastmem.copy(u8, buf[i..][0..sentinel_len], &sentinel_pattern);
    }
    fastmem.copy(u8, buf[i..], sentinel_pattern[0 .. buf.len - i]);
}

/// Every byte of the filled region `buf[0..filled]` from `from` on must still
/// hold its sentinel: a decode wrote past the length it was allowed.
fn checkSentinels(buf: []const u8, from: usize, filled: usize) !void {
    assert(from <= filled);
    for (buf[from..filled], from..) |x, i| try testing.expectEqual(sentinelAt(i), x);
}

/// How many `stream` calls a stream of `len` bytes may take: every call
/// consumes at least a 5-byte block (4-byte prefix plus one block byte) or
/// ends the stream, so anything past this is a stall, not progress.
fn pumpLimit(len: usize) usize {
    return len / 4 + 8;
}

/// Pump `r` into `w` until the clean end of stream (the shape of
/// `Reader.zig`'s own `roundTrip` driver), bounded: every call consumes at
/// least a 4-byte framing prefix or ends the stream, so more calls than
/// `limit` means the reader stopped making progress — a hang is a finding,
/// not a timeout.
fn pump(r: *Io.Reader, w: *Io.Writer, limit: usize) !void {
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > limit) return error.PumpStalled;
        _ = r.stream(w, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
    }
}

/// Compress `bytes` (at most one block) and decode it back: identity, with
/// the decode's overrun check. This is the property every successful decode
/// must satisfy — a block that decodes to `bytes` re-encodes to a block that
/// decodes back to `bytes`.
fn blockRoundTrip(bytes: []const u8) !void {
    assert(bytes.len <= block_max);
    var compressed: [scratch_max]u8 = undefined;
    const c_len = try encode.compressBlock(bytes, &compressed);
    // The documented bound: never past the worst-case literal form.
    try testing.expect(c_len <= encode.maxCompressedLength(bytes.len));
    // The preamble agrees with the input, and the block decodes back.
    try testing.expectEqual(bytes.len, try decode.decompressedBlockLen(compressed[0..c_len]));

    var window: [block_max + guard_len]u8 = undefined;
    fillSentinels(window[0 .. bytes.len + guard_len]);
    const n = try decode.decompressBlock(compressed[0..c_len], window[0..bytes.len]);
    try testing.expectEqual(bytes.len, n);
    try testing.expectEqualSlices(u8, bytes, window[0..n]);
    try checkSentinels(&window, bytes.len, bytes.len + guard_len);
}

/// One block-decode seed in `std.testing.Smith`'s serialized form: the
/// `u32-le` length plus bytes that `smith.slice` consumes, then a
/// little-endian u64 of 1 — the value that selects `true` in the target's
/// `boolWeighted(1, 3)` full-window choice.
fn decodeSeed(comptime block: []const u8) [4 + block.len + 8]u8 {
    var seed: [4 + block.len + 8]u8 = undefined;
    seed[0] = @truncate(block.len);
    seed[1] = @truncate(block.len >> 8);
    seed[2] = @truncate(block.len >> 16);
    seed[3] = @truncate(block.len >> 24);
    for (block, 0..) |b, i| seed[4 + i] = b;
    for (seed[4 + block.len ..]) |*b| b.* = 0;
    seed[4 + block.len] = 1;
    return seed;
}

// Seed corpus for the block-decode target: valid blocks from the golden
// vectors plus two corrupt ones, so the fuzzer starts from real tag streams
// instead of discovering the format from scratch. The same entries also run
// as plain unit tests when the executable is not in fuzz mode.
const seed_empty = decodeSeed("\x00");
const seed_literal = decodeSeed("\x03\x08\xff\xff\xff");
const seed_copy1 = decodeSeed("\x0d\x0cabcd\x15\x04");
const seed_copy2 = decodeSeed("\x06\x0cabcd\x06\x03\x00");
const seed_copy4 = decodeSeed("\x06\x0cabcd\x07\x03\x00\x00\x00");
const seed_literal40 = decodeSeed("\x28\x9c" ++ "." ** 40);
const seed_zero_offset = decodeSeed("\x08\x0cabcd\x01\x00");
const block_decode_corpus: []const []const u8 = &.{
    &seed_empty,
    &seed_literal,
    &seed_copy1,
    &seed_copy2,
    &seed_copy4,
    &seed_literal40,
    &seed_zero_offset,
};

/// Target 1: arbitrary bytes into the block decoder.
///
/// Attacks the tag dispatch, the extended-literal length forms (tags 60-63),
/// copy offsets and lengths (including overlapping RLE and 4-byte offsets),
/// the declared-length preamble, and the target-size gate. The property:
/// decode either fails (`DecompressionFailed`, or `BufferTooSmall` when the
/// declared length exceeds the target) or is exact — `decompressedBlockLen`
/// bytes out, re-encoding into a block that decodes back to the same bytes —
/// and never writes past the target's length (the sentinel check).
fn fuzzBlockDecode(_: void, smith: *Smith) anyerror!void {
    var source_buf: [source_max]u8 = undefined;
    const source = source_buf[0..smith.slice(&source_buf)];

    const declared = decode.decompressedBlockLen(source) catch |err| {
        // The only failure a length preamble has: truncated, longer than 5
        // bytes, or a fifth byte carrying more than 4 value bits (spec §1).
        try testing.expectEqual(error.DecompressionFailed, err);
        return;
    };

    // A declared length past the window is exercised as `BufferTooSmall`;
    // within it, the target is the exact decoded length three quarters of the
    // time and a Smith-chosen shorter one otherwise (the size gate).
    const declared_cap = @min(declared, decode_window_len);
    const target_len = if (smith.boolWeighted(1, 3))
        declared_cap
    else
        rangeAtMost(smith, 0, declared_cap);

    var window: [decode_window_len + guard_len]u8 = undefined;
    fillSentinels(window[0 .. target_len + guard_len]);

    const target = window[0..target_len];
    const result = decode.decompressBlock(source, target);
    if (target_len < declared) {
        // The size gate: a declared length past the target is refused up
        // front, with no partial output.
        try testing.expectError(error.BufferTooSmall, result);
    } else if (result) |n| {
        // Exactness, then the round trip. `compressBlock` takes one block,
        // so a longer decode round-trips its front.
        try testing.expectEqual(declared, n);
        try blockRoundTrip(target[0..@min(n, block_max)]);
    } else |err| switch (err) {
        error.DecompressionFailed => {},
        error.BufferTooSmall => unreachable, // target_len == declared
    }

    // Overrun: pass or fail, nothing at or past the target's length moved.
    try checkSentinels(&window, target_len, target_len + guard_len);
}

test "snappy fuzz: block decode" {
    try testing.fuzz({}, fuzzBlockDecode, .{ .corpus = block_decode_corpus });
}

/// The input shapes the block round trip feeds the encoder. Random bytes
/// alone mostly exercise the bail-to-literal path; the structured shapes
/// drive the match finder's copy emission.
const Shape = enum(u8) { random, run, phrase, mixed };

/// Fill `buf` with the Smith-chosen shape and return the used length.
fn buildShape(smith: *Smith, buf: []u8) usize {
    const shape = smith.value(Shape);
    const len = rangeAtMost(smith, 0, buf.len);
    if (len == 0) return 0;
    switch (shape) {
        .random => smith.bytes(buf[0..len]),
        .run => {
            // A single-byte run: the repeat-offset check and the RLE copy
            // path, at every length.
            fastmem.set(u8, buf[0..len], smith.value(u8));
        },
        .phrase => {
            // A short phrase repeated: overlapping copies at the phrase's
            // offset, including offsets that divide 16 (the no-op reshuffle).
            const phrase_len = rangeAtMost(smith, 1, @min(len, 64));
            smith.bytes(buf[0..phrase_len]);
            var i = phrase_len;
            while (i < len) : (i += phrase_len) {
                const n = @min(phrase_len, len - i);
                fastmem.copy(u8, buf[i..][0..n], buf[0..n]);
            }
        },
        .mixed => {
            // Runs and random bytes interleaved: a literal, a copy, then a
            // fresh hash insert — the encoder's own scan cascade.
            var i: usize = 0;
            while (i < len) {
                const n = @min(rangeAtMost(smith, 1, 128), len - i);
                if (smith.boolWeighted(1, 1)) {
                    fastmem.set(u8, buf[i..][0..n], smith.value(u8));
                } else {
                    smith.bytes(buf[i..][0..n]);
                }
                i += n;
            }
        },
    }
    return len;
}

/// Target 2: the whole block codec, on the shapes a compressor is worst at.
///
/// Attacks the match finder (hash hits, the repeat-offset check, the skip
/// heuristic, the bail-to-literal threshold) and every copy form it emits.
/// The property: `compressBlock` -> `decompressBlock` is the identity, the
/// preamble is exact, the compressed size stays within `maxCompressedLength`,
/// and the decode writes nothing past the decoded length.
fn fuzzBlockRoundTrip(_: void, smith: *Smith) anyerror!void {
    var input_buf: [block_max]u8 = undefined;
    try blockRoundTrip(input_buf[0..buildShape(smith, &input_buf)]);
}

test "snappy fuzz: block round trip" {
    try testing.fuzz({}, fuzzBlockRoundTrip, .{});
}

/// Target 3: framed stream round trip, `Writer` -> `Reader`.
///
/// Attacks the block splitter (a stream is whole 64 KiB blocks plus a tail),
/// the `u32-le` length prefix, the reader's fill/slide machinery, and the
/// clean end of stream. The property: for any input up to the cap, the
/// decoded bytes are identical and the reader ends cleanly. Both sides write
/// through `Io.Writer.Allocating`, so the runner's per-input leak check
/// covers every `deinit`.
fn fuzzStreamRoundTrip(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    var input_buf: [stream_max]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf);
    try w.writer.writeAll(input);
    try w.finish();

    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    var rbuf: Reader.Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    try pump(&r.reader, &plain.writer, pumpLimit(compressed.written().len));

    try testing.expectEqual(input.len, plain.written().len);
    try testing.expectEqualSlices(u8, input, plain.written());
}

test "snappy fuzz: stream round trip" {
    try testing.fuzz({}, fuzzStreamRoundTrip, .{});
}

/// The `Io.Writer` operations the machinery target mixes, ported from the
/// unit test at Writer.zig:"random write machinery sequences stay correct":
/// the vtable contract under multi-slice splats, partial takes, direct-slice
/// writes onto a full buffer, and mid-stream flushes.
const Op = enum(u8) {
    write_splat_all,
    write_vec_all,
    splat_bytes_all,
    writable_slice,
    byte_and_flush,
};

/// Target 4: the writer's machinery, Smith-driven, against a model.
///
/// Attacks `drain` accounting under the full `Io.Writer` contract —
/// `writeSplatAll` with a splat count, `writeVecAll`, `splatBytesAll`,
/// `writableSliceGreedy` + `advance` (which lands on `rebase` when the
/// accumulation buffer is full), `writeByte`, and mid-stream `flush` — by
/// decoding the produced stream and comparing it against the bytes the model
/// says were written. The unit test is the PRNG version; here the fuzzer
/// drives the operation sequence and the sizes.
fn fuzzStreamMachinery(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var expect: std.ArrayList(u8) = .empty;
    defer expect.deinit(gpa);
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf);

    // The op sources, sliced at Smith-chosen lengths.
    var a: [1024]u8 = undefined;
    var b: [8192]u8 = undefined;
    var pattern: [7]u8 = undefined;
    smith.bytes(&a);
    smith.bytes(&b);
    smith.bytes(&pattern);

    // Bounded work: at most `ops_max` operations writing `write_budget` bytes
    // in total, so one iteration stays a few hundred KiB of data through the
    // machinery no matter what the Smith stream says.
    const write_budget: usize = 96 * 1024;
    const ops_max: usize = 32;
    var remaining = write_budget;
    var ops: usize = 0;
    while (ops < ops_max and !smith.eosWeightedSimple(15, 1)) : (ops += 1) {
        const op = smith.value(Op);
        const a_len = rangeAtMost(smith, 0, a.len);
        const b_len = rangeAtMost(smith, 0, b.len);
        const p_len = rangeAtMost(smith, 1, pattern.len);
        const splat = rangeAtMost(smith, 0, 2048);
        const max_written: usize = switch (op) {
            .write_splat_all => a_len + b_len + p_len * splat,
            .write_vec_all => a_len + b_len,
            .splat_bytes_all => p_len * splat,
            .writable_slice => b_len,
            .byte_and_flush => 1,
        };
        if (max_written > remaining) continue;
        remaining -= max_written;

        switch (op) {
            .write_splat_all => {
                var data = [_][]const u8{ a[0..a_len], b[0..b_len], pattern[0..p_len] };
                try w.writer.writeSplatAll(&data, splat);
                try expect.appendSlice(gpa, a[0..a_len]);
                try expect.appendSlice(gpa, b[0..b_len]);
                for (0..splat) |_| try expect.appendSlice(gpa, pattern[0..p_len]);
            },
            .write_vec_all => {
                var data = [_][]const u8{ a[0..a_len], b[0..b_len] };
                try w.writer.writeVecAll(&data);
                try expect.appendSlice(gpa, a[0..a_len]);
                try expect.appendSlice(gpa, b[0..b_len]);
            },
            .splat_bytes_all => {
                try w.writer.splatBytesAll(pattern[0..p_len], splat);
                for (0..splat) |_| try expect.appendSlice(gpa, pattern[0..p_len]);
            },
            .writable_slice => {
                // The File.Reader simple-mode path: a direct write into the
                // buffer, which lands on `rebase` when the buffer is full.
                const dest = try w.writer.writableSliceGreedy(1);
                const n = @min(dest.len, b_len);
                fastmem.copy(u8, dest[0..n], b[0..n]);
                w.writer.advance(n);
                try expect.appendSlice(gpa, b[0..n]);
            },
            .byte_and_flush => {
                const byte = smith.value(u8);
                try w.writer.writeByte(byte);
                try expect.append(gpa, byte);
                if (smith.boolWeighted(1, 1)) try w.writer.flush();
            },
        }
    }
    try w.finish();

    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    var rbuf: Reader.Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    try pump(&r.reader, &plain.writer, pumpLimit(compressed.written().len));
    try testing.expectEqualSlices(u8, expect.items, plain.written());
}

test "snappy fuzz: stream machinery" {
    try testing.fuzz({}, fuzzStreamMachinery, .{});
}

/// The corruption operators. Each keeps `buf[0..len.*]` in bounds; the stream
/// is corrupted in place and then parsed by both the reader and the reference
/// walk.
const Mutation = enum(u8) {
    truncate,
    flip_byte,
    poke_length,
    append_bytes,
    duplicate_prefix,
};

/// The framing-corruption stream cap: the worst-case compressed form of one
/// `framing_max` block plus its length prefix, plus room for appended bytes.
const mut_max: usize = encode.maxCompressedLength(framing_max) + 4 + 64;

/// Apply a Smith-chosen sequence of corruptions to `buf[0..len.*]`.
fn mutateStream(smith: *Smith, buf: []u8, len: *usize) !void {
    var i: usize = 0;
    while (i < 8 and !smith.eosWeightedSimple(7, 1)) : (i += 1) {
        switch (smith.value(Mutation)) {
            .truncate => len.* = rangeAtMost(smith, 0, len.*),
            .flip_byte => {
                if (len.* == 0) continue;
                buf[smith.index(len.*)] ^= smith.value(u8);
            },
            .poke_length => {
                // A declared block length: zero, one, absurd, or arbitrary.
                // Poked at any offset, which is usually a block's 4-byte
                // prefix and sometimes data inside a block.
                if (len.* < 4) continue;
                const at = smith.index(len.* - 3);
                const value: u32 = switch (smith.valueRangeAtMost(u8, 0, 3)) {
                    0 => 0,
                    1 => 1,
                    2 => std.math.maxInt(u32),
                    else => smith.value(u32),
                };
                common.writeInt(u32, buf[at..][0..4], value);
            },
            .append_bytes => {
                const extra = @min(buf.len - len.*, rangeAtMost(smith, 0, 64));
                smith.bytes(buf[len.*..][0..extra]);
                len.* += extra;
            },
            .duplicate_prefix => {
                // Two streams concatenated: the framing has no end marker, so
                // this must decode as the input twice.
                const room = @min(len.*, buf.len - len.*);
                const take = rangeAtMost(smith, 0, room);
                fastmem.copy(u8, buf[len.*..][0..take], buf[0..take]);
                len.* += take;
            },
        }
    }
}

/// Walk the framing independently of `Reader`: decode each `u32-le`-prefixed
/// block with the block decoder and append it to `plain`. Returns true when
/// the whole buffer parsed; false at the first framing or block error, with
/// the bytes decoded before it still in `plain`.
///
/// The rules are README.md's ("Streaming"): a 4-byte prefix with a length in
/// `[1, scratch_len]`, that many block bytes, and a block whose declared
/// decoded length fits one block. The block decode itself is shared with
/// `Reader` — that layer has its own target.
fn referenceDecode(stream: []const u8, plain: *Io.Writer.Allocating) !bool {
    var block_buf: [block_max]u8 = undefined;
    var pos: usize = 0;
    while (pos < stream.len) {
        if (stream.len - pos < 4) return false;
        const block_len = common.readInt(u32, stream[pos..][0..4]);
        pos += 4;
        if (block_len == 0 or block_len > Writer.scratch_len) return false;
        if (stream.len - pos < block_len) return false;
        const block = stream[pos..][0..block_len];
        pos += block_len;
        const decoded_len = decode.decompressedBlockLen(block) catch return false;
        if (decoded_len > block_max) return false;
        const n = decode.decompressBlock(block, block_buf[0..decoded_len]) catch return false;
        try plain.writer.writeAll(block_buf[0..n]);
    }
    return true;
}

/// Target 5: framing corruption.
///
/// Attacks truncation at any offset (mid-prefix, mid-block, mid-stream), byte
/// flips inside blocks and prefixes, declared lengths poked past the staging
/// region, appended garbage, and stream duplication. The property: the reader
/// either fails closed (`ReadFailed`, sticky) or serves exactly the bytes an
/// independent framing parse of the same buffer produces, and it never
/// panics, stalls, or writes outside its buffer.
fn fuzzFramingCorruption(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    var input_buf: [framing_max]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    // A valid stream to corrupt.
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf);
    try w.writer.writeAll(input);
    try w.finish();

    var mut_buf: [mut_max]u8 = undefined;
    // The annotation matters: `@min` with a comptime-known operand narrows to
    // the smallest type that holds the result, which is a `u16` here.
    var mut_len: usize = @min(compressed.written().len, mut_buf.len);
    fastmem.copy(u8, mut_buf[0..mut_len], compressed.written()[0..mut_len]);
    try mutateStream(smith, &mut_buf, &mut_len);
    const mutated = mut_buf[0..mut_len];

    // The oracle: what the framing says is decodable.
    var expected: Io.Writer.Allocating = .init(gpa);
    defer expected.deinit();
    const all_valid = try referenceDecode(mutated, &expected);

    var got: Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    var rbuf: Reader.Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(mutated);
    var r: Reader = .init(&fixed_in, &rbuf);
    const call_limit = pumpLimit(mutated.len);
    if (all_valid) {
        try pump(&r.reader, &got.writer, call_limit);
    } else {
        try testing.expectError(error.ReadFailed, pump(&r.reader, &got.writer, call_limit));
    }

    // Either way, the bytes served before the end (clean or failed) are the
    // framing's decoded bytes.
    try testing.expectEqualSlices(u8, expected.written(), got.written());

    // Both terminal states are sticky: a failed reader stays failed, a done
    // reader stays at the clean end.
    var sink: Io.Writer.Discarding = .init(&.{});
    const sticky = if (all_valid) error.EndOfStream else error.ReadFailed;
    try testing.expectError(sticky, r.reader.stream(&sink.writer, .unlimited));
}

test "snappy fuzz: framing corruption" {
    try testing.fuzz({}, fuzzFramingCorruption, .{});
}
