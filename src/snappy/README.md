# snappy

A standalone Snappy raw-block codec in pure Zig — a hash-table match-finder
encoder and a SIMD-accelerated decoder. Imports only `std` and `fastmem`; no
heap allocation on any codec path. Exposed as the `snappy` build module and
re-exported as `zcompress.snappy`.

This implements the [Snappy block format][format], not a framing/streaming
format. There is no framing layer here by design: a consumer that needs
framing (Xerial, LZO-style length-prefixed chunks, anything else) splits its
input into blocks and owns the framing bytes. See "S2 vs Snappy" below for
what is deliberately out.

## API

```zig
const snappy = @import("snappy");

// Worst-case compressed size — size `out` to this before compress.
snappy.maxCompressedLength(input_len: usize) usize

// Compress `src` into `out` as a raw snappy block. Zero heap allocation.
// `src.len` must be <= max_block_size (snappy's u16-position limit); a
// consumer's framing layer splits larger inputs into blocks.
snappy.compressBlock(src: []const u8, out: []u8) error{BufferTooSmall}!usize

// Decompress a raw snappy block. Zero heap allocation.
snappy.decompressBlock(input: []const u8, out: []u8) DecompressError!usize

// Read the decompressed length (the leading varint) to size `out`.
snappy.decompressedBlockLen(input: []const u8) DecompressError!usize

// The block-size precondition: 65536. compressBlock asserts it.
snappy.max_block_size: usize

pub const DecompressError = error{ BufferTooSmall, DecompressionFailed };
```

Contracts, stated plainly:

- **Ownership**: the caller owns every buffer, on both sides. Nothing is
  allocated, freed, or retained. There is no allocator in the API at all.
- **Sizing**: size `out` for `compressBlock` with `maxCompressedLength(src.len)`,
  and for `decompressBlock` with `decompressedBlockLen(input)`. Both functions
  return `error.BufferTooSmall` rather than truncating. Snappy never expands
  past its bound, so the sizing helpers are exact upper bounds.
- **Corruption**: `decompressBlock` fails closed on any malformed tag,
  offset, or length — no partial output is trusted past the error.
- **No hidden copies**: all copies go through `fastmem.copy`/`fastmem.set`;
  there is no `@memcpy`/`@memset` anywhere in this module, tests included.

Files: `root.zig` (public surface), `encode.zig` (match-finder),
`decode.zig` (SIMD decoder + golden vectors), `common.zig` (LEB128 varint),
`bench.zig` (local benchmark).

An example CLI (`examples/snappy.zig`, `zig build example-snappy -- encode
README.md > out`) exercises this surface end-to-end and owns the framing the
consumer-side needs: a stream of `u32-le compressed-length + raw block`,
split at `max_block_size`.

## Encoder

A port of the algorithm in [klauspost/compress][kp]'s `encodeBlockSnappyGo64K`
(which is itself descended from the Snappy-Go reference and is the same shape
as Google's C++ `CompressFragment`):

- A `1 << 14` `u16` position hash table (a 32 KiB stack frame — zero heap
  allocation). The 6-byte hash is `(u << 16) * prime6bytes >> (64 - 14)` with
  `prime6bytes = 227718039650203`.
- A skip heuristic: the longer the run of bytes with no match, the larger the
  stride, so incompressible regions are skipped quickly instead of hashed
  byte-by-byte.
- Match extension 8 bytes at a time: XOR two `u64` loads and `@ctz` to find the
  first mismatch byte — no byte-by-byte compare loop. On AArch64 this lowers to
  `eor` + `rbit` + `clz`.
- A bail threshold: if the encoded form would exceed `src - src>>5 - 5` bytes,
  the whole block is emitted as a single literal. Snappy guarantees it never
  expands past its bound.
- A repeat-offset check that catches RLE-style input without a fresh hash
  lookup.

Real match-finding compresses: on a 32 KiB block of repetitive text the ratio
is ~0.05 (20:1); HTML and single-byte runs compress similarly. Incompressible
(random) input correctly bails to a literal at ratio 1.0.

Snappy copies are capped at 64 bytes, so long matches split into 60-byte
copy-2 chunks (60, not 64, so the final remainder is guaranteed `>= 4` and
can use a copy-1). A `<= 64 KiB` block never produces a 4-byte-offset copy
(offsets fit in `u16`), but the decoder handles copy-4 for compatibility with
blocks produced by other compressors.

## Decoder

The tag stream is decoded scalarly (it's inherently sequential — a copy can
reference bytes written moments ago). The win is in the copy operations:

- **`offset >= length`** (non-overlapping): a plain `fastmem.copy`.
- **`offset <= 16`** (overlapping / RLE): the `offset`-byte pattern repeats.
  Load the pattern bytes, permute them into the repeating 16-byte window with
  one SIMD shuffle — `tbl` on AArch64, `pshufb` on x86-64 — and store 16-byte
  chunks, re-shuffling each chunk to advance the phase. The shuffle masks are
  comptime-generated (`mask[i] = i % offset` for generation,
  `(16 + i) % offset` for the per-chunk phase advance). For offsets that
  divide 16 (1, 2, 4, 8, 16) the reshuffle is a no-op; for others it shifts
  the phase.
- **`offset > 16`**: the 16-byte source window doesn't overlap the destination
  within a 16-byte span, so a vectorized chunk copy is safe.

One subtlety that bit us: the output buffer is sized to the decompressed
length with **no slop**, so a 16-byte pattern load at `out[pos - offset]` can
overread past `out.len` near the tail. The fix is to copy just the `offset`
source bytes into a zero-padded `[16]u8` before the shuffle — the mask only
references indices `< offset`, so the padding is dead. This is verified by the
golden-vector overrun checks (see below).

## Disassembly

The three optimizations are visible in the machine code, not just the source
(on an AArch64 `ReleaseFast` build):

- `tbl.16b` — the SIMD shuffle for overlapping copies (5 call sites).
- `ldr q` / `str q` — 16-byte vector loads/stores for the literal and
  non-overlapping copy paths.
- `eor` + `rbit` + `clz` — `@ctz` for the 8-byte match extension.

Inspect your own build with:

```sh
zig build bench -Doptimize=ReleaseFast
objdump -d $(find .zig-cache -name benchmark -type f | head -1) | grep tbl.16b | head
```

## Benchmarks

`zig build bench -Doptimize=ReleaseFast` (Go-style, via
[mattrobenolt/zig-benchmark][zigbench]). 32 KiB blocks, one run, on the local
dev box (neoverse_v3, aarch64) — **local reference numbers only**, not claim
evidence; claims cite fleet runs under `docs/results/` (see
`docs/zcompress-plan.md`):

| shape   | compress MB/s | decompress MB/s | ratio |
|---------|---------------|-----------------|-------|
| text    | ~4 200        | ~10 800         | 0.05  |
| html    | ~4 160        | ~12 100         | 0.05  |
| rle     | ~4 770        | ~4 300–4 600    | 0.05  |
| random  | ~5 560        | ~92 500         | 1.00  |
| mixed   | ~5 560        | ~92 600         | 1.00  |

Incompressible input decompresses fastest (~92 GB/s — it's just literal
copies). RLE is the slowest decompress path because it is many short
overlapping copies, each doing a shuffle.

## Testing & golden vectors

The decoder is checked against the authoritative conformance vectors ported
from [golang/snappy][golsnappy]'s `TestDecode`, `TestDecodeCopy4`, and
`TestDecodeLengthOffset`:

- **`TestDecode` table** (30 cases): every tag type, every extended-literal
  length form (tags 60–63), and the corrupt-input rejections (zero offset,
  offset past start, inconsistent decoded length, truncated length/offset
  bytes). Each case includes an **overrun check**: the output buffer is
  pre-filled with cycling sentinel bytes and every byte past the decoded
  length must be untouched afterward — so a copy that writes past the end is
  caught immediately.
- **`TestDecodeCopy4`**: a 64 KiB literal plus a copy-4 at offset 65540 — the
  only case exercising the 4-byte-offset path with a real large offset.
- **`TestDecodeLengthOffset`**: an exhaustive `length × offset × suffixLen`
  sweep (6156 combinations) of a literal + copy2 + literal pattern, with the
  overrun check. Hammers the SIMD copy path across every small offset/length
  pair, including overlapping RLE.
- The `format_description.txt` hand examples and the spec's varint examples.

Run everything with `zig build test` (the ztest plain-text runner).

**On encoder golden vectors**: Snappy does not mandate a canonical compressed
form — as golang/snappy's own test code puts it, "there is more than one valid
encoding of any given input." So we do **not** assert byte-identical encoder
output against reference corpora. That would test "we match a specific
encoder's heuristics," not correctness. Our encoder produces valid blocks that
round-trip through our decoder and through any conformant snappy decoder; the
decode vectors above are the real interop bar.

## S2 vs Snappy

[klauspost/compress][kp] ships two related things in its `snappy/` and `s2/`
packages. **S2** is Klaus Post's own format — a superset of Snappy that
*decodes* standard Snappy but *encodes* a richer, Snappy-incompatible stream.
The extensions:

- **Repeat offsets**: a copy-1 tag with offset 0 means "reuse the previous
  offset" (an LZ4-style distance cache). Standard Snappy has no such state
  and treats offset 0 as corrupt.
- **Larger blocks**: up to 4 MiB vs Snappy's hard 64 KiB.
- **Concurrent streaming compression** and extra **better/best** encoder modes.

The relationship is asymmetric: **S2 decodes Snappy, but Snappy does not decode
S2.** His `snappy/` package is a thin wrapper over the `s2` engine that caps
blocks at 64 KiB and uses the Snappy-compatible encoder path
(`encodeBlockSnappyGo64K`) so the output stays decodable by any standard Snappy
consumer.

This module ports the **Snappy-compatible path only**: no repeat offsets,
blocks capped at 64 KiB, and the decoder rejects offset-0 copies as
`DecompressionFailed` rather than interpreting them as repeats. S2-style
extensions are a deferred plan decision, not a missing feature.

## Licensing & attribution

This module is original Zig. The **algorithm** (hash table match-finding) and
the **format** are uncopyrightable ideas and a public specification
respectively; the **expression** here is ours. We did, however, study three
reference implementations closely and port the test vectors, so attribution
is in order (see `THIRD_PARTY.md`):

- **[klauspost/compress][kp]** (`s2/encode_all.go`, `encode_go.go`) —
  BSD-3-Clause. The encoder algorithm (`encodeBlockSnappyGo64K`), the
  `prime6bytes` hash, the skip heuristic, and the bail-to-literal threshold
  are ported from here.
- **[golang/snappy][golsnappy]** (`snappy_test.go`) — BSD-3-Clause. The golden
  decode vector tables and the overrun-check sentinel technique are ported
  from here.
- **[google/snappy][gpcpp]** (`snappy.cc`, `snappy-internal.h`, `snappy.h`) —
  BSD-3-Clause. The SIMD overlapping-copy technique (PSHUFB/TBL shuffle masks
  and the generation+reshuffle mask tables) and the block/hash-table
  constants were studied here. Our decoder's shuffle approach is the Zig
  equivalent of their `pattern_generation_masks` / `pattern_reshuffle_masks`.

All three are BSD-3-Clause, compatible with this repository's MIT license.
The BSD-3-Clause "no endorsement" clause is satisfied by this attribution; no
code was copied verbatim.

[format]: https://github.com/google/snappy/blob/main/format_description.txt
[kp]: https://github.com/klauspost/compress
[golsnappy]: https://github.com/golang/snappy
[gpcpp]: https://github.com/google/snappy
[zigbench]: https://github.com/mattrobenolt/zig-benchmark
