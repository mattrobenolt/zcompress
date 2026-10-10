//! zcompress: fast, self-contained compression codecs in pure Zig.
//!
//! ONE module; each codec is a namespace under it. Codecs import only `std`
//! and `fastmem` (plus the codec-agnostic `src/internal/` shares, by
//! relative import) and lift out of the repo with their directory plus
//! `src/internal/` in tow (docs/zcompress-plan.md, "Architecture").

const std = @import("std");

/// Raw DEFLATE (RFC 1951) codec. Full inflate over caller-owned buffers,
/// zero heap allocation. API and design: `src/flate/README.md`; format:
/// docs/research/specs/rfc1951-deflate.txt.
pub const flate = @import("flate/root.zig");
/// gzip (RFC 1952) container over the flate module: the member framing, the
/// CRC-32 trailer, and the `std.Io` streaming layer. API and design:
/// `src/gzip/README.md`; format: docs/research/specs/rfc1952-gzip.txt.
pub const gzip = @import("gzip/root.zig");
/// Raw-block Snappy codec. Block functions over caller-owned buffers, zero
/// heap allocation. API and design: `src/snappy/README.md`; format:
/// docs/research/specs/snappy-format-description.txt.
pub const snappy = @import("snappy/root.zig");

test {
    _ = flate;
    _ = snappy;
    _ = gzip;
    // The consumer surface, named the way a consumer names it: four names
    // per codec namespace, nothing flat at the root (AGENTS.md, "Rules").
    _ = flate.encode.Level;
    _ = flate.decode.decompress;
    _ = flate.Reader.streamAll;
    _ = flate.Writer.streamAll;
    _ = gzip.encode.Level;
    _ = gzip.decode.decompress;
    _ = gzip.Reader.streamAll;
    _ = gzip.Writer.streamAll;
    _ = snappy.encode.compressBlock;
    _ = snappy.decode.decompressBlock;
    _ = snappy.Reader.streamAll;
    _ = snappy.Writer.streamAll;
    std.testing.refAllDecls(@This());
}
