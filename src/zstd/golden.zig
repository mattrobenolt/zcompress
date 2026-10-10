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
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

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
