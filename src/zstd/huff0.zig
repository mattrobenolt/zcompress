//! Huffman (huff0) for the zstd decoder: the weight series a literals block
//! transmits (`§4.2.1`), the prefix codes it describes (`§4.2.1.3`), and the
//! backwards Huffman-coded streams (`§4.2.2`).
//!
//! The tree arrives as weights, never as code lengths: `Number_of_Bits =
//! Max_Number_of_Bits + 1 - Weight` for a nonzero Weight, and the last
//! symbol's weight is implied — "The last symbol's Weight is deduced from
//! previously decoded ones, by completing to the nearest power of 2"
//! (`§4.2.1`). Two descriptions carry it (`§4.2.1.1`): the direct mode, two
//! 4-bit weights per byte, and the FSE-compressed mode, whose series is
//! `§4.2.1.2`'s one bitstream with two interleaved states terminated by the
//! overflow rule ("if updating state after decoding a symbol would require
//! more bits than remain in the stream, it is assumed that extra bits are
//! zero. Then, symbols for each of the final states are decoded and the
//! process is complete").
//!
//! The prefix codes are assigned by `§4.2.1.3`: symbols sorted by weight,
//! natural order within a weight, weight-0 symbols dropped, and "starting
//! from the lowest Weight, prefix codes are distributed in sequential
//! order". The decode table holds each code left-justified at the top of the
//! stream's next `Max_Number_of_Bits` bits, so a symbol decode is one lookup
//! and one skip. The RFC's own `§4.2.2` example contradicts the assignment
//! (errata 8195, `docs/research/zstd-notes.md` §4 T1); Table 25 and the
//! algorithm text win, and `golden.t1_stream` pins the difference.
//!
//! The stream decode is the literals layer's building block, not its
//! driver: `§3.1.1.3.1.6`'s 1-or-4-stream walk, the jump table, and the
//! per-stream sizes are the literals section's, and it calls `decodeStream`
//! once per stream with the slice and count it computed.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const internal = @import("../internal/root.zig");
const bits = @import("bits.zig");
const fse = @import("fse.zig");
const golden = @import("golden.zig");

/// Everything the Huffman layer reports.
pub const Error = error{
    /// The weight series and its completion (`§4.2.1`, `§4.2.1.1`,
    /// `§4.2.1.2`) — the FSE-compressed series' own table description
    /// included, which is part of the series rather than a table of its own.
    MalformedHuffmanWeights,
    /// A stream whose last byte is zero, so it carries no final 1 bit
    /// (`§4.2.2`).
    MissingStartBit,
    /// A stream that ran out of bits before its symbols did (`§4.2.2`).
    InvalidBitStream,
    /// Bits left over once the stream's symbols were decoded (`§4.2.2`: "If
    /// a bitstream is not entirely and exactly consumed ... the decoding
    /// process is considered faulty").
    BitstreamNotConsumed,
};

/// `§4.2.1` — "This specification limits the maximum code length to 11
/// bits."
pub const code_length_max: u5 = 11;

/// The literals alphabet: symbols 0-255.
pub const symbol_count_max = 256;

/// The most weights a series can list: the last symbol's weight is implied,
/// so 255 are transmitted (`§4.2.1.2`).
pub const weight_count_max = symbol_count_max - 1;

/// A Huffman_Tree_Description (`§4.2.1.1`).
pub const Tree = struct {
    /// One weight per symbol, in symbol order; only the first
    /// `symbol_count` are meaningful.
    weights: [symbol_count_max]u8,
    /// The number of symbols the tree covers, the implied last weight
    /// included.
    symbol_count: u16,
    /// Max_Number_of_Bits: the tree's depth, from the completion.
    max_bits: u5,
    /// The bytes the description consumed — the literals header's
    /// Compressed_Size includes the tree description (`§3.1.1.3.1.1`).
    bytes_consumed: usize,
};

/// Read a Huffman_Tree_Description (`§4.2.1.1`, `§4.2.1.2`) from the bytes
/// after the literals header.
pub fn readTree(source: []const u8) Error!Tree {
    if (source.len == 0) return error.MalformedHuffmanWeights;
    var tree: Tree = .{
        .weights = undefined,
        .symbol_count = 0,
        .max_bits = 0,
        .bytes_consumed = 0,
    };
    const header = source[0];
    if (header >= 128) {
        // §4.2.1.1 — the direct representation: "each Weight is written
        // directly as a 4-bit field ... with the first weight taking the top
        // 4 bits and the second taking the bottom 4", and "The full
        // representation occupies ceiling(Number_of_Symbols/2) bytes".
        const symbol_count: u16 = header - 127;
        const byte_count = (@as(usize, symbol_count) + 1) / 2;
        if (1 + byte_count > source.len) return error.MalformedHuffmanWeights;
        for (0..symbol_count) |symbol| {
            const byte = source[1 + symbol / 2];
            tree.weights[symbol] = if (symbol % 2 == 0) byte >> 4 else byte & 0xf;
        }
        tree.symbol_count = symbol_count;
        tree.bytes_consumed = 1 + byte_count;
    } else {
        // §4.2.1.2 — "the series of weights is compressed using FSE ... The
        // length of the FSE-compressed series is equal to headerByte".
        const series_len: usize = header;
        if (1 + series_len > source.len) return error.MalformedHuffmanWeights;
        const series = source[1 .. 1 + series_len];
        // The weights context's caps: a maximum accuracy log of 6 bits
        // (§4.2.1.2) over the whole 0-255 weight alphabet.
        const description = fse.readDescription(series, 255, 6) catch
            return error.MalformedHuffmanWeights;
        const counts = description.counts[0..description.symbol_count];
        const table = fse.buildTable(counts, description.accuracy_log);
        const stream = series[description.bytes_consumed..];
        var reader = bits.BackwardReader.init(stream) catch
            return error.MalformedHuffmanWeights;
        const count = try decodeWeights(&reader, &table, tree.weights[0..weight_count_max]);
        tree.symbol_count = @intCast(count);
        tree.bytes_consumed = 1 + series_len;
    }
    try complete(&tree);
    return tree;
}

/// Decode a weight series (`§4.2.1.2`): one bitstream, two interleaved
/// states sharing one distribution, terminated by the overflow rule.
///
/// "The first state (State1) encodes the even-numbered index symbols, and
/// the second (State2) encodes the odd-numbered index symbols. State1 is
/// initialized first ... and they take turns decoding a single symbol and
/// updating their state." Returns the number of weights decoded.
///
/// `target` bounds the series — 255 weights, the alphabet's last symbol
/// being implied — and a series that wants more is corruption. The
/// reference's own destination check is one slot more conservative (it
/// refuses to fill its last two cells, because its tail decodes in pairs);
/// the cap here is the format's.
fn decodeWeights(
    reader: *bits.BackwardReader,
    table: *const fse.Table,
    target: []u8,
) Error!usize {
    var state1: fse.State = .init(reader, table);
    var state2: fse.State = .init(reader, table);
    // The reference's post-init check: a stream too short to hold even the
    // two initial states is corruption, not an empty series.
    if (reader.overran()) return error.MalformedHuffmanWeights;

    var count: usize = 0;
    while (true) {
        // The overflow rule: a symbol is emitted, its state updates (reading
        // zeros past the stream's start), and once that update has overrun,
        // the other state's symbol completes the series.
        if (count == target.len) return error.MalformedHuffmanWeights;
        target[count] = state1.symbol(table);
        count += 1;
        state1.update(reader, table);
        if (reader.overran()) {
            if (count == target.len) return error.MalformedHuffmanWeights;
            target[count] = state2.symbol(table);
            count += 1;
            break;
        }
        if (count == target.len) return error.MalformedHuffmanWeights;
        target[count] = state2.symbol(table);
        count += 1;
        state2.update(reader, table);
        if (reader.overran()) {
            if (count == target.len) return error.MalformedHuffmanWeights;
            target[count] = state1.symbol(table);
            count += 1;
            break;
        }
    }
    return count;
}

/// The completion (`§4.2.1`): the transmitted weights must complete to a
/// power of two, which fixes `Max_Number_of_Bits` and the implied last
/// weight, and the result must be a tree a decoder can walk.
fn complete(tree: *Tree) Error!void {
    if (tree.symbol_count == 0) return error.MalformedHuffmanWeights;
    var total: u32 = 0;
    for (tree.weights[0..tree.symbol_count]) |weight| {
        // A weight over the code-length cap cannot come from a valid tree,
        // and the shift below would not fit the sum either.
        if (weight > code_length_max) return error.MalformedHuffmanWeights;
        total += (@as(u32, 1) << @intCast(weight)) >> 1;
    }
    if (total == 0) return error.MalformedHuffmanWeights;

    // "The sum of 2^((Weight-1)) (excluding 0's) is 15. The nearest power of
    // 2 is 16. Therefore, Max_Number_of_Bits = 4 and Weight[5] = 16 - 15 =
    // 1." The remainder must be a clean power of two: it is the implied
    // weight's share, and a weight is 2^(Weight-1) of the total.
    const max_bits: u5 = @intCast(highBit(total) + 1);
    if (max_bits > code_length_max) return error.MalformedHuffmanWeights;
    const rest = (@as(u32, 1) << max_bits) - total;
    if (rest == 0) return error.MalformedHuffmanWeights;
    if ((@as(u32, 1) << highBit(rest)) != rest) return error.MalformedHuffmanWeights;
    const last_weight: u8 = highBit(rest) + 1;

    tree.weights[tree.symbol_count] = last_weight;
    tree.symbol_count += 1;
    tree.max_bits = max_bits;

    // The tree must be walkable, which the completion alone does not
    // guarantee: the deepest level's leaves come in pairs, and there must be
    // at least one pair — three 1-bit codes for three symbols sum correctly
    // but cannot exist. The reference's own structural check
    // (`HUF_readStats`: "by construction : at least 2 elts of rank 1, must
    // be even").
    var deepest: u16 = 0;
    for (tree.weights[0..tree.symbol_count]) |weight| {
        if (weight == 1) deepest += 1;
    }
    if (deepest < 2) return error.MalformedHuffmanWeights;
    if (deepest % 2 != 0) return error.MalformedHuffmanWeights;
}

/// One decode-table cell: the symbol a code decodes to and the code's length.
pub const Entry = struct {
    symbol: u8,
    num_bits: u5,
};

/// A decode table (`§4.2.1.3`): `1 << max_bits` cells, indexed by the
/// stream's next `max_bits` bits with the code left-justified, so a decode
/// is one lookup and one skip.
pub const DecodeTable = struct {
    max_bits: u5,
    entries: [@as(usize, 1) << code_length_max]Entry,
};

/// Build the decode table from a tree (`§4.2.1.3`).
pub fn buildTable(tree: *const Tree) DecodeTable {
    assert(tree.symbol_count >= 2);
    assert(tree.max_bits <= code_length_max);
    var table: DecodeTable = .{ .max_bits = tree.max_bits, .entries = undefined };

    // "Symbols are sorted by Weight. Within the same Weight, symbols keep
    // natural sequential order. Symbols with a Weight of zero are removed.
    // Then, starting from the lowest Weight, prefix codes are distributed in
    // sequential order." A weight-w symbol owns 2^(w-1) consecutive cells —
    // its code, left-justified.
    var rank_count: [code_length_max + 1]u16 = @splat(0);
    for (tree.weights[0..tree.symbol_count]) |weight| rank_count[weight] += 1;
    var rank_start: [code_length_max + 1]u16 = @splat(0);
    var start: u16 = 0;
    for (1..code_length_max + 1) |weight| {
        rank_start[weight] = start;
        start += rank_count[weight] << @intCast(weight - 1);
    }
    assert(start == @as(u16, 1) << @intCast(tree.max_bits));

    for (tree.weights[0..tree.symbol_count], 0..) |weight, symbol| {
        if (weight == 0) continue;
        assert(weight <= tree.max_bits);
        const length = @as(u16, 1) << @intCast(weight - 1);
        const cell: Entry = .{
            .symbol = @intCast(symbol),
            .num_bits = @intCast(tree.max_bits + 1 - weight),
        };
        const begin = rank_start[weight];
        for (table.entries[begin .. begin + length]) |*entry| entry.* = cell;
        rank_start[weight] += length;
    }
    return table;
}

/// Decode one Huffman-coded stream backwards into `target` (`§4.2.2`):
/// exactly `target.len` symbols, and then the stream must be exactly
/// consumed.
pub fn decodeStream(table: *const DecodeTable, source: []const u8, target: []u8) Error!void {
    var reader: bits.BackwardReader = try .init(source);
    for (target) |*byte| {
        const cell = table.entries[reader.peekBits(table.max_bits)];
        reader.skipBits(cell.num_bits);
        byte.* = cell.symbol;
    }
    // "If a bitstream is not entirely and exactly consumed, hence reaching
    // exactly its beginning position with all bits consumed, the decoding
    // process is considered faulty."
    if (reader.overran()) return error.InvalidBitStream;
    if (!reader.isConsumed()) return error.BitstreamNotConsumed;
}

/// The index of the highest set bit; `value` must be nonzero.
inline fn highBit(value: u32) u5 {
    assert(value != 0);
    return @intCast(31 - @clz(value));
}

test "readTree reads the direct representation, high nibble first" {
    // RFC 8878 §4.2.1.1 — "Weight[0] = (Byte[0] >> 4), Weight[1] =
    // (Byte[0] & 0xf), etc." and "Number_of_Symbols = headerByte - 127".
    // The T1 pair's tree: five symbols, weights 4, 3, 2, 0, 1.
    const tree = try readTree(&golden.t1_tree);
    try testing.expectEqual(@as(usize, 4), tree.bytes_consumed);
    // RFC 8878 §4.2.1 — the completion: the sum of 2^(Weight-1) is 15, "the
    // nearest power of 2 is 16. Therefore, Max_Number_of_Bits = 4 and
    // Weight[5] = 16 - 15 = 1."
    try testing.expectEqual(@as(u5, 4), tree.max_bits);
    try testing.expectEqual(@as(u16, 6), tree.symbol_count);
    try testing.expectEqualSlices(
        u8,
        &.{ 4, 3, 2, 0, 1, 1 },
        tree.weights[0..tree.symbol_count],
    );
}

test "decodeStream decodes the T1 pair: Table 25's assignment, not the example's" {
    // RFC 8878 §4.2.1.3 (Table 25) — "prefix codes are distributed in
    // sequential order" from the lowest weight: the weight-1 symbols 4 and 5
    // take 0000 and 0001. §4.2.2's worked example (Table 26) swaps them;
    // errata 8195, docs/research/zstd-notes.md §4 T1. Both streams below are
    // hand-built frames the C CLI v1.5.7 and Zig std decode as written.
    const tree = try readTree(&golden.t1_tree);
    const table = buildTable(&tree);
    try testing.expectEqual(@as(u5, 4), table.max_bits);

    var target: [4]u8 = @splat(0xaa);
    try decodeStream(&table, &golden.t1_stream, &target);
    try testing.expectEqualSlices(u8, &golden.t1_literals, &target);

    var errata: [4]u8 = @splat(0xaa);
    try decodeStream(&table, &golden.t1_errata_stream, &errata);
    try testing.expectEqualSlices(u8, &golden.t1_errata_literals, &errata);
}

test "decodeStream leaves the bytes past its symbols untouched" {
    // RFC 8878 §4.2.2 — the stream holds exactly `target.len` symbols; the
    // sentinel proves a decode writes nowhere else (AGENTS.md, "Rules").
    const tree = try readTree(&golden.t1_tree);
    const table = buildTable(&tree);
    var buffer: [16]u8 = undefined;
    internal.sentinel.fill(&buffer);
    try decodeStream(&table, &golden.t1_stream, buffer[0..4]);
    try internal.sentinel.expect(&buffer, 4);
}

test "readTree reads an FSE-compressed weight series" {
    // RFC 8878 §4.2.1.2 — "the series of weights is compressed using FSE.
    // The length of the FSE-compressed series is equal to headerByte" — and
    // the number of weights "is determined by tracking the bitStream
    // overflow condition". The fixture is a real frame's tree: 122 weights,
    // completing to 192, so the implied last weight is 7 and the tree depth
    // is 8.
    const tree = try readTree(&golden.weights_description);
    try testing.expectEqual(@as(usize, 20), tree.bytes_consumed);
    try testing.expectEqual(@as(u5, 8), tree.max_bits);
    try testing.expectEqual(@as(u16, 123), tree.symbol_count);
    try testing.expectEqualSlices(
        u8,
        &golden.weights_expected,
        tree.weights[0..golden.weights_expected.len],
    );
    try testing.expectEqual(@as(u8, 7), tree.weights[golden.weights_expected.len]);
}

test "readTree rejects a series whose weights cannot complete to a power of two" {
    // RFC 8878 §4.2.1 — the implied last weight "is deduced from previously
    // decoded ones, by completing to the nearest power of 2", and the
    // remainder must be a clean power of two. A direct tree of one symbol
    // with weight 2 leaves 4 - 2 = 2, which is not one.
    try testing.expectError(error.MalformedHuffmanWeights, readTree(&.{ 128, 0x20 }));
    // The same one-symbol tree with weight 1 completes: 2 - 1 = 1.
    const ok = try readTree(&.{ 128, 0x10 });
    try testing.expectEqual(@as(u16, 2), ok.symbol_count);
    try testing.expectEqual(@as(u5, 1), ok.max_bits);
}

test "readTree rejects a tree whose deepest level cannot exist" {
    // RFC 8878 §4.2.1 — the completion is not enough: a tree of three
    // weight-2 symbols sums to 1 + 1 + 1 = 3, completes with a weight-2
    // fourth symbol (4 - 3 = 1 -> 2^0), and would give every symbol a 1-bit
    // code. The reference rejects it ("at least 2 elts of rank 1, must be
    // even"); so does this reader.
    try testing.expectError(error.MalformedHuffmanWeights, readTree(&.{ 130, 0x22, 0x20 }));
}

test "readTree rejects a truncated description" {
    // RFC 8878 §4.2.1.1 — the direct representation occupies
    // ceiling(Number_of_Symbols/2) bytes; here it needs 3 and has 1.
    try testing.expectError(error.MalformedHuffmanWeights, readTree(&.{ 133, 0x43 }));
    // The FSE-compressed form needs headerByte bytes after the header byte.
    try testing.expectError(error.MalformedHuffmanWeights, readTree(&.{ 0x04, 0x10, 0x3f }));
    try testing.expectError(error.MalformedHuffmanWeights, readTree(&.{}));
}

test "readTree rejects a zero last byte in the FSE-compressed series" {
    // RFC 8878 §4.2.2 — "a last byte of 0 is not possible": the series has
    // no final 1 bit to start from. The weights path reports it as a
    // malformed series, the same class the reference's FSE_decompress
    // reports for it.
    // The description is §4.1.1's [16, 16] (log 5) and the bitstream is a
    // single zero byte.
    try testing.expectError(
        error.MalformedHuffmanWeights,
        readTree(&.{ 0x03, 0x10, 0x3f, 0x00 }),
    );
}

test "decodeWeights stops at the target: a series longer than the alphabet" {
    // RFC 8878 §4.2.1.2 — "It's also necessary to know its maximum possible
    // decompressed size, which is 255, since literal values span from 0 to
    // 255, and the last symbol's Weight is not represented." A series that
    // wants more than the target holds is corruption, not an overrun.
    const series = golden.weights_description[1..];
    const description = try fse.readDescription(series, 255, 6);
    const table = fse.buildTable(
        description.counts[0..description.symbol_count],
        description.accuracy_log,
    );
    var reader: bits.BackwardReader = try .init(series[description.bytes_consumed..]);
    var target: [4]u8 = @splat(0);
    try testing.expectError(
        error.MalformedHuffmanWeights,
        decodeWeights(&reader, &table, &target),
    );
}

test "readTree rejects a tree deeper than the code-length ceiling" {
    // RFC 8878 §4.2.1 — "This specification limits the maximum code length
    // to 11 bits." Four weight-11 symbols sum to 4096, whose completion
    // depth is 13: over the ceiling, and over the shift the sum itself can
    // carry.
    try testing.expectError(error.MalformedHuffmanWeights, readTree(&.{ 0x83, 0xbb, 0xbb }));
}

test "decodeStream rejects a stream with bits left over or none to spare" {
    // RFC 8878 §4.2.2 — the stream must be exactly consumed. The T1 stream
    // decodes four symbols; asking for three leaves bits over, and asking
    // for five runs out.
    const tree = try readTree(&golden.t1_tree);
    const table = buildTable(&tree);
    var target: [5]u8 = @splat(0);
    try testing.expectError(
        error.BitstreamNotConsumed,
        decodeStream(&table, &golden.t1_stream, target[0..3]),
    );
    try testing.expectError(
        error.InvalidBitStream,
        decodeStream(&table, &golden.t1_stream, target[0..5]),
    );
    // A zero last byte has no start bit at all.
    try testing.expectError(
        error.MissingStartBit,
        decodeStream(&table, &.{ 0x01, 0x00 }, target[0..1]),
    );
}

test "buildTable: the codes are left-justified at the table's top bits" {
    // RFC 8878 §4.2.1.3 — Table 25's assignment: weight-1 symbols first (in
    // natural order), then increasing weight. For the T1 tree the codes are
    // 0 -> "1", 1 -> "01", 2 -> "001", 4 -> "0000", 5 -> "0001", and the
    // decode table indexes them by the stream's next four bits.
    const tree = try readTree(&golden.t1_tree);
    const table = buildTable(&tree);
    try testing.expectEqual(@as(u8, 0), table.entries[0b1000].symbol);
    try testing.expectEqual(@as(u5, 1), table.entries[0b1000].num_bits);
    try testing.expectEqual(@as(u8, 0), table.entries[0b1111].symbol);
    try testing.expectEqual(@as(u8, 1), table.entries[0b0100].symbol);
    try testing.expectEqual(@as(u5, 2), table.entries[0b0100].num_bits);
    try testing.expectEqual(@as(u8, 2), table.entries[0b0010].symbol);
    try testing.expectEqual(@as(u5, 3), table.entries[0b0010].num_bits);
    try testing.expectEqual(@as(u8, 4), table.entries[0b0000].symbol);
    try testing.expectEqual(@as(u5, 4), table.entries[0b0000].num_bits);
    try testing.expectEqual(@as(u8, 5), table.entries[0b0001].symbol);
    try testing.expectEqual(@as(u5, 4), table.entries[0b0001].num_bits);
}
