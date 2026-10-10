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
//! (`decoded_region_len`): a `peek` beyond it fails closed (`err ==
//! .StreamTooLong`), never an assert.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const VTable = internal.reader.VTable;
const State = internal.reader.State;
const common = @import("common.zig");
const readInt = common.readInt;
const writeInt = common.writeInt;
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const golden = @import("golden.zig");
const Writer = @import("Writer.zig");

/// The caller-provided buffer: two decoded blocks plus the compressed-block
/// staging region.
pub const Buffer = [decoded_region_len + Writer.scratch_len]u8;

/// Two blocks of contiguous decoded serving region.
const decoded_region_len = 3 * encode.max_block_size;

const Reader = @This();

/// The detailed error recorded once `state == .failed` (the interface reports
/// `error.ReadFailed`): framing errors are ours (`Truncated`, `InvalidStream`,
/// `StreamTooLong`), block errors come from `decode.DecompressError`, and
/// `ReadFailed`/`EndOfStream` pass through from the input.
pub const Error = error{
    Truncated,
    InvalidStream,
    StreamTooLong,
} || decode.DecompressError || error{ ReadFailed, EndOfStream };

reader: Io.Reader,
input: *Io.Reader,
staging: *[Writer.scratch_len]u8,
/// The stream lifecycle (src/internal/reader.zig): `streaming` until the
/// input ends cleanly at a block boundary (`done`) or a failure sticks
/// (`failed`, details in `err`).
state: State = .streaming,
/// Detailed error once `state == .failed`; the interface reports
/// `error.ReadFailed`.
err: ?Error = null,

/// The generated `Io.Reader` entries (src/internal/README.md, "The Io codec
/// pattern book"): the sticky guard, the zero-length poll, and the
/// fill-and-return-0 count are structural. `fillNextBlock` is the pump;
/// `rebase` owns the region's capacity policy.
const vtable = VTable(Reader, fillNextBlock, rebase).vtable;

/// Wrap `input` (a framed snappy stream) with `buffer` for decoded output.
/// Consume through `&r.reader` (`stream`, `read`-family, `peek`-family);
/// the stream ends cleanly with `error.EndOfStream` at a block boundary and
/// fails closed with `error.ReadFailed` (sticky, details in `err`) on any
/// corrupt framing or block.
pub fn init(input: *Io.Reader, buffer: *Buffer) Reader {
    return .{
        .reader = .{
            .buffer = buffer[0..decoded_region_len],
            .seek = 0,
            .end = 0,
            .vtable = &vtable,
        },
        .input = input,
        .staging = buffer[decoded_region_len..],
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
        // The consumer asked for more contiguous bytes than the region can
        // hold beside a fresh block: fail closed, never assert on it.
        if (r.reader.end + encode.max_block_size > decoded_region_len) {
            return fail(r, error.StreamTooLong);
        }
    }

    // Zero bytes read at a block boundary is the clean, sticky end of the
    // stream; 1-3 bytes is a truncated framing prefix.
    var prefix: [4]u8 = undefined;
    const prefix_len = r.input.readSliceShort(&prefix) catch |e| return fail(r, e);
    if (prefix_len == 0) {
        r.state = .done;
        return error.EndOfStream;
    }
    if (prefix_len < 4) return fail(r, error.Truncated);
    const block_len = readInt(u32, &prefix);
    if (block_len == 0 or block_len > Writer.scratch_len) return fail(r, error.InvalidStream);

    // A short block read is corrupt framing: the length was declared.
    r.input.readSliceAll(r.staging[0..block_len]) catch |e| return switch (e) {
        error.EndOfStream => fail(r, error.Truncated),
        else => |e2| fail(r, e2),
    };

    const block = r.staging[0..block_len];
    const decoded_len = decode.decompressedBlockLength(block) catch |err| return fail(r, err);
    // Our framing never declares a decoded block over one block; a hostile
    // stream does not get the staging region. An empty decoded block is
    // degenerate but valid snappy (the golden table's first case), and our
    // Writer never emits one: it is accepted, and `stream` simply returns 0.
    if (decoded_len > encode.max_block_size) return fail(r, error.InvalidStream);
    const dest = r.reader.buffer[r.reader.end..][0..decoded_len];
    const n = decode.decompressBlock(block, dest) catch |err| return fail(r, err);
    assert(n == decoded_len);
    r.reader.end += n;
    return 0;
}

fn fail(r: *Reader, err: Error) Io.Reader.Error {
    return internal.reader.fail(Error, &r.state, &r.err, err);
}

/// The generated entries' rebase hook: slide the unconsumed bytes to the
/// front, so the serving region then has `decoded_region_len - end`
/// contiguous free.
///
/// A capacity past the serving region (a plain consumer `peek` — the
/// buffer capacity is the full `Buffer`, larger than the region, so std's
/// `peek` assert does not catch it first) fails closed, never asserts.
fn rebase(r: *Reader, capacity: usize) Io.Reader.RebaseError!void {
    const keep = r.reader.end - r.reader.seek;
    fastmem.move(u8, r.reader.buffer[0..keep], r.reader.buffer[r.reader.seek..][0..keep]);
    r.reader.seek = 0;
    r.reader.end = keep;
    if (capacity > decoded_region_len) return fail(r, error.StreamTooLong);
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

test "Reader: golden golang/snappy vectors through the framed stream" {
    // Every golden block (valid and corrupt), framed per the stream format,
    // decoded through Reader: valid cases produce the golden output and end
    // at a clean end of stream; corrupt cases fail closed and stay failed.
    const gpa = testing.allocator;
    for (golden.golden_decode_cases) |tc| {
        var frame_buf: [128]u8 = undefined;
        const frame = framedBlock(tc.source, &frame_buf);

        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(frame);
        var r: Reader = .init(&fixed_in, &rbuf);
        var plain: Io.Writer.Allocating = .init(gpa);
        defer plain.deinit();

        if (tc.want_err) {
            try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&plain.writer));
            var sink: Io.Writer.Discarding = .init(&.{});
            try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
            continue;
        }
        _ = r.reader.streamRemaining(&plain.writer) catch |err| {
            std.debug.print("\nFAIL: {s}\n", .{tc.desc});
            return err;
        };
        try testing.expectEqualSlices(u8, tc.want, plain.written());
    }
}

test "Reader: golden outputs round-trip Writer -> Reader" {
    for (golden.golden_decode_cases) |tc| {
        if (tc.want_err) continue; // Corrupt sources have no output.
        roundTrip(tc.want) catch |err| {
            std.debug.print("\nFAIL: {s}\n", .{tc.desc});
            return err;
        };
    }
}

test "Reader: a zero-length stream poll does not fail the stream" {
    // std calls vtable stream at limit 0 when the buffer is nonempty: the
    // poll must answer 0 without filling (a fill could fail StreamTooLong
    // on a valid stream with buffered output — the serving region cannot
    // always hold a fresh block beside unconsumed bytes).
    const gpa = testing.allocator;
    const src = "the quick brown fox jumps over the lazy dog. " ** 3000;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&out.writer, &wbuf);
    try w.writer.writeAll(src);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(out.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    _ = try r.reader.peek(1);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectEqual(@as(usize, 0), try r.reader.stream(&sink.writer, .limited(0)));
    try testing.expect(r.err == null);
    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    _ = try r.reader.streamRemaining(&plain.writer);
    try testing.expectEqualSlices(u8, src, plain.written());
}

test "Reader: random consumer machinery sequences stay correct" {
    // Mixed peek/take/discardAll/readSliceAll/stream operations over randomly
    // chunked streams: this is the driver class that catches vtable machinery
    // interactions (the R1 contiguity bug asserted on ordinary consumer calls
    // like `takeDelimiterExclusive`).
    const gpa = testing.allocator;
    var rng: DefaultPrng = .init(4242);
    const rand = rng.random();
    const input = try gpa.alloc(u8, 400_000);
    defer gpa.free(input);
    for (input, 0..) |*b, i| b.* = @truncate((i / 7) *% 31 +% rand.uintLessThan(u8, 3));

    var iter: usize = 0;
    while (iter < 120) : (iter += 1) {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var wbuf: Writer.Buffer = undefined;
        var w: Writer = .init(&out.writer, &wbuf);
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
                    const n = @min(left, rand.intRangeAtMost(usize, 1, encode.max_block_size));
                    try testing.expectEqualSlices(u8, input[pos..][0..n], try r.reader.peek(n));
                },
                1 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, encode.max_block_size));
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
                    const served_bytes = fw.buffered()[0..served];
                    try testing.expectEqualSlices(u8, input[pos..][0..served], served_bytes);
                    pos += served;
                },
            }
        }
        // The clean end of stream is sticky.
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    }
}

test "Reader: a peek past the serving region fails closed" {
    // README, "Streaming" — a request beyond the contiguous cap fails
    // closed with `error.ReadFailed` (`err == .StreamTooLong`), never an
    // assert. `peek` routes the consumer's request through the vtable's
    // rebase as the capacity, so a request larger than the serving region
    // reaches rebase itself.
    const gpa = testing.allocator;
    const src = "the quick brown fox jumps over the lazy dog. " ** 4000;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&out.writer, &wbuf);
    try w.writer.writeAll(src);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(out.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    try testing.expectError(error.ReadFailed, r.reader.peek(decoded_region_len + 1));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
}

test "Reader: a contiguous request past the two-block cap fails closed" {
    // A consumer scanning for a delimiter inside an incompressible line
    // longer than the cap asks the machinery for more contiguous bytes than
    // the serving region can hold beside a fresh block. This must fail
    // closed (`ReadFailed`, `err == .StreamTooLong`), never assert.
    const gpa = testing.allocator;
    const line_len: usize = 180_000;
    var input: [60_000 + line_len + 1]u8 = undefined;
    for (&input) |*b| b.* = 'a';
    input[59_999] = '\n';
    input[input.len - 1] = '\n';

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&out.writer, &wbuf);
    try w.writer.writeAll(&input);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(out.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    _ = try r.reader.takeDelimiterExclusive('\n');
    r.reader.toss(1);
    try testing.expectError(error.ReadFailed, r.reader.takeDelimiterExclusive('\n'));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
}

/// Frame one raw block for a golden stream test: the `u32-le` length
/// prefix plus the block. Asserts `buf` can hold the frame.
fn framedBlock(source: []const u8, buf: []u8) []u8 {
    assert(source.len + 4 <= buf.len);
    writeInt(u32, buf.ptr[0..4], @intCast(source.len));
    fastmem.copy(u8, buf[4..][0..source.len], source);
    return buf[0 .. 4 + source.len];
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
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        // The failure is sticky.
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    }
}

test "Reader: peek across blocks stays contiguous" {
    // The documented cap is two blocks of contiguous decoded reads: after
    // an unaligned take, a peek spanning the cap must stay contiguous (the
    // append + slide path of fillNextBlock).
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
    _ = try r.reader.take(1000);
    const peek_len = 2 * encode.max_block_size - 1000;
    const peeked = try r.reader.peek(peek_len);
    try testing.expectEqualSlices(u8, src[1000..][0..peek_len], peeked);
}

test "Reader: a framed block decoding past one block fails closed" {
    // The framing amplification guard: the golden Copy4 block decodes to
    // 65545 bytes, over the one-block cap — a hostile stream does not get
    // the serving region.
    const gpa = testing.allocator;
    var source: [golden.copy4_source_len]u8 = undefined;
    golden.buildCopy4Source(&source);

    var frame_buf: [golden.copy4_source_len + 4]u8 = undefined;
    const frame = framedBlock(&source, &frame_buf);

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(frame);
    var r: Reader = .init(&fixed_in, &rbuf);
    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&plain.writer));
    try testing.expectEqual(Error.InvalidStream, r.err.?);
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
    _ = try r.reader.streamRemaining(&plain.writer);
    try testing.expectEqual(src.len, plain.written().len);
    try testing.expectEqualSlices(u8, src, plain.written());
}

/// Stream everything from `in` through one snappy `Reader` into `out`,
/// returning the decoded bytes served. Consumes `in` exactly through the
/// stream's end. The reader and its buffer live on this stack frame; zero
/// allocation.
pub fn streamAll(in: *Io.Reader, out: *Io.Writer) Io.Reader.StreamRemainingError!usize {
    var buf: Buffer = undefined;
    var rr: Reader = .init(in, &buf);
    return rr.reader.streamRemaining(out);
}
