//! gzip (RFC 1952) container over the flate module: the member framing, the
//! CRC-32 trailer, and the `std.Io` streaming layer. Imports `std` and
//! `fastmem`, plus `flate` by relative path (the container-over-codec import
//! the plan sanctions); no heap allocation on any codec path. The
//! `zcompress.gzip` namespace of the zcompress module.
//!
//! The public surface is four namespaces — everything else composes through
//! them: `gzip.encode` (one-shot encode), `gzip.decode` (one-shot decode),
//! `gzip.Writer` (streaming encode), `gzip.Reader` (streaming decode).
//! Contracts: README.md; format: docs/research/specs/rfc1952-gzip.txt.

const std = @import("std");

pub const encode = @import("encode.zig");
pub const decode = @import("decode.zig");
/// A decompressing `Io.Reader` over one gzip member (README.md,
/// "Streaming"). Consume through `&r.reader`; ends cleanly with
/// `error.EndOfStream` once the trailer is verified, details in `r.err`.
/// Zero heap allocation; the caller provides `Reader.Buffer`.
pub const Reader = @import("Reader.zig");
/// A compressing `Io.Writer` producing one gzip member (README.md,
/// "Streaming"). Write through `&w.writer`; complete the member with
/// `finish`. Zero heap allocation; the caller provides `Writer.Buffer`.
pub const Writer = @import("Writer.zig");

test {
    _ = encode;
    _ = decode;
    _ = Writer;
    _ = Reader;
    _ = @import("crc32.zig");
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    std.testing.refAllDecls(@This());
}
