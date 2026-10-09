//! Golden decode fixtures ported from golang/go (BSD-3-Clause; attribution in
//! THIRD_PARTY.md) plus RFC 1951's own micro-examples. Shared by every layer's
//! tests, the snappy pattern: `decode.zig` owns the decoder, this module owns
//! the reference vectors it is judged against.
//!
//! Sources:
//!   - `flate_test.go` `TestStreams` (28 hex vectors) and `TestTruncatedStreams`
//!   - `inflate_test.go` `TestReaderTruncated` (10 vectors)
//!   - `deflate_test.go` `deflateTests` (15 rows, as decode goldens)
//!   - `testdata/huffman-*` `.in`/`.golden` pairs (9)
//!   - `docs/research/flate-notes.md` §3.2's two oracle-verified micro-streams
//!     (the T1 extra-bit-order proof) and RFC 1951 §3.2.3/§3.2.4/§3.2.7
//!     micro-examples.
//!
//! Every decode here is checked against the sentinel overrun rule: the target
//! is pre-filled with cycling sentinel bytes, decoded into twice — once with a
//! target of exactly the decoded length (any overrun is then an out-of-bounds
//! write) and once with slack (the bytes past the decoded length must still
//! hold their sentinels).

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const print = std.debug.print;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const decode = @import("decode.zig");
const decompress = decode.decompress;
const DecompressError = decode.DecompressError;

/// Comptime hex decoding, so the ported vectors keep golang/go's own hexstring
/// spelling instead of a byte-list transcription.
fn hex(comptime text: []const u8) [text.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    comptime assert(text.len % 2 == 0);
    var bytes: [text.len / 2]u8 = undefined;
    for (&bytes, 0..) |*b, i| {
        b.* = std.fmt.parseInt(u8, text[i * 2 ..][0..2], 16) catch unreachable;
    }
    return bytes;
}

/// What a golden stream must do.
pub const Expect = union(enum) {
    /// Decode to exactly these bytes.
    ok: []const u8,
    /// Reject the stream with any `DecompressError`.
    fail,
    /// Reject the stream with this specific error (the README's decided rules
    /// pin these; the rest only have to fail, as in Go's own test).
    fail_with: DecompressError,
};

/// One `TestStreams` vector: Go's `desc`, `stream`, and `want`.
pub const StreamCase = struct {
    desc: []const u8,
    source: []const u8,
    expect: Expect,
};

/// One `TestReaderTruncated` vector: a truncated stream and the bytes the
/// decoder must have produced before it failed.
pub const TruncatedCase = struct {
    source: []const u8,
    partial: []const u8,
};

/// One `deflateTests` row, as a decode golden.
pub const DeflateCase = struct {
    /// Go's `out`: a complete raw deflate stream.
    source: []const u8,
    /// Go's `in`: what it decodes to.
    want: []const u8,
};

/// One RFC 1951 or flate-notes micro-example.
pub const MicroCase = struct {
    desc: []const u8,
    source: []const u8,
    want: []const u8,
};

/// One `testdata/huffman-*` pair.
pub const HuffmanFixture = struct {
    name: []const u8,
    /// The uncompressed input (`.in`).
    input: []const u8,
    /// Go's `writeBlockHuff(false, ...)` output (`.golden`): a single
    /// Huffman/stored block with BFINAL clear, so verbatim it is a truncated
    /// stream.
    golden: []const u8,
};

/// Decode `source` into `target` (sentinel-filled) twice: exact-cap first, so
/// any write past the decoded length is an out-of-bounds write, then with
/// slack, to prove the bytes past the decoded length are untouched.
fn checkDecode(target: []u8, source: []const u8, want: []const u8) !void {
    try testing.expect(want.len <= target.len);

    sentinel.fill(target);
    const exact = try decompress(source, target[0..want.len]);
    try testing.expectEqual(want.len, exact);
    try testing.expectEqualSlices(u8, want, target[0..exact]);

    sentinel.fill(target);
    const n = try decompress(source, target);
    try testing.expectEqualSlices(u8, want, target[0..n]);
    try sentinel.expect(target, n);
}

fn checkStreamCase(target: []u8, tc: StreamCase) !void {
    sentinel.fill(target);
    const result = decompress(tc.source, target);
    switch (tc.expect) {
        .ok => |want| {
            const n = result catch |err| {
                print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
                return err;
            };
            try testing.expectEqualSlices(u8, want, target[0..n]);
            try sentinel.expect(target, n);
        },
        .fail => if (result) |n| {
            print("\nFAIL ({s}): expected a decode error, got {d} bytes\n", .{ tc.desc, n });
            return error.TestUnexpectedResult;
        } else |_| {},
        .fail_with => |want_err| {
            if (result) |n| {
                print("\nFAIL ({s}): expected {s}, decoded {d} bytes\n", .{
                    tc.desc, @errorName(want_err), n,
                });
                return error.TestUnexpectedResult;
            } else |err| {
                if (err != want_err) {
                    print("\nFAIL ({s}): {s}, want {s}\n", .{
                        tc.desc, @errorName(err), @errorName(want_err),
                    });
                    return err;
                }
            }
        },
    }
}

/// golang/go `flate_test.go` `TestStreams`, ported verbatim (BSD-3-Clause;
/// THIRD_PARTY.md). The hex strings are Go's own. `.expect` is what the
/// stream must do here: the `"fail"` rows carry the specific error the
/// README's decided rules pin where they pin one (the T2/T3 corners), and
/// plain `.fail` where any `DecompressError` is acceptable (Go asserts only
/// that the stream is rejected).
pub const stream_cases: [28]StreamCase = .{
    .{
        .desc = "degenerate HCLenTree",
        .source = &hex("05e0010000000000100000000000000000000000000000000000000000000000" ++
            "00000000000000000004"),
        .expect = .{ .fail_with = error.InvalidCode },
    },
    .{
        .desc = "complete HCLenTree, empty HLitTree, empty HDistTree",
        .source = &hex("05e0010400000000000000000000000000000000000000000000000000000000" ++
            "00000000000000000010"),
        .expect = .{ .fail_with = error.MissingEndOfBlockCode },
    },
    .{
        .desc = "empty HCLenTree",
        .source = &hex("05e0010000000000000000000000000000000000000000000000000000000000" ++
            "00000000000000000010"),
        .expect = .{ .fail_with = error.InvalidDynamicBlockHeader },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree, empty HDistTree, use missing HDist symbol",
        .source = &hex("000100feff000de0010400000000100000000000000000000000000000000000" ++
            "0000000000000000000000000000002c"),
        .expect = .{ .fail_with = error.InvalidCode },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree, degenerate HDistTree, use" ++
            "missing HDist symbol",
        .source = &hex("000100feff000de0010000000000000000000000000000000000000000000000" ++
            "00000000000000000610000000004070"),
        .expect = .{ .fail_with = error.InvalidDynamicBlockHeader },
    },
    .{
        .desc = "complete HCLenTree, empty HLitTree, empty HDistTree",
        .source = &hex("05e0010400000000100400000000000000000000000000000000000000000000" ++
            "0000000000000000000000000008"),
        .expect = .{ .fail_with = error.MissingEndOfBlockCode },
    },
    .{
        .desc = "complete HCLenTree, empty HLitTree, degenerate HDistTree",
        .source = &hex("05e0010400000000100400000000000000000000000000000000000000000000" ++
            "0000000000000000000800000008"),
        .expect = .{ .fail_with = error.MissingEndOfBlockCode },
    },
    .{
        .desc = "complete HCLenTree, degenerate HLitTree, degenerate HDistTree, use" ++
            "missing HLit symbol",
        .source = &hex("05e0010400000000100000000000000000000000000000000000000000000000" ++
            "0000000000000000001c"),
        .expect = .{ .fail_with = error.InvalidCode },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree, too large HDistTree",
        .source = &hex("edff870500000000200400000000000000000000000000000000000000000000" ++
            "000000000000000000080000000000000004"),
        .expect = .{ .fail_with = error.InvalidDynamicBlockHeader },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree, empty HDistTree, excessive repeater code",
        .source = &hex("edfd870500000000200400000000000000000000000000000000000000000000" ++
            "000000000000000000e8b100"),
        .expect = .{ .fail_with = error.InvalidDynamicBlockHeader },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree, empty HDistTree of normal length 30",
        .source = &hex("05fd01240000000000f8ffffffffffffffffffffffffffffffffffffffffffff" ++
            "ffffffffffffffffff07000000fe01"),
        .expect = .{ .ok = &hex("") },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree, empty HDistTree of excessive length 31",
        .source = &hex("05fe01240000000000f8ffffffffffffffffffffffffffffffffffffffffffff" ++
            "ffffffffffffffffff07000000fc03"),
        .expect = .{ .fail_with = error.InvalidDynamicBlockHeader },
    },
    .{
        .desc = "complete HCLenTree, over-subscribed HLitTree, empty HDistTree",
        .source = &hex("05e001240000000000fcffffffffffffffffffffffffffffffffffffffffffff" ++
            "ffffffffffffffffff07f00f"),
        .expect = .{ .fail_with = error.OversubscribedHuffmanTree },
    },
    .{
        .desc = "complete HCLenTree, under-subscribed HLitTree, empty HDistTree",
        .source = &hex("05e001240000000000fcffffffffffffffffffffffffffffffffffffffffffff" ++
            "fffffffffcffffffff07f00f"),
        .expect = .{ .fail_with = error.IncompleteHuffmanTree },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree with single code, empty HDistTree",
        .source = &hex("05e001240000000000f8ffffffffffffffffffffffffffffffffffffffffffff" ++
            "ffffffffffffffffff07f00f"),
        .expect = .{ .ok = &hex("01") },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree with multiple codes, empty HDistTree",
        .source = &hex("05e301240000000000f8ffffffffffffffffffffffffffffffffffffffffffff" ++
            "ffffffffffffffffff07807f"),
        .expect = .{ .ok = &hex("01") },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree, degenerate HDistTree, use valid" ++
            "HDist symbol",
        .source = &hex("000100feff000de0010400000000100000000000000000000000000000000000" ++
            "0000000000000000000000000000003c"),
        .expect = .{ .ok = &hex("00000000") },
    },
    .{
        .desc = "complete HCLenTree, degenerate HLitTree, degenerate HDistTree",
        .source = &hex("05e0010400000000100000000000000000000000000000000000000000000000" ++
            "0000000000000000000c"),
        .expect = .{ .ok = &hex("") },
    },
    .{
        .desc = "complete HCLenTree, degenerate HLitTree, empty HDistTree",
        .source = &hex("05e0010400000000100000000000000000000000000000000000000000000000" ++
            "00000000000000000004"),
        .expect = .{ .ok = &hex("") },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree, empty HDistTree, spanning repeater code",
        .source = &hex("edfd870500000000200400000000000000000000000000000000000000000000" ++
            "000000000000000000e8b000"),
        .expect = .{ .ok = &hex("") },
    },
    .{
        .desc = "complete HCLenTree with length codes, complete HLitTree, empty HDistTree",
        .source = &hex("ede0010400000000100000000000000000000000000000000000000000000000" ++
            "0000000000000000000400004000"),
        .expect = .{ .ok = &hex("") },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree, degenerate HDistTree, use valid" ++
            "HLit symbol 284 with count 31",
        .source = &hex("000100feff00ede0010400000000100000000000000000000000000000000000" ++
            "000000000000000000000000000000040000407f00"),
        .expect = .{ .ok = &hex("000000000000000000000000000000000000000000000000000000000000" ++
            "000000000000000000000000000000000000000000000000000000000000" ++
            "000000000000000000000000000000000000000000000000000000000000" ++
            "000000000000000000000000000000000000000000000000000000000000" ++
            "000000000000000000000000000000000000000000000000000000000000" ++
            "000000000000000000000000000000000000000000000000000000000000" ++
            "000000000000000000000000000000000000000000000000000000000000" ++
            "000000000000000000000000000000000000000000000000000000000000" ++
            "00000000000000000000000000000000000000") },
    },
    .{
        .desc = "complete HCLenTree, complete HLitTree, degenerate HDistTree, use valid" ++
            "HLit and HDist symbols",
        .source = &hex("0cc2010d00000082b0ac4aff0eb07d27060000ffff"),
        .expect = .{ .ok = &hex("616263616263") },
    },
    .{
        .desc = "fixed block, use reserved symbol 287",
        .source = &hex("33180700"),
        .expect = .{ .fail_with = error.InvalidCode },
    },
    .{
        .desc = "raw block",
        .source = &hex("010100feff11"),
        .expect = .{ .ok = &hex("11") },
    },
    .{
        .desc = "issue 10426 - over-subscribed HCLenTree causes a hang",
        .source = &hex("344c4a4e494d4b070000ff2e2eff2e2e2e2e2eff"),
        .expect = .{ .fail_with = error.OversubscribedHuffmanTree },
    },
    .{
        .desc = "issue 11030 - empty HDistTree unexpectedly leads to error",
        .source = &hex("05c0070600000080400fff37a0ca"),
        .expect = .{ .ok = &hex("") },
    },
    .{
        .desc = "issue 11033 - empty HDistTree unexpectedly leads to error",
        .source = &hex("050fb109c020cca5d017dcbca044881ee1034ec149c8980bbc413c2ab35be9dc" ++
            "b1473449922449922411202306ee97b0383a521b4ffdcf3217f9f7d3adb701"),
        .expect = .{ .ok = &hex("3130303634342068652e706870005d05355f7ed957ff084a90925d19e3eb" ++
            "c6d0c6d7") },
    },
};
/// golang/go `deflate_test.go` `deflateTests`, ported as *decode* goldens
/// (BSD-3-Clause; THIRD_PARTY.md): every `source` (Go's `out`) is a valid
/// stream that must decode to `want` (Go's `in`). As encoder goldens they
/// assert Go's heuristics and do not port — deflate mandates no canonical
/// compressed form. The level comments are Go's own, kept for provenance.
pub const deflate_cases: [15]DeflateCase = .{
    // Go level: []byte{}, 0, []byte{
    .{ .source = &hex("0300"), .want = &hex("") },
    // Go level: BestCompression, []byte{
    .{ .source = &hex("12040c00"), .want = &hex("11") },
    // Go level: BestCompression, []byte{
    .{ .source = &hex("12040c00"), .want = &hex("11") },
    // Go level: BestCompression, []byte{
    .{ .source = &hex("12040c00"), .want = &hex("11") },
    // Go level: 0, []byte{
    .{ .source = &hex("000100feff110300"), .want = &hex("11") },
    // Go level: 0, []byte{
    .{ .source = &hex("000200fdff11120300"), .want = &hex("1112") },
    // Go level: 0,[]byte{
    .{ .source = &hex("000800f7ff11111111111111110300"), .want = &hex("1111111111111111") },
    // Go level: []byte{}, 1, []byte{
    .{ .source = &hex("0300"), .want = &hex("") },
    // Go level: BestCompression, []byte{
    .{ .source = &hex("12040c00"), .want = &hex("11") },
    // Go level: BestCompression, []byte{
    .{ .source = &hex("1214020c00"), .want = &hex("1112") },
    // Go level: BestCompression, []byte{
    .{ .source = &hex("128401c000"), .want = &hex("111111111111111111") },
    // Go level: []byte{}, 9, []byte{
    .{ .source = &hex("0300"), .want = &hex("") },
    // Go level: 9, []byte{
    .{ .source = &hex("12040c00"), .want = &hex("11") },
    // Go level: 9, []byte{
    .{ .source = &hex("1214020c00"), .want = &hex("1112") },
    // Go level: 9, []byte{
    .{ .source = &hex("128401c000"), .want = &hex("111111111111111111") },
};
/// golang/go `inflate_test.go` `TestReaderTruncated`, ported verbatim
/// (BSD-3-Clause; THIRD_PARTY.md). Every vector is a truncated stream: the
/// decoder must fail closed with `error.Truncated` and must have produced
/// exactly `partial` bytes by then (Go asserts the same partial output).
pub const truncated_cases: [10]TruncatedCase = .{
    .{
        .source = &hex("00"),
        .partial = &hex(""),
    },
    .{
        .source = &hex("000c"),
        .partial = &hex(""),
    },
    .{
        .source = &hex("000c00"),
        .partial = &hex(""),
    },
    .{
        .source = &hex("000c00f3ff"),
        .partial = &hex(""),
    },
    .{
        .source = &hex("000c00f3ff68656c6c6f"),
        .partial = &hex("68656c6c6f"),
    },
    .{
        .source = &hex("000c00f3ff68656c6c6f2c20776f726c64"),
        .partial = &hex("68656c6c6f2c20776f726c64"),
    },
    .{
        .source = &hex("02"),
        .partial = &hex(""),
    },
    .{
        .source = &hex("f248cd"),
        .partial = &hex("4865"),
    },
    .{
        .source = &hex("f248cd993061c28409"),
        .partial = &hex("48656c9090909090"),
    },
    .{
        .source = &hex("f248cd993061c2840900"),
        .partial = &hex("48656c9090909090"),
    },
};

/// `TestTruncatedStreams`' two-block stream (a stored block with its payload,
/// then a final empty stored block). Every strict prefix must fail closed —
/// Go asserts `io.ErrUnexpectedEOF` for all of them.
pub const truncated_streams_data = "\x00\x0c\x00\xf3\xffhello, world\x01\x00\x00\xff\xff";

/// `docs/research/flate-notes.md` §3.2's hand-built, oracle-verified streams
/// plus RFC 1951's own micro-examples. These are the byte-level packing proof:
///   - "fixed Huffman: literal 'A', match length 20 at distance 1" decodes to
///     21 bytes of 'A'; the same stream with the length code's two extra bits
///     read MSB-first would be 22 bytes, so the pair pins T1 (extra bits pack
///     LSB-of-value first).
///   - "70 literals 'A', then length 3 at distance 67": distance code 12's
///     extra bits are 2 (65 + 2 = 67); read MSB-first they would be 73, past
///     the 70-byte history, which the reference rejects — the clean decode
///     pins the distance extra-bit order independently.
///   - RFC 1951 §3.2.3's <length = 5, distance = 2> overlap example.
///   - RFC 1951 §3.2.4: a fixed block followed by a stored block whose header
///     sits at a non-byte offset, so the stored block's alignment path runs.
///   - RFC 1951 §3.2.7: a dynamic header whose code lengths are carried by
///     repeat code 16 ("repeat the previous code length 3-6 times") and
///     zero-run codes 17/18, with a single 1-bit distance code ("it is encoded
///     using one bit, not zero bits").
pub const micro_cases: [9]MicroCase = .{
    .{
        .desc = "flate-notes §3.2 stream 1: literal 'A' + <length 20, distance 1>",
        .source = &hex("73c40600"),
        .want = "A" ** 21,
    },
    .{
        .desc = "flate-notes §3.2 stream 1, length extra bits the other way: 22 bytes of 'A'",
        .source = &hex("73c40a00"),
        .want = "A" ** 22,
    },
    .{
        .desc = "flate-notes §3.2 stream 2: 70 literals 'A' + <length 3, distance 67>",
        .source = &hex("737474747474747474747474747474747474747474747474747474747474" ++
            "747474747474747474747474747474747474747474747474747474747474" ++
            "74747474747474747474041a0100"),
        .want = "A" ** 73,
    },
    .{
        .desc = "RFC 1951 §3.2.3: <length = 5, distance = 2> adds X,Y,X,Y,X",
        .source = &hex("8b88044300"),
        .want = "XYXYXYX",
    },
    .{
        .desc = "RFC 1951 §3.2.4: stored block header at a non-byte offset",
        .source = &hex("4a04040200fdff6263"),
        .want = "abc",
    },
    .{
        .desc = "RFC 1951 §3.2.7: repeat code 16, zero runs 17/18, single 1-bit distance code",
        .source = &hex("0de0b5010000000220dc66e8ff2729a06e"),
        .want = "ABCCCC",
    },
    // Zig std's four raw micro-streams (`std/compress/flate/Decompress.zig`,
    // MIT, in-tree), one per block kind: a stored block, a fixed block, and a
    // dynamic block (README.md, "Testing & golden vectors").
    .{
        .desc = "std.compress.flate micro-stream: stored block, 'Hello world'",
        .source = &hex("010c00f3ff48656c6c6f20776f726c640a"),
        .want = "Hello world\n",
    },
    .{
        .desc = "std.compress.flate micro-stream: fixed block, 'Hello world'",
        .source = &hex("f348cdc9c95728cf2fca49e10200"),
        .want = "Hello world\n",
    },
    .{
        .desc = "std.compress.flate micro-stream: dynamic block, 'ABCDEABCD ABCDEABCD'",
        .source = &hex("3dc6391100000c02302bb5521eff963816965c1e94cb6d01"),
        .want = "ABCDEABCD ABCDEABCD",
    },
};

/// The nine `testdata/huffman-*` `.in`/`.golden` pairs, embedded verbatim.
/// `.golden` is Go's `writeBlockHuff(false, ...)` output — a *single* block
/// with BFINAL clear, which raw deflate has no way to terminate, so verbatim
/// it is a truncated stream. Both lanes are tested below: verbatim it must
/// fail closed with `error.Truncated` after producing exactly `.in`, and with
/// BFINAL set on that one block it is a complete stream that must decode to
/// `.in` (both verified against the python3 zlib oracle, `wbits=-15`).
pub const huffman_fixtures: [9]HuffmanFixture = .{
    .{
        .name = "huffman-null-max",
        .input = @embedFile("testdata/huffman-null-max.in"),
        .golden = @embedFile("testdata/huffman-null-max.golden"),
    },
    .{
        .name = "huffman-pi",
        .input = @embedFile("testdata/huffman-pi.in"),
        .golden = @embedFile("testdata/huffman-pi.golden"),
    },
    .{
        .name = "huffman-rand-1k",
        .input = @embedFile("testdata/huffman-rand-1k.in"),
        .golden = @embedFile("testdata/huffman-rand-1k.golden"),
    },
    .{
        .name = "huffman-rand-limit",
        .input = @embedFile("testdata/huffman-rand-limit.in"),
        .golden = @embedFile("testdata/huffman-rand-limit.golden"),
    },
    .{
        .name = "huffman-rand-max",
        .input = @embedFile("testdata/huffman-rand-max.in"),
        .golden = @embedFile("testdata/huffman-rand-max.golden"),
    },
    .{
        .name = "huffman-shifts",
        .input = @embedFile("testdata/huffman-shifts.in"),
        .golden = @embedFile("testdata/huffman-shifts.golden"),
    },
    .{
        .name = "huffman-text-shift",
        .input = @embedFile("testdata/huffman-text-shift.in"),
        .golden = @embedFile("testdata/huffman-text-shift.golden"),
    },
    .{
        .name = "huffman-text",
        .input = @embedFile("testdata/huffman-text.in"),
        .golden = @embedFile("testdata/huffman-text.golden"),
    },
    .{
        .name = "huffman-zero",
        .input = @embedFile("testdata/huffman-zero.in"),
        .golden = @embedFile("testdata/huffman-zero.golden"),
    },
};

/// streaming `Writer`'s tests, whose streams must end the same way.
fn bitAt(stream: []const u8, bit: usize) u1 {
    return @intCast((stream[bit / 8] >> @intCast(bit % 8)) & 1);
}

const final_empty_block_bits: u10 = 0b0000000011;

/// `count` bits of `stream` from `bit`, LSB-of-value first.
fn readBits(stream: []const u8, bit: usize, comptime count: u6) u64 {
    var value: u64 = 0;
    for (0..count) |i| value |= @as(u64, bitAt(stream, bit + i)) << @intCast(i);
    return value;
}

pub fn expectFinalEmptyBlock(stream: []const u8) !void {
    const total_bits = stream.len * 8;
    var last_set: ?usize = null;
    var bit = total_bits;
    while (bit > 0) {
        bit -= 1;
        if (bitAt(stream, bit) != 0) {
            last_set = bit;
            break;
        }
    }
    const p = last_set orelse return error.TestUnexpectedResult;
    try testing.expect(p >= 1);
    try testing.expectEqual(final_empty_block_bits, readBits(stream, p - 1, 10));
    // At most seven zero bits of padding follow the ten ending bits.
    try testing.expect(total_bits - (p - 1) <= 10 + 7);
}

test "golden decode: golang/go TestStreams" {
    // The primary conformance table: every degenerate dynamic-header corner,
    // the T2/T3 divergence rows, a raw stored block, and the
    // issue-10426/11030/11033 regressions. Spec: rfc1951-deflate.txt §3.2.3,
    // §3.2.6, §3.2.7.
    var target: [512]u8 = undefined;
    for (stream_cases) |tc| try checkStreamCase(&target, tc);
}

test "golden decode: golang/go TestStreams, exact-cap decodes" {
    // The same table decoded into a target of exactly the expected size: any
    // write past the decoded length is an out-of-bounds write.
    var target: [512]u8 = undefined;
    for (stream_cases) |tc| {
        switch (tc.expect) {
            .ok => |want| {
                if (want.len > target.len) continue;
                const n = try decompress(tc.source, target[0..want.len]);
                try testing.expectEqualSlices(u8, want, target[0..n]);
            },
            else => {},
        }
    }
}

test "golden decode: golang/go TestTruncatedStreams, every prefix" {
    // Spec: rfc1951-deflate.txt §3.2.3 — the stream ends at the first block
    // with BFINAL=1, so a prefix that stops earlier must fail closed.
    const data = truncated_streams_data;
    var target: [64]u8 = undefined;
    for (0..data.len) |prefix_len| {
        sentinel.fill(&target);
        const result = decompress(data[0..prefix_len], &target);
        if (result) |n| {
            print("\nFAIL: prefix {d} decoded {d} bytes, want Truncated\n", .{ prefix_len, n });
            return error.TestUnexpectedResult;
        } else |err| {
            if (err != error.Truncated) {
                print("\nFAIL: prefix {d}: {s}, want Truncated\n", .{
                    prefix_len, @errorName(err),
                });
                return err;
            }
        }
    }
}

test "golden decode: golang/go TestReaderTruncated" {
    // Spec: rfc1951-deflate.txt §3.2.3/§3.2.4 — truncated stored headers,
    // partial fixed-block payloads, mid-match truncation. Every one must fail
    // closed with the partial output Go expects, and must leave the sentinels
    // past that partial output untouched.
    var target: [64]u8 = undefined;
    for (truncated_cases) |tc| {
        sentinel.fill(&target);
        const result = decompress(tc.source, &target);
        if (result) |n| {
            print("\nFAIL: decoded {d} bytes, want Truncated\n", .{n});
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.Truncated, err);
        }
        try testing.expectEqualSlices(u8, tc.partial, target[0..tc.partial.len]);
        try sentinel.expect(&target, tc.partial.len);
    }
}

test "golden decode: golang/go deflateTests rows" {
    // Every Go `out` is a valid stream that must decode to `in`. Spec:
    // rfc1951-deflate.txt §3.2.3 (empty stream `03 00`), §3.2.4 (stored
    // blocks with LEN/NLEN), §3.2.6 (fixed blocks).
    var target: [64]u8 = undefined;
    for (deflate_cases) |tc| try checkDecode(&target, tc.source, tc.want);
}

test "golden decode: RFC 1951 and flate-notes micro-streams" {
    // Spec: rfc1951-deflate.txt §3.1.1 (packing), §3.2.3 (overlap copy),
    // §3.2.4 (stored alignment), §3.2.7 (repeat codes); flate-notes.md §3.2.
    var target: [128]u8 = undefined;
    for (micro_cases) |tc| {
        checkDecode(&target, tc.source, tc.want) catch |err| {
            print("\nFAIL: {s}\n", .{tc.desc});
            return err;
        };
    }
}

test "golden decode: golang/go testdata huffman-* pairs" {
    // Spec: rfc1951-deflate.txt §3.2.6/§3.2.7 — real dynamic and stored
    // blocks over 242 KB of reference data. `.golden` verbatim is a non-final
    // block (BFINAL clear), so it must fail closed as `Truncated` after
    // producing exactly `.in`; with BFINAL set on that single block it is a
    // complete stream and must decode to `.in`.
    const allocator = testing.allocator;
    const target = try allocator.alloc(u8, 65536);
    defer allocator.free(target);
    const stream = try allocator.alloc(u8, 65540);
    defer allocator.free(stream);

    for (huffman_fixtures) |fixture| {
        try testing.expect(fixture.golden.len <= stream.len);

        // Verbatim: truncated, with the full input already decoded.
        sentinel.fill(target);
        const result = decompress(fixture.golden, target);
        if (result) |n| {
            print("\nFAIL ({s}): decoded {d} bytes, want Truncated\n", .{ fixture.name, n });
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.Truncated, err);
        }
        try testing.expectEqualSlices(u8, fixture.input, target[0..fixture.input.len]);
        try sentinel.expect(target, fixture.input.len);

        // With BFINAL set on the fixture's single block: a complete stream.
        fastmem.copy(u8, stream[0..fixture.golden.len], fixture.golden);
        const complete = stream[0..fixture.golden.len];
        complete[0] |= 1;
        checkDecode(target, complete, fixture.input) catch |err| {
            print("\nFAIL: {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "golden decode: empty stream and empty non-final block" {
    // Spec: rfc1951-deflate.txt §3.2.3 — a single final empty block is a valid
    // stream; §3.2.4 — LEN 0 is legal, so an empty non-final block is too.
    var target: [4]u8 = undefined;
    try checkDecode(&target, &hex("0300"), ""); // final empty fixed block
    // A final empty stored block, with the bytes after it ignored.
    try checkDecode(&target, &hex("010000ffff0300"), "");
    try checkDecode(&target, &hex("000000ffff010000ffff"), ""); // empty stored, non-final
}

test "golden decode: BufferTooSmall leaves the cap untouched" {
    // README, "Contracts" — `target` is a cap: a stream that does not fit is
    // `error.BufferTooSmall`, reported before the overflowing write, and the
    // bytes at and past the cap are untouched.
    const source = &hex("000800f7ff11111111111111110300"); // 8 bytes of 0x11
    var target: [4]u8 = undefined;
    sentinel.fill(&target);
    try testing.expectError(error.BufferTooSmall, decompress(source, &target));
    try sentinel.expect(&target, 0);
}
