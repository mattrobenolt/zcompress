# internal

The codec-agnostic layer a zcompress codec may import
(docs/zcompress-plan.md, "Architecture"): it imports only `std` and
`fastmem`, holds no codec-specific state, and travels with a codec that uses
it. Nothing lands here before two codecs need it.

Codec files import it relatively (`@import("../internal/root.zig")`); there
is no `internal` build module, and neither the barrel (`src/root.zig`) nor
the codec namespaces re-export it. A codec lifts out of the repo with
`src/internal/` in tow, wired the same way: a scratch project holding the
codec directory, `src/internal/`, and the fastmem dependency builds and
runs the codec's tests. The scratch project needs a root file above both
directories (the repo's `src/root.zig` is that file): relative imports
cannot escape the module root's directory, so rooting the module at the
codec's own `root.zig` fails with "import of file outside module path".

Two namespaces:

- `internal.sentinel` — the decode-overrun sentinel: the constants, the
  fill, and the check every decode test runs (AGENTS.md, "Rules": "Decode
  never writes past the decoded length; sentinel overrun checks prove it in
  tests").
- `internal.reader` — the reader lifecycle (`State`, `guard`, `fail`) and
  the generated `Io.Reader` vtable entries (`VTable`).

## The Io codec pattern book

The `std.Io.Reader`/`std.Io.Writer` vtable contracts a codec discovers the
hard way, one entry per bug class. Snappy and flate are the worked examples;
a new codec's README-first sketch cites the entries it adopts (the
gzip/zlib/zstd/lzw streaming lanes start here).

`std/...` citations are files under the flake's Zig 0.16.0 standard library:
`/nix/store/amh3bnymjncd56jwmd2hqdkciz9d7pys-zig-0.16.0/lib/zig/`.

### Fill and return 0, never the bytes-added count

Contract: an entry that stores decoded bytes in `reader.buffer` (adjusting
`seek`/`end`) returns 0, never the number of bytes stored. The count is the
bytes the entry served to the caller's writer, and the interface advances
its logical position by that count; returning the stored count serves the
same bytes twice.

- std: `std/Io/Reader.zig:26-28` ("The number returned, including zero, does
  not indicate end of stream"), `std/Io/Reader.zig:43-44` ("the
  implementation may choose to store data in `buffer`, modifying `seek` and
  `end` accordingly").
- Worked examples: snappy `Reader.fillNextBlock` and flate
  `Reader.fillWindow` return a count to their pumps, and the generated
  entries discard it (`_ = try pump(host); return 0;`,
  `src/internal/reader.zig`). The random consumer-machinery drivers in both
  `Reader.zig`s pin the count contract across peek/take/discardAll/
  readSliceAll/stream mixes.

### The zero-length poll answers 0 without filling

Contract: `std.Io.Reader.stream` slices the buffered region by `limit`; a
zero limit leaves that slice empty, so the original limit (0) reaches
`vtable.stream` even when bytes are buffered. The entry answers 0 without
filling: a fill can fail `StreamTooLong` on a valid stream whose serving
region cannot hold a fresh block beside unconsumed bytes.

- std: `std/Io/Reader.zig:168-177` — `limit.slice(r.buffer[r.seek..r.end])`
  empty → `r.vtable.stream(r, w, limit)` with the original limit.
- Caught: the identical bug in both readers. Flate fixed first (8057598,
  R2), snappy separately (5c5eb16) — the duplication this layer exists to
  remove. The generated `stream` entry owns the check; both readers keep "a
  zero-length stream poll does not fail the stream" tests.

### Sticky lifecycle: clean end, sticky failure, detail in `err`

Contract: the interface error set carries two coarse values
(`error.ReadFailed`, `error.EndOfStream`); the detail is recorded in the
codec's `err` field, set once and never cleared. Every vtable entry opens
with the sticky guard: `failed` reports `error.ReadFailed`, `done` reports
`error.EndOfStream`. `done` is set only when the input ends cleanly at a
stream boundary. A failed reader may drop or keep its already-buffered
decoded bytes (flate drops — no partial output past the error; snappy keeps
them, and `std.Io.Reader.stream` serves buffered bytes before consulting the
vtable), but the state never returns to `streaming`.

- std: `std/Io/Reader.zig:111-116` (the error set: "See the `Reader`
  implementation for detailed diagnostics").
- Evidence: the `done: bool` + `err` pair became `State` + shared guard as
  the Tiger-style reference pattern (972925d); the golden suites assert
  stickiness in both readers ("The failure is sticky"); the poll test
  asserts a poll leaves `err == null` on a valid stream (8057598).

### Rebase emits, never discards (writers)

Contract: `rebase` is where a full buffer's bytes go when a consumer asks
for a direct writable slice (`writableSliceGreedy`) into the buffer. It
emits everything buffered beyond the preserved tail, then slides the
preserved bytes to the front. Discarding instead silently drops input, and
`writeAll`-based tests never touch the direct-slice path.

- std: `std/Io/Writer.zig:82-88` (rebase: "The most recent `preserve` bytes
  must remain buffered"), `std/Io/Writer.zig:397-418`
  (`writableSliceGreedyPreserve` calls `rebase` when the buffer cannot
  satisfy the request).
- Caught: ea2a581 — a 2.19-GB corpus encoded to a stream missing exactly one
  64-KiB block; the `File.Reader` simple-mode stream feeds a writer through
  `writableSliceGreedy` + `advance`. Regression tests: "writableSliceGreedy
  on a full buffer/block emits, never drops" in both `Writer.zig`s.

### Drain tops up before emitting: maximal blocks, not caller chunking

Contract: `drain` runs only when `data` cannot fit in the buffer. It fills
the remaining space from the front of `data` (the last slice repeated
`splat` times), then emits the full block; the caller re-slices and calls
again. Emitting before topping up splits blocks at the caller's write
boundaries instead of the codec's block size.

- std: `std/Io/Writer.zig:21-22` (drain: "A write will only be sent here if
  it could not fit into `buffer`"), `std/Io/Writer.zig:27-28`
  ("`buffer[0..end]` is consumed first, followed by each slice of `data` in
  order"), `std/Io/Writer.zig:183-186` (`writeSplat` calls `drain` only when
  the data does not fit).
- Caught: caeaae9 — `writeAll(40000)` four times emitted 40000-byte blocks
  instead of 65536/65536/28928. Tests: "blocks are maximal and the split
  follows the block size" (flate), "writes past one block split into full
  blocks" (snappy).

### Contiguity fails closed, never asserts on a consumer request

Contract: a consumer (`peek`, `take`, delimiter scans, `fillMore`) can ask
for more contiguous bytes than the codec's buffer can hold at its position.
The request reaches `vtable.rebase` as the capacity; the entry fails closed
with `error.ReadFailed` and `err == .StreamTooLong`. It never asserts: the
request is the consumer's, not a codec bug. std's own `rebase` contract is
an assert; the codecs replace it with a sticky failure.

- std: `std/Io/Reader.zig:89-92` (rebase: "Asserts `capacity` is within
  buffer capacity, or that the stream ends within `capacity` bytes"),
  `std/Io/Reader.zig:1132-1136` (`fillMore` passes `r.end - r.seek + 1`),
  `std/Io/Reader.zig:1402-1409` (the wrapper calls `vtable.rebase` with the
  consumer's capacity).
- Caught: caeaae9 (R1) — snappy's serving region included the staging
  region, so ordinary consumer calls asserted in Debug and segfaulted in
  ReleaseFast; the fix separated the region and made over-capacity requests
  fail closed. The same class survived in snappy's hand-written rebase
  (`assert(capacity <= decoded_region_len)`): a plain `peek` past the
  serving region asserted in Debug (a812b4f; the reproduction test is in
  that commit). The generated `rebase` entry owns the guard; the codec hook
  owns the capacity check. Tests: "a contiguous request past the two-block
  cap fails closed", "a peek past the serving region fails closed"
  (snappy), "a request past the window fails closed with StreamTooLong"
  (flate).

### Poison checks: finish after failure never reports false success

Contract: a codec's `finish` checks that the interface is still the codec's
own vtable before emitting the stream ending, then poisons it
(`Writer.failing`); a failed or finished writer reports `error.WriteFailed`,
never a false success on a truncated stream.

- std: `std/Io/Writer.zig:124-125` (`fixed`: "Writes to `buffer` and returns
  `error.WriteFailed` when it is full"), `std/Io/Writer.zig:140-148`
  (`Writer.failing`, the poisoned-writer precedent),
  `std/Io/Writer.zig:43-45` ("Number of bytes returned may be zero, which
  does not indicate stream end. A subsequent call may return nonzero, or
  signal end of stream via `error.WriteFailed`").
- Caught: caeaae9 — `finish` reported success after a failed write and after
  `finish`; the fix is the vtable check plus the `defer w.writer = .failing`
  poison. Tests: "a failed or finished writer never reports a false success"
  in both `Writer.zig`s.

## API

```zig
// From a codec file under src/<codec>/:
const internal = @import("../internal/root.zig");

// The decode-overrun sentinel: fill, then prove [decoded_len, target.len)
// still holds the cycle.
internal.sentinel.base   // u8: the first sentinel byte
internal.sentinel.len    // u8: the cycle length (37, prime)
internal.sentinel.at(i)  // u8: the sentinel byte at absolute index i
internal.sentinel.fill(target: []u8) void
internal.sentinel.expect(target: []const u8, decoded_len: usize) !void

// The reader lifecycle: the codec owns `state: State` and `err: ?Detail`;
// `fail` runs once, from the entry that discovers the failure.
internal.reader.State = enum { streaming, done, failed };
internal.reader.guard(state: State) ?std.Io.Reader.Error
internal.reader.fail(comptime Detail: type, state: *State, detail: *?Detail, err: Detail) std.Io.Reader.Error

// The generated vtable quartet. Host carries `reader: std.Io.Reader` and
// `state: State`; `pump` fills the serving region and maps failures to the
// interface's error set; `rebase` slides the unconsumed bytes and owns the
// capacity policy.
const vtable = internal.reader.VTable(Host, pump, rebase).vtable;
```

## Testing

`internal` has no test target of its own: the sentinel machinery is test
machinery, and the lifecycle and generated entries run under every reader
test in both codecs. The acceptance test for the generated quartet is the
migration of both readers: snappy (three-block serving region, whole-block
staging) and flate (sliding window, bit reader) each replaced four hand
written entries with `VTable(Host, pump, rebase)`, and the full suite —
including the random consumer-machinery drivers, the golden suites, the
poll tests, and the contiguity tests — passes through the generated
entries. The lift story runs as a scratch project per codec (the codec
directory, `src/internal/`, and a path dependency on fastmem): 48/48 snappy
tests and 84/84 flate tests pass in the scratch projects.

## Licensing

Original. The sentinel range and period match golang/snappy's
`notPresentBase`/`notPresentLen` (THIRD_PARTY.md); the std source is cited,
never copied.
