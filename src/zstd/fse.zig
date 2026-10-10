//! FSE (RFC 8878 §4.1) for the zstd decoder: the normalized-count table
//! description (`§4.1.1`), the decoding-table construction, and the state
//! machine that reads symbols out of a backwards bitstream (`§4.1`).
//!
//! Three contexts share this layer: the literals length, match length, and
//! offset code tables of the sequences section (`§3.1.1.3.2.1`, caps 9, 9, 8
//! and symbol spans 36, 53, 32) and the Huffman weights (`§4.2.1.2`, cap 6,
//! symbol span 256). The caller supplies both caps; nothing here knows which
//! context it serves.
//!
//! The description is the one zstd bitstream read *forward* (`§4.1.1`); the
//! symbol streams are read backward (`§4.1`: "all FSE bitstreams are read
//! from end to beginning"). The construction is `§4.1.1`'s: "less than 1"
//! symbols take one cell each from the end of the table and retreat, the
//! rest are spread (`position += (tableSize >> 1) + (tableSize >> 3) + 3;
//! position &= tableSize - 1`), and each symbol's states get their widths
//! and baselines in natural order. Appendix A's three tables are the
//! day-one golden vectors for it (`golden.zig`).
//!
//! Two decisions where the RFC text and the reference decoders disagree are
//! recorded here (docs/research/zstd-notes.md §4):
//!
//! - **T9 — the symbol-count rule.** `§4.1.1` says "If the number of symbols
//!   decoded is not equal to the expected, the header should be considered
//!   corrupt", which read literally rejects the short distributions the
//!   reference encoder emits all the time. The rule enforced here is the
//!   reference's: the probability budget must land *exactly* on
//!   `1 << Accuracy_Log`, and the symbol count may fall short of the
//!   context's expectation but never exceed it. Both directions are pinned
//!   below; the fuzz lane carries the corner further.
//! - **"two or more symbols with nonzero probability"** (`§4.1.1`) is
//!   enforced here and *not* by the reference (`FSE_readNCount` and
//!   `FSE_buildDTable` have no such check), so a single-symbol compressed
//!   distribution — which the reference encoder never emits, because
//!   `Table 15`'s FSE_Compressed mode "must not be used when only one symbol
//!   is present" — is `MalformedFseTable` rather than a decodable table.
//!   Fail closed, per the house posture.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const bits = @import("bits.zig");
const golden = @import("golden.zig");

/// Everything the FSE layer reports.
pub const Error = error{
    /// `§4.1.1`'s rules: the accuracy log exceeds the context's cap, the
    /// probability budget does not land exactly on `1 << Accuracy_Log`, the
    /// symbol count exceeds the context's expectation, or fewer than two
    /// symbols have a nonzero probability.
    MalformedFseTable,
    /// A backwards stream whose last byte is zero, so it carries no final 1
    /// bit (`§3.1.1.3.2.1.2`, `§4.2.2`).
    MissingStartBit,
    /// A read ran past the stream's start (`§4.1`).
    InvalidBitStream,
    /// Bits left over once the last symbol was decoded (`§3.1.1.3.2.1.2`:
    /// "At the end, the bitstream shall be entirely consumed").
    BitstreamNotConsumed,
};

/// The largest accuracy log any zstd FSE context uses: the literals length
/// and match length code tables cap at 9, the offset code table at 8, and
/// the Huffman weights at 6 (`§3.1.1.3.2.1` Table 15, `§4.2.1.2`).
pub const accuracy_log_max: u5 = 9;

/// The largest table any context builds: `1 << accuracy_log_max` cells.
pub const table_size_max = 1 << accuracy_log_max;

/// "That expected number of symbols never exceeds 256" (`§4.1.1`).
pub const symbol_count_max = 256;

/// One decoding-table cell (`§4.1`): the symbol the state holds, the bits to
/// consume for the next state, and the baseline to add to them.
pub const Entry = struct {
    symbol: u8,
    num_bits: u5,
    baseline: u16,
};

/// A decoding table: `1 << log` cells, indexed by a state value (`§4.1`).
pub const Table = struct {
    /// The table's Accuracy_Log.
    log: u5,
    /// Only the first `1 << log` cells are live.
    entries: [table_size_max]Entry,

    /// The cell a state value indexes.
    pub fn entry(self: *const Table, state: u16) Entry {
        assert(state < @as(u16, 1) << @intCast(self.log));
        return self.entries[state];
    }
};

/// A normalized-count table description (`§4.1.1`): the probability of each
/// symbol from 0 to the last present one, on a scale of
/// `1 << accuracy_log`. `-1` is the "less than 1" probability, which "counts
/// as 1" point.
pub const Description = struct {
    /// Only the first `symbol_count` entries are meaningful.
    counts: [symbol_count_max]i16,
    /// The number of symbols the description covers: the distribution runs
    /// from symbol 0 to `symbol_count - 1`.
    symbol_count: u16,
    accuracy_log: u5,
    /// The bytes the description consumed: "The bitstream consumes a round
    /// number of bytes" (`§4.1.1`).
    bytes_consumed: usize,
};

/// Read a distribution table description (`§4.1.1`).
///
/// `symbol_value_max` is the context's last symbol index — 35, 52, and 31
/// for the literals length, match length, and offset code tables, 255 for
/// the Huffman weights — and `accuracy_log_cap` its accuracy cap. The
/// description may cover fewer symbols than the context allows (T9) but
/// never more.
pub fn readDescription(
    source: []const u8,
    symbol_value_max: u16,
    accuracy_log_cap: u5,
) Error!Description {
    assert(symbol_value_max < symbol_count_max);
    assert(accuracy_log_cap <= accuracy_log_max);
    var reader = bits.ForwardReader.init(source);

    // §4.1.1 — "If low4bits designates the lowest 4 bits of the first byte,
    // then Accuracy_Log = low4bits + 5."
    const nibble = reader.readBits(4);
    const accuracy_log: u5 = @intCast(nibble + 5);
    if (accuracy_log > accuracy_log_cap) return error.MalformedFseTable;

    var description: Description = .{
        .counts = undefined,
        .symbol_count = 0,
        .accuracy_log = accuracy_log,
        .bytes_consumed = 0,
    };
    // The C memsets the counts to zero before reading: the repeat flags below
    // skip zero-probability symbols without writing them, so "all symbols not
    // present in NCount have a frequency of 0" must be established up front.
    fastmem.set(i16, &description.counts, 0);

    // The budget is `1 << Accuracy_Log` points; `remaining` starts one above
    // it and lands on exactly 1 when the distribution is complete.
    var budget: Budget = .init(accuracy_log);
    var symbol_index: u32 = 0;
    const symbol_count_limit: u32 = @as(u32, symbol_value_max) + 1;
    var previous_zero = false;

    while (true) {
        if (previous_zero) {
            symbol_index += skipZeroRun(&reader, symbol_index, symbol_count_limit);
            // Past the context's symbol count there is nothing left to read.
            if (symbol_index >= symbol_count_limit) break;
        }
        const count = budget.readProbability(&reader);
        description.counts[symbol_index] = count;
        symbol_index += 1;
        previous_zero = count == 0;
        if (budget.spent()) break;
        if (symbol_index >= symbol_count_limit) break;
    }

    // The budget must land exactly on the table size (`§4.1.1`: "If the last
    // symbol makes the cumulated total go above (1 << Accuracy_Log),
    // distribution is considered corrupted"), and the symbol count may fall
    // short of the context's expectation but never exceed it (T9).
    if (budget.remaining != 1) return error.MalformedFseTable;
    if (symbol_index > symbol_count_limit) return error.MalformedFseTable;
    // The reader may look past the description's own bytes (the reference
    // reads a window), but it may not consume more than the caller offered:
    // "the bitstream consumes a round number of bytes" and those bytes must
    // be there.
    if (reader.bytesConsumed() > source.len) return error.MalformedFseTable;
    description.symbol_count = @intCast(symbol_index);
    if (description.symbol_count < 2) return error.MalformedFseTable;
    if (!hasTwoNonzero(description)) return error.MalformedFseTable;
    description.bytes_consumed = reader.bytesConsumed();
    return description;
}

/// The description reader's budget state (`§4.1.1`'s Table 20 widths): the
/// points not yet allocated, the "small values use 1 fewer bit" boundary,
/// and the current field width.
const Budget = struct {
    /// The points left to allocate, plus one: it reaches exactly 1 when the
    /// distribution is complete, and anything else is corruption.
    remaining: i32,
    /// `1 << (field_bits - 1)`, the boundary between the narrow and the wide
    /// encodings of Table 20.
    threshold: i32,
    /// The width of the next field, one more than the narrow form's.
    field_bits: u5,

    fn init(accuracy_log: u5) Budget {
        return .{
            .remaining = (@as(i32, 1) << accuracy_log) + 1,
            .threshold = @as(i32, 1) << accuracy_log,
            .field_bits = accuracy_log + 1,
        };
    }

    /// Read one symbol's probability: the value read is one above it, and
    /// "the value 0 becomes the negative probability -1", worth one point.
    fn readProbability(self: *Budget, reader: *bits.ForwardReader) i16 {
        // §4.1.1's Table 20: a value below `max_value` uses one bit fewer
        // than the field's width.
        const max_value: i32 = (2 * self.threshold - 1) - self.remaining;
        assert(max_value >= 0);
        const narrow_mask: u16 = @intCast(self.threshold - 1);
        const peeked = reader.peekBits(self.field_bits);
        var value: i32 = undefined;
        if (peeked & narrow_mask < @as(u16, @intCast(max_value))) {
            value = peeked & narrow_mask;
            reader.skipBits(self.field_bits - 1);
        } else {
            value = peeked & @as(u16, @intCast(2 * self.threshold - 1));
            if (value >= self.threshold) value -= max_value;
            reader.skipBits(self.field_bits);
        }
        const count = value - 1;
        self.remaining -= if (count >= 0) count else -count;
        // "Small values use 1 fewer bit": the width shrinks with the budget.
        // A spent budget leaves the widths alone — the loop is over.
        if (self.remaining > 1 and self.remaining < self.threshold) {
            self.field_bits = highBit(self.remaining) + 1;
            self.threshold = @as(i32, 1) << @intCast(self.field_bits - 1);
        }
        return @intCast(count);
    }

    /// Whether the loop is done: the budget is spent, so the next symbol
    /// would have nothing to allocate (`§4.1.1`: "When the last symbol
    /// reaches a cumulated total of (1 << Accuracy_Log), decoding is
    /// complete").
    fn spent(self: Budget) bool {
        return self.remaining <= 1;
    }
};

/// §4.1.1 — "When a symbol has a probability of zero, it is followed by a
/// 2-bit repeat flag. This repeat flag tells how many probabilities of zeroes
/// follow the current one. ... If it is a 3, another 2-bit repeat flag
/// follows, and so on." Returns how many symbols the flags skip.
fn skipZeroRun(
    reader: *bits.ForwardReader,
    symbol_index: u32,
    symbol_count_limit: u32,
) u32 {
    var zero_run: u32 = 0;
    while (true) {
        const flag = reader.readBits(2);
        zero_run += flag;
        if (flag != 3) break;
        // Past the context's symbol count the run is corruption whatever the
        // budget says, so stop reading flags.
        if (symbol_index + zero_run > symbol_count_limit) break;
    }
    return zero_run;
}

/// §4.1.1 — "Note that there must be two or more symbols with nonzero
/// probability."
fn hasTwoNonzero(description: Description) bool {
    var nonzero: u32 = 0;
    for (description.counts[0..description.symbol_count]) |count| {
        if (count != 0) nonzero += 1;
    }
    return nonzero >= 2;
}

/// Build the decoding table from normalized counts (`§4.1.1`'s
/// construction). `counts` runs from symbol 0 to the last present one.
pub fn buildTable(counts: []const i16, accuracy_log: u5) Table {
    assert(counts.len >= 1);
    assert(counts.len <= symbol_count_max);
    assert(accuracy_log >= 5);
    assert(accuracy_log <= accuracy_log_max);
    const table_size: u16 = @as(u16, 1) << @intCast(accuracy_log);
    var table: Table = .{ .log = accuracy_log, .entries = undefined };

    // §4.1.1 — "Symbols with this probability are being attributed a single
    // cell, starting from the end of the table and retreating. These symbols
    // define a full state reset, reading Accuracy_Log bits."
    var placed: u16 = 0;
    for (counts, 0..) |count, symbol| {
        if (count != -1) continue;
        placed += 1;
        assert(placed <= table_size);
        table.entries[table_size - placed] = .{
            .symbol = @intCast(symbol),
            .num_bits = accuracy_log,
            .baseline = 0,
        };
    }

    // §4.1.1 — the rest are allocated in natural order, spread across the
    // cells the "less than 1" symbols did not take:
    //   position += (tableSize >> 1) + (tableSize >> 3) + 3;
    //   position &= tableSize - 1;
    // "A position is skipped if it is already occupied by a 'less than 1'
    // probability symbol. Position does not reset between symbols."
    const spread_size: u16 = table_size - placed;
    if (spread_size > 0) {
        const mask: u16 = table_size - 1;
        const step: u16 = (table_size >> 1) + (table_size >> 3) + 3;
        var position: u16 = 0;
        for (counts, 0..) |count, symbol| {
            if (count <= 0) continue;
            var allocated: i16 = 0;
            while (allocated < count) : (allocated += 1) {
                table.entries[position].symbol = @intCast(symbol);
                position = (position + step) & mask;
                while (position >= spread_size) position = (position + step) & mask;
            }
        }
        assert(position == 0);
    }

    // §4.1.1 — "To get the Number_of_Bits and Baseline required for the next
    // state, it is first necessary to sort all states in their natural
    // order. The lower states will need 1 more bit than higher ones."
    // Baselines are then assigned "starting from the higher states using
    // fewer bits, and proceeding naturally, then resuming at the first
    // state".
    var next_state: [symbol_count_max]u16 = @splat(0);
    for (counts, 0..) |count, symbol| {
        next_state[symbol] = if (count == -1) 1 else @intCast(count);
    }
    for (table.entries[0..table_size]) |*entry| {
        const state = next_state[entry.symbol];
        next_state[entry.symbol] = state + 1;
        const num_bits: u5 = accuracy_log - highBitU16(state);
        entry.num_bits = num_bits;
        entry.baseline = (state << @intCast(num_bits)) - table_size;
    }
    return table;
}

/// A decoding state (`§4.1`): an index into a table.
pub const State = struct {
    index: u16,

    /// "To obtain the initial state value, consume Accuracy_Log bits from
    /// the stream as a little-endian value" (`§4.1`).
    pub fn init(reader: *bits.BackwardReader, table: *const Table) State {
        return .{ .index = reader.readBits(table.log) };
    }

    /// "The next symbol in the stream is the Symbol indicated in the table
    /// for that state" (`§4.1`).
    pub fn symbol(self: State, table: *const Table) u8 {
        return table.entry(self.index).symbol;
    }

    /// "To obtain the next state value, the decoder should consume Num_Bits
    /// bits from the stream as a little-endian value and add it to
    /// Baseline" (`§4.1`).
    pub fn update(self: *State, reader: *bits.BackwardReader, table: *const Table) void {
        const cell = table.entry(self.index);
        self.index = cell.baseline + reader.readBits(cell.num_bits);
    }
};

/// The index of the highest set bit; `value` must be nonzero.
fn highBitU16(value: u16) u5 {
    assert(value != 0);
    return @intCast(15 - @clz(value));
}

/// The index of the highest set bit; `value` must be nonzero.
fn highBit(value: i32) u5 {
    assert(value > 0);
    return @intCast(31 - @clz(@as(u32, @intCast(value))));
}

test "readDescription reads a real frame's literals length table" {
    // RFC 8878 §4.1.1 — the description reader against the reference
    // encoder's own FSE_writeNCount output: a zstd v1.5.7 frame's literals
    // length table, zero runs and "less than 1" symbols included
    // (golden.zig's provenance note). 34 symbols over an accuracy log of 9.
    const description = try readDescription(&golden.literals_length_description, 35, 9);
    try testing.expectEqual(@as(u5, 9), description.accuracy_log);
    try testing.expectEqual(@as(usize, 9), description.bytes_consumed);
    try testing.expectEqual(
        @as(u16, golden.literals_length_description_counts.len),
        description.symbol_count,
    );
    try testing.expectEqualSlices(
        i16,
        &golden.literals_length_description_counts,
        description.counts[0..description.symbol_count],
    );
}

test "readDescription reads a real frame's offset table" {
    // RFC 8878 §4.1.1 + §3.1.1.3.2.1 (Table 15) — the offset code table's
    // cap is 8, and this frame's table uses all of it.
    const description = try readDescription(&golden.offset_description, 31, 8);
    try testing.expectEqual(@as(u5, 8), description.accuracy_log);
    try testing.expectEqual(@as(usize, 12), description.bytes_consumed);
    try testing.expectEqual(
        @as(u16, golden.offset_description_counts.len),
        description.symbol_count,
    );
    try testing.expectEqualSlices(
        i16,
        &golden.offset_description_counts,
        description.counts[0..description.symbol_count],
    );
}

test "readDescription: Accuracy_Log = low4bits + 5, bounded by the context" {
    // RFC 8878 §4.1.1 — "If low4bits designates the lowest 4 bits of the
    // first byte, then Accuracy_Log = low4bits + 5." A nibble of 4 asks for
    // 9; the offset code table's cap is 8 (Table 15), so the same bytes that
    // the literals length context accepts are over the cap here.
    try testing.expectError(error.MalformedFseTable, readDescription(&.{ 0x04, 0x00 }, 31, 8));
    // Two symbols of 16 points each over an accuracy log of 5 (nibble 0).
    const description = try readDescription(&.{ 0x10, 0x3f }, 3, 9);
    try testing.expectEqual(@as(u5, 5), description.accuracy_log);
    try testing.expectEqual(@as(usize, 2), description.bytes_consumed);
    try testing.expectEqual(@as(i16, 16), description.counts[0]);
    try testing.expectEqual(@as(i16, 16), description.counts[1]);
}

test "readDescription: the budget must land exactly on 1 << Accuracy_Log" {
    // RFC 8878 §4.1.1 — the cumulated total "must" reach (1 << Accuracy_Log);
    // a distribution that stops short is corruption. 16 + 15 = 31 of a
    // 32-point budget: the reader runs out of expected symbols first.
    try testing.expectError(error.MalformedFseTable, readDescription(&.{ 0x10, 0x3d }, 1, 9));
    // The same bytes against a wider context spend the last point on a
    // "less than 1" symbol: 16 + 15 + 1 = 32, and that is legal.
    const description = try readDescription(&.{ 0x10, 0x3d }, 3, 9);
    try testing.expectEqual(@as(u16, 3), description.symbol_count);
    try testing.expectEqualSlices(i16, &.{ 16, 15, -1 }, description.counts[0..3]);
}

test "readDescription: a short distribution is legal, an exceeding count is not" {
    // RFC 8878 §4.1.1 + docs/research/zstd-notes.md §4 T9 — the RFC's "if
    // the number of symbols decoded is not equal to the expected, the header
    // should be considered corrupt" would reject the short distributions the
    // reference encoder emits routinely. The reference's reading is enforced:
    // fewer symbols than the context expects is legal when the budget is
    // exact, more is corruption.
    //
    // Two symbols of 16 points over an accuracy log of 5: the literals
    // length context expects up to 36 symbols and accepts it.
    const short = try readDescription(&.{ 0x10, 0x3f }, 35, 9);
    try testing.expectEqual(@as(u16, 2), short.symbol_count);
    // The same bytes against a context whose alphabet is one symbol: the
    // description decodes a symbol the context does not have.
    try testing.expectError(error.MalformedFseTable, readDescription(&.{ 0x10, 0x3f }, 0, 9));
}

test "readDescription rejects a distribution with one nonzero symbol" {
    // RFC 8878 §4.1.1 — "Note that there must be two or more symbols with
    // nonzero probability." The reference's FSE_readNCount has no such
    // check; this reader fails closed. 32 points all on symbol 1, with
    // symbol 0 a transmitted zero.
    try testing.expectError(error.MalformedFseTable, readDescription(&.{ 0x10, 0xf8, 0x01 }, 3, 9));
    // And the degenerate single-symbol distribution the same rule forbids.
    try testing.expectError(error.MalformedFseTable, readDescription(&.{ 0xf0, 0x03 }, 3, 9));
}

test "readDescription: a zero-probability symbol carries 2-bit repeat flags" {
    // RFC 8878 §4.1.1 — "When a symbol has a probability of zero, it is
    // followed by a 2-bit repeat flag. This repeat flag tells how many
    // probabilities of zeroes follow the current one." Here symbol 1 is zero
    // and the flag (value 2) skips symbols 2 and 3, so symbol 4 takes the
    // last 16 points.
    const description = try readDescription(&.{ 0x10, 0xc3, 0x0f }, 8, 9);
    try testing.expectEqual(@as(u16, 5), description.symbol_count);
    try testing.expectEqualSlices(i16, &.{ 16, 0, 0, 0, 16 }, description.counts[0..5]);
}

test "readDescription: a long zero run extends the repeat flags" {
    // RFC 8878 §4.1.1 — "If it is a 3, another 2-bit repeat flag follows,
    // and so on." A run of 24 zeros is the reference's fast-path shape
    // (eight 3-flags in a row); the reader must skip them all.
    const description = try readDescription(&.{ 0x10, 0xe3, 0xff, 0x9f, 0x0f }, 40, 9);
    try testing.expectEqual(@as(u16, 27), description.symbol_count);
    try testing.expectEqual(@as(i16, 16), description.counts[0]);
    try testing.expectEqual(@as(i16, 16), description.counts[26]);
    for (description.counts[1..26]) |count| try testing.expectEqual(@as(i16, 0), count);
}

test "readDescription: a 'less than 1' probability is worth one point" {
    // RFC 8878 §4.1.1 — "The value 0 becomes the negative probability -1
    // ... For the purpose of calculating total allocated probability points,
    // it counts as 1." -1 + 31 = 32 over an accuracy log of 5.
    const description = try readDescription(&.{ 0x00, 0x7e }, 4, 9);
    try testing.expectEqual(@as(u16, 2), description.symbol_count);
    try testing.expectEqual(@as(i16, -1), description.counts[0]);
    try testing.expectEqual(@as(i16, 31), description.counts[1]);
}

test "readDescription rejects a truncated description" {
    // RFC 8878 §4.1.1 — the description is a bitstream of its own; running
    // out of it mid-symbol is corruption, not a short read of the block.
    try testing.expectError(error.MalformedFseTable, readDescription(&.{0x10}, 3, 9));
    try testing.expectError(error.MalformedFseTable, readDescription(&.{}, 3, 9));
}

test "buildTable reproduces Appendix A's three predefined tables" {
    // RFC 8878 §4.1.1 + Appendix A — "The tables here can be used as
    // examples to crosscheck that an implementation has built its decoding
    // tables correctly." Each table's first data row is the all-zero state-0
    // duplicate (errata 6441, docs/research/zstd-notes.md §4 T2); the real
    // state-0 row is the second.
    const cases = .{
        .{
            .counts = &golden.literals_length_distribution,
            .log = 6,
            .rows = &golden.literals_length_table,
        },
        .{
            .counts = &golden.match_length_distribution,
            .log = 6,
            .rows = &golden.match_length_table,
        },
        .{
            .counts = &golden.offset_distribution,
            .log = 5,
            .rows = &golden.offset_table,
        },
    };
    inline for (cases) |case| {
        const table = buildTable(case.counts, case.log);
        try testing.expectEqual(@as(u5, case.log), table.log);
        for (case.rows, 0..) |row, state| {
            const entry = table.entries[state];
            try testing.expectEqual(row.symbol, entry.symbol);
            try testing.expectEqual(row.num_bits, entry.num_bits);
            try testing.expectEqual(row.baseline, entry.baseline);
        }
    }
}

test "buildTable places 'less than 1' symbols from the end and retreating" {
    // RFC 8878 §4.1.1 — "Symbols are scanned in their natural order for
    // 'less than 1' probabilities ... being attributed a single cell,
    // starting from the end of the table and retreating. These symbols
    // define a full state reset, reading Accuracy_Log bits." Symbols 0 and 2
    // take the last two cells; symbols 1 and 3 split the other 30.
    const counts = [_]i16{ -1, 15, -1, 15 };
    const table = buildTable(&counts, 5);
    try testing.expectEqual(@as(u8, 0), table.entries[31].symbol);
    try testing.expectEqual(@as(u5, 5), table.entries[31].num_bits);
    try testing.expectEqual(@as(u16, 0), table.entries[31].baseline);
    try testing.expectEqual(@as(u8, 2), table.entries[30].symbol);
    try testing.expectEqual(@as(u5, 5), table.entries[30].num_bits);
    try testing.expectEqual(@as(u16, 0), table.entries[30].baseline);
    var ones: u16 = 0;
    var threes: u16 = 0;
    for (table.entries[0..30]) |entry| {
        try testing.expect(entry.symbol == 1 or entry.symbol == 3);
        if (entry.symbol == 1) ones += 1 else threes += 1;
    }
    try testing.expectEqual(@as(u16, 15), ones);
    try testing.expectEqual(@as(u16, 15), threes);
}

test "State walks a table from the stream's end" {
    // RFC 8878 §4.1 — "To obtain the initial state value, consume
    // Accuracy_Log bits from the stream as a little-endian value. The next
    // symbol in the stream is the Symbol indicated in the table for that
    // state. To obtain the next state value, the decoder should consume
    // Num_Bits bits from the stream as a little-endian value and add it to
    // Baseline."
    //
    // Two symbols of 16 points over an accuracy log of 5: every cell needs
    // one bit and sits at baseline 2 * state. The stream holds the initial
    // state 0 and the update bits 1, 0, 1, 0, 1, so the states walked are
    // 0, 1, 2, 5, 6, 9 and the symbols 0, 0, 0, 0, 0, 1.
    const counts = [_]i16{ 16, 16 };
    const table = buildTable(&counts, 5);
    var reader = try bits.BackwardReader.init(&.{ 0x15, 0x04 });
    var state = State.init(&reader, &table);
    const expected_states = [_]u16{ 0, 1, 2, 5, 6, 9 };
    const expected_symbols = [_]u8{ 0, 0, 0, 0, 0, 1 };
    for (
        expected_states[0 .. expected_states.len - 1],
        expected_symbols[0 .. expected_symbols.len - 1],
    ) |want_state, want_symbol| {
        try testing.expectEqual(want_state, state.index);
        try testing.expectEqual(want_symbol, state.symbol(&table));
        state.update(&reader, &table);
    }
    try testing.expectEqual(expected_states[expected_states.len - 1], state.index);
    try testing.expectEqual(expected_symbols[expected_symbols.len - 1], state.symbol(&table));
    // The stream is exactly consumed: 5 initial bits plus one per update.
    try testing.expect(reader.isConsumed());
}
