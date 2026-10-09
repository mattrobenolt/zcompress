//! Raw DEFLATE (RFC 1951) encoder — the fast level: fixed-Huffman blocks over
//! a klauspost-L1-class match finder, with a stored-block fallback so no block
//! ever expands past its stored form (`§3.2.4`).
//!
//! The match finder (src/flate/README.md, "Encoder"; flate-notes.md §5.1): one
//! single-slot `[1 << 15]u32` table keyed by the klauspost lineage's 5-byte
//! hash (`prime5bytes`), greedy — no lazy matching — with a 4-byte confirm, the
//! snappy-style accelerating skip, backward extension into the preceding
//! literals, minimum match 4, and a 32768-byte distance cap (`§3.2.5`). The
//! finder's window is the block's 32-KiB history followed by the block itself,
//! so matches cross block boundaries exactly as the format allows (`§3.2.3`).
//!
//! The bit writer has exactly two write operations, named for the packing rule
//! each implements (`§3.1.1`): `writeBits` (a non-Huffman data element,
//! LSB-of-value first — block headers, extra bits, stored LEN/NLEN) and
//! `writeCode` (a Huffman code, MSB-of-code first; the code tables below store
//! the wire bits pre-reversed). Mixing them up is the T1 bug: invisible to a
//! self-round-trip, fatal to interop — which is why `just flate-oracle` decodes
//! our output with python3's zlib.
//!
//! Every stream ends with a final empty fixed block, `03 00` — BFINAL=1,
//! BTYPE=01, EOB — and no data block carries BFINAL (README, "Divergences"
//! T4).
//!
//! Zero heap allocation: the finder table is a comptime-sized `[1 << 15]u32`
//! (128 KiB) stack local or Writer field, zeroed once per stream through
//! `fastmem.set` (a `@splat` lowers to the scalar compiler-rt memset on
//! aarch64 — the snappy encoder's 3x lesson). Entries are absolute stream
//! positions (wrapping u32), so the table persists across a stream's blocks
//! — a stale entry fails the distance cap — and each block pays only a
//! strided priming pass over its history, not a re-zero of the table.
//!
//! Format: docs/research/specs/rfc1951-deflate.txt
//! Lineage: klauspost/compress `flate/level1.go` (`fastEncL1`) and
//! `flate/fast_encoder.go`, via the shape of this repo's snappy encoder;
//! attribution in THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const mem = std.mem;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const decode = @import("decode.zig");
const golden = @import("golden.zig");

/// The encoder's block size: 65535, the stored-block LEN cap (`§3.2.4`), so any
/// block can fall back to stored. `compress` splits input at it; the streaming
/// `Writer` emits blocks at it.
pub const max_block_size: usize = 65535;

/// The format's maximum backward match reach: 32768 (`§3.2.5`). The finder's
/// window is this much history followed by the block, so the cap is
/// structural.
pub const history_len: usize = 32768;

/// Worst-case compressed size for `input_len` bytes (README, "Contracts"):
/// every block costs at most 5 bytes of stored header beyond its input
/// (`§3.2.4`), and the stream always ends with a 2-byte final empty block.
/// Size `target` to this before `compress`.
pub fn maxCompressedLength(input_len: usize) usize {
    return input_len + 5 * ((input_len + max_block_size - 1) / max_block_size) + 2;
}

/// The finder table: `[1 << 15]u32` single-slot entries = 128 KiB of
/// comptime-sized stack scratch (README, "Stack").
const table_bits = 15;
const table_size = 1 << table_bits;

/// The match-finder table. An entry is the *absolute* stream position
/// (wrapping u32) of the newest scanned position with that hash; a stale
/// entry fails `matchCandidate`'s distance cap, so a table persists across a
/// stream's blocks with no per-block zeroing — std's persistent Lookup
/// (flate-notes.md §8, `Compress.zig:66-80`). Callers zero it once per
/// stream (`fastmem.set`) and prime each block's history at
/// `stream_prime_stride`.
pub const FinderTable = [table_size]u32;

/// History priming density for the streaming/one-shot block sequence: every
/// `stream_prime_stride`-th history position is hashed so a match may reach
/// across the block boundary (`§3.2.3`). Backward extension recovers a
/// repeat from any covered position inside it, so a stride above 1 keeps the
/// long matches while dividing the priming pass's cost.
const stream_prime_stride: usize = 1;

/// The klauspost-lineage 5-byte hash multiplier — the flate L1 sibling of the
/// snappy encoder's `prime6bytes` (flate-notes.md §5.1).
const prime5bytes: u64 = 889523592379;

/// Hash the low 5 bytes of `u` to a table index: the 5 bytes into the high 40
/// bits, multiply by the 40-bit prime, keep the top `table_bits`.
inline fn hash5(u: u64) usize {
    return @intCast(((u << 24) *% prime5bytes) >> (64 - table_bits));
}

/// 8 bytes of `source` at `pos`, little-endian. The caller keeps the 8-byte
/// margin.
inline fn load64(source: []const u8, pos: usize) u64 {
    return mem.readInt(u64, source[pos..][0..8], .little);
}

/// 4 bytes of `source` at `pos`, little-endian — the match confirm.
inline fn load32(source: []const u8, pos: usize) u32 {
    return mem.readInt(u32, source[pos..][0..4], .little);
}

/// Minimum match length the finder emits: 3-byte matches cost a length symbol
/// and a distance symbol for three bytes, so the fast level starts at 4
/// (README, "Encoder"). The *format*'s shortest length is 3 (`§3.2.5`), which
/// is what the emitter's chunking and its assert use.
const min_match_len: usize = 4;

/// `§3.2.5` — the shortest codable match length: length code 257.
const min_length: usize = 3;

/// Trailing bytes a block reserves so the 8-byte loads and the 3-position hash
/// cascade stay in bounds — klauspost's `inputMargin` (flate-notes.md §5.1).
const input_margin: usize = 11;

/// Blocks below this size skip match finding entirely (klauspost's
/// `minNonLiteralBlockSize`): `input_margin` bytes cannot start a match, and a
/// match needs `min_match_len` bytes.
const min_match_block_size: usize = 1 + 1 + input_margin;

/// One Huffman code: its wire bits (the numeral's MSB first on the wire,
/// `§3.1.1`) and its length. `writeCode` consumes exactly this, so a numeral
/// cannot be passed where wire bits are expected.
const Code = struct { bits: u16, len: u5 };

/// The wire bits of a canonical code: `§3.2.2` assigns the numeral and
/// `§3.1.1` transmits its MSB first, so the low `len` bits of the result are
/// the code in transmission order. (decode.zig's `wireBits` is the decoder's
/// half of the same transform.)
fn wireBits(code: u16, len: u5) u16 {
    return @bitReverse(code) >> @intCast(16 - @as(u6, len));
}

/// `§3.2.6` — the fixed literal/length codes, from the numerals the RFC spells
/// out: 0-143 are 8 bits, `00110000` through `10111111`; 144-255 are 9 bits,
/// `110010000` through `111111111`; 256-279 are 7 bits, `0000000` through
/// `0010111`; 280-287 are 8 bits, `11000000` through `11000111`. Values 286-287
/// "will never actually occur in the compressed data, but participate in the
/// code construction", so they are part of the table.
const fixed_literal_codes: [288]Code = blk: {
    var codes: [288]Code = undefined;
    for (0..144) |i| codes[i] = .{ .bits = wireBits(@intCast(0x30 + i), 8), .len = 8 };
    for (144..256) |i| codes[i] = .{ .bits = wireBits(@intCast(0x190 + (i - 144)), 9), .len = 9 };
    for (256..280) |i| codes[i] = .{ .bits = wireBits(@intCast(i - 256), 7), .len = 7 };
    for (280..288) |i| codes[i] = .{ .bits = wireBits(@intCast(0xC0 + (i - 280)), 8), .len = 8 };
    break :blk codes;
};

/// `§3.2.6` — "Distance codes 0-31 are represented by (fixed-length) 5-bit
/// codes", so the numeral is the symbol. 30-31 never occur.
const fixed_distance_codes: [32]Code = blk: {
    var codes: [32]Code = undefined;
    for (&codes, 0..) |*code, i| code.* = .{ .bits = wireBits(@intCast(i), 5), .len = 5 };
    break :blk codes;
};

/// `§3.2.5` — length code 257-285 bases (index = code - 257).
const length_bases = [29]u16{
    3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23,  27,
    31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
};

/// `§3.2.5` — length extra-bit counts (index = code - 257). Code 285 carries
/// zero extra bits: 258 is its only value.
const length_extras = [29]u5{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
};

/// `§3.2.5` — distance code 0-29 bases.
const distance_bases = [30]u16{
    1,    2,    3,    4,    5,    7,    9,    13,    17,    25,
    33,   49,   65,   97,   129,  193,  257,  385,   513,   769,
    1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};

/// `§3.2.5` — distance extra-bit counts.
const distance_extras = [30]u5{
    0, 0, 0,  0,  1,  1,  2,  2,  3,  3,  4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};

/// A length symbol ready to emit: the merged-alphabet symbol (257-285), its
/// extra-bit count, and the extra-bit value.
const LengthSymbol = struct { symbol: u16, extra_bits: u5, extra_value: u16 };

/// `§3.2.5` — length -> its symbol and extra bits, derived at comptime from the
/// base/extra table above. Index = the length (3-258); 0-2 are unused. Code
/// 284's entry covers 227-258 by the table's own arithmetic, and code 285
/// overwrites 258 with zero extra bits — which is what the encoder emits: 258
/// is code 285, the one code with no extra bits (README, "Encoder"; T5).
const length_symbols: [259]LengthSymbol = blk: {
    var table: [259]LengthSymbol = undefined;
    for (length_bases, length_extras, 0..) |base, extra, i| {
        const span = @as(usize, 1) << extra;
        for (@as(usize, base)..@as(usize, base) + span) |length| {
            table[length] = .{
                .symbol = @intCast(257 + i),
                .extra_bits = extra,
                .extra_value = @intCast(length - base),
            };
        }
    }
    break :blk table;
};

/// `§3.2.5` — distance -> its code, derived at comptime from the base/extra
/// table above. Distances are 1-32768, so index 0 is unused.
const distance_codes: [history_len + 1]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [history_len + 1]u8 = undefined;
    for (distance_bases, distance_extras, 0..) |base, extra, i| {
        const span = @as(usize, 1) << extra;
        for (@as(usize, base)..@as(usize, base) + span) |distance| {
            table[distance] = @intCast(i);
        }
    }
    break :blk table;
};

/// A distance symbol with its extra bits.
const DistanceSymbol = struct { symbol: u8, extra_bits: u5, extra: u16 };

/// `§3.2.5` — the distance symbol for `distance` (1-32768) and its extra bits.
fn distanceSymbol(distance: usize) DistanceSymbol {
    assert(distance >= 1);
    assert(distance <= history_len);
    const symbol = distance_codes[distance];
    return .{
        .symbol = symbol,
        .extra_bits = distance_extras[symbol],
        .extra = @intCast(distance - distance_bases[symbol]),
    };
}

/// The bit writer (`§3.1.1`): bits fill a byte from bit 0 up, and a 9th bit
/// spills into bit 0 of the next byte. `bits`/`bit_count` carry the stream's
/// pending partial byte, which is what lets the streaming `Writer` emit one
/// block at a time: a block's bits continue at the previous block's bit
/// offset.
pub const BitWriter = struct {
    target: []u8,
    /// Whole bytes written into `target`.
    pos: usize = 0,
    /// Pending bits, LSB first: bit 0 is the next bit on the wire.
    bits: u64 = 0,
    /// Valid bits in `bits` (0-63, and below 8 outside `writeBits`).
    bit_count: u6 = 0,

    /// A block's start, so a block that bails to stored can be rewound.
    const Snapshot = struct { pos: usize, bits: u64, bit_count: u6 };

    /// The stream's bit position: `pos` bytes are flushed, `bit_count` bits are
    /// pending.
    fn bitsWritten(self: *const BitWriter) u64 {
        return @as(u64, self.pos) * 8 + self.bit_count;
    }

    fn snapshot(self: *const BitWriter) Snapshot {
        return .{ .pos = self.pos, .bits = self.bits, .bit_count = self.bit_count };
    }

    fn restore(self: *BitWriter, snap: Snapshot) void {
        self.pos = snap.pos;
        self.bits = snap.bits;
        self.bit_count = snap.bit_count;
    }

    /// Write a data element that is not a Huffman code, LSB-of-value first
    /// (`§3.1.1`): the block header, extra bits, stored LEN/NLEN. Extra bits
    /// are an ordinary element, so they go out LSB first — T1; `§3.2.5`'s
    /// "most-significant bit first" sentence describes the numeral.
    fn writeBits(self: *BitWriter, value: u32, n: u5) error{BufferTooSmall}!void {
        assert(n <= 32);
        assert(n == 32 or value >> n == 0);
        assert(self.bit_count < 8);
        self.bits |= @as(u64, value) << self.bit_count;
        self.bit_count += n;
        try self.flushBytes();
    }

    /// Write a Huffman code, MSB-of-code first (`§3.1.1`). `code` carries the
    /// wire bits (see `wireBits`), never the numeral.
    fn writeCode(self: *BitWriter, code: Code) error{BufferTooSmall}!void {
        self.bits |= @as(u64, code.bits) << self.bit_count;
        self.bit_count += code.len;
        try self.flushBytes();
    }

    /// Flush whole bytes into `target`. `error.BufferTooSmall` when the target
    /// is exhausted — which cannot happen when `target` is sized via
    /// `maxCompressedLength` (README, "Contracts").
    fn flushBytes(self: *BitWriter) error{BufferTooSmall}!void {
        while (self.bit_count >= 8) {
            if (self.pos == self.target.len) return error.BufferTooSmall;
            self.target[self.pos] = @truncate(self.bits);
            self.pos += 1;
            self.bits >>= 8;
            self.bit_count -= 8;
        }
    }

    /// Pad with zero bits to the next byte boundary (`§3.2.4`: a stored block
    /// ignores the bits up to the boundary; a decoder must not require them to
    /// be zero).
    fn alignToByte(self: *BitWriter) error{BufferTooSmall}!void {
        const pad: u4 = @intCast((8 - self.bitsWritten() % 8) % 8);
        if (pad != 0) try self.writeBits(0, pad);
    }

    /// Flush the final partial byte, zero-padded (README, "The stream
    /// format").
    pub fn finish(self: *BitWriter) error{BufferTooSmall}!void {
        if (self.bit_count == 0) return;
        if (self.pos == self.target.len) return error.BufferTooSmall;
        self.target[self.pos] = @truncate(self.bits);
        self.pos += 1;
        self.bits = 0;
        self.bit_count = 0;
    }
};

/// The candidate's index in `source` when the table entry is a legal match
/// source with the 4 bytes at `s_index`, or null. Entries are absolute
/// stream positions (wrapping u32, `base`-relative to `source[0]`; the
/// caller passes `s_absolute = base +% s_index`). A legal source sits before
/// `s` (a distance of at least 1), within `history_len` (`§3.2.5`), and not
/// before the window's front. The wrapping subtraction makes a stale entry
/// — one the window slid past, or a zero-initialized slot — fail the
/// distance cap; a wrapped-around entry (a stream past 4 GiB) still lands
/// in-window, where the 4-byte confirm decides. Either way no candidate
/// outside the window is ever emitted.
inline fn matchCandidate(
    source: []const u8,
    s_index: usize,
    s_absolute: u32,
    entry: u32,
    expect: u32,
    comptime windowed: bool,
) ?usize {
    const distance = s_absolute -% entry;
    // One unsigned check rejects both 0 (wrapping to max) and every distance
    // past the cap (`§3.2.5`).
    if (distance -% 1 >= history_len) return null;
    // A windowed caller (the streaming Writer) drops bytes from the front, so
    // an entry can name a position no longer in `source`; the one-shot paths
    // never drop, and every entry is a position the scan already passed.
    if (windowed and distance > s_index) return null;
    const candidate = s_index - distance;
    if (load32(source, candidate) != expect) return null; // the 4-byte confirm
    return candidate;
}

/// Number of bytes of `source[a..]` and `source[b..]` that match, up to
/// `limit`. Compares 8 bytes at a time and uses `@ctz` on the first differing
/// u64 to find the exact mismatch byte. The caller guarantees `a < b` and that
/// neither read runs past `limit` (the 8-byte loop bounds `b`).
fn matchLength(source: []const u8, a: usize, b: usize, limit: usize) usize {
    var p = a;
    var q = b;
    while (q + 8 <= limit) {
        const diff = load64(source, p) ^ load64(source, q);
        if (diff != 0) return p - a + (@ctz(diff) >> 3);
        p += 8;
        q += 8;
    }
    while (q < limit) : ({
        p += 1;
        q += 1;
    }) {
        if (source[p] != source[q]) return p - a;
    }
    return p - a;
}

/// Emit `literal` as fixed-Huffman literal codes. Returns false when the
/// payload would reach the stored form's payload — `§3.2.4`'s 32 + 8 x len bits
/// — at which point the block is stored instead (README, "Encoder").
///
/// The check runs before the write, so a bailing block has never written past
/// the stored form's own bytes.
fn emitLiterals(
    literal: []const u8,
    w: *BitWriter,
    payload: *u64,
    payload_limit: u64,
) error{BufferTooSmall}!bool {
    for (literal) |byte| {
        const code = fixed_literal_codes[byte];
        if (payload.* + code.len >= payload_limit) return false;
        payload.* += code.len;
        try w.writeCode(code);
    }
    return true;
}

/// Emit one match as a `§3.2.5` length symbol and distance symbol, each with
/// its extra bits (LSB-of-value first). Lengths above 258 split into chunks:
/// the last chunk drops to 255 when a 258 would leave a 1- or 2-byte tail,
/// which cannot be coded (the shortest length symbol is 3). Returns false on
/// the stored-form threshold, as `emitLiterals`.
fn emitMatch(
    w: *BitWriter,
    distance: usize,
    length: usize,
    payload: *u64,
    payload_limit: u64,
) error{BufferTooSmall}!bool {
    assert(distance >= 1);
    assert(distance <= history_len);
    assert(length >= min_length);

    const d = distanceSymbol(distance);
    const distance_code = fixed_distance_codes[d.symbol];
    var remaining = length;
    while (true) {
        const chunk = if (remaining > 258 and remaining - 258 < min_length)
            255
        else
            @min(remaining, 258);
        const l = length_symbols[chunk];
        const length_code = fixed_literal_codes[l.symbol];
        const cost = @as(u64, length_code.len) + l.extra_bits +
            distance_code.len + d.extra_bits;
        if (payload.* + cost >= payload_limit) return false;
        payload.* += cost;

        try w.writeCode(length_code);
        try w.writeBits(l.extra_value, l.extra_bits);
        try w.writeCode(distance_code);
        try w.writeBits(d.extra, d.extra_bits);

        remaining -= chunk;
        if (remaining == 0) return true;
    }
}

/// `§3.2.4` — a stored block: BFINAL and BTYPE=00, then skip to the next byte
/// boundary, then LEN and NLEN (u16 little-endian, NLEN the one's complement of
/// LEN) and LEN raw bytes. This is the fallback that makes
/// `maxCompressedLength` provable: no block ever exceeds its stored form.
pub fn emitStoredBlock(w: *BitWriter, block: []const u8) error{BufferTooSmall}!void {
    assert(block.len <= max_block_size);
    try w.writeBits(0, 1); // BFINAL: the ending carries it (README, T4)
    try w.writeBits(0, 2); // BTYPE = 00, stored
    try w.alignToByte();
    const len: u16 = @intCast(block.len);
    try w.writeBits(len, 16);
    try w.writeBits(~len, 16);
    // Byte-aligned after LEN/NLEN: the payload is a straight copy.
    assert(w.bit_count == 0);
    if (w.target.len - w.pos < block.len) return error.BufferTooSmall;
    fastmem.copy(u8, w.target[w.pos..][0..block.len], block);
    w.pos += block.len;
}

/// Hash the block's history into the table, every `stride` positions, so a
/// match may reach across the block boundary (`§3.2.3`). Entries are
/// absolute stream positions (`base` is the stream position of `source[0]`),
/// matching the scan's stores. The 8-byte load reads a few bytes past the
/// hashed 5, so the loop stops where that load would leave `source`.
fn primeTable(
    source: []const u8,
    window_start: usize,
    block_start: usize,
    table: *FinderTable,
    base: u32,
    comptime stride: usize,
) void {
    var pos = window_start;
    while (pos < block_start and pos + 8 <= source.len) : (pos += stride) {
        table[hash5(load64(source, pos))] = base +% @as(u32, @truncate(pos));
    }
}

/// Encode one block's payload as fixed-Huffman symbols, greedily. Returns
/// false when the payload reached the stored form's payload (the README's bail
/// threshold) — the caller rewinds and stores the block.
///
/// The scan cascade is the klauspost `fastEncL1` shape: hash three positions
/// per step, confirm 4 bytes, extend backwards over the literals already
/// scanned and forwards to the block's end, and accelerate the skip as the
/// distance since the last emit grows.
///
/// `table` is the caller's (see `FinderTable`): the streaming Writer and the
/// one-shot `compress` persist one table across the stream's blocks, so the
/// per-block cost is the history prime alone, never a 128-KiB re-zero; `base`
/// is the absolute stream position of `source[0]`. `compressBlock` (the pub
/// block-at-a-time entry) passes a fresh, densely primed table.
fn encodeFixedBlock(
    source: []const u8,
    block_start: usize,
    block_end: usize,
    w: *BitWriter,
    table: *FinderTable,
    base: u32,
    comptime prime_stride: usize,
    comptime windowed: bool,
) error{BufferTooSmall}!bool {
    const block_len = block_end - block_start;
    // §3.2.4 — the stored alternative's payload is 32 + 8 x len bits; a block
    // is emitted fixed only while its payload stays below that (README,
    // "Encoder"). The end-of-block symbol is part of the payload and is always
    // emitted last, so its 7 bits are reserved up front.
    const payload_limit: u64 = @as(u64, block_len) * 8 + 32;
    var payload: u64 = fixed_literal_codes[256].len;

    // The finder's window: this block's history followed by the block itself,
    // so matches cross block boundaries exactly as the format allows
    // (`§3.2.3`). A block too small to scan needs no priming either: its
    // bytes are all literals, and its own history range is primed afresh by
    // the next scanning block.
    const window_start = block_start - @min(block_start, history_len);

    var next_emit = block_start;
    var s = block_start;
    if (block_len >= min_match_block_size) {
        if (prime_stride != 0) {
            primeTable(source, window_start, block_start, table, base, prime_stride);
        }
        // Stop scanning this far from the end so the 8-byte loads and the
        // 3-position cascade stay in bounds; the tail becomes literals.
        const s_limit = block_end - input_margin;
        var cv = load64(source, s);

        scan: while (true) {
            var candidate: usize = 0;
            // Inner scan: three hash slots per step until a 4-byte confirm.
            inner: while (true) {
                const s_absolute = base +% @as(u32, @truncate(s));
                const h0 = hash5(cv);
                const h1 = hash5(cv >> 8);
                const h2 = hash5(cv >> 16);
                const e0 = table[h0];
                table[h0] = s_absolute;
                const e1 = table[h1];
                table[h1] = s_absolute +% 1;
                const e2 = table[h2];
                table[h2] = s_absolute +% 2;

                if (matchCandidate(source, s, s_absolute, e0, @truncate(cv), windowed)) |c| {
                    candidate = c;
                    break :inner;
                }
                const hit1 = matchCandidate(
                    source,
                    s + 1,
                    s_absolute +% 1,
                    e1,
                    @truncate(cv >> 8),
                    windowed,
                );
                if (hit1) |c| {
                    candidate = c;
                    s += 1;
                    break :inner;
                }
                const hit2 = matchCandidate(
                    source,
                    s + 2,
                    s_absolute +% 2,
                    e2,
                    @truncate(cv >> 16),
                    windowed,
                );
                if (hit2) |c| {
                    candidate = c;
                    s += 2;
                    break :inner;
                }

                // No match here: accelerate the skip with the distance since
                // the last emit, so incompressible regions are crossed fast.
                const next_s = s + 3 + ((s - next_emit) >> 5);
                if (next_s > s_limit) break :scan;
                cv = load64(source, next_s);
                s = next_s;
            }

            // Backward extension: the match may start before the hash hit,
            // over the literals already scanned, shrinking the literal run.
            while (s > next_emit and candidate > window_start and
                source[candidate - 1] == source[s - 1])
            {
                s -= 1;
                candidate -= 1;
            }

            if (!try emitLiterals(source[next_emit..s], w, &payload, payload_limit)) return false;

            // The match, extended greedily to the block's end: a match may
            // never run past it, or the next block would emit the same bytes
            // again.
            const length = min_match_len +
                matchLength(source, candidate + min_match_len, s + min_match_len, block_end);
            if (!try emitMatch(w, s - candidate, length, &payload, payload_limit)) return false;
            s += length;
            next_emit = s;

            if (s > s_limit) break :scan;
            cv = load64(source, s);
        }
    }

    // The trailing bytes (and, for a block below the match-finding threshold,
    // the whole block) are literals.
    if (!try emitLiterals(source[next_emit..block_end], w, &payload, payload_limit)) return false;

    // §3.2.7 — every block is terminated by the end-of-block symbol 256.
    try w.writeCode(fixed_literal_codes[256]);
    return true;
}

/// `§3.2.3`, README "Divergences" T4 — the final empty fixed block every
/// stream ends with: BFINAL=1, BTYPE=01, end-of-block (`03 00` at a byte
/// boundary). One function, so the one-shot and streaming encoders cannot
/// drift: no data block carries BFINAL, which is what makes a mid-stream
/// `flush` safe.
pub fn writeFinalEmptyBlock(w: *BitWriter) error{BufferTooSmall}!void {
    try w.writeBits(1, 1);
    try w.writeBits(1, 2);
    try w.writeCode(fixed_literal_codes[256]);
}

/// The streaming Writer's block encode: the shared block path over the
/// Writer's persistent table (zeroed once per stream), with the stream's
/// priming stride. `base` is the absolute stream position of `source[0]` —
/// the Writer's window base.
pub fn compressBlockStream(
    source: []const u8,
    block_start: usize,
    block_end: usize,
    w: *BitWriter,
    table: *FinderTable,
    base: u32,
) error{BufferTooSmall}!void {
    try compressBlockStateful(
        source,
        block_start,
        block_end,
        w,
        table,
        base,
        stream_prime_stride,
        true,
    );
}

/// The block-at-a-time encode over a caller-managed finder table: the shared
/// internal entry behind `compressBlock` (fresh table, dense prime), the
/// one-shot `compress`, and the streaming Writer (persistent table,
/// `stream_prime_stride`). `base` is the absolute stream position of
/// `source[0]`; entries older than the window fail the distance cap, so the
/// table needs no clearing between blocks.
fn compressBlockStateful(
    source: []const u8,
    block_start: usize,
    block_end: usize,
    w: *BitWriter,
    table: *FinderTable,
    base: u32,
    comptime prime_stride: usize,
    comptime windowed: bool,
) error{BufferTooSmall}!void {
    const start = w.snapshot();

    // §3.2.3 — BFINAL is clear on every data block: the stream ends with a
    // final empty fixed block (README, "Divergences" T4). BTYPE = 01, whose
    // two bits go out LSB-of-value first.
    try w.writeBits(0, 1);
    try w.writeBits(1, 2);

    if (!try encodeFixedBlock(
        source,
        block_start,
        block_end,
        w,
        table,
        base,
        prime_stride,
        windowed,
    )) {
        // The fixed payload did not beat the stored form: rewind the block's
        // bits and store it. Storing fits wherever the fixed attempt did —
        // `maxCompressedLength` reserves 5 bytes per block plus the ending.
        w.restore(start);
        try emitStoredBlock(w, source[block_start..block_end]);
    }
}

/// Compress `source` as one raw deflate stream into `target`. Returns bytes
/// written; `error.BufferTooSmall` when `target` is too small — size it via
/// `maxCompressedLength`. Zero heap allocation.
///
/// The stream is self-delimiting: BFINAL on the final empty block ends it
/// (`§3.2.3`), and every data block is fixed Huffman or stored. The same input
/// always produces the same bytes.
/// Compression level. Every numeric zlib-style level is addressable
/// (`.{ .level = .@"5" }`); pretty names reserve the tuned modes:
///
///   - `.fast` — the fixed-Huffman match-finding mode, the tuned default.
///   - `.ratio` — dynamic Huffman (the later ratio mode). Unimplemented
///     today: selecting it is `error.Unimplemented`, never silent aliasing.
///   - `.@"0"` — stored blocks only, the format's passthrough level.
///   - `.@"1"`..`.@"9"` — the numeric levels; today they all tune to
///     `.fast` until more tuned modes exist (stated, not hidden).
pub const Level = enum {
    fast,
    ratio,
    @"0",
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
};

/// Encoder configuration. `.{}` is the default: the fast level.
pub const Options = struct {
    level: Level = .fast,
};

/// Compress `source` as one raw deflate stream into `target`. Returns bytes
/// written; `error.BufferTooSmall` when `target` is too small — size it via
/// `maxCompressedLength`. Zero heap allocation.
///
/// The stream is self-delimiting: BFINAL on the final empty block ends it
/// (`§3.2.3`), and every data block is fixed Huffman or stored. The same
/// input and options always produce the same bytes.
pub fn compress(
    source: []const u8,
    target: []u8,
    options: Options,
) error{ BufferTooSmall, Unimplemented }!usize {
    if (options.level == .ratio) return error.Unimplemented;
    const stored_only = options.level == .@"0";

    var w: BitWriter = .{ .target = target };

    // One finder table for the whole stream, zeroed once (`FinderTable`):
    // entries are absolute source positions, so the per-block cost is the
    // strided history prime alone.
    var table: FinderTable = undefined;
    fastmem.set(u32, &table, 0);

    var block_start: usize = 0;
    while (block_start < source.len) {
        const block_end = @min(block_start + max_block_size, source.len);
        if (stored_only) {
            try emitStoredBlock(&w, source[block_start..block_end]);
        } else {
            try compressBlockStateful(
                source,
                block_start,
                block_end,
                &w,
                &table,
                0,
                stream_prime_stride,
                false,
            );
        }
        block_start = block_end;
    }

    try writeFinalEmptyBlock(&w);
    try w.finish();

    // The README's sizing contract, as a postcondition: the stored fallback
    // and the block split keep every stream inside `maxCompressedLength`.
    assert(w.pos <= maxCompressedLength(source.len));
    return w.pos;
}

// ---------------------------------------------------------------------------
// Tests. Every decode goes through the landed decoder (decode.zig), with the
// sentinel overrun rule: the target is pre-filled and the bytes past the
// decoded length must be untouched.
// ---------------------------------------------------------------------------

/// The final empty fixed block's ten bits, in wire order (LSB of this value is
/// the first bit on the wire): BFINAL=1, BTYPE=01, then the end-of-block code.
/// Assert the stream's last block is the final empty fixed block (README,
/// "Divergences" T4): bits `1,1,0,0,0,0,0,0,0,0` — BFINAL=1, BTYPE=01,
/// end-of-block — zero-padded to the byte boundary. The ending's start depends
/// on the last data block's bit offset, so it is located from the stream's
/// last set bit: that is the ending's BTYPE low bit, and everything after it
/// (the end-of-block's seven zeros and the padding) is clear. Shared with the
/// Compress `input`, check the sizing contract and the T4 ending, then decode
/// with the landed decoder and prove the bytes past the decoded length are
/// untouched.
fn roundTrip(input: []const u8) !void {
    const allocator = testing.allocator;
    const bound = maxCompressedLength(input.len);
    const comp = try allocator.alloc(u8, bound);
    defer allocator.free(comp);
    const clen = try compress(input, comp, .{});
    try testing.expect(clen <= bound);
    try golden.expectFinalEmptyBlock(comp[0..clen]);

    const target = try allocator.alloc(u8, input.len + sentinel.len);
    defer allocator.free(target);
    sentinel.fill(target);
    const n = try decode.decompress(comp[0..clen], target);
    try testing.expectEqual(input.len, n);
    try testing.expectEqualSlices(u8, input, target[0..n]);
    try sentinel.expect(target, n);
}

/// Corpus shapes, the same set the bench uses: repetitive text, PRNG bytes
/// (incompressible, so the stored fallback runs), markup, a single-byte run,
/// and a structured-plus-random batch.
const Shape = enum { text, random, html, rle, mixed };

fn makeShape(allocator: mem.Allocator, shape: Shape, len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    switch (shape) {
        .text => {
            const phrase = "the quick brown fox jumps over the lazy dog. ";
            var i: usize = 0;
            while (i < len) {
                const n = @min(phrase.len, len - i);
                fastmem.copy(u8, buf[i..][0..n], phrase[0..n]);
                i += n;
            }
        },
        .random => {
            var rng: DefaultPrng = .init(0xC0FFEE);
            for (buf) |*b| b.* = rng.random().int(u8);
        },
        .html => {
            const phrase = "<div class=\"row\"><span>hello</span><span>flate</span></div>";
            var i: usize = 0;
            while (i < len) {
                const n = @min(phrase.len, len - i);
                fastmem.copy(u8, buf[i..][0..n], phrase[0..n]);
                i += n;
            }
        },
        .rle => fastmem.set(u8, buf, 0x41),
        .mixed => {
            var rng: DefaultPrng = .init(0x5A4BEEF);
            for (buf, 0..) |*b, i| b.* = @truncate(rng.random().int(u8) ^ @as(u8, @truncate(i)));
        },
    }
    return buf;
}

test "compress: options — every implemented level round-trips" {
    // Levels are addressable by number and by name (`.{ .level = .@"5" }`);
    // every implemented level must produce a stream our decoder decodes, and
    // `.{}` is the fast default.
    var comp: [4096]u8 = undefined;
    var decoded: [4096]u8 = undefined;
    const input = "the quick brown fox jumps over the lazy dog. " ** 8;

    for ([_]Level{ .fast, .@"0", .@"1", .@"5", .@"9" }) |level| {
        const n = try compress(input, &comp, .{ .level = level });
        const dn = try decode.decompress(comp[0..n], &decoded);
        try testing.expectEqualSlices(u8, input, decoded[0..dn]);
    }

    // The reserved seat: dynamic huffman is unimplemented, never silent.
    try testing.expectError(error.Unimplemented, compress(input, &comp, .{ .level = .ratio }));
}

test "compress: the stored-only level emits stored blocks" {
    // `.{ .level = .@"0" }` is the format's passthrough: every data block is
    // stored (`§3.2.4`) — no match finding, no huffman codes.
    var comp: [64]u8 = undefined;
    const n = try compress("hello, flate!", &comp, .{ .level = .@"0" });
    // 1 header byte (BFINAL=0, BTYPE=00, pad — our ending carries BFINAL,
    // README T4) + LEN/NLEN (4) + 13 data + the 03 00 ending (2) = 20.
    // zlib's level 0 sets BFINAL on the stored block instead (19) — both
    // are valid streams; ours shares the single T4 ending with every level.
    try testing.expectEqual(@as(usize, 20), n);
    var decoded: [16]u8 = undefined;
    const dn = try decode.decompress(comp[0..n], &decoded);
    try testing.expectEqualSlices(u8, "hello, flate!", decoded[0..dn]);
}

test "matchCandidate: the position edge cases of the absolute-entry arithmetic" {
    // A uniform source (every byte equal) makes the 4-byte confirm always
    // pass, so each row isolates the accept/reject logic: distance 0,
    // exactly history_len, past the cap, a wrapped-around 4-GiB entry
    // landing in-window, an entry ahead of `s`, and the windowed front.
    // Spec: rfc1951-deflate.txt §3.2.5 (a distance is at most 32768).
    var src_buf: [70_000]u8 = undefined;
    fastmem.set(u8, &src_buf, 'a');
    const src: []const u8 = &src_buf;
    const s_index: usize = 40_000;
    const s_absolute: u32 = 40_000;
    const e = load32(src, s_index);

    // Distance 0 (entry == s): rejected.
    try testing.expectEqual(@as(?usize, null), matchCandidate(
        src,
        s_index,
        s_absolute,
        s_absolute,
        e,
        false,
    ));
    // Exactly history_len: accepted.
    try testing.expectEqual(
        @as(?usize, s_index - history_len),
        matchCandidate(src, s_index, s_absolute, s_absolute - history_len, e, false),
    );
    // history_len + 1: rejected.
    try testing.expectEqual(@as(?usize, null), matchCandidate(
        src,
        s_index,
        s_absolute,
        s_absolute - history_len - 1,
        e,
        false,
    ));
    // A wrapped-around entry: distance 16 lands in-window.
    try testing.expectEqual(
        @as(?usize, s_index - 16),
        matchCandidate(src, s_index, 5, std.math.maxInt(u32) - 10, e, false),
    );
    // An entry ahead of `s` (wraps to a huge distance): rejected.
    try testing.expectEqual(
        @as(?usize, null),
        matchCandidate(src, s_index, 100, 101, e, false),
    );
    // Windowed: a distance past the source front (into dropped history) is
    // rejected; equal to the front names position 0.
    try testing.expectEqual(
        @as(?usize, null),
        matchCandidate(src, 10, 50_010, 100, e, true),
    );
    try testing.expectEqual(
        @as(?usize, 0),
        matchCandidate(src, 10, 50_010, 50_000, e, true),
    );
}

test "matchCandidate: a garbage-filled table stays exact on the windowed path" {
    // The table is only hints: a stale entry fails the cap, a wrapped entry
    // lands in-window where the confirm decides, and the windowed check
    // rejects dropped history — every emitted match is byte-verified.
    var src_buf: [70_000]u8 = undefined;
    fastmem.set(u8, &src_buf, 'a');
    const src: []const u8 = &src_buf;
    var rng: DefaultPrng = .init(0xDEADBEEF);
    for (0..64) |i| {
        const s_index: usize = 1 + (i * 1000) % 60_000;
        const s_absolute: u32 = @truncate(500_000 + s_index);
        const entry = rng.random().int(u32);
        const candidate = matchCandidate(src, s_index, s_absolute, entry, 0, true);
        if (candidate) |c| {
            // Whatever the entry, an accepted candidate names a real
            // in-window position with four equal bytes.
            try testing.expect(c < s_index);
            try testing.expect(s_index - c <= history_len);
            try testing.expectEqual(load32(src, c), load32(src, s_index));
        }
    }
}

test "compress: empty input is the final empty block" {
    // Spec: rfc1951-deflate.txt §3.2.3 — "BFINAL is set if and only if this is
    // the last block of the data set", and README "Divergences" T4: the stream
    // ends with the empty fixed block `03 00`. Spec: §3.2.6 — the fixed
    // end-of-block code is seven zero bits.
    var target: [4]u8 = undefined;
    const n = try compress("", &target, .{});
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x00 }, target[0..n]);
    try testing.expectEqual(@as(usize, 2), maxCompressedLength(0));

    var decoded: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try decode.decompress(target[0..n], &decoded));
}

test "compress: maxCompressedLength formula" {
    // README, "Contracts": input_len + 5 * ceil(input_len / 65535) + 2, with
    // §3.2.4's 65535-byte stored LEN cap as the block size.
    try testing.expectEqual(@as(usize, 2), maxCompressedLength(0));
    try testing.expectEqual(@as(usize, 1 + 5 + 2), maxCompressedLength(1));
    try testing.expectEqual(@as(usize, 65535 + 5 + 2), maxCompressedLength(65535));
    try testing.expectEqual(@as(usize, 65536 + 10 + 2), maxCompressedLength(65536));
    try testing.expectEqual(@as(usize, 131070 + 10 + 2), maxCompressedLength(131070));
    try testing.expectEqual(@as(usize, 131071 + 15 + 2), maxCompressedLength(131071));
    try testing.expectEqual(@as(usize, max_block_size), 65535);
    try testing.expectEqual(@as(usize, history_len), 32768);
}

test "compress: §3.2.4 stored fallback for incompressible input" {
    // Spec: rfc1951-deflate.txt §3.2.4 — a stored block is BFINAL/BTYPE=00
    // followed by the byte-aligned LEN/NLEN and the raw bytes. Random data
    // cannot beat the stored form, so the whole block is stored: the output is
    // input_len + 5 (one block) + 2 (the ending).
    const allocator = testing.allocator;
    const input = try makeShape(allocator, .random, 4096);
    defer allocator.free(input);
    const comp = try allocator.alloc(u8, maxCompressedLength(input.len));
    defer allocator.free(comp);
    const clen = try compress(input, comp, .{});

    try testing.expectEqual(@as(u8, 0), comp[0] & 0b1); // BFINAL clear on data
    try testing.expectEqual(@as(u8, 0b00), (comp[0] >> 1) & 0b11); // BTYPE stored
    try testing.expectEqual(input.len + 5 + 2, clen);
    try roundTrip(input);
}

test "compress: round trips through our decoder (shapes)" {
    const allocator = testing.allocator;
    inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
        for ([_]usize{ 0, 1, 3, 4, 13, 64, 1000, 8192 }) |len| {
            const input = try makeShape(allocator, shape, len);
            defer allocator.free(input);
            roundTrip(input) catch |err| {
                std.debug.print("FAIL: shape {s} len {d}\n", .{ @tagName(shape), len });
                return err;
            };
        }
    }
}

test "compress: round trips across block boundaries" {
    // Sizes around the 65535-byte split, where the second block's matches may
    // reach back into the first (`§3.2.3`: "the backward distance may cross one
    // or more block boundaries").
    const allocator = testing.allocator;
    const sizes = [_]usize{
        65534, 65535, 65536, 65537, 131070, 131071, 131072, 196605, 196606,
    };
    inline for (.{ Shape.text, Shape.random, Shape.rle, Shape.mixed }) |shape| {
        for (sizes) |len| {
            const input = try makeShape(allocator, shape, len);
            defer allocator.free(input);
            roundTrip(input) catch |err| {
                std.debug.print("FAIL: shape {s} len {d}\n", .{ @tagName(shape), len });
                return err;
            };
        }
    }
}

test "compress: many blocks round trip (1 MiB)" {
    // Sixteen blocks of text (cross-block matches across many boundaries) and
    // of incompressible bytes (all stored), with the sizing contract checked
    // end to end.
    const allocator = testing.allocator;
    inline for (.{ Shape.text, Shape.mixed }) |shape| {
        const input = try makeShape(allocator, shape, 1 << 20);
        defer allocator.free(input);
        roundTrip(input) catch |err| {
            std.debug.print("FAIL: shape {s} len 1 MiB\n", .{@tagName(shape)});
            return err;
        };
    }
}

test "compress: maxCompressedLength bounds every emission" {
    // README, "Contracts" — "`compress` never expands past it": every emission
    // fits a target of exactly `maxCompressedLength`, across the block-boundary
    // sizes and the adversarial shapes (a compressible block followed by an
    // incompressible one, which is where the stored fallback's alignment is
    // worst).
    const allocator = testing.allocator;
    const sizes = [_]usize{
        0,     1,     2,     3,     4,      13,     100,    1024,
        65534, 65535, 65536, 65537, 131070, 131071, 131072, 196605,
    };
    inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
        for (sizes) |len| {
            const input = try makeShape(allocator, shape, len);
            defer allocator.free(input);
            const bound = maxCompressedLength(len);
            const comp = try allocator.alloc(u8, bound);
            defer allocator.free(comp);
            const clen = compress(input, comp, .{}) catch |err| {
                std.debug.print(
                    "FAIL: {s} len {d}: {s}\n",
                    .{ @tagName(shape), len, @errorName(err) },
                );
                return err;
            };
            try testing.expect(clen <= bound);
            try golden.expectFinalEmptyBlock(comp[0..clen]);
        }
    }

    // A compressible first block followed by an incompressible tail: the tail
    // is stored after a fixed block, which is the misaligned-stored case.
    inline for (.{ 1, 2, 3, 7, 8, 9, 15, 16, 17, 24, 25, 31, 33, 63, 100 }) |tail| {
        const input = try allocator.alloc(u8, 65535 + tail);
        defer allocator.free(input);
        fastmem.set(u8, input[0..65535], 0x41);
        var rng: DefaultPrng = .init(0xFEEDFACE);
        for (input[65535..]) |*b| b.* = rng.random().int(u8);
        const bound = maxCompressedLength(input.len);
        const comp = try allocator.alloc(u8, bound);
        defer allocator.free(comp);
        const clen = try compress(input, comp, .{});
        try testing.expect(clen <= bound);
        try roundTrip(input);
    }
}

test "compress: a target smaller than the output is BufferTooSmall" {
    // README, "API" — `error.BufferTooSmall` when `target` is too small.
    var target: [2]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, compress("hello, flate!", &target, .{}));
    // ... and the empty stream is the smallest legal output.
    try testing.expectEqual(@as(usize, 2), try compress("", &target, .{}));
}

test "compress: deterministic" {
    // README, "Encoder" — "the same input and the same block split produce the
    // same bytes".
    const allocator = testing.allocator;
    const input = try makeShape(allocator, .mixed, 70000);
    defer allocator.free(input);
    const bound = maxCompressedLength(input.len);
    const first = try allocator.alloc(u8, bound);
    defer allocator.free(first);
    const second = try allocator.alloc(u8, bound);
    defer allocator.free(second);
    const a = try compress(input, first, .{});
    const b = try compress(input, second, .{});
    try testing.expectEqual(a, b);
    try testing.expectEqualSlices(u8, first[0..a], second[0..b]);
}

test "compress: golang/go deflateTests inputs round trip" {
    // golden.zig's `deflate_cases` carry Go's `in` bytes alongside streams that
    // decode to them; the encoder is judged the other way round: its own stream
    // for the same input must decode to it (deflate mandates no canonical
    // form).
    for (golden.deflate_cases) |tc| {
        roundTrip(tc.want) catch |err| {
            std.debug.print("FAIL: deflateTests input len {d}\n", .{tc.want.len});
            return err;
        };
    }
}

test "compress: golang/go testdata huffman-* inputs round trip" {
    // 242 KB of reference data (Go's `writeBlockHuff` inputs), through our
    // encoder and our decoder: the round trip covers real text, digits of pi,
    // random tails, and the degenerate 64-KiB single-byte runs.
    for (golden.huffman_fixtures) |fixture| {
        roundTrip(fixture.input) catch |err| {
            std.debug.print("FAIL: {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "compress: a match reaches back across a block boundary" {
    // Spec: rfc1951-deflate.txt §3.2.3 — "the backward distance may cross one
    // or more block boundaries". The second block is a copy of a window of the
    // first, so only the finder's history priming can find it: without
    // cross-block history the block is incompressible and costs a stored block
    // (31773 bytes). The distance is deliberately not 32768, which the
    // zero-initialized table's window_start entry would satisfy by accident.
    const allocator = testing.allocator;
    const copy_from = 65535 - history_len + 1000;
    const input = try allocator.alloc(u8, 65535 + (65535 - copy_from));
    defer allocator.free(input);
    var rng: DefaultPrng = .init(0xBADD_CAFE);
    for (input[0..65535]) |*b| b.* = rng.random().int(u8);
    fastmem.copy(u8, input[65535..], input[copy_from..65535]);

    const comp = try allocator.alloc(u8, maxCompressedLength(input.len));
    defer allocator.free(comp);
    const clen = try compress(input, comp, .{});
    // The first block is incompressible (stored: 65540 bytes); the second is
    // one match of 31768 bytes (~125 chunks of 258).
    try testing.expect(clen > 65540);
    try testing.expect(clen < 67000);
    try roundTrip(input);
}

test "compress: RFC 1951 and flate-notes micro-example outputs round trip" {
    // The decode-side micro-fixtures' payloads as encoder inputs: the RFC's
    // overlap example, the repeat-code example, std's micro-streams, and the
    // notes' two streams.
    for (golden.micro_cases) |tc| {
        roundTrip(tc.want) catch |err| {
            std.debug.print("FAIL: {s}\n", .{tc.desc});
            return err;
        };
    }
}

test "fixed tables: §3.2.6's numerals are the canonical construction" {
    // Spec: rfc1951-deflate.txt §3.2.6 gives the fixed codes as numerals;
    // §3.2.2's construction assigns codes from lengths alone. The encoder's
    // table holds the numerals (pre-reversed for the wire) — this proves the
    // two agree symbol for symbol, including 286-287, which "will never
    // actually occur in the compressed data, but participate in the code
    // construction".
    var lens: [288]u4 = undefined;
    for (0..144) |i| lens[i] = 8;
    for (144..256) |i| lens[i] = 9;
    for (256..280) |i| lens[i] = 7;
    for (280..288) |i| lens[i] = 8;

    var count: [16]u16 = @splat(0);
    for (lens) |len| count[len] += 1;
    var next_code: [16]u16 = @splat(0);
    var code: u16 = 0;
    for (1..16) |bits| {
        code = (code + count[bits - 1]) << 1;
        next_code[bits] = code;
    }

    for (lens, 0..) |len, symbol| {
        const expected = wireBits(next_code[len], len);
        next_code[len] += 1;
        try testing.expectEqual(expected, fixed_literal_codes[symbol].bits);
        try testing.expectEqual(len, fixed_literal_codes[symbol].len);
    }
    // §3.2.6 — "Distance codes 0-31 are represented by (fixed-length) 5-bit
    // codes"; the numeral is the symbol.
    for (fixed_distance_codes, 0..) |entry, symbol| {
        try testing.expectEqual(@as(u5, 5), entry.len);
        try testing.expectEqual(wireBits(@intCast(symbol), 5), entry.bits);
    }
}

test "emit: flate-notes §3.2 stream 1 packing, byte-exact modulo BFINAL" {
    // Spec: docs/research/flate-notes.md §3.2, stream 1 — "literal 'A', match
    // length 20 (code 269 = base 19 + extra 1) at distance 1 (code 0), EOB",
    // packed as `73 c4 06 00` with BFINAL set on that block. Our encoder never
    // sets BFINAL on a data block (T4), so the same tokens are `72 c4 06 00`
    // followed by the final empty block: the packing — header bits, the
    // MSB-of-code literal and length codes, and the LSB-of-value length extra
    // bits — is byte-exact otherwise. The finder produces exactly these
    // tokens: one literal 'A', then a 20-byte match at distance 1.
    const allocator = testing.allocator;
    const input = [_]u8{'A'} ** 21;
    const comp = try allocator.alloc(u8, maxCompressedLength(input.len));
    defer allocator.free(comp);
    const clen = try compress(&input, comp, .{});
    const want = [_]u8{ 0x72, 0xc4, 0x06, 0x00, 0x03, 0x00 };
    try testing.expectEqualSlices(u8, &want, comp[0..clen]);
    try roundTrip(&input);

    // And the notes' own stream decodes to the same bytes through our decoder,
    // with BFINAL on its single block (golden.zig pins it too).
    var decoded: [32]u8 = undefined;
    const n = try decode.decompress(&[_]u8{ 0x73, 0xc4, 0x06, 0x00 }, &decoded);
    try testing.expectEqualSlices(u8, &input, decoded[0..n]);
}

test "emit: flate-notes §3.2 stream 2 tokens pack the distance extra bits LSB-first" {
    // Spec: docs/research/flate-notes.md §3.2, stream 2 — "70 literals 'A',
    // then match length 3 (code 257, no extra) at distance 67 (code 12 = base
    // 65 + extra value 2, bits [0,1,0,0,0] LSB-first), EOB", packed as the
    // golden.zig hex with BFINAL set on the block. Our greedy finder cannot
    // produce this token sequence (on a run of 'A' it takes the longer match at
    // distance 1), so the tokens are emitted directly here: this is the
    // distance-side T1 pin — an MSB-first reading of those extra bits would
    // give distance 73, past the 70-byte history.
    var target: [128]u8 = undefined;
    var w: BitWriter = .{ .target = &target };
    try w.writeBits(1, 1); // BFINAL, matching the notes' stream
    try w.writeBits(1, 2); // BTYPE = 01, fixed
    var payload: u64 = 0;
    const limit: u64 = std.math.maxInt(u64);
    const run = [_]u8{'A'} ** 70;
    try testing.expect(try emitLiterals(&run, &w, &payload, limit));
    try testing.expect(try emitMatch(&w, 67, 3, &payload, limit));
    try w.writeCode(fixed_literal_codes[256]);
    try w.finish();

    const notes_stream = [_]u8{
        0x73, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74,
        0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74,
        0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74,
        0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74,
        0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74,
        0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x04, 0x1a,
        0x01, 0x00,
    };
    try testing.expectEqualSlices(u8, &notes_stream, target[0..w.pos]);

    // The notes' stream decodes to 73 bytes of 'A' (70 literals + a 3-byte
    // match from distance 67); so must ours.
    var decoded: [80]u8 = undefined;
    sentinel.fill(&decoded);
    const n = try decode.decompress(target[0..w.pos], &decoded);
    try testing.expectEqual(@as(usize, 73), n);
    for (decoded[0..n]) |byte| try testing.expectEqual(@as(u8, 'A'), byte);
    try sentinel.expect(&decoded, n);
}

test "emit: long matches split at 258 with a legal tail" {
    // README, "Encoder" — "Long matches split at 258 with the final chunk kept
    // >= 3: the last chunk drops to 255 when a 258 would leave a 1- or 2-byte
    // tail, which cannot be coded (the shortest length symbol is 3)".
    // §3.2.5 — 258 is code 285, the one length code with zero extra bits.
    try testing.expectEqual(@as(u16, 285), length_symbols[258].symbol);
    try testing.expectEqual(@as(u5, 0), length_symbols[258].extra_bits);
    try testing.expectEqual(@as(u16, 257), length_symbols[3].symbol);
    try testing.expectEqual(@as(u16, 284), length_symbols[257].symbol);
    try testing.expectEqual(@as(u16, 269), length_symbols[20].symbol);
    try testing.expectEqual(@as(u16, 1), length_symbols[20].extra_value);

    // Every length 3-258 must have a symbol whose base + extra reconstructs it.
    for (3..259) |length| {
        const l = length_symbols[length];
        const base = length_bases[l.symbol - 257];
        try testing.expectEqual(@as(u16, @intCast(length)), base + l.extra_value);
        try testing.expect(l.extra_value < (@as(u32, 1) << l.extra_bits));
    }
    // Every distance 1-32768 likewise.
    for (1..history_len + 1) |distance| {
        const d = distanceSymbol(distance);
        try testing.expectEqual(
            @as(u16, @intCast(distance)),
            distance_bases[d.symbol] + d.extra,
        );
        try testing.expect(d.extra < (@as(u32, 1) << d.extra_bits));
    }

    // A run long enough to force the split, through the whole encoder.
    const allocator = testing.allocator;
    const input = try allocator.alloc(u8, 4000);
    defer allocator.free(input);
    fastmem.set(u8, input, 0x5A);
    try roundTrip(input);
}

test "compress: every length and distance code round trips" {
    // Sweep the encodable space: distances across all 30 codes (a pattern
    // repeated at each distance) and lengths across all 29 codes (runs of each
    // length), each through our encoder and our decoder. §3.2.5's tables.
    const allocator = testing.allocator;
    var input: [70000]u8 = undefined;
    var rng: DefaultPrng = .init(0x1234_5678);
    for (input[0..4096]) |*b| b.* = rng.random().int(u8);
    for (4096..input.len) |i| input[i] = input[i - 4096];

    const comp = try allocator.alloc(u8, maxCompressedLength(input.len));
    defer allocator.free(comp);
    const clen = try compress(&input, comp, .{});
    try testing.expect(clen <= maxCompressedLength(input.len));

    const back = try allocator.alloc(u8, input.len + sentinel.len);
    defer allocator.free(back);
    sentinel.fill(back);
    const n = try decode.decompress(comp[0..clen], back);
    try testing.expectEqual(input.len, n);
    try testing.expectEqualSlices(u8, input[0..n], back[0..n]);
    try sentinel.expect(back, n);

    // Runs of every length 3-258 at distance 1.
    for (3..259) |length| {
        const run = try allocator.alloc(u8, length + 1);
        defer allocator.free(run);
        fastmem.set(u8, run, 0x7E);
        try roundTrip(run);
    }
}
