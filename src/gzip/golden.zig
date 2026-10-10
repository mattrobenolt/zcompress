//! Golden decode fixtures ported from golang/go (BSD-3-Clause; attribution in
//! THIRD_PARTY.md) plus Zig 0.16 std's in-tree container members and RFC 1952
//! micro-examples. Shared by every layer's tests (the flate pattern):
//! `decode.zig` owns the one-shot decoder, `Reader.zig` the streaming layer,
//! and this module owns the reference vectors both are judged against.
//!
//! Sources:
//!   - `src/compress/gzip/gunzip_test.go` `gunzipTests` (15 vectors), ported
//!     verbatim as hex; `TestTruncatedStreams` (3 vectors, every prefix);
//!     `TestIssue6550` (`testdata/issue6550.gz.base64`); `TestMultistreamFalse`
//!     (the x2 vector); `TestNilStream` (the zero-member reading); and
//!     `TestCVE202230631` (the repeated empty member).
//!   - `src/compress/gzip/gzip_test.go` `TestEmpty` (the emitted-header
//!     policy) and `TestWriterFlush` (the lazy header) as round-trip and
//!     policy fixtures.
//!   - Zig 0.16 std `std/compress/flate/Decompress.zig`'s container tests
//!     (MIT, in-tree): the gzip stored/fixed/dynamic "Hello world\n"
//!     members, the FNAME member, and the FHCRC member (FLG=0x12, CRC16
//!     `99 d6`) — decoder goldens and divergence pins (std verifies neither
//!     FHCRC nor the trailer, T3/T4; it does not check reserved bits).
//!
//! Every decode here runs the sentinel overrun rule: the target is
//! pre-filled with cycling sentinels and every byte past the decoded length
//! must be untouched (`src/internal/README.md`, "API").

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const common = @import("common.zig");
const readInt = common.readInt;
const crc32 = @import("crc32.zig");
const decode = @import("decode.zig");

/// Comptime hex decoding, so the ported vectors keep golang/go's own
/// hexstring spelling instead of a byte-list transcription.
fn hex(comptime text: []const u8) [text.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    comptime assert(text.len % 2 == 0);
    var bytes: [text.len / 2]u8 = undefined;
    for (&bytes, 0..) |*byte, i| {
        byte.* = std.fmt.parseInt(u8, text[i * 2 ..][0..2], 16) catch unreachable;
    }
    return bytes;
}

/// What a golden member must do.
pub const Expect = union(enum) {
    /// Decode to exactly these bytes.
    ok: []const u8,
    /// Reject the member with any `DecompressError`.
    fail,
    /// Reject the member with this specific error (the README's decided rules
    /// pin these; the rest only have to fail).
    fail_with: decode.DecompressError,
};

/// One ported member vector: Go's `desc`, `gzip`, and expected outcome.
pub const Case = struct {
    desc: []const u8,
    source: []const u8,
    expect: Expect,
    /// What a fresh reader at the member boundary finds in the trailing
    /// bytes, when the vector carries any: `null` when the member is the
    /// whole source. This is the boundary policy's pin (T2/OQ3): the member
    /// decodes, the trailing bytes are left unconsumed, and the next header
    /// parse in a caller loop fails closed (`BadHeader`), or succeeds when
    /// the trailing bytes are the next member (the x2 vector).
    trailing: ?Expect = null,
};

/// `gunzipTests` (15 vectors) plus the two writer-policy fixtures, ported
/// verbatim. RFC 1952 §2.2 (members), §2.3 (the member), §2.3.1 (the fixed
/// header, optional fields, the trailer).
pub const gunzip_cases: []const Case = &.{
    // 1. "has 1 empty fixed-huffman block", FNAME "empty.txt" (§2.3.1 FNAME).
    .{
        .desc = "empty.txt",
        .source = &hex("1f8b0808f75e144a0003656d7074792e7478740003000000000000000000"),
        .expect = .{ .ok = "" },
    },
    // 2. "empty - with no file name": FLG=0, MTIME=0x886e0900, OS=255.
    .{
        .desc = "empty - with no file name",
        .source = &hex("1f8b080000096e8800ff010000ffff0000000000000000"),
        .expect = .{ .ok = "" },
    },
    // 3. "has 1 non-empty fixed huffman block", FNAME "hello.txt".
    .{
        .desc = "hello.txt",
        .source = &hex("1f8b0808c858134a000368656c6c6f2e74787400cb48cdc9c95728cf2fca49e1" ++
            "02002d3b08af0c000000"),
        .expect = .{ .ok = "hello world\n" },
    },
    // 4. "concatenation" (§2.2: members appear one after another): one
    // reader decodes the first member; a fresh reader at the boundary
    // decodes the second (TestMultistreamFalse's shape).
    .{
        .desc = "hello.txt x2",
        .source = &hex("1f8b0808c858134a000368656c6c6f2e74787400cb48cdc9c95728cf2fca49e1" ++
            "02002d3b08af0c0000001f8b0808c858134a000368656c6c6f2e74787400cb48" ++
            "cdc9c95728cf2fca49e102002d3b08af0c000000"),
        .expect = .{ .ok = "hello world\n" },
        .trailing = .{ .ok = "hello world\n" },
    },
    // 5. "has a fixed huffman block with some length-distance pairs".
    .{
        .desc = "shesells.txt",
        .source = &hex("1f8b080872668b4a000373686573656c6c732e747874002bce4855284ecdc929" ++
            "069289c519605652a54209581828905f94ca050076b03beb24000000"),
        .expect = .{ .ok = "she sells seashells by the seashore\n" },
    },
    // 6. "has dynamic huffman blocks" (the Gettysburg address).
    .{
        .desc = "gettysburg",
        .source = &hex("1f8b0808d1122b4a000367657474797362757267006554cd6ed43010befb29e6" ++
            "0142a50a09c111904048a8e280d4f3249e2456bd9ec57676951b0fc113f2247c" ++
            "63779b4a5caa6e6ccf7c7f33445f74cb5426cd429c3c15b948a25d3817e245c9" ++
            "4e67aeabe0f798755bd64ab3e6ba922657d75068d25443925407624a72a5c435" ++
            "681aec609270114f21d1f7304aaefbd09a78f161e22ade5525d4a673d6b39660" ++
            "eff09b2b718c74021006ac298bdd25f9b571bc73440f7aa5abb433490b2fbd03" ++
            "d36217e973b884488f9c07aa52006da1eb2ac6a0957637789a81657f464b455f" ++
            "e16d42e801135c3851d4b438497ecb62281e3b82935448f1d27de45aa3bc9983" ++
            "444f3a773657cecf2f56be80909e84ea511f8fcf90d460dc5eb4f7100b26e0ff" ++
            "c4d1e5672ee7c8939805b8a845c04d09dc84162b0d9a2153048bd20bbda24ca7" ++
            "60eed9e11dd1b74a308f63d5a58b3387da1a1879f3e3a617942eab6ea0e3cdac" ++
            "508ccaa70d7637d123e705578ba42283d9625225ad07bbbfbfffbcfaee207391" ++
            "29ff7f02716284b5f6b5256b41de92b7763f9191311b418462300a37a45e183a" ++
            "9908a5e66d5922ec33398626f5ab66c80820cf0cd74745210bf659d5fe5c8daa" ++
            "127b6fa1f052334ff5ce59d3ab6610bf06c4310673d680a278c245cb036539c9" ++
            "09d10604331a5af1de01b87183c4b5b3c35465330d5af79b907c271f3a58a3d8" ++
            "fd305fb7d266a2931c28b7e91b0ce1284726bbe97d7edc96109250567c06e227" ++
            "b408d3da7b9834739fdbf662ed314113d3a2a84b3ac61de42f8cf8fb9764f4b6" ++
            "2f805af356e04050d519d01efccae5c9d46000812ea3ccb652f0b4db6999ce7a" ++
            "324c08edaa1010e36fee9968959f0471b2492f62a65eb4ef02ed4f27de4a0ffd" ++
            "c1ccdd028f081654dfdacae082f1b4317aa981fe90b73edbd335c0208033464a" ++
            "63abd10d29d2e284b8dbfae98944867ce80be6026a079b96d0db2e414ca1d557" ++
            "4514fbe3a6725b876e0c6d5bcee02fe2218195b0e8b6320bb29813525dfbec63" ++
            "178a9e232236eecddadbcf3ef1c7f10112930aeb6ff2021596775def9cfb8891" ++
            "59f984dd9b268d80f980662dacf71f06ba7fffeeed405fa5d6bd8c5b46d27e48" ++
            "4a658f084260f70fb9160b0c1a060000"),
        .expect = .{ .ok = gettysburg },
    },
    // 7. "has 1 non-empty fixed huffman block then garbage": Go's
    // multistream reader fails ErrHeader on the garbage; ours decodes the
    // member, leaves the garbage unconsumed, and a caller loop's next header
    // parse is `BadHeader` (T2/OQ3, the recorded divergence).
    .{
        .desc = "hello.txt + garbage",
        .source = &hex("1f8b0808c858134a000368656c6c6f2e74787400cb48cdc9c95728cf2fca49e1" ++
            "02002d3b08af0c00000067617262616765212121"),
        .expect = .{ .ok = "hello world\n" },
        .trailing = .{ .fail_with = error.BadHeader },
    },
    // 8. "has 1 non-empty fixed huffman block not enough header": the
    // trailing byte is gzipID1 (0x1f), a header cut at one byte — the next
    // parse is `Truncated`.
    .{
        .desc = "hello.txt + not enough header",
        .source = &hex("1f8b0808c858134a000368656c6c6f2e74787400cb48cdc9c95728cf2fca49e1" ++
            "02002d3b08af0c0000001f"),
        .expect = .{ .ok = "hello world\n" },
        .trailing = .{ .fail_with = error.Truncated },
    },
    // 9. "but corrupt checksum": Go collapses this into ErrChecksum
    // (`gunzip.go:267`); ours is the specific `WrongChecksum` (T4).
    .{
        .desc = "hello.txt + corrupt checksum",
        .source = &hex("1f8b0808c858134a000368656c6c6f2e74787400cb48cdc9c95728cf2fca49e1" ++
            "0200ffffffff0c000000"),
        .expect = .{ .fail_with = error.WrongChecksum },
    },
    // 10. "but corrupt size": the CRC matches, ISIZE does not — `WrongSize`.
    .{
        .desc = "hello.txt + corrupt size",
        .source = &hex("1f8b0808c858134a000368656c6c6f2e74787400cb48cdc9c95728cf2fca49e1" ++
            "02002d3b08afff000000"),
        .expect = .{ .fail_with = error.WrongSize },
    },
    // 11. "header with all fields used": FLG=0x1e (FHCRC+FEXTRA+FNAME+
    // FCOMMENT), a 'zz' subfield with LEN 5, a 256-byte comment, FHCRC
    // 0xfd92 — the low 16 bits of the header CRC-32 (§2.3.1; verified in
    // containers-notes.md §3.1).
    .{
        .desc = "header with all fields used",
        .source = &hex("1f8b081e70f0f94a00aa09007a7a0500616263646566316c336e346d332e7458" ++
            "74000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e" ++
            "1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e" ++
            "3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e" ++
            "5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e" ++
            "7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e" ++
            "9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbe" ++
            "bfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcddde" ++
            "dfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfe" ++
            "ff0092fd010000ffff0000000000000000"),
        .expect = .{ .ok = "" },
    },
    // 12. "truncated gzip file amid raw-block" (Go: io.ErrUnexpectedEOF).
    .{
        .desc = "truncated gzip file amid raw-block",
        .source = &hex("1f8b08000000000000ff000c00f3ff68656c6c6f"),
        .expect = .{ .fail_with = error.Truncated },
    },
    // 13. "truncated gzip file amid fixed-block".
    .{
        .desc = "truncated gzip file amid fixed-block",
        .source = &hex("1f8b08000000000000fff248cd"),
        .expect = .{ .fail_with = error.Truncated },
    },
    // 14. "gzip header with truncated name": the first member decodes; the
    // trailing 11 bytes are a second header cut inside its name — the next
    // parse is `Truncated`.
    .{
        .desc = "gzip header with truncated name",
        .source = &hex("1f8b0808c858134a000368656c6c6f2e74787400cb48cdc9c95728cf2fca49e1" ++
            "02002d3b08af0c0000001f8b08080000000000ff01"),
        .expect = .{ .ok = "hello world\n" },
        .trailing = .{ .fail_with = error.Truncated },
    },
    // 15. "gzip header with truncated comment" (Go's labels swap the two
    // flags; the vectors are kept verbatim).
    .{
        .desc = "gzip header with truncated comment",
        .source = &hex("1f8b0810c858134a000368656c6c6f2e74787400cb48cdc9c95728cf2fca49e1" ++
            "02002d3b08af0c0000001f8b08100000000000ff01"),
        .expect = .{ .ok = "hello world\n" },
        .trailing = .{ .fail_with = error.Truncated },
    },
};

/// The Gettysburg address, the `gettysburg` vector's payload (verbatim from
/// Go's `gunzip_test.go`, em dashes and all).
pub const gettysburg =
    "  Four score and seven years ago our fathers brought forth on\n" ++
    "this continent, a new nation, conceived in Liberty, and dedicated\n" ++
    "to the proposition that all men are created equal.\n" ++
    "  Now we are engaged in a great Civil War, testing whether that\n" ++
    "nation, or any nation so conceived and so dedicated, can long\n" ++
    "endure.\n" ++
    "  We are met on a great battle-field of that war.\n" ++
    "  We have come to dedicate a portion of that field, as a final\n" ++
    "resting place for those who here gave their lives that that\n" ++
    "nation might live.  It is altogether fitting and proper that\n" ++
    "we should do this.\n" ++
    "  But, in a larger sense, we can not dedicate \xe2\x80\x94 we can not\n" ++
    "consecrate \xe2\x80\x94 we can not hallow \xe2\x80\x94 this ground.\n" ++
    "  The brave men, living and dead, who struggled here, have\n" ++
    "consecrated it, far above our poor power to add or detract.\n" ++
    "The world will little note, nor long remember what we say here,\n" ++
    "but it can never forget what they did here.\n" ++
    "  It is for us the living, rather, to be dedicated here to the\n" ++
    "unfinished work which they who fought here have thus far so\n" ++
    "nobly advanced.  It is rather for us to be here dedicated to\n" ++
    "the great task remaining before us \xe2\x80\x94 that from these honored\n" ++
    "dead we take increased devotion to that cause for which they\n" ++
    "gave the last full measure of devotion \xe2\x80\x94\n" ++
    "  that we here highly resolve that these dead shall not have\n" ++
    "died in vain \xe2\x80\x94 that this nation, under God, shall have a new\n" ++
    "birth of freedom \xe2\x80\x94 and that government of the people, by the\n" ++
    "people, for the people, shall not perish from this earth.\n" ++
    "\n" ++
    "Abraham Lincoln, November 19, 1863, Gettysburg, Pennsylvania\n";

/// Zig 0.16 std's in-tree gzip container members (MIT; divergence pins,
/// T3/T4): stored, fixed, and dynamic "Hello world\n", the FNAME member, and
/// the FHCRC member (FLG=0x12, CRC16 `99 d6`).
pub const std_cases: []const Case = &.{
    .{
        .desc = "std: gzip stored block (type 0)",
        .source = &hex("1f8b0800000000000003010c00f3ff48656c6c6f20776f726c640ad5e039b70c" ++
            "000000"),
        .expect = .{ .ok = "Hello world\n" },
    },
    .{
        .desc = "std: gzip fixed code block (type 1)",
        .source = &hex("1f8b0800000000000403f348cdc9c95728cf2fca49e10200d5e039b70c000000"),
        .expect = .{ .ok = "Hello world\n" },
    },
    .{
        .desc = "std: gzip dynamic block (type 2)",
        .source = &hex("1f8b08000000000000033dc6391100000c02302bb5521eff963816965c1e94cb" ++
            "6d01171c39b413000000"),
        .expect = .{ .ok = "ABCDEABCD ABCDEABCD" },
    },
    .{
        .desc = "std: gzip header with name",
        .source = &hex("1f8b0808e570b165000368656c6c6f2e74787400f348cdc9c95728cf2fca49e1" ++
            "0200d5e039b70c000000"),
        .expect = .{ .ok = "Hello world\n" },
    },
    // The FHCRC member: FLG=0x12 (FHCRC+FCOMMENT), the comment "Hello\0", the
    // CRC16 `99 d6`, a stored block of length 0, and the zero trailer. std
    // discards the CRC16 unchecked (`Decompress.zig:305-307`); we verify it
    // (T3) — the member decodes because the value is right.
    .{
        .desc = "std: gzip FHCRC member",
        .source = &hex("1f8b081200096e8800ff48656c6c6f0099d6010000ffff0000000000000000"),
        .expect = .{ .ok = "" },
    },
};

/// `TestTruncatedStreams` (3 vectors): every prefix of each must fail closed
/// with `Truncated`, never decode cleanly. Go's vector names swap FNAME and
/// FCOMMENT; the flag bytes are the ground truth (0x10 is FCOMMENT).
pub const truncated_streams: []const []const u8 = &.{
    // "original": FEXTRA with a 7-byte 'foo bar' extra field, then a fixed
    // block, then the trailer.
    &hex("1f8b080400096e8800ff0700666f6f20626172cb48cdc9c9d75128cf2fca4901043a72abff0c000000"),
    // "truncated name" (FLG=0x10: FCOMMENT).
    &hex("1f8b08100000000000ff01"),
    // "truncated comment" (FLG=0x08: FNAME).
    &hex("1f8b08080000000000ff01"),
};

/// `TestCVE202230631`: an empty member (MTIME 0x62438fa7) repeated — the
/// stack-exhaustion regression's input. One member at a time through the
/// caller loop: every boundary is exact and nothing accumulates.
pub const cve_2022_30631_member = hex("1f8b0800a78f4362000303000000000000000000");

/// `TestIssue6550`: the 85.3-KB base64 of a real-world member whose FLG has
/// reserved bits set (0xa4) — Apple's notarization service and old Go
/// inflates hung or crashed on it. Ours fails closed at the header parse
/// (`BadHeader`, `§2.3.1.2`).
pub const issue6550_base64 = @embedFile("testdata/issue6550.gz.base64");

/// Decode `source` with the one-shot decoder, checking `expect` and the
/// sentinel overrun rule: `target` is `window[0..cap]`, and the bytes at and
/// past the cap must hold their sentinels — a decode never writes past its
/// cap, on success or failure.
pub fn checkOneShot(window: []u8, cap: usize, source: []const u8, expect: Expect) !void {
    try testing.expect(cap <= window.len);
    sentinel.fill(window);
    const target = window[0..cap];
    switch (expect) {
        .ok => |want| {
            const n = try decode.decompress(source, target);
            try testing.expectEqual(want.len, n);
            try testing.expectEqualSlices(u8, want, target[0..n]);
            try sentinel.expect(window, n);
        },
        .fail => {
            if (decode.decompress(source, target)) |_| return error.TestExpectedFailure else |_| {}
            try sentinel.expect(window, cap);
        },
        .fail_with => |want| {
            const got = decode.decompress(source, target) catch |err| err;
            try testing.expectEqual(want, got);
            try sentinel.expect(window, cap);
        },
    }
}

/// Assert the deterministic 10-byte header (OQ7) on an emitted member:
/// ID1/ID2/CM fixed, FLG=0, MTIME=0, XFL as given, OS=255.
pub fn expectHeader(member: []const u8, xfl: u8) !void {
    try testing.expect(member.len >= 10 + 8);
    try testing.expectEqual(@as(u8, 0x1f), member[0]);
    try testing.expectEqual(@as(u8, 0x8b), member[1]);
    try testing.expectEqual(@as(u8, 8), member[2]);
    try testing.expectEqual(@as(u8, 0), member[3]);
    try testing.expectEqual(@as(u32, 0), readInt(u32, member[4..8]));
    try testing.expectEqual(xfl, member[8]);
    try testing.expectEqual(@as(u8, 255), member[9]);
}

/// Assert the trailer on an emitted member: CRC-32 of `source` per ISO 3309
/// and ISIZE, the length mod 2^32, both little-endian (`§2.1`, `§2.3.1`).
/// The reference is std's CRC-32 kernel over the same bytes, so this pins
/// the container's byte accounting (every byte exactly once, in order).
pub fn expectTrailer(member: []const u8, source: []const u8) !void {
    try testing.expect(member.len >= decode.trailer_len);
    const trailer = member[member.len - decode.trailer_len ..];
    try testing.expectEqual(
        std.hash.crc.Crc32.hash(source),
        readInt(u32, trailer[0..4]),
    );
    try testing.expectEqual(
        crc32.crc32(0, source),
        readInt(u32, trailer[0..4]),
    );
    try testing.expectEqual(
        @as(u32, @truncate(source.len)),
        readInt(u32, trailer[4..8]),
    );
}

// ---------------------------------------------------------------------------
// Tests. Spec: rfc1952-gzip.txt §2.2 (members), §2.3 (the member), §2.3.1
// (the fixed header, the optional fields, the trailer), §2.3.1.1 (FEXTRA),
// §2.3.1.2 (decoder obligations).
// ---------------------------------------------------------------------------

test "golden decode: golang/go gunzipTests" {
    // The primary gzip conformance table: valid members, the concatenation
    // vector, the all-fields header, and the corrupt/truncated vectors with
    // their pinned errors. Every decode is sentinel-checked.
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 2048 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (gunzip_cases) |tc| {
        const cap = switch (tc.expect) {
            .ok => |want| want.len,
            else => window.len,
        };
        checkOneShot(window, cap, tc.source, tc.expect) catch |err| {
            std.debug.print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "golden decode: the std in-tree container members" {
    // Zig 0.16 std's container tests (MIT, in-tree): stored, fixed, dynamic,
    // FNAME, and the FHCRC member — the FHCRC value verified (T3, a
    // divergence from std, which discards it).
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 512 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (std_cases) |tc| {
        const cap = switch (tc.expect) {
            .ok => |want| want.len,
            else => window.len,
        };
        checkOneShot(window, cap, tc.source, tc.expect) catch |err| {
            std.debug.print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "golden decode: truncated streams fail closed at every prefix" {
    // `TestTruncatedStreams`: every prefix of each vector must fail closed
    // with `Truncated` — a truncated member never decodes cleanly.
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 256 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (truncated_streams) |stream| {
        var len: usize = 1;
        while (len < stream.len) : (len += 1) {
            const expect: Expect = .{ .fail_with = error.Truncated };
            checkOneShot(window, window.len, stream[0..len], expect) catch |err| {
                std.debug.print("\nFAIL: prefix {d}/{d}: {s}\n", .{
                    len, stream.len, @errorName(err),
                });
                return err;
            };
        }
    }
}

test "golden decode: the FHCRC value is the header CRC's low 16 bits" {
    // RFC 1952 §2.3.1 — FHCRC is "the two least significant bytes of the
    // CRC32 for all bytes of the gzip header up to and not including the
    // CRC16". The all-fields vector's value is 0xfd92; the std FHCRC member
    // carries the wire bytes `99 d6` (0xd699 little-endian). Recomputing
    // both pins the arithmetic (T3).
    // The all-fields member ends with the 2-byte CRC16, the 5-byte stored
    // body (`01 00 00 ff ff`), and the 8-byte trailer.
    const all_fields = gunzip_cases[10].source;
    try testing.expectEqual(
        @as(u16, 0xfd92),
        @as(u16, @truncate(crc32.crc32(0, all_fields[0 .. all_fields.len - 15]))),
    );
    const fhcrc_member = std_cases[4].source;
    try testing.expectEqual(
        @as(u16, 0xd699),
        @as(u16, @truncate(crc32.crc32(0, fhcrc_member[0..16]))),
    );
}

test "golden decode: issue6550 fails closed without hanging" {
    // `TestIssue6550`: the base64 fixture's FLG has reserved bits set
    // (0xa4), so the header parse is `BadHeader` (`§2.3.1.2`: a reserved bit
    // "could indicate the presence of a new field that would cause
    // subsequent data to be interpreted incorrectly"). The decode returns;
    // it does not run away.
    const gpa = testing.allocator;
    const member = try gpa.alloc(u8, issue6550_base64.len / 4 * 3);
    defer gpa.free(member);
    const decoder = std.base64.standard.decoderWithIgnore("\n");
    const len = try decoder.decode(member, issue6550_base64);
    try testing.expectEqual(@as(usize, 65536), len);
    try testing.expectEqual(@as(u8, 0xa4), member[3]);

    const window = try gpa.alloc(u8, 4096 + @as(usize, sentinel.len));
    defer gpa.free(window);
    try checkOneShot(window, window.len, member, .{ .fail_with = error.BadHeader });
}
