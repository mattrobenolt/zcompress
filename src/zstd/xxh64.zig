//! The zstd frame checksum state over std's XXH64 kernel.
//!
//! RFC 8878 §3.1.1: "The content checksum is the result of the XXH64() hash
//! function [XXHASH] digesting the original (decoded) data as input, and a
//! seed of zero. The low 4 bytes of the checksum are stored in little-endian
//! format."
//!
//! `std.hash.XxHash64` is the day-one kernel — the audit in
//! `docs/research/zstd-notes.md` §3 verified it by running it against the C
//! library's own trailers, the CRC-32 lesson applied: the canonical check
//! value, the streaming form, and two real `zstd` frames' trailers all
//! agree, and the four-lane accumulator with its 32-byte staging buffer is
//! exactly the incremental shape a frame boundary needs (no staging of our
//! own). No kernel is written at M4: the state below is this module's own
//! function boundary, the `src/gzip/crc32.zig` shape, so the perf lane can
//! swap a kernel in without touching a decoder. std's `XxHash64` stays in
//! the tests as the reference oracle, and the pinned zstd v1.5.7's trailers
//! are the differential pin (`frame_checksum`, `frame_checksum_empty`, and
//! `frame_checksum_multi` in `golden.zig`; the CLI verifies each with `zstd
//! -t`).
//!
//! Where it folds (OQ7): at the one per-block emission funnel
//! (`frame.State.recordBlock`), so every decoded byte is hashed exactly
//! once, in order, with no second pass and no buffer of our own. The
//! flag-off frame never folds and never verifies.

const std = @import("std");
const testing = std.testing;

/// `§3.1.1` — the seed: "a seed of zero".
pub const seed: u64 = 0;

/// The frame's checksum state: the incremental XXH64 over the frame's
/// decoded bytes, folded per block by `frame.State.recordBlock` (OQ7).
pub const State = struct {
    /// std's kernel, seeded with zero (`§3.1.1`). The four-lane accumulator
    /// and the 32-byte tail buffer live inside it.
    hasher: std.hash.XxHash64 = std.hash.XxHash64.init(seed),

    /// Fold one contiguous run of decoded bytes.
    pub fn update(self: *State, bytes: []const u8) void {
        self.hasher.update(bytes);
    }

    /// The trailer's value (`§3.1.1`): "The low 4 bytes of the checksum are
    /// stored in little-endian format" — the digest's low 32 bits, compared
    /// against the wire's four bytes read little-endian. std spells `final`
    /// through a mutable receiver, so this one is `*State`; it is a read.
    pub fn final(self: *State) u32 {
        return @truncate(self.hasher.final());
    }
};

/// The one-shot digest `XXH64(bytes, seed)`, the `crc32(crc, bytes)` shape:
/// the tests' and the oracle's form. The frame paths fold through `State`.
pub fn xxh64(seed_value: u64, bytes: []const u8) u64 {
    return std.hash.XxHash64.hash(seed_value, bytes);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1.1 (the checksum),
// §3.1.1.1.1.5 (the flag). std's `XxHash64` is the kernel, so the oracle
// values here are the C library's own — the CLI's verified trailers — never
// our own arithmetic.
// ---------------------------------------------------------------------------

test "xxh64: the canonical check values" {
    // RFC 8878 §3.1.1 + docs/research/zstd-notes.md §3 — the reference
    // XXH64 values (the audit ran these against the 0.16.0 store). The
    // empty string's is the canonical one every XXH64 description pins;
    // "123456789" is the alphabet's standard vector.
    try testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), xxh64(0, ""));
    try testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), std.hash.XxHash64.hash(0, ""));
    try testing.expectEqual(@as(u64, 0x8CB841DB40E6AE83), xxh64(0, "123456789"));
}

test "xxh64: the zstd cross-check, through the CLI's own trailers" {
    // RFC 8878 §3.1.1 — the trailer of a checksum-enabled frame is the low
    // 4 bytes, little-endian, of `XXH64(decoded, seed = 0)`. The two
    // fixtures' trailers are the pinned zstd v1.5.7's own output, which the
    // CLI verifies with `zstd -t`: `frame_checksum` decodes "abcd", and
    // `frame_checksum_empty` decodes nothing (the empty payload's low 4).
    // The differential pin: std's kernel and the C library's XXH64 agree on
    // the exact bytes zstd writes.
    const abcd = "abcd";
    var state: State = .{};
    state.update(abcd);
    try testing.expectEqual(@as(u32, 0xD25D92CC), state.final());
    try testing.expectEqual(@as(u64, 0xDE0327B0D25D92CC), xxh64(0, abcd));
    // The trailer bytes as the wire carries them: cc 92 5d d2.
    const trailer: [4]u8 = @bitCast(state.final());
    try testing.expectEqualSlices(u8, &.{ 0xcc, 0x92, 0x5d, 0xd2 }, &trailer);
    // The empty payload: 99 e9 d8 51 (`frame_checksum_empty`).
    var empty: State = .{};
    try testing.expectEqual(@as(u32, 0x51D8E999), empty.final());
    const empty_trailer: [4]u8 = @bitCast(empty.final());
    try testing.expectEqualSlices(u8, &.{ 0x99, 0xe9, 0xd8, 0x51 }, &empty_trailer);
}

test "xxh64: the seed-0 pin is observable" {
    // RFC 8878 §3.1.1 — "a seed of zero". A seed-1 hash of the same bytes
    // differs, so the seed is pinned by the value, not by convention.
    try testing.expect(xxh64(1, "abcd") != xxh64(0, "abcd"));
    try testing.expectEqual(@as(u64, 0xDE0327B0D25D92CC), xxh64(0, "abcd"));
}

test "xxh64: the streaming form equals the one-shot form" {
    // RFC 8878 §3.1.1 — the checksum is over the *decoded* data however it
    // was produced: the frame layer folds one block at a time (OQ7), so the
    // digest must be independent of where the runs are cut, including cuts
    // inside the kernel's 32-byte staging buffer and the four-lane
    // accumulator's stripe.
    var bytes: [200]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(0x5EED);
    rng.random().bytes(&bytes);
    const whole = xxh64(0, &bytes);
    for ([_]usize{ 1, 7, 31, 32, 33, 63, 64, 65, 100, 199 }) |cut| {
        var state: State = .{};
        state.update(bytes[0..cut]);
        state.update(bytes[cut..]);
        try testing.expectEqual(@as(u32, @truncate(whole)), state.final());
    }
}
