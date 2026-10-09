//! Standalone Snappy block codec. Imports only `std` and `fastmem`.
//!
//! The public surface is four names — everything else composes through
//! their namespaces:
//!
//!   - `snappy.encode` — the block encoder: `encode.compressBlock`,
//!     `encode.maxCompressedLength`, `encode.max_block_size`.
//!   - `snappy.decode` — the block decoder: `decode.decompressBlock`,
//!     `decode.decompressedBlockLength`, `decode.DecompressError`.
//!   - `snappy.Reader` / `snappy.Writer` — the streaming `Io` layer over
//!     the framed stream: `Reader.Buffer`, `Reader.streamAll`,
//!     `Writer.scratch_len`, `finish`, and the interfaces themselves.
//!
//! Contracts live in `README.md` (the module's API document).

const std = @import("std");

pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");
pub const Reader = @import("Reader.zig");
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
