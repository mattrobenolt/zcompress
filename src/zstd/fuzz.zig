//! Fuzz targets for the zstd decoder (RFC 8878), one per layer of the
//! decode-only surface M4 ships. M5 adds the encoder; until then there is no
//! in-process encode oracle, so every target's corpus is the CLI-verified
//! golden fixtures (`golden.zig` records each verdict) and the reference
//! oracle is the wire itself: the frames' own checksum trailers are the C
//! library's XXH64 values, and std's `XxHash64` is the second opinion.
//!
//!   - `fuzzGoldenCorpus`: the committed fixture frames through
//!     `decode.decompress` — identity against the model each fixture's CLI
//!     verdict pins, the exact / one-below / slack cap boundary, the
//!     trailing-bytes boundary (markers and a second frame unit are ignored),
//!     determinism, and the streaming reader's agreement at the exact frame
//!     boundary; plus the `streamAll` walk over the frame units (concatenated
//!     frames, skippable-only, garbage after a unit).
//!   - `fuzzCorruption`: the bad-frame corpus with its pinned errors and
//!     written floors, then Smith mutations over the good frames — the
//!     magic, the descriptor (the reserved bit, the dictionary flag, the
//!     unused bit), the FCS forms and their single-segment window coupling,
//!     the block header (type, size, Last_Block), the entropy bytes, the
//!     checksum trailer, truncation at every position, the skippable walk,
//!     T12's window pair, T13, T14 — with the contract's specific errors
//!     pinned and the universal property: the one-shot and the streaming
//!     reader agree (same bytes, or the same named error — the reader's only
//!     own refusal is `WindowTooLarge`), a clean `Reader` end proves its
//!     trailer matches the reference XXH64 of its own output at the exact
//!     frame boundary, and a failure is sticky.
//!   - `fuzzReaderMachinery`: Smith-chosen consumer op sequences
//!     (peek/take/discardAll/readSliceAll/stream/poll/over-cap take) over
//!     known frames with markers after them, the input sometimes chunked at
//!     the 4-byte contiguity minimum (the documented precondition) — the
//!     boundary preserved under every op, and the unbounded-request class:
//!     `over_end_peek` asks past the frame's tail, and `over_buffer_peek`
//!     asks past the whole buffer so the trailer step runs through the
//!     codec's `rebase` (the M3 B1 shape, the README's own ask: a clean
//!     `EndOfStream` must mean the trailer was verified).
//!   - `fuzzChecksumAccounting`: the XXH64 fold through the one funnel —
//!     every checksummed fixture's wire trailer (the C library's own value,
//!     `zstd -t`-verified) must equal std's `XxHash64` over the decoded
//!     bytes, the empty frame and the multi-block frame included; a
//!     corrupted trailer byte fails `WrongChecksum` on both the one-shot and
//!     the reader paths, stickily.
//!   - `fuzzAmplification`: the declared-size bombs — an RLE block's 128 KiB
//!     from one byte, a 28-byte frame's 262147, a 4 GiB skippable
//!     Frame_Size, T14's 2^64-1 declaration, T7's window/block coupling —
//!     decoded into caps below their decoded length: fail closed
//!     (`BufferTooSmall`), never write past the cap, never size anything
//!     from a declaration.
//!
//! Run with `just fuzz <budget>` (ReleaseSafe only: a Debug-mode fuzz run
//! hits ziglang/zig#30655). Every target caps its per-iteration input and
//! work (`source_max`, `out_max`) so a budget run finishes. The codec
//! allocates nothing on any decode path and these targets allocate nothing
//! at all: every buffer is a stack local, so the runner's per-input leak
//! check is trivially clean.
//!
//! Spec: docs/research/specs/rfc8878-zstd.txt (§3.1 frames, §3.1.1 the frame
//! and its checksum, §3.1.1.1 the header, §3.1.1.2 the block chain, §3.1.1.3
//! and §3.1.1.4 the entropy layers and execution, §3.1.2 skippable frames,
//! §4.1 and §4.2 the FSE and Huffman tables). Contracts: src/zstd/README.md.
//! The divergences the mutations pin are docs/research/zstd-notes.md §4 (T7,
//! T9, T12, T13, T14) and the fixtures' verdicts recorded in `golden.zig`.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;
const Smith = testing.Smith;
const math = std.math;
const mem = std.mem;
const XxHash64 = std.hash.XxHash64;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const readInt = @import("common.zig").readInt;
const block = @import("block.zig");
const decode = @import("decode.zig");
const fse = @import("fse.zig");
const frame = @import("frame.zig");
const golden = @import("golden.zig");
const Reader = @import("Reader.zig");

// ---------------------------------------------------------------------------
// Shared harness
// ---------------------------------------------------------------------------

/// Bytes past a decode's cap checked on every one-shot decode: an
/// out-of-bounds write lands in this region.
const guard_len: usize = 256;

/// The corpus's widest decoded output: `frame_window_128k`'s 2 * 131072 + 3.
/// Every output buffer below is this plus `guard_len`.
const out_max: usize = 262_147;

/// The corpus frames' declared window (`frame_raw`'s Window_Descriptor 0x48:
/// 512 KiB, `§3.1.1.1.2`) — the reader buffers below authorize it, and it is
/// the `checkWindow` boundary the mutations probe.
const fixture_window_len: usize = 512 * 1024;

/// The corpus's widest frame unit; the mutation buffers add room for a
/// skippable prefix, a duplicated unit, and markers.
const source_max: usize = 1024;
const mutation_max: usize = 2 * source_max + 64;

/// Marker bytes appended after a frame unit to prove the reader stops at the
/// unit's last byte (README, "Streaming"): the frame is self-delimiting, so
/// bytes after it are not the reader's to consume.
const marker_len: usize = 8;
const marker_byte: u8 = 0xa5;

/// A Smith-chosen value in `[at_least, at_most]`. `Smith.valueRangeAtMost`
/// rejects `usize` (no fixed bitsize), so bounded lengths go through a `u32`
/// and widen here; every call site is inside a per-iteration cap.
fn rangeAtMost(smith: *Smith, at_least: usize, at_most: usize) usize {
    assert(at_least <= at_most);
    assert(at_most <= math.maxInt(u32));
    return smith.valueRangeAtMost(u32, @intCast(at_least), @intCast(at_most));
}

/// A Smith-serialized `u64`: the little-endian form every `smith.value` call
/// consumes, so hand-built seeds can pin the values the target reads.
fn u64Le(comptime value: u64) [8]u8 {
    var out: [8]u8 = undefined;
    mem.writeInt(u64, &out, value, .little);
    return out;
}

/// A nonzero byte to XOR with, so a flip always changes the byte.
fn flipValue(smith: *Smith) u8 {
    return @intCast(1 + rangeAtMost(smith, 0, 254));
}

/// How many `stream` calls decoding `plain_len` bytes may take: each call
/// either serves buffered bytes or fills the serving region with at least one
/// byte, so two calls per output byte plus slack for a stall is a generous
/// bound. More calls than this is a hang, not a timeout.
fn pumpLimit(plain_len: usize) usize {
    return 16 + 2 * plain_len;
}

/// Pump `r` into `w` until the clean end of the frame (the shape of
/// Reader.zig's own pump driver), bounded: a reader that neither serves bytes
/// nor fails is a hang, not a timeout.
fn pump(r: *Io.Reader, w: *Io.Writer, limit: usize) !void {
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > limit) return error.PumpStalled;
        _ = r.stream(w, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
    }
}

/// How a corruption-lane pump stopped. `output_full` is the harness's own cap
/// (a fixed writer), not a codec failure.
const Stop = enum { end_of_stream, read_failed, output_full };

const Pumped = struct { served: usize, stop: Stop };

/// Pump `r` into the fixed writer `w` until the frame ends, the reader fails,
/// or `w` is full. The reader's coarse `error.ReadFailed` is reported as
/// `read_failed` (the detail is sticky in `r.err`); `error.WriteFailed` is the
/// output cap. More calls than `limit` is a hang, not a timeout.
fn pumpCapped(r: *Io.Reader, w: *Io.Writer, limit: usize) !Pumped {
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > limit) return error.PumpStalled;
        _ = r.stream(w, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return .{ .served = w.end, .stop = .end_of_stream },
            error.ReadFailed => return .{ .served = w.end, .stop = .read_failed },
            error.WriteFailed => return .{ .served = w.end, .stop = .output_full },
        };
    }
}

/// The clean end is sticky: repeated `stream` calls end in `EndOfStream`. A
/// zero-serve fill call may come first — the interface allows a zero return
/// that does not indicate frame end — so this drives the calls instead of
/// pinning the first one.
fn expectStickyEnd(r: *Reader) !void {
    var sink: Io.Writer.Discarding = .init(&.{});
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > 4) return error.EndNotSticky;
        const n = r.reader.stream(&sink.writer, .unlimited) catch |err| {
            try testing.expectEqual(error.EndOfStream, err);
            return;
        };
        try testing.expectEqual(@as(usize, 0), n);
    }
}

/// A failure is sticky: repeated `stream` calls end in `ReadFailed` (a
/// zero-serve call may come first), with the detail still recorded in `err`.
fn expectStickyFailure(r: *Reader) !void {
    try testing.expect(r.err != null);
    var sink: Io.Writer.Discarding = .init(&.{});
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > 4) return error.FailureNotSticky;
        _ = r.reader.stream(&sink.writer, .unlimited) catch |err| {
            try testing.expectEqual(error.ReadFailed, err);
            return;
        };
    }
}

/// The guaranteed contiguous request length: `Block_Maximum_Size` — 128 KiB
/// (README, "Streaming": "any contiguous request ... of at most
/// Block_Maximum_Size — 128 KiB — is served"). The over-cap ops ask one byte
/// past it.
fn windowTailLen() usize {
    return block.max_block_size;
}

/// The reader's whole buffer, window plus block room: a request of this size
/// necessarily exceeds `buffer.len - seek` once the consumer has advanced, so
/// the std fill routes it through the codec's `rebase` (the B1 shape).
fn bufferLen() usize {
    return @sizeOf(Reader.Buffer(fixture_window_len));
}

/// The only legal failure of a *valid* frame under a bounded contiguous
/// request: the serving region cannot hold what the consumer asked for
/// (README, "Streaming": the contiguous-read cap). Anything else is a
/// finding. The failure is sticky and reports the detail beside the
/// interface's coarse error.
fn expectContiguityStop(r: *Reader, err: anyerror) !void {
    try testing.expectEqual(error.ReadFailed, err);
    try testing.expectEqual(Reader.Error.StreamTooLong, r.err.?);
    try expectStickyFailure(r);
}

/// A failed one-shot decode where no specific error is pinned.
fn expectFailure(result: decode.DecompressError!usize) !void {
    if (result) |_| return error.ExpectedFailure else |_| {}
}

/// The same error name across the one-shot's and the reader's sets — the
/// reader's detail set is the one-shot's minus `BufferTooSmall` plus its own
/// names, so a shared failure must carry the same name.
fn sameErrorName(one_shot: decode.DecompressError, reader_detail: Reader.Error) bool {
    return mem.eql(u8, @errorName(one_shot), @errorName(reader_detail));
}

/// The frame's wire trailer, when it has one, must be the low 4 bytes of the
/// reference XXH64 over the decoded bytes (`§3.1.1`): the golden trailers are
/// the C library's own values (the CLI verified each with `zstd -t`), and the
/// reader's clean end means its fold — the one funnel, `recordBlock` — agreed
/// with exactly these bytes.
fn expectTrailerConsistent(
    source: []const u8,
    end: usize,
    output: []const u8,
    has_checksum: bool,
) !void {
    if (!has_checksum) return;
    try testing.expect(end >= frame.checksum_len);
    const trailer = source[end - frame.checksum_len .. end];
    try testing.expectEqual(
        @as(u32, @truncate(XxHash64.hash(0, output))),
        readInt(u32, trailer[0..4]),
    );
}

// ---------------------------------------------------------------------------
// The corpus: the golden fixtures and the models their CLI verdicts pin
// ---------------------------------------------------------------------------

/// The decoded output of a corpus frame, in the shape that builds it without
/// copying a multi-hundred-KiB literal.
const Output = union(enum) {
    /// The fixture's decoded bytes, verbatim.
    static: []const u8,
    /// One byte repeated `count` times.
    splat: struct { byte: u8, count: usize },
    /// `count` copies of a phrase.
    repeat: struct { text: []const u8, count: usize },
    /// Two runs and a tail (`frame_window_*`: RLE blocks then a match).
    two_runs: struct {
        first_byte: u8,
        first_count: usize,
        second_byte: u8,
        second_count: usize,
        tail: []const u8,
    },
};

/// Build `output` into `buf` and return the used prefix.
fn materialize(output: Output, buf: []u8) []const u8 {
    switch (output) {
        .static => |bytes| {
            fastmem.copy(u8, buf[0..bytes.len], bytes);
            return buf[0..bytes.len];
        },
        .splat => |s| {
            fastmem.set(u8, buf[0..s.count], s.byte);
            return buf[0..s.count];
        },
        .repeat => |r| {
            var i: usize = 0;
            while (i < r.count) : (i += 1) {
                fastmem.copy(u8, buf[i * r.text.len ..][0..r.text.len], r.text);
            }
            return buf[0 .. r.count * r.text.len];
        },
        .two_runs => |t| {
            fastmem.set(u8, buf[0..t.first_count], t.first_byte);
            fastmem.set(u8, buf[t.first_count..][0..t.second_count], t.second_byte);
            const tail_at = t.first_count + t.second_count;
            fastmem.copy(u8, buf[tail_at..][0..t.tail.len], t.tail);
            return buf[0 .. tail_at + t.tail.len];
        },
    }
}

const Row = struct {
    desc: []const u8,
    source: []const u8,
    output: Output,
};

/// The good corpus: every committed frame whose CLI verdict is a decode, with
/// the expected bytes the verdict pins. The one-shot's identity, the cap
/// boundary, the reader's boundary, and the walk all run over this table.
const rows = [_]Row{
    .{ .desc = "frame_raw", .source = &golden.frame_raw, .output = .{ .static = "zstd raw" } },
    .{ .desc = "frame_raw_empty", .source = &golden.frame_raw_empty, .output = .{ .static = "" } },
    .{ .desc = "frame_rle", .source = &golden.frame_rle, .output = .{ .static = "AAAAAAAAAA" } },
    .{
        .desc = "frame_multi",
        .source = &golden.frame_multi,
        .output = .{ .static = "abcdefghIIIIII" },
    },
    .{
        .desc = "frame_t1",
        .source = &golden.frame_t1,
        .output = .{ .static = &golden.t1_literals },
    },
    .{
        .desc = "frame_t1_errata",
        .source = &golden.frame_t1_errata,
        .output = .{ .static = &golden.t1_errata_literals },
    },
    .{
        .desc = "frame_treeless",
        .source = &golden.frame_treeless,
        .output = .{ .static = &[_]u8{ 0, 1, 4, 5, 0, 0, 0, 0, 0 } },
    },
    .{
        .desc = "frame_repeat",
        .source = &golden.frame_repeat,
        .output = .{ .static = &golden.frame_repeat_expected },
    },
    .{
        .desc = "frame_temp_offset",
        .source = &golden.frame_temp_offset,
        .output = .{ .static = &golden.frame_temp_offset_expected },
    },
    .{
        .desc = "frame_corner",
        .source = &golden.frame_corner,
        .output = .{ .static = &golden.frame_corner_expected },
    },
    .{
        .desc = "frame_two_byte",
        .source = &golden.frame_two_byte,
        .output = .{ .static = &golden.frame_two_byte_expected },
    },
    .{
        .desc = "frame_zero_seq",
        .source = &golden.frame_zero_seq,
        .output = .{ .static = &golden.frame_zero_seq_expected },
    },
    .{
        .desc = "frame_zero_seq_2b",
        .source = &golden.frame_zero_seq_2b,
        .output = .{ .static = &golden.frame_zero_seq_expected },
    },
    .{
        .desc = "frame_sequences_predefined",
        .source = &golden.frame_sequences_predefined,
        .output = .{ .static = &golden.sequences_predefined_expected },
    },
    .{
        .desc = "frame_sequences_rle_match_lengths",
        .source = &golden.frame_sequences_rle_match_lengths,
        .output = .{ .static = &golden.sequences_rle_match_lengths_expected },
    },
    .{
        .desc = "frame_sequences_fse_offsets",
        .source = &golden.frame_sequences_fse_offsets,
        .output = .{ .static = &golden.sequences_fse_offsets_expected },
    },
    .{
        .desc = "frame_sequences_fse_all",
        .source = &golden.frame_sequences_fse_all,
        .output = .{ .static = &golden.sequences_fse_all_expected },
    },
    .{
        .desc = "frame_literals_1stream",
        .source = &golden.frame_literals_1stream,
        .output = .{ .static = &golden.literals_1stream_expected },
    },
    .{
        .desc = "frame_literals_4stream_sf1",
        .source = &golden.frame_literals_4stream_sf1,
        .output = .{ .static = &golden.literals_4stream_sf1_expected },
    },
    .{
        .desc = "frame_literals_4stream_sf2",
        .source = &golden.frame_literals_4stream_sf2,
        .output = .{ .static = &golden.literals_4stream_sf2_expected },
    },
    .{
        .desc = "frame_literals_fse_tree",
        .source = &golden.frame_literals_fse_tree,
        .output = .{ .static = &golden.literals_fse_tree_expected },
    },
    .{ .desc = "frame_fcs1", .source = &golden.frame_fcs1, .output = .{ .static = "01234567" } },
    .{
        .desc = "frame_fcs2",
        .source = &golden.frame_fcs2,
        .output = .{ .splat = .{ .byte = 'A', .count = 300 } },
    },
    .{
        .desc = "frame_fcs2_single_segment",
        .source = &golden.frame_fcs2_single_segment,
        .output = .{ .splat = .{ .byte = 'A', .count = 300 } },
    },
    .{ .desc = "frame_fcs4", .source = &golden.frame_fcs4, .output = .{ .static = "01234567" } },
    .{ .desc = "frame_fcs8", .source = &golden.frame_fcs8, .output = .{ .static = "01234567" } },
    .{
        .desc = "frame_unused_bit",
        .source = &golden.frame_unused_bit,
        .output = .{ .static = "abcd" },
    },
    .{
        .desc = "frame_checksum",
        .source = &golden.frame_checksum,
        .output = .{ .static = "abcd" },
    },
    .{
        .desc = "frame_checksum_empty",
        .source = &golden.frame_checksum_empty,
        .output = .{ .static = "" },
    },
    .{
        .desc = "frame_checksum_off",
        .source = &golden.frame_checksum_off,
        .output = .{ .static = "abcd" },
    },
    .{
        .desc = "frame_checksum_multi",
        .source = &golden.frame_checksum_multi,
        .output = .{ .repeat = .{ .text = golden.frame_checksum_multi_text, .count = 3000 } },
    },
    .{
        .desc = "frame_window_1k",
        .source = &golden.frame_window_1k,
        .output = .{ .two_runs = .{
            .first_byte = 'A',
            .first_count = 1024,
            .second_byte = 'B',
            .second_count = 1024,
            .tail = "BBB",
        } },
    },
    .{
        .desc = "frame_window_128k",
        .source = &golden.frame_window_128k,
        .output = .{ .two_runs = .{
            .first_byte = 'A',
            .first_count = 131072,
            .second_byte = 'B',
            .second_count = 131072,
            .tail = "BBB",
        } },
    },
    .{
        .desc = "frame_window_1152",
        .source = &golden.frame_window_1152,
        .output = .{ .static = "" },
    },
    .{
        .desc = "skippable_prefix",
        .source = &golden.skippable_prefix,
        .output = .{ .static = "zstd raw" },
    },
    .{
        .desc = "skippable_sixteen",
        .source = &golden.skippable_sixteen,
        .output = .{ .static = "" },
    },
    .{
        .desc = "skippable_around",
        .source = &golden.skippable_around,
        .output = .{ .static = "zstd raw" },
    },
    .{
        .desc = "frame_trailing_garbage",
        .source = &golden.frame_trailing_garbage,
        .output = .{ .static = "zstd raw" },
    },
    .{
        .desc = "frame_two_frames",
        .source = &golden.frame_two_frames,
        .output = .{ .static = "zstd raw" },
    },
};

/// The index of a good row by name, at comptime — the seeds below name their
/// rows instead of numbering them.
fn rowIndex(comptime desc: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000);
        for (rows, 0..) |row, index| {
            if (mem.eql(u8, row.desc, desc)) return index;
        }
        @compileError("no good row named " ++ desc);
    }
}

comptime {
    for (rows) |row| {
        assert(row.source.len <= source_max);
        assert(row.source.len >= frame.magic_len);
    }
}

const BadRow = struct {
    desc: []const u8,
    source: []const u8,
    err: decode.DecompressError,
    /// The bytes the one-shot's failing decode wrote before the error: the
    /// sentinel floor, each one the count `decode.zig`'s tests pin.
    written: usize,
};

/// The bad-frame corpus (`golden.zig` records the CLI's exit-1 verdict for
/// each): the pinned error and the written floor the one-shot's tests
/// establish. T12's window pair, T13, and T14 are rows here.
const bad_rows = [_]BadRow{
    .{ .desc = "empty", .source = "", .err = error.Truncated, .written = 0 },
    .{ .desc = "frame_magic", .source = &golden.frame_magic, .err = error.Truncated, .written = 0 },
    .{
        .desc = "frame_reserved_bit",
        .source = &golden.frame_reserved_bit,
        .err = error.ReservedBitSet,
        .written = 0,
    },
    .{
        .desc = "frame_dictionary_id",
        .source = &golden.frame_dictionary_id,
        .err = error.DictionaryRequired,
        .written = 0,
    },
    .{
        .desc = "frame_dictionary_id_wide",
        .source = &golden.frame_dictionary_id_wide,
        .err = error.DictionaryRequired,
        .written = 0,
    },
    .{
        .desc = "frame_dictionary_id_truncated",
        .source = &golden.frame_dictionary_id_truncated,
        .err = error.Truncated,
        .written = 0,
    },
    .{
        .desc = "frame_reserved",
        .source = &golden.frame_reserved,
        .err = error.ReservedBlock,
        .written = 0,
    },
    .{
        .desc = "frame_oversize_raw",
        .source = &golden.frame_oversize_raw,
        .err = error.BlockOversize,
        .written = 0,
    },
    .{
        .desc = "frame_oversize_rle",
        .source = &golden.frame_oversize_rle,
        .err = error.BlockOversize,
        .written = 0,
    },
    .{
        .desc = "frame_single_segment_oversize",
        .source = &golden.frame_single_segment_oversize,
        .err = error.BlockOversize,
        .written = 0,
    },
    .{
        .desc = "frame_amplify_match",
        .source = &golden.frame_amplify_match,
        .err = error.BlockOversize,
        .written = 16,
    },
    .{
        .desc = "frame_oversize_literals",
        .source = &golden.frame_oversize_literals,
        .err = error.LiteralsTooLarge,
        .written = 0,
    },
    .{
        .desc = "frame_treeless_first",
        .source = &golden.frame_treeless_first,
        .err = error.TreelessLiteralsFirst,
        .written = 0,
    },
    .{
        .desc = "frame_repeat_first",
        .source = &golden.frame_repeat_first,
        .err = error.RepeatModeFirst,
        .written = 0,
    },
    .{
        .desc = "frame_no_sequences",
        .source = &golden.frame_no_sequences,
        .err = error.MalformedSequencesHeader,
        .written = 0,
    },
    .{
        .desc = "frame_short_sequences",
        .source = &golden.frame_short_sequences,
        .err = error.MalformedSequencesHeader,
        .written = 0,
    },
    .{
        .desc = "frame_short_raw",
        .source = &golden.frame_short_raw,
        .err = error.Truncated,
        .written = 0,
    },
    .{
        .desc = "frame_short_compressed",
        .source = &golden.frame_short_compressed,
        .err = error.Truncated,
        .written = 0,
    },
    .{
        .desc = "frame_truncated_header",
        .source = &golden.frame_truncated_header,
        .err = error.Truncated,
        .written = 0,
    },
    // T13 — the empty zero-size Compressed_Block: ours reads the missing
    // literals header and fails closed; the C reads it as a no-op.
    .{
        .desc = "frame_empty_compressed",
        .source = &golden.frame_empty_compressed,
        .err = error.MalformedLiteralsHeader,
        .written = 0,
    },
    .{
        .desc = "frame_fcs_short",
        .source = &golden.frame_fcs_short,
        .err = error.ContentSizeMismatch,
        .written = 8,
    },
    .{
        .desc = "frame_fcs_long",
        .source = &golden.frame_fcs_long,
        .err = error.ContentSizeMismatch,
        .written = 8,
    },
    // T14 — FCS 2^64-1: a declaration like any other, checked against the
    // decode; the C skips it as ZSTD_CONTENTSIZE_UNKNOWN.
    .{
        .desc = "frame_fcs_max",
        .source = &golden.frame_fcs_max,
        .err = error.ContentSizeMismatch,
        .written = 4,
    },
    // T12 — the one-byte-past-the-window pair: ours enforces §3.1.1.4's
    // declared bound where the C's whole-buffer decoder accepts.
    .{
        .desc = "frame_window_1k_over",
        .source = &golden.frame_window_1k_over,
        .err = error.OffsetTooFar,
        .written = 2048,
    },
    .{
        .desc = "frame_window_128k_over",
        .source = &golden.frame_window_128k_over,
        .err = error.OffsetTooFar,
        .written = 262144,
    },
    .{
        .desc = "frame_checksum_corrupt",
        .source = &golden.frame_checksum_corrupt,
        .err = error.WrongChecksum,
        .written = 4,
    },
    .{
        .desc = "frame_checksum_truncated",
        .source = &golden.frame_checksum_truncated,
        .err = error.Truncated,
        .written = 4,
    },
    .{
        .desc = "frame_bad_magic",
        .source = &golden.frame_bad_magic,
        .err = error.BadMagic,
        .written = 0,
    },
    .{
        .desc = "skippable_bad_magic",
        .source = &golden.skippable_bad_magic,
        .err = error.BadMagic,
        .written = 0,
    },
    .{
        .desc = "skippable_truncated",
        .source = &golden.skippable_truncated,
        .err = error.Truncated,
        .written = 0,
    },
    // §3.1.2's field maximum: 4 GiB of User_Data with three bytes present —
    // skipped by arithmetic, never staged (the gzip XLEN rule).
    .{
        .desc = "skippable_huge",
        .source = &golden.skippable_huge,
        .err = error.Truncated,
        .written = 0,
    },
};

fn badIndex(comptime desc: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000);
        for (bad_rows, 0..) |row, index| {
            if (mem.eql(u8, row.desc, desc)) return index;
        }
        @compileError("no bad row named " ++ desc);
    }
}

// ---------------------------------------------------------------------------
// The frame-structure model: the walk the mutations and boundary checks share
// ---------------------------------------------------------------------------

/// One complete frame unit's structure, walked with the public `frame` and
/// `block` API — the model the mutations classify against and the boundary
/// the reader's clean end is pinned to. `null` when the bytes do not form one
/// complete unit (a truncated chain, a partial skippable frame, a reserved
/// block, a missing trailer).
const FrameInfo = struct {
    /// The Zstandard frame's magic offset (after any leading skippable
    /// frames, `§3.1.2`).
    start: usize,
    header: frame.Header,
    /// The first Block_Header's offset and its parsed header.
    first_block_at: usize,
    first_block: block.Header,
    /// The first block's Block_Content offset.
    first_content_at: usize,
    /// How many blocks the chain carries.
    block_count: usize,
    /// The checksum trailer's offset, when the frame has one (`§3.1.1`).
    trailer_at: ?usize,
    /// The unit's last byte plus one: the reader's boundary.
    end: usize,
};

fn analyze(source: []const u8) ?FrameInfo {
    var cursor: usize = 0;
    while (true) {
        const kind = frame.classify(source[cursor..]) catch return null;
        if (kind == .zstandard) break;
        const head_len = frame.magic_len + frame.frame_size_len;
        if (source.len - cursor < head_len) return null;
        const user_len: usize =
            @intCast(readInt(u32, source[cursor + frame.magic_len ..][0..frame.frame_size_len]));
        if (source.len - cursor - head_len < user_len) return null;
        cursor += head_len + user_len;
    }
    const start = cursor;
    cursor += frame.magic_len;
    const header = frame.parseHeader(source[cursor..]) catch return null;
    cursor += header.bytes_consumed;
    var first_block: block.Header = undefined;
    var first_block_at: usize = 0;
    var first_content_at: usize = 0;
    var block_count: usize = 0;
    while (true) {
        const header_at = cursor;
        const bh = block.parseHeader(source[cursor..]) catch return null;
        if (block_count == 0) {
            first_block = bh;
            first_block_at = header_at;
            first_content_at = header_at + block.block_header_len;
        }
        block_count += 1;
        if (bh.block_type == .reserved) return null;
        cursor += block.block_header_len + block.contentLength(bh);
        if (cursor > source.len) return null;
        if (bh.last_block) break;
    }
    const trailer_at: ?usize = if (header.checksum) cursor else null;
    if (header.checksum) {
        if (source.len - cursor < frame.checksum_len) return null;
        cursor += frame.checksum_len;
    }
    return .{
        .start = start,
        .header = header,
        .first_block_at = first_block_at,
        .first_block = first_block,
        .first_content_at = first_content_at,
        .block_count = block_count,
        .trailer_at = trailer_at,
        .end = cursor,
    };
}

/// One unit sequence's boundary model: the first Zstandard frame's structure
/// when the sequence carries one, else the skippable-only span (`§3.1.2` —
/// a stream of only skippable frames is the clean end with zero bytes
/// served).
const Unit = struct {
    /// The first Zstandard frame, when there is one.
    frame: ?FrameInfo,
    /// The reader's boundary: the first frame's end, or the end of the
    /// skippable run.
    end: usize,
    /// Whether a checksum trailer is verified at the boundary.
    checksum: bool,
};

fn unitOf(source: []const u8) Unit {
    if (analyze(source)) |info| {
        return .{ .frame = info, .end = info.end, .checksum = info.header.checksum };
    }
    return .{ .frame = null, .end = source.len, .checksum = false };
}

// ---------------------------------------------------------------------------
// Target 1: the golden corpus through the one-shot and the walk
// ---------------------------------------------------------------------------

/// The `streamAll` walk's expected shape over a unit sequence.
const WalkKind = enum {
    /// Every frame unit decodes; the served bytes are the model's.
    all,
    /// Nothing but skippable frames (or nothing at all): the clean end with
    /// zero bytes served (`§3.1.2`, T10).
    zero,
    /// The first unit decodes, then the walk fails closed on the bytes after
    /// it (the coarse `error.ReadFailed`; the detail is the walk's own
    /// reader's).
    first_then_fail,
};

const WalkRow = struct { desc: []const u8, source: []const u8, output: Output, kind: WalkKind };

/// The walk corpus: the frame-unit cardinalities T10 records — concatenated
/// frames (the CLI decodes both), skippable-only (the clean end, zero bytes),
/// and garbage after a unit (fail closed, never silently skipped).
const walk_rows = [_]WalkRow{
    .{
        .desc = "frame_raw",
        .source = &golden.frame_raw,
        .output = .{ .static = "zstd raw" },
        .kind = .all,
    },
    .{
        .desc = "frame_two_frames",
        .source = &golden.frame_two_frames,
        .output = .{ .static = "zstd raw" ++ "second" },
        .kind = .all,
    },
    .{
        .desc = "skippable_prefix",
        .source = &golden.skippable_prefix,
        .output = .{ .static = "zstd raw" },
        .kind = .all,
    },
    .{
        .desc = "skippable_around",
        .source = &golden.skippable_around,
        .output = .{ .static = "zstd raw" },
        .kind = .all,
    },
    .{
        .desc = "frame_checksum_multi",
        .source = &golden.frame_checksum_multi,
        .output = .{ .repeat = .{ .text = golden.frame_checksum_multi_text, .count = 3000 } },
        .kind = .all,
    },
    .{
        .desc = "skippable_sixteen",
        .source = &golden.skippable_sixteen,
        .output = .{ .static = "" },
        .kind = .zero,
    },
    .{ .desc = "empty", .source = "", .output = .{ .static = "" }, .kind = .zero },
    .{
        .desc = "frame_trailing_garbage",
        .source = &golden.frame_trailing_garbage,
        .output = .{ .static = "zstd raw" },
        .kind = .first_then_fail,
    },
    .{
        .desc = "frame_checksum_corrupt",
        .source = &golden.frame_checksum_corrupt,
        .output = .{ .static = "abcd" },
        .kind = .first_then_fail,
    },
    .{
        .desc = "frame_fcs_max",
        .source = &golden.frame_fcs_max,
        .output = .{ .static = "abcd" },
        .kind = .first_then_fail,
    },
};

fn walkIndex(comptime desc: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000);
        for (walk_rows, 0..) |row, index| {
            if (mem.eql(u8, row.desc, desc)) return index;
        }
        @compileError("no walk row named " ++ desc);
    }
}

/// The reader over one frame unit, pumped to its clean end: identity against
/// the model, the trailer-verified clean end (no detail, state `done`), the
/// exact frame boundary with the markers unconsumed, and stickiness.
fn expectReaderIdentity(unit: Unit, framed: []const u8, expected: []const u8) !void {
    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(framed);
    var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf);
    try pump(&r.reader, &fw, pumpLimit(expected.len));
    try testing.expectEqual(expected.len, fw.end);
    try testing.expectEqualSlices(u8, expected, got[0..fw.end]);
    try testing.expectEqual(@as(?Reader.Error, null), r.err);
    try testing.expectEqual(internal.reader.State.done, r.state);
    try testing.expectEqual(unit.end, fixed_in.seek);
    try expectTrailerConsistent(framed[0..unit.end], unit.end, expected, unit.checksum);
    try expectStickyEnd(&r);
}

/// The `streamAll` walk over a unit sequence, checked against its kind.
fn expectWalk(row: WalkRow) !void {
    var expected_buf: [out_max]u8 = undefined;
    const expected = materialize(row.output, &expected_buf);
    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(row.source);
    switch (row.kind) {
        .all => {
            const served = try Reader.streamAll(fixture_window_len, &fixed_in, &fw, &rbuf);
            try testing.expectEqual(expected.len, served);
            try testing.expectEqualSlices(u8, expected, fw.buffered());
            try testing.expectEqual(row.source.len, fixed_in.seek);
        },
        .zero => {
            const served = try Reader.streamAll(fixture_window_len, &fixed_in, &fw, &rbuf);
            try testing.expectEqual(@as(usize, 0), served);
            try testing.expectEqual(@as(usize, 0), fw.end);
            try testing.expectEqual(row.source.len, fixed_in.seek);
        },
        .first_then_fail => {
            try testing.expectError(
                error.ReadFailed,
                Reader.streamAll(fixture_window_len, &fixed_in, &fw, &rbuf),
            );
            try testing.expectEqualSlices(u8, expected, fw.buffered());
        },
    }
}

/// Seeds for target 1: one per good row — the row index, a cap shape, and a
/// walk row — so the plain `zig build test` run replays every fixture.
const corpus: []const []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    const seeds: [rows.len][24]u8 = init: {
        var built: [rows.len][24]u8 = undefined;
        for (&built, 0..) |*seed, index| {
            mem.writeInt(u64, seed[0..8], @intCast(index), .little);
            mem.writeInt(u64, seed[8..16], @intCast(index % 4), .little);
            mem.writeInt(u64, seed[16..24], @intCast(index % walk_rows.len), .little);
        }
        break :init built;
    };
    var slices: [rows.len][]const u8 = undefined;
    for (&slices, 0..) |*slice, index| slice.* = &seeds[index];
    const frozen = slices;
    break :blk &frozen;
};

/// Target 1: the whole one-shot decoder over the CLI-verified corpus.
///
/// Attacks the frame layer's identity on every landed fixture — the Raw/RLE
/// and compressed blocks, the literals size formats, the sequences modes, the
/// FCS forms, the window fixtures, the checksum trailer, the skippable walk,
/// the trailing-bytes rule — through the cap boundary (exact, below, slack),
/// the sentinel overrun check, determinism, and the streaming reader's
/// agreement at the exact frame boundary. The corpus is the evidence: each
/// row's expected bytes are the pinned CLI's own `zstd -d` output
/// (`golden.zig`), so the identity check is a differential against the C
/// library, not against a local encoder (M5's).
fn fuzzGoldenCorpus(_: void, smith: *Smith) anyerror!void {
    const row = rows[smith.index(rows.len)];
    const shape = rangeAtMost(smith, 0, 3);
    const walk = walk_rows[smith.index(walk_rows.len)];

    var expected_buf: [out_max]u8 = undefined;
    const expected = materialize(row.output, &expected_buf);
    const unit = unitOf(row.source);
    try testing.expect(unit.end <= row.source.len);

    var window: [out_max + guard_len]u8 = undefined;

    // The exact cap: identity, and the sentinel proves nothing past it moved.
    sentinel.fill(&window);
    const n = try decode.decompress(row.source, window[0..expected.len]);
    try testing.expectEqual(expected.len, n);
    try testing.expectEqualSlices(u8, expected, window[0..n]);
    try sentinel.expect(&window, n);

    // Slack: the bytes past the decoded length are the caller's.
    sentinel.fill(&window);
    const m = try decode.decompress(row.source, &window);
    try testing.expectEqual(n, m);
    try testing.expectEqualSlices(u8, expected, window[0..m]);
    try sentinel.expect(&window, m);

    // Below the decoded length: fail closed, and the cap held.
    if (expected.len > 0) {
        const cap = switch (shape) {
            0 => expected.len - 1,
            1 => expected.len / 2,
            2 => 0,
            else => rangeAtMost(smith, 0, expected.len - 1),
        };
        sentinel.fill(&window);
        try testing.expectError(
            error.BufferTooSmall,
            decode.decompress(row.source, window[0..cap]),
        );
        try sentinel.expect(&window, cap);
    }

    // Determinism: a second decode of the same bytes is the same bytes.
    sentinel.fill(&window);
    const again = try decode.decompress(row.source, window[0..expected.len]);
    try testing.expectEqual(n, again);
    try testing.expectEqualSlices(u8, expected, window[0..again]);

    // The trailing-bytes boundary: markers after a frame unit are not part
    // of it (`§3.1` defines frames, not files; T10 records the CLI's
    // reading). A skippable-only run has no frame for the tail to be after:
    // the markers are the next unit's bytes, and a bad magic fails closed.
    var framed: [source_max + marker_len]u8 = undefined;
    fastmem.copy(u8, framed[0..row.source.len], row.source);
    fastmem.set(u8, framed[row.source.len..][0..marker_len], marker_byte);
    if (unit.frame != null) {
        sentinel.fill(&window);
        const f = try decode.decompress(
            framed[0 .. row.source.len + marker_len],
            window[0..expected.len],
        );
        try testing.expectEqual(expected.len, f);
        try testing.expectEqualSlices(u8, expected, window[0..f]);
        try sentinel.expect(&window, f);
    } else {
        sentinel.fill(&window);
        try testing.expectError(
            error.BadMagic,
            decode.decompress(framed[0 .. row.source.len + marker_len], window[0..expected.len]),
        );
        try sentinel.expect(&window, expected.len);
    }

    // The streaming reader over the same unit plus markers: identity and the
    // exact boundary. A skippable-only run is checked without markers — the
    // markers would be the next unit's bytes, and a bad magic there is the
    // walk's own refusal, not the unit's boundary.
    const reader_framed = if (unit.frame != null)
        framed[0 .. row.source.len + marker_len]
    else
        row.source;
    try expectReaderIdentity(unit, reader_framed, expected);

    // The `streamAll` walk over the frame units.
    try expectWalk(walk);
}

test "zstd fuzz: golden corpus" {
    try testing.fuzz({}, fuzzGoldenCorpus, .{ .corpus = corpus });
}

// ---------------------------------------------------------------------------
// Target 2: the bad-frame corpus and the mutation taxonomy
// ---------------------------------------------------------------------------

/// The outcome class a mutation pins (the container lanes' taxonomy, adapted
/// to the frame layer's names).
const Expected = enum {
    /// The mutation must decode to exactly the row's expected output.
    exact_source,
    /// Any failure: a frame whose end is gone never decodes.
    fail_any,
    /// `error.Truncated`.
    fail_truncated,
    /// `error.BadMagic`.
    fail_bad_magic,
    /// `error.ReservedBitSet` (`§3.1.1.1.1.4`).
    fail_reserved_bit,
    /// `error.DictionaryRequired` (`§3.1.1.1.3`, OQ4).
    fail_dictionary,
    /// `error.BlockOversize` (`§3.1.1.2.4`, T7's coupling).
    fail_block_oversize,
    /// `error.ReservedBlock` (`§3.1.1.2.2`).
    fail_reserved_block,
    /// `error.ContentSizeMismatch` (`§3.1.1.1.4`).
    fail_content_size,
    /// `error.WrongChecksum` (`§3.1.1`, T8).
    fail_wrong_checksum,
    /// Fail closed or succeed, with the universal properties checked.
    unknown,
};

const Mutated = struct {
    len: usize,
    expected: Expected,
    /// The frame unit's end in the mutated bytes: the position a clean reader
    /// end must stop at for `exact_source`.
    frame_end: usize,
};

/// The mutation operators. Each keeps `buf[0..len]` in bounds and stays
/// inside the mutation buffer.
const Mutation = enum(u8) {
    /// Cut the unit at a Smith-chosen byte: inside the trailer is
    /// `Truncated` exactly, elsewhere the bits run out first.
    truncate,
    /// A flip inside the 4-byte Magic_Number (`§3.1`, `§3.1.2`): neither
    /// family (`BadMagic`). One byte of either magic can never land on the
    /// other.
    flip_magic,
    /// Descriptor bit 3 (`§3.1.1.1.1.4`): "must ensure it is not set".
    set_reserved_bit,
    /// A Dictionary_ID_Flag bit (`§3.1.1.1.3`): refused at the first ID byte,
    /// before any body byte.
    set_dictionary_flag,
    /// Descriptor bit 4 (`§3.1.1.1.1.3`): "shall not interpret this bit" —
    /// the frame decodes identically (ZD7).
    flip_unused_bit,
    /// A flip in the block chain: the body's business (`unknown`).
    flip_body,
    /// A flip inside the checksum trailer: the body is untouched, so the
    /// check must fail (`§3.1.1`, T8).
    flip_trailer,
    /// Block type 3 (`§3.1.1.2.2`): "a compliant decoder must reject it".
    block_reserved_type,
    /// Block_Size 2^21 - 1: past Block_Maximum_Size for every fixture's
    /// window (`§3.1.1.2.4`).
    block_oversize,
    /// The Last_Block bit on the first block (`§3.1.1.2.1`): a one-block
    /// frame is unchanged, a chain stops early.
    last_block_first,
    /// A poked Window_Descriptor byte (`§3.1.1.1.2`): the window arithmetic
    /// against the block max and the offset bound.
    poke_window,
    /// A poked Frame_Content_Size byte (`§3.1.1.1.4`), classified against
    /// the single-segment window coupling.
    poke_fcs,
    /// A flip inside the first compressed block's content: the entropy
    /// layers' business.
    entropy_poke,
    /// Markers after the unit: ignored by the one-shot, unconsumed by the
    /// reader.
    append_markers,
    /// A second frame unit after the first: not consumed by one reader.
    duplicate_frame,
    /// A skippable frame before the unit (`§3.1.2`): consumed and ignored.
    skippable_prefix,
    /// A skippable frame declaring 4 GiB of User_Data with three bytes
    /// present: the walk runs out, nothing is staged.
    skippable_huge_prefix,
};

/// The byte range a body mutation may touch: the first block up to the
/// trailer (or the unit's end).
fn bodyEnd(info: FrameInfo) usize {
    return info.trailer_at orelse info.end;
}

/// Read a Frame_Content_Size field (`§3.1.1.1.4`): the 2-byte form carries
/// the +256 offset.
fn readFcs(bytes: []const u8) u64 {
    return switch (bytes.len) {
        1 => bytes[0],
        2 => @as(u64, readInt(u16, bytes[0..2])) + 256,
        4 => readInt(u32, bytes[0..4]),
        8 => readInt(u64, bytes[0..8]),
        else => unreachable,
    };
}

/// Poke one Frame_Content_Size byte and classify (`§3.1.1.1.4`): a
/// non-single-segment frame's window is untouched, so the only new failure is
/// the size check; a single-segment frame's Window_Size *is* the FCS
/// (`§3.1.1.1.1.2`), so a smaller declaration can starve Block_Maximum_Size
/// and fail `BlockOversize` first (T7), while a larger one still ends at the
/// size check.
fn pokeFcs(smith: *Smith, buf: []u8, info: FrameInfo) Mutated {
    const fcs_len = frame.fcsFieldSize(info.header.descriptor);
    if (fcs_len == 0) {
        // No Frame_Content_Size to poke: the body flip stands in.
        buf[rangeAtMost(smith, info.first_block_at, bodyEnd(info))] ^= flipValue(smith);
        return .{ .len = info.end, .expected = .unknown, .frame_end = info.end };
    }
    // The FCS is the header's last field, so it ends where the block chain
    // begins.
    const fcs_at = info.first_block_at - fcs_len;
    buf[fcs_at + rangeAtMost(smith, 0, fcs_len - 1)] ^= flipValue(smith);
    const new_fcs = readFcs(buf[fcs_at..][0..fcs_len]);
    const block_max: u64 = @min(new_fcs, @as(u64, block.max_block_size));
    const oversize = info.first_block.block_size > block_max;
    var expected: Expected = .fail_content_size;
    if (info.header.descriptor & frame.descriptor_single_segment != 0) {
        if (oversize) {
            expected = .fail_block_oversize;
        } else if (new_fcs < info.header.window_size) {
            // The window shrank: a match may now reach past it (`§3.1.1.4`),
            // so the failure's name is the decode's business.
            expected = .unknown;
        }
    }
    return .{ .len = info.end, .expected = expected, .frame_end = info.end };
}

/// Apply one Smith-chosen mutation to the row's frame unit in `buf` and
/// return the mutated length, the class the contract pins, and the unit's end
/// in the mutated bytes.
fn mutate(smith: *Smith, buf: []u8, row: Row) Mutated {
    // The comptime-known prefix lengths below (the skippable-magic arrays)
    // drive fastmem's inline dispatch search past the default comptime
    // branch quota on the 32-bit baseline targets (where the search's
    // fallback table is the widest); raised once, here, for the whole body.
    @setEvalBranchQuota(1_000_000);
    const info = analyze(row.source).?;
    fastmem.copy(u8, buf[0..row.source.len], row.source);
    var len = row.source.len;
    var frame_end = info.end;
    var expected: Expected = .unknown;
    switch (smith.value(Mutation)) {
        .truncate => {
            const cut = rangeAtMost(smith, 0, row.source.len - 1);
            len = cut;
            if (cut >= frame_end) {
                // The unit is complete; only bytes after it were cut.
                expected = .exact_source;
            } else if (cut > 0 and cut == info.start) {
                // The cut removed the whole Zstandard frame and left only
                // complete skippable frames: the only-skippables clean end
                // with zero bytes served (`§3.1.2`, T10).
                expected = .unknown;
            } else if (cut < info.first_block_at) {
                // Inside a leading skippable frame, the Magic_Number, or the
                // Frame_Header: the input ends before any body byte.
                expected = .fail_truncated;
            } else if (info.trailer_at) |trailer_at| {
                // The body's bits run out first; a cut inside the trailer
                // leaves the body intact and is `Truncated` exactly.
                expected = if (cut >= trailer_at) .fail_truncated else .fail_any;
            } else {
                expected = .fail_any;
            }
        },
        .flip_magic => {
            buf[rangeAtMost(smith, 0, frame.magic_len - 1)] ^= flipValue(smith);
            // One byte of either magic can never reach the other family,
            // but a skippable magic's low nibble is its tag (`§3.1.2`): a
            // flip that keeps the front in the skippable range (byte 0 into
            // 0x50-0x5f) leaves a valid frame unit, and the walk proceeds
            // to the frame behind it.
            const magic_now = readInt(u32, buf[0..frame.magic_len]);
            expected = if (magic_now & frame.skippable_magic_mask == frame.skippable_magic_base)
                .exact_source
            else
                .fail_bad_magic;
        },
        .set_reserved_bit => {
            buf[info.start + frame.magic_len] |= frame.descriptor_reserved;
            expected = .fail_reserved_bit;
        },
        .set_dictionary_flag => {
            const bit: u8 = @as(u8, 1) << @intCast(rangeAtMost(smith, 0, 1));
            buf[info.start + frame.magic_len] |= bit;
            expected = .fail_dictionary;
        },
        .flip_unused_bit => {
            buf[info.start + frame.magic_len] ^= frame.descriptor_unused;
            expected = .exact_source;
        },
        .flip_body => {
            buf[rangeAtMost(smith, info.first_block_at, bodyEnd(info))] ^= flipValue(smith);
            expected = .unknown;
        },
        .flip_trailer => {
            if (info.trailer_at) |trailer_at| {
                const at = trailer_at + rangeAtMost(smith, 0, frame.checksum_len - 1);
                buf[at] ^= flipValue(smith);
                expected = .fail_wrong_checksum;
            } else {
                buf[rangeAtMost(smith, info.first_block_at, bodyEnd(info))] ^= flipValue(smith);
                expected = .unknown;
            }
        },
        .block_reserved_type => {
            buf[info.first_block_at] |= 0b0000_0110;
            expected = .fail_reserved_block;
        },
        .block_oversize => {
            buf[info.first_block_at] |= 0b1111_1000;
            buf[info.first_block_at + 1] = 0xff;
            buf[info.first_block_at + 2] = 0xff;
            expected = .fail_block_oversize;
        },
        .last_block_first => {
            buf[info.first_block_at] |= 1;
            expected = if (info.block_count == 1) .exact_source else .unknown;
        },
        .poke_window => {
            if (info.header.descriptor & frame.descriptor_single_segment != 0) {
                // Single-segment: Window_Size is the FCS; the FCS poke is
                // the same mutation.
                return pokeFcs(smith, buf, info);
            }
            buf[info.start + frame.magic_len + 1] = smith.value(u8);
            expected = .unknown;
        },
        .poke_fcs => return pokeFcs(smith, buf, info),
        .entropy_poke => {
            if (info.first_block.block_type == .compressed and info.first_block.block_size > 0) {
                const at = info.first_content_at +
                    rangeAtMost(smith, 0, info.first_block.block_size - 1);
                buf[at] ^= flipValue(smith);
            } else {
                buf[rangeAtMost(smith, info.first_block_at, bodyEnd(info))] ^= flipValue(smith);
            }
            expected = .unknown;
        },
        .append_markers => {
            const extra = rangeAtMost(smith, 1, 64);
            fastmem.set(u8, buf[len..][0..extra], marker_byte);
            len += extra;
            expected = .exact_source;
        },
        .duplicate_frame => {
            fastmem.copy(u8, buf[len..][0..frame_end], buf[0..frame_end]);
            len += frame_end;
            expected = .exact_source;
        },
        .skippable_prefix => {
            const prefix = [_]u8{ 0x50, 0x2a, 0x4d, 0x18, 4, 0, 0, 0, 'm', 'e', 't', 'a' };
            fastmem.move(u8, buf[prefix.len..][0..row.source.len], buf[0..row.source.len]);
            fastmem.copy(u8, buf[0..prefix.len], &prefix);
            len += prefix.len;
            frame_end += prefix.len;
            expected = .exact_source;
        },
        .skippable_huge_prefix => {
            const prefix = [_]u8{ 0x51, 0x2a, 0x4d, 0x18, 0xff, 0xff, 0xff, 0xff, 'a', 'b', 'c' };
            fastmem.move(u8, buf[prefix.len..][0..row.source.len], buf[0..row.source.len]);
            fastmem.copy(u8, buf[0..prefix.len], &prefix);
            len += prefix.len;
            expected = .fail_truncated;
        },
    }
    return .{ .len = len, .expected = expected, .frame_end = frame_end };
}

/// The one-shot under the mutated bytes, checked against the mutation's
/// class. Every decode pre-fills the window with cycling sentinels and proves
/// the bytes at and past the cap are untouched (the amplification rule).
fn checkOneShot(mutated: []const u8, expected_output: []const u8, meta: Mutated, cap: usize) !void {
    var window: [out_max + guard_len]u8 = undefined;
    sentinel.fill(&window);
    const target = window[0..cap];
    const result = decode.decompress(mutated, target);
    switch (meta.expected) {
        .exact_source => {
            const n = try result;
            try testing.expectEqual(expected_output.len, n);
            try testing.expectEqualSlices(u8, expected_output, target[0..n]);
            try sentinel.expect(&window, n);
        },
        .fail_any => {
            try expectFailure(result);
            try sentinel.expect(&window, cap);
        },
        .fail_truncated => {
            try testing.expectError(error.Truncated, result);
            try sentinel.expect(&window, cap);
        },
        .fail_bad_magic => {
            try testing.expectError(error.BadMagic, result);
            try sentinel.expect(&window, cap);
        },
        .fail_reserved_bit => {
            try testing.expectError(error.ReservedBitSet, result);
            try sentinel.expect(&window, cap);
        },
        .fail_dictionary => {
            try testing.expectError(error.DictionaryRequired, result);
            try sentinel.expect(&window, cap);
        },
        .fail_block_oversize => {
            try testing.expectError(error.BlockOversize, result);
            try sentinel.expect(&window, cap);
        },
        .fail_reserved_block => {
            try testing.expectError(error.ReservedBlock, result);
            try sentinel.expect(&window, cap);
        },
        .fail_content_size => {
            try testing.expectError(error.ContentSizeMismatch, result);
            try sentinel.expect(&window, cap);
        },
        .fail_wrong_checksum => {
            try testing.expectError(error.WrongChecksum, result);
            try sentinel.expect(&window, cap);
        },
        .unknown => {
            if (result) |n| {
                try testing.expect(n <= cap);
                try sentinel.expect(&window, n);
            } else |_| {
                try sentinel.expect(&window, cap);
            }
        },
    }
}

/// The reader's window cap is the one refusal the one-shot does not have
/// (`§3.1.1.1.2`: "a decoder is allowed to reject a compressed frame that
/// requests a memory size beyond the decoder's authorized range"): a pinned
/// frame-layer detail must hold unless the mutated frame's declared window
/// exceeds the reader buffer's, where `WindowTooLarge` is the reader's
/// answer and the pinned detail remains the one-shot's.
fn expectReaderDetail(detail: Reader.Error, want: Reader.Error, info: ?FrameInfo) !void {
    if (info) |i| {
        if (i.header.window_size > fixture_window_len) {
            try testing.expectEqual(Reader.Error.WindowTooLarge, detail);
            return;
        }
    }
    try testing.expectEqual(want, detail);
}

/// The streaming reader under the mutated bytes, checked against the
/// mutation's class and the one-shot's uncapped verdict. The universal
/// property: the two decode paths agree — a reader failure on bytes the
/// uncapped one-shot decoded is the window cap (`WindowTooLarge`), the one
/// refusal only the reader has — and a clean end proves the trailer matched
/// the reference XXH64 of the reader's own output at the exact boundary.
fn checkReader(
    mutated: []const u8,
    expected_output: []const u8,
    meta: Mutated,
    info: ?FrameInfo,
    full: decode.DecompressError!usize,
    full_output: []const u8,
) !void {
    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(mutated);
    var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf);
    const pumped = try pumpCapped(&r.reader, &fw, pumpLimit(out_max));
    const served = pumped.served;

    switch (pumped.stop) {
        .end_of_stream => {
            try testing.expect(meta.expected == .exact_source or meta.expected == .unknown);
            try testing.expectEqual(internal.reader.State.done, r.state);
            try testing.expectEqual(@as(?Reader.Error, null), r.err);
            if (meta.expected == .exact_source) {
                try testing.expectEqual(expected_output.len, served);
                try testing.expectEqualSlices(u8, expected_output, got[0..served]);
                try testing.expectEqual(meta.frame_end, fixed_in.seek);
            }
            if (full) |m| {
                try testing.expectEqual(m, served);
                try testing.expectEqualSlices(u8, full_output[0..m], got[0..served]);
            } else |err| switch (err) {
                // The reader has no output cap: it cannot end cleanly on
                // bytes the uncapped one-shot refused.
                else => return error.ReaderOutranOneShot,
            }
            if (info) |i| {
                try expectTrailerConsistent(
                    mutated,
                    fixed_in.seek,
                    got[0..served],
                    i.header.checksum,
                );
            }
            try expectStickyEnd(&r);
        },
        .read_failed => {
            try testing.expect(meta.expected != .exact_source);
            const detail = r.err.?;
            switch (meta.expected) {
                .fail_truncated => try expectReaderDetail(detail, Reader.Error.Truncated, info),
                .fail_bad_magic => try expectReaderDetail(detail, Reader.Error.BadMagic, info),
                .fail_reserved_bit => try expectReaderDetail(
                    detail,
                    Reader.Error.ReservedBitSet,
                    info,
                ),
                .fail_dictionary => try expectReaderDetail(
                    detail,
                    Reader.Error.DictionaryRequired,
                    info,
                ),
                .fail_block_oversize => try expectReaderDetail(
                    detail,
                    Reader.Error.BlockOversize,
                    info,
                ),
                .fail_reserved_block => try expectReaderDetail(
                    detail,
                    Reader.Error.ReservedBlock,
                    info,
                ),
                .fail_content_size => try expectReaderDetail(
                    detail,
                    Reader.Error.ContentSizeMismatch,
                    info,
                ),
                .fail_wrong_checksum => try expectReaderDetail(
                    detail,
                    Reader.Error.WrongChecksum,
                    info,
                ),
                // An unpinned mutation (`unknown`) or a cut member
                // (`fail_any`): the detail is the mutation's business. The
                // agreement check below is the pin.
                .fail_any, .unknown => {},
                .exact_source => unreachable,
            }
            if (full) |_| {
                // The uncapped one-shot decoded these bytes: the reader's
                // only own refusal is the window cap.
                try testing.expectEqual(Reader.Error.WindowTooLarge, detail);
            } else |err| {
                if (err != error.BufferTooSmall) {
                    // The reader's only own refusal is the window cap; the
                    // one recorded codec divergence is the RLE staging
                    // order (the pinned test at the file's end): an RLE
                    // block whose declared Block_Size is past
                    // Block_Maximum_Size with its content byte missing
                    // stages the content first and reports the input's end
                    // (`Truncated`) where the one-shot's declared-size check
                    // fires `BlockOversize` first. Both fail closed.
                    const rle_staging_order = err == error.BlockOversize and
                        detail == Reader.Error.Truncated;
                    try testing.expect(
                        sameErrorName(err, detail) or
                            detail == Reader.Error.WindowTooLarge or
                            rle_staging_order,
                    );
                }
            }
            try expectStickyFailure(&r);
        },
        .output_full => {
            // Only an uncapped expansion past the harness window (an
            // unknown-class mutation): the cap is the writer's, not the
            // codec's.
            try testing.expectEqual(Expected.unknown, meta.expected);
            try testing.expectEqual(out_max, served);
            if (full) |m| {
                try testing.expectEqual(out_max, m);
            } else |err| {
                try testing.expectEqual(error.BufferTooSmall, err);
            }
        },
    }
}

/// The bad-frame lane: every committed negative fixture, one-shot and reader,
/// with the pinned error and the written floor.
fn fuzzBadRows(smith: *Smith) !void {
    const row = bad_rows[smith.index(bad_rows.len)];
    var window: [out_max + guard_len]u8 = undefined;
    sentinel.fill(&window);
    try testing.expectError(row.err, decode.decompress(row.source, window[0..out_max]));
    try sentinel.expect(&window, row.written);

    // The streaming reader reports the same detail, stickily, before it can
    // serve past the failure.
    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(row.source);
    var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf);
    const pumped = try pumpCapped(&r.reader, &fw, pumpLimit(out_max));
    try testing.expectEqual(Stop.read_failed, pumped.stop);
    try testing.expect(sameErrorName(row.err, r.err.?));
    try expectStickyFailure(&r);
}

/// Target 2: the bad-frame corpus and the mutation taxonomy.
///
/// Attacks the header parse (the magic, the reserved bit, the dictionary
/// flag, the unused bit, the FCS forms and the single-segment window
/// coupling), the block header (the reserved type, Block_Size past
/// Block_Maximum_Size, Last_Block), the entropy bytes, the checksum trailer,
/// truncation at every position, and the skippable walk. The property: the
/// committed fixtures' errors and written floors hold; a mutation's class
/// holds; the one-shot and the streaming reader agree on the same bytes
/// (same output, or the same named error, `WindowTooLarge` excepted); a clean
/// end is trailer-verified at the exact boundary; a failure is sticky; and
/// the cap held on every failure.
fn fuzzCorruption(_: void, smith: *Smith) anyerror!void {
    if (smith.boolWeighted(1, 3)) {
        try fuzzBadRows(smith);
        return;
    }
    const row = mutable_rows[smith.index(mutable_rows.len)];
    var expected_buf: [out_max]u8 = undefined;
    const expected = materialize(row.output, &expected_buf);

    var mut_buf: [mutation_max]u8 = undefined;
    const meta = mutate(smith, &mut_buf, row);
    const mutated = mut_buf[0..meta.len];
    const info = analyze(mutated);

    // The cap: the expected length for the pinned classes (so `exact_source`
    // can succeed and the pinned failures land where the class says), a
    // Smith-chosen cap otherwise.
    const cap = switch (meta.expected) {
        .exact_source,
        .fail_any,
        .fail_truncated,
        .fail_bad_magic,
        .fail_reserved_bit,
        .fail_dictionary,
        .fail_block_oversize,
        .fail_reserved_block,
        .fail_content_size,
        .fail_wrong_checksum,
        => expected.len,
        .unknown => rangeAtMost(smith, 0, out_max),
    };

    // The capped one-shot: the class pin and the cap invariant.
    try checkOneShot(mutated, expected, meta, cap);

    // The uncapped verdict: the reader's reference, and the determinism pin
    // (a second decode of the same bytes is the same bytes).
    var full_window: [out_max + guard_len]u8 = undefined;
    sentinel.fill(&full_window);
    const full = decode.decompress(mutated, full_window[0..out_max]);
    const full_len = full catch out_max;
    try sentinel.expect(&full_window, full_len);
    {
        var window: [out_max + guard_len]u8 = undefined;
        sentinel.fill(&window);
        const capped = decode.decompress(mutated, window[0..cap]);
        if (capped) |n| {
            if (full) |m| {
                try testing.expectEqual(n, m);
                try testing.expectEqualSlices(u8, window[0..n], full_window[0..m]);
            } else |_| {
                // The uncapped decode can only fail where the capped one
                // did, plus the cap itself: a capped success on bytes the
                // full window refused is a contradiction.
                return error.CapDisagreement;
            }
        } else |err| {
            // A capped failure other than the cap itself must reproduce
            // uncapped.
            if (err != error.BufferTooSmall) try testing.expectError(err, full);
        }
    }

    try checkReader(mutated, expected, meta, info, full, full_window[0..out_max]);
}

/// The rows the mutation lane may pick: those whose unit is a complete
/// Zstandard frame (the all-skippable row has no header to poke).
const mutable_rows: []const Row = blk: {
    @setEvalBranchQuota(100_000);
    var built: [rows.len]Row = undefined;
    var count: usize = 0;
    for (rows) |row| {
        if (analyze(row.source) != null) {
            built[count] = row;
            count += 1;
        }
    }
    const frozen = built;
    break :blk frozen[0..count];
};

fn mutableIndex(comptime desc: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000);
        for (mutable_rows, 0..) |row, index| {
            if (mem.eql(u8, row.desc, desc)) return index;
        }
        @compileError("no mutable row named " ++ desc);
    }
}

/// Seeds for target 2: the bad lane (one seed per bad row) and one mutation
/// per operator over the row that exercises it.
fn badSeed(comptime desc: []const u8) [16]u8 {
    var seed: [16]u8 = undefined;
    mem.writeInt(u64, seed[0..8], 1, .little);
    mem.writeInt(u64, seed[8..16], badIndex(desc), .little);
    return seed;
}

fn mutationSeed(comptime row: []const u8, comptime mutation: Mutation, comptime param: u64) [32]u8 {
    var seed: [32]u8 = undefined;
    mem.writeInt(u64, seed[0..8], 0, .little);
    mem.writeInt(u64, seed[8..16], mutableIndex(row), .little);
    mem.writeInt(u64, seed[16..24], @intFromEnum(mutation), .little);
    mem.writeInt(u64, seed[24..32], param, .little);
    return seed;
}

const corrupt_corpus: []const []const u8 = &.{
    &badSeed("empty"),
    &badSeed("frame_magic"),
    &badSeed("frame_reserved_bit"),
    &badSeed("frame_dictionary_id"),
    &badSeed("frame_dictionary_id_wide"),
    &badSeed("frame_dictionary_id_truncated"),
    &badSeed("frame_reserved"),
    &badSeed("frame_oversize_raw"),
    &badSeed("frame_oversize_rle"),
    &badSeed("frame_single_segment_oversize"),
    &badSeed("frame_amplify_match"),
    &badSeed("frame_oversize_literals"),
    &badSeed("frame_treeless_first"),
    &badSeed("frame_repeat_first"),
    &badSeed("frame_no_sequences"),
    &badSeed("frame_short_sequences"),
    &badSeed("frame_short_raw"),
    &badSeed("frame_short_compressed"),
    &badSeed("frame_truncated_header"),
    &badSeed("frame_empty_compressed"),
    &badSeed("frame_fcs_short"),
    &badSeed("frame_fcs_long"),
    &badSeed("frame_fcs_max"),
    &badSeed("frame_window_1k_over"),
    &badSeed("frame_window_128k_over"),
    &badSeed("frame_checksum_corrupt"),
    &badSeed("frame_checksum_truncated"),
    &badSeed("frame_bad_magic"),
    &badSeed("skippable_bad_magic"),
    &badSeed("skippable_truncated"),
    &badSeed("skippable_huge"),
    &mutationSeed("frame_checksum", .truncate, 20),
    &mutationSeed("frame_raw", .flip_magic, 0),
    &mutationSeed("frame_raw", .set_reserved_bit, 0),
    &mutationSeed("frame_raw", .set_dictionary_flag, 0),
    &mutationSeed("frame_raw", .flip_unused_bit, 0),
    &mutationSeed("frame_t1", .flip_body, 0),
    &mutationSeed("frame_checksum", .flip_trailer, 0),
    &mutationSeed("frame_raw", .block_reserved_type, 0),
    &mutationSeed("frame_raw", .block_oversize, 0),
    &mutationSeed("frame_multi", .last_block_first, 0),
    &mutationSeed("frame_window_1k", .poke_window, 0),
    &mutationSeed("frame_fcs4", .poke_fcs, 0),
    &mutationSeed("frame_literals_1stream", .entropy_poke, 0),
    &mutationSeed("frame_raw", .append_markers, 0),
    &mutationSeed("frame_checksum", .duplicate_frame, 0),
    &mutationSeed("frame_raw", .skippable_prefix, 0),
    &mutationSeed("frame_raw", .skippable_huge_prefix, 0),
    // The first budget run's finding, seeded: a single-segment FCS poke that
    // grows the window past the reader buffer's authorization — the one-shot
    // fails `ContentSizeMismatch`, the reader `WindowTooLarge` (the recorded
    // divergence), and both must be the class the mutation pins.
    &mutationSeed("frame_checksum_multi", .poke_fcs, 3),
    // The second budget run's findings, seeded: a cut exactly at the leading
    // skippable frame's end — the only-skippables clean end with zero bytes
    // served, not a failure (T10) — and the zero-byte cut, which is
    // `Truncated` (no unit began).
    &mutationSeed("skippable_around", .truncate, 10),
    &mutationSeed("skippable_prefix", .truncate, 0),
    &mutationSeed("frame_raw", .truncate, 0),
    // The third budget run's finding, seeded: a flip of the leading
    // skippable magic's tag nibble leaves a valid skippable frame, so the
    // walk proceeds and the frame behind it decodes (not `BadMagic`).
    &mutationSeed("skippable_around", .flip_magic, 0),
};

test "zstd fuzz: corruption" {
    try testing.fuzz({}, fuzzCorruption, .{ .corpus = corrupt_corpus });
}

// ---------------------------------------------------------------------------
// Target 3: the reader's consumer machinery
// ---------------------------------------------------------------------------

/// The consumer ops the reader target mixes: the `Io.Reader` surface the
/// README's "Streaming" section contracts on.
const ReadOp = enum(u8) {
    peek,
    take,
    discard_all,
    read_slice_all,
    stream_fixed,
    /// The interface's zero-length request (a poll). Mid-frame it is a
    /// zero-byte serve; on a done reader it reports `EndOfStream`. Both are
    /// legal; nothing may be lost either way.
    poll,
    /// A request past the contiguous-read cap: served when the window has
    /// room, `StreamTooLong` when it does not — never an assert.
    over_cap_take,
    /// A peek past the cap with no `left` guard: at the frame's tail the
    /// trailer step must run before the clean end is reported (the M3 B1
    /// shape; a clean `EndOfStream` always means the trailer was verified).
    over_end_peek,
    /// A peek of nearly the whole buffer: past `buffer.len - seek` as soon
    /// as the consumer has advanced, so the std fill routes it through the
    /// codec's `rebase` — the trailer branch the B1 entry names.
    over_buffer_peek,
};

/// Target 3: the reader's consumer machinery, Smith-driven.
///
/// Attacks the vtable surface (`peek`/`take`/`discardAll`/`readSliceAll`/
/// `stream`), the serving region's slide and its retained history, the
/// contiguity cap, the trailer verification at the clean end through both
/// `fill` and `rebase`, and the boundary: the frame unit followed by markers
/// stops exactly at the unit's last byte under every op. The input side is
/// sometimes a small `Io.Reader.Limited` buffer (at the documented 4-byte
/// minimum), so the header and the block staging cross fills.
fn fuzzReaderMachinery(_: void, smith: *Smith) anyerror!void {
    const row = rows[smith.index(rows.len)];
    var expected_buf: [out_max]u8 = undefined;
    const expected = materialize(row.output, &expected_buf);
    const unit = unitOf(row.source);

    // Markers after the frame unit: the reader must stop at the unit's last
    // byte whatever the consumer ops do. A skippable-only run is checked
    // bare — markers behind it are the next unit's bytes, and a bad magic
    // there is the walk's own refusal.
    var framed: [source_max + marker_len]u8 = undefined;
    fastmem.copy(u8, framed[0..row.source.len], row.source);
    const framed_len = if (unit.frame != null) blk: {
        fastmem.set(u8, framed[row.source.len..][0..marker_len], marker_byte);
        break :blk row.source.len + marker_len;
    } else row.source.len;

    // The input side: sometimes a chunked reader whose buffer is small — the
    // documented 4-byte minimum is the frame layer's largest fixed-size read
    // — so the header and the block staging cross fills.
    var chunk_buf: [64]u8 = undefined;
    var fixed_in: Io.Reader = .fixed(framed[0..framed_len]);
    var limited: Io.Reader.Limited = undefined;
    const chunked = smith.boolWeighted(1, 3);
    const input_reader: *Io.Reader = if (chunked) blk: {
        limited = .init(&fixed_in, .unlimited, chunk_buf[0..rangeAtMost(smith, 4, chunk_buf.len)]);
        break :blk &limited.interface;
    } else &fixed_in;

    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var r: Reader = .init(fixture_window_len, input_reader, &rbuf);

    var pos: usize = 0;
    var ops: usize = 0;
    var stalls: usize = 0;
    var dead = false;
    while (pos < expected.len and ops < 64) : (ops += 1) {
        const left = expected.len - pos;
        switch (smith.value(ReadOp)) {
            .peek => {
                // README, "Streaming": any contiguous request of at most
                // Block_Maximum_Size is served, so a failure here is the
                // contiguity stop, not a decode error.
                const n = @min(left, rangeAtMost(smith, 1, windowTailLen()));
                if (r.reader.peek(n)) |served| {
                    try testing.expectEqualSlices(u8, expected[pos..][0..n], served);
                } else |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                }
            },
            .take => {
                const n = @min(left, rangeAtMost(smith, 1, windowTailLen()));
                if (r.reader.take(n)) |served| {
                    try testing.expectEqualSlices(u8, expected[pos..][0..n], served);
                    pos += n;
                } else |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                }
            },
            .discard_all => {
                const n = @min(left, rangeAtMost(smith, 1, out_max));
                r.reader.discardAll(n) catch |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                };
                pos += n;
            },
            .read_slice_all => {
                var tmp: [8 * 1024]u8 = undefined;
                const n = @min(left, rangeAtMost(smith, 1, tmp.len));
                r.reader.readSliceAll(tmp[0..n]) catch |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                };
                try testing.expectEqualSlices(u8, expected[pos..][0..n], tmp[0..n]);
                pos += n;
            },
            .stream_fixed => {
                // `stream` may serve from the window or fill it; the bytes
                // land in the fixed writer, so the served count is what it
                // holds. The limit is at least one byte, so `EndOfStream`
                // here means the window is drained *and* the frame is done:
                // every byte the frame decodes must have been served by then.
                var tmp: [4 * 1024]u8 = undefined;
                var fw: Io.Writer = .fixed(&tmp);
                const n = @min(left, rangeAtMost(smith, 1, tmp.len));
                if (r.reader.stream(&fw, .limited(n))) |served| {
                    try testing.expectEqualSlices(
                        u8,
                        expected[pos..][0..served],
                        fw.buffered()[0..served],
                    );
                    pos += served;
                    if (served == 0) {
                        stalls += 1;
                        if (stalls > 8) return error.PumpStalled;
                    }
                } else |err| switch (err) {
                    error.EndOfStream => {
                        try testing.expectEqual(expected.len, pos);
                        break;
                    },
                    else => |e| {
                        try expectContiguityStop(&r, e);
                        dead = true;
                        break;
                    },
                }
            },
            .poll => {
                // A zero-length request: the interface's own poll. Mid-frame
                // it is a zero-byte serve; on a done reader it reports
                // `EndOfStream`. The vtable answers it without filling, so
                // nothing is lost either way.
                if (smith.boolWeighted(3, 1)) continue;
                var sink: Io.Writer.Discarding = .init(&.{});
                if (r.reader.stream(&sink.writer, .limited(0))) |served| {
                    try testing.expectEqual(@as(usize, 0), served);
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    else => |e| {
                        try expectContiguityStop(&r, e);
                        dead = true;
                        break;
                    },
                }
            },
            .over_cap_take => {
                const n = windowTailLen() + 1 + rangeAtMost(smith, 0, windowTailLen() - 1);
                if (left <= n) continue;
                if (r.reader.take(n)) |served| {
                    try testing.expectEqualSlices(u8, expected[pos..][0..n], served);
                    pos += n;
                } else |err| {
                    // Past what the window can hold at the consumer's
                    // position: fail closed, stickily, with the contiguity
                    // detail.
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                }
            },
            .over_end_peek => {
                // A peek past the contiguity cap with no `left` guard: at
                // the frame's tail it must run the trailer step before
                // reporting the clean end (the M3 closing review's blocker:
                // a clean `EndOfStream` always means the trailer was
                // verified). The unserved decoded bytes stay in the window;
                // the epilogue drains them.
                const n = windowTailLen() + 1 + rangeAtMost(smith, 0, windowTailLen() - 1);
                if (r.reader.peek(n)) |served| {
                    try testing.expect(n <= left);
                    try testing.expectEqualSlices(u8, expected[pos..][0..n], served);
                } else |err| switch (err) {
                    error.EndOfStream => {
                        // The frame ended through the trailer funnel: the
                        // clean end is real — no detail, the state done, the
                        // input stopped exactly at the frame's last byte
                        // (the plain reader), every unserved decoded byte
                        // still in the window.
                        try testing.expectEqual(@as(?Reader.Error, null), r.err);
                        try testing.expectEqual(internal.reader.State.done, r.state);
                        if (!chunked) try testing.expectEqual(unit.end, fixed_in.seek);
                        try testing.expectEqual(left, r.reader.end - r.reader.seek);
                        try expectTrailerConsistent(
                            framed[0..unit.end],
                            unit.end,
                            expected,
                            unit.checksum,
                        );
                        break;
                    },
                    else => |e| {
                        try expectContiguityStop(&r, e);
                        dead = true;
                        break;
                    },
                }
            },
            .over_buffer_peek => {
                // A peek of nearly the whole buffer: the std fill routes a
                // request past `buffer.len - seek` through the codec's
                // `rebase`, whose trailer branch must run the trailer step
                // (the B1 shape) rather than pass the frame's end through.
                const n = bufferLen() - rangeAtMost(smith, 0, windowTailLen());
                if (r.reader.peek(n)) |served| {
                    try testing.expect(n <= left);
                    try testing.expectEqualSlices(u8, expected[pos..][0..n], served);
                } else |err| switch (err) {
                    error.EndOfStream => {
                        try testing.expectEqual(@as(?Reader.Error, null), r.err);
                        try testing.expectEqual(internal.reader.State.done, r.state);
                        if (!chunked) try testing.expectEqual(unit.end, fixed_in.seek);
                        try testing.expectEqual(left, r.reader.end - r.reader.seek);
                        try expectTrailerConsistent(
                            framed[0..unit.end],
                            unit.end,
                            expected,
                            unit.checksum,
                        );
                        break;
                    },
                    else => |e| {
                        try expectContiguityStop(&r, e);
                        dead = true;
                        break;
                    },
                }
            },
        }
    }
    if (dead) return; // the sticky failure was asserted where it happened

    // Finish whatever the op budget left: `discardAll` takes any size (it is
    // not a contiguous request), so the clean end always runs.
    if (pos < expected.len) {
        r.reader.discardAll(expected.len - pos) catch |err| {
            try expectContiguityStop(&r, err);
            return;
        };
    }

    // The clean end is sticky, and the input stopped exactly at the unit's
    // last byte (the markers are the caller's). The `Limited` input may have
    // buffered ahead, so the exact position is only pinned on the plain
    // fixed reader.
    try testing.expectEqual(@as(?Reader.Error, null), r.err);
    try expectStickyEnd(&r);
    if (!chunked) try testing.expectEqual(unit.end, fixed_in.seek);
}

/// An op record: the op and its one parameter, the 16-byte serialized unit
/// every op in the loop consumes.
const OpRecord = struct { op: ReadOp, param: u64 };

/// A reader-machinery seed: the row, the chunked flag, then one record per op.
fn opSeed(
    comptime row: []const u8,
    comptime chunked: bool,
    comptime records: []const OpRecord,
) [16 + 16 * records.len]u8 {
    var seed: [16 + 16 * records.len]u8 = undefined;
    mem.writeInt(u64, seed[0..8], rowIndex(row), .little);
    mem.writeInt(u64, seed[8..16], @intFromBool(chunked), .little);
    for (records, 0..) |record, index| {
        mem.writeInt(u64, seed[16 + 16 * index ..][0..8], @intFromEnum(record.op), .little);
        mem.writeInt(u64, seed[16 + 16 * index + 8 ..][0..8], record.param, .little);
    }
    return seed;
}

const reader_corpus: []const []const u8 = &.{
    // The tail pin: one byte consumed, then the whole-buffer peek, which the
    // std fill routes through the codec's `rebase` (the B1 shape).
    &opSeed("frame_checksum", false, &.{
        .{ .op = .take, .param = 0 },
        .{ .op = .over_buffer_peek, .param = 0 },
    }),
    &opSeed("frame_checksum_off", false, &.{
        .{ .op = .take, .param = 0 },
        .{ .op = .over_buffer_peek, .param = 0 },
    }),
    // The over-the-end peek through the fill path.
    &opSeed("frame_checksum", false, &.{
        .{ .op = .take, .param = 0 },
        .{ .op = .over_end_peek, .param = 0 },
    }),
    // A chunked input at the 4-byte minimum over a compressed fixture.
    &opSeed("frame_t1", true, &.{
        .{ .op = .peek, .param = 0 },
        .{ .op = .take, .param = 0 },
        .{ .op = .read_slice_all, .param = 0 },
        .{ .op = .discard_all, .param = 0 },
    }),
    // The long fixture: over-cap takes, a stream, and the poll.
    &opSeed("frame_window_128k", false, &.{
        .{ .op = .take, .param = 0 },
        .{ .op = .over_cap_take, .param = 0 },
        .{ .op = .stream_fixed, .param = 0 },
        .{ .op = .poll, .param = 0 },
        .{ .op = .discard_all, .param = 0 },
    }),
    &opSeed("frame_checksum_multi", false, &.{
        .{ .op = .peek, .param = 0 },
        .{ .op = .stream_fixed, .param = 0 },
        .{ .op = .over_cap_take, .param = 0 },
    }),
    &opSeed("skippable_prefix", false, &.{
        .{ .op = .take, .param = 0 },
        .{ .op = .poll, .param = 0 },
    }),
    // The all-skippable run: no frame unit to carry the boundary — the clean
    // end is the end of the skippable walk (the first budget run's crash
    // input, seeded).
    &opSeed("skippable_sixteen", false, &.{}),
};

test "zstd fuzz: reader machinery" {
    try testing.fuzz({}, fuzzReaderMachinery, .{ .corpus = reader_corpus });
}

// ---------------------------------------------------------------------------
// Target 4: checksum accounting
// ---------------------------------------------------------------------------

const checksum_rows = [_]Row{
    .{
        .desc = "frame_checksum",
        .source = &golden.frame_checksum,
        .output = .{ .static = "abcd" },
    },
    .{
        .desc = "frame_checksum_empty",
        .source = &golden.frame_checksum_empty,
        .output = .{ .static = "" },
    },
    .{
        .desc = "frame_checksum_multi",
        .source = &golden.frame_checksum_multi,
        .output = .{ .repeat = .{ .text = golden.frame_checksum_multi_text, .count = 3000 } },
    },
    // The flag-off control: the same frame with no trailer to verify.
    .{
        .desc = "frame_checksum_off",
        .source = &golden.frame_checksum_off,
        .output = .{ .static = "abcd" },
    },
};

fn checksumIndex(comptime desc: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000);
        for (checksum_rows, 0..) |row, index| {
            if (mem.eql(u8, row.desc, desc)) return index;
        }
        @compileError("no checksum row named " ++ desc);
    }
}

/// Target 4: the XXH64 fold through the one funnel.
///
/// The wire trailer is the C library's own XXH64 value (`§3.1.1`; the CLI
/// wrote it and `zstd -t` verifies it), so comparing it against std's
/// `XxHash64` over the decoded bytes is the differential pin the codec's own
/// tests run — the reader's clean end proves its per-block fold
/// (`frame.State.recordBlock`) agreed with the same reference over the same
/// bytes, in order, across blocks. A corrupted trailer byte must fail
/// `WrongChecksum` on both paths, stickily, with the decoded output's cap
/// held.
fn fuzzChecksumAccounting(_: void, smith: *Smith) anyerror!void {
    const row = checksum_rows[smith.index(checksum_rows.len)];
    var expected_buf: [out_max]u8 = undefined;
    const expected = materialize(row.output, &expected_buf);
    const info = analyze(row.source).?;
    const trailer_at = info.trailer_at orelse {
        // The flag-off control: no trailer, so the frame is the whole story.
        try testing.expect(!info.header.checksum);
        var window: [out_max + guard_len]u8 = undefined;
        sentinel.fill(&window);
        const n = try decode.decompress(row.source, window[0..expected.len]);
        try testing.expectEqual(expected.len, n);
        try testing.expectEqualSlices(u8, expected, window[0..n]);
        try sentinel.expect(&window, n);
        return;
    };

    // The reference: the wire trailer against std's one-shot hash.
    try testing.expectEqual(
        @as(u32, @truncate(XxHash64.hash(0, expected))),
        readInt(u32, row.source[trailer_at..][0..frame.checksum_len]),
    );

    // The one-shot: identity, the trailer consistent, the sentinel clean.
    var window: [out_max + guard_len]u8 = undefined;
    sentinel.fill(&window);
    const n = try decode.decompress(row.source, window[0..expected.len]);
    try testing.expectEqual(expected.len, n);
    try testing.expectEqualSlices(u8, expected, window[0..n]);
    try sentinel.expect(&window, n);

    // The reader: the same bytes, the clean end's fold against the reference.
    try expectReaderIdentity(unitOf(row.source), row.source, expected);

    // A corrupted trailer byte fails closed on both paths.
    var corrupted: [source_max]u8 = undefined;
    fastmem.copy(u8, corrupted[0..row.source.len], row.source);
    const at = trailer_at + rangeAtMost(smith, 0, frame.checksum_len - 1);
    corrupted[at] ^= flipValue(smith);
    const bad = corrupted[0..row.source.len];
    var bad_window: [out_max + guard_len]u8 = undefined;
    sentinel.fill(&bad_window);
    try testing.expectError(
        error.WrongChecksum,
        decode.decompress(bad, bad_window[0..expected.len]),
    );
    try sentinel.expect(&bad_window, expected.len);

    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(bad);
    var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf);
    const pumped = try pumpCapped(&r.reader, &fw, pumpLimit(expected.len));
    try testing.expectEqual(Stop.read_failed, pumped.stop);
    try testing.expectEqual(Reader.Error.WrongChecksum, r.err.?);
    try expectStickyFailure(&r);
}

fn checksumSeed(comptime desc: []const u8, comptime param: u64) [16]u8 {
    var seed: [16]u8 = undefined;
    mem.writeInt(u64, seed[0..8], checksumIndex(desc), .little);
    mem.writeInt(u64, seed[8..16], param, .little);
    return seed;
}

const checksum_corpus: []const []const u8 = &.{
    &checksumSeed("frame_checksum", 0),
    &checksumSeed("frame_checksum_empty", 0),
    &checksumSeed("frame_checksum_multi", 0),
    &checksumSeed("frame_checksum_off", 0),
    &checksumSeed("frame_checksum", 1),
    &checksumSeed("frame_checksum_multi", 2),
};

test "zstd fuzz: checksum accounting" {
    try testing.fuzz({}, fuzzChecksumAccounting, .{ .corpus = checksum_corpus });
}

// ---------------------------------------------------------------------------
// Target 5: the amplification limits
// ---------------------------------------------------------------------------

/// A bomb row: the frame's full decoded output when it completes, or the
/// failure it pins and the bytes written before it.
const BombRow = struct {
    desc: []const u8,
    source: []const u8,
    output: ?Output,
    fail: ?struct {
        err: decode.DecompressError,
        /// The bytes the decode wrote before the error.
        written: usize,
        /// The smallest cap at which the pinned error (rather than the cap
        /// itself) fires: below it the failing declaration does not fit and
        /// `BufferTooSmall` is the refusal. Measured, not guessed.
        min_cap: usize,
    },
};

/// The bombs: small members whose declared sizes are orders of magnitude past
/// their bytes. The ratio is asserted for the rows that decode.
const bomb_rows = [_]BombRow{
    // §3.1.1.2.2 — an RLE block: 131072 bytes from a 10-byte frame.
    .{
        .desc = "frame_rle_max",
        .source = &golden.frame_rle_max,
        .output = .{ .splat = .{ .byte = 0x5a, .count = 131072 } },
        .fail = null,
    },
    // A 28-byte frame decoding 262147 bytes: two RLE blocks then a match at
    // exactly Window_Size (§3.1.1.4).
    .{
        .desc = "frame_window_128k",
        .source = &golden.frame_window_128k,
        .output = .{ .two_runs = .{
            .first_byte = 'A',
            .first_count = 131072,
            .second_byte = 'B',
            .second_count = 131072,
            .tail = "BBB",
        } },
        .fail = null,
    },
    // The CLI's own multi-block checksummed frame: 135000 bytes from 82.
    .{
        .desc = "frame_checksum_multi",
        .source = &golden.frame_checksum_multi,
        .output = .{ .repeat = .{ .text = golden.frame_checksum_multi_text, .count = 3000 } },
        .fail = null,
    },
    // §3.1.1.2.4 — a declared 1026-byte match over a 16-byte history: past
    // Block_Maximum_Size, refused before the second block's write.
    .{
        .desc = "frame_amplify_match",
        .source = &golden.frame_amplify_match,
        .output = null,
        .fail = .{ .err = error.BlockOversize, .written = 16, .min_cap = 1040 },
    },
    // §3.1.1.3.1.3 — an RLE literals section regenerating 4096 from one byte
    // in a 1 KB window: the declared size is refused, nothing written.
    .{
        .desc = "frame_oversize_literals",
        .source = &golden.frame_oversize_literals,
        .output = null,
        .fail = .{ .err = error.LiteralsTooLarge, .written = 0, .min_cap = 0 },
    },
    // §3.1.1.2.4 + §3.1.1.1.2 — a Raw block of 131073 in a 512-KiB window:
    // Block_Maximum_Size is the bound.
    .{
        .desc = "frame_oversize_raw",
        .source = &golden.frame_oversize_raw,
        .output = null,
        .fail = .{ .err = error.BlockOversize, .written = 0, .min_cap = 0 },
    },
    // The window/block coupling (T7): an RLE block of 1025 in a 1 KB window.
    .{
        .desc = "frame_oversize_rle",
        .source = &golden.frame_oversize_rle,
        .output = null,
        .fail = .{ .err = error.BlockOversize, .written = 0, .min_cap = 0 },
    },
    // T7's single-segment form: FCS 4 carrying a 5-byte block.
    .{
        .desc = "frame_single_segment_oversize",
        .source = &golden.frame_single_segment_oversize,
        .output = null,
        .fail = .{ .err = error.BlockOversize, .written = 0, .min_cap = 0 },
    },
    // T14 — FCS 2^64-1 against a 4-byte block: a declaration, never a size.
    .{
        .desc = "frame_fcs_max",
        .source = &golden.frame_fcs_max,
        .output = null,
        .fail = .{ .err = error.ContentSizeMismatch, .written = 4, .min_cap = 4 },
    },
    // §3.1.2 — 4 GiB of declared User_Data with three bytes present: skipped
    // by arithmetic, never staged.
    .{
        .desc = "skippable_huge",
        .source = &golden.skippable_huge,
        .output = null,
        .fail = .{ .err = error.Truncated, .written = 0, .min_cap = 0 },
    },
};

fn bombIndex(comptime desc: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000);
        for (bomb_rows, 0..) |row, index| {
            if (mem.eql(u8, row.desc, desc)) return index;
        }
        @compileError("no bomb row named " ++ desc);
    }
}

/// Target 5: the amplification caps.
///
/// Attacks the declared-size rules the README states ("Amplification
/// limits"): `target` is a cap, never a promise — every declared size is a
/// bound the decode fails closed on before the write that would pass the cap
/// (`BufferTooSmall`), and no declaration sizes anything. A bomb-shaped frame
/// is decoded into caps below its decoded length (including zero and
/// `len - 1`), at the exact length, and with slack, with the sentinel proving
/// the cap held; the failure rows pin their error and written floor under
/// every cap, including a cap smaller than the floor (where the cap itself is
/// the refusal). The bomb ratio is asserted where the shape pins it: the
/// member is a small fraction of the bytes it decodes to.
fn fuzzAmplification(_: void, smith: *Smith) anyerror!void {
    const row = bomb_rows[smith.index(bomb_rows.len)];
    const shape = rangeAtMost(smith, 0, 3);
    var window: [out_max + guard_len]u8 = undefined;

    if (row.output) |output| {
        var expected_buf: [out_max]u8 = undefined;
        const expected = materialize(output, &expected_buf);
        // The bomb property: the frame's bytes are a small fraction of its
        // output (an amplification a cap that ignored the decoded length
        // would turn into a real overrun).
        try testing.expect(row.source.len * 8 <= expected.len);

        var caps: [3]usize = .{ 0, expected.len, out_max };
        switch (shape) {
            0 => caps[0] = 0,
            1 => caps[0] = expected.len / 2,
            2 => caps[0] = expected.len - 1,
            else => caps[0] = rangeAtMost(smith, 0, expected.len - 1),
        }
        for (caps) |cap| {
            sentinel.fill(&window);
            if (cap < expected.len) {
                try testing.expectError(
                    error.BufferTooSmall,
                    decode.decompress(row.source, window[0..cap]),
                );
                try sentinel.expect(&window, cap);
            } else {
                const n = try decode.decompress(row.source, window[0..cap]);
                try testing.expectEqual(expected.len, n);
                try testing.expectEqualSlices(u8, expected, window[0..n]);
                try sentinel.expect(&window, n);
            }
        }
        return;
    }

    const fail = row.fail.?;
    const caps = [_]usize{ 0, fail.min_cap, out_max };
    for (caps) |cap| {
        sentinel.fill(&window);
        if (cap < fail.min_cap) {
            // The declared size the failing block needs first is past the
            // cap: the cap is the refusal, before any write.
            try testing.expectError(
                error.BufferTooSmall,
                decode.decompress(row.source, window[0..cap]),
            );
            try sentinel.expect(&window, cap);
        } else {
            try testing.expectError(fail.err, decode.decompress(row.source, window[0..cap]));
            try sentinel.expect(&window, @min(cap, fail.written));
        }
    }
}

fn bombSeed(comptime desc: []const u8, comptime shape: u64) [16]u8 {
    var seed: [16]u8 = undefined;
    mem.writeInt(u64, seed[0..8], bombIndex(desc), .little);
    mem.writeInt(u64, seed[8..16], shape, .little);
    return seed;
}

const amplification_corpus: []const []const u8 = &.{
    &bombSeed("frame_rle_max", 0),
    &bombSeed("frame_window_128k", 1),
    &bombSeed("frame_checksum_multi", 2),
    &bombSeed("frame_amplify_match", 0),
    &bombSeed("frame_oversize_literals", 1),
    &bombSeed("frame_oversize_raw", 2),
    &bombSeed("frame_oversize_rle", 3),
    &bombSeed("frame_single_segment_oversize", 0),
    &bombSeed("frame_fcs_max", 1),
    &bombSeed("skippable_huge", 2),
};

test "zstd fuzz: amplification caps" {
    try testing.fuzz({}, fuzzAmplification, .{ .corpus = amplification_corpus });
}

// ---------------------------------------------------------------------------
// Contract pins: the deterministic targets `just test` gates too
// ---------------------------------------------------------------------------

test "zstd fuzz: the corpus decodes to its models" {
    // Every row's expected bytes, through the one-shot at the exact cap and
    // with slack: a wrong table entry fails here rather than inside a budget
    // run, and every row's structure analyzes (the mutations' model).
    for (rows) |row| {
        const unit = unitOf(row.source);
        var expected_buf: [out_max]u8 = undefined;
        const expected = materialize(row.output, &expected_buf);
        var window: [out_max + guard_len]u8 = undefined;
        sentinel.fill(&window);
        const n = try decode.decompress(row.source, window[0..expected.len]);
        try testing.expectEqual(expected.len, n);
        try testing.expectEqualSlices(u8, expected, window[0..n]);
        try sentinel.expect(&window, n);
        sentinel.fill(&window);
        const m = try decode.decompress(row.source, &window);
        try testing.expectEqual(n, m);
        try testing.expectEqualSlices(u8, expected, window[0..m]);
        try sentinel.expect(&window, m);
        // The unit's boundary is inside the source, and a frame-carrying
        // unit's structure round-trips through the walk model.
        try testing.expect(unit.end <= row.source.len);
        if (unit.frame) |info| try testing.expect(info.end == unit.end);
    }
}

test "zstd fuzz: the bad-frame corpus pins its errors and floors" {
    for (bad_rows) |row| {
        var window: [out_max + guard_len]u8 = undefined;
        sentinel.fill(&window);
        try testing.expectError(row.err, decode.decompress(row.source, window[0..out_max]));
        try sentinel.expect(&window, row.written);
    }
}

test "zstd fuzz: the reader's 4-byte input precondition" {
    // README, "Streaming": the reader's input must buffer at least 4 bytes —
    // the frame layer's largest fixed-size read — or end before then. A
    // `Limited` at exactly four bytes decodes the checksummed frame
    // byte-exact; the read is what the precondition exists for.
    var chunk_buf: [4]u8 = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_checksum);
    var limited: Io.Reader.Limited = .init(&fixed_in, .unlimited, &chunk_buf);
    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var r: Reader = .init(fixture_window_len, &limited.interface, &rbuf);
    try pump(&r.reader, &fw, pumpLimit(4));
    try testing.expectEqualSlices(u8, "abcd", got[0..fw.end]);
    try testing.expectEqual(@as(?Reader.Error, null), r.err);
    try testing.expectEqual(internal.reader.State.done, r.state);
    try testing.expectEqual(golden.frame_checksum.len, fixed_in.seek);
    try expectStickyEnd(&r);
}

test "zstd fuzz: the codec's rebase runs the trailer step at the frame's tail" {
    // The M3 B1 shape (README, "Streaming": "the regression tests drive the
    // over-the-end shapes on good and corrupted trailers, and the fuzz lane
    // carries the unbounded-request op"). Consume one byte, then ask for the
    // whole buffer: the std fill routes the request through the codec's
    // `rebase`, whose trailer branch must read and verify the trailer before
    // reporting the clean end — and must fail `WrongChecksum` when the
    // trailer is corrupt.
    const buffer_len = bufferLen();
    {
        var fixed_in: Io.Reader = .fixed(&golden.frame_checksum);
        var rbuf: Reader.Buffer(fixture_window_len) = undefined;
        var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf);
        const first = try r.reader.take(1);
        try testing.expectEqual(@as(u8, 'a'), first[0]);
        try testing.expectError(error.EndOfStream, r.reader.peek(buffer_len));
        try testing.expectEqual(@as(?Reader.Error, null), r.err);
        try testing.expectEqual(internal.reader.State.done, r.state);
        try testing.expectEqual(golden.frame_checksum.len, fixed_in.seek);
    }
    {
        // The same shape over the corrupted trailer: the check must run and
        // refuse, not pass the end through.
        var fixed_in: Io.Reader = .fixed(&golden.frame_checksum_corrupt);
        var rbuf: Reader.Buffer(fixture_window_len) = undefined;
        var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf);
        _ = try r.reader.take(1);
        try testing.expectError(error.ReadFailed, r.reader.peek(buffer_len));
        try testing.expectEqual(Reader.Error.WrongChecksum, r.err.?);
        try expectStickyFailure(&r);
    }
    {
        // The fill path at the same tail: an over-cap peek from a fresh
        // reader decodes to the frame's end and reports the clean end only
        // after the trailer was verified (the frame is checksummed).
        var fixed_in: Io.Reader = .fixed(&golden.frame_checksum);
        var rbuf: Reader.Buffer(fixture_window_len) = undefined;
        var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf);
        try testing.expectError(error.EndOfStream, r.reader.peek(windowTailLen() + 1));
        try testing.expectEqual(@as(?Reader.Error, null), r.err);
        try testing.expectEqual(internal.reader.State.done, r.state);
        try testing.expectEqual(golden.frame_checksum.len, fixed_in.seek);
    }
}

test "zstd fuzz: the checksum reference pins the empty and multi-block frames" {
    // §3.1.1 — the empty payload's XXH64: std's canonical check value
    // (`zstd-notes.md` §3), and the trailer the C library wrote for it.
    try testing.expectEqual(
        @as(u64, 0xEF46_DB37_51D8_E999),
        XxHash64.hash(0, ""),
    );
    const empty_info = analyze(&golden.frame_checksum_empty).?;
    try testing.expectEqual(
        @as(u32, 0x51D8_E999),
        readInt(u32, golden.frame_checksum_empty[empty_info.trailer_at.?..][0..frame.checksum_len]),
    );
    // The multi-block frame's trailer is over all 135000 bytes in order.
    const multi_info = analyze(&golden.frame_checksum_multi).?;
    const multi_expected = golden.frame_checksum_multi_text ** 3000;
    try testing.expectEqual(
        @as(u32, @truncate(XxHash64.hash(0, multi_expected))),
        readInt(
            u32,
            golden.frame_checksum_multi[multi_info.trailer_at.?..][0..frame.checksum_len],
        ),
    );
}

test "zstd fuzz: the T9 exceed-only table corner" {
    // docs/research/zstd-notes.md §4 T9: the FSE distribution's symbol-count
    // rule is the reference's exceed-only reading — a distribution that
    // spends its budget before the context's last symbol is legal (the
    // reference encoder emits them), while a description that runs past its
    // context is corruption. The golden descriptions are the reference
    // encoder's own bytes.
    const weights = try fse.readDescription(golden.weights_description[1..], 255, 6);
    try testing.expectEqual(@as(u16, 9), weights.symbol_count);
    try testing.expectEqual(@as(u5, 5), weights.accuracy_log);
    const literals_lengths = try fse.readDescription(&golden.literals_length_description, 35, 9);
    try testing.expectEqual(@as(u16, 34), literals_lengths.symbol_count);
    // The same description against a context that ends at symbol 2: the
    // distribution covers 9 symbols, so it must be refused, not truncated.
    try testing.expectError(
        error.MalformedFseTable,
        fse.readDescription(golden.weights_description[1..], 2, 6),
    );
    // The budget-exactness half: a description cut inside its fields cannot
    // land on the table size.
    try testing.expectError(
        error.MalformedFseTable,
        fse.readDescription(golden.weights_description[1..4], 255, 6),
    );
}

test "zstd fuzz: the RLE staging-order divergence is recorded" {
    // A finding of the corruption lane, pinned: an RLE block whose declared
    // Block_Size is past Block_Maximum_Size with its content byte missing.
    // The one-shot's declared-size check fires first (`BlockOversize`,
    // `§3.1.1.2.4`); the reader stages the content first and reports the
    // input's end (`Truncated`). Both fail closed — the divergence is the
    // name alone, and it is allowed, named, in `checkReader`'s agreement
    // check. If the reader's declared-size check moves ahead of its staging
    // read, this pin flips to `BlockOversize` and that allowance can go.
    const source = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x48, 0xfb, 0xff, 0xff };
    var target: [1024]u8 = undefined;
    sentinel.fill(&target);
    try testing.expectError(error.BlockOversize, decode.decompress(&source, &target));
    try sentinel.expect(&target, 0);

    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(&source);
    var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf);
    var got: [1024]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    const pumped = try pumpCapped(&r.reader, &fw, 64);
    try testing.expectEqual(Stop.read_failed, pumped.stop);
    try testing.expectEqual(Reader.Error.Truncated, r.err.?);
    try expectStickyFailure(&r);
}
