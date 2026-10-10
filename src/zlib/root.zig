//! zlib (RFC 1950) container over the flate module: the 2-byte header, the
//! Adler-32 trailer, and the `std.Io` streaming layer. Imports `std` and
//! `fastmem`, plus `flate` by relative path (the container-over-codec import
//! the plan sanctions); no heap allocation on any codec path. The
//! `zcompress.zlib` namespace of the zcompress module.
//!
//! The public surface is four namespaces — everything else composes through
//! them: `zlib.encode` (one-shot encode), `zlib.decode` (one-shot decode),
//! `zlib.Writer` (streaming encode), `zlib.Reader` (streaming decode).
//! Contracts: README.md; format: docs/research/specs/rfc1950-zlib.txt.

const std = @import("std");

pub const encode = @import("encode.zig");
pub const decode = @import("decode.zig");
/// A decompressing `Io.Reader` over one zlib stream (README.md,
/// "Streaming"). Consume through `&r.reader`; ends cleanly with
/// `error.EndOfStream` once the trailer is verified, details in `r.err`.
/// Zero heap allocation; the caller provides `Reader.Buffer`.
pub const Reader = @import("Reader.zig");
/// A compressing `Io.Writer` producing one zlib stream (README.md,
/// "Streaming"). Write through `&w.writer`; complete the stream with
/// `finish`. Zero heap allocation; the caller provides `Writer.Buffer`.
pub const Writer = @import("Writer.zig");

test {
    _ = encode;
    _ = decode;
    _ = Writer;
    _ = Reader;
    _ = @import("adler32.zig");
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    std.testing.refAllDecls(@This());
}
