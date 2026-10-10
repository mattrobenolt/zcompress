//! Shared helpers for the flate codec: little-endian integer access. Every
//! byte-aligned integer access in this package is little-endian — the
//! encoder's hash loads and the bit reader's window (deflate packs bits into
//! bytes LSB-first, RFC 1951 §3.1.1) — so the helpers bake the endianness in
//! and call sites carry no endian argument.

const mem = @import("std").mem;

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
/// Forces little-endianness.
pub inline fn readInt(comptime T: type, buffer: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    return mem.readInt(T, buffer, .little);
}

/// Reads an integer from `bytes` with size equal to `bytes.len`. The return
/// type must be large enough to store the result.
/// Forces little-endianness.
pub inline fn readVarInt(comptime T: type, bytes: []const u8) T {
    return mem.readVarInt(T, bytes, .little);
}
