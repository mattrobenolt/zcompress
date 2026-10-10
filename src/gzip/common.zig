//! Shared helpers for the gzip codec: little-endian integer access. RFC 1952
//! §2.1 stores every multi-byte number least-significant byte first — the
//! CRC32 and ISIZE trailer and the FHCRC header field (§2.3.1) — so the
//! helpers bake the endianness in and call sites carry no endian argument.

const mem = @import("std").mem;

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
/// Forces little-endianness.
pub inline fn readInt(comptime T: type, buffer: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    return mem.readInt(T, buffer, .little);
}

/// Writes an integer to memory, storing it in twos-complement.
/// This function always succeeds, has defined behavior for all inputs, but
/// the integer bit width must be divisible by 8.
/// Forces little-endianness.
pub inline fn writeInt(
    comptime T: type,
    buffer: *[@divExact(@typeInfo(T).int.bits, 8)]u8,
    value: T,
) void {
    return mem.writeInt(T, buffer, value, .little);
}
