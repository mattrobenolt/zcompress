//! Raw DEFLATE (RFC 1951) codec. Imports only `std` and `fastmem`. Exposed as
//! its own build module (`flate`) and re-exported by the zcompress umbrella
//! module: a full inflate (stored, fixed, and dynamic blocks) over
//! caller-owned buffers, zero heap allocation. The fast fixed-Huffman encoder
//! and the streaming `Io` layer are later lanes.
//!
//! Format: docs/research/specs/rfc1951-deflate.txt
//! API and design: src/flate/README.md

const std = @import("std");

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
    _ = decode;
    _ = @import("golden.zig");
    std.testing.refAllDecls(@This());
}
