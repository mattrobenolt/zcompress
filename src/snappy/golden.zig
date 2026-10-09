//! Golden decode fixtures ported from golang/snappy (BSD-3-Clause)
//! `decode_test.go` — attribution in THIRD_PARTY.md. The fixtures and their
//! block-level checks live here, shared by the block-level tests (decode.zig)
//! and the streaming-layer tests (Reader.zig/Writer.zig): the golden table,
//! the copy-4 large-offset case, and the exhaustive length x offset x suffix
//! sweep. Every layer is validated against the same reference vectors.

const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

const common = @import("common.zig");
const readUvarint = common.readUvarint;
const writeUvarint = common.writeUvarint;

const fastmem = @import("fastmem");

const decode = @import("decode.zig");
const decompressBlock = decode.decompressBlock;
const readInt = common.readInt;

/// Sentinel byte range [0xa0, 0xc5) used to detect decoder overrun: the output
/// buffer is pre-filled with these (cycling), and after decode every byte past
/// `dLen` must be untouched. 37 is prime so a mis-copied byte lands at an
/// unrelated offset (a 'natural' 32 could mask a 4*8-byte-off copy). This
/// matches golang/snappy's notPresentBase/notPresentLen.
const overrun_base: u8 = 0xa0;
const overrun_len: u8 = 37;

/// One decode test case: `source` is a raw snappy block (varint dLen + tags),
/// `want` is the expected decompressed bytes (empty when expecting an error),
/// and `want_err` is true when the source must be rejected as corrupt.
pub const DecodeCase = struct {
    desc: []const u8,
    source: []const u8,
    want: []const u8,
    want_err: bool,
};

/// Run one decode case against `decompressBlock`, checking the decoded bytes
/// and that no byte past dLen in `d_buf` was modified (overrun check).
fn checkDecodeCase(d_buf: []u8, tc: DecodeCase) !void {
    // The source must not contain the sentinel bytes, or the overrun check is
    // meaningless. (All golang vectors satisfy this by construction.)
    for (tc.source) |x| {
        try testing.expect(!(overrun_base <= x and x < overrun_base + overrun_len));
    }

    // Pre-fill d_buf with the cycling sentinel.
    for (d_buf, 0..) |*b, j| b.* = overrun_base + @as(u8, @intCast(j % overrun_len));

    // dLen is the leading varint; size the output window to it.
    var vp: usize = 0;
    const d_len = try readUvarint(tc.source, &vp);
    try testing.expect(d_len <= d_buf.len);

    if (tc.want_err) {
        try testing.expectError(
            error.DecompressionFailed,
            decompressBlock(tc.source, d_buf[0..d_len]),
        );
        return;
    }

    const n = try decompressBlock(tc.source, d_buf[0..d_len]);
    try testing.expectEqualSlices(u8, tc.want, d_buf[0..n]);

    // Overrun: every byte from dLen onward must still hold its sentinel.
    for (d_buf[d_len..], 0..) |x, j| {
        try testing.expectEqual(overrun_base + @as(u8, @intCast((d_len + j) % overrun_len)), x);
    }
}

/// The golang/snappy `TestDecode` golden vector table, ported verbatim from
/// `decode_test.go` (attribution in THIRD_PARTY.md). Shared by the block-level
/// tests here and the streaming-layer tests in `Reader.zig`/`Writer.zig`.
pub const golden_decode_cases: [30]DecodeCase = table_blk: {
    // lit40 = 40 bytes 0..39, used by the length=40 literal case.
    @setEvalBranchQuota(1000);
    var lit40: [40]u8 = undefined;
    for (&lit40, 0..) |*b, i| b.* = @intCast(i);
    // A container-level const cannot reference the comptime var: take a
    // const copy for the fields that embed it.
    const lit40_const: [40]u8 = lit40;

    break :table_blk [_]DecodeCase{
        .{
            .desc = "dLen=0; valid",
            .source = "\x00",
            .want = "",
            .want_err = false,
        },
        .{
            .desc = "dLen=3; lit 0-byte len; valid",
            .source = "\x03\x08\xff\xff\xff",
            .want = "\xff\xff\xff",
            .want_err = false,
        },
        .{
            .desc = "dLen=2; lit 0-byte len; not enough dst",
            .source = "\x02\x08\xff\xff\xff",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=3; lit 0-byte len; not enough src",
            .source = "\x03\x08\xff\xff",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=40; lit 0-byte len; valid",
            .source = blk: {
                var b: [42]u8 = undefined;
                b[0] = 0x28;
                b[1] = 0x9c;
                @memcpy(b[2..][0..lit40_const.len], &lit40_const);
                const source: [42]u8 = b;
                break :blk &source;
            },
            .want = &lit40_const,
            .want_err = false,
        },
        .{
            .desc = "dLen=1; lit 1-byte len; truncated",
            .source = "\x01\xf0",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=3; lit 1-byte len; valid",
            .source = "\x03\xf0\x02\xff\xff\xff",
            .want = "\xff\xff\xff",
            .want_err = false,
        },
        .{
            .desc = "dLen=1; lit 2-byte len; truncated",
            .source = "\x01\xf4\x00",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=3; lit 2-byte len; valid",
            .source = "\x03\xf4\x02\x00\xff\xff\xff",
            .want = "\xff\xff\xff",
            .want_err = false,
        },
        .{
            .desc = "dLen=1; lit 3-byte len; truncated",
            .source = "\x01\xf8\x00\x00",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=3; lit 3-byte len; valid",
            .source = "\x03\xf8\x02\x00\x00\xff\xff\xff",
            .want = "\xff\xff\xff",
            .want_err = false,
        },
        .{
            .desc = "dLen=1; lit 4-byte len; truncated",
            .source = "\x01\xfc\x00\x00\x00",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=1; lit 4-byte len; not enough dst",
            .source = "\x01\xfc\x02\x00\x00\x00\xff\xff\xff",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=4; lit 4-byte len; not enough src",
            .source = "\x04\xfc\x02\x00\x00\x00\xff",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=3; lit 4-byte len; valid",
            .source = "\x03\xfc\x02\x00\x00\x00\xff\xff\xff",
            .want = "\xff\xff\xff",
            .want_err = false,
        },
        .{
            .desc = "dLen=4; copy1; truncated extra",
            .source = "\x04\x01",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=4; copy2; truncated extra",
            .source = "\x04\x02\x00",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=4; copy4; truncated extra",
            .source = "\x04\x03\x00\x00\x00",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=4; lit 'abcd'; valid",
            .source = "\x04\x0cabcd",
            .want = "abcd",
            .want_err = false,
        },
        .{
            .desc = "dLen=13; lit abcd; copy1 len9 off4",
            .source = "\x0d\x0cabcd\x15\x04",
            .want = "abcdabcdabcda",
            .want_err = false,
        },
        .{
            .desc = "dLen=8; lit abcd; copy1 len4 off4",
            .source = "\x08\x0cabcd\x01\x04",
            .want = "abcdabcd",
            .want_err = false,
        },
        .{
            .desc = "dLen=8; lit abcd; copy1 len4 off2",
            .source = "\x08\x0cabcd\x01\x02",
            .want = "abcdcdcd",
            .want_err = false,
        },
        .{
            .desc = "dLen=8; lit abcd; copy1 len4 off1",
            .source = "\x08\x0cabcd\x01\x01",
            .want = "abcddddd",
            .want_err = false,
        },
        .{
            .desc = "dLen=8; lit abcd; copy1 len4 off0; zero offset",
            .source = "\x08\x0cabcd\x01\x00",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=9; lit abcd; copy1 len4 off4; bad dLen",
            .source = "\x09\x0cabcd\x01\x04",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=8; lit abcd; copy1 len4 off5; offset too large",
            .source = "\x08\x0cabcd\x01\x05",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=7; lit abcd; copy1 len4 off4; length too large",
            .source = "\x07\x0cabcd\x01\x04",
            .want = "",
            .want_err = true,
        },
        .{
            .desc = "dLen=6; lit abcd; copy2 len2 off3",
            .source = "\x06\x0cabcd\x06\x03\x00",
            .want = "abcdbc",
            .want_err = false,
        },
        .{
            .desc = "dLen=6; lit abcd; copy4 len2 off3",
            .source = "\x06\x0cabcd\x07\x03\x00\x00\x00",
            .want = "abcdbc",
            .want_err = false,
        },
        .{
            .desc = "dLen=0; copy4; msb set (0x93); go-fuzz",
            .source = "\x00\xfc000\x93",
            .want = "",
            .want_err = true,
        },
    };
};

test "golden decode: golang/snappy TestDecode vector table" {
    var d_buf: [100]u8 = undefined;
    for (golden_decode_cases) |tc| {
        checkDecodeCase(&d_buf, tc) catch |err| {
            print("\nFAIL: {s}\n", .{tc.desc});
            return err;
        };
    }
}

test "golden decode: large copy-4 offset (golang TestDecodeCopy4)" {
    // decodedLen=65545: a 4-byte literal "pqrs", a 65536-byte literal of '.',
    // then a copy-4 of length 5 offset 65540 (back into the start). Exercises
    // the 4-byte-offset copy with a real large offset and a 64KiB literal.
    const dots_len: usize = 65536;
    const total: usize = 3 + 5 + (3 + dots_len) + 5; // varint(65545)=3, lit pqrs, lit dots, copy4
    const source = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(source);
    var p: usize = 0;
    // varint 65545 = 0x89 0x80 0x04
    source[p] = 0x89;
    source[p + 1] = 0x80;
    source[p + 2] = 0x04;
    p += 3;
    // literal "pqrs" (length 4 -> tag (4-1)<<2 = 0x0c)
    source[p] = 0x0c;
    fastmem.copy(u8, source[p + 1 ..][0..4], "pqrs");
    p += 5;
    // literal 65536 '.' (length 65536 -> 2-byte extended: tag 0xf4, len-1 LE)
    source[p] = 0xf4;
    const n: u32 = @intCast(dots_len - 1);
    source[p + 1] = @truncate(n);
    source[p + 2] = @truncate(n >> 8);
    p += 3;
    fastmem.set(u8, source[p..][0..dots_len], '.');
    p += dots_len;
    // copy-4: length 5, offset 65540. tag = ((5-1)<<2)|0b11 = 0x13.
    // offset 65540 = 0x00010004 LE.
    source[p] = 0x13;
    source[p + 1] = 0x04;
    source[p + 2] = 0x00;
    source[p + 3] = 0x01;
    source[p + 4] = 0x00;
    p += 5;
    try testing.expectEqual(total, p);

    const d_len: usize = 65545;
    const target = try testing.allocator.alloc(u8, d_len);
    defer testing.allocator.free(target);
    const got = try decompressBlock(source, target);
    try testing.expectEqual(d_len, got);
    // want = "pqrs" + dots + "pqrs."
    try testing.expectEqualSlices(u8, "pqrs", target[0..4]);
    for (target[4..][0..dots_len]) |b| try testing.expectEqual(@as(u8, '.'), b);
    try testing.expectEqualSlices(u8, "pqrs.", target[4 + dots_len ..][0..5]);
}

test "golden decode: literal + copy2 + literal (golang TestDecodeLengthOffset)" {
    // Exhaustive sweep over length, offset, suffixLen (1..18 each) of a
    // literal(prefix) + copy2(length, offset) + literal(suffix) pattern, with
    // the overrun check. This stresses copyMatch across every small offset
    // and length combination, including overlapping (offset < length) RLE.
    const prefix = "abcdefghijklmnopqr"; // 18 bytes
    const suffix = "ABCDEFGHIJKLMNOPQR"; // 18 bytes
    var got_buf: [128]u8 = undefined;
    var want_buf: [128]u8 = undefined;
    var input_buf: [128]u8 = undefined;

    for (1..19) |length| {
        for (1..19) |offset| {
            for (0..19) |suffix_len| {
                const total_len = prefix.len + length + suffix_len;

                // Build the source block: varint(total_len) + literal(prefix)
                // + copy2(length, offset) + [literal(suffix)].
                var p: usize = 0;
                p += writeUvarint(input_buf[p..], total_len) catch unreachable;
                input_buf[p] = @as(u8, @intCast(prefix.len - 1)) << 2; // tagLiteral
                p += 1;
                fastmem.copy(u8, input_buf[p..][0..prefix.len], prefix);
                p += prefix.len;
                input_buf[p] = @as(u8, @intCast(length - 1)) << 2 | 0b10; // tagCopy2
                input_buf[p + 1] = @truncate(@as(u32, @intCast(offset)));
                input_buf[p + 2] = 0x00;
                p += 3;
                if (suffix_len > 0) {
                    input_buf[p] = @as(u8, @intCast(suffix_len - 1)) << 2; // tagLiteral
                    p += 1;
                    fastmem.copy(u8, input_buf[p..][0..suffix_len], suffix[0..suffix_len]);
                    p += suffix_len;
                }
                const source = input_buf[0..p];

                // Pre-fill got_buf with sentinels and decode.
                for (&got_buf, 0..) |*b, j| b.* = overrun_base +
                    @as(u8, @intCast(j % overrun_len));
                const n = decompressBlock(source, got_buf[0..total_len]) catch |err| {
                    print("\nFAIL length={d} offset={d} suffixLen={d}: {s}\n", .{
                        length, offset, suffix_len, @errorName(err),
                    });
                    return err;
                };

                // Build the expected output: prefix + (length bytes copied
                // from offset back) + suffix.
                var w: usize = 0;
                fastmem.copy(u8, want_buf[w..][0..prefix.len], prefix);
                w += prefix.len;
                for (0..length) |i| {
                    want_buf[w + i] = want_buf[w + i - offset];
                }
                w += length;
                fastmem.copy(u8, want_buf[w..][0..suffix_len], suffix[0..suffix_len]);
                w += suffix_len;
                try testing.expectEqualSlices(u8, want_buf[0..w], got_buf[0..n]);

                // Overrun check: bytes past total_len must be untouched.
                for (got_buf[total_len..], 0..) |x, j| {
                    try testing.expectEqual(
                        overrun_base + @as(u8, @intCast((total_len + j) % overrun_len)),
                        x,
                    );
                }
            }
        }
    }
}
