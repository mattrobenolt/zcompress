//! gzip.decode: the one-shot member decoder, the header parser both layers
//! share, and the trailer check (README.md, "API" and "The member format").
//!
//! The header parse is a byte-fed state machine (`HeaderParser`): the one-shot
//! drives it over the whole source, the streaming `Reader` over the input's
//! buffered chunks, and neither stages an optional field — the extra field
//! and the name/comment scans fold the bytes into the header CRC as they
//! pass, so a 65,535-byte XLEN cannot amplify memory (T7, OQ6). The trailer
//! check is one function, so both layers report the same specific errors
//! (`WrongChecksum`, `WrongSize`, T4).

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const flate = @import("../flate/root.zig");
const crc32 = @import("crc32.zig");
const encode = @import("encode.zig");
const Reader = @import("Reader.zig");
const golden = @import("golden.zig");

/// RFC 1952 §2.3 — the fixed header's length: the 10 bytes of §2.3.1.
pub const header_len = 10;

/// RFC 1952 §2.3 — the trailer's length: CRC32 and ISIZE (`§2.3.1`).
pub const trailer_len = 8;

/// The FNAME/FCOMMENT NUL-scan cap (T7): Go's house rule (`gunzip.go:145`),
/// not a spec rule — the RFC bounds nothing. At most this many bytes are
/// scanned for the terminator; none found is `HeaderTooLong`.
pub const name_comment_cap = 512;

/// The one-shot decoder's error set (README, "API"): flate's decode detail
/// set plus this module's header and trailer entries. `BufferTooSmall` is
/// flate's (a member that does not fit the caller's cap).
pub const DecompressError = flate.decode.DecompressError || error{
    BadHeader, // ID1/ID2/CM wrong, or a reserved FLG bit (§2.3.1.2)
    HeaderTooLong, // FNAME/FCOMMENT past the 512-byte cap (T7)
    WrongHeaderChecksum, // FHCRC mismatch (§2.3.1)
    WrongChecksum, // CRC32 mismatch (§2.3.1)
    WrongSize, // ISIZE mismatch (§2.3.1)
};

/// The header parser's own failures; the drivers add `Truncated` when the
/// input ends mid-header.
pub const HeaderError = error{
    BadHeader,
    HeaderTooLong,
    WrongHeaderChecksum,
};

/// RFC 1952 §2.3.1 — the FLG bits. Bits 5-7 are reserved and must be zero
/// (`§2.3.1.2`); FTEXT is advisory and ignorable on decode.
pub const flg_ftext = 0x01;
pub const flg_fhcrc = 0x02;
pub const flg_fextra = 0x04;
pub const flg_fname = 0x08;
pub const flg_fcomment = 0x10;
pub const flg_reserved = 0xe0;

/// The member header parser (`§2.3.1`): a byte-fed state machine over the
/// field order of `§2.3` — the 10 fixed bytes, FEXTRA, FNAME, FCOMMENT,
/// FHCRC. Bytes are folded into the header CRC-32 as they are consumed
/// (FHCRC is its low 16 bits, `§2.3.1`), and the optional fields are never
/// staged: a hostile XLEN or an unterminated name costs bounded work and no
/// memory (T7, OQ6).
pub const HeaderParser = struct {
    /// The field being consumed, in `§2.3`'s order.
    stage: Stage = .fixed,
    /// The 10 fixed header bytes (`§2.3.1`), as they arrive.
    fixed: [header_len]u8 = undefined,
    /// The FLG byte: the optional-field presence bits (`§2.3.1`).
    flags: u8 = 0,
    /// Bytes of the current fixed-width field consumed (XLEN, FHCRC).
    taken: usize = 0,
    /// XLEN (`§2.3.1.1`): the extra field's length, little-endian (`§2.1`).
    extra_len: u16 = 0,
    /// The extra field's bytes already skipped.
    skipped: usize = 0,
    /// The NUL-scan bytes consumed in the current FNAME/FCOMMENT field,
    /// terminator included (the cap counts both).
    scanned: usize = 0,
    /// The header CRC-32 so far: FHCRC's expected value is its low 16 bits
    /// (`§2.3.1`).
    crc: u32 = 0,
    /// The FHCRC value read from the wire.
    fhcrc: u16 = 0,

    /// The field being consumed.
    pub const Stage = enum { fixed, xlen, extra, name, comment, fhcrc, done };

    /// Whether the header is complete.
    pub fn done(parser: *const HeaderParser) bool {
        return parser.stage == .done;
    }

    /// Feed `bytes` to the parser and return the bytes consumed. The parser
    /// consumes as much as the current field needs; a caller with more input
    /// feeds again (the streaming route), and a caller with the whole member
    /// feeds once. Every non-`done` stage consumes at least one byte of a
    /// non-empty slice, so a driver always makes progress.
    pub fn feed(parser: *HeaderParser, bytes: []const u8) HeaderError!usize {
        var consumed: usize = 0;
        while (consumed < bytes.len and parser.stage != .done) {
            const taken = try parser.step(bytes[consumed..]);
            assert(taken > 0);
            consumed += taken;
        }
        return consumed;
    }

    /// One field's worth of progress; `bytes` is non-empty.
    fn step(parser: *HeaderParser, bytes: []const u8) HeaderError!usize {
        return switch (parser.stage) {
            .fixed => parser.stepFixed(bytes),
            .xlen => parser.stepXlen(bytes),
            .extra => parser.stepExtra(bytes),
            .name, .comment => parser.stepString(bytes),
            .fhcrc => parser.stepFhcrc(bytes),
            .done => unreachable,
        };
    }

    /// The 10 fixed bytes (`§2.3.1`): ID1/ID2/CM are checked as they arrive
    /// (`§2.3.1.2`: "must check ID1, ID2, and CM, and provide an error
    /// indication"); a reserved FLG bit is `BadHeader` ("such a bit could
    /// indicate the presence of a new field that would cause subsequent data
    /// to be interpreted incorrectly"). MTIME, XFL, and OS are informational
    /// and may be ignored (`§2.3.1.2`).
    fn stepFixed(parser: *HeaderParser, bytes: []const u8) HeaderError!usize {
        const byte = bytes[0];
        switch (parser.taken) {
            0 => if (byte != 0x1f) return error.BadHeader, // ID1
            1 => if (byte != 0x8b) return error.BadHeader, // ID2
            2 => if (byte != 8) return error.BadHeader, // CM: deflate
            3 => {
                parser.flags = byte;
                if (byte & flg_reserved != 0) return error.BadHeader;
            },
            else => {},
        }
        parser.fixed[parser.taken] = byte;
        parser.crc = crc32.crc32(parser.crc, bytes[0..1]);
        parser.taken += 1;
        if (parser.taken == header_len) parser.enterOptional();
        return 1;
    }

    /// XLEN (`§2.3.1.1`): the extra field's length, u16 little-endian
    /// (`§2.1`). The subfield structure (SI1/SI2/LEN) needs no parse — the
    /// field is skipped, and `§2.3.1.2` requires only that it be examined
    /// enough to skip it.
    fn stepXlen(parser: *HeaderParser, bytes: []const u8) HeaderError!usize {
        const byte = bytes[0];
        if (parser.taken == 0) {
            parser.extra_len = byte;
        } else {
            parser.extra_len |= @as(u16, byte) << 8;
            parser.skipped = 0;
            if (parser.extra_len == 0) parser.enterName() else parser.stage = .extra;
        }
        parser.crc = crc32.crc32(parser.crc, bytes[0..1]);
        parser.taken += 1;
        return 1;
    }

    /// The extra field's bytes, skipped streaming from the input and folded
    /// into the header CRC: never staged (T7, OQ6).
    fn stepExtra(parser: *HeaderParser, bytes: []const u8) HeaderError!usize {
        const remaining = @as(usize, parser.extra_len) - parser.skipped;
        const take = @min(remaining, bytes.len);
        parser.crc = crc32.crc32(parser.crc, bytes[0..take]);
        parser.skipped += take;
        if (parser.skipped == parser.extra_len) parser.enterName();
        return take;
    }

    /// FNAME and FCOMMENT (`§2.3.1`): NUL-terminated Latin-1, scanned for
    /// the terminator with the 512-byte cap (T7). The bytes, terminator
    /// included, are header bytes for FHCRC (`§2.3.1`). A name or comment
    /// longer than the cap is `HeaderTooLong`; the strings' contents are not
    /// the container's business.
    fn stepString(parser: *HeaderParser, bytes: []const u8) HeaderError!usize {
        const room = name_comment_cap - parser.scanned;
        const chunk = bytes[0..@min(room, bytes.len)];
        const terminator = mem.findScalar(u8, chunk, 0);
        const take = if (terminator) |at| at + 1 else chunk.len;
        parser.crc = crc32.crc32(parser.crc, chunk[0..take]);
        parser.scanned += take;
        if (terminator != null) {
            switch (parser.stage) {
                .name => parser.enterComment(),
                else => parser.enterFhcrc(),
            }
        } else if (parser.scanned == name_comment_cap) {
            return error.HeaderTooLong;
        }
        return take;
    }

    /// FHCRC (`§2.3.1`): "the two least significant bytes of the CRC32 for
    /// all bytes of the gzip header up to and not including the CRC16",
    /// u16 little-endian. RFC 1952 requires only that the field be skippable
    /// (`§2.3.1.2`); we verify it (T3), and the header is complete here.
    fn stepFhcrc(parser: *HeaderParser, bytes: []const u8) HeaderError!usize {
        const byte = bytes[0];
        if (parser.taken == 0) {
            parser.fhcrc = byte;
        } else {
            parser.fhcrc |= @as(u16, byte) << 8;
            if (@as(u16, @truncate(parser.crc)) != parser.fhcrc) return error.WrongHeaderChecksum;
            parser.stage = .done;
        }
        parser.taken += 1;
        return 1;
    }

    /// The optional fields begin after the fixed header, in `§2.3`'s order.
    fn enterOptional(parser: *HeaderParser) void {
        if (parser.flags & flg_fextra != 0) {
            parser.stage = .xlen;
            parser.taken = 0;
            return;
        }
        parser.enterName();
    }

    /// FNAME follows FEXTRA (`§2.3`).
    fn enterName(parser: *HeaderParser) void {
        if (parser.flags & flg_fname != 0) {
            parser.stage = .name;
            parser.scanned = 0;
            return;
        }
        parser.enterComment();
    }

    /// FCOMMENT follows FNAME (`§2.3`).
    fn enterComment(parser: *HeaderParser) void {
        if (parser.flags & flg_fcomment != 0) {
            parser.stage = .comment;
            parser.scanned = 0;
            return;
        }
        parser.enterFhcrc();
    }

    /// FHCRC follows FCOMMENT (`§2.3`) and ends the header.
    fn enterFhcrc(parser: *HeaderParser) void {
        if (parser.flags & flg_fhcrc != 0) {
            parser.stage = .fhcrc;
            parser.taken = 0;
            return;
        }
        parser.stage = .done;
    }
};

/// Verify the 8-byte trailer against the folded checksum state (`§2.3.1`):
/// CRC-32 (ISO 3309) and ISIZE, the input size mod 2^32, both u32
/// little-endian (`§2.1`). The two are kept separate — Go collapses both
/// into `ErrChecksum` (`gunzip.go:267`); ours report which half failed (T4).
pub fn checkTrailer(
    trailer: *const [trailer_len]u8,
    crc: u32,
    len: u32,
) error{ WrongChecksum, WrongSize }!void {
    if (mem.readInt(u32, trailer[0..4], .little) != crc) return error.WrongChecksum;
    if (mem.readInt(u32, trailer[4..8], .little) != len) return error.WrongSize;
}

/// Decode one complete gzip member from `source` into `target`. `target` is
/// a cap; the return is the decoded length. The member is located by exact
/// consumption (OQ2): the body runs through the streaming `Reader` over the
/// fixed input, whose position after the clean end is the trailer — and the
/// trailer is verified against the bytes the decode produced. Bytes after
/// the trailer are ignored: the one-shot reports no consumed count, so a
/// boundary-aware caller uses the streaming reader (README, "Contracts").
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

/// The one-shot's view of a streaming failure: the detail recorded in
/// `err`. Three `Reader.Error` entries cannot occur on this path — the
/// one-shot's consumer never asks for contiguous bytes (no `StreamTooLong`),
/// its input is a fixed slice (no input `ReadFailed`), and `streamRemaining`
/// consumes the clean end itself (no `EndOfStream`) — so they are
/// unreachable here.
fn detail(reader: *const Reader) DecompressError {
    const recorded = reader.err.?;
    return switch (recorded) {
        error.StreamTooLong, error.ReadFailed, error.EndOfStream => unreachable,
        else => |err| err,
    };
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1952-gzip.txt §2.1 (byte order), §2.2
// (members), §2.3 (the member), §2.3.1 (the fixed header, the optional
// fields, FHCRC, the trailer), §2.3.1.1 (FEXTRA), §2.3.1.2 (decoder
// obligations).
// ---------------------------------------------------------------------------

/// Parse a whole header from `source` and return the parser.
fn parseHeader(source: []const u8) HeaderError!HeaderParser {
    var parser: HeaderParser = .{};
    const consumed = try parser.feed(source);
    assert(parser.done());
    assert(consumed == source.len);
    return parser;
}

/// The empty member's 10-byte fixed header (`§2.3.1`): FLG=0, MTIME=0,
/// XFL=4, OS=255.
const empty_header = [header_len]u8{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 4, 255 };

test "decode: the fixed header parses, and its fields are ignorable" {
    // RFC 1952 §2.3.1 — ID1/ID2/CM fixed; MTIME, XFL, and OS are
    // informational on decode ("may ignore FTEXT and OS and always produce
    // binary output", §2.3.1.2), as is FTEXT.
    const parser = try parseHeader(&empty_header);
    try testing.expectEqual(@as(u8, 0), parser.flags);
    try testing.expectEqual(crc32.crc32(0, &empty_header), parser.crc);

    var ignorable = empty_header;
    ignorable[3] = flg_ftext; // FTEXT, advisory
    for (4..header_len) |at| { // MTIME, XFL, OS
        var bytes = empty_header;
        bytes[at] = 0xff;
        _ = try parseHeader(&bytes);
    }
    _ = try parseHeader(&ignorable);
}

test "decode: the magic, CM, and reserved FLG bits fail closed" {
    // RFC 1952 §2.3.1.2 — "must check ID1, ID2, and CM, and provide an error
    // indication"; a non-zero reserved FLG bit "could indicate the presence
    // of a new field that would cause subsequent data to be interpreted
    // incorrectly".
    for (0..3) |at| {
        var bytes = empty_header;
        bytes[at] ^= 0xff;
        try testing.expectError(error.BadHeader, parseHeader(&bytes));
    }
    for ([_]u8{ 0x20, 0x40, 0x80, 0xe0 }) |bit| {
        var bytes = empty_header;
        bytes[3] = bit;
        try testing.expectError(error.BadHeader, parseHeader(&bytes));
    }
}

test "decode: the extra field is skipped with the XLEN bound" {
    // RFC 1952 §2.3.1.1 — XLEN is a u16 little-endian length; the subfields
    // are skipped, not interpreted (§2.3.1.2 examines them only "so it can
    // skip over the optional fields"). A 65,535-byte XLEN costs bounded
    // work: the bytes are consumed streaming, never staged (T7, OQ6).
    const extra = "z" ** 0xffff;
    const header = try testing.allocator.alloc(u8, header_len + 2 + extra.len);
    defer testing.allocator.free(header);
    fastmem.copy(u8, header[0..header_len], &empty_header);
    header[3] = flg_fextra;
    mem.writeInt(u16, header[header_len..][0..2], 0xffff, .little);
    fastmem.copy(u8, header[header_len + 2 ..], extra);
    const parser = try parseHeader(header);
    try testing.expectEqual(@as(u16, 0xffff), parser.extra_len);
    try testing.expectEqual(crc32.crc32(0, header), parser.crc);

    // One byte short of the declared XLEN: the field is incomplete, so the
    // parser has not finished (the driver reports `Truncated`).
    var partial: HeaderParser = .{};
    _ = try partial.feed(header[0 .. header.len - 1]);
    try testing.expect(!partial.done());

    // A zero XLEN is an empty extra field, not an absent one.
    var zero: [header_len + 2]u8 = undefined;
    fastmem.copy(u8, zero[0..header_len], &empty_header);
    zero[3] = flg_fextra;
    mem.writeInt(u16, zero[header_len..][0..2], 0, .little);
    const zero_parser = try parseHeader(&zero);
    try testing.expectEqual(@as(u16, 0), zero_parser.extra_len);
}

test "decode: FNAME and FCOMMENT are NUL-scanned with the 512-byte cap" {
    // RFC 1952 §2.3.1 — the fields are NUL-terminated; the cap is the house
    // rule (T7, Go's `gunzip.go:145`). The terminator counts as a header
    // byte for FHCRC, and 511 bytes of name plus the terminator is inside
    // the cap while 512 without one is `HeaderTooLong`.
    const name = "n" ** 511;
    const header = try testing.allocator.alloc(u8, header_len + name.len + 1);
    defer testing.allocator.free(header);
    fastmem.copy(u8, header[0..header_len], &empty_header);
    header[3] = flg_fname;
    fastmem.copy(u8, header[header_len..][0..name.len], name);
    header[header.len - 1] = 0;
    const parser = try parseHeader(header);
    try testing.expectEqual(@as(usize, name.len + 1), parser.scanned);
    try testing.expectEqual(crc32.crc32(0, header), parser.crc);

    // 512 bytes with no terminator: past the cap.
    const long = try testing.allocator.alloc(u8, header_len + name_comment_cap);
    defer testing.allocator.free(long);
    fastmem.copy(u8, long[0..header_len], &empty_header);
    long[3] = flg_fname;
    fastmem.set(u8, long[header_len..], 'a');
    try testing.expectError(error.HeaderTooLong, parseHeader(long));

    // The same for FCOMMENT, which follows FNAME.
    var comment: [header_len + 2]u8 = undefined;
    fastmem.copy(u8, comment[0..header_len], &empty_header);
    comment[3] = flg_fcomment;
    comment[header_len] = 'c';
    comment[header_len + 1] = 0;
    const comment_parser = try parseHeader(&comment);
    try testing.expectEqual(@as(u8, flg_fcomment), comment_parser.flags);
}

test "decode: FHCRC is verified" {
    // RFC 1952 §2.3.1 — FHCRC is "the two least significant bytes of the
    // CRC32 for all bytes of the gzip header up to and not including the
    // CRC16". A right value completes the header; a wrong one is
    // `WrongHeaderChecksum` (T3: the RFC requires only a skip, we verify).
    var header: [header_len + 2]u8 = undefined;
    fastmem.copy(u8, header[0..header_len], &empty_header);
    header[3] = flg_fhcrc;
    const value: u16 = @truncate(crc32.crc32(0, header[0..header_len]));
    mem.writeInt(u16, header[header_len..][0..2], value, .little);
    const parser = try parseHeader(&header);
    try testing.expectEqual(value, parser.fhcrc);

    header[header_len] ^= 0x01;
    try testing.expectError(error.WrongHeaderChecksum, parseHeader(&header));
}

test "decode: the parser is feed-boundary independent" {
    // The streaming layer feeds the parser in arbitrary chunks; the result
    // must not depend on where they are cut (the all-fields vector: FEXTRA +
    // FNAME + FCOMMENT + FHCRC, §2.3.1).
    // The complete header: the member minus the 5-byte stored body and the
    // 8-byte trailer (the FHCRC field is inside it).
    const source = golden.gunzip_cases[10].source;
    const full_header_len = source.len - 13;
    const whole = try parseHeader(source[0..full_header_len]);
    var chunked: HeaderParser = .{};
    var at: usize = 0;
    while (!chunked.done()) {
        const n = @min(7, full_header_len - at);
        const consumed = try chunked.feed(source[at..][0..n]);
        at += consumed;
    }
    try testing.expectEqual(full_header_len, at);
    try testing.expectEqual(whole.crc, chunked.crc);
    try testing.expectEqual(whole.flags, chunked.flags);
    try testing.expectEqual(@as(u16, 0xfd92), chunked.fhcrc);
}

test "decode: the one-shot decodes the golden table's trailing-byte cases" {
    // README, "Contracts" — "Bytes after the trailer are ignored by the
    // one-shot": the member decodes identically with garbage, a truncated
    // next header, or a whole second member behind it (§2.2's boundary,
    // T2/OQ3).
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 128 + sentinel.len);
    defer gpa.free(window);
    for (golden.gunzip_cases) |tc| {
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

test "decode: a zero-byte input is Truncated" {
    // T2/OQ3 — the fail-closed reading: no member began. (Go accepts an
    // empty file as a zero-member stream, CPython accepts it, the gzip CLI
    // errors; ours is the CLI's reading, recorded in the research.)
    try testing.expectError(error.Truncated, decompress("", &.{}));
    try testing.expectError(error.Truncated, decompress(&[_]u8{0x1f}, &.{}));
}

test "decode: the trailer checks are specific" {
    // RFC 1952 §2.3.1 — CRC32 and ISIZE. A corrupt CRC byte is
    // `WrongChecksum`, a corrupt ISIZE byte is `WrongSize` (T4: Go collapses
    // both into ErrChecksum; ours keep which half failed).
    var member: [golden_max]u8 = undefined;
    const source = "hello world\n";
    const len = try encode.compress(source, &member, .{});
    const window = try testing.allocator.alloc(u8, 64 + sentinel.len);
    defer testing.allocator.free(window);

    for (0..trailer_len) |at| {
        var bad = member;
        bad[len - trailer_len + at] ^= 0x80;
        const want: DecompressError = if (at < 4) error.WrongChecksum else error.WrongSize;
        try golden.checkOneShot(window, source.len, bad[0..len], .{ .fail_with = want });
    }

    // The intact member decodes; the same bytes with one trailer byte
    // dropped are `Truncated`.
    try golden.checkOneShot(window, source.len, member[0..len], .{ .ok = source });
    try golden.checkOneShot(window, source.len, member[0 .. len - 1], .{
        .fail_with = error.Truncated,
    });
}

/// The widest member the local tests build (the golden vectors' payloads).
const golden_max = 2048;

test "decode: the all-fields member's header is skipped, not interpreted" {
    // RFC 1952 §2.3.1 — a decoder must examine FEXTRA/FNAME/FCOMMENT/FHCRC
    // "at least enough to skip the optional fields"; the reader surfaces no
    // header metadata. The vector's FHCRC is right, so the member decodes to
    // the empty payload.
    const source = golden.gunzip_cases[10].source;
    var empty: [0]u8 = .{};
    try testing.expectEqual(@as(usize, 0), try decompress(source, &empty));
}

test "decode: a corrupt body fails closed with flate's detail" {
    // RFC 1952 §2.3.1.2 — CM=8's method is "documented elsewhere": the body
    // is flate's rules unchanged, and its failures are the module's own
    // (`Truncated`, `InvalidBlockType`, ...).
    var member: [256]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try encode.compress(source, &member, .{});
    // BTYPE=11 (reserved, §3.2.3 of RFC 1951) in the first body byte: the
    // body's first three bits are BFINAL, BTYPE.
    member[header_len] |= 0b110;
    var target: [256]u8 = undefined;
    try testing.expectError(error.InvalidBlockType, decompress(member[0..len], &target));
}

test "decode: the empty target is a valid cap for an empty member" {
    // README, "Sizing": `target` is a cap; an empty member needs none.
    var member: [32]u8 = undefined;
    const len = try encode.compress("", &member, .{});
    try testing.expectEqual(@as(usize, 0), try decompress(member[0..len], &.{}));
}

test "decode: a bomb member is capped, never an overrun" {
    // README, "Sizing": a member that does not fit is `BufferTooSmall`,
    // reported before the overflowing write; the bytes past the cap hold.
    var member: [512]u8 = undefined;
    const source = "A" ** 4096;
    const len = try encode.compress(source, &member, .{});
    try testing.expect(len < member.len);

    var window: [4096 + @as(usize, sentinel.len)]u8 = undefined;
    try golden.checkOneShot(&window, source.len - 1, member[0..len], .{
        .fail_with = error.BufferTooSmall,
    });
    try golden.checkOneShot(&window, source.len, member[0..len], .{ .ok = source });
}
