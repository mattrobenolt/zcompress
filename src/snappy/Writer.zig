//! snappy.Writer: a compressing `Io.Writer` producing the framed snappy
//! stream (README.md, "Streaming").
//!
//! Uncompressed writes accumulate in the caller-provided `Buffer` (one full
//! block). As the buffer fills, `drain` compresses whole `max_block_size`
//! blocks and emits them; `flush`/`finish` emit the partial tail. The
//! compressed-output scratch is a comptime-sized stack local, so the full
//! encode path allocates nothing.
//!
//! Framing (the package's canonical stream format):
//! ```text
//! stream := block*
//! block  := u32-le compressed_length, raw-snappy-block
//! ```

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const common = @import("common.zig");
const readInt = common.readInt;
const writeInt = common.writeInt;
const encode = @import("encode.zig");

/// The caller-provided uncompressed accumulation buffer: one full block.
pub const Buffer = [encode.max_block_size]u8;

/// The compressed-output scratch size: the exact worst case for one block.
pub const scratch_len = encode.maxCompressedLength(encode.max_block_size);

pub const Writer = @This();

writer: Io.Writer,
output: *Io.Writer,

const vtable: Io.Writer.VTable = .{
    .drain = drain,
    .flush = flush,
    .rebase = rebase,
};

/// Wrap `output` (the compressed-stream sink) with `buffer` as the
/// uncompressed accumulation buffer. Write through `&w.writer`; complete the
/// stream with `finish`.
pub fn init(output: *Io.Writer, buffer: *Buffer) Writer {
    return .{
        .writer = .{
            .buffer = buffer,
            .end = 0,
            .vtable = &vtable,
        },
        .output = output,
    };
}

/// Complete the stream: emit the final partial block, then flush `output`.
/// Terminal — the writer is poisoned afterwards.
pub fn finish(w: *Writer) Io.Writer.Error!void {
    defer w.writer = .failing;
    try w.emitBlock();
    try w.output.flush();
}

/// Compress the buffered block into stack scratch and emit it with the
/// `u32-le` length prefix. A no-op when nothing is buffered.
fn emitBlock(w: *Writer) Io.Writer.Error!void {
    if (w.writer.end == 0) return;
    var scratch: [scratch_len]u8 = undefined;
    const source = w.writer.buffer[0..w.writer.end];
    const n = encode.compressBlock(source, &scratch) catch |err| switch (err) {
        // `scratch` is sized to the exact worst case for any block.
        error.BufferTooSmall => unreachable,
    };
    var prefix: [4]u8 = undefined;
    writeInt(u32, &prefix, @intCast(n));
    try w.output.writeAll(&prefix);
    try w.output.writeAll(scratch[0..n]);
    w.writer.end = 0;
    // Postcondition: the block is fully emitted and the buffer is empty.
    assert(w.writer.end == 0);
}

/// The buffer is full: emit it as one block, then accept the front of
/// `data` into the freed buffer. The caller re-slices the remainder and
/// calls again, so full blocks stay maximal — only `flush`/`finish` emit
/// partial ones.
fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    errdefer w.* = .failing;
    const parent: *Writer = @fieldParentPtr("writer", w);
    try parent.emitBlock();

    // Fill from the front of `data` (the last slice repeats `splat` times),
    // stopping when the buffer fills.
    var consumed: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        consumed += accept(w, bytes, consumed);
        if (consumed == w.buffer.len) break;
    }
    if (consumed < w.buffer.len) {
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            consumed += accept(w, pattern, consumed);
            if (consumed == w.buffer.len) break;
        }
    }
    assert(consumed <= w.buffer.len);
    w.end = consumed;
    return consumed;
}

/// Copy at most the buffer's remaining space from the front of `bytes`,
/// returning the bytes taken (a partial take when the buffer fills).
fn accept(w: *Io.Writer, bytes: []const u8, consumed: usize) usize {
    const n = @min(bytes.len, w.buffer.len - consumed);
    fastmem.copy(u8, w.buffer[consumed..][0..n], bytes[0..n]);
    return n;
}

fn flush(w: *Io.Writer) Io.Writer.Error!void {
    errdefer w.* = .failing;
    const parent: *Writer = @fieldParentPtr("writer", w);
    try parent.emitBlock();
    try parent.output.flush();
}

/// Blocks are independent, so no compression state rides on the buffer:
/// slide the last `preserve` bytes to the front.
fn rebase(w: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
    errdefer w.* = .failing;
    assert(preserve + capacity <= w.buffer.len);
    const keep = @min(preserve, w.end);
    fastmem.move(u8, w.buffer[0..keep], w.buffer[w.end - keep ..][0..keep]);
    w.end = keep;
}

test "Writer: empty input produces an empty stream" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.finish();
    try testing.expectEqual(0, out.written().len);
}

test "Writer: partial tail is emitted at finish" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.writer.writeAll("hello, snappy");
    try w.finish();
    // One block: a 4-byte prefix + the raw block (varint 13 + literal tag +
    // 13 bytes = 15).
    try testing.expectEqual(19, out.written().len);
    try testing.expectEqual(@as(u32, 15), readInt(u32, out.written()[0..4]));
}

test "Writer: writes past one block split into full blocks" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.writer.writeAll("a" ** (3 * encode.max_block_size + 1));
    try w.finish();
    // Four blocks: three full (64K each) plus a one-byte tail.
    try testing.expectEqual(4, countBlocks(out.written()));
}

test "Writer: flush mid-stream emits the partial block" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.writer.writeAll("hello, ");
    try w.writer.flush();
    try testing.expectEqual(1, countBlocks(out.written()));
    try w.writer.writeAll("snappy");
    try w.finish();
    try testing.expectEqual(2, countBlocks(out.written()));
}

/// Count the framed blocks in a stream produced by `Writer`.
fn countBlocks(stream: []const u8) usize {
    var n: usize = 0;
    var pos: usize = 0;
    while (pos < stream.len) {
        const block_len = readInt(u32, stream[pos..][0..4]);
        pos += 4 + block_len;
        n += 1;
    }
    return n;
}
