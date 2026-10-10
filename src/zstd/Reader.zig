//! zstd.Reader: a decompressing `Io.Reader` over one Zstandard frame
//! (README.md, "Streaming").
//!
//! One frame per reader, with the exact boundary visible: the reader consumes
//! `input` through the frame's last byte — the Content_Checksum trailer's
//! last byte when the flag is set, the last block's last byte otherwise
//! (`§3.1.1`) — and stops there, so the input's position at the clean end is
//! the next frame unit's first byte. Multi-frame is `Reader.streamAll`'s walk
//! at that boundary (the gzip member walk, `src/gzip/README.md`, "The
//! wrapping design"): the walk resumes there until a unit is not present (the
//! file's clean end, zero frames served), and garbage in a unit's place fails
//! `BadMagic` — fail closed at interpretation, never silently skipped.
//! Skippable frames (`§3.1.2`) are consumed and ignored in every layer — all
//! 16 magics, before a frame and between frames — and their User_Data is
//! skipped by streaming through the input, never staged: a 4 GiB Frame_Size
//! costs the walk and no memory (the gzip XLEN rule).
//!
//! The machinery is the pattern book's (`src/internal/README.md`, "The Io
//! codec pattern book"): the generated vtable quartet, the fill-and-return-0
//! contract, the zero-length poll, the sticky lifecycle (`State` + the detail
//! in `err`), the contiguity failure, and the wrapper-rebase funnel. What
//! this module adds is the framing.
//!
//! ## The buffer is the cap
//!
//! `Reader.Buffer(window_len)` is `[window_len + max_block_size]u8`: the
//! retained history — "all offsets leading to previously decoded data must be
//! smaller than Window_Size" (`§3.1.1.4`), capped by the caller — plus the
//! largest decoded block (`§3.1.1.2.4`'s Block_Maximum_Size ≤ 128 KB).
//! `init` takes the exact pointer to it and derives the authorized window
//! from the buffer's type, so the cap and the buffer cannot disagree; a frame
//! declaring a larger Window_Size fails `WindowTooLarge` before any block
//! byte (`§3.1.1.1.2`: "a decoder is allowed to reject a compressed frame
//! that requests a memory size beyond the decoder's authorized range"), never
//! a silent truncation. The serving region slides forward as it fills,
//! keeping the consumer's unconsumed bytes and the retained history: any
//! contiguous request (the `peek`/`take` family) of at most Block_Maximum_Size
//! — 128 KiB — is served, and a request beyond what the window can hold at
//! the consumer's position fails closed with `error.ReadFailed`
//! (`err == .StreamTooLong`), never an assert.
//!
//! Zero allocation, end to end: the caller owns the window buffer, the block
//! staging and the literals scratch are comptime-sized stack locals (up to
//! ~256 KiB per compressed block, README, "Stack"), and no allocator appears
//! anywhere in this API.
//!
//! ## The frame state machine
//!
//! `phase` is the resume point across pump calls, and each phase drives one
//! step of the frame layer's composition hand-off (`frame.zig`, "The
//! composition, and what the streaming reader drives"):
//!
//! - `.start` / `.magic`: the 4-byte Magic_Number (`§3.1`), classified by
//!   `frame.classify`; a skippable magic leads to `.skip`. The input's end
//!   before the *first* unit is `Truncated` (no frame unit began, T10); after
//!   a skippable unit it is the clean end — a stream of only skippable frames
//!   decodes to zero bytes (T10, the CLI's own verified behavior).
//! - `.header`: the Frame_Header fed to `frame.HeaderParser` (`§3.1.1.1`),
//!   which consumes as much as its current field needs — so the 2-14 byte
//!   header parses across fills even when the input buffers only the magic's
//!   four bytes — then `frame.checkWindow` against the buffer's window.
//! - `.blocks`: one block per iteration — the 3-byte Block_Header off the
//!   input (`block.parseHeader`), the Block_Content staged (the backwards
//!   bitstreams need the block's end first), `block.decodeContent` with the
//!   *retained* count of frame output in the serving region (the frame total
//!   and the serving region are different numbers), and `State.recordBlock` —
//!   the one funnel — with exactly the bytes the block wrote (OQ7: every
//!   decoded byte hashed once, in order, no second pass).
//! - `.trailer`: the frame end — `State.checkContentSize` and the XXH64
//!   Content_Checksum trailer, read and verified exactly once (`§3.1.1`,
//!   T8) — reached from the pump and from `rebase`, the M3 B1 shape
//!   (`src/internal/README.md`, "A wrapper's rebase routes the inner end
//!   through the same ending as fill"): an over-the-end peek or record
//!   request at a frame's tail must read and verify the trailer before the
//!   reader reports its clean end, never pass the frame's end through with
//!   the trailer unread.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;
const print = std.debug.print;

const fastmem = @import("fastmem");

const block = @import("block.zig");
const common = @import("common.zig");
const frame = @import("frame.zig");
const golden = @import("golden.zig");
const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const State = internal.reader.State;
const VTable = internal.reader.VTable;

/// The caller-owned window buffer (`§3.1.1.1.2`): `window_len` bytes of
/// retained history plus the largest decoded block (`§3.1.1.2.4`'s
/// Block_Maximum_Size ≤ 128 KB). The buffer *is* the cap: `init` takes the
/// exact pointer to it and derives the authorized window from its type, so
/// the two cannot disagree (README, "Streaming").
pub fn Buffer(comptime window_len: usize) type {
    return [window_len + block.max_block_size]u8;
}

/// `§3.1.1.1.2` — "It is recommended to support Window_Size up to 8 MB": the
/// default cap, and the pin from the CLI's level-19 frames (`windowLog` 23).
pub const default_window_len: usize = 8 * 1024 * 1024;

/// `Reader.Buffer(default_window_len)` — 8 MiB + 128 KiB.
pub const DefaultBuffer = Buffer(default_window_len);

/// The detailed error recorded once `state == .failed` (README, "API"):
/// `frame.Error` — the one-shot's `DecompressError`, name for name — minus
/// `BufferTooSmall` (the window is the caller's buffer, not a target cap, so
/// no decode can outgrow it), plus this layer's own names. The interface
/// reports the coarse `error.ReadFailed`/`error.EndOfStream`; the detail
/// lives beside it in `err`.
pub const Error = error{
    BadMagic,
    ReservedBitSet,
    DictionaryRequired,
    BlockOversize,
    ReservedBlock,
    MalformedLiteralsHeader,
    LiteralsTooLarge,
    TreelessLiteralsFirst,
    MalformedHuffmanWeights,
    MalformedFseTable,
    MalformedSequencesHeader,
    RepeatModeFirst,
    ReservedModeBits,
    MissingStartBit,
    InvalidBitStream,
    BitstreamNotConsumed,
    ZeroOffset,
    OffsetTooFar,
    ContentSizeMismatch,
    WrongChecksum,
    Truncated,
    /// `§3.1.1.1.2` — the frame's Window_Size exceeds the buffer's window
    /// (the caller's "authorized range"): fail closed, never truncate.
    WindowTooLarge,
    /// The serving region cannot hold a contiguous request at the consumer's
    /// position: fail closed, never assert (the pattern book's contiguity
    /// rule).
    StreamTooLong,
    /// The interface's coarse pair (`src/internal/README.md`, "Sticky
    /// lifecycle"): the detail is recorded in `err`.
    ReadFailed,
    EndOfStream,
};

comptime {
    // The set is the frame layer's, minus `BufferTooSmall`, plus the four
    // names this layer adds: a frame-layer error the reader forgot, or one it
    // invented, fails the build here (the `decode.zig` vocabulary check, one
    // layer up).
    @setEvalBranchQuota(100_000);
    const own = [_][]const u8{ "WindowTooLarge", "StreamTooLong", "ReadFailed", "EndOfStream" };
    const frame_set = @typeInfo(frame.Error).error_set.?;
    const mine = @typeInfo(Error).error_set.?;
    assert(mine.len == frame_set.len - 1 + own.len);
    for (frame_set) |want| {
        var found = false;
        for (mine) |entry| {
            if (mem.eql(u8, entry.name, want.name)) found = true;
        }
        // `BufferTooSmall` is the one name the reader does not carry: its
        // window is the caller's buffer, and every output path is bounded by
        // the room the block phase guarantees.
        assert(found == !mem.eql(u8, want.name, "BufferTooSmall"));
    }
    for (own) |name| {
        var found = false;
        for (mine) |entry| {
            if (mem.eql(u8, entry.name, name)) found = true;
        }
        assert(found);
    }
}

/// The frame's phase: the resume point across pump calls.
const Phase = union(enum) {
    /// The first frame unit's Magic_Number. The input's end here is
    /// `Truncated`: no frame unit began (T10 — the zero-byte input; the gzip
    /// decision mapped over).
    start,
    /// A skippable frame's User_Data (`§3.1.2`): `left` bytes still to skip,
    /// then the next unit's magic.
    skip: usize,
    /// The next frame unit's Magic_Number, after a skippable frame was
    /// consumed. The input's end here is the clean end: a stream of only
    /// skippable frames decodes to zero bytes (T10).
    magic,
    /// The Frame_Header (`§3.1.1.1`), fed to the byte-fed parser.
    header,
    /// The block chain (`§3.1.1.2`).
    blocks,
    /// The last block has landed; the frame end — Frame_Content_Size and the
    /// Content_Checksum trailer (`§3.1.1.1.4`, `§3.1.1`) — is next.
    trailer,
};

const Reader = @This();

reader: Io.Reader,
/// The frame's input: the magic, the block headers, the staged Block_Content,
/// and the trailer are read from it, at the frame's exact positions. Its
/// buffer must hold the frame layer's largest fixed-size read — four bytes
/// (the magic, the skippable Frame_Size, the trailer; the 3-byte Block_Header
/// fits inside) — or the input must end before then (README, "Streaming";
/// std's decoder names the same class `InputBufferUndersize`).
input: *Io.Reader,
/// The authorized window: the buffer's type less the block room, derived
/// once at `init`.
window_len: usize,
/// The Frame_Header parse (`§3.1.1.1`), run across fills.
header: frame.HeaderParser = .{},
/// One frame's cross-block decode state (`frame.State`): the parsed header,
/// the two entropy layers' tables, the frame's decoded length, and the XXH64
/// fold. Present once the header is parsed.
frame_state: ?frame.State = null,
phase: Phase = .start,
/// The stream lifecycle (`src/internal/reader.zig`): `streaming` until the
/// frame's trailer is verified (`done`) or a failure sticks (`failed`,
/// details in `err`).
state: State = .streaming,
/// Detailed error once `state == .failed`; the interface reports
/// `error.ReadFailed`.
err: ?Error = null,

/// The generated `Io.Reader` entries (the pattern book): the sticky guard,
/// the zero-length poll, and the fill-and-return-0 count are structural.
/// `pump` is the frame's fill; `rebase` owns the window's capacity policy.
const vtable = VTable(Reader, pump, rebase).vtable;

/// Wrap `input` (one Zstandard frame, skippable frames allowed before it)
/// with `buffer` as the decoded window: the exact pointer to a
/// `Buffer(window_len)`, the comptime parameter and the buffer's type
/// agreeing at the call site — the compiler is the check, so the window cap
/// and the buffer cannot disagree (README, "Streaming"; AGENTS.md, "Rules").
/// Consume through `&r.reader` (`stream`, `read`-family, `peek`-family); the
/// frame ends cleanly with `error.EndOfStream` once the trailer is verified
/// and fails closed with `error.ReadFailed` (sticky, details in `err`) on
/// any malformed frame or input failure. The reader consumes `input` exactly
/// through the frame's last byte; bytes after it are left unconsumed
/// (README, "Streaming").
pub fn init(comptime window_len: usize, input: *Io.Reader, buffer: *Buffer(window_len)) Reader {
    return .{
        .reader = .{
            .buffer = buffer,
            .seek = 0,
            .end = 0,
            .vtable = &vtable,
        },
        .input = input,
        .window_len = window_len,
    };
}

/// Stream one complete frame unit from `in` through a `Reader` over `buffer`
/// into `out`, returning the decoded bytes served. Leading skippable frames
/// are consumed and ignored (`§3.1.2`); the unit is consumed exactly through
/// the frame's last byte — the trailer's when the flag is set — and bytes
/// after it are left unconsumed (README, "Streaming"). A zero-byte input is
/// a failure: no frame unit began. The pump reports the coarse
/// `error.ReadFailed`; a caller who needs a failure's detail drives a
/// `Reader` directly. Zero allocation: the window is the caller's buffer.
pub fn streamFrame(
    comptime window_len: usize,
    in: *Io.Reader,
    out: *Io.Writer,
    buffer: *Buffer(window_len),
) Io.Reader.StreamRemainingError!usize {
    var rr: Reader = .init(window_len, in, buffer);
    return rr.reader.streamRemaining(out);
}

/// Stream every frame unit `in` holds into `out`, returning the total decoded
/// bytes served. `§3.1` — "The output of the decompression is the
/// concatenation of all the frames": the walk is `streamFrame`'s semantics
/// per unit, at the boundary it leaves (one unit per iteration; a unit that
/// is not present is the file's clean end, zero frames served). A stream of
/// only skippable frames is the clean end with zero bytes served, the
/// zero-byte input the clean end with zero frames served, and garbage where a
/// unit should start fails `BadMagic` (T10). The pump reports the coarse
/// `error.ReadFailed`; a caller who needs a failure's detail drives a
/// `Reader` directly. Zero allocation: the window is the caller's buffer.
pub fn streamAll(
    comptime window_len: usize,
    in: *Io.Reader,
    out: *Io.Writer,
    buffer: *Buffer(window_len),
) Io.Reader.StreamRemainingError!usize {
    var rr: Reader = undefined;
    var served: usize = 0;
    while (true) {
        // A clean end between units is the file's end; any byte where a unit
        // should start is parsed as one, so garbage fails closed.
        _ = in.peekByte() catch |err| switch (err) {
            error.EndOfStream => return served,
            else => |e| return e,
        };
        rr = .init(window_len, in, buffer);
        served += try rr.reader.streamRemaining(out);
    }
}

/// The generated entries' fill: the frame's detailed errors through `record`
/// (the pattern book's funnel), so the interface sees `error.ReadFailed` with
/// the detail sticky in `err`, or the clean `error.EndOfStream` once the
/// trailer is verified.
fn pump(r: *Reader) Io.Reader.Error!usize {
    return r.record(r.fillFrame());
}

/// The one place a detailed failure becomes the interface's coarse error.
fn record(r: *Reader, result: Error!usize) Io.Reader.Error!usize {
    return result catch |err| switch (err) {
        error.EndOfStream => {
            r.state = .done;
            return error.EndOfStream;
        },
        else => return r.fail(err),
    };
}

/// Fail closed, stickily: the detail is recorded beside the state and the
/// interface's coarse `error.ReadFailed` is returned. The serving region's
/// unconsumed bytes are dropped — no partial output is trusted past the
/// error (README, "Corruption"; the flate reader's rule).
fn fail(r: *Reader, err: Error) Io.Reader.Error {
    r.reader.seek = r.reader.end;
    return internal.reader.fail(Error, &r.state, &r.err, err);
}

/// One frame fill: the unit's magic, header, and blocks into the serving
/// region, until the frame's output is complete (the frame end is next, run
/// by the following fill or by `rebase`) or the region cannot take another
/// block. Returns the bytes added — never zero without an error, unless the
/// frame's output is complete.
fn fillFrame(r: *Reader) Error!usize {
    var added: usize = 0;
    while (r.state == .streaming) {
        switch (r.phase) {
            .start => {
                // The input ended before any frame unit began: `Truncated`
                // (T10 — the zero-byte input; the gzip decision mapped over).
                const kind = (try r.readMagic()) orelse return error.Truncated;
                try r.beginUnit(kind);
            },
            .magic => {
                // A stream of only skippable frames: the clean end with zero
                // bytes served (T10, `§3.1.2`).
                const kind = (try r.readMagic()) orelse return error.EndOfStream;
                try r.beginUnit(kind);
            },
            .skip => |left| {
                try r.skipUserData(left);
                r.phase = .magic;
            },
            .header => try r.readHeader(),
            .blocks => {
                // Room for the next block's output: the frame's
                // Block_Maximum_Size (`§3.1.1.2.4`). A full serving region
                // slides — the consumer's unconsumed bytes and the retained
                // history stay, the rest is dropped — and a slide that cannot
                // make room is the contiguity cap: fail closed, never an
                // assert (the pattern book's rule).
                const room_needed = r.blockRoom();
                if (r.reader.buffer.len - r.reader.end < room_needed) {
                    const room = r.slide();
                    if (room < room_needed) {
                        if (added == 0) return error.StreamTooLong;
                        return added;
                    }
                }
                added += try r.decodeBlock();
                // The block chain is complete. The frame end — the
                // Frame_Content_Size check and the checksum trailer — is
                // next; it runs when the consumer next needs bytes, or from
                // `rebase` for an over-the-end request at the frame's tail
                // (the B1 shape). Returning the block's bytes now keeps the
                // boundary honest: the trailer is read exactly once, by the
                // first call that finds nothing more to add.
                if (r.phase == .trailer) return added;
            },
            .trailer => try r.endFrame(),
        }
    }
    if (added == 0) return error.EndOfStream;
    return added;
}

/// The next frame unit's Magic_Number (`§3.1`, `§3.1.2`): its kind, or null
/// when the input ends at a unit boundary (an empty remainder — the caller
/// decides what that means). Fewer than four bytes left is the input's end
/// inside a unit: `Truncated`.
fn readMagic(r: *Reader) Error!?frame.Kind {
    r.input.fill(frame.magic_len) catch |err| switch (err) {
        error.EndOfStream => {
            if (r.input.seek == r.input.end) return null;
            return error.Truncated;
        },
        error.ReadFailed => return error.ReadFailed,
    };
    const bytes = r.input.buffer[r.input.seek..][0..frame.magic_len];
    const kind = frame.classify(bytes) catch |err| {
        // The four bytes are buffered: the classifier cannot see a short
        // slice, so `BadMagic` is the only failure left.
        assert(err == error.BadMagic);
        return error.BadMagic;
    };
    r.input.toss(frame.magic_len);
    return kind;
}

/// Start the frame unit whose Magic_Number was just read: a Zstandard frame's
/// Frame_Header is next; a skippable frame's Frame_Size — "the size, in
/// bytes, of the following User_Data (without including the magic number nor
/// the size field itself)" (`§3.1.2`) — is read, and its User_Data is next.
fn beginUnit(r: *Reader, kind: frame.Kind) Error!void {
    switch (kind) {
        .zstandard => r.phase = .header,
        .skippable => {
            const bytes = try r.readFixed(frame.frame_size_len);
            r.phase = .{ .skip = @intCast(common.readInt(u32, &bytes)) };
        },
    }
}

/// The Frame_Header (`§3.1.1.1`, Table 2), fed to the byte-fed parser: it
/// consumes as much as its current field needs, so a reader whose input
/// buffers only the magic's four bytes parses the 2-14 byte header across
/// fills. The input's end inside it is `Truncated`; the parser's own
/// refusals (the reserved bit, a Dictionary_ID) land where the frame layer
/// raises them. Once done, the header is checked against the buffer's window
/// (OQ1) and the block chain begins.
fn readHeader(r: *Reader) Error!void {
    while (!r.header.done()) {
        r.input.fill(1) catch |err| switch (err) {
            error.EndOfStream => return error.Truncated,
            error.ReadFailed => return error.ReadFailed,
        };
        const buffered = r.input.buffer[r.input.seek..r.input.end];
        const consumed = r.header.feed(buffered) catch |err| switch (err) {
            // The parser raises the header's own refusals — the reserved bit,
            // a Dictionary_ID — and nothing else; a block-layer name cannot
            // come out of a header feed, and the reader's error set does not
            // carry `BufferTooSmall` (README, "API"). Fail closed rather
            // than turn a broken invariant into undefined behavior.
            error.BufferTooSmall => {
                assert(false);
                return error.Truncated;
            },
            else => |e| return e,
        };
        // `feed` consumes at least one byte while the header is incomplete,
        // so the loop always progresses (or fails).
        assert(consumed > 0);
        r.input.toss(consumed);
    }
    const header = r.header.header();
    // §3.1.1.1.2 — "a decoder is allowed to reject a compressed frame that
    // requests a memory size beyond the decoder's authorized range": the
    // caller's buffer is the authorization, checked once, before any block
    // byte is read (OQ1).
    try frame.checkWindow(header, r.window_len);
    r.frame_state = .init(header);
    r.phase = .blocks;
}

/// Skip a skippable frame's User_Data (`§3.1.2`): the bytes are skipped by
/// streaming through the input, never staged, so a 4 GiB Frame_Size costs the
/// walk and no memory (the gzip XLEN rule). The input's end inside the
/// User_Data is `Truncated`.
fn skipUserData(r: *Reader, count: usize) Error!void {
    var left = count;
    while (left > 0) {
        if (r.input.seek == r.input.end) {
            r.input.fill(1) catch |err| switch (err) {
                error.EndOfStream => return error.Truncated,
                error.ReadFailed => return error.ReadFailed,
            };
        }
        const take = @min(r.input.end - r.input.seek, left);
        r.input.toss(take);
        left -= take;
    }
}

/// Decode one block (`§3.1.1.2`): the 3-byte Block_Header off the input, the
/// Block_Content staged (both backwards bitstreams read from the block's end
/// toward its beginning, so the whole block is staged first — `§3.1.1.3.2.1.2`
/// "it is necessary to know the offset of the last byte"), then
/// `block.decodeContent` with the *retained* count of frame output in the
/// serving region, and `State.recordBlock` — the one funnel — with exactly
/// the bytes the block wrote. Returns the bytes written; moves the phase to
/// `.trailer` when the block is the frame's last (`§3.1.1.2.1`).
fn decodeBlock(r: *Reader) Error!usize {
    const header_bytes = try r.readFixed(block.block_header_len);
    const header = block.parseHeader(&header_bytes) catch |err| {
        // The three bytes are buffered: the parser cannot see a short slice.
        assert(err == error.Truncated);
        return error.Truncated;
    };
    // §3.1.1.2.2 — block type 3, Reserved: "This is not a block. ... a
    // compliant decoder must reject it." No Block_Content is read.
    if (header.block_type == .reserved) return error.ReservedBlock;
    // §3.1.1.2.4 — Block_Maximum_Size bounds "both the decompressed size and
    // the compressed size of any block in the frame": the check that lets the
    // staging scratch be comptime-sized. An RLE block's one content byte
    // passes it here; its Block_Size (the repeat count) is checked by
    // `decodeContent`.
    const content_len = block.contentLength(header);
    if (content_len > r.blockRoom()) return error.BlockOversize;
    var scratch: [block.max_block_size]u8 = undefined;
    try r.readExact(scratch[0..content_len]);
    // The block phase implies the header was parsed: the frame's state is
    // the one this block decodes through.
    assert(r.frame_state != null);
    const state = &r.frame_state.?;
    const retained_len = r.reader.end;
    const written = block.decodeContent(
        header,
        scratch[0..content_len],
        r.reader.buffer,
        retained_len,
        state.header.window_size,
        &state.literals,
        &state.sequences,
    ) catch |err| switch (err) {
        // The block phase guarantees the serving region's room — it slides
        // until Block_Maximum_Size is free (`§3.1.1.2.4`) — so no decode can
        // outgrow it, which is why the reader's error set does not carry
        // this name (README, "API"). The failure is structurally
        // impossible: report it loudly where assertions are live, and fail
        // closed rather than trust it where they are not.
        error.BufferTooSmall => {
            assert(false);
            return error.BlockOversize;
        },
        else => |e| return e,
    };
    // The one funnel (OQ7): exactly the bytes this block wrote, in order,
    // folded into the checksum and the frame's running total.
    try state.recordBlock(r.reader.buffer[retained_len..][0..written]);
    r.reader.end += written;
    if (header.last_block) r.phase = .trailer;
    return written;
}

/// The frame end, one place (`§3.1.1.1.4`, `§3.1.1`): Frame_Content_Size
/// against the frame's decoded total — "It's allowed to represent a small
/// size (for example, 18) using any compatible variant", so the declaration
/// is a check on the decode, never a sizing hint — then the Content_Checksum
/// trailer, read and verified exactly once, advancing the input through the
/// frame's last byte. Reached from `fill` (the block chain is complete and
/// the consumer needs bytes) and from `rebase` (an over-the-end request at
/// the frame's tail), the M3 B1 shape (`src/internal/README.md`, "A
/// wrapper's rebase routes the inner end through the same ending as fill").
fn endFrame(r: *Reader) Error!void {
    assert(r.state == .streaming);
    assert(r.phase == .trailer);
    assert(r.frame_state != null);
    const state = &r.frame_state.?;
    try state.checkContentSize();
    if (state.header.checksum) {
        const trailer = try r.readFixed(frame.checksum_len);
        try state.verifyTrailer(&trailer);
    }
    r.state = .done;
}

/// The frame layer's fixed-size reads (`§3.1.1`, `§3.1.2`, `§3.1.1.2`): the
/// next `n` bytes of `input`, consumed — one `fill(n)`, so the input must
/// buffer `n` bytes (the frame layer's largest fixed-size read is four: the
/// magic, the skippable Frame_Size, the trailer; the 3-byte Block_Header fits
/// inside it) or end before them. Fewer bytes left is `Truncated`.
fn readFixed(r: *Reader, comptime n: usize) Error![n]u8 {
    r.input.fill(n) catch |err| switch (err) {
        error.EndOfStream => return error.Truncated,
        error.ReadFailed => return error.ReadFailed,
    };
    const bytes = r.input.buffer[r.input.seek..][0..n].*;
    r.input.toss(n);
    return bytes;
}

/// Read exactly `target.len` bytes from `input` into `target`, one input
/// buffer's worth at a time: the input's buffer may be as small as the
/// frame layer's four bytes, so a block's content is staged in chunks, never
/// with a single `fill(content_len)` (which would assert on a smaller input
/// buffer). A short input is `Truncated`.
fn readExact(r: *Reader, target: []u8) Error!void {
    var taken: usize = 0;
    while (taken < target.len) {
        if (r.input.seek == r.input.end) {
            r.input.fill(1) catch |err| switch (err) {
                error.EndOfStream => return error.Truncated,
                error.ReadFailed => return error.ReadFailed,
            };
        }
        const buffered = r.input.buffer[r.input.seek..r.input.end];
        const take = @min(buffered.len, target.len - taken);
        fastmem.copy(u8, target[taken..][0..take], buffered[0..take]);
        r.input.toss(take);
        taken += take;
    }
}

/// The room one block's output needs in the serving region: the frame's
/// Block_Maximum_Size — "the smallest of: Window_Size, 128 KB"
/// (`§3.1.1.2.4`). The block phase guarantees it, which is why the decode's
/// own `BufferTooSmall` can never fire here.
fn blockRoom(r: *const Reader) usize {
    assert(r.frame_state != null);
    const state = &r.frame_state.?;
    return @intCast(@min(state.header.window_size, @as(u64, block.max_block_size)));
}

/// The history the window retains: the frame's Window_Size, capped by the
/// caller's window (`checkWindow` enforced the cap) — `§3.1.1.4`'s "all
/// offsets leading to previously decoded data must be smaller than
/// Window_Size" is the match reach, so retaining that much is enough. Before
/// a frame is parsed nothing is buffered; the authorized window is the bound.
fn historyLength(r: *const Reader) usize {
    // Before a frame is parsed nothing is buffered, so the window itself is
    // the bound; `rebase` can run at that phase.
    const state = &(r.frame_state orelse return r.window_len);
    return @intCast(@min(state.header.window_size, @as(u64, r.window_len)));
}

/// Slide the serving region forward: keep the consumer's unconsumed bytes and
/// the retained history (`§3.1.1.4`'s window), drop the rest. Returns the free
/// room afterwards, which is at least Block_Maximum_Size once the history is
/// within the window — the guaranteed contiguous request (README,
/// "Streaming").
fn slide(r: *Reader) usize {
    const seek = r.reader.seek;
    const end = r.reader.end;
    const unconsumed = end - seek;
    const keep = @max(unconsumed, @min(end, r.historyLength()));
    fastmem.move(u8, r.reader.buffer[0..keep], r.reader.buffer[end - keep ..][0..keep]);
    r.reader.seek = keep - unconsumed;
    r.reader.end = keep;
    return r.reader.buffer.len - keep;
}

/// The generated entries' rebase hook: make room for `capacity` more
/// contiguous bytes by sliding the window, with the consumer's position kept.
/// A request the window cannot hold at the consumer's position fails closed —
/// unless the frame is at its tail, where the request is answered by the
/// frame end instead: the trailer step runs (once), and only then the clean
/// end is reported. An over-the-end request must never pass the frame's end
/// through with the trailer unread (the pattern book's B1 entry; the
/// regression tests drive both the good and the corrupted trailer).
fn rebase(r: *Reader, capacity: usize) Io.Reader.RebaseError!void {
    _ = r.slide();
    if (r.reader.buffer.len - r.reader.seek >= capacity) return;
    if (r.phase == .trailer) {
        r.endFrame() catch |err| return r.fail(err);
        return error.EndOfStream;
    }
    return r.fail(error.StreamTooLong);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1 (frames), §3.1.1
// (the frame and its checksum), §3.1.1.1 (the header), §3.1.1.2 (the block
// chain), §3.1.1.4 (offsets and the window), §3.1.2 (skippable frames). The
// fixtures are `golden.zig`'s, each verified with the pinned zstd v1.5.7.
// Every decode is sentinel-checked: the target is pre-filled and the bytes
// past the served length must be untouched.
// ---------------------------------------------------------------------------

/// The fixtures' window: their standard Frame_Header_Descriptor declares a
/// 512-KiB window (`§3.1.1.1.2`), so one buffer covers every fixture whose
/// frame declares at most that.
const fixture_buffer_len = 512 * 1024;

/// Decode `source` through a fresh reader into `target` (sentinel-filled),
/// returning the served length and leaving the reader in `r`. The shape the
/// streaming decode tests run.
fn decodeInto(r: *Reader, target: []u8) !usize {
    sentinel.fill(target);
    var w: Io.Writer = .fixed(target);
    const served = try r.reader.streamRemaining(&w);
    try testing.expectEqual(@as(?Error, null), r.err);
    return served;
}

/// One good fixture through the streaming layer: the bytes, and the output
/// the one-shot decoder's tests expect.
const Case = struct {
    desc: []const u8,
    source: []const u8,
    expected: []const u8,
};

const stream_cases = [_]Case{
    .{ .desc = "frame_raw", .source = &golden.frame_raw, .expected = "zstd raw" },
    .{ .desc = "frame_raw_empty", .source = &golden.frame_raw_empty, .expected = "" },
    .{ .desc = "frame_rle", .source = &golden.frame_rle, .expected = "AAAAAAAAAA" },
    .{ .desc = "frame_multi", .source = &golden.frame_multi, .expected = "abcdefghIIIIII" },
    .{ .desc = "frame_t1", .source = &golden.frame_t1, .expected = &golden.t1_literals },
    .{
        .desc = "frame_t1_errata",
        .source = &golden.frame_t1_errata,
        .expected = &golden.t1_errata_literals,
    },
    .{
        .desc = "frame_treeless",
        .source = &golden.frame_treeless,
        .expected = &[_]u8{ 0, 1, 4, 5, 0, 0, 0, 0, 0 },
    },
    .{
        .desc = "frame_repeat",
        .source = &golden.frame_repeat,
        .expected = &golden.frame_repeat_expected,
    },
    .{
        .desc = "frame_temp_offset",
        .source = &golden.frame_temp_offset,
        .expected = &golden.frame_temp_offset_expected,
    },
    .{
        .desc = "frame_corner",
        .source = &golden.frame_corner,
        .expected = &golden.frame_corner_expected,
    },
    .{
        .desc = "frame_two_byte",
        .source = &golden.frame_two_byte,
        .expected = &golden.frame_two_byte_expected,
    },
    .{
        .desc = "frame_zero_seq",
        .source = &golden.frame_zero_seq,
        .expected = &golden.frame_zero_seq_expected,
    },
    .{
        .desc = "frame_zero_seq_2b",
        .source = &golden.frame_zero_seq_2b,
        .expected = &golden.frame_zero_seq_expected,
    },
    .{
        .desc = "frame_sequences_predefined",
        .source = &golden.frame_sequences_predefined,
        .expected = &golden.sequences_predefined_expected,
    },
    .{
        .desc = "frame_sequences_rle_match_lengths",
        .source = &golden.frame_sequences_rle_match_lengths,
        .expected = &golden.sequences_rle_match_lengths_expected,
    },
    .{
        .desc = "frame_sequences_fse_offsets",
        .source = &golden.frame_sequences_fse_offsets,
        .expected = &golden.sequences_fse_offsets_expected,
    },
    .{
        .desc = "frame_sequences_fse_all",
        .source = &golden.frame_sequences_fse_all,
        .expected = &golden.sequences_fse_all_expected,
    },
    .{
        .desc = "frame_literals_1stream",
        .source = &golden.frame_literals_1stream,
        .expected = &golden.literals_1stream_expected,
    },
    .{
        .desc = "frame_literals_4stream_sf1",
        .source = &golden.frame_literals_4stream_sf1,
        .expected = &golden.literals_4stream_sf1_expected,
    },
    .{
        .desc = "frame_literals_4stream_sf2",
        .source = &golden.frame_literals_4stream_sf2,
        .expected = &golden.literals_4stream_sf2_expected,
    },
    .{
        .desc = "frame_literals_fse_tree",
        .source = &golden.frame_literals_fse_tree,
        .expected = &golden.literals_fse_tree_expected,
    },
    .{ .desc = "frame_fcs1", .source = &golden.frame_fcs1, .expected = "01234567" },
    .{ .desc = "frame_fcs4", .source = &golden.frame_fcs4, .expected = "01234567" },
    .{ .desc = "frame_fcs8", .source = &golden.frame_fcs8, .expected = "01234567" },
    .{ .desc = "frame_unused_bit", .source = &golden.frame_unused_bit, .expected = "abcd" },
    .{ .desc = "frame_checksum", .source = &golden.frame_checksum, .expected = "abcd" },
    .{ .desc = "frame_checksum_empty", .source = &golden.frame_checksum_empty, .expected = "" },
    .{ .desc = "frame_checksum_off", .source = &golden.frame_checksum_off, .expected = "abcd" },
};

test "Reader: the buffer type is the documented window plus a block" {
    // RFC 8878 §3.1.1.1.2 — "It is recommended to support Window_Size up to
    // 8 MB": the default window is 8 MiB, and the buffer is the window plus
    // Block_Maximum_Size (§3.1.1.2.4 — "128 KB").
    try testing.expectEqual(@as(usize, 8 * 1024 * 1024), default_window_len);
    try testing.expectEqual(@as(usize, 128 * 1024), block.max_block_size);
    try testing.expectEqual(@as(usize, 8 * 1024 * 1024 + 128 * 1024), @sizeOf(DefaultBuffer));
    try testing.expectEqual(@as(usize, 1024 + 128 * 1024), @sizeOf(Buffer(1024)));
    try testing.expectEqual(@as(usize, 1152 + 128 * 1024), @sizeOf(Buffer(1152)));
}

test "Reader: the error set mirrors DecompressError minus BufferTooSmall" {
    // README, "API" — `err`'s type is the `DecompressError` set minus
    // `BufferTooSmall` (the window is the caller's buffer, not a target cap),
    // plus the interface's `ReadFailed`/`EndOfStream` and this layer's
    // `WindowTooLarge`/`StreamTooLong`.
    const mine = @typeInfo(Error).error_set.?;
    for (@typeInfo(frame.Error).error_set.?) |want| {
        if (mem.eql(u8, want.name, "BufferTooSmall")) continue;
        var found = false;
        for (mine) |entry| {
            if (mem.eql(u8, entry.name, want.name)) found = true;
        }
        try testing.expect(found);
    }
    var has_buffer_too_small = false;
    for (mine) |entry| {
        if (mem.eql(u8, entry.name, "BufferTooSmall")) has_buffer_too_small = true;
    }
    try testing.expect(!has_buffer_too_small);
}

test "Reader: the landed fixtures decode through the streaming layer" {
    // The same fixtures the one-shot decoder is judged against, through the
    // streaming interface: each decodes to the golden output and consumes
    // exactly its own bytes (`§3.1.1` — the frame ends at the last block's
    // last byte, or at the trailer's when the flag is set).
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var target: [300 * 1024]u8 = undefined;
    for (stream_cases) |tc| {
        var fixed_in: Io.Reader = .fixed(tc.source);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf);
        const n = decodeInto(&r, &target) catch |err| {
            print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
        try testing.expectEqual(tc.expected.len, n);
        try testing.expectEqualSlices(u8, tc.expected, target[0..n]);
        try sentinel.expect(&target, n);
        try testing.expectEqual(tc.source.len, fixed_in.seek);
        try testing.expectEqual(State.done, r.state);
    }

    // The CLI's own multi-block, checksummed, single-segment frame: 135000
    // bytes over two Compressed_Blocks with the XXH64 trailer (`§3.1.1`).
    const expected = golden.frame_checksum_multi_text ** 3000;
    var big_in: Io.Reader = .fixed(&golden.frame_checksum_multi);
    var big: Reader = .init(fixture_buffer_len, &big_in, &rbuf);
    const n = try decodeInto(&big, &target);
    try testing.expectEqual(expected.len, n);
    try testing.expectEqualSlices(u8, expected, target[0..n]);
    try sentinel.expect(&target, n);
    try testing.expectEqual(golden.frame_checksum_multi.len, big_in.seek);
    try testing.expectEqual(State.done, big.state);
}

test "Reader: the negative corners fail closed with the detail in err" {
    // The frame layer's negative corners through the streaming layer: every
    // one is `error.ReadFailed` with the specific detail beside it, and
    // sticky. `written` is what the frame serves before the failure: the
    // frame-end checks — Frame_Content_Size and the checksum trailer — land
    // after the frame's output is complete (`§3.1.1.1.4`, `§3.1.1`), so a
    // frame whose declared size is short or whose trailer is corrupt still
    // serves its bytes before the failure (the one-shot's tests pin the same
    // counts). Every other corner fails before or inside the pump call that
    // would serve, and the reader drops what it buffered — no partial output
    // is trusted past the error (the flate reader's rule) — so the sentinel
    // past `written` holds.
    const CaseNeg = struct { desc: []const u8, source: []const u8, want: Error, written: usize };
    const cases = [_]CaseNeg{
        // §3.1.1.1.1.4 — descriptor bit 3.
        .{
            .desc = "frame_reserved_bit",
            .source = &golden.frame_reserved_bit,
            .want = error.ReservedBitSet,
            .written = 0,
        },
        // §3.1.1.1.3 — Dictionary_ID_Flag set.
        .{
            .desc = "frame_dictionary_id",
            .source = &golden.frame_dictionary_id,
            .want = error.DictionaryRequired,
            .written = 0,
        },
        .{
            .desc = "frame_dictionary_id_wide",
            .source = &golden.frame_dictionary_id_wide,
            .want = error.DictionaryRequired,
            .written = 0,
        },
        .{
            .desc = "frame_dictionary_id_truncated",
            .source = &golden.frame_dictionary_id_truncated,
            .want = error.Truncated,
            .written = 0,
        },
        // §3.1.1.2.4 — Block_Maximum_Size, and §3.1.1.2.2 — the reserved type.
        .{
            .desc = "frame_reserved",
            .source = &golden.frame_reserved,
            .want = error.ReservedBlock,
            .written = 0,
        },
        .{
            .desc = "frame_oversize_raw",
            .source = &golden.frame_oversize_raw,
            .want = error.BlockOversize,
            .written = 0,
        },
        .{
            .desc = "frame_oversize_rle",
            .source = &golden.frame_oversize_rle,
            .want = error.BlockOversize,
            .written = 0,
        },
        .{
            .desc = "frame_single_segment_oversize",
            .source = &golden.frame_single_segment_oversize,
            .want = error.BlockOversize,
            .written = 0,
        },
        .{
            .desc = "frame_amplify_match",
            .source = &golden.frame_amplify_match,
            .want = error.BlockOversize,
            .written = 0,
        },
        .{
            .desc = "frame_oversize_literals",
            .source = &golden.frame_oversize_literals,
            .want = error.LiteralsTooLarge,
            .written = 0,
        },
        // §3.1.1.3.1.1 / §3.1.1.3.2.1 — the first-block entropy corners.
        .{
            .desc = "frame_treeless_first",
            .source = &golden.frame_treeless_first,
            .want = error.TreelessLiteralsFirst,
            .written = 0,
        },
        .{
            .desc = "frame_repeat_first",
            .source = &golden.frame_repeat_first,
            .want = error.RepeatModeFirst,
            .written = 0,
        },
        .{
            .desc = "frame_empty_compressed",
            .source = &golden.frame_empty_compressed,
            .want = error.MalformedLiteralsHeader,
            .written = 0,
        },
        .{
            .desc = "frame_no_sequences",
            .source = &golden.frame_no_sequences,
            .want = error.MalformedSequencesHeader,
            .written = 0,
        },
        // §3.1.1.2 — the input's end inside the frame.
        .{
            .desc = "frame_short_raw",
            .source = &golden.frame_short_raw,
            .want = error.Truncated,
            .written = 0,
        },
        .{
            .desc = "frame_short_compressed",
            .source = &golden.frame_short_compressed,
            .want = error.Truncated,
            .written = 0,
        },
        .{
            .desc = "frame_truncated_header",
            .source = &golden.frame_truncated_header,
            .want = error.Truncated,
            .written = 0,
        },
        .{
            .desc = "frame_checksum_truncated",
            .source = &golden.frame_checksum_truncated,
            .want = error.Truncated,
            .written = 4,
        },
        // §3.1.1.1.4 — Frame_Content_Size against the decode.
        .{
            .desc = "frame_fcs_short",
            .source = &golden.frame_fcs_short,
            .want = error.ContentSizeMismatch,
            .written = 0,
        },
        .{
            .desc = "frame_fcs_long",
            .source = &golden.frame_fcs_long,
            .want = error.ContentSizeMismatch,
            .written = 8,
        },
        .{
            .desc = "frame_fcs_max",
            .source = &golden.frame_fcs_max,
            .want = error.ContentSizeMismatch,
            .written = 4,
        },
        // §3.1.1.4 — the declared window bound (T12).
        .{
            .desc = "frame_window_1k_over",
            .source = &golden.frame_window_1k_over,
            .want = error.OffsetTooFar,
            .written = 0,
        },
        // §3.1.1 — the XXH64 trailer (T8).
        .{
            .desc = "frame_checksum_corrupt",
            .source = &golden.frame_checksum_corrupt,
            .want = error.WrongChecksum,
            .written = 4,
        },
        // §3.1 / §3.1.2 — the magic, and the skippable frame's own corners.
        .{
            .desc = "frame_bad_magic",
            .source = &golden.frame_bad_magic,
            .want = error.BadMagic,
            .written = 0,
        },
        .{
            .desc = "skippable_bad_magic",
            .source = &golden.skippable_bad_magic,
            .want = error.BadMagic,
            .written = 0,
        },
        .{
            .desc = "skippable_truncated",
            .source = &golden.skippable_truncated,
            .want = error.Truncated,
            .written = 0,
        },
        .{
            .desc = "skippable_huge",
            .source = &golden.skippable_huge,
            .want = error.Truncated,
            .written = 0,
        },
    };
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var target: [1024]u8 = undefined;
    for (cases) |tc| {
        var fixed_in: Io.Reader = .fixed(tc.source);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf);
        sentinel.fill(&target);
        var w: Io.Writer = .fixed(&target);
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&w));
        try testing.expectEqual(tc.want, r.err.?);
        // Exactly the bytes the frame produced before the failure were
        // served, and the bytes past them are untouched: no partial output is
        // trusted past the error, and nothing was written past what was
        // reported (the sentinel rule).
        if (w.end != tc.written) {
            print("\nFAIL ({s}): served {d}, want {d}\n", .{ tc.desc, w.end, tc.written });
            return error.TestUnexpectedResult;
        }
        try sentinel.expect(&target, w.end);
        // The failure is sticky, and the interface keeps reporting it.
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
        try testing.expectError(error.ReadFailed, r.reader.peek(1));
    }
}

test "Reader: the frame boundary is exact at the frame's last byte" {
    // README, "Streaming": the reader consumes `input` exactly through the
    // frame's last byte — the checksum trailer's last byte when the flag is
    // set (`§3.1.1`), the last block's last byte otherwise — and stops there.
    // Marker bytes behind the frame are not the reader's to consume.
    const cases = [_]struct { desc: []const u8, source: []const u8, expected: []const u8 }{
        .{ .desc = "checksummed", .source = &golden.frame_checksum, .expected = "abcd" },
        .{ .desc = "unchecksummed", .source = &golden.frame_raw, .expected = "zstd raw" },
    };
    const markers = 8;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var framed: [64 + markers]u8 = undefined;
    var target: [64]u8 = undefined;
    for (cases) |tc| {
        fastmem.copy(u8, framed[0..tc.source.len], tc.source);
        fastmem.set(u8, framed[tc.source.len..], 0xaa);
        var fixed_in: Io.Reader = .fixed(framed[0 .. tc.source.len + markers]);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf);
        const n = try decodeInto(&r, &target);
        try testing.expectEqualStrings(tc.expected, target[0..n]);
        try sentinel.expect(&target, n);
        try testing.expectEqual(tc.source.len, fixed_in.seek);
    }
}

test "Reader: a multi-frame file is a caller loop at the boundary" {
    // RFC 8878 §3.1 — frames concatenate: "The output of the decompression is
    // the concatenation of all the frames". One frame per reader, the caller
    // loops at the boundary (`streamAll` is the same walk, one call down).
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_two_frames);
    var first: Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    var second: Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    try testing.expectEqual(
        @as(usize, 8),
        try streamFrame(fixture_buffer_len, &fixed_in, &first.writer, &rbuf),
    );
    try testing.expectEqualStrings("zstd raw", first.written());
    try testing.expectEqual(@as(usize, golden.frame_raw.len), fixed_in.seek);
    try testing.expectEqual(
        @as(usize, 6),
        try streamFrame(fixture_buffer_len, &fixed_in, &second.writer, &rbuf),
    );
    try testing.expectEqualStrings("second", second.written());
    try testing.expectEqual(@as(usize, golden.frame_two_frames.len), fixed_in.seek);
}

test "Reader: streamAll walks every frame to the input's end" {
    // RFC 8878 §3.1 — the walk: every frame decoded, in order, at the exact
    // boundary, stopping at the last frame's last byte.
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_two_frames);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectEqual(
        @as(usize, 14),
        try streamAll(fixture_buffer_len, &fixed_in, &out.writer, &rbuf),
    );
    try testing.expectEqualStrings("zstd rawsecond", out.written());
    try testing.expectEqual(@as(usize, golden.frame_two_frames.len), fixed_in.seek);

    // A checksummed frame between two others: each frame's trailer verified
    // at its own boundary, the walk's total the concatenation.
    var framed: [golden.frame_raw.len * 2 + golden.frame_checksum.len]u8 = undefined;
    fastmem.copy(u8, framed[0..golden.frame_raw.len], &golden.frame_raw);
    fastmem.copy(
        u8,
        framed[golden.frame_raw.len..][0..golden.frame_checksum.len],
        &golden.frame_checksum,
    );
    fastmem.copy(
        u8,
        framed[golden.frame_raw.len + golden.frame_checksum.len ..],
        &golden.frame_raw,
    );
    var walk_in: Io.Reader = .fixed(&framed);
    var walk_out: Io.Writer.Allocating = .init(gpa);
    defer walk_out.deinit();
    try testing.expectEqual(
        @as(usize, 8 + 4 + 8),
        try streamAll(fixture_buffer_len, &walk_in, &walk_out.writer, &rbuf),
    );
    try testing.expectEqualStrings("zstd rawabcdzstd raw", walk_out.written());
    try testing.expectEqual(@as(usize, framed.len), walk_in.seek);
}

test "Reader: skippable frames are skipped in every layer" {
    // RFC 8878 §3.1.2 — "skippable frames simply need to be skipped, and
    // their content ignored, resuming decoding after the skippable frame";
    // "All 16 values are valid to identify a skippable frame". Before a
    // frame, around a frame, and in the walk.
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    // A skippable frame before the frame: consumed and ignored, and the
    // frame's own boundary is the input's end.
    {
        var fixed_in: Io.Reader = .fixed(&golden.skippable_prefix);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectEqual(
            @as(usize, 8),
            try streamFrame(fixture_buffer_len, &fixed_in, &out.writer, &rbuf),
        );
        try testing.expectEqualStrings("zstd raw", out.written());
        try testing.expectEqual(golden.skippable_prefix.len, fixed_in.seek);
    }
    // A skippable frame after the frame: one reader ends at the Zstandard
    // frame's last byte — the trailing skippable is the next unit's — and
    // the walk consumes it and reaches the clean end with zero more bytes.
    {
        var fixed_in: Io.Reader = .fixed(&golden.skippable_around);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectEqual(
            @as(usize, 8),
            try streamFrame(fixture_buffer_len, &fixed_in, &out.writer, &rbuf),
        );
        try testing.expectEqualStrings("zstd raw", out.written());
        try testing.expectEqual(@as(usize, 27), fixed_in.seek);
        try testing.expectEqual(
            @as(usize, 0),
            try streamFrame(fixture_buffer_len, &fixed_in, &out.writer, &rbuf),
        );
        try testing.expectEqual(golden.skippable_around.len, fixed_in.seek);

        var walk_in: Io.Reader = .fixed(&golden.skippable_around);
        var walk_out: Io.Writer.Allocating = .init(gpa);
        defer walk_out.deinit();
        try testing.expectEqual(
            @as(usize, 8),
            try streamAll(fixture_buffer_len, &walk_in, &walk_out.writer, &rbuf),
        );
        try testing.expectEqualStrings("zstd raw", walk_out.written());
        try testing.expectEqual(golden.skippable_around.len, walk_in.seek);
    }

    // §3.1.2 + T10 — a stream of only skippable frames is the clean end with
    // zero bytes served (the CLI decodes all sixteen to zero bytes cleanly),
    // for the walk and for a reader driven directly.
    var only_in: Io.Reader = .fixed(&golden.skippable_sixteen);
    var only_out: Io.Writer.Allocating = .init(gpa);
    defer only_out.deinit();
    try testing.expectEqual(
        @as(usize, 0),
        try streamAll(fixture_buffer_len, &only_in, &only_out.writer, &rbuf),
    );
    try testing.expectEqual(@as(usize, 0), only_out.written().len);
    try testing.expectEqual(golden.skippable_sixteen.len, only_in.seek);

    var direct_in: Io.Reader = .fixed(&golden.skippable_sixteen);
    var direct: Reader = .init(fixture_buffer_len, &direct_in, &rbuf);
    var direct_out: Io.Writer.Allocating = .init(gpa);
    defer direct_out.deinit();
    try testing.expectEqual(
        @as(usize, 0),
        try direct.reader.streamRemaining(&direct_out.writer),
    );
    try testing.expectEqual(@as(?Error, null), direct.err);
    try testing.expectEqual(State.done, direct.state);
    try testing.expectEqual(golden.skippable_sixteen.len, direct_in.seek);
}

test "Reader: the cardinality rules for the empty input" {
    // T10 — the gzip decision mapped over: a zero-byte input is `Truncated`
    // (no frame unit began — the CLI fails "unexpected end of file"), and the
    // walk's clean end (zero frames served).
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var fixed_in: Io.Reader = .fixed("");
    var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
    try testing.expectEqual(Error.Truncated, r.err.?);

    // The pump reports the coarse failure (its error set is the interface's
    // pair); the detail above is the reader's.
    var frame_in: Io.Reader = .fixed("");
    try testing.expectError(
        error.ReadFailed,
        streamFrame(fixture_buffer_len, &frame_in, &out.writer, &rbuf),
    );

    var walk_in: Io.Reader = .fixed("");
    try testing.expectEqual(
        @as(usize, 0),
        try streamAll(fixture_buffer_len, &walk_in, &out.writer, &rbuf),
    );
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

test "Reader: trailing garbage fails closed at the next unit's classify" {
    // T10 — the walk: any byte where a frame unit should start is parsed as
    // one, so trailing garbage fails `BadMagic` instead of being skipped.
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_trailing_garbage);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectError(
        error.ReadFailed,
        streamAll(fixture_buffer_len, &fixed_in, &out.writer, &rbuf),
    );
    try testing.expectEqualStrings("zstd raw", out.written());

    // The same through the manual loop: the frame decodes, the next reader
    // fails the classify.
    var loop_in: Io.Reader = .fixed(&golden.frame_trailing_garbage);
    var loop_out: Io.Writer.Allocating = .init(gpa);
    defer loop_out.deinit();
    _ = try streamFrame(fixture_buffer_len, &loop_in, &loop_out.writer, &rbuf);
    try testing.expectEqual(@as(usize, golden.frame_raw.len), loop_in.seek);
    var next: Reader = .init(fixture_buffer_len, &loop_in, &rbuf);
    try testing.expectError(error.ReadFailed, next.reader.streamRemaining(&loop_out.writer));
    try testing.expectEqual(Error.BadMagic, next.err.?);
}

test "Reader: a truncated frame is Truncated at every prefix" {
    // RFC 8878 §3.1.1 — a frame cut off anywhere (header, block, trailer) is
    // the input's end, `Truncated`, never a clean end. The checksummed
    // fixture: every strict prefix fails, the whole frame decodes.
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (1..golden.frame_checksum.len) |prefix| {
        var fixed_in: Io.Reader = .fixed(golden.frame_checksum[0..prefix]);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf);
        out.clearRetainingCapacity();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);
    }
    // The unchecksummed fixture: the prefix that ends at the last block's
    // last byte is the frame's clean end (§3.1.1 — no trailer to read).
    for (1..golden.frame_raw.len) |prefix| {
        var fixed_in: Io.Reader = .fixed(golden.frame_raw[0..prefix]);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf);
        out.clearRetainingCapacity();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);
    }
}

test "Reader: the window cap is the buffer's" {
    // RFC 8878 §3.1.1.1.2 — "a decoder is allowed to reject a compressed
    // frame that requests a memory size beyond the decoder's authorized
    // range": the caller's buffer type is the authorization (OQ1), and the
    // cap is exact. `frame_window_1152` declares 1152 bytes (1024 + 128, the
    // first window above the 1-KB minimum); `frame_window_1k` declares 1024.
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    {
        var rbuf: Buffer(1024) = undefined;
        var fixed_in: Io.Reader = .fixed(&golden.frame_window_1152);
        var r: Reader = .init(1024, &fixed_in, &rbuf);
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.WindowTooLarge, r.err.?);
        // The cap is checked once the header is parsed and before any block
        // byte: the magic and the two header bytes were consumed, no more.
        try testing.expectEqual(@as(usize, 6), fixed_in.seek);
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    }
    {
        // The same frame with a buffer whose window is exactly its
        // declaration: the cap is inclusive.
        var rbuf: Buffer(1152) = undefined;
        var fixed_in: Io.Reader = .fixed(&golden.frame_window_1152);
        var r: Reader = .init(1152, &fixed_in, &rbuf);
        try testing.expectEqual(@as(usize, 0), try r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(@as(?Error, null), r.err);
        try testing.expectEqual(golden.frame_window_1152.len, fixed_in.seek);
    }
    {
        // The minimum legal window, exactly declared.
        var rbuf: Buffer(1024) = undefined;
        var fixed_in: Io.Reader = .fixed(&golden.frame_window_1k);
        var r: Reader = .init(1024, &fixed_in, &rbuf);
        try testing.expectEqual(@as(usize, 2048 + 3), try r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(@as(?Error, null), r.err);
        try testing.expectEqual(golden.frame_window_1k.len, fixed_in.seek);
        try testing.expectEqualSlices(u8, "BBB", out.written()[2048..2051]);
    }
}

test "Reader: the window slides to serve a frame larger than the buffer" {
    // RFC 8878 §3.1.1.4 — the window is the match reach: a frame whose output
    // exceeds the buffer decodes through the slide, which keeps the retained
    // history and the consumer's unconsumed bytes. `frame_window_128k` is
    // 262147 bytes with a 128-KiB window; the buffer is exactly
    // window + Block_Maximum_Size (262144), so every slide matters. The
    // expected output is the fixture's own shape — two 131072-byte RLE
    // blocks, 'A' then 'B', and a match copying "BBB" — and the canaries
    // around the buffer prove the reader stayed inside it.
    const gpa = testing.allocator;
    const Guarded = struct {
        before: [64]u8,
        buffer: Buffer(128 * 1024),
        after: [64]u8,
    };
    const expected_len = 2 * 131072 + 3;
    const reference = try gpa.alloc(u8, expected_len);
    defer gpa.free(reference);
    fastmem.set(u8, reference[0..131072], 'A');
    fastmem.set(u8, reference[131072..][0..131072], 'B');
    fastmem.copy(u8, reference[2 * 131072 ..], "BBB");

    const served = try gpa.alloc(u8, expected_len + @as(usize, sentinel.len));
    defer gpa.free(served);
    var guarded: Guarded = undefined;
    sentinel.fill(&guarded.before);
    sentinel.fill(&guarded.after);
    var fixed_in: Io.Reader = .fixed(&golden.frame_window_128k);
    var r: Reader = .init(128 * 1024, &fixed_in, &guarded.buffer);
    const n = try decodeInto(&r, served);
    try testing.expectEqual(expected_len, n);
    try testing.expectEqualSlices(u8, reference, served[0..n]);
    try sentinel.expect(served, n);
    try testing.expectEqual(golden.frame_window_128k.len, fixed_in.seek);
    // The window is the caller's and the reader's writes stayed inside it.
    try sentinel.expect(&guarded.before, 0);
    try sentinel.expect(&guarded.after, 0);
}

test "Reader: a contiguous request past the window fails closed" {
    // README, "Streaming" — "any contiguous request of at most 128 KiB is
    // served" (the slide always frees Block_Maximum_Size, §3.1.1.2.4), and "a
    // request beyond what the window can hold at the consumer's position
    // fails closed with `error.ReadFailed` (`err == .StreamTooLong`), never
    // an assert".
    var rbuf: Buffer(128 * 1024) = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_window_128k);
    var r: Reader = .init(128 * 1024, &fixed_in, &rbuf);
    // The guaranteed floor: a whole Block_Maximum_Size of contiguous output.
    try testing.expectEqual(block.max_block_size, (try r.reader.peek(block.max_block_size)).len);
    // Drain everything the pump buffered, so only the retained history stands
    // behind the next request: one byte more than the floor cannot fit.
    try r.reader.discardAll(r.reader.end - r.reader.seek);
    try testing.expectError(error.ReadFailed, r.reader.peek(block.max_block_size + 1));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
    // The failure is sticky, and the interface keeps reporting it.
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.ReadFailed, r.reader.peek(1));
}

test "Reader: an over-the-end request still checks the trailer" {
    // The rebase path, the M3 B1 shape (`src/internal/README.md`, "A
    // wrapper's rebase routes the inner end through the same ending as
    // fill"): an over-the-end peek at a frame's tail routes through
    // `rebase`, where the frame end — `§3.1.1`'s trailer, read and verified
    // exactly once — must run before the clean end is reported, never pass
    // the frame's end through with the trailer unread. RFC 8878 §3.1.1: "the
    // result of the XXH64() hash function digesting the original (decoded)
    // data as input, and a seed of zero. The low 4 bytes of the checksum are
    // stored in little-endian format."
    //
    // `frame_checksum_multi` is 135000 bytes with a 135000-byte window
    // (single-segment), so the buffer is window + Block_Maximum_Size; the
    // take lands the frame's whole output in the buffer with the trailer
    // unread, and the over-the-end peek cannot be satisfied beside the
    // retained history.
    const take_len = 135000;
    const peek_len = 140000;

    // The good trailer: the request reports the clean end, the input stands
    // exactly at the frame's last byte, and the state is done with no error.
    {
        var rbuf: Buffer(take_len) = undefined;
        var fixed_in: Io.Reader = .fixed(&golden.frame_checksum_multi);
        var r: Reader = .init(take_len, &fixed_in, &rbuf);
        _ = try r.reader.take(take_len);
        try testing.expectError(error.EndOfStream, r.reader.peek(peek_len));
        try testing.expectEqual(golden.frame_checksum_multi.len, fixed_in.seek);
        try testing.expectEqual(State.done, r.state);
        try testing.expectEqual(@as(?Error, null), r.err);
    }

    // The corrupted trailer: the same request fails `ReadFailed` with the
    // specific error, on every trailer byte.
    for (0..frame.checksum_len) |at| {
        var bad: [golden.frame_checksum_multi.len]u8 = undefined;
        fastmem.copy(u8, &bad, &golden.frame_checksum_multi);
        bad[bad.len - frame.checksum_len + at] ^= 0x01;
        var rbuf: Buffer(take_len) = undefined;
        var fixed_in: Io.Reader = .fixed(&bad);
        var r: Reader = .init(take_len, &fixed_in, &rbuf);
        _ = try r.reader.take(take_len);
        try testing.expectError(error.ReadFailed, r.reader.peek(peek_len));
        try testing.expectEqual(Error.WrongChecksum, r.err.?);
        try testing.expectEqual(State.failed, r.state);
    }
}

test "Reader: a chunked input refills across the header and a block" {
    // README, "Streaming": "The reader's input must buffer at least 4 bytes —
    // the magic, the frame layer's largest fixed-size read (the 3-byte block
    // header and the 4-byte checksum fit inside it)". A 4-byte input buffer
    // is therefore the minimum, and the header parse, the block staging, and
    // the trailer read all run on refills. The marker bytes behind the frame
    // must never reach the decoder.
    const gpa = testing.allocator;
    const markers = 8;
    const framed = try gpa.alloc(u8, golden.frame_checksum_multi.len + markers);
    defer gpa.free(framed);
    fastmem.copy(u8, framed[0..golden.frame_checksum_multi.len], &golden.frame_checksum_multi);
    fastmem.set(u8, framed[golden.frame_checksum_multi.len..], 0xaa);

    var small: [4]u8 = undefined;
    var inner: Io.Reader = .fixed(framed);
    var chunked: Io.Reader.Limited = .init(&inner, .unlimited, &small);
    var rbuf: Buffer(135000) = undefined;
    var r: Reader = .init(135000, &chunked.interface, &rbuf);
    const out = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(out);
    try testing.expectEqual(135000, out.len);
    try testing.expectEqualStrings(golden.frame_checksum_multi_text ** 3000, out);
    try testing.expectEqual(@as(?Error, null), r.err);
    // The logical input position — the inner's position less the chunked
    // reader's still-buffered bytes — is the frame's last byte.
    const buffered = chunked.interface.end - chunked.interface.seek;
    try testing.expectEqual(golden.frame_checksum_multi.len, inner.seek - buffered);
}

test "Reader: a zero-length poll does not fail the stream" {
    // The pattern book's zero-length poll: std calls `vtable.stream` at
    // limit 0 when the buffer is nonempty, and the poll must answer 0 without
    // filling (a fill could fail `StreamTooLong` on a valid stream).
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_checksum_multi);
    var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf);
    _ = try r.reader.peek(1);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectEqual(@as(usize, 0), try r.reader.stream(&sink.writer, .limited(0)));
    try testing.expectEqual(@as(?Error, null), r.err);
    const got = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualStrings(golden.frame_checksum_multi_text ** 3000, got);
}

test "Reader: random consumer machinery sequences stay correct" {
    // Mixed peek/take/discardAll/readSliceAll/stream operations over the
    // multi-block, checksummed fixture: the driver class that catches vtable
    // machinery interactions (contiguity, slide accounting, the sticky end).
    // The frame's output is 135000 bytes over a 135000-byte window, so the
    // driver's positions exercise the slide.
    var rng: DefaultPrng = .init(4242);
    const rand = rng.random();
    const input = golden.frame_checksum_multi_text ** 3000;
    var rbuf: Buffer(135000) = undefined;

    var iter: usize = 0;
    while (iter < 8) : (iter += 1) {
        var fixed_in: Io.Reader = .fixed(&golden.frame_checksum_multi);
        var r: Reader = .init(135000, &fixed_in, &rbuf);
        var pos: usize = 0;
        while (pos < input.len) {
            const left = input.len - pos;
            switch (rand.uintLessThan(u8, 5)) {
                0 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, block.max_block_size));
                    try testing.expectEqualSlices(u8, input[pos..][0..n], try r.reader.peek(n));
                },
                1 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, block.max_block_size));
                    try testing.expectEqualSlices(u8, input[pos..][0..n], try r.reader.take(n));
                    pos += n;
                },
                2 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, input.len));
                    try r.reader.discardAll(n);
                    pos += n;
                },
                3 => {
                    var tmp: [100_000]u8 = undefined;
                    const n = @min(left, rand.intRangeAtMost(usize, 1, tmp.len));
                    try r.reader.readSliceAll(tmp[0..n]);
                    try testing.expectEqualSlices(u8, input[pos..][0..n], tmp[0..n]);
                    pos += n;
                },
                else => {
                    var tmp: [5000]u8 = undefined;
                    var fw: Io.Writer = .fixed(&tmp);
                    const n = @min(left, rand.intRangeAtMost(usize, 0, 5000));
                    _ = try r.reader.stream(&fw, .limited(n));
                    // `stream` may serve from the buffer or fill it; the
                    // bytes land in `fw` or stay buffered. Only the served
                    // count is contractual.
                    const served = @min(n, fw.end);
                    try testing.expectEqualSlices(
                        u8,
                        input[pos..][0..served],
                        fw.buffered()[0..served],
                    );
                    pos += served;
                },
            }
        }
        // The clean end of the frame is sticky.
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    }
}
