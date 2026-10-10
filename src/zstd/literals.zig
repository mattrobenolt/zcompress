//! The literals section of a compressed block (`§3.1.1.3.1`): the 1-5 byte
//! header, the four Literals_Block_Types (`§3.1.1.3.1.1`, Table 13), the
//! Huffman streams, and the cross-block table a Treeless_Literals_Block
//! reuses.
//!
//! The literals section is the first part of a compressed block; the rest is
//! the sequences section, whose size is derived from this one
//! (`§3.1.1.3.2`: "Sequences_Section_Size = Block_Size -
//! Literals_Section_Header - Literals_Section_Content"), so `decode` returns
//! the decoded literals *and* the block bytes the section consumed. That is
//! the whole hand-off to the block slice: it passes the block's remaining
//! content, the literals scratch, and the frame's `State`; it takes back the
//! literals and `bytes_consumed`, and the sequences section is the content
//! from there.
//!
//! The four types (`§3.1.1.3.1.1`):
//!
//! - **Raw** (0): "Literals are stored uncompressed"; the content is
//!   Regenerated_Size bytes (`§3.1.1.3.1.2`) — one `fastmem.copy`.
//! - **RLE** (1): "Literals consist of a single-byte value repeated
//!   Regenerated_Size times" (`§3.1.1.3.1.3`) — one `fastmem.set`, bounded
//!   by the declared size and by the target.
//! - **Compressed** (2): a Huffman_Tree_Description (`§3.1.1.3.1.5`,
//!   `§4.2.1`) followed by 1 or 4 Huffman-coded streams (`§3.1.1.3.1.6`).
//!   The tree's decode table becomes the frame's literals state.
//! - **Treeless** (3): the streams only; the tree is the previous
//!   Compressed_Literals_Block's ("The Huffman tree comes from the previous
//!   Compressed_Literals_Block", `§3.1.1.3`). Without one it "should be
//!   treated as data corruption" (`§3.1.1.3.1.1`) — `TreelessLiteralsFirst`.
//!
//! The stream layout is `§3.1.1.3.1.6`: one stream occupies the entire
//! remaining content; four streams carry a 6-byte Jump_Table of u16-LE
//! compressed sizes for the first three, with `Stream4_Size =
//! Total_Streams_Size - 6 - Stream1_Size - Stream2_Size - Stream3_Size`, and
//! each stream's decompressed size is `(Regenerated_Size+3)/4` "except for
//! the last stream, which may be up to 3 bytes smaller". 4-stream mode needs
//! >= 6 regenerated literals — errata 7297 (`docs/research/zstd-notes.md`
//! §4 T4); below 6 the fourth stream's share underflows, so the section is
//! `LiteralsTooLarge` whatever the streams say.
//!
//! The header (`§3.1.1.3.1.1`, Table 12) is "a byte-aligned variable-size
//! bit field, ranging from 1 to 5 bytes, using little-endian convention":
//! the 2-bit block type, a 1-2 bit Size_Format, Regenerated_Size (5-20 bits),
//! and for the compressed family Compressed_Size (10-18 bits, which
//! "includes the size of the Huffman_Tree_Description when it is present").
//! In the 5-byte format the Compressed_Size's top 8 bits live in the fifth
//! byte — a corner the slice-1 Python mirror caught before this port
//! (`parseHeader` reads all five bytes, and the parse test pins a
//! Compressed_Size above 1023).
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const common = @import("common.zig");
const huff0 = @import("huff0.zig");
const golden = @import("golden.zig");
const internal = @import("../internal/root.zig");

/// Everything the literals layer reports.
pub const Error = error{
    /// The 1-5 byte literals header (`§3.1.1.3.1.1`): a source too short for
    /// the Size_Format its first byte declares.
    MalformedLiteralsHeader,
    /// A declared size beyond what the block or the target can hold: a
    /// Regenerated_Size or Compressed_Size past the block content, a
    /// Regenerated_Size past the caller's target, a 4-stream Jump_Table
    /// whose sizes exceed the streams region, or a 4-stream section below
    /// errata 7297's 6 regenerated literals.
    LiteralsTooLarge,
    /// Treeless literals with no previous Huffman table in the frame
    /// (`§3.1.1.3.1.1`).
    TreelessLiteralsFirst,
} || huff0.Error;

/// The two lowest bits of the header's first byte (`§3.1.1.3.1.1`, Table 13).
pub const BlockType = enum(u2) {
    raw = 0,
    rle = 1,
    compressed = 2,
    treeless = 3,
};

/// `§3.1.1.3.1.6` — "The Jump_Table is 6 bytes long and consists of three
/// 2-byte little-endian fields".
pub const jump_table_len = 6;

/// Errata 7297 (`§3.1.1.3.1.6`; `docs/research/zstd-notes.md` §4 T4) — the
/// 4-stream size ranges are 6-1023 / 6-16383 / 6-262143, not 0-based: below
/// 6 the fourth stream's `(Regenerated_Size+3)/4` share underflows. The C
/// enforces it as `MIN_LITERALS_FOR_4_STREAMS`.
pub const min_literals_for_4streams = 6;

/// A parsed Literals_Section_Header (`§3.1.1.3.1.1`, Table 12).
pub const Header = struct {
    block_type: BlockType,
    /// The Size_Format field; its width and meaning follow the block type's
    /// family (`§3.1.1.3.1.1`).
    size_format: u2,
    /// Regenerated_Size: the literals the section decodes to (5-20 bits).
    regenerated_size: u20,
    /// Compressed_Size: the section's content length for the compressed
    /// family — "includes the size of the Huffman_Tree_Description when it
    /// is present" (`§3.1.1.3.1.1`) — 10-18 bits. Zero for Raw and RLE,
    /// which carry no such field.
    compressed_size: u18,
    /// The header's own length in bytes: 1-5.
    header_len: usize,
};

/// Parse a Literals_Section_Header (`§3.1.1.3.1.1`, Table 12). A source too
/// short for the form the first byte declares is `MalformedLiteralsHeader`.
pub fn parseHeader(source: []const u8) error{MalformedLiteralsHeader}!Header {
    if (source.len < 1) return error.MalformedLiteralsHeader;
    const byte0 = source[0];
    const block_type: BlockType = @enumFromInt(byte0 & 0b11);
    const size_format: u2 = @intCast((byte0 >> 2) & 0b11);
    return switch (block_type) {
        .raw, .rle => parseRawSizes(block_type, size_format, source),
        .compressed, .treeless => parseCompressedSizes(block_type, size_format, source),
    };
}

/// The Raw/RLE size family (`§3.1.1.3.1.1`): "it's only necessary to decode
/// Regenerated_Size. There is no Compressed_Size field." Size_Format 00 and
/// 10 are the same 1-byte form (5 bits, `Header[0]>>3`), 01 is 2 bytes
/// (12 bits), 11 is 3 bytes (20 bits).
fn parseRawSizes(
    block_type: BlockType,
    size_format: u2,
    source: []const u8,
) error{MalformedLiteralsHeader}!Header {
    switch (size_format) {
        0, 2 => return .{
            .block_type = block_type,
            .size_format = size_format,
            .regenerated_size = source[0] >> 3,
            .compressed_size = 0,
            .header_len = 1,
        },
        1 => {
            if (source.len < 2) return error.MalformedLiteralsHeader;
            return .{
                .block_type = block_type,
                .size_format = size_format,
                .regenerated_size = @truncate((headerBits(source, 2) >> 4) & 0xfff),
                .compressed_size = 0,
                .header_len = 2,
            };
        },
        3 => {
            if (source.len < 3) return error.MalformedLiteralsHeader;
            return .{
                .block_type = block_type,
                .size_format = size_format,
                .regenerated_size = @truncate((headerBits(source, 3) >> 4) & 0xfffff),
                .compressed_size = 0,
                .header_len = 3,
            };
        },
    }
}

/// The Compressed/Treeless size family (`§3.1.1.3.1.1`): "it's required to
/// decode both Compressed_Size and Regenerated_Size (the decompressed size).
/// It's also necessary to decode the number of streams (1 or 4)."
/// Size_Format 00 is a 3-byte header with a single stream, 01 a 3-byte
/// header with four (10-bit fields); 10 is 4 bytes (14 bits); 11 is 5 bytes
/// (18 bits) — and there the Compressed_Size's top 8 bits are the fifth
/// byte.
fn parseCompressedSizes(
    block_type: BlockType,
    size_format: u2,
    source: []const u8,
) error{MalformedLiteralsHeader}!Header {
    switch (size_format) {
        0, 1 => {
            if (source.len < 3) return error.MalformedLiteralsHeader;
            const bits = headerBits(source, 3);
            return .{
                .block_type = block_type,
                .size_format = size_format,
                .regenerated_size = @truncate((bits >> 4) & 0x3ff),
                .compressed_size = @truncate((bits >> 14) & 0x3ff),
                .header_len = 3,
            };
        },
        2 => {
            if (source.len < 4) return error.MalformedLiteralsHeader;
            const bits = headerBits(source, 4);
            return .{
                .block_type = block_type,
                .size_format = size_format,
                .regenerated_size = @truncate((bits >> 4) & 0x3fff),
                .compressed_size = @truncate((bits >> 18) & 0x3fff),
                .header_len = 4,
            };
        },
        3 => {
            if (source.len < 5) return error.MalformedLiteralsHeader;
            const bits = headerBits(source, 5);
            return .{
                .block_type = block_type,
                .size_format = size_format,
                .regenerated_size = @truncate((bits >> 4) & 0x3ffff),
                .compressed_size = @truncate((bits >> 22) & 0x3ffff),
                .header_len = 5,
            };
        },
    }
}

/// The header's first `len` bytes as one little-endian bit field
/// (`§3.1.1.3.1.1`: "In this representation, bits at the top are the lowest
/// bits", and "For values spanning several bytes, the convention is little
/// endian"), zero-extended past the bytes read.
fn headerBits(source: []const u8, len: usize) u40 {
    assert(len >= 1);
    assert(len <= 5);
    assert(source.len >= len);
    var bits: u40 = 0;
    for (source[0..len], 0..) |byte, index| {
        bits |= @as(u40, byte) << @intCast(8 * index);
    }
    return bits;
}

/// The literals layer's cross-block state (`§3.1.1.3`): the decode table of
/// the frame's most recent Compressed_Literals_Block, which a
/// Treeless_Literals_Block reuses ("The Huffman tree comes from the previous
/// Compressed_Literals_Block"). One per frame, threaded through the block
/// loop; only a Compressed block updates it, and Raw, RLE, and Treeless
/// blocks leave it alone.
pub const State = struct {
    /// `null` until the frame's first Compressed_Literals_Block decodes;
    /// Treeless before that is `TreelessLiteralsFirst`.
    table: ?huff0.DecodeTable = null,
};

/// One decoded literals section.
pub const Section = struct {
    /// The literals: Regenerated_Size bytes, a prefix of the caller's
    /// target — exactly what Sequence Execution copies from (`§3.1.1.4`).
    bytes: []u8,
    /// How much of the block content the section consumed: the header, the
    /// tree description when present, the Jump_Table, and the streams. The
    /// sequences section starts here (`§3.1.1.3.2`).
    bytes_consumed: usize,
};

/// Decode one literals section from the front of `source` (a compressed
/// block's content) into `target` (the caller's literals scratch, up to the
/// block maximum), updating `state` when the section is Compressed.
///
/// Every path is bounded: the decoded literals never exceed
/// Regenerated_Size, Regenerated_Size never exceeds `target.len`, and every
/// read stays inside the block content — a declaration that would break
/// either is `LiteralsTooLarge`, before any write.
pub fn decode(source: []const u8, target: []u8, state: *State) Error!Section {
    const header = try parseHeader(source);
    const content = source[header.header_len..];
    const section = switch (header.block_type) {
        .raw => try decodeRaw(header, content, target),
        .rle => try decodeRle(header, content, target),
        .compressed => try decodeCompressed(header, content, target, state),
        .treeless => try decodeTreeless(header, content, target, state),
    };
    // Postconditions: a section never writes past the target and never
    // consumes past the block it was handed.
    assert(section.bytes.len <= target.len);
    assert(section.bytes_consumed <= source.len);
    return section;
}

/// `§3.1.1.3.1.2`: "The data in Stream_1 is Regenerated_Size bytes long. It
/// contains the raw literals data to be used during Sequence Execution".
fn decodeRaw(header: Header, content: []const u8, target: []u8) Error!Section {
    const regenerated_size: usize = header.regenerated_size;
    if (regenerated_size > content.len) return error.LiteralsTooLarge;
    if (regenerated_size > target.len) return error.LiteralsTooLarge;
    fastmem.copy(u8, target[0..regenerated_size], content[0..regenerated_size]);
    return .{
        .bytes = target[0..regenerated_size],
        .bytes_consumed = header.header_len + regenerated_size,
    };
}

/// `§3.1.1.3.1.3`: "Stream_1 consists of a single byte that should be
/// repeated Regenerated_Size times to generate the decoded literals."
///
/// The amplification limit: Regenerated_Size is a declared size (up to
/// 2^20 - 1), and the splat is bounded by it *and* by the caller's target —
/// a declared size the target cannot hold fails closed with
/// `LiteralsTooLarge` and writes nothing.
fn decodeRle(header: Header, content: []const u8, target: []u8) Error!Section {
    const regenerated_size: usize = header.regenerated_size;
    if (content.len < 1) return error.LiteralsTooLarge;
    if (regenerated_size > target.len) return error.LiteralsTooLarge;
    fastmem.set(u8, target[0..regenerated_size], content[0]);
    return .{
        .bytes = target[0..regenerated_size],
        .bytes_consumed = header.header_len + 1,
    };
}

/// `§3.1.1.3.1.4`: "Both of these modes contain Huffman-coded data" — a
/// Huffman_Tree_Description, then 1 or 4 streams (`§3.1.1.3.1.5`,
/// `§3.1.1.3.1.6`).
fn decodeCompressed(
    header: Header,
    content: []const u8,
    target: []u8,
    state: *State,
) Error!Section {
    const compressed_size: usize = header.compressed_size;
    if (compressed_size > content.len) return error.LiteralsTooLarge;
    const compressed = content[0..compressed_size];
    // §3.1.1.3.1.5: "Total_Streams_Size = Compressed_Size -
    // Huffman_Tree_Description_Size". The description is read from the
    // front of the compressed region, so a description that does not fit in
    // Compressed_Size is a malformed weight series, not an overread of the
    // block.
    const tree = try huff0.readTree(compressed);
    const table = huff0.buildTable(&tree);
    try decodeStreams(header, compressed[tree.bytes_consumed..], target, &table);
    // The state the next block sees is a table whose own block decoded
    // whole; a failed decode leaves the frame failed, never a partial state.
    state.table = table;
    return .{
        .bytes = target[0..header.regenerated_size],
        .bytes_consumed = header.header_len + compressed_size,
    };
}

/// Treeless_Literals_Block (`§3.1.1.3.1.1`): "This is a Huffman-compressed
/// block, using the Huffman tree from the previous Compressed_Literals_Block
/// ... Huffman_Tree_Description will be skipped." Without a previous table
/// "it should be treated as data corruption" — `TreelessLiteralsFirst`.
fn decodeTreeless(
    header: Header,
    content: []const u8,
    target: []u8,
    state: *State,
) Error!Section {
    const compressed_size: usize = header.compressed_size;
    if (compressed_size > content.len) return error.LiteralsTooLarge;
    const table = state.table orelse return error.TreelessLiteralsFirst;
    try decodeStreams(header, content[0..compressed_size], target, &table);
    return .{
        .bytes = target[0..header.regenerated_size],
        .bytes_consumed = header.header_len + compressed_size,
    };
}

/// The 1-or-4-stream layout (`§3.1.1.3.1.6`) over a tree the caller
/// resolved: Size_Format 00 is one stream, every other format is four.
fn decodeStreams(
    header: Header,
    streams: []const u8,
    target: []u8,
    table: *const huff0.DecodeTable,
) Error!void {
    const regenerated_size: usize = header.regenerated_size;
    // The amplification limit: a section never writes past its declared
    // Regenerated_Size, and never past the caller's target.
    if (regenerated_size > target.len) return error.LiteralsTooLarge;
    if (header.size_format == 0) {
        // "If only 1 stream is present, it is a single bitstream occupying
        // the entire remaining portion of the literals block, encoded as
        // described within Section 4.2.2."
        return huff0.decodeStream(table, streams, target[0..regenerated_size]);
    }
    // Errata 7297: 4-stream mode needs >= 6 regenerated literals; below that
    // the fourth stream's share would underflow.
    if (regenerated_size < min_literals_for_4streams) return error.LiteralsTooLarge;
    return decodeFourStreams(streams, target[0..regenerated_size], table);
}

/// The four-stream layout (`§3.1.1.3.1.6`): the Jump_Table, then four
/// independently decoded Huffman streams.
fn decodeFourStreams(
    streams: []const u8,
    target: []u8,
    table: *const huff0.DecodeTable,
) Error!void {
    assert(target.len >= min_literals_for_4streams);
    // "The Jump_Table is 6 bytes long and consists of three 2-byte
    // little-endian fields, describing the compressed sizes of the first 3
    // streams."
    if (streams.len < jump_table_len) return error.LiteralsTooLarge;
    const stream1_len: usize = common.readInt(u16, streams[0..2]);
    const stream2_len: usize = common.readInt(u16, streams[2..4]);
    const stream3_len: usize = common.readInt(u16, streams[4..6]);
    const streams_len = streams.len - jump_table_len;
    // "Note that if Stream1_Size + Stream2_Size + Stream3_Size exceeds
    // Total_Streams_Size, the data are considered corrupted."
    if (stream1_len + stream2_len + stream3_len > streams_len) return error.LiteralsTooLarge;
    const stream1_start = jump_table_len;
    const stream2_start = stream1_start + stream1_len;
    const stream3_start = stream2_start + stream2_len;
    const stream4_start = stream3_start + stream3_len;
    // "The decompressed size of each stream is equal to
    // (Regenerated_Size+3)/4, except for the last stream, which may be up to
    // 3 bytes smaller, to reach a total decompressed size as specified in
    // Regenerated_Size." (The last slice runs to the target's end, so its
    // length is `Regenerated_Size - 3 * segment_len`.)
    const segment_len = (target.len + 3) / 4;
    try huff0.decodeStream(
        table,
        streams[stream1_start..stream2_start],
        target[0..segment_len],
    );
    try huff0.decodeStream(
        table,
        streams[stream2_start..stream3_start],
        target[segment_len .. 2 * segment_len],
    );
    try huff0.decodeStream(
        table,
        streams[stream3_start..stream4_start],
        target[2 * segment_len .. 3 * segment_len],
    );
    try huff0.decodeStream(table, streams[stream4_start..], target[3 * segment_len ..]);
}

/// Hand-built literals sections over the T1 tree (`golden.t1_tree`), each
/// verified end-to-end with the zstd CLI v1.5.7: the section sits in a
/// one-block frame (magic, descriptor 0x00, a 1 KB window descriptor, the
/// compressed block, then the zero-sequence byte) whose decoded output is
/// exactly the expected literals. The streams carry symbols 0-5 of the T1
/// tree, whose codes are 1, 01, 001, 0000, 0001 (`§4.2.1.3`, Table 25).
const four_stream_body: [16]u8 = .{
    0x84, 0x43, 0x20, 0x10, // the T1 tree
    0x01, 0x00, 0x02, 0x00, 0x02, 0x00, // Jump_Table: 1, 2, 2
    0x69, // stream 1: 0, 1, 2
    0x03, 0x02, // stream 2: 4, 5, 0
    0x49, 0x02, // stream 3: 2, 2, 2
    0x03, // stream 4: 0
};
/// The same body under the 3-, 4-, and 5-byte compressed headers
/// (Size_Format 01, 10, 11): rs = 10, cs = 16.
const four_stream_sf1: [19]u8 = [3]u8{ 0xa6, 0x00, 0x04 } ++ four_stream_body;
const four_stream_sf2: [20]u8 = [4]u8{ 0xaa, 0x00, 0x40, 0x00 } ++ four_stream_body;
const four_stream_sf3: [21]u8 = [5]u8{ 0xae, 0x00, 0x00, 0x04, 0x00 } ++ four_stream_body;
const four_stream_expected = [_]u8{ 0, 1, 2, 4, 5, 0, 2, 2, 2, 0 };

/// The last-stream padding corner: rs = 7 splits as 2/2/2/1 (the fourth
/// stream decodes one symbol); rs = 6 as 2/2/2/0, the fourth stream being
/// the end marker alone (`§4.2.2`'s final 1 bit with no useful bits). Both
/// carry the T1 tree, a Jump_Table of (1, 2, 1), and the streams for
/// [0, 1] [4, 5] [2, 0] plus the fourth's one symbol (0x10) or end
/// marker (0x01).
const four_stream_rs7: [18]u8 = .{
    0x76, 0xc0, 0x03, 0x84, 0x43, 0x20, 0x10, 0x01, 0x00, 0x02, 0x00, 0x01,
    0x00, 0x0d, 0x01, 0x01, 0x13, 0x10,
};
const four_stream_rs7_expected = [_]u8{ 0, 1, 4, 5, 2, 0, 4 };
const four_stream_rs6: [18]u8 = .{
    0x66, 0xc0, 0x03, 0x84, 0x43, 0x20, 0x10, 0x01, 0x00, 0x02, 0x00, 0x01,
    0x00, 0x0d, 0x01, 0x01, 0x13, 0x01,
};
const four_stream_rs6_expected = [_]u8{ 0, 1, 4, 5, 2, 0 };

/// Errata 7297's corner: the same body under a Size_Format 01 header
/// declaring rs = 5. The CLI v1.5.7 rejects the frame ("Header of Literals'
/// block ..."), and so does this layer — before any stream is decoded.
const four_stream_below_min: [19]u8 = [3]u8{ 0x56, 0x00, 0x04 } ++ four_stream_body;

/// A Jump_Table claiming 4 + 4 + 4 of the 6 stream bytes (`§3.1.1.3.1.6`:
/// "if Stream1_Size + Stream2_Size + Stream3_Size exceeds
/// Total_Streams_Size, the data are considered corrupted").
const jump_table_overflow: [19]u8 = [3]u8{ 0xa6, 0x00, 0x04 } ++ [16]u8{
    0x84, 0x43, 0x20, 0x10, 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x69, 0x03, 0x02, 0x49, 0x02, 0x03,
};
/// cs = 8: the tree, then four bytes where the 6-byte Jump_Table belongs.
const jump_table_truncated: [11]u8 = .{
    0xa6, 0x00, 0x02, 0x84, 0x43, 0x20, 0x10, 0x01, 0x00, 0x02, 0x00,
};

/// A Treeless section reusing the T1 tree: Size_Format 00, rs = 4, cs = 2
/// (the T1 stream alone). Hand-built and CLI-verified as one frame with a
/// preceding Compressed block.
const treeless_section: [5]u8 = .{ 0x43, 0x80, 0x00, 0x01, 0x0d };

/// Decode one hand-built section with a sentinel-filled target and check the
/// literals, the consumed count, and the untouched tail (AGENTS.md,
/// "Rules": every decode test proves no write past the decoded length).
fn expectDecode(section: []const u8, expected: []const u8) !void {
    var target: [1280]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    const decoded = try decode(section, &target, &state);
    try testing.expectEqualSlices(u8, expected, decoded.bytes);
    try testing.expectEqual(section.len, decoded.bytes_consumed);
    try internal.sentinel.expect(&target, decoded.bytes.len);
}

test "parseHeader reads the Raw and RLE size formats" {
    // RFC 8878 §3.1.1.3.1.1 — Size_Format 00 or 10 is the 1-byte form with
    // a 5-bit Regenerated_Size (`Header[0]>>3`); 01 is 2 bytes with 12 bits;
    // 11 is 3 bytes with 20 bits. The type field is the two lowest bits.
    // In the 1-byte form the Size_Format field is one bit wide, so bit 2 is
    // Regenerated_Size's own low bit: rs = 20 reads Size_Format 00 and
    // rs = 21 (the same byte plus bit 2) reads 10.
    const one = try parseHeader(&.{0b1010_0000});
    try testing.expectEqual(BlockType.raw, one.block_type);
    try testing.expectEqual(@as(u2, 0), one.size_format);
    try testing.expectEqual(@as(u20, 20), one.regenerated_size);
    try testing.expectEqual(@as(usize, 1), one.header_len);
    const two = try parseHeader(&.{0b1010_1000});
    try testing.expectEqual(BlockType.raw, two.block_type);
    try testing.expectEqual(@as(u2, 2), two.size_format);
    try testing.expectEqual(@as(u20, 21), two.regenerated_size);
    try testing.expectEqual(@as(usize, 1), two.header_len);
    const twelve = try parseHeader(&.{ 0xc4, 0xab });
    try testing.expectEqual(@as(u20, 0xabc), twelve.regenerated_size);
    try testing.expectEqual(@as(usize, 2), twelve.header_len);
    const twenty = try parseHeader(&.{ 0xec, 0xcd, 0xab });
    try testing.expectEqual(@as(u20, 0xabcde), twenty.regenerated_size);
    try testing.expectEqual(@as(usize, 3), twenty.header_len);
    const rle = try parseHeader(&.{0b1111_1001});
    try testing.expectEqual(BlockType.rle, rle.block_type);
    try testing.expectEqual(@as(u20, 31), rle.regenerated_size);
    try testing.expectEqual(@as(u18, 0), rle.compressed_size);
}

test "parseHeader reads the compressed size formats, the fifth byte included" {
    // RFC 8878 §3.1.1.3.1.1 — the Compressed/Treeless family always uses
    // two Size_Format bits: 00 is a 3-byte header with one stream, 01 a
    // 3-byte header with four (10-bit fields); 10 is 4 bytes (14 bits); 11
    // is 5 bytes (18 bits). The sizes are adjacent little-endian fields, so
    // in the 5-byte form the Compressed_Size's top 8 bits are the *fifth*
    // byte — the corner the slice-1 mirror caught (docs/research/
    // zstd-notes.md, the slice-1 report).
    const t1 = try parseHeader(&.{ 0x42, 0x80, 0x01 });
    try testing.expectEqual(BlockType.compressed, t1.block_type);
    try testing.expectEqual(@as(u2, 0), t1.size_format);
    try testing.expectEqual(@as(u20, 4), t1.regenerated_size);
    try testing.expectEqual(@as(u18, 6), t1.compressed_size);
    try testing.expectEqual(@as(usize, 3), t1.header_len);
    const four = try parseHeader(&.{ 0x46, 0x90, 0x12 });
    try testing.expectEqual(@as(u2, 1), four.size_format);
    try testing.expectEqual(@as(u20, 260), four.regenerated_size);
    try testing.expectEqual(@as(u18, 74), four.compressed_size);
    try testing.expectEqual(@as(usize, 3), four.header_len);
    const fourteen = try parseHeader(&.{ 0x6a, 0x40, 0x30, 0x04 });
    try testing.expectEqual(@as(u2, 2), fourteen.size_format);
    try testing.expectEqual(@as(u20, 1030), fourteen.regenerated_size);
    try testing.expectEqual(@as(u18, 268), fourteen.compressed_size);
    try testing.expectEqual(@as(usize, 4), fourteen.header_len);
    // rs = 1000, cs = 1026: byte 4 (0x01) carries cs's bits 10-17, and a
    // four-byte read would recover cs = 2.
    const eighteen = try parseHeader(&.{ 0x8e, 0x3e, 0x80, 0x00, 0x01 });
    try testing.expectEqual(@as(u2, 3), eighteen.size_format);
    try testing.expectEqual(@as(u20, 1000), eighteen.regenerated_size);
    try testing.expectEqual(@as(u18, 1026), eighteen.compressed_size);
    try testing.expectEqual(@as(usize, 5), eighteen.header_len);
    // The same bytes with the type field 11 are Treeless.
    const treeless = try parseHeader(&.{ 0x8f, 0x3e, 0x80, 0x00, 0x01 });
    try testing.expectEqual(BlockType.treeless, treeless.block_type);
    try testing.expectEqual(@as(u18, 1026), treeless.compressed_size);
}

test "parseHeader rejects a source shorter than the format it declares" {
    // RFC 8878 §3.1.1.3.1.1 — the header is 1 to 5 bytes; a source too short
    // for the Size_Format its first byte declares is MalformedLiteralsHeader,
    // never a read past the block.
    try testing.expectError(error.MalformedLiteralsHeader, parseHeader(&.{}));
    // Raw/RLE: the 2- and 3-byte forms.
    try testing.expectError(error.MalformedLiteralsHeader, parseHeader(&.{0b0000_0100}));
    try testing.expectError(error.MalformedLiteralsHeader, parseHeader(&.{ 0b0000_1100, 0x00 }));
    // Compressed/Treeless: 3, 4, and 5-byte forms.
    try testing.expectError(error.MalformedLiteralsHeader, parseHeader(&.{ 0x42, 0x80 }));
    try testing.expectError(
        error.MalformedLiteralsHeader,
        parseHeader(&.{ 0xaa, 0x00, 0x40 }),
    );
    try testing.expectError(
        error.MalformedLiteralsHeader,
        parseHeader(&.{ 0xae, 0x00, 0x00, 0x04 }),
    );
}

test "decodeRaw copies Regenerated_Size bytes and stops there" {
    // RFC 8878 §3.1.1.3.1.2 — "The data in Stream_1 is Regenerated_Size
    // bytes long. It contains the raw literals data to be used during
    // Sequence Execution". All three Raw size formats decode the same five
    // bytes; the byte after them belongs to the sequences section, not the
    // literals.
    const cases = .{
        .{ .section = &[_]u8{ 0x28, 0xde, 0xad, 0xbe, 0xef, 0x00, 0xff }, .header_len = 1 },
        .{ .section = &[_]u8{ 0x54, 0x00, 0xde, 0xad, 0xbe, 0xef, 0x00, 0xff }, .header_len = 2 },
        .{
            .section = &[_]u8{ 0x5c, 0x00, 0x00, 0xde, 0xad, 0xbe, 0xef, 0x00, 0xff },
            .header_len = 3,
        },
    };
    inline for (cases) |case| {
        var target: [8]u8 = undefined;
        internal.sentinel.fill(&target);
        var state: State = .{};
        const section = try decode(case.section, &target, &state);
        try testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef, 0x00 }, section.bytes);
        try testing.expectEqual(case.header_len + 5, section.bytes_consumed);
        try internal.sentinel.expect(&target, section.bytes.len);
    }
}

test "decodeRaw fails closed when the declared size exceeds the block" {
    // RFC 8878 §3.1.1.3.1.2 + §8 — the declared size is bounded by the block
    // content and by the caller's target; both failures write nothing.
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    // rs = 31 declared, 3 content bytes present.
    try testing.expectError(
        error.LiteralsTooLarge,
        decode(&.{ 0xf8, 0xde, 0xad, 0xbe }, &target, &state),
    );
    try internal.sentinel.expect(&target, 0);
    // rs = 9 declared, 5 content bytes present.
    try testing.expectError(
        error.LiteralsTooLarge,
        decode(&.{ 0x48, 1, 2, 3, 4, 5 }, &target, &state),
    );
    try internal.sentinel.expect(&target, 0);
    // rs = 9 fits the block but not an 8-byte target.
    var small: [8]u8 = undefined;
    internal.sentinel.fill(&small);
    try testing.expectError(
        error.LiteralsTooLarge,
        decode(&.{ 0x48, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, &small, &state),
    );
    try internal.sentinel.expect(&small, 0);
}

test "decodeRle repeats the single content byte Regenerated_Size times" {
    // RFC 8878 §3.1.1.3.1.3 — "Stream_1 consists of a single byte that
    // should be repeated Regenerated_Size times to generate the decoded
    // literals."
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    // Size_Format 01: rs = 9, one content byte, then the next section's byte.
    const section = try decode(&.{ 0x95, 0x00, 0x41, 0xff }, &target, &state);
    const expected = [_]u8{0x41} ** 9;
    try testing.expectEqualSlices(u8, &expected, section.bytes);
    try testing.expectEqual(@as(usize, 3), section.bytes_consumed);
    try internal.sentinel.expect(&target, section.bytes.len);
}

test "decodeRle's declared size is an amplification limit" {
    // RFC 8878 §3.1.1.3.1.3 + §8 — a 20-bit Regenerated_Size (up to 1 MiB)
    // is a declared size, not a license: a splat that would overflow the
    // target fails closed and writes nothing.
    var target: [64]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    // Size_Format 11: rs = 0xfffff, content byte 0x41.
    try testing.expectError(
        error.LiteralsTooLarge,
        decode(&.{ 0xfd, 0xff, 0xff, 0x41 }, &target, &state),
    );
    try internal.sentinel.expect(&target, 0);
    // The same declared size with no content byte at all: still closed.
    try testing.expectError(
        error.LiteralsTooLarge,
        decode(&.{ 0xfd, 0xff, 0xff }, &target, &state),
    );
    try internal.sentinel.expect(&target, 0);
}

test "a compressed section's Regenerated_Size beyond the target fails closed" {
    // RFC 8878 §3.1.1.3.1.1 + §8 — the same amplification bound as Raw and
    // RLE: Regenerated_Size is the header's declaration, and a target that
    // cannot hold it fails `LiteralsTooLarge` before any stream is decoded
    // — and before the tree becomes the state the next block would reuse.
    var small: [3]u8 = undefined;
    internal.sentinel.fill(&small);
    var state: State = .{};
    // The T1 section decodes four literals.
    try testing.expectError(
        error.LiteralsTooLarge,
        decode(&golden.t1_literals_section, &small, &state),
    );
    try internal.sentinel.expect(&small, 0);
    try testing.expect(state.table == null);
}

test "decodeCompressed decodes the T1 pair's one-stream sections" {
    // RFC 8878 §3.1.1.3.1.4 + §4.2.2 — the hand-built T1 pair
    // (docs/research/zstd-notes.md §5.4): a direct-weights tree and one
    // stream, decoding to 0, 1, 4, 5. The second section carries the §4.2.2
    // example's own bytes (errata 8195, T1) and decodes to 0, 1, 5, 4.
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    const section = try decode(&golden.t1_literals_section, &target, &state);
    try testing.expectEqualSlices(u8, &golden.t1_literals, section.bytes);
    try testing.expectEqual(golden.t1_literals_section.len, section.bytes_consumed);
    try internal.sentinel.expect(&target, section.bytes.len);
    // The Compressed block's tree is the state the next block sees.
    try testing.expect(state.table != null);

    var errata_target: [16]u8 = undefined;
    internal.sentinel.fill(&errata_target);
    var errata_state: State = .{};
    const errata = try decode(&golden.t1_errata_literals_section, &errata_target, &errata_state);
    try testing.expectEqualSlices(u8, &golden.t1_errata_literals, errata.bytes);
    try internal.sentinel.expect(&errata_target, errata.bytes.len);
}

test "decodeCompressed decodes a real encoder's one-stream section" {
    // RFC 8878 §3.1.1.3.1.1 (Size_Format 00) + §4.2.2 — a zstd v1.5.7
    // frame's literals section (golden.zig's provenance): a direct-weights
    // tree and one Huffman-coded stream, 120 literals from 37 content bytes.
    var target: [256]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    const section = try decode(&golden.literals_1stream_section, &target, &state);
    try testing.expectEqualSlices(u8, &golden.literals_1stream_expected, section.bytes);
    try testing.expectEqual(golden.literals_1stream_section.len, section.bytes_consumed);
    try internal.sentinel.expect(&target, section.bytes.len);
}

test "decodeCompressed decodes a real encoder's four-stream section" {
    // RFC 8878 §3.1.1.3.1.6 — a zstd v1.5.7 frame's literals section: the
    // Jump_Table, four independently decoded streams, 260 literals from 74
    // content bytes.
    var target: [512]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    const section = try decode(&golden.literals_4stream_sf1_section, &target, &state);
    try testing.expectEqualSlices(u8, &golden.literals_4stream_sf1_expected, section.bytes);
    try testing.expectEqual(golden.literals_4stream_sf1_section.len, section.bytes_consumed);
    try internal.sentinel.expect(&target, section.bytes.len);
}

test "decodeCompressed decodes the 14-bit four-stream form" {
    // RFC 8878 §3.1.1.3.1.1 — Size_Format 10, the 4-byte header with 14-bit
    // sizes: a zstd v1.5.7 frame's literals section, 1030 literals from 268
    // content bytes.
    var target: [1100]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    const section = try decode(&golden.literals_4stream_sf2_section, &target, &state);
    try testing.expectEqualSlices(u8, &golden.literals_4stream_sf2_expected, section.bytes);
    try testing.expectEqual(golden.literals_4stream_sf2_section.len, section.bytes_consumed);
    try internal.sentinel.expect(&target, section.bytes.len);
}

test "decodeCompressed reads the tree description before the streams" {
    // RFC 8878 §3.1.1.3.1.5 — "Total_Streams_Size = Compressed_Size -
    // Huffman_Tree_Description_Size": the 20-byte FSE-compressed weight
    // series (golden.weights_description, pinned by huff0's tests) is
    // followed by the Jump_Table and four streams; the streams decode ten
    // 0x62 symbols through that tree.
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    const section = try decode(&golden.literals_fse_tree_section, &target, &state);
    try testing.expectEqualSlices(u8, &golden.literals_fse_tree_expected, section.bytes);
    try testing.expectEqual(golden.literals_fse_tree_section.len, section.bytes_consumed);
    try internal.sentinel.expect(&target, section.bytes.len);
}

test "the 5-byte header's four streams decode" {
    // RFC 8878 §3.1.1.3.1.1 — Size_Format 10 (4 bytes) and 11 (5 bytes) are
    // the 4-stream forms with 14- and 18-bit sizes; the same body decodes
    // under all three compressed headers, and only the header's length
    // differs.
    try expectDecode(&four_stream_sf1, &four_stream_expected);
    try expectDecode(&four_stream_sf2, &four_stream_expected);
    try expectDecode(&four_stream_sf3, &four_stream_expected);
}

test "the jump table's last stream may be up to 3 bytes smaller" {
    // RFC 8878 §3.1.1.3.1.6 — "The decompressed size of each stream is
    // equal to (Regenerated_Size+3)/4, except for the last stream, which may
    // be up to 3 bytes smaller". rs = 7 splits 2/2/2/1; rs = 6 splits
    // 2/2/2/0, the fourth stream being the end marker alone.
    try expectDecode(&four_stream_rs7, &four_stream_rs7_expected);
    try expectDecode(&four_stream_rs6, &four_stream_rs6_expected);
}

test "four-stream mode below 6 regenerated literals is LiteralsTooLarge" {
    // RFC 8878 §3.1.1.3.1.6 + errata 7297 (docs/research/zstd-notes.md §4
    // T4) — the 4-stream ranges start at 6, not 0: below 6 the fourth
    // stream's share underflows. The CLI v1.5.7 rejects this frame at the
    // literals header; the check here runs before any stream is decoded.
    var target: [1280]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    try testing.expectError(
        error.LiteralsTooLarge,
        decode(&four_stream_below_min, &target, &state),
    );
    try internal.sentinel.expect(&target, 0);
    // rs = 0 is below the minimum too, whatever the streams hold.
    try testing.expectError(
        error.LiteralsTooLarge,
        decode(&([3]u8{ 0x06, 0x00, 0x04 } ++ four_stream_body), &target, &state),
    );
    try internal.sentinel.expect(&target, 0);
}

test "the jump table's sizes must fit the streams region" {
    // RFC 8878 §3.1.1.3.1.6 — "if Stream1_Size + Stream2_Size +
    // Stream3_Size exceeds Total_Streams_Size, the data are considered
    // corrupted": a Jump_Table claiming 4 + 4 + 4 of 6 stream bytes is
    // LiteralsTooLarge, and so is a region too short to hold the table.
    var target: [1280]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    try testing.expectError(error.LiteralsTooLarge, decode(&jump_table_overflow, &target, &state));
    try internal.sentinel.expect(&target, 0);
    try testing.expectError(error.LiteralsTooLarge, decode(&jump_table_truncated, &target, &state));
    try internal.sentinel.expect(&target, 0);
}

test "decodeCompressed rejects a Compressed_Size beyond the block" {
    // RFC 8878 §3.1.1.3.1.1 — Compressed_Size is the section's content
    // length; a value past the block content is LiteralsTooLarge, checked
    // before the tree description is read.
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    // cs = 8 declared, 2 content bytes present.
    try testing.expectError(
        error.LiteralsTooLarge,
        decode(&.{ 0x42, 0x80, 0x02, 0x84, 0x43 }, &target, &state),
    );
    try internal.sentinel.expect(&target, 0);
}

test "a tree description that overruns Compressed_Size is malformed weights" {
    // RFC 8878 §3.1.1.3.1.5 + §4.2.1.1 — the tree description lives inside
    // Compressed_Size: a direct header declaring five symbols (4 bytes)
    // inside a 3-byte Compressed_Size is a malformed weight series, not a
    // read into the sequences section.
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    try testing.expectError(
        error.MalformedHuffmanWeights,
        decode(&.{ 0x42, 0xc0, 0x00, 0x84, 0x43, 0x20 }, &target, &state),
    );
    try internal.sentinel.expect(&target, 0);
}

test "decodeTreeless reuses the previous Compressed block's table" {
    // RFC 8878 §3.1.1.3.1.1 — Treeless "us[es] the Huffman tree from the
    // previous Compressed_Literals_Block ... Huffman_Tree_Description will
    // be skipped". The pair is hand-built and verified as one frame with
    // the CLI v1.5.7: a Compressed block (the T1 section), then a Treeless
    // block whose stream is the T1 stream.
    var target: [16]u8 = undefined;
    var state: State = .{};
    internal.sentinel.fill(&target);
    const first = try decode(&golden.t1_literals_section, &target, &state);
    try testing.expectEqualSlices(u8, &golden.t1_literals, first.bytes);
    try internal.sentinel.expect(&target, first.bytes.len);

    var treeless_target: [16]u8 = undefined;
    internal.sentinel.fill(&treeless_target);
    const second = try decode(&treeless_section, &treeless_target, &state);
    try testing.expectEqualSlices(u8, &golden.t1_literals, second.bytes);
    try testing.expectEqual(treeless_section.len, second.bytes_consumed);
    try internal.sentinel.expect(&treeless_target, second.bytes.len);
}

test "decodeTreeless before any Compressed block is TreelessLiteralsFirst" {
    // RFC 8878 §3.1.1.3.1.1 — "if this mode is triggered without any
    // previous Huffman table in the frame ... it should be treated as data
    // corruption". The target stays untouched.
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    try testing.expectError(
        error.TreelessLiteralsFirst,
        decode(&treeless_section, &target, &state),
    );
    try internal.sentinel.expect(&target, 0);
}

test "the treeless table survives intervening Raw and RLE blocks" {
    // RFC 8878 §3.1.1.3 — "The Huffman tree comes from the previous
    // Compressed_Literals_Block": Raw, RLE, and Treeless blocks do not
    // update it, and a Treeless block after either still decodes.
    var target: [16]u8 = undefined;
    var state: State = .{};
    _ = try decode(&golden.t1_literals_section, &target, &state);

    internal.sentinel.fill(&target);
    const raw = try decode(&.{ 0x28, 0xde, 0xad, 0xbe, 0xef, 0x00 }, &target, &state);
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef, 0x00 }, raw.bytes);
    try internal.sentinel.expect(&target, raw.bytes.len);

    internal.sentinel.fill(&target);
    const rle = try decode(&.{ 0x95, 0x00, 0x41 }, &target, &state);
    const expected_rle = [_]u8{0x41} ** 9;
    try testing.expectEqualSlices(u8, &expected_rle, rle.bytes);
    try internal.sentinel.expect(&target, rle.bytes.len);

    internal.sentinel.fill(&target);
    const treeless = try decode(&treeless_section, &target, &state);
    try testing.expectEqualSlices(u8, &golden.t1_literals, treeless.bytes);
    try internal.sentinel.expect(&target, treeless.bytes.len);
}
