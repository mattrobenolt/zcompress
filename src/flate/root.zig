//! Raw DEFLATE (RFC 1951) codec. Imports only `std` and `fastmem`. The
//! `zcompress.flate` namespace of the zcompress module: a full inflate
//! (stored, fixed, and dynamic blocks), the fast fixed-Huffman encoder, and
//! the streaming `Io` layer (`Reader`/`Writer`) over raw deflate —
//! caller-owned buffers, zero heap allocation, end to end.
//!
//! The public surface is four names — everything else composes through
//! their namespaces: `encode.compress`, `encode.maxCompressedLength`,
//! `decode.decompress`, `decode.DecompressError`, `Reader.Buffer`,
//! `Reader.streamAll`, `Writer.finish`. Contracts: README.md.
//!
//! Format: docs/research/specs/rfc1951-deflate.txt

const std = @import("std");

pub const encode = @import("encode.zig");
pub const decode = @import("decode.zig");
/// A decompressing `Io.Reader` over a raw deflate stream (README.md,
/// "Streaming"). Consume through `&r.reader`; ends cleanly with
/// `error.EndOfStream` once the final block's output is consumed. Zero heap
/// allocation; the caller provides `Reader.Buffer`.
pub const Reader = @import("Reader.zig");
/// A compressing `Io.Writer` over a raw deflate stream (README.md,
/// "Streaming"). Write through `&w.writer`; complete the stream with
/// `finish`. Zero heap allocation; the caller provides `Writer.Buffer`.
pub const Writer = @import("Writer.zig");

test {
    _ = encode;
    _ = decode;
    _ = Writer;
    _ = Reader;
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    std.testing.refAllDecls(@This());
}
