//! Snappy example CLI: `snappy encode [FILE|-] > out`,
//! `snappy decode [FILE|-] > out`. Shared scaffolding in `examples/cli.zig`.
//!
//! Snappy is a raw-block codec with no framing, so this CLI owns the framing
//! (src/snappy/README.md: "the consumer owns the framing bytes"). The stream
//! format this CLI defines:
//!
//! ```text
//! stream   := block*
//! block    := u32-le compressed_length, raw-snappy-block
//! ```
//!
//! The raw block itself leads with the varint uncompressed length, but a
//! concatenation of raw blocks is not self-delimiting on the compressed side,
//! hence the explicit length prefix. Encode splits input into blocks of
//! `snappy.max_block_size` (64 KiB, the format's u16-position limit).

const std = @import("std");
const Io = std.Io;

const cli = @import("cli");
const snappy = @import("snappy");

pub fn main(init: std.process.Init) !u8 {
    return cli.run(.{
        .name = "snappy",
        .encode = encode,
        .decode = decode,
    }, init);
}

fn encode(allocator: std.mem.Allocator, input: []const u8, out: *Io.Writer) !void {
    if (input.len == 0) return;

    // One scratch buffer, sized once: the worst case for the largest block.
    const scratch = try allocator.alloc(u8, snappy.maxCompressedLength(snappy.max_block_size));
    defer allocator.free(scratch);

    var pos: usize = 0;
    while (pos < input.len) {
        const take = @min(snappy.max_block_size, input.len - pos);
        const chunk = input[pos..][0..take];
        const n = try snappy.compressBlock(chunk, scratch);
        try writeU32Le(out, @intCast(n));
        try out.writeAll(scratch[0..n]);
        pos += take;
    }
}

fn decode(allocator: std.mem.Allocator, input: []const u8, out: *Io.Writer) !void {
    // One scratch buffer, sized once: the largest block's decoded size.
    const scratch = try allocator.alloc(u8, snappy.max_block_size);
    defer allocator.free(scratch);

    var pos: usize = 0;
    while (pos < input.len) {
        if (input.len - pos < 4) return error.Truncated;
        const block_len = std.mem.readInt(u32, input[pos..][0..4], .little);
        pos += 4;
        if (input.len - pos < block_len) return error.Truncated;
        const block = input[pos..][0..block_len];
        pos += block_len;

        const decoded_len = try snappy.decompressedBlockLen(block);
        if (decoded_len > scratch.len) return error.OversizedBlock;
        const n = try snappy.decompressBlock(block, scratch[0..decoded_len]);
        try out.writeAll(scratch[0..n]);
    }
}

fn writeU32Le(out: *Io.Writer, value: u32) !void {
    try out.writeAll(&.{
        @truncate(value),
        @truncate(value >> 8),
        @truncate(value >> 16),
        @truncate(value >> 24),
    });
}

test {
    // The framing round-trips: split, prefix, and reassemble.
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const src = "hello hello hello hello, snappy framing round-trip";
    try encode(gpa, src, &out.writer);
    try std.testing.expect(out.written().len > 0);

    var plain: std.Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    try decode(gpa, out.written(), &plain.writer);
    try std.testing.expectEqualStrings(src, plain.written());
}
