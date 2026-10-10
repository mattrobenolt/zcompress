# zlib

A zlib container (RFC 1950) over the flate module: the 2-byte header, the
Adler-32 trailer, and the `std.Io` streaming layer. Imports `std` and
`fastmem`, plus `flate` by relative path (the container-over-codec import the
plan sanctions); no heap allocation on any codec path. The `zcompress.zlib`
namespace of the zcompress module.

The codec is flate's (RFC 1951, `src/flate/`); this module is framing and
checksums — a 2-byte header, an optional DICTID the decoder refuses, a 4-byte
trailer, and the Adler-32 that rides along the bytes the codec already moves.
The format is [RFC 1950][rfc1950], vendored verbatim at
`docs/research/specs/rfc1950-zlib.txt`. The research stage — the requirements
matrix, the checksum survey, the reference-lineage divergence rows, and the
wrapping-design questions (OQ1-OQ7) this document decides — is
`docs/research/containers-notes.md` (cited below as `containers-notes.md`).

**The wrapping design is stated once, in `src/gzip/README.md`** ("The
wrapping design"): one stream per reader with the exact boundary visible to
the caller, no container buffers (the real memory is flate's `Writer.Buffer`
and `Reader.Buffer`, re-exported here under this module's names), hashing at
the codec boundary so every byte is hashed exactly once with no copy and no
second pass, deterministic emitted headers, and the fail-closed posture. This
module shares all of it; what differs is below — the header arithmetic, the
checksum, the dictionary refusal, and the absence of a size field.

Two zlib-specific decisions:

- **FDICT is rejected, never skipped** (OQ4/ZD4). RFC 1950's compliance
  section makes rejecting a dictionary stream conformant when the embedding
  format has no dictionary registry: "When the other format does not use the
  preset dictionary feature, a compliant decompressor must reject any stream
  in which the FDICT flag is set" (`rfc1950-zlib.txt §2.3`). Real zlib does
  emit such streams when handed a dictionary (the oracle: `compressobj(6,
  DEFLATED, 15, 9, Z_DEFAULT_STRATEGY, dict)` → header `78 bb` + the
  dictionary's big-endian Adler-32, `containers-notes.md §5.5`), and Go's
  nil-dictionary reader rejects every one of them (`reader.go:164`,
  `ErrDictionary`) — ours fails with the specific `DictionaryRequired`,
  before any body byte is decoded: never a silent skip of the four DICTID
  bytes, and never std's misparse of them as deflate data (T6). Preset
  dictionaries stay out of scope until flate's own dictionary entry point
  lands (flate's OQ6 deferral; flate README). The encoder never sets FDICT
  (`§2.3`: a compressor "need not support preset dictionaries at all").
- **The trailer checksum is a decoder MUST here.** `§2.3`: "A compliant
  decompressor must check CMF, FLG, and ADLER32, and provide an error
  indication if any of these have incorrect values." RFC 1950's `§5`
  Security Considerations repeats the stakes: "A decoder that fails to check
  the ADLER32 checksum value may be subject to undetected data corruption."
  std checks neither CMF's FCHECK nor the trailer (T6, T4); this module
  checks all three.

## API

The public surface is four namespaces — everything else composes through
them: `zlib.encode` (one-shot encode), `zlib.decode` (one-shot decode),
`zlib.Writer` (streaming encode), `zlib.Reader` (streaming decode).

```zig
const zlib = @import("zcompress").zlib;

// The one-shot encoder (zlib.encode):
zlib.encode.Level = flate.encode.Level   // the flate level type, re-exported
zlib.encode.Options = struct { level: flate.encode.Level = .fast };
zlib.encode.maxCompressedLength(input_len) usize
        // 2 + flate.encode.maxCompressedLength(input_len) + 4: the fixed
        // header, the worst-case deflate body, the fixed trailer (§2.2).
zlib.encode.compress(source, target, options)
    error{BufferTooSmall, Unimplemented}!usize
        // One complete stream into `target`; returns its length. `.ratio`
        // is flate's unimplemented seat: `error.Unimplemented`, never
        // silent aliasing.

// The one-shot decoder (zlib.decode):
zlib.decode.decompress(source, target) DecompressError!usize
        // `target` is a cap; returns the decoded length. The stream is
        // located by exact consumption (see "Contracts").
zlib.decode.DecompressError = flate.decode.DecompressError || error{
    BadHeader,           // CM != 8, CINFO > 7, or FCHECK (§2.2, §2.3)
    DictionaryRequired,  // FDICT set: no preset-dictionary support (§2.3)
    WrongChecksum,       // ADLER32 mismatch (§2.2, §2.3)
};

// The streaming Io layer. Writer.Buffer / Reader.Buffer are flate's buffer
// types, re-exported: the container adds none (OQ5).
zlib.Writer.Buffer = flate.Writer.Buffer;  // 98,303 bytes: block + history
zlib.Reader.Buffer = flate.Reader.Buffer;  // 65,536 bytes: the window
var w: zlib.Writer = .init(out, &wbuf, .{}); // wbuf: zlib.Writer.Buffer
try w.writer.writeAll(bytes);                // through the Io.Writer interface
try w.writer.flush();                        // mid-stream: partial block out
try w.finish();                              // trailer, terminal, poison
var r: zlib.Reader = .init(in, &rbuf);       // rbuf: zlib.Reader.Buffer
// consume through &r.reader (stream, read-family, peek-family); ends with
// error.EndOfStream once the trailer is verified, details in r.err.
zlib.Reader.Error = flate.Reader.Error || error{
    BadHeader, DictionaryRequired, WrongChecksum,
};
        // The detail recorded in `err` beside the interface's coarse
        // error.ReadFailed / error.EndOfStream. No BufferTooSmall here:
        // the window is the caller's, and flate owns it.

// The one-call conveniences: stack-buffered end-to-end, zero allocation.
zlib.Writer.streamAll(in, out, options) error{ReadFailed, WriteFailed}!usize
zlib.Reader.streamAll(in, out) error{ReadFailed, WriteFailed}!usize
```

Caller-owned buffer types (exact pointers at init; both are flate's, named
here for a self-contained surface):

- `zlib.Reader.Buffer = flate.Reader.Buffer` — `[2 * history_len]u8`, 64 KiB.
- `zlib.Writer.Buffer = flate.Writer.Buffer` — `[max_block_size +
  history_len]u8`, 98303 bytes.

The streaming shape, the pattern-book machinery, the lifecycle, the poison
check, and the contiguity failure are exactly the gzip sibling's
(`src/gzip/README.md`, "Streaming"; `src/internal/README.md`, "The Io codec
pattern book"). Contracts, stated plainly:

- **Ownership**: the caller owns every buffer, on both sides. Nothing is
  allocated, freed, or retained. There is no allocator in the API at all.
- **Sizing**: size `target` for `compress` with
  `maxCompressedLength(input_len)`. A smaller target may still fit when the
  body compresses under the bound; if it does not, the result is
  `error.BufferTooSmall` and `target`'s contents are unspecified.
  `decompress` takes `target` as a cap and returns the decoded length; a
  stream that does not fit is `error.BufferTooSmall`, reported before the
  overflowing write, never a truncated success. **The format carries no
  decoded size** — ADLER32 is the whole trailer — so the caller sizes from
  out-of-band knowledge, or streams.
- **Trailer location**: `decompress` routes the body through the streaming
  reader over `Io.Reader.fixed(source[header_len..])`. The flate reader
  consumes the input exactly through the body's last byte
  (`src/flate/README.md`, "Streaming"), so the fixed reader's position
  afterwards is exactly the ADLER32 — the exact-consumption contract this
  design was built on (OQ2). Bytes after ADLER32 are ignored by the
  one-shot, which is the spec's own boundary: "Any data which may appear
  after ADLER32 are not part of the zlib stream" (`§2.2`); Go's golden table
  pins the same behavior ("excess data silently ignored",
  `containers-notes.md §5.2`). The streaming reader leaves those bytes
  unconsumed, so a caller that wants the boundary sees it.
- **Corruption**: decode fails closed at the first invalid byte — header,
  body (flate's `DecompressError`), or trailer — and no partial output is
  trusted past the error. Every decode test pre-fills the target with
  cycling sentinels and proves the bytes past the decoded length are
  untouched (`src/internal/README.md`, "API").
- **No hidden copies**: every copy goes through `fastmem.copy` /
  `fastmem.move` / `fastmem.set`; there is no `@memcpy`/`@memmove`/`@memset`
  anywhere in this module, tests included. The container itself copies
  nothing: the codec's bytes are hashed and framed in place.
- **Stack**: the one-shot encode runs on flate's one-shot stack (~128 KiB,
  the match-finder table); the one-shot decode carries the streaming
  reader's 64-KiB window on its stack (the fixed-reader route); each
  streamed block runs on flate's ~192 KiB. Add a few bytes for the
  header/trailer scratch. Size thread stacks accordingly when embedding.
- **Allocation**: zero, end to end. The one-shot functions take no
  allocator; `Reader`/`Writer` take none either (caller-provided buffers
  through the named buffer types).

## The stream format

```text
zlib stream :=
  +---+---+                                   2 bytes             §2.2
  |CMF|FLG|
  +---+---+
  (FLG.FDICT)    DICTID u32-be, Adler-32 of the dictionary   §2.2
  deflate body   raw DEFLATE, RFC 1951 — the flate module
  +---+---+---+---+
  |    ADLER32    |   4 bytes, u32 big-endian                 §2.1, §2.2
  +---+---+---+---+
```

The header (`§2.2`): CMF's low four bits are CM (8 = "deflate", window up to
32K; 15 reserved), its high four bits CINFO (the base-2 log of the window
size minus eight; "values of CINFO above 7 are not allowed in this version").
FLG's low five bits are FCHECK, bit 5 is FDICT, bits 6-7 are FLEVEL.
FCHECK "must be such that CMF and FLG, when viewed as a 16-bit unsigned
integer stored in MSB order (CMF\*256 + FLG), is a multiple of 31" (`§2.2`).
FDICT, when set, is followed by DICTID, "the Adler-32 checksum" of the
preset dictionary (`§2.2`). FLEVEL is informational: "not needed for
decompression; it is there to indicate if recompression might be worthwhile"
(`§2.2`), and a decompressor "may ignore FLEVEL and still be compliant"
(`§2.3`). The trailer is the Adler-32 of "the uncompressed data (excluding
any dictionary data)", stored "in most-significant-byte first (network)
order" (`§2.2`). The stream ends at ADLER32 (`§2.2`).

**Byte order is the family's trap** (`containers-notes.md` §1.2, ambiguity
4): zlib's multi-byte numbers are MSB-first (`§2.1` — the same 520 example
RFC 1952 writes little-endian), so DICTID, ADLER32, and the FCHECK
arithmetic's CMF/FLG pair read big-endian, while the deflate LEN/NLEN
underneath stay little-endian (`rfc1951-deflate.txt §3.2.4`).

Emitted, deterministically (OQ7):

| field | emitted | why |
|-------|---------|-----|
| CM | 8 | "deflate" (`§2.2`); anything else is `BadHeader` on decode (`§2.3`) |
| CINFO | 7 | a 32-KiB window (`§2.2`); > 7 is invalid (`§2.2`) |
| FDICT | 0 | no preset dictionaries (`§2.3`: a compressor "need not support preset dictionaries at all") |
| FLEVEL | see below | `§2.2`; informational, ignored on decode (`§2.3`) |
| FCHECK | `(31 - r) % 31`, where `r` is the remainder of `CMF*256 + FLG` with FCHECK's five bits zero | `§2.2`; the minimal form |
| ADLER32 | computed | `§2.2`, `§2.3` |

FLEVEL by level, the reference lineage's bands (C zlib's mapping,
oracle-verified in `containers-notes.md §5.5`: {0,1}→0, {2-5}→1, {6,-1}→2,
{7-9}→3): `.@"0"` and `.@"1"` → 0; `.@"2"` through `.@"5"` → 1; `.fast` and
`.@"6"` → 2; `.@"7"` through `.@"9"` → 3. `.ratio` is unimplemented and
emits no stream. The field is informational and the band reports the
requested level; flate's numeric levels all tune to the fast encoder today
(flate README), which its own documentation states.

A conformant decoder's obligations, all enforced here:

- Check CMF, FLG, and ADLER32, with an error indication on incorrect values
  (`§2.3`) — `BadHeader` for the header, `WrongChecksum` for the trailer.
- CM != 8 is `BadHeader`: "another value could indicate the presence of new
  features that would cause subsequent data to be interpreted incorrectly"
  (`§2.3`).
- CINFO > 7 is `BadHeader` on its face (`§2.2`).
- FCHECK is validated as `(CMF*256 + FLG) % 31 == 0` — **never by
  re-deriving the value and comparing** (T5). The references' naive emission
  `31 - r` (no outer modulo) produces FCHECK = 31 in the FDICT + FLEVEL-0
  corner: C zlib emits `78 3f` there (oracle-verified), Go's writer the same
  (`zlib/writer.go:118`). 31 ≡ 0 mod 31 and fits the five-bit field, so it is
  conformant and must be accepted; a re-deriving validator rejects the whole
  Go/C-zlib output family in that corner. Go's bad-FCHECK golden (`78 9f`)
  and std's laxness (it checks neither FCHECK nor FDICT, T6) are the two
  sides this rule is pinned against.
- FDICT set is `DictionaryRequired`, sticky, before any body byte (`§2.3`,
  ZD3/ZD4; see the intro).
- FLEVEL is ignored (`§2.3`).
- A truncated stream — header, body, or trailer — is `error.Truncated`.
  A zero-byte input is `error.Truncated` (the gzip sibling's decision, same
  fail-closed reading; `containers-notes.md` T2/OQ3).
- Accept any deflate body that conforms to RFC 1951 (`§1.4`; `§2.2` — CM=8's
  "deflate" method is the RFC 1951 document) — flate's rules, unchanged.

The reader surfaces no header metadata (there is none beyond the two header
bytes), and the encoder exposes no header knobs: CMF is 0x78, FLG carries
only FLEVEL and FCHECK.

## The checksum

**Adler-32** (`§2.2`, algorithm in `§8.2`, sample in `§9`): two sums mod
65521 — "s1 is the sum of all bytes, s2 is the sum of all s1 values. Both
sums are done modulo 65521. s1 is initialized to 1, s2 to zero. The Adler-32
checksum is stored as s2\*65536 + s1 in most-significant-byte first
(network) order." s1 starts at 1 "to make the length of the sequence part of
s2" (`§8.2`), and 65521 is prime to kill a class of two-byte errors the
Fletcher checksum (255, not prime) misses (`§8.2`). The implementation
shape comes from the same appendix: "The modulo on unsigned long accumulators
can be delayed for 5552 bytes" (`§8.2`) — the deferred-modulo block loop,
not `§9`'s per-byte sample.

What std has, verified by running (`containers-notes.md §3.2`):
`std.hash.Adler32` is the 5552-block deferred-modulo form with a 16-byte
comptime-unrolled inner loop and the `adler: u32 = 1` state — check value
verified: `Adler32("Wikipedia")` = 0x11E60398, the standard check value, and
its "Hello world\n" value matches C zlib's through the oracle. Correct and
in-tree: the day-one kernel.

As in gzip, the kernel is wrapped behind this module's own function boundary
(the libdeflate shape, `adler32(adler, bytes)`), so the kernel is swappable
without touching the containers (`containers-notes.md §3.3`). The M3
performance work landed behind that boundary: the kernel keeps §8.2's
5552-byte deferred-modulo blocks but folds each block with two `@Vector`
accumulators (byte-sum lanes and weight-times-byte lanes, reduced once per
block) instead of the per-byte `s1 += b; s2 += s1` chain — ~0.10 ns/byte
against std's scalar ~0.32 ns/byte on the dev box, local numbers only, with
std's `Adler32` kept as the test oracle. The kernel file lives in this codec
directory (`src/internal/checksum.zig` waits for a second user — Adler-32's
only user is zlib). Hashing happens exactly once per byte, where bytes cross the flate
boundary (OQ1; `src/gzip/README.md`, "The checksums"): blocks on encode,
window fills on decode, `source` directly on the one-shot encode.

## Streaming

`zlib.Writer` / `zlib.Reader` are the gzip sibling's shape over one zlib
stream: the pattern book's machinery, the caller's flate buffers, the lazy
header (2 bytes, written before the first compressed byte), the trailer at
`finish`, the terminal poison, the contiguity cap, and the sticky lifecycle
(`src/gzip/README.md`, "Streaming"; `src/internal/README.md`, "The Io codec
pattern book"). What differs:

- The reader consumes `input` exactly through ADLER32's last byte and stops;
  bytes after it are "not part of the zlib stream" (`§2.2`) and stay
  unconsumed. Concatenated zlib streams are not a spec feature (unlike gzip's
  members): a caller can loop at the boundary the exact consumption exposes,
  but nothing in the format promises a second stream follows, and garbage
  there is that caller's problem — this reader never silently skips it.
- At the body's clean end the reader reads and verifies ADLER32 exactly once,
  and only then reports `error.EndOfStream` (sticky). A mismatch is
  `error.ReadFailed` with `err == .WrongChecksum`; a truncated trailer is
  `err == .Truncated`. A caller that stops before the end never sees the
  check.
- `Reader.Error` is `flate.Reader.Error || error{BadHeader,
  DictionaryRequired, WrongChecksum}` — the flate decode detail set (minus
  `BufferTooSmall`, since the window is the caller's and flate owns it) plus
  this module's entries, recorded in `err` beside the interface's coarse
  `error.ReadFailed` / `error.EndOfStream`.
- `zlib.Writer.init(..., .{ .level = .ratio })` poisons the interface
  (writes and `finish` report `error.WriteFailed`), and `Writer.streamAll`
  returns `error.ReadFailed` upfront — flate's reserved-seat behavior.

Files (the intended layout; the implementation lanes may split further):
`root.zig` (public surface), `encode.zig` (stream emission), `decode.zig`
(the header parse and trailer check, shared by both layers), `Writer.zig` +
`Reader.zig` (the streaming `Io` layer), `adler32.zig` (the checksum kernel
boundary), `golden.zig` (ported golden fixtures, shared by every layer's
tests), `common.zig` (big-endian integer access), `bench.zig` (local
benchmark), `fuzz.zig` (fuzz targets).

An example CLI (`examples/zlib.zig`, `zig build example-zlib -- encode
README.md > out`) is a thin streaming pump over this surface, the same shape
as snappy's and flate's.

## Testing & golden vectors

The conformance bar, the porting discipline, the sentinel overrun rule, and
the fuzz lane are the gzip sibling's (`src/gzip/README.md`, "Testing & golden
vectors"; `src/internal/README.md`). The zlib-specific inventory
(`containers-notes.md §5`):

- **golang/go `src/compress/zlib/reader_test.go` `zlibTests` (11 vectors)** —
  the primary zlib conformance table, whose own comment says the golden
  bytes came from the C reference's `zpipe.c`: truncated empty / truncated
  dict / truncated checksum → `error.Truncated`; the empty stream
  (`78 9c 03 00 00 00 00 01`); "goodbye, world"; bad CINFO (`88 98`) →
  `BadHeader`; **bad FCHECK (`78 9f`) → `BadHeader`**; bad checksum →
  `WrongChecksum`; not-enough-data; **excess data silently ignored** (ZD7's
  boundary); the **dictionary** vector (`78 bb` + DICTID + a
  dict-compressed body) and the **wrong dictionary** vector → both
  `DictionaryRequired` here (one error name covers "no dictionary" and
  "wrong dictionary", as Go's `ErrDictionary` does).
- **The T5 corner**: a `78 3f`-headed stream (FCHECK=31, C zlib's
  FDICT+FLEVEL-0 emission) must pass FCHECK validation and land on
  `DictionaryRequired`, never `BadHeader` — the vector that proves the check
  is `% 31`, not re-derivation.
- **Zig 0.16 std's in-tree zlib tests** (MIT): the stored, fixed, and
  dynamic "Hello world\n" streams, **"zlib should not overshoot"** (the
  exact-consumption case: four bytes after the trailer stay unconsumed), the
  bad-CM, bad-CINFO, truncated-header, and truncated-checksum failures — and
  the divergence pins: std accepts `78 9f` (no FCHECK check) and misparses
  FDICT streams' DICTID as deflate data (T6).
- **The local oracle** (`containers-notes.md §5.5`, every line run and
  round-tripped): python3's `zlib` as a CLI — `zlib.compress(data, level)`
  and `zlib.decompress(zw)` for the one-shot lanes, `decompressobj(15)` with
  `unused_data` for the boundary, the FDICT emission and its two failure
  cases, and the FLEVEL/FCHECK emissions (`78 9c` at level 6, `78 3f` in the
  dict + FLEVEL-0 corner) pinned in tests. Levels {0, -2, 1, 6, 9} in both
  directions over the committed corpus. There is no zlib CLI on PATH
  (`zlib-flate` checked and absent, `containers-notes.md §5.5`), so the
  oracle is this module's reference lane; the gzip CLI lane belongs to the
  gzip sibling, and the flate module's `oracle.zig` harness is the precedent
  for wiring an oracle lane into `just`.
- **Fuzz**: decode, corrupt-input, and round-trip targets over the golden
  corpus — the header parse (2 bytes, CM/CINFO/FCHECK/FDICT) and the
  truncated-trailer path are the first targets. Fuzz-target creation is the
  fuzz-engineer's lane.

Run everything with `zig build test` / `just test` (the ztest plain-text
runner).

## Benchmarks

`zig build bench -Doptimize=ReleaseFast` (Go-style, via
[mattrobenolt/zig-benchmark][zigbench]) over the committed, fixed, hashed
corpus; local numbers are never quoted as claims, and a claim names a fleet
run directory and a results file under `docs/results/`. The row set, the
container-overhead isolation (paired raw-flate rows), and the streaming
direction via the example pump are the gzip sibling's
(`src/gzip/README.md`, "Benchmarks"). The story is the same: the flate core
dominates; the framing (2 + 4 bytes per stream) must be noise; what shows in
a zlib number is the Adler-32 pass, which is cheaper than gzip's CRC-32.

Competitors: klauspost/compress's `zlib`, `std.compress.flate`'s
`Compress`/`Decompress` with `container = .zlib` (the in-tree baseline: it
checks neither FCHECK nor the trailer, T6/T4, and pays std's scalar
checksums), and the native pair — libdeflate (whole-buffer) and zlib-ng
(streaming; the fastest zlib-format implementation per box, with the
strongest hand-tuned Adler-32 kernels, `containers-notes.md §6.4`).

## Licensing & attribution

This module is original Zig. The **format** is a public specification (RFC
1950, vendored with provenance under `docs/research/specs/`); the expression
here is ours. The reference implementations studied, all attributed in
`THIRD_PARTY.md` (the gzip sibling lists the shared ones):

- **[golang/go][golang]** (`src/compress/zlib`) — BSD-3-Clause. The
  `zlibTests` golden table is ported from here, as are the reference
  behaviors the divergence rows cite.
- **[klauspost/compress][kp]** (`zlib/`) — BSD-3-Clause. The Go stdlib
  container over the klauspost flate engine (diff-verified); the emission
  policy and hash-on-the-boundary lineage.
- **[ebiggers/libdeflate][libdeflate]** (`lib/adler32.c`) — MIT. The
  checksum kernel's function shape, and the whole-buffer competitor whose
  Adler-32 dispatch sets the throughput band.
- **[zlib-ng][zlibng]** (`adler32.c`, `arch/**`) — zlib license. The
  kernel-dispatch landscape behind the M3 performance work.
- **Zig std's `std.compress.flate`** (MIT, in-tree) — the
  container-inside-flate shape; its lax header parse (T6) and unverified
  footer (T4) are studied as divergence pins, never copied.

madler/zlib's emission rules were verified through the python3 oracle, not
read (`containers-notes.md §0`); python3's `zlib` (PSF) is used as a CLI
oracle, nothing vendored.

All upstream licenses are compatible with this repository's MIT license.
The BSD-3-Clause "no endorsement" clause is satisfied by this attribution;
no code was copied verbatim.

[rfc1950]: https://www.rfc-editor.org/rfc/rfc1950.txt
[golang]: https://github.com/golang/go
[kp]: https://github.com/klauspost/compress
[libdeflate]: https://github.com/ebiggers/libdeflate
[zlibng]: https://github.com/zlib-ng/zlib-ng
[zigbench]: https://github.com/mattrobenolt/zig-benchmark
