# flate

A standalone raw DEFLATE (RFC 1951) codec in pure Zig — a fast fixed-Huffman
encoder in the klauspost level-1 class and a full inflate (stored, fixed, and
dynamic blocks). Imports only `std` and `fastmem`; no heap allocation on any
codec path. Exposed as the `flate` build module and re-exported as
`zcompress.flate`.

The format is [RFC 1951][rfc1951], vendored verbatim at
`docs/research/specs/rfc1951-deflate.txt`. The research stage — the
requirements matrix, the fixture inventory, and the reference-lineage
divergence rows this document decides — is `docs/research/flate-notes.md`
(cited below as `flate-notes.md`).

This module is raw deflate only, deliberately:

- **No container.** gzip (RFC 1952) and zlib (RFC 1950) wrap deflate; M3
  builds them over this module. The bytes here start at the first block
  header and end at BFINAL.
- **No preset dictionaries.** Deferred (OQ6), not designed; nothing here
  precludes a dictionary entry point later.
- **No ratio mode.** The fast level emits fixed-Huffman blocks (OQ1);
  dynamic Huffman with cross-block table reuse is the planned ratio mode
  (flate-notes.md §6). `.ratio` in `Level` selects `error.Unimplemented` —
  no silent aliasing. One mode, one function on the surface.
- **No canonical compressed form.** Deflate mandates none: two compliant
  encoders may emit different bytes for the same input, so reference encoder
  goldens do not port (same rationale as snappy's README).

The stream is self-delimiting — BFINAL on the last block ends it
(`rfc1951-deflate.txt §3.2.3`) — so unlike snappy this module adds no framing
of its own. That single fact forces three API deviations from the snappy
sibling (OQ2: one-shot `compress`/`decompress` over caller buffers plus the
streaming layer); they are stated in "The stream format". `std.compress.flate` is the
in-tree precedent for the streaming shape; it is streaming-only with the
container inside flate, so the one-shot layer here is an addition.

## API

The public surface is four namespaces — everything else composes through
them: `flate.encode` (block encoding), `flate.decode` (block decoding),
`flate.Writer` (streaming encode), `flate.Reader` (streaming decode).

```zig
const flate = @import("flate");

// The block encoder (flate.encode):
flate.encode.max_block_size      // 65535, the stored-block LEN cap (§3.2.4);
                                  // compress splits input at it; the streaming
                                  // Writer emits blocks at it.
flate.encode.history_len          // 32768, the format's backward reach
                                  // (RFC 1951 §3.2.5); the finder's window
                                  // is history_len followed by the block.
flate.encode.maxCompressedLength(input_len) usize
                                  // size `target` to this before compress.
flate.encode.Level                // enum { fast, ratio, @"0", @"1".."@"9" }:
                                  //   fast   — the tuned default; fixed-Huffman
                                  //   ratio  — dynamic Huffman; unimplemented,
                                  //            selects error.Unimplemented
                                  //   @"0"   — stored blocks only
                                  //   @"1".."@"9" — numeric levels; they all
                                  //            tune to fast until more tuned
                                  //            modes exist (stated, not hidden).
flate.encode.Options              // struct { level: Level = .fast }.
                                  // .{} is the default: the fast level.
flate.encode.compress(source, target, options)
    error{BufferTooSmall, Unimplemented}!usize

// The block decoder (flate.decode):
flate.decode.decompress(source, target) DecompressError!usize
                                  // `target` is a cap; returns the decoded
                                  // length, or `error.BufferTooSmall` before
                                  // the overflow. No decoded-length helper:
                                  // a raw deflate stream declares no decoded
                                  // length anywhere.
flate.decode.DecompressError = error{
    BufferTooSmall,             // decompress only: `target` cannot hold output
    Truncated,                  // input ended before the final block completed
    InvalidBlockType,           // BTYPE = 11 (§3.2.3)
    WrongStoredBlockNlen,       // NLEN != one's complement of LEN (§3.2.4)
    InvalidDynamicBlockHeader,  // a malformed dynamic header (§3.2.7)
    OversubscribedHuffmanTree,  // Kraft sum > 1 (§3.2.2)
    IncompleteHuffmanTree,      // Kraft sum < 1, beyond the single-1-bit-code case
    MissingEndOfBlockCode,      // literal/length tree with no code for 256
    InvalidCode,                // a code that decodes to no legal symbol
    InvalidMatch,               // a distance before the start of the output (§3.2.3)
};

// The streaming Io layer: Writer.Buffer / Reader.Buffer are caller-provided
// buffer types (exact pointers at init). Writer.init takes options; the
// streaming Reader does not (decode options are input-shaped, not user-set).
var w: flate.Writer = .init(out, &wbuf, .{}); // wbuf: flate.Writer.Buffer
try w.writer.writeAll(bytes);                  // through the Io.Writer interface
try w.finish();
var r: flate.Reader = .init(in, &rbuf);        // rbuf: flate.Reader.Buffer
// consume through &r.reader; flate.Reader.Error (= the DecompressError
// set minus BufferTooSmall — the Reader owns its window — plus StreamTooLong /
// ReadFailed / EndOfStream) records the specific failure beside the
// interface's coarse ReadFailed / EndOfStream.

// The one-call conveniences: stack-buffered end-to-end, zero allocation.
// Writer.streamAll takes options; `.ratio` lands as error.ReadFailed upfront.
// Reader.streamAll has only the codec side.
flate.Writer.streamAll(in, out, options) error{ReadFailed, WriteFailed}!usize
flate.Reader.streamAll(in, out) error{ReadFailed, WriteFailed}!usize
```

Caller-owned buffer types (exact pointers at init):

- `flate.Reader.Buffer = [2 * history_len]u8`               — 64 KiB window.
- `flate.Writer.Buffer = [max_block_size + history_len]u8`  — 98303 bytes.

Contracts, stated plainly:

- **Ownership**: the caller owns every buffer, on both sides. Nothing is
  allocated, freed, or retained. There is no allocator in the API at all.
- **Sizing**: `maxCompressedLength(input_len) = input_len + 5 *
  ceil(input_len / 65535) + 2` — every emitted block costs at most 5 bytes of
  header beyond its input when stored (`§3.2.4`), and the encoder always ends
  with a 2-byte final empty block. The RFC's own bound is looser — "5 bytes
  per 32K-byte block" (`§1.1`); this is the tighter bound our 65535-byte
  blocks and stored fallback give. `compress` never expands past it.
  `decompress` takes `target` as a cap and returns the decoded length; a
  stream that does not fit is `error.BufferTooSmall`, reported before the
  overflowing write, never a truncated success. There is no decoded-length
  helper: a raw deflate stream declares no decoded length anywhere, so the
  caller knows the size out-of-band (the gzip/zlib containers carry it; M3).
- **Corruption**: decode fails closed at the first invalid bit — a malformed
  header, tree, code, stored block, or distance returns the specific
  `DecompressError` above, and no partial output is trusted past the error.
  Every decode test pre-fills the target with cycling sentinels and proves
  the bytes past the decoded length are untouched.
- **Amplification**: `decompress` writes only into `target` and the Reader
  writes only into its 64-KiB window — neither grows with the input, and a
  small stream cannot overrun a small cap.
- **Contiguity**: the Reader serves contiguous decoded bytes from its
  window; a request beyond what the window can hold at the consumer's
  position fails closed (`error.ReadFailed`, `err == .StreamTooLong`), never
  an assert. See "Streaming".
- **No hidden copies**: every copy goes through `fastmem.copy` /
  `fastmem.move` / `fastmem.set`; there is no `@memcpy`/`@memmove`/`@memset`
  anywhere in this module, tests included.
- **Stack**: the encoder's match-finder table is `[1 << 15]u32` = 128 KiB of
  comptime-sized stack scratch, and the streaming Writer's per-block path
  adds a 64 KiB compressed-output scratch — an emitted block runs on roughly
  192 KiB of stack, the one-shot path on roughly 128 KiB. Size thread stacks
  accordingly when embedding.
- **Allocation**: zero, end to end. The one-shot functions take no
  allocator; `Reader`/`Writer` take none either (caller-provided buffers
  through the named buffer types).

## The stream format

A deflate stream is a sequence of blocks. Each block begins with 3 header
bits — BFINAL, then BTYPE, two bits LSB-of-value first — that do not
necessarily begin on a byte boundary (`§3.2.3`). BTYPE 00 is stored, 01
fixed-Huffman, 10 dynamic-Huffman, 11 reserved (error) (`§3.2.3`). BFINAL is
set "if and only if this is the last block of the data set" (`§3.2.3`):
**the stream ends at the first block with BFINAL=1** — no length prefix, no
magic, no checksum, no decoded size. Block sizes are otherwise arbitrary,
and a compliant decoder must accept blocks of arbitrary size (`§3.3`).

Bit packing (`§3.1.1`), the format's number-one corruption risk:

- Bits fill a byte from bit 0 up; a 9th bit spills into bit 0 of the next
  byte.
- Data elements other than Huffman codes are packed LSB-of-value first.
- Huffman codes are packed MSB-of-code first — a code appears bit-reversed
  relative to its numeral, so the encoder stores codes pre-reversed (or
  reverses at emission).
- **Extra bits are data elements: LSB-of-value first.** `§3.2.5`'s "stored
  with the most-significant bit first, e.g., bits 1110 represent the value
  14" describes the numeral, not the wire order; the wire order is settled
  by the reference lineage and was verified against the oracle with the
  hand-built streams in flate-notes.md §3.2. An implementer who reads only
  `§3.2.5` emits MSB-first and produces streams every reference decoder
  misreads. The encoder names its two writes differently (`writeCode` vs
  `writeBits`) so the distinction cannot be lost.
- Stored blocks skip to the next byte boundary ("any bits of input up to the
  next byte boundary are ignored", `§3.2.4`), then carry LEN and NLEN, u16
  little-endian, NLEN the one's complement of LEN, then LEN raw bytes
  (`§3.2.4`). LEN is 16 bits, so a stored block carries at most 65535 bytes
  (`§2`). The encoder pads with zero bits; a decoder must not require the
  padding to be zero.
- The final partial byte is zero-padded on emission; the decoder ignores its
  unused high bits.

Matches reach backwards up to 32768 bytes and **across block boundaries**:
"the backward distance may cross one or more block boundaries. However a
distance cannot refer past the beginning of the output stream" (`§3.2.3`).
The referenced string may overlap the current position — `§3.2.3`'s
`<length = 5, distance = 2>` example adds X,Y,X,Y,X. That 32-KiB backward
reach is the window a decoder must retain; it is the format's invariant, not
a design choice.

The three format-forced deviations from the snappy sibling:

- **No framing of our own.** BFINAL self-delimits, so `Reader`/`Writer` are
  raw deflate with nothing added. A truncated stream is detectable (input
  ends before BFINAL) but concatenation is not: the reader stops at the
  first final block and leaves the rest of `input` unconsumed, and the
  one-shot `decompress` ignores bytes after the final block in `source` (the
  reference lineage's behavior — zlib reports them as `unused_data`, Go
  leaves them unread). A caller that needs the stream boundary knows it
  out-of-band.
- **No `decompressedBlockLength` equivalent.** A raw deflate stream declares
  no decoded length anywhere, so `decompress` takes `target` as a cap and
  returns the decoded length. There is no helper that reads one.
- **The Reader decodes directly from the input `Io.Reader`** through a bit
  reader with a few bytes of lookahead — no compressed-block staging region,
  because a Huffman block has no compressed length prefix. std's decoder is
  the precedent: both of its modes decode incrementally from the input and
  never stage compressed bytes (flate-notes.md §5.4).

## Encoder

The fast level emits **fixed-Huffman blocks with a stored-block fallback**
(OQ1). Fixed emission is branch-light — no header to build, no precode, one
shift-add per symbol — which is why zlib-ng's fastest level is fixed-only
(flate-notes.md §5.3). The ratio cost is real (a literal costs 8-9 bits vs
dynamic's ~5), so a dynamic-Huffman ratio mode is deferred: klauspost L1 and
libdeflate L1 both pay for dynamic headers at their fastest level and still
lead the speed class, and the fleet decides whether the fast level gains a
dynamic sibling; `Level.ratio` reserves the seat with
`error.Unimplemented` — never silent aliasing (see the API block above).

The match finder is the klauspost-L1 shape (OQ3), the snappy encoder's
sibling: the shape below is flate-notes.md §5.1's reading of
klauspost/compress's `flate/fast_encoder.go` and `flate/level1.go`
(`fastEncL1`), which is where the algorithm is ported from; attribution is
in `THIRD_PARTY.md`:

- A single-slot `[1 << 15]u32` table (128 KiB of comptime-sized stack
  scratch — zero heap allocation) and a 5-byte hash of the klauspost lineage
  (`prime5bytes = 889523592379`, 15 table bits).
- Greedy: no lazy matching (level 1 is lazyless in every fast reference —
  klauspost L1, libdeflate L1, zlib-ng quick, zlib level 1, std level_1;
  flate-notes.md §5).
- A 4-byte confirm after a hash hit, the snappy-style accelerating skip
  (`nextS = s + 3 + (s - nextEmit) >> 5`), and backward extension into the
  preceding literals so the literal run shrinks to the true match start.
- Minimum match 4 (a 3-byte match costs a length and a distance symbol for
  three bytes; left to the ratio mode) and maximum distance 32768
  (`§3.2.5`).
- Long matches split at 258 with the final chunk kept >= 3: the last chunk
  drops to 255 when a 258 would leave a 1- or 2-byte tail, which cannot be
  coded (the shortest length symbol is 3). Length 258 is code 285, the one
  code with zero extra bits; code 284's table range tops out at 257
  (`§3.2.5`).

The finder's window is the block's 32-KiB history followed by the block
itself, so the 32-KiB distance cap is structural and matches cross block
boundaries exactly as the format allows. The table is a block-scoped
instance rebuilt from that window (the streaming Writer's scratch is per
call, so it hashes the history region first; the one-shot path points at the
source slice directly). If the fleet later shows the rebuild costs
measurable throughput, klauspost's persistent table plus `shiftOffsets` is
the known alternative — a perf change, not an API change.

Block policy:

- The encoder splits input at 65535 bytes (`max_block_size`) — the
  stored-block LEN cap, so any block can fall back to stored. `compress`
  knows the whole source and splits it the same way.
- A block is emitted as fixed Huffman only if its payload is smaller than
  the stored alternative (32 + 8 x len payload bits, `§3.2.4`); otherwise
  the whole block is stored. That is the bail threshold, and it makes
  `maxCompressedLength` provable: no block ever exceeds its stored form.
- Every data block carries BFINAL=0. The stream ends with a final empty
  fixed block — BFINAL=1, BTYPE=01, EOB, bytes `03 00` — emitted by both
  layers. zlib's level 0 ends an empty stream with an empty stored block
  (`01 00 00 ff ff`); Go ends with `03 00`; both are legal, and `03 00` is
  the cheapest and the uniform choice (T4, below; flate-notes.md §2.3).
  Consequence: `flush` mid-stream is always safe (no block ever claims to be
  last), and the one-shot and streaming encoders share one ending.
- The encoder is deterministic: the same input and the same block split
  produce the same bytes. The streaming layer's split follows the caller's
  writes and flushes, so a streamed encoding and a one-shot encoding of the
  same bytes are both valid and usually — not necessarily — identical.

The bit writer has exactly two write operations, named for the packing rule
each implements: `writeBits` (a non-Huffman data element, LSB-of-value first
— extra bits and any future precode lengths) and `writeCode` (a Huffman
code, MSB-of-code first). Mixing them up is the T1 bug.

## Decoder

Inflate: a bit reader, the fixed and dynamic tables, the match copy, and the
window.

**Bit reader.** LSB-first fill (`§3.1.1`), a few bytes of lookahead, and
resumable at any bit boundary: blocks have no size limit (`§3.3`), so the
Reader decodes incrementally into its window and never stages a whole block.
Huffman codes are read MSB-first (the fixed table's codes are read
bit-reversed; std's `readFixedCode` is the precedent, flate-notes.md §5.4);
extra bits are read LSB-first (T1).

**Tables.** The fixed literal/length and distance tables come from `§3.2.6`
— 286-287 and distance codes 30-31 "will never actually occur in the
compressed data" but still participate in the fixed table's construction
(`§3.2.6`) — and codes are canonical per `§3.2.2`. The dynamic header is
`§3.2.7`: HLIT, HDIST, HCLEN, the (HCLEN+4) x 3-bit precode lengths in the
scrambled order 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14,
1, 15, then the literal/length and distance lengths as one sequence of
HLIT+HDIST+258 values that repeat codes 16/17/18 may carry across the
boundary. Code lengths are 0-15; precode lengths 0-7.

A decoder must accept:

- Blocks of arbitrary size and headers at any bit offset (`§3.3`,
  `§3.2.3`).
- Stored blocks at any alignment, LEN 0-65535, NLEN = ~LEN (`§3.2.4`).
- Fixed and dynamic blocks, including zero distance codes (the data is all
  literals) and a single distance code of one bit — "it is encoded using one
  bit, not zero bits; in this case there is a single code length of one,
  with one unused code" (`§3.2.7`) — and a literal/length tree whose only
  code is the EOB (an empty block; Go's degenerate-HLitTree vectors decode
  to "", flate-notes.md §7).
- Every length code 257-285 and distance code 0-29 with its extra bits
  (`§3.2.5`), distances reaching back across block boundaries up to 32768,
  and overlapping copies (`§3.2.3`).
- Empty streams (a single final empty block) and empty non-final blocks
  (LEN 0 is legal, `§3.2.4`).

A decoder must reject, fail-closed:

- BTYPE=11, "reserved (error)" (`§3.2.3`) — `InvalidBlockType`.
- NLEN != ~LEN (`§3.2.4`) — `WrongStoredBlockNlen`.
- Oversubscribed code sets (Kraft sum > 1, implied by `§3.2.2`'s
  construction) — `OversubscribedHuffmanTree`.
- Incomplete code sets, except the single-1-bit-code case (zlib's
  `inftrees.c` rule, std's `checkCompleteness`, Go's degenerate vectors;
  flate-notes.md §7) — `IncompleteHuffmanTree`.
- A literal/length tree with no code for 256 — `MissingEndOfBlockCode`,
  rejected up front at table build (std's choice; zlib accepts the tree and
  dies later, when the stream cannot terminate — T2, below). An empty
  precode tree is the same situation one level up: it cannot decode the
  lengths that must follow, so the header is `InvalidDynamicBlockHeader`
  (Go's "empty HCLenTree" vector fails).
- HLIT past 286 codes or HDIST past 30, and any literal/length symbol
  286-287 or distance code 30-31 that decodes anyway — the reference lineage
  caps both alphabets (zlib's "too many length or distance symbols",
  oracle-verified; flate-notes.md §7): `InvalidDynamicBlockHeader` for the
  header, `InvalidCode` for a symbol.
- A distance before the start of the output stream (`§3.2.3`) —
  `InvalidMatch`.
- Input that ends before the final block completes — `Truncated`.

**Length and distance arithmetic is unclamped**: length = base + extra, so
code 284 with extra 31 is length 258, even though `§3.2.5` states 284's
range as 227-257 (T5, below; Go's TestStreams pins it, oracle-verified).
Code 285 is 258 with zero extra bits. Distances are 1-32768.

**Match copy.** A match copies `length` bytes from `distance` back in the
decoded output. `distance >= length` is a non-overlapping `fastmem.copy`;
`distance < length` is the format's overlapping copy (`§3.2.3`) and
replicates the `distance`-byte pattern (the snappy decoder's shuffle
technique applies). A match may span block boundaries but never the start of
the output (`§3.2.3`).

**Window retain.** The decoder retains the last 32768 bytes of decoded
output across block boundaries — the format's reach (`§2`, `§3.2.3`) — so
the Reader's 64-KiB buffer is a sliding window, not an accumulation. The
one-shot `decompress` needs no separate window: `target` is the output, and
the history is the bytes already written to it.

### Divergences, decided

The RFC is silent or self-contradictory exactly where every implementation
must pick; the research notes record both sides (flate-notes.md §2.3, §7).
Our calls, so the conformance suite pins them deliberately:

| # | corner | our call |
|---|--------|----------|
| T1 | extra-bit order | LSB-of-value first, like every non-Huffman element; `§3.2.5`'s sentence describes the numeral. Verified against the oracle in both directions (flate-notes.md §3.2). |
| T2 | degenerate literal/length trees, missing EOB | Missing EOB: reject up front (`MissingEndOfBlockCode`). Single 1-bit code: accept — it must be 256, else the missing-EOB rule fires. Empty tree: reject. The distance side follows `§3.2.7`: zero codes and a single 1-bit code are both accepted. |
| T3 | alphabet caps | HLIT <= 286, HDIST <= 30; symbols 286-287 and distance codes 30-31 never decode. The RFC's parentheticals read wider; the whole reference lineage (zlib, Go, std; oracle-verified) caps, so we cap. |
| T4 | stream ending | The encoder ends every stream with a final empty fixed block (`03 00`), never BFINAL on a data block. zlib's level 0 uses an empty stored block, Go uses `03 00`; both legal, ours is the cheaper and uniform one. |
| T5 | code 284 + extra 31 | Accept unclamped: length 258. The references compute unclamped and Go's TestStreams expects it; range-clamping would reject a stream the entire lineage accepts. |

An RFC-literal decoder would differ on T1, T3, and T5. Ours is the
reference-compatible one, on purpose: the conformance fixtures are the
reference suites.

## Streaming

`flate.Writer` is a compressing `Io.Writer`; `flate.Reader` is a
decompressing `Io.Reader` — the `std.Io` interfaces, in-package, over raw
deflate. The `std.compress.flate` `Compress`/`Decompress` pair is the
in-tree precedent for the shape: an embedded interface with a vtable,
`@fieldParentPtr` back to the parent, a failing state after errors, and
caller-provided buffers.

Buffer ownership, in full (OQ4):

- `Writer.Buffer` is `[max_block_size + history_len]u8` (98303 bytes, ~96
  KiB): the uncompressed accumulation block (65535) plus the retained match
  history (32768). `Writer.init(output: *Io.Writer, buffer: *Writer.Buffer)`.
- `Reader.Buffer` is `[2 * history_len]u8` (65536 bytes, 64 KiB): one
  window of decoded output — the last 32 KiB of it is match history (the
  format's reach), the rest is fresh output. There is no compressed staging
  region: the Reader decodes directly from `input` through the bit reader.
  `Reader.init(input: *Io.Reader, buffer: *Reader.Buffer)`.
- Zero allocation end to end: no allocator appears anywhere in the streaming
  API. The compressed-output scratch and the finder table are comptime-sized
  stack locals.
- Stack: each emitted block uses roughly 192 KiB of stack (the 128 KiB
  finder table plus the 64 KiB compressed-output scratch) — size thread
  stacks accordingly when embedding.

Semantics:

- `Writer.finish()` emits the buffered partial block, then the final empty
  fixed block, then flushes `output`; it is terminal — the writer is
  poisoned afterwards, and a failed or finished writer reports
  `error.WriteFailed` instead of a false success.
- `Writer.flush()` mid-stream emits the buffered partial block and keeps the
  writer usable. It is always safe, because no data block carries BFINAL.
- Full blocks stay maximal: `drain` emits one buffered block, then accepts
  what fits of the incoming data; `rebase` (which `writableSliceGreedy`
  hits when the buffer is full — the `File.Reader` simple-mode stream feeds
  writers this way) emits the buffered input beyond the retained history and
  slides the tail to the front, never discarding input. History is a ratio
  input on the writer side, never a correctness one: a rebase that the
  caller's capacity request leaves no room for simply drops it.
- `Reader` ends cleanly with `error.EndOfStream` (sticky) once the final
  block's output has been consumed, and fails closed with
  `error.ReadFailed` (sticky, details in `err`) on any malformed stream or
  input failure. `err`'s type is the `DecompressError` set above minus
  `BufferTooSmall` (the Reader owns its buffer) plus `ReadFailed` and
  `EndOfStream`.
- The Reader consumes `input` exactly through the stream's last byte — the
  final block's partial byte included — and stops there; bytes after the
  stream are not consumed. (That is what lets M3's gzip/zlib readers find
  their footers.) The bit reader refills with `peek`/`toss`, never blind
  reads.
- The input's own buffer must hold at least 3 bytes — a stored block's
  LEN/NLEN (`§3.2.4`), or a Huffman code, plus the partial byte already
  consumed — or the input must end before then. The bit reader buffers ahead
  through `peek`, so a buffer narrower than that cannot see enough bits to
  decode a symbol correctly.
- The contiguous decoded-read cap: the window holds 64 KiB, and the decoder
  can slide it forward only when the consumer has drained everything older
  than the retained 32-KiB tail. Any contiguous request (`peek`/`take`
  family) of at most 32 KiB is served; a request beyond what the window can
  hold at the consumer's position fails closed with `error.ReadFailed`
  (`err == .StreamTooLong`), never an assert — a hostile or unusual consumer
  cannot crash the reader. (Snappy's cap is two blocks because its blocks
  are independent; flate's window must retain history, so its cap is
  tighter.)

Files (the intended layout; the implementation lanes may split further):
`root.zig` (public surface), `encode.zig` (fixed-Huffman encoder and match
finder), `decode.zig` (inflate, bit reader, and the canonical Huffman
table construction shared by both sides), `golden.zig` (ported golden
fixtures, shared by every layer's tests), `Writer.zig` + `Reader.zig` (the
streaming `Io` layer), `bench.zig` (local benchmark), `oracle.zig` (the
external-oracle harness behind `just flate-oracle`), `fuzz.zig` (fuzz
targets).

The example CLI (`examples/flate.zig`, `zig build example-flate -- encode
README.md > out`) is a thin streaming pump over this surface, the same shape
as snappy's.

## Benchmarks

`zig build bench -Doptimize=ReleaseFast` (Go-style, via
[mattrobenolt/zig-benchmark][zigbench]) over the committed, fixed, hashed
corpus: the same bytes for every implementation, throughput measured over
uncompressed bytes. Local numbers are never quoted as claims; a claim names
a fleet run directory and a results file under `docs/results/`, with the
competitor set the plan pins for this family — klauspost/compress and
std.compress always, plus the strongest native libraries on the box
(libdeflate and zlib-ng).

Rows: `BenchmarkCompress`/`BenchmarkDecompress` (the one-shot block path at
32 KiB and 64 KiB per shape) and `BenchmarkRatio` (compressed/uncompressed
per shape, untimed). A streaming bench row was tried and reverted: the
compiled streaming-row code bulk in the bench binary perturbs the one-shot
rows' numbers ~3x (placement and machine state exonerated, filtered runs
clean — the effect is code layout, unprofiled on this box). Streaming
direction comes from the example pump (`just example flate
encode|decode <file>`) over a multi-hundred-MiB corpus, which times the
same path with real file sinks and no bench-binary interference.

## Testing & golden vectors

The conformance bar is the reference suites, ported as fixtures and shared
by every layer's tests (the snappy pattern: `golden.zig` holds the tables,
and the block, streaming, and round-trip tests all read them):

- **golang/go `flate_test.go` `TestStreams` (27 hex vectors)** — the primary
  conformance table: every degenerate dynamic-header corner (empty and
  degenerate HCLenTree/HLitTree/HDistTree, a spanning repeat code, symbol
  284 with count 31, reserved symbol 287, HDistTree "of normal length 30"
  vs "excessive length 31"), a raw stored block, and the
  issue-10426/11030/11033 regressions. `TestTruncatedStreams`: every prefix
  of a 26-byte two-block stream must fail closed. Both port verbatim
  (BSD-3-Clause; attribution in `THIRD_PARTY.md`).
- **golang/go `deflate_test.go` `deflateTests` (15 rows)** — as *decode*
  goldens: every `out` is a valid stream that must decode to `in` (stored
  blocks with LEN/NLEN, fixed blocks, the `03 00` empty stream). As
  *encoder* goldens they assert Go's heuristics and do not port — deflate
  mandates no canonical form.
- **golang/go truncated vectors (10)** — truncated stored headers, partial
  fixed-block payloads, mid-match truncation: all must fail closed with a
  short-read error, never a panic.
- **The `huffman-*` `.in`/`.golden` pairs (9)** — `.in` is uncompressed
  input, `.golden` a valid huffman-only stream that decodes to it (verified
  against the oracle). The `.expect` variants are Go-heuristic byte-exact
  encoder outputs: valid decoder inputs, not encoder goldens.
- **Corpus texts** — `e.txt` (97.7 KB of digits of e) and
  `Isaac.Newton-Opticks.txt` (553.9 KB) from Go's testdata, plus
  `Mark.Twain-Tom.Sawyer.txt` from klauspost/compress (Go removed it from
  `src/compress/testdata/`; klauspost is the vendoring source). BSD-3.
- **RFC 1951's own micro-examples** — `§3.2.2`'s canonical-construction
  table (the fixed-header emission test), `§3.2.3`'s overlap copy,
  `§3.2.7`'s repeat expansion, `§3.1`'s 520-as-two-bytes — each test cites
  the section it validates. Plus the two hand-built oracle-verified streams
  in flate-notes.md §3.2 (fixed Huffman; the extra-bit order proved in both
  directions) and std's four raw micro-streams (MIT, in-tree).
- **The oracle lanes, both directions** — python3's `zlib`, run as a CLI
  (nothing vendored), over the committed corpus:

  ```python
  import zlib
  co = zlib.compressobj(level, zlib.DEFLATED, -15)     # raw deflate, no container
  raw = co.compress(data) + co.flush()                  # our decode lane
  do = zlib.decompressobj(-15)
  assert do.decompress(raw) + do.flush() == data        # our encode lane
  zlib.decompress(bytes.fromhex("010100feff11"), -15)   # one-shot stream check
  ```

  Levels {0, -2, 1, 6, 9}: our encoder -> oracle decode, oracle encode ->
  our decode, both directions over the same corpus (`-2` is huffman-only;
  `-15` is raw; 15 is zlib-wrapped; 31 is gzip/autodetect). The gzip and
  gunzip CLIs join at M3.
- **Sentinel overrun checks on every decode**: the target is pre-filled with
  cycling sentinel bytes, and every byte past the decoded length must be
  untouched afterwards.
- **Fuzz**: `fuzz.zig` carries a decode target (over the golden corpus, plus
  a corrupt-input target that must never panic or overrun) and a round-trip
  target, run under the default runner: `zig build test
  -Doptimize=ReleaseSafe -Dfuzz --fuzz=<budget>` (`just fuzz 10M`) — Debug
  fuzz hits ziglang/zig#30655. Fuzz-target creation is the fuzz-engineer's
  lane.

Run everything with `zig build test` / `just test` (the ztest plain-text
runner).

## Licensing & attribution

This module is original Zig. The **format** is a public specification (RFC
1951, vendored with provenance under `docs/research/specs/`) and the
**algorithms** are ideas; the expression here is ours. Two reference
implementations shaped the work, both BSD-3-Clause and both attributed in
`THIRD_PARTY.md`:

- **[klauspost/compress][kp]** (`flate/fast_encoder.go`, `flate/level1.go`)
  — BSD-3-Clause. The fast-level match finder (`fastEncL1`: the single-slot
  table, the 5-byte hash and its `prime5bytes`, the skip heuristic, the
  4-byte confirm, the backward extension, the 258/255 match split, the
  64-KiB block policy) is ported from here.
- **[golang/go][golang]** (`src/compress/flate`) — BSD-3-Clause. The
  `TestStreams`, `TestTruncatedStreams`, truncated-stream, and `deflateTests`
  fixture tables and the `huffman-*` pairs are ported from here, as are the
  corpus texts.

Studied but not ported: Zig std's `std.compress.flate` (MIT — the streaming
`Compress`/`Decompress` shape and the decoder-validation rules), and the zlib
family — madler/zlib, zlib-ng, and libdeflate (zlib and MIT licenses — read
for the decoder-validation rules and the fast-level landscape, flate-notes.md
§5). The python3 `zlib` module (PSF) is used as a CLI oracle; nothing is
vendored.

Both upstream projects are BSD-3-Clause, compatible with this repository's
MIT license. The BSD-3-Clause "no endorsement" clause is satisfied by this
attribution; no code was copied verbatim.

[rfc1951]: https://www.rfc-editor.org/rfc/rfc1951.txt
[kp]: https://github.com/klauspost/compress
[golang]: https://github.com/golang/go
[zigbench]: https://github.com/mattrobenolt/zig-benchmark
