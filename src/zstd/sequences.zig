//! The sequences section of a compressed block (`§3.1.1.3.2`): the header
//! (Number_of_Sequences and Symbol_Compression_Modes), the per-alphabet
//! decoding tables, the interleaved backwards bitstream, and Sequence
//! Execution (`§3.1.1.4`) with the repeat offsets (`§3.1.1.5`).
//!
//! `Sequences_Section_Size = Block_Size - Literals_Section_Header -
//! Literals_Section_Content` (`§3.1.1.3.2`), so `decode` takes the block's
//! remaining bytes after the literals section, the decoded literals as the
//! copy source, the caller's output region with its history, and the frame's
//! `State`; it returns the block's output length and the section bytes it
//! consumed. That is the whole hand-off from the block slice: `literals`'s
//! `decode` hands over the literals and where they ended, this hands over the
//! rest of the block.
//!
//! The section's four parts, in order:
//!
//! - **Number_of_Sequences** (`§3.1.1.3.2.1`): 1-3 bytes. `byte0 == 0` ends
//!   the section — "Decompressed content is defined entirely as
//!   Literals_Section content. The FSE tables used in Repeat_Mode are not
//!   updated" — and the reference ends it on a *decoded* zero in any form,
//!   which the 2-byte `80 00` count reaches; std rejects that corner, ours
//!   is the reference's (T5, docs/research/zstd-notes.md §4). Bytes past the
//!   count are corruption — the reference's "extraneous data present in the
//!   Sequences section", `BitstreamNotConsumed` here, the section's
//!   exact-consumption rule applied to a section with no bitstream.
//! - **Symbol_Compression_Modes** (`§3.1.1.3.2.1`, Table 14): one byte, bits
//!   7-6 literals lengths, 5-4 offsets, 3-2 match lengths, 1-0 Reserved —
//!   "The last field, Reserved, must be all zeroes" (`ReservedModeBits`).
//!   Each mode is Predefined / RLE / FSE_Compressed / Repeat (Table 15).
//! - **The tables**, in the order Literals_Length, Offset, Match_Length
//!   (`§3.1.1.3.2`). A description is read from the section's *remaining*
//!   bytes — never an exact-size slice, because its own length is what the
//!   `§4.1.1` reader recovers and the reference reads it through a window.
//!   Repeat reuses the frame's previous table for that alphabet and is
//!   corruption without one (`RepeatModeFirst`).
//! - **The bitstream** (`§3.1.1.3.2.1.2`): read backwards from the block's
//!   last byte, the last byte nonzero (its highest set bit is the final 1
//!   bit), the initial states in the order Literals_Length, Offset, Match
//!   Length, and per sequence the extra bits in the order offset, match
//!   length, literals length. The states update — except after the last
//!   sequence — in the order literals length, match length, offset, "and at
//!   the end, the bitstream shall be entirely consumed".
//!
//! Sequence Execution (`§3.1.1.4`) copies `literals_length` bytes from the
//! literals, then `match_length` bytes from the history at the offset, where
//! an offset below the match length replicates the offset-byte pattern
//! ("an offset of 6 and a match length of 3 means that 3 bytes should be
//! copied from 6 bytes back"). The offset comes from `Offset_Value =
//! (1 << offsetCode) + readNBits(offsetCode)`: above 3 it is `Offset_Value -
//! 3`, and 1-3 select the repeat offsets, which rotate on use (`§3.1.1.5`).
//! Two corners the rules carry and the tests pin: when the sequence's
//! literals length is 0 the repeat offsets shift by one (offset_value 1 is
//! Repeated_Offset2, 2 is Repeated_Offset3, 3 is Repeated_Offset1 - 1 byte),
//! and an offset_value above 3 shifts the repeats whatever the offset's
//! value — the equal-offsets rule (Table 18's cells carry errata 6442; the
//! rules are the test source, T3). Offset 0 is `ZeroOffset` (T6: the C and
//! std reject it, klauspost silently decodes a corrupt frame).
//!
//! **The bounds are the caller's slice.** A match offset may reach back into
//! `target[0..history_len]` and no further, so the caller passes the history
//! it authorizes — the frame's decoded bytes so far, capped at the frame's
//! Window_Size (`§3.1.1.4`: "all offsets leading to previously decoded data
//! must be smaller than Window_Size") — and an offset beyond it is
//! `OffsetTooFar`. The section never writes past `target`, and never reads
//! past the literals or the section's own bytes: every declared size is a
//! bound, never a license (`§8`'s amplification vectors, which this layer
//! answers for the sequences: a Number_of_Sequences past the block cannot
//! read past the staged section, and each sequence's match writes at least
//! 3 bytes, so the loop is bounded by the target).
//!
//! Zero allocation: the decoding tables are the frame state's or the
//! section's own stack, the bitstream reads the caller's bytes.
//!
//! One error name here is this layer's addition to the README's public set:
//! `MalformedSequencesHeader`, the section's fixed-size fields running past
//! the block's remaining bytes — the literals layer's
//! `MalformedLiteralsHeader` mirrored, the reference's `srcSize_wrong`. Every
//! reference distinguishes the class and the sketch's list has no name for
//! it, so the block slice carries it into `zstd.decode.DecompressError`.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const bits = @import("bits.zig");
const fse = @import("fse.zig");
const golden = @import("golden.zig");
const literals = @import("literals.zig");

/// Everything the sequences layer reports.
pub const Error = error{
    /// The section's fixed-size fields — the Number_of_Sequences bytes, the
    /// Symbol_Compression_Modes byte, an RLE_Mode symbol byte — run past the
    /// block's remaining bytes (`§3.1.1.3.2.1`). The reference's
    /// `srcSize_wrong`; never `Truncated`, which is the input's end.
    MalformedSequencesHeader,
    /// `§3.1.1.3.2.1` — "The last field, Reserved, must be all zeroes."
    ReservedModeBits,
    /// `§3.1.1.3.2.1` — Repeat_Mode "used without any previous sequence
    /// table in the frame ... to repeat, this should be treated as
    /// corruption."
    RepeatModeFirst,
    /// A sequence's literals_length reaches past the literals section's
    /// Regenerated_Size — a declared size the section cannot supply.
    LiteralsTooLarge,
    /// A sequence or the trailing literals would write past the caller's
    /// `target` (`§3.1.1.2.4`'s Block_Maximum_Size is the caller's cap).
    BufferTooSmall,
    /// `§3.1.1.5` — the repeat-offset arithmetic reached offset 0: an
    /// offset_value of 3 with literals_length 0 means Repeated_Offset1 - 1
    /// byte, which is 0 when Repeated_Offset1 is 1 (T6).
    ZeroOffset,
    /// `§3.1.1.4` — "all offsets leading to previously decoded data must be
    /// smaller than Window_Size": the offset reaches past the history the
    /// caller authorized.
    OffsetTooFar,
} || fse.Error;

/// `§3.1.1.3.2.1.1`, Table 16 — literals length codes 0-35, "They define
/// lengths from 0 to 131071 bytes."
pub const literals_length_code_max: u8 = 35;

/// `§3.1.1.3.2.1.1`, Table 17 — match length codes 0-52, "They define lengths
/// from 3 to 131074 bytes."
pub const match_length_code_max: u8 = 52;

/// `§3.1.1.3.2.1.1` — "A decoder is free to limit its maximum supported
/// value for N. Support for values of at least 22 is recommended. At the time
/// of this writing, the reference decoder supports a maximum N value of 31."
/// Ours is the reference's 31.
pub const offset_code_max: u5 = 31;

/// `§3.1.1.3.2.1.1` — an offset code's `Offset_Value = (1 << offsetCode) +
/// readNBits(offsetCode)`, "supporting back-reference distance up to
/// (2^(N+1)) - 4".
pub const offset_value_max: u32 = (@as(u32, 1) << offset_code_max) + 0x7fffffff;

/// The three symbol types of a sequences section (`§3.1.1.3.2`), in the
/// section's own order — the header's `[Literals_Length_Table]
/// [Offset_Table] [Match_Length_Table]`, and the bitstream's initial-state
/// order (`§3.1.1.3.2.1.2`).
pub const Alphabet = enum(u2) {
    literals_lengths = 0,
    offsets = 1,
    match_lengths = 2,
};

/// The alphabets' number.
pub const alphabet_count = @typeInfo(Alphabet).@"enum".fields.len;

/// `§3.1.1.3.2.1`, Table 15 — the four Compression_Modes of each symbol type.
pub const Mode = enum(u2) {
    predefined = 0,
    rle = 1,
    fse = 2,
    repeat = 3,
};

/// One `§3.1.1.3.2.1.1` code: "The [value] is equal to the decoded Baseline
/// plus the result of reading Number_of_Bits bits from the bitstream, as a
/// little-endian value."
pub const Code = struct {
    baseline: u32,
    /// The RFC's Number_of_Bits: the extra bits read *after* the code's own.
    extra_bits: u5,
};

/// `§3.1.1.3.2.1.1`, Table 16 — "Literals length codes are values ranging
/// from 0 to 35 ... Codes 0-15 are the literal length itself" with no extra
/// bits, then the baseline/extra-bits bands up to code 35's 65536 + 16 bits.
pub const literals_length_codes: [literals_length_code_max + 1]Code = blk: {
    @setEvalBranchQuota(10_000);
    var codes: [literals_length_code_max + 1]Code = undefined;
    for (codes[0..16], 0..) |*code, length| code.* = .{ .baseline = length, .extra_bits = 0 };
    const bands = [20]Code{
        .{ .baseline = 16, .extra_bits = 1 },
        .{ .baseline = 18, .extra_bits = 1 },
        .{ .baseline = 20, .extra_bits = 1 },
        .{ .baseline = 22, .extra_bits = 1 },
        .{ .baseline = 24, .extra_bits = 2 },
        .{ .baseline = 28, .extra_bits = 2 },
        .{ .baseline = 32, .extra_bits = 3 },
        .{ .baseline = 40, .extra_bits = 3 },
        .{ .baseline = 48, .extra_bits = 4 },
        .{ .baseline = 64, .extra_bits = 6 },
        .{ .baseline = 128, .extra_bits = 7 },
        .{ .baseline = 256, .extra_bits = 8 },
        .{ .baseline = 512, .extra_bits = 9 },
        .{ .baseline = 1024, .extra_bits = 10 },
        .{ .baseline = 2048, .extra_bits = 11 },
        .{ .baseline = 4096, .extra_bits = 12 },
        .{ .baseline = 8192, .extra_bits = 13 },
        .{ .baseline = 16384, .extra_bits = 14 },
        .{ .baseline = 32768, .extra_bits = 15 },
        .{ .baseline = 65536, .extra_bits = 16 },
    };
    for (bands, 16..) |band, index| codes[index] = band;
    break :blk codes;
};

/// `§3.1.1.3.2.1.1`, Table 17 — "Match length codes are values ranging from 0
/// to 52 ... Codes 0-31 are Match_Length_Code + 3" with no extra bits, then
/// the bands up to code 52's 65539 + 16 bits.
pub const match_length_codes: [match_length_code_max + 1]Code = blk: {
    @setEvalBranchQuota(10_000);
    var codes: [match_length_code_max + 1]Code = undefined;
    for (codes[0..32], 0..) |*code, symbol| code.* = .{ .baseline = symbol + 3, .extra_bits = 0 };
    const bands = [21]Code{
        .{ .baseline = 35, .extra_bits = 1 },
        .{ .baseline = 37, .extra_bits = 1 },
        .{ .baseline = 39, .extra_bits = 1 },
        .{ .baseline = 41, .extra_bits = 1 },
        .{ .baseline = 43, .extra_bits = 2 },
        .{ .baseline = 47, .extra_bits = 2 },
        .{ .baseline = 51, .extra_bits = 3 },
        .{ .baseline = 59, .extra_bits = 3 },
        .{ .baseline = 67, .extra_bits = 4 },
        .{ .baseline = 83, .extra_bits = 4 },
        .{ .baseline = 99, .extra_bits = 5 },
        .{ .baseline = 131, .extra_bits = 7 },
        .{ .baseline = 259, .extra_bits = 8 },
        .{ .baseline = 515, .extra_bits = 9 },
        .{ .baseline = 1027, .extra_bits = 10 },
        .{ .baseline = 2051, .extra_bits = 11 },
        .{ .baseline = 4099, .extra_bits = 12 },
        .{ .baseline = 8195, .extra_bits = 13 },
        .{ .baseline = 16387, .extra_bits = 14 },
        .{ .baseline = 32771, .extra_bits = 15 },
        .{ .baseline = 65539, .extra_bits = 16 },
    };
    for (bands, 32..) |band, index| codes[index] = band;
    break :blk codes;
};

/// The offset alphabet's code count: codes 0-31.
const offset_code_count = @as(usize, offset_code_max) + 1;

/// `§3.1.1.3.2.1.1` — "Offset_Value = (1 << offsetCode) + readNBits(offsetCode)",
/// so the offset code's Baseline is the `1 << code` term and its extra bits
/// are the code itself. Codes 0-31 are the reference's range; the predefined
/// offset table (`§3.1.1.3.2.2.3`) tops out at 28.
pub const offset_codes: [offset_code_count]Code = blk: {
    @setEvalBranchQuota(10_000);
    var codes: [offset_code_count]Code = undefined;
    for (&codes, 0..) |*code, symbol| {
        code.* = .{ .baseline = @as(u32, 1) << @intCast(symbol), .extra_bits = @intCast(symbol) };
    }
    break :blk codes;
};

/// `§3.1.1.3.2.2.1` — `literalsLength_defaultDistribution[36]`, "The decoding
/// table uses an accuracy log of 6 bits (64 states)", transcribed verbatim.
pub const literals_length_distribution = [36]i16{
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1,  1,  2,  2,
    2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
};

/// `§3.1.1.3.2.2.2` — `matchLengths_defaultDistribution[53]`, accuracy log 6.
pub const match_length_distribution = [53]i16{
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1,  1,  1,  1,  1,  1,  1,  1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  1,  1,  1,  1,  1,  1,  1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1,
};

/// `§3.1.1.3.2.2.3` — `offsetCodes_defaultDistribution[29]`, accuracy log 5,
/// "supports a maximum N value of 28".
pub const offset_distribution = [29]i16{
    1,  1,  1,  1,  1,  1, 2, 2, 2, 1, 1, 1,
    1,  1,  1,  1,  1,  1, 1, 1, 1, 1, 1, 1,
    -1, -1, -1, -1, -1,
};

/// One alphabet's context (`§3.1.1.3.2.1`, Table 15; `§3.1.1.3.2.2`).
const AlphabetSpec = struct {
    /// The alphabet's last code (`§4.1.1`'s `maxSymbolValue`): the FSE
    /// description may not name a symbol past it, nor may RLE_Mode.
    symbol_value_max: u16,
    /// "the maximum allowed accuracy log for literals length code and match
    /// length code tables is 9, and the maximum accuracy log for the offset
    /// code table is 8" (`§3.1.1.3.2.1`).
    accuracy_log_max: u5,
    /// The Predefined_Mode distribution's accuracy log (`§3.1.1.3.2.2`).
    accuracy_log_default: u5,
    distribution: []const i16,
    codes: []const Code,
};

const alphabet_specs = [alphabet_count]AlphabetSpec{
    .{
        .symbol_value_max = literals_length_code_max,
        .accuracy_log_max = 9,
        .accuracy_log_default = 6,
        .distribution = &literals_length_distribution,
        .codes = &literals_length_codes,
    },
    .{
        .symbol_value_max = offset_code_max,
        .accuracy_log_max = 8,
        .accuracy_log_default = 5,
        .distribution = &offset_distribution,
        .codes = &offset_codes,
    },
    .{
        .symbol_value_max = match_length_code_max,
        .accuracy_log_max = 9,
        .accuracy_log_default = 6,
        .distribution = &match_length_distribution,
        .codes = &match_length_codes,
    },
};

/// The alphabets' contexts.
fn specOf(alphabet: Alphabet) AlphabetSpec {
    return alphabet_specs[@intFromEnum(alphabet)];
}

/// `§3.1.1.3.2.2`'s three distributions through `§4.1.1`'s construction: the
/// Predefined_Mode tables, built once at comptime — a Predefined alphabet
/// costs no per-block work.
const predefined_tables: [alphabet_count]fse.Table = blk: {
    @setEvalBranchQuota(100_000);
    var tables: [alphabet_count]fse.Table = undefined;
    for (alphabet_specs, 0..) |spec, index| {
        tables[index] = fse.buildTable(spec.distribution, spec.accuracy_log_default);
    }
    break :blk tables;
};

/// `§3.1.1.3.2.1` — "RLE_Mode: The table description consists of a single
/// byte, which contains the symbol's value. This symbol will be used for all
/// sequences." One cell read with zero bits, so the state never moves (the
/// reference's `ZSTD_buildSeqTable_rle`); the code's Baseline and extra bits
/// come from the alphabet's code table, as for every other mode.
fn rleTable(symbol: u8) fse.Table {
    var table: fse.Table = .{ .log = 0, .entries = undefined };
    table.entries[0] = .{ .symbol = symbol, .num_bits = 0, .baseline = 0 };
    return table;
}

/// A parsed Sequences_Section_Header (`§3.1.1.3.2.1`).
pub const Header = struct {
    /// Number_of_Sequences: 0, 1-127, `((byte0 - 128) << 8) + byte1`, or
    /// `byte1 + (byte2 << 8) + 0x7F00` (at most 98047).
    sequence_count: u32,
    /// The count field's own length: 1-3 bytes.
    count_len: usize,
    /// The Symbol_Compression_Modes byte's three fields (Table 14), `null`
    /// when the count is zero: "The sequence section stops here", so no mode
    /// byte follows.
    modes: ?Modes,
};

/// `§3.1.1.3.2.1`, Table 14 — one mode per symbol type.
pub const Modes = struct {
    literals_lengths: Mode,
    offsets: Mode,
    match_lengths: Mode,

    fn mode(self: Modes, alphabet: Alphabet) Mode {
        return switch (alphabet) {
            .literals_lengths => self.literals_lengths,
            .offsets => self.offsets,
            .match_lengths => self.match_lengths,
        };
    }
};

/// Parse a Sequences_Section_Header (`§3.1.1.3.2.1`) from the front of a
/// compressed block's sequences section.
pub fn parseHeader(source: []const u8) Error!Header {
    if (source.len < 1) return error.MalformedSequencesHeader;
    const byte0 = source[0];
    var header: Header = .{ .sequence_count = 0, .count_len = 1, .modes = null };
    if (byte0 < 128) {
        // "if (byte0 < 128): Number_of_Sequences = byte0. Uses 1 byte" —
        // byte0 == 0 included: no sequences at all.
        header.sequence_count = byte0;
    } else if (byte0 < 255) {
        if (source.len < 2) return error.MalformedSequencesHeader;
        header.sequence_count = (@as(u32, byte0 - 128) << 8) + source[1];
        header.count_len = 2;
    } else {
        if (source.len < 3) return error.MalformedSequencesHeader;
        header.sequence_count = @as(u32, source[1]) + (@as(u32, source[2]) << 8) + 0x7F00;
        header.count_len = 3;
    }
    // The reference ends the section on a *decoded* zero in any form — the
    // 2-byte `80 00` count reaches here — and std rejects that corner (T5,
    // docs/research/zstd-notes.md §4); ours is the reference's.
    if (header.sequence_count == 0) return header;
    if (source.len < header.count_len + 1) return error.MalformedSequencesHeader;
    const modes_byte = source[header.count_len];
    // "The last field, Reserved, must be all zeroes."
    if (modes_byte & 0b11 != 0) return error.ReservedModeBits;
    header.modes = .{
        .literals_lengths = @enumFromInt(modes_byte >> 6),
        .offsets = @enumFromInt((modes_byte >> 4) & 0b11),
        .match_lengths = @enumFromInt((modes_byte >> 2) & 0b11),
    };
    return header;
}

/// The sequences layer's cross-block state (`§3.1.1.3`): the three decoding
/// tables a Repeat_Mode reuses and the three repeat offsets (`§3.1.1.5`).
/// One per frame, threaded through the block loop; only a Compressed_Block
/// with a nonzero sequence count updates it ("blocks that are not
/// Compressed_Block are skipped; they do not contribute to offset history"),
/// and a zero-count section leaves it alone.
pub const State = struct {
    /// The table each alphabet last decoded with, `null` until the frame's
    /// first sequences section with a nonzero count. "The table used in the
    /// previous Compressed_Block with Number_Of_Sequences > 0 will be used
    /// again ... It also includes Predefined_Mode ... and RLE_Mode", so every
    /// mode stores its resolved table here.
    tables: [alphabet_count]?fse.Table = @splat(null),
    /// Repeated_Offset1/2/3 "sorted in recency order, with Repeated_Offset1
    /// meaning 'most recent one'" (`§3.1.1.5`), seeded {1, 4, 8} "for the
    /// first block ... unless a dictionary is used" (dictionaries are
    /// refused: the README's OQ4).
    repeat_offsets: [3]u32 = repeat_offsets_start,
};

/// `§3.1.1.5` — "For the first block, the starting offset history is
/// populated with the following values: Repeated_Offset1 (1), Repeated_Offset2
/// (4), and Repeated_Offset3 (8)".
pub const repeat_offsets_start = [3]u32{ 1, 4, 8 };

/// One decoded sequences section.
pub const Section = struct {
    /// The block's output: `bytes_written` bytes at `target[history_len..]`.
    bytes_written: usize,
    /// The section bytes consumed. Always all of `source` on success — the
    /// bitstream is the block's tail and "shall be entirely consumed"
    /// (`§3.1.1.3.2.1.2`) — returned so the block layer checks its derived
    /// `Sequences_Section_Size` against it (`§3.1.1.3.2`).
    bytes_consumed: usize,
};

/// Decode one sequences section: `source` is the block's bytes after the
/// literals section (`Sequences_Section_Size`, `§3.1.1.3.2`), `literals_bytes`
/// the decoded literals Sequence Execution copies from, and `target` the
/// caller's contiguous output region — `target[0..history_len]` is the
/// history a match may read (the caller caps it at the frame's Window_Size,
/// `§3.1.1.4`), `target[history_len..]` where this block's output is written.
/// `state` carries the frame's tables and repeat offsets across blocks.
///
/// Every declared size is a bound: the output never exceeds `target`, the
/// literals read never exceeds `literals_bytes`, and no offset reaches past
/// the authorized history — the failures are `BufferTooSmall`,
/// `LiteralsTooLarge`, and `OffsetTooFar`, raised before the offending write.
pub fn decode(
    source: []const u8,
    literals_bytes: []const u8,
    target: []u8,
    history_len: usize,
    state: *State,
) Error!Section {
    assert(history_len <= target.len);
    const header = try parseHeader(source);
    const modes = header.modes orelse
        return decodeEmpty(header, source, literals_bytes, target, history_len);
    // §3.1.1.3.2 — the layout is the header, then "[Literals_Length_Table]
    // [Offset_Table] [Match_Length_Table]", then the bitstream, which is the
    // section's remaining bytes.
    var tables: [alphabet_count]*const fse.Table = undefined;
    const bitstream = source[try resolveTables(source, header, modes, state, &tables)..];
    const written = try executeSequences(
        bitstream,
        header.sequence_count,
        &tables,
        &state.repeat_offsets,
        literals_bytes,
        target,
        history_len,
    );
    return .{ .bytes_written = written, .bytes_consumed = source.len };
}

/// `§3.1.1.3.2`'s table-description order: "[Literals_Length_Table]
/// [Offset_Table] [Match_Length_Table]". The bitstream's initial-state order
/// is the same (`§3.1.1.3.2.1.2`); the state *updates* are not.
const description_order = [alphabet_count]Alphabet{ .literals_lengths, .offsets, .match_lengths };

/// `§3.1.1.3.2.1.2` — "Literals_Length_State is updated, followed by
/// Match_Length_State, and then Offset_State" — the description order with
/// match lengths and offsets swapped.
const update_order = [alphabet_count]Alphabet{ .literals_lengths, .match_lengths, .offsets };

/// A zero Number_of_Sequences (`§3.1.1.3.2.1`): "there are no sequences. The
/// sequence section stops here. Decompressed content is defined entirely as
/// Literals_Section content. The FSE tables used in Repeat_Mode are not
/// updated." The count is the whole section, so the block is its literals —
/// and bytes past the count are corruption: the reference's "extraneous data
/// present in the Sequences section", which is `BitstreamNotConsumed` here
/// (the section's exact-consumption rule, applied to a section with no
/// bitstream).
fn decodeEmpty(
    header: Header,
    source: []const u8,
    literals_bytes: []const u8,
    target: []u8,
    history_len: usize,
) Error!Section {
    if (source.len != header.count_len) return error.BitstreamNotConsumed;
    const written = try appendTrailingLiterals(literals_bytes, target, history_len, 0);
    return .{ .bytes_written = written, .bytes_consumed = source.len };
}

/// Resolve the three alphabets' decoding tables for this block (`§3.1.1.3.2`'s
/// optional per-symbol-type descriptions, in the section's own order) into
/// the frame state, returning where the bitstream starts.
fn resolveTables(
    source: []const u8,
    header: Header,
    modes: Modes,
    state: *State,
    tables: *[alphabet_count]*const fse.Table,
) Error!usize {
    var cursor = header.count_len + 1;
    assert(cursor <= source.len);
    for (description_order) |alphabet| {
        const consumed = try resolveTable(alphabet, source[cursor..], modes.mode(alphabet), state);
        cursor += consumed;
        // A description never reads past the bytes it was handed, so the
        // next table's slice and the bitstream's start are in the section.
        assert(cursor <= source.len);
        tables[@intFromEnum(alphabet)] = &state.tables[@intFromEnum(alphabet)].?;
    }
    return cursor;
}

/// Resolve one alphabet's decoding table for this block (`§3.1.1.3.2.1`'s
/// four Compression_Modes, Table 15) into the frame state, returning the
/// bytes its description consumed.
///
/// `source` is the section's *remaining* bytes, never an exact-size slice: a
/// table description's own length is what `§4.1.1`'s reader recovers, and the
/// reference reads it through a window and validates the byte count after.
fn resolveTable(
    alphabet: Alphabet,
    source: []const u8,
    mode: Mode,
    state: *State,
) Error!usize {
    const index = @intFromEnum(alphabet);
    const spec = specOf(alphabet);
    switch (mode) {
        .predefined => {
            // "A predefined FSE ... distribution table is used, as defined in
            // Section 3.1.1.3.2.2. No distribution table will be present."
            state.tables[index] = predefined_tables[index];
            return 0;
        },
        .rle => {
            // "The table description consists of a single byte, which
            // contains the symbol's value."
            if (source.len < 1) return error.MalformedSequencesHeader;
            const symbol = source[0];
            // The reference rejects a symbol outside the context's alphabet
            // (`ZSTD_buildSeqTable`'s `symbol > max` check); the table such a
            // byte describes is not one of this context's.
            if (symbol > spec.symbol_value_max) return error.MalformedFseTable;
            state.tables[index] = rleTable(symbol);
            return 1;
        },
        .fse => {
            // "Standard FSE compression. A distribution table will be
            // present." The description is the one zstd bitstream read
            // forward (`§4.1.1`), and it covers at most the alphabet.
            const description = try fse.readDescription(
                source,
                spec.symbol_value_max,
                spec.accuracy_log_max,
            );
            state.tables[index] = fse.buildTable(
                description.counts[0..description.symbol_count],
                description.accuracy_log,
            );
            return description.bytes_consumed;
        },
        .repeat => {
            // "The table used in the previous Compressed_Block with
            // Number_Of_Sequences > 0 will be used again ... If this mode is
            // used without any previous sequence table in the frame ... to
            // repeat, this should be treated as corruption."
            if (state.tables[index] == null) return error.RepeatModeFirst;
            return 0;
        },
    }
}

/// Decode and execute every sequence of the section (`§3.1.1.3.2.1.2`'s
/// loop, `§3.1.1.4`'s copies), then append the trailing literals; returns
/// the block's output length. `bitstream` is the section's bytes after the
/// table descriptions.
fn executeSequences(
    bitstream: []const u8,
    sequence_count: u32,
    tables: *const [alphabet_count]*const fse.Table,
    repeat_offsets: *[3]u32,
    literals_bytes: []const u8,
    target: []u8,
    history_len: usize,
) Error!usize {
    // §3.1.1.3.2.1.2 — "The bitstream starts with initial FSE state values
    // ... It starts with Literals_Length_State, followed by Offset_State, and
    // finally Match_Length_State", each reading its table's Accuracy_Log bits
    // from the section's tail.
    var reader: bits.BackwardReader = try .init(bitstream);
    var states: [alphabet_count]fse.State = undefined;
    for (description_order) |alphabet| {
        states[@intFromEnum(alphabet)] = .init(&reader, tables[@intFromEnum(alphabet)]);
    }

    var produced: usize = 0;
    var literals_consumed: usize = 0;
    var sequence_index: u32 = 0;
    while (sequence_index < sequence_count) : (sequence_index += 1) {
        const codes = readCodes(&reader, tables, &states);
        // A read past the stream's start: the section promised more bits than
        // it holds, which is the exact-consumption rule read the other way.
        if (reader.overran()) return error.InvalidBitStream;
        const offset = try resolveOffset(codes.literals_length, codes.offset_value, repeat_offsets);
        const written = history_len + produced;
        assert(written <= target.len);
        produced += try executeSequence(
            codes.literals_length,
            codes.match_length,
            offset,
            literals_bytes,
            literals_consumed,
            target,
            written,
        );
        literals_consumed += codes.literals_length;
        // §3.1.1.3.2.1.2 — "If it is not the last sequence in the block, the
        // next operation is to update states ... Literals_Length_State is
        // updated, followed by Match_Length_State, and then Offset_State."
        if (sequence_index + 1 < sequence_count) {
            for (update_order) |alphabet| {
                const index = @intFromEnum(alphabet);
                states[index].update(&reader, tables[index]);
            }
        }
    }
    // "At the end, the bitstream shall be entirely consumed; otherwise, the
    // bitstream is considered corrupted."
    if (!reader.isConsumed()) return error.BitstreamNotConsumed;
    // §3.1.1.3.2 — "When all sequences are decoded, if there are literals
    // left in the Literals_Section, these bytes are added at the end of the
    // block."
    const written = history_len + produced;
    assert(written <= target.len);
    produced += try appendTrailingLiterals(literals_bytes, target, written, literals_consumed);
    return produced;
}

/// The three code values of one sequence (`§3.1.1.3.2.1.1`), with their
/// extra bits already added.
const Codes = struct {
    literals_length: u32,
    match_length: u32,
    offset_value: u32,
};

/// Read one sequence's codes and extra bits (`§3.1.1.3.2.1.2`): "Decoding
/// starts by reading the Number_of_Bits required to decode offset. It does
/// the same for Match_Length and then for Literals_Length."
fn readCodes(
    reader: *bits.BackwardReader,
    tables: *const [alphabet_count]*const fse.Table,
    states: *const [alphabet_count]fse.State,
) Codes {
    const offset = codeOf(.offsets, states, tables);
    const match = codeOf(.match_lengths, states, tables);
    const literal = codeOf(.literals_lengths, states, tables);
    return .{
        .offset_value = offset.baseline + readExtra(reader, offset.extra_bits),
        .match_length = match.baseline + readExtra(reader, match.extra_bits),
        .literals_length = literal.baseline + readExtra(reader, literal.extra_bits),
    };
}

/// The code one alphabet's state names, through its table
/// (`§4.1`: "The next symbol in the stream is the Symbol indicated in the
/// table for that state").
fn codeOf(
    alphabet: Alphabet,
    states: *const [alphabet_count]fse.State,
    tables: *const [alphabet_count]*const fse.Table,
) Code {
    const index = @intFromEnum(alphabet);
    const symbol = states[index].symbol(tables[index]);
    // Every table this layer builds spans its alphabet — the distributions
    // and the description reader are both bounded by symbol_value_max, and
    // RLE_Mode checks its byte — so the code table lookup cannot go past.
    assert(symbol <= specOf(alphabet).symbol_value_max);
    return specOf(alphabet).codes[symbol];
}

/// Read one code's extra bits (`§3.1.1.3.2.1.1`'s Number_of_Bits). The
/// backward reader takes at most 11 bits at a time, so a wider field — the
/// offset alphabet's codes go to 31 — is read in chunks, the first chunk
/// holding the value's high bits (the reader assembles most significant
/// first).
fn readExtra(reader: *bits.BackwardReader, count: u5) u32 {
    assert(count <= offset_code_max);
    if (count <= bits.max_read_bits) return reader.readBits(count);
    var value: u32 = reader.readBits(bits.max_read_bits);
    var remaining: u5 = count - bits.max_read_bits;
    while (remaining > bits.max_read_bits) {
        value = (value << bits.max_read_bits) | reader.readBits(bits.max_read_bits);
        remaining -= bits.max_read_bits;
    }
    return (value << remaining) | reader.readBits(remaining);
}

/// `§3.1.1.4` + `§3.1.1.5` — the offset a sequence's offset_value selects,
/// updating the repeat offsets.
///
/// An offset_value above 3 is a literal offset ("if Offset_Value > 3, then
/// the offset is Offset_Value - 3"), whatever its value: "When the sequence's
/// offset_value does not refer to one of the Repeated_Offsets ... the
/// Repeated_Offsets' values are shifted back one, and Repeated_Offset1 takes
/// on the value of the offset that was just used" — the equal-offsets rule.
/// Below 4 the repeat offsets are selected, with the literals_length == 0
/// shift.
fn resolveOffset(literals_length: u32, offset_value: u32, repeat_offsets: *[3]u32) Error!u32 {
    assert(offset_value >= 1);
    if (offset_value > 3) {
        const offset = offset_value - 3;
        shiftRepeatOffsets(repeat_offsets, offset);
        return offset;
    }
    // §3.1.1.5 — "when the current sequence's literals_length is 0, repeated
    // offsets are shifted by 1, so an offset_value of 1 means
    // Repeated_Offset2, an offset_value of 2 means Repeated_Offset3, and an
    // offset_value of 3 means Repeated_Offset1 - 1_byte."
    const selected = if (literals_length == 0) offset_value else offset_value - 1;
    if (selected == 3) {
        // The "Repeated_Offset1 - 1_byte" corner: a nonzero offset is not
        // guaranteed — Repeated_Offset1 == 1 gives 0, which no reference
        // decodes (T6, docs/research/zstd-notes.md §4).
        assert(repeat_offsets[0] >= 1);
        const offset = repeat_offsets[0] - 1;
        if (offset == 0) return error.ZeroOffset;
        shiftRepeatOffsets(repeat_offsets, offset);
        return offset;
    }
    return useRepeatOffset(repeat_offsets, selected);
}

/// `§3.1.1.5` — "the Repeated_Offsets' values are shifted back one, and
/// Repeated_Offset1 takes on the value of the offset that was just used."
fn shiftRepeatOffsets(repeat_offsets: *[3]u32, offset: u32) void {
    repeat_offsets[2] = repeat_offsets[1];
    repeat_offsets[1] = repeat_offsets[0];
    repeat_offsets[0] = offset;
}

/// `§3.1.1.5` — selecting a repeat offset reorders the three "so that
/// Repeated_Offset1 takes on the value of the used Repeated_Offset, and the
/// existing values are pushed back from the first Repeated_Offset through to
/// the Repeated_Offset selected": a swap for Repeated_Offset2, a rotation for
/// Repeated_Offset3, and no change for Repeated_Offset1.
fn useRepeatOffset(repeat_offsets: *[3]u32, selected: u32) u32 {
    assert(selected < 3);
    switch (selected) {
        0 => {},
        1 => {
            const used = repeat_offsets[1];
            repeat_offsets[1] = repeat_offsets[0];
            repeat_offsets[0] = used;
        },
        2 => {
            const used = repeat_offsets[2];
            repeat_offsets[2] = repeat_offsets[1];
            repeat_offsets[1] = repeat_offsets[0];
            repeat_offsets[0] = used;
        },
        else => unreachable,
    }
    return repeat_offsets[0];
}

/// Execute one sequence's copies (`§3.1.1.4`) and return the bytes written:
/// `literals_length` from the literals, then `match_length` from the history
/// at `offset`. `written` is the output position the sequence starts at, from
/// the caller's region's start.
fn executeSequence(
    literals_length: u32,
    match_length: u32,
    offset: u32,
    literals_bytes: []const u8,
    literals_consumed: usize,
    target: []u8,
    written: usize,
) Error!usize {
    assert(literals_consumed <= literals_bytes.len);
    assert(written <= target.len);
    // The amplification limits: neither copy may run past the literals
    // section's Regenerated_Size or the caller's target, and the checks come
    // before the writes.
    if (literals_length > literals_bytes.len - literals_consumed) return error.LiteralsTooLarge;
    const sequence_length = literals_length + match_length;
    if (sequence_length > target.len - written) return error.BufferTooSmall;
    fastmem.copy(
        u8,
        target[written..][0..literals_length],
        literals_bytes[literals_consumed..][0..literals_length],
    );
    // "The offset is defined as from the current position (after copying the
    // literals)", and "all offsets leading to previously decoded data must
    // be smaller than Window_Size" — the caller's history is that bound.
    const match_start = written + literals_length;
    if (offset > match_start) return error.OffsetTooFar;
    copyMatch(target, match_start, offset, match_length);
    return sequence_length;
}

/// `§3.1.1.4` — "match_length bytes are copied from previous decoded data.
/// The offset to copy from is determined by offset_value". An offset below
/// the match length replicates the offset-byte pattern, so the copy observes
/// its own writes; the caller has checked every bound.
fn copyMatch(target: []u8, match_start: usize, offset: u32, match_length: u32) void {
    assert(offset > 0);
    assert(offset <= match_start);
    assert(match_length >= 3);
    assert(match_start + match_length <= target.len);
    const distance: usize = offset;
    const length: usize = match_length;
    const source = match_start - distance;
    // The common case: the match lies entirely before the output position,
    // one vectorized copy.
    if (distance >= length) {
        fastmem.copy(u8, target[match_start..][0..length], target[source..][0..length]);
        return;
    }
    // Overlapping (distance < length): the match replicates the `distance`
    // bytes at the source, so the copy must see its own writes — a memmove
    // would copy the bytes that were there before. Doubling: copy the
    // pattern's first `distance` bytes (the source is final), then copy the
    // final prefix onto the space just past it, each step at most doubling
    // what is in place. Every copy's destination starts at or after its
    // source's end, so `fastmem.copy`'s non-overlap rule holds.
    const first = @min(distance, length);
    fastmem.copy(u8, target[match_start..][0..first], target[source..][0..first]);
    var copied: usize = first;
    while (copied < length) {
        const chunk = @min(copied, length - copied);
        fastmem.copy(
            u8,
            target[match_start + copied ..][0..chunk],
            target[match_start..][0..chunk],
        );
        copied += chunk;
    }
}

/// `§3.1.1.3.2` — "When all sequences are decoded, if there are literals left
/// in the Literals_Section, these bytes are added at the end of the block."
/// Returns the bytes appended; a target that cannot hold them fails
/// `BufferTooSmall` before any write.
fn appendTrailingLiterals(
    literals_bytes: []const u8,
    target: []u8,
    written: usize,
    literals_consumed: usize,
) Error!usize {
    assert(literals_consumed <= literals_bytes.len);
    assert(written <= target.len);
    const trailing = literals_bytes[literals_consumed..];
    if (trailing.len > target.len - written) return error.BufferTooSmall;
    fastmem.copy(u8, target[written..][0..trailing.len], trailing);
    return trailing.len;
}

/// Comptime hex decoding, so the fixtures keep the spelling the generator
/// printed (the flate/gzip/golden shape).
fn hex(comptime text: []const u8) [text.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    comptime assert(text.len % 2 == 0);
    var bytes: [text.len / 2]u8 = undefined;
    for (&bytes, 0..) |*byte, i| {
        byte.* = std.fmt.parseInt(u8, text[i * 2 ..][0..2], 16) catch unreachable;
    }
    return bytes;
}

/// The hand-built fixtures below are whole frames verified with the pinned
/// zstd CLI v1.5.7: each frame is a magic, a descriptor 0x00 (no
/// Frame_Content_Size, no checksum), a 512 KB window descriptor, then one or
/// more compressed blocks of raw literals and the sequences section in
/// question. `zstd -d` decodes every one of them to the bytes the tests
/// expect, so the fixtures are conformant frames rather than self-consistent
/// guesses (the literals slice's hand-built-section pattern, one layer up).
///
/// The corner fixture: RLE modes with LL symbol 5, ML symbol 0, OF symbol 3
/// (three extra bits, so offset_value 8-15), six sequences over 32 literals.
/// Offsets 5, 6, 7, 7 (the equal-offsets rule), 9, 12; two trailing
/// literals. Modes byte 0x54 = RLE|RLE|RLE.
const corner_literals: [34]u8 = hex(
    "0402202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d" ++
        "3e3f",
);
const corner_section: [8]u8 = hex("0654050300a71404");
const corner_expected: [50]u8 = hex(
    "202122232420212225262728292225262a2b2c2d2e25262a2f30313233262a2f" ++
        "343536373833262a393a3b3c3d3536373e3f",
);

/// The tempOffset fixture, three blocks: the first two sequences lay down a
/// 22-byte history (offsets 5 and 6, so the repeats end at {6, 5, 1}); the
/// second block's sequences all have literals_length 0 (LL symbol 0) and
/// offset_value 3 or 2, the two shifted repeat codes; the third block's all
/// have offset_value 1, the Repeated_Offset2 selection whose swap alternates
/// the offsets.
const temp_offset_0_literals: [17]u8 = hex("80202122232425262728292a2b2c2d2e2f");
const temp_offset_0_section: [6]u8 = hex("025405030041");
const temp_offset_0_expected: [22]u8 = hex("202122232420212225262728292225262a2b2c2d2e2f");
const temp_offset_1_literals: [9]u8 = hex("403031323334353637");
const temp_offset_1_section: [6]u8 = hex("04540001031a");
const temp_offset_1_expected: [32]u8 = hex(
    "2b2c2d2e2f2b2c2d2e2f2b2c2e2f2b2c2e2f2f2b2c2e2f2f3031323334353637",
);
const temp_offset_2_literals: [9]u8 = hex("4038393a3b3c3d3e3f");
const temp_offset_2_section: [6]u8 = hex("035400000001");
const temp_offset_2_expected: [17]u8 = hex("34353636373436363738393a3b3c3d3e3f");

/// The Repeat_Mode fixture: the second block's modes byte is 0xfc (all
/// three alphabets Repeat), so it carries no table bytes and reuses the
/// first block's three RLE tables — and, because the offset history carries
/// across blocks, its offsets continue the first block's.
const repeat_0_literals: [17]u8 = hex("80202122232425262728292a2b2c2d2e2f");
const repeat_0_section: [6]u8 = hex("025405030041");
const repeat_0_expected: [22]u8 = hex("202122232420212225262728292225262a2b2c2d2e2f");
const repeat_1_literals: [17]u8 = hex("80303132333435363738393a3b3c3d3e3f");
const repeat_1_section: [3]u8 = hex("02fc53");
const repeat_1_expected: [22]u8 = hex("30313233342e2f3035363738392e2f303a3b3c3d3e3f");

/// The two-byte Number_of_Sequences fixture: the second block's count is
/// 128, the first count that needs the 2-byte form (`80 80`), and its 128
/// sequences all have literals_length 0 with offset_value 1 — the shifted
/// Repeated_Offset2 selection, whose swap alternates offsets 5 and 6 as the
/// history's own bytes are consumed. The block's 384 bytes start with block
/// 1's tail (12 bytes) and settle into the six-byte cycle `----./` (62
/// times), then its 8 literals are trailing (the CLI's output, verbatim).
const two_byte_0_literals: [17]u8 = hex("80202122232425262728292a2b2c2d2e2f");
const two_byte_0_section: [6]u8 = hex("025405030041");
const two_byte_0_expected: [22]u8 = hex("202122232420212225262728292225262a2b2c2d2e2f");
const two_byte_1_literals: [9]u8 = hex("403031323334353637");
const two_byte_1_section: [7]u8 = hex("80805400000001");
const two_byte_1_expected: [392]u8 = hex(
    "2b2c2d2d2e2f2c2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
        "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d" ++
        "2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f" ++
        "2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
        "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d" ++
        "2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f" ++
        "2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
        "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d" ++
        "2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f" ++
        "2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
        "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d" ++
        "2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f" ++
        "3031323334353637",
);

/// The zero-count fixture: the 1-byte zero (the section stops after the
/// count) and the 2-byte `80 00` that decodes to zero — the corner the
/// reference accepts and std rejects (T5).
const zero_literals: [9]u8 = hex("402021222324252627");
const zero_section: [1]u8 = hex("00");
const zero_two_byte_section: [2]u8 = hex("8000");
const zero_expected: [8]u8 = hex("2021222324252627");

/// One fixture block: the two sections of a compressed block (`§3.1.1.3`).
const FixtureBlock = struct {
    literals_section: []const u8,
    sequences_section: []const u8,
};

/// Decode a fixture's blocks in order — composing the landed literals layer
/// with this one — threading both states and the history, and check each
/// block's output. The target is pre-filled with the sentinel and every byte
/// past the last block's output must be untouched (AGENTS.md, "Rules").
fn expectBlocks(blocks: []const FixtureBlock, expected: []const []const u8) !void {
    var target: [4096]u8 = undefined;
    internal.sentinel.fill(&target);
    var literals_scratch: [1024]u8 = undefined;
    var literals_state: literals.State = .{};
    var sequences_state: State = .{};
    var produced: usize = 0;
    for (blocks, expected) |block, want| {
        const literals_section = try literals.decode(
            block.literals_section,
            &literals_scratch,
            &literals_state,
        );
        const section = try decode(
            block.sequences_section,
            literals_section.bytes,
            &target,
            produced,
            &sequences_state,
        );
        // The section runs to the block's end: the bitstream is the tail and
        // "shall be entirely consumed" (`§3.1.1.3.2.1.2`).
        try testing.expectEqual(block.sequences_section.len, section.bytes_consumed);
        try testing.expectEqualSlices(u8, want, target[produced..][0..section.bytes_written]);
        produced += section.bytes_written;
    }
    try internal.sentinel.expect(&target, produced);
}

/// Decode one section and expect `err`, proving nothing was written into the
/// block's output region (`target[history_len..]`): the failure came before
/// the offending write.
fn expectError(
    err: Error,
    section: []const u8,
    literals_bytes: []const u8,
    history_len: usize,
) !void {
    var target: [512]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    try testing.expectError(err, decode(section, literals_bytes, &target, history_len, &state));
    try internal.sentinel.expect(&target, history_len);
}

test "parseHeader reads the three Number_of_Sequences forms" {
    // RFC 8878 §3.1.1.3.2.1 — "if (byte0 < 128): Number_of_Sequences =
    // byte0. Uses 1 byte"; "if (byte0 < 255): Number_of_Sequences =
    // ((byte0 - 128) << 8) + byte1. Uses 2 bytes"; "if (byte0 == 255):
    // Number_of_Sequences = byte1 + (byte2 << 8) + 0x7F00. Uses 3 bytes."
    const one = try parseHeader(&.{ 0x7f, 0x00 });
    try testing.expectEqual(@as(u32, 127), one.sequence_count);
    try testing.expectEqual(@as(usize, 1), one.count_len);
    const two = try parseHeader(&.{ 0x80, 0x80, 0x00 });
    try testing.expectEqual(@as(u32, 128), two.sequence_count);
    try testing.expectEqual(@as(usize, 2), two.count_len);
    const last_two = try parseHeader(&.{ 0xfe, 0xff, 0x00 });
    try testing.expectEqual(@as(u32, 32511), last_two.sequence_count);
    const three = try parseHeader(&.{ 0xff, 0x00, 0x00, 0x00 });
    try testing.expectEqual(@as(u32, 0x7f00), three.sequence_count);
    try testing.expectEqual(@as(usize, 3), three.count_len);
    const most = try parseHeader(&.{ 0xff, 0xff, 0xff, 0x00 });
    try testing.expectEqual(@as(u32, 0x7f00 + 0xffff), most.sequence_count);
}

test "parseHeader ends the section on a zero count, decoded or literal" {
    // RFC 8878 §3.1.1.3.2.1 — "if (byte0 == 0): there are no sequences. The
    // sequence section stops here." The reference ends it on the *decoded*
    // count too, so the 2-byte `80 00` is the same case (T5, docs/research/
    // zstd-notes.md §4); std rejects that corner, ours follows the
    // reference. No mode byte follows either form.
    const literal = try parseHeader(&.{0x00});
    try testing.expectEqual(@as(u32, 0), literal.sequence_count);
    try testing.expectEqual(@as(usize, 1), literal.count_len);
    try testing.expect(literal.modes == null);
    const decoded = try parseHeader(&.{ 0x80, 0x00 });
    try testing.expectEqual(@as(u32, 0), decoded.sequence_count);
    try testing.expectEqual(@as(usize, 2), decoded.count_len);
    try testing.expect(decoded.modes == null);
}

test "parseHeader maps the Symbol_Compression_Modes fields" {
    // RFC 8878 §3.1.1.3.2.1, Table 14 — "bits 7-6 Literal_Lengths_Mode,
    // 5-4 Offsets_Mode, 3-2 Match_Lengths_Mode, 1-0 Reserved"; Table 15's
    // enumeration is Predefined, RLE, FSE_Compressed, Repeat.
    const header = try parseHeader(&.{ 0x01, 0b10_01_11_00 });
    const modes = header.modes.?;
    try testing.expectEqual(Mode.fse, modes.literals_lengths);
    try testing.expectEqual(Mode.rle, modes.offsets);
    try testing.expectEqual(Mode.repeat, modes.match_lengths);
    const predefined = try parseHeader(&.{ 0x01, 0x00 });
    try testing.expectEqual(Mode.predefined, predefined.modes.?.literals_lengths);
    // "The last field, Reserved, must be all zeroes."
    try testing.expectError(error.ReservedModeBits, parseHeader(&.{ 0x01, 0x01 }));
    try testing.expectError(error.ReservedModeBits, parseHeader(&.{ 0x01, 0b11_11_11_11 }));
}

test "parseHeader fails closed on a short section" {
    // RFC 8878 §3.1.1.3.2.1 — the header's fields are fixed-size, so a
    // section that ends inside one is corruption, never a short read of the
    // input (the reference's `srcSize_wrong`).
    try testing.expectError(error.MalformedSequencesHeader, parseHeader(&.{}));
    try testing.expectError(error.MalformedSequencesHeader, parseHeader(&.{0x80}));
    try testing.expectError(error.MalformedSequencesHeader, parseHeader(&.{ 0xff, 0x00 }));
    // A nonzero count with no mode byte.
    try testing.expectError(error.MalformedSequencesHeader, parseHeader(&.{0x01}));
    try testing.expectError(error.MalformedSequencesHeader, parseHeader(&.{ 0x80, 0x80 }));
}

test "the code tables are Tables 16 and 17" {
    // RFC 8878 §3.1.1.3.2.1.1 — "Literals length codes are values ranging
    // from 0 to 35 ... They define lengths from 0 to 131071 bytes"; match
    // length codes 0-52 define 3 to 131074. Codes 0-15 (literals) and 0-31
    // (matches) carry the length itself, the bands above them the
    // baseline/extra-bits pairs.
    try testing.expectEqual(@as(u32, 0), literals_length_codes[0].baseline);
    try testing.expectEqual(@as(u32, 15), literals_length_codes[15].baseline);
    try testing.expectEqual(@as(u5, 0), literals_length_codes[15].extra_bits);
    try testing.expectEqual(@as(u32, 16), literals_length_codes[16].baseline);
    try testing.expectEqual(@as(u5, 1), literals_length_codes[16].extra_bits);
    try testing.expectEqual(@as(u32, 64), literals_length_codes[25].baseline);
    try testing.expectEqual(@as(u5, 6), literals_length_codes[25].extra_bits);
    // Code 35 tops out at 65536 + (1 << 16) - 1 = 131071.
    try testing.expectEqual(@as(u32, 65536), literals_length_codes[35].baseline);
    try testing.expectEqual(@as(u5, 16), literals_length_codes[35].extra_bits);
    const ll_top = literals_length_codes[35];
    try testing.expectEqual(
        @as(u32, 131071),
        ll_top.baseline + (@as(u32, 1) << ll_top.extra_bits) - 1,
    );
    try testing.expectEqual(@as(u32, 3), match_length_codes[0].baseline);
    try testing.expectEqual(@as(u32, 34), match_length_codes[31].baseline);
    try testing.expectEqual(@as(u5, 0), match_length_codes[31].extra_bits);
    try testing.expectEqual(@as(u32, 35), match_length_codes[32].baseline);
    try testing.expectEqual(@as(u5, 1), match_length_codes[32].extra_bits);
    try testing.expectEqual(@as(u32, 131), match_length_codes[43].baseline);
    try testing.expectEqual(@as(u5, 7), match_length_codes[43].extra_bits);
    try testing.expectEqual(@as(u32, 65539), match_length_codes[52].baseline);
    try testing.expectEqual(
        @as(u32, 131074),
        match_length_codes[52].baseline + (@as(u32, 1) << match_length_codes[52].extra_bits) - 1,
    );
    // "Offset_Value = (1 << offsetCode) + readNBits(offsetCode)": the
    // baseline is the shift, the extra bits are the code.
    try testing.expectEqual(@as(u32, 1), offset_codes[0].baseline);
    try testing.expectEqual(@as(u5, 0), offset_codes[0].extra_bits);
    try testing.expectEqual(@as(u32, 8), offset_codes[3].baseline);
    try testing.expectEqual(@as(u5, 3), offset_codes[3].extra_bits);
    try testing.expectEqual(@as(u32, 1 << 31), offset_codes[31].baseline);
    try testing.expectEqual(@as(u5, 31), offset_codes[31].extra_bits);
    try testing.expectEqual(
        offset_value_max,
        offset_codes[31].baseline + ((@as(u32, 1) << 31) - 1),
    );
}

test "the predefined tables use §3.1.1.3.2.2's accuracy logs" {
    // RFC 8878 §3.1.1.3.2.2 — the literals length and match length default
    // distributions "use an accuracy log of 6 bits (64 states)", the offset
    // codes' 5 bits (32 states). Appendix A's rows pin the tables themselves
    // (fse.zig's cross-check builds them from these distributions).
    const ll_table = predefined_tables[@intFromEnum(Alphabet.literals_lengths)];
    const ml_table = predefined_tables[@intFromEnum(Alphabet.match_lengths)];
    const offset_table = predefined_tables[@intFromEnum(Alphabet.offsets)];
    try testing.expectEqual(@as(u5, 6), ll_table.log);
    try testing.expectEqual(@as(u5, 5), offset_table.log);
    try testing.expectEqual(@as(u5, 6), ml_table.log);
    // The offset table's last cell is one of the distribution's "less than
    // 1" symbols (Appendix A.3's state 31 is symbol 24) — the retreat from
    // the end of the table.
    try testing.expectEqual(@as(u8, 24), offset_table.entry(31).symbol);
}

test "resolveTable stores every mode's table for Repeat_Mode" {
    // RFC 8878 §3.1.1.3.2.1 — Repeat reuses "the table used in the previous
    // Compressed_Block with Number_Of_Sequences > 0 ... Note that this
    // includes RLE_Mode ... It also includes Predefined_Mode, in which case
    // Repeat_Mode will have the same outcome as Predefined_Mode", so every
    // mode's resolved table lands in the frame state — and Repeat with
    // nothing to repeat is corruption. RLE_Mode's symbol byte is bounded by
    // the context's alphabet (the reference's `symbol > max` check).
    var state: State = .{};
    try testing.expectError(error.RepeatModeFirst, resolveTable(.offsets, &.{}, .repeat, &state));
    try testing.expectEqual(@as(usize, 0), try resolveTable(.offsets, &.{}, .predefined, &state));
    try testing.expectEqual(@as(usize, 0), try resolveTable(.offsets, &.{}, .repeat, &state));
    try testing.expectEqual(
        predefined_tables[@intFromEnum(Alphabet.offsets)].log,
        state.tables[@intFromEnum(Alphabet.offsets)].?.log,
    );
    try testing.expectEqual(@as(usize, 1), try resolveTable(.offsets, &.{7}, .rle, &state));
    const rle = state.tables[@intFromEnum(Alphabet.offsets)].?;
    try testing.expectEqual(@as(u8, 7), rle.entry(0).symbol);
    try testing.expectEqual(@as(u5, 0), rle.entry(0).num_bits);
    // One past each alphabet's last code (31, 35, 52).
    try testing.expectError(
        error.MalformedFseTable,
        resolveTable(.offsets, &.{32}, .rle, &state),
    );
    try testing.expectError(
        error.MalformedFseTable,
        resolveTable(.literals_lengths, &.{36}, .rle, &state),
    );
    try testing.expectError(
        error.MalformedFseTable,
        resolveTable(.match_lengths, &.{53}, .rle, &state),
    );
    // And a symbol byte the section does not hold.
    try testing.expectError(
        error.MalformedSequencesHeader,
        resolveTable(.offsets, &.{}, .rle, &state),
    );
}

test "readExtra reads fields wider than the reader's 11-bit chunk" {
    // RFC 8878 §3.1.1.3.2.1.1 — an offset code's Number_of_Bits is the code
    // itself, so a table's symbol 31 asks for 31 bits; the backward reader
    // takes 11 at a time, and the first chunk read is the value's high bits.
    // The stream is 0x12 0x34 0x56 0x78 0x01: its last byte's highest set
    // bit is bit 0, so the 32 bits below it are useful, read from bit 31
    // down.
    var reader = try bits.BackwardReader.init(&.{ 0x12, 0x34, 0x56, 0x78, 0x01 });
    try testing.expectEqual(@as(u32, 0x3c2b1a09), readExtra(&reader, 31));
    try testing.expectEqual(@as(i32, 1), reader.remainingBits());
    var split = try bits.BackwardReader.init(&.{ 0x12, 0x34, 0x56, 0x78, 0x01 });
    try testing.expectEqual(@as(u32, 0x7856), readExtra(&split, 16));
    try testing.expectEqual(@as(u32, 0x3412), readExtra(&split, 16));
    try testing.expect(split.isConsumed());
    // A read of exactly the chunk width stays on the direct path.
    var direct = try bits.BackwardReader.init(&.{ 0x34, 0x78, 0x01 });
    try testing.expectEqual(@as(u32, 0x7834 >> 5), readExtra(&direct, 11));
}

test "resolveOffset follows §3.1.1.5's rules, never Table 18's cells" {
    // RFC 8878 §3.1.1.5 — the rules are the source: Table 18's worked
    // example carries errata 6442 (its second-to-last row's offset_value is
    // 3, not 1) and its last row's Repeated_Offset3 cell contradicts the
    // rotation rule (docs/research/zstd-notes.md §4 T3). Every expectation
    // below is derived from the rule text and the reference decoder's
    // `ZSTD_decodeSequence`, not from the table's cells.
    //
    // The starting values are "Repeated_Offset1 (1), Repeated_Offset2 (4),
    // and Repeated_Offset3 (8)".
    var offsets: [3]u32 = repeat_offsets_start;
    // "When the sequence's offset_value does not refer to one of the
    // Repeated_Offsets ... the Repeated_Offsets' values are shifted back
    // one, and Repeated_Offset1 takes on the value of the offset that was
    // just used."
    try testing.expectEqual(@as(u32, 1111), try resolveOffset(11, 1114, &offsets));
    try testing.expectEqualSlices(u32, &.{ 1111, 1, 4 }, &offsets);
    // "when the sequence's offset_value refers to one of the Repeated_Offsets
    // ... the Repeated_Offsets are reordered, so that Repeated_Offset1 takes
    // on the value of the used Repeated_Offset": offset_value 1 is
    // Repeated_Offset1 itself, so nothing moves.
    try testing.expectEqual(@as(u32, 1111), try resolveOffset(22, 1, &offsets));
    try testing.expectEqualSlices(u32, &.{ 1111, 1, 4 }, &offsets);
    try testing.expectEqual(@as(u32, 2222), try resolveOffset(22, 2225, &offsets));
    try testing.expectEqualSlices(u32, &.{ 2222, 1111, 1 }, &offsets);
    // The equal-offsets rule: offset_value 1114 resolves to 1111, which is
    // Repeated_Offset1 — still a shift, because the offset_value is above 3.
    try testing.expectEqual(@as(u32, 1111), try resolveOffset(111, 1114, &offsets));
    try testing.expectEqualSlices(u32, &.{ 1111, 2222, 1111 }, &offsets);
    try testing.expectEqual(@as(u32, 3333), try resolveOffset(33, 3336, &offsets));
    try testing.expectEqualSlices(u32, &.{ 3333, 1111, 2222 }, &offsets);
    // offset_value 2 with a nonzero literals length selects
    // Repeated_Offset2: "the existing values are pushed back from the first
    // Repeated_Offset through to the Repeated_Offset selected" — a swap.
    try testing.expectEqual(@as(u32, 1111), try resolveOffset(22, 2, &offsets));
    try testing.expectEqualSlices(u32, &.{ 1111, 3333, 2222 }, &offsets);
    // offset_value 3 selects Repeated_Offset3: the "single-stepped wrapping
    // rotation", Repeated_Offset3 to the front.
    try testing.expectEqual(@as(u32, 2222), try resolveOffset(33, 3, &offsets));
    try testing.expectEqualSlices(u32, &.{ 2222, 1111, 3333 }, &offsets);
    // "when the current sequence's literals_length is 0, repeated offsets
    // are shifted by 1, so an offset_value of 3 means Repeated_Offset1 -
    // 1_byte": the resolved offset is inserted at the front.
    try testing.expectEqual(@as(u32, 2221), try resolveOffset(0, 3, &offsets));
    try testing.expectEqualSlices(u32, &.{ 2221, 2222, 1111 }, &offsets);
    // And offset_value 1 with literals_length 0 means Repeated_Offset2,
    // which leaves Repeated_Offset3 alone (the table's last row says 3333).
    try testing.expectEqual(@as(u32, 2222), try resolveOffset(0, 1, &offsets));
    try testing.expectEqualSlices(u32, &.{ 2222, 2221, 1111 }, &offsets);
    // offset_value 2 with literals_length 0 means Repeated_Offset3.
    try testing.expectEqual(@as(u32, 1111), try resolveOffset(0, 2, &offsets));
    try testing.expectEqualSlices(u32, &.{ 1111, 2222, 2221 }, &offsets);
}

test "resolveOffset refuses the offset-0 corner" {
    // RFC 8878 §3.1.1.5 — "an offset_value of 3 means Repeated_Offset1 -
    // 1_byte"; with the seeded Repeated_Offset1 == 1 that is offset 0, which
    // no reference decodes (T6, docs/research/zstd-notes.md §4: the C and
    // std reject it, klauspost substitutes offset 1).
    var offsets: [3]u32 = repeat_offsets_start;
    try testing.expectError(error.ZeroOffset, resolveOffset(0, 3, &offsets));
    // The refusal leaves the repeats untouched; once Repeated_Offset1 is
    // above 1 the same code is legal.
    try testing.expectEqualSlices(u32, &repeat_offsets_start, &offsets);
    offsets = .{ 5, 4, 8 };
    try testing.expectEqual(@as(u32, 4), try resolveOffset(0, 3, &offsets));
    try testing.expectEqualSlices(u32, &.{ 4, 5, 4 }, &offsets);
}

test "copyMatch replicates an overlapping match" {
    // RFC 8878 §3.1.1.4 — "an offset of 6 and a match length of 3 means that
    // 3 bytes should be copied from 6 bytes back"; an offset below the match
    // length replicates the pattern, and the copy must observe its own
    // writes (a memmove's would not).
    var target: [32]u8 = undefined;
    fastmem.set(u8, &target, 0);
    // A two-byte pattern at offset 2, matched for 7 bytes: the copy must see
    // its own writes, so the pattern repeats.
    fastmem.copy(u8, target[0..2], "AB");
    copyMatch(&target, 2, 2, 7);
    try testing.expectEqualSlices(u8, "ABABABA", target[2..9]);
    // An offset of 1 replicates a single byte.
    fastmem.copy(u8, target[9..12], "xyz");
    copyMatch(&target, 12, 1, 8);
    try testing.expectEqualSlices(u8, "zzzzzzzz", target[12..20]);
    // An offset at least the match's length is a plain copy.
    fastmem.copy(u8, target[20..24], "abcd");
    copyMatch(&target, 24, 4, 4);
    try testing.expectEqualSlices(u8, "abcd", target[24..28]);
}

test "decode reads a real frame's Predefined-mode sequences section" {
    // RFC 8878 §3.1.1.3.2.2 — all three alphabets in Predefined_Mode: the
    // tables come from the default distributions and no table bytes are
    // present. golden.zig's fixture is the first compressed block of a real
    // `zstd -5` frame, so the CLI's own output is the expectation.
    const blocks = [_]FixtureBlock{.{
        .literals_section = &golden.sequences_predefined_literals,
        .sequences_section = &golden.sequences_predefined_section,
    }};
    try expectBlocks(&blocks, &.{&golden.sequences_predefined_expected});
}

test "decode reads a real frame's RLE-mode match lengths" {
    // RFC 8878 §3.1.1.3.2.1 — "RLE_Mode: The table description consists of
    // a single byte, which contains the symbol's value. This symbol will be
    // used for all sequences": the match length code is fixed, so every
    // match length comes from that one code's baseline and extra bits.
    const blocks = [_]FixtureBlock{.{
        .literals_section = &golden.sequences_rle_match_lengths_literals,
        .sequences_section = &golden.sequences_rle_match_lengths_section,
    }};
    try expectBlocks(&blocks, &.{&golden.sequences_rle_match_lengths_expected});
}

test "decode reads a real frame's FSE-compressed offset table" {
    // RFC 8878 §3.1.1.3.2.1 — FSE_Compressed_Mode for one alphabet beside
    // Predefined for the others: one distribution table is present, and its
    // description is the §4.1.1 reader's.
    const blocks = [_]FixtureBlock{.{
        .literals_section = &golden.sequences_fse_offsets_literals,
        .sequences_section = &golden.sequences_fse_offsets_section,
    }};
    try expectBlocks(&blocks, &.{&golden.sequences_fse_offsets_expected});
}

test "decode reads a real frame's all-FSE sequences section" {
    // RFC 8878 §3.1.1.3.2.1 + §3.1.1.3.2.1.2 — three distribution tables
    // then the interleaved bitstream: 19 sequences of literals-length,
    // offset, and match-length codes with their extra bits.
    const blocks = [_]FixtureBlock{.{
        .literals_section = &golden.sequences_fse_all_literals,
        .sequences_section = &golden.sequences_fse_all_section,
    }};
    try expectBlocks(&blocks, &.{&golden.sequences_fse_all_expected});
}

test "decode executes the corner fixture: offsets, rotation, trailing literals" {
    // RFC 8878 §3.1.1.4 + §3.1.1.5 — six RLE-mode sequences over 32
    // literals: offsets 5, 6, 7, then 7 again (an offset_value above 3 that
    // equals Repeated_Offset1, the equal-offsets rule), 9, and 12, with two
    // literals left over that "are added at the end of the block".
    const blocks = [_]FixtureBlock{.{
        .literals_section = &corner_literals,
        .sequences_section = &corner_section,
    }};
    try expectBlocks(&blocks, &.{&corner_expected});
}

test "decode threads the repeat offsets and the history across blocks" {
    // RFC 8878 §3.1.1.5 — "each block gets its starting offset history from
    // the ending values of the most recent Compressed_Block": block 2's
    // literals_length is 0 for every sequence (the shifted selection), and
    // its offsets reach into block 1's output; block 3's offset_value 1
    // sequences walk the Repeated_Offset2 swap.
    const blocks = [_]FixtureBlock{
        .{
            .literals_section = &temp_offset_0_literals,
            .sequences_section = &temp_offset_0_section,
        },
        .{
            .literals_section = &temp_offset_1_literals,
            .sequences_section = &temp_offset_1_section,
        },
        .{
            .literals_section = &temp_offset_2_literals,
            .sequences_section = &temp_offset_2_section,
        },
    };
    try expectBlocks(&blocks, &.{
        &temp_offset_0_expected,
        &temp_offset_1_expected,
        &temp_offset_2_expected,
    });
}

test "decode reuses the previous tables in Repeat mode" {
    // RFC 8878 §3.1.1.3.2.1 — "The table used in the previous
    // Compressed_Block with Number_Of_Sequences > 0 will be used again ...
    // Note that this includes RLE_Mode, so if Repeat_Mode follows RLE_Mode,
    // the same symbol will be repeated." Block 2's modes byte is 0xfc (all
    // three Repeat) and carries no table bytes.
    const blocks = [_]FixtureBlock{
        .{
            .literals_section = &repeat_0_literals,
            .sequences_section = &repeat_0_section,
        },
        .{
            .literals_section = &repeat_1_literals,
            .sequences_section = &repeat_1_section,
        },
    };
    try expectBlocks(&blocks, &.{ &repeat_0_expected, &repeat_1_expected });
}

test "decode reads the 2-byte Number_of_Sequences form over 128 sequences" {
    // RFC 8878 §3.1.1.3.2.1 — `80 80` is 128, the first count that needs
    // the 2-byte form, and each of the 128 sequences copies three bytes at
    // the alternating repeat offsets.
    const blocks = [_]FixtureBlock{
        .{
            .literals_section = &two_byte_0_literals,
            .sequences_section = &two_byte_0_section,
        },
        .{
            .literals_section = &two_byte_1_literals,
            .sequences_section = &two_byte_1_section,
        },
    };
    try expectBlocks(&blocks, &.{ &two_byte_0_expected, &two_byte_1_expected });
}

test "decode ends a zero-count section on the literals" {
    // RFC 8878 §3.1.1.3.2.1 — "there are no sequences. The sequence section
    // stops here. Decompressed content is defined entirely as
    // Literals_Section content." Both the 1-byte zero and the 2-byte
    // decoded-zero form (T5) end the same way, and neither updates the
    // frame's tables.
    const blocks = [_]FixtureBlock{
        .{ .literals_section = &zero_literals, .sequences_section = &zero_section },
        .{
            .literals_section = &zero_literals,
            .sequences_section = &zero_two_byte_section,
        },
    };
    try expectBlocks(&blocks, &.{ &zero_expected, &zero_expected });
    var state: State = .{};
    var target: [64]u8 = undefined;
    internal.sentinel.fill(&target);
    const section = try decode(&zero_section, &zero_expected, &target, 0, &state);
    try testing.expectEqual(zero_expected.len, section.bytes_written);
    try testing.expectEqual(@as(usize, 1), section.bytes_consumed);
    try testing.expect(state.tables[0] == null);
    try testing.expectEqualSlices(u32, &repeat_offsets_start, &state.repeat_offsets);
    try internal.sentinel.expect(&target, section.bytes_written);
}

test "decode rejects the mode corners" {
    // RFC 8878 §3.1.1.3.2.1 — the Reserved field "must be all zeroes", and
    // Repeat "used without any previous sequence table in the frame ... to
    // repeat ... should be treated as corruption". The RLE symbol byte is
    // outside the alphabet when it exceeds the context's last code.
    try expectError(error.ReservedModeBits, &.{ 0x01, 0x55, 0x00, 0x01 }, &.{}, 0);
    try expectError(error.RepeatModeFirst, &.{ 0x01, 0xfc, 0x01 }, &.{}, 0);
    try expectError(error.MalformedFseTable, &.{ 0x01, 0x54, 0x00, 0x20, 0x00, 0x01 }, &.{}, 0);
    // An RLE symbol byte the section does not hold.
    try expectError(error.MalformedSequencesHeader, &.{ 0x01, 0x54, 0x00 }, &.{}, 0);
    // A truncated FSE description: the modes byte puts the literals length
    // table in FSE_Compressed_Mode and the section ends before its
    // description does (`§4.1.1`).
    try expectError(error.MalformedFseTable, &.{ 0x01, 0xa4, 0x10 }, &.{}, 0);
}

test "decode fails closed on the sequence bounds" {
    // RFC 8878 §3.1.1.4 + §8 — a match that would reach before the
    // authorized history is `OffsetTooFar`, a match that would write past
    // the target is `BufferTooSmall`, and a literals_length past the
    // section's Regenerated_Size is `LiteralsTooLarge`; each fails before
    // the write it refuses.
    // OF symbol 3 with extra bits 7: offset_value 15, offset 12.
    const far = [_]u8{ 0x01, 0x54, 0x00, 0x03, 0x00, 0x0f };
    try expectError(error.OffsetTooFar, &far, &.{}, 0);
    // The same sequence with a 12-byte history is legal; with only 11 the
    // caller's cap (the frame's Window_Size) still refuses it.
    var target: [64]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    const section = try decode(&far, &.{}, &target, 12, &state);
    try testing.expectEqual(@as(usize, 3), section.bytes_written);
    try internal.sentinel.expect(&target, 15);
    try testing.expectError(error.OffsetTooFar, decode(&far, &.{}, &target, 11, &state));
    // literals_length 5 (LL symbol 5) with a 4-byte literals section.
    const five = [_]u8{ 0x01, 0x54, 0x05, 0x00, 0x00, 0x01 };
    try expectError(error.LiteralsTooLarge, &five, &.{ 1, 2, 3, 4 }, 0);
    // The same section with a target of 7 bytes: 5 literals + a 3-byte
    // match needs 8, and the check comes before the write.
    var small: [7]u8 = undefined;
    internal.sentinel.fill(&small);
    var small_state: State = .{};
    try testing.expectError(
        error.BufferTooSmall,
        decode(&.{ 0x01, 0x54, 0x05, 0x00, 0x00, 0x01 }, "abcde", &small, 0, &small_state),
    );
    try internal.sentinel.expect(&small, 0);
}

test "a Number_of_Sequences past the block cannot amplify" {
    // RFC 8878 §8 — the named vector is "the encoding of Number_of_Sequences
    // values that cause the decoder to read into the block header (and
    // beyond)". The count here is the 3-byte form's maximum (98047) over an
    // 8-byte section, and every sequence's match writes at least 3 bytes, so
    // the loop is bounded by the target: 21 sequences fill the 63 bytes
    // available and the 22nd fails closed. The sentinel proves the last byte
    // was not written.
    const section = [_]u8{ 0xff, 0xff, 0xff, 0x54, 0x00, 0x00, 0x00, 0x01 };
    var target: [72]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    try testing.expectError(error.BufferTooSmall, decode(&section, &.{}, &target, 8, &state));
    try internal.sentinel.expect(&target, 71);
}

test "decode fails closed on the bitstream's ends" {
    // RFC 8878 §3.1.1.3.2.1.2 — "the last byte of the compressed bitstream
    // cannot be zero", the stream must hold every bit the codes ask for, and
    // "at the end, the bitstream shall be entirely consumed".
    // A zero last byte has no start bit (`§4.2.2`).
    try expectError(error.MissingStartBit, &.{ 0x01, 0x54, 0x05, 0x00, 0x00, 0x00 }, "abcde", 0);
    // No bitstream at all.
    try expectError(error.MissingStartBit, &.{ 0x01, 0x54, 0x05, 0x00, 0x00 }, "abcde", 0);
    // One sequence whose match needs 3 extra bits over a 1-bit stream: the
    // reads run past the stream's start (`InvalidBitStream`).
    try expectError(error.InvalidBitStream, &.{ 0x01, 0x54, 0x05, 0x03, 0x00, 0x01 }, "abcde", 0);
    // A bit left over at the end: the section must consume the stream
    // whole. The sequence itself executed (5 literals and a 3-byte match at
    // the seeded Repeated_Offset1), so its output stands and only the
    // section end is refused.
    var target: [64]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    try testing.expectError(
        error.BitstreamNotConsumed,
        decode(&.{ 0x01, 0x54, 0x05, 0x00, 0x00, 0x02 }, "abcde", &target, 0, &state),
    );
    // offset_value 1 with a nonzero literals length is the seeded
    // Repeated_Offset1, so the match replicates the last literal.
    try testing.expectEqualSlices(u8, "abcdeeee", target[0..8]);
    try internal.sentinel.expect(&target, 8);
}

test "a zero-count section with bytes past the count is corruption" {
    // RFC 8878 §3.1.1.3.2.1 — "the sequence section stops here", and the
    // reference reads that as "extraneous data present in the Sequences
    // section" (its `zeroSeq_extraneous.zst` fixture is the sibling pin).
    try expectError(error.BitstreamNotConsumed, &.{ 0x00, 0x00 }, &.{}, 0);
    try expectError(error.BitstreamNotConsumed, &.{ 0x80, 0x00, 0x00 }, &.{}, 0);
}
