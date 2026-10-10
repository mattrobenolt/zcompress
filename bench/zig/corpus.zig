//! The fleet corpus generator (bench/README.md). Deterministic: the same
//! bytes on every host, so the committed `bench/corpus/` tree regenerates
//! exactly and every implementation on the fleet measures the same inputs.
//!
//! Shapes and sizes mirror the codec bench files (src/flate/bench.zig):
//! text, random, html, rle, mixed at 32 KiB and 64 KiB. Alongside each raw
//! file the generator writes the reference compressed blob per codec —
//! flate, gzip, zlib at level `.fast`, snappy raw block — produced by the
//! zcompress one-shots. Decompression rows on the fleet decode these exact
//! blobs, so every implementation's decoder sees identical input bytes.
//!
//! Run from the repo root: `zig build corpus -- [DIR]` (default bench/corpus).
//! Rewrites only files whose bytes differ and prints the SHA256SUMS.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;
const DefaultPrng = std.Random.DefaultPrng;
const Sha256 = std.crypto.hash.sha2.Sha256;

const fastmem = @import("fastmem");

const zcompress = @import("zcompress");

pub const Shape = enum {
    text, // repetitive English-ish text (highly compressible)
    random, // PRNG bytes (incompressible -> stored blocks)
    html, // tag-heavy markup (compressible, short matches)
    rle, // single-byte run (extreme RLE)
    mixed, // structured + random (realistic-ish record batch)
};

pub const sizes = [_]usize{ 32 * 1024, 64 * 1024 };

/// One definition of the corpus shapes: the fleet drivers read the files
/// this generates; nothing regenerates shapes on the boxes.
pub fn makeShape(shape: Shape, buf: []u8) void {
    switch (shape) {
        .text => fill(buf, "the quick brown fox jumps over the lazy dog. "),
        .random => {
            var rng: DefaultPrng = .init(0xC0FFEE);
            for (buf) |*b| b.* = rng.random().int(u8);
        },
        .html => fill(buf, "<div class=\"row\"><span>hello</span><span>flate</span></div>"),
        .rle => fastmem.set(u8, buf, 0x41),
        .mixed => {
            var rng: DefaultPrng = .init(0x5A4BEEF);
            for (buf, 0..) |*b, i| b.* = @truncate(rng.random().int(u8) ^ @as(u8, @truncate(i)));
        },
    }
}

fn fill(buf: []u8, phrase: []const u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const n = @min(phrase.len, buf.len - i);
        fastmem.copy(u8, buf[i..][0..n], phrase[0..n]);
        i += n;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const dir_path = if (args.len > 1) args[1] else "bench/corpus";

    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    var sums: std.ArrayList(u8) = .empty;
    for (std.enums.values(Shape)) |shape| {
        for (sizes) |size| {
            const raw = try arena.alloc(u8, size);
            makeShape(shape, raw);
            const base_name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ @tagName(shape), size });
            try writeFile(io, arena, dir, &sums, base_name, raw);

            // One blob at a time: every encoder writes the same scratch, so
            // the write must complete before the next encode starts.
            const target = try arena.alloc(u8, maxCompressedLength(size));
            try writeBlob(io, arena, dir, &sums, base_name, "flate", target, zcompress.flate.encode.compress(raw, target, .{}));
            try writeBlob(io, arena, dir, &sums, base_name, "gz", target, zcompress.gzip.encode.compress(raw, target, .{}));
            try writeBlob(io, arena, dir, &sums, base_name, "zz", target, zcompress.zlib.encode.compress(raw, target, .{}));
            try writeBlob(io, arena, dir, &sums, base_name, "snappy", target, zcompress.snappy.encode.compressBlock(raw, target));
        }
    }

    try dir.writeFile(io, .{ .sub_path = "SHA256SUMS", .data = sums.items });
    var out_buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &out_buf);
    try stdout.interface.print("wrote {s}\n{s}", .{ dir_path, sums.items });
    try stdout.interface.flush();
}

fn writeBlob(
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    sums: *std.ArrayList(u8),
    base_name: []const u8,
    ext: []const u8,
    target: []u8,
    generated: anytype,
) !void {
    const n = generated catch |err| {
        std.debug.print("corpus: {s} {s} failed: {s}\n", .{ base_name, ext, @errorName(err) });
        return err;
    };
    const blob_name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ base_name, ext });
    try writeFile(io, arena, dir, sums, blob_name, target[0..n]);
}

fn maxCompressedLength(input_len: usize) usize {
    return @max(
        zcompress.gzip.encode.maxCompressedLength(input_len),
        @max(
            zcompress.zlib.encode.maxCompressedLength(input_len),
            zcompress.snappy.encode.maxCompressedLength(input_len),
        ),
    );
}

/// Write `bytes` as `name`, hash it into the SHA256SUMS accumulator, and skip
/// the write when the file already holds exactly these bytes (a regenerated
/// corpus leaves the committed tree untouched).
fn writeFile(
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    sums: *std.ArrayList(u8),
    name: []const u8,
    bytes: []const u8,
) !void {
    const current: ?[]u8 = dir.readFileAlloc(io, name, arena, .limited(bytes.len + 1)) catch null;
    if (current == null or !mem.eql(u8, current.?, bytes)) {
        try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try sums.print(arena, "{s}  {s}\n", .{ hex, name });
}
