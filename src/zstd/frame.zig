//! The frame layer of a zstandard frame (`§3.1`): the Magic_Number, the
//! Frame_Header, the block chain over the landed block layer, the XXH64
//! Content_Checksum trailer, and the skippable frames that may sit around a
//! frame.
//!
//! A Zstandard frame is a 4-byte Magic_Number (0xFD2FB528, little-endian), a
//! 2-14 byte Frame_Header, one or more Data_Blocks, and an optional 4-byte
//! Content_Checksum (`§3.1.1`, Table 1). A skippable frame is a magic from
//! 0x184D2A50 to 0x184D2A5F — "All 16 values are valid to identify a
//! skippable frame" — a 4-byte little-endian Frame_Size, and that many
//! User_Data bytes, which "simply need to be skipped, and their content
//! ignored, resuming decoding after the skippable frame" (`§3.1.2`, Table
//! 19). `classify` is the one place a unit's kind is decided, so every layer
//! that meets a magic agrees: the one-shot (`decode.zig`) and the streaming
//! reader both skip skippables and fail `BadMagic` on anything else.
//!
//! ## The Frame_Header
//!
//! Table 2's field order is the descriptor, an optional Window_Descriptor, an
//! optional Dictionary_ID, and an optional Frame_Content_Size. The descriptor
//! (`§3.1.1.1.1`, Table 3, bit 7 highest):
//!
//! - bits 7-6 Frame_Content_Size_Flag: FCS_Field_Size 0-or-1 / 2 / 4 / 8
//!   (Table 4). "When Frame_Content_Size_Flag is 0, FCS_Field_Size depends on
//!   Single_Segment_Flag: if Single_Segment_Flag is set, FCS_Field_Size is
//!   1. Otherwise, FCS_Field_Size is 0; Frame_Content_Size is not provided."
//! - bit 5 Single_Segment_Flag: "In this case, Window_Descriptor byte is
//!   skipped, but Frame_Content_Size is necessarily present", and Window_Size
//!   is Frame_Content_Size itself (`§3.1.1.1.2`).
//! - bit 4 (unused): "A decoder compliant with this specification version
//!   shall not interpret this bit" (`§3.1.1.1.1.3`) — accepted with either
//!   value, never read.
//! - bit 3 (reserved): "Its value must be zero. A decoder compliant with this
//!   specification version must ensure it is not set"
//!   (`§3.1.1.1.1.4`) — `ReservedBitSet`.
//! - bit 2 Content_Checksum_Flag: the 4-byte trailer rides the frame end
//!   (`§3.1.1.1.1.5`).
//! - bits 1-0 Dictionary_ID_Flag: DID_Field_Size 0 / 1 / 2 / 4 (Table 5).
//!   A nonzero flag is `DictionaryRequired`, raised at the first
//!   Dictionary_ID byte and before any body byte (`§3.1.1.1.3`, `§5`;
//!   `docs/research/zstd-notes.md` §7 OQ4: fail closed, never skip, never
//!   misparse).
//!
//! Frame_Content_Size is little-endian, and "When FCS_Field_Size is 2, the
//! offset of 256 is added" — the 2-byte form carries 256-65791 (`§3.1.1.1.4`,
//! Table 7). "It's allowed to represent a small size (for example, 18) using
//! any compatible variant", so the size is a *check* on the decode, never a
//! sizing hint: `recordBlock` enforces it as a running bound and
//! `checkContentSize` closes it at the frame end (`§8` names the
//! smaller-than-actual FCS as an attack vector).
//!
//! Window_Size (`§3.1.1.1.2`) is `windowLog = 10 + Exponent`, `windowBase =
//! 1 << windowLog`, `windowAdd = (windowBase / 8) * Mantissa`, `Window_Size =
//! windowBase + windowAdd` — 1 KB to 3.75 TB, and the descriptor byte always
//! parses. The *cap* is the caller's: "a decoder is allowed to reject a
//! compressed frame that requests a memory size beyond the decoder's
//! authorized range", which is `checkWindow` for the streaming reader
//! (OQ1 — the caller's buffer type is the authorization). The one-shot
//! applies no cap: it materializes no window at all, its history is `target`,
//! and an offset that reaches past the decoded output is `OffsetTooFar`
//! whatever the header declared.
//!
//! ## The composition, and what the streaming reader drives
//!
//! `State` is one frame's decode state — the parsed header, the two landed
//! entropy layers' cross-block states, the frame's decoded length, and the
//! XXH64 fold — and the frame layer drives it block by block through the
//! landed `block.decode` hand-off. The one-shot's whole frame is:
//!
//! 1. `classify` the magic (`§3.1`), skipping skippable frames (`§3.1.2`);
//! 2. `parseHeader` the Frame_Header (`§3.1.1.1`);
//! 3. `State.init(header)`, then `State.decodeBlock` per block until its
//!    `last_block`;
//! 4. `State.checkContentSize` (`§3.1.1.1.4`);
//! 5. `State.verifyTrailer` on the 4 bytes at the cursor when the header's
//!    checksum flag is set (`§3.1.1`) — the frame ends at that trailer's
//!    last byte, and whatever follows it belongs to the next frame unit.
//!
//! The streaming reader (`Reader.zig`, the next slice) drives the same state
//! over its own input, and the pieces are shaped for it:
//!
//! - **The header is byte-fed.** `HeaderParser` consumes as much as its
//!   current field needs, so a reader whose input buffer holds only the 4
//!   bytes the magic needs parses the 2-14 byte header across `fill` calls;
//!   it feeds the parser, and an input end before `done()` is its
//!   `Truncated`. `parseHeader` is the whole-slice convenience over it.
//! - **The blocks are the reader's.** The reader parses the 3-byte
//!   Block_Header off its input (`block.parseHeader`), stages the
//!   Block_Content, and calls `block.decodeContent` itself — its serving
//!   region slides, so the length it hands that call is the *retained* count
//!   of frame output in the buffer, not the frame's total.
//! - **`State.recordBlock` is the one funnel.** It folds the block's output
//!   into the checksum (OQ7: exactly the bytes the block wrote, once, in
//!   order), advances the frame's decoded length, and enforces
//!   Frame_Content_Size's running bound. The reader passes
//!   `serving[retained_len..][0..bytes_written]`, the one-shot passes
//!   `target[decoded_len..][0..bytes_written]`; the fold is the same call, so
//!   no byte escapes the hash by taking a fast path — Raw, RLE, and
//!   Compressed blocks all land in the output before `recordBlock` sees
//!   them.
//! - **The frame end is one place.** `checkContentSize` and `verifyTrailer`
//!   are the reader's clean-end step, reached from both `fill` and `rebase`
//!   (`src/internal/README.md`, "A wrapper's rebase routes the inner end
//!   through the same ending as fill" — the zstd frame checksum rides that
//!   exact shape): an over-the-end peek or record request at a frame's tail
//!   must read and verify the trailer before the reader reports its end,
//!   never pass the inner end through with the trailer unread.
//!
//! ## The checksum
//!
//! `xxh64.zig` holds the fold state over std's kernel (`docs/research/
//! zstd-notes.md` §3). The trailer is "the result of the XXH64() hash
//! function digesting the original (decoded) data as input, and a seed of
//! zero. The low 4 bytes of the checksum are stored in little-endian format"
//! (`§3.1.1`); it is read and compared exactly once, at the frame's end, and
//! a mismatch is `WrongChecksum` — the RFC makes ignoring the checksum
//! compliant ("It may also ignore informative fields, such as the
//! checksum", `§2`), every working reference verifies it anyway, and std's
//! verification is a documented panic, so ours verifies and fails closed
//! (T8). A decode that fails before the frame end leaves the hash partial
//! and reports the decode's failure, never the checksum's.
//!
//! ## Errors
//!
//! The public set is the block layer's composed set plus this layer's own
//! names — `BadMagic`, `ReservedBitSet`, `DictionaryRequired`,
//! `ContentSizeMismatch`, `WrongChecksum`, and the `Truncated` the input's
//! end raises everywhere — and `zstd.decode.DecompressError` is exactly this
//! set, name for name. `WindowTooLarge` is deliberately *not* here: only a
//! caller with an authorized window (`checkWindow`) can raise it.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const block = @import("block.zig");
const common = @import("common.zig");
const golden = @import("golden.zig");
const internal = @import("../internal/root.zig");
const literals = @import("literals.zig");
const sequences = @import("sequences.zig");
const xxh64 = @import("xxh64.zig");

/// Everything the frame layer reports: the block layer's composed set plus
/// this layer's own names. `zstd.decode.DecompressError` is this set, name
/// for name (`decode.zig` asserts it at comptime).
pub const Error = error{
    /// `§3.1`, `§3.1.2` — the 4-byte Magic_Number is neither the Zstandard
    /// magic nor one of the 16 skippable magics.
    BadMagic,
    /// `§3.1.1.1.1.4` — descriptor bit 3: "Its value must be zero. A decoder
    /// compliant with this specification version must ensure it is not set."
    ReservedBitSet,
    /// `§3.1.1.1.3`, `§5` — Dictionary_ID_Flag is set: the frame needs a
    /// dictionary this decoder does not have. Raised at the first
    /// Dictionary_ID byte, before any body byte; never skipped, never
    /// misparsed (OQ4).
    DictionaryRequired,
    /// `§3.1.1.1.4` — Frame_Content_Size against the frame's actual decoded
    /// total: a running bound (`recordBlock`, `§8`'s smaller-than-actual
    /// vector) and a frame-end check (`checkContentSize`).
    ContentSizeMismatch,
    /// `§3.1.1` — the Content_Checksum trailer does not match the decoded
    /// bytes' XXH64 (T8: verify, never skip).
    WrongChecksum,
} || block.Error;

/// `§3.1.1` — "Magic_Number: 4 bytes, little-endian format. Value:
/// 0xFD2FB528."
pub const magic: u32 = 0xFD2F_B528;

/// `§3.1.2` — "Magic_Number: 4 bytes, little-endian format. Value:
/// 0x184D2A5?, which means any value from 0x184D2A50 to 0x184D2A5F. All 16
/// values are valid to identify a skippable frame."
pub const skippable_magic_base: u32 = 0x184D_2A50;
/// The skippable magic's low four bits carry the frame's tag; the rest must
/// match `skippable_magic_base`.
pub const skippable_magic_mask: u32 = 0xFFFF_FFF0;

/// The Magic_Number's 4 bytes (`§3.1.1`, `§3.1.2`).
pub const magic_len = 4;
/// The skippable Frame_Size's 4 bytes (`§3.1.2`): "the size, in bytes, of the
/// following User_Data (without including the magic number nor the size field
/// itself)".
pub const frame_size_len = 4;
/// `§3.1.1` — "Content_Checksum: ... 4 bytes" ("The low 4 bytes of the
/// checksum are stored in little-endian format").
pub const checksum_len = 4;

/// What a frame unit's Magic_Number identifies (`§3.1`): a Zstandard frame
/// (compressed data) or a skippable frame (user metadata).
pub const Kind = enum { zstandard, skippable };

/// Classify the 4 bytes at the front of `source` (`§3.1`, `§3.1.2`): the
/// Zstandard frame magic, one of the 16 skippable magics, or `BadMagic`.
/// Fewer than 4 bytes is the input's end, `Truncated`.
pub fn classify(source: []const u8) error{ BadMagic, Truncated }!Kind {
    if (source.len < magic_len) return error.Truncated;
    const value = common.readInt(u32, source[0..magic_len]);
    if (value == magic) return .zstandard;
    if (value & skippable_magic_mask == skippable_magic_base) return .skippable;
    return error.BadMagic;
}

/// `§3.1.1.1.2`'s Window_Size arithmetic: the four formulas both layers check
/// a frame against. The descriptor byte always parses — the formulas cannot
/// fail — and the *cap* on what a caller accepts is `checkWindow`'s.
pub const window = struct {
    /// `windowLog = 10 + Exponent` — 10 to 41.
    pub fn windowLog(exponent: u5) u6 {
        return @as(u6, exponent) + 10;
    }

    /// `windowBase = 1 << windowLog`.
    pub fn windowBase(exponent: u5) u64 {
        return @as(u64, 1) << windowLog(exponent);
    }

    /// `windowAdd = (windowBase / 8) * Mantissa`.
    pub fn windowAdd(exponent: u5, mantissa: u3) u64 {
        return (windowBase(exponent) / 8) * mantissa;
    }

    /// `Window_Size = windowBase + windowAdd`, from the Window_Descriptor
    /// byte (`§3.1.1.1.2`, Table 6: bits 7-3 Exponent, bits 2-0 Mantissa).
    pub fn size(descriptor: u8) u64 {
        const exponent: u5 = @truncate(descriptor >> 3);
        const mantissa: u3 = @truncate(descriptor);
        return windowBase(exponent) + windowAdd(exponent, mantissa);
    }

    /// `§3.1.1.1.2` — "The minimum Window_Size is 1 KB."
    pub const min_size: u64 = 1 << 10;
    /// `§3.1.1.1.2` — "The maximum Window_Size is (1<<41) + 7*(1<<38) bytes,
    /// which is 3.75 TB."
    pub const max_size: u64 = (1 << 41) + 7 * (1 << 38);
};

// The formulas' extremes, pinned at comptime: the descriptor's all-zero and
// all-one bytes must land exactly on the spec's stated minimum and maximum.
comptime {
    assert(window.size(0x00) == window.min_size);
    assert(window.size(0xff) == window.max_size);
    assert(window.windowLog(0) == 10);
    assert(window.windowLog(31) == 41);
}

/// The Frame_Header_Descriptor's fields (`§3.1.1.1.1`, Table 3).
pub const descriptor_fcs_flag_mask: u8 = 0xc0;
pub const descriptor_single_segment: u8 = 0x20;
pub const descriptor_unused: u8 = 0x10;
pub const descriptor_reserved: u8 = 0x08;
pub const descriptor_checksum: u8 = 0x04;
pub const descriptor_dictionary_flag_mask: u8 = 0x03;

/// `§3.1.1.1.1.1`, Table 4 — FCS_Field_Size from the descriptor: 1 when
/// Frame_Content_Size_Flag is 0 and Single_Segment_Flag is set, 0 when the
/// flag is 0 and it is not, else 2 / 4 / 8.
pub fn fcsFieldSize(descriptor: u8) usize {
    const flag: u2 = @truncate((descriptor & descriptor_fcs_flag_mask) >> 6);
    return switch (flag) {
        0 => if (descriptor & descriptor_single_segment != 0) 1 else 0,
        1 => 2,
        2 => 4,
        3 => 8,
    };
}

/// `§3.1.1.1.1.6`, Table 5 — DID_Field_Size from the descriptor.
pub fn didFieldSize(descriptor: u8) usize {
    const flag: u2 = @truncate(descriptor & descriptor_dictionary_flag_mask);
    return switch (flag) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 4,
    };
}

/// A parsed Frame_Header (`§3.1.1.1`, Table 2): the descriptor's fields and
/// the two sizes they imply.
pub const Header = struct {
    /// The raw Frame_Header_Descriptor byte (`§3.1.1.1.1`, Table 3), kept
    /// whole so every bit's provenance stays visible at the call site.
    descriptor: u8,
    /// `§3.1.1.1.2` — Window_Size: the window arithmetic's value, or
    /// Frame_Content_Size itself when Single_Segment_Flag is set.
    window_size: u64,
    /// `§3.1.1.1.4` — Frame_Content_Size; `null` when FCS_Field_Size is 0.
    /// Single_Segment_Flag makes it necessarily present.
    content_size: ?u64,
    /// `§3.1.1.1.1.5` — Content_Checksum_Flag: the 4-byte trailer.
    checksum: bool,
    /// The Frame_Header's length, 2-14 bytes (`§3.1.1.1`): the descriptor
    /// plus its optional fields. The block chain starts here.
    bytes_consumed: usize,
};

/// The Frame_Header parser (`§3.1.1.1`, Table 2): a byte-fed state machine
/// over the field order — the descriptor, the Window_Descriptor, the
/// Dictionary_ID, the Frame_Content_Size. The one-shot drives it over the
/// whole source, the streaming reader over its buffered chunks, and it stages
/// nothing: the header is at most 14 bytes and each field accumulates into
/// its own scalar (the gzip `HeaderParser` shape), so a reader whose input
/// buffer is only the 4 bytes the magic needs can still parse it byte by
/// byte.
pub const HeaderParser = struct {
    stage: Stage = .descriptor,
    /// The Frame_Header_Descriptor byte, once read.
    descriptor: u8 = 0,
    /// The current field's bytes consumed so far, and its little-endian
    /// value (the Window_Descriptor's one byte, the FCS's up to eight).
    taken: usize = 0,
    value: u64 = 0,
    /// The two sizes the header implies; 0 / `null` until their fields are
    /// complete.
    window_size: u64 = 0,
    content_size: ?u64 = null,
    /// The Frame_Header's bytes consumed (`§3.1.1.1`: 2-14).
    total: usize = 0,

    /// The field being consumed, in Table 2's order.
    pub const Stage = enum { descriptor, window, dictionary, fcs, done };

    /// Whether the header is complete.
    pub fn done(parser: *const HeaderParser) bool {
        return parser.stage == .done;
    }

    /// The parsed header. Only legal once `done`.
    pub fn header(parser: *const HeaderParser) Header {
        assert(parser.done());
        return .{
            .descriptor = parser.descriptor,
            .window_size = parser.window_size,
            .content_size = parser.content_size,
            .checksum = parser.descriptor & descriptor_checksum != 0,
            .bytes_consumed = parser.total,
        };
    }

    /// Feed `bytes` to the parser and return the bytes consumed. The parser
    /// consumes as much as the current field needs; a caller with more input
    /// feeds again (the streaming route), and a caller holding the whole
    /// header feeds once. Every stage of a non-empty slice either consumes a
    /// byte or fails, so a driver always makes progress; the input's end
    /// inside the header is the driver's `Truncated` (the parser simply is
    /// not `done` yet).
    pub fn feed(parser: *HeaderParser, bytes: []const u8) Error!usize {
        var consumed: usize = 0;
        while (consumed < bytes.len and parser.stage != .done) {
            consumed += try parser.step(bytes[consumed..]);
        }
        return consumed;
    }

    /// One field's worth of progress; `bytes` is non-empty.
    fn step(parser: *HeaderParser, bytes: []const u8) Error!usize {
        assert(bytes.len > 0);
        switch (parser.stage) {
            .descriptor => {
                // §3.1.1.1.1.4 — "Its value must be zero. A decoder
                // compliant with this specification version must ensure it
                // is not set." Bit 4 is deliberately not tested: "shall not
                // interpret this bit" (§3.1.1.1.1.3).
                if (bytes[0] & descriptor_reserved != 0) return error.ReservedBitSet;
                parser.descriptor = bytes[0];
                parser.total += 1;
                // §3.1.1.1.2 — "The Window_Descriptor byte is optional.
                // When Single_Segment_Flag is set, Window_Descriptor is not
                // present."
                parser.stage = if (bytes[0] & descriptor_single_segment == 0)
                    .window
                else
                    parser.afterWindow();
                return 1;
            },
            .window => {
                parser.window_size = window.size(bytes[0]);
                parser.total += 1;
                parser.stage = parser.afterWindow();
                return 1;
            },
            .dictionary => {
                // §3.1.1.1.3 + §5 — the frame references a dictionary. The
                // refusal lands at the first Dictionary_ID byte, before any
                // body byte, and no byte of the ID is interpreted (OQ4).
                return error.DictionaryRequired;
            },
            .fcs => {
                const need = fcsFieldSize(parser.descriptor);
                assert(need > 0);
                const take = @min(need - parser.taken, bytes.len);
                for (bytes[0..take], 0..) |byte, index| {
                    parser.value |= @as(u64, byte) << @intCast(8 * (parser.taken + index));
                }
                parser.taken += take;
                parser.total += take;
                if (parser.taken < need) return take;
                // §3.1.1.1.4 — "When FCS_Field_Size is 2, the offset of 256
                // is added"; 1, 4, and 8 bytes are read directly.
                parser.content_size = if (need == 2) parser.value + 256 else parser.value;
                // §3.1.1.1.2 — "In this case, Window_Size is
                // Frame_Content_Size."
                if (parser.descriptor & descriptor_single_segment != 0) {
                    parser.window_size = parser.content_size.?;
                }
                parser.stage = .done;
                return take;
            },
            .done => unreachable,
        }
    }

    /// The stage after the descriptor or the Window_Descriptor: the
    /// Dictionary_ID when the flag is set, else the Frame_Content_Size when
    /// one is present, else the header is done.
    fn afterWindow(parser: *const HeaderParser) Stage {
        if (parser.descriptor & descriptor_dictionary_flag_mask != 0) return .dictionary;
        if (fcsFieldSize(parser.descriptor) > 0) return .fcs;
        return .done;
    }
};

/// Parse a whole Frame_Header from the front of `source` — the bytes *after*
/// the Magic_Number (`§3.1.1.1`). The one-shot's and the fixtures' form; the
/// streaming reader drives `HeaderParser` directly. Fewer bytes than the
/// header needs is the input's end: `Truncated`.
pub fn parseHeader(source: []const u8) Error!Header {
    var parser: HeaderParser = .{};
    const consumed = try parser.feed(source);
    if (!parser.done()) return error.Truncated;
    assert(consumed <= source.len);
    return parser.header();
}

/// `§3.1.1.1.2` — "a decoder is allowed to reject a compressed frame that
/// requests a memory size beyond the decoder's authorized range": the
/// streaming reader's cap, checked once the header is parsed and before any
/// block byte is read. The one-shot applies no cap — its history is `target`
/// itself — so `WindowTooLarge` is not in `zstd.decode.DecompressError`.
pub fn checkWindow(header: Header, max_window_size: u64) error{WindowTooLarge}!void {
    if (header.window_size > max_window_size) return error.WindowTooLarge;
}

/// One frame's decode state, threaded across its blocks (the landed layers'
/// `State` shape, one level up): the parsed header, the two entropy layers'
/// cross-block states, the frame's decoded length, and the XXH64 fold.
///
/// The checksum rides the one per-block emission funnel (OQ7):
/// `recordBlock` is the only place a decoded byte reaches the hash, and it is
/// handed exactly the bytes each block wrote, in order.
pub const State = struct {
    /// The parsed Frame_Header (`§3.1.1.1`).
    header: Header,
    /// The Huffman tree a Treeless_Literals_Block reuses (`§3.1.1.3`), one
    /// per frame.
    literals: literals.State = .{},
    /// The three decoding tables and the repeat offsets a Repeat_Mode reuses
    /// (`§3.1.1.3`, `§3.1.1.5`), one per frame.
    sequences: sequences.State = .{},
    /// `§3.1.1` — the decoded bytes' XXH64, folded per block. A flag-off
    /// frame folds nothing: nothing will be verified.
    checksum: xxh64.State = .{},
    /// The frame's decoded length so far: the block layer's `decoded_len` on
    /// the one-shot's contiguous path, and the frame's running total
    /// (Frame_Content_Size's bound, `§3.1.1.1.4`) everywhere.
    decoded_len: usize = 0,

    /// A fresh state for one frame.
    pub fn init(header: Header) State {
        return .{ .header = header };
    }

    /// Decode one block from the front of `source` (its Block_Header) into
    /// `target`, recording its output — the one-shot's contiguous step, where
    /// `target[0..decoded_len]` is the frame's output so far and the frame's
    /// counter is also the block call's index.
    ///
    /// The streaming reader does not use this one: its serving region slides,
    /// so it parses the Block_Header off its own input, stages the content,
    /// and drives `block.decodeContent` with its *retained* length — then
    /// `recordBlock` below.
    pub fn decodeBlock(state: *State, source: []const u8, target: []u8) Error!block.Section {
        const section = try block.decode(
            source,
            target,
            state.decoded_len,
            state.header.window_size,
            &state.literals,
            &state.sequences,
        );
        // The output slice is taken with the pre-call `decoded_len`: the
        // bytes this block just wrote, which `recordBlock` then folds and
        // counts.
        const output = target[state.decoded_len..][0..section.bytes_written];
        try state.recordBlock(output);
        return section;
    }

    /// Record one decoded block: the OQ7 funnel — the block's output folded
    /// into the checksum exactly once, in order — the frame's decoded length,
    /// and Frame_Content_Size's running bound: a frame that has already
    /// produced more bytes than it declared fails at that block, so a hostile
    /// header cannot amplify before the frame end (`§3.1.1.1.4`, `§8`'s
    /// smaller-than-actual vector).
    ///
    /// `output` is exactly the bytes the block just wrote, and the slice is
    /// computed with the length that block call used: the one-shot's
    /// `target[decoded_len..][0..bytes_written]`, the streaming reader's
    /// `serving[retained_len..][0..bytes_written]`.
    pub fn recordBlock(state: *State, output: []const u8) error{ContentSizeMismatch}!void {
        if (state.header.checksum) state.checksum.update(output);
        state.decoded_len += output.len;
        if (state.header.content_size) |declared| {
            if (state.decoded_len > declared) return error.ContentSizeMismatch;
        }
    }

    /// The frame end's check (`§3.1.1.1.4`): Frame_Content_Size against the
    /// frame's actual decoded total. `recordBlock` catches the running
    /// overshoot; this catches a frame that stopped short of what it declared.
    pub fn checkContentSize(state: *const State) error{ContentSizeMismatch}!void {
        if (state.header.content_size) |declared| {
            if (state.decoded_len != declared) return error.ContentSizeMismatch;
        }
    }

    /// The frame end's trailer step (`§3.1.1`, `§3.1.1.1.1.5`): compare the
    /// 4-byte Content_Checksum against the folded digest — "The low 4 bytes
    /// of the checksum are stored in little-endian format" — once, here, and
    /// fail `WrongChecksum` on a mismatch (T8: verify, never skip).
    ///
    /// The caller gates on the header's checksum flag (a flag-off frame has
    /// no trailer and folded nothing) and owns the input's end: fewer than
    /// four bytes is its `Truncated`. std spells the kernel's `final` through
    /// a mutable receiver, so this is `*State`; it is a read.
    pub fn verifyTrailer(state: *State, trailer: []const u8) error{WrongChecksum}!void {
        assert(state.header.checksum);
        assert(trailer.len == checksum_len);
        if (common.readInt(u32, trailer[0..checksum_len]) != state.checksum.final()) {
            return error.WrongChecksum;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1 (the frame), §3.1.1
// (the header, the checksum), §3.1.1.1.1-§3.1.1.1.4 (the descriptor and its
// fields), §3.1.1.2 (the block chain), §3.1.2 (skippable frames). The
// fixture frames are `golden.zig`'s, each verified by the pinned zstd v1.5.7
// (the CLI decodes the good ones byte-exact and exits 1 on the negative
// corners).
// ---------------------------------------------------------------------------

/// Walk a whole fixture frame the way the one-shot does, one layer down: the
/// magic, the header, the block chain through `State`, and the trailer. The
/// fixture is the frame unit entire, so the walk must land exactly on its
/// end. `progress` records the decoded length after the last block that
/// succeeded, so a failing walk can prove nothing past it was written.
fn decodeFrame(bytes: []const u8, target: []u8, progress: *usize) !usize {
    progress.* = 0;
    try testing.expectEqual(Kind.zstandard, try classify(bytes));
    const header = try parseHeader(bytes[magic_len..]);
    var state: State = .init(header);
    var cursor = magic_len + header.bytes_consumed;
    while (true) {
        const section = state.decodeBlock(bytes[cursor..], target) catch |err| {
            // A post-write check — Frame_Content_Size's running bound — fails
            // after the block landed, so the sentinel's floor is the frame's
            // decoded length, not the last successful block's.
            progress.* = state.decoded_len;
            return err;
        };
        cursor += section.bytes_consumed;
        progress.* = state.decoded_len;
        if (section.last_block) break;
    }
    try state.checkContentSize();
    // §3.1.1 — the frame ends at the last block's last byte, or at the
    // Content_Checksum trailer's when the flag is set.
    if (header.checksum) {
        if (bytes.len - cursor < checksum_len) return error.Truncated;
        try state.verifyTrailer(bytes[cursor..][0..checksum_len]);
        cursor += checksum_len;
    }
    try testing.expectEqual(bytes.len, cursor);
    return state.decoded_len;
}

/// Decode a fixture frame and check its output, with the sentinel overrun
/// check every decode test runs (AGENTS.md, "Rules").
fn expectFrame(bytes: []const u8, expected: []const u8) !void {
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    var progress: usize = 0;
    const written = try decodeFrame(bytes, &target, &progress);
    try testing.expectEqual(expected.len, written);
    try testing.expectEqualSlices(u8, expected, target[0..written]);
    try internal.sentinel.expect(&target, written);
}

/// Walk a fixture frame expecting `err`, proving the failure came before the
/// offending write: the bytes past what the blocks that did decode wrote are
/// untouched.
fn expectFrameError(err: Error, bytes: []const u8) !void {
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    var progress: usize = 0;
    if (decodeFrame(bytes, &target, &progress)) |_| {
        return error.TestExpectedError;
    } else |actual| {
        try testing.expectEqual(err, actual);
        try internal.sentinel.expect(&target, progress);
    }
}

test "classify reads §3.1's two magic families" {
    // RFC 8878 §3.1 — "The Magic_Number is 0xFD2FB528", little-endian; §3.1.2
    // — "Value: 0x184D2A5?, which means any value from 0x184D2A50 to
    // 0x184D2A5F. All 16 values are valid to identify a skippable frame."
    try testing.expectEqual(Kind.zstandard, try classify(&golden.frame_magic));
    try testing.expectEqual(Kind.zstandard, try classify(&golden.frame_raw));
    for (0..16) |tag| {
        const value: u32 = skippable_magic_base + @as(u32, @intCast(tag));
        const skippable = [_]u8{
            @truncate(value),
            @truncate(value >> 8),
            @truncate(value >> 16),
            @truncate(value >> 24),
        };
        try testing.expectEqual(Kind.skippable, try classify(&skippable));
    }
    // The neighbors outside the range: 0x184D2A4F and 0x184D2A60 are
    // neither family (`docs/research/zstd-notes.md` §5.4's out-of-range
    // frame; the CLI exits 1 on it).
    try testing.expectError(error.BadMagic, classify(&.{ 0x4f, 0x2a, 0x4d, 0x18 }));
    try testing.expectError(error.BadMagic, classify(&.{
        0x60, 0x2a, 0x4d, 0x18,
    }));
    // A flipped Zstandard magic is neither family (the corruption set's
    // flipped-magic row).
    try testing.expectError(error.BadMagic, classify(&golden.frame_bad_magic));
    // A short or empty input is the input's end, not a wrong magic.
    try testing.expectError(error.Truncated, classify(&.{}));
    try testing.expectError(error.Truncated, classify(&.{ 0x28, 0xb5 }));
}

test "parseHeader reads every FCS form" {
    // RFC 8878 §3.1.1.1.1.1, Table 4 — "When Frame_Content_Size_Flag is 0,
    // FCS_Field_Size depends on Single_Segment_Flag: if Single_Segment_Flag
    // is set, FCS_Field_Size is 1. Otherwise, FCS_Field_Size is 0;
    // Frame_Content_Size is not provided." Table 7 — 1 / 2 / 4 / 8 bytes,
    // little-endian, "When FCS_Field_Size is 2, the offset of 256 is added."
    // Flag 0 without Single_Segment_Flag: absent, and the header is the
    // descriptor plus the Window_Descriptor.
    const absent = try parseHeader(&.{ 0x00, 0x00 });
    try testing.expectEqual(@as(?u64, null), absent.content_size);
    try testing.expectEqual(@as(usize, 2), absent.bytes_consumed);
    try testing.expect(!absent.checksum);
    // Flag 0 with Single_Segment_Flag: one byte (0-255), and Window_Size is
    // that value.
    const one = try parseHeader(&.{ 0x20, 0x08 });
    try testing.expectEqual(@as(?u64, 8), one.content_size);
    try testing.expectEqual(@as(u64, 8), one.window_size);
    try testing.expectEqual(@as(usize, 2), one.bytes_consumed);
    // Flag 1: two bytes, plus the 256 offset — 0x2c 0x00 is 300.
    const two = try parseHeader(&.{ 0x40, 0x00, 0x2c, 0x00 });
    try testing.expectEqual(@as(?u64, 300), two.content_size);
    try testing.expectEqual(@as(usize, 4), two.bytes_consumed);
    // The form's floor: 0x00 0x00 is 256, not 0.
    try testing.expectEqual(@as(?u64, 256), (try parseHeader(&.{ 0x40, 0x00, 0, 0 })).content_size);
    // Flag 2: four bytes, little-endian.
    const four = try parseHeader(&.{ 0x80, 0x00, 0x78, 0x56, 0x34, 0x12 });
    try testing.expectEqual(@as(?u64, 0x12345678), four.content_size);
    try testing.expectEqual(@as(usize, 6), four.bytes_consumed);
    // Flag 3: eight bytes, little-endian — "It's allowed to represent a
    // small size (for example, 18) using any compatible variant", so the
    // value is not range-checked against the form.
    const eight = try parseHeader(&.{ 0xc0, 0x00, 0x12, 0, 0, 0, 0, 0, 0, 0 });
    try testing.expectEqual(@as(?u64, 0x12), eight.content_size);
    try testing.expectEqual(@as(usize, 10), eight.bytes_consumed);
    // The descriptor's checksum bit (§3.1.1.1.1.5) rides along: same bytes,
    // flag set.
    const flagged = try parseHeader(&.{ 0xc4, 0x00, 1, 0, 0, 0, 0, 0, 0, 0 });
    try testing.expect(flagged.checksum);
}

test "parseHeader: Single_Segment_Flag skips the Window_Descriptor" {
    // RFC 8878 §3.1.1.1.1.2 — "In this case, Window_Descriptor byte is
    // skipped, but Frame_Content_Size is necessarily present. ... the decoder
    // must allocate a memory segment of a size equal to or larger than
    // Frame_Content_Size"; §3.1.1.1.2 — "When Single_Segment_Flag is set,
    // Window_Descriptor is not present. In this case, Window_Size is
    // Frame_Content_Size."
    const single = try parseHeader(&.{ 0x60, 0x2c, 0x00 });
    try testing.expectEqual(@as(?u64, 300), single.content_size);
    try testing.expectEqual(@as(u64, 300), single.window_size);
    try testing.expectEqual(@as(usize, 3), single.bytes_consumed);
    // The same bytes without the flag are a descriptor, a Window_Descriptor
    // (0x2c -> exponent 5, mantissa 4 -> 4 KB), and a 4-byte FCS that is not
    // there.
    try testing.expectError(error.Truncated, parseHeader(&.{ 0x40, 0x2c, 0x00 }));
    // The zero-size single-segment frame: Window_Size 0, so no block may
    // carry content (Block_Maximum_Size is 0, §3.1.1.2.4) — the CLI's own
    // empty-input frame is this shape.
    const empty = try parseHeader(&.{ 0x20, 0x00 });
    try testing.expectEqual(@as(?u64, 0), empty.content_size);
    try testing.expectEqual(@as(u64, 0), empty.window_size);
}

test "window reads §3.1.1.1.2's descriptor arithmetic" {
    // RFC 8878 §3.1.1.1.2 — "windowLog = 10 + Exponent; windowBase = 1 <<
    // windowLog; windowAdd = (windowBase / 8) * Mantissa; Window_Size =
    // windowBase + windowAdd. The minimum Window_Size is 1 KB. The maximum
    // Window_Size is (1<<41) + 7*(1<<38) bytes, which is 3.75 TB."
    try testing.expectEqual(@as(u64, 1024), window.size(0x00));
    // Mantissa alone: descriptor 0x07 is 1 KB + 7/8 KB.
    try testing.expectEqual(@as(u64, 1024 + 7 * 128), window.size(0x07));
    // Exponent alone: 0x38 is exponent 7 -> 128 KB; 0x48 is exponent 9 ->
    // 512 KB (the fixture frames' window); 0x58 is exponent 11 -> 2 MB (the
    // CLI's level-3 pin); 0x68 is exponent 13 -> 8 MB (the level-19 pin and
    // §3.1.1.1.2's recommendation).
    try testing.expectEqual(@as(u64, 128 * 1024), window.size(0x38));
    try testing.expectEqual(@as(u64, 512 * 1024), window.size(0x48));
    try testing.expectEqual(@as(u64, 2 * 1024 * 1024), window.size(0x58));
    try testing.expectEqual(@as(u64, 8 * 1024 * 1024), window.size(0x68));
    try testing.expectEqual(@as(u64, 8 * 1024 * 1024), window.windowBase(13));
    try testing.expectEqual(@as(u64, 0), window.windowAdd(13, 0));
    try testing.expectEqual(@as(u6, 23), window.windowLog(13));
    // The extremes: the spec's own numbers, not a formula re-derivation.
    try testing.expectEqual(window.min_size, window.size(0x00));
    try testing.expectEqual(window.max_size, window.size(0xff));
    // The spec's "3.75 TB" is binary: 15 * 2^38 bytes, which the formula's
    // maximum lands on exactly.
    try testing.expectEqual(@as(u64, 15 * (1 << 38)), window.max_size);
    try testing.expectEqual(@as(u64, 1 << 41), window.windowBase(31));
    try testing.expectEqual(@as(u64, 7 * (1 << 38)), window.windowAdd(31, 7));
}

test "parseHeader: the unused bit is never interpreted, the reserved bit fails closed" {
    // RFC 8878 §3.1.1.1.1.3 — "A decoder compliant with this specification
    // version shall not interpret this bit. It might be used in a future
    // version to signal a property that is not mandatory to properly decode
    // the frame." The CLI decodes a frame with bit 4 set (verified: exit 0),
    // so the bit is accepted with either value and never read.
    const plain = try parseHeader(&.{ 0x00, 0x00 });
    const unused = try parseHeader(&.{ descriptor_unused, 0x00 });
    try testing.expectEqual(plain.window_size, unused.window_size);
    try testing.expectEqual(plain.content_size, unused.content_size);
    try testing.expectEqual(plain.checksum, unused.checksum);
    // RFC 8878 §3.1.1.1.1.4 — "This bit is reserved for some future feature.
    // Its value must be zero. A decoder compliant with this specification
    // version must ensure it is not set." The CLI exits 1 ("Unsupported
    // frame parameter") on the same frame.
    try testing.expectError(error.ReservedBitSet, parseHeader(&.{ 0x08, 0x00 }));
    // Every descriptor byte with bit 3 set, whatever the other flags say: the
    // check lands at the descriptor byte, before any other field, so no
    // combination of the rest can rescue it.
    for (0..256) |byte| {
        if (byte & descriptor_reserved == 0) continue;
        try testing.expectError(
            error.ReservedBitSet,
            parseHeader(&.{ @intCast(byte), 0x00, 0x00, 0x00, 0x00, 0x00 }),
        );
    }
}

test "parseHeader refuses dictionaries at the first Dictionary_ID byte" {
    // RFC 8878 §3.1.1.1.3 — the Dictionary_ID "contains the ID of the
    // dictionary required to properly decode the frame"; §5 leaves
    // acquisition out of band and §2 demands "an unambiguous error code".
    // OQ4: refused at the first Dictionary_ID byte, before any body byte —
    // the CLI fails both fixtures with "Dictionary mismatch".
    try testing.expectError(error.DictionaryRequired, parseHeader(&.{ 0x01, 0x00, 0x2a }));
    try testing.expectError(error.DictionaryRequired, parseHeader(&.{ 0x02, 0x00, 0x2a, 0x2b }));
    try testing.expectError(error.DictionaryRequired, parseHeader(&.{
        0x03, 0x00, 0x44, 0x33, 0x22, 0x11,
    }));
    // The refusal is not gated on the whole field being present: the first
    // byte alone is enough, and the rest of the ID is never read.
    try testing.expectError(error.DictionaryRequired, parseHeader(&.{ 0x03, 0x00, 0x44 }));
    // A header cut before the first Dictionary_ID byte is the input's end
    // (`Truncated`), the same rule as everywhere else in the frame — the CLI
    // agrees on both shapes ("premature end" for the cut one, "Dictionary
    // mismatch" for the complete one).
    try testing.expectError(error.Truncated, parseHeader(&.{ 0x03, 0x00 }));
    try testing.expectError(error.Truncated, parseHeader(&.{0x01}));
    try testing.expectError(error.Truncated, parseHeader(&.{0x00}));
    // The DID field sizes themselves (Table 5), and the header's 14-byte
    // maximum: 1 descriptor + 1 window + 4 DID + 8 FCS.
    try testing.expectEqual(@as(usize, 0), didFieldSize(0x00));
    try testing.expectEqual(@as(usize, 1), didFieldSize(0x01));
    try testing.expectEqual(@as(usize, 2), didFieldSize(0x02));
    try testing.expectEqual(@as(usize, 4), didFieldSize(0x03));
    try testing.expectEqual(@as(usize, 14), 1 + 1 + 4 + 8);
}

test "parseHeader is byte-fed" {
    // The streaming reader's shape: its input buffer holds only the 4 bytes
    // the magic needs, so the 2-14 byte header arrives a chunk at a time. The
    // parser must consume as much as it can and no more, and the same header
    // must parse identically however the bytes are cut.
    const bytes = [_]u8{ 0x84, 0x00, 0x78, 0x56, 0x34, 0x12 };
    const whole = try parseHeader(&bytes);
    var parser: HeaderParser = .{};
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const consumed = try parser.feed(bytes[cursor..][0..1]);
        try testing.expectEqual(@as(usize, 1), consumed);
        cursor += consumed;
    }
    try testing.expect(parser.done());
    try testing.expectEqual(whole.descriptor, parser.header().descriptor);
    try testing.expectEqual(whole.window_size, parser.header().window_size);
    try testing.expectEqual(whole.content_size, parser.header().content_size);
    try testing.expectEqual(whole.checksum, parser.header().checksum);
    try testing.expectEqual(whole.bytes_consumed, parser.header().bytes_consumed);
    // The parser stops at the header's end: the block chain's first bytes are
    // not consumed (the one-shot's cursor depends on that).
    var slack: HeaderParser = .{};
    const with_block = bytes ++ [_]u8{0xff};
    const consumed = try slack.feed(&with_block);
    try testing.expectEqual(bytes.len, consumed);
    // An input end inside the header leaves the parser not-done, which is the
    // driver's `Truncated`.
    var short: HeaderParser = .{};
    try testing.expectEqual(@as(usize, 1), try short.feed(&.{0x84}));
    try testing.expect(!short.done());
}

test "checkWindow bounds the frame's Window_Size" {
    // RFC 8878 §3.1.1.1.2 — "In order to protect decoders from unreasonable
    // memory requirements, a decoder is allowed to reject a compressed frame
    // that requests a memory size beyond the decoder's authorized range. ...
    // it's recommended for decoders to support values of Window_Size up to
    // 8 MB". The cap is the caller's; the one-shot never applies one.
    const header = try parseHeader(&.{ 0x00, 0x48 }); // 512 KB
    try checkWindow(header, 512 * 1024);
    try checkWindow(header, 8 * 1024 * 1024);
    try testing.expectError(error.WindowTooLarge, checkWindow(header, 512 * 1024 - 1));
    try testing.expectError(error.WindowTooLarge, checkWindow(header, 0));
    // The single-segment form's window is its FCS, so the cap sees the same
    // number the decoder would have to materialize.
    const single = try parseHeader(&.{ 0x60, 0x2c, 0x00 }); // FCS 300
    try checkWindow(single, 300);
    try testing.expectError(error.WindowTooLarge, checkWindow(single, 299));
}

test "the frame walk decodes the fast-path fixtures" {
    // RFC 8878 §3.1.1.2 — the block chain, and §3.1.1.2.1's Last_Block ends
    // it. Raw and RLE blocks take no entropy path but land in the output (and
    // so in the checksum funnel) like any other.
    try expectFrame(&golden.frame_raw, "zstd raw");
    try expectFrame(&golden.frame_raw_empty, "");
    try expectFrame(&golden.frame_rle, "AAAAAAAAAA");
    try expectFrame(&golden.frame_multi, "abcdefghIIIIII");
    // §3.1.1.2.4 — an RLE block at exactly Block_Maximum_Size: 128 KB from
    // one content byte.
    const run = [_]u8{0x5a} ** block.max_block_size;
    var target: [block.max_block_size + 8]u8 = undefined;
    internal.sentinel.fill(&target);
    var progress: usize = 0;
    const written = try decodeFrame(&golden.frame_rle_max, &target, &progress);
    try testing.expectEqual(block.max_block_size, written);
    try testing.expectEqualSlices(u8, &run, target[0..written]);
    try internal.sentinel.expect(&target, written);
}

test "the frame walk decodes the landed fixture frames" {
    // RFC 8878 §3.1.1.3 — the compressed blocks' fixtures, framed as whole
    // frames by the block slice and re-read here through the frame layer: the
    // T1 pair, the literals families, the sequences pairs, and the
    // hand-built corners. Each expectation is the CLI's own `zstd -d` bytes.
    try expectFrame(&golden.frame_t1, &golden.t1_literals);
    try expectFrame(&golden.frame_t1_errata, &golden.t1_errata_literals);
    try expectFrame(&golden.frame_treeless, &.{ 0, 1, 4, 5, 0, 0, 0, 0, 0 });
    try expectFrame(&golden.frame_repeat, &golden.frame_repeat_expected);
    try expectFrame(&golden.frame_temp_offset, &golden.frame_temp_offset_expected);
    try expectFrame(&golden.frame_corner, &golden.frame_corner_expected);
    try expectFrame(&golden.frame_two_byte, &golden.frame_two_byte_expected);
    try expectFrame(&golden.frame_zero_seq, &golden.frame_zero_seq_expected);
    try expectFrame(&golden.frame_zero_seq_2b, &golden.frame_zero_seq_expected);
    try expectFrame(&golden.frame_sequences_predefined, &golden.sequences_predefined_expected);
    try expectFrame(
        &golden.frame_sequences_rle_match_lengths,
        &golden.sequences_rle_match_lengths_expected,
    );
    try expectFrame(&golden.frame_sequences_fse_offsets, &golden.sequences_fse_offsets_expected);
    try expectFrame(&golden.frame_sequences_fse_all, &golden.sequences_fse_all_expected);
    try expectFrame(&golden.frame_literals_1stream, &golden.literals_1stream_expected);
    try expectFrame(&golden.frame_literals_4stream_sf1, &golden.literals_4stream_sf1_expected);
    try expectFrame(&golden.frame_literals_4stream_sf2, &golden.literals_4stream_sf2_expected);
    try expectFrame(&golden.frame_literals_fse_tree, &golden.literals_fse_tree_expected);
}

test "the frame walk carries the window accounting across blocks" {
    // RFC 8878 §3.1.1.4 — "all offsets leading to previously decoded data
    // must be smaller than Window_Size": the two window fixtures' decoded
    // lengths pass both Window_Size and Block_Maximum_Size, so the frame
    // layer's one running counter is what the block layer's history is
    // re-based against.
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    var progress: usize = 0;
    var written = try decodeFrame(&golden.frame_window_1k, &target, &progress);
    try testing.expectEqual(@as(usize, 2048 + 3), written);
    try testing.expectEqualSlices(u8, "BBB", target[2048..2051]);
    try internal.sentinel.expect(&target, written);
    written = try decodeFrame(&golden.frame_window_128k, &target, &progress);
    try testing.expectEqual(@as(usize, 2 * 131072 + 3), written);
    try testing.expectEqualSlices(u8, "BBB", target[262144..262147]);
    try internal.sentinel.expect(&target, written);
    // The one-byte-past siblings: `OffsetTooFar` (T12 — the CLI decodes
    // both, its whole-buffer decoder checking the bytes it still has rather
    // than the declared window).
    try expectFrameError(error.OffsetTooFar, &golden.frame_window_1k_over);
    try expectFrameError(error.OffsetTooFar, &golden.frame_window_128k_over);
}

test "the checksum folds each block's output exactly once, in order" {
    // RFC 8878 §3.1.1 — "The content checksum is the result of the XXH64()
    // hash function digesting the original (decoded) data as input, and a
    // seed of zero. The low 4 bytes of the checksum are stored in
    // little-endian format." The fixtures' trailers are the CLI's own bytes
    // (each verified with `zstd -t`), so the fold is pinned against the C
    // library's XXH64, not against our own arithmetic.
    try expectFrame(&golden.frame_checksum, "abcd");
    try expectFrame(&golden.frame_checksum_empty, "");
    // The flag is the only difference the trailer makes: the checksum-off
    // sibling is the same frame with descriptor bit 2 clear and no trailer
    // (the CLI's own `--check`/`--no-check` pair differs in exactly those
    // bytes), and it decodes to the same output.
    try expectFrame(&golden.frame_checksum_off, "abcd");
    // The multi-block CLI frame: 135000 decoded bytes over two compressed
    // blocks, folded in order (OQ7 — one funnel, no second pass).
    var target: [block.max_block_size * 2]u8 = undefined;
    internal.sentinel.fill(&target);
    var progress: usize = 0;
    const written = try decodeFrame(&golden.frame_checksum_multi, &target, &progress);
    const expected = golden.frame_checksum_multi_text ** 3000;
    try testing.expectEqual(expected.len, written);
    try testing.expectEqualSlices(u8, expected, target[0..written]);
    try internal.sentinel.expect(&target, written);
    // A mismatched trailer is `WrongChecksum` (T8 — verify, never skip; the
    // CLI exits 1 with "Restored data doesn't match checksum"), and a trailer
    // cut short is the input's end.
    try expectFrameError(error.WrongChecksum, &golden.frame_checksum_corrupt);
    try expectFrameError(error.Truncated, &golden.frame_checksum_truncated);
}

test "the fold is independent of the block boundaries" {
    // OQ7's discipline, stated as an invariant: the digest over a frame's
    // blocks in order is the digest over the concatenation, whatever the
    // boundaries. `recordBlock` is the only path, and it is handed exactly
    // the bytes each block wrote.
    const first = "the quick brown fox ";
    const second = "jumps over the lazy dog";
    var state: State = .init(.{
        .descriptor = descriptor_checksum,
        .window_size = 1024,
        .content_size = null,
        .checksum = true,
        .bytes_consumed = 2,
    });
    try state.recordBlock(first);
    try state.recordBlock(second);
    try testing.expectEqual(@as(usize, first.len + second.len), state.decoded_len);
    try testing.expectEqual(
        @as(u32, @truncate(xxh64.xxh64(0, first ++ second))),
        state.checksum.final(),
    );
    // A flag-off frame folds nothing at all: the state's digest stays the
    // empty-payload value, which is what makes the branch a real saving
    // rather than a cosmetic one.
    var plain: State = .init(.{
        .descriptor = 0,
        .window_size = 1024,
        .content_size = null,
        .checksum = false,
        .bytes_consumed = 2,
    });
    try plain.recordBlock(first);
    try testing.expectEqual(@as(u32, 0x51D8E999), plain.checksum.final());
}

test "Frame_Content_Size is a running bound, and the frame end closes it" {
    // RFC 8878 §3.1.1.1.4 — "Frame_Content_Size ... is the original
    // (uncompressed) size"; §8 names the smaller-than-actual FCS as an
    // attack vector. Both fixtures are one 8-byte Raw block whose header
    // declares 4 and 12: the first fails at that block (the running bound),
    // the second at the frame end. The CLI exits 1 on both.
    try expectFrameError(error.ContentSizeMismatch, &golden.frame_fcs_short);
    try expectFrameError(error.ContentSizeMismatch, &golden.frame_fcs_long);
    // The matching declaration decodes: the same shape with FCS 8.
    try expectFrame(&golden.frame_fcs4, "01234567");
    // The 8-byte form's maximum is a declaration like any other — nothing is
    // sized from it, and it is checked against the decode. The C reserves
    // 2^64-1 as its `ZSTD_CONTENTSIZE_UNKNOWN` sentinel and skips the check
    // (the CLI decodes this frame); the RFC has no such value, so ours is
    // `ContentSizeMismatch` — the divergence `golden.zig` records beside the
    // fixture.
    try expectFrameError(error.ContentSizeMismatch, &golden.frame_fcs_max);
}

test "the descriptor corners decode as the CLI does" {
    // RFC 8878 §3.1.1.1.1.1 — every FCS form, and §3.1.1.1.1.2's
    // single-segment Window_Size = Frame_Content_Size. The CLI decodes each
    // of these byte-exact.
    const run = [_]u8{'A'} ** 300;
    try expectFrame(&golden.frame_fcs1, "01234567");
    try expectFrame(&golden.frame_fcs2, &run);
    try expectFrame(&golden.frame_fcs2_single_segment, &run);
    try expectFrame(&golden.frame_fcs4, "01234567");
    try expectFrame(&golden.frame_fcs8, "01234567");
    // §3.1.1.1.1.3 — the unused bit is accepted (the CLI exits 0 on it).
    try expectFrame(&golden.frame_unused_bit, "abcd");
    // §3.1.1.1.1.4 + §3.1.1.1.3 — the reserved bit and the dictionary ID
    // (the CLI exits 1 on both).
    try expectFrameError(error.ReservedBitSet, &golden.frame_reserved_bit);
    try expectFrameError(error.DictionaryRequired, &golden.frame_dictionary_id);
    try expectFrameError(error.DictionaryRequired, &golden.frame_dictionary_id_wide);
    try expectFrameError(error.Truncated, &golden.frame_dictionary_id_truncated);
    // §3.1.1.2.4's window/block coupling (T7): a single-segment frame's
    // Window_Size is its FCS, so a block larger than it is `BlockOversize`
    // ("Src size is incorrect" to the C).
    try expectFrameError(error.BlockOversize, &golden.frame_single_segment_oversize);
}
