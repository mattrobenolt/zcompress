//! Golden decode fixtures ported from golang/go (BSD-3-Clause; attribution in
//! THIRD_PARTY.md) plus Zig 0.16 std's in-tree container streams and the
//! oracle-verified C-reference emissions. Shared by every layer's tests (the
//! flate pattern): `decode.zig` owns the one-shot decoder, `Reader.zig` the
//! streaming layer, and this module owns the reference vectors both are
//! judged against.
//!
//! Sources:
//!   - `src/compress/zlib/reader_test.go` `zlibTests` (14 vectors, the
//!     current tree), ported verbatim as hex; its own comment says the golden
//!     bytes came from the C reference's `zpipe.c`. Our outcomes differ where
//!     the README decided they must: an FDICT stream is `DictionaryRequired`
//!     before any body byte (ZD3/ZD4), never Go's `io.ErrUnexpectedEOF` or
//!     `ErrDictionary`, and a truncated trailer is `Truncated`.
//!   - Zig 0.16 std `std/compress/flate/Decompress.zig`'s zlib tests (MIT,
//!     in-tree): the stored "Hello world\n" stream, "zlib should not
//!     overshoot" (the exact-consumption case), and the bad-CM / bad-CINFO /
//!     truncated-header / truncated-checksum failures. The fixed and dynamic
//!     members are std's gzip vectors with the container framing swapped for
//!     zlib's (the bodies are std's, verified against the C reference here);
//!     std's laxness (no FCHECK check, no FDICT handling, no trailer
//!     comparison, T4/T6) is pinned by running std's decoder in this module's
//!     tests.
//!   - The C-reference emissions (oracle-verified, `containers-notes.md
//!     §5.5`): the FLEVEL/FCHECK header bands (`78 01`, `78 5e`, `78 9c`,
//!     `78 da`) and the dictionary + FLEVEL-0 corner's `78 3f` (FCHECK = 31,
//!     T5).
//!
//! Every decode here runs the sentinel overrun rule: the target is
//! pre-filled with cycling sentinels and every byte past the decoded length
//! must be untouched (`src/internal/README.md`, "API").

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const print = std.debug.print;

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const adler32 = @import("adler32.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const readInt = @import("common.zig").readInt;

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

/// What a golden stream must do.
pub const Expect = union(enum) {
    /// Decode to exactly these bytes.
    ok: []const u8,
    /// Reject the stream with any `DecompressError`.
    fail,
    /// Reject the stream with this specific error (the README's decided rules
    /// pin these; the rest only have to fail).
    fail_with: decode.DecompressError,
};

/// One ported stream vector: Go's `desc`, `compressed`, and expected outcome.
pub const Case = struct {
    desc: []const u8,
    source: []const u8,
    expect: Expect,
    /// What a fresh reader at the stream boundary finds in the trailing
    /// bytes, when the vector carries any: `null` when the stream is the
    /// whole source. This is the boundary policy's pin (`§2.2`: "Any data
    /// which may appear after ADLER32 are not part of the zlib stream"): the
    /// stream decodes, the trailing bytes are left unconsumed, and the next
    /// parse in a caller loop is the pinned outcome.
    trailing: ?Expect = null,
};

/// The Go `zlibTests` dictionary vector: the FDICT header `78 bb`, the
/// DICTID `1c 32 04 27` (the Adler-32 of the 12-byte dictionary), and a
/// dict-compressed body. Go decodes it against the caller's dictionary; ours
/// refuses the stream before any body byte (`DictionaryRequired`, ZD3/ZD4).
pub const dictionary_stream = hex("78bb1c320427f300b175201c452e0024120474");

/// `zlibTests` (14 vectors), ported verbatim. RFC 1950 §2.2 (the header, the
/// trailer, the stream's end), §2.3 (decoder obligations).
pub const zlib_cases: []const Case = &.{
    // 1. "truncated empty": no stream began.
    .{ .desc = "truncated empty", .source = &hex(""), .expect = .{
        .fail_with = error.Truncated,
    } },
    // 2. "truncated dict": the FDICT header alone. Go reads the DICTID and
    // hits io.ErrUnexpectedEOF; the flag is refused before any DICTID byte
    // here (§2.3).
    .{ .desc = "truncated dict", .source = &hex("78bb"), .expect = .{
        .fail_with = error.DictionaryRequired,
    } },
    // 3. "truncated checksum": an FDICT stream with a DICTID, a stored body,
    // and no trailer. Go decodes against the caller's dictionary and hits
    // io.ErrUnexpectedEOF at the trailer; the FDICT refusal comes first here.
    .{
        .desc = "truncated checksum",
        .source = &hex("78bb00010001ca48cdc9c9d75128cf2fca49010400" ++ "00ffff"),
        .expect = .{ .fail_with = error.DictionaryRequired },
    },
    // 4. "empty": the C reference's empty stream — the bytes our own encoder
    // emits at `.fast` (the fuzz lane's hostile-header pins carry them too).
    .{ .desc = "empty", .source = &hex("789c030000000001"), .expect = .{ .ok = "" } },
    // 5. "goodbye": the C reference's fixed-Huffman stream.
    .{
        .desc = "goodbye",
        .source = &hex("789c4bcfcf4f49aa4cd55128cf2fca49010028a5055e"),
        .expect = .{ .ok = "goodbye, world" },
    },
    // 6. "bad header (CINFO)": CM=8, CINFO=8 — "values of CINFO above 7 are
    // not allowed in this version" (§2.2).
    .{
        .desc = "bad header (CINFO)",
        .source = &hex("88980300000000" ++ "01"),
        .expect = .{ .fail_with = error.BadHeader },
    },
    // 7. "bad header (FCHECK)": 78 9f breaks the (CMF*256 + FLG) % 31 == 0
    // arithmetic (§2.2) — and is the vector std's lax parse accepts (T6).
    .{
        .desc = "bad header (FCHECK)",
        .source = &hex("789f030000000001"),
        .expect = .{ .fail_with = error.BadHeader },
    },
    // 8. "bad checksum": the body decodes, the trailer does not match
    // (§2.3: the check is a decoder MUST).
    .{
        .desc = "bad checksum",
        .source = &hex("789c0300000000ff"),
        .expect = .{ .fail_with = error.WrongChecksum },
    },
    // 9. "not enough data": the trailer is cut short.
    .{
        .desc = "not enough data",
        .source = &hex("789c03000000"),
        .expect = .{ .fail_with = error.Truncated },
    },
    // 10. "excess data is silently ignored": the empty stream followed by a
    // second header's first bytes and an invalid block-type byte. The
    // one-shot ignores everything past ADLER32 (§2.2, ZD7); a fresh reader
    // at the boundary parses the second header and fails in its body.
    .{
        .desc = "excess data is silently ignored",
        .source = &hex("789c030000000001789cff"),
        .expect = .{ .ok = "" },
        .trailing = .{ .fail_with = error.InvalidBlockType },
    },
    // 11. "dictionary": Go decodes against the caller's dictionary; the
    // FDICT flag is refused here (§2.3).
    .{
        .desc = "dictionary",
        .source = &dictionary_stream,
        .expect = .{ .fail_with = error.DictionaryRequired },
    },
    // 12. "wrong dictionary": Go's second dictionary vector — the same bytes
    // with a different caller-supplied dictionary. One error name covers "no
    // dictionary" and "wrong dictionary" here, as Go's ErrDictionary does.
    .{
        .desc = "wrong dictionary",
        .source = &dictionary_stream,
        .expect = .{ .fail_with = error.DictionaryRequired },
    },
    // 13. "truncated zlib stream amid raw-block": a stored block whose LEN
    // declares 12 bytes with 6 present.
    .{
        .desc = "truncated zlib stream amid raw-block",
        .source = &hex("789c000c00f3ff68656c6c6f"),
        .expect = .{ .fail_with = error.Truncated },
    },
    // 14. "truncated zlib stream amid fixed-block".
    .{
        .desc = "truncated zlib stream amid fixed-block",
        .source = &hex("789cf248cd"),
        .expect = .{ .fail_with = error.Truncated },
    },
    // 15. The boundary the exact consumption exposes (README, "Streaming"):
    // two empty streams back to back. Nothing in the format promises a
    // second stream, but a caller loop at the boundary decodes it.
    .{
        .desc = "empty stream x2 (the boundary is exact)",
        .source = &hex("789c030000000001789c030000000001"),
        .expect = .{ .ok = "" },
        .trailing = .{ .ok = "" },
    },
};

/// Zig 0.16 std's in-tree zlib vectors (MIT): the stored "Hello world\n"
/// stream, "zlib should not overshoot" (four bytes after the trailer stay
/// unconsumed), and the header failures. The fixed and dynamic streams are
/// std's gzip bodies with zlib's framing (header `78 9c`, the payload's
/// big-endian Adler-32), verified against the C reference.
pub const std_cases: []const Case = &.{
    .{
        .desc = "std: zlib stored block (type 0)",
        .source = &hex("789c010c00f3ff48656c6c6f20776f726c640a1cf20447"),
        .expect = .{ .ok = "Hello world\n" },
    },
    .{
        .desc = "std: zlib fixed block (type 1)",
        .source = &hex("789cf348cdc9c95728cf2fca49e102001cf20447"),
        .expect = .{ .ok = "Hello world\n" },
    },
    .{
        .desc = "std: zlib dynamic block (type 2)",
        .source = &hex("789c3dc6391100000c02302bb5521eff963816965c1e94cb6d01303304d3"),
        .expect = .{ .ok = "ABCDEABCD ABCDEABCD" },
    },
    // "zlib should not overshoot": the stream ends at ADLER32's last byte
    // (`8b 61 0f a4`); the four bytes behind it (`52 5a 94 12`) stay
    // unconsumed — a fresh reader at the boundary sees `52` as CM 2.
    .{
        .desc = "std: zlib should not overshoot",
        .source = &hex("789c73ce2fa82cca4ccf285108cfccc949cd55284bcc53084ece48ccccd65108" ++
            "cecc4b4f2cc82f4a5530b4b434d5b53403008b610fa4525a9412"),
        .expect = .{ .ok = "Copyright Willem van Schaik, Singapore 1995-96" },
        .trailing = .{ .fail_with = error.BadHeader },
    },
    .{
        .desc = "std: zlib header, wrong CM",
        .source = &hex("7994"),
        .expect = .{ .fail_with = error.BadHeader },
    },
    .{
        .desc = "std: zlib header, wrong CINFO",
        .source = &hex("8898"),
        .expect = .{ .fail_with = error.BadHeader },
    },
    .{
        .desc = "std: zlib truncated header",
        .source = &hex("78"),
        .expect = .{ .fail_with = error.Truncated },
    },
    .{
        .desc = "std: zlib truncated checksum",
        .source = &hex("78da030000"),
        .expect = .{ .fail_with = error.Truncated },
    },
};

/// The C reference's dictionary + FLEVEL-0 emission (oracle-verified,
/// `containers-notes.md §5.5`):
/// `zlib.compressobj(0, DEFLATED, 15, 9, Z_DEFAULT_STRATEGY, dict)` over a
/// 225-byte payload. The header is `78 3f` — FCHECK = 31, which is 0 mod 31
/// and fits the five-bit field, so it is conformant and must pass the FCHECK
/// check (T5); the FDICT flag then lands on `DictionaryRequired`, never
/// `BadHeader`. DICTID `fa 2c 0d 48` is the Adler-32 of the dictionary
/// ("she sells seashells by the seashore\n"); the body is a stored block of
/// the payload; the trailer `d2 8c 50 c4` is the payload's Adler-32.
pub const t5_corner_dict_stream = hex(
    "783ffa2c0d4801e1001eff54686520717569636b2062726f776e20666f78206a" ++
        "756d7073206f76657220746865206c617a7920646f672e205468652071756963" ++
        "6b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920" ++
        "646f672e2054686520717569636b2062726f776e20666f78206a756d7073206f" ++
        "76657220746865206c617a7920646f672e2054686520717569636b2062726f77" ++
        "6e20666f78206a756d7073206f76657220746865206c617a7920646f672e2054" ++
        "686520717569636b2062726f776e20666f78206a756d7073206f766572207468" ++
        "65206c617a7920646f672e20d28c50c4",
);

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

/// Assert the deterministic header on an emitted stream: CMF = 0x78 (CM=8,
/// CINFO=7), FLG = the level's FLEVEL band plus the minimal FCHECK, FDICT
/// clear, and `(CMF*256 + FLG) % 31 == 0` (§2.2).
pub fn expectHeader(stream: []const u8, level: encode.Level) !void {
    try testing.expect(stream.len >= encode.header_len + encode.trailer_len);
    try testing.expectEqual(@as(u8, 0x78), stream[0]);
    try testing.expectEqual(encode.flgFor(level), stream[1]);
    try testing.expectEqual(
        @as(u16, 0),
        (@as(u16, stream[0]) * 256 + @as(u16, stream[1])) % 31,
    );
    // ZE2 — the encoder never sets FDICT.
    try testing.expectEqual(@as(u8, 0), stream[1] & 0x20);
}

/// Assert the trailer on an emitted stream: the Adler-32 of `source`,
/// big-endian (§2.1, §2.2). The reference is std's Adler-32 kernel over the
/// same bytes, so this pins the container's byte accounting (every byte
/// exactly once, in order).
pub fn expectTrailer(stream: []const u8, source: []const u8) !void {
    try testing.expect(stream.len >= encode.trailer_len);
    const trailer = stream[stream.len - encode.trailer_len ..];
    try testing.expectEqual(
        std.hash.Adler32.hash(source),
        readInt(u32, trailer[0..4]),
    );
    try testing.expectEqual(
        adler32.adler32(1, source),
        readInt(u32, trailer[0..4]),
    );
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1950-zlib.txt §2.1 (byte order), §2.2
// (the header, FLEVEL, FCHECK, the trailer), §2.3 (decoder obligations),
// §8.2 (the Adler-32 algorithm), §9 (the sample).
// ---------------------------------------------------------------------------

test "golden decode: golang/go zlibTests" {
    // The primary zlib conformance table, whose own comment says the golden
    // bytes came from the C reference's zpipe.c. Valid streams, the FDICT
    // vectors with this module's refusal, the excess-data boundary, and the
    // corrupt/truncated vectors with their pinned errors. Every decode is
    // sentinel-checked.
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 2048 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (zlib_cases) |tc| {
        const cap = switch (tc.expect) {
            .ok => |want| want.len,
            else => window.len,
        };
        checkOneShot(window, cap, tc.source, tc.expect) catch |err| {
            print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "golden decode: the std in-tree streams" {
    // Zig 0.16 std's zlib tests (MIT, in-tree): stored, fixed, dynamic, the
    // exact-consumption vector, and the header failures.
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 512 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (std_cases) |tc| {
        const cap = switch (tc.expect) {
            .ok => |want| want.len,
            else => window.len,
        };
        checkOneShot(window, cap, tc.source, tc.expect) catch |err| {
            print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "golden decode: the T5 corner passes FCHECK and lands on the dictionary" {
    // RFC 1950 §2.2 requires only that (CMF*256 + FLG) be a multiple of 31;
    // the C reference's naive emission writes FCHECK = 31 in the FDICT +
    // FLEVEL-0 corner (`78 3f`), which a re-deriving validator rejects
    // (T5). The header check must accept it — the stream is FDICT, so the
    // contract's answer is `DictionaryRequired`.
    try testing.expectEqual(@as(u16, 0), 0x783f % 31);
    try testing.expectError(
        error.DictionaryRequired,
        decode.checkHeader(t5_corner_dict_stream[0], t5_corner_dict_stream[1]),
    );
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 256 + @as(usize, sentinel.len));
    defer gpa.free(window);
    try checkOneShot(window, window.len, &t5_corner_dict_stream, .{
        .fail_with = error.DictionaryRequired,
    });
}

test "golden decode: the oracle-verified emissions" {
    // The C-reference emissions pinned by the research (containers-notes.md
    // §5.5, every line run and round-tripped): the level bands' FLEVEL
    // values, the dict + FLEVEL-0 corner's `78 3f`, and the DICTID and
    // trailer byte order (both big-endian, §2.1).
    const data = "The quick brown fox jumps over the lazy dog. " ** 5;
    // Level bands: {0,1} -> FLEVEL 0 (`78 01`), {2-5} -> 1 (`78 5e`),
    // {6,-1} -> 2 (`78 9c`), {7-9} -> 3 (`78 da`).
    try testing.expectEqual(@as(u8, 0x01), encode.flgFor(.@"0"));
    try testing.expectEqual(@as(u8, 0x01), encode.flgFor(.@"1"));
    try testing.expectEqual(@as(u8, 0x5e), encode.flgFor(.@"3"));
    try testing.expectEqual(@as(u8, 0x9c), encode.flgFor(.fast));
    try testing.expectEqual(@as(u8, 0x9c), encode.flgFor(.@"6"));
    try testing.expectEqual(@as(u8, 0xda), encode.flgFor(.@"9"));

    // The dictionary stream: DICTID is the dictionary's Adler-32, and the
    // trailer is the payload's — both stored most-significant-byte first.
    const dictionary = "she sells seashells by the seashore\n";
    try testing.expectEqual(
        @as(u32, 0xFA2C0D48),
        readInt(u32, t5_corner_dict_stream[2..6]),
    );
    try testing.expectEqual(@as(u32, 0xFA2C0D48), adler32.adler32(1, dictionary));
    try testing.expectEqual(
        std.hash.Adler32.hash(data),
        readInt(u32, t5_corner_dict_stream[t5_corner_dict_stream.len - 4 ..]),
    );
    // The payload's Adler-32 is the value C zlib writes: 0xd28c50c4.
    try testing.expectEqual(@as(u32, 0xD28C50C4), std.hash.Adler32.hash(data));
}

test "golden decode: the std divergence pins (T4, T6)" {
    // Zig 0.16 std's zlib parse checks CM and CINFO only
    // (`std/compress/flate/Decompress.zig:310-314`): no FCHECK validation,
    // no FDICT handling, and its footer is read into `container_metadata`
    // and never compared (T4). Running std's own decoder here pins both
    // divergences: std accepts `78 9f`, which ours rejects `BadHeader`, and
    // it misparses an FDICT stream's DICTID as deflate data (the Go
    // dictionary vector fails `OversubscribedHuffmanTree`), where ours is
    // the specific `DictionaryRequired` before any body byte.
    var buf: [64]u8 = undefined;
    const bad_fcheck = "\x78\x9f\x03\x00\x00\x00\x00\x01";
    try testing.expectEqual(@as(usize, 0), try stdDecode(bad_fcheck, &buf));
    try testing.expectError(error.BadHeader, decode.decompress(bad_fcheck, &buf));

    try testing.expectError(error.ReadFailed, stdDecode(&dictionary_stream, &buf));
    try testing.expectError(error.DictionaryRequired, decode.decompress(&dictionary_stream, &buf));
}

/// std's in-tree zlib decoder over `source` (the divergence pins run it to
/// show what std accepts). Returns the decoded length into `target`, or the
/// interface's coarse error.
fn stdDecode(source: []const u8, target: []u8) !usize {
    var input: std.Io.Reader = .fixed(source);
    var output: std.Io.Writer = .fixed(target);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    return decompress.reader.streamRemaining(&output);
}
