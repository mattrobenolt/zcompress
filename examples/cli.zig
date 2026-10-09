//! Shared scaffolding for the per-codec example CLIs.
//!
//! Each codec gets a thin executable (`examples/<codec>.zig`) that names the
//! codec and provides whole-input `encode`/`decode`. This file owns
//! everything the codecs share: argument parsing, input (a file, or stdin
//! via `-` or no argument), stdout, error reporting, and exit codes.
//!
//! Usage (per codec): `<codec> encode [FILE|-] > out`, `<codec> decode [FILE|-] > out`.
//!
//! These CLIs read the whole input before encoding. They exist to feel the
//! codec APIs in real usage, not to stream; streaming CLIs arrive with the
//! streaming cores (docs/zcompress-plan.md, API layers). Exit codes: 0 ok,
//! 1 usage, 2 codec error.

const std = @import("std");
const Io = std.Io;

/// Input cap. Whole-file reads beyond this fail closed rather than OOM.
const input_limit: Io.Limit = .limited64(1 << 30);

pub const Codec = struct {
    name: []const u8,
    /// Encode the whole input and write the encoded stream to `out`.
    encode: *const fn (allocator: std.mem.Allocator, input: []const u8, out: *Io.Writer) anyerror!void,
    /// Decode a stream produced by `encode` and write the decoded bytes.
    decode: *const fn (allocator: std.mem.Allocator, input: []const u8, out: *Io.Writer) anyerror!void,
};

pub fn run(codec: Codec, init: std.process.Init) !u8 {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage(codec.name);
    const mode: enum { encode, decode } =
        if (std.mem.eql(u8, args[1], "encode")) .encode else if (std.mem.eql(u8, args[1], "decode")) .decode else return usage(codec.name);
    const path: ?[]const u8 = switch (args.len) {
        2 => null,
        3 => if (std.mem.eql(u8, args[2], "-")) null else args[2],
        else => return usage(codec.name),
    };

    const input: []const u8 = if (path) |p|
        Io.Dir.cwd().readFileAlloc(io, p, arena, input_limit) catch |err| {
            std.debug.print("{s}: {s}: {s}\n", .{ codec.name, @errorName(err), p });
            return 2;
        }
    else blk: {
        var stdin_buffer: [64 * 1024]u8 = undefined;
        var stdin: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
        break :blk stdin.interface.allocRemaining(arena, input_limit) catch |err| {
            std.debug.print("{s}: {s}: <stdin>\n", .{ codec.name, @errorName(err) });
            return 2;
        };
    };

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout.interface;

    const op = switch (mode) {
        .encode => codec.encode,
        .decode => codec.decode,
    };
    op(arena, input, out) catch |err| {
        std.debug.print("{s}: {s}: {s}\n", .{ codec.name, @errorName(err), if (path) |p| p else "<stdin>" });
        return 2;
    };
    out.flush() catch |err| {
        std.debug.print("{s}: stdout: {s}\n", .{ codec.name, @errorName(err) });
        return 2;
    };
    return 0;
}

fn usage(name: []const u8) u8 {
    std.debug.print("usage: {s} encode|decode [FILE|-] > out\n", .{name});
    return 1;
}
