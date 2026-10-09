//! The shared reader lifecycle and the generated `Io.Reader` vtable entries
//! (README.md, "The Io codec pattern book").
//!
//! The lifecycle: `streaming` until the input ends cleanly at a stream
//! boundary (`done`) or a failure sticks (`failed`, the detail recorded in
//! the codec's `err` field). Every codec reader keeps its own `state` and
//! `err` fields — the detail error set is the codec's — and runs its
//! transitions through the free functions here.
//!
//! The generator builds the `stream`/`discard`/`readVec`/`rebase` entries
//! from a codec's host type, fill function, and rebase function: the
//! zero-length poll, the sticky guard, and the fill-and-return-0 count are
//! structural, not per-codec.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

/// The stream lifecycle: `streaming` until the input ends cleanly at a
/// stream boundary (`done`) or a failure sticks (`failed`, the detail in the
/// codec's `err` field).
pub const State = enum { streaming, done, failed };

/// The sticky guard every vtable entry opens with: a failed reader stays
/// failed, a done reader stays at the clean end, `streaming` reports nothing.
pub fn guard(state: State) ?Io.Reader.Error {
    return switch (state) {
        .failed => error.ReadFailed,
        .done => error.EndOfStream,
        .streaming => null,
    };
}

/// Fail closed, stickily: the state becomes `failed`, the detail is recorded
/// beside it, and the interface's coarse `error.ReadFailed` is returned. The
/// codec's own `fail` wrapper owns any further policy — flate drops its
/// window's unconsumed bytes (no partial output past the error), snappy
/// keeps them.
pub fn fail(comptime Detail: type, state: *State, detail: *?Detail, err: Detail) Io.Reader.Error {
    // `failed` is terminal: a failure is recorded once, by the entry that
    // discovered it.
    assert(state.* == .streaming);
    state.* = .failed;
    detail.* = err;
    return error.ReadFailed;
}

/// The generated `Io.Reader` vtable entries for a codec reader `Host`.
///
/// `Host` carries two fields: `reader: Io.Reader` (the embedded interface)
/// and `state: State` (the lifecycle). `pump` fills the serving region and
/// maps every failure to the interface's error set; its count is ignored,
/// because the data lands in `reader.buffer` (the VTable's store-in-buffer
/// mode, `std/Io/Reader.zig:43`). `rebase` slides the unconsumed bytes to
/// the front and owns the codec's capacity policy.
///
/// The generated entries own the sticky guard, the zero-length poll, the
/// fill-and-return-0 count, and `discard`'s consume-after-fill. Take the
/// entries from the returned namespace:
/// `const vtable = internal.reader.VTable(Reader, pump, rebase).vtable;`
pub fn VTable(
    comptime Host: type,
    comptime pump: fn (*Host) Io.Reader.Error!usize,
    comptime rebase: fn (*Host, usize) Io.Reader.RebaseError!void,
) type {
    return struct {
        fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            _ = w;
            const host: *Host = @alignCast(@fieldParentPtr("reader", r));
            if (guard(host.state)) |err| return err;
            // A zero-length request is a poll: `std.Io.Reader.stream` slices
            // the buffered region by the limit, and a zero limit leaves the
            // slice empty, so the original limit reaches the vtable
            // (`std/Io/Reader.zig:168-177`). Answer 0 without filling — a
            // fill can fail `StreamTooLong` on a valid stream whose serving
            // region cannot hold a fresh block beside unconsumed bytes.
            if (limit == .nothing) return 0;
            _ = try pump(host);
            return 0;
        }

        fn discard(r: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
            const host: *Host = @alignCast(@fieldParentPtr("reader", r));
            if (guard(host.state)) |err| return err;
            _ = try pump(host);
            const n = limit.minInt(r.end - r.seek);
            r.seek += n;
            return n;
        }

        fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
            _ = data;
            const host: *Host = @alignCast(@fieldParentPtr("reader", r));
            if (guard(host.state)) |err| return err;
            _ = try pump(host);
            return 0;
        }

        fn rebaseEntry(r: *Io.Reader, capacity: usize) Io.Reader.RebaseError!void {
            const host: *Host = @alignCast(@fieldParentPtr("reader", r));
            if (guard(host.state)) |err| return err;
            return rebase(host, capacity);
        }

        pub const vtable: Io.Reader.VTable = .{
            .stream = stream,
            .discard = discard,
            .readVec = readVec,
            .rebase = rebaseEntry,
        };
    };
}
