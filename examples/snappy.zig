//! Snappy example CLI: `snappy encode [FILE|-] > out`,
//! `snappy decode [FILE|-] > out`. Shared scaffolding in `examples/cli.zig`.
//!
//! This is the thin-pump shape the streaming layer enables: `encode` wraps
//! stdout in a `snappy.Writer` and pumps stdin into it; `decode` wraps stdin
//! in a `snappy.Reader` and pumps it into stdout. The framing
//! (`u32-le compressed_length + raw block`, split at `snappy.max_block_size`)
//! is the package's stream format — it lives in `src/snappy/` (see
//! `snappy.Reader`/`snappy.Writer` and `src/snappy/README.md`), not here.
//!
//! Both pumps are stack-buffered end to end: the whole encode/decode path
//! allocates nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const cli = @import("cli");
const snappy = @import("snappy");

pub fn main(init: std.process.Init) !u8 {
    return cli.run(.{
        .name = "snappy",
        .encode = encode,
        .decode = decode,
    }, init);
}

fn encode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    var buf: snappy.WriterBuffer = undefined;
    var w: snappy.Writer = .init(out, &buf);
    while (true) {
        _ = in.stream(&w.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
    }
    try w.finish();
}

fn decode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    var buf: snappy.ReaderBuffer = undefined;
    var r: snappy.Reader = .init(in, &buf);
    while (true) {
        _ = r.reader.stream(out, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
    }
}

test "example: streaming round-trip" {
    var compressed: Io.Writer.Allocating = .init(testing.allocator);
    defer compressed.deinit();

    var in: Io.Reader = .fixed("hello hello hello, streaming snappy round-trip");
    try encode(testing.allocator, &in, &compressed.writer);

    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(compressed.written());
    try decode(testing.allocator, &z, &plain.writer);

    try testing.expectEqualStrings("hello hello hello, streaming snappy round-trip", plain.written());
}
