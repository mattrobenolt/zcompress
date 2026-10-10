//! zlib.encode: the one-shot stream encoder (README.md, "API").
//!
//! One complete stream into a caller-provided target: the deterministic
//! 2-byte header (CM=8, CINFO=7, the level's FLEVEL band, the minimal FCHECK,
//! FDICT clear), the deflate body through flate's one-shot encoder, and the
//! 4-byte trailer — the Adler-32 of `source`, big-endian
//! (`rfc1950-zlib.txt §2.1`, `§2.2`). The Adler-32 is hashed directly over
//! `source` (OQ1's one-shot shape: the container holds the bytes, so one
//! pass, no flate involvement). Zero heap allocation; the stream is
//! byte-identical for the same input and options.

const std = @import("std");
const testing = std.testing;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const common = @import("common.zig");
const readInt = common.readInt;
const writeInt = common.writeInt;
const flate = @import("../flate/root.zig");
const adler32 = @import("adler32.zig");
const decode = @import("decode.zig");
const golden = @import("golden.zig");

/// The flate level type, re-exported: the container adds no levels of its own
/// (README, "API"). `.ratio` is flate's reserved seat — `error.Unimplemented`
/// here, never silent aliasing.
pub const Level = flate.encode.Level;

/// Encoder configuration. `.{}` is the default: the fast level.
pub const Options = struct {
    level: Level = .fast,
};

/// RFC 1950 §2.2 — the header's length: CMF and FLG.
pub const header_len = 2;

/// RFC 1950 §2.2 — the trailer's length: ADLER32.
pub const trailer_len = 4;

/// The emitted CMF: CM = 8 ("deflate", `§2.2`) in the low four bits, CINFO = 7
/// (a 32-KiB window: "the base-2 log of the window size minus eight", `§2.2`)
/// in the high four. Fixed — the encoder exposes no header knobs.
pub const cmf: u8 = 0x78;

/// The worst-case stream length: the fixed header, flate's worst-case body,
/// and the fixed trailer (README, "API").
pub fn maxCompressedLength(input_len: usize) usize {
    return header_len + flate.encode.maxCompressedLength(input_len) + trailer_len;
}

/// Emit the deterministic 2-byte header: CMF fixed, FLG carrying only the
/// level's FLEVEL band and the minimal FCHECK, FDICT clear (OQ7; `§2.2`).
pub fn writeHeader(target: *[header_len]u8, level: Level) void {
    target[0] = cmf;
    target[1] = flgFor(level);
}

/// The emitted FLG byte for `level` (`§2.2`): FLEVEL in bits 6-7, FCHECK in
/// bits 0-4, FDICT (bit 5) clear. FLEVEL's bands follow the reference
/// lineage's mapping (C zlib and Go, oracle-verified in `containers-notes.md
/// §5.5`): {0,1} → 0, {2-5} → 1, {fast, 6} → 2, {7-9} → 3. FCHECK is the
/// minimal form, `(31 - r) % 31` with `r` the remainder of `CMF*256 +
/// FLEVEL<<6` (FCHECK's five bits zero) — the emitted pair always satisfies
/// "CMF and FLG, when viewed as a 16-bit unsigned integer stored in MSB
/// order (CMF*256 + FLG), is a multiple of 31" (`§2.2`).
pub fn flgFor(level: Level) u8 {
    const flevel: u8 = switch (level) {
        .@"0", .@"1" => 0,
        .@"2", .@"3", .@"4", .@"5" => 1,
        .fast, .@"6" => 2,
        .@"7", .@"8", .@"9" => 3,
        .ratio => unreachable, // never emits a stream (README, "API")
    };
    return flevel << 6 | fcheck(flevel);
}

/// The minimal FCHECK for `flevel`: `(31 - r) % 31` with `r` the remainder of
/// the header's partial value (FCHECK's five bits zero) modulo 31 (`§2.2`).
fn fcheck(flevel: u8) u8 {
    const partial = @as(u16, cmf) * 256 + @as(u16, flevel) * 64;
    const remainder = partial % 31;
    return @intCast((31 - remainder) % 31);
}

/// Emit the 4-byte trailer: the Adler-32 of the uncompressed data (excluding
/// any dictionary data), u32 most-significant-byte first (`§2.1`, `§2.2`).
pub fn writeTrailer(target: *[trailer_len]u8, adler: u32) void {
    writeInt(u32, target[0..4], adler);
}

/// Compress `source` as one complete zlib stream into `target` and return the
/// stream's length. `error.BufferTooSmall` when `target` cannot hold it (size
/// `target` with `maxCompressedLength`; a smaller target may still fit when
/// the body compresses under the bound, and its contents are unspecified on
/// failure). `error.Unimplemented` for the reserved `.ratio` level. Zero heap
/// allocation.
pub fn compress(
    source: []const u8,
    target: []u8,
    options: Options,
) error{ BufferTooSmall, Unimplemented }!usize {
    if (options.level == .ratio) return error.Unimplemented;
    // The header is written before the body is attempted, so the check must
    // come first: a target that cannot hold even the framing is too small.
    if (target.len < header_len + trailer_len) return error.BufferTooSmall;
    writeHeader(target[0..header_len], options.level);

    const body_len = try flate.encode.compress(source, target[header_len..], .{
        .level = options.level,
    });
    const trailer_at = header_len + body_len;
    // A body that compressed under the bound can still leave no room for the
    // trailer: report that before the overflowing write, never after.
    if (target.len - trailer_at < trailer_len) return error.BufferTooSmall;
    var trailer: [trailer_len]u8 = undefined;
    writeTrailer(&trailer, adler32.adler32(1, source));
    fastmem.copy(u8, target[trailer_at..][0..trailer_len], &trailer);
    return trailer_at + trailer_len;
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1950-zlib.txt §2.1 (byte order), §2.2
// (the header, the trailer, FCHECK, FLEVEL), §2.3 (decoder obligations).
// ---------------------------------------------------------------------------

test "encode: the emitted stream is the deterministic one" {
    // RFC 1950 §2.2 — CMF: CM=8 ("deflate"), CINFO=7 (a 32-KiB window);
    // FLG: FLEVEL by band, the minimal FCHECK, FDICT clear. The pair is a
    // multiple of 31 as one MSB-order u16 (§2.2).
    var target: [256]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try compress(source, &target, .{});
    const stream = target[0..len];

    try testing.expectEqual(@as(u8, 0x78), stream[0]);
    try testing.expectEqual(@as(u8, 0x9c), stream[1]); // FLEVEL 2, FCHECK 28
    const header = @as(u16, stream[0]) * 256 + @as(u16, stream[1]);
    try testing.expectEqual(@as(u16, 0), header % 31);
    try testing.expectEqual(@as(u8, 0), stream[1] & 0x20); // FDICT clear

    // §2.2 — the trailer is the Adler-32 of the uncompressed data, stored
    // most-significant-byte first (§2.1). The reference kernel agrees.
    try testing.expectEqual(
        std.hash.Adler32.hash(source),
        readInt(u32, stream[len - trailer_len ..][0..4]),
    );
    try testing.expectEqual(
        adler32.adler32(1, source),
        readInt(u32, stream[len - trailer_len ..][0..4]),
    );
}

test "encode: the empty stream is the golden bytes" {
    // RFC 1950 §2.2 — an empty payload is a valid stream: the header, the
    // final empty fixed block (`03 00`, flate's uniform ending), and the
    // Adler-32 of nothing, 1. The fuzz lane's hostile-header pins carry the
    // same bytes; Go's `zlibTests` "empty" vector is byte-identical.
    var target: [maxCompressedLength(0)]u8 = undefined;
    const len = try compress("", &target, .{});
    try testing.expectEqualSlices(u8, &[_]u8{
        0x78, 0x9c, // header: CM=8, CINFO=7, FLEVEL 2, FCHECK 28
        0x03, 0x00, // final empty fixed block
        0x00, 0x00, 0x00, 0x01, // Adler-32 of nothing
    }, target[0..len]);
}

test "encode: FLEVEL follows the level bands" {
    // RFC 1950 §2.2 — FLEVEL is informational ("not needed for
    // decompression"); the bands follow the reference lineage
    // (containers-notes.md §5.5, oracle-verified): {0,1} -> 0, {2-5} -> 1,
    // {fast, 6} -> 2, {7-9} -> 3. The oracle emits 78 01 at level 0/1,
    // 78 9c at level 6, 78 da at level 9. `.ratio` never emits a stream.
    const cases = [_]struct { level: Level, flg: u8 }{
        .{ .level = .fast, .flg = 0x9c },
        .{ .level = .@"0", .flg = 0x01 },
        .{ .level = .@"1", .flg = 0x01 },
        .{ .level = .@"2", .flg = 0x5e },
        .{ .level = .@"5", .flg = 0x5e },
        .{ .level = .@"6", .flg = 0x9c },
        .{ .level = .@"7", .flg = 0xda },
        .{ .level = .@"9", .flg = 0xda },
    };
    var target: [64]u8 = undefined;
    for (cases) |case| {
        const len = try compress("x", &target, .{ .level = case.level });
        try testing.expectEqual(case.flg, target[1]);
        const header = @as(u16, target[0]) * 256 + @as(u16, target[1]);
        try testing.expectEqual(@as(u16, 0), header % 31);
        try testing.expectEqual(@as(u8, 0), target[1] & 0x20);
        try testing.expect(len > 0);
    }
}

test "encode: the ratio seat is unimplemented, never aliased" {
    // flate's reserved seat (README, "API"): `error.Unimplemented`, and no
    // stream bytes are claimed.
    var target: [64]u8 = undefined;
    sentinel.fill(&target);
    try testing.expectError(error.Unimplemented, compress("x", &target, .{ .level = .ratio }));
    try sentinel.expect(&target, 0);
}

test "encode: a small target fails closed, an exact one fits" {
    // README, "Contracts": a target smaller than `maxCompressedLength` may
    // still fit; when it does not, `error.BufferTooSmall` and `target`'s
    // contents are unspecified. Nothing is ever written past the target.
    const source = "hello world\n";
    var stream: [maxCompressedLength(source.len)]u8 = undefined;
    const len = try compress(source, &stream, .{});

    // The exact stream length fits (the body compressed under the bound).
    var exact: [maxCompressedLength(source.len) + 8]u8 = undefined;
    sentinel.fill(&exact);
    const exact_len = try compress(source, exact[0..len], .{});
    try testing.expectEqual(len, exact_len);
    try testing.expectEqualSlices(u8, stream[0..len], exact[0..len]);
    // The trailing sentinels are untouched: no write past the target.
    try sentinel.expect(&exact, len);

    // One byte short: BufferTooSmall, and the sentinel past the target holds.
    var short: [maxCompressedLength(source.len) + 8]u8 = undefined;
    sentinel.fill(&short);
    try testing.expectError(error.BufferTooSmall, compress(source, short[0 .. len - 1], .{}));
    try sentinel.expect(&short, len - 1);

    // Too small for even the framing.
    var tiny: [header_len + trailer_len - 1]u8 = undefined;
    sentinel.fill(&tiny);
    try testing.expectError(error.BufferTooSmall, compress(source, &tiny, .{}));
    try sentinel.expect(&tiny, 0);
}

test "encode: the bound holds for every shape" {
    // README, "API": `compress` never expands past `maxCompressedLength`.
    // Random bytes take the stored fallback, runs the match finder.
    const cases = [_][]const u8{
        "",
        "a",
        "hello world\n",
        "the quick brown fox jumps over the lazy dog. " ** 100,
        "\x00\x01\x02\x03\x04\x05\x06\x07" ** 64,
    };
    for (cases) |source| {
        const target = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
        defer testing.allocator.free(target);
        var rng: std.Random.DefaultPrng = .init(0xC0FFEE);
        for (target) |*byte| byte.* = rng.random().int(u8);
        const len = try compress(source, target, .{});
        try testing.expect(len <= maxCompressedLength(source.len));
    }
    // A single-byte run of every block-split size: the bound is tight at the
    // stored fallback's worst case.
    const run = try testing.allocator.alloc(u8, 3 * 65535 + 17);
    defer testing.allocator.free(run);
    fastmem.set(u8, run, 0x41);
    const target = try testing.allocator.alloc(u8, maxCompressedLength(run.len));
    defer testing.allocator.free(target);
    const len = try compress(run, target, .{ .level = .@"0" });
    try testing.expectEqual(maxCompressedLength(run.len), len);
}

test "encode: the golden payloads re-encode to decodable streams" {
    // The ported golang/go and std payloads: each must round-trip through
    // this module's own two halves — the container's framing must not
    // disturb the body flate's fixtures pin.
    var stream: [512]u8 = undefined;
    var plain: [512]u8 = undefined;
    for (golden.zlib_cases) |tc| {
        const source = switch (tc.expect) {
            .ok => |bytes| bytes,
            else => continue, // Reject cases have no payload to re-encode.
        };
        if (maxCompressedLength(source.len) > stream.len) continue;
        const len = try compress(source, &stream, .{});
        sentinel.fill(&plain);
        const decoded = try decode.decompress(stream[0..len], plain[0..source.len]);
        try testing.expectEqual(source.len, decoded);
        try testing.expectEqualSlices(u8, source, plain[0..decoded]);
        try sentinel.expect(&plain, decoded);
    }
}
