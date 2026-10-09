//! Flate example CLI: `flate encode [FILE|-] > out`,
//! `flate decode [FILE|-] > out`. Shared scaffolding in `examples/cli.zig`.
//!
//! This is the thin-pump shape the streaming layer enables: `encode` wraps
//! stdout in a `flate.Writer` and pumps the input into it; `decode` wraps the
//! input in a `flate.Reader` and pumps it into stdout. Raw deflate needs no
//! framing of its own — BFINAL self-delimits the stream (`RFC 1951 §3.2.3`),
//! so the package's stream format is the deflate stream itself (see
//! `flate.Reader`/`flate.Writer` and `src/flate/README.md`, "Streaming").
//!
//! Both pumps are stack-buffered end to end: the whole encode/decode path
//! allocates nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const cli = @import("cli");
const flate = @import("zcompress").flate;

pub fn main(init: std.process.Init) !u8 {
    return cli.run(.{
        .name = "flate",
        .encode = encode,
        .decode = decode,
    }, init);
}

fn encode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = try flate.Writer.streamAll(in, out, .{});
}

fn decode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = try flate.Reader.streamAll(in, out);
}

test "example: streaming round-trip" {
    var compressed: Io.Writer.Allocating = .init(testing.allocator);
    defer compressed.deinit();

    var in: Io.Reader = .fixed("hello hello hello, streaming flate round-trip");
    try encode(testing.allocator, &in, &compressed.writer);

    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(compressed.written());
    try decode(testing.allocator, &z, &plain.writer);

    try testing.expectEqualStrings("hello hello hello, streaming flate round-trip", plain.written());
}
