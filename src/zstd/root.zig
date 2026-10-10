//! zstd (RFC 8878): a decoder in pure Zig — the frame layer, the block
//! layer, the literals (huff0) and sequences (FSE) entropy layers, the
//! XXH64 frame checksum, and the `std.Io` streaming layer. Imports only
//! `std` and `fastmem`; no heap allocation on any decode path. The
//! `zcompress.zstd` namespace of the zcompress module.
//!
//! M4 is decoder-first and lands in slices: the entropy kernels are here
//! first (`fse.zig`, `huff0.zig`, with `bits.zig` carrying the two
//! bitstream readers they share), then the sections that compose them —
//! the literals section (`literals.zig`) and the sequences section
//! (`sequences.zig`, Sequence Execution included) — then the block layer
//! (`block.zig`: the Block_Header, the Raw/RLE/Compressed dispatch, and the
//! frame's cross-block state), then the frame layer (`frame.zig`: the
//! magic, the Frame_Header, the block chain, the XXH64 trailer, skippable
//! frames) with the one-shot decoder (`decode.zig`) on top of it, and the
//! streaming frame decoder (`Reader.zig`: one frame per reader at the exact
//! boundary, the caller-owned window buffer, the `streamFrame`/`streamAll`
//! walk). The public surface is `zstd.decode` and `zstd.Reader`; M5 adds
//! `zstd.encode` and `zstd.Writer` (README, the header).
//! Contracts: README.md (the M4 sketch); format:
//! docs/research/specs/rfc8878-zstd.txt.

const std = @import("std");

const bits = @import("bits.zig");
const block = @import("block.zig");
const common = @import("common.zig");
const fse = @import("fse.zig");
const frame = @import("frame.zig");
const huff0 = @import("huff0.zig");
const literals = @import("literals.zig");
const sequences = @import("sequences.zig");
const xxh64 = @import("xxh64.zig");

/// The one-shot decoder: `decompress`, its error set, and the layer types
/// it is built from (`frame`, `block`, `literals`, `sequences`, `fse`, and
/// the `window` arithmetic). API and design: README.md, "API".
pub const decode = @import("decode.zig");

/// The streaming frame decoder: the decompressing `Io.Reader` over one
/// Zstandard frame, the caller-owned window buffer (`Reader.Buffer`), and
/// the `streamFrame`/`streamAll` pumps. API and design: README.md,
/// "Streaming".
pub const Reader = @import("Reader.zig");

test {
    _ = bits;
    _ = block;
    _ = common;
    _ = fse;
    _ = frame;
    _ = huff0;
    _ = literals;
    _ = sequences;
    _ = xxh64;
    _ = decode;
    _ = Reader;
    _ = @import("golden.zig");
    std.testing.refAllDecls(@This());
}
