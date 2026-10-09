//! The decode-overrun sentinel: every decode test pre-fills the target with
//! a cycling byte pattern and proves the bytes past the decoded length are
//! untouched (AGENTS.md, "Rules"; both codecs' READMEs, "Testing").
//!
//! The cycle is `[base, base + len)`, period 37: prime, so a mis-copied byte
//! lands at an unrelated phase — a power of two could mask an 8-byte-off
//! copy. The range and period match golang/snappy's
//! `notPresentBase`/`notPresentLen` (THIRD_PARTY.md).

const std = @import("std");
const testing = std.testing;

const fastmem = @import("fastmem");

/// The first sentinel byte; the cycle is `[base, base + len)`.
pub const base: u8 = 0xa0;
/// The cycle length, in bytes.
pub const len: u8 = 37;

/// The sentinel byte at absolute index `i`.
pub fn at(i: usize) u8 {
    return base + @as(u8, @intCast(i % len));
}

/// Pre-fill `target` with the cycling sentinel, from index 0: the phase is
/// the absolute buffer index, so a partial fill starts there too.
pub fn fill(target: []u8) void {
    var i: usize = 0;
    while (i + len <= target.len) : (i += len) {
        fastmem.copy(u8, target[i..][0..len], &pattern);
    }
    fastmem.copy(u8, target[i..], pattern[0 .. target.len - i]);
}

/// Every byte from `decoded_len` on must still hold its sentinel: a decode
/// wrote past the length it was allowed.
pub fn expect(target: []const u8, decoded_len: usize) !void {
    for (target[decoded_len..], decoded_len..) |byte, i| {
        try testing.expectEqual(at(i), byte);
    }
}

/// The cycle, materialized once so fills are chunked copies.
const pattern: [len]u8 = blk: {
    var bytes: [len]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = base + @as(u8, @intCast(i));
    break :blk bytes;
};
