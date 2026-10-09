//! Shared scaffolding for the per-codec example CLIs.
//!
//! Each codec gets a thin executable (`examples/<codec>.zig`) that names the
//! codec and provides streaming `encode`/`decode` pumps. This file owns
//! everything the codecs share: argument parsing, input (a file, or stdin
//! via `-` or no argument) as an `Io.File.Reader`, stdout, and error
//! handling.
//!
//! Usage (per codec): `<codec> encode [FILE|-] > out`, `<codec> decode [FILE|-] > out`.
//! Errors propagate to an error return trace with a nonzero exit code.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;
const stringToEnum = std.meta.stringToEnum;
const mem = std.mem;
const Allocator = mem.Allocator;
const process = std.process;

pub const Codec = struct {
    name: []const u8,
    /// Encode the whole input and write the encoded stream to `out`.
    encode: *const fn (arena: Allocator, in: *Io.Reader, out: *Io.Writer) anyerror!void,
    /// Decode a stream produced by `encode` and write the decoded bytes.
    decode: *const fn (arena: Allocator, in: *Io.Reader, out: *Io.Writer) anyerror!void,
};

const Mode = enum {
    encode,
    decode,
};

pub fn run(codec: Codec, init: process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage(codec.name);

    const cmd = args[1];
    const rest = args[2..];

    const mode = stringToEnum(Mode, cmd) orelse return usage(codec.name);

    const path: ?[]const u8 = switch (rest.len) {
        0 => null,
        1 => if (mem.eql(u8, rest[0], "-")) null else rest[0],
        else => return usage(codec.name),
    };

    const input: Io.File = if (path) |p| try Io.Dir.cwd().openFile(io, p, .{
        .allow_directory = false,
        .follow_symlinks = true,
    }) else .stdin();

    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(input, io, &read_buffer);
    const reader = &file_reader.interface;

    var write_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &write_buffer);
    const writer = &stdout_writer.interface;
    // Best-effort flush on every exit path; errors are unreportable here.
    defer writer.flush() catch {};

    const op = switch (mode) {
        .encode => codec.encode,
        .decode => codec.decode,
    };
    try op(arena, reader, writer);
    return 0;
}

fn usage(name: []const u8) u8 {
    print("usage: {s} encode|decode [FILE|-] > out\n", .{name});
    return 1;
}
