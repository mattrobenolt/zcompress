//! flate.Reader: a decompressing `Io.Reader` over a raw deflate stream
//! (README.md, "Streaming") produced by `Writer`.
//!
//! The window: `buffer[0..end]` is decoded output, `buffer[seek..end]` the
//! bytes the consumer has not consumed. The decoder slides it forward as it
//! fills, keeping the last `history_len` bytes before `end` — the format's
//! match reach (`§3.2.3`) — so the buffer is a sliding window, never an
//! accumulation. There is no compressed staging region: a Huffman block
//! carries no compressed length, so the decoder reads the input through a bit
//! reader and decodes straight into the window.
//!
//! The bit reader consumes `input` exactly through the stream's last byte —
//! the final block's partial byte included — and stops there (README,
//! "Streaming"). It peeks bits out of `input`'s buffer and tosses a byte only
//! once all eight of its bits are consumed, so bytes after the stream are
//! never consumed, and the final padded byte is.
//!
//! The contiguous-read cap: the window holds 64 KiB and can slide only when
//! the consumer has drained everything older than the retained 32-KiB tail,
//! so any request of at most `history_len` bytes is served and a request
//! beyond what the window can hold at the consumer's position fails closed
//! with `error.ReadFailed` (`err == .StreamTooLong`) — never an assert.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const history_len = encode.history_len;
const max_block_size = encode.max_block_size;
const golden = @import("golden.zig");
const Writer = @import("Writer.zig");

/// `§3.2.5` — the longest match a symbol can declare (length code 285 is 258),
/// so the decoder stops this far short of a full window.
const max_match_len = 258;

/// The widest peek any read takes: 16 bits, the stored block's LEN or NLEN
/// (`§3.2.4`). The Huffman tables peek at most 15.
const max_peek_bits: u6 = 16;

/// The caller-provided window: one window of decoded output. The last
/// `history_len` bytes of it are the match history (`§3.2.3`), the rest is
/// fresh output; there is no compressed staging region.
pub const Buffer = [2 * history_len]u8;

/// The detailed error recorded once `state == .failed` (the interface reports
/// `error.ReadFailed`): `decode.DecompressError` minus `BufferTooSmall` — the
/// Reader owns its window, so no decode can outgrow it — plus the contiguity
/// cap and the interface's own `ReadFailed`/`EndOfStream`.
pub const Error = error{
    Truncated,
    InvalidBlockType,
    WrongStoredBlockNlen,
    InvalidDynamicBlockHeader,
    OversubscribedHuffmanTree,
    IncompleteHuffmanTree,
    MissingEndOfBlockCode,
    InvalidCode,
    InvalidMatch,
    StreamTooLong,
    ReadFailed,
    EndOfStream,
};

/// An alias for `Error` that `Bits` can name: a container declaration shadows
/// the file scope inside it, so `Bits.Error` cannot refer to `Error` directly.
const ReaderError = Error;

/// Where the decoder is in the block structure (`§3.2.3`): a resume point, so
/// a window that fills mid-block picks up exactly where it stopped.
const Phase = union(enum) {
    /// BFINAL and BTYPE are next.
    block_header,
    /// Copying a stored block's payload: `remaining` bytes left (`§3.2.4`).
    stored_block: u16,
    /// Decoding symbols from a fixed-Huffman block (`§3.2.6`).
    fixed_block,
    /// A fixed block's match length is decoded; its distance is next.
    fixed_match: u16,
    /// Decoding symbols from a dynamic-Huffman block (`§3.2.7`).
    dynamic_block,
    /// A dynamic block's match length is decoded; its distance is next.
    dynamic_match: u16,
};

/// The bit reader (`§3.1.1`): LSB-first fill, straight from the input
/// `Io.Reader`, no compressed staging.
///
/// `input`'s position advances only in whole consumed bytes: `consumed` counts
/// the bits already consumed in the byte at the input's position, so a peek
/// never consumes and the stream's last partial byte is consumed exactly once
/// (`finish`). That is what makes the stream boundary exact.
const Bits = struct {
    /// The error set this bit source produces: the Reader's own, whose reads
    /// can fail. The tree machinery in decode.zig is generic over it.
    pub const ErrorSet = ReaderError;

    input: *Io.Reader,
    /// Bits already consumed in the byte at `input`'s position (0-7).
    consumed: u3 = 0,

    /// The next `n` bits, LSB-of-value first, buffering first. Bits past the
    /// end of the input read as zero; `take` is the gate that turns that into
    /// `error.Truncated`, so a truncated stream can never decode a symbol out
    /// of padding (decode.zig's rule). Public with `take` because decode.zig's
    /// tree machinery is generic over the bit source.
    pub fn peek(self: *Bits, n: u6) ErrorSet!u64 {
        assert(n <= max_peek_bits);
        try self.bufferBits(n);
        const buffered = self.input.buffer[self.input.seek..self.input.end];
        const window = mem.readVarInt(u64, buffered[0..@min(buffered.len, 8)], .little);
        return (window >> self.consumed) & ((@as(u64, 1) << n) - 1);
    }

    /// Consume `n` bits. `error.Truncated` when the input ends first.
    pub fn take(self: *Bits, n: u6) ErrorSet!u64 {
        if (!try self.hasBits(n)) return error.Truncated;
        const value = try self.peek(n);
        self.consume(n);
        return value;
    }

    /// True when the next `n` bits exist in the input.
    fn hasBits(self: *Bits, n: u6) ErrorSet!bool {
        try self.bufferBits(n);
        return self.available() >= n;
    }

    /// Bits of the input not yet consumed, as far as the buffer shows.
    fn available(self: *const Bits) u64 {
        return @as(u64, self.input.end - self.input.seek) * 8 - self.consumed;
    }

    /// Buffer the bytes the next `n` bits come from, when the input has them.
    /// A short input is not an error here: `peek` zero-extends past it and
    /// `take` reports the shortage as `error.Truncated`.
    fn bufferBits(self: *Bits, n: u6) ErrorSet!void {
        const need = (@as(usize, self.consumed) + n + 7) / 8;
        if (self.input.end - self.input.seek >= need) return;
        self.input.fill(need) catch |err| switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => return error.ReadFailed,
        };
    }

    /// Consume `n` bits (the caller has checked availability): whole consumed
    /// bytes leave `input`, the partial byte's consumed bits stay counted.
    fn consume(self: *Bits, n: u6) void {
        const total: u6 = self.consumed + n;
        self.input.toss(total / 8);
        self.consumed = @intCast(total % 8);
    }

    /// Skip to the next byte boundary: "any bits of input up to the next byte
    /// boundary are ignored" (`§3.2.4`). A decoder must not require the
    /// skipped bits to be zero.
    fn alignToByte(self: *Bits) ErrorSet!void {
        const skip: u6 = (8 - @as(u6, self.consumed)) % 8;
        if (skip != 0) _ = try self.take(skip);
    }

    /// The stream's last byte: the final block ends mid-byte and the format
    /// pads it (`§3.1.1`), so the byte belongs to the stream — and the bytes
    /// after it do not (README, "Streaming").
    fn finish(self: *Bits) void {
        if (self.consumed == 0) return;
        assert(self.input.seek < self.input.end);
        self.input.toss(1);
        self.consumed = 0;
    }
};

const Reader = @This();

reader: Io.Reader,
bits: Bits,
phase: Phase = .block_header,
/// `§3.2.3` — "a distance cannot refer past the beginning of the output
/// stream" is a stream-wide rule, not a window one, so the total decoded
/// length is tracked beside the window's.
total_out: u64 = 0,
/// Whether the current block is the stream's last (`§3.2.3`).
final: bool = false,
/// The dynamic block's tables (`§3.2.7`), rebuilt per block.
literal: decode.LitDecoder = .{},
distance: decode.DistDecoder = .{},
/// The stream lifecycle (src/internal/reader.zig): `streaming` until the
/// final block's output is complete (`done`) or a failure sticks (`failed`,
/// details in `err`).
state: internal.reader.State = .streaming,
/// Detailed error once `state == .failed`; the interface reports
/// `error.ReadFailed`.
err: ?Error = null,

/// The generated `Io.Reader` entries (src/internal/README.md, "The Io codec
/// pattern book"): the sticky guard, the zero-length poll, and the
/// fill-and-return-0 count are structural. `fill` is the pump; `rebase`
/// owns the window's capacity policy.
const vtable = internal.reader.VTable(Reader, fill, rebase).vtable;

/// Wrap `input` (a raw deflate stream) with `buffer` as the decoded window.
/// Consume through `&r.reader` (`stream`, `read`-family, `peek`-family); the
/// stream ends cleanly with `error.EndOfStream` once the final block's output
/// has been consumed and fails closed with `error.ReadFailed` (sticky,
/// details in `err`) on any malformed stream or input failure.
pub fn init(input: *Io.Reader, buffer: *Buffer) Reader {
    return .{
        .reader = .{
            .buffer = buffer,
            .seek = 0,
            .end = 0,
            .vtable = &vtable,
        },
        .bits = .{ .input = input },
    };
}

/// Decode into the window until it has no room for another symbol, or the
/// stream ends. Returns the bytes added — never zero without an error: a
/// caller that needs more either gets them or gets a failure.
fn fillWindow(r: *Reader) Error!usize {
    var added: usize = 0;
    while (r.state == .streaming) {
        // Room for the next write: a match may declare up to 258 bytes
        // (`§3.2.5`), so the decoder stops this far short of a full window and
        // slides the retained history forward. That is what bounds the
        // guaranteed contiguous request at `history_len` bytes: a slide always
        // leaves at least that much free (README, "Streaming").
        if (r.reader.buffer.len - r.reader.end < max_match_len) {
            if (r.slide() < max_match_len) {
                // The window cannot take another symbol: the consumer holds
                // more than it has drained, so a request that needs one fails
                // closed rather than asserting (README, "Streaming").
                if (added == 0) return error.StreamTooLong;
                return added;
            }
        }
        added += try r.step();
    }
    if (added == 0) return error.EndOfStream;
    return added;
}

/// Slide the window forward: keep the unconsumed bytes and the retained
/// history (`§3.2.3`'s 32-KiB reach), drop the rest. Returns the free space
/// afterwards.
fn slide(r: *Reader) usize {
    const seek = r.reader.seek;
    const end = r.reader.end;
    const unconsumed = end - seek;
    const keep = @max(unconsumed, @min(end, history_len));
    fastmem.move(u8, r.reader.buffer[0..keep], r.reader.buffer[end - keep ..][0..keep]);
    r.reader.seek = keep - unconsumed;
    r.reader.end = keep;
    return r.reader.buffer.len - keep;
}

/// One step of the decode: a block header, one symbol, or one stored chunk.
/// Returns the bytes added to the window (0 for a header or a block end). The
/// caller guarantees room for one symbol.
fn step(r: *Reader) Error!usize {
    switch (r.phase) {
        .block_header => {
            // §3.2.3 — BFINAL, then BTYPE, two bits LSB-of-value first.
            r.final = (try r.bits.take(1)) != 0;
            const block_type: decode.BlockType = @enumFromInt(
                @as(u2, @intCast(try r.bits.take(2))),
            );
            switch (block_type) {
                .stored => try r.readStoredHeader(),
                .fixed => r.phase = .fixed_block,
                .dynamic => {
                    try decode.readDynamicHeader(&r.bits, &r.literal, &r.distance);
                    r.phase = .dynamic_block;
                },
                .reserved => return error.InvalidBlockType,
            }
            return 0;
        },
        .stored_block => |remaining| return r.copyStored(remaining),
        else => return r.decodeSymbols(),
    }
}

/// `§3.2.4` — a stored block: byte-aligned, LEN and NLEN (u16 little-endian,
/// NLEN the one's complement of LEN), then LEN raw bytes. At the byte
/// boundary the header is the next 32 bits LSB-first (`§3.1.1`), and the
/// payload follows at the next byte boundary.
fn readStoredHeader(r: *Reader) Error!void {
    try r.bits.alignToByte();
    const len: u16 = @intCast(try r.bits.take(16));
    const nlen: u16 = @intCast(try r.bits.take(16));
    if (len != ~nlen) return error.WrongStoredBlockNlen;
    r.phase = .{ .stored_block = len };
}

/// Copy the rest of a stored block's payload into the window, as much as fits:
/// the window slides and the copy resumes, so a block of any size decodes
/// without staging (`§3.2.4`, `§3.3`). A payload cut short is
/// `error.Truncated`.
fn copyStored(r: *Reader, remaining: u16) Error!usize {
    if (remaining == 0) {
        try r.endBlock();
        return 0;
    }
    const input = r.bits.input;
    if (input.seek == input.end) {
        input.fill(1) catch |err| switch (err) {
            error.EndOfStream => return error.Truncated,
            error.ReadFailed => return error.ReadFailed,
        };
    }
    const buffered = input.buffer[input.seek..input.end];
    const free = r.reader.buffer.len - r.reader.end;
    const copied = @min(@min(@as(usize, remaining), free), buffered.len);
    assert(copied > 0);
    fastmem.copy(u8, r.reader.buffer[r.reader.end..][0..copied], buffered[0..copied]);
    input.toss(copied);
    r.reader.end += copied;
    r.total_out += copied;
    r.phase = .{ .stored_block = remaining - @as(u16, @intCast(copied)) };
    return copied;
}

/// One symbol of a Huffman block (`§3.2.7`): a literal, a match whose length
/// is decoded here and whose distance is the next step, or the end-of-block
/// code. The block kind is in `phase`, so the resume point survives a slide.
fn decodeSymbols(r: *Reader) Error!usize {
    switch (r.phase) {
        .fixed_match => |length| return r.copyMatchStep(length, true),
        .dynamic_match => |length| return r.copyMatchStep(length, false),
        else => {},
    }
    const fixed = r.phase == .fixed_block;
    const literal = if (fixed) &decode.fixed_literal else &r.literal;
    const symbol = try literal.decode(&r.bits);
    if (symbol < 256) {
        r.reader.buffer[r.reader.end] = @intCast(symbol);
        r.reader.end += 1;
        r.total_out += 1;
        return 1;
    }
    if (symbol == 256) {
        // §3.2.7 — every block is terminated by the end-of-block symbol.
        try r.endBlock();
        return 0;
    }
    // §3.2.6: values 286-287 "will never actually occur in the compressed
    // data, but participate in the code construction".
    if (symbol > 285) return error.InvalidCode;
    const length = try decode.decodeLength(&r.bits, symbol);
    r.phase = if (fixed)
        .{ .fixed_match = @intCast(length) }
    else
        .{ .dynamic_match = @intCast(length) };
    return 0;
}

/// A match's distance (`§3.2.5`), then the copy: `§3.2.3`'s reach check
/// against the whole output, and the format's overlapping copy.
fn copyMatchStep(r: *Reader, length: u16, fixed: bool) Error!usize {
    const distance = if (fixed) &decode.fixed_distance else &r.distance;
    const symbol = try distance.decode(&r.bits);
    // §3.2.6: distance codes 30-31 "will never actually occur".
    if (symbol > 29) return error.InvalidCode;
    const match_distance = try decode.decodeDistance(&r.bits, symbol);
    // §3.2.3 — "a distance cannot refer past the beginning of the output
    // stream". The window always retains the last 32 KiB of the output, so a
    // distance that passes this check is in the window.
    if (match_distance > r.total_out) return error.InvalidMatch;
    const out_pos = r.reader.end;
    assert(match_distance <= out_pos);
    decode.copyMatch(r.reader.buffer, out_pos, match_distance, length);
    r.reader.end += length;
    r.total_out += length;
    r.phase = if (fixed) .fixed_block else .dynamic_block;
    return length;
}

/// A block ended. `§3.2.3` — BFINAL ends the stream; otherwise the next block
/// header follows at the current bit offset.
fn endBlock(r: *Reader) Error!void {
    if (!r.final) {
        r.phase = .block_header;
        return;
    }
    r.bits.finish();
    r.state = .done;
}

/// The one place a detailed failure becomes the interface's coarse error:
/// `error.ReadFailed` with the detail sticky in `err`, or the clean
/// `error.EndOfStream` once the final block's output is complete.
fn record(r: *Reader, result: Error!usize) Io.Reader.Error!usize {
    return result catch |err| switch (err) {
        error.EndOfStream => {
            r.state = .done;
            return error.EndOfStream;
        },
        else => return fail(r, err),
    };
}

/// Fail closed, stickily. The window's unconsumed bytes are dropped: the
/// README's rule is that no partial output is trusted past the error, so a
/// failed reader serves the error and nothing else — buffered bytes included.
fn fail(r: *Reader, err: Error) Io.Reader.Error {
    r.reader.seek = r.reader.end;
    return internal.reader.fail(Error, &r.state, &r.err, err);
}

/// The generated entries' fill: `fillWindow`'s detailed errors through
/// `record`, so every failure is the interface's `error.ReadFailed` with the
/// detail sticky in `err`. The count is ignored — the data lands in the
/// window (the VTable's store-in-buffer mode), not in the caller's writer.
fn fill(r: *Reader) Io.Reader.Error!usize {
    return r.record(r.fillWindow());
}

/// The generated entries' rebase hook: make room for `capacity` more
/// buffered bytes by sliding the unconsumed bytes and the retained history to
/// the front. A slide frees at least `history_len + unconsumed` bytes, so
/// every request of at most `history_len` bytes is served; a request the
/// window cannot hold at the consumer's position fails closed with
/// `error.ReadFailed` (`err == .StreamTooLong`), never an assert (README,
/// "Streaming").
fn rebase(r: *Reader, capacity: usize) Io.Reader.RebaseError!void {
    _ = r.slide();
    if (r.reader.buffer.len - r.reader.seek < capacity) {
        return fail(r, error.StreamTooLong);
    }
}

// ---------------------------------------------------------------------------
// Tests. Every decode is checked with the sentinel overrun rule: the target is
// pre-filled with cycling sentinels and every byte past the decoded length
// must be untouched.
// ---------------------------------------------------------------------------

/// Pump `r` into `w` until the clean end of stream.
fn pump(r: *Io.Reader, w: *Io.Writer) Io.Reader.StreamError!void {
    while (true) {
        _ = r.stream(w, .unlimited) catch |err| return switch (err) {
            error.EndOfStream => {},
            else => |e| e,
        };
    }
}

/// Decode `r` into `target` through a fixed writer, returning the length.
fn decodeInto(r: *Io.Reader, target: []u8) !usize {
    var w: Io.Writer = .fixed(target);
    try pump(r, &w);
    return w.end;
}

/// Encode `source` with `Writer`, decode with `Reader`, expect identity.
fn roundTrip(source: []const u8) !void {
    const gpa = testing.allocator;
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    const target = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(target);
    sentinel.fill(target);
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    const n = try decodeInto(&r.reader, target);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, target[0..n]);
    try sentinel.expect(target, n);
    // The whole stream is consumed, nothing after it.
    try testing.expectEqual(compressed.written().len, fixed_in.seek);
}

/// Corpus source bytes: repetitive text with a rotating tail, so blocks are
/// both compressible and varied.
fn makeSource(gpa: mem.Allocator, len: usize) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    var rng: DefaultPrng = .init(0xC0FFEE);
    for (buf, 0..) |*b, i| {
        b.* = if (i % 3 == 0) @truncate(i / 7) else rng.random().int(u8);
    }
    return buf;
}

test "Reader: the buffer types are the documented sizes" {
    // README, "Streaming": the Reader's window is 2 * history_len = 64 KiB,
    // the Writer's buffer is max_block_size + history_len = 98303.
    try testing.expectEqual(@as(usize, 65536), @sizeOf(Buffer));
    try testing.expectEqual(@as(usize, 2 * history_len), @sizeOf(Buffer));
    try testing.expectEqual(@as(usize, 98303), @sizeOf(Writer.Buffer));
    try testing.expectEqual(@as(usize, max_block_size + history_len), @sizeOf(Writer.Buffer));
    try testing.expectEqual(@as(usize, 32768), history_len);
    try testing.expectEqual(@as(usize, 65535), max_block_size);
}

test "Reader: the error set mirrors DecompressError minus BufferTooSmall" {
    // README, "API" — `Reader.err`'s type is the `DecompressError` set minus
    // `BufferTooSmall` (the Reader owns its window), plus the interface's
    // `ReadFailed`/`EndOfStream` and the contiguity cap's `StreamTooLong`.
    const mine = @typeInfo(Error).error_set.?;
    for (@typeInfo(decode.DecompressError).error_set.?) |want| {
        if (mem.eql(u8, want.name, "BufferTooSmall")) continue;
        var found = false;
        for (mine) |entry| {
            if (mem.eql(u8, entry.name, want.name)) found = true;
        }
        try testing.expect(found);
    }
}

test "Reader: round-trips through Writer" {
    try roundTrip("");
    try roundTrip("a");
    try roundTrip("hello, flate");
    try roundTrip("the quick brown fox jumps over the lazy dog. " ** 1000);
    try roundTrip("a" ** (max_block_size - 1));
    try roundTrip("b" ** max_block_size);
    try roundTrip("c" ** (max_block_size + 1));
    try roundTrip("d" ** (3 * max_block_size + 17));
}

test "Reader: multi-block inputs round-trip" {
    // Sizes around the 65535-byte split, where the second block's matches may
    // reach back into the first (`§3.2.3`: "the backward distance may cross
    // one or more block boundaries").
    const gpa = testing.allocator;
    const sizes = [_]usize{ 65534, 65535, 65536, 131070, 131071, 200_000 };
    for (sizes) |len| {
        const source = try makeSource(gpa, len);
        defer gpa.free(source);
        roundTrip(source) catch |err| {
            std.debug.print("FAIL: len {d}\n", .{len});
            return err;
        };
    }
    // Incompressible input: every block is stored, so the Reader's stored-block
    // resume across window slides is exercised on a multi-block stream.
    var rng: DefaultPrng = .init(0xC0FFEE);
    const random_bytes = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(random_bytes);
    for (random_bytes) |*b| b.* = rng.random().int(u8);
    try roundTrip(random_bytes);
}

test "Reader: golden golang/go vectors through the streaming reader" {
    // The same fixtures the one-shot decoder is judged against, through the
    // streaming interface: valid streams decode to the golden output and
    // consume exactly their own bytes; rejected streams fail closed with the
    // specific error the README's rules pin.
    const gpa = testing.allocator;
    for (golden.stream_cases) |tc| {
        switch (tc.expect) {
            .ok => |want| {
                const target = try gpa.alloc(u8, want.len + sentinel.len);
                defer gpa.free(target);
                sentinel.fill(target);
                var rbuf: Buffer = undefined;
                var fixed_in: Io.Reader = .fixed(tc.source);
                var r: Reader = .init(&fixed_in, &rbuf);
                const n = decodeInto(&r.reader, target) catch |err| {
                    std.debug.print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
                    return err;
                };
                try testing.expectEqualSlices(u8, want, target[0..n]);
                try sentinel.expect(target, n);
                // The Reader stops at the stream's last byte. Go's vectors
                // carry at most one byte of padding after it (the "spanning
                // repeater code" vector's trailing zero), which must NOT be
                // consumed — `pump` already proved the clean end of stream.
                try testing.expect(fixed_in.seek <= tc.source.len);
                try testing.expect(fixed_in.seek + 1 >= tc.source.len);
            },
            else => {
                var rbuf: Buffer = undefined;
                var fixed_in: Io.Reader = .fixed(tc.source);
                var r: Reader = .init(&fixed_in, &rbuf);
                var out: Io.Writer.Allocating = .init(gpa);
                defer out.deinit();
                try testing.expectError(error.ReadFailed, pump(&r.reader, &out.writer));
                switch (tc.expect) {
                    .fail_with => |want_err| {
                        if (r.err.? != want_err) {
                            std.debug.print("\nFAIL ({s}): {s}, want {s}\n", .{
                                tc.desc, @errorName(r.err.?), @errorName(want_err),
                            });
                            return error.TestUnexpectedResult;
                        }
                    },
                    else => {},
                }
                // The failure is sticky.
                var sink: Io.Writer.Discarding = .init(&.{});
                try testing.expectError(
                    error.ReadFailed,
                    r.reader.stream(&sink.writer, .unlimited),
                );
            },
        }
    }
}

test "Reader: truncated streams fail closed and stay failed" {
    // Spec: rfc1951-deflate.txt §3.2.3 — the stream ends at BFINAL, so any
    // input that ends before it is `error.Truncated`, never a clean end.
    const gpa = testing.allocator;
    for (golden.truncated_cases) |tc| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(tc.source);
        var r: Reader = .init(&fixed_in, &rbuf);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, pump(&r.reader, &out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    }

    // Every prefix of a two-block stream: none may decode cleanly.
    const full = golden.truncated_streams_data;
    var len: usize = 0;
    while (len < full.len) : (len += 1) {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(full[0..len]);
        var r: Reader = .init(&fixed_in, &rbuf);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, pump(&r.reader, &out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);
    }
}

test "Reader: golang/go huffman-* fixtures decode through the stream" {
    // The fixtures are a single non-final block (Go's `writeBlockHuff`), so
    // verbatim each is a truncated stream — and with BFINAL set on that block
    // it decodes to `.input`, exactly as the one-shot decoder does.
    const gpa = testing.allocator;
    for (golden.huffman_fixtures) |fixture| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(fixture.golden);
        var r: Reader = .init(&fixed_in, &rbuf);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, pump(&r.reader, &out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);

        const completed = try gpa.alloc(u8, fixture.golden.len);
        defer gpa.free(completed);
        fastmem.copy(u8, completed, fixture.golden);
        completed[0] |= 1; // BFINAL on the fixture's single block header

        const target = try gpa.alloc(u8, fixture.input.len + sentinel.len);
        defer gpa.free(target);
        sentinel.fill(target);
        var rbuf2: Buffer = undefined;
        var fixed_in2: Io.Reader = .fixed(completed);
        var r2: Reader = .init(&fixed_in2, &rbuf2);
        const n = decodeInto(&r2.reader, target) catch |err| {
            std.debug.print("\nFAIL: {s}: {s}\n", .{ fixture.name, @errorName(err) });
            return err;
        };
        try testing.expectEqual(fixture.input.len, n);
        try testing.expectEqualSlices(u8, fixture.input, target[0..n]);
        try sentinel.expect(target, n);
        try testing.expectEqual(completed.len, fixed_in2.seek);
    }
}

test "Reader: consumes input exactly through the stream's last byte" {
    // README, "Streaming" — "The Reader consumes `input` exactly through the
    // stream's last byte — the final block's partial byte included — and stops
    // there; bytes after the stream are not consumed." The stream is followed
    // by marker bytes through the `Io.Reader` interface: the input's position
    // after the decode is exactly the stream's length.
    const gpa = testing.allocator;
    inline for (.{ "", "a", "the quick brown fox jumps over the lazy dog. " ** 40 }) |source| {
        var compressed: Io.Writer.Allocating = .init(gpa);
        defer compressed.deinit();
        var wbuf: Writer.Buffer = undefined;
        var w: Writer = .init(&compressed.writer, &wbuf, .{});
        try w.writer.writeAll(source);
        try w.finish();

        const markers = 64;
        const buffer = try gpa.alloc(u8, compressed.written().len + markers);
        defer gpa.free(buffer);
        fastmem.copy(u8, buffer[0..compressed.written().len], compressed.written());
        fastmem.set(u8, buffer[compressed.written().len..], 0xAA);

        var fixed_in: Io.Reader = .fixed(buffer);
        var rbuf: Buffer = undefined;
        var r: Reader = .init(&fixed_in, &rbuf);
        const out = try r.reader.allocRemaining(gpa, .unlimited);
        defer gpa.free(out);
        try testing.expectEqualStrings(source, out);
        try testing.expectEqual(compressed.written().len, fixed_in.seek);
    }

    // The same through a `File.Reader`-shaped input: a chunked source whose
    // buffer is refilled as the decode consumes it. The bit reader's lookahead
    // must not read past the stream into the next chunk.
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    const source = try makeSource(gpa, 100_000);
    defer gpa.free(source);
    try w.writer.writeAll(source);
    try w.finish();

    const buffer = try gpa.alloc(u8, compressed.written().len + 8);
    defer gpa.free(buffer);
    fastmem.copy(u8, buffer[0..compressed.written().len], compressed.written());
    fastmem.set(u8, buffer[compressed.written().len..], 0xAA);
    // An 8-byte input buffer: the stream cannot be seen in one piece, so the
    // decode runs on refills mid-symbol. The marker bytes must never reach
    // the decoder as stream bytes.
    var small: [8]u8 = undefined;
    var inner: Io.Reader = .fixed(buffer);
    var chunked: Io.Reader.Limited = .init(&inner, .unlimited, &small);
    var rbuf: Buffer = undefined;
    var r: Reader = .init(&chunked.interface, &rbuf);
    const out = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(out);
    try testing.expectEqualSlices(u8, source, out);
}

test "Reader: a 32-KiB peek is served at any position" {
    // README, "Streaming" — "Any contiguous request (peek/take family) of at
    // most 32 KiB is served": the window holds 64 KiB and slides forward
    // keeping the 32-KiB history tail, so a full-history peek always fits.
    const gpa = testing.allocator;
    const source = try makeSource(gpa, 200_000);
    defer gpa.free(source);
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    // At the start: the request needs the whole window behind it.
    try testing.expectEqualSlices(u8, source[0..history_len], try r.reader.peek(history_len));
    try r.reader.discardAll(60_000);
    // Deep into the stream, where the window must slide to serve it.
    try testing.expectEqualSlices(
        u8,
        source[60_000..][0..history_len],
        try r.reader.peek(history_len),
    );
    // And again after a partial consume, which moves the consumer's position.
    try r.reader.discardAll(1);
    try testing.expectEqualSlices(
        u8,
        source[60_001..][0..history_len],
        try r.reader.peek(history_len),
    );
}

test "Reader: a request past the window fails closed with StreamTooLong" {
    // README, "Streaming" — "a request beyond what the window can hold at the
    // consumer's position fails closed with `error.ReadFailed`
    // (`err == .StreamTooLong`), never an assert". At position 60000 with the
    // window's retained 32-KiB tail, 40000 contiguous bytes do not fit.
    const gpa = testing.allocator;
    const source = try makeSource(gpa, 200_000);
    defer gpa.free(source);
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    _ = try r.reader.peek(history_len);
    try r.reader.discardAll(60_000);
    try testing.expectError(error.ReadFailed, r.reader.peek(40_000));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
    // The failure is sticky, and the interface keeps reporting it.
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.ReadFailed, r.reader.peek(1));
}

test "Reader: a consumer scanning for a delimiter past the window fails closed" {
    // The `fillMore` path (the `peek`/`take`-delimiter family): a consumer
    // scanning for a delimiter inside a line longer than the window asks the
    // machinery for more contiguous bytes than the window can hold beside the
    // retained history. It must fail closed (`ReadFailed`, `err ==
    // .StreamTooLong`), never assert and never spin.
    const gpa = testing.allocator;
    const line_len = 100_000;
    const source = try gpa.alloc(u8, 100 + line_len + 1);
    defer gpa.free(source);
    fastmem.set(u8, source, 'a');
    source[99] = '\n';
    source[source.len - 1] = '\n';

    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    // `takeDelimiterExclusive` leaves the delimiter buffered; the consumer
    // steps over it (the snappy regression test's shape).
    try testing.expectEqualStrings("a" ** 99, try r.reader.takeDelimiterExclusive('\n'));
    r.reader.toss(1);
    try testing.expectError(error.ReadFailed, r.reader.takeDelimiterExclusive('\n'));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
}

test "Reader: a zero-length stream poll does not fail the stream" {
    // std calls vtable stream at limit 0 when the buffer is nonempty: the
    // poll must answer 0 without filling (a fill could fail StreamTooLong
    // on a valid stream with buffered output).
    const gpa = testing.allocator;
    const src = "the quick brown fox jumps over the lazy dog. " ** 6000;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&out.writer, &wbuf, .{});
    try w.writer.writeAll(src);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(out.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    _ = try r.reader.peek(1);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectEqual(@as(usize, 0), try r.reader.stream(&sink.writer, .limited(0)));
    try testing.expect(r.err == null);
    const got = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, src, got);
}

test "Reader: a stream ends cleanly and stickily" {
    // README, "Streaming" — "`Reader` ends cleanly with `error.EndOfStream`
    // (sticky) once the final block's output has been consumed."
    const gpa = testing.allocator;
    const source = "the quick brown fox jumps over the lazy dog. " ** 100;
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    const out = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(out);
    try testing.expectEqualStrings(source, out);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectEqual(@as(?Error, null), r.err);
}

test "Reader: random consumer machinery sequences stay correct" {
    // Mixed peek/take/discardAll/readSliceAll/stream operations over randomly
    // chunked streams: the driver class that catches vtable machinery
    // interactions (contiguity, slide accounting, the sticky end).
    const gpa = testing.allocator;
    var rng: DefaultPrng = .init(4242);
    const rand = rng.random();
    // 200 KB is three window fills, so every iteration slides the window and
    // crosses blocks; the op mix is what the iterations buy.
    const input = try gpa.alloc(u8, 200_000);
    defer gpa.free(input);
    for (input, 0..) |*b, i| b.* = @truncate((i / 7) *% 31 +% rand.uintLessThan(u8, 3));

    var iter: usize = 0;
    while (iter < 50) : (iter += 1) {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var wbuf: Writer.Buffer = undefined;
        var w: Writer = .init(&out.writer, &wbuf, .{});
        var p: usize = 0;
        while (p < input.len) {
            const n = @min(input.len - p, rand.intRangeAtMost(usize, 1, 90_000));
            try w.writer.writeAll(input[p..][0..n]);
            if (rand.uintLessThan(u8, 4) == 0) try w.writer.flush();
            p += n;
        }
        try w.finish();

        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(out.written());
        var r: Reader = .init(&fixed_in, &rbuf);
        var pos: usize = 0;
        while (pos < input.len) {
            const left = input.len - pos;
            switch (rand.uintLessThan(u8, 5)) {
                0 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, history_len));
                    try testing.expectEqualSlices(u8, input[pos..][0..n], try r.reader.peek(n));
                },
                1 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, history_len));
                    try testing.expectEqualSlices(u8, input[pos..][0..n], try r.reader.take(n));
                    pos += n;
                },
                2 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, 200_000));
                    try r.reader.discardAll(n);
                    pos += n;
                },
                3 => {
                    var tmp: [100_000]u8 = undefined;
                    const n = @min(left, rand.intRangeAtMost(usize, 1, tmp.len));
                    try r.reader.readSliceAll(tmp[0..n]);
                    try testing.expectEqualSlices(u8, input[pos..][0..n], tmp[0..n]);
                    pos += n;
                },
                else => {
                    var tmp: [5000]u8 = undefined;
                    var fw: Io.Writer = .fixed(&tmp);
                    const n = @min(left, rand.intRangeAtMost(usize, 0, 5000));
                    _ = try r.reader.stream(&fw, .limited(n));
                    // `stream` may serve from the buffer or fill it; the bytes
                    // land in `fw` or stay buffered. Only the served count is
                    // contractual.
                    const served = @min(n, fw.end);
                    try testing.expectEqualSlices(
                        u8,
                        input[pos..][0..served],
                        fw.buffered()[0..served],
                    );
                    pos += served;
                },
            }
        }
        // The clean end of stream is sticky.
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    }
}

test "Reader: a corrupt stream fails closed and stays failed" {
    // Every failure path is sticky and reports the detail beside the coarse
    // `error.ReadFailed`: a bad block type, a bad stored header, a bad
    // distance, and garbage.
    const gpa = testing.allocator;
    const cases = [_]struct { source: []const u8, want: Error }{
        // §3.2.3 — BTYPE 11 is "reserved (error)".
        .{ .source = &[_]u8{0b0000_0111}, .want = error.InvalidBlockType },
        // §3.2.4 — NLEN must be the one's complement of LEN.
        .{
            .source = &[_]u8{ 0x01, 0x03, 0x00, 0xFD, 0xFF, 'a', 'b', 'c' },
            .want = error.WrongStoredBlockNlen,
        },
        // §3.2.3 — a match at distance 1 with nothing decoded yet: a distance
        // before the start of the output. BFINAL=1, BTYPE=01, length code 257
        // (3 bytes), distance code 0. python3's zlib agrees: "invalid distance
        // too far back".
        .{ .source = &[_]u8{ 0x03, 0x02 }, .want = error.InvalidMatch },
        // A truncated stored payload.
        .{ .source = &[_]u8{ 0x01, 0x0C, 0x00, 0xF3, 0xFF, 'h', 'i' }, .want = error.Truncated },
        // Garbage: a code that decodes to no legal symbol.
        .{
            .source = &[_]u8{ 0x05, 0x00, 0x00, 0x00, 0x00 },
            .want = error.InvalidDynamicBlockHeader,
        },
    };
    for (cases) |tc| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(tc.source);
        var r: Reader = .init(&fixed_in, &rbuf);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, pump(&r.reader, &out.writer));
        try testing.expectEqual(tc.want, r.err.?);
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    }
}

/// Stream everything from `r` through one flate `Reader` into `w`,
/// returning the decoded bytes served. Consumes `r` exactly through the
/// stream's end (the final partial byte included) — bytes after the stream
/// are left unconsumed. The reader and its window live on this stack frame;
/// zero allocation.
pub fn streamAll(r: *Io.Reader, w: *Io.Writer) Io.Reader.StreamRemainingError!usize {
    var buf: Buffer = undefined;
    var rr: Reader = .init(r, &buf);
    return rr.reader.streamRemaining(w);
}
