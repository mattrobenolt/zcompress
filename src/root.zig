//! zcompress: fast, self-contained compression codecs in pure Zig.
//!
//! One module per codec, each importing only `std` and building alone
//! (docs/zcompress-plan.md). This umbrella module re-exports them.

const std = @import("std");

/// Raw-block Snappy codec. Block functions over caller-owned buffers, zero
/// heap allocation. API and design: `src/snappy/README.md`; format:
/// docs/research/specs/snappy-format-description.txt.
pub const snappy = @import("snappy");

test {
    _ = snappy;
    std.testing.refAllDecls(@This());
}
