//! The two bitstream readers the zstd entropy layers share.
//!
//! The **forward** reader is the one zstd bitstream read forward: the FSE
//! table description of `§4.1.1` ("A bitstream is read forward, in
//! little-endian fashion"), where the first bit of the first byte is the
//! least significant bit of the first field.
//!
//! The **backward** reader is every other bitstream — the FSE data streams
//! (`§4.1`) and the Huffman-coded streams (`§4.2.2`): "all FSE bitstreams are
//! read from end to beginning. Note that the order of the bits in the stream
//! is not reversed; they are simply read in the reverse order from which they
//! were written." The last byte's highest set bit is the final 1 bit that
//! marks where the useful bits end (`§4.2.2`: "a last byte of 0 is not
//! possible. And the final-bit-flag itself is not part of the useful
//! bitstream"); above it is zero padding, below it the stream runs backward,
//! most significant bit of each field first.
//!
//! The backward reader keeps an exact bit position: `remainingBits` counts
//! the bits not yet consumed, and a read that runs past the stream's start
//! drives it negative with the missing bits reading as zero. That is the
//! state the callers need, because the two consumption contracts differ:
//! the sequences stream and the Huffman streams must be "entirely and
//! exactly consumed" (`§4.2.2`, `§3.1.1.3.2.1.2`), while the FSE-compressed
//! Huffman weights terminate *on* the overflow — "if updating state after
//! decoding a symbol would require more bits than remain in the stream, it
//! is assumed that extra bits are zero. Then, symbols for each of the final
//! states are decoded and the process is complete" (`§4.2.1.2`).
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// The most bits one read takes: a 9-bit FSE accuracy log, an 11-bit Huffman
/// code, or a 9-bit `§4.1.1` Table 20 field (`2 * threshold - 1` is at most
/// `2 * 256 - 1`).
pub const max_read_bits: u5 = 11;

/// The forward reader (`§4.1.1`): fields are read little-endian from the
/// first byte's low bit up.
pub const ForwardReader = struct {
    source: []const u8,
    /// The number of bits consumed so far, counted from the first byte's
    /// least significant bit.
    consumed_bits: usize,

    pub fn init(source: []const u8) ForwardReader {
        return .{ .source = source, .consumed_bits = 0 };
    }

    /// The next `count` bits, without consuming them: the first bit read is
    /// the value's least significant bit (`§4.1.1`).
    ///
    /// Bits past the source's end read as zero — the reference reads a
    /// description through a zero-padded window and then checks the byte
    /// count it consumed against the buffer it was given
    /// (`FSE_readNCount`'s `countSize > hbSize` rule), so the padding is the
    /// caller's to validate, not the reader's to refuse.
    pub fn peekBits(self: ForwardReader, count: u5) u16 {
        assert(count <= max_read_bits);
        var value: u16 = 0;
        var taken: u5 = 0;
        while (taken < count) {
            const index = self.consumed_bits + taken;
            const in_byte: u5 = @intCast(index & 7);
            const take = @min(@as(u5, 8) - in_byte, count - taken);
            const chunk = if (index >> 3 < self.source.len)
                @as(u16, self.source[index >> 3] >> @intCast(in_byte))
            else
                0;
            value |= (chunk & mask(take)) << @intCast(taken);
            taken += take;
        }
        return value;
    }

    /// Consume `count` bits a `peekBits` proved are there. Consumption may
    /// run past the source's end — `bytesConsumed` is what the caller
    /// validates — so this only adds.
    pub fn skipBits(self: *ForwardReader, count: u5) void {
        self.consumed_bits += count;
    }

    /// Read `count` bits.
    pub fn readBits(self: *ForwardReader, count: u5) u16 {
        const value = self.peekBits(count);
        self.skipBits(count);
        return value;
    }

    /// The whole bytes consumed: "The bitstream consumes a round number of
    /// bytes. Any remaining bit within the last byte is simply unused"
    /// (`§4.1.1`), so this rounds up.
    pub fn bytesConsumed(self: ForwardReader) usize {
        return (self.consumed_bits + 7) / 8;
    }
};

/// The backward reader (`§4.1`, `§4.2.2`).
pub const BackwardReader = struct {
    source: []const u8,
    /// The write-order index one past the next bit to read — the number of
    /// bits not yet consumed. It goes negative when a read runs past the
    /// stream's start; those bits read as zero.
    remaining_bits: i32,

    /// The last byte's highest set bit is the final 1 bit (`§4.2.2`); a last
    /// byte of zero has no start bit at all.
    pub fn init(source: []const u8) error{MissingStartBit}!BackwardReader {
        if (source.len == 0) return error.MissingStartBit;
        const last = source[source.len - 1];
        if (last == 0) return error.MissingStartBit;
        // Bits below the final 1 bit of the last byte, plus every bit of the
        // bytes before it: `§4.2.2`'s "between 0 and 7 useful bits".
        const useful: i32 = @intCast(8 * (source.len - 1) + highBit(last));
        return .{ .source = source, .remaining_bits = useful };
    }

    /// The next `count` bits, without consuming them. The first bit read is
    /// the value's most significant bit; bits past the stream's start read
    /// as zero.
    pub fn peekBits(self: BackwardReader, count: u5) u16 {
        assert(count <= max_read_bits);
        var value: u16 = 0;
        var taken: u5 = 0;
        var remaining = self.remaining_bits;
        while (taken < count) {
            if (remaining <= 0) {
                // Past the stream's start: the missing bits are zero, which
                // is exactly the overflow condition the callers test for
                // (`§4.2.1.2`).
                value <<= @intCast(count - taken);
                break;
            }
            const position: u32 = @intCast(remaining - 1);
            const in_byte: u5 = @intCast(position & 7);
            const available = in_byte + 1;
            const take = @min(available, count - taken);
            // The bits of a byte are consumed from its most significant end
            // down, so the chunk is the byte's top `take` bits at `in_byte`.
            const chunk = @as(u16, self.source[position >> 3] >> @intCast(available - take)) &
                mask(take);
            value = (value << @intCast(take)) | chunk;
            taken += take;
            remaining -= take;
        }
        return value;
    }

    /// Consume `count` bits.
    pub fn skipBits(self: *BackwardReader, count: u5) void {
        assert(count <= max_read_bits);
        self.remaining_bits -= count;
    }

    /// Read `count` bits.
    pub fn readBits(self: *BackwardReader, count: u5) u16 {
        const value = self.peekBits(count);
        self.skipBits(count);
        return value;
    }

    /// The bits not yet consumed; negative once a read ran past the stream's
    /// start.
    pub fn remainingBits(self: BackwardReader) i32 {
        return self.remaining_bits;
    }

    /// A read ran past the stream's start (`§4.2.1.2`'s overflow).
    pub fn overran(self: BackwardReader) bool {
        return self.remaining_bits < 0;
    }

    /// Every bit consumed and none left over: the exact end `§4.2.2` and
    /// `§3.1.1.3.2.1.2` demand.
    pub fn isConsumed(self: BackwardReader) bool {
        return self.remaining_bits == 0;
    }
};

/// `(1 << count) - 1`, for `count` up to `max_read_bits`.
fn mask(count: u5) u16 {
    return (@as(u16, 1) << @intCast(count)) - 1;
}

/// The index of the highest set bit; `value` must be nonzero.
fn highBit(value: u8) u3 {
    assert(value != 0);
    return @intCast(7 - @clz(value));
}

test "ForwardReader reads fields little-endian from the first byte's low bit" {
    // RFC 8878 §4.1.1 — "A bitstream is read forward, in little-endian
    // fashion": the first field is the low bits of the first byte.
    var reader = ForwardReader.init(&.{ 0b1011_0101, 0b0011_0100 });
    try testing.expectEqual(@as(u16, 0b0101), reader.readBits(4));
    try testing.expectEqual(@as(u16, 0b1011), reader.readBits(4));
    // A field may cross the byte boundary: the second byte's low 3 bits are
    // 100 and the 5 above them 00110, least significant bit first.
    try testing.expectEqual(@as(u16, 0b100), reader.readBits(3));
    try testing.expectEqual(@as(u16, 0b00110), reader.readBits(5));
    try testing.expectEqual(@as(usize, 2), reader.bytesConsumed());
    // Past the source's end the bits read as zero; the caller checks the
    // byte count it consumed (the reference's own padding rule).
    try testing.expectEqual(@as(u16, 0), reader.readBits(1));
    try testing.expectEqual(@as(usize, 3), reader.bytesConsumed());
}

test "ForwardReader rounds its byte count up: a description consumes whole bytes" {
    // RFC 8878 §4.1.1 — "The bitstream consumes a round number of bytes. Any
    // remaining bit within the last byte is simply unused."
    var reader = ForwardReader.init(&.{0xff});
    _ = reader.readBits(4);
    try testing.expectEqual(@as(usize, 1), reader.bytesConsumed());
    _ = reader.readBits(1);
    try testing.expectEqual(@as(usize, 1), reader.bytesConsumed());
    try testing.expectEqual(@as(u16, 0b111), reader.readBits(3));
    try testing.expectEqual(@as(usize, 1), reader.bytesConsumed());
    try testing.expectEqual(@as(u16, 0), reader.peekBits(0));
    // A peek past the end reads zero without consuming.
    try testing.expectEqual(@as(u16, 0), reader.peekBits(1));
    try testing.expectEqual(@as(usize, 1), reader.bytesConsumed());
}

test "BackwardReader skips the padding and the final 1 bit, then reads MSB first" {
    // RFC 8878 §4.2.2 — the hand-built T1 pair's `01 0D` stream
    // (docs/research/zstd-notes.md §5.4): the last byte 0x0d has its final 1
    // bit at bit 3, and the useful bits run down from bit 2.
    var reader = try BackwardReader.init(&.{ 0x01, 0x0d });
    try testing.expectEqual(@as(i32, 11), reader.remainingBits());
    // 1 | 01 | 0000 | 0001 — the Table 25 codes for 0, 1, 4, 5 read in
    // forward order (the stream is written in reverse).
    try testing.expectEqual(@as(u16, 1), reader.readBits(1));
    try testing.expectEqual(@as(u16, 0b01), reader.readBits(2));
    try testing.expectEqual(@as(u16, 0b0000), reader.readBits(4));
    try testing.expectEqual(@as(u16, 0b0001), reader.readBits(4));
    try testing.expect(reader.isConsumed());
}

test "BackwardReader: a peek does not consume, a skip does" {
    // RFC 8878 §4.1 — the Huffman decode peeks a full code width and then
    // discards only the code's own bits.
    var reader = try BackwardReader.init(&.{0b0000_0001});
    // One byte: the final 1 bit is bit 0, so nothing below it is useful.
    try testing.expectEqual(@as(i32, 0), reader.remainingBits());
    try testing.expect(reader.isConsumed());
    var wide = try BackwardReader.init(&.{ 0b0000_0010, 0b0000_0011 });
    // 0x03's highest set bit is bit 1, so two useful bits are below it, then
    // all eight bits of 0x02: 10 | 00000010.
    try testing.expectEqual(@as(u16, 0b1000_0001), wide.peekBits(8));
    wide.skipBits(2);
    // The next eight bits run past the stream's start, so the last one
    // reads as zero.
    try testing.expectEqual(@as(u16, 0b0000_0100), wide.peekBits(8));
    try testing.expectEqual(@as(i32, 7), wide.remainingBits());
}

test "BackwardReader: a zero last byte has no start bit" {
    // RFC 8878 §4.2.2 — "a last byte of 0 is not possible".
    try testing.expectError(error.MissingStartBit, BackwardReader.init(&.{ 0x01, 0x00 }));
    try testing.expectError(error.MissingStartBit, BackwardReader.init(&.{}));
}

test "BackwardReader: reads past the stream's start are zero and overrun" {
    // RFC 8878 §4.2.1.2 — "if updating state after decoding a symbol would
    // require more bits than remain in the stream, it is assumed that extra
    // bits are zero".
    var reader = try BackwardReader.init(&.{0b0000_0001});
    try testing.expectEqual(@as(u16, 0), reader.remainingBits());
    try testing.expectEqual(@as(u16, 0b000), reader.readBits(3));
    try testing.expectEqual(@as(i32, -3), reader.remainingBits());
    try testing.expect(reader.overran());
    try testing.expectEqual(@as(u16, 0b0_0000_0000), reader.readBits(10));
    try testing.expectEqual(@as(i32, -13), reader.remainingBits());
    try testing.expect(!reader.isConsumed());
}
