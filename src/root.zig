//! zcompress: fast, self-contained compression codecs in pure Zig.
//!
//! One module per codec, each importing only `std` and building alone
//! (docs/zcompress-plan.md). This umbrella module re-exports them.

const std = @import("std");

/// Raw DEFLATE (RFC 1951) codec. Full inflate over caller-owned buffers,
/// zero heap allocation. API and design: `src/flate/README.md`; format:
/// docs/research/specs/rfc1951-deflate.txt.
pub const flate = @import("flate");
/// Raw-block Snappy codec. Block functions over caller-owned buffers, zero
/// heap allocation. API and design: `src/snappy/README.md`; format:
/// docs/research/specs/snappy-format-description.txt.
pub const snappy = @import("snappy");

test {
    _ = flate;
    _ = snappy;
    std.testing.refAllDecls(@This());
}
