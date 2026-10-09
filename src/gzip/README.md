# gzip

A gzip container (RFC 1952) over the flate module: the member framing, the
CRC-32 trailer, and the `std.Io` streaming layer. Imports `std` and
`fastmem`, plus `flate` by relative path (the container-over-codec import the
plan sanctions); no heap allocation on any codec path. The `zcompress.gzip`
namespace of the zcompress module.

The codec is flate's (RFC 1951, `src/flate/`); this module is framing and
checksums — a 10-byte fixed header, the optional-field skip, an 8-byte
trailer, and the CRC-32 that rides along the bytes the codec already moves.
A container lifts out of the repo with `src/internal/` and the flate
directory in tow. The format is [RFC 1952][rfc1952], vendored verbatim at
`docs/research/specs/rfc1952-gzip.txt`. The research stage — the requirements
matrix, the checksum survey, the reference-lineage divergence rows, and the
wrapping-design questions (OQ1-OQ7) this document decides — is
`docs/research/containers-notes.md` (cited below as `containers-notes.md`).

The wrapping design, stated once here (the zlib sibling cross-references this
section):

- **One member per stream** (OQ3). A gzip file is "a series of members ...
  with no additional information before, between, or after them"
  (`rfc1952-gzip.txt §2.2`); the reader handles exactly one. It consumes
  `input` through the member's last trailer byte and stops there — bytes
  after the member are not consumed, not interpreted, never silently
  skipped — so the input position at the clean end is the next member's first
  byte. Multi-member composes outside the reader: a caller loop at that
  boundary, where garbage in a next member's place fails `BadHeader` — fail
  closed at interpretation. (Go's multistream reader fails `ErrHeader` on
  the same input, the gzip CLI warns "trailing garbage ignored" and exits 2,
  CPython tolerates trailing zeros, libdeflate reports the member's end and
  leaves concatenation to the caller — `containers-notes.md §2.5` T2 and
  §4 OQ3 record all four; ours is the libdeflate boundary with the caller
  loop's fail-closed header parse.) A zero-byte input is `error.Truncated`:
  no member began. Go and CPython accept it as a zero-member file, the CLI
  errors — the fail-closed reading, recorded in T2/OQ3.
- **The container owns no buffers** (OQ5). The real memory is flate's:
  `Writer.Buffer` (98,303 bytes) and `Reader.Buffer` (65,536 bytes), whose
  pointers the container hands to its internal flate layer. The container
  re-exports them under its own names and adds nothing of its own — a few
  bytes of header/trailer scratch, comptime-sized on the stack.
- **Hashing rides the codec boundary** (OQ1). The CRC-32 is updated where
  bytes cross the flate boundary — as a block is emitted on encode, as bytes
  enter the window on decode — so every byte is hashed exactly once, with no
  container buffer, no second copy, and no second pass over the data. The
  one-shot encode hashes `source` directly. (The flate module carries the
  optional hook that makes this zero-copy; it is not part of this module's
  surface, and the raw module pays nothing when it is unset.)
- **Deterministic headers** (OQ7). The encoder emits FLG=0 (no optional
  fields), MTIME=0, XFL by level band, OS=255 — no clock, no locale, no
  environment. Decoders accept any OS byte and ignore XFL and MTIME
  (`§2.3.1.2`).
- **Fail closed.** Every malformed header, body, or trailer is a specific
  error; no partial output is trusted past the error.

## API

The public surface is four namespaces — everything else composes through
them: `gzip.encode` (one-shot encode), `gzip.decode` (one-shot decode),
`gzip.Writer` (streaming encode), `gzip.Reader` (streaming decode).

```zig
const gzip = @import("zcompress").gzip;

// The one-shot encoder (gzip.encode):
gzip.encode.Level = flate.encode.Level   // the flate level type, re-exported
gzip.encode.Options = struct { level: flate.encode.Level = .fast };
gzip.encode.maxCompressedLength(input_len) usize
        // 10 + flate.encode.maxCompressedLength(input_len) + 8: the fixed
        // header, the worst-case deflate body, the fixed trailer (§2.3).
gzip.encode.compress(source, target, options)
    error{BufferTooSmall, Unimplemented}!usize
        // One complete member into `target`; returns its length. `.ratio`
        // is flate's unimplemented seat: `error.Unimplemented`, never
        // silent aliasing.

// The one-shot decoder (gzip.decode):
gzip.decode.decompress(source, target) DecompressError!usize
        // `target` is a cap; returns the decoded length. The member is
        // located by exact consumption (see "Contracts").
gzip.decode.DecompressError = flate.decode.DecompressError || error{
    BadHeader,           // ID1/ID2/CM wrong, or a reserved FLG bit (§2.3.1.2)
    HeaderTooLong,       // FNAME/FCOMMENT past the 512-byte cap (T7)
    WrongHeaderChecksum, // FHCRC mismatch (§2.3.1)
    WrongChecksum,       // CRC32 mismatch (§2.3.1)
    WrongSize,           // ISIZE mismatch (§2.3.1)
};

// The streaming Io layer. Writer.Buffer / Reader.Buffer are flate's buffer
// types, re-exported: the container adds none (OQ5).
gzip.Writer.Buffer = flate.Writer.Buffer;  // 98,303 bytes: block + history
gzip.Reader.Buffer = flate.Reader.Buffer;  // 65,536 bytes: the window
var w: gzip.Writer = .init(out, &wbuf, .{}); // wbuf: gzip.Writer.Buffer
try w.writer.writeAll(bytes);                // through the Io.Writer interface
try w.writer.flush();                        // mid-stream: partial block out
try w.finish();                              // trailer, terminal, poison
var r: gzip.Reader = .init(in, &rbuf);       // rbuf: gzip.Reader.Buffer
// consume through &r.reader (stream, read-family, peek-family); ends with
// error.EndOfStream once the trailer is verified, details in r.err.
gzip.Reader.Error = flate.Reader.Error || error{
    BadHeader, HeaderTooLong, WrongHeaderChecksum, WrongChecksum, WrongSize,
};
        // The detail recorded in `err` beside the interface's coarse
        // error.ReadFailed / error.EndOfStream. No BufferTooSmall here:
        // the window is the caller's, and flate owns it.

// The one-call conveniences: stack-buffered end-to-end, zero allocation.
gzip.Writer.streamAll(in, out, options) error{ReadFailed, WriteFailed}!usize
gzip.Reader.streamAll(in, out) error{ReadFailed, WriteFailed}!usize
```

Caller-owned buffer types (exact pointers at init; both are flate's, named
here for a self-contained surface):

- `gzip.Reader.Buffer = flate.Reader.Buffer` — `[2 * history_len]u8`, 64 KiB.
- `gzip.Writer.Buffer = flate.Writer.Buffer` — `[max_block_size +
  history_len]u8`, 98303 bytes.

The streaming `Reader`/`Writer` are the pattern book's shape
(`src/internal/README.md`, "The Io codec pattern book"): the sticky
lifecycle (`State` + the detail in `err`), the count contracts, the
zero-length poll, the poison check on `finish`, and the contiguity failure
run through the internal flate layer's entries, which this module decorates
with the framing — the member boundary and the trailer check. See
"Streaming".

Contracts, stated plainly:

- **Ownership**: the caller owns every buffer, on both sides. Nothing is
  allocated, freed, or retained. There is no allocator in the API at all.
- **Sizing**: size `target` for `compress` with `maxCompressedLength(input_len)`.
  A smaller target may still fit when the body compresses under the bound;
  if it does not, the result is `error.BufferTooSmall` and `target`'s
  contents are unspecified. `decompress` takes `target` as a cap and returns
  the decoded length; a member that does not fit is `error.BufferTooSmall`,
  reported before the overflowing write, never a truncated success. gzip's
  ISIZE cannot size the target for you: it sits in the trailer, after the
  body, and it is the size mod 2^32 (`§2.3.1`), so it is exact only for
  members under 4 GiB. The caller sizes from out-of-band knowledge, or
  streams.
- **Trailer location**: `decompress` routes the body through the streaming
  reader over `Io.Reader.fixed(source[header_len..])`. The flate reader
  consumes the input exactly through the body's last byte
  (`src/flate/README.md`, "Streaming"), so the fixed reader's position
  afterwards is exactly the trailer — the exact-consumption contract this
  design was built on (OQ2). Bytes after the trailer are ignored by the
  one-shot: it reports no consumed count, so a boundary-aware caller uses
  the streaming reader (see the member-boundary note above).
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

## The member format

```text
gzip member :=
  +---+---+---+---+---+---+---+---+---+---+
  |ID1|ID2|CM |FLG|     MTIME     |XFL|OS |  10 fixed bytes     §2.3.1
  +---+---+---+---+---+---+---+---+---+---+
  (FLG.FEXTRA)   XLEN u16-le, then XLEN bytes of subfields      §2.3.1.1
  (FLG.FNAME)    original file name, NUL-terminated, Latin-1    §2.3.1
  (FLG.FCOMMENT) comment, NUL-terminated, Latin-1               §2.3.1
  (FLG.FHCRC)    CRC16 u16-le = low 16 bits of the header CRC32 §2.3.1
  deflate body   raw DEFLATE, RFC 1951 — the flate module
  +---+---+---+---+---+---+---+---+
  |     CRC32     |     ISIZE     |  8 bytes, both u32-le        §2.3.1
  +---+---+---+---+---+---+---+---+
```

The fixed header (`§2.3.1`): ID1 = 0x1f, ID2 = 0x8b; CM = 8 deflate (0-7
reserved); FLG bits FTEXT 0, FHCRC 1, FEXTRA 2, FNAME 3, FCOMMENT 4, 5-7
reserved; MTIME a u32 of Unix seconds, 0 = no timestamp; XFL 2 = maximum
compression, 4 = fastest, informational; OS the `§2.3.1` table's byte (255 =
unknown). Optional fields appear in the order above when their FLG bit is
set: FEXTRA is an XLEN-bounded series of SI1/SI2/LEN subfields
(`§2.3.1.1`); FNAME and FCOMMENT are NUL-terminated Latin-1 strings
(`§2.3.1`); FHCRC is "the two least significant bytes of the CRC32 for all
bytes of the gzip header up to and not including the CRC16" (`§2.3.1`).
All multi-byte numbers are little-endian (`§2.1`). The trailer is the
CRC-32 of the uncompressed data per ISO 3309 and ISIZE, "the size of the
original (uncompressed) input data modulo 2^32" (`§2.3.1`). Members "simply
appear one after another in the file, with no additional information before,
between, or after them" (`§2.2`).

Emitted, deterministically (OQ7):

| field | emitted | why |
|-------|---------|-----|
| ID1, ID2, CM | 0x1f, 0x8b, 8 | required (`§2.3.1.2`) |
| FLG | 0 | no optional fields; reserved bits zero (`§2.3.1.2`) |
| MTIME | 0 | "no time stamp is available" (`§2.3.1`); reproducibility (`containers-notes.md` OQ7, `issue14937_test.go`) |
| XFL | see below | `§2.3.1`; informational |
| OS | 255 | the compliance section's default (`§2.3.1.2`: "255 for OS, 0 for all others"); Go, libdeflate, and CPython emit 255, the gzip CLI and C zlib 3, zlib-ng 19 on Apple — T1 |
| CRC32, ISIZE | computed | `§2.3.1.2` |

XFL by level, following the reference lineage's bands (C zlib and Go,
oracle-verified in `containers-notes.md §5.5`: {0,1}→4, 9→2, else 0): 4 for
the levels that select the fast fixed-Huffman encoder (`.fast` — our own
fastest default, XFL 4 is "compressor used fastest algorithm" — plus
`.@"0"` and `.@"1"`), 0 for `.@"2"` through `.@"8"`, and 2 for `.@"9"`.
`.ratio` is unimplemented and emits no member. The field is informational —
a decoder need not examine it (`§2.3.1.2`) — and the band reports the
requested level; flate's numeric levels all tune to the fast encoder today
(flate README), which its own documentation states.

A conformant decoder's obligations, all enforced here:

- Check ID1, ID2, and CM; error indication otherwise (`§2.3.1.2`) —
  `BadHeader`.
- Error indication if any reserved FLG bit is non-zero, "since such a bit
  could indicate the presence of a new field that would cause subsequent
  data to be interpreted incorrectly" (`§2.3.1.2`) — `BadHeader`.
- Examine FEXTRA/XLEN, FNAME, FCOMMENT, and FHCRC at least enough to skip
  the optional fields (`§2.3.1.2`). The extra field is skipped and hashed
  streaming from the input — never staged, so a 65,535-byte XLEN cannot
  amplify memory (OQ6, T7). FNAME and FCOMMENT are NUL-scanned with a
  512-byte cap (`HeaderTooLong`; Go's house rule, `gunzip.go:145`, T7).
- Verify FHCRC when present (`WrongHeaderChecksum`). RFC 1952 requires only
  that the field be skippable (`§2.3.1.2`); Go verifies, CPython, libdeflate,
  and std skip — our call is verify (T3), one CRC-32 over a few hundred
  header bytes at most.
- Verify CRC32 and ISIZE (`WrongChecksum`, `WrongSize`, kept separate; Go
  collapses both into `ErrChecksum` at `gunzip.go:267`, T4). RFC 1952 makes
  the trailer check optional ("need not examine any other part of the header
  or trailer", `§2.3.1.2`) while RFC 1950 makes zlib's ADLER32 check a MUST
  (`rfc1950-zlib.txt §2.3`); the
  house posture is fail closed, and every reference gzip reader verifies —
  except std, whose `Decompress` reads the footer and never compares it, and
  whose `WrongGzipChecksum`/`WrongGzipSize` errors exist only as
  declarations (T4). This module exceeds RFC 1952's minimum on purpose.
- Accept any deflate body that conforms to RFC 1951 (`§1.4`; `§2.3.1` — CM=8's
  method is "documented elsewhere") — flate's rules, unchanged.
- Accept any OS byte and ignore FTEXT, XFL, and MTIME (`§2.3.1.2`: a
  decompressor "may ignore FTEXT and OS and always produce binary output,
  and still be compliant").
- A truncated member — header, body, or trailer — is `error.Truncated`.

The reader surfaces no header metadata: FNAME/FCOMMENT/MTIME/OS are parsed
only enough to skip and to verify FHCRC. A caller that needs them reads the
header bytes itself; the layout above is the whole contract.

## The checksums

**CRC-32 (ISO 3309).** `§2.3.1` names "the CRC-32 algorithm used in the ISO
3309 standard and in section 8.1.1.6.2 of ITU-T recommendation V.42". The
algorithm, from the RFC's own sample code (`§8`, marked "not part of the
specification per se" by `§1.4`): a reflected bytewise table built from the
polynomial 0xEDB88320, one lookup and one shift per byte, with the
one's-complement pre/post-conditioning inside the update. The same value
computes FHCRC, the low 16 bits over the header bytes (`§2.3.1`).

What std has, verified by running (`containers-notes.md §3.1`):

- `std.hash.crc.Crc32` **is** the gzip CRC-32: `std/hash/crc.zig` aliases
  `Crc32IsoHdlc` (polynomial 0x04C11DB7, reflected input and output,
  initial and xor-output 0xFFFFFFFF — the reflected form whose bytewise
  table constant is 0xEDB88320). Check values verified: `Crc32("123456789")`
  = 0xCBF43926 (the standard check value). It is a comptime table plus a
  per-byte scalar update: correct, scalar, the day-one kernel.
- `std.hash.crc.Crc32Iscsi` is **CRC-32C**, a different polynomial
  (0x1EDC6F41) — the wrong CRC for gzip, and the one-line trap in the same
  file.
- `std.hash.crc.Crc32SmallWithPoly` is a dangling declaration in the 0.16.0
  tree (its `impl` name does not exist); do not reach for it.

This module wraps the kernel behind its own function boundary — the
libdeflate shape, `crc32(crc, bytes)` with the pre/post-conditioning inside
and "return the initial value" for an empty or null input — so the day-one
std kernel is swappable without touching the containers (`containers-notes.md
§3.3`). The M3 performance work (the plan's deferred decision: slice-by-8
tables, then folded-vector/PCLMULQDQ after the `ghash_polyval` study) lands
behind that boundary. The kernel file lives in this codec directory, not
`src/internal/`: CRC-32 has one user in this repo (`containers-notes.md
§3.3` — snappy's framing carries no checksum and zstd uses xxhash, so
`src/internal/checksum.zig` waits for a second user).

Hashing happens exactly once per byte, where bytes cross the flate boundary
(OQ1): on encode, a block is hashed as it is emitted (the block's bytes are
already in the caller's `Writer.Buffer`); on decode, bytes are hashed as
they enter the window; the one-shot encode hashes `source` directly. No
container buffer, no copy of the payload, no second pass.

## Streaming

`gzip.Writer` is a compressing `Io.Writer`; `gzip.Reader` is a decompressing
`Io.Reader` — the `std.Io` interfaces, in-package, over one gzip member. The
machinery is the pattern book's (`src/internal/README.md`, "The Io codec
pattern book"); the entries that serve bytes, the count contracts, the
zero-length poll, the sticky lifecycle, and the contiguity failure are the
internal flate layer's, which this module decorates with the framing — the
header, the trailer, and the member boundary. The container has no serving
region of its own: decoded bytes are served straight out of flate's window
(the caller's `Reader.Buffer`), and written bytes land straight in flate's
block buffer (the caller's `Writer.Buffer`) — one region, one position, no
staging copy.

Buffer ownership, in full (OQ5):

- `Writer.Buffer` and `Reader.Buffer` are flate's, re-exported: the
  container declares no buffer of its own. `Writer.init(output: *Io.Writer,
  buffer: *Writer.Buffer, options: encode.Options)`;
  `Reader.init(input: *Io.Reader, buffer: *Reader.Buffer)`.
- Zero allocation end to end: no allocator appears anywhere in the streaming
  API. The header/trailer scratch is a few comptime-sized stack bytes.

Semantics:

- The header is written before the first compressed byte reaches `output`,
  lazily: `init` cannot fail, so it writes nothing; the first write, flush,
  or finish emits the 10-byte header first (Go's lazy-header shape,
  `gzip.go`). The trailer is written by `finish`.
- `finish()` flushes the buffered partial block and the deflate ending,
  writes CRC32 and ISIZE, and flushes `output`; it is terminal — the writer
  is poisoned afterwards, and a failed or finished writer reports
  `error.WriteFailed` instead of a false success (the pattern book's poison
  check).
- `w.writer.flush()` mid-stream emits the buffered partial block and keeps
  the writer usable; the trailer is never written before `finish`.
- The CRC-32 and the input length (for ISIZE, mod 2^32) are accumulated as
  the data crosses the codec boundary — no re-read of the input, no second
  pass.
- `.ratio` never emits a member: `Writer.init(..., .{ .level = .ratio })`
  poisons the interface (every write and `finish` reports
  `error.WriteFailed`), and `Writer.streamAll` returns `error.ReadFailed`
  upfront — the same reserved-seat behavior as flate's (flate README).
- `Reader` serves decoded bytes with flate's consumer surface and flate's
  contiguous-read cap: a request beyond what the window can hold at the
  consumer's position fails closed with `error.ReadFailed`
  (`err == .StreamTooLong`), never an assert (the pattern book's contiguity
  rule).
- The reader consumes `input` exactly through the member's last trailer byte
  and stops there; bytes after the member are left unconsumed. A
  multi-member file is a caller loop: after `error.EndOfStream`, the input
  position is the next member's first byte; a fresh `Reader` continues
  there, and garbage in a header's place fails `BadHeader`.
- At the body's clean end the reader reads and verifies the trailer exactly
  once, and only then reports `error.EndOfStream` (sticky). A trailer
  mismatch is `error.ReadFailed` with `err` set to `WrongChecksum` /
  `WrongSize` / `WrongHeaderChecksum` / `Truncated`. A caller that stops
  reading before the end never sees the check — the trailer is verified at
  the end of the member, as every reference does.
- `Reader.Error` is `flate.Reader.Error || error{BadHeader, HeaderTooLong,
  WrongHeaderChecksum, WrongChecksum, WrongSize}` — the flate decode detail
  set (minus `BufferTooSmall`, since the window is the caller's and flate
  owns it) plus this module's entries, recorded in `err` beside the
  interface's coarse `error.ReadFailed` / `error.EndOfStream`.
- `Reader.streamAll` / `Writer.streamAll` are the stack-buffered one-call
  pumps (flate's shape): `Reader.streamAll` consumes one member and leaves
  the rest of `in` unconsumed; `Writer.streamAll` consumes `in` to its end
  and writes one member.

Files (the intended layout; the implementation lanes may split further):
`root.zig` (public surface), `encode.zig` (member emission), `decode.zig`
(the header parse and trailer check, shared by both layers), `Writer.zig` +
`Reader.zig` (the streaming `Io` layer), `crc32.zig` (the checksum kernel
boundary), `golden.zig` (ported golden fixtures, shared by every layer's
tests), `bench.zig` (local benchmark), `fuzz.zig` (fuzz targets).

An example CLI (`examples/gzip.zig`, `zig build example-gzip -- encode
README.md > out`) is a thin streaming pump over this surface, the same shape
as snappy's and flate's.

## Testing & golden vectors

The conformance bar is the reference suites, ported as fixtures and shared
by every layer's tests (the flate pattern: `golden.zig` holds the tables,
and the block, streaming, and round-trip tests all read them). The inventory
is `containers-notes.md §5`:

- **golang/go `src/compress/gzip/gunzip_test.go` `gunzipTests` (15
  vectors)** — the primary gzip conformance table: valid members (empty with
  and without FNAME, "hello.txt", a fixed-Huffman member with
  length-distance pairs, the Gettysburg dynamic-Huffman member), the
  **concatenation vector ("hello.txt x2")** decoded member-by-member through
  two reader instances at the boundary, the **all-fields header** (FLG=0x1e:
  FHCRC+FEXTRA+FNAME+FCOMMENT, an 'zz' subfield, a 256-byte comment, FHCRC
  0xfd92 — verified against the CRC arithmetic in `containers-notes.md
  §3.1`), and the corrupt/truncated vectors with pinned errors: corrupt
  CRC32, corrupt ISIZE, truncation mid-raw-block, mid-fixed-block, and inside
  truncated name/comment headers. The "+ garbage" vector pins our boundary
  policy: the member decodes, the garbage is left unconsumed, and a caller
  loop's next header parse is `BadHeader` (a recorded divergence from Go's
  `ErrHeader`, T2/OQ3).
- `TestTruncatedStreams`, `TestIssue6550` (the 85.3-KB decompression-hang
  regression: must fail closed without hanging), `TestMultistreamFalse`,
  `TestNilStream` (the zero-member reading our `Truncated` decision answers).
- **`gzip_test.go`** — `TestEmpty` pins the emitted-header policy on
  readback (`Header{OS: 255}`); `TestRoundTrip` and `TestWriterFlush` are
  round-trip fixtures; `TestLatin1RoundTrip` pins the FNAME/FCOMMENT byte
  rules our decoder skips.
- **Zig 0.16 std's in-tree container tests** (MIT): the gzip stored, fixed,
  and dynamic "Hello world\n" members, "gzip header with name", and the
  **FHCRC member** (`FLG=0x12`, CRC16 `99 d6`) — ported as decoder goldens
  and as divergence pins (std verifies neither FHCRC nor the trailer, T3/T4;
  it does not check reserved bits).
- **The local oracle** (`containers-notes.md §5.5`, every line run and
  round-tripped): python3's `zlib` as a CLI — `compressobj(level, DEFLATED,
  31)` for the gzip wrapper, `zlib.decompress(gz, 31)` for the decode lane,
  `decompressobj(31)` for the single-member boundary (the second member
  lands in `unused_data`), `gzip.compress`/`gzip.decompress` for the CPython
  emitter (OS=255) and its multi-member tolerance. Levels {0, -2, 1, 6, 9}
  in both directions over the committed corpus, the `flate-notes.md §4.3`
  precedent. The flate module's `oracle.zig` harness is the precedent for
  wiring an oracle lane into `just`.
- **The gzip/gunzip 1.14 CLI lane**: the reference decompressor over our
  emitted members and the reference emitter into our decoder (its OS=3,
  MTIME=0, XFL=0 emissions are pinned facts, T1/OQ7).
- **Sentinel overrun checks on every decode**: the target is pre-filled with
  cycling sentinels, and every byte past the decoded length must be
  untouched (`internal.sentinel`, `src/internal/README.md`).
- **Fuzz**: decode, corrupt-input, and round-trip targets over the golden
  corpus — `fuzz.zig` under `zig build test -Doptimize=ReleaseSafe -Dfuzz
  --fuzz=<budget>` (`just fuzz`). The header parser is the amplification
  surface: a tiny member declaring a giant XLEN, an unterminated FNAME, and
  truncated trailers are the first targets (T7). Fuzz-target creation is the
  fuzz-engineer's lane.

Run everything with `zig build test` / `just test` (the ztest plain-text
runner).

## Benchmarks

`zig build bench -Doptimize=ReleaseFast` (Go-style, via
[mattrobenolt/zig-benchmark][zigbench]) over the committed, fixed, hashed
corpus: the same bytes for every implementation, throughput measured over
uncompressed bytes. Local numbers are never quoted as claims; a claim names
a fleet run directory and a results file under `docs/results/`.

The container story is that the flate core dominates and the framing must be
noise: a member adds 10 header bytes and 8 trailer bytes per stream, and the
one thing that shows up in a container number is the checksum pass — CRC-32
over the whole payload. Rows: `BenchmarkCompress` / `BenchmarkDecompress`
(the one-shot container path over the same shapes as flate's), `BenchmarkRatio`,
and the paired raw-flate rows that isolate the container's delta (same
corpus, same level) — the framing-plus-checksum overhead, measured, not
assumed. The streaming direction comes from the example pump (`just example
gzip encode|decode <file>`), which times the same path with real file sinks
(the flate precedent for avoiding bench-binary code-layout interference).

Competitors: klauspost/compress's `gzip` (the Go stdlib container over the
klauspost engine — its checksums are scalar, the known gap our kernel work
attacks), `std.compress.flate.Compress`/`Decompress` with `container = .gzip`
(the in-tree baseline; it verifies neither FHCRC nor the trailer), and the
strongest native libraries on the box — libdeflate (whole-buffer) and zlib-ng
(streaming), the plan's pinned set for this family.

## Licensing & attribution

This module is original Zig. The **format** is a public specification (RFC
1952, vendored with provenance under `docs/research/specs/`) and the
**algorithms** are ideas; the expression here is ours. The reference
implementations studied, all attributed in `THIRD_PARTY.md`:

- **[golang/go][golang]** (`src/compress/gzip`) — BSD-3-Clause. The
  `gunzipTests`, `TestTruncatedStreams`, `TestIssue6550`, and writer-test
  fixture tables are ported from here, as are the reference behaviors the
  divergence rows cite.
- **[klauspost/compress][kp]** (`gzip/`) — BSD-3-Clause. The Go stdlib
  container over the klauspost flate engine (diff-verified); the emission
  policy and hash-on-the-boundary lineage.
- **[ebiggers/libdeflate][libdeflate]** (`lib/crc32.c`,
  `lib/gzip_compress.c`, `lib/gzip_decompress.c`) — MIT. The checksum
  kernel's function shape (`crc32(crc, bytes)`, pre/post-conditioning
  inside), the fixed deterministic header, and the single-member boundary
  reported to the caller are studied from here.
- **[zlib-ng][zlibng]** (`crc32.c`, `arch/**`, `zutil.h`) — zlib license.
  The kernel-dispatch landscape and the `OS_CODE` survey behind T1.
- **Zig std's `std.compress.flate`** (MIT, in-tree) — the container-inside-
  flate shape and the lax decoder rows (T4: no trailer verification, T6;
  no reserved-bit check) are studied as divergence pins, never copied.

madler/zlib's emission rules were verified through the python3 oracle, not
read (`containers-notes.md §0`); python3's `zlib`/`gzip` modules (PSF) are
used as a CLI oracle, nothing vendored.

All upstream licenses are compatible with this repository's MIT license.
The BSD-3-Clause "no endorsement" clause is satisfied by this attribution;
no code was copied verbatim.

[rfc1952]: https://www.rfc-editor.org/rfc/rfc1952.txt
[golang]: https://github.com/golang/go
[kp]: https://github.com/klauspost/compress
[libdeflate]: https://github.com/ebiggers/libdeflate
[zlibng]: https://github.com/zlib-ng/zlib-ng
[zigbench]: https://github.com/mattrobenolt/zig-benchmark
