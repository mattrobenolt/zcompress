//! Fuzz targets for the zlib container (RFC 1950) over the flate module, one
//! per layer of the container surface:
//!
//!   - `fuzzOneShotRoundTrip`: structured shapes through `encode.compress` ->
//!     `decode.decompress`: identity, the `maxCompressedLength` bound, the
//!     deterministic header (CMF=0x78, the FLEVEL band, the minimal FCHECK,
//!     FDICT clear), the trailer against a reference Adler-32 over the same
//!     bytes, and the trailer-location divergence: bytes after ADLER32 are not
//!     part of the stream and are ignored by the one-shot (§2.2).
//!   - `fuzzHeaderTrailerCorruption`: valid streams with Smith mutations —
//!     truncation at every position, header/body/trailer flips, arbitrary
//!     CMF/FLG pokes classified by the FCHECK arithmetic, the T5 corner, the
//!     FDICT rejection, appended markers, a duplicated stream — with the
//!     contract's specific errors pinned and the universal property: a
//!     successful decode re-encodes, and a clean `Reader` end proves its
//!     trailer matches the reference checksum of its own output at the exact
//!     stream boundary.
//!   - `fuzzStreamRoundTrip`: `Writer` -> `Reader` identity over streams,
//!     through both `streamAll` pairs and the manual init/write/finish and
//!     consume paths, plus the exact-boundary property: markers and a second
//!     stream after ADLER32 are never consumed, and a fresh reader at the
//!     boundary decodes what follows.
//!   - `fuzzWriterMachinery`: Smith-chosen `Io.Writer` operation sequences
//!     against an expected-bytes model — the lazy header, `drain`/`flush`/
//!     `rebase` accounting, and the trailer at `finish` — then decoded and
//!     compared.
//!   - `fuzzReaderMachinery`: Smith-chosen consumer op sequences
//!     (peek/take/discardAll/readSliceAll/stream) over known streams — the
//!     boundary preserved under every op, the contiguity cap probed.
//!   - `fuzzChecksumAccounting`: chunked streaming writes with mid-stream
//!     flushes; the trailer must equal a reference Adler-32 over the same
//!     bytes in order (every byte exactly once), and a corrupted trailer must
//!     fail closed.
//!   - `fuzzChecksumHook`: the flate checksum hook (`src/flate/Checksum.zig`,
//!     in the tree) is the container's zero-copy dependency, so this lane
//!     drives `flate.Writer`/`flate.Reader` with a synthetic fold and pins the
//!     contract the container rides: every payload byte folded exactly once,
//!     in stream order, through both layers.
//!   - `fuzzAmplification`: bomb-shaped streams decoded into caps below their
//!     decoded length: fail closed (`BufferTooSmall`), never write past the
//!     cap, never allocate.
//!
//! Run with `just fuzz <budget>` (ReleaseSafe only: a Debug-mode fuzz run
//! hits ziglang/zig#30655). Every target caps its per-iteration input
//! (`roundtrip_max`, `stream_max`, `corrupt_source_max`, `checksum_max`,
//! `bomb_source_max`) so a budget run finishes. The container allocates
//! nothing; the only allocation is the harness's `Io.Writer.Allocating`,
//! which the runner's per-input leak check covers.
//!
//! Spec: docs/research/specs/rfc1950-zlib.txt (§2.1 byte order, §2.2 the
//! header and trailer, §2.3 decoder obligations, §8.2 the Adler-32
//! algorithm). Contracts: src/zlib/README.md.

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
const flate = @import("../flate/root.zig");
const zlib = @import("root.zig");

// ---------------------------------------------------------------------------
// Shared harness
// ---------------------------------------------------------------------------

/// Bytes past the decoded length checked on every decode: an out-of-bounds
/// write (a 16-byte SIMD store, a 64-byte copy chunk) lands in this region.
const guard_len: usize = 256;

/// RFC 1950 §2.2 — the header and the trailer.
const header_len: usize = 2;
const trailer_len: usize = 4;

/// The round-trip source cap: the widest block-boundary case (131070) rounded
/// up to 128 KiB, so the encoder's block split and the cross-block match
/// reach both run.
const roundtrip_max: usize = 131_072;

/// The stream source cap: one full block plus a tail, so the writer emits
/// multiple blocks and the reader slides its window.
const stream_max: usize = 64 * 1024;

/// The mid-stream flush budget: how many Smith-chosen flushes a target's
/// writer loop may take. Every flush ends the current block and every block
/// costs at most 5 stored-header bytes beyond its input (the encoder's
/// stored-block fallback, `src/flate/README.md`, "Encoder"), so each flushed
/// block grows the stream past the no-flush `maxCompressedLength` bound by at
/// most 5 bytes — the fixed buffers below carry `5 * flush_budget` of
/// headroom for exactly this (the bound itself budgets only the unflushed
/// block count).
const flush_budget: usize = 16;

/// The checksum lane's source cap.
const checksum_max: usize = 64 * 1024;

/// The corruption source cap: the valid stream is built from at most this
/// much plaintext, and the mutations stay inside the mutation buffer.
const corrupt_source_max: usize = 2048;

/// The corruption output cap: a hostile stream can expand far past its input
/// (a dynamic tree can code 258-byte matches in two bits), so the cap bounds
/// the decode's work and the sentinel window.
const corrupt_out_max: usize = 64 * 1024;

/// The mutation buffer: two valid streams (the duplicate-stream operator) plus
/// room for appended markers.
const corrupt_mut_max: usize = 2 * zlib.encode.maxCompressedLength(corrupt_source_max) + 1024;

/// The amplification source cap: a run this long compresses to a few hundred
/// bytes, so its decode is a ~100x expansion — a bomb in miniature.
const bomb_source_max: usize = 64 * 1024;

/// The checksum-hook lane's source cap.
const hook_max: usize = 64 * 1024;

/// Marker bytes appended after a stream to prove the reader stops at
/// ADLER32's last byte (README, "Streaming"): bytes after the trailer are not
/// part of the stream (§2.2), so they are not the reader's to consume.
const marker_len: usize = 8;
const marker_byte: u8 = 0xa5;

/// A Smith-chosen value in `[at_least, at_most]`. `Smith.valueRangeAtMost`
/// rejects `usize` (no fixed bitsize), so bounded lengths go through a `u32`
/// and widen here; every call site is inside a per-iteration cap.
fn rangeAtMost(smith: *Smith, at_least: usize, at_most: usize) usize {
    assert(at_least <= at_most);
    assert(at_most <= math.maxInt(u32));
    return smith.valueRangeAtMost(u32, @intCast(at_least), @intCast(at_most));
}

/// A Smith-picked implemented level: `.fast`, the stored-only `.@"0"`, or one
/// of the numeric aliases that tune to `.fast` today (`encode.Level`'s
/// contract). `.ratio` is never returned — it is `error.Unimplemented`,
/// exercised explicitly by the round-trip target.
fn implementedLevel(smith: *Smith) zlib.encode.Level {
    const pick = rangeAtMost(smith, 0, 10);
    if (pick == 0) return .fast;
    return @enumFromInt(@as(u8, @intCast(pick + 1)));
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
/// own pump driver), bounded: a reader that neither serves bytes nor fails is
/// a hang, not a timeout.
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

/// A Smith-serialized `u64`: the little-endian form every `smith.value` call
/// consumes, so hand-built seeds can pin the values the target reads.
fn u64Le(comptime value: u64) [8]u8 {
    var out: [8]u8 = undefined;
    mem.writeInt(u64, &out, value, .little);
    return out;
}

/// A round-trip seed in Smith's serialized form: the level, the shape, and the
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

/// A stream-lane seed in Smith's serialized form: the little-endian level
/// `smith.value(encode.Level)` consumes, then the `u32-le` length plus bytes
/// `smith.slice` consumes.
fn sliceSeed(comptime level: u64, comptime bytes: []const u8) [12 + bytes.len]u8 {
    var seed: [12 + bytes.len]u8 = undefined;
    mem.writeInt(u64, seed[0..8], level, .little);
    mem.writeInt(u32, seed[8..12], @intCast(bytes.len), .little);
    for (bytes, 0..) |b, i| seed[12 + i] = b;
    return seed;
}

/// The input shapes the round trip feeds the encoder. Random bytes alone
/// mostly exercise the stored fallback; the structured shapes drive the match
/// finder's copy emission.
const Shape = enum(u8) { random, run, phrase, mixed, boundary };

/// The block-boundary sizes the `.boundary` shape pins: one below, at, and
/// above `max_block_size` (65535), and a two-block length.
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

/// RFC 1950 §2.2 — the deterministic emitted header (README, "Emitted,
/// deterministically"): CMF = 0x78 (CM=8 deflate, CINFO=7: a 32-KiB window),
/// FLG carrying only the FLEVEL band and the minimal FCHECK, FDICT clear.
/// The exact FLG bytes are derived here from the §2.2 arithmetic, not from the
/// implementation's formula: FLEVEL 0 -> 0x01, 1 -> 0x5e, 2 -> 0x9c, 3 -> 0xda.
fn expectZlibHeader(stream: []const u8, level: zlib.encode.Level) !void {
    try testing.expect(stream.len >= header_len + trailer_len);
    try testing.expectEqual(@as(u8, 0x78), stream[0]);
    try testing.expectEqual(flgFor(level), stream[1]);
    // §2.2 — "CMF and FLG, when viewed as a 16-bit unsigned integer stored in
    // MSB order (CMF*256 + FLG), is a multiple of 31".
    const h = @as(u16, stream[0]) * 256 + @as(u16, stream[1]);
    try testing.expectEqual(@as(u16, 0), h % 31);
    // ZE2 — the encoder never sets FDICT.
    try testing.expectEqual(@as(u8, 0), stream[1] & 0x20);
}

/// RFC 1950 §2.2 — FLEVEL by level band (README, "Emitted,
/// deterministically"; the C zlib mapping, oracle-verified): {0,1} -> 0,
/// {2-5} -> 1, {fast, 6} -> 2, {7-9} -> 3. The FLG byte is the band's FLEVEL
/// plus the minimal FCHECK for CMF=0x78.
fn flgFor(level: zlib.encode.Level) u8 {
    const flevel: u8 = switch (level) {
        .@"0", .@"1" => 0,
        .@"2", .@"3", .@"4", .@"5" => 1,
        .fast, .@"6" => 2,
        .@"7", .@"8", .@"9" => 3,
        .ratio => unreachable, // never emits a stream (README, "API")
    };
    // The minimal FCHECK: (31 - r) % 31, r = (CMF*256 + FLEVEL<<6) % 31.
    const r = (@as(u16, 0x78) * 256 + @as(u16, flevel) * 64) % 31;
    const fcheck: u8 = @intCast((31 - r) % 31);
    return flevel << 6 | fcheck;
}

/// RFC 1950 §2.2 — the trailer: the Adler-32 of the uncompressed data
/// (excluding dictionary data), stored most-significant-byte first (§2.1). The
/// reference is std's Adler-32 kernel over the same bytes, so this pins the
/// container's byte accounting (every byte exactly once, in order).
fn expectZlibTrailer(stream: []const u8, source: []const u8) !void {
    try testing.expect(stream.len >= trailer_len);
    const trailer = stream[stream.len - trailer_len ..];
    try testing.expectEqual(
        std.hash.Adler32.hash(source),
        mem.readInt(u32, trailer[0..4], .big),
    );
}

/// The clean end is sticky: repeated `stream` calls end in `EndOfStream`. A
/// zero-serve fill call may come first — the interface allows a zero return
/// that does not indicate stream end — so this drives the calls instead of
/// pinning the first one.
fn expectStickyEnd(r: *zlib.Reader) !void {
    var sink: Io.Writer.Discarding = .init(&.{});
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > 4) return error.EndNotSticky;
        const n = r.reader.stream(&sink.writer, .unlimited) catch |err| {
            try testing.expectEqual(error.EndOfStream, err);
            return;
        };
        try testing.expectEqual(@as(usize, 0), n);
    }
}

/// A failure is sticky: repeated `stream` calls end in `ReadFailed` (a
/// zero-serve call may come first), with the detail still recorded in `err`.
fn expectStickyFailure(r: *zlib.Reader) !void {
    try testing.expect(r.err != null);
    var sink: Io.Writer.Discarding = .init(&.{});
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > 4) return error.FailureNotSticky;
        _ = r.reader.stream(&sink.writer, .unlimited) catch |err| {
            try testing.expectEqual(error.ReadFailed, err);
            return;
        };
    }
}

/// A failed decode where no specific error is pinned.
fn expectFailure(result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |_| {}
}

/// Whatever a hostile stream decoded to must survive a full encode/decode
/// cycle (the oracle-within-process property): our encoder is checked by our
/// decoder on bytes the fuzzer chose, not on bytes we chose.
fn reencodeRoundTrip(bytes: []const u8) !void {
    assert(bytes.len <= corrupt_out_max);
    var stream: [zlib.encode.maxCompressedLength(corrupt_out_max)]u8 = undefined;
    const s_len = try zlib.encode.compress(bytes, &stream, .{ .level = .fast });
    try testing.expect(s_len <= zlib.encode.maxCompressedLength(bytes.len));

    var plain: [corrupt_out_max + guard_len]u8 = undefined;
    sentinel.fill(&plain);
    const n = try zlib.decode.decompress(stream[0..s_len], plain[0..bytes.len]);
    try testing.expectEqual(bytes.len, n);
    try testing.expectEqualSlices(u8, bytes, plain[0..n]);
    try sentinel.expect(&plain, n);
}

// ---------------------------------------------------------------------------
// Target 1: the one-shot round trip
// ---------------------------------------------------------------------------

/// Seeds for target 1: the Smith values the shape builder reads, so each seed
/// pins a structure instead of relying on the fuzzer to grow one. `0` is
/// `fast`, `1` is `ratio`, `2` is `@"0"` (stored-only).
const roundtrip_corpus: []const []const u8 = &.{
    // A 65534-byte phrase at the block split (the seed runs out of content
    // bytes, so the phrase is eight zero bytes repeated).
    &shapeSeed(0, .boundary, 0, ""),
    // A 4096-byte run of 'A' through the match finder: the shape reads one
    // `smith.value(u8)`, the seed supplies it as a u64.
    &shapeSeed(0, .run, 4096, &u64Le(0x41)),
    // A 2048-byte phrase, eight bytes long, repeated.
    &shapeSeed(0, .phrase, 2048, &(u64Le(8) ++ [8]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' })),
    // 70000 bytes of 'Z' at the stored-only level: two stored blocks plus the
    // final empty fixed block.
    &shapeSeed(2, .run, 70_000, &u64Le(0x5a)),
    // The reserved ratio mode: `error.Unimplemented`, never a silent alias.
    &shapeSeed(1, .random, 0, ""),
};

/// Target 1: the whole one-shot codec, on the shapes a compressor is worst at.
///
/// Attacks the encoder's block split and the container framing (the header
/// arithmetic, the trailer, the `maxCompressedLength` bound), then the
/// decoder's trailer location through the fixed-reader route, its cap, and its
/// sentinel-clean output. The property: `compress` -> `decompress` is the
/// identity, the emitted stream is the deterministic one, and a stream
/// followed by marker bytes decodes identically (bytes after ADLER32 are not
/// part of the stream).
fn fuzzOneShotRoundTrip(_: void, smith: *Smith) anyerror!void {
    const level = smith.value(zlib.encode.Level);
    var source_buf: [roundtrip_max]u8 = undefined;
    const source = source_buf[0..buildShape(smith, &source_buf)];

    if (level == .ratio) {
        // encode.Level's contract: the ratio mode is `error.Unimplemented` on
        // the one-shot and `error.ReadFailed` on the stream, never silent
        // aliasing (README, "API").
        var tiny: [16]u8 = undefined;
        try testing.expectError(
            error.Unimplemented,
            zlib.encode.compress(source, &tiny, .{ .level = .ratio }),
        );
        var sink: Io.Writer.Discarding = .init(&.{});
        var fixed_in: Io.Reader = .fixed(source);
        try testing.expectError(
            error.ReadFailed,
            zlib.Writer.streamAll(&fixed_in, &sink.writer, .{ .level = .ratio }),
        );
        var wbuf: zlib.Writer.Buffer = undefined;
        var w: zlib.Writer = .init(&sink.writer, &wbuf, .{ .level = .ratio });
        try testing.expectError(error.WriteFailed, w.writer.writeAll("x"));
        try testing.expectError(error.WriteFailed, w.finish());
        return;
    }

    // The marker room rides the same buffer: the stream followed by markers is
    // one contiguous slice.
    var stream_buf: [zlib.encode.maxCompressedLength(roundtrip_max) + marker_len]u8 = undefined;
    const s_len = try zlib.encode.compress(source, &stream_buf, .{ .level = level });
    const stream = stream_buf[0..s_len];

    // The documented bound, on every emission (README, "Contracts").
    try testing.expect(s_len <= zlib.encode.maxCompressedLength(source.len));
    try expectZlibHeader(stream, level);
    try expectZlibTrailer(stream, source);

    var plain_buf: [roundtrip_max + guard_len]u8 = undefined;
    // Exact cap first: a decoder that writes past the decoded length lands in
    // the guard region (the sentinel check is what proves it did not).
    sentinel.fill(&plain_buf);
    const n = try zlib.decode.decompress(stream, plain_buf[0..source.len]);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, plain_buf[0..n]);
    try sentinel.expect(&plain_buf, n);

    // Then with slack, so the bytes past the decoded length are checked too.
    sentinel.fill(&plain_buf);
    const m = try zlib.decode.decompress(stream, &plain_buf);
    try testing.expectEqual(n, m);
    try testing.expectEqualSlices(u8, source, plain_buf[0..m]);
    try sentinel.expect(&plain_buf, m);

    // The trailer-location divergence, pinned: the one-shot decodes a stream
    // followed by marker bytes identically — "any data which may appear after
    // ADLER32 are not part of the zlib stream" (§2.2; the streaming reader is
    // the boundary-aware route).
    fastmem.set(u8, stream_buf[s_len..][0..marker_len], marker_byte);
    const framed = stream_buf[0 .. s_len + marker_len];
    sentinel.fill(&plain_buf);
    const f = try zlib.decode.decompress(framed, plain_buf[0..source.len]);
    try testing.expectEqual(source.len, f);
    try testing.expectEqualSlices(u8, source, plain_buf[0..f]);
    try sentinel.expect(&plain_buf, f);
}

test "zlib fuzz: one-shot round trip" {
    try testing.fuzz({}, fuzzOneShotRoundTrip, .{ .corpus = roundtrip_corpus });
}

// ---------------------------------------------------------------------------
// Target 2: header and trailer corruption
// ---------------------------------------------------------------------------

/// The outcome class a mutation pins (README, "The stream format" and
/// "Contracts"; the error names are the `DecompressError` set).
const Expected = enum {
    /// The stream must decode to exactly the original source.
    exact_source,
    /// Any failure: a stream whose end is gone never decodes.
    fail_any,
    /// `error.Truncated`.
    fail_truncated,
    /// `error.BadHeader` (CM, CINFO, or FCHECK).
    fail_bad_header,
    /// `error.DictionaryRequired` (FDICT set, §2.3).
    fail_dictionary,
    /// `error.WrongChecksum` (ADLER32 mismatch).
    fail_checksum,
    /// Fail closed or succeed, with the universal properties checked.
    unknown,
};

/// The corruption operators. Each keeps `buf[0..len]` in bounds.
const Mutation = enum(u8) {
    /// Cut the stream at a Smith-chosen byte: its end is gone.
    truncate,
    /// A flip in the 2-byte header: classified by the §2.2 arithmetic. An
    /// arbitrary-byte XOR can land on another conformant pair (e.g. `78 01`
    /// -> `78 da`, C zlib's own level-9 header), so the class is computed,
    /// never assumed.
    flip_header,
    /// A flip inside the deflate body: the output is the body's business.
    flip_body,
    /// A flip inside ADLER32: the check must fail.
    flip_trailer,
    /// An arbitrary CMF/FLG pair, classified by the §2.2 arithmetic.
    poke_header,
    /// The T5 corner: FCHECK = 31 is conformant and lands on the FDICT
    /// rejection, never `BadHeader`.
    poke_t5_corner,
    /// Marker bytes after ADLER32: ignored by the one-shot, unconsumed by the
    /// reader.
    append_markers,
    /// A second stream after the first: not consumed by one reader.
    duplicate_stream,
};

const Mutated = struct {
    len: usize,
    /// The valid stream's end inside the mutation buffer: the position a clean
    /// `Reader` end must stop at for the `exact_source` class.
    member_end: usize,
    expected: Expected,
};

/// A nonzero byte to XOR with, so a flip always changes the byte.
fn flipValue(smith: *Smith) u8 {
    return @intCast(1 + rangeAtMost(smith, 0, 254));
}

/// The §2.2 header arithmetic, independently of the implementation: CM must be
/// 8, CINFO at most 7, and CMF*256 + FLG a multiple of 31.
fn headerClass(cmf: u8, flg: u8) Expected {
    const h = @as(u16, cmf) * 256 + @as(u16, flg);
    if ((cmf & 0x0f) != 8 or (cmf >> 4) > 7 or h % 31 != 0) return .fail_bad_header;
    if (flg & 0x20 != 0) return .fail_dictionary;
    return .exact_source;
}

/// Apply one Smith-chosen mutation to the valid stream in `buf[0..member_len]`
/// and return the mutated length plus the class the contract pins.
fn mutateStream(smith: *Smith, buf: []u8, member_len: usize) Mutated {
    assert(member_len >= header_len + trailer_len);
    const body_start = header_len;
    const body_end = member_len - trailer_len;
    switch (smith.value(Mutation)) {
        .truncate => {
            // A cut inside the trailer leaves the body intact: Truncated
            // exactly. A cut inside the body runs its bits out first.
            const cut = rangeAtMost(smith, 0, member_len - 1);
            const expected: Expected = if (cut >= body_end) .fail_truncated else .fail_any;
            return .{ .len = cut, .member_end = member_len, .expected = expected };
        },
        .flip_header => {
            // `flipValue` is an arbitrary nonzero byte, not a bit, so the XOR
            // can land on another conformant header: `78 01` -> `78 da` is
            // C zlib's level-9 pair, FLEVEL advisory and the body untouched,
            // so that stream decodes exactly. The classification is the §2.2
            // arithmetic's, exactly as `.poke_header` does it — a single-bit
            // flip always breaks FCHECK or CM/CINFO, an arbitrary byte need
            // not.
            const at = rangeAtMost(smith, 0, header_len - 1);
            buf[at] ^= flipValue(smith);
            return .{
                .len = member_len,
                .member_end = member_len,
                .expected = headerClass(buf[0], buf[1]),
            };
        },
        .flip_body => {
            const at = rangeAtMost(smith, body_start, body_end - 1);
            buf[at] ^= flipValue(smith);
            return .{ .len = member_len, .member_end = member_len, .expected = .unknown };
        },
        .flip_trailer => {
            // The body is untouched, so the trailer must still equal the
            // reference checksum; a flipped byte can only fail the check.
            const at = rangeAtMost(smith, body_end, member_len - 1);
            buf[at] ^= flipValue(smith);
            return .{ .len = member_len, .member_end = member_len, .expected = .fail_checksum };
        },
        .poke_header => {
            // The arithmetic decides the class before the implementation sees
            // the bytes: an invalid header is BadHeader, FDICT is
            // DictionaryRequired, and a conformant header (any CINFO <= 7,
            // any FLEVEL) decodes the untouched body.
            const cmf = smith.value(u8);
            const flg = smith.value(u8);
            buf[0] = cmf;
            buf[1] = flg;
            return .{
                .len = member_len,
                .member_end = member_len,
                .expected = headerClass(cmf, flg),
            };
        },
        .poke_t5_corner => {
            // C zlib's and Go's FDICT+FLEVEL-0 emission: 0x78 0x3f, FCHECK=31
            // (31 == 0 mod 31). A re-deriving validator rejects the whole
            // reference output family here; the stream is FDICT, so the
            // contract's answer is DictionaryRequired, never BadHeader (T5).
            buf[0] = 0x78;
            buf[1] = 0x3f;
            return .{ .len = member_len, .member_end = member_len, .expected = .fail_dictionary };
        },
        .append_markers => {
            const extra = rangeAtMost(smith, 1, 64);
            fastmem.set(u8, buf[member_len..][0..extra], marker_byte);
            return .{
                .len = member_len + extra,
                .member_end = member_len,
                .expected = .exact_source,
            };
        },
        .duplicate_stream => {
            const take = rangeAtMost(smith, header_len, member_len);
            fastmem.copy(u8, buf[member_len..][0..take], buf[0..take]);
            return .{
                .len = member_len + take,
                .member_end = member_len,
                .expected = .exact_source,
            };
        },
    }
}

/// The one-shot decode under the mutated bytes, checked against the mutation's
/// class. Every decode pre-fills the target with cycling sentinels and proves
/// the bytes at and past the cap are untouched.
fn checkOneShot(mutated: []const u8, source: []const u8, meta: Mutated, cap: usize) !void {
    var window: [corrupt_out_max + guard_len]u8 = undefined;
    sentinel.fill(&window);
    const target = window[0..cap];
    const result = zlib.decode.decompress(mutated, target);
    switch (meta.expected) {
        .exact_source => {
            const n = try result;
            try testing.expectEqual(source.len, n);
            try testing.expectEqualSlices(u8, source, target[0..n]);
            try sentinel.expect(&window, n);
        },
        .fail_any => {
            try expectFailure(result);
            try sentinel.expect(&window, cap);
        },
        .fail_truncated => {
            try testing.expectError(error.Truncated, result);
            try sentinel.expect(&window, cap);
        },
        .fail_bad_header => {
            try testing.expectError(error.BadHeader, result);
            try sentinel.expect(&window, cap);
        },
        .fail_dictionary => {
            try testing.expectError(error.DictionaryRequired, result);
            try sentinel.expect(&window, cap);
        },
        .fail_checksum => {
            try testing.expectError(error.WrongChecksum, result);
            try sentinel.expect(&window, cap);
        },
        .unknown => {
            if (result) |n| {
                try testing.expect(n <= cap);
                try reencodeRoundTrip(target[0..n]);
                try sentinel.expect(&window, n);
            } else |_| {
                try sentinel.expect(&window, cap);
            }
        },
    }
}

/// The streaming reader under the mutated bytes, checked against the
/// mutation's class. The universal property: a clean end proves the trailer
/// matches the reference checksum of the reader's own output at the exact
/// stream boundary; a failure is sticky with the detail in `err`.
fn checkReader(mutated: []const u8, source: []const u8, meta: Mutated) !void {
    var got: [corrupt_out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: zlib.Reader.Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(mutated);
    var r: zlib.Reader = .init(&fixed_in, &rbuf);
    const pumped = try pumpCapped(&r.reader, &fw, pumpLimit(corrupt_out_max));
    const served = pumped.served;

    switch (pumped.stop) {
        .end_of_stream => {
            // The reader verified the trailer against its own output, so the
            // reference must agree — and the input stopped exactly at
            // ADLER32's last byte (the stream boundary contract).
            try testing.expect(fixed_in.seek >= trailer_len);
            const trailer = mutated[fixed_in.seek - trailer_len .. fixed_in.seek];
            try testing.expectEqual(
                std.hash.Adler32.hash(got[0..served]),
                mem.readInt(u32, trailer[0..4], .big),
            );
            if (meta.expected == .exact_source) {
                try testing.expectEqualSlices(u8, source, got[0..served]);
                try testing.expectEqual(meta.member_end, fixed_in.seek);
            }
            try testing.expectEqual(@as(?zlib.Reader.Error, null), r.err);
            try expectStickyEnd(&r);
        },
        .read_failed => {
            try testing.expect(meta.expected != .exact_source);
            const detail = r.err.?;
            switch (meta.expected) {
                .fail_truncated => try testing.expectEqual(zlib.Reader.Error.Truncated, detail),
                .fail_bad_header => try testing.expectEqual(zlib.Reader.Error.BadHeader, detail),
                .fail_dictionary => try testing.expectEqual(
                    zlib.Reader.Error.DictionaryRequired,
                    detail,
                ),
                .fail_checksum => try testing.expectEqual(
                    zlib.Reader.Error.WrongChecksum,
                    detail,
                ),
                // An unpinned mutation (`unknown`) or a cut member
                // (`fail_any`): the detail is the mutation's business. A
                // flipped body byte makes the untouched Adler-32 mismatch the
                // changed output; a corrupted deflate stream can end
                // mid-stream. The sticky-failure property below is the pin.
                .unknown, .fail_any => {},
                else => unreachable,
            }
            try expectStickyFailure(&r);
        },
        .output_full => {
            // A mutated body can expand past the harness cap; nothing more is
            // pinned, only that it did not crash or overrun.
            try testing.expectEqual(Expected.unknown, meta.expected);
        },
    }
}

/// Target 2: header and trailer corruption.
///
/// Attacks the header arithmetic (CM, CINFO, FCHECK, FDICT — including the T5
/// corner and the wrong-FCHECK golden), the body's exact end, and the ADLER32
/// check. The property: the mutation's contract class holds — the specific
/// error, or an exact-source decode for a conformant poked header and for
/// trailing bytes — and otherwise the decode fails closed, any success
/// re-encodes, and the streaming reader's clean end is trailer-consistent at
/// the exact stream boundary.
fn fuzzHeaderTrailerCorruption(_: void, smith: *Smith) anyerror!void {
    const level = implementedLevel(smith);
    var source_buf: [corrupt_source_max]u8 = undefined;
    const source = source_buf[0..buildShape(smith, &source_buf)];

    var mut_buf: [corrupt_mut_max]u8 = undefined;
    const s_len = try zlib.encode.compress(source, &mut_buf, .{ .level = level });
    const meta = mutateStream(smith, &mut_buf, s_len);
    const mutated = mut_buf[0..meta.len];

    // The cap: the exact source length for the pinned classes (so
    // `exact_source` can succeed), a Smith-chosen cap otherwise.
    const cap = switch (meta.expected) {
        .exact_source,
        .fail_truncated,
        .fail_bad_header,
        .fail_dictionary,
        .fail_checksum,
        => source.len,
        .fail_any, .unknown => rangeAtMost(smith, 0, corrupt_out_max),
    };
    try checkOneShot(mutated, source, meta, cap);
    try checkReader(mutated, source, meta);
}

test "zlib fuzz: header and trailer corruption" {
    try testing.fuzz({}, fuzzHeaderTrailerCorruption, .{});
}

// ---------------------------------------------------------------------------
// Target 3: the streaming round trip and the stream boundary
// ---------------------------------------------------------------------------

/// Seeds for target 3: a repeated phrase the encoder turns into matches, and
/// an empty payload (the header-before-nothing path).
const stream_corpus: []const []const u8 = &.{
    &sliceSeed(0, "the quick brown fox " ** 8),
    &sliceSeed(0, ""),
};

/// Target 3: `Writer` -> `Reader` identity over streams, both the `streamAll`
/// pair and the manual init/write/finish and consume paths.
///
/// Attacks the lazy header (written before the first compressed byte), the
/// trailer at `finish`, the streaming writer's block accumulation with
/// mid-stream flushes, the reader's window and refill, and the exact-boundary
/// rule: the reader consumes its input through ADLER32's last byte and never
/// reads a byte past it — markers and a second stream stay unconsumed, and a
/// fresh reader at the boundary decodes what follows. (Concatenated zlib
/// streams are not a spec feature; the boundary is what the exact consumption
/// exposes, README, "Streaming".)
fn fuzzStreamRoundTrip(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    const level = implementedLevel(smith);
    var input_buf: [stream_max]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    // The stream followed by markers, and two streams followed by markers: one
    // buffer, both shapes (plus the flushed blocks' 5-byte headers).
    var framed: [
        2 * zlib.encode.maxCompressedLength(stream_max) + 2 * marker_len + 5 * flush_budget
    ]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&.{});

    // Path A — the `streamAll` pair: Writer.streamAll consumes its input
    // exactly, then Reader.streamAll decodes it back.
    var stream_out: Io.Writer.Allocating = .init(gpa);
    defer stream_out.deinit();
    var source_in: Io.Reader = .fixed(input);
    const consumed = try zlib.Writer.streamAll(&source_in, &stream_out.writer, .{ .level = level });
    try testing.expectEqual(input.len, consumed);
    try testing.expectEqual(input.len, source_in.seek);
    const stream = stream_out.written();
    try expectZlibHeader(stream, level);
    try expectZlibTrailer(stream, input);
    try testing.expect(stream.len + marker_len <= framed.len);

    // The exact-boundary property: stream ++ markers serves the stream's bytes
    // and leaves the markers unconsumed.
    fastmem.copy(u8, framed[0..stream.len], stream);
    fastmem.set(u8, framed[stream.len..][0..marker_len], marker_byte);
    var framed_in: Io.Reader = .fixed(&framed);
    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    const served = try zlib.Reader.streamAll(&framed_in, &plain.writer);
    try testing.expectEqual(input.len, served);
    try testing.expectEqualSlices(u8, input, plain.written());
    try testing.expectEqual(stream.len, framed_in.seek);

    // Garbage where a stream would be: fail closed with BadHeader, sticky.
    // The garbage is at least a full fixed header, so the magic check is what
    // rejects it (a shorter prefix is a truncated header instead).
    var garbage: [2 * marker_len]u8 = undefined;
    fastmem.set(u8, &garbage, marker_byte);
    var rbuf: zlib.Reader.Buffer = undefined;
    var garbage_in: Io.Reader = .fixed(&garbage);
    var garbage_reader: zlib.Reader = .init(&garbage_in, &rbuf);
    try testing.expectError(
        error.ReadFailed,
        pump(&garbage_reader.reader, &sink.writer, pumpLimit(marker_len)),
    );
    try testing.expectEqual(zlib.Reader.Error.BadHeader, garbage_reader.err.?);
    try expectStickyFailure(&garbage_reader);

    // A second stream is not consumed either: one stream per reader. A fresh
    // reader at the boundary decodes it — the caller loop the exact
    // consumption exposes.
    fastmem.copy(u8, framed[stream.len..][0..stream.len], stream);
    fastmem.set(u8, framed[2 * stream.len ..][0..marker_len], marker_byte);
    const two = framed[0 .. 2 * stream.len + marker_len];
    var two_in: Io.Reader = .fixed(two);
    var first: Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    const first_served = try zlib.Reader.streamAll(&two_in, &first.writer);
    try testing.expectEqual(input.len, first_served);
    try testing.expectEqualSlices(u8, input, first.written());
    try testing.expectEqual(stream.len, two_in.seek);
    var second: Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    const second_served = try zlib.Reader.streamAll(&two_in, &second.writer);
    try testing.expectEqual(input.len, second_served);
    try testing.expectEqualSlices(u8, input, second.written());
    try testing.expectEqual(2 * stream.len, two_in.seek);

    // Path B — manual init/write/finish with Smith-chosen chunking and
    // mid-stream flushes, then a manual consume over markers.
    var stream2: Io.Writer.Allocating = .init(gpa);
    defer stream2.deinit();
    var wbuf: zlib.Writer.Buffer = undefined;
    var w: zlib.Writer = .init(&stream2.writer, &wbuf, .{ .level = level });
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
    const stream2_bytes = stream2.written();
    try expectZlibHeader(stream2_bytes, level);
    try expectZlibTrailer(stream2_bytes, input);

    fastmem.copy(u8, framed[0..stream2_bytes.len], stream2_bytes);
    fastmem.set(u8, framed[stream2_bytes.len..][0..marker_len], marker_byte);
    var in2: Io.Reader = .fixed(framed[0 .. stream2_bytes.len + marker_len]);
    var r2: zlib.Reader = .init(&in2, &rbuf);
    var out2: Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    try pump(&r2.reader, &out2.writer, pumpLimit(input.len));
    try testing.expectEqualSlices(u8, input, out2.written());
    try testing.expectEqual(stream2_bytes.len, in2.seek);
    try testing.expectEqual(@as(?zlib.Reader.Error, null), r2.err);

    // The clean end is sticky.
    try expectStickyEnd(&r2);
}

test "zlib fuzz: stream round trip" {
    try testing.fuzz({}, fuzzStreamRoundTrip, .{ .corpus = stream_corpus });
}

// ---------------------------------------------------------------------------
// Target 4: the writer's machinery
// ---------------------------------------------------------------------------

/// The `Io.Writer` operations the machinery target mixes: the vtable contract
/// under multi-slice splats, partial takes, direct-slice writes onto a full
/// buffer, and mid-stream flushes.
const Op = enum(u8) {
    write_splat_all,
    write_vec_all,
    splat_bytes_all,
    writable_slice,
    byte_and_flush,
};

/// Target 4: the writer's machinery, Smith-driven, against a model.
///
/// Attacks the lazy header (it must be emitted before the first compressed
/// byte, whatever the first call is), `drain`/`flush`/`rebase` accounting
/// under the full `Io.Writer` contract, and the trailer at `finish` — by
/// decoding the produced stream and comparing it against the bytes the model
/// says were written, with the trailer checked against the reference.
fn fuzzWriterMachinery(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    const level = implementedLevel(smith);
    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();
    var expect: std.ArrayList(u8) = .empty;
    defer expect.deinit(gpa);
    var wbuf: zlib.Writer.Buffer = undefined;
    var w: zlib.Writer = .init(&stream.writer, &wbuf, .{ .level = level });

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

    // The stream frames the model's bytes exactly: header, trailer, identity.
    try expectZlibHeader(stream.written(), level);
    try expectZlibTrailer(stream.written(), expect.items);

    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    var fixed_in: Io.Reader = .fixed(stream.written());
    const served = try zlib.Reader.streamAll(&fixed_in, &plain.writer);
    try testing.expectEqual(expect.items.len, served);
    try testing.expectEqualSlices(u8, expect.items, plain.written());
    try testing.expectEqual(stream.written().len, fixed_in.seek);
}

test "zlib fuzz: writer machinery" {
    try testing.fuzz({}, fuzzWriterMachinery, .{});
}

// ---------------------------------------------------------------------------
// Target 5: the reader's consumer machinery
// ---------------------------------------------------------------------------

/// The reader-machinery source cap: one and a half windows, so every iteration
/// slides the window and crosses blocks.
const reader_source_max: usize = 96 * 1024;

/// The consumer ops the reader target mixes: the `Io.Reader` surface the
/// README's "Streaming" section contracts on.
const ReadOp = enum(u8) {
    peek,
    take,
    discard_all,
    read_slice_all,
    stream_fixed,
    /// The interface's zero-length request (a poll). Mid-stream it is a
    /// zero-byte serve; on a done reader it reports `EndOfStream`. Both are
    /// legal; nothing may be lost either way.
    poll,
    /// A request past the contiguous-read cap: served when the window has
    /// room, `StreamTooLong` when it does not — never an assert.
    over_cap_take,
};

/// Target 5: the reader's consumer machinery, Smith-driven.
///
/// Attacks the vtable surface (`peek`/`take`/`discardAll`/`readSliceAll`/
/// `stream`), the window slide and its retained tail, the contiguity cap, the
/// trailer verification at the clean end, and the boundary: the stream
/// followed by markers stops exactly at ADLER32 under every op. The input side
/// is sometimes a small `Io.Reader.Limited` buffer, so the bit reader refills
/// mid-symbol.
fn fuzzReaderMachinery(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    const level = implementedLevel(smith);
    var input_buf: [reader_source_max]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    // A known stream: chunked writes with mid-stream flushes.
    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();
    var wbuf: zlib.Writer.Buffer = undefined;
    var w: zlib.Writer = .init(&stream.writer, &wbuf, .{ .level = level });
    var p: usize = 0;
    var flushes: usize = 0;
    while (p < input.len) {
        const n = @min(input.len - p, rangeAtMost(smith, 1, 32 * 1024));
        try w.writer.writeAll(input[p..][0..n]);
        p += n;
        if (flushes < flush_budget and smith.boolWeighted(1, 3)) {
            try w.writer.flush();
            flushes += 1;
        }
    }
    try w.finish();

    // Markers after the stream: the reader must stop at ADLER32's last byte
    // whatever the consumer ops do.
    var framed: [
        zlib.encode.maxCompressedLength(reader_source_max) + marker_len + 5 * flush_budget
    ]u8 = undefined;
    try testing.expect(stream.written().len + marker_len <= framed.len);
    fastmem.copy(u8, framed[0..stream.written().len], stream.written());
    fastmem.set(u8, framed[stream.written().len..][0..marker_len], marker_byte);

    // The input side: sometimes a chunked reader whose buffer is small (16
    // bytes: enough for the 2-byte header and a refill), so the bit reader
    // refills mid-symbol and its lookahead must not read past the stream.
    var chunk_buf: [64]u8 = undefined;
    var fixed_in: Io.Reader = .fixed(&framed);
    var limited: Io.Reader.Limited = undefined;
    const chunked = smith.boolWeighted(1, 3);
    const input_reader: *Io.Reader = if (chunked) blk: {
        limited = .init(&fixed_in, .unlimited, chunk_buf[0..rangeAtMost(smith, 16, chunk_buf.len)]);
        break :blk &limited.interface;
    } else &fixed_in;

    var rbuf: zlib.Reader.Buffer = undefined;
    var r: zlib.Reader = .init(input_reader, &rbuf);

    var pos: usize = 0;
    var ops: usize = 0;
    var stalls: usize = 0;
    var dead = false;
    while (pos < input.len and ops < 64) : (ops += 1) {
        const left = input.len - pos;
        switch (smith.value(ReadOp)) {
            .peek => {
                // README, "Streaming": any contiguous request of at most the
                // window's retained tail is served, so a failure here is the
                // contiguity stop, not a decode error.
                const n = @min(left, rangeAtMost(smith, 1, windowTailLen()));
                if (r.reader.peek(n)) |served| {
                    try testing.expectEqualSlices(u8, input[pos..][0..n], served);
                } else |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                }
            },
            .take => {
                const n = @min(left, rangeAtMost(smith, 1, windowTailLen()));
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
                // `stream` may serve from the window or fill it; the bytes
                // land in the fixed writer, so the served count is what it
                // holds. The limit is at least one byte, so `EndOfStream`
                // here means the window is drained *and* the stream is done:
                // every byte the stream decodes must have been served by then.
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
                // it is a zero-byte serve; on a done reader it reports
                // `EndOfStream`. The reader's vtable may ignore the limit and
                // fill the window, so a poll on a nearly full window is the
                // contiguity stop — the `expectContiguityStop` path documents
                // that a zero-byte request can fail the reader.
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
                const n = windowTailLen() + 1 + rangeAtMost(smith, 0, windowTailLen() - 1);
                if (left <= n) continue;
                if (r.reader.take(n)) |served| {
                    try testing.expectEqualSlices(u8, input[pos..][0..n], served);
                    pos += n;
                } else |err| {
                    // Past what the window can hold at the consumer's
                    // position: fail closed, stickily, with the contiguity
                    // detail.
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

    // The clean end is sticky, and the input stopped exactly at the trailer
    // (the marker bytes are the caller's). The `Limited` input may have
    // buffered ahead, so the exact position is only pinned on the plain fixed
    // reader.
    try testing.expectEqual(@as(?zlib.Reader.Error, null), r.err);
    try expectStickyEnd(&r);
    if (!chunked) try testing.expectEqual(stream.written().len, fixed_in.seek);
}

/// The retained history length: `Reader.Buffer` is `2 * history_len` and the
/// decoder guarantees a contiguous request of at most one history length
/// (`src/flate/README.md`, "Streaming"; the container re-exports the buffer).
fn windowTailLen() usize {
    return @sizeOf(zlib.Reader.Buffer) / 2;
}

/// The only legal failure of a *valid* stream: the window cannot hold what the
/// consumer asked for (README, "Streaming": the contiguous-read cap). Anything
/// else is a finding. The failure is sticky and reports the detail beside the
/// interface's coarse error.
fn expectContiguityStop(r: *zlib.Reader, err: anyerror) !void {
    try testing.expectEqual(error.ReadFailed, err);
    try testing.expectEqual(zlib.Reader.Error.StreamTooLong, r.err.?);
    try expectStickyFailure(r);
}

/// Seeds for target 5: the level, then the `u32-le` length plus bytes
/// `smith.slice` consumes — one repetitive and one empty body.
const reader_corpus: []const []const u8 = &.{
    &sliceSeed(0, "abcabcabcabcabcabcabcabcabcabcabcabcabcd"),
    &sliceSeed(0, ""),
};

test "zlib fuzz: reader machinery" {
    try testing.fuzz({}, fuzzReaderMachinery, .{ .corpus = reader_corpus });
}

// ---------------------------------------------------------------------------
// Target 6: checksum accounting
// ---------------------------------------------------------------------------

/// Target 6: the checksum's byte accounting through the streaming writer.
///
/// The flate checksum hook is not in the tree yet, so this lane drives the
/// public surface instead: chunked writes with mid-stream flushes, empty
/// writes, and empty flushes — then the trailer must equal a reference
/// Adler-32 over exactly the input bytes in order (a dropped, doubled, or
/// reordered byte changes it). The reader must verify the same trailer, and a
/// corrupted ADLER32 byte must fail closed with `WrongChecksum`, stickily.
fn fuzzChecksumAccounting(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    const level = implementedLevel(smith);
    var input_buf: [checksum_max]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();
    var wbuf: zlib.Writer.Buffer = undefined;
    var w: zlib.Writer = .init(&stream.writer, &wbuf, .{ .level = level });
    var pos: usize = 0;
    var flushes: usize = 0;
    while (pos < input.len) {
        const n = @min(input.len - pos, rangeAtMost(smith, 1, 8192));
        try w.writer.writeAll(input[pos..][0..n]);
        pos += n;
        if (flushes < flush_budget and smith.boolWeighted(1, 2)) {
            try w.writer.flush();
            flushes += 1;
        }
    }
    // Empty writes and flushes must not move the digest.
    if (smith.boolWeighted(1, 1)) try w.writer.writeAll("");
    if (smith.boolWeighted(1, 1)) try w.writer.flush();
    try w.finish();
    const s = stream.written();
    try expectZlibHeader(s, level);
    try expectZlibTrailer(s, input);

    // The reader over the same stream: identity, clean end, boundary.
    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    var fixed_in: Io.Reader = .fixed(s);
    const served = try zlib.Reader.streamAll(&fixed_in, &plain.writer);
    try testing.expectEqual(input.len, served);
    try testing.expectEqualSlices(u8, input, plain.written());
    try testing.expectEqual(s.len, fixed_in.seek);

    // A corrupted trailer must fail closed with WrongChecksum — the check
    // RFC 1950 §2.3 makes a decoder MUST. The buffer carries the flushed
    // blocks' 5-byte headers beyond the no-flush bound.
    var corrupted: [zlib.encode.maxCompressedLength(checksum_max) + 5 * flush_budget]u8 = undefined;
    fastmem.copy(u8, corrupted[0..s.len], s);
    const at = s.len - trailer_len + rangeAtMost(smith, 0, trailer_len - 1);
    corrupted[at] ^= flipValue(smith);
    const bad = corrupted[0..s.len];
    var plain_buf: [checksum_max + guard_len]u8 = undefined;
    sentinel.fill(&plain_buf);
    const result = zlib.decode.decompress(bad, plain_buf[0..input.len]);
    const err = if (result) |_| return error.ExpectedFailure else |e| e;
    try testing.expectEqual(error.WrongChecksum, err);
    try sentinel.expect(&plain_buf, input.len);

    // The reader reports the same detail, sticky.
    var rbuf: zlib.Reader.Buffer = undefined;
    var bad_in: Io.Reader = .fixed(bad);
    var r: zlib.Reader = .init(&bad_in, &rbuf);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, pump(&r.reader, &sink.writer, pumpLimit(input.len)));
    try testing.expectEqual(zlib.Reader.Error.WrongChecksum, r.err.?);
    try expectStickyFailure(&r);
}

/// Seeds for target 6: an empty payload (Adler-32 1) and a phrase with
/// matches.
const checksum_corpus: []const []const u8 = &.{
    &sliceSeed(0, ""),
    &sliceSeed(0, "checksums ride the codec boundary " ** 4),
};

test "zlib fuzz: checksum accounting" {
    try testing.fuzz({}, fuzzChecksumAccounting, .{ .corpus = checksum_corpus });
}

// ---------------------------------------------------------------------------
// Target 7: the flate checksum hook
// ---------------------------------------------------------------------------

/// The hook lane's fold state: the container's day-one kernel is std's
/// (README, "The checksum"), so the synthetic hook folds runs through a std
/// Adler-32 state and the reference is the one-shot hash over the same bytes.
const Fold = struct {
    adler: std.hash.Adler32 = .{},

    fn update(context: *anyopaque, bytes: []const u8) void {
        const self: *Fold = @ptrCast(@alignCast(context));
        self.adler.update(bytes);
    }

    /// The hook value: `flate.Writer.Checksum` and `flate.Reader.Checksum`
    /// name the same type (`src/flate/Checksum.zig`), so one value serves
    /// both layers.
    fn hook(self: *Fold) flate.Writer.Checksum {
        return .{ .context = self, .update_fn = update };
    }
};

/// Seeds for target 7: a phrase with matches, and an empty payload.
const hook_corpus: []const []const u8 = &.{
    &sliceSeed(0, "the checksum rides the codec boundary " ** 4),
    &sliceSeed(0, ""),
};

/// Target 7: the flate checksum hook, the container's dependency.
///
/// The hook slice is in the tree (`src/flate/Checksum.zig`), so this lane pins
/// the contract the containers ride (README, "Hashing rides the codec
/// boundary"): set before the first write and the first read, the hook folds
/// every payload byte exactly once, in stream order, through both streaming
/// layers — across mid-stream flushes on the encode side and a chunked input
/// on the decode side — and each digest equals the reference Adler-32 over the
/// same bytes. The container's own wiring of this state into a trailer is
/// targets 1, 3, and 6; this lane is the raw funnel underneath.
fn fuzzChecksumHook(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    var input_buf: [hook_max]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: flate.Writer.Buffer = undefined;
    var w: flate.Writer = .init(&compressed.writer, &wbuf, .{});
    var encode_fold: Fold = .{};
    w.checksum = encode_fold.hook();
    var pos: usize = 0;
    while (pos < input.len) {
        const n = @min(input.len - pos, rangeAtMost(smith, 1, 8192));
        try w.writer.writeAll(input[pos..][0..n]);
        pos += n;
        if (smith.boolWeighted(1, 2)) try w.writer.flush();
    }
    try w.finish();
    try testing.expectEqual(std.hash.Adler32.hash(input), encode_fold.adler.adler);

    // The reader side: the same fold over the same bytes, with the input
    // sometimes chunked so the window fills mid-symbol.
    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    var rbuf: flate.Reader.Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var limited: Io.Reader.Limited = undefined;
    var chunk_buf: [64]u8 = undefined;
    const input_reader: *Io.Reader = if (smith.boolWeighted(1, 3)) blk: {
        limited = .init(&fixed_in, .unlimited, chunk_buf[0..rangeAtMost(smith, 3, chunk_buf.len)]);
        break :blk &limited.interface;
    } else &fixed_in;
    var r: flate.Reader = .init(input_reader, &rbuf);
    var decode_fold: Fold = .{};
    r.checksum = decode_fold.hook();
    try pump(&r.reader, &plain.writer, pumpLimit(input.len));
    try testing.expectEqualSlices(u8, input, plain.written());
    try testing.expectEqual(std.hash.Adler32.hash(input), decode_fold.adler.adler);
}

test "zlib fuzz: flate checksum hook" {
    try testing.fuzz({}, fuzzChecksumHook, .{ .corpus = hook_corpus });
}

// ---------------------------------------------------------------------------
// Target 8: the amplification caps
// ---------------------------------------------------------------------------

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

/// Seeds for target 8: a run and a phrase at the fast and stored-only levels,
/// so the cap boundary runs over a match-heavy and a passthrough stream.
const amplification_corpus: []const []const u8 = &.{
    &shapeSeed(0, .run, 8192, &u64Le(0x41)),
    &shapeSeed(0, .phrase, 4096, &u64Le(16) ++ "0123456789abcdef"),
    &shapeSeed(2, .run, 4096, &u64Le(0x5a)),
};

/// Target 8: the amplification caps.
///
/// Attacks the two amplification rules the README states ("Sizing"): the
/// one-shot writes only into `target`, and a small stream cannot buy output
/// past what the caller offered. A bomb-shaped stream is decoded into a cap
/// below its decoded length — including the exact boundary `len - 1` — which
/// must fail closed with `BufferTooSmall` and leave every byte past the cap
/// untouched, then at the exact length (identity) and with slack (the guard
/// region untouched). The stored-only level decodes the same source through
/// the passthrough path, so the cap rule is not a property of the match
/// finder.
fn fuzzAmplification(_: void, smith: *Smith) anyerror!void {
    const level = smith.value(zlib.encode.Level);
    if (level == .ratio) return; // the reserved seat; target 1 covers it
    const shape = smith.value(Shape);
    var source_buf: [bomb_source_max]u8 = undefined;
    const source = source_buf[0..buildBomb(smith, shape, &source_buf)];

    var stream_buf: [zlib.encode.maxCompressedLength(bomb_source_max)]u8 = undefined;
    const s_len = try zlib.encode.compress(source, &stream_buf, .{ .level = level });
    const stream = stream_buf[0..s_len];
    try testing.expect(s_len <= zlib.encode.maxCompressedLength(source.len));
    if (level != .@"0" and shape == .run and source.len >= 1024) {
        // The bomb property, where the shape pins it: a run of at least a KiB
        // is almost all 258-byte matches, so its stream is a small fraction
        // of its output and a cap that ignored the decoded length would be a
        // real overrun.
        try testing.expect(s_len * 8 <= source.len);
    }

    var window: [bomb_source_max + guard_len]u8 = undefined;

    // Below the decoded length: fail closed, nothing past the cap written.
    if (source.len > 0) {
        const caps = [_]usize{ source.len - 1, rangeAtMost(smith, 0, source.len - 1) };
        for (caps) |cap| {
            sentinel.fill(&window);
            try testing.expectError(
                error.BufferTooSmall,
                zlib.decode.decompress(stream, window[0..cap]),
            );
            try sentinel.expect(&window, cap);
        }
    }

    // At the decoded length: exact, and the guard region is the caller's.
    sentinel.fill(&window);
    const n = try zlib.decode.decompress(stream, window[0..source.len]);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, window[0..n]);
    try sentinel.expect(&window, n);

    // Above it: the same, with the whole window as the cap.
    sentinel.fill(&window);
    const m = try zlib.decode.decompress(stream, &window);
    try testing.expectEqual(source.len, m);
    try testing.expectEqualSlices(u8, source, window[0..m]);
    try sentinel.expect(&window, m);
}

test "zlib fuzz: amplification caps" {
    try testing.fuzz({}, fuzzAmplification, .{ .corpus = amplification_corpus });
}

// ---------------------------------------------------------------------------
// Contract pins: the hostile-header first targets, deterministic
// ---------------------------------------------------------------------------

// The constructed streams the header parser must fail closed on, as plain
// unit tests so a normal `zig build test` run gates them too.
test "zlib fuzz: hostile-header pins" {
    // The empty stream our encoder emits at `.fast`: CMF=0x78, FLG=0x9c
    // (FLEVEL 2, FCHECK 28), the final empty fixed block, Adler-32 1 (§2.2).
    const empty_stream = "\x78\x9c\x03\x00\x00\x00\x00\x01";

    // A zero-byte input is error.Truncated: no stream began (T2/OQ3).
    try testing.expectError(error.Truncated, zlib.decode.decompress("", &.{}));

    // Every truncation — header, body, trailer — fails closed.
    var i: usize = 0;
    while (i < empty_stream.len) : (i += 1) {
        try testing.expectError(
            error.Truncated,
            zlib.decode.decompress(empty_stream[0..i], &.{}),
        );
    }

    var buf: [empty_stream.len]u8 = undefined;

    // Bad FCHECK (Go's golden 78 9f): BadHeader (§2.3).
    fastmem.copy(u8, &buf, empty_stream);
    buf[1] = 0x9f;
    try testing.expectError(error.BadHeader, zlib.decode.decompress(&buf, &.{}));

    // Bad CINFO (Go's golden 88 98: CM=8, CINFO=8): BadHeader (§2.2).
    buf[0] = 0x88;
    buf[1] = 0x98;
    try testing.expectError(error.BadHeader, zlib.decode.decompress(&buf, &.{}));

    // A CM other than 8 with a conformant FCHECK (09 15): BadHeader (§2.3).
    buf[0] = 0x09;
    buf[1] = 0x15;
    try testing.expectError(error.BadHeader, zlib.decode.decompress(&buf, &.{}));

    // FDICT set with a conformant FCHECK (78 bb): DictionaryRequired, before
    // any body byte — never a silent DICTID skip (§2.3, ZD3/ZD4).
    buf[0] = 0x78;
    buf[1] = 0xbb;
    try testing.expectError(error.DictionaryRequired, zlib.decode.decompress(&buf, &.{}));

    // The T5 corner: 0x78 0x3f (FCHECK = 31, C zlib's and Go's FDICT +
    // FLEVEL-0 emission) is conformant — 31 == 0 mod 31 — and must land on
    // DictionaryRequired, never BadHeader.
    buf[1] = 0x3f;
    try testing.expectError(error.DictionaryRequired, zlib.decode.decompress(&buf, &.{}));

    // A conformant FLEVEL band with a matching FCHECK (78 5e, FLEVEL 1) and a
    // CINFO-0 header (08 1d): both decode the empty body. FLEVEL is
    // informational and CINFO <= 7 is legal (§2.2, §2.3).
    buf[0] = 0x78;
    buf[1] = 0x5e;
    try testing.expectEqual(@as(usize, 0), try zlib.decode.decompress(&buf, &.{}));
    buf[0] = 0x08;
    buf[1] = 0x1d;
    try testing.expectEqual(@as(usize, 0), try zlib.decode.decompress(&buf, &.{}));

    // FLEVEL is ignored but FCHECK still guards the pair: a lone FCHECK flip
    // (0x9c -> 0x9e) breaks the arithmetic and is BadHeader.
    buf[0] = 0x78;
    buf[1] = 0x9e;
    try testing.expectError(error.BadHeader, zlib.decode.decompress(&buf, &.{}));
}
