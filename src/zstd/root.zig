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
//! frame's cross-block state) — and the public surface — `zstd.decode` and
//! `zstd.Reader` — arrives with the frame layer on top.
//! Contracts: README.md (the M4 sketch); format:
//! docs/research/specs/rfc8878-zstd.txt.

const std = @import("std");

const bits = @import("bits.zig");
const block = @import("block.zig");
const common = @import("common.zig");
const fse = @import("fse.zig");
const huff0 = @import("huff0.zig");
const literals = @import("literals.zig");
const sequences = @import("sequences.zig");

test {
    _ = bits;
    _ = block;
    _ = common;
    _ = fse;
    _ = huff0;
    _ = literals;
    _ = sequences;
    _ = @import("golden.zig");
    std.testing.refAllDecls(@This());
}
