//! Fuzz targets for the gzip container (RFC 1952) over the flate module, one
//! per layer of the container surface:
//!
//!   - `fuzzOneShotRoundTrip`: structured shapes through `encode.compress` ->
//!     `decode.decompress`: identity, the `maxCompressedLength` bound, the
//!     deterministic header (FLG=0, MTIME=0, the XFL band, OS=255), the
//!     trailer against a reference CRC-32/ISIZE over the same bytes, and the
//!     trailer-location divergence: bytes after the trailer are ignored by
//!     the one-shot (README, "Contracts").
//!   - `fuzzHeaderTrailerCorruption`: valid members with Smith mutations —
//!     truncation at every position, header/body/trailer flips, reserved FLG
//!     bits, a giant XLEN, an unterminated FNAME, appended markers, a
//!     duplicated member — with the contract's specific errors pinned and the
//!     universal property: a successful decode re-encodes, and a clean
//!     `Reader` end proves its trailer matches the reference checksums of its
//!     own output at the exact member boundary.
//!   - `fuzzStreamRoundTrip`: `Writer` -> `Reader` identity over members,
//!     through both `streamAll` pairs and the manual init/write/finish and
//!     consume paths, plus the exact-boundary property: markers and a second
//!     member after the trailer are never consumed, and a fresh reader at the
//!     boundary decodes the next member (the caller loop).
//!   - `fuzzWriterMachinery`: Smith-chosen `Io.Writer` operation sequences
//!     against an expected-bytes model — the lazy header, `drain`/`flush`/
//!     `rebase` accounting, and the trailer at `finish` — then decoded and
//!     compared.
//!   - `fuzzReaderMachinery`: Smith-chosen consumer op sequences
//!     (peek/take/discardAll/readSliceAll/stream) over known members — the
//!     boundary preserved under every op, the contiguity cap probed.
//!   - `fuzzChecksumAccounting`: chunked streaming writes with mid-stream
//!     flushes; the trailer must equal a reference CRC-32 over the same bytes
//!     in order (every byte exactly once), and a corrupted trailer must fail
//!     closed.
//!   - `fuzzChecksumHook`: the flate checksum hook (`src/flate/Checksum.zig`,
//!     in the tree) is the container's zero-copy dependency, so this lane
//!     drives `flate.Writer`/`flate.Reader` with a synthetic fold and pins the
//!     contract the container rides: every payload byte folded exactly once,
//!     in stream order, through both layers.
//!   - `fuzzAmplification`: bomb-shaped members decoded into caps below their
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
//! Spec: docs/research/specs/rfc1952-gzip.txt (§2.2 members, §2.3.1 the fixed
//! header, §2.3.1.1 FEXTRA, §2.3.1.2 decoder obligations, §8 the CRC-32
//! sample). Contracts: src/gzip/README.md.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;
const Smith = testing.Smith;
const math = std.math;
const mem = std.mem;
const Crc32 = std.hash.crc.Crc32;

const fastmem = @import("fastmem");

const flate = @import("../flate/root.zig");
const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const gzip = @import("root.zig");

// ---------------------------------------------------------------------------
// Shared harness
// ---------------------------------------------------------------------------

/// Bytes past the decoded length checked on every decode: an out-of-bounds
/// write (a 16-byte SIMD store, a 64-byte copy chunk) lands in this region.
const guard_len: usize = 256;

/// RFC 1952 §2.3 — the fixed header and the trailer.
const header_len: usize = 10;
const trailer_len: usize = 8;

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
/// block grows the member past the no-flush `maxCompressedLength` bound by
/// at most 5 bytes — the fixed buffers below carry `5 * flush_budget` of
/// headroom for exactly this (the bound itself budgets only the
/// unflushed block count).
const flush_budget: usize = 16;

/// The checksum lane's source cap.
const checksum_max: usize = 64 * 1024;

/// The corruption source cap: the valid member is built from at most this
/// much plaintext, and the mutations stay inside the mutation buffer.
const corrupt_source_max: usize = 2048;

/// The corruption output cap: a hostile member can expand far past its input
/// (a dynamic tree can code 258-byte matches in two bits), so the cap bounds
/// the decode's work and the sentinel window.
const corrupt_out_max: usize = 64 * 1024;

/// The mutation buffer: two valid members (the duplicate-member operator) plus
/// room for the constructed hostile headers and appended markers.
const corrupt_mut_max: usize = 2 * gzip.encode.maxCompressedLength(corrupt_source_max) + 1024;

/// The amplification source cap: a run this long compresses to a few hundred
/// bytes, so its decode is a ~100x expansion — a bomb in miniature.
const bomb_source_max: usize = 64 * 1024;

/// The checksum-hook lane's source cap.
const hook_max: usize = 64 * 1024;

/// Marker bytes appended after a member to prove the reader stops at the
/// trailer's last byte (README, "Streaming"): the member is self-delimiting,
/// so bytes after the trailer are not the reader's to consume.
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
fn implementedLevel(smith: *Smith) gzip.encode.Level {
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

/// Pump `r` into the fixed writer `w` until the member ends, the reader fails,
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

/// RFC 1952 §2.3.1 — the deterministic emitted header (README, "The member
/// format"): ID1/ID2/CM fixed, FLG=0 (no optional fields, reserved bits
/// clear), MTIME=0, XFL by level band, OS=255.
fn expectGzipHeader(member: []const u8, level: gzip.encode.Level) !void {
    try testing.expect(member.len >= header_len + trailer_len);
    try testing.expectEqual(@as(u8, 0x1f), member[0]);
    try testing.expectEqual(@as(u8, 0x8b), member[1]);
    try testing.expectEqual(@as(u8, 8), member[2]);
    try testing.expectEqual(@as(u8, 0), member[3]);
    // MTIME 0: "no time stamp is available" (§2.3.1); little-endian (§2.1).
    try testing.expectEqual(@as(u32, 0), mem.readInt(u32, member[4..8], .little));
    try testing.expectEqual(xflFor(level), member[8]);
    try testing.expectEqual(@as(u8, 255), member[9]);
}

/// RFC 1952 §2.3.1 — XFL is informational; the emitted band follows the
/// reference lineage (README, "The member format"): 4 for the levels that
/// select the fast fixed-Huffman encoder, 2 for level 9, 0 otherwise.
fn xflFor(level: gzip.encode.Level) u8 {
    return switch (level) {
        .fast, .@"0", .@"1" => 4,
        .@"9" => 2,
        else => 0,
    };
}

/// RFC 1952 §2.3.1 — the trailer: CRC-32 of the uncompressed data per
/// ISO 3309, and ISIZE = the input length mod 2^32; both little-endian (§2.1).
/// The reference is std's CRC-32 kernel over the same bytes, so this pins the
/// container's byte accounting (every byte exactly once, in order).
fn expectGzipTrailer(member: []const u8, source: []const u8) !void {
    try testing.expect(member.len >= trailer_len);
    const trailer = member[member.len - trailer_len ..];
    try testing.expectEqual(
        Crc32.hash(source),
        mem.readInt(u32, trailer[0..4], .little),
    );
    try testing.expectEqual(
        @as(u32, @truncate(source.len)),
        mem.readInt(u32, trailer[4..8], .little),
    );
}

/// The clean end is sticky: repeated `stream` calls end in `EndOfStream`. A
/// zero-serve fill call may come first — the interface allows a zero return
/// that does not indicate stream end — so this drives the calls instead of
/// pinning the first one.
fn expectStickyEnd(r: *gzip.Reader) !void {
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
fn expectStickyFailure(r: *gzip.Reader) !void {
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

/// Whatever a hostile member decoded to must survive a full encode/decode
/// cycle (the oracle-within-process property): our encoder is checked by our
/// decoder on bytes the fuzzer chose, not on bytes we chose.
fn reencodeRoundTrip(bytes: []const u8) !void {
    assert(bytes.len <= corrupt_out_max);
    var member: [gzip.encode.maxCompressedLength(corrupt_out_max)]u8 = undefined;
    const m_len = try gzip.encode.compress(bytes, &member, .{ .level = .fast });
    try testing.expect(m_len <= gzip.encode.maxCompressedLength(bytes.len));

    var plain: [corrupt_out_max + guard_len]u8 = undefined;
    sentinel.fill(&plain);
    const n = try gzip.decode.decompress(member[0..m_len], plain[0..bytes.len]);
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
/// Attacks the encoder's block split and the container framing (the header,
/// the trailer, the `maxCompressedLength` bound), then the decoder's trailer
/// location through the fixed-reader route, its cap, and its sentinel-clean
/// output. The property: `compress` -> `decompress` is the identity, the
/// emitted member is the deterministic one, and a member followed by marker
/// bytes decodes identically (bytes after the trailer are ignored).
fn fuzzOneShotRoundTrip(_: void, smith: *Smith) anyerror!void {
    const level = smith.value(gzip.encode.Level);
    var source_buf: [roundtrip_max]u8 = undefined;
    const source = source_buf[0..buildShape(smith, &source_buf)];

    if (level == .ratio) {
        // encode.Level's contract: the ratio mode is `error.Unimplemented` on
        // the one-shot and `error.ReadFailed` on the stream, never silent
        // aliasing (README, "API").
        var tiny: [16]u8 = undefined;
        try testing.expectError(
            error.Unimplemented,
            gzip.encode.compress(source, &tiny, .{ .level = .ratio }),
        );
        var sink: Io.Writer.Discarding = .init(&.{});
        var fixed_in: Io.Reader = .fixed(source);
        try testing.expectError(
            error.ReadFailed,
            gzip.Writer.streamAll(&fixed_in, &sink.writer, .{ .level = .ratio }),
        );
        var wbuf: gzip.Writer.Buffer = undefined;
        var w: gzip.Writer = .init(&sink.writer, &wbuf, .{ .level = .ratio });
        try testing.expectError(error.WriteFailed, w.writer.writeAll("x"));
        try testing.expectError(error.WriteFailed, w.finish());
        return;
    }

    // The marker room rides the same buffer: the member followed by markers is
    // one contiguous slice.
    var member_buf: [gzip.encode.maxCompressedLength(roundtrip_max) + marker_len]u8 = undefined;
    const m_len = try gzip.encode.compress(source, &member_buf, .{ .level = level });
    const member = member_buf[0..m_len];

    // The documented bound, on every emission (README, "Contracts").
    try testing.expect(m_len <= gzip.encode.maxCompressedLength(source.len));
    try expectGzipHeader(member, level);
    try expectGzipTrailer(member, source);

    var plain_buf: [roundtrip_max + guard_len]u8 = undefined;
    // Exact cap first: a decoder that writes past the decoded length lands in
    // the guard region (the sentinel check is what proves it did not).
    sentinel.fill(&plain_buf);
    const n = try gzip.decode.decompress(member, plain_buf[0..source.len]);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, plain_buf[0..n]);
    try sentinel.expect(&plain_buf, n);

    // Then with slack, so the bytes past the decoded length are checked too.
    sentinel.fill(&plain_buf);
    const m = try gzip.decode.decompress(member, &plain_buf);
    try testing.expectEqual(n, m);
    try testing.expectEqualSlices(u8, source, plain_buf[0..m]);
    try sentinel.expect(&plain_buf, m);

    // The trailer-location divergence, pinned: the one-shot decodes a member
    // followed by marker bytes identically — bytes after the trailer are
    // ignored (README, "Contracts"; the streaming reader is the
    // boundary-aware route).
    fastmem.set(u8, member_buf[m_len..][0..marker_len], marker_byte);
    const framed = member_buf[0 .. m_len + marker_len];
    sentinel.fill(&plain_buf);
    const f = try gzip.decode.decompress(framed, plain_buf[0..source.len]);
    try testing.expectEqual(source.len, f);
    try testing.expectEqualSlices(u8, source, plain_buf[0..f]);
    try sentinel.expect(&plain_buf, f);
}

test "gzip fuzz: one-shot round trip" {
    try testing.fuzz({}, fuzzOneShotRoundTrip, .{ .corpus = roundtrip_corpus });
}

// ---------------------------------------------------------------------------
// Target 2: header and trailer corruption
// ---------------------------------------------------------------------------

/// The outcome class a mutation pins (README, "The member format" and
/// "Contracts"; the error names are the `DecompressError` set).
const Expected = enum {
    /// The member must decode to exactly the original source.
    exact_source,
    /// Any failure: a member whose end is gone never decodes.
    fail_any,
    /// `error.Truncated`.
    fail_truncated,
    /// `error.BadHeader`.
    fail_bad_header,
    /// `error.HeaderTooLong`.
    fail_header_too_long,
    /// `error.WrongChecksum` or `error.WrongSize`.
    fail_trailer,
    /// Fail closed or succeed, with the universal properties checked.
    unknown,
};

/// The corruption operators. Each keeps `buf[0..len]` in bounds.
const Mutation = enum(u8) {
    /// Cut the member at a Smith-chosen byte: its end is gone.
    truncate,
    /// §2.3.1.2 — MTIME, XFL, and OS are ignorable on decode.
    flip_ignorable,
    /// A flip inside the deflate body: the output is the body's business.
    flip_body,
    /// A flip inside the trailer: the check must fail.
    flip_trailer,
    /// §2.3.1.2 — a reserved FLG bit is `BadHeader`.
    set_reserved_flg,
    /// ID1/ID2/CM (§2.3.1.2): `BadHeader`.
    flip_magic,
    /// FEXTRA/FNAME/FCOMMENT/FHCRC: the parse shifts into the body.
    poke_optional_flg,
    /// A tiny member declaring a 65,535-byte extra field (T7): fail closed,
    /// never staged.
    giant_xlen,
    /// FNAME with no NUL before the 512-byte cap (T7): `HeaderTooLong`.
    unterminated_name,
    /// Marker bytes after the trailer: ignored by the one-shot, unconsumed by
    /// the reader.
    append_markers,
    /// A second member after the first: not consumed by one reader.
    duplicate_member,
};

const Mutated = struct {
    len: usize,
    /// The valid member's end inside the mutation buffer: the position a clean
    /// `Reader` end must stop at for the `exact_source` class.
    member_end: usize,
    expected: Expected,
};

/// A nonzero byte to XOR with, so a flip always changes the byte.
fn flipValue(smith: *Smith) u8 {
    return @intCast(1 + rangeAtMost(smith, 0, 254));
}

/// Apply one Smith-chosen mutation to the valid member in `buf[0..member_len]`
/// and return the mutated length plus the class the contract pins.
fn mutateMember(smith: *Smith, buf: []u8, member_len: usize) Mutated {
    assert(member_len >= header_len + trailer_len);
    const body_start = header_len;
    const body_end = member_len - trailer_len;
    switch (smith.value(Mutation)) {
        .truncate => {
            // The trailer is incomplete, or the body's bits run out first:
            // a truncated member never decodes.
            const cut = rangeAtMost(smith, 0, member_len - 1);
            return .{ .len = cut, .member_end = member_len, .expected = .fail_any };
        },
        .flip_ignorable => {
            const at = rangeAtMost(smith, 4, header_len - 1);
            buf[at] ^= flipValue(smith);
            return .{ .len = member_len, .member_end = member_len, .expected = .exact_source };
        },
        .flip_body => {
            const at = rangeAtMost(smith, body_start, body_end - 1);
            buf[at] ^= flipValue(smith);
            return .{ .len = member_len, .member_end = member_len, .expected = .unknown };
        },
        .flip_trailer => {
            // The body is untouched, so the trailer must still equal the
            // reference checksums; a flipped byte can only fail the check.
            const at = rangeAtMost(smith, body_end, member_len - 1);
            buf[at] ^= flipValue(smith);
            return .{ .len = member_len, .member_end = member_len, .expected = .fail_trailer };
        },
        .set_reserved_flg => {
            // §2.3.1.2 — a reserved bit "could indicate the presence of a new
            // field that would cause subsequent data to be interpreted
            // incorrectly": fail closed.
            const bit = @as(u8, 0x20) << @intCast(rangeAtMost(smith, 0, 2));
            buf[3] |= bit;
            return .{ .len = member_len, .member_end = member_len, .expected = .fail_bad_header };
        },
        .flip_magic => {
            const at = rangeAtMost(smith, 0, 2);
            buf[at] ^= flipValue(smith);
            return .{ .len = member_len, .member_end = member_len, .expected = .fail_bad_header };
        },
        .poke_optional_flg => {
            const bit = @as(u8, 0x02) << @intCast(rangeAtMost(smith, 0, 3));
            buf[3] |= bit;
            return .{ .len = member_len, .member_end = member_len, .expected = .unknown };
        },
        .giant_xlen => {
            // FLG = FEXTRA, XLEN = 0xffff, and nothing after: the skip runs
            // out of input (§2.3.1.1, T7).
            buf[3] = 0x04;
            fastmem.set(u8, buf[header_len..][0..2], 0xff);
            return .{
                .len = header_len + 2,
                .member_end = member_len,
                .expected = .fail_truncated,
            };
        },
        .unterminated_name => {
            // FLG = FNAME, then 600 non-NUL bytes: past the 512-byte cap.
            buf[3] = 0x08;
            fastmem.set(u8, buf[header_len..][0..600], 'a');
            return .{
                .len = header_len + 600,
                .member_end = member_len,
                .expected = .fail_header_too_long,
            };
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
        .duplicate_member => {
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
    const result = gzip.decode.decompress(mutated, target);
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
        .fail_header_too_long => {
            try testing.expectError(error.HeaderTooLong, result);
            try sentinel.expect(&window, cap);
        },
        .fail_trailer => {
            const err = if (result) |_| return error.ExpectedFailure else |e| e;
            switch (err) {
                error.WrongChecksum, error.WrongSize => {},
                else => return err,
            }
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
/// matches the reference checksums of the reader's own output at the exact
/// member boundary; a failure is sticky with the detail in `err`.
fn checkReader(mutated: []const u8, source: []const u8, meta: Mutated) !void {
    var got: [corrupt_out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: gzip.Reader.Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(mutated);
    var r: gzip.Reader = .init(&fixed_in, &rbuf);
    const pumped = try pumpCapped(&r.reader, &fw, pumpLimit(corrupt_out_max));
    const served = pumped.served;

    switch (pumped.stop) {
        .end_of_stream => {
            // The reader verified the trailer against its own output, so the
            // reference must agree — and the input stopped exactly at the
            // trailer's last byte (the member boundary contract).
            try testing.expect(fixed_in.seek >= trailer_len);
            const trailer = mutated[fixed_in.seek - trailer_len .. fixed_in.seek];
            try testing.expectEqual(
                Crc32.hash(got[0..served]),
                mem.readInt(u32, trailer[0..4], .little),
            );
            try testing.expectEqual(
                @as(u32, @truncate(served)),
                mem.readInt(u32, trailer[4..8], .little),
            );
            if (meta.expected == .exact_source) {
                try testing.expectEqualSlices(u8, source, got[0..served]);
                try testing.expectEqual(meta.member_end, fixed_in.seek);
            }
            try testing.expectEqual(@as(?gzip.Reader.Error, null), r.err);
            try expectStickyEnd(&r);
        },
        .read_failed => {
            try testing.expect(meta.expected != .exact_source);
            const detail = r.err.?;
            switch (meta.expected) {
                .fail_truncated => try testing.expectEqual(gzip.Reader.Error.Truncated, detail),
                .fail_bad_header => try testing.expectEqual(gzip.Reader.Error.BadHeader, detail),
                .fail_header_too_long => try testing.expectEqual(
                    gzip.Reader.Error.HeaderTooLong,
                    detail,
                ),
                .fail_trailer => try testing.expect(
                    detail == gzip.Reader.Error.WrongChecksum or
                        detail == gzip.Reader.Error.WrongSize,
                ),
                // An unpinned mutation (`unknown`) or a cut member
                // (`fail_any`): the detail is the mutation's business. A
                // flipped body byte makes the untouched trailer mismatch the
                // changed output (`WrongChecksum`/`WrongSize`); a shifted
                // optional-field parse can end the stream mid-deflate
                // (`Truncated`). The sticky-failure property below is the pin.
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
/// Attacks the header parse (magic, CM, FLG bits, the optional-field skip, the
/// 512-byte FNAME cap, a giant XLEN), the body's exact end, and the trailer
/// check (CRC-32 and ISIZE). The property: the mutation's contract class
/// holds — the specific error, or an exact-source decode for ignorable header
/// bytes and trailing bytes — and otherwise the decode fails closed, any
/// success re-encodes, and the streaming reader's clean end is
/// trailer-consistent at the exact member boundary.
fn fuzzHeaderTrailerCorruption(_: void, smith: *Smith) anyerror!void {
    const level = implementedLevel(smith);
    var source_buf: [corrupt_source_max]u8 = undefined;
    const source = source_buf[0..buildShape(smith, &source_buf)];

    var mut_buf: [corrupt_mut_max]u8 = undefined;
    const m_len = try gzip.encode.compress(source, &mut_buf, .{ .level = level });
    const meta = mutateMember(smith, &mut_buf, m_len);
    const mutated = mut_buf[0..meta.len];

    // The cap: the exact source length for the pinned classes (so
    // `exact_source` can succeed), a Smith-chosen cap otherwise.
    const cap = switch (meta.expected) {
        .exact_source,
        .fail_truncated,
        .fail_bad_header,
        .fail_header_too_long,
        .fail_trailer,
        => source.len,
        .fail_any, .unknown => rangeAtMost(smith, 0, corrupt_out_max),
    };
    try checkOneShot(mutated, source, meta, cap);
    try checkReader(mutated, source, meta);
}

test "gzip fuzz: header and trailer corruption" {
    try testing.fuzz({}, fuzzHeaderTrailerCorruption, .{});
}

// ---------------------------------------------------------------------------
// Target 3: the streaming round trip and the member boundary
// ---------------------------------------------------------------------------

/// Seeds for target 3: a repeated phrase the encoder turns into matches, and
/// an empty payload (the header-before-nothing path).
const stream_corpus: []const []const u8 = &.{
    &sliceSeed(0, "the quick brown fox " ** 8),
    &sliceSeed(0, ""),
};

/// Target 3: `Writer` -> `Reader` identity over members, both the `streamAll`
/// pair and the manual init/write/finish and consume paths.
///
/// Attacks the lazy header (written before the first compressed byte), the
/// trailer at `finish`, the streaming writer's block accumulation with
/// mid-stream flushes, the reader's window and refill, and the exact-boundary
/// rule: the reader consumes its input through the trailer's last byte and
/// never reads a byte past it — markers and a second member stay unconsumed,
/// and a fresh reader at the boundary decodes the next member.
fn fuzzStreamRoundTrip(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    const level = implementedLevel(smith);
    var input_buf: [stream_max]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    // The member followed by markers, and two members followed by markers:
    // one buffer, both shapes.
    var framed: [
        2 * gzip.encode.maxCompressedLength(stream_max) +
            2 * marker_len + 5 * flush_budget
    ]u8 = undefined;
    var sink: Io.Writer.Discarding = .init(&.{});

    // Path A — the `streamAll` pair: Writer.streamAll consumes its input
    // exactly, then Reader.streamAll decodes it back.
    var member_out: Io.Writer.Allocating = .init(gpa);
    defer member_out.deinit();
    var source_in: Io.Reader = .fixed(input);
    const consumed = try gzip.Writer.streamAll(&source_in, &member_out.writer, .{ .level = level });
    try testing.expectEqual(input.len, consumed);
    try testing.expectEqual(input.len, source_in.seek);
    const member = member_out.written();
    try expectGzipHeader(member, level);
    try expectGzipTrailer(member, input);
    try testing.expect(member.len + marker_len <= framed.len);

    // The exact-boundary property: member ++ markers serves the member's
    // bytes and leaves the markers unconsumed.
    fastmem.copy(u8, framed[0..member.len], member);
    fastmem.set(u8, framed[member.len..][0..marker_len], marker_byte);
    var framed_in: Io.Reader = .fixed(&framed);
    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    const served = try gzip.Reader.streamAll(&framed_in, &plain.writer);
    try testing.expectEqual(input.len, served);
    try testing.expectEqualSlices(u8, input, plain.written());
    try testing.expectEqual(member.len, framed_in.seek);

    // Garbage where a member would be: fail closed with BadHeader, sticky.
    // The garbage is at least a full fixed header, so the magic check is what
    // rejects it (a shorter prefix is a truncated header instead).
    var garbage: [2 * marker_len]u8 = undefined;
    fastmem.set(u8, &garbage, marker_byte);
    var rbuf: gzip.Reader.Buffer = undefined;
    var garbage_in: Io.Reader = .fixed(&garbage);
    var garbage_reader: gzip.Reader = .init(&garbage_in, &rbuf);
    try testing.expectError(
        error.ReadFailed,
        pump(&garbage_reader.reader, &sink.writer, pumpLimit(marker_len)),
    );
    try testing.expectEqual(gzip.Reader.Error.BadHeader, garbage_reader.err.?);
    try expectStickyFailure(&garbage_reader);

    // A second member is not consumed either: one member per reader. A fresh
    // reader at the boundary decodes the next member — the caller loop.
    fastmem.copy(u8, framed[member.len..][0..member.len], member);
    fastmem.set(u8, framed[2 * member.len ..][0..marker_len], marker_byte);
    const two = framed[0 .. 2 * member.len + marker_len];
    var two_in: Io.Reader = .fixed(two);
    var first: Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    const first_served = try gzip.Reader.streamAll(&two_in, &first.writer);
    try testing.expectEqual(input.len, first_served);
    try testing.expectEqualSlices(u8, input, first.written());
    try testing.expectEqual(member.len, two_in.seek);
    var second: Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    const second_served = try gzip.Reader.streamAll(&two_in, &second.writer);
    try testing.expectEqual(input.len, second_served);
    try testing.expectEqualSlices(u8, input, second.written());
    try testing.expectEqual(2 * member.len, two_in.seek);

    // Path B — manual init/write/finish with Smith-chosen chunking and
    // mid-stream flushes, then a manual consume over markers.
    var member2: Io.Writer.Allocating = .init(gpa);
    defer member2.deinit();
    var wbuf: gzip.Writer.Buffer = undefined;
    var w: gzip.Writer = .init(&member2.writer, &wbuf, .{ .level = level });
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
    const member2_bytes = member2.written();
    try expectGzipHeader(member2_bytes, level);
    try expectGzipTrailer(member2_bytes, input);

    fastmem.copy(u8, framed[0..member2_bytes.len], member2_bytes);
    fastmem.set(u8, framed[member2_bytes.len..][0..marker_len], marker_byte);
    var in2: Io.Reader = .fixed(framed[0 .. member2_bytes.len + marker_len]);
    var r2: gzip.Reader = .init(&in2, &rbuf);
    var out2: Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    try pump(&r2.reader, &out2.writer, pumpLimit(input.len));
    try testing.expectEqualSlices(u8, input, out2.written());
    try testing.expectEqual(member2_bytes.len, in2.seek);
    try testing.expectEqual(@as(?gzip.Reader.Error, null), r2.err);

    // The clean end is sticky.
    try expectStickyEnd(&r2);
}

test "gzip fuzz: stream round trip" {
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
/// decoding the produced member and comparing it against the bytes the model
/// says were written, with the trailer checked against the reference.
fn fuzzWriterMachinery(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    const level = implementedLevel(smith);
    var member: Io.Writer.Allocating = .init(gpa);
    defer member.deinit();
    var expect: std.ArrayList(u8) = .empty;
    defer expect.deinit(gpa);
    var wbuf: gzip.Writer.Buffer = undefined;
    var w: gzip.Writer = .init(&member.writer, &wbuf, .{ .level = level });

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

    // The member frames the model's bytes exactly: header, trailer, identity.
    try expectGzipHeader(member.written(), level);
    try expectGzipTrailer(member.written(), expect.items);

    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    var fixed_in: Io.Reader = .fixed(member.written());
    const served = try gzip.Reader.streamAll(&fixed_in, &plain.writer);
    try testing.expectEqual(expect.items.len, served);
    try testing.expectEqualSlices(u8, expect.items, plain.written());
    try testing.expectEqual(member.written().len, fixed_in.seek);
}

test "gzip fuzz: writer machinery" {
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
/// trailer verification at the clean end, and the boundary: the member
/// followed by markers stops exactly at the trailer under every op. The
/// input side is sometimes a small `Io.Reader.Limited` buffer, so the bit
/// reader refills mid-symbol.
fn fuzzReaderMachinery(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    const level = implementedLevel(smith);
    var input_buf: [reader_source_max]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    // A known member: chunked writes with mid-stream flushes.
    var member: Io.Writer.Allocating = .init(gpa);
    defer member.deinit();
    var wbuf: gzip.Writer.Buffer = undefined;
    var w: gzip.Writer = .init(&member.writer, &wbuf, .{ .level = level });
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

    // Markers after the member: the reader must stop at the trailer's last
    // byte whatever the consumer ops do.
    var framed: [
        gzip.encode.maxCompressedLength(reader_source_max) +
            marker_len + 5 * flush_budget
    ]u8 = undefined;
    try testing.expect(member.written().len + marker_len <= framed.len);
    fastmem.copy(u8, framed[0..member.written().len], member.written());
    fastmem.set(u8, framed[member.written().len..][0..marker_len], marker_byte);

    // The input side: sometimes a chunked reader whose buffer is small (16
    // bytes: enough for the 10-byte fixed header and a refill), so the bit
    // reader refills mid-symbol and its lookahead must not read past the
    // member.
    var chunk_buf: [64]u8 = undefined;
    var fixed_in: Io.Reader = .fixed(&framed);
    var limited: Io.Reader.Limited = undefined;
    const chunked = smith.boolWeighted(1, 3);
    const input_reader: *Io.Reader = if (chunked) blk: {
        limited = .init(&fixed_in, .unlimited, chunk_buf[0..rangeAtMost(smith, 16, chunk_buf.len)]);
        break :blk &limited.interface;
    } else &fixed_in;

    var rbuf: gzip.Reader.Buffer = undefined;
    var r: gzip.Reader = .init(input_reader, &rbuf);

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
                // here means the window is drained *and* the member is done:
                // every byte the member decodes must have been served by then.
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
    try testing.expectEqual(@as(?gzip.Reader.Error, null), r.err);
    try expectStickyEnd(&r);
    if (!chunked) try testing.expectEqual(member.written().len, fixed_in.seek);
}

/// The retained history length: `Reader.Buffer` is `2 * history_len` and the
/// decoder guarantees a contiguous request of at most one history length
/// (`src/flate/README.md`, "Streaming"; the container re-exports the buffer).
fn windowTailLen() usize {
    return @sizeOf(gzip.Reader.Buffer) / 2;
}

/// The only legal failure of a *valid* member: the window cannot hold what the
/// consumer asked for (README, "Streaming": the contiguous-read cap). Anything
/// else is a finding. The failure is sticky and reports the detail beside the
/// interface's coarse error.
fn expectContiguityStop(r: *gzip.Reader, err: anyerror) !void {
    try testing.expectEqual(error.ReadFailed, err);
    try testing.expectEqual(gzip.Reader.Error.StreamTooLong, r.err.?);
    try expectStickyFailure(r);
}

/// Seeds for target 5: the level, then the `u32-le` length plus bytes
/// `smith.slice` consumes — one repetitive and one empty body.
const reader_corpus: []const []const u8 = &.{
    &sliceSeed(0, "abcabcabcabcabcabcabcabcabcabcabcabcabcd"),
    &sliceSeed(0, ""),
};

test "gzip fuzz: reader machinery" {
    try testing.fuzz({}, fuzzReaderMachinery, .{ .corpus = reader_corpus });
}

// ---------------------------------------------------------------------------
// Target 6: checksum accounting
// ---------------------------------------------------------------------------

/// Target 6: the checksum's byte accounting through the streaming writer.
///
/// The flate checksum hook is not in the tree yet, so this lane drives the
/// public surface instead: chunked writes with mid-stream flushes, empty
/// writes, and empty flushes — then the trailer must equal a reference CRC-32
/// over exactly the input bytes in order (a dropped, doubled, or reordered
/// byte changes it). The reader must verify the same trailer, and a corrupted
/// CRC byte or ISIZE byte must fail closed with the specific error, stickily.
fn fuzzChecksumAccounting(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    const level = implementedLevel(smith);
    var input_buf: [checksum_max]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];

    var member: Io.Writer.Allocating = .init(gpa);
    defer member.deinit();
    var wbuf: gzip.Writer.Buffer = undefined;
    var w: gzip.Writer = .init(&member.writer, &wbuf, .{ .level = level });
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
    const m = member.written();
    try expectGzipHeader(m, level);
    try expectGzipTrailer(m, input);

    // The reader over the same member: identity, clean end, boundary.
    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    var fixed_in: Io.Reader = .fixed(m);
    const served = try gzip.Reader.streamAll(&fixed_in, &plain.writer);
    try testing.expectEqual(input.len, served);
    try testing.expectEqualSlices(u8, input, plain.written());
    try testing.expectEqual(m.len, fixed_in.seek);

    // A corrupted trailer must fail closed: a CRC byte is WrongChecksum, an
    // ISIZE byte is WrongSize — the check the format's own trailer exists for.
    var corrupted: [gzip.encode.maxCompressedLength(checksum_max) + 5 * flush_budget]u8 = undefined;
    fastmem.copy(u8, corrupted[0..m.len], m);
    const at = m.len - trailer_len + rangeAtMost(smith, 0, trailer_len - 1);
    corrupted[at] ^= flipValue(smith);
    const bad = corrupted[0..m.len];
    var plain_buf: [checksum_max + guard_len]u8 = undefined;
    sentinel.fill(&plain_buf);
    const result = gzip.decode.decompress(bad, plain_buf[0..input.len]);
    const err = if (result) |_| return error.ExpectedFailure else |e| e;
    const crc_byte = at < m.len - 4;
    if (crc_byte) {
        try testing.expectEqual(error.WrongChecksum, err);
    } else {
        try testing.expectEqual(error.WrongSize, err);
    }
    try sentinel.expect(&plain_buf, input.len);

    // The reader reports the same detail, sticky.
    var rbuf: gzip.Reader.Buffer = undefined;
    var bad_in: Io.Reader = .fixed(bad);
    var r: gzip.Reader = .init(&bad_in, &rbuf);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, pump(&r.reader, &sink.writer, pumpLimit(input.len)));
    const detail = r.err.?;
    if (crc_byte) {
        try testing.expectEqual(gzip.Reader.Error.WrongChecksum, detail);
    } else {
        try testing.expectEqual(gzip.Reader.Error.WrongSize, detail);
    }
    try expectStickyFailure(&r);
}

/// Seeds for target 6: an empty payload (the CRC-32 of nothing is 0) and a
/// phrase with matches.
const checksum_corpus: []const []const u8 = &.{
    &sliceSeed(0, ""),
    &sliceSeed(0, "checksums ride the codec boundary " ** 4),
};

test "gzip fuzz: checksum accounting" {
    try testing.fuzz({}, fuzzChecksumAccounting, .{ .corpus = checksum_corpus });
}

// ---------------------------------------------------------------------------
// Target 7: the flate checksum hook
// ---------------------------------------------------------------------------

/// The hook lane's fold state: the container's day-one kernel is std's
/// (README, "The checksums"), so the synthetic hook folds runs through a std
/// CRC-32 state and the reference is the one-shot hash over the same bytes.
const Fold = struct {
    crc: std.hash.crc.Crc32 = .init(),

    fn update(context: *anyopaque, bytes: []const u8) void {
        const self: *Fold = @ptrCast(@alignCast(context));
        self.crc.update(bytes);
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
/// on the decode side — and each digest equals the reference CRC-32 over the
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
    try testing.expectEqual(Crc32.hash(input), encode_fold.crc.final());

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
    try testing.expectEqual(Crc32.hash(input), decode_fold.crc.final());
}

test "gzip fuzz: flate checksum hook" {
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
/// so the cap boundary runs over a match-heavy and a passthrough member.
const amplification_corpus: []const []const u8 = &.{
    &shapeSeed(0, .run, 8192, &u64Le(0x41)),
    &shapeSeed(0, .phrase, 4096, &u64Le(16) ++ "0123456789abcdef"),
    &shapeSeed(2, .run, 4096, &u64Le(0x5a)),
};

/// Target 8: the amplification caps.
///
/// Attacks the two amplification rules the README states ("Sizing"): the
/// one-shot writes only into `target`, and a small member cannot buy output
/// past what the caller offered. A bomb-shaped member is decoded into a cap
/// below its decoded length — including the exact boundary `len - 1` — which
/// must fail closed with `BufferTooSmall` and leave every byte past the cap
/// untouched, then at the exact length (identity) and with slack (the guard
/// region untouched). The stored-only level decodes the same source through
/// the passthrough path, so the cap rule is not a property of the match
/// finder.
fn fuzzAmplification(_: void, smith: *Smith) anyerror!void {
    const level = smith.value(gzip.encode.Level);
    if (level == .ratio) return; // the reserved seat; target 1 covers it
    const shape = smith.value(Shape);
    var source_buf: [bomb_source_max]u8 = undefined;
    const source = source_buf[0..buildBomb(smith, shape, &source_buf)];

    var member_buf: [gzip.encode.maxCompressedLength(bomb_source_max)]u8 = undefined;
    const m_len = try gzip.encode.compress(source, &member_buf, .{ .level = level });
    const member = member_buf[0..m_len];
    try testing.expect(m_len <= gzip.encode.maxCompressedLength(source.len));
    if (level != .@"0" and shape == .run and source.len >= 1024) {
        // The bomb property, where the shape pins it: a run of at least a KiB
        // is almost all 258-byte matches, so its member is a small fraction
        // of its output and a cap that ignored the decoded length would be a
        // real overrun.
        try testing.expect(m_len * 8 <= source.len);
    }

    var window: [bomb_source_max + guard_len]u8 = undefined;

    // Below the decoded length: fail closed, nothing past the cap written.
    if (source.len > 0) {
        const caps = [_]usize{ source.len - 1, rangeAtMost(smith, 0, source.len - 1) };
        for (caps) |cap| {
            sentinel.fill(&window);
            try testing.expectError(
                error.BufferTooSmall,
                gzip.decode.decompress(member, window[0..cap]),
            );
            try sentinel.expect(&window, cap);
        }
    }

    // At the decoded length: exact, and the guard region is the caller's.
    sentinel.fill(&window);
    const n = try gzip.decode.decompress(member, window[0..source.len]);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, window[0..n]);
    try sentinel.expect(&window, n);

    // Above it: the same, with the whole window as the cap.
    sentinel.fill(&window);
    const m = try gzip.decode.decompress(member, &window);
    try testing.expectEqual(source.len, m);
    try testing.expectEqualSlices(u8, source, window[0..m]);
    try sentinel.expect(&window, m);
}

test "gzip fuzz: amplification caps" {
    try testing.fuzz({}, fuzzAmplification, .{ .corpus = amplification_corpus });
}

// ---------------------------------------------------------------------------
// Contract pins: the hostile-header first targets (T7), deterministic
// ---------------------------------------------------------------------------

// The constructed members the header parser must fail closed on, as plain
// unit tests so a normal `zig build test` run gates them too.
test "gzip fuzz: hostile-header pins" {
    // The empty member our encoder emits: FLG=0, MTIME=0, XFL=4, OS=255, the
    // final empty fixed block, CRC-32 0 and ISIZE 0 (§2.3.1).
    const empty_member = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x04\xff" ++
        "\x03\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00";

    // A zero-byte input is error.Truncated: no member began (T2/OQ3).
    try testing.expectError(error.Truncated, gzip.decode.decompress("", &.{}));

    // Every truncation — header, body, trailer — fails closed.
    var i: usize = 0;
    while (i < empty_member.len) : (i += 1) {
        try testing.expectError(
            error.Truncated,
            gzip.decode.decompress(empty_member[0..i], &.{}),
        );
    }

    // A tiny member declaring a giant XLEN: the skip runs out of input, and
    // nothing was staged (§2.3.1.1, T7).
    const giant_xlen = "\x1f\x8b\x08\x04\x00\x00\x00\x00\x00\xff\xff\xff";
    try testing.expectError(error.Truncated, gzip.decode.decompress(giant_xlen, &.{}));

    // An unterminated FNAME past the 512-byte cap: HeaderTooLong (T7).
    var name_buf: [header_len + 600]u8 = undefined;
    fastmem.copy(u8, name_buf[0..header_len], empty_member[0..header_len]);
    name_buf[3] = 0x08; // FNAME
    fastmem.set(u8, name_buf[header_len..], 'a');
    try testing.expectError(error.HeaderTooLong, gzip.decode.decompress(&name_buf, &.{}));

    // Reserved FLG bits are BadHeader (§2.3.1.2): "such a bit could indicate
    // the presence of a new field".
    for ([_]u8{ 0x20, 0x40, 0x80 }) |bit| {
        var buf: [empty_member.len]u8 = undefined;
        fastmem.copy(u8, &buf, empty_member);
        buf[3] = bit;
        try testing.expectError(error.BadHeader, gzip.decode.decompress(&buf, &.{}));
    }

    // ID1, ID2, and CM are checked (§2.3.1.2): BadHeader.
    for (0..3) |at| {
        var buf: [empty_member.len]u8 = undefined;
        fastmem.copy(u8, &buf, empty_member);
        buf[at] ^= 0xff;
        try testing.expectError(error.BadHeader, gzip.decode.decompress(&buf, &.{}));
    }

    // FHCRC (§2.3.1, T3): the low 16 bits of the header CRC-32, verified when
    // present — a right value decodes, a wrong one is WrongHeaderChecksum.
    var fhcrc: [header_len + 2 + 2 + trailer_len]u8 = undefined;
    fastmem.copy(u8, fhcrc[0..header_len], empty_member[0..header_len]);
    fhcrc[3] = 0x02; // FHCRC
    const hcrc: u16 = @truncate(Crc32.hash(fhcrc[0..header_len]));
    mem.writeInt(u16, fhcrc[header_len..][0..2], hcrc, .little);
    fastmem.copy(u8, fhcrc[header_len + 2 ..][0..2], empty_member[10..12]);
    fastmem.set(u8, fhcrc[header_len + 4 ..], 0);
    try testing.expectEqual(@as(usize, 0), try gzip.decode.decompress(&fhcrc, &.{}));
    fhcrc[header_len] ^= 0x01;
    try testing.expectError(error.WrongHeaderChecksum, gzip.decode.decompress(&fhcrc, &.{}));

    // The ignorable header fields (§2.3.1.2): MTIME, XFL, and OS flips decode
    // to the same empty payload.
    for (4..header_len) |at| {
        var buf: [empty_member.len]u8 = undefined;
        fastmem.copy(u8, &buf, empty_member);
        buf[at] ^= 0xff;
        try testing.expectEqual(@as(usize, 0), try gzip.decode.decompress(&buf, &.{}));
    }
}
