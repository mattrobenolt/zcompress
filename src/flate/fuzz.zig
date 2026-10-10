//! Fuzz targets for the flate module, one per layer of the decode surface:
//!
//!   - `fuzzBlockDecode`: arbitrary bytes into `decode.decompress` against a
//!     few window shapes, with the sentinel overrun check and a re-encode
//!     round trip (the oracle-within-process property) on every success.
//!   - `fuzzRoundTrip`: structured shapes (runs, repeated phrases, mixed
//!     text+random, the block-boundary sizes) through `encode.compress` ->
//!     `decode.decompress`: identity, the `maxCompressedLength` bound on every
//!     emission, and the T4 ending.
//!   - `fuzzStreamRoundTrip`: `Writer` -> `Reader` identity over raw streams,
//!     through both `streamAll` pairs and the manual init/write/finish and
//!     consume paths, plus the exact-boundary property: a stream followed by
//!     marker bytes consumes the input exactly through the stream's last byte
//!     — markers never read.
//!   - `fuzzStreamMachinery`: Smith-chosen `Io.Writer` operation sequences
//!     (writeAll/writeSplatAll/writeVecAll/splatBytesAll/writableSliceGreedy +
//!     advance/writeByte/flush) against an expected-bytes model, then decoded
//!     through `Reader` and compared.
//!   - `fuzzCorruption`: valid (and committed invalid) streams with Smith
//!     mutations — truncation at byte and bit boundaries, byte and bit flips,
//!     poked LEN/NLEN, poked tree headers — against an independent walk of the
//!     same bytes; the `Reader` must fail closed (stickily, `err` set) or serve
//!     exactly what the walk says, and never write outside its window.
//!   - `fuzzReaderMachinery`: Smith-chosen consumer op sequences
//!     (peek/take/discardAll/readSliceAll/stream) over known streams, with the
//!     contiguous-read cap probed past `history_len`.
//!
//! Run with `just fuzz <budget>` (ReleaseSafe only: a Debug-mode fuzz run hits
//! ziglang/zig#30655). Every target caps its per-iteration input
//! (`source_max`, `roundtrip_max`, `stream_max`, `corrupt_source_max`,
//! `reader_source_max`) and its per-iteration work (`corrupt_out_max`,
//! `write_budget`) so a budget run finishes. The codec allocates nothing; the
//! only allocation is the harness's `Io.Writer.Allocating`/`ArrayList`, which
//! the runner's per-input leak check covers.
//!
//! Spec: docs/research/specs/rfc1951-deflate.txt (§3.1.1 bit packing, §3.2.3
//! block format, §3.2.4 stored blocks, §3.2.5 length/distance codes, §3.2.6
//! fixed Huffman, §3.2.7 dynamic Huffman). Contracts: src/flate/README.md.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;
const Smith = testing.Smith;
const math = std.math;
const mem = std.mem;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const golden = @import("golden.zig");
const Reader = @import("Reader.zig");
const Writer = @import("Writer.zig");

// ---------------------------------------------------------------------------
// Shared harness
// ---------------------------------------------------------------------------

/// Bytes past the decoded length checked on every decode: an out-of-bounds
/// write (a 16-byte SIMD store, a 64-byte copy chunk) lands in this region.
const guard_len: usize = 256;

/// A Smith-chosen value in `[at_least, at_most]`. `Smith.valueRangeAtMost`
/// rejects `usize` (no fixed bitsize), so bounded lengths go through a `u32`
/// and widen here; every call site is inside a per-iteration cap.
fn rangeAtMost(smith: *Smith, at_least: usize, at_most: usize) usize {
    assert(at_least <= at_most);
    assert(at_most <= std.math.maxInt(u32));
    return smith.valueRangeAtMost(u32, @intCast(at_least), @intCast(at_most));
}

/// A Smith-picked implemented level: `fast` or the stored-only `@"0"`, or one
/// of the numeric aliases that tune to `fast` today (encode.Level's contract).
/// `ratio` is never returned — it is `error.Unimplemented`, exercised
/// explicitly by the round-trip target.
fn implementedLevel(smith: *Smith) encode.Level {
    const pick = rangeAtMost(smith, 0, 10);
    if (pick == 0) return .fast;
    return @enumFromInt(@as(u8, @intCast(pick + 1)));
}

/// README "Divergences" T4, `§3.2.3` — every stream ends with the final empty
/// fixed block: BFINAL=1, BTYPE=01, end-of-block. `golden.expectFinalEmptyBlock`
/// pins the ten ending bits; when the ending lands byte-aligned (every stored
/// block, and any fixed block whose payload ends on a byte) those ten bits are
/// the literal last two bytes, `03 00`.
fn expectT4Ending(stream: []const u8) !void {
    try golden.expectFinalEmptyBlock(stream);
    const total_bits = stream.len * 8;
    var bit = total_bits;
    var last_set: usize = 0;
    while (bit > 0) {
        bit -= 1;
        if ((stream[bit / 8] >> @intCast(bit % 8)) & 1 != 0) {
            last_set = bit;
            break;
        }
    }
    const start = last_set - 1; // expectFinalEmptyBlock proved last_set >= 1
    if (start % 8 != 0) return;
    try testing.expectEqual(@as(u8, 0x03), stream[start / 8]);
    try testing.expectEqual(@as(u8, 0x00), stream[start / 8 + 1]);
}

/// How many `stream` calls decoding `plain_len` bytes may take: each call
/// either serves buffered bytes or fills the window with at least one byte (a
/// zero-serve call is always followed by one that serves), so two calls per
/// output byte plus slack for a stall is a generous bound. More calls than
/// this is a hang, not a timeout.
fn pumpLimit(plain_len: usize) usize {
    return 16 + 2 * plain_len;
}

/// Pump `r` into `w` until the clean end of stream (the shape of Reader.zig's
/// own `pump` driver), bounded: a reader that neither serves bytes nor fails
/// is a hang, not a timeout.
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

/// A Smith-serialized `u64`: the little-endian form every `smith.value` call
/// consumes, so hand-built seeds can pin the values the target reads.
fn u64Le(comptime value: u64) [8]u8 {
    var out: [8]u8 = undefined;
    mem.writeInt(u64, &out, value, .little);
    return out;
}

/// A target-1 seed in Smith's serialized form: the `u32-le` length plus the
/// bytes `smith.slice` consumes, then the little-endian u64 that selects the
/// full 64-KiB window shape (3).
fn decodeSeed(comptime block: []const u8) [4 + block.len + 8]u8 {
    var seed: [4 + block.len + 8]u8 = undefined;
    mem.writeInt(u32, seed[0..4], @intCast(block.len), .little);
    for (block, 0..) |b, i| seed[4 + i] = b;
    fastmem.set(u8, seed[4 + block.len ..], 0);
    seed[4 + block.len] = 3;
    return seed;
}

/// A target-5 seed in Smith's serialized form: the u64 that selects the raw
/// slice source (1), then the `u32-le` length plus bytes `smith.slice`
/// consumes. An empty mutation stream follows, so the seed itself is the
/// stream under test.
fn streamSeed(comptime stream: []const u8) [8 + 4 + stream.len]u8 {
    var seed: [8 + 4 + stream.len]u8 = undefined;
    mem.writeInt(u64, seed[0..8], 1, .little);
    mem.writeInt(u32, seed[8..12], @intCast(stream.len), .little);
    for (stream, 0..) |b, i| seed[12 + i] = b;
    return seed;
}

/// A target-3/target-6 seed in Smith's serialized form: the little-endian
/// level `smith.value(encode.Level)` consumes, then the `u32-le` length plus
/// bytes `smith.slice` consumes.
fn sliceSeed(comptime level: u64, comptime bytes: []const u8) [12 + bytes.len]u8 {
    @setEvalBranchQuota(10_000);
    var seed: [12 + bytes.len]u8 = undefined;
    mem.writeInt(u64, seed[0..8], level, .little);
    mem.writeInt(u32, seed[8..12], @intCast(bytes.len), .little);
    for (bytes, 0..) |b, i| seed[12 + i] = b;
    return seed;
}

// ---------------------------------------------------------------------------
// Target 1: arbitrary bytes into the one-shot decoder
// ---------------------------------------------------------------------------

/// The block-decode source cap. A hostile stream expands at most ~1032x (a
/// dynamic tree can code 258-byte matches in two bits), so the source is kept
/// small and the window is what bounds the work.
const source_max: usize = 4 * 1024;

/// The widest decode window target 1 sizes: `Reader.Buffer`'s own 64 KiB, so a
/// decoded stream can exceed one block and still be re-encoded in full.
const decode_window_len: usize = 2 * encode.history_len;

/// The window shapes target 1 draws: empty, tiny, one block's worth, and the
/// full window. The full shape is the "larger cap" the sentinel check needs;
/// the short ones exercise the size gate (`error.BufferTooSmall`) on streams
/// that decode to more than they hold.
fn windowShape(smith: *Smith) usize {
    return switch (rangeAtMost(smith, 0, 3)) {
        0 => 0,
        1 => rangeAtMost(smith, 0, 64),
        2 => rangeAtMost(smith, 0, 4096),
        else => decode_window_len,
    };
}

/// Re-encode `bytes` with a Smith-picked implemented level and decode it back:
/// whatever a hostile input decoded to must survive a full compress/decompress
/// cycle (the oracle-within-process property — our encoder is checked by our
/// decoder on bytes the fuzzer chose, not on bytes we chose).
fn reencodeRoundTrip(bytes: []const u8, smith: *Smith) !void {
    assert(bytes.len <= decode_window_len);
    const level = implementedLevel(smith);
    var compressed: [encode.maxCompressedLength(decode_window_len)]u8 = undefined;
    const c_len = try encode.compress(bytes, &compressed, .{ .level = level });
    try testing.expect(c_len <= encode.maxCompressedLength(bytes.len));

    var plain: [decode_window_len + guard_len]u8 = undefined;
    sentinel.fill(&plain);
    const n = try decode.decompress(compressed[0..c_len], plain[0..bytes.len]);
    try testing.expectEqual(bytes.len, n);
    try testing.expectEqualSlices(u8, bytes, plain[0..n]);
    try sentinel.expect(&plain, n);
}

/// Target 1: arbitrary bytes into the one-shot decoder.
///
/// Attacks the bit reader's `take` gate (a truncated stream must never decode a
/// symbol out of zero padding), the block-header dispatch, the stored LEN/NLEN
/// path, the fixed and dynamic tables, the length/distance extra bits, the
/// match copy (including overlapping and distance-1 runs), the
/// distance-past-the-start check, and the target-as-cap size gate. The
/// property: decode either fails closed with a `DecompressError` or is exact —
/// the bytes it produced re-encode to a stream that decodes back to the same
/// bytes — and no byte past the window's length is ever touched.
fn fuzzBlockDecode(_: void, smith: *Smith) anyerror!void {
    var source_buf: [source_max]u8 = undefined;
    const source = source_buf[0..smith.slice(&source_buf)];

    const window_len = windowShape(smith);
    var window: [decode_window_len + guard_len]u8 = undefined;
    sentinel.fill(window[0 .. window_len + guard_len]);

    const target = window[0..window_len];
    if (decode.decompress(source, target)) |n| {
        // The declared length is the decoded length: no partial success.
        try testing.expect(n <= window_len);
        try reencodeRoundTrip(target[0..n], smith);
    } else |_| {
        // Every failure is a `DecompressError`: the size gate
        // (`BufferTooSmall`, a stream that wants more than the window holds)
        // or one of the specific malformed-stream errors. A success that
        // overran the window is caught by the sentinel check below.
    }

    // Overrun: pass or fail, nothing at or past the window's length moved.
    try sentinel.expect(window[0 .. window_len + guard_len], window_len);
}

/// Seed corpus for target 1: the committed micro-streams (one per block kind),
/// the RFC §3.2.3 overlap example, and a few pre-corrupt streams, so the
/// fuzzer starts from real bit patterns instead of discovering the format from
/// scratch.
const block_decode_corpus: []const []const u8 = &.{
    &decodeSeed(""),
    &decodeSeed("\x03\x00"),
    // Zig std's raw micro-streams: stored, fixed, dynamic (golden.zig).
    &decodeSeed("\x01\x0c\x00\xf3\xffHello world\x0a"),
    &decodeSeed("\xf3\x48\xcd\xc9\xc9\x57\x28\xcf\x2f\xca\x49\xe1\x02\x00"),
    &decodeSeed("\x3d\xc6\x39\x11\x00\x00\x0c\x02\x30\x2b\xb5\x52\x1e\xff\x96\x38" ++
        "\x16\x96\x5c\x1e\x94\xcb\x6d\x01"),
    // RFC 1951 §3.2.3: <length = 5, distance = 2> adds X,Y,X,Y,X.
    &decodeSeed("\x8b\x88\x04\x43\x00"),
    // Corrupt: BTYPE = 11 (reserved), a bad stored NLEN, and a truncated
    // stored payload.
    &decodeSeed("\x07"),
    &decodeSeed("\x01\x0c\x00\x00\x00\x61"),
    &decodeSeed("\x01\x0c\x00\xf3\xffhi"),
};

test "flate fuzz: block decode" {
    try testing.fuzz({}, fuzzBlockDecode, .{ .corpus = block_decode_corpus });
}

// ---------------------------------------------------------------------------
// Target 2: the one-shot round trip
// ---------------------------------------------------------------------------

/// The round-trip source cap: the widest boundary case (131070) rounded up to
/// 128 KiB. Two blocks plus a tail, so the block split and the cross-block
/// match reach both run.
const roundtrip_max: usize = 131_072;

/// The input shapes the round trip feeds the encoder. Random bytes alone mostly
/// exercise the stored fallback; the structured shapes drive the match finder's
/// copy emission.
const Shape = enum(u8) { random, run, phrase, mixed, boundary };

/// The block-boundary sizes the `.boundary` shape pins: one below, at, and
/// above `max_block_size` (65535), and a two-block length (README, "Encoder":
/// the encoder splits at 65535).
const boundary_sizes = [_]usize{ 65534, 65535, 65536, 131070 };

/// Fill `buf` with the Smith-chosen shape and return the used length. The
/// boundary shape takes its length from `boundary_sizes` regardless of the
/// Smith stream, so the block split is exercised on every budget run without
/// the fuzzer having to discover 65535.
fn buildShape(smith: *Smith, buf: []u8) usize {
    const shape = smith.value(Shape);
    const len = switch (shape) {
        .boundary => boundary_sizes[smith.index(boundary_sizes.len)],
        else => rangeAtMost(smith, 0, buf.len),
    };
    const used = @min(len, buf.len);
    if (used == 0) return 0;
    switch (shape) {
        .random => smith.bytes(buf[0..used]),
        .run => {
            // A single-byte run: distance-1 matches at every length, and the
            // stored fallback once the run is short enough to be cheaper raw.
            fastmem.set(u8, buf[0..used], smith.value(u8));
        },
        .phrase => {
            // A short phrase repeated: overlapping copies at the phrase's
            // offset, including offsets that divide the copy chunk.
            const phrase_len = rangeAtMost(smith, 1, @min(used, 64));
            smith.bytes(buf[0..phrase_len]);
            var i = phrase_len;
            while (i < used) : (i += phrase_len) {
                const n = @min(phrase_len, used - i);
                fastmem.copy(u8, buf[i..][0..n], buf[0..n]);
            }
        },
        .mixed => {
            // Runs and random bytes interleaved: a literal, a copy, then a
            // fresh hash insert — the encoder's own scan cascade.
            var i: usize = 0;
            while (i < used) {
                const n = @min(rangeAtMost(smith, 1, 128), used - i);
                if (smith.boolWeighted(1, 1)) {
                    fastmem.set(u8, buf[i..][0..n], smith.value(u8));
                } else {
                    smith.bytes(buf[i..][0..n]);
                }
                i += n;
            }
        },
        .boundary => {
            // A repeated phrase at a block-boundary length: matches that
            // straddle the split, and the stored fallback for the tail.
            const phrase_len = rangeAtMost(smith, 8, 64);
            smith.bytes(buf[0..phrase_len]);
            var i = phrase_len;
            while (i < used) : (i += phrase_len) {
                const n = @min(phrase_len, used - i);
                fastmem.copy(u8, buf[i..][0..n], buf[0..n]);
            }
        },
    }
    return used;
}

/// A target-2 seed in Smith's serialized form: the level, the shape, and the
/// length `buildShape` reads, then `content` — the bytes the shape's own
/// `smith.value`/`smith.bytes` calls consume.
fn shapeSeed(
    comptime level: u64,
    comptime shape: Shape,
    comptime len: u64,
    comptime content: []const u8,
) [24 + content.len]u8 {
    var seed: [24 + content.len]u8 = undefined;
    mem.writeInt(u64, seed[0..8], level, .little);
    mem.writeInt(u64, seed[8..16], @intFromEnum(shape), .little);
    mem.writeInt(u64, seed[16..24], len, .little);
    for (content, 0..) |b, i| seed[24 + i] = b;
    return seed;
}

/// Seeds for target 2: the Smith values the shape builder reads, so each seed
/// pins a structure instead of relying on the fuzzer to grow one. `0` is
/// `fast`, `1` is `ratio`, `2` is `@"0"` (stored-only).
const roundtrip_corpus: []const []const u8 = &.{
    // A 65534-byte phrase at the block split (the seed runs out of content
    // bytes, so the phrase is eight zero bytes repeated).
    &shapeSeed(0, .boundary, 0, ""),
    // A 4096-byte run of 'A' through the match finder: the shape reads one
    // `smith.value(u8)`, the seed supplies it as a u64.
    &shapeSeed(0, .run, 4096, &u64Le(0x41)),
    // A 2048-byte phrase, eight bytes long, repeated: the shape reads a
    // phrase length, then that many content bytes.
    &shapeSeed(0, .phrase, 2048, &(u64Le(8) ++ [8]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' })),
    // 70000 bytes of 'Z' at the stored-only level: two stored blocks plus the
    // final empty fixed block.
    &shapeSeed(2, .run, 70_000, &u64Le(0x5a)),
    // The reserved ratio mode: `error.Unimplemented`, never a silent alias.
    &shapeSeed(1, .random, 0, ""),
};

/// Target 2: the whole one-shot codec, on the shapes a compressor is worst at.
///
/// Attacks the match finder (hash hits, the 4-byte confirm, backward
/// extension, the accelerating skip, the 258/255 long-match split), the
/// fixed-vs-stored bail threshold, the block split at `max_block_size`, the
/// cross-block match reach, and the final empty fixed block. The property:
/// `compress` -> `decompress` is the identity, the compressed size stays
/// within `maxCompressedLength` on every emission, the stream ends with the T4
/// ending (`03 00` where byte-aligned), and the decode writes nothing past the
/// decoded length.
fn fuzzRoundTrip(_: void, smith: *Smith) anyerror!void {
    const level = smith.value(encode.Level);
    var source_buf: [roundtrip_max]u8 = undefined;
    const source = source_buf[0..buildShape(smith, &source_buf)];

    if (level == .ratio) {
        // encode.Level's contract: the ratio mode is `error.Unimplemented` on
        // both layers, never silent aliasing.
        var tiny: [8]u8 = undefined;
        try testing.expectError(
            error.Unimplemented,
            encode.compress(source, &tiny, .{ .level = .ratio }),
        );
        var sink: Io.Writer.Discarding = .init(&.{});
        var fixed_in: Io.Reader = .fixed(source);
        try testing.expectError(
            error.ReadFailed,
            Writer.streamAll(&fixed_in, &sink.writer, .{ .level = .ratio }),
        );
        return;
    }

    var compressed_buf: [encode.maxCompressedLength(roundtrip_max)]u8 = undefined;
    const c_len = try encode.compress(source, &compressed_buf, .{ .level = level });
    const compressed = compressed_buf[0..c_len];

    // The documented bound, on every emission: `maxCompressedLength` is a
    // promise, not a guess (README, "Contracts").
    try testing.expect(c_len <= encode.maxCompressedLength(source.len));
    try expectT4Ending(compressed);

    var plain_buf: [roundtrip_max + guard_len]u8 = undefined;
    // Exact cap first: a decoder that writes past the decoded length lands in
    // the guard region, not past the array (the sentinel check is what proves
    // it did not write there).
    sentinel.fill(&plain_buf);
    const n = try decode.decompress(compressed, plain_buf[0..source.len]);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, plain_buf[0..n]);
    try sentinel.expect(&plain_buf, n);

    // Then with slack, so the bytes past the decoded length are checked too.
    sentinel.fill(&plain_buf);
    const m = try decode.decompress(compressed, &plain_buf);
    try testing.expectEqual(n, m);
    try testing.expectEqualSlices(u8, source, plain_buf[0..m]);
    try sentinel.expect(&plain_buf, m);
}

test "flate fuzz: one-shot round trip" {
    try testing.fuzz({}, fuzzRoundTrip, .{ .corpus = roundtrip_corpus });
}

// ---------------------------------------------------------------------------
// Target 3: the streaming round trip
// ---------------------------------------------------------------------------

/// The stream source cap: two `Reader.Buffer` windows' worth, so the reader
/// slides repeatedly and the writer emits multiple blocks.
const stream_max: usize = 128 * 1024;

/// The mid-stream flush budget: how many Smith-chosen flushes the stream
/// target's writer loop may take. Every flush ends the current block and
/// every block costs at most 5 stored-header bytes beyond its input (the
/// stored-block fallback, README "Encoder"), so each flushed block grows
/// the stream past the no-flush `maxCompressedLength` bound by at most 5
/// bytes — `framed` below carries `5 * flush_budget` of headroom for
/// exactly this (the bound itself budgets only the unflushed block count).
const flush_budget: usize = 16;

/// Marker bytes appended after a stream to prove the reader stops at the
/// stream's last byte (README, "Streaming"): the format is self-delimiting, so
/// bytes after BFINAL are not the reader's to consume.
const marker_len: usize = 8;
const marker_byte: u8 = 0xa5;

/// Target 3: `Writer` -> `Reader` identity over raw deflate streams.
///
/// Attacks the streaming encoder's block accumulation and flush path, the
/// final empty fixed block, the decoder's window slide and refill, and the
/// exact-boundary rule: the reader consumes its input through the stream's
/// last byte (the final block's partial byte included) and never reads a byte
/// past it — the property M3's gzip/zlib readers depend on to find a footer.
/// Both `streamAll` pairs and the manual init/write/finish and consume paths
/// are driven, with Smith-chosen write chunking and mid-stream flushes.
fn fuzzStreamRoundTrip(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    const level = implementedLevel(smith);
    var input_buf: [stream_max]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    // Path A — the `streamAll` pair: Writer.streamAll consumes its input
    // exactly, then Reader.streamAll decodes it back.
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var source_in: Io.Reader = .fixed(input);
    const consumed = try Writer.streamAll(&source_in, &compressed.writer, .{ .level = level });
    try testing.expectEqual(input.len, consumed);
    try testing.expectEqual(input.len, source_in.seek);
    const stream = compressed.written();
    try expectT4Ending(stream);

    // The exact-boundary property: the stream followed by marker bytes.
    var framed: [
        encode.maxCompressedLength(stream_max) +
            marker_len + 5 * flush_budget
    ]u8 = undefined;
    try testing.expect(stream.len <= framed.len - marker_len);
    fastmem.copy(u8, framed[0..stream.len], stream);
    fastmem.set(u8, framed[stream.len..], marker_byte);
    var framed_in: Io.Reader = .fixed(&framed);
    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    const served = try Reader.streamAll(&framed_in, &plain.writer);
    try testing.expectEqual(input.len, served);
    try testing.expectEqualSlices(u8, input, plain.written());
    try testing.expectEqual(stream.len, framed_in.seek);

    // Path B — manual init/write/finish, then a manual consume: Smith-chosen
    // write chunks and mid-stream flushes, so the block split follows the
    // caller's calls (README, "Encoder": the split follows writes and flushes).
    var compressed2: Io.Writer.Allocating = .init(gpa);
    defer compressed2.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed2.writer, &wbuf, .{ .level = level });
    var pos: usize = 0;
    var flushes: usize = 0;
    while (pos < input.len) {
        const n = @min(input.len - pos, rangeAtMost(smith, 1, 32 * 1024));
        try w.writer.writeAll(input[pos..][0..n]);
        pos += n;
        if (flushes < flush_budget and smith.boolWeighted(1, 3)) {
            try w.writer.flush();
            flushes += 1;
        }
    }
    try w.finish();
    const stream2 = compressed2.written();
    try expectT4Ending(stream2);

    var rbuf: Reader.Buffer = undefined;
    var in2: Io.Reader = .fixed(stream2);
    var r: Reader = .init(&in2, &rbuf);
    var out2: Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    try pump(&r.reader, &out2.writer, pumpLimit(input.len));
    try testing.expectEqualSlices(u8, input, out2.written());
    try testing.expectEqual(stream2.len, in2.seek);

    // The clean end of stream is sticky.
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectEqual(@as(?Reader.Error, null), r.err);
}

/// Seeds for target 3: the level, then the `u32-le` length plus bytes
/// `smith.slice` consumes — a repeated phrase, which the encoder turns into
/// matches across blocks.
const stream_corpus: []const []const u8 = &.{
    &sliceSeed(0, "the quick brown fox " ** 8),
    // implementedLevel maps pick 1 to the stored-only .@"0" (pick+1 is the
    // Level backing int: 2 = .@"0"), with real content so stored blocks emit.
    &sliceSeed(1, "z" ** 1024),
};

test "flate fuzz: stream round trip" {
    try testing.fuzz({}, fuzzStreamRoundTrip, .{ .corpus = stream_corpus });
}

// ---------------------------------------------------------------------------
// Target 4: the writer's machinery
// ---------------------------------------------------------------------------

/// The `Io.Writer` operations the machinery target mixes, ported from the unit
/// test at Writer.zig:"random write machinery sequences stay correct": the
/// vtable contract under multi-slice splats, partial takes, direct-slice
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
/// Attacks `drain`/`rebase`/`compact` accounting under the full `Io.Writer`
/// contract — `writeSplatAll` with a splat count, `writeVecAll`,
/// `splatBytesAll`, `writableSliceGreedy` + `advance` (which lands on `rebase`
/// when the accumulation buffer is full), `writeByte`, and mid-stream `flush`
/// — by decoding the produced stream through `Reader` and comparing it against
/// the bytes the model says were written. The unit test is the PRNG version;
/// here the fuzzer drives the operation sequence and the sizes.
fn fuzzStreamMachinery(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var expect: std.ArrayList(u8) = .empty;
    defer expect.deinit(gpa);
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});

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
    try expectT4Ending(compressed.written());

    // Decode through the streaming Reader and compare against the model.
    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    var fixed_in: Io.Reader = .fixed(compressed.written());
    const served = try Reader.streamAll(&fixed_in, &plain.writer);
    try testing.expectEqual(expect.items.len, served);
    try testing.expectEqualSlices(u8, expect.items, plain.written());
}

test "flate fuzz: stream machinery" {
    try testing.fuzz({}, fuzzStreamMachinery, .{});
}

// ---------------------------------------------------------------------------
// Target 5: corruption, against an independent walk
// ---------------------------------------------------------------------------

/// The corruption source cap: the valid stream is built from at most this much
/// plaintext (or a committed golden stream), and the mutations stay inside it.
const corrupt_source_max: usize = 2048;

/// The corruption output cap: the walk's target and the reader's fixed output.
/// A hostile stream can expand ~1032x from its input (a dynamic tree can code
/// 258-byte matches in two bits), so a 2-KiB mutation can out-expand this cap —
/// the cap branch below is the honest way to bound the work, and the reader's
/// own window is what bounds *its* memory (README, "Amplification").
const corrupt_out_max: usize = 192 * 1024;

/// Every committed stream the corruption target can seed from: the micro
/// streams (one per block kind), Go's `deflateTests` streams, the `.ok`
/// `TestStreams` rows, and the truncated/reject vectors — a pre-corrupted
/// stream is a mutation the fuzzer would otherwise have to find.
const seed_streams: []const []const u8 = blk: {
    @setEvalBranchQuota(10_000);
    var out: []const []const u8 = &.{};
    for (golden.micro_cases) |tc| out = out ++ .{tc.source};
    for (golden.deflate_cases) |tc| out = out ++ .{tc.source};
    for (golden.truncated_cases) |tc| out = out ++ .{tc.source};
    for (golden.stream_cases) |tc| out = out ++ .{tc.source};
    break :blk out;
};

/// The largest seed stream, so the mutation buffer covers every one of them.
const seed_stream_max = blk: {
    var max: usize = 0;
    for (seed_streams) |stream| max = @max(max, stream.len);
    break :blk max;
};
comptime {
    // A stack-sized mutation buffer: a much larger committed vector means the
    // target's caps need a second look, not a silent stack growth.
    assert(seed_stream_max <= 8 * 1024);
}

/// The mutation buffer: the widest valid stream the target builds (the
/// encoder's own output for `corrupt_source_max`, or a committed seed) plus
/// room for appended and duplicated bytes.
const corrupt_mut_max: usize = @max(
    encode.maxCompressedLength(corrupt_source_max),
    seed_stream_max,
) + 256;

/// The corruption operators. Each keeps `buf[0..len.*]` in bounds; the stream
/// is corrupted in place and then walked by both the reference and the reader.
const Mutation = enum(u8) {
    /// Cut the input at a Smith-chosen byte.
    truncate,
    /// The byte-string form of a bit-boundary truncation: the last byte keeps
    /// only its low `k` bits, so the final symbol is cut mid-code.
    zero_tail_bits,
    /// Flip one bit inside the stream.
    flip_bit,
    /// Flip a whole byte.
    flip_byte,
    /// Poke a *consistent* stored header (LEN and NLEN agree), so the declared
    /// payload length is a lie the framing accepts.
    poke_stored_len,
    /// Poke an inconsistent one (NLEN != ~LEN).
    poke_stored_nlen,
    /// Force the first block's BTYPE (00/01/10/11), so the bits after it are
    /// read as a header of a different kind — or as the reserved type.
    poke_block_type,
    /// Append bytes after the final block: the reader must stop at the stream.
    append_bytes,
    /// Append a copy of the stream's front: a second stream the reader must
    /// not decode.
    duplicate_prefix,
};

/// Apply a Smith-chosen sequence of corruptions to `buf[0..len.*]`.
fn mutateStream(smith: *Smith, buf: []u8, len: *usize) void {
    var i: usize = 0;
    while (i < 8 and !smith.eosWeightedSimple(7, 1)) : (i += 1) {
        switch (smith.value(Mutation)) {
            .truncate => len.* = rangeAtMost(smith, 0, len.*),
            .zero_tail_bits => {
                if (len.* == 0) continue;
                const keep: u3 = @intCast(rangeAtMost(smith, 1, 7));
                buf[len.* - 1] &= (@as(u8, 1) << keep) - 1;
            },
            .flip_bit => {
                if (len.* == 0) continue;
                const at = smith.index(len.*);
                buf[at] ^= @as(u8, 1) << @intCast(rangeAtMost(smith, 0, 7));
            },
            .flip_byte => {
                if (len.* == 0) continue;
                buf[smith.index(len.*)] ^= smith.value(u8);
            },
            .poke_stored_len, .poke_stored_nlen => {
                // A declared block length: zero, one, the stored cap, or
                // arbitrary. Poked at any offset, which is usually a stored
                // block's LEN/NLEN and sometimes data inside a block.
                if (len.* < 4) continue;
                const at = smith.index(len.* - 3);
                const value: u16 = switch (rangeAtMost(smith, 0, 3)) {
                    0 => 0,
                    1 => 1,
                    2 => math.maxInt(u16),
                    else => smith.value(u16),
                };
                writeU16Le(buf, at, value);
                const nlen = if (smith.boolWeighted(1, 1)) ~value else value;
                writeU16Le(buf, at + 2, nlen);
            },
            .poke_block_type => {
                if (len.* == 0) continue;
                // §3.2.3: BFINAL then BTYPE, two bits LSB-of-value first.
                const btype: u2 = @intCast(rangeAtMost(smith, 0, 3));
                buf[0] = (buf[0] & ~@as(u8, 0b110)) | (@as(u8, btype) << 1);
            },
            .append_bytes => {
                const extra = @min(buf.len - len.*, rangeAtMost(smith, 0, 64));
                smith.bytes(buf[len.*..][0..extra]);
                len.* += extra;
            },
            .duplicate_prefix => {
                const room = @min(len.*, buf.len - len.*);
                const take = rangeAtMost(smith, 0, room);
                fastmem.copy(u8, buf[len.*..][0..take], buf[0..take]);
                len.* += take;
            },
        }
    }
}

/// u16 little-endian at `at`; the caller has bounds-checked `at + 2`.
fn writeU16Le(buf: []u8, at: usize, value: u16) void {
    buf[at] = @truncate(value);
    buf[at + 1] = @truncate(value >> 8);
}

/// u16 little-endian at `pos`; the caller has bounds-checked `pos + 2`.
fn readU16Le(source: []const u8, pos: usize) u16 {
    return @as(u16, source[pos]) | (@as(u16, source[pos + 1]) << 8);
}

/// An LSB-first bit reader over the mutated stream. decode.zig's `BitReader`
/// is private to that file, so the reference walk carries its own (the snappy
/// `referenceDecode` pattern): it exposes the `peek`/`take`/`ErrorSet` surface
/// decode.zig's tree machinery is generic over, so the tables and the length
/// arithmetic are shared while the bit source and the block loop are not.
/// `peek` reads zeros past the end of the input; `take` is the gate that turns
/// that into `error.Truncated` (`§3.1.1`).
const RefBits = struct {
    pub const ErrorSet = decode.DecompressError;

    source: []const u8,
    bit_pos: u64 = 0,

    // `pub` because the tree machinery that calls these (decode.zig's
    // `HuffmanDecoder.decode`) is instantiated in decode.zig's file scope.
    pub fn peek(self: *const RefBits, n: u6) ErrorSet!u64 {
        var value: u64 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const pos = self.bit_pos + i;
            if (pos / 8 >= self.source.len) break;
            value |= @as(u64, (self.source[@intCast(pos / 8)] >> @intCast(pos % 8)) & 1) <<
                @intCast(i);
        }
        return value;
    }

    pub fn take(self: *RefBits, n: u6) ErrorSet!u64 {
        if (self.bit_pos + n > @as(u64, self.source.len) * 8) return error.Truncated;
        const value = try self.peek(n);
        self.bit_pos += n;
        return value;
    }
};

/// Where the reference walk stopped: `err == null` is a clean decode to the
/// final block, `produced` the bytes written; otherwise the specific
/// `DecompressError` and the bytes produced before it — the same
/// "prefix then fail closed" shape `decompress` documents.
const Walk = struct { err: ?decode.DecompressError, produced: usize };

/// Walk `source` block by block, independently of `Reader`: decode each block
/// into `target` (a cap, `error.BufferTooSmall` past it) until BFINAL. The
/// rules are README.md's decoder contract, and the tree machinery
/// (`readDynamicHeader`, the tables, `decodeLength`/`decodeDistance`,
/// `copyMatch`) is decode.zig's — shared with the one-shot decoder, which
/// `checkWalkAgrees` cross-checks on every stream both can decode.
fn referenceWalk(source: []const u8, target: []u8) Walk {
    var br: RefBits = .{ .source = source };
    var out_pos: usize = 0;
    while (true) {
        const final = (br.take(1) catch |err| return .{ .err = err, .produced = out_pos }) != 0;
        const btype: u2 = @intCast(br.take(2) catch |err| return .{
            .err = err,
            .produced = out_pos,
        });
        switch (@as(decode.BlockType, @enumFromInt(btype))) {
            .stored => walkStored(&br, target, &out_pos) catch |err| return .{
                .err = err,
                .produced = out_pos,
            },
            .fixed => walkHuffman(
                &br,
                target,
                &out_pos,
                &decode.fixed_literal,
                &decode.fixed_distance,
            ) catch |err| return .{ .err = err, .produced = out_pos },
            .dynamic => {
                var literal: decode.LitDecoder = .{};
                var distance: decode.DistDecoder = .{};
                decode.readDynamicHeader(&br, &literal, &distance) catch |err| return .{
                    .err = err,
                    .produced = out_pos,
                };
                walkHuffman(&br, target, &out_pos, &literal, &distance) catch |err| return .{
                    .err = err,
                    .produced = out_pos,
                };
            },
            .reserved => return .{ .err = error.InvalidBlockType, .produced = out_pos },
        }
        if (final) return .{ .err = null, .produced = out_pos };
    }
}

/// `§3.2.4` — a stored block: byte-aligned, LEN and NLEN (u16 LE, NLEN the
/// one's complement of LEN), then LEN raw bytes. A payload cut short copies
/// what is there and then fails closed, as the one-shot decoder does.
fn walkStored(br: *RefBits, target: []u8, out_pos: *usize) decode.DecompressError!void {
    const header_pos: usize = @intCast((br.bit_pos + 7) / 8);
    if (br.source.len - header_pos < 4) return error.Truncated;
    const len = readU16Le(br.source, header_pos);
    const nlen = readU16Le(br.source, header_pos + 2);
    if (len != ~nlen) return error.WrongStoredBlockNlen;

    const data_pos = header_pos + 4;
    const present = @min(len, br.source.len - data_pos);
    if (target.len - out_pos.* < present) return error.BufferTooSmall;
    fastmem.copy(u8, target[out_pos.*..][0..present], br.source[data_pos..][0..present]);
    out_pos.* += present;
    if (present < len) return error.Truncated;

    br.bit_pos = @as(u64, data_pos + len) * 8;
}

/// `§3.2.7` — a Huffman block's payload: symbols until the end-of-block code,
/// each match length followed by its distance and the copy (`§3.2.3`).
fn walkHuffman(
    br: *RefBits,
    target: []u8,
    out_pos: *usize,
    literal: *const decode.LitDecoder,
    distance: *const decode.DistDecoder,
) decode.DecompressError!void {
    while (true) {
        const symbol = try literal.decode(br);
        if (symbol < 256) {
            if (out_pos.* == target.len) return error.BufferTooSmall;
            target[out_pos.*] = @intCast(symbol);
            out_pos.* += 1;
            continue;
        }
        if (symbol == 256) return; // §3.2.7 — end of block
        if (symbol > 285) return error.InvalidCode; // §3.2.6 — never emitted
        const length = try decode.decodeLength(br, symbol);
        const dist_symbol = try distance.decode(br);
        if (dist_symbol > 29) return error.InvalidCode; // §3.2.6 — never emitted
        const match_distance = try decode.decodeDistance(br, dist_symbol);
        if (match_distance > out_pos.*) return error.InvalidMatch; // §3.2.3
        if (target.len - out_pos.* < length) return error.BufferTooSmall;
        decode.copyMatch(target, out_pos.*, match_distance, length);
        out_pos.* += length;
    }
}

/// The largest walk output a second decode may pay for: the walk is
/// cross-checked against the one-shot decoder while its output is this small,
/// and skipped above it (a bomb would otherwise be decoded twice per input).
const walk_check_max: usize = 8 * 1024;

/// The walk and the landed one-shot decoder must agree on the same bytes: same
/// error, same produced length, same bytes. This is the differential that
/// keeps the reference honest — a bug in the walk shows up as a mismatch
/// against `decode.decompress`, not as a false finding against `Reader`.
fn checkWalkAgrees(source: []const u8, reference: []const u8, walked: Walk) !void {
    if (walked.produced > walk_check_max - 258) return;
    var target: [walk_check_max]u8 = undefined;
    const result = decode.decompress(source, &target);
    if (walked.err) |want| {
        const got = result catch |err| {
            try testing.expectEqual(want, err);
            return;
        };
        // The walk failed but the one-shot decoder decoded: with the walk's
        // output inside the check window, the decoder's own cap is not the
        // explanation — a real divergence.
        try testing.expectEqual(walked.produced, got);
    } else {
        const n = try result;
        try testing.expectEqual(walked.produced, n);
        try testing.expectEqualSlices(u8, reference[0..n], target[0..n]);
    }
}

/// How a corruption-lane pump stopped. `output_full` is the harness's own cap
/// (a fixed writer), not a codec failure.
const Stop = enum { end_of_stream, read_failed, output_full };

const Pumped = struct { served: usize, stop: Stop };

/// Pump `r` into the fixed writer `w` until the stream ends, the reader fails,
/// or `w` is full. The reader's coarse `error.ReadFailed` is reported as
/// `read_failed` (the detail is sticky in `r.err`); `error.WriteFailed` is the
/// output cap. More calls than `limit` is a hang, not a timeout.
fn pumpCapped(r: *Io.Reader, w: *Io.Writer, limit: usize) !Pumped {
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > limit) return error.PumpStalled;
        _ = r.stream(w, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return .{ .served = w.end, .stop = .end_of_stream },
            error.ReadFailed => return .{ .served = w.end, .stop = .read_failed },
            error.WriteFailed => return .{ .served = w.end, .stop = .output_full },
        };
    }
}

/// Target 5: corruption of valid streams, against an independent walk.
///
/// Attacks truncation at byte and bit boundaries (mid-dynamic-tree, mid-match,
/// mid-stored-payload), single-bit and whole-byte flips inside headers and
/// payloads, declared LEN/NLEN pairs that are consistent lies or inconsistent,
/// forced BTYPEs (including the reserved 11), and trailing bytes the stream's
/// BFINAL must make the reader ignore. The property: the `Reader` either fails
/// closed — `error.ReadFailed`, stickily, with the walk's own error in `err` —
/// or serves exactly what the walk says, always as a prefix of the walk's
/// output, and never writes outside its window.
fn fuzzCorruption(_: void, smith: *Smith) anyerror!void {
    // A stream to corrupt: our encoder's output for a Smith shape (the shapes
    // target 2 drives), a raw Smith byte string, or a committed golden stream.
    var valid_buf: [corrupt_mut_max]u8 = undefined;
    var valid_len: usize = 0;
    switch (rangeAtMost(smith, 0, 2)) {
        0 => {
            const level = implementedLevel(smith);
            var plain_buf: [corrupt_source_max]u8 = undefined;
            const plain = plain_buf[0..buildShape(smith, &plain_buf)];
            valid_len = try encode.compress(plain, &valid_buf, .{ .level = level });
        },
        1 => valid_len = smith.slice(&valid_buf),
        else => {
            const seed = seed_streams[smith.index(seed_streams.len)];
            valid_len = seed.len;
            fastmem.copy(u8, valid_buf[0..valid_len], seed);
        },
    }

    var mut_buf: [corrupt_mut_max]u8 = undefined;
    var mut_len = valid_len;
    fastmem.copy(u8, mut_buf[0..mut_len], valid_buf[0..mut_len]);
    mutateStream(smith, &mut_buf, &mut_len);
    const mutated = mut_buf[0..mut_len];

    // The oracle: what an independent walk of these bytes produces.
    var reference: [corrupt_out_max]u8 = undefined;
    const walked = referenceWalk(mutated, &reference);
    try checkWalkAgrees(mutated, &reference, walked);

    // The reader over the same bytes, capped at the walk's own target size.
    var got: [corrupt_out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(mutated);
    var r: Reader = .init(&fixed_in, &rbuf);
    const pumped = try pumpCapped(&r.reader, &fw, pumpLimit(corrupt_out_max));
    const served = pumped.served;

    // Whatever the reader served is a prefix of the walk's output.
    try testing.expect(served <= walked.produced);
    try testing.expectEqualSlices(u8, reference[0..served], got[0..served]);

    var sink: Io.Writer.Discarding = .init(&.{});
    switch (pumped.stop) {
        .end_of_stream => {
            // A clean end: the walk decoded the whole stream, and the reader
            // served all of it. The end is sticky.
            try testing.expectEqual(@as(?decode.DecompressError, null), walked.err);
            try testing.expectEqual(walked.produced, served);
            try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
            try testing.expectEqual(@as(?Reader.Error, null), r.err);
        },
        .read_failed => {
            // A failure: the walk failed too, and the reader stays failed.
            // (The reader drops the bytes decoded in the failing fill, so it
            // may serve less than the walk produced.) The walk writes into a
            // cap and the reader has none, so a walk stopped by its cap is
            // compared on the served prefix alone.
            switch (walked.err.?) {
                error.BufferTooSmall => try testing.expectEqual(corrupt_out_max, served),
                else => |detail| try testing.expectEqual(@as(?Reader.Error, detail), r.err),
            }
            try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
        },
        .output_full => {
            // The reader still had bytes to serve when the output cap filled:
            // the walk must have hit the same cap, so the prefix compared
            // above is the whole story.
            try testing.expectEqual(corrupt_out_max, served);
            try testing.expectEqual(corrupt_out_max, walked.produced);
            try testing.expectEqual(@as(?decode.DecompressError, error.BufferTooSmall), walked.err);
        },
    }
}

/// Seed corpus for target 5: raw committed streams (the micro streams, the
/// truncated vectors, the `TestStreams` rows) with no mutations, so the
/// non-fuzz smoke run walks every one of them against the reader.
const corruption_corpus: []const []const u8 = &.{
    &streamSeed(""),
    &streamSeed("\x03\x00"),
    &streamSeed("\x01\x0c\x00\xf3\xffHello world\x0a"),
    &streamSeed("\xf3\x48\xcd\xc9\xc9\x57\x28\xcf\x2f\xca\x49\xe1\x02\x00"),
    &streamSeed("\x3d\xc6\x39\x11\x00\x00\x0c\x02\x30\x2b\xb5\x52\x1e\xff\x96\x38" ++
        "\x16\x96\x5c\x1e\x94\xcb\x6d\x01"),
    // Truncated mid-match: the 26-byte two-block stream Go's
    // `TestTruncatedStreams` walks prefix by prefix.
    &streamSeed(golden.truncated_streams_data),
    &streamSeed("\x07"), // BTYPE = 11, the reserved type
};

test "flate fuzz: corruption" {
    try testing.fuzz({}, fuzzCorruption, .{ .corpus = corruption_corpus });
}

// ---------------------------------------------------------------------------
// Target 7: the amplification caps
// ---------------------------------------------------------------------------

/// The amplification source cap: a run this long compresses to a few hundred
/// bytes, so its decode is a ~100x expansion — a bomb in miniature.
const bomb_source_max: usize = 64 * 1024;

/// A bomb: a source whose compressed form is a small fraction of its output —
/// a single-byte run or a repeated short phrase, the shapes whose decode is
/// almost entirely 258-byte matches (`§3.2.5`).
fn buildBomb(smith: *Smith, shape: Shape, buf: []u8) usize {
    const len = rangeAtMost(smith, 0, buf.len);
    if (len == 0) return 0;
    if (shape == .run) {
        fastmem.set(u8, buf[0..len], smith.value(u8));
        return len;
    }
    const phrase_len = rangeAtMost(smith, 1, @min(len, 32));
    smith.bytes(buf[0..phrase_len]);
    var i = phrase_len;
    while (i < len) : (i += phrase_len) {
        const n = @min(phrase_len, len - i);
        fastmem.copy(u8, buf[i..][0..n], buf[0..n]);
    }
    return len;
}

/// Target 7: the amplification caps.
///
/// Attacks the two amplification rules the README states ("Amplification"):
/// `decompress` writes only into `target`, and a small stream cannot buy
/// output past what the caller offered. A bomb-shaped stream is decoded into a
/// cap below its decoded length — any cap, including the exact boundary
/// `len - 1` — which must fail closed with `BufferTooSmall` and leave every
/// byte past the cap untouched, then at the exact length (identity) and with
/// slack (the guard region untouched). A stored-only level decodes the same
/// source through the passthrough path, so the cap rule is not a property of
/// the match finder.
fn fuzzAmplification(_: void, smith: *Smith) anyerror!void {
    const level = implementedLevel(smith);
    const shape = smith.value(Shape);
    var source_buf: [bomb_source_max]u8 = undefined;
    const source = source_buf[0..buildBomb(smith, shape, &source_buf)];

    var compressed: [encode.maxCompressedLength(bomb_source_max)]u8 = undefined;
    const c_len = try encode.compress(source, &compressed, .{ .level = level });
    const bomb = compressed[0..c_len];
    try testing.expect(c_len <= encode.maxCompressedLength(source.len));
    if (level != .@"0" and shape == .run and source.len >= 1024) {
        // The bomb property, where the shape pins it: a run of at least a
        // KiB is almost all 258-byte matches (`§3.2.5`), so its stream is a
        // small fraction of its output and a cap that ignored the decoded
        // length would be a real overrun. A repeated *random* phrase is not
        // in this class — its first copy costs eight bits a byte.
        try testing.expect(c_len * 8 <= source.len);
    }

    var window: [bomb_source_max + guard_len]u8 = undefined;

    // Below the decoded length: fail closed, nothing past the cap written.
    if (source.len > 0) {
        const caps = [_]usize{ source.len - 1, rangeAtMost(smith, 0, source.len - 1) };
        for (caps) |cap| {
            sentinel.fill(&window);
            try testing.expectError(error.BufferTooSmall, decode.decompress(bomb, window[0..cap]));
            try sentinel.expect(&window, cap);
        }
    }

    // At the decoded length: exact, and the guard region is the caller's.
    sentinel.fill(&window);
    const n = try decode.decompress(bomb, window[0..source.len]);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, window[0..n]);
    try sentinel.expect(&window, n);

    // Above it: the same, with the whole window as the cap.
    sentinel.fill(&window);
    const m = try decode.decompress(bomb, &window);
    try testing.expectEqual(source.len, m);
    try testing.expectEqualSlices(u8, source, window[0..m]);
    try sentinel.expect(&window, m);
}

/// Seeds for target 7: a run and a phrase, at the fast and stored-only levels,
/// so the cap boundary runs over a match-heavy and a passthrough stream.
const amplification_corpus: []const []const u8 = &.{
    &shapeSeed(0, .run, 8192, &u64Le(0x41)),
    &shapeSeed(0, .phrase, 4096, &u64Le(16) ++ "0123456789abcdef"),
    &shapeSeed(2, .run, 4096, &u64Le(0x5a)),
};

test "flate fuzz: amplification caps" {
    try testing.fuzz({}, fuzzAmplification, .{ .corpus = amplification_corpus });
}

// ---------------------------------------------------------------------------
// Target 6: the reader's consumer machinery
// ---------------------------------------------------------------------------

/// The reader-machinery source cap: 96 KiB is one and a half windows, so every
/// iteration slides the window and crosses blocks.
const reader_source_max: usize = 96 * 1024;

/// The consumer ops target 6 mixes: the `Io.Reader` surface the README's
/// "Streaming" section contracts on.
const ReadOp = enum(u8) {
    peek,
    take,
    discard_all,
    read_slice_all,
    stream_fixed,
    /// The interface's zero-length request (a poll): `Io.Reader.fixed` reports
    /// `EndOfStream` for one even with bytes buffered — its vtable is reached
    /// with an empty slice — and a done flate reader does the same. Mid-stream
    /// it is a zero-byte serve. Both are legal; nothing may be lost either way.
    poll,
    /// A request past the contiguous-read cap (`history_len`): served when the
    /// window has room, `StreamTooLong` when it does not — never an assert.
    over_cap_take,
};

/// Target 6: the reader's consumer machinery, Smith-driven.
///
/// Attacks the vtable surface (`peek`/`take`/`discardAll`/`readSliceAll`/
/// `stream`), the window slide and its retained 32-KiB tail, the
/// contiguous-read cap, and the clean sticky end, over streams written in
/// Smith-chosen chunks with mid-stream flushes. The unit test is the PRNG
/// version; here the fuzzer drives the op sequence, the sizes, and the input
/// chunking (a small `Io.Reader.Limited` buffer makes the bit reader refill
/// mid-symbol, and its lookahead must not read past the stream).
fn fuzzReaderMachinery(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    const level = implementedLevel(smith);
    var input_buf: [reader_source_max]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    // A known stream: chunked writes with mid-stream flushes.
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{ .level = level });
    var p: usize = 0;
    while (p < input.len) {
        const n = @min(input.len - p, rangeAtMost(smith, 1, 32 * 1024));
        try w.writer.writeAll(input[p..][0..n]);
        p += n;
        if (smith.boolWeighted(1, 3)) try w.writer.flush();
    }
    try w.finish();

    // The input side: sometimes a chunked reader whose buffer is as small as
    // the README allows (3 bytes: a stored block's LEN/NLEN plus the partial
    // byte already consumed).
    var chunk_buf: [64]u8 = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var limited: Io.Reader.Limited = undefined;
    const input_reader: *Io.Reader = if (smith.boolWeighted(1, 3)) blk: {
        limited = .init(&fixed_in, .unlimited, chunk_buf[0..rangeAtMost(smith, 3, chunk_buf.len)]);
        break :blk &limited.interface;
    } else &fixed_in;

    var rbuf: Reader.Buffer = undefined;
    var r: Reader = .init(input_reader, &rbuf);

    var pos: usize = 0;
    var ops: usize = 0;
    var stalls: usize = 0;
    var dead = false;
    while (pos < input.len and ops < 64) : (ops += 1) {
        const left = input.len - pos;
        switch (smith.value(ReadOp)) {
            .peek => {
                // README, "Streaming": any contiguous request of at most
                // `history_len` is served, so a failure here is the contiguity
                // stop, not a decode error.
                const n = @min(left, rangeAtMost(smith, 1, encode.history_len));
                if (r.reader.peek(n)) |served| {
                    try testing.expectEqualSlices(u8, input[pos..][0..n], served);
                } else |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                }
            },
            .take => {
                const n = @min(left, rangeAtMost(smith, 1, encode.history_len));
                if (r.reader.take(n)) |served| {
                    try testing.expectEqualSlices(u8, input[pos..][0..n], served);
                    pos += n;
                } else |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                }
            },
            .discard_all => {
                const n = @min(left, rangeAtMost(smith, 1, reader_source_max));
                r.reader.discardAll(n) catch |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                };
                pos += n;
            },
            .read_slice_all => {
                var tmp: [8 * 1024]u8 = undefined;
                const n = @min(left, rangeAtMost(smith, 1, tmp.len));
                r.reader.readSliceAll(tmp[0..n]) catch |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                };
                try testing.expectEqualSlices(u8, input[pos..][0..n], tmp[0..n]);
                pos += n;
            },
            .stream_fixed => {
                // `stream` may serve from the window or fill it; the bytes land
                // in the fixed writer, so the served count is what it holds.
                // The limit is at least one byte, so `EndOfStream` here means
                // the window is drained *and* the stream is done: every byte
                // the stream decodes must have been served by then.
                var tmp: [4 * 1024]u8 = undefined;
                var fw: Io.Writer = .fixed(&tmp);
                const n = @min(left, rangeAtMost(smith, 1, tmp.len));
                if (r.reader.stream(&fw, .limited(n))) |served| {
                    try testing.expectEqualSlices(
                        u8,
                        input[pos..][0..served],
                        fw.buffered()[0..served],
                    );
                    pos += served;
                    if (served == 0) {
                        stalls += 1;
                        if (stalls > 8) return error.PumpStalled;
                    }
                } else |err| switch (err) {
                    error.EndOfStream => {
                        try testing.expectEqual(input.len, pos);
                        break;
                    },
                    else => |e| {
                        try expectContiguityStop(&r, e);
                        dead = true;
                        break;
                    },
                }
            },
            .poll => {
                // A zero-length request: the interface's own poll. Mid-stream
                // it is a zero-byte serve; on a done reader `Io.Reader.fixed`
                // reports `EndOfStream` for one even with bytes buffered (its
                // vtable is reached with an empty slice), and so does this
                // reader. The flate vtable ignores the limit and fills the
                // window, so a poll on a nearly full window is the contiguity
                // stop — the `expectContiguityStop` path documents that a
                // zero-byte request can fail the reader.
                if (smith.boolWeighted(3, 1)) continue;
                var sink: Io.Writer.Discarding = .init(&.{});
                if (r.reader.stream(&sink.writer, .limited(0))) |served| {
                    try testing.expectEqual(@as(usize, 0), served);
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    else => |e| {
                        try expectContiguityStop(&r, e);
                        dead = true;
                        break;
                    },
                }
            },
            .over_cap_take => {
                const n = encode.history_len + 1 + rangeAtMost(smith, 0, encode.history_len - 1);
                if (left <= n) continue;
                if (r.reader.take(n)) |served| {
                    try testing.expectEqualSlices(u8, input[pos..][0..n], served);
                    pos += n;
                } else |err| {
                    // Past what the window can hold at the consumer's position:
                    // fail closed, stickily, with the contiguity detail.
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                }
            },
        }
    }
    if (dead) return; // the sticky failure was asserted where it happened

    // Finish whatever the op budget left: `discardAll` takes any size (it is
    // not a contiguous request), so the clean end always runs.
    if (pos < input.len) {
        r.reader.discardAll(input.len - pos) catch |err| {
            try expectContiguityStop(&r, err);
            return;
        };
    }

    // The clean end is sticky.
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectEqual(@as(?Reader.Error, null), r.err);
}

/// The only legal failure of a *valid* stream: the window cannot hold what the
/// consumer asked for (README, "Streaming": the contiguous-read cap). Anything
/// else is a finding. The failure is sticky and reports the detail beside the
/// interface's coarse error.
fn expectContiguityStop(r: *Reader, err: anyerror) !void {
    try testing.expectEqual(error.ReadFailed, err);
    try testing.expectEqual(Reader.Error.StreamTooLong, r.err.?);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
}

/// Seeds for target 6: the level, then the `u32-le` length plus bytes
/// `smith.slice` consumes — one repetitive and one incompressible body, so the
/// op mix runs over both a match-heavy and a stored-block stream.
const reader_corpus: []const []const u8 = &.{
    &sliceSeed(0, "abcabcabcabcabcabcabcabcabcabcabcabcabcd"),
    &sliceSeed(0, ""),
};

test "flate fuzz: reader machinery" {
    try testing.fuzz({}, fuzzReaderMachinery, .{ .corpus = reader_corpus });
}
