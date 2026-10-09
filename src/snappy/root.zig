//! Standalone Snappy block codec (raw block format, no framing). Imports only
//! `std` and `fastmem`. Exposed as its own build module (`snappy`) and
//! re-exported by the zcompress umbrella module: a hash-table match-finder
//! encoder, a SIMD-accelerated decoder, and a streaming `Io` layer
//! (`Reader`/`Writer`) over the package's framed stream format. Block
//! functions over caller-owned buffers, zero heap allocation.
//!
//! Format: docs/research/specs/snappy-format-description.txt
//! (upstream: https://github.com/google/snappy/blob/main/format_description.txt)

const std = @import("std");

const decode = @import("decode.zig");
/// The error set of `decompressedBlockLen` and `decompressBlock`:
/// `BufferTooSmall` (size `out` via `decompressedBlockLen` first) or
/// `DecompressionFailed` (corrupt input).
pub const DecompressError = decode.DecompressError;
/// Decompress a raw snappy block from `input` into `out`. Returns bytes written.
/// `error.BufferTooSmall` when `out` is too small (size via
/// `decompressedBlockLen`); `error.DecompressionFailed` on corrupt input.
/// Zero heap allocation.
pub const decompressBlock = decode.decompressBlock;
/// Decompressed byte length of a raw snappy block (the leading varint).
pub const decompressedBlockLen = decode.decompressedBlockLen;
const encode = @import("encode.zig");
/// Worst-case raw-block compressed size for `input_len` bytes (varint length
/// prefix + literal blowup bound). Size `out` to this before `compressBlock`.
pub const maxCompressedLength = encode.maxCompressedLength;
/// Maximum raw-block size (65536). Snappy positions are stored as `u16`;
/// `compressBlock` asserts `src.len <= max_block_size`. Larger inputs are
/// split into blocks by the caller's framing layer.
pub const max_block_size = encode.max_block_size;
/// Compress `src` into `out` as a raw snappy block. Returns bytes written.
/// `error.BufferTooSmall` when `out` is too small — size it via
/// `maxCompressedLength`. Zero heap allocation.
pub const compressBlock = encode.compressBlock;
/// A compressing `Io.Writer` over the framed snappy stream
/// (README.md, "Streaming"). Write through `&w.writer`; complete with
/// `finish`. Zero heap allocation.
pub const Writer = @import("Writer.zig").Writer;
/// The caller-provided uncompressed accumulation buffer for `Writer`: one
/// full block.
pub const WriterBuffer = @import("Writer.zig").Buffer;
/// A decompressing `Io.Reader` over the framed snappy stream
/// (README.md, "Streaming"). Consume through `&r.reader`; ends cleanly with
/// `error.EndOfStream`. Zero heap allocation.
pub const Reader = @import("Reader.zig").Reader;
/// The caller-provided buffer for `Reader`: two decoded blocks of contiguity
/// plus the compressed-block staging region.
pub const ReaderBuffer = @import("Reader.zig").Buffer;

test {
    _ = encode;
    _ = decode;
    _ = Writer;
    _ = Reader;
    std.testing.refAllDecls(@This());
}
