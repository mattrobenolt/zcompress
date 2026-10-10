//! zstd.decode: the one-shot frame decoder (README, "API").
//!
//! `decompress` locates exactly one Zstandard frame in `source` and decodes
//! it into `target`, returning the decoded length. The boundary rule is the
//! M3 one, mapped over: leading skippable frames are consumed and ignored
//! (`§3.1.2`), the frame is located by exact consumption — the block chain's
//! Last_Block and, when the flag is set, the 4-byte Content_Checksum trailer
//! (`§3.1.1`) — and bytes after the frame are ignored. The one-shot reports
//! no consumed count, so a boundary-aware caller drives `zstd.Reader` (the
//! next slice): the C's `ZSTD_decompress` and klauspost's `DecodeAll` walk
//! every frame in one call, and ours does not — a multi-frame file's tail is
//! the caller's loop, exactly as gzip's one-shot treats a second member.
//!
//! The one-shot needs no window buffer: the decoded output *is* the history,
//! and every match offset is bounded by it (`§3.1.1.4` — an offset that
//! reaches before `target[0]` is `OffsetTooFar`), so `WindowTooLarge` is not
//! in the error set. `target` is a cap, never a promise: the decode writes
//! only into it and fails `BufferTooSmall` before an overflowing write, and
//! `Frame_Content_Size` — optional (`§3.1.1.1.4`), and absent from most
//! frames — is checked *against* the decode, never trusted for it.
//!
//! The cardinality rules are the CLI's own (T10): a zero-byte input is
//! `Truncated` (no frame unit began — the gzip decision mapped over), and so
//! is a partial magic or a header cut short; a stream of only skippable
//! frames is the clean end with zero bytes served.
//!
//! ## The namespace
//!
//! Beyond `decompress`, `max_block_size`, and `DecompressError`, the layer
//! types the decoder is built from stay reachable, named, and stable (the
//! flate precedent: `BitReader`, `copyMatch`): `frame` (the magic, the frame
//! header, the block chain, the checksum trailer, skippable frames), `block`
//! (the 3-byte block header, the Raw/RLE/Compressed dispatch, sequence
//! execution, the checksum funnel), `literals`, `sequences`, `fse`, and the
//! `window` arithmetic both layers check a frame against. They are public
//! because the one-shot and the streaming reader are composed from them and
//! the golden and fuzz lanes pin the same functions.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const common = @import("common.zig");
const golden = @import("golden.zig");
const internal = @import("../internal/root.zig");

/// The frame layer (`§3.1`): the Magic_Number, the Frame_Header, the block
/// chain, the checksum trailer, and skippable frames.
pub const frame = @import("frame.zig");
/// The block layer (`§3.1.1.2`): the Block_Header, the four Block_Types, and
/// the per-block decode.
pub const block = @import("block.zig");
/// The literals section (`§3.1.1.3.1`) and its Huffman streams.
pub const literals = @import("literals.zig");
/// The sequences section (`§3.1.1.3.2`) and Sequence Execution
/// (`§3.1.1.4`).
pub const sequences = @import("sequences.zig");
/// The FSE tables (`§4.1`), shared by the sequences section and the Huffman
/// weights.
pub const fse = @import("fse.zig");
/// `§3.1.1.1.2`'s Window_Size arithmetic.
pub const window = frame.window;

/// `§3.1.1.2.4` — "128 KB": Block_Maximum_Size's ceiling. A frame's own
/// bound is `min(Window_Size, this)`.
pub const max_block_size = block.max_block_size;

/// The one-shot decoder's error set (README, "API"): the frame layer's
/// composed set — the frame header's names, the block chain's, and the two
/// entropy layers' — name for name.
pub const DecompressError = frame.Error;

comptime {
    // The README's vocabulary (README, "API") is this set, name for name:
    // a layer that invents an error name fails the build here rather than at
    // review, and a name the document promises but no layer raises is dead
    // surface. The set is the frame layer's composed one, so this is also the
    // assertion that the frame layer's set did not drift.
    const vocabulary = [_][]const u8{
        "BufferTooSmall",
        "BadMagic",
        "ReservedBitSet",
        "DictionaryRequired",
        "BlockOversize",
        "ReservedBlock",
        "MalformedLiteralsHeader",
        "LiteralsTooLarge",
        "TreelessLiteralsFirst",
        "MalformedHuffmanWeights",
        "MalformedFseTable",
        "MalformedSequencesHeader",
        "RepeatModeFirst",
        "ReservedModeBits",
        "MissingStartBit",
        "InvalidBitStream",
        "BitstreamNotConsumed",
        "ZeroOffset",
        "OffsetTooFar",
        "ContentSizeMismatch",
        "WrongChecksum",
        "Truncated",
    };
    @setEvalBranchQuota(100_000);
    const set = @typeInfo(DecompressError).error_set.?;
    assert(set.len == vocabulary.len);
    for (vocabulary) |name| {
        var found = false;
        for (set) |entry| {
            if (std.mem.eql(u8, name, entry.name)) found = true;
        }
        assert(found);
    }
}

/// Decode one Zstandard frame from `source` into `target` and return the
/// decoded length.
///
/// Leading skippable frames are consumed and ignored (`§3.1.2`); the frame is
/// located by exact consumption and bytes after it are ignored (see the
/// module doc). `target` is a cap: the decode writes only into it and fails
/// `BufferTooSmall` before an overflowing write.
pub fn decompress(source: []const u8, target: []u8) DecompressError!usize {
    var cursor: usize = 0;
    // §3.1.2 — "skippable frames simply need to be skipped, and their
    // content ignored, resuming decoding after the skippable frame".
    while (true) {
        const kind = frame.classify(source[cursor..]) catch |err| switch (err) {
            // The input's end, before any frame unit's magic. A zero-byte
            // input is `Truncated` — no frame unit began (the gzip decision
            // mapped over) — and so is a partial magic or one after a
            // skippable frame; a stream of *only* skippable frames is the
            // clean end with zero bytes served (T10, the CLI's own behavior).
            error.Truncated => {
                if (cursor > 0 and cursor == source.len) return 0;
                return error.Truncated;
            },
            error.BadMagic => return error.BadMagic,
        };
        if (kind == .zstandard) break;
        cursor += try skippableLength(source[cursor..]);
    }
    cursor += frame.magic_len;
    // §3.1.1.1 — the Frame_Header, 2-14 bytes, ending where the block chain
    // begins.
    const header = try frame.parseHeader(source[cursor..]);
    cursor += header.bytes_consumed;
    var state: frame.State = .init(header);
    // §3.1.1.2 — "Each frame must have at least 1 block, but there is no
    // upper limit on the number of blocks per frame": the chain ends at the
    // Last_Block flag, and every block lands in `target` through the state's
    // one funnel (the checksum fold and the Frame_Content_Size bound).
    while (true) {
        const section = try state.decodeBlock(source[cursor..], target);
        cursor += section.bytes_consumed;
        if (section.last_block) break;
    }
    // §3.1.1.1.4 — "Frame_Content_Size ... is the original (uncompressed)
    // size": checked against the decode, never trusted for it.
    try state.checkContentSize();
    // §3.1.1 — "The content checksum is the result of the XXH64() hash
    // function digesting the original (decoded) data as input, and a seed of
    // zero. The low 4 bytes of the checksum are stored in little-endian
    // format": read and compared once, at the frame's end (T8 — verify,
    // never skip).
    if (header.checksum) {
        if (source.len - cursor < frame.checksum_len) return error.Truncated;
        try state.verifyTrailer(source[cursor..][0..frame.checksum_len]);
    }
    return state.decoded_len;
}

/// One skippable frame's length from its front (`§3.1.2`): the 4-byte magic,
/// the 4-byte Frame_Size — "the size, in bytes, of the following User_Data" —
/// and that many bytes. The User_Data is never staged: a 4 GiB Frame_Size
/// costs the walk and no memory (the gzip XLEN rule), and a frame cut inside
/// it is the input's end, `Truncated`.
fn skippableLength(source: []const u8) error{Truncated}!usize {
    const head_len = frame.magic_len + frame.frame_size_len;
    if (source.len < head_len) return error.Truncated;
    const user_data_len: usize =
        @intCast(common.readInt(u32, source[frame.magic_len..][0..frame.frame_size_len]));
    if (source.len - head_len < user_data_len) return error.Truncated;
    return head_len + user_data_len;
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1 (frames and
// skippable frames), §3.1.1 (the frame and its checksum), §3.1.1.1.1-§3.1.1.1.4
// (the header's fields), §3.1.1.2 (the block chain), §3.1.1.4 (offsets and the
// window), §3.1.2 (skippable frames). The fixtures are `golden.zig`'s, each
// verified with the pinned zstd v1.5.7.
// ---------------------------------------------------------------------------

/// Decode `source` into a fresh sentinel-filled target, check the output and
/// the bytes past it, and return the decoded length — the shape every decode
/// test runs (AGENTS.md, "Rules").
fn expectDecode(source: []const u8, expected: []const u8) !void {
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    const written = try decompress(source, &target);
    try testing.expectEqual(expected.len, written);
    try testing.expectEqualSlices(u8, expected, target[0..written]);
    try internal.sentinel.expect(&target, written);
}

/// Decode `source` into a sentinel-filled target expecting `err`, and prove
/// the decode wrote exactly `written` bytes before failing: the bytes past
/// that still hold their sentinel. A frame whose earlier blocks decoded
/// leaves their output behind — the caller must not use it (README,
/// "Corruption"), and the byte the failing check refused was never written.
fn expectDecodeError(err: DecompressError, source: []const u8, written: usize) !void {
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    try testing.expectError(err, decompress(source, &target));
    try internal.sentinel.expect(&target, written);
}

test "the layer types are reachable through the decode namespace" {
    // README, "API": the layer types the decoder is built from stay
    // reachable, named, and stable — the one-shot and the streaming reader
    // are composed from them and the golden and fuzz lanes pin the same
    // functions. Referencing every public decl of each also keeps the
    // surface honest: a decl that no longer composes fails here.
    std.testing.refAllDecls(frame);
    std.testing.refAllDecls(block);
    std.testing.refAllDecls(literals);
    std.testing.refAllDecls(sequences);
    std.testing.refAllDecls(fse);
    std.testing.refAllDecls(window);
    try testing.expectEqual(block.max_block_size, max_block_size);
}

test "decompress decodes the landed whole-frame fixtures" {
    // RFC 8878 §3.1.1 — the frame layer's fixtures end to end through the
    // public entry point: the fast paths, the window fixtures, and every
    // landed slice's fixtures framed. Each expectation is the CLI's own
    // `zstd -d` output (golden.zig records the verdicts).
    try expectDecode(&golden.frame_raw, "zstd raw");
    try expectDecode(&golden.frame_raw_empty, "");
    try expectDecode(&golden.frame_rle, "AAAAAAAAAA");
    try expectDecode(&golden.frame_multi, "abcdefghIIIIII");
    try expectDecode(&golden.frame_t1, &golden.t1_literals);
    try expectDecode(&golden.frame_t1_errata, &golden.t1_errata_literals);
    try expectDecode(&golden.frame_treeless, &.{ 0, 1, 4, 5, 0, 0, 0, 0, 0 });
    try expectDecode(&golden.frame_repeat, &golden.frame_repeat_expected);
    try expectDecode(&golden.frame_temp_offset, &golden.frame_temp_offset_expected);
    try expectDecode(&golden.frame_corner, &golden.frame_corner_expected);
    try expectDecode(&golden.frame_two_byte, &golden.frame_two_byte_expected);
    try expectDecode(&golden.frame_zero_seq, &golden.frame_zero_seq_expected);
    try expectDecode(&golden.frame_zero_seq_2b, &golden.frame_zero_seq_expected);
    try expectDecode(&golden.frame_sequences_predefined, &golden.sequences_predefined_expected);
    try expectDecode(
        &golden.frame_sequences_rle_match_lengths,
        &golden.sequences_rle_match_lengths_expected,
    );
    try expectDecode(&golden.frame_sequences_fse_offsets, &golden.sequences_fse_offsets_expected);
    try expectDecode(&golden.frame_sequences_fse_all, &golden.sequences_fse_all_expected);
    try expectDecode(&golden.frame_literals_1stream, &golden.literals_1stream_expected);
    try expectDecode(&golden.frame_literals_4stream_sf1, &golden.literals_4stream_sf1_expected);
    try expectDecode(&golden.frame_literals_4stream_sf2, &golden.literals_4stream_sf2_expected);
    try expectDecode(&golden.frame_literals_fse_tree, &golden.literals_fse_tree_expected);
}

test "decompress decodes the CLI's multi-block checksummed frame" {
    // RFC 8878 §3.1.1 + §3.1.1.1.4 — the pinned CLI's own `zstd -3` frame:
    // 135000 bytes over two Compressed_Blocks, single-segment (Window_Size =
    // Frame_Content_Size = 135000), with the XXH64 trailer the C library
    // wrote. The decoded bytes are the input the CLI compressed, and the
    // trailer check is what makes this the end-to-end differential pin.
    const expected = golden.frame_checksum_multi_text ** 3000;
    try expectDecode(&golden.frame_checksum_multi, expected);
    // The same frame with its trailer byte flipped: the decode succeeds byte
    // for byte and then fails closed on the checksum (T8).
    var corrupt: [golden.frame_checksum_multi.len]u8 = undefined;
    fastmem.copy(u8, &corrupt, &golden.frame_checksum_multi);
    corrupt[corrupt.len - 1] ^= 0xff;
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    try testing.expectError(error.WrongChecksum, decompress(&corrupt, &target));
    // The output of a failed decode is not trusted, but the bytes the frame
    // did write are exactly the frame's: the sentinel past the frame's
    // length proves the decode never wrote past its declared content.
    try testing.expectEqualSlices(u8, expected, target[0..expected.len]);
    try internal.sentinel.expect(&target, expected.len);
}

test "decompress reads the descriptor corners" {
    // RFC 8878 §3.1.1.1.1.1, Table 4 — every FCS_Field_Size; §3.1.1.1.1.2 —
    // Single_Segment_Flag's Window_Size = Frame_Content_Size; §3.1.1.1.1.3 —
    // the unused bit is never interpreted. The CLI decodes each of these.
    const run = [_]u8{'A'} ** 300;
    try expectDecode(&golden.frame_fcs1, "01234567");
    try expectDecode(&golden.frame_fcs2, &run);
    try expectDecode(&golden.frame_fcs2_single_segment, &run);
    try expectDecode(&golden.frame_fcs4, "01234567");
    try expectDecode(&golden.frame_fcs8, "01234567");
    try expectDecode(&golden.frame_unused_bit, "abcd");
    // §3.1.1.1.1.4 + §3.1.1.1.3 — the reserved bit and the dictionary ID are
    // the two header refusals, each before any body byte.
    try expectDecodeError(error.ReservedBitSet, &golden.frame_reserved_bit, 0);
    try expectDecodeError(error.DictionaryRequired, &golden.frame_dictionary_id, 0);
    try expectDecodeError(error.DictionaryRequired, &golden.frame_dictionary_id_wide, 0);
    try expectDecodeError(error.Truncated, &golden.frame_dictionary_id_truncated, 0);
}

test "decompress verifies the checksum trailer" {
    // RFC 8878 §3.1.1 — the trailer is the low 4 bytes of the decoded data's
    // XXH64, little-endian: a good one passes, a flipped one is
    // `WrongChecksum` (the CLI: "Restored data doesn't match checksum"), and
    // a missing one is the input's end.
    try expectDecode(&golden.frame_checksum, "abcd");
    try expectDecode(&golden.frame_checksum_empty, "");
    try expectDecode(&golden.frame_checksum_off, "abcd");
    // The corrupt-trailer frame decodes "abcd" and then fails: the four bytes
    // the frame produced are the decode's, and the check that refused them
    // wrote nothing.
    try expectDecodeError(error.WrongChecksum, &golden.frame_checksum_corrupt, 4);
    try expectDecodeError(error.Truncated, &golden.frame_checksum_truncated, 4);
}

test "decompress skips skippable frames and resumes after them" {
    // RFC 8878 §3.1.2 — "From a compliant decoder perspective, skippable
    // frames simply need to be skipped, and their content ignored, resuming
    // decoding after the skippable frame"; "All 16 values are valid to
    // identify a skippable frame." Leading skippables, consecutive ones, and
    // a frame between them all decode to the frame's output.
    try expectDecode(&golden.skippable_prefix, "zstd raw");
    try expectDecode(&golden.skippable_around, "zstd raw");
    // §3.1.2 + T10 — a stream of only skippable frames is the clean end with
    // zero bytes served (the CLI decodes all sixteen to zero bytes cleanly).
    var target: [64]u8 = undefined;
    internal.sentinel.fill(&target);
    try testing.expectEqual(@as(usize, 0), try decompress(&golden.skippable_sixteen, &target));
    try internal.sentinel.expect(&target, 0);
    // The magic one past the range is neither family, and a truncated
    // skippable is the input's end.
    try expectDecodeError(error.BadMagic, &golden.skippable_bad_magic, 0);
    try expectDecodeError(error.Truncated, &golden.skippable_truncated, 0);
    // §3.1 — a flipped Zstandard magic is neither family either (the CLI:
    // "unsupported format").
    try expectDecodeError(error.BadMagic, &golden.frame_bad_magic, 0);
}

test "decompress ignores bytes after the frame" {
    // RFC 8878 §3.1 defines frames, not files; T10 records the CLI's
    // trailing-bytes behavior and the one-shot's rule is the M3 member
    // boundary: one frame by exact consumption, the rest untouched. A
    // multi-frame file's tail is `Reader.streamAll`'s walk.
    try expectDecode(&golden.frame_trailing_garbage, "zstd raw");
    try expectDecode(&golden.frame_two_frames, "zstd raw");
}

test "decompress's cardinality rules for the empty and short inputs" {
    // T10 — the gzip decision mapped over: a zero-byte input is `Truncated`
    // (no frame unit began; the CLI fails "unexpected end of file"), and so
    // is a partial magic or one after skippable frames.
    var target: [64]u8 = undefined;
    internal.sentinel.fill(&target);
    try testing.expectError(error.Truncated, decompress(&.{}, &target));
    try testing.expectError(error.Truncated, decompress(&.{ 0x28, 0xb5 }, &target));
    // The magic alone: the frame began, the header did not.
    try testing.expectError(error.Truncated, decompress(&golden.frame_magic, &target));
    try testing.expectError(
        error.Truncated,
        decompress(golden.skippable_prefix[0 .. golden.skippable_prefix.len - 1], &target),
    );
    try internal.sentinel.expect(&target, 0);
}

test "decompress fails closed on the negative corners" {
    // RFC 8878 §3.1.1.2.4 (Block_Maximum_Size), §3.1.1.2.2 (the reserved
    // block), §3.1.1.3.1.1 (a literals section with no header), §3.1.1.3.2.1
    // (a sequences section cut inside its fields), §3.1.1.1.4 (the FCS
    // checks), §3.1.1.4 (the window bound), §3.1.1.3.1.1 (Treeless with no
    // tree), §3.1.1.3.2.1 (Repeat with no tables): the CLI exits 1 on every
    // one of these, and the sentinel proves each failure lands before its
    // write.
    try expectDecodeError(error.ReservedBlock, &golden.frame_reserved, 0);
    try expectDecodeError(error.BlockOversize, &golden.frame_oversize_raw, 0);
    try expectDecodeError(error.BlockOversize, &golden.frame_oversize_rle, 0);
    try expectDecodeError(error.BlockOversize, &golden.frame_single_segment_oversize, 0);
    // This frame's first block is a 16-byte Raw block; the compressed one
    // that follows declares a match past Block_Maximum_Size and is refused
    // before its own write.
    try expectDecodeError(error.BlockOversize, &golden.frame_amplify_match, 16);
    try expectDecodeError(error.LiteralsTooLarge, &golden.frame_oversize_literals, 0);
    try expectDecodeError(error.TreelessLiteralsFirst, &golden.frame_treeless_first, 0);
    try expectDecodeError(error.RepeatModeFirst, &golden.frame_repeat_first, 0);
    try expectDecodeError(error.MalformedLiteralsHeader, &golden.frame_empty_compressed, 0);
    try expectDecodeError(error.MalformedSequencesHeader, &golden.frame_no_sequences, 0);
    try expectDecodeError(error.MalformedSequencesHeader, &golden.frame_short_sequences, 0);
    try expectDecodeError(error.Truncated, &golden.frame_short_raw, 0);
    try expectDecodeError(error.Truncated, &golden.frame_short_compressed, 0);
    try expectDecodeError(error.Truncated, &golden.frame_truncated_header, 0);
    // Frame_Content_Size is a check on the decode, and both checks land
    // after the block that broke them: the 8 bytes are in the target, and
    // the failing byte was never written.
    try expectDecodeError(error.ContentSizeMismatch, &golden.frame_fcs_short, 8);
    try expectDecodeError(error.ContentSizeMismatch, &golden.frame_fcs_long, 8);
    // The 8-byte form's maximum (2^64-1): the C's `ZSTD_CONTENTSIZE_UNKNOWN`
    // sentinel, which the RFC does not have — a declaration here, checked
    // against the decode like any other, with nothing sized from it.
    try expectDecodeError(error.ContentSizeMismatch, &golden.frame_fcs_max, 4);
    // The one-byte-past-the-window pair: ours enforces §3.1.1.4's declared
    // bound and refuses what the CLI's whole-buffer decoder accepts (T12).
    // Two 1 KB (128 KB) RLE blocks decoded before the offending match.
    try expectDecodeError(error.OffsetTooFar, &golden.frame_window_1k_over, 2048);
    try expectDecodeError(error.OffsetTooFar, &golden.frame_window_128k_over, 262144);
}

test "decompress caps the output at target" {
    // RFC 8878 §3.1.1.2.4 + §8 — "Each frame must have at least 1 block"
    // and a declared size is a bound, never a license: every output path
    // fails `BufferTooSmall` before the write that would pass the cap, and
    // the sentinel proves the byte past it is untouched. The one-shot has no
    // window buffer to grow: `target` is the cap and the history both.
    var small: [7]u8 = undefined;
    internal.sentinel.fill(&small);
    try testing.expectError(error.BufferTooSmall, decompress(&golden.frame_raw, &small));
    try internal.sentinel.expect(&small, 0);
    // A zero-cap target: the empty frame decodes, anything else does not.
    var none: [0]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try decompress(&golden.frame_raw_empty, &none));
    try testing.expectError(error.BufferTooSmall, decompress(&golden.frame_raw, &none));
    // An RLE block declaring 128 KB into 100 bytes, and the amplification
    // vector: a compressed block whose sequence declares more than the cap.
    var hundred: [100]u8 = undefined;
    internal.sentinel.fill(&hundred);
    try testing.expectError(error.BufferTooSmall, decompress(&golden.frame_rle_max, &hundred));
    try internal.sentinel.expect(&hundred, 0);
    try testing.expectError(
        error.BufferTooSmall,
        decompress(&golden.frame_sequences_predefined, hundred[0..2]),
    );
    try internal.sentinel.expect(&hundred, 0);
    // The exact fit decodes, one byte under does not: the cap is the frame's
    // length, not a guess at it. At 76 the sequences that fit are written and
    // the one that would pass the cap is refused before its write — the
    // sentinel from 76 proves the cap held.
    var exact: [77]u8 = undefined;
    internal.sentinel.fill(&exact);
    try testing.expectEqual(
        @as(usize, 77),
        try decompress(&golden.frame_sequences_predefined, &exact),
    );
    try testing.expectEqualSlices(u8, &golden.sequences_predefined_expected, &exact);
    try internal.sentinel.expect(&exact, 77);
    try testing.expectError(
        error.BufferTooSmall,
        decompress(&golden.frame_sequences_predefined, hundred[0..76]),
    );
    try internal.sentinel.expect(&hundred, 76);
}

test "decompress's history is the output, so a match cannot reach before it" {
    // RFC 8878 §3.1.1.4 — "all offsets leading to previously decoded data
    // must be smaller than Window_Size": the one-shot has no window buffer,
    // so a frame's first block cannot reference data the frame never
    // produced. The same compressed block at the frame's start is
    // `OffsetTooFar`; inside its frame (two RLE blocks of history) it reads
    // the window's oldest retained byte.
    const header = [_]u8{ 0x00, 0x00 }; // 1 KB window
    const bare = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd } ++ header ++ golden.frame_window_1k[14..];
    try expectDecodeError(error.OffsetTooFar, bare, 0);
    // And the window bound holds at frame scope: the full frame decodes to
    // 2048 + 3 bytes, with the match reading offset 1024 — exactly
    // Window_Size.
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    const written = try decompress(&golden.frame_window_1k, &target);
    try testing.expectEqual(@as(usize, 2048 + 3), written);
    try testing.expectEqualSlices(u8, "BBB", target[2048..2051]);
    try internal.sentinel.expect(&target, written);
    // The 128 KB window sibling, whose decoded length passes both
    // Block_Maximum_Size and Window_Size.
    internal.sentinel.fill(&target);
    const wide = try decompress(&golden.frame_window_128k, &target);
    try testing.expectEqual(@as(usize, 2 * 131072 + 3), wide);
    try testing.expectEqualSlices(u8, "BBB", target[262144..262147]);
    try internal.sentinel.expect(&target, wide);
}
