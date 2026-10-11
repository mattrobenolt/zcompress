//! zstd example CLI: `zstd decode [FILE|-] > out`. Shared scaffolding in
//! `examples/cli.zig`.
//!
//! Decode-only until M5 adds the encoder direction (README, "API"): `decode`
//! is the frame walk the codec owns — `Reader.streamAll`, RFC 8878 §3.1: the
//! output of the decompression is the concatenation of the frames, one unit
//! per iteration at the boundary contract's exact position (skippable frames
//! consumed and ignored, `§3.1.2`; a unit that is not present is the file's
//! clean end; garbage where a frame unit should start fails `BadMagic`,
//! never silently skipped; the zero-byte input is the clean end).
//!
//! The window is the codec's default — 8 MiB (`§3.1.1.1.2`'s recommendation,
//! the pin from the CLI's level-19 frames) plus Block_Maximum_Size — and
//! that is why the codec's pumps take a caller-owned buffer: 8.4 MiB cannot
//! be a portable stack local (an 8 MiB stack limit is the common case, and
//! the CLI scaffolding's arena is exactly the caller the pumps expect). Every
//! other codec's example sizes its window on the stack; zstd's is the
//! divergence, and the arena owns the buffer for the run. The codec still
//! allocates nothing — the example, as its caller, does.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const cli = @import("cli");
const zstd = @import("zcompress").zstd;

pub fn main(init: std.process.Init) !u8 {
    return cli.run(.{
        .name = "zstd",
        .encode = encode,
        .decode = decode,
    }, init);
}

/// M5 adds the fast encoder; until then the encode direction reports the
/// missing half of the surface (the CLI's error trace names it).
fn encode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = in;
    _ = out;
    return error.EncodeNotImplemented;
}

fn decode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    // The example's window, owned by the run's arena: 8.4 MiB, the codec's
    // default cap. The pump is the same one a caller with a stack-sized
    // window drives (`Reader.Buffer(window_len)`), and no allocator appears
    // anywhere in the codec itself.
    const buffer = try arena.create(zstd.Reader.DefaultBuffer);
    defer arena.destroy(buffer);
    _ = try zstd.Reader.streamAll(zstd.Reader.default_window_len, in, out, buffer);
}

test "example: the decode pump walks a multi-frame file" {
    // RFC 8878 §3.1 — frames concatenate: the CLI decodes every frame, and
    // trailing bytes that are not a frame unit fail closed.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var frames: Io.Writer.Allocating = .init(testing.allocator);
    defer frames.deinit();
    try frames.writer.writeAll(&frame_raw);
    try frames.writer.writeAll(&frame_raw);

    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(frames.written());
    try decode(arena, &z, &plain.writer);
    try testing.expectEqualStrings("zstd rawzstd raw", plain.written());

    // Trailing garbage: the walk's next unit fails its classify.
    try frames.writer.writeByte(0x00);
    var bad: Io.Writer.Allocating = .init(testing.allocator);
    defer bad.deinit();
    var bad_in: Io.Reader = .fixed(frames.written());
    try testing.expectError(error.ReadFailed, decode(arena, &bad_in, &bad.writer));
}

test "example: the pump stops at the frame's end" {
    // The frame's boundary is exact: one unit's pump consumes through the
    // frame's last byte — the checksum trailer's when the flag is set
    // (RFC 8878 §3.1.1) — and the marker bytes behind it are not the
    // decoder's to consume, which is where the walk's next unit starts.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var framed: Io.Writer.Allocating = .init(testing.allocator);
    defer framed.deinit();
    try framed.writer.writeAll(&frame_raw);
    try framed.writer.writeByte(0xaa);
    try framed.writer.writeByte(0xaa);

    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(framed.written());
    const buffer = try arena.create(zstd.Reader.DefaultBuffer);
    try testing.expectEqual(
        @as(usize, 8),
        try zstd.Reader.streamFrame(zstd.Reader.default_window_len, &z, &plain.writer, buffer),
    );
    try testing.expectEqualStrings("zstd raw", plain.written());
    try testing.expectEqual(frame_raw.len, z.seek);
}

/// `golden.frame_raw`'s bytes: the Zstandard magic (`§3.1.1`), a 512-KiB
/// window descriptor (`§3.1.1.1.2`), and one Raw block of 8 bytes —
/// "zstd raw" (`§3.1.1.2.2`).
const frame_raw = [_]u8{
    0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x48, 0x41, 0x00, 0x00,
    0x7a, 0x73, 0x74, 0x64, 0x20, 0x72, 0x61, 0x77,
};
