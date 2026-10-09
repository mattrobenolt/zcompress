//! Shared helpers for the snappy block codec: the LEB128 varint used for the
//! uncompressed-length prefix.

const mem = @import("std").mem;

/// Number of bytes to encode `value` as an unsigned LEB128 varint.
pub fn uvarintSize(value: usize) usize {
    if (value == 0) return 1;
    var size: usize = 0;
    var v = value;
    while (v != 0) : (v >>= 7) size += 1;
    return size;
}

/// Write `value` as an unsigned LEB128 varint into `out`, returning bytes
/// written. `error.BufferTooSmall` when `out` is too small.
pub fn writeUvarint(out: []u8, value: usize) error{BufferTooSmall}!usize {
    var v = value;
    var pos: usize = 0;
    while (v >= 0x80) {
        if (pos >= out.len) return error.BufferTooSmall;
        out[pos] = @as(u8, @truncate(v)) | 0x80;
        pos += 1;
        v >>= 7;
    }
    if (pos >= out.len) return error.BufferTooSmall;
    out[pos] = @as(u8, @truncate(v));
    return pos + 1;
}

/// Read an unsigned LEB128 varint from `input` at `pos`, advancing `pos`.
/// `error.DecompressionFailed` on truncation or overflow (varint > 5 bytes).
pub fn readUvarint(input: []const u8, pos: *usize) error{DecompressionFailed}!usize {
    var result: usize = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        if (pos.* >= input.len) return error.DecompressionFailed;
        const byte = input[pos.*];
        pos.* += 1;
        // Spec §1: the length is at most 2^32 - 1, so a fifth byte carries
        // at most 4 value bits.
        if (i == 4 and byte > 0x0f) return error.DecompressionFailed;
        result |= (@as(usize, byte & 0x7F)) << @intCast(i * 7);
        if (byte & 0x80 == 0) return result;
    }
    return error.DecompressionFailed; // varint too long (> 5 bytes)
}

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
