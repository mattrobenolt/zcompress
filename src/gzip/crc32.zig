//! The gzip checksum state over std's CRC-32 kernel.
//!
//! RFC 1952 §2.3.3 names "the CRC-32 algorithm used in the ISO 3309 standard".
//! `std.hash.crc.Crc32` (the `Crc32IsoHdlc` polynomial, reflected
//! 0xEDB88320, with the full pre/post-conditioning) is exactly that kernel
//! (`std/hash/crc.zig:10`); verified against `0xCBF43926` and python
//! `zlib.crc32` in the tests. The container keeps only the state: the
//! running CRC plus the payload length mod 2^32 (the trailer's ISIZE,
//! `§2.3.1`), folded through flate's checksum hook as bytes cross the
//! codec boundary — every payload byte exactly once, in stream order, with
//! no copy and no second pass (README.md, "The checksums"; OQ1).

const std = @import("std");
const testing = std.testing;
const Crc32 = std.hash.crc.Crc32;

const flate = @import("../flate/root.zig");

/// The container's checksum state, folded through flate's checksum hook as
/// bytes cross the codec boundary (README.md, "The checksums"; OQ1): the
/// CRC-32 of every payload byte, exactly once, in stream order, plus the
/// payload length mod 2^32 — the trailer's ISIZE (`§2.3.1`).
pub const Checksum = struct {
    /// CRC-32 of the bytes folded so far (the kernel state; `final()` carries
    /// the conditioning). Starts at `Crc32.init()`.
    crc: Crc32 = .init(),
    /// The folded length mod 2^32 (`§2.3.1`: "the size of the original
    /// (uncompressed) input data modulo 2^32").
    len: u32 = 0,

    /// Fold one contiguous payload run: the hook's `update_fn`, called with
    /// non-empty runs in stream order (`src/flate/Checksum.zig`).
    fn update(context: *anyopaque, bytes: []const u8) void {
        const self: *Checksum = @ptrCast(@alignCast(context));
        self.crc.update(bytes);
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
        return self.crc.final();
    }
};

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1952-gzip.txt §8 (the sample table and
// update), §2.3.1 (the trailer value).
// ---------------------------------------------------------------------------

test "crc32: the standard check value" {
    // RFC 1952 §8 — the bytewise reflected table over the polynomial
    // 0xEDB88320. The check value every CRC-32 description pins:
    // crc32("123456789") = 0xCBF43926.
    try testing.expectEqual(@as(u32, 0xCBF43926), Crc32.hash("123456789"));
}

test "crc32: the golang/go gzip golden trailer" {
    // RFC 1952 §2.3.1 — the CRC-32 of the uncompressed data. Go's gzip
    // golden "hello.txt" carries the little-endian bytes `2d 3b 08 af` for
    // "hello world\n" (`gunzip_test.go`); read back, the value is 0xAF083B2D.
    try testing.expectEqual(@as(u32, 0xAF083B2D), Crc32.hash("hello world\n"));
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
    // (OQ1): the digest must be independent of where the runs are cut.
    const bytes = "the quick brown fox jumps over the lazy dog. " ** 20;
    const whole = Crc32.hash(bytes);
    var split: Crc32 = .init();
    var at: usize = 0;
    while (at < bytes.len) : (at += 7) {
        split.update(bytes[at..][0..@min(7, bytes.len - at)]);
    }
    try testing.expectEqual(whole, split.final());
}

/// Fold `bytes` into `crc` (a `final()` digest, the initial value 0) and
/// return the new digest: the libdeflate `crc32(crc, bytes)` shape the
/// one-shot paths use. The conditioning is inside (a state continuation on
/// the kernel's raw state, not a re-fold of the digest), so the identity
/// `crc32(0, b) == Crc32.hash(b)` holds and `crc32(crc, "") == crc`.
pub fn crc32(crc: u32, bytes: []const u8) u32 {
    var c: Crc32 = .init();
    // `.init()` is the fully conditioned raw state (0xffff_ffff here) and
    // `final()` complements it, so the raw state behind a digest `d` is
    // `d ^ 0xffff_ffff` — exactly `init() ^ d`.
    c.crc ^= crc;
    c.update(bytes);
    return c.final();
}
