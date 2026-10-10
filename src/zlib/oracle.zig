//! External-oracle-lane harness: the driver behind `just zlib-oracle`, which
//! cross-checks this module against python3's `zlib` (the C reference) in
//! both directions (docs/research/containers-notes.md §5.5). It is a test
//! tool, not part of the codec's surface: the codec itself (src/zlib/README.md)
//! has no allocator anywhere.
//!
//! Usage:
//!   zlib-oracle decode <stream-file> <cap-bytes> > out
//!   zlib-oracle encode <input-file> [LEVEL] > stream
//!
//! `decode` writes the decoded bytes of one zlib stream to stdout; `encode`
//! writes our zlib stream for the input file at `LEVEL` (`fast` by default;
//! `0`-`9` and `ratio` name the flate levels). Exit 1 on a codec error, with
//! the error name on stderr.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const zlib = @import("zcompress").zlib;

/// Cap on the stream the harness will read into memory.
const max_stream_len = 1 << 30;
/// Cap on the uncompressed input `encode` will read.
const max_input_len = 1 << 30;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        print("usage: zlib-oracle decode <stream-file> <cap-bytes> > out\n", .{});
        print("       zlib-oracle encode <input-file> [LEVEL] > stream\n", .{});
        return 1;
    }

    const file = try Io.Dir.cwd().openFile(io, args[2], .{
        .allow_directory = false,
        .follow_symlinks = true,
    });
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buffer);

    var write_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &write_buffer);
    defer stdout_writer.interface.flush() catch {};

    if (std.mem.eql(u8, args[1], "decode")) {
        if (args.len != 4) {
            print("zlib-oracle: decode needs <stream-file> <cap-bytes>\n", .{});
            return 1;
        }
        const cap = std.fmt.parseInt(usize, args[3], 10) catch {
            print("zlib-oracle: cap must be a byte count, got '{s}'\n", .{args[3]});
            return 1;
        };
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_stream_len));
        const target = try arena.alloc(u8, cap);

        const decoded_len = zlib.decode.decompress(source, target) catch |err| {
            print("zlib-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..decoded_len]);
        return 0;
    }

    if (std.mem.eql(u8, args[1], "encode")) {
        if (args.len != 3 and args.len != 4) {
            print("zlib-oracle: encode needs <input-file> [LEVEL]\n", .{});
            return 1;
        }
        const level: zlib.encode.Level = if (args.len == 4)
            std.meta.stringToEnum(zlib.encode.Level, args[3]) orelse {
                print("zlib-oracle: unknown level '{s}'\n", .{args[3]});
                return 1;
            }
        else
            .fast;
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_input_len));
        const target = try arena.alloc(u8, zlib.encode.maxCompressedLength(source.len));

        const encoded_len = zlib.encode.compress(source, target, .{ .level = level }) catch |err| {
            print("zlib-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..encoded_len]);
        return 0;
    }

    print("zlib-oracle: unknown mode '{s}'\n", .{args[1]});
    return 1;
}
