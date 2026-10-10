//! The gzip checksum state over a slice-by-16 CRC-32 kernel.
//!
//! RFC 1952 §2.3.3 names "the CRC-32 algorithm used in the ISO 3309 standard"
//! (reflected polynomial 0xEDB88320, with the full pre/post-conditioning).
//! The kernel here is the slice-by-16 table method — sixteen interleaved
//! 256-entry tables, sixteen independent table loads per sixteen bytes — the
//! portable table shape (slice-by-8 is libdeflate's scalar default,
//! `lib/crc32.c crc32_slice8`; `containers-notes.md` §3.3) taken one step
//! wider. It replaces the day-one `std.hash.crc.Crc32` bytewise loop, whose
//! table-load address depends on the previous byte's CRC (a serialized ~4-5
//! cycle/byte chain: ~2.1 ns/byte measured, 23x the flate core's cost on
//! text). Slicing breaks that chain into independent loads, but one chain
//! remains per slice step (the state's own four bytes feed four of the
//! loads); at sixteen bytes per step that chain costs half of slice-by-8's
//! per byte. The boundary is unchanged —
//! `crc32(crc, bytes)` with the conditioning inside and the `Checksum`
//! state's `final()` — so a braided or folded-vector/PCLMULQDQ kernel can
//! still swap in behind it (the plan's deferred decision,
//! `containers-notes.md` §3.3).
//! std's `Crc32.hash` stays in the tests as the reference oracle
//! (0xCBF43926, the golang golden trailer, a differential length sweep).
//!
//! The container keeps only the state: the raw running CRC plus the payload
//! length mod 2^32 (the trailer's ISIZE, `§2.3.1`), folded through flate's
//! checksum hook as bytes cross the codec boundary — every payload byte
//! exactly once, in stream order, with no copy and no second pass
//! (README.md, "The checksums"; OQ1).

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Crc32 = std.hash.crc.Crc32;

const flate = @import("../flate/root.zig");
const common = @import("common.zig");
const readInt = common.readInt;

/// The reflected polynomial (§2.3.3's ISO 3309 CRC-32), bit-reversed for the
/// LSB-first shift.
const poly: u32 = 0xEDB8_8320;

/// The slice width: sixteen bytes per step, sixteen tables (16 KiB).
const slice_count = 16;

/// The slice-by-16 tables. `tables[0]` is RFC 1952 §8's sample table (the
/// CRC of the single byte); `tables[k][x]` is the CRC of the byte `x`
/// followed by `k` zero bytes, by the recurrence
/// `tables[k+1][x] = (tables[k][x] >> 8) ^ tables[0][tables[k][x] & 0xff]`.
/// Stepping the state sixteen bytes at once is then sixteen *independent*
/// table loads xor'd together — the serial bytewise chain is gone.
const tables: [slice_count][256]u32 = blk: {
    @setEvalBranchQuota(200_000);
    var t: [slice_count][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            c = if (c & 1 != 0) (c >> 1) ^ poly else c >> 1;
        }
        t[0][i] = c;
    }
    for (1..slice_count) |k| {
        for (0..256) |i| {
            t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
        }
    }
    break :blk t;
};

// The table construction and the fold are pinned at comptime against the
// check value (RFC 1952 §8). The 17-byte pin crosses one full slice plus a
// one-byte tail: `crc32("123456789")` is 9 bytes, so the comptime check is
// against std's oracle for the sliced path.
comptime {
    assert(tables[0][0x01] == 0x7707_3096);
    assert(crc32(0, "123456789") == 0xCBF4_3926);
    assert(crc32(0, "123456789ABCDEFGH") == Crc32.hash("123456789ABCDEFGH"));
}

/// Fold `bytes` into the raw running state (the complemented-running
/// convention: the state starts at `0xffff_ffff` and `final()` complements
/// it). Exactly the state transition of std's bytewise `Crc32.update`,
/// sixteen bytes per step; the tail under sixteen bytes steps bytewise.
fn fold(raw: u32, bytes: []const u8) u32 {
    var crc = raw;
    var rest = bytes;
    while (rest.len >= slice_count) {
        // The first four bytes xor into the state (its four bytes leave over
        // the next four steps); the other twelve enter as independent terms.
        const w0 = readInt(u32, rest[0..4]);
        const w1 = readInt(u32, rest[4..8]);
        const w2 = readInt(u32, rest[8..12]);
        const w3 = readInt(u32, rest[12..16]);
        crc ^= w0;
        crc = tables[15][crc & 0xff] ^ tables[14][(crc >> 8) & 0xff] ^
            tables[13][(crc >> 16) & 0xff] ^ tables[12][crc >> 24] ^
            tables[11][w1 & 0xff] ^ tables[10][(w1 >> 8) & 0xff] ^
            tables[9][(w1 >> 16) & 0xff] ^ tables[8][w1 >> 24] ^
            tables[7][w2 & 0xff] ^ tables[6][(w2 >> 8) & 0xff] ^
            tables[5][(w2 >> 16) & 0xff] ^ tables[4][w2 >> 24] ^
            tables[3][w3 & 0xff] ^ tables[2][(w3 >> 8) & 0xff] ^
            tables[1][(w3 >> 16) & 0xff] ^ tables[0][w3 >> 24];
        rest = rest[slice_count..];
    }
    for (rest) |byte| {
        crc = tables[0][(crc ^ byte) & 0xff] ^ (crc >> 8);
    }
    return crc;
}

/// The container's checksum state, folded through flate's checksum hook as
/// bytes cross the codec boundary (README.md, "The checksums"; OQ1): the
/// CRC-32 of every payload byte, exactly once, in stream order, plus the
/// payload length mod 2^32 — the trailer's ISIZE (`§2.3.1`).
pub const Checksum = struct {
    /// The raw running CRC-32 (the kernel state; `final()` carries the
    /// conditioning). Starts at the complemented-running initial value.
    raw: u32 = 0xffff_ffff,
    /// The folded length mod 2^32 (`§2.3.1`: "the size of the original
    /// (uncompressed) input data modulo 2^32").
    len: u32 = 0,

    /// Fold one contiguous payload run: the hook's `update_fn`, called with
    /// non-empty runs in stream order (`src/flate/Checksum.zig`).
    fn update(context: *anyopaque, bytes: []const u8) void {
        const self: *Checksum = @ptrCast(@alignCast(context));
        self.raw = fold(self.raw, bytes);
        self.len +%= @as(u32, @truncate(bytes.len));
    }

    /// The flate checksum hook over this state. `flate.Writer.Checksum` and
    /// `flate.Reader.Checksum` name the same type, so one value serves both
    /// layers.
    pub fn hook(self: *Checksum) flate.Writer.Checksum {
        return .{ .context = self, .update_fn = update };
    }

    /// The final trailer CRC-32 (`§2.3.1`). `final()` is the complemented
    /// digest; an empty payload folds to the RFC's empty-CRC value.
    pub fn final(self: *const Checksum) u32 {
        return self.raw ^ 0xffff_ffff;
    }
};

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1952-gzip.txt §8 (the sample table and
// update), §2.3.1 (the trailer value). std's `Crc32` is the reference oracle
// for the slice-by-16 kernel.
// ---------------------------------------------------------------------------

test "crc32: the standard check value" {
    // RFC 1952 §8 — the bytewise reflected table over the polynomial
    // 0xEDB88320. The check value every CRC-32 description pins:
    // crc32("123456789") = 0xCBF43926.
    try testing.expectEqual(@as(u32, 0xCBF43926), Crc32.hash("123456789"));
    try testing.expectEqual(@as(u32, 0xCBF43926), crc32(0, "123456789"));
}

test "crc32: the golang/go gzip golden trailer" {
    // RFC 1952 §2.3.1 — the CRC-32 of the uncompressed data. Go's gzip
    // golden "hello.txt" carries the little-endian bytes `2d 3b 08 af` for
    // "hello world\n" (`gunzip_test.go`); read back, the value is 0xAF083B2D.
    try testing.expectEqual(@as(u32, 0xAF083B2D), Crc32.hash("hello world\n"));
    try testing.expectEqual(@as(u32, 0xAF083B2D), crc32(0, "hello world\n"));
}

test "crc32: the empty payload is the RFC's empty-CRC value" {
    // The complement of the initial state: what a zero-length member's
    // trailer carries (§2.3.1's CRC over zero bytes).
    const empty: Checksum = .{};
    try testing.expectEqual(@as(u32, 0x0000_0000), empty.final());
    try testing.expectEqual(@as(u32, 0), empty.len);
}

test "crc32: incremental runs equal one pass" {
    // The streaming layers fold runs as bytes cross the codec boundary
    // (OQ1): the digest must be independent of where the runs are cut —
    // including cuts inside an eight-byte slice.
    const bytes = "the quick brown fox jumps over the lazy dog. " ** 20;
    const whole = Crc32.hash(bytes);
    try testing.expectEqual(whole, crc32(0, bytes));
    var split: Checksum = .{};
    const hook = split.hook();
    var at: usize = 0;
    while (at < bytes.len) : (at += 7) {
        hook.update(bytes[at..][0..@min(7, bytes.len - at)]);
    }
    try testing.expectEqual(whole, split.final());
    try testing.expectEqual(@as(u32, @truncate(bytes.len)), split.len);
}

test "crc32: slice-by-16 agrees with std over a length sweep" {
    // Every slice-loop trip count and every tail length, against the
    // reference kernel: deterministic bytes, lengths 0 through three full
    // slices plus one.
    var bytes: [3 * slice_count + 1]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(0x5EED);
    rng.random().bytes(&bytes);
    for (0..bytes.len + 1) |len| {
        try testing.expectEqual(Crc32.hash(bytes[0..len]), crc32(0, bytes[0..len]));
    }
}

test "crc32: a long fold agrees with std" {
    // Well past one slice: the length the one-shot paths fold in a call.
    const bytes = "the quick brown fox jumps over the lazy dog. " ** 1024;
    try testing.expectEqual(Crc32.hash(bytes), crc32(0, bytes));
    try testing.expectEqual(
        Crc32.hash(bytes),
        crc32(crc32(0, bytes[0..1000]), bytes[1000..]),
    );
}

/// Fold `bytes` into `crc` (a `final()` digest, the initial value 0) and
/// return the new digest: the libdeflate `crc32(crc, bytes)` shape the
/// one-shot paths use. The conditioning is inside (a state continuation on
/// the kernel's raw state, not a re-fold of the digest), so the identity
/// `crc32(0, b) == Crc32.hash(b)` holds and `crc32(crc, "") == crc`.
pub fn crc32(crc: u32, bytes: []const u8) u32 {
    // The digest is the complemented raw state, so the raw state behind a
    // digest `d` is `d ^ 0xffff_ffff` — complement in, fold, complement out.
    return fold(crc ^ 0xffff_ffff, bytes) ^ 0xffff_ffff;
}
