//! The codec-agnostic shares every zcompress codec may import
//! (docs/zcompress-plan.md, "Architecture"): imports only `std` and
//! `fastmem`, holds no codec-specific state, and travels with a codec that
//! uses it. Never re-exported by the barrel (`src/root.zig`) or a codec
//! namespace.
//!
//! Contracts: README.md (the Io codec pattern book).

/// The decode-overrun sentinel: the constants, the fill, and the check every
/// decode test runs (AGENTS.md, "Rules").
pub const sentinel = @import("sentinel.zig");
/// The reader lifecycle (`State`, `guard`, `fail`) and the generated
/// `Io.Reader` vtable entries (`VTable`).
pub const reader = @import("reader.zig");
