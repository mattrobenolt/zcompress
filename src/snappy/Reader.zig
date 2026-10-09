//! snappy.Reader: a decompressing `Io.Reader` over the framed snappy stream
//! (README.md, "Streaming") produced by `Writer`.
//!
//! Buffer layout: `buffer[0..decoded_region_len]` is the decoded serving
//! region (two blocks, so a `peek` of up to two blocks is contiguous), and the
//! bytes behind it stage one compressed block during decode. Zero
//! allocation; the block decodes run through `decompressBlock`.
//!
//! The input's own buffer must hold at least 4 bytes (or the stream must end
//! before then). The contiguous decoded read cap is two blocks
//! (`decoded_region_len`): a `peek` beyond it asserts.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const common = @import("common.zig");
const readInt = common.readInt;
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const Writer = @import("Writer.zig");

/// The caller-provided buffer: two decoded blocks plus the compressed-block
/// staging region.
pub const Buffer = [decoded_region_len + Writer.scratch_len]u8;

/// Two blocks of contiguous decoded serving region.
const decoded_region_len = 2 * encode.max_block_size;

pub const Reader = @This();

reader: Io.Reader,
input: *Io.Reader,
/// Detailed error after a failure; the interface reports `error.ReadFailed`.
err: ?anyerror = null,
/// Set once the input ended cleanly at a block boundary.
done: bool = false,

const vtable: Io.Reader.VTable = .{
    .stream = stream,
    .discard = discard,
    .readVec = readVec,
    .rebase = rebase,
};

/// Wrap `input` (a framed snappy stream) with `buffer` for decoded output.
/// Consume through `&r.reader` (`stream`, `read`-family, `peek`-family);
/// the stream ends cleanly with `error.EndOfStream` at a block boundary and
/// fails closed with `error.ReadFailed` (sticky, details in `err`) on any
/// corrupt framing or block.
pub fn init(input: *Io.Reader, buffer: *Buffer) Reader {
    return .{
        .reader = .{
            .buffer = buffer,
            .seek = 0,
            .end = 0,
            .vtable = &vtable,
        },
        .input = input,
    };
}

/// Decode the next framed block into the serving region, appending after any
/// unconsumed bytes (sliding to the front first when the region lacks room
/// for a block). Returns 0: the data lands in `reader.buffer` per the
/// VTable contract.
fn fillNextBlock(r: *Reader) Io.Reader.Error!usize {
    if (r.reader.end + encode.max_block_size > decoded_region_len) {
        // Slide the unconsumed bytes to the front to make room for a block.
        const keep = r.reader.end - r.reader.seek;
        fastmem.move(u8, r.reader.buffer[0..keep], r.reader.buffer[r.reader.seek..][0..keep]);
        r.reader.seek = 0;
        r.reader.end = keep;
        assert(r.reader.end + encode.max_block_size <= decoded_region_len);
    }

    // Zero bytes available at a block boundary is the clean, sticky end of
    // the stream.
    _ = r.input.peek(1) catch |err| switch (err) {
        error.EndOfStream => {
            r.done = true;
            return error.EndOfStream;
        },
        else => |e| return fail(r, e),
    };
    // Some bytes remain, so the 4-byte prefix must be complete.
    const prefix = r.input.take(4) catch |err| switch (err) {
        error.EndOfStream => return fail(r, error.Truncated),
        else => |e| return fail(r, e),
    };
    const block_len = readInt(u32, prefix.ptr[0..4]);
    if (block_len == 0 or block_len > Writer.scratch_len) return fail(r, error.InvalidStream);

    const staging = r.reader.buffer[decoded_region_len..];
    readExact(r.input, staging[0..block_len]) catch |err| switch (err) {
        // The block was cut short: corrupt framing.
        error.EndOfStream => return fail(r, error.Truncated),
        else => |e| return fail(r, e),
    };

    const block = staging[0..block_len];
    const decoded_len = decode.decompressedBlockLen(block) catch |err| return fail(r, err);
    // Our framing never declares a decoded block over one block; a hostile
    // stream does not get the staging region.
    if (decoded_len > encode.max_block_size) return fail(r, error.InvalidStream);
    const dest = r.reader.buffer[r.reader.end..][0..decoded_len];
    const n = decode.decompressBlock(block, dest) catch |err| return fail(r, err);
    assert(n == decoded_len);
    r.reader.end += n;
    return 0;
}

fn fail(r: *Reader, err: anyerror) Io.Reader.Error {
    r.err = err;
    return error.ReadFailed;
}

/// Read exactly `dest.len` bytes from `input`. A short input is
/// `error.EndOfStream` (the caller maps it to corrupt framing).
fn readExact(input: *Io.Reader, dest: []u8) Io.Reader.Error!void {
    var fw: Io.Writer = .fixed(dest);
    while (fw.end < dest.len) {
        _ = input.stream(&fw, .limited(dest.len - fw.end)) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
            // `stream` writes at most the remaining capacity of `fw`.
            error.WriteFailed => unreachable,
        };
    }
}

fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    _ = w;
    _ = limit;
    const parent: *Reader = @alignCast(@fieldParentPtr("reader", r));
    if (parent.err != null) return error.ReadFailed;
    if (parent.done) return error.EndOfStream;
    return fillNextBlock(parent);
}

fn discard(r: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
    const parent: *Reader = @alignCast(@fieldParentPtr("reader", r));
    if (parent.err != null) return error.ReadFailed;
    if (parent.done) return error.EndOfStream;
    _ = try fillNextBlock(parent);
    const n = limit.minInt(r.end - r.seek);
    r.seek += n;
    return n;
}

fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    _ = data;
    const parent: *Reader = @alignCast(@fieldParentPtr("reader", r));
    if (parent.err != null) return error.ReadFailed;
    if (parent.done) return error.EndOfStream;
    return fillNextBlock(parent);
}

/// Slide the unconsumed bytes to the front; the serving region then has
/// `decoded_region_len - end` contiguous free.
fn rebase(r: *Io.Reader, capacity: usize) Io.Reader.RebaseError!void {
    const keep = r.end - r.seek;
    fastmem.move(u8, r.buffer[0..keep], r.buffer[r.seek..][0..keep]);
    r.seek = 0;
    r.end = keep;
    assert(capacity + r.end <= decoded_region_len);
}

test "Reader: round-trips through Writer" {
    try roundTrip("");
    try roundTrip("hello, snappy");
    try roundTrip("the quick brown fox jumps over the lazy dog. " ** 1000);
    try roundTrip("a" ** (encode.max_block_size - 1));
    try roundTrip("b" ** encode.max_block_size);
    try roundTrip("c" ** (encode.max_block_size + 1));
}

test "Reader: random multi-block input round-trips" {
    var input: [150 * 1024]u8 = undefined;
    var rng: DefaultPrng = .init(0xC0FFEE);
    for (&input) |*b| b.* = rng.random().int(u8);
    try roundTrip(&input);
}

test "Reader: corrupt framing fails closed and stays failed" {
    const cases = [_][]const u8{
        "\x01\x02", // truncated prefix
        "\x00\x00\x00\x00", // declared length 0
        "\xff\xff\xff\xff", // declared length past staging
        "\x05\x00\x00\x00ab", // block cut short
        "\x10\x00\x00\x00" ++ "garbage bytes!", // garbage block
    };
    for (cases) |input| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(input);
        var r: Reader = .init(&fixed_in, &rbuf);
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, pump(&r.reader, &out.writer));
        // The failure is sticky.
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    }
}

test "Reader: peek across blocks stays contiguous" {
    const src = "the quick brown fox jumps over the lazy dog. " ** 4000; // ~172 KiB
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&out.writer, &wbuf);
    try w.writer.writeAll(src);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(out.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    // Consume some, then peek a full block (the append + slide path).
    _ = try r.reader.take(1000);
    const peeked = try r.reader.peek(encode.max_block_size);
    try testing.expectEqualSlices(u8, src[1000 .. 1000 + encode.max_block_size], peeked);
}

/// Pump `r` into `w` until the clean end of stream.
fn pump(r: *Io.Reader, w: *Io.Writer) Io.Reader.StreamError!void {
    while (true) {
        _ = r.stream(w, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
    }
}

/// Encode `src` with `Writer`, decode with `Reader`, expect identity.
fn roundTrip(src: []const u8) !void {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&out.writer, &wbuf);
    try w.writer.writeAll(src);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(out.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    try pump(&r.reader, &plain.writer);
    try testing.expectEqual(src.len, plain.written().len);
    try testing.expectEqualSlices(u8, src, plain.written());
}
