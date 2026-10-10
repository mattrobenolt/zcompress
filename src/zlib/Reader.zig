//! zlib.Reader: a decompressing `Io.Reader` over one zlib stream (README.md,
//! "Streaming").
//!
//! The machinery is the pattern book's (`src/internal/README.md`, "The Io
//! codec pattern book"): the sticky lifecycle (`state` + the detail in
//! `err`), the zero-length poll, the fill-and-return-0 count, and the
//! contiguity failure all run through `internal.reader.VTable`. What this
//! module adds is the framing: the 2-byte header check before the first body
//! byte, the trailer read and check at the body's clean end, and the stream
//! boundary — `input` is consumed exactly through ADLER32's last byte and
//! stops there (OQ2, `§2.2`).
//!
//! The window is flate's, re-exported: the caller's `Reader.Buffer` is handed
//! to the inner `flate.Reader`, and this reader's serving position is that
//! window's position — one region, one position, no staging copy (OQ6). The
//! decoded bytes are folded into the container's Adler-32 by flate's checksum
//! hook as they enter the window (OQ1), so the trailer check at the clean end
//! hashes nothing again.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;
const print = std.debug.print;

const fastmem = @import("fastmem");

const flate = @import("../flate/root.zig");
/// The caller-provided window: flate's, re-exported — the container adds no
/// buffer of its own (OQ6). `[2 * history_len]u8`, 64 KiB.
pub const Buffer = flate.Reader.Buffer;
const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const State = internal.reader.State;
const VTable = internal.reader.VTable;
const adler32 = @import("adler32.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const golden = @import("golden.zig");
const Writer = @import("Writer.zig");

/// The detailed error recorded once `state == .failed` (README, "API"):
/// flate's decode detail set — minus `BufferTooSmall`, the window is the
/// caller's and flate owns it — plus this module's header and trailer
/// entries.
pub const Error = flate.Reader.Error || error{
    BadHeader,
    DictionaryRequired,
    WrongChecksum,
};

/// Whether the header has been parsed: the check runs once, before the first
/// body byte.
const Header = enum { pending, parsed };

const Reader = @This();

reader: Io.Reader,
inner: flate.Reader,
/// The stream's input: the header is read from it and the trailer read from
/// it, both at flate's exact positions.
input: *Io.Reader,
/// The header check (`§2.2`), run once, before the first body byte.
header: Header = .pending,
/// The checksum state folded through flate's hook: the Adler-32 over the
/// decoded bytes (`§2.2`).
checksum: adler32.Checksum = .{},
/// The stream lifecycle (`src/internal/reader.zig`): `streaming` until the
/// trailer is verified (`done`) or a failure sticks (`failed`, details in
/// `err`).
state: State = .streaming,
/// Detailed error once `state == .failed`; the interface reports
/// `error.ReadFailed`.
err: ?Error = null,

/// The generated `Io.Reader` entries (the pattern book): the sticky guard,
/// the zero-length poll, and the fill-and-return-0 count are structural.
/// `pump` is the stream's fill; `rebase` owns the window's capacity policy.
const vtable = VTable(Reader, pump, rebase).vtable;

/// Wrap `input` (one zlib stream) with `buffer` as the decoded window.
/// Consume through `&r.reader` (`stream`, `read`-family, `peek`-family); the
/// stream ends cleanly with `error.EndOfStream` once the trailer is verified
/// and fails closed with `error.ReadFailed` (sticky, details in `err`) on any
/// malformed header, body, trailer, or input failure. The reader consumes
/// `input` exactly through ADLER32's last byte; bytes after it are "not part
/// of the zlib stream" (`§2.2`) and are left unconsumed (README,
/// "Streaming").
pub fn init(input: *Io.Reader, buffer: *Buffer) Reader {
    return .{
        .reader = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &vtable },
        .inner = flate.Reader.init(input, buffer),
        .input = input,
    };
}

/// The generated entries' fill: the detailed errors through `record` (the
/// pattern book's funnel), so the interface sees `error.ReadFailed` with the
/// detail sticky in `err`, or the clean `error.EndOfStream` once the trailer
/// is verified.
fn pump(r: *Reader) Io.Reader.Error!usize {
    return r.record(r.fillStream());
}

/// The one place a detailed failure becomes the interface's coarse error.
fn record(r: *Reader, result: Error!usize) Io.Reader.Error!usize {
    return result catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => return r.fail(err),
    };
}

/// Fail closed, stickily: the detail is recorded beside the state and the
/// interface's coarse `error.ReadFailed` is returned.
fn fail(r: *Reader, err: Error) Io.Reader.Error {
    return internal.reader.fail(Error, &r.state, &r.err, err);
}

/// One stream fill: the header check (once), then flate's window, then the
/// trailer at the body's clean end.
fn fillStream(r: *Reader) Error!usize {
    if (r.header == .pending) try r.readHeader();
    // The window is flate's: hand it the consumer's position, fill, and take
    // the (possibly slid) position back — one region, one position (OQ6).
    r.inner.reader.seek = r.reader.seek;
    r.inner.reader.end = r.reader.end;
    r.inner.reader.fillMore() catch |err| switch (err) {
        // flate's clean end: the body is complete, and its bit reader
        // consumed the input exactly through the last byte — the trailer is
        // next (the exact-consumption contract, OQ2).
        error.EndOfStream => {
            try r.readTrailer();
            return error.EndOfStream;
        },
        // The detail is recorded by `record`'s funnel, once.
        error.ReadFailed => return r.inner.err.?,
    };
    r.reader.seek = r.inner.reader.seek;
    r.reader.end = r.inner.reader.end;
    assert(r.reader.end > r.reader.seek);
    return r.reader.end - r.reader.seek;
}

/// Check the stream header (`§2.2`, `§2.3`), consuming its two bytes: CM,
/// CINFO, FCHECK, and the FDICT refusal — before any body byte, never a
/// silent skip of the DICTID the flag announces (`§2.3`, ZD3/ZD4). A header
/// cut short by the input's end is `Truncated`.
fn readHeader(r: *Reader) Error!void {
    var header: [decode.header_len]u8 = undefined;
    try decode.readExact(r.input, &header);
    try decode.checkHeader(header[0], header[1]);
    // The checksum hook (OQ1) is armed before the first body byte is
    // decoded: every decoded byte folds into the Adler-32 exactly once, in
    // stream order (`src/flate/Checksum.zig`).
    r.inner.checksum = r.checksum.hook();
    r.header = .parsed;
}

/// Read and verify the trailer at the body's clean end (`§2.2`): the
/// Adler-32 of the decoded bytes, u32 most-significant-byte first (`§2.1`).
/// Verified exactly once, then the reader is `done` (sticky); a mismatch is
/// the specific error, a short trailer `Truncated`.
fn readTrailer(r: *Reader) Error!void {
    var trailer: [decode.trailer_len]u8 = undefined;
    try decode.readExact(r.input, &trailer);
    try decode.checkTrailer(&trailer, r.checksum.final());
    r.state = .done;
    return error.EndOfStream;
}

/// The generated entries' rebase hook: make room for `capacity` more
/// contiguous bytes by sliding flate's window, with the consumer's position
/// synced in. A request the window cannot hold at the consumer's position
/// fails closed with `error.ReadFailed` (`err == .StreamTooLong`), never an
/// assert (the pattern book's contiguity rule).
fn rebase(r: *Reader, capacity: usize) Io.Reader.RebaseError!void {
    r.inner.reader.seek = r.reader.seek;
    r.inner.reader.end = r.reader.end;
    r.inner.reader.rebase(capacity) catch |err| switch (err) {
        // flate's sticky end is the body's clean end: the trailer is next,
        // the same funnel `fillStream` runs — read it, check it, and only
        // then report the clean end. The input stands exactly at the
        // trailer's first byte (the exact-consumption contract), so the
        // check consumes exactly through the stream's last byte.
        error.EndOfStream => {
            r.readTrailer() catch |trailer_err| return switch (trailer_err) {
                error.EndOfStream => error.EndOfStream,
                else => r.fail(trailer_err),
            };
        },
        error.ReadFailed => return r.fail(r.inner.err.?),
    };
    r.reader.seek = r.inner.reader.seek;
    r.reader.end = r.inner.reader.end;
    assert(r.reader.buffer.len - r.reader.seek >= capacity);
}

/// Stream one complete zlib stream from `in` through a stack-buffered
/// `Reader` into `out`, returning the decoded bytes served. Consumes `in`
/// exactly through the stream's last trailer byte; bytes after it are left
/// unconsumed (README, "Streaming"). Zero allocation: the window is a stack
/// local.
pub fn streamAll(in: *Io.Reader, out: *Io.Writer) Io.Reader.StreamRemainingError!usize {
    var buffer: Buffer = undefined;
    var rr: Reader = .init(in, &buffer);
    return rr.reader.streamRemaining(out);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1950-zlib.txt §2.1 (byte order), §2.2
// (the header, the trailer, the stream's end), §2.3 (decoder obligations).
// Every decode is sentinel-checked.
// ---------------------------------------------------------------------------

/// Decode `r` into `target` through a fixed writer, returning the length.
fn decodeInto(r: *Io.Reader, target: []u8) !usize {
    var w: Io.Writer = .fixed(target);
    _ = try r.streamRemaining(&w);
    return w.end;
}

/// Encode `source` with `Writer`, decode it through a `Reader` over `source
/// ++ markers`, and expect identity with the stream boundary intact.
fn roundTrip(source: []const u8) !void {
    const gpa = testing.allocator;
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();
    const stream = compressed.written();
    try golden.expectHeader(stream, .fast);
    try golden.expectTrailer(stream, source);

    const markers = 8;
    const framed = try gpa.alloc(u8, stream.len + markers);
    defer gpa.free(framed);
    fastmem.copy(u8, framed[0..stream.len], stream);
    fastmem.set(u8, framed[stream.len..], 0xaa);

    const target = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(target);
    sentinel.fill(target);
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(framed);
    var r: Reader = .init(&fixed_in, &rbuf);
    const n = try decodeInto(&r.reader, target);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, target[0..n]);
    try sentinel.expect(target, n);
    // The stream boundary: the markers are not the reader's to consume
    // (`§2.2`: "Any data which may appear after ADLER32 are not part of the
    // zlib stream").
    try testing.expectEqual(stream.len, fixed_in.seek);
    try testing.expectEqual(@as(?Error, null), r.err);
    // The clean end is sticky.
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
}

test "Reader: the buffer type is flate's, re-exported" {
    // README, "Caller-owned buffer types": `Reader.Buffer` is
    // `flate.Reader.Buffer` — 2 * history_len, 64 KiB (OQ6).
    try testing.expectEqual(@as(usize, 65536), @sizeOf(Buffer));
    try testing.expect(Buffer == flate.Reader.Buffer);
    try testing.expectEqual(@as(usize, 98303), @sizeOf(Writer.Buffer));
}

test "Reader: the error set mirrors DecompressError minus BufferTooSmall" {
    // README, "API" — `Reader.err`'s type is the `DecompressError` set minus
    // `BufferTooSmall` (the window is the caller's), plus the interface's
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
    try roundTrip("hello, zlib");
    try roundTrip("the quick brown fox jumps over the lazy dog. " ** 1000);
    try roundTrip("a" ** (flate.encode.max_block_size - 1));
    try roundTrip("b" ** flate.encode.max_block_size);
    try roundTrip("c" ** (flate.encode.max_block_size + 1));
    try roundTrip("d" ** (3 * flate.encode.max_block_size + 17));
}

test "Reader: multi-block inputs round-trip" {
    // Sizes around the 65535-byte block split, where the second block's
    // matches reach back into the first (`rfc1951-deflate.txt §3.2.3`).
    const gpa = testing.allocator;
    const sizes = [_]usize{ 65534, 65535, 65536, 131070, 200_000 };
    for (sizes) |len| {
        const source = try gpa.alloc(u8, len);
        defer gpa.free(source);
        var rng: DefaultPrng = .init(0xC0FFEE);
        for (source, 0..) |*byte, i| {
            byte.* = if (i % 3 == 0) @truncate(i / 7) else rng.random().int(u8);
        }
        roundTrip(source) catch |err| {
            print("\nFAIL: len {d}: {s}\n", .{ len, @errorName(err) });
            return err;
        };
    }
    // Incompressible input: every block is stored (`§3.2.4`), so the
    // stored-block resume across window slides runs.
    var rng: DefaultPrng = .init(0x5EED);
    const random_bytes = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(random_bytes);
    for (random_bytes) |*byte| byte.* = rng.random().int(u8);
    try roundTrip(random_bytes);
}

test "Reader: the golden table decodes through the streaming layer" {
    // The same vectors the one-shot decoder is judged against, through the
    // streaming interface: valid streams decode to the golden output and
    // consume exactly their own bytes; the trailing bytes of a case are left
    // unconsumed and the next parse is the pinned outcome (ZD7).
    const gpa = testing.allocator;
    const target = try gpa.alloc(u8, 2048 + @as(usize, sentinel.len));
    defer gpa.free(target);
    for (golden.zlib_cases) |tc| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(tc.source);
        var r: Reader = .init(&fixed_in, &rbuf);
        switch (tc.expect) {
            .ok => |want| {
                sentinel.fill(target);
                const n = decodeInto(&r.reader, target) catch |err| {
                    print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
                    return err;
                };
                try testing.expectEqual(want.len, n);
                try testing.expectEqualSlices(u8, want, target[0..n]);
                try sentinel.expect(target, n);
                try testing.expectEqual(@as(?Error, null), r.err);
                if (tc.trailing == null) {
                    // The stream is the whole input: the boundary is its end.
                    try testing.expectEqual(tc.source.len, fixed_in.seek);
                } else {
                    // The boundary is inside the input; a fresh reader there
                    // sees the pinned trailing outcome.
                    const stream_len = fixed_in.seek;
                    try testing.expect(stream_len < tc.source.len);
                    try checkAtBoundary(gpa, tc.source[stream_len..], tc.trailing.?);
                }
            },
            .fail => try expectStreamFailure(&r, null),
            .fail_with => |want| try expectStreamFailure(&r, want),
        }
    }
}

/// A golden failure through the streaming layer: `error.ReadFailed` with the
/// detail (when the case pins one) sticky in `err`.
fn expectStreamFailure(r: *Reader, want: ?decode.DecompressError) !void {
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&sink.writer));
    if (want) |detail| try testing.expectEqual(detail, r.err.?);
}

/// Decode `source` with a fresh reader and check the boundary outcome: the
/// caller-loop shape (a fresh `Reader` per stream).
fn checkAtBoundary(gpa: mem.Allocator, source: []const u8, expect: golden.Expect) !void {
    const target = try gpa.alloc(u8, 256 + @as(usize, sentinel.len));
    defer gpa.free(target);
    sentinel.fill(target);
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(source);
    var r: Reader = .init(&fixed_in, &rbuf);
    switch (expect) {
        .ok => |want| {
            const n = try decodeInto(&r.reader, target);
            try testing.expectEqual(want.len, n);
            try testing.expectEqualSlices(u8, want, target[0..n]);
            try sentinel.expect(target, n);
        },
        .fail => try expectStreamFailure(&r, null),
        .fail_with => |want| try expectStreamFailure(&r, want),
    }
}

test "Reader: a doubled stream is a caller loop at the boundary" {
    // README, "Streaming": the reader consumes `input` exactly through
    // ADLER32's last byte and stops; nothing in the format promises a second
    // stream follows, but the exact consumption exposes the boundary — a
    // caller loop decodes what the first reader left. The golden table's
    // "stream x2" case pins the same shape (a fresh reader at the boundary
    // decodes the second stream).
    const gpa = testing.allocator;
    var stream: [64]u8 = undefined;
    const source = "hello, zlib";
    const len = try encode.compress(source, &stream, .{});

    var framed: [128 + 8]u8 = undefined;
    fastmem.copy(u8, framed[0..len], stream[0..len]);
    fastmem.copy(u8, framed[len..][0..len], stream[0..len]);
    fastmem.set(u8, framed[2 * len ..], 0xaa);
    const two = framed[0 .. 2 * len + 8];

    var fixed_in: Io.Reader = .fixed(two);
    var first: Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    var second: Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    try testing.expectEqual(source.len, try Reader.streamAll(&fixed_in, &first.writer));
    try testing.expectEqualStrings(source, first.written());
    try testing.expectEqual(len, fixed_in.seek);
    try testing.expectEqual(source.len, try Reader.streamAll(&fixed_in, &second.writer));
    try testing.expectEqualStrings(source, second.written());
    try testing.expectEqual(2 * len, fixed_in.seek);
}

test "Reader: garbage in a stream's place fails closed" {
    // README, "Contracts": decode fails closed at the first invalid byte.
    // The garbage is at least a full header, so the header check is what
    // rejects it (a shorter prefix is a truncated header instead).
    const garbage = "not a zlib stream at all!";
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(garbage);
    var r: Reader = .init(&fixed_in, &rbuf);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(Error.BadHeader, r.err.?);
    // The failure is sticky.
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.ReadFailed, r.reader.peek(1));
}

test "Reader: the dictionary refusal is sticky and before any body byte" {
    // RFC 1950 §2.3 — rejecting an FDICT stream is conformant when the
    // embedding format has no dictionary registry; the four DICTID bytes are
    // never read, never decoded as deflate data (ZD3/ZD4, T6). The refusal
    // arrives at the header, so a valid-looking body behind it is never
    // touched.
    const source = &golden.dictionary_stream; // the Go "dictionary" vector
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(source);
    var r: Reader = .init(&fixed_in, &rbuf);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(Error.DictionaryRequired, r.err.?);
    // Exactly the two header bytes were consumed; the DICTID and body stay.
    try testing.expectEqual(@as(usize, decode.header_len), fixed_in.seek);
    // The failure is sticky: the detail stays recorded and every later read
    // reports it again.
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(Error.DictionaryRequired, r.err.?);
}

test "Reader: a corrupt trailer fails at the clean end, stickily" {
    // README, "Streaming": "At the body's clean end the reader reads and
    // verifies ADLER32 exactly once, and only then reports
    // `error.EndOfStream`". A mismatch is `error.ReadFailed` with the detail
    // in `err` (`§2.3`, T4).
    const gpa = testing.allocator;
    var stream: [128]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try encode.compress(source, &stream, .{});

    for (0..decode.trailer_len) |at| {
        var bad = stream;
        bad[len - decode.trailer_len + at] ^= 0x01;
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(bad[0..len]);
        var r: Reader = .init(&fixed_in, &rbuf);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.WrongChecksum, r.err.?);
        // The decoded bytes are still served (the check is at the end), but
        // no clean end is reported.
        try testing.expectEqualStrings(source, out.written());
    }
}

test "Reader: an over-the-end request still checks the trailer" {
    // The rebase path: a request the window cannot hold at the consumer's
    // position routes through `rebase`, where flate's sticky end fires
    // before the trailer is read. The trailer check must run there too —
    // "verifies the trailer exactly once, and only then reports
    // `error.EndOfStream`" (README, "Streaming") holds on every path, and
    // RFC 1950 §2.3 requires the ADLER32 check unconditionally. Found by
    // the M3 closing review: the input stops 4 bytes short otherwise, and
    // a corrupted stream ends with a clean `EndOfStream`.

    // A stream whose decoded size lands the window deep enough that a
    // 30-KiB request overflows the room at the consumer's position.
    const source = "the quick brown fox jumps over the lazy dog. " ** 950;
    var stream: [encode.maxCompressedLength(43 * 950)]u8 = undefined;
    const len = try encode.compress(source, &stream, .{});

    // The good trailer: the over-the-end request reports the clean end
    // with the input exactly at the stream's last byte (the boundary
    // contract) and the state done.
    {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(stream[0..len]);
        var r: Reader = .init(&fixed_in, &rbuf);
        _ = try r.reader.take(39 * 1024);
        try testing.expectError(error.EndOfStream, r.reader.peek(30 * 1024));
        try testing.expectEqual(@as(usize, len), fixed_in.seek);
        try testing.expectEqual(State.done, r.state);
        try testing.expectEqual(@as(?Error, null), r.err);
    }

    // The corrupted trailer: the same request fails `ReadFailed` with the
    // specific error, on every trailer byte.
    for (0..decode.trailer_len) |at| {
        var bad = stream;
        bad[len - decode.trailer_len + at] ^= 0x01;
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(bad[0..len]);
        var r: Reader = .init(&fixed_in, &rbuf);
        _ = try r.reader.take(39 * 1024);
        try testing.expectError(error.ReadFailed, r.reader.peek(30 * 1024));
        try testing.expectEqual(Error.WrongChecksum, r.err.?);
        try testing.expectEqual(State.failed, r.state);
    }
}

test "Reader: a truncated stream is Truncated at every prefix" {
    // README, "The stream format": a truncated stream — header, body, or
    // trailer — is `error.Truncated`. Every prefix of a real stream fails
    // closed, never decodes cleanly.
    const gpa = testing.allocator;
    var stream: [128]u8 = undefined;
    const len = try encode.compress("hello world\n", &stream, .{});
    for (1..len) |prefix| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(stream[0..prefix]);
        var r: Reader = .init(&fixed_in, &rbuf);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);
    }
}

test "Reader: a contiguous request past the window fails closed" {
    // README, "Streaming": "a request beyond what the window can hold at the
    // consumer's position fails closed with `error.ReadFailed`
    // (`err == .StreamTooLong`), never an assert".
    const gpa = testing.allocator;
    const source = try gpa.alloc(u8, 200_000);
    defer gpa.free(source);
    var rng: DefaultPrng = .init(0xBEEF);
    for (source, 0..) |*byte, i| byte.* = @truncate(i / 7 +% rng.random().int(u8));
    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&stream.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    const history_len = flate.encode.history_len;
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(stream.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    // A full history is always servable (README, "Streaming": "Any
    // contiguous request of at most 32 KiB is served").
    try testing.expectEqualSlices(u8, source[0..history_len], try r.reader.peek(history_len));
    // Drain what the pump buffered: the window's guaranteed contiguous room
    // is exactly the retained history.
    const buffered = r.reader.end - r.reader.seek;
    try r.reader.discardAll(buffered);
    try testing.expectEqualSlices(
        u8,
        source[buffered..][0..history_len],
        try r.reader.peek(history_len),
    );
    // Drain everything the pump buffered, so only the retained history stands
    // behind the next request: a whole-window request cannot fit beside it
    // (a slide retains exactly `history_len` bytes). Fail closed with the
    // contiguity detail, stickily.
    try r.reader.discardAll(r.reader.end - r.reader.seek);
    try testing.expect(r.reader.end > history_len);
    try testing.expectError(error.ReadFailed, r.reader.peek(@sizeOf(Buffer)));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.ReadFailed, r.reader.peek(1));
}

test "Reader: a zero-length poll does not fail the stream" {
    // The pattern book's zero-length poll: std calls `vtable.stream` at
    // limit 0 when the buffer is nonempty, and the poll must answer 0
    // without filling (a fill could fail `StreamTooLong` on a valid stream).
    const gpa = testing.allocator;
    var stream: [64]u8 = undefined;
    const source = "poll";
    const len = try encode.compress(source, &stream, .{});
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(stream[0..len]);
    var r: Reader = .init(&fixed_in, &rbuf);
    _ = try r.reader.peek(1);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectEqual(@as(usize, 0), try r.reader.stream(&sink.writer, .limited(0)));
    try testing.expectEqual(@as(?Error, null), r.err);
    const got = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualStrings(source, got);
}

test "Reader: a chunked input refills across the header and the body" {
    // The input's buffer is small (16 bytes: enough for the 2-byte header and
    // a refill), so the header check, the bit reader, and the trailer read
    // all run on refills — and the marker bytes behind the stream must never
    // reach the decoder.
    const gpa = testing.allocator;
    var stream: [128]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try encode.compress(source, &stream, .{});

    var framed: [144]u8 = undefined;
    fastmem.copy(u8, framed[0..len], stream[0..len]);
    fastmem.set(u8, framed[len..], 0xaa);
    var small: [16]u8 = undefined;
    var inner: Io.Reader = .fixed(framed[0..len]);
    var chunked: Io.Reader.Limited = .init(&inner, .unlimited, &small);
    var rbuf: Buffer = undefined;
    var r: Reader = .init(&chunked.interface, &rbuf);
    const got = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualStrings(source, got);
    try testing.expectEqual(@as(?Error, null), r.err);
}

test "Reader: streamAll consumes one stream and leaves the rest" {
    // README, "Streaming": `Reader.streamAll` consumes one stream and leaves
    // the rest of `in` unconsumed — the same boundary the manual path keeps.
    const gpa = testing.allocator;
    var stream: [64]u8 = undefined;
    const source = "hello, zlib";
    const len = try encode.compress(source, &stream, .{});
    var framed: [64 + 8]u8 = undefined;
    fastmem.copy(u8, framed[0..len], stream[0..len]);
    fastmem.set(u8, framed[len..][0..8], 0xaa);

    var fixed_in: Io.Reader = .fixed(framed[0 .. len + 8]);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectEqual(source.len, try Reader.streamAll(&fixed_in, &out.writer));
    try testing.expectEqualStrings(source, out.written());
    try testing.expectEqual(len, fixed_in.seek);
}
