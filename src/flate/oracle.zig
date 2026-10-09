//! External-oracle-lane harness: decode one raw deflate stream from a file
//! into a caller-sized buffer and write the decoded bytes to stdout. This is
//! the driver behind `just flate-oracle`, which cross-checks the decoder
//! against python3's `zlib` in both directions (docs/research/flate-notes.md
//! §4.3). It is a test tool, not part of the codec's surface: the codec
//! itself (src/flate/README.md) has no allocator anywhere.
//!
//! Usage: `flate-oracle <stream-file> <cap-bytes> > out`; exit 1 on a decode
//! error, with the `DecompressError` name on stderr.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const flate = @import("flate");

/// Cap on the compressed stream the harness will read into memory.
const max_stream_len = 1 << 30;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        print("usage: flate-oracle <stream-file> <cap-bytes> > out\n", .{});
        return 1;
    }
    const cap = std.fmt.parseInt(usize, args[2], 10) catch {
        print("flate-oracle: cap must be a byte count, got '{s}'\n", .{args[2]});
        return 1;
    };

    const file = try Io.Dir.cwd().openFile(io, args[1], .{
        .allow_directory = false,
        .follow_symlinks = true,
    });
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buffer);
    const source = try file_reader.interface.allocRemaining(arena, .limited(max_stream_len));
    const target = try arena.alloc(u8, cap);

    const decoded_len = flate.decompress(source, target) catch |err| {
        print("flate-oracle: {s}\n", .{@errorName(err)});
        return 1;
    };

    var write_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &write_buffer);
    defer stdout_writer.interface.flush() catch {};
    try stdout_writer.interface.writeAll(target[0..decoded_len]);
    return 0;
}
