//! Raw DEFLATE (RFC 1951) decoder: one-shot inflate over caller-owned buffers,
//! zero heap allocation, fail-closed on every malformed stream.
//!
//! Shape: a resumable LSB-first bit reader (`§3.1.1`), canonical Huffman
//! decode tables (`§3.2.2`) for the fixed (`§3.2.6`) and dynamic (`§3.2.7`)
//! blocks, stored blocks at any alignment (`§3.2.4`), and matches decoded in
//! place into `target` — the one-shot path's history *is* the output buffer,
//! so a distance before the start of the output is `error.InvalidMatch`
//! (`§3.2.3`).
//!
//! The three packing rules of `§3.1.1` are the format's number-one corruption
//! risk, and the two Huffman paths are deliberately spelled differently:
//! Huffman codes are read MSB-of-code first (a code's wire bits are the *low*
//! bits of its table index), everything else — the 3 header bits, extra bits,
//! LEN/NLEN — is read LSB-of-value first. Extra bits are an ordinary data
//! element (T1 in src/flate/README.md, "Divergences"); `§3.2.5`'s
//! "most-significant bit first" sentence describes the numeral, not the wire.
//!
//! Format: docs/research/specs/rfc1951-deflate.txt
//!
//! Lineage: the two-level decode table (a `lookup_bits`-wide primary table
//! plus a chained chase for longer codes) follows zlib's `doc/algorithm.txt`
//! and Zig std's `std.compress.flate.Decompress.zig` (MIT), reimplemented in
//! this package's shape; see THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

/// Every decode failure, in detail (src/flate/README.md, "API"). `decompress`
/// returns this set; the streaming `Reader` (a later lane) reports the coarse
/// `error.ReadFailed` through the `Io` interface and records the specific
/// failure beside it.
pub const DecompressError = error{
    /// `decompress` only: `target` cannot hold the decoded output.
    BufferTooSmall,
    /// Input ended before the final block completed.
    Truncated,
    /// BTYPE = 11 is "reserved (error)" (`§3.2.3`).
    InvalidBlockType,
    /// NLEN != one's complement of LEN (`§3.2.4`).
    WrongStoredBlockNlen,
    /// A malformed dynamic header (`§3.2.7`).
    InvalidDynamicBlockHeader,
    /// Kraft sum > 1 (`§3.2.2`).
    OversubscribedHuffmanTree,
    /// Kraft sum < 1, beyond the single-1-bit-code case (`§3.2.7`).
    IncompleteHuffmanTree,
    /// A literal/length tree with no code for 256 (`§3.2.7`).
    MissingEndOfBlockCode,
    /// A code that decodes to no legal symbol.
    InvalidCode,
    /// A distance before the start of the output (`§3.2.3`).
    InvalidMatch,
};

/// `§3.2.7` — the order the precode code lengths are transmitted in. The
/// scrambled order keeps the common precode lengths early, so HCLEN can be
/// small.
const codegen_order = [19]u5{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// `§3.2.5` — length code 257-285 bases (index = code - 257).
const length_base = [29]u16{
    3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23,  27,
    31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
};

/// `§3.2.5` — length extra-bit counts (index = code - 257). Code 285 carries
/// zero extra bits: 258 is its only value.
const length_extra = [29]u5{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
};

/// `§3.2.5` — distance code 0-29 bases.
const distance_base = [30]u16{
    1,    2,    3,    4,    5,    7,    9,    13,    17,    25,
    33,   49,   65,   97,   129,  193,  257,  385,   513,   769,
    1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};

/// `§3.2.5` — distance extra-bit counts.
const distance_extra = [30]u5{
    0, 0, 0,  0,  1,  1,  2,  2,  3,  3,  4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};

/// The widest value `peek` may be asked for: the reader buffers 64 bits and
/// refills at 56, so any narrower peek is exact whenever the bits exist.
const max_peek_bits: u6 = 56;

/// Bit reader over `source`, LSB-first (`§3.1.1`): the first bit read is bit 0
/// of the next byte, a 9th bit spills into bit 0 of the byte after.
///
/// `bit_pos` is the source of truth for availability. `peek` may read zeros
/// past the end of the input; `take` is the gate that turns that into
/// `error.Truncated`, so a truncated stream can never decode a symbol out of
/// padding.
const BitReader = struct {
    source: []const u8,
    /// Next source byte not yet loaded into `bits`.
    next_byte: usize,
    /// Unconsumed bits, LSB first: bit 0 is the next bit on the wire.
    bits: u64,
    /// Valid bits in `bits` (0-64).
    bit_count: u7,
    /// Absolute bit offset of the next unconsumed bit. 64-bit so the position
    /// arithmetic cannot overflow a 32-bit `usize` on a large input.
    bit_pos: u64,

    fn init(source: []const u8) BitReader {
        return .{ .source = source, .next_byte = 0, .bits = 0, .bit_count = 0, .bit_pos = 0 };
    }

    /// Bits of `source` not yet consumed.
    fn availableBits(self: *const BitReader) u64 {
        return @as(u64, self.source.len) * 8 - self.bit_pos;
    }

    /// Load whole bytes while the buffer has room. Afterwards `bits` holds
    /// `min(available, 64)` bits, so any `peek` of at most 56 bits is exact
    /// whenever that many bits remain.
    fn refill(self: *BitReader) void {
        while (self.bit_count <= max_peek_bits and self.next_byte < self.source.len) {
            self.bits |= @as(u64, self.source[self.next_byte]) << @intCast(self.bit_count);
            self.next_byte += 1;
            self.bit_count += 8;
        }
    }

    /// The next `n` bits, LSB-of-value first, refilling first. Bits past the
    /// end of the input read as zero; the caller must `take` before trusting
    /// them.
    fn peek(self: *BitReader, n: u6) u64 {
        assert(n <= max_peek_bits);
        self.refill();
        return self.bits & ((@as(u64, 1) << n) - 1);
    }

    /// Consume `n` bits. `error.Truncated` when the input ends first.
    fn take(self: *BitReader, n: u6) DecompressError!u64 {
        if (self.availableBits() < n) return error.Truncated;
        const value = self.peek(n);
        self.bits >>= n;
        self.bit_count -= n;
        self.bit_pos += n;
        return value;
    }

    /// Skip to the next byte boundary: "any bits of input up to the next byte
    /// boundary are ignored" (`§3.2.4`). A decoder must not require the
    /// skipped bits to be zero.
    fn alignToByte(self: *BitReader) DecompressError!void {
        const skip: u6 = @intCast((8 - (self.bit_pos & 7)) & 7);
        if (skip != 0) _ = try self.take(skip);
        self.rebase();
    }

    /// Drop the buffered whole bytes back to `source` so a stored block can be
    /// read directly. Only valid at a byte boundary: the buffered bits are
    /// then whole unconsumed bytes, so rewinding loses nothing.
    fn rebase(self: *BitReader) void {
        assert(self.bit_pos % 8 == 0);
        assert(self.bit_count % 8 == 0);
        self.next_byte = @intCast(self.bit_pos / 8);
        self.bits = 0;
        self.bit_count = 0;
    }
};

/// Decoder-table kinds: the alphabet decides which structural rules apply.
const TreeKind = enum {
    /// Literal/length alphabet (0-285). Must be able to code 256 — without an
    /// end-of-block code no block could ever terminate (`§3.2.7`).
    literal_length,
    /// Distance alphabet (0-29). Zero codes ("the data is all literals") and a
    /// single 1-bit code are both legal (`§3.2.7`).
    distance,
    /// The 19-symbol precode alphabet. An empty precode tree cannot decode the
    /// lengths that must follow, so it is a malformed header.
    precode,
};

/// Canonical Huffman decode table (`§3.2.2`): a `lookup_bits`-wide primary
/// table plus a chained chase for longer codes.
///
/// A code's *wire* bits are read MSB-of-code first (`§3.1.1`), so bit 0 of a
/// table index is the first bit on the wire and the index's low `len` bits are
/// the code. `lookup[i]` packs `(symbol << 4) | code_len`; `code_len == 0`
/// marks a primary slot whose codes are all longer than `lookup_bits` (the
/// chain head is in the same field), and `invalid` marks a slot no code
/// matches — `error.InvalidCode`.
fn HuffmanDecoder(
    comptime alphabet_size: usize,
    comptime max_bits: u5,
    comptime lookup_bits: u5,
    comptime kind: TreeKind,
) type {
    const table_size = 1 << lookup_bits;
    const lookup_mask: u16 = table_size - 1;
    const invalid: u16 = 0xFFFF;
    const chain_end: u16 = 0xFFFF;

    return struct {
        const Self = @This();

        const Chain = struct {
            /// The code's wire bits (first bit on the wire in bit 0).
            wire: u16,
            len: u5,
            /// Next symbol index sharing this primary slot, or `chain_end`.
            next: u16,
        };

        lookup: [table_size]u16 = @splat(invalid),
        chain: [alphabet_size]Chain = @splat(.{ .wire = 0, .len = 0, .next = chain_end }),

        /// Build the table from `lens` (code length per symbol, in symbol
        /// order; 0 = "does not occur", `§3.2.7`). `error.Oversubscribed
        /// HuffmanTree` / `error.IncompleteHuffmanTree` /
        /// `error.MissingEndOfBlockCode` per the README's decided rules.
        fn build(self: *Self, lens: []const u4) DecompressError!void {
            assert(lens.len <= alphabet_size);
            assert(kind != .literal_length or lens.len > 256);
            try checkLengths(kind, lens);
            self.lookup = @splat(invalid);

            var count: [max_bits + 1]u16 = @splat(0);
            for (lens) |len| {
                if (len != 0) count[len] += 1;
            }

            // RFC 1951 §3.2.2, step 2: bl_count -> next_code.
            var next_code: [max_bits + 1]u16 = @splat(0);
            var code: u16 = 0;
            for (1..max_bits + 1) |bits| {
                code = (code + count[bits - 1]) << 1;
                next_code[bits] = code;
            }

            var chain_heads: [table_size]u16 = @splat(chain_end);
            for (lens, 0..) |len, symbol| {
                if (len == 0) continue;
                const wire = wireBits(next_code[len], len);
                next_code[len] += 1;
                if (len <= lookup_bits) {
                    // Every primary index whose low `len` bits are the code.
                    var i: usize = wire;
                    while (i < table_size) : (i += @as(usize, 1) << len) {
                        self.lookup[i] = (@as(u16, @intCast(symbol)) << 4) | len;
                    }
                } else {
                    const index = wire & lookup_mask;
                    self.chain[symbol] = .{ .wire = wire, .len = len, .next = chain_heads[index] };
                    chain_heads[index] = @intCast(symbol);
                    self.lookup[index] = @as(u16, @intCast(symbol)) << 4;
                }
            }
        }

        /// Decode one symbol: peek `max_bits`, resolve the code, consume its
        /// length. `error.InvalidCode` for a bit pattern no code matches.
        fn decode(self: *const Self, br: *BitReader) DecompressError!u16 {
            // The primary table is indexed by the next `lookup_bits` bits,
            // which is exactly the code for codes no longer than that.
            const peeked = br.peek(max_bits);
            const entry = self.lookup[@intCast(peeked & lookup_mask)];
            if (entry == invalid) return error.InvalidCode;
            if ((entry & 0xF) != 0) {
                _ = try br.take(@intCast(entry & 0xF));
                return entry >> 4;
            }
            var symbol = entry >> 4;
            while (symbol != chain_end) {
                const node = self.chain[symbol];
                if ((peeked & ((@as(u64, 1) << node.len) - 1)) == node.wire) {
                    _ = try br.take(node.len);
                    return symbol;
                }
                symbol = node.next;
            }
            return error.InvalidCode;
        }
    };
}

/// The code's wire value: `code` is the canonical numeral (`§3.2.2`), whose
/// MSB is transmitted first, so the low `len` bits of the result are the code
/// in transmission order.
fn wireBits(code: u16, len: u5) u16 {
    return @bitReverse(code) >> @intCast(16 - @as(u6, len));
}

/// Reject the code-length sets no decoder may accept, and the two shapes the
/// reference lineage pins (README, "Divergences" T2/T3):
///
///   - oversubscribed always (Kraft sum > 1, implied by `§3.2.2`);
///   - incomplete unless the only code is a single 1-bit code — zlib's
///     `inftrees.c` rule, Go's `huffmanDecoder.init`, std's `checkCompleteness`;
///   - an empty literal/length tree (no code for 256) or an empty precode tree.
fn checkLengths(comptime kind: TreeKind, lens: []const u4) DecompressError!void {
    var count: [16]u16 = @splat(0);
    var max: u4 = 0;
    for (lens) |len| {
        count[len] += 1;
        if (len > max) max = len;
    }
    if (max == 0) return switch (kind) {
        .distance => {}, // §3.2.7: zero distance codes, "the data is all literals"
        .literal_length => error.MissingEndOfBlockCode,
        .precode => error.InvalidDynamicBlockHeader,
    };

    // "left" is the number of code slots left after each length; one possible
    // code of zero length starts it.
    var left: u32 = 1;
    for (1..16) |len| {
        left <<= 1;
        if (count[len] > left) return error.OversubscribedHuffmanTree;
        left -= count[len];
    }
    if (left > 0 and !(max == 1 and count[1] == 1)) return error.IncompleteHuffmanTree;
    if (kind == .literal_length and lens[256] == 0) return error.MissingEndOfBlockCode;
}

const LitDecoder = HuffmanDecoder(288, 15, 9, .literal_length);
const DistDecoder = HuffmanDecoder(32, 15, 9, .distance);
const PrecodeDecoder = HuffmanDecoder(19, 7, 7, .precode);

/// `§3.2.6` — the fixed literal/length code lengths. Values 286-287 "will
/// never actually occur in the compressed data, but participate in the code
/// construction", so they are part of the table (and rejected at decode).
const fixed_literal_lens: [288]u4 = blk: {
    var lens: [288]u4 = undefined;
    for (0..144) |i| lens[i] = 8;
    for (144..256) |i| lens[i] = 9;
    for (256..280) |i| lens[i] = 7;
    for (280..288) |i| lens[i] = 8;
    break :blk lens;
};

/// `§3.2.6` — distance codes 0-31 are fixed 5-bit codes; 30-31 "will never
/// actually occur in the compressed data".
const fixed_distance_lens: [32]u4 = @splat(5);

/// `§3.2.6` — the fixed tables, built once at compile time. Building the
/// literal table with all 288 lengths is what makes it complete
/// (152x2^-8 + 112x2^-9 + 24x2^-7 = 1).
const fixed_literal: LitDecoder = blk: {
    @setEvalBranchQuota(10_000);
    var decoder: LitDecoder = .{};
    decoder.build(&fixed_literal_lens) catch |err| @compileError(
        "fixed literal table: " ++ @errorName(err),
    );
    break :blk decoder;
};

const fixed_distance: DistDecoder = blk: {
    @setEvalBranchQuota(10_000);
    var decoder: DistDecoder = .{};
    decoder.build(&fixed_distance_lens) catch |err| @compileError(
        "fixed distance table: " ++ @errorName(err),
    );
    break :blk decoder;
};

/// Decompress one raw deflate stream from `source` into `target`, which is a
/// cap: returns the decoded length, or `error.BufferTooSmall`. Zero heap
/// allocation; the one-shot path's match history is `target` itself, so a
/// match may reach back across block boundaries (`§3.2.3`) but never before
/// the start of the output. Bytes after the final block in `source` are
/// ignored: BFINAL self-delimits the stream (`§3.2.3`).
///
/// The block loop: one block per iteration, BFINAL ends it. Pure per-block
/// logic lives in the helpers.
pub fn decompress(source: []const u8, target: []u8) DecompressError!usize {
    var br: BitReader = .init(source);
    var out_pos: usize = 0;

    while (true) {
        const final = (try br.take(1)) != 0;
        // §3.2.3: BFINAL then BTYPE, two bits LSB-of-value first.
        const block_type: BlockType = @enumFromInt(@as(u2, @intCast(try br.take(2))));
        switch (block_type) {
            .stored => try decodeStoredBlock(&br, target, &out_pos),
            .fixed => try decodeCompressedBlock(
                &br,
                target,
                &out_pos,
                &fixed_literal,
                &fixed_distance,
            ),
            .dynamic => {
                var literal: LitDecoder = .{};
                var distance: DistDecoder = .{};
                try readDynamicHeader(&br, &literal, &distance);
                try decodeCompressedBlock(&br, target, &out_pos, &literal, &distance);
            },
            .reserved => return error.InvalidBlockType,
        }
        if (final) return out_pos;
    }
}

/// `§3.2.3` — BTYPE 00 stored, 01 fixed-Huffman, 10 dynamic-Huffman, 11
/// "reserved (error)".
const BlockType = enum(u2) { stored = 0, fixed = 1, dynamic = 2, reserved = 3 };

/// `§3.2.4` — a stored block: byte-aligned, LEN and NLEN (u16 LE, NLEN the
/// one's complement of LEN), then LEN raw bytes.
///
/// A payload cut short copies what is there and then fails closed, the
/// reference readers' behavior (Go's `TestReaderTruncated` pins the partial
/// output): the prefix written is a prefix of the true output, and the caller
/// must not trust `target` after any error.
fn decodeStoredBlock(br: *BitReader, target: []u8, out_pos: *usize) DecompressError!void {
    try br.alignToByte();
    const header_pos: usize = @intCast(br.bit_pos / 8);
    if (br.source.len - header_pos < 4) return error.Truncated;
    const len = readU16Le(br.source, header_pos);
    const nlen = readU16Le(br.source, header_pos + 2);
    if (len != ~nlen) return error.WrongStoredBlockNlen;

    const data_pos = header_pos + 4;
    const present: usize = @min(len, br.source.len - data_pos);
    if (target.len - out_pos.* < present) return error.BufferTooSmall;
    fastmem.copy(u8, target[out_pos.*..][0..present], br.source[data_pos..][0..present]);
    out_pos.* += present;
    if (present < len) return error.Truncated;

    br.bit_pos = @as(u64, data_pos + len) * 8;
    br.rebase();
}

/// A Huffman block's payload: symbols from the merged literal/length alphabet
/// until the end-of-block symbol (`§3.2.7`), each length followed by a
/// distance and its match copy.
fn decodeCompressedBlock(
    br: *BitReader,
    target: []u8,
    out_pos: *usize,
    literal: *const LitDecoder,
    distance: *const DistDecoder,
) DecompressError!void {
    while (true) {
        const symbol = try literal.decode(br);
        if (symbol < 256) {
            if (out_pos.* == target.len) return error.BufferTooSmall;
            target[out_pos.*] = @intCast(symbol);
            out_pos.* += 1;
            continue;
        }
        if (symbol == 256) return; // §3.2.7 — end of block
        // §3.2.6: values 286-287 "will never actually occur".
        if (symbol > 285) return error.InvalidCode;

        const length = try decodeLength(br, symbol);
        const dist_symbol = try distance.decode(br);
        // §3.2.6: distance codes 30-31 "will never actually occur".
        if (dist_symbol > 29) return error.InvalidCode;
        const match_distance = try decodeDistance(br, dist_symbol);
        // §3.2.3: "a distance cannot refer past the beginning of the output
        // stream" — in the one-shot path `target` is the whole output.
        if (match_distance > out_pos.*) return error.InvalidMatch;
        if (target.len - out_pos.* < length) return error.BufferTooSmall;

        copyMatch(target, out_pos.*, match_distance, length);
        out_pos.* += length;
    }
}

/// `§3.2.5` — length = base + extra, computed *unclamped* (README, "Divergences"
/// T5): code 284 with extra bits 31 is 258, even though the table states 284's
/// range as 227-257, because the whole reference lineage computes it that way.
fn decodeLength(br: *BitReader, symbol: u16) DecompressError!usize {
    const index: usize = symbol - 257;
    const extra = length_extra[index];
    const bits: usize = if (extra == 0) 0 else @intCast(try br.take(extra));
    return length_base[index] + bits;
}

/// `§3.2.5` — distance = base + extra, unclamped; the result is 1-32768.
fn decodeDistance(br: *BitReader, symbol: u16) DecompressError!usize {
    const index: usize = symbol;
    const extra = distance_extra[index];
    const bits: usize = if (extra == 0) 0 else @intCast(try br.take(extra));
    return distance_base[index] + bits;
}

/// `§3.2.7` — the dynamic header: HLIT, HDIST, HCLEN, the scrambled precode
/// lengths, then HLIT+HDIST code lengths as one sequence that repeat codes may
/// carry across the literal/distance boundary.
fn readDynamicHeader(
    br: *BitReader,
    literal: *LitDecoder,
    distance: *DistDecoder,
) DecompressError!void {
    const hlit: usize = @as(usize, @intCast(try br.take(5))) + 257;
    const hdist: usize = @as(usize, @intCast(try br.take(5))) + 1;
    const hclen: usize = @as(usize, @intCast(try br.take(4))) + 4;
    // §3.2.7's parentheticals read wider, but no base/extra values exist past
    // 285/29 and the reference lineage caps both alphabets (T3).
    if (hlit > 286 or hdist > 30) return error.InvalidDynamicBlockHeader;

    var precode_lens: [19]u4 = @splat(0);
    for (codegen_order[0..hclen]) |symbol| {
        precode_lens[symbol] = @intCast(try br.take(3));
    }
    var precode: PrecodeDecoder = .{};
    try precode.build(&precode_lens);

    var lens: [286 + 30]u4 = @splat(0);
    const total = hlit + hdist;
    var pos: usize = 0;
    while (pos < total) {
        const symbol = try precode.decode(br);
        if (symbol < 16) {
            lens[pos] = @intCast(symbol);
            pos += 1;
            continue;
        }
        if (symbol == 16) {
            // Repeat the previous code length 3-6 times (§3.2.7).
            if (pos == 0) return error.InvalidDynamicBlockHeader;
            const repeat: usize = @as(usize, @intCast(try br.take(2))) + 3;
            if (pos + repeat > total) return error.InvalidDynamicBlockHeader;
            fastmem.set(u4, lens[pos..][0..repeat], lens[pos - 1]);
            pos += repeat;
            continue;
        }
        if (symbol == 17 or symbol == 18) {
            // Repeat a zero code length 3-10 (17) or 11-138 (18) times.
            const repeat: usize = if (symbol == 17)
                @as(usize, @intCast(try br.take(3))) + 3
            else
                @as(usize, @intCast(try br.take(7))) + 11;
            if (pos + repeat > total) return error.InvalidDynamicBlockHeader;
            fastmem.set(u4, lens[pos..][0..repeat], 0);
            pos += repeat;
            continue;
        }
        return error.InvalidDynamicBlockHeader; // precode symbols are 0-18
    }

    try literal.build(lens[0..hlit]);
    try distance.build(lens[hlit..][0..hdist]);
}

/// Copy `length` bytes from `match_distance` back in `target` (`§3.2.3`).
/// `match_distance <= out_pos` and `out_pos + length <= target.len` are the
/// caller's guarantees. A match may overlap the bytes it is writing — the
/// referenced string repeats — so the overlapping case replicates the
/// `match_distance`-byte pattern.
fn copyMatch(target: []u8, out_pos: usize, match_distance: usize, length: usize) void {
    assert(match_distance > 0);
    assert(match_distance <= out_pos);
    assert(out_pos + length <= target.len);

    if (match_distance >= length) {
        const source = target[out_pos - match_distance ..][0..length];
        fastmem.copy(u8, target[out_pos..][0..length], source);
        return;
    }
    if (match_distance == 1) {
        // Single-byte run: §3.2.3's <length = 5, distance = 2> at distance 1.
        fastmem.set(u8, target[out_pos..][0..length], target[out_pos - 1]);
        return;
    }
    // Overlapping. Write one period, then double the written region until
    // `length` bytes are out: every copy's destination starts at or past its
    // source's end, so each one is a plain `fastmem.copy`.
    const first = @min(match_distance, length);
    fastmem.copy(u8, target[out_pos..][0..first], target[out_pos - match_distance ..][0..first]);
    var written = first;
    while (written < length) {
        const n = @min(written, length - written);
        fastmem.copy(u8, target[out_pos + written ..][0..n], target[out_pos..][0..n]);
        written += n;
    }
}

/// u16 little-endian at `pos`; the caller has bounds-checked `pos + 2`.
fn readU16Le(source: []const u8, pos: usize) u16 {
    return @as(u16, source[pos]) | (@as(u16, source[pos + 1]) << 8);
}

test "bit reader: LSB-first fill" {
    // Spec: rfc1951-deflate.txt §3.1.1 — "Data elements are packed into bytes
    // in order of increasing bit number within the byte, i.e., starting with
    // the least-significant bit of the byte", and a 9th bit spills into bit 0
    // of the next byte.
    var br: BitReader = .init(&[_]u8{ 0b1010_0101, 0b1100_0011 });
    try testing.expectEqual(@as(u64, 1), try br.take(1));
    try testing.expectEqual(@as(u64, 0), try br.take(1));
    try testing.expectEqual(@as(u64, 1), try br.take(1));
    try testing.expectEqual(@as(u64, 0b10100), try br.take(5));
    // Bit 8 is the first bit of the second byte.
    try testing.expectEqual(@as(u64, 0b1), try br.take(1));
    try testing.expectEqual(@as(u64, 0b1), try br.take(1));
    try testing.expectEqual(@as(u64, 0b110000), try br.take(6));
    try testing.expectError(error.Truncated, br.take(1));
}

test "bit reader: §3.1 multi-byte numbers are least-significant byte first" {
    // Spec: rfc1951-deflate.txt §3.1 — "the decimal number 520 is stored as
    // 00001000 00000010", i.e. 0x08 0x02 little-endian.
    var br: BitReader = .init(&[_]u8{ 0x08, 0x02 });
    try testing.expectEqual(@as(u64, 520), try br.take(16));
}

test "bit reader: peek past the end reads zeros, take fails" {
    // Spec: rfc1951-deflate.txt §3.1.1 — a peek is not a read; only `take`
    // consumes, and a truncated stream must fail closed.
    var br: BitReader = .init(&[_]u8{0xFF});
    try testing.expectEqual(@as(u64, 0xFF), br.peek(8));
    try testing.expectEqual(@as(u64, 0xFF), br.peek(15)); // high bits read as zero
    try testing.expectError(error.Truncated, br.take(9));
    try testing.expectEqual(@as(u64, 0xFF), try br.take(8));
    try testing.expectError(error.Truncated, br.take(1));
}

test "bit reader: alignToByte skips to the boundary, padding need not be zero" {
    // Spec: rfc1951-deflate.txt §3.2.4 — "any bits of input up to the next
    // byte boundary are ignored". The skipped bits here are 1s, which a
    // decoder must not require to be zero.
    var br: BitReader = .init(&[_]u8{ 0b1111_1010, 0x11 });
    try testing.expectEqual(@as(u64, 0b010), try br.take(3));
    try br.alignToByte();
    try testing.expectEqual(@as(usize, 8), br.bit_pos);
    try testing.expectEqual(@as(u64, 0x11), try br.take(8));
}

test "decompress: stored block" {
    // Spec: rfc1951-deflate.txt §3.2.4 — BFINAL=1, BTYPE=00, then LEN/NLEN
    // (u16 LE, NLEN the one's complement) and LEN raw bytes.
    const source = [_]u8{ 0x01, 0x03, 0x00, 0xFC, 0xFF, 'a', 'b', 'c' };
    var target: [8]u8 = undefined;
    const n = try decompress(&source, &target);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, "abc", target[0..n]);
}

test "decompress: stored block LEN 0 is legal" {
    // Spec: rfc1951-deflate.txt §3.2.4 — LEN is 0-65535, so an empty block is
    // legal; §3.2.3's BFINAL still ends the stream.
    const source = [_]u8{ 0x01, 0x00, 0x00, 0xFF, 0xFF };
    var target: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try decompress(&source, &target));
}

test "decompress: wrong stored NLEN" {
    // Spec: rfc1951-deflate.txt §3.2.4 — "NLEN is the one's complement of
    // LEN". 0xFC is ~3, 0xFD is not.
    const source = [_]u8{ 0x01, 0x03, 0x00, 0xFD, 0xFF, 'a', 'b', 'c' };
    var target: [8]u8 = undefined;
    try testing.expectError(error.WrongStoredBlockNlen, decompress(&source, &target));
}

test "decompress: reserved block type" {
    // Spec: rfc1951-deflate.txt §3.2.3 — BTYPE 11 is "reserved (error)".
    const source = [_]u8{0b0000_0111};
    var target: [1]u8 = undefined;
    try testing.expectError(error.InvalidBlockType, decompress(&source, &target));
}

test "decompress: empty input is truncated" {
    // Spec: rfc1951-deflate.txt §3.2.3 — a stream is a sequence of blocks and
    // the last one has BFINAL=1; no input means no final block.
    var target: [1]u8 = undefined;
    try testing.expectError(error.Truncated, decompress("", &target));
}

test "decompress: target too small for a stored block" {
    // README, "Contracts" — `target` is a cap and a stream that does not fit
    // is `error.BufferTooSmall`, reported before the overflowing write.
    const source = [_]u8{ 0x01, 0x03, 0x00, 0xFC, 0xFF, 'a', 'b', 'c' };
    var target: [2]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, decompress(&source, &target));
}

test "decompress: truncated stored payload writes its available prefix" {
    // Spec: rfc1951-deflate.txt §3.2.4 — LEN 12 but only 5 payload bytes are
    // present. The reference readers emit the 5 bytes and then fail; the
    // caller must not trust `target` past the error.
    const source = [_]u8{ 0x00, 0x0C, 0x00, 0xF3, 0xFF, 'h', 'e', 'l', 'l', 'o' };
    var target: [16]u8 = undefined;
    fastmem.set(u8, &target, 0xAA);
    try testing.expectError(error.Truncated, decompress(&source, &target));
    try testing.expectEqualSlices(u8, "hello", target[0..5]);
    try testing.expectEqual(@as(u8, 0xAA), target[5]);
}

test "copyMatch: non-overlapping" {
    var buf: [64]u8 = undefined;
    fastmem.set(u8, &buf, 0);
    fastmem.copy(u8, buf[0..8], "abcdefgh");
    copyMatch(&buf, 16, 16, 8);
    try testing.expectEqualSlices(u8, "abcdefgh", buf[16..24]);
}

test "copyMatch: §3.2.3's overlap example (length 5, distance 2)" {
    // Spec: rfc1951-deflate.txt §3.2.3 — "if the last 2 bytes decoded have
    // values X and Y, a string reference with <length = 5, distance = 2> adds
    // X,Y,X,Y,X to the output stream".
    var buf: [7]u8 = undefined;
    buf[0] = 'X';
    buf[1] = 'Y';
    copyMatch(&buf, 2, 2, 5);
    try testing.expectEqualSlices(u8, "XYXYXYX", &buf);
}

test "copyMatch: every distance and length combination" {
    // The overlapping pattern replication, swept over the small space: a
    // period of `distance` bytes, then `length` bytes of it.
    var buf: [256]u8 = undefined;
    var want: [256]u8 = undefined;
    for (1..33) |match_distance| {
        for (1..65) |length| {
            for (&buf, 0..) |*b, i| b.* = @intCast(i);
            fastmem.copy(u8, &want, &buf);
            for (0..length) |i| want[match_distance + i] = want[i];
            copyMatch(&buf, match_distance, match_distance, length);
            const end = match_distance + length;
            try testing.expectEqualSlices(u8, want[0..end], buf[0..end]);
        }
    }
}

test "checkLengths: oversubscribed and incomplete sets" {
    // README, "Divergences" T2 — oversubscribed always rejected; incomplete
    // rejected unless the longest code is 1 bit.
    // Kraft sum 1/2 + 1/4 + 1/8 + 1/8 = 1 is complete.
    const complete = [_]u4{ 1, 2, 3, 3 };
    try checkLengths(.distance, &complete);
    // 1/2 + 1/4 + 1/4 + 1/4 = 5/4 > 1.
    const oversubscribed = [_]u4{ 1, 2, 2, 2 };
    try testing.expectError(
        error.OversubscribedHuffmanTree,
        checkLengths(.distance, &oversubscribed),
    );
    // 1/2 + 1/4 + 1/8 = 7/8 < 1, longest code 3 bits.
    const incomplete = [_]u4{ 1, 2, 3, 0 };
    try testing.expectError(error.IncompleteHuffmanTree, checkLengths(.distance, &incomplete));
    // A single 1-bit code is the one legal incomplete shape (§3.2.7).
    const single = [_]u4{ 1, 0, 0, 0 };
    try checkLengths(.distance, &single);
}

test "checkLengths: literal/length trees need a code for 256" {
    // README, "Divergences" T2 — missing EOB is rejected up front, at table
    // build; an empty precode tree is the same situation one level up.
    var lens: [288]u4 = @splat(0);
    lens[0] = 1;
    lens[1] = 1; // complete, but no code for 256
    try testing.expectError(error.MissingEndOfBlockCode, checkLengths(.literal_length, &lens));

    const empty: [19]u4 = @splat(0);
    try testing.expectError(error.InvalidDynamicBlockHeader, checkLengths(.precode, &empty));
    try checkLengths(.distance, &empty); // zero distance codes are legal
}
