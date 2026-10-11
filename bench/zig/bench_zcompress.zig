//! The fleet benchmark driver for the zcompress arms (bench/README.md).
//!
//! One process run is one round of one arm. The binary reads the committed
//! corpus (`bench/corpus/`, uploaded to the box by the harness), measures
//! each (case, implementation) cell for `--samples` time-boxed samples of
//! `--sample-ms` milliseconds each, and writes schema-v1 JSONL on stdout: a
//! meta record, one sample record per measurement, and an end record.
//!
//! Implementations in this binary:
//!   - `zc`  — the zcompress one-shots: flate/gzip/zlib at level .fast and
//!     the snappy raw block codec, both directions, plus the zstd one-shot
//!     decode (M4 is decode-only: no zstd compress row).
//!   - `std` — std.compress.flate with Container raw/gzip/zlib at level_1
//!     (the fast class), both directions, plus std.compress.zstd decode.
//!     The in-binary competitor: its rows pair with the `zc` rows inside
//!     the same process.
//!
//! Decompression rows decode the reference blobs produced by the corpus
//! generator (the zcompress encoders), so every arm's decoder sees the same
//! bytes. The warmup pass of each cell verifies the round trip; `--check`
//! runs the whole matrix as a correctness gate and reports one JSON line.
//!
//! Usage: bench-zcompress --corpus DIR [--suite standard|quick] [--seed N]
//!         [--samples N] [--sample-ms MS] [--filter SUB] [--impl zc,std]
//!         [--check]

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const fastmem = @import("fastmem");

const zcompress = @import("zcompress");
const build_options = @import("build_options");
const std_flate = std.compress.flate;
const std_zstd = std.compress.zstd;

const shapes = [_][]const u8{ "text", "random", "html", "rle", "mixed" };
const sizes = [_]usize{ 32 * 1024, 64 * 1024 };
const codecs = [_][]const u8{ "flate", "gzip", "zlib", "snappy", "zstd" };
const directions = [_][]const u8{ "compress", "decompress" };
const decode_only = [_][]const u8{"decompress"};

const Suite = enum { standard, quick };

/// The blob extension of each codec's reference compressed form.
fn blobExt(codec: []const u8) []const u8 {
    if (mem.eql(u8, codec, "gzip")) return "gz";
    if (mem.eql(u8, codec, "zlib")) return "zz";
    if (mem.eql(u8, codec, "zstd")) return "zst";
    return codec;
}

/// zstd is decode-only until M5 (there is no zcompress zstd encoder, and
/// std.compress.zstd has no compressor either): its rows are decompress
/// only, decoding the pinned CLI's reference frames (bench/zig/corpus.zig).
fn codecDirections(codec: []const u8) []const []const u8 {
    if (mem.eql(u8, codec, "zstd")) return &decode_only;
    return &directions;
}

const Options = struct {
    corpus: []const u8 = "",
    suite: Suite = .standard,
    seed: u64 = 0,
    samples: u32 = 5,
    sample_ms: u64 = 100,
    filter: ?[]const u8 = null,
    impls: Impls = .both,
    check: bool = false,
};

const Impls = enum {
    both,
    zc,
    std,

    fn list(impls: Impls) []const []const u8 {
        const both = [_][]const u8{ "zc", "std" };
        const zc = [_][]const u8{"zc"};
        const std_only = [_][]const u8{"std"};
        return switch (impls) {
            .both => &both,
            .zc => &zc,
            .std => &std_only,
        };
    }
};

fn parseArgs(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value = if (i + 1 < args.len) args[i + 1] else "";
        if (mem.eql(u8, arg, "--corpus")) {
            options.corpus = value;
            i += 1;
        } else if (mem.eql(u8, arg, "--suite")) {
            options.suite = std.meta.stringToEnum(Suite, value) orelse return error.BadSuite;
            i += 1;
        } else if (mem.eql(u8, arg, "--seed")) {
            options.seed = try std.fmt.parseInt(u64, value, 10);
            i += 1;
        } else if (mem.eql(u8, arg, "--samples")) {
            options.samples = try std.fmt.parseInt(u32, value, 10);
            i += 1;
        } else if (mem.eql(u8, arg, "--sample-ms")) {
            options.sample_ms = try std.fmt.parseInt(u64, value, 10);
            i += 1;
        } else if (mem.eql(u8, arg, "--filter")) {
            options.filter = value;
            i += 1;
        } else if (mem.eql(u8, arg, "--impl")) {
            options.impls = std.meta.stringToEnum(Impls, value) orelse return error.BadImpl;
            i += 1;
        } else if (mem.eql(u8, arg, "--check")) {
            options.check = true;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.BadArgument;
        }
    }
    if (options.corpus.len == 0) return error.MissingCorpus;
    if (options.samples == 0 or options.sample_ms == 0) return error.BadTiming;
    return options;
}

/// One corpus case: the raw bytes and the four reference blobs, loaded once.
const Case = struct {
    shape: []const u8,
    size: usize,
    raw: []u8,
    blobs: [codecs.len][]u8,

    fn id(case: Case, codec: []const u8, direction: []const u8, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}/{s}/{d}", .{
            codec, direction, case.shape, case.size,
        }) catch unreachable;
    }
};

const Bench = struct {
    io: Io,
    arena: Allocator,
    options: Options,
    out: *Io.Writer,
    /// Compress-row scratch: the largest one-shot output, allocated once.
    compressed: []u8,
    /// Decompress-row scratch: the raw size at most. Never aliases
    /// `compressed`: a round trip reads one while writing the other.
    decoded: []u8,
    /// The std competitor's history window (std_flate.Compress/Decompress).
    window: []u8,
    /// The std zstd decoder's window buffer: std_zstd.Decompress asserts it
    /// holds window_len + block_size_max (the 8 MiB default + 128 KiB).
    zstd_window: []u8,
    cases: u32 = 0,

    fn now(bench: Bench) i96 {
        return Io.Timestamp.now(bench.io, .awake).nanoseconds;
    }

    /// True when `--filter` is absent or matches this row's case ID.
    fn selected(bench: Bench, case: Case, codec: []const u8, direction: []const u8) bool {
        const filter = bench.options.filter orelse return true;
        var buf: [96]u8 = undefined;
        return mem.containsAtLeast(u8, case.id(codec, direction, &buf), 1, filter);
    }

    /// True when any row of this codec (any selected impl, any direction
    /// the codec carries) is selected.
    fn anyRow(bench: Bench, case: Case, codec: []const u8) bool {
        for (bench.options.impls.list()) |impl| {
            if (mem.eql(u8, impl, "std") and mem.eql(u8, codec, "snappy")) continue;
            for (codecDirections(codec)) |direction| {
                if (bench.selected(case, codec, direction)) return true;
            }
        }
        return false;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = parseArgs(args) catch |err| {
        std.debug.print(
            "usage: bench-zcompress --corpus DIR [--suite standard|quick] [--seed N] " ++
                "[--samples N] [--sample-ms MS] [--filter SUB] [--impl both|zc|std] " ++
                "[--check]: {s}\n",
            .{@errorName(err)},
        );
        std.process.exit(2);
    };

    var out_buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &stdout.interface;

    var bench: Bench = .{
        .io = io,
        .arena = arena,
        .options = options,
        .out = out,
        .compressed = try arena.alloc(u8, maxTargetLen()),
        .decoded = try arena.alloc(u8, 64 * 1024),
        .window = try arena.alloc(u8, std_flate.max_window_len),
        .zstd_window = try arena.alloc(u8, std_zstd.default_window_len + std_zstd.block_size_max),
    };
    if (options.check) {
        try checkAll(&bench);
    } else {
        try measure(&bench);
    }
    try out.flush();
}

fn maxTargetLen() usize {
    return @max(
        zcompress.gzip.encode.maxCompressedLength(64 * 1024),
        zcompress.snappy.encode.maxCompressedLength(64 * 1024),
    );
}

fn loadCase(bench: *Bench, shape: []const u8, size: usize) !Case {
    const io = bench.io;
    var dir = try Io.Dir.cwd().openDir(io, bench.options.corpus, .{});
    defer dir.close(io);
    const base = try std.fmt.allocPrint(bench.arena, "{s}-{d}", .{ shape, size });
    const raw = try dir.readFileAlloc(io, base, bench.arena, .limited(size + 1));
    if (raw.len != size) return error.CorpusSizeMismatch;
    var blobs: [codecs.len][]u8 = undefined;
    for (codecs, 0..) |codec, k| {
        const name = try std.fmt.allocPrint(
            bench.arena,
            "{s}.{s}",
            .{ base, blobExt(codec) },
        );
        blobs[k] = try dir.readFileAlloc(io, name, bench.arena, .unlimited);
    }
    return .{ .shape = shape, .size = size, .raw = raw, .blobs = blobs };
}

// ---------------------------------------------------------------------------
// The measured one-shots. Each returns the produced length; decompress rows
// read the case's reference blob. Nothing here allocates.
// ---------------------------------------------------------------------------

fn compressOne(bench: *Bench, impl: []const u8, codec: []const u8, raw: []const u8) !usize {
    // The compress direction is never selected for a decode-only codec
    // (codecDirections gates every loop above), so a zstd call is a bug.
    assert(!mem.eql(u8, codec, "zstd"));
    const target = bench.compressed;
    if (mem.eql(u8, impl, "zc")) {
        if (mem.eql(u8, codec, "flate"))
            return zcompress.flate.encode.compress(raw, target, .{});
        if (mem.eql(u8, codec, "gzip"))
            return zcompress.gzip.encode.compress(raw, target, .{});
        if (mem.eql(u8, codec, "zlib"))
            return zcompress.zlib.encode.compress(raw, target, .{});
        return zcompress.snappy.encode.compressBlock(raw, target);
    }
    return stdCompress(bench, codec, raw);
}

fn stdContainer(codec: []const u8) std_flate.Container {
    if (mem.eql(u8, codec, "gzip")) return .gzip;
    if (mem.eql(u8, codec, "zlib")) return .zlib;
    return .raw;
}

fn stdCompress(bench: *Bench, codec: []const u8, raw: []const u8) !usize {
    var out: Io.Writer = .fixed(bench.compressed);
    var compressor = try std_flate.Compress.init(
        &out,
        bench.window,
        stdContainer(codec),
        .level_1,
    );
    try compressor.writer.writeAll(raw);
    try compressor.finish();
    return out.buffered().len;
}

fn decompressOne(bench: *Bench, impl: []const u8, codec: []const u8, blob: []const u8) !usize {
    const target = bench.decoded;
    if (mem.eql(u8, impl, "zc")) {
        if (mem.eql(u8, codec, "flate"))
            return zcompress.flate.decode.decompress(blob, target);
        if (mem.eql(u8, codec, "gzip"))
            return zcompress.gzip.decode.decompress(blob, target);
        if (mem.eql(u8, codec, "zlib"))
            return zcompress.zlib.decode.decompress(blob, target);
        if (mem.eql(u8, codec, "zstd"))
            return zcompress.zstd.decode.decompress(blob, target);
        return zcompress.snappy.decode.decompressBlock(blob, target);
    }
    return stdDecompress(bench, codec, blob);
}

fn stdDecompress(bench: *Bench, codec: []const u8, blob: []const u8) !usize {
    var in: Io.Reader = .fixed(blob);
    if (mem.eql(u8, codec, "zstd")) {
        // Indirect vtable: the window buffer carries the history (std
        // asserts it holds window_len + block_size_max). The codec set
        // guarantees only this call takes the zstd path with that buffer.
        var decompress = std_zstd.Decompress.init(&in, bench.zstd_window, .{});
        var out: Io.Writer = .fixed(bench.decoded);
        _ = try decompress.reader.streamRemaining(&out);
        return out.buffered().len;
    }
    var decompress = std_flate.Decompress.init(&in, stdContainer(codec), bench.window);
    var out: Io.Writer = .fixed(bench.decoded);
    _ = try decompress.reader.streamRemaining(&out);
    return out.buffered().len;
}

/// One round trip per (impl, codec) plus one reference-blob decode; the
/// detail of the first failure, or null. Nothing allocates past case load.
fn checkCase(bench: *Bench, case: Case) !?[]const u8 {
    for (bench.options.impls.list()) |impl| {
        for (codecs, 0..) |codec, k| {
            if (mem.eql(u8, impl, "std") and mem.eql(u8, codec, "snappy")) continue;
            if (!bench.anyRow(case, codec)) continue;
            bench.cases += 1;
            // Decode-only codecs (zstd until M5) have no round trip: the
            // reference-blob decode below is the whole check.
            if (codecDirections(codec).len == 2) {
                const n = compressOne(bench, impl, codec, case.raw) catch |err| {
                    return @errorName(err);
                };
                const back = decompressOne(bench, impl, codec, bench.compressed[0..n]) catch |err| {
                    return @errorName(err);
                };
                if (back != case.size or !mem.eql(u8, bench.decoded[0..back], case.raw)) {
                    return "round trip mismatch";
                }
            }
            const decoded = decompressOne(bench, impl, codec, case.blobs[k]) catch |err| {
                return @errorName(err);
            };
            if (decoded != case.size or !mem.eql(u8, bench.decoded[0..decoded], case.raw)) {
                return "reference blob mismatch";
            }
        }
    }
    return null;
}

fn checkAll(bench: *Bench) !void {
    var detail: []const u8 = "";
    for (shapes) |shape| {
        for (sizes) |size| {
            if (bench.options.suite == .quick and size != sizes[0]) continue;
            const case = try loadCase(bench, shape, size);
            if (try checkCase(bench, case)) |found| {
                detail = found;
                break;
            }
        } else continue;
        break;
    }
    const status = if (detail.len == 0) "pass" else "fail";
    try bench.out.print(
        "{{\"type\":\"check\",\"schema\":1,\"arm\":\"zc\",\"status\":\"{s}\",\"cases\":{d}," ++
            "\"cpu\":\"{s}\",\"optimize\":\"{s}\",\"detail\":\"{s}\"}}\n",
        .{ status, bench.cases, builtin.cpu.model.name, @tagName(builtin.mode), detail },
    );
    try bench.out.flush();
    if (detail.len != 0) std.process.exit(1);
}

// ---------------------------------------------------------------------------
// Measurement: meta record, interleaved samples, end record.
// ---------------------------------------------------------------------------

fn measure(bench: *Bench) !void {
    try writeMeta(bench);

    const start = bench.now();
    for (shapes) |shape| {
        for (sizes) |size| {
            if (bench.options.suite == .quick and size != sizes[0]) continue;
            const case = try loadCase(bench, shape, size);
            // Warmup: one pass per cell, which also verifies the round trip
            // once per process. A failure stops the run: a faster kernel
            // that corrupts data is a bug, not a measurement.
            const impls = bench.options.impls.list();
            var selected_codecs: u32 = 0;
            for (codecs) |codec| {
                if (bench.anyRow(case, codec)) selected_codecs += 1;
            }
            if (selected_codecs == 0) continue;
            bench.cases += selected_codecs;
            for (impls) |impl| {
                for (codecs, 0..) |codec, k| {
                    if (mem.eql(u8, impl, "std") and mem.eql(u8, codec, "snappy")) continue;
                    if (!bench.anyRow(case, codec)) continue;
                    if (codecDirections(codec).len == 2) {
                        const n = try compressOne(bench, impl, codec, case.raw);
                        const back = try decompressOne(bench, impl, codec, bench.compressed[0..n]);
                        if (back != case.size or !mem.eql(u8, bench.decoded[0..back], case.raw))
                            return error.RoundTripMismatch;
                    }
                    const decoded = try decompressOne(bench, impl, codec, case.blobs[k]);
                    if (decoded != case.size or !mem.eql(u8, bench.decoded[0..decoded], case.raw))
                        return error.ReferenceBlobMismatch;
                }
            }
            // Samples interleave implementations so paired comparisons share
            // the process's thermal and frequency state across the round.
            for (0..bench.options.samples) |sample_index| {
                for (bench.options.impls.list()) |impl| {
                    for (codecs, 0..) |codec, k| {
                        if (mem.eql(u8, impl, "std") and mem.eql(u8, codec, "snappy")) continue;
                        for (codecDirections(codec)) |direction| {
                            if (!bench.selected(case, codec, direction)) continue;
                            try sample(bench, case, codec, k, impl, direction, @intCast(sample_index));
                        }
                    }
                }
            }
        }
    }
    try bench.out.print("{{\"type\":\"end\",\"cases\":{d},\"elapsed_ns\":{d}}}\n", .{
        bench.cases, bench.now() - start,
    });
}

fn sample(
    bench: *Bench,
    case: Case,
    codec: []const u8,
    codec_index: usize,
    impl: []const u8,
    direction: []const u8,
    index: u32,
) !void {
    const compressing = mem.eql(u8, direction, "compress");
    const blob = case.blobs[codec_index];
    const deadline_ns = bench.options.sample_ms * std.time.ns_per_ms;
    var iters: u64 = 0;
    var out_len: usize = 0;
    const start = bench.now();
    while (true) {
        out_len = if (compressing)
            try compressOne(bench, impl, codec, case.raw)
        else
            try decompressOne(bench, impl, codec, blob);
        iters += 1;
        if (iters % 8 == 0 and bench.now() - start >= deadline_ns) break;
    }
    const elapsed = bench.now() - start;
    var id_buf: [96]u8 = undefined;
    try bench.out.print(
        "{{\"type\":\"sample\",\"case\":\"{s}\",\"codec\":\"{s}\",\"direction\":\"{s}\"," ++
            "\"shape\":\"{s}\",\"size\":{d},\"impl\":\"{s}\",\"sample\":{d},\"iters\":{d}," ++
            "\"ns\":{d},\"out_len\":{d}}}\n",
        .{
            case.id(codec, direction, &id_buf), codec, direction, case.shape, case.size,
            impl,                               index, iters,     elapsed,    out_len,
        },
    );
}

fn writeMeta(bench: *Bench) !void {
    const options = bench.options;
    try bench.out.print(
        "{{\"type\":\"meta\",\"schema\":1,\"arm\":\"zc\",\"tool\":\"zcompress\"," ++
            "\"rev\":\"{s}\",\"toolchain\":\"zig {s}\",\"target\":\"{s}\",\"cpu\":\"{s}\"," ++
            "\"optimize\":\"{s}\",\"suite\":\"{s}\",\"seed\":{d},\"samples\":{d}," ++
            "\"sample_ms\":{d},\"impls\":[",
        .{
            build_options.rev,      builtin.zig_version_string, tripleName(), builtin.cpu.model.name,
            @tagName(builtin.mode), @tagName(options.suite),    options.seed, options.samples,
            options.sample_ms,
        },
    );
    for (options.impls.list(), 0..) |impl, k| {
        try bench.out.print("{s}\"{s}\"", .{ if (k == 0) "" else ",", impl });
    }
    try bench.out.writeAll("],\"corpus\":{");
    try writeCorpusHashes(bench);
    try bench.out.writeAll("}}\n");
}

fn writeCorpusHashes(bench: *Bench) !void {
    var dir = try Io.Dir.cwd().openDir(bench.io, bench.options.corpus, .{});
    defer dir.close(bench.io);
    var first = true;
    for (shapes) |shape| {
        for (sizes) |size| {
            const base = try std.fmt.allocPrint(bench.arena, "{s}-{d}", .{ shape, size });
            const raw = try dir.readFileAlloc(bench.io, base, bench.arena, .limited(size + 1));
            var digest: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(raw, &digest, .{});
            try bench.out.print("{s}\"{s}\":\"{s}\"", .{
                if (first) "" else ",", base, std.fmt.bytesToHex(digest, .lower),
            });
            first = false;
        }
    }
}

fn tripleName() []const u8 {
    return comptime std.fmt.comptimePrint("{s}-{s}-{s}", .{
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
    });
}
