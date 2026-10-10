//! Shared helpers for the zlib container: big-endian integer access. RFC 1950
//! §2.1 stores every multi-byte number MOST-significant byte first — the
//! Adler-32 trailer (§2.2) — so the helpers bake the endianness in and call
//! sites carry no endian argument. The fuzz seeds' Smith serialization is
//! little-endian by that harness's format and does not use these helpers.

const mem = @import("std").mem;

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
/// Forces big-endianness.
pub inline fn readInt(comptime T: type, buffer: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    return mem.readInt(T, buffer, .big);
}

/// Writes an integer to memory, storing it in twos-complement.
/// This function always succeeds, has defined behavior for all inputs, but
/// the integer bit width must be divisible by 8.
/// Forces big-endianness.
pub inline fn writeInt(
    comptime T: type,
    buffer: *[@divExact(@typeInfo(T).int.bits, 8)]u8,
    value: T,
) void {
    return mem.writeInt(T, buffer, value, .big);
}
