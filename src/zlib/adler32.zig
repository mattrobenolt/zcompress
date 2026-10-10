//! The zlib checksum state over std's Adler-32 kernel.
//!
//! RFC 1950 §2.2 defines the trailer value: the Adler-32 of "the uncompressed
//! data (excluding any dictionary data)", stored "in most-significant-byte
//! first (network) order". The algorithm is `§8.2`: two sums mod 65521 — s1
//! the sum of all bytes (initialized to 1, "to make the length of the
//! sequence part of s2"), s2 the sum of all s1 values — combined as
//! `s2*65536 + s1`; the appendix's implementation shape is the deferred
//! modulo ("The modulo on unsigned long accumulators can be delayed for 5552
//! bytes"). `std.hash.Adler32` is exactly that shape (the 5552-block
//! deferred-modulo form, a 16-byte comptime-unrolled inner loop, state
//! `adler: u32 = 1`; check values verified below), so the kernel here is
//! std's, wrapped behind this module's own function boundary.
//!
//! The container keeps only the state: the running Adler-32, folded through
//! flate's checksum hook as bytes cross the codec boundary — every payload
//! byte exactly once, in stream order, with no copy and no second pass
//! (README.md, "The checksum"; OQ1). RFC 1950's trailer carries no length
//! field, so the state is the digest alone.

const std = @import("std");
const testing = std.testing;
const Adler32 = std.hash.Adler32;

const flate = @import("../flate/root.zig");

/// The container's checksum state, folded through flate's checksum hook as
/// bytes cross the codec boundary (README.md, "The checksum"; OQ1): the
/// Adler-32 of every payload byte, exactly once, in stream order. RFC 1950's
/// trailer is this value alone — there is no size field beside it (`§2.2`).
pub const Checksum = struct {
    /// The kernel state (`§8.2`); `final()` is the value the trailer carries.
    /// Starts at the kernel's initial value, 1 (`§8.2`: "s1 is initialized
    /// to 1").
    adler: Adler32 = .{},

    /// Fold one contiguous payload run: the hook's `update_fn`, called with
    /// non-empty runs in stream order (`src/flate/Checksum.zig`).
    fn update(context: *anyopaque, bytes: []const u8) void {
        const self: *Checksum = @ptrCast(@alignCast(context));
        self.adler.update(bytes);
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
        return self.adler.adler;
    }
};

/// Fold `bytes` into `adler` (a `final()` value, the initial value 1) and
/// return the new value: the libdeflate `adler32(adler, bytes)` shape the
/// one-shot paths use (`containers-notes.md §3.3`). The state is a
/// continuation, so `adler32(1, b) == Adler32.hash(b)` and
/// `adler32(adler, "") == adler`.
pub fn adler32(adler: u32, bytes: []const u8) u32 {
    return Adler32.permute(adler, bytes);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1950-zlib.txt §2.2 (the trailer value),
// §8.2 (the algorithm and the deferred modulo), §9 (the sample).
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
    // §8.2 — s1 starts at 1, so the empty sequence hashes to the initial
    // state, and `permute` with it is the identity on empty input.
    try testing.expectEqual(@as(u32, 1), Adler32.hash(""));
    try testing.expectEqual(@as(u32, 1), adler32(1, ""));
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
    try testing.expect(bytes.len > 5552);
    const whole = Adler32.hash(bytes);
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
    while (at < bytes.len) : (at += 5551) {
        hook.update(bytes[at..][0..@min(5551, bytes.len - at)]);
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
        std.mem.readInt(u32, &trailer, .big),
    );
}
