//! zlib.decode: the one-shot stream decoder, the header check both layers
//! share, and the trailer check (README.md, "API" and "The stream format").
//!
//! The header is two bytes and an arithmetic check (`checkHeader`): CM, CINFO,
//! FCHECK, and the FDICT refusal — never a silent skip of the DICTID the flag
//! announces (`§2.3`, ZD3/ZD4). The trailer check is one function, so both
//! layers report the same specific errors (`WrongChecksum`, T4). The one-shot
//! drives the streaming `Reader` over the whole source, exactly as the gzip
//! sibling does: the header parse, the body's exact end, and the trailer
//! verification all run through one funnel, and the one-shot maps the
//! recorded detail back to this module's error set.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const common = @import("common.zig");
const readInt = common.readInt;
const flate = @import("../flate/root.zig");
const encode = @import("encode.zig");
const Reader = @import("Reader.zig");
const golden = @import("golden.zig");

/// RFC 1950 §2.2 — the header's length: CMF and FLG.
pub const header_len = 2;

/// RFC 1950 §2.2 — the trailer's length: ADLER32.
pub const trailer_len = 4;

/// The one-shot decoder's error set (README, "API"): flate's decode detail
/// set plus this module's header and trailer entries. `BufferTooSmall` is
/// flate's (a stream that does not fit the caller's cap).
pub const DecompressError = flate.decode.DecompressError || error{
    BadHeader, // CM != 8, CINFO > 7, or FCHECK (§2.2, §2.3)
    DictionaryRequired, // FDICT set: no preset-dictionary support (§2.3)
    WrongChecksum, // ADLER32 mismatch (§2.2, §2.3)
};

/// The header check's own failures; the drivers add `Truncated` when the
/// input ends mid-header.
pub const HeaderError = error{
    BadHeader,
    DictionaryRequired,
};

/// RFC 1950 §2.2 — the FLG bits: FCHECK in 0-4, FDICT is bit 5, FLEVEL in
/// 6-7. FDICT is the one the decoder acts on (`§2.3`); FLEVEL "may [be
/// ignored] and still be compliant" (`§2.3`).
pub const flg_fdict = 0x20;

/// Check the header pair (`§2.2`, `§2.3`), in the order a conformant decoder
/// must: CM, CINFO, and FCHECK are `BadHeader`; FDICT is the dictionary
/// refusal.
///
/// - CM (CMF's low four bits) must be 8: "another value could indicate the
///   presence of new features that would cause subsequent data to be
///   interpreted incorrectly" (`§2.3`).
/// - CINFO (CMF's high four bits) must be at most 7: "values of CINFO above
///   7 are not allowed in this version" (`§2.2`).
/// - FCHECK is validated as `(CMF*256 + FLG) % 31 == 0` — **never by
///   re-deriving the value and comparing** (T5): the references emit
///   FCHECK = 31 in the FDICT + FLEVEL-0 corner (C zlib and Go write
///   `78 3f`), which a re-deriving validator rejects; 31 ≡ 0 mod 31 and fits
///   the five-bit field, so it is conformant (`§2.2`).
/// - FDICT set is `DictionaryRequired`, before any body byte: RFC 1950's
///   compliance section makes rejecting a dictionary stream conformant when
///   the embedding format has no dictionary registry (`§2.3`), and the four
///   DICTID bytes are never read, never interpreted as deflate data (ZD3,
///   ZD4, T6).
pub fn checkHeader(cmf: u8, flg: u8) HeaderError!void {
    if (cmf & 0x0f != 8) return error.BadHeader;
    if (cmf >> 4 > 7) return error.BadHeader;
    if ((@as(u16, cmf) * 256 + @as(u16, flg)) % 31 != 0) return error.BadHeader;
    if (flg & flg_fdict != 0) return error.DictionaryRequired;
}

/// Read exactly `target.len` bytes from `input`, consuming them: the
/// streaming route for the header and the trailer, one refill at a time (the
/// input's buffer may deliver one byte). A short input is `Truncated`; the
/// input's own failure is `ReadFailed`.
pub fn readExact(input: *Io.Reader, target: []u8) error{ Truncated, ReadFailed }!void {
    for (target) |*byte| {
        input.fill(1) catch |err| switch (err) {
            error.EndOfStream => return error.Truncated,
            error.ReadFailed => return error.ReadFailed,
        };
        byte.* = input.buffer[input.seek];
        input.toss(1);
    }
}

/// Verify the 4-byte trailer against the folded Adler-32 (`§2.2`, `§2.3`):
/// "the Adler-32 checksum of the uncompressed data (excluding any dictionary
/// data)", stored "in most-significant-byte first (network) order". RFC 1950
/// makes the check a decoder MUST: "A compliant decompressor must check CMF,
/// FLG, and ADLER32, and provide an error indication if any of these have
/// incorrect values" (`§2.3`).
pub fn checkTrailer(trailer: *const [trailer_len]u8, adler: u32) error{WrongChecksum}!void {
    if (readInt(u32, trailer[0..4]) != adler) return error.WrongChecksum;
}

/// Decode one complete zlib stream from `source` into `target`. `target` is a
/// cap; the return is the decoded length. The stream is located by exact
/// consumption (OQ2): the body runs through the streaming `Reader`, whose
/// position after the clean end is the trailer — and the trailer is verified
/// against the bytes the decode produced. Bytes after ADLER32 are ignored:
/// "Any data which may appear after ADLER32 are not part of the zlib stream"
/// (`§2.2`), and the one-shot reports no consumed count, so a boundary-aware
/// caller uses the streaming reader (README, "Contracts").
///
/// Zero heap allocation: the streaming reader's 64-KiB window is a stack
/// local. `error.BufferTooSmall` is reported before the overflowing write.
pub fn decompress(source: []const u8, target: []u8) DecompressError!usize {
    var input: Io.Reader = .fixed(source);
    var output: Io.Writer = .fixed(target);
    var buffer: Reader.Buffer = undefined;
    var reader: Reader = .init(&input, &buffer);
    _ = reader.reader.streamRemaining(&output) catch |err| switch (err) {
        // The output cap: `Io.Writer.fixed` reports `WriteFailed` before
        // writing past `target`, and the one-shot's name for that is
        // `BufferTooSmall` (README, "Sizing").
        error.WriteFailed => return error.BufferTooSmall,
        // The detail recorded beside the interface's coarse `ReadFailed`.
        error.ReadFailed => return detail(&reader),
    };
    return output.end;
}

/// The one-shot's view of a streaming failure: the detail recorded in `err`.
/// Three `Reader.Error` entries cannot occur on this path — the one-shot's
/// consumer never asks for contiguous bytes (no `StreamTooLong`), its input
/// is a fixed slice (no input `ReadFailed`), and `streamRemaining` consumes
/// the clean end itself (no `EndOfStream`) — so they are unreachable here.
fn detail(reader: *const Reader) DecompressError {
    const recorded = reader.err.?;
    return switch (recorded) {
        error.StreamTooLong, error.ReadFailed, error.EndOfStream => unreachable,
        else => |err| err,
    };
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1950-zlib.txt §2.1 (byte order), §2.2
// (the header, FCHECK, FLEVEL, the trailer), §2.3 (decoder obligations).
// Every decode is sentinel-checked.
// ---------------------------------------------------------------------------

test "decode: the header check is the §2.2 arithmetic" {
    // RFC 1950 §2.3 — CM: "another value could indicate the presence of new
    // features that would cause subsequent data to be interpreted
    // incorrectly". §2.2 — CINFO above 7 is not allowed; FCHECK is
    // `(CMF*256 + FLG) % 31 == 0`.
    try testing.expectError(error.BadHeader, checkHeader(0x09, 0x15)); // CM 9
    try testing.expectError(error.BadHeader, checkHeader(0x88, 0x98)); // CINFO 8
    try testing.expectError(error.BadHeader, checkHeader(0x78, 0x9f)); // FCHECK
    try testing.expectError(error.BadHeader, checkHeader(0x78, 0x00)); // FCHECK

    // Conformant pairs decode: any CINFO at most 7, any FLEVEL band (`§2.3`:
    // FLEVEL may be ignored), and any FCHECK that satisfies the arithmetic.
    try checkHeader(0x78, 0x9c); // CINFO 7, FLEVEL 2
    try checkHeader(0x78, 0x01); // CINFO 7, FLEVEL 0
    try checkHeader(0x78, 0x5e); // CINFO 7, FLEVEL 1
    try checkHeader(0x78, 0xda); // CINFO 7, FLEVEL 3
    try checkHeader(0x08, 0x1d); // CINFO 0 (a 256-byte window) is legal

    // FDICT set is the dictionary refusal, before any body byte (§2.3,
    // ZD3/ZD4) — and the T5 corner: `78 3f` (FCHECK = 31, C zlib's and Go's
    // FDICT + FLEVEL-0 emission) satisfies the arithmetic and must land on
    // `DictionaryRequired`, never `BadHeader`.
    try testing.expectError(error.DictionaryRequired, checkHeader(0x78, 0xbb));
    try testing.expectError(error.DictionaryRequired, checkHeader(0x78, 0x3f));

    // The order the checks run in: a pair that is both FDICT and bad-FCHECK
    // is `BadHeader` (the fuzz lane's `headerClass` classification).
    try testing.expectError(error.BadHeader, checkHeader(0x78, 0xbf));
}

test "decode: the one-shot decodes the golden table" {
    // The ported golang/go `zlibTests` and std's in-tree zlib vectors: every
    // case through the one-shot decoder, with the pinned outcome and the
    // sentinel overrun rule. The failing cases carry the specific errors the
    // README decided (FDICT -> DictionaryRequired, bad FCHECK -> BadHeader,
    // truncated -> Truncated).
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 2048 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (golden.zlib_cases) |tc| {
        const cap = switch (tc.expect) {
            .ok => |want| want.len,
            else => window.len,
        };
        golden.checkOneShot(window, cap, tc.source, tc.expect) catch |err| {
            std.debug.print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "decode: the std in-tree vectors and the divergence pins" {
    // Zig 0.16 std's container tests (MIT, in-tree) as decoder goldens, plus
    // the divergence pins (T6): std checks neither FCHECK nor FDICT
    // (`std/compress/flate/Decompress.zig:310-314`), so it accepts `78 9f`
    // and misparses an FDICT stream's DICTID as deflate data; ours rejects
    // both, per `§2.2` and `§2.3`.
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 512 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (golden.std_cases) |tc| {
        const cap = switch (tc.expect) {
            .ok => |want| want.len,
            else => window.len,
        };
        golden.checkOneShot(window, cap, tc.source, tc.expect) catch |err| {
            std.debug.print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "decode: the one-shot decodes the golden table's trailing-byte cases" {
    // README, "Contracts" — "Bytes after ADLER32 are ignored by the
    // one-shot": the stream decodes identically with markers, a truncated
    // next stream, or a whole second stream behind it (`§2.2`'s boundary,
    // ZD7).
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 128 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (golden.zlib_cases) |tc| {
        if (tc.trailing == null) continue;
        const want = switch (tc.expect) {
            .ok => |bytes| bytes,
            else => continue,
        };
        golden.checkOneShot(window, want.len, tc.source, tc.expect) catch |err| {
            std.debug.print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "decode: a zero-byte input is Truncated, and so is every prefix" {
    // T2/OQ3's fail-closed reading: no stream began. The fuzz lane's
    // hostile-header pins carry the same expectations; Go's "truncated
    // empty", "not enough data", and the two "amid raw/fixed-block" vectors
    // are the ported forms.
    try testing.expectError(error.Truncated, decompress("", &.{}));
    const empty_stream = "\x78\x9c\x03\x00\x00\x00\x00\x01";
    var i: usize = 0;
    while (i < empty_stream.len) : (i += 1) {
        try testing.expectError(error.Truncated, decompress(empty_stream[0..i], &.{}));
    }
}

test "decode: the trailer check is specific" {
    // RFC 1950 §2.3 — "A compliant decompressor must check CMF, FLG, and
    // ADLER32". A corrupt trailer byte is `WrongChecksum`; a trailer byte
    // missing is `Truncated`.
    var stream: [64]u8 = undefined;
    const source = "hello world\n";
    const len = try encode.compress(source, &stream, .{});
    const window = try testing.allocator.alloc(u8, 64 + @as(usize, sentinel.len));
    defer testing.allocator.free(window);

    for (0..trailer_len) |at| {
        var bad = stream;
        bad[len - trailer_len + at] ^= 0x80;
        try golden.checkOneShot(window, source.len, bad[0..len], .{
            .fail_with = error.WrongChecksum,
        });
    }

    // The intact stream decodes; the same bytes with one trailer byte
    // dropped are `Truncated`.
    try golden.checkOneShot(window, source.len, stream[0..len], .{ .ok = source });
    try golden.checkOneShot(window, source.len, stream[0 .. len - 1], .{
        .fail_with = error.Truncated,
    });
}

test "decode: the T5 corner stream is the reference's emission" {
    // The oracle-emitted dictionary stream (`containers-notes.md §5.5`):
    // `zlib.compressobj(0, DEFLATED, 15, 9, Z_DEFAULT_STRATEGY, dict)` with
    // the C reference's naive FCHECK emits the header `78 3f` — FCHECK = 31,
    // which is 0 mod 31 and fits the five-bit field. A re-deriving validator
    // rejects the whole Go/C-zlib output family here (T5); ours lands on the
    // dictionary refusal, never `BadHeader`.
    try testing.expectError(
        error.DictionaryRequired,
        decompress(&golden.t5_corner_dict_stream, &.{}),
    );
    // The FCHECK arithmetic accepts the pair; the FDICT flag is the refusal.
    try testing.expectError(
        error.DictionaryRequired,
        checkHeader(golden.t5_corner_dict_stream[0], golden.t5_corner_dict_stream[1]),
    );
}

test "decode: a corrupt body fails closed with flate's detail" {
    // RFC 1950 §2.2 — CM=8's "deflate" method is the RFC 1951 document; the
    // body is flate's rules unchanged, and its failures are the module's own
    // (`Truncated`, `InvalidBlockType`, ...).
    var stream: [256]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try encode.compress(source, &stream, .{});
    // BTYPE=11 (reserved, `rfc1951-deflate.txt §3.2.3`) in the first body
    // byte: the body's first three bits are BFINAL, BTYPE.
    stream[header_len] |= 0b110;
    var target: [256]u8 = undefined;
    try testing.expectError(error.InvalidBlockType, decompress(stream[0..len], &target));
}

test "decode: the empty target is a valid cap for an empty stream" {
    // README, "Sizing": `target` is a cap; an empty stream needs none.
    var stream: [32]u8 = undefined;
    const len = try encode.compress("", &stream, .{});
    try testing.expectEqual(@as(usize, 0), try decompress(stream[0..len], &.{}));
}

test "decode: a bomb stream is capped, never an overrun" {
    // README, "Sizing": a stream that does not fit is `BufferTooSmall`,
    // reported before the overflowing write; the bytes past the cap hold.
    var stream: [512]u8 = undefined;
    const source = "A" ** 4096;
    const len = try encode.compress(source, &stream, .{});
    try testing.expect(len < stream.len);

    var window: [4096 + @as(usize, sentinel.len)]u8 = undefined;
    try golden.checkOneShot(&window, source.len - 1, stream[0..len], .{
        .fail_with = error.BufferTooSmall,
    });
    try golden.checkOneShot(&window, source.len, stream[0..len], .{ .ok = source });
}
