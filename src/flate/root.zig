//! Raw DEFLATE (RFC 1951) codec. Imports only `std` and `fastmem`. Exposed as
//! its own build module (`flate`) and re-exported by the zcompress umbrella
//! module: a full inflate (stored, fixed, and dynamic blocks) and the fast
//! fixed-Huffman encoder over caller-owned buffers, zero heap allocation. The
//! streaming `Io` layer is a later lane.
//!
//! Format: docs/research/specs/rfc1951-deflate.txt
//! API and design: src/flate/README.md

const std = @import("std");

const encode = @import("encode.zig");
/// Worst-case compressed size for `input_len` bytes
/// (`input_len + 5 * ceil(input_len / 65535) + 2`). Size `target` to this
/// before `compress`.
pub const maxCompressedLength = encode.maxCompressedLength;
/// Compress `source` as one raw deflate stream into `target`. Returns bytes
/// written; `error.BufferTooSmall` when `target` is too small — size it via
/// `maxCompressedLength`. Zero heap allocation.
pub const compress = encode.compress;
/// The encoder's block size: 65535, the stored-block LEN cap
/// (RFC 1951 §3.2.4). `compress` splits at it; the streaming Writer emits
/// blocks at it.
pub const max_block_size = encode.max_block_size;
/// The format's maximum backward match reach: 32768 (RFC 1951 §3.2.5).
pub const history_len = encode.history_len;

const decode = @import("decode.zig");
/// Every decode failure, in detail (README.md, "API"): the specific error for
/// a malformed block, tree, code, stored block, or distance, `Truncated` when
/// the input ends before the final block, and `BufferTooSmall` when `target`
/// cannot hold the output.
pub const DecompressError = decode.DecompressError;
/// Decompress one raw deflate stream from `source` into `target`, which is a
/// cap: returns the decoded length, or `error.BufferTooSmall`. Zero heap
/// allocation. There is no decompressed-length helper — a raw deflate stream
/// declares no decoded length anywhere. Bytes after the final block are
/// ignored (BFINAL self-delimits the stream).
pub const decompress = decode.decompress;

test {
    _ = encode;
    _ = decode;
    _ = @import("golden.zig");
    std.testing.refAllDecls(@This());
}
