//! Raw DEFLATE codec benchmarks. Run with `zig build bench -Doptimize=ReleaseFast`.
//!
//! Covers compress and decompress across the shared data shapes (repetitive
//! text, random, html-like, a single-byte run, and a mixed batch) at the 64-KiB
//! block size and at 32 KiB. Throughput is reported as MB/s over the
//! *uncompressed* input size so compress and decompress are directly
//! comparable.
//!
//! Output is benchstat-friendly:
//! `zig build bench -Doptimize=ReleaseFast -- --count=10 > bench.txt`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const DefaultPrng = std.Random.DefaultPrng;
const fastmem = @import("fastmem");

const bench = @import("benchmark");
const flate = @import("flate");

/// Input corpus shapes. Each returns a freshly-allocated buffer the benchmark
/// is responsible for freeing (once, in setup — not in the timed loop).
const Shape = enum {
    text, // repetitive English-ish text (highly compressible)
    random, // PRNG bytes (incompressible -> stored blocks)
    html, // tag-heavy markup (compressible, short matches)
    rle, // single-byte run (extreme RLE)
    mixed, // structured + random (realistic-ish record batch)
};

/// The two input sizes: the encoder's block size (65535, rounded to 64 KiB) and
/// half of it.
const Size = enum {
    half,
    block,

    fn len(size: Size) usize {
        return switch (size) {
            .half => 32 * 1024,
            .block => 64 * 1024,
        };
    }

    fn name(comptime size: Size) []const u8 {
        return switch (size) {
            .half => "32K",
            .block => "64K",
        };
    }
};

fn makeShape(allocator: Allocator, shape: Shape, len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    switch (shape) {
        .text => {
            const phrase = "the quick brown fox jumps over the lazy dog. ";
            var i: usize = 0;
            while (i < len) {
                const n = @min(phrase.len, len - i);
                fastmem.copy(u8, buf[i..][0..n], phrase[0..n]);
                i += n;
            }
        },
        .random => {
            var rng: DefaultPrng = .init(0xC0FFEE);
            for (buf) |*b| b.* = rng.random().int(u8);
        },
        .html => {
            const phrase = "<div class=\"row\"><span>hello</span><span>flate</span></div>";
            var i: usize = 0;
            while (i < len) {
                const n = @min(phrase.len, len - i);
                fastmem.copy(u8, buf[i..][0..n], phrase[0..n]);
                i += n;
            }
        },
        .rle => fastmem.set(u8, buf, 0x41),
        .mixed => {
            var rng: DefaultPrng = .init(0x5A4BEEF);
            for (buf, 0..) |*b, i| b.* = @truncate(rng.random().int(u8) ^ @as(u8, @truncate(i)));
        },
    }
    return buf;
}

fn shapeName(comptime shape: Shape) []const u8 {
    return switch (shape) {
        .text => "text",
        .random => "random",
        .html => "html",
        .rle => "rle",
        .mixed => "mixed",
    };
}

/// `64K/text`, so a benchstat run lines the sizes up per shape.
fn caseName(comptime size: Size, comptime shape: Shape) []const u8 {
    return comptime size.name() ++ "/" ++ shapeName(shape);
}

/// Compress benchmarks: one sub-benchmark per size and shape. Reports MB/s over
/// the uncompressed input.
pub fn benchmarkCompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.block }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    const input = try makeShape(bb.allocator, shape, size.len());
                    defer bb.allocator.free(input);
                    const bound = flate.maxCompressedLength(input.len);
                    const comp = try bb.allocator.alloc(u8, bound);
                    defer bb.allocator.free(comp);

                    while (try bb.loop()) {
                        const n = try flate.compress(input, comp);
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(input.len));
                }
            }.run);
        }
    }
}

/// Decompress benchmarks. The compressed input is prepared once (outside the
/// timed loop), then decompressed repeatedly. Reports MB/s over the
/// *decompressed* size.
pub fn benchmarkDecompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.block }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    const input = try makeShape(bb.allocator, shape, size.len());
                    defer bb.allocator.free(input);
                    const comp = try bb.allocator.alloc(u8, flate.maxCompressedLength(input.len));
                    defer bb.allocator.free(comp);
                    const clen = try flate.compress(input, comp);

                    const back = try bb.allocator.alloc(u8, input.len);
                    defer bb.allocator.free(back);

                    while (try bb.loop()) {
                        const n = try flate.decompress(comp[0..clen], back);
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(input.len));
                }
            }.run);
        }
    }
}

/// Compression ratio (compressed / uncompressed) per size and shape, reported
/// as a custom metric so the table shows what the fixed-Huffman level buys over
/// the stored form. Not a timed loop — it runs once.
pub fn benchmarkRatio(b: *bench.B) !void {
    inline for (.{ Size.half, Size.block }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    const input = try makeShape(bb.allocator, shape, size.len());
                    defer bb.allocator.free(input);
                    const comp = try bb.allocator.alloc(u8, flate.maxCompressedLength(input.len));
                    defer bb.allocator.free(comp);
                    const clen = try flate.compress(input, comp);
                    const ratio = @as(f64, @floatFromInt(clen)) /
                        @as(f64, @floatFromInt(input.len));
                    try bb.reportMetric(ratio, "ratio");
                    // One iteration so the harness is happy; the metric is the point.
                    while (try bb.loop()) {
                        bb.keepAlive(clen);
                    }
                }
            }.run);
        }
    }
}
