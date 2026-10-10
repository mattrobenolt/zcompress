//! The checksum hook: the byte-moving interface flate's streaming funnels
//! hand a container's checksum state to (README.md, "Checksum hook"), so a
//! container's checksum rides the codec boundary — every payload byte folded
//! exactly once, in stream order, with no container buffer, no second copy,
//! and no second pass over the data.
//!
//! Checksum-agnostic by construction: the container owns the state and the
//! arithmetic (gzip's CRC-32, zlib's Adler-32), the codec only hands it
//! contiguous payload runs. The codec holds one optional two-word hook per
//! streaming layer — null in the raw module's use — and no checksum state of
//! its own; the container reads its own state at the clean end and owns any
//! trailer. Nothing here allocates.
//!
//! The interface lives with flate, not in `src/internal/`, because it is
//! flate's funnel contract that the containers consume through flate — the
//! same placement as the container-shared buffer types (`Writer.Buffer`,
//! `Reader.Buffer`). A second *codec* needing it moves it to `internal/`;
//! `src/internal/checksum.zig` is reserved for the shared checksum kernels
//! (`src/gzip/README.md`, "The checksums").

pub const Checksum = @This();

/// The container's checksum state, untyped: the codec never inspects it and
/// never allocates for it. The container guarantees it outlives the codec
/// layer holding the hook.
context: *anyopaque,
/// Fold one contiguous run of payload into the state. Runs arrive in stream
/// order, each byte exactly once, and are never empty. Must not allocate.
update_fn: *const fn (context: *anyopaque, bytes: []const u8) void,

/// Fold `bytes` into the container's state.
pub fn update(checksum: Checksum, bytes: []const u8) void {
    checksum.update_fn(checksum.context, bytes);
}
