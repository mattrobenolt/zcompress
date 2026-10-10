//! The block layer of a zstandard frame (`§3.1.1.2`): the 3-byte
//! Block_Header, the four Block_Types, and the per-block decode that
//! composes the landed literals and sequences layers with the frame's
//! cross-block state.
//!
//! A frame is a chain of blocks — "Each frame must have at least 1 block,
//! but there is no upper limit on the number of blocks per frame"
//! (`§3.1.1.2`) — and each block is a 3-byte little-endian Block_Header
//! followed by Block_Content: Last_Block (bit 0), Block_Type (bits 1-2),
//! Block_Size (bits 3-23) (`§3.1.1.2`, Tables 8-9). Four types
//! (`§3.1.1.2.2`, Table 10):
//!
//! - **Raw_Block** (0): "Block_Content contains Block_Size bytes" — one
//!   `fastmem.copy`.
//! - **RLE_Block** (1): "a single byte, repeated Block_Size times";
//!   Block_Content is that one byte — one `fastmem.set`. The reference CLI
//!   never emits it, so only fixtures cover it (the golden corpus's
//!   `rle-first-block.zst`, and `frame_rle`/`frame_rle_max` here).
//! - **Compressed_Block** (2): Block_Size is "the length of Block_Content,
//!   namely the compressed data. The decompressed size is not known, but
//!   its maximum possible value is guaranteed" — `decodeCompressed` below,
//!   the literals and sequences layers composed (`§3.1.1.3`).
//! - **Reserved** (3): "This is not a block. ... If such a value is
//!   present, it is considered to be corrupt data, and a compliant decoder
//!   must reject it" — `ReservedBlock`.
//!
//! Block_Maximum_Size (`§3.1.1.2.4`) is "the smallest of: Window_Size,
//! 128 KB", "constant for a given frame", and "applicable to both the
//! decompressed size and the compressed size of any block in the frame" —
//! so one `BlockOversize` covers a declared Block_Size past it (every type)
//! and a compressed block whose output would land past it, and the
//! window/block coupling is real: a frame with a small window cannot carry
//! a large block at all (the single-segment `Window_Size = Frame_Content_Size`
//! corner, `docs/research/zstd-notes.md` §4 T7).
//!
//! ## The composition, and the state it threads
//!
//! `decode` is the whole hand-off to the frame layer: it takes the frame's
//! remaining bytes at this block's Block_Header, the frame's output region,
//! how many bytes the frame has decoded so far, the frame's Window_Size, and
//! the two landed layers' states; it returns the block's output length, the
//! bytes it consumed, and the Last_Block flag. Everything the frame layer
//! has to carry lives in the layers' own states and its one running counter:
//!
//! - **The output region.** `target[0..decoded_len]` is the frame's output
//!   so far — the one-shot's `target`, the streaming reader's serving
//!   region — and `target[decoded_len..]` is this block's capacity. A match
//!   may read `min(decoded_len, Window_Size)` bytes back and no further
//!   (`§3.1.1.4`: "all offsets leading to previously decoded data must be
//!   smaller than Window_Size"), so the region the sequences layer sees is
//!   re-based at `decoded_len - history`: the writes still land at
//!   `target[decoded_len..]` while the history bound is the window. That is
//!   the one place the window rule is applied, and it is what lets a 256 KB
//!   frame over a 128 KB window decode with the same call as a 20-byte one
//!   (`frame_window_128k`). The RFC's "smaller than Window_Size" is the
//!   window's addressable span: an offset of exactly Window_Size reads the
//!   oldest retained byte, which the reference family's windowSize-byte
//!   history accepts and the reference encoder can emit (its match search
//!   is bounded by the window). The reference's whole-buffer decoder is
//!   *looser* than this when the bytes are still around — it checks the
//!   available history, not the declared window (`frame_window_*_over` are
//!   frames it decodes and we refuse) — and ours is the fail-closed
//!   reading, the RFC's rule.
//! - **The literals state** (`literals.State`): the Huffman tree a
//!   Treeless_Literals_Block reuses — "The Huffman tree comes from the
//!   previous Compressed_Literals_Block" (`§3.1.1.3`) — one per frame,
//!   updated only by a Compressed_Literals_Block.
//! - **The sequences state** (`sequences.State`): the three decoding tables
//!   a Repeat_Mode reuses and the three repeat offsets, one per frame
//!   (`§3.1.1.3`, `§3.1.1.5`). A Raw or RLE block leaves both states
//!   alone — "blocks that are not Compressed_Block are skipped; they do not
//!   contribute to offset history" (`§3.1.1.5`) — which is why this layer
//!   threads them rather than owning them: only a Compressed_Block with a
//!   nonzero sequence count moves the tables and the offsets, and a
//!   zero-count section leaves them too.
//! - **The window accounting** is the caller's `decoded_len`; the block
//!   layer never accumulates it, so the frame layer's one counter is the
//!   whole story.
//!
//! ## Staging and amplification limits
//!
//! The compressed block is staged before it is decoded, because both
//! backwards bitstreams (the sequences stream, `§3.1.1.3.2.1.2`, and each
//! Huffman literals stream, `§4.2.2`) are read from the block's *end*
//! toward its beginning: the last byte's offset must be known before the
//! first symbol. Here `source` *is* that staged block — a contiguous slice,
//! exactly `Block_Size` bytes of content — so the one-shot passes the input
//! directly and the streaming reader stages the block into its own buffer
//! (`src/zstd/README.md`, "The block and entropy layers"). The literals
//! decode into a comptime `[max_block_size]u8` scratch, bounded by
//! Block_Maximum_Size: the literals are part of the block's output (every
//! one of them lands in it, as sequence literals or trailing literals), so
//! a declared Regenerated_Size past the block maximum is `LiteralsTooLarge`
//! and never a write. Total per-block stack scratch: 128 KB, comptime, zero
//! allocation.
//!
//! The limits this layer owns, each fail-closed before its write:
//!
//! - Block_Size past Block_Maximum_Size is `BlockOversize` (`§3.1.1.2.4`).
//! - A compressed block whose output would pass Block_Maximum_Size is
//!   `BlockOversize` too: the output region is capped at the block maximum
//!   first, so the sequences layer's `BufferTooSmall` means the caller's
//!   cap only when the cap was smaller (`§8`'s amplification vectors).
//! - Raw and RLE block sizes are declarations, not licenses: both copies
//!   are bounded by the caller's remaining capacity, and a declared size
//!   the target cannot hold is `BufferTooSmall` before the write.
//! - Block_Content past the input's end — the header itself included — is
//!   `Truncated`: the input ended inside the frame.
//!
//! ## Errors
//!
//! The public set is the two landed layers' sets composed with this layer's
//! own names — `Truncated`, `BlockOversize`, `ReservedBlock`, and the
//! `BufferTooSmall` the Raw and RLE capacity checks raise (the sequences
//! layer's name for the same class) — so the frame layer's
//! `zstd.decode.DecompressError` is this set plus the frame layer's own
//! (`BadMagic`, `ReservedBitSet`, `DictionaryRequired`,
//! `ContentSizeMismatch`, `WrongChecksum`, ...). Nothing is renamed: a
//! sequence that overruns the window is `OffsetTooFar`, a literals section
//! past the block is `LiteralsTooLarge`, a sequences section cut inside its
//! header is `MalformedSequencesHeader` (the sequences slice's addition,
//! carried into the README's list by this slice).
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const common = @import("common.zig");
const golden = @import("golden.zig");
const internal = @import("../internal/root.zig");
const literals = @import("literals.zig");
const sequences = @import("sequences.zig");

/// `§3.1.1.2.4` — "128 KB": Block_Maximum_Size's ceiling. A frame's own
/// bound is `min(Window_Size, this)`, so this is also the largest block any
/// frame can carry and the block scratch this layer sizes for.
pub const max_block_size: usize = 128 * 1024;

/// `§3.1.1.2`: "Block_Header uses 3 bytes, written using little-endian
/// convention."
pub const block_header_len = 3;

/// Everything the block layer reports: the two landed layers' error sets
/// composed with this layer's own names. The frame layer's public set is
/// this one plus the frame header's own (`BadMagic`, `ReservedBitSet`,
/// `DictionaryRequired`, ...).
pub const Error = error{
    /// The 3-byte Block_Header, or the Block_Content its Block_Size
    /// declares, running past the input (`§3.1.1.2`). The input's end: the
    /// frame layer's `Truncated`.
    Truncated,
    /// `§3.1.1.2.4` — Block_Size past Block_Maximum_Size = "the smallest
    /// of: Window_Size, 128 KB" — or a compressed block that would decode
    /// past it (the maximum "is applicable to both the decompressed size
    /// and the compressed size of any block in the frame").
    BlockOversize,
    /// `§3.1.1.2.2` — block type 3, Reserved: "This is not a block. ...
    /// a compliant decoder must reject it."
    ReservedBlock,
    /// A block whose output does not fit the caller's region: the one-shot's
    /// `target` cap, reported before the overflowing write (`§3.1.1.2.4`,
    /// `§8`).
    BufferTooSmall,
} || literals.Error || sequences.Error;

/// The Block_Type field (`§3.1.1.2.2`, Table 10).
pub const BlockType = enum(u2) {
    raw = 0,
    rle = 1,
    compressed = 2,
    reserved = 3,
};

/// A parsed Block_Header (`§3.1.1.2`, Table 9).
pub const Header = struct {
    /// `§3.1.1.2.1` — "The lowest bit (Last_Block) signals whether this
    /// block is the last one. The frame will end after this last block."
    last_block: bool,
    block_type: BlockType,
    /// Block_Size: Block_Content's length for Raw_Block and
    /// Compressed_Block, the repeat count for RLE_Block (`§3.1.1.2.3`).
    block_size: usize,
};

/// Parse a Block_Header (`§3.1.1.2`, Table 9): 3 bytes, little-endian,
/// Last_Block in bit 0, Block_Type in bits 1-2, Block_Size in bits 3-23.
/// Fewer than 3 bytes is the input's end: `Truncated`.
pub fn parseHeader(source: []const u8) error{Truncated}!Header {
    if (source.len < block_header_len) return error.Truncated;
    const bits = common.readInt(u24, source[0..block_header_len]);
    return .{
        .last_block = (bits & 1) != 0,
        .block_type = @enumFromInt(@as(u2, @truncate((bits >> 1) & 0b11))),
        // "The upper 21 bits of Block_Header represent the Block_Size."
        .block_size = (bits >> 3) & 0x1fffff,
    };
}

/// The Block_Content length a header implies (`§3.1.1.2.3`): "When
/// Block_Type is RLE_Block, since Block_Content's size is always 1,
/// Block_Size represents the number of times this byte must be repeated";
/// for Raw_Block and Compressed_Block it "is the size of Block_Content
/// (hence excluding Block_Header)".
pub fn contentLength(header: Header) usize {
    return if (header.block_type == .rle) 1 else header.block_size;
}

/// One decoded block.
pub const Section = struct {
    /// The block's output: `bytes_written` bytes at `target[decoded_len..]`
    /// of the region the caller handed `decode`.
    bytes_written: usize,
    /// The block's bytes consumed from the caller's `source`: the 3-byte
    /// Block_Header plus its Block_Content.
    bytes_consumed: usize,
    /// `§3.1.1.2.1` — the frame ends after this block.
    last_block: bool,
};

/// Decode one block: the frame's remaining bytes at this block's
/// Block_Header, into the frame's output region, threading the two landed
/// layers' per-frame states.
///
/// `target[0..decoded_len]` is the frame's output so far and
/// `target[decoded_len..]` this block's capacity; `window_size` is the
/// frame's declared Window_Size (`§3.1.1.1.2`), which caps both the history
/// a match may read and Block_Maximum_Size. Both layers' states are the
/// frame's, updated in place by a Compressed_Block and left alone by Raw
/// and RLE blocks (`§3.1.1.5`).
///
/// Every failure is raised before the write it refuses: the caller's output
/// past `decoded_len` is untouched on every error path.
pub fn decode(
    source: []const u8,
    target: []u8,
    decoded_len: usize,
    window_size: u64,
    literals_state: *literals.State,
    sequences_state: *sequences.State,
) Error!Section {
    const header = try parseHeader(source);
    const bytes_written = try decodeContent(
        header,
        source[block_header_len..],
        target,
        decoded_len,
        window_size,
        literals_state,
        sequences_state,
    );
    return .{
        .bytes_written = bytes_written,
        .bytes_consumed = block_header_len + contentLength(header),
        .last_block = header.last_block,
    };
}

/// Decode one block's Block_Content, its header already parsed — the shape
/// a caller that reads the input itself needs (the streaming reader parses
/// the header off its input, then stages the content). Returns the block's
/// output length; `decode` is this plus the header parse and the consumed
/// count.
pub fn decodeContent(
    header: Header,
    content: []const u8,
    target: []u8,
    decoded_len: usize,
    window_size: u64,
    literals_state: *literals.State,
    sequences_state: *sequences.State,
) Error!usize {
    assert(decoded_len <= target.len);
    // A Reserved block has no Block_Content whose size could be checked:
    // the type alone is the corruption (`§3.1.1.2.2`).
    if (header.block_type == .reserved) return error.ReservedBlock;
    // §3.1.1.2.4 — Block_Maximum_Size = "the smallest of: Window_Size,
    // 128 KB", bounding the compressed size of every block.
    const block_max_size: usize = @intCast(@min(window_size, @as(u64, max_block_size)));
    if (header.block_size > block_max_size) return error.BlockOversize;
    // §3.1.1.2.3 — Block_Content's length, and the input's end behind it.
    const content_len = contentLength(header);
    if (content.len < content_len) return error.Truncated;
    const block = content[0..content_len];
    return switch (header.block_type) {
        .raw => try decodeRaw(header.block_size, block, target, decoded_len),
        .rle => try decodeRle(header.block_size, block, target, decoded_len),
        .compressed => try decodeCompressed(
            block,
            target,
            decoded_len,
            window_size,
            block_max_size,
            literals_state,
            sequences_state,
        ),
        .reserved => unreachable,
    };
}

/// `§3.1.1.2.2` — "This is an uncompressed block. Block_Content contains
/// Block_Size bytes": one `fastmem.copy`.
///
/// The amplification limit: Block_Size is a declared size, and the copy is
/// bounded by it *and* by the caller's remaining capacity — a declared size
/// the target cannot hold fails `BufferTooSmall` before the write.
fn decodeRaw(block_size: usize, block: []const u8, target: []u8, decoded_len: usize) Error!usize {
    assert(block.len == block_size);
    assert(decoded_len <= target.len);
    if (block_size > target.len - decoded_len) return error.BufferTooSmall;
    fastmem.copy(u8, target[decoded_len..][0..block_size], block);
    return block_size;
}

/// `§3.1.1.2.2` — "This is a single byte, repeated Block_Size times. ...
/// On the decompression side, this byte must be repeated Block_Size times":
/// one `fastmem.set`, the same capacity bound as a Raw block.
///
/// This is the format's cheapest amplification: one content byte declares
/// up to Block_Maximum_Size bytes of output. The declared size is a bound,
/// never a license — `block_size` has already been checked against
/// Block_Maximum_Size, and the capacity check below is the second bound, so
/// the splat is at most `min(block_max_size, the caller's room)`.
fn decodeRle(block_size: usize, block: []const u8, target: []u8, decoded_len: usize) Error!usize {
    assert(block.len == 1);
    assert(decoded_len <= target.len);
    if (block_size > target.len - decoded_len) return error.BufferTooSmall;
    fastmem.set(u8, target[decoded_len..][0..block_size], block[0]);
    return block_size;
}

/// A Compressed_Block (`§3.1.1.3`): a Literals_Section, then a
/// Sequences_Section over "Sequences_Section_Size = Block_Size -
/// Literals_Section_Header - Literals_Section_Content" (`§3.1.1.3.2`),
/// combined by Sequence Execution (`§3.1.1.4`).
///
/// The literals decode into a scratch bounded by Block_Maximum_Size (every
/// literal lands in the block's output, so the maximum bounds them too);
/// the sequences then execute into the output region, whose history is
/// `min(decoded_len, Window_Size)` and whose capacity is capped by
/// Block_Maximum_Size — the one `BufferTooSmall` the sequences layer
/// reports at that cap is this layer's `BlockOversize`, a corrupt block
/// rather than a caller's small target.
fn decodeCompressed(
    block: []const u8,
    target: []u8,
    decoded_len: usize,
    window_size: u64,
    block_max_size: usize,
    literals_state: *literals.State,
    sequences_state: *sequences.State,
) Error!usize {
    assert(block.len <= block_max_size);
    assert(decoded_len <= target.len);
    assert(block_max_size <= max_block_size);
    // §3.1.1.3 — "All literals are regrouped in the first part of the
    // block": the section is what fixes where the sequences section starts.
    var literals_scratch: [max_block_size]u8 = undefined;
    const literals_section = try literals.decode(
        block,
        literals_scratch[0..block_max_size],
        literals_state,
    );
    const section_source = block[literals_section.bytes_consumed..];
    // §3.1.1.4 — "all offsets leading to previously decoded data must be
    // smaller than Window_Size": the history a match may read is the frame's
    // decoded bytes so far, capped by the frame's window.
    const history: usize = @intCast(@min(decoded_len, window_size));
    // The sequences layer's region: the retained history in front of this
    // block's output, the output capped at Block_Maximum_Size.
    const region = target[decoded_len - history ..];
    const output_capacity = @min(region.len - history, block_max_size);
    const section = sequences.decode(
        section_source,
        literals_section.bytes,
        region[0 .. history + output_capacity],
        history,
        sequences_state,
    ) catch |err| switch (err) {
        // The region was capped at Block_Maximum_Size when the block maximum
        // was the smaller of the two: a block that would decode past it is
        // corrupt (`§3.1.1.2.4`), not a caller's small target.
        error.BufferTooSmall => return if (output_capacity == block_max_size)
            error.BlockOversize
        else
            error.BufferTooSmall,
        else => |e| return e,
    };
    // §3.1.1.3.2 — the sequences section is the rest of the block: its size
    // is derived, so the section must consume exactly what is left.
    assert(section.bytes_consumed == section_source.len);
    return section.bytes_written;
}

/// `§3.1.1.1.2` — `windowLog = 10 + Exponent`, `windowBase = 1 <<
/// windowLog`, `windowAdd = (windowBase / 8) * Mantissa`, `Window_Size =
/// windowBase + windowAdd`. The frame layer owns this arithmetic; the
/// fixture helper below reads a fixture's descriptor back so each frame is
/// checked against the window it declares.
fn windowSizeOf(descriptor: u8) u64 {
    const exponent: u6 = @truncate(descriptor >> 3);
    const mantissa: u3 = @truncate(descriptor);
    const base: u64 = @as(u64, 1) << (10 + exponent);
    return base + (base / 8) * mantissa;
}

/// Walk a fixture frame's block chain the way the frame layer will: the
/// 6-byte prefix (magic, Frame_Header_Descriptor, Window_Descriptor) is
/// checked, then `decode` runs until the Last_Block flag, threading both
/// layer states and the running decoded length. Returns the decoded length;
/// the caller checks the output and the sentinel.
fn decodeFrame(bytes: []const u8, target: []u8) !usize {
    try testing.expectEqualSlices(u8, &golden.frame_magic, bytes[0..4]);
    try testing.expectEqual(golden.frame_descriptor, bytes[4]);
    const window_size = windowSizeOf(bytes[5]);
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    var decoded_len: usize = 0;
    var cursor: usize = 6;
    while (true) {
        const section = try decode(
            bytes[cursor..],
            target,
            decoded_len,
            window_size,
            &literals_state,
            &sequences_state,
        );
        cursor += section.bytes_consumed;
        decoded_len += section.bytes_written;
        if (section.last_block) break;
    }
    // The block chain ends the frame exactly: the fixtures carry no checksum
    // trailer (`§3.1.1`), so the last block's last byte is the frame's.
    try testing.expectEqual(bytes.len, cursor);
    return decoded_len;
}

/// Decode a fixture frame and check its output, with the sentinel overrun
/// check every decode test runs (AGENTS.md, "Rules").
fn expectFrame(frame: []const u8, expected: []const u8) !void {
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    const written = try decodeFrame(frame, &target);
    try testing.expectEqualSlices(u8, expected, target[0..written]);
    try internal.sentinel.expect(&target, written);
}

/// Decode a bare block (a fixture frame's bytes after its 6-byte prefix) and
/// expect `err`, with the sentinel proving the block wrote nothing: the
/// failure came before its write.
fn expectBlockError(err: Error, block_bytes: []const u8, target: []u8) !void {
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    internal.sentinel.fill(target);
    try testing.expectError(
        err,
        decode(block_bytes, target, 0, 512 * 1024, &literals_state, &sequences_state),
    );
    try internal.sentinel.expect(target, 0);
}

/// Walk a fixture frame's block chain expecting a block to fail with `err`,
/// proving nothing past the blocks that did decode was written: the failure
/// came before the offending write, and the earlier blocks' output (which the
/// caller discards on error) is all that stands.
fn expectFrameError(err: Error, frame: []const u8) !void {
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    try testing.expectEqualSlices(u8, &golden.frame_magic, frame[0..4]);
    try testing.expectEqual(golden.frame_descriptor, frame[4]);
    const window_size = windowSizeOf(frame[5]);
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    var decoded_len: usize = 0;
    var cursor: usize = 6;
    while (true) {
        const section = decode(
            frame[cursor..],
            &target,
            decoded_len,
            window_size,
            &literals_state,
            &sequences_state,
        ) catch |actual| {
            try testing.expectEqual(err, actual);
            try internal.sentinel.expect(&target, decoded_len);
            return;
        };
        cursor += section.bytes_consumed;
        decoded_len += section.bytes_written;
        if (section.last_block) break;
    }
    return error.TestExpectedError;
}

test "parseHeader reads the 3-byte Block_Header" {
    // RFC 8878 §3.1.1.2, Table 9 — "Block_Header uses 3 bytes, written
    // using little-endian convention": Last_Block in bit 0, Block_Type in
    // bits 1-2, Block_Size in bits 3-23.
    const raw = try parseHeader(&.{ 0x00, 0x00, 0x00 });
    try testing.expect(!raw.last_block);
    try testing.expectEqual(BlockType.raw, raw.block_type);
    try testing.expectEqual(@as(usize, 0), raw.block_size);
    const last = try parseHeader(&.{ 0x01, 0x00, 0x00 });
    try testing.expect(last.last_block);
    try testing.expectEqual(BlockType.raw, last.block_type);
    try testing.expectEqual(BlockType.rle, (try parseHeader(&.{ 0x02, 0x00, 0x00 })).block_type);
    try testing.expectEqual(
        BlockType.compressed,
        (try parseHeader(&.{ 0x04, 0x00, 0x00 })).block_type,
    );
    try testing.expectEqual(
        BlockType.reserved,
        (try parseHeader(&.{ 0x06, 0x00, 0x00 })).block_type,
    );
    // Block_Size's 21 bits: the top of the field, with Last_Block clear.
    const wide = try parseHeader(&.{ 0xf8, 0xff, 0xff });
    try testing.expect(!wide.last_block);
    try testing.expectEqual(BlockType.raw, wide.block_type);
    try testing.expectEqual(@as(usize, 0x1fffff), wide.block_size);
    // §3.1.1.2.3 — Block_Content's length, Block_Size for Raw and
    // Compressed, one byte for RLE.
    try testing.expectEqual(@as(usize, 5), contentLength(.{
        .last_block = true,
        .block_type = .raw,
        .block_size = 5,
    }));
    try testing.expectEqual(@as(usize, 1), contentLength(.{
        .last_block = true,
        .block_type = .rle,
        .block_size = 5,
    }));
    // Fewer than 3 bytes is the input's end, not a malformed header.
    try testing.expectError(error.Truncated, parseHeader(&.{}));
    try testing.expectError(error.Truncated, parseHeader(&.{0x01}));
    try testing.expectError(error.Truncated, parseHeader(&.{ 0x01, 0x00 }));
}

test "decode copies a Raw block" {
    // RFC 8878 §3.1.1.2.2 — "This is an uncompressed block. Block_Content
    // contains Block_Size bytes": the frame's block chain is the bytes
    // themselves.
    try expectFrame(&golden.frame_raw, "zstd raw");
    // A zero-size Raw block is the empty frame's shape (T7: the CLI's own
    // empty-input frame is a 0-size Raw block).
    try expectFrame(&golden.frame_raw_empty, "");
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    const section = try decode(
        golden.frame_raw[6..],
        &target,
        0,
        512 * 1024,
        &literals_state,
        &sequences_state,
    );
    try testing.expectEqual(@as(usize, 8), section.bytes_written);
    try testing.expectEqual(@as(usize, 3 + 8), section.bytes_consumed);
    try testing.expect(section.last_block);
    try internal.sentinel.expect(&target, 8);
}

test "decode splats an RLE block" {
    // RFC 8878 §3.1.1.2.2 — "This is a single byte, repeated Block_Size
    // times. Block_Content consists of a single byte. On the decompression
    // side, this byte must be repeated Block_Size times." The CLI never
    // emits RLE as a *first* block, so only fixtures cover it.
    try expectFrame(&golden.frame_rle, "AAAAAAAAAA");
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    const section = try decode(
        golden.frame_rle[6..],
        &target,
        0,
        512 * 1024,
        &literals_state,
        &sequences_state,
    );
    try testing.expectEqual(@as(usize, 10), section.bytes_written);
    try testing.expectEqual(@as(usize, 3 + 1), section.bytes_consumed);
    try testing.expect(section.last_block);
    try internal.sentinel.expect(&target, 10);
}

test "decode walks a multi-block chain" {
    // RFC 8878 §3.1.1.2 — "there is no upper limit on the number of blocks
    // per frame", and §3.1.1.2.1's Last_Block is what ends the walk: three
    // blocks, the flag on the third.
    try expectFrame(&golden.frame_multi, "abcdefghIIIIII");
    // The same chain one block at a time: the consumed counts are the
    // frame layer's cursor.
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    var decoded_len: usize = 0;
    var cursor: usize = 6;
    for ([_]usize{ 7, 7, 4 }) |consumed| {
        const section = try decode(
            golden.frame_multi[cursor..],
            &target,
            decoded_len,
            512 * 1024,
            &literals_state,
            &sequences_state,
        );
        try testing.expectEqual(consumed, section.bytes_consumed);
        cursor += consumed;
        decoded_len += section.bytes_written;
    }
    try testing.expectEqual(@as(usize, 14), decoded_len);
    try internal.sentinel.expect(&target, decoded_len);
}

test "Raw and RLE blocks leave the frame's cross-block state alone" {
    // RFC 8878 §3.1.1.5 — "each block gets its starting offset history from
    // the ending values of the most recent Compressed_Block. Note that
    // blocks that are not Compressed_Block are skipped; they do not
    // contribute to offset history." Neither the repeat offsets nor the
    // tables nor the Huffman tree move.
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    var decoded_len: usize = 0;
    var cursor: usize = 6;
    while (true) {
        const section = try decode(
            golden.frame_multi[cursor..],
            &target,
            decoded_len,
            512 * 1024,
            &literals_state,
            &sequences_state,
        );
        cursor += section.bytes_consumed;
        decoded_len += section.bytes_written;
        if (section.last_block) break;
    }
    try testing.expect(literals_state.table == null);
    try testing.expect(sequences_state.tables[0] == null);
    try testing.expect(sequences_state.tables[1] == null);
    try testing.expect(sequences_state.tables[2] == null);
    try testing.expectEqualSlices(
        u32,
        &sequences.repeat_offsets_start,
        &sequences_state.repeat_offsets,
    );
    try internal.sentinel.expect(&target, decoded_len);
}

test "decode rejects the Reserved block type" {
    // RFC 8878 §3.1.1.2.2 — "This is not a block. This value cannot be used
    // with the current specification. If such a value is present, it is
    // considered to be corrupt data, and a compliant decoder must reject
    // it." The CLI exits 1 on the same frame.
    try expectFrameError(error.ReservedBlock, &golden.frame_reserved);
}

test "decode refuses Block_Size past Block_Maximum_Size" {
    // RFC 8878 §3.1.1.2.4 — Block_Maximum_Size "is the smallest of:
    // Window_Size, 128 KB" and "is applicable to both the decompressed size
    // and the compressed size of any block in the frame". A 128 KB + 1 Raw
    // block in a 512 KB-window frame, and an RLE block of 1025 in a 1 KB
    // one (the window/block coupling: the declared window is the smaller
    // term). The CLI rejects both.
    try expectFrameError(error.BlockOversize, &golden.frame_oversize_raw);
    try expectFrameError(error.BlockOversize, &golden.frame_oversize_rle);
    // The compressed-block term of the same rule: Block_Size is the
    // compressed size, and 1025 of them do not fit a 1 KB window's block
    // maximum. The size is what is pinned, not the content.
    var target: [8]u8 = undefined;
    internal.sentinel.fill(&target);
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    const oversize = [_]u8{ 0x0d, 0x20, 0x00 } ++ [_]u8{0} ** 8;
    try testing.expectError(
        error.BlockOversize,
        decode(&oversize, &target, 0, 1024, &literals_state, &sequences_state),
    );
    try internal.sentinel.expect(&target, 0);
    // The legal neighbor: an RLE block at exactly 128 KB in a 512 KB-window
    // frame decodes (the CLI's own output is 131072 bytes of one byte).
    var big: [max_block_size + 8]u8 = undefined;
    internal.sentinel.fill(&big);
    const written = try decodeFrame(&golden.frame_rle_max, &big);
    try testing.expectEqual(max_block_size, written);
    const run = [_]u8{0x5a} ** max_block_size;
    try testing.expectEqualSlices(u8, &run, big[0..written]);
    try internal.sentinel.expect(&big, written);
}

test "decode fails closed on a block cut short" {
    // RFC 8878 §3.1.1.2 — the Block_Header and the Block_Content it
    // declares both come from the input: a frame cut inside either is the
    // input's end (`Truncated`), never a structure's own error. The CLI
    // exits 1 on every one of these.
    try expectFrameError(error.Truncated, &golden.frame_truncated_header);
    try expectFrameError(error.Truncated, &golden.frame_short_raw);
    try expectFrameError(error.Truncated, &golden.frame_short_compressed);
    // An RLE block whose one content byte is missing: Block_Size 5, the
    // header only.
    var target: [8]u8 = undefined;
    try expectBlockError(error.Truncated, &.{ 0x2b, 0x00, 0x00 }, &target);
}

test "decode fails closed on a target too small" {
    // RFC 8878 §3.1.1.2.4 + §8 — a declared size is a bound, never a
    // license: the copy is refused before the write, and the sentinel
    // proves the byte the block would have written is untouched. A Raw
    // block of 8 into 7 bytes, an RLE block of 128 KB into 100, and a
    // compressed block whose output does not fit.
    var target: [100]u8 = undefined;
    internal.sentinel.fill(&target);
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    try testing.expectError(
        error.BufferTooSmall,
        decode(
            golden.frame_raw[6..],
            target[0..7],
            0,
            512 * 1024,
            &literals_state,
            &sequences_state,
        ),
    );
    try internal.sentinel.expect(&target, 0);
    try testing.expectError(
        error.BufferTooSmall,
        decode(
            golden.frame_rle_max[6..],
            &target,
            0,
            512 * 1024,
            &literals_state,
            &sequences_state,
        ),
    );
    try internal.sentinel.expect(&target, 0);
    try testing.expectError(
        error.BufferTooSmall,
        decode(
            golden.frame_sequences_predefined[6..],
            target[0..2],
            0,
            512 * 1024,
            &literals_state,
            &sequences_state,
        ),
    );
    try internal.sentinel.expect(&target, 0);
    // The same block one byte of room larger decodes.
    var fits: [77]u8 = undefined;
    internal.sentinel.fill(&fits);
    const section = try decode(
        golden.frame_sequences_predefined[6..],
        &fits,
        0,
        512 * 1024,
        &literals_state,
        &sequences_state,
    );
    try testing.expectEqual(@as(usize, 77), section.bytes_written);
    try testing.expectEqualSlices(u8, &golden.sequences_predefined_expected, &fits);
    try internal.sentinel.expect(&fits, 77);
}

test "decode composes the landed sequences fixtures as whole frames" {
    // RFC 8878 §3.1.1.3 — "A compressed block consists of two sections: a
    // Literals_Section and a Sequences_Section. The results of the two
    // sections are then combined to produce the decompressed data in
    // Sequence Execution": each landed sequences fixture pair framed as one
    // compressed block, and the CLI's own `zstd -d` output as the
    // expectation (the same bytes the landed slice's tests decode section
    // by section).
    try expectFrame(&golden.frame_sequences_predefined, &golden.sequences_predefined_expected);
    try expectFrame(
        &golden.frame_sequences_rle_match_lengths,
        &golden.sequences_rle_match_lengths_expected,
    );
    try expectFrame(&golden.frame_sequences_fse_offsets, &golden.sequences_fse_offsets_expected);
    try expectFrame(&golden.frame_sequences_fse_all, &golden.sequences_fse_all_expected);
}

test "decode composes the landed literals fixtures as whole frames" {
    // RFC 8878 §3.1.1.3.2.1 — "Decompressed content is defined entirely as
    // Literals_Section content": each landed literals fixture framed with
    // the zero-count sequences section, so the block's output is its
    // literals. The 4-stream fixtures pin the Jump_Table path end to end,
    // the FSE-weights one the Huffman_Tree_Description path.
    try expectFrame(&golden.frame_literals_1stream, &golden.literals_1stream_expected);
    try expectFrame(&golden.frame_literals_4stream_sf1, &golden.literals_4stream_sf1_expected);
    try expectFrame(&golden.frame_literals_4stream_sf2, &golden.literals_4stream_sf2_expected);
    try expectFrame(&golden.frame_literals_fse_tree, &golden.literals_fse_tree_expected);
    // The T1 pair: the Table-25 assignment and the errata-8195 stream, as
    // whole frames both decoders read.
    try expectFrame(&golden.frame_t1, &golden.t1_literals);
    try expectFrame(&golden.frame_t1_errata, &golden.t1_errata_literals);
}

test "decode carries the Huffman tree across blocks" {
    // RFC 8878 §3.1.1.3.1.1 — a Treeless_Literals_Block uses "the Huffman
    // tree from the previous Compressed_Literals_Block": block 2 carries
    // streams only and decodes five more symbols through block 1's tree.
    try expectFrame(&golden.frame_treeless, &.{ 0, 1, 4, 5, 0, 0, 0, 0, 0 });
    // "if this mode is triggered without any previous Huffman table in the
    // frame ... it should be treated as data corruption" — block 1 has none.
    try expectFrameError(error.TreelessLiteralsFirst, &golden.frame_treeless_first);
}

test "decode carries the tables and the repeat offsets across blocks" {
    // RFC 8878 §3.1.1.3.2.1 — "The table used in the previous
    // Compressed_Block with Number_Of_Sequences > 0 will be used again":
    // block 2's modes byte is 0xfc (all three alphabets Repeat) and it
    // carries no table bytes. §3.1.1.5's offsets carry with them: block 2's
    // offsets continue block 1's history.
    try expectFrame(&golden.frame_repeat, &golden.frame_repeat_expected);
    try expectFrameError(error.RepeatModeFirst, &golden.frame_repeat_first);
    // The three-block tempOffset chain: block 2's sequences all have
    // literals_length 0 (the shifted repeat selection) and reach into block
    // 1, block 3's walk the Repeated_Offset2 swap.
    try expectFrame(&golden.frame_temp_offset, &golden.frame_temp_offset_expected);
    // 128 sequences through the 2-byte Number_of_Sequences form.
    try expectFrame(&golden.frame_two_byte, &golden.frame_two_byte_expected);
}

test "decode reads the hand-built fixture blocks as whole frames" {
    // RFC 8878 §3.1.1.4 + §3.1.1.5 — the corner fixture's six RLE-mode
    // sequences with their trailing literals, and the two zero-count forms
    // (the 2-byte `80 00` is T5's decoded-zero corner, which std rejects).
    try expectFrame(&golden.frame_corner, &golden.frame_corner_expected);
    try expectFrame(&golden.frame_zero_seq, &golden.frame_zero_seq_expected);
    try expectFrame(&golden.frame_zero_seq_2b, &golden.frame_zero_seq_expected);
}

test "the history a match may read is capped by Window_Size" {
    // RFC 8878 §3.1.1.4 — "all offsets leading to previously decoded data
    // must be smaller than Window_Size": with 2 KB decoded over a 1 KB
    // window, a match at offset 1024 reads the window's oldest retained
    // byte and decodes; one byte further is `OffsetTooFar`, whatever the
    // target still holds. The CLI decodes both — its whole-buffer decoder
    // checks the bytes it still has, not the declared window — and the
    // module doc above records the divergence.
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    const written = try decodeFrame(&golden.frame_window_1k, &target);
    try testing.expectEqual(@as(usize, 2048 + 3), written);
    const first = [_]u8{0x41} ** 1024;
    const second = [_]u8{0x42} ** 1024;
    try testing.expectEqualSlices(u8, &first, target[0..1024]);
    try testing.expectEqualSlices(u8, &second, target[1024..2048]);
    // Offset 1024 from position 2048 is the B block's first byte.
    try testing.expectEqualSlices(u8, "BBB", target[2048..2051]);
    try internal.sentinel.expect(&target, written);
    try expectFrameError(error.OffsetTooFar, &golden.frame_window_1k_over);
    // The same compressed block at the frame's start: with no history at
    // all, its offset reaches before `target[0]` and is `OffsetTooFar` —
    // the one-shot's history is the output itself, so a frame cannot
    // reference data it never produced.
    var bare: [16]u8 = undefined;
    internal.sentinel.fill(&bare);
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    try testing.expectError(
        error.OffsetTooFar,
        decode(
            golden.frame_window_1k[14..],
            &bare,
            0,
            1024,
            &literals_state,
            &sequences_state,
        ),
    );
    try internal.sentinel.expect(&bare, 0);
}

test "the window accounting crosses Block_Maximum_Size" {
    // RFC 8878 §3.1.1.2.4 + §3.1.1.4 — two 128 KB blocks put the decoded
    // length past both Block_Maximum_Size and Window_Size, so the history
    // is the window's 128 KB and a match at offset 131072 reads the first
    // retained byte; 131073 is `OffsetTooFar` (the CLI decodes both — the
    // recorded divergence above). The output position is 262144 while the
    // history starts at 131072: the re-based region the sequences layer
    // sees is what makes the two independent.
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    const written = try decodeFrame(&golden.frame_window_128k, &target);
    try testing.expectEqual(@as(usize, 2 * 131072 + 3), written);
    const first = [_]u8{0x41} ** 131072;
    const second = [_]u8{0x42} ** 131072;
    try testing.expectEqualSlices(u8, &first, target[0..131072]);
    try testing.expectEqualSlices(u8, &second, target[131072..262144]);
    try testing.expectEqualSlices(u8, "BBB", target[262144..262147]);
    try internal.sentinel.expect(&target, written);
    try expectFrameError(error.OffsetTooFar, &golden.frame_window_128k_over);
}

test "a compressed block cannot amplify past Block_Maximum_Size" {
    // RFC 8878 §3.1.1.2.4 + §8 — Block_Maximum_Size "is applicable to both
    // the decompressed size and the compressed size of any block": a
    // sequence declaring a 1026-byte match in a 1 KB-window frame is
    // `BlockOversize` (the region is capped at the block maximum first, so
    // the sequences layer's `BufferTooSmall` is the block's fault, not the
    // target's), and a literals section regenerating 4096 bytes in the same
    // frame is `LiteralsTooLarge` (the literals scratch is the block
    // maximum). Both fail before any write; the CLI rejects both.
    try expectFrameError(error.BlockOversize, &golden.frame_amplify_match);
    try expectFrameError(error.LiteralsTooLarge, &golden.frame_oversize_literals);
}

test "decode fails closed on the entropy layers' corners" {
    // RFC 8878 §3.1.1.3.1.1 — a compressed block that is only a literals
    // header short of nothing: the literals section must have its 1-5 byte
    // header (`MalformedLiteralsHeader`; the CLI reads a zero-size
    // compressed block as a no-op, ours fails closed). §3.1.1.3.2.1 — a
    // sequences section cut inside its fixed-size fields is
    // `MalformedSequencesHeader`, the sequences slice's name carried into
    // the public set.
    try expectFrameError(error.MalformedLiteralsHeader, &golden.frame_empty_compressed);
    try expectFrameError(error.MalformedSequencesHeader, &golden.frame_no_sequences);
    try expectFrameError(error.MalformedSequencesHeader, &golden.frame_short_sequences);
}

test "decodeContent decodes a block whose header is already parsed" {
    // The streaming reader's shape: the header is parsed off the input (its
    // 3 bytes are the only fixed-size read), then the content is staged and
    // handed over. `decode` is this plus the header parse and the consumed
    // count.
    const header = try parseHeader(golden.frame_raw[6..]);
    try testing.expectEqual(@as(usize, 8), header.block_size);
    var target: [16]u8 = undefined;
    internal.sentinel.fill(&target);
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    const written = try decodeContent(
        header,
        golden.frame_raw[6 + block_header_len ..],
        &target,
        0,
        512 * 1024,
        &literals_state,
        &sequences_state,
    );
    try testing.expectEqual(@as(usize, 8), written);
    try testing.expectEqualSlices(u8, "zstd raw", target[0..written]);
    try internal.sentinel.expect(&target, written);
}

test "windowSizeOf reads §3.1.1.1.2's descriptor arithmetic" {
    // RFC 8878 §3.1.1.1.2 — "windowLog = 10 + Exponent", "windowBase = 1 <<
    // windowLog", "windowAdd = (windowBase / 8) * Mantissa", "Window_Size =
    // windowBase + windowAdd": the fixture frames' three descriptors.
    try testing.expectEqual(@as(u64, 1024), windowSizeOf(0x00));
    try testing.expectEqual(@as(u64, 128 * 1024), windowSizeOf(0x38));
    try testing.expectEqual(@as(u64, 512 * 1024), windowSizeOf(0x48));
}
