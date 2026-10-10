//! zlib example CLI: `zlib encode [FILE|-] > out`,
//! `zlib decode [FILE|-] > out`. Shared scaffolding in `examples/cli.zig`.
//!
//! This is the thin-pump shape the streaming layer enables: `encode` wraps
//! stdout in a `zlib.Writer` and pumps the input into it (one stream);
//! `decode` wraps the input in a `zlib.Reader` and pumps it into stdout (one
//! stream — zlib's format is a single stream, `§2.2`: "Any data which may
//! appear after ADLER32 are not part of the zlib stream", so a caller that
//! wants to walk concatenated streams loops at the boundary the reader's
//! exact consumption exposes; the CLI does not, and nothing is silently
//! skipped).
//!
//! Both pumps are stack-buffered end to end: the whole encode/decode path
//! allocates nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const cli = @import("cli");
const zlib = @import("zcompress").zlib;

pub fn main(init: std.process.Init) !u8 {
    return cli.run(.{
        .name = "zlib",
        .encode = encode,
        .decode = decode,
    }, init);
}

fn encode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = try zlib.Writer.streamAll(in, out, .{});
}

fn decode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = try zlib.Reader.streamAll(in, out);
}

test "example: streaming round-trip" {
    var compressed: Io.Writer.Allocating = .init(testing.allocator);
    defer compressed.deinit();

    var in: Io.Reader = .fixed("hello hello hello, streaming zlib round-trip");
    try encode(testing.allocator, &in, &compressed.writer);

    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(compressed.written());
    try decode(testing.allocator, &z, &plain.writer);

    try testing.expectEqualStrings("hello hello hello, streaming zlib round-trip", plain.written());
}

test "example: decode stops at the stream's end" {
    // RFC 1950 §2.2 — "Any data which may appear after ADLER32 are not part
    // of the zlib stream": the pump decodes the stream and leaves whatever
    // follows unconsumed.
    var compressed: Io.Writer.Allocating = .init(testing.allocator);
    defer compressed.deinit();
    var in: Io.Reader = .fixed("hello, zlib");
    try encode(testing.allocator, &in, &compressed.writer);

    // The stream, then marker bytes where a next stream would start.
    var framed: Io.Writer.Allocating = .init(testing.allocator);
    defer framed.deinit();
    try framed.writer.writeAll(compressed.written());
    try framed.writer.splatBytesAll(&[_]u8{0xaa}, 8);

    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(framed.written());
    try decode(testing.allocator, &z, &plain.writer);
    try testing.expectEqualStrings("hello, zlib", plain.written());
    try testing.expectEqual(compressed.written().len, z.seek);
}
