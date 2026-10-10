//! The zstd golden fixtures the entropy layers' tests read: `§3.1.1.3.2.2`'s
//! predefined distributions, Appendix A's decoding tables, and the real
//! frames' table descriptions the kernels were validated against. Shared by
//! every layer's tests (the flate/gzip `golden.zig` shape).
//!
//! Provenance, so every fixture can be re-derived:
//!
//! - **The predefined distributions** are `§3.1.1.3.2.2`'s
//!   `literalsLength_defaultDistribution`, `matchLengths_defaultDistribution`,
//!   and `offsetCodes_defaultDistribution`, transcribed verbatim. They are
//!   the sequences layer's Predefined-mode input *and* the input the
//!   Appendix A cross-check builds from — when `sequences.zig` lands it
//!   should own them and this module's test should read them from there,
//!   so the production data lives in production code.
//! - **The Appendix A tables** are the spec's A.1, A.2, and A.3 rows, minus
//!   each table's first data row — errata 6441's all-zero state-0 duplicate
//!   (`docs/research/zstd-notes.md` §4 T2). 64 + 64 + 32 real rows.
//! - **`literals_length_description` and `offset_description`** are the
//!   literals length and offset table descriptions of the first compressed
//!   block of a `zstd -1` frame of a synthetic mixed corpus (a table of
//!   `zstd` v1.5.7, the reference encoder's own `FSE_writeNCount` output).
//!   They pin the `§4.1.1` description reader against real encoder output,
//!   zero runs and all: the counts are what the reader must recover, and the
//!   description's byte count is what the section's next structure depends
//!   on. The same vectors were cross-checked by decoding the whole frame's
//!   sequences section to exact bitstream consumption.
//! - **`t1_*`** are the hand-built T1 pair (`docs/research/zstd-notes.md`
//!   §5.4): a 19-byte frame whose literals stream is `01 0D` or `10 0D` and
//!   which decodes to `00 01 04 05` and `00 01 05 04` respectively on both
//!   the C CLI v1.5.7 and Zig std. `t1_tree` is the direct-weights tree
//!   description, `t1_stream` the Table-25 stream, `t1_errata_stream` the
//!   Table 26 (errata 8195) stream that no conformant decoder follows.
//! - **`weights_description`** is the Huffman_Tree_Description of the first
//!   compressed block of a `zstd -3` frame of synthetic text — the reference
//!   encoder's `HUF_compressWeights` output: the header byte 19, then the
//!   19-byte FSE-compressed series. `weights_expected` is the 122-weight
//!   series it decodes to under `§4.2.1.2`'s two-state,
//!   overflow-terminated decode (total 192, so the implied last weight is 7
//!   and `Max_Number_of_Bits` is 8).
//! - **The `literals_*` sections** are the literals sections of real `zstd`
//!   v1.5.7 frames (`docs/research/zstd-notes.md` §5's golden corpus row),
//!   each a single compressed block whose sequences section is the
//!   zero-sequence byte (`§3.1.1.3.2.1`), so the frame's decoded output is
//!   exactly its literals and both the CLI's `zstd -d` and CPython 3.14's
//!   `compression.zstd` pin the expected bytes. The input in each case is
//!   the research harness's skewed-random corpus (a geometric byte
//!   distribution: Huffman-compressible, effectively match-free), recorded
//!   per fixture; the sizes are `§3.1.1.3.1.1`'s compressed Size_Formats as
//!   the encoder chose them. `literals_fse_tree_section` is hand-built
//!   around the real FSE-compressed weight series above (its streams decode
//!   ten `0x62` symbols through `§4.2.1.3`'s assignment), verified the same
//!   way.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;

/// Comptime hex decoding, so the ported vectors keep their source spelling
/// (the CLI's own hex output, the research harness's dumps) instead of a
/// byte-list transcription (the flate/gzip golden shape).
fn hex(comptime text: []const u8) [text.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    comptime assert(text.len % 2 == 0);
    var bytes: [text.len / 2]u8 = undefined;
    for (&bytes, 0..) |*byte, i| {
        byte.* = std.fmt.parseInt(u8, text[i * 2 ..][0..2], 16) catch unreachable;
    }
    return bytes;
}

/// One row of an Appendix A table (`§4.1`'s Symbol / Num_Bits / Baseline).
pub const TableRow = struct {
    symbol: u8,
    num_bits: u5,
    baseline: u16,
};

/// RFC 8878 §4.2.2 — the T1 pair's Huffman tree description: the direct
/// mode, `Number_of_Symbols = 5`, weights 4, 3, 2, 0, 1 (`§4.2.1.1`).
pub const t1_tree = [_]u8{ 0x84, 0x43, 0x20, 0x10 };
/// RFC 8878 §4.2.1.3 Table 25 — the codes of `t1_tree`: 4 -> 0000,
/// 5 -> 0001 (the RFC's §4.2.2 example swaps them; errata 8195, T1).
pub const t1_stream = [_]u8{ 0x01, 0x0d };
/// The literals `t1_stream` decodes to: "0145" = symbols 0, 1, 4, 5.
pub const t1_literals = [_]u8{ 0, 1, 4, 5 };
/// The §4.2.2 example's own bytes (errata 8195): they decode to 0, 1, 5, 4
/// — the swapped assignment no decoder follows.
pub const t1_errata_stream = [_]u8{ 0x10, 0x0d };
pub const t1_errata_literals = [_]u8{ 0, 1, 5, 4 };
/// `t1_tree`'s `Max_Number_of_Bits` (`§4.2.1`: the completion lands on 16).
pub const t1_max_bits: u5 = 4;
/// The T1 pair's whole literals sections (`§3.1.1.3.1.1` Size_Format 00,
/// one stream; Compressed_Size = 6 covers the 4-byte tree and the stream):
/// the 3-byte header, the tree, and the stream. Decoding the section must
/// give `t1_literals` / `t1_errata_literals`.
pub const t1_literals_section: [9]u8 = [3]u8{ 0x42, 0x80, 0x01 } ++ t1_tree ++ t1_stream;
pub const t1_errata_literals_section: [9]u8 =
    [3]u8{ 0x42, 0x80, 0x01 } ++ t1_tree ++ t1_errata_stream;

pub const literals_length_distribution = [_]i16{
    4, 3, 2, 2, 2, 2, 2, 2, 2,  2,  2,  2,
    2, 1, 1, 1, 2, 2, 2, 2, 2,  2,  2,  2,
    2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
};
pub const match_length_distribution = [_]i16{
    1,  4,  3,  2,  2,  2, 2, 2, 2, 1, 1,  1,
    1,  1,  1,  1,  1,  1, 1, 1, 1, 1, 1,  1,
    1,  1,  1,  1,  1,  1, 1, 1, 1, 1, 1,  1,
    1,  1,  1,  1,  1,  1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1, -1, -1,
};
pub const offset_distribution = [_]i16{
    1,  1,  1,  1,  1,  1, 2, 2, 2, 1, 1, 1,
    1,  1,  1,  1,  1,  1, 1, 1, 1, 1, 1, 1,
    -1, -1, -1, -1, -1,
};
pub const literals_length_table = [_]TableRow{
    .{ .symbol = 0, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 0, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 1, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 3, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 4, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 6, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 7, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 9, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 10, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 12, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 14, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 16, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 18, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 19, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 21, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 22, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 24, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 25, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 26, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 27, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 29, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 31, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 0, .num_bits = 4, .baseline = 32 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 2, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 4, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 5, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 7, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 8, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 10, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 11, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 13, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 16, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 17, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 19, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 20, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 22, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 23, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 25, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 25, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 26, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 28, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 30, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 0, .num_bits = 4, .baseline = 48 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 2, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 3, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 5, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 6, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 8, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 9, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 11, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 12, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 15, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 17, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 18, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 20, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 21, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 23, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 24, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 35, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 34, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 33, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 32, .num_bits = 6, .baseline = 0 },
};
pub const match_length_table = [_]TableRow{
    .{ .symbol = 0, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 2, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 3, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 5, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 6, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 8, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 10, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 13, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 16, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 19, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 22, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 25, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 28, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 31, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 33, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 35, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 37, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 39, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 41, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 43, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 45, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 2, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 3, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 4, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 6, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 7, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 9, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 12, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 15, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 18, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 21, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 24, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 27, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 30, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 32, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 34, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 36, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 38, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 40, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 42, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 44, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 32 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 48 },
    .{ .symbol = 2, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 4, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 5, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 7, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 8, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 11, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 14, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 17, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 20, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 23, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 26, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 29, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 52, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 51, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 50, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 49, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 48, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 47, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 46, .num_bits = 6, .baseline = 0 },
};
pub const offset_table = [_]TableRow{
    .{ .symbol = 0, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 6, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 9, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 15, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 21, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 3, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 7, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 12, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 18, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 23, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 5, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 8, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 14, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 20, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 2, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 7, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 11, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 17, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 22, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 4, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 8, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 13, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 19, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 1, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 6, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 10, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 16, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 28, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 27, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 26, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 25, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 24, .num_bits = 5, .baseline = 0 },
};
pub const literals_length_description = [_]u8{
    0x14, 0x1f, 0x01, 0x20, 0x10, 0xb4, 0xd0, 0xbf, 0x00,
};
pub const literals_length_description_counts = [_]i16{
    496, 7, -1, -1, -1, -1, 0, -1, 0, -1, 0, 0,
    0,   0, 0,  0,  -1, -1, 0, 0,  0, 0,  0, 0,
    0,   0, 0,  0,  0,  0,  0, 0,  0, -1,
};
pub const offset_description = [_]u8{
    0x73, 0x10, 0x00, 0xe0, 0xa0, 0xa1, 0xd2, 0xd1, 0xb6, 0xd9, 0x48, 0x0d,
};
pub const offset_description_counts = [_]i16{
    6,  0, -1, 13, 25, 41, 57, 51, 26, 18, 12, 3,
    -1, 0, 0,  2,
};
pub const weights_description = [_]u8{
    0x13, 0xb0, 0xa5, 0x99, 0x03, 0x0e, 0x89, 0x98, 0x90, 0x65, 0xde, 0x6a,
    0x21, 0x49, 0x93, 0x19, 0x06, 0x1f, 0x03, 0x60,
};
pub const weights_description_counts = [_]i16{ 26, 1, 1, 2, 1, 0, 0, 0, 1 };
/// A real `zstd -1` frame of the skewed-random corpus (120 bytes, seed 9):
/// Size_Format 00, one stream, rs = 120, cs = 37 — the 1-stream layout with
/// a real direct-weights tree.
pub const literals_1stream_section = hex(
    "824709855431111f26493580af02b85769fb0d42816b26c3a5925aa399d3662b" ++
        "002c31311d940d04",
);
pub const literals_1stream_expected = hex(
    "0301000100020103000000010200050100050101000303020101000100020001" ++
        "0001020000020002000106010100010102020101020100000400020200020001" ++
        "0100000301010403000001000000000001000100010201010100000001000003" ++
        "040101010000000003040001010102020202000400000000",
);

/// A real `zstd -19` frame of the skewed-random corpus (260 bytes, seed 0):
/// Size_Format 01, four streams, rs = 260, cs = 74 — the Jump_Table and the
/// `(Regenerated_Size+3)/4` segmentation with a real tree.
pub const literals_4stream_sf1_section = hex(
    "469012856543210d0012001200ebfdfa33eadf58c95ac7bd9d721b6a96b6e342" ++
        "59c82354866c270146722fa53f423e4ed12c848e32913d1900248dfa7d14c165" ++
        "0ecf4bf5efb414a843cae4757f",
);
pub const literals_4stream_sf1_expected = hex(
    "0000020102000001000100000001000003000001010001010002020101000300" ++
        "0100000000000000010103000200000000000001010000000000010000000101" ++
        "0001020102010000000100000202030005020202000001000100020400020101" ++
        "0403000000020401000201040100000300000100010001020100020001010400" ++
        "0100010300000000010000000000010103000102020505010002020000000100" ++
        "0203020002010300000104040100020001030102000003000000000204030000" ++
        "0000000000000000000100000101000000020200020102040000010105000102" ++
        "0100010200000100000000000000010101020100000002000000040000020002" ++
        "01000006",
);

/// A real `zstd -19` frame of the skewed-random corpus (1030 bytes, seed 2):
/// Size_Format 10, four streams, rs = 1030, cs = 268 — the 14-bit sizes and
/// a real Jump_Table at realistic magnitudes.
pub const literals_4stream_sf2_section = hex(
    "6a403004888765431110400040004000f94b5bc940528712fbbf96b00205afae" ++
        "9502dc928ea4b6efb95ea771b56b1cf2e015f7908a60d225bb04218f0f5215f9" ++
        "6124a9284bddf955dcaeed7738e071e77bda8f3e217268a9481ee09acde92328" ++
        "2d7c9be9b66f579f033c3a875650d393bdfc9aa20ef0ab0d527cb39322246f06" ++
        "6ea9b271e3f97433c0fc814f69412e019ba58acdd3924b9d7b943ccb60d034dd" ++
        "8fed536ac7f28dbabb1f1d1184b46eb803b26bf0dce1f1ce55c1c2a8f0efbabc" ++
        "d38ceb18900147037a9b340b70a78d014dc3ff792ed399720ddda3d67f80ef1c" ++
        "b488da53ba051aaa88853c19ad964388045dbfcf703a407a540e80d43be9eafd" ++
        "1d170d5b8ac1c90d06f811e6a9b39871",
);
pub const literals_4stream_sf2_expected = hex(
    "0000020000010000030000000700000400000100000000000100010001010000" ++
        "0100010000030101010000000000020000010000010102010002010301010202" ++
        "0203000400000000000203010101010205000000000300000002040502010000" ++
        "0100020201000001020200050301010204000000010000030101000000050000" ++
        "0002040000030001010000010001010100000300010200000101000000010100" ++
        "0002000000010000000001000100010102020300000102020100010000060001" ++
        "0201010001010000010101000000050108000100040201000101000000000000" ++
        "0000000001000302010400000101020209020201010001000102010000000000" ++
        "0002020100000205010001020102000000000900000000000200060000020001" ++
        "0000010200000000020000000300010000030001000201010102010001000009" ++
        "0200010000000202040301020200000100020001000000000301020500010001" ++
        "0101000000000006000000010103010200010100000000000201000000010002" ++
        "0200000001020001010501010001040000020000010300000006000000020000" ++
        "0000010101000001000100000000010001000100000102000200010001000000" ++
        "0004010001020105030000000001020000020001000200010100000600000000" ++
        "0202030101020100010400000203040200000000010300000000000100010200" ++
        "0000010000030001000102000001000006000100020001020200010001000000" ++
        "0107000103000007000207000300000101000003000200010200000100000002" ++
        "0100000101000001000000000000000401010300040100050101010100000200" ++
        "0001000000030000000400000100000200000005000101000001000207000001" ++
        "0000040001000001010001020405030300000103000000000001000001000001" ++
        "0000010103000100000000020100030000010001010201020000000001000100" ++
        "0300000000000100000102000102000105000500020100020000000202010300" ++
        "0000010000020000010102010000020201000102000000020001000301010102" ++
        "0100020001000000030002000301000200000101020000000200040300000000" ++
        "0006000005000100000202000005000301020100010004000103010000030000" ++
        "0100000000000001000000010101000001020200000100000001010206030000" ++
        "0201010300000001020600000001020000040002000000000100000000000101" ++
        "0000010502030404000002010001010100010300020200000002040100030301" ++
        "0101040001080000010000010201020000000100010103030100010500000200" ++
        "0001000000000600000000000000000001010001010300000001000001040001" ++
        "0100000201020002000001020002010000020000000200000000000000000000" ++
        "040001020001",
);

/// A hand-built section around the real FSE-compressed weight series below:
/// Size_Format 01, four streams, rs = 10, cs = 30 (the 20-byte description
/// plus the 6-byte Jump_Table and four 1-byte streams). Its streams decode
/// `weights_expected`'s weight-8 symbol (98, the shortest code) ten times.
pub const literals_fse_tree_section = hex(
    "a6800713b0a599030e89989065de6a21499319061f03600100010001000f0f0f03",
);
pub const literals_fse_tree_expected = [_]u8{0x62} ** 10;

pub const weights_expected = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 4, 8, 2, 3, 4, 0, 2, 1, 1, 0, 0,
    4, 3, 1, 3, 3, 0, 3, 3, 3, 0, 0, 0,
    0, 1,
};
