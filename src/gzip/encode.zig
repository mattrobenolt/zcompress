//! gzip.encode: the one-shot member encoder (README.md, "API").
//!
//! One complete member into a caller-provided target: the deterministic
//! 10-byte fixed header (OQ7), the deflate body through flate's one-shot
//! encoder, and the 8-byte trailer — CRC-32 of `source` per ISO 3309 and
//! ISIZE, the input length mod 2^32 (`rfc1952-gzip.txt §2.3.1`). The CRC-32
//! is hashed directly over `source` (OQ1's one-shot shape: the container
//! holds the bytes, so one pass, no flate involvement). Zero heap
//! allocation; the member is byte-identical for the same input and options.

const std = @import("std");
const testing = std.testing;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const common = @import("common.zig");
const readInt = common.readInt;
const writeInt = common.writeInt;
const flate = @import("../flate/root.zig");
const crc32 = @import("crc32.zig");
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

/// RFC 1952 §2.3 — the fixed header's length.
pub const header_len = 10;

/// RFC 1952 §2.3 — the trailer's length.
pub const trailer_len = 8;

/// The worst-case member length: the fixed header, flate's worst-case body,
/// and the fixed trailer (README, "API").
pub fn maxCompressedLength(input_len: usize) usize {
    return header_len + flate.encode.maxCompressedLength(input_len) + trailer_len;
}

/// Emit the deterministic 10-byte header (OQ7): ID1/ID2/CM fixed, FLG=0 (no
/// optional fields, reserved bits clear — `§2.3.1.2`), MTIME=0 ("no time
/// stamp is available", `§2.3.1`), XFL by level band, OS=255 (`§2.3.1.2`'s
/// "255 for OS" default; T1). All multi-byte numbers little-endian
/// (`§2.1`).
pub fn writeHeader(target: *[header_len]u8, level: Level) void {
    target[0] = 0x1f; // ID1
    target[1] = 0x8b; // ID2
    target[2] = 8; // CM: deflate
    target[3] = 0; // FLG: no optional fields, reserved bits clear
    writeInt(u32, target[4..8], 0); // MTIME
    target[8] = xflFor(level); // XFL, informational (§2.3.1)
    target[9] = 255; // OS: unknown
}

/// Emit the 8-byte trailer: CRC-32 of the uncompressed data per ISO 3309,
/// then ISIZE, the input length mod 2^32; both u32 little-endian
/// (`§2.1`, `§2.3.1`).
pub fn writeTrailer(target: *[trailer_len]u8, crc: u32, len: u32) void {
    writeInt(u32, target[0..4], crc);
    writeInt(u32, target[4..8], len);
}

/// XFL by level (`§2.3.1`: 2 = "maximum compression", 4 = "fastest
/// algorithm"): 4 for the levels that select the fast fixed-Huffman encoder
/// (`.fast`, `.@"0"`, `.@"1"`), 2 for level 9, 0 otherwise — the reference
/// lineage's bands, oracle-verified (containers-notes.md §5.5). The field is
/// informational; a decoder need not examine it (`§2.3.1.2`).
pub fn xflFor(level: Level) u8 {
    return switch (level) {
        .fast, .@"0", .@"1" => 4,
        .@"9" => 2,
        else => 0,
    };
}

/// Compress `source` as one complete gzip member into `target` and return the
/// member's length. `error.BufferTooSmall` when `target` cannot hold it (size
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
    writeTrailer(
        target[trailer_at..][0..trailer_len],
        crc32.crc32(0, source),
        @truncate(source.len),
    );
    return trailer_at + trailer_len;
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1952-gzip.txt §2.1 (byte order), §2.3
// (the member), §2.3.1 (the fixed header, XFL, OS, the trailer).
// ---------------------------------------------------------------------------

test "encode: the emitted member is the deterministic one" {
    // RFC 1952 §2.3.1 — ID1/ID2/CM fixed, FLG=0 (no optional fields,
    // reserved bits clear), MTIME=0, OS=255 (T1/OQ7); XFL is informational.
    var target: [256]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try compress(source, &target, .{});
    const member = target[0..len];

    try testing.expectEqual(@as(u8, 0x1f), member[0]);
    try testing.expectEqual(@as(u8, 0x8b), member[1]);
    try testing.expectEqual(@as(u8, 8), member[2]);
    try testing.expectEqual(@as(u8, 0), member[3]);
    try testing.expectEqual(@as(u32, 0), readInt(u32, member[4..8]));
    try testing.expectEqual(@as(u8, 4), member[8]);
    try testing.expectEqual(@as(u8, 255), member[9]);

    // §2.3.1 — the trailer is the CRC-32 of the uncompressed data (ISO 3309)
    // and ISIZE, the input size mod 2^32, both little-endian (§2.1).
    try testing.expectEqual(
        crc32.crc32(0, source),
        readInt(u32, member[len - 8 ..][0..4]),
    );
    try testing.expectEqual(
        @as(u32, @truncate(source.len)),
        readInt(u32, member[len - 4 ..][0..4]),
    );
    // The reference kernel agrees (std.hash.crc.Crc32 is the same algorithm).
    try testing.expectEqual(std.hash.crc.Crc32.hash(source), crc32.crc32(0, source));
}

test "encode: the empty member is the golden bytes" {
    // RFC 1952 §2.3.1 — an empty payload is a valid member: the fixed header,
    // the final empty fixed block (`03 00`, flate's uniform ending), and the
    // zero CRC-32 and ISIZE. The fuzz lane's hostile-header pins carry the
    // same bytes.
    var target: [maxCompressedLength(0)]u8 = undefined;
    const len = try compress("", &target, .{});
    try testing.expectEqualSlices(u8, &[_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0xff, // header
        0x03, 0x00, // final empty fixed block
        0x00, 0x00, 0x00, 0x00, // CRC-32 of nothing
        0x00, 0x00, 0x00, 0x00, // ISIZE 0
    }, target[0..len]);
}

test "encode: XFL follows the level bands" {
    // RFC 1952 §2.3.1 — XFL 4 is "compressor used fastest algorithm", 2
    // "maximum compression"; the bands follow the reference lineage
    // (containers-notes.md §5.5). `.ratio` never emits a member.
    const cases = [_]struct { level: Level, xfl: u8 }{
        .{ .level = .fast, .xfl = 4 },
        .{ .level = .@"0", .xfl = 4 },
        .{ .level = .@"1", .xfl = 4 },
        .{ .level = .@"2", .xfl = 0 },
        .{ .level = .@"8", .xfl = 0 },
        .{ .level = .@"9", .xfl = 2 },
    };
    var target: [64]u8 = undefined;
    for (cases) |case| {
        const len = try compress("x", &target, .{ .level = case.level });
        try testing.expectEqual(case.xfl, target[8]);
        try testing.expect(len > 0);
    }
}

test "encode: the ratio seat is unimplemented, never aliased" {
    // flate's reserved seat (README, "API"): `error.Unimplemented`, and no
    // member bytes are claimed.
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
    var member: [maxCompressedLength(source.len)]u8 = undefined;
    const len = try compress(source, &member, .{});

    // The exact member length fits (the body compressed under the bound).
    var exact: [maxCompressedLength(source.len) + 8]u8 = undefined;
    sentinel.fill(&exact);
    const exact_len = try compress(source, exact[0..len], .{});
    try testing.expectEqual(len, exact_len);
    try testing.expectEqualSlices(u8, member[0..len], exact[0..len]);
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

test "encode: the golden outputs re-encode to decodable members" {
    // The ported golang/go `gunzipTests` payloads: each must round-trip
    // through this module's own two halves — the container's framing must
    // not disturb the body flate's fixtures pin.
    var member: [512]u8 = undefined;
    var plain: [512]u8 = undefined;
    for (golden.gunzip_cases) |tc| {
        const source = switch (tc.expect) {
            .ok => |bytes| bytes,
            else => continue, // Reject cases have no payload to re-encode.
        };
        if (maxCompressedLength(source.len) > member.len) continue;
        const len = try compress(source, &member, .{});
        sentinel.fill(&plain);
        const decoded = try decode.decompress(member[0..len], plain[0..source.len]);
        try testing.expectEqual(source.len, decoded);
        try testing.expectEqualSlices(u8, source, plain[0..decoded]);
        try sentinel.expect(&plain, decoded);
    }
}
