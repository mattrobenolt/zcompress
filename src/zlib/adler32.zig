//! The zlib checksum state over a vectorized Adler-32 kernel.
//!
//! RFC 1950 §2.2 defines the trailer value: the Adler-32 of "the uncompressed
//! data (excluding any dictionary data)", stored "in most-significant-byte
//! first (network) order". The algorithm is `§8.2`: two sums mod 65521 — s1
//! the sum of all bytes (initialized to 1, "to make the length of the
//! sequence part of s2"), s2 the sum of all s1 values — combined as
//! `s2*65536 + s1`; the appendix's implementation shape is the deferred
//! modulo ("The modulo on unsigned long accumulators can be delayed for 5552
//! bytes").
//!
//! The kernel here keeps that deferred-modulo block structure (blocks of at
//! most 5552 bytes, one mod per block — the zlib NMAX bound keeps every
//! accumulator under 2^32) but replaces the per-byte `s1 += b; s2 += s1`
//! chain with vector arithmetic. Within a block of `len` bytes the two sums
//! are
//!
//!   s1 += Σ b_i                    (lane-wise byte sums)
//!   s2 += len·s1_old + Σ (len-i) b_i  (lane-wise weighted byte sums)
//!
//! so the block folds as two `@Vector` accumulators — byte-sum lanes and
//! weight-times-byte lanes — reduced once at the block's end; the serial
//! per-byte dependency is gone. The day-one kernel was
//! `std.hash.Adler32.permute` (the same 5552 blocks, a 16-byte
//! comptime-unrolled scalar inner loop: ~0.32 ns/byte measured, 3x the flate
//! core's cost on text); std's `Adler32.hash` stays in the tests as the
//! reference oracle (check values, a differential length sweep across the
//! 5552 boundary).
//!
//! The container keeps only the state: the running Adler-32, folded through
//! flate's checksum hook as bytes cross the codec boundary — every payload
//! byte exactly once, in stream order, with no copy and no second pass
//! (README.md, "The checksum"; OQ1). RFC 1950's trailer carries no length
//! field, so the state is the digest alone.

const std = @import("std");
const testing = std.testing;
const Adler32 = std.hash.Adler32;

const fastmem = @import("fastmem");

const flate = @import("../flate/root.zig");
const common = @import("common.zig");
const readInt = common.readInt;

/// §8.2's prime modulus.
const base: u32 = 65521;

/// §8.2's deferred-modulo block bound ("delayed for 5552 bytes"): the
/// largest block whose sums provably stay under 2^32 — s2 tops out at
/// (len+1)·(base-1) + 255·len·(len+1)/2, which is under 2^32 exactly at
/// 5552. Sixteen divides 5552, so every full block vectorizes without a tail.
const nmax: usize = 5552;

/// The chunk width: one 16-byte vector per step.
const chunk_len = 16;
const Chunk = @Vector(chunk_len, u8);

/// The vector kernel's accumulator type: one u32 lane per input byte, the
/// width the NMAX bound's arithmetic demands (see `nmax`).
const Lane = @Vector(chunk_len, u32);

/// Lane indices 0..15, the per-lane weight offset within a chunk.
const lane_index: Lane = std.simd.iota(u32, chunk_len);

/// Fold `bytes` into `adler` (a `final()` value, the initial value 1) and
/// return the new value: the libdeflate `adler32(adler, bytes)` shape the
/// one-shot paths use (`containers-notes.md §3.3`). The state is a
/// continuation, so `adler32(1, b) == Adler32.hash(b)` and
/// `adler32(adler, "") == adler`.
pub fn adler32(adler: u32, bytes: []const u8) u32 {
    var s1: u32 = adler & 0xffff;
    var s2: u32 = adler >> 16;

    var rest = bytes;
    while (rest.len >= chunk_len) {
        // One deferred-modulo block: full chunks fold into the vector
        // accumulators, a sub-chunk tail (only possible in the input's last
        // block) finishes with the per-byte recurrence.
        const len = @min(rest.len, nmax);
        const block = rest[0..len];
        defer rest = rest[len..];

        // The vector part folds the chunk-aligned prefix of `vec_len`
        // bytes; its weights are relative to that prefix (the weight of
        // 0-based byte p in an n-byte prefix is n-p), so the prefix fold
        // lands the exact running state and the sub-chunk tail's per-byte
        // recurrence continues from it without double-counting.
        const vec_len = block.len - block.len % chunk_len;
        var sum_lanes: Lane = @splat(0);
        var weighted_lanes: Lane = @splat(0);
        var at: usize = 0;
        while (at < vec_len) : (at += chunk_len) {
            const chunk: Chunk = block[at..][0..chunk_len].*;
            const wide: Lane = chunk;
            // Per chunk, the lane weights are (vec_len - at) - lane.
            const weights: Lane =
                @as(Lane, @splat(@intCast(vec_len - at))) - lane_index;
            sum_lanes +%= wide;
            weighted_lanes +%= wide *% weights;
        }
        // The NMAX bound: every lane and every sum below stays under 2^32
        // (see nmax), so the wrapping ops never wrap.
        const block_s1 = @reduce(.Add, sum_lanes);
        const block_s2 = @reduce(.Add, weighted_lanes);
        s2 +%= block_s2 +% @as(u32, @intCast(vec_len)) *% s1;
        s1 +%= block_s1;
        // The sub-chunk tail (only possible in the input's last block,
        // since 16 | nmax): the plain recurrence continues from the folded
        // state, byte order preserved.
        while (at < block.len) : (at += 1) {
            s1 +%= block[at];
            s2 +%= s1;
        }
        s1 %= base;
        s2 %= base;
    }
    // The under-a-chunk remainder: the RFC's per-byte form, one mod at the
    // end (the sums of under 16 bytes cannot reach the modulus twice...
    // s2 can: 15 bytes of 0xff give s2 = 15·s1 + 255·120 ≈ 15·65735 + 30600,
    // still far under 2^32 — one mod each suffices).
    for (rest) |byte| {
        s1 +%= byte;
        s2 +%= s1;
    }
    s1 %= base;
    s2 %= base;
    return s1 | (s2 << 16);
}

/// The container's checksum state, folded through flate's checksum hook as
/// bytes cross the codec boundary (README.md, "The checksum"; OQ1): the
/// Adler-32 of every payload byte, exactly once, in stream order. RFC 1950's
/// trailer is this value alone — there is no size field beside it (`§2.2`).
pub const Checksum = struct {
    /// The running digest (`§8.2`); starts at the algorithm's initial value,
    /// 1 (`§8.2`: "s1 is initialized to 1").
    adler: u32 = 1,

    /// Fold one contiguous payload run: the hook's `update_fn`, called with
    /// non-empty runs in stream order (`src/flate/Checksum.zig`).
    fn update(context: *anyopaque, bytes: []const u8) void {
        const self: *Checksum = @ptrCast(@alignCast(context));
        self.adler = adler32(self.adler, bytes);
    }

    /// The flate checksum hook over this state. `flate.Writer.Checksum` and
    /// `flate.Reader.Checksum` name the same type, so one value serves both
    /// layers.
    pub fn hook(self: *Checksum) flate.Writer.Checksum {
        return .{ .context = self, .update_fn = update };
    }

    /// The final trailer value (`§2.2`). An empty payload folds to the
    /// kernel's initial value, 1 (`§8.2`).
    pub fn final(self: *const Checksum) u32 {
        return self.adler;
    }
};

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1950-zlib.txt §2.2 (the trailer value),
// §8.2 (the algorithm and the deferred modulo), §9 (the sample). std's
// `Adler32` is the reference oracle for the vector kernel.
// ---------------------------------------------------------------------------

test "adler32: the standard check values" {
    // RFC 1950 §9's sample is the per-byte form; these are the values every
    // Adler-32 description pins. `Wikipedia` is the canonical check value
    // (0x11E60398); `Hello world\n` is the value std's own zlib test member
    // carries big-endian as the bytes `1c f2 04 47`; `123456789` is the
    // companion check value to the RFC's sample table.
    try testing.expectEqual(@as(u32, 0x11E60398), Adler32.hash("Wikipedia"));
    try testing.expectEqual(@as(u32, 0x1CF20447), Adler32.hash("Hello world\n"));
    try testing.expectEqual(@as(u32, 0x091E01DE), Adler32.hash("123456789"));
    // The kernel under test agrees, through its own continuation boundary.
    try testing.expectEqual(@as(u32, 0x11E60398), adler32(1, "Wikipedia"));
    try testing.expectEqual(@as(u32, 0x091E01DE), adler32(1, "123456789"));
    // §8.2 — s1 starts at 1, so the empty sequence hashes to the initial
    // state, and the kernel with it is the identity on empty input.
    try testing.expectEqual(@as(u32, 1), Adler32.hash(""));
    try testing.expectEqual(@as(u32, 1), adler32(1, ""));
}

test "adler32: the vector kernel agrees with std over a length sweep" {
    // Every vector-chunk trip count and every tail length, across the
    // deferred-modulo boundary (§8.2): deterministic bytes, lengths 0 through
    // nmax + one chunk + one byte. The worst-wrap case rides along: all-0xff
    // bytes at the same lengths.
    var bytes: [nmax + chunk_len + 1]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(0x5EED);
    rng.random().bytes(&bytes);
    for (0..bytes.len + 1) |len| {
        try testing.expectEqual(Adler32.hash(bytes[0..len]), adler32(1, bytes[0..len]));
    }
    fastmem.set(u8, &bytes, 0xff);
    var len: usize = 0;
    while (len <= bytes.len) : (len += chunk_len) {
        try testing.expectEqual(Adler32.hash(bytes[0..len]), adler32(1, bytes[0..len]));
    }
}

test "adler32: the wrapper is a continuation of the kernel" {
    // The libdeflate shape: `adler32(crc, bytes)` continues a digest, with
    // the initial value 1 standing for "no bytes yet". The identity
    // `adler32(1, b) == Adler32.hash(b)` is what the one-shot encoder rides.
    const bytes = "the quick brown fox jumps over the lazy dog. " ** 20;
    try testing.expectEqual(Adler32.hash(bytes), adler32(1, bytes));
    try testing.expectEqual(
        adler32(1, bytes),
        adler32(adler32(1, bytes[0..7]), bytes[7..]),
    );
}

test "adler32: incremental runs equal one pass" {
    // The streaming layers fold runs as bytes cross the codec boundary
    // (OQ1): the digest must be independent of where the runs are cut —
    // including across the 5552-byte deferred-modulo boundary (§8.2).
    const bytes = "the quick brown fox jumps over the lazy dog. " ** 300;
    try testing.expect(bytes.len > nmax);
    const whole = Adler32.hash(bytes);
    try testing.expectEqual(whole, adler32(1, bytes));
    var state: u32 = 1;
    var at: usize = 0;
    while (at < bytes.len) : (at += 37) {
        state = adler32(state, bytes[at..][0..@min(37, bytes.len - at)]);
    }
    try testing.expectEqual(whole, state);

    // The same through the container's own state and hook: runs in order,
    // each byte once.
    var checksum: Checksum = .{};
    const hook = checksum.hook();
    at = 0;
    while (at < bytes.len) : (at += nmax - 1) {
        hook.update(bytes[at..][0..@min(nmax - 1, bytes.len - at)]);
    }
    try testing.expectEqual(whole, checksum.final());
}

test "adler32: the streaming accounting through a container trailer" {
    // The state the container reads at the clean end: the trailer of a
    // stream is this value, big-endian (`§2.2`).
    const encode = @import("encode.zig");
    var checksum: Checksum = .{};
    const hook = checksum.hook();
    const bytes = "checksums ride the codec boundary " ** 8;
    hook.update(bytes[0..100]);
    hook.update(bytes[100..]);
    var trailer: [encode.trailer_len]u8 = undefined;
    encode.writeTrailer(&trailer, checksum.final());
    try testing.expectEqual(
        Adler32.hash(bytes),
        readInt(u32, &trailer),
    );
}
