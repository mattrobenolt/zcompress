//! gzip example CLI: `gzip encode [FILE|-] > out`,
//! `gzip decode [FILE|-] > out`. Shared scaffolding in `examples/cli.zig`.
//!
//! This is the thin-pump shape the streaming layer enables: `encode` wraps
//! stdout in a `gzip.Writer` and pumps the input into it (one member);
//! `decode` walks the input member by member, one `gzip.Reader` per member —
//! the multi-member caller loop the container's boundary contract documents
//! (src/gzip/README.md, "The wrapping design": a reader consumes exactly one
//! member and leaves the rest; garbage in a next member's place fails
//! `BadHeader`). A trailing byte that is not a member is therefore an error,
//! never silently ignored.
//!
//! Both pumps are stack-buffered end to end: the whole encode/decode path
//! allocates nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const cli = @import("cli");
const gzip = @import("zcompress").gzip;

pub fn main(init: std.process.Init) !u8 {
    return cli.run(.{
        .name = "gzip",
        .encode = encode,
        .decode = decode,
    }, init);
}

fn encode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = try gzip.Writer.streamAll(in, out, .{});
}

fn decode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    while (true) {
        // A clean end between members is the file's end; any byte where a
        // member should start is parsed as one, so garbage fails closed.
        _ = in.peekByte() catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        _ = try gzip.Reader.streamAll(in, out);
    }
}

test "example: streaming round-trip" {
    var compressed: Io.Writer.Allocating = .init(testing.allocator);
    defer compressed.deinit();

    var in: Io.Reader = .fixed("hello hello hello, streaming gzip round-trip");
    try encode(testing.allocator, &in, &compressed.writer);

    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(compressed.written());
    try decode(testing.allocator, &z, &plain.writer);

    try testing.expectEqualStrings("hello hello hello, streaming gzip round-trip", plain.written());
}

test "example: the decode loop walks a multi-member file" {
    // RFC 1952 §2.2 — members appear one after another: the CLI decodes all
    // of them, and a trailing byte that is not a member fails closed.
    var members: Io.Writer.Allocating = .init(testing.allocator);
    defer members.deinit();
    inline for (.{ "first ", "second" }) |part| {
        var in: Io.Reader = .fixed(part);
        try encode(testing.allocator, &in, &members.writer);
    }
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(members.written());
    try decode(testing.allocator, &z, &plain.writer);
    try testing.expectEqualStrings("first second", plain.written());

    // Trailing garbage: the next member's header parse fails (`BadHeader`).
    try members.writer.writeByte(0x00);
    var bad: Io.Writer.Allocating = .init(testing.allocator);
    defer bad.deinit();
    var bad_in: Io.Reader = .fixed(members.written());
    try testing.expectError(
        error.ReadFailed,
        decode(testing.allocator, &bad_in, &bad.writer),
    );
}
