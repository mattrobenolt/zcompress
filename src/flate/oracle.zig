//! External-oracle-lane harness: the driver behind `just flate-oracle`, which
//! cross-checks this module against python3's `zlib` in both directions
//! (docs/research/flate-notes.md §4.3). It is a test tool, not part of the
//! codec's surface: the codec itself (src/flate/README.md) has no allocator
//! anywhere.
//!
//! Usage:
//!   flate-oracle decode <stream-file> <cap-bytes> > out
//!   flate-oracle encode <input-file> > stream
//!
//! `decode` writes the decoded bytes of one raw deflate stream to stdout;
//! `encode` writes our raw deflate stream for the input file. Exit 1 on a
//! codec error, with the error name on stderr.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const flate = @import("flate");

/// Cap on the compressed stream the harness will read into memory.
const max_stream_len = 1 << 30;
/// Cap on the uncompressed input `encode` will read.
const max_input_len = 1 << 30;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        print("usage: flate-oracle decode <stream-file> <cap-bytes> > out\n", .{});
        print("       flate-oracle encode <input-file> > stream\n", .{});
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
            print("flate-oracle: decode needs <stream-file> <cap-bytes>\n", .{});
            return 1;
        }
        const cap = std.fmt.parseInt(usize, args[3], 10) catch {
            print("flate-oracle: cap must be a byte count, got '{s}'\n", .{args[3]});
            return 1;
        };
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_stream_len));
        const target = try arena.alloc(u8, cap);

        const decoded_len = flate.decompress(source, target) catch |err| {
            print("flate-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..decoded_len]);
        return 0;
    }

    if (std.mem.eql(u8, args[1], "encode")) {
        if (args.len != 3) {
            print("flate-oracle: encode needs <input-file>\n", .{});
            return 1;
        }
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_input_len));
        const target = try arena.alloc(u8, flate.maxCompressedLength(source.len));

        const encoded_len = flate.compress(source, target) catch |err| {
            print("flate-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..encoded_len]);
        return 0;
    }

    print("flate-oracle: unknown mode '{s}'\n", .{args[1]});
    return 1;
}
