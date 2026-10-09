# flate research notes

The research stage of the codec development loop for flate (M2: fast encoder
plus full inflate). Spec: `docs/research/specs/rfc1951-deflate.txt` (vendored,
verbatim). Every requirement line below cites that file and its section; where
the RFC is ambiguous or silent, that is stated explicitly and the divergence is
marked as a decision for the parent, never silently picked.

## 0. Provenance

- Spec: `rfc1951-deflate.txt` — RFC 1951, "DEFLATE Compressed Data Format
  Specification version 1.3" (Deutsch, May 1996), 36,944 bytes, verified by
  title and byte count. Fetched 2026-10-08 from
  https://www.rfc-editor.org/rfc/rfc1951.txt; provenance row already in
  `docs/research/specs/README.md`. IETF RFCs are freely distributed (the
  document's own Notices grant copying for any purpose with the notice
  preserved).
- Reference implementations read for this file (cited inline as
  `repo path:file`): golang/go `src/compress/flate/` (BSD-3-Clause),
  klauspost/compress `flate/` (BSD-3-Clause), ebigers/libdeflate `lib/`
  (MIT), zlib-ng (zlib license), madler/zlib (zlib license, read for the
  decoder-validation rules), and Zig 0.16 std `std/compress/flate/` (MIT,
  local: `/nix/store/amh3bnymjncd56jwmd2hqdkciz9d7pys-zig-0.16.0/lib/zig/`).
- Local oracle: python3 3.14.7's `zlib` module (CPython, PSF license — used as
  a CLI, nothing vendored). Every incantation in §4.3 was run and round-tripped
  here before being written down; the hand-built streams in §3.2 were decoded
  by it to settle the bit-order questions empirically.

A note on the task brief: it said RFC 1951 "contains a worked example (a tiny
'deflate' of a string in §3.2.5/appendix)". It does not. RFC 1951 has **no
appendix and no complete worked-stream example**; its examples are the
micro-examples catalogued in §3.2 below (§3.2.2's code construction, §3.2.3's
overlap copy, §3.2.7's code-length repeat). The complete worked micro-streams
we do have are the golden vectors from Go's suite and two hand-built streams
verified against the oracle (§3.2). Recorded rather than smoothed over.

## 1. Format summary

A deflate stream is a sequence of blocks, each carrying 3 header bits
(BFINAL, BTYPE) that do **not** start on a byte boundary, followed by that
block's payload; the last block has BFINAL=1 (`rfc1951-deflate.txt §3.2.3`).
Three payload kinds: stored (BTYPE=00) — skip to a byte boundary, then
LEN/NLEN u16-LE and LEN raw bytes (`§3.2.4`); fixed-Huffman (BTYPE=01) — the
literal/length and distance code tables are the RFC's fixed tables (`§3.2.6`);
dynamic-Huffman (BTYPE=10) — the two code tables are transmitted first, in a
compressed form of their own (`§3.2.7`). BTYPE=11 is "reserved (error)"
(`§3.2.3`).

The payload of a Huffman block is a sequence of symbols from a single merged
literal/length alphabet (0-285): 0-255 literals, 256 end-of-block, 257-285
length codes, most followed by extra bits that select a length within the
code's base range (`§3.2.5`). Each length symbol is followed by a distance
symbol from the distance alphabet (codes 0-29), most followed by extra bits
selecting the backward distance (1-32,768) (`§3.2.5`). A distance may reach
back across block boundaries, up to 32 KiB into previously decoded output,
but never before the start of the output stream; the referenced string may
overlap the current position (RLE-style) (`§2`, `§3.2.3`). Trees are
independent per block; matches are not (`§2`).

Huffman codes here are *canonical*: all codes of a given bit length are
lexicographically consecutive in symbol order, and shorter codes precede longer
ones lexicographically; a code table is therefore fully determined by the list
of code lengths in symbol order (`§3.2.2`). The RFC gives the exact
construction algorithm (`§3.2.2`, steps 1-3, reproduced in §3.1 below).

Dynamic headers pack the two code-length lists using a third Huffman code
(the "precode") over a 19-symbol alphabet: 0-15 (a code length), 16 (repeat the
previous length 3-6 times, 2 extra bits), 17 (repeat zero 3-10 times, 3 extra
bits), 18 (repeat zero 11-138 times, 7 extra bits) (`§3.2.7`). The precode's
own lengths (3-bit values, max 7) are transmitted first, permuted into a fixed
scrambled order, and the two repeat streams form one sequence of
HLIT+HDIST+258 lengths that repeat codes may cross the middle of
(`§3.2.7`).

Worst case expansion: 5 bytes per 32-KiB block, "a size increase of 0.015% for
large data sets" (`§1.1`); stored blocks carry at most 65,535 bytes (`§2`,
LEN is 16 bits in `§3.2.4`). Block sizes are otherwise arbitrary, and blocks
of arbitrary size must be accepted by a compliant decompressor (`§3.3`).

### 1.1 The code tables (`rfc1951-deflate.txt §3.2.5`)

Length codes (merged alphabet 257-285); the extra-bits value offsets the base:

| code | extra | lengths | | code | extra | lengths | | code | extra | lengths |
|------|-------|---------|---|------|-------|---------|---|------|-------|---------|
| 257 | 0 | 3 | | 267 | 1 | 15,16 | | 277 | 4 | 67-82 |
| 258 | 0 | 4 | | 268 | 1 | 17,18 | | 278 | 4 | 83-98 |
| 259 | 0 | 5 | | 269 | 2 | 19-22 | | 279 | 4 | 99-114 |
| 260 | 0 | 6 | | 270 | 2 | 23-26 | | 280 | 4 | 115-130 |
| 261 | 0 | 7 | | 271 | 2 | 27-30 | | 281 | 5 | 131-162 |
| 262 | 0 | 8 | | 272 | 2 | 31-34 | | 282 | 5 | 163-194 |
| 263 | 0 | 9 | | 273 | 3 | 35-42 | | 283 | 5 | 195-226 |
| 264 | 0 | 10 | | 274 | 3 | 43-50 | | 284 | 5 | 227-257 |
| 265 | 1 | 11,12 | | 275 | 3 | 51-58 | | 285 | 0 | 258 |
| 266 | 1 | 13,14 | | 276 | 3 | 59-66 | | | | |

Distance codes (0-29), same scheme:

| code | extra | dist | | code | extra | dist | | code | extra | dist |
|------|-------|------|---|------|-------|------|---|------|-------|------|
| 0 | 0 | 1 | | 10 | 4 | 33-48 | | 20 | 9 | 1025-1536 |
| 1 | 0 | 2 | | 11 | 4 | 49-64 | | 21 | 9 | 1537-2048 |
| 2 | 0 | 3 | | 12 | 5 | 65-96 | | 22 | 10 | 2049-3072 |
| 3 | 0 | 4 | | 13 | 5 | 97-128 | | 23 | 10 | 3073-4096 |
| 4 | 1 | 5,6 | | 14 | 6 | 129-192 | | 24 | 11 | 4097-6144 |
| 5 | 1 | 7,8 | | 15 | 6 | 193-256 | | 25 | 11 | 6145-8192 |
| 6 | 2 | 9-12 | | 16 | 7 | 257-384 | | 26 | 12 | 8193-12288 |
| 7 | 2 | 13-16 | | 17 | 7 | 385-512 | | 27 | 12 | 12289-16384 |
| 8 | 3 | 17-24 | | 18 | 8 | 513-768 | | 28 | 13 | 16385-24576 |
| 9 | 3 | 25-32 | | 19 | 8 | 769-1024 | | 29 | 13 | 24577-32768 |

Two boundary traps, both load-bearing for the encoder: length 258 is code 285
with **zero** extra bits — code 284's stated range tops out at 257 (extra
30), and its extra 31 overshoots to 258 (accepted unclamped by the
references; see T5); and code 16 repeats a code length *3-6* times, so run
encoding pays off only for runs ≥ 3. The RFC's own example of the run codes
is in §3.2 below.

### 1.2 The fixed tables (`rfc1951-deflate.txt §3.2.6`)

| lit/len value | bits | codes |
|---------------|------|-------|
| 0-143 | 8 | 00110000 through 10111111 |
| 144-255 | 9 | 110010000 through 111111111 |
| 256-279 | 7 | 0000000 through 0010111 |
| 280-287 | 8 | 11000000 through 11000111 |

"Literal/length values 286-287 will never actually occur in the compressed
data, but participate in the code construction." Distances: "Distance codes
0-31 are represented by (fixed-length) 5-bit codes... Note that distance codes
30-31 will never actually occur in the compressed data." (`§3.2.6` — both
quotes verbatim.) With all 288 literal/length lengths counted, the fixed
table is a complete canonical code (24×2⁻⁷ + 152×2⁻⁸ + 112×2⁻⁹ = 1 exactly);
286-287 carry the two unused 8-bit codes 11000110, 11000111. A decoder that
builds only 286 entries gets identical codes for 0-285 (the ranges do not
interleave) — std `flate/token.zig:27-53` does exactly that.

### 1.3 The dynamic header layout (`rfc1951-deflate.txt §3.2.7`)

In stream order, after the 3 block-header bits:

1. 5 bits: HLIT = (# literal/length codes) − 257, "(257 - 286)"
2. 5 bits: HDIST = (# distance codes) − 1, "(1 - 32)"
3. 4 bits: HCLEN = (# precode lengths) − 4, "(4 - 19)"
4. (HCLEN+4) × 3 bits: precode code lengths, in the scrambled order
   **16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15**
   (values are 0-7; 0 means the precode symbol is unused)
5. HLIT+257 code lengths for the literal/length alphabet, precode-encoded
6. HDIST+1 code lengths for the distance alphabet, precode-encoded
   (repeat codes may cross the 5→6 boundary; the lengths are "a single
   sequence of HLIT + HDIST + 258 values")
7. the compressed data, then the end-of-block symbol 256

Degenerate rules, verbatim from `§3.2.7`: "If only one distance code is used,
it is encoded using one bit, not zero bits; in this case there is a single
code length of one, with one unused code. One distance code of zero bits
means that there are no distance codes used at all (the data is all
literals)." A code length of 0 means the symbol does not occur and "should
not participate in the Huffman code construction algorithm given earlier."

## 2. Requirements matrix

### 2.1 A conformant decoder must accept

The root obligation, `rfc1951-deflate.txt §1.4`: "a compliant decompressor
must be able to accept and decompress any data set that conforms to all the
specifications presented here", restated at `§3.3`: "A compliant decompressor
must accept the full range of possible values defined in the previous
section, and must accept blocks of arbitrary size."

| # | requirement | cite |
|---|-------------|------|
| D1 | Blocks of arbitrary size, including a single block spanning arbitrary input; no block-length limit exists in the format | `§3.3`, `§2` |
| D2 | The 3 header bits at any bit offset — "the header bits do not necessarily begin on a byte boundary" | `§3.2.3` |
| D3 | Stored blocks after arbitrary bit alignment (skip "any bits of input up to the next byte boundary"), LEN 0-65535, NLEN the one's complement of LEN, LEN raw bytes | `§3.2.4` |
| D4 | Fixed-Huffman blocks using exactly the tables of §3.2.6 | `§3.2.6` |
| D5 | Dynamic-Huffman blocks with any legal code-length lists, including: a single distance code of one bit; **zero** distance codes (HDIST field 0, all-literal data); repeat codes 16/17/18 crossing the HLIT/HDIST boundary | `§3.2.7` |
| D6 | All length codes 257-285 with their extra bits (3-258), all distance codes 0-29 with theirs (1-32,768) | `§3.2.5` |
| D7 | Distances reaching back across block boundaries up to 32 KiB, and overlapping references (`§3.2.3`'s `<length = 5, distance = 2>` example) | `§2`, `§3.2.3` |
| D8 | Over-subscribed Huffman code sets — rejected (`§3.2.2` step 2 arithmetic implies the Kraft inequality; references enforce it, see T3) | `§3.2.2` |
| D9 | BTYPE=11 — "reserved (error)"; must fail, not guess | `§3.2.3` |
| D10 | A distance before the start of the output stream — must fail: "a distance cannot refer past the beginning of the output stream" | `§3.2.3` |
| D11 | An empty stream (a single final empty block), and an empty *non-final* block mid-stream | `§3.2.3`, `§3.2.4` (LEN 0 is legal) |

Reference hardening the RFC does not state (see §2.3): reject distance codes
30-31 and literal/length codes 286-287 anywhere they could be decoded
(`§3.2.5`'s tables stop at 29 and 285; `§3.2.6` says both pairs "will never
actually occur"); reject incomplete code sets except the single-1-bit-code
degenerate case; require the EOB symbol to be codeable. Each of these is a
parent decision, not a spec fact.

### 2.2 A conformant encoder must emit

`rfc1951-deflate.txt §1.4`: "a compliant compressor must produce data sets
that conform to all the specifications presented here." `§3.3` explicitly
relaxes the value ranges on the *compressor* side: "A compressor may limit
further the ranges of values specified in the previous section and still be
compliant; for example, it may limit the range of backward pointers to some
value smaller than 32K. Similarly, a compressor may limit the size of blocks
so that a compressible block fits in memory." Section 4's algorithm ("The
material in this section is not part of the definition of the specification
per se, and a compressor need not follow it in order to be compliant") is
advice, not a requirement.

| # | requirement | cite |
|---|-------------|------|
| E1 | BFINAL set "if and only if this is the last block of the data set" | `§3.2.3` |
| E2 | Every block terminated by the end-of-block symbol 256, encoded with the block's literal/length code (implied by `§3.2.7`'s block definition and `§3.2.3`'s decode loop) | `§3.2.7`, `§3.2.3` |
| E3 | Canonical code assignment: same-length codes lexicographically consecutive in symbol order, shorter codes lexicographically first; "Codes that are never used (which have a bit length of zero) must not be assigned a value" | `§3.2.2` |
| E4 | Huffman codes "must not exceed certain maximum code lengths" — 15 bits for literal/length and distance codes (the precode alphabet represents lengths 0-15), 7 for the precode itself (3-bit fields) | `§3.2.1`, `§3.2.7` |
| E5 | Distances ≤ 32,768 and ≥ 1; lengths 3-258; distances never before the start of the output stream | `§3.2.5`, `§3.2.3`, `§2` |
| E6 | Stored blocks: NLEN the one's complement of LEN; LEN ≤ 65,535; payload byte-aligned | `§3.2.4`, `§2` |
| E7 | The three packing rules of `§3.1.1` (see §3 below) — the #1 corruption risk | `§3.1.1` |
| E8 | Dynamic headers: HDIST may be 0 (zero distance codes); a single used distance code must be given length 1, "not zero bits"; the precode lengths transmitted in the exact scrambled order | `§3.2.7` |
| E9 | Worst-case output bound: 5 bytes per 32-KiB block over the input — the sizing helper's contract | `§1.1` |

The Kraft inequality is not stated as a compressor requirement in so many
words; it is forced by E3+E4: the canonical construction over legal lengths
either fills the code space exactly or leaves it incomplete, and an encoder
that emits a complete code (it should — a deliberately incomplete code is
legal only in the single-code degenerate cases the RFC spells out for
*decoders* in `§3.2.7`) satisfies it implicitly. A dynamic-header encoder
edge case the RFC allows: incomplete trees are only decoder-legal in the
single-1-bit-code case, so an encoder that uses exactly one distance symbol
must still give it length 1 (E8).

### 2.3 Spec-vs-reference divergences (decisions for the parent)

The RFC is silent or self-contradictory in exactly the corners where every
implementation has to pick. Recorded both sides; not silently picked.

- **T1 — extra-bits order.** `§3.1.1` bullet 2: "Data elements other than
  Huffman codes are packed starting with the least-significant bit of the
  data element." But `§3.2.5`: "The extra bits should be interpreted as a
  machine integer stored with the most-significant bit first, e.g., bits 1110
  represent the value 14." Read literally, the second sentence says the
  *first* extra bit on the wire is the value's MSB — the opposite of bullet 2.
  `§3.1.1`'s closing "print it right-to-left and fixed-width elements come out
  in the correct MSB-to-LSB order" paragraph feeds the same confusion. The
  wire truth (zlib lineage, verified here against the oracle with hand-built
  streams, §3.2): **extra bits pack LSB-of-value first**, exactly like every
  other non-Huffman element; the `§3.2.5` sentence describes the *numeral*
  ("1110" is how you write 14), not the transmission order. Ranked #1 in §7.
- **T2 — degenerate literal/length trees and the missing EOB.** `§3.2.7`
  spells out the single-code and zero-code rules for *distance* codes only.
  For the literal/length tree it is silent on (a) a tree whose only code is
  256 (an empty block) and (b) a complete tree with no code for 256. Behavior:
  zlib's `inflate` accepts both tree shapes (incomplete is legal when the
  longest code is 1 bit — madler/zlib `inftrees.c:147` `if (left > 0 && (type
  == CODES || max != 1)) return -1`), and a missing EOB then surfaces later
  as a stream that cannot terminate; Go accepts the empty-block shape (its
  TestStreams vectors "degenerate HLitTree" decode to "") and rejects the
  "empty HLitTree" (no codes at all) as invalid; Zig std rejects the missing
  EOB up front (`Decompress.zig` `MissingEndOfBlockCode`, HuffmanDecoder
  `checkCompleteness`). Decision: which error, and up front or on demand.
- **T3 — HDIST/HLIT caps vs the RFC's parentheticals.** `§3.2.7` says HDIST
  covers "(1 - 32)" codes and HLIT "(257 - 286)", but the `§3.2.5` tables
  define no base/extra for distance codes 30-31 or length codes 286-287, and
  `§3.2.6` says both pairs never occur. The reference lineage caps the
  alphabets: zlib rejects `nlen > 286 || ndist > 30` ("too many length or
  distance symbols", madler/zlib `inflate.c:791-793`, i.e. a dynamic header
  declaring 31-32 distance codes is *invalid* on the wire even though the
  RFC's parenthetical reads as permitting it); Go agrees (TestStreams:
  "empty HDistTree of excessive length 31" → fail, "of normal length 30" →
  ok); std agrees (`HuffmanDecoder(30, 15, 9)`). Oracle-verified here: the
  "length 31" vector is rejected with "too many length or distance symbols"
  and a fixed block using symbol 287 is rejected ("invalid literal/length
  code"). Decision: our decoder follows the references (caps at 286/30) and
  the notes record that an RFC-literal decoder would differ.
- **T4 — stream endings.** A final *empty* block is the standard ending, but
  references disagree on its type: Go ends with an empty **fixed** block
  (`deflate_test.go` golden: empty input, level 0 → `03 00`; one byte, level 0
  → stored block then `03 00`); zlib ends an empty level-0 stream with an
  empty **stored** block (`01 00 00 ff ff`, verified: python3
  `compressobj(0, DEFLATED, -15)` close), and levels 1-9 with `03 00`
  (verified). Both are legal (`§3.2.3`, `§3.2.4`); a decoder must accept
  both. Our encoder picks one — parent decision, cosmetic.
- **T5 — table arithmetic vs the stated ranges (code 284 + extra 31).** The
  `§3.2.5` length table assigns code 284 the range 227-257 (5 extra bits, 31
  of the 32 possible values) and length 258 to code 285 alone — but the
  arithmetic `base + extra` lets 284 with extra bits 31 express 258, and the
  references compute it unclamped: Go's TestStreams vector "use valid HLit
  symbol 284 with count 31" expects exactly that (verified here: the vector
  decodes via the oracle to 259 bytes — a 1-byte literal plus a 258-byte
  match). So a decoder that clamps to the table's stated ranges rejects a
  stream the entire reference lineage accepts; ours must compute unclamped
  (or clamp only where the RFC's own single-value codes force it — code 285
  has 0 extra bits, so no clamping question exists there). It is the only
  length/distance code whose extra-bit space exceeds its stated range (all
  others are exact). Our encoder, of course, uses 285 for 258 (E-table
  trap, §1.1).

## 3. Byte-level packing rules for the encoder

The #1 corruption risk. The rules, verbatim from `rfc1951-deflate.txt
§3.1.1` ("we must therefore specify how to pack these data elements into
bytes"):

- "Data elements are packed into bytes in order of increasing bit number
  within the byte, i.e., starting with the least-significant bit of the byte."
- "Data elements other than Huffman codes are packed starting with the
  least-significant bit of the data element."
- "Huffman codes are packed starting with the most-significant bit of the
  code."

Plus `§3.1`: bytes have bit 0 as the LSB ("|76543210|"), and "All multi-byte
numbers in the format described here are stored with the least-significant
byte first (at the lower memory address)" — LEN/NLEN (`§3.2.4`) and every
multi-byte field.

Assembling the encoder's write operations from those rules:

- **Bit fill**: the first bit written goes to bit 0 of the next byte; a
  9th bit spills into bit 0 of the following byte.
- **BFINAL (1 bit) / BTYPE (2 bits)**: BFINAL first, then BTYPE's two bits
  LSB-of-value first (BTYPE=01 fixed emits stream bits `1,0` after BFINAL=1).
  Empirically settled by the §3.2 hand-built streams — a stream with header
  bits `1,1,0` decodes as a final fixed block; with MSB-first BTYPE it would
  read as dynamic and fail.
- **A Huffman code**: written MSB-of-code first. The fixed code for literal
  65 is `01110001` (`§3.2.6` table), so the stream bits are
  `0,1,1,1,0,0,0,1` in that order — i.e. the code appears *bit-reversed*
  relative to its numeral. Implementation shape: store codes pre-reversed
  (std `flate/token.zig:39` does `@bitReverse`; Go's `reverseBitsTests`
  exercise the same), or reverse at emission.
- **Extra bits (length/distance/precode-repeat)**: an ordinary data element —
  LSB-of-value first (T1). The length code 269 with extra value 1 emits the
  two stream bits `1,0`.
- **LEN/NLEN**: u16, least-significant byte first, after byte alignment.
- **Stored-block padding**: "Any bits of input up to the next byte boundary
  are ignored" (`§3.2.4`) — the encoder pads with zero bits to alignment;
  a decoder must not require the padding to be zero (a mid-stream resync
  after a corrupted block could land on any padding).
- **Stream end**: pad the final partial byte with zero bits.

### 3.1 Canonical code construction (`rfc1951-deflate.txt §3.2.2`)

Verbatim algorithm (it is normative for both header generation and any
encoder-side cost estimates):

1. `bl_count[N]` = number of codes of length N (N ≥ 1).
2. `code = 0; bl_count[0] = 0; for (bits = 1; bits <= MAX_BITS; bits++) {
   code = (code + bl_count[bits-1]) << 1; next_code[bits] = code; }`
3. `for (n = 0; n <= max_code; n++) { len = tree[n].Len; if (len != 0) {
   tree[n].Code = next_code[len]; next_code[len]++; } }` — with
   "Codes that are never used (which have a bit length of zero) must not be
   assigned a value."

The RFC's worked example (`§3.2.2`, "Example:"), for the alphabet ABCDEFGH
with bit lengths (3, 3, 3, 3, 3, 2, 4, 4):

```
N      bl_count[N]          N      next_code[N]
-      -----------          -      ------------
2      1                    1      0
3      5                    2      0
4      2                    3      2
                            4      14

Symbol Length   Code        (read MSB-first; these are the numerals)
------ ------   ----
A       3        010
B       3        011
C       3        100
D       3        101
E       3        110
F       2         00
G       4       1110
H       4       1111
```

Same section, first example: alphabet ABCD with lengths (2, 1, 3, 3) codes as
A=10, B=0, C=110, D=111 ("0 precedes 10 which precedes 11x").

### 3.2 Worked micro-examples (RFC's own, plus oracle-verified streams)

RFC 1951 gives exactly these; no others exist (no appendix, no complete
stream):

- `§3.1`: the decimal number 520 stored as `00001000 00000010` (LSB first).
- `§3.2.2`: the tree, recode, and construction examples above.
- `§3.2.3`: "if the last 2 bytes decoded have values X and Y, a string
  reference with <length = 5, distance = 2> adds X,Y,X,Y,X to the output
  stream" — the overlapping-copy semantics.
- `§3.2.7`: "Codes 8, 16 (+2 bits 11), 16 (+2 bits 10) will expand to 12
  code lengths of 8 (1 + 6 + 5)" — the arithmetic: code 16's extra bits 0-3
  mean 3-6 repeats of the *previous* length, so `11` (value 3) = 6 copies
  and `10` (value 2) = 5 copies; 1 + 6 + 5 = 12 lengths of 8. The 3-repeat
  floor is why code 17 (3-10 zeros) and 18 (11-138 zeros) exist: two-digit
  zero runs are cheaper as two literal 0-lengths than a 16.

The two hand-built streams below were constructed here and decoded by the
oracle (python3 zlib, raw −15) — they are the byte-level packing proof, and
they double as golden micro-fixtures for the tests:

```
Stream 1 (fixed Huffman): literal 'A', match length 20 (code 269 = base 19
+ extra 1) at distance 1 (code 0), EOB. Stream bits, in order:
  header 1,1,0 | lit65 code 01110001 | len269 code 0001101 | extra 1,0 |
  dist code 00000 | EOB 0000000 | zero pad
Packed (first bit -> bit 0 of byte 0): 73 c4 06 00
Decodes (zlib -15) to 21 bytes of 'A'. With extra bits [0,1] instead: value 2,
length 21, 22 bytes — the flip proves the LSB-first extra-bits rule.

Stream 2 (fixed Huffman): 70 literals 'A', then match length 3 (code 257,
no extra) at distance 67 (code 12 = base 65 + extra value 2, bits
[0,1,0,0,0] LSB-first), EOB. Decodes to 73 bytes of 'A' — 70 literals + a
3-byte match from distance 67. MSB-first reading of those extra bits would
give distance 73, past the 70-byte history, which the reference rejects
("invalid distance too far back"); the clean decode proves the distance
extra-bits order independently.
```

### 3.3 Dynamic-header emission checklist (for the encoder slice)

1. Count lit/len and distance symbol frequencies over the tokenized block;
   include the EOB (256) with count ≥ 1.
2. Build canonical codes (lengths ≤ 15) from the frequencies.
3. Trim: HLIT = 257 + (index of the last nonzero literal/length length),
   HDIST likewise for distances; a block with no matches has HDIST = 0
   (zero distance codes, legal, `§3.2.7`); a block with exactly one used
   distance symbol gives it length 1 (`§3.2.7`).
4. Serialize the HLIT+257 + HDIST+1 lengths as one sequence, RLE-coding with
   16/17/18; the repeats may cross the lit/dist boundary.
5. Build the precode over the 19-symbol alphabet from the RLE stream's
   symbol frequencies (precode lengths ≤ 7; the RFC's 3-bit fields force
   it, `§3.2.7`/E4).
6. Emit HLIT, HDIST, HCLEN = 4 + (number of nonzero precode lengths,
   truncated to the last nonzero in the scrambled order), the precode
   lengths in the scrambled order (3 bits each, LSB-first — they are
   non-Huffman data elements), then the RLE stream (precode symbols as
   Huffman codes MSB-first, their extra bits LSB-first), then the data.

## 4. Fixture inventory

### 4.1 golang/go `src/compress/flate/` (BSD-3-Clause)

Test files (all "Copyright ... The Go Authors", BSD-style license in the repo
LICENSE):

- **`flate_test.go` — `TestStreams` (27 hex vectors): the primary conformance
  table.** Every degenerate dynamic-header corner: degenerate/empty HCLenTree,
  empty and degenerate HLitTree/HDistTree, missing-symbol uses, excessive
  repeater code, HDistTree "of normal length 30" (decodes) vs "excessive
  length 31" (fails), over-/under-subscribed trees, a spanning repeat code,
  symbol 284 with count 31 (a 258-byte match — see T5), reserved symbol 287
  (fails),
  a raw stored block, and the issue-10426/11030/11033 regressions (oversubscribed
  precode hang; empty HDistTree acceptance). The file's own comment documents
  the oracle incantation. Also `TestTruncatedStreams` (every prefix of a
  26-byte two-block stream must fail closed) and the huffman `init` edge
  cases (`TestIssue5915/5962/6255`, `TestInvalidBits`).
- **`deflate_test.go` — `deflateTests` (15 rows, input/level/expected-output
  bytes).** As *encoder* goldens they assert Go's exact heuristics and do not
  port (same rationale as the snappy README's "encoder golden vectors"
  section: deflate mandates no canonical encoding). As *decoder* goldens they
  port perfectly: every `out` is a valid stream that must decode to `in`
  (stored blocks with LEN/NLEN; fixed blocks; the `03 00` empty stream;
  verified here for the empty and one-byte cases). Also
  `deflateInflateStringTests`' corpus: `../testdata/e.txt` (97.7 KB of
  digits of e — `src/compress/testdata/e.txt`) and
  `../../testdata/Isaac.Newton-Opticks.txt` (553.9 KB, `src/testdata/`),
  round-tripped at all levels with size ceilings.
- **`inflate_test.go` — `TestReaderTruncated` (10 vectors)**: truncated stored
  headers, partial fixed-block payloads, mid-match truncation — all must fail
  closed with a short-read error, never panic.
- **`huffman_bit_writer_test.go` + `testdata/huffman-*`: 9 `.in`/`.golden`
  pairs plus `.dyn/.sync/.wb` `.expect` variants.** `.in` is the *uncompressed*
  input, `.golden` the expected `writeBlockHuff` (huffman-only) output;
  verified here: `huffman-zero.golden` decodes via the oracle to exactly
  `huffman-zero.in`. The `.expect` files are Go-heuristic byte-exact encoder
  outputs (not portable as ours), but every one is a valid stream worth
  feeding the decoder. The family covers: 64 KiB of one byte (the
  degenerate-huffman bug case), digits of pi, 1 KiB random, a 64 KiB random
  tail, single-byte runs with shifts, a 299-byte text, a 253-byte text with
  matches, and a 64 KiB random max case. `null-long-match.*` (token lists
  with no input) is encoder-internal.
- `writer_test.go` (error persistence, determinism across write sizes,
  wraparound), `dict_decoder_test.go` (preset dictionaries — out of scope for
  M2, revisit with T2), `fuzz_test.go` + `testdata/fuzz/` (seed corpus).

**Vendor:** the `TestStreams` table and `TestReaderTruncated` ported into a
`golden.zig`-style fixtures module (the snappy pattern: shared by every
layer's tests, attribution in `THIRD_PARTY.md`); the `deflateTests` rows as
decode goldens; the 9 `.in`/`.golden` pairs as binary fixtures; the corpus
texts `e.txt` and `Isaac.Newton-Opticks.txt`, plus `Mark.Twain-Tom.Sawyer.txt`
— **note: the task brief named it under flate's `testdata/`, but Go removed
it from `src/compress/testdata/` (today: `e.txt`, `gettysburg.txt`,
`pi.txt`); it lives on in klauspost/compress `testdata/` (BSD-3-Clause), which
is the vendoring source.** The `.expect` family: optionally, as extra valid
decoder inputs. The task brief's "`.Z`-derived inputs" does not correspond to
anything in the current suite — there are no `.Z` files; the `.in`/`.golden`
family above is what exists (recorded, not guessed at).

### 4.2 RFC 1951's own examples

`rfc1951-deflate.txt §3.2.2` (canonical construction, ABCDEFGH table above),
`§3.2.3` (overlap copy), `§3.2.7` (repeat expansion), `§3.1` (520 as two
bytes). Cite these directly in tests per the house spec-first rule; the
`§3.2.2` table is the natural fixed-header emission test. Also in-tree and
free: Zig std's four raw golden micro-streams (`std/compress/flate/
Decompress.zig:858-877`: stored/fixed/dynamic blocks, "Hello world\n") and
its `token.zig` code tables, local under the flake (MIT).

### 4.3 The local oracle: python3 zlib (verified by running)

CPython 3.14.7's `zlib` (PSF license; used as a CLI, nothing vendored). All
four incantations round-tripped here on a 208-byte buffer before writing:

```python
import zlib

# raw deflate compress (no container), level 1-9 (0 = stored-only, -2 = huffman-only)
co = zlib.compressobj(level, zlib.DEFLATED, -15)
raw = co.compress(data) + co.flush()

# raw deflate decompress
do = zlib.decompressobj(-15)
out = do.decompress(raw) + do.flush()
assert out == data

# one-shot oracle check of a hex-encoded stream (Go's flate_test.go documents
# the same trick; modern spelling:)
zlib.decompress(bytes.fromhex("010100feff11"), -15)   # -> b'\x11'

# zlib container (RFC 1950) — M3 lanes; wbits=15 is the default in zlib.compress
zw = zlib.compress(data, level)
assert zlib.decompress(zw) == data

# gzip container (RFC 1952) — M3 lanes
import gzip
assert gzip.decompress(gzip.compress(data, level)) == data
```

Negative `wbits` = raw; 15 = zlib-wrapped; 16+15 (31) = gzip/autodetect.
`gzip`/`gunzip` 1.14 is also on PATH for container-lane CLIs at M3.
Conformance lanes run both directions over the committed corpus: our encoder
→ oracle decode, oracle encode → our decode, at levels {0, -2, 1, 6, 9}.

## 5. Competitor inventory

The benchmark plan (`docs/zcompress-plan.md`, "Benchmark methodology") pins
the flate competitor set: klauspost/compress and std.compress always, plus
the strongest native library on each box (libdeflate/zlib-ng for this
family). What each one's numbers will mean, and what the fast encoder should
copy conceptually for the "klauspost level-1 class" target:

### 5.1 klauspost/compress flate (BSD-3-Clause) — the class target

Read: `flate/deflate.go`, `flate/fast_encoder.go`, `flate/level1.go`,
`flate/level2.go`, `flate/huffman_bit_writer.go`.

- **Levels 1-6** are snappy-descended single-table greedy encoders
  (`fast_encoder.go:19-38` `newFastEnc`; `level1.go` header: "Copyright 2011
  The Snappy-Go Authors... Modified for deflate by Klaus Post"). Level 1
  (`fastEncL1`): one `[1 << 15]tableEntry` table (32,768 single-slot u32
  offsets — 128 KiB, no chains), **5-byte hash** (`hashLen(cv, tableBits=15,
  hashBytes=5)`, `prime5bytes = 889523592379`), the snappy skip heuristic
  (`nextS = s + 2 + (s-nextEmit) >> 5`, `skipLog=5`, `doEvery=2`,
  `inputMargin=11`), **no lazy matching** (greedy), 4-byte match confirmation
  (`uint32(cv) == load3232(src, t)`), match extension via
  `matchlenLong` plus **backward** extension into the preceding literals,
  `maxMatchOffset = 1 << 15`, matches split at 258 with the final chunk kept
  ≥ 3 (`level1.go` inlined `AddMatchLong`: cap 258, else 255, so the tail
  never lands below the 3-byte minimum).
- **Levels 7-9** are hash-chain lazy matchers (`deflate.go` `levels` table:
  good/lazy/nice/chain 8/12/16/24, 16/30/40/64, 32/258/258/1024;
  `hashHead [1<<17]uint32` + `hashPrev [windowSize]uint32`), with a
  cost-estimate `findMatch` at chain > 100.
- **Block/huffman policy** (`deflate.go` `storeFast` + `huffman_bit_writer.go`):
  64-KiB blocks (`maxStoreBlockSize` = 65535); no matches → stored; tokens
  > 15/16ths of the window → huffman-only block; else `writeBlockDynamic` —
  dynamic huffman **with cross-block table reuse** (`canReuse`, `lastHeader`,
  `logNewTablePenalty = 7`), fixed considered only for tiny blocks
  (`tokens.n < maxPredefinedTokens` = 250, `token.go:31`), stored when it
  wins. **So: klauspost level 1 emits dynamic blocks, not fixed.**
  `close()` ends with a final empty stored block (`writeStoredHeader(0,
  true)`); `Flush()` is a sync marker.
- **Inflate**: code-generated per-input-shape specializations
  (`inflate_gen.go`, "Code generated by go generate gen_inflate.go"),
  inlined per-symbol state machines — architecturally the Go stdlib
  decoder with buffer-shape clones and register tricks, not a redesign.

Copy conceptually for our fast level: the `fastEncL1` shape entire —
single-slot 2^15 table, 5-byte hash, accelerating skip, greedy, 4-byte
confirm, backward extension, 258/255 split, 64-KiB blocks, stored fallback;
plus a cheapest-of-three block decider at the ratio mode.

### 5.2 ebigers/libdeflate (MIT) — the strongest native inflate/deflate on x86

Read: `README.md`, `lib/deflate_compress.c`, `lib/ht_matchfinder.h`.

Whole-buffer API, deliberately no streaming ("if your application compresses
large files as a single compressed stream... libdeflate isn't for you"). 12
levels: **1 = `deflate_compress_fastest`** — `ht_matchfinder` (single-slot
hash table, `HT_MATCHFINDER_MIN_MATCH_LEN 4`), greedy, fixed-size 64-KiB
blocks (`FAST_SOFT_MAX_BLOCK_LENGTH 65535`, `FAST_SEQ_STORE_LENGTH 8192`
sequences), `nice_match_length = 32`; block type chosen by exact bit-cost
comparison of dynamic vs static(fixed) vs uncompressed
(`deflate_flush_block` — dynamic usually wins, static wins on small or
flat-histogram blocks). 2-4 greedy with hash chains (`hc_matchfinder`),
5-7 lazy, 8-9 lazy2, 10-12 near-optimal (min-cost-path over a binary-tree
matchfinder, multi-pass, static-block optimization at 11-12;
`MIN_BLOCK_LENGTH 5000`, `SOFT_MAX_BLOCK_LENGTH 300000`). Runtime CPU
feature dispatch, hand-tuned SIMD (match copy, Adler-32, CRC-32). Numbers
mean: the ceiling a C whole-buffer implementation reaches on each fleet box;
its level-1 ratio/throughput point is the honest target band for our fast
level.

### 5.3 zlib-ng (zlib license) — the fastest *fixed-huffman* level 1

Read: `README.md`, `deflate_quick.c`, `deflate.c` (`configuration_table`).

zlib API-compatible streaming fork; "Deflate medium and quick algorithms
based on Intel's zlib fork", SIMD everywhere (compare256, slide_hash, inflate
chunk copying, CRC32-B with PCLMUL, Adler-32), "x86-64 can be about 4x faster
than stock zlib". Level 1 is `deflate_quick` (`deflate.c`
`configuration_table[1] = {0,0,0,0, deflate_quick}`): **fixed trees only**
(`quick_start_block` emits `STATIC_TREES`), 4-byte Knuth hash reading only
the chain head ("only reads the hash chain head, so it can skip prev
maintenance", `deflate.c:141`), 4-byte confirm + `compare256` extension,
byte-at-a-time literal fallback, no skip heuristic. This is the one
first-tier implementation whose fastest level is fixed-only — the datapoint
behind OQ1's fixed-first recommendation. The rest of its table
(`deflate.c:108-133`): level 2 is zlib's `fast`, levels 3-6 use Intel's
`medium`/`medium_fizzle` (hash chains), 7-9 zlib's `slow` (lazy).

### 5.4 std.compress.flate (Zig 0.16, MIT) — the in-tree baseline to beat

Read locally: `std/compress/flate/{flate.zig,Compress.zig,Decompress.zig,
token.zig}`. A Go-port lineage in Zig clothing (the plan's phrase).

- **API shape**: streaming-only. `Compress.init(output: *Writer, buffer: []u8,
  container: flate.Container, opts: Options)` — `Container` (raw/gzip/zlib,
  with header/footer/hashers) lives *inside* flate; buffer asserted
  ≥ `flate.max_window_len` = 65,536 (`flate.zig:5-7`: `history_len = 32768`,
  `max_window_len = history_len * 2`); zero heap allocation ("Allocates
  statically ~224K (128K lookup, 96K tokens)"). `Decompress.init(input,
  container, buffer)` — a zero-length buffer selects a mode that decodes
  straight into the consuming writer; otherwise ≥ 65,536,
  rebase preserves the trailing 32 KiB (`Decompress.zig` `rebase`:
  `assert(capacity <= r.buffer.len - flate.history_len)`). No one-shot
  buffer-to-buffer functions exist.
- **Encoder**: zlib-configuration hash chains at every level
  (`Compress.zig:275-296`: good/nice/lazy/chain — level_1 = 4/8/0/4, ...
  level_9 = 32/258/258/4096, "Default paramaters are taken from zlib"),
  15-bit head + 32,768-entry chain, 3-byte sequence hash
  (`seq_bytes = 3`, Fibonacci multiplier `0x9E3779B1`), lazy matching above
  the `lazy` threshold, 2^15 tokens buffered with frequency histograms, and
  `writeBlock` choosing the cheapest of stored/fixed/dynamic per block
  (`Compress.zig:880-1020`). There is no klauspost-style single-table fast
  path — its fastest level is a 4-deep chain walk.
- **Decoder**: a per-symbol state machine (`State` union with per-literal/
  per-match states), a `HuffmanDecoder(alphabet, max_bits, lookup_bits=9)`
  two-level table (9-bit primary + linked-list chase for longer codes,
  puff.c-style completeness checks, `MissingEndOfBlockCode` up front —
  stricter than zlib, see T2), one 15-bit `peekIntBitsShort` + one `find`
  per symbol, `@bitReverse` on fixed-block code reads (`readFixedCode`).
  That per-symbol shape is the known slowness: no multi-symbol decode table
  (libdeflate and klauspost both decode several symbols per refill), a
  state-machine transition per literal, and a linked chase per >9-bit
  code.

Numbers mean: the "correct but scalar" baseline. Our decoder's win is
exactly where libdeflate's and klauspost's are — decode tables that resolve
multiple bits per step, vectorized match copies, batched literal runs —
and our encoder's win is the missing single-table fast level.

## 6. Open questions with recommendations

Decisions deferred to the API sketch; each labeled with its recommendation.

- **OQ1 — Encoder huffman strategy: fixed-only first, or dynamic from the
  start?** *Recommendation: fixed-only + stored fallback for the fast level;
  dynamic as the ratio mode once the fast path wins.* Grounds: fixed emission
  is branch-light (no header, no precode, no table build — one shift-add per
  symbol), which is why zlib-ng's fastest level is fixed-only (§5.3); but
  klauspost L1 and libdeflate L1 both pay for dynamic headers at their
  fastest level and still lead the speed class, so dynamic-with-reuse is
  defensible from day one. Note the plan's "klauspost level-1 class" is about
  the *match finder* class (single-slot hash table, greedy), not the huffman
  mode — klauspost L1 itself emits dynamic (§5.1). Ratio cost of fixed on
  text: literals cost 8/9 bits vs dynamic's ~5, so the fleet ratio gap will
  be visible; the fleet decides whether the fast level ships fixed-only or
  gains a dynamic sibling.
- **OQ2 — Surface shape.** *Recommendation: whole-stream one-shot functions
  (`compress`/`decompress` over source/target buffers, plus a
  `maxCompressedLength` sizing helper) + the Reader/Writer streaming layer
  copying the snappy pattern — with three deviations, all forced by the
  format:* (a) **no framing of our own** — the deflate stream is
  self-delimiting via BFINAL (snappy's Reader/Writer add `u32-le` framing
  precisely because raw snappy blocks are not); (b) **no
  `decompressedBlockLength` equivalent** — a raw deflate stream declares no
  decoded length anywhere, so one-shot `decompress` takes `target` as a cap
  and returns the decoded length or `error.BufferTooSmall` (the zlib/gzip
  containers that do declare sizes are M3, built on this); (c) **the Reader
  cannot stage whole compressed blocks** — huffman blocks have no compressed
  length prefix, so the natural Reader decodes directly from the input
  `Io.Reader` with a bit reader — std `Decompress`'s precedent: both of its
  vtable modes decode incrementally from `input` and never stage compressed
  bytes (§5.4) — rather than snappy's stage-a-block design. Confirmed against std:
  std is streaming-only with the container inside flate; our one-shot layer
  is an addition, and our flate stays raw-only (containers are separate M3
  codecs per the plan's build order).
- **OQ3 — Match-finder shape for the fast level.** *Recommendation: port the
  klauspost L1 finder (it is the class target and the snappy encoder's
  sibling):* single-slot `[1 << 15]` table, 5-byte hash, greedy (lazy off —
  unanimous at level 1: klauspost L1, libdeflate L1, zlib-ng quick, zlib
  level 1, std level_1 all lazyless), 4-byte confirm, the accelerating skip,
  backward extension, distance cap 32 KiB, min match **4** (all three fast
  references agree; 3-byte matches are left to the ratio mode — they cost a
  length symbol + distance symbol each and add hash noise), block sizing
  64 KiB for the one-shot path (the stored-block cap; klauspost's
  `maxStoreBlockSize` and libdeflate's `FAST_SOFT_MAX_BLOCK_LENGTH` are both
  65535). Alternative on the table: std/zlib's 3-byte hash-chain at chain=4
  (better ratio, slower per byte — it is the baseline we are beating).
- **OQ4 — Buffer types and sizes.** The snappy precedent is named
  exact-pointer types; flate's window semantics change the design: **matches
  reach backwards across block boundaries** (`rfc1951-deflate.txt §2`,
  `§3.2.3`), so unlike snappy's independent blocks, the Reader's serving
  region *is* the history and must retain the last 32 KiB of decoded output
  across rebases. Sketch (std's `flate.zig:5-7` is the precedent — buffer
  65,536 = 2× window, rebase preserves 32,768):
  `ReaderBuffer = [2 * 32 KiB]u8` — one window of fresh decoded output plus
  the 32-KiB history preserve, decoded straight from `input` (no compressed
  staging region at all, per OQ2c; the bit reader needs only a few bytes of
  lookahead). Contiguity cap: contiguous decoded reads can span up to
  `buffer.len − history_len` ≈ 32 KiB minus what is unconsumed — tighter than
  snappy's two blocks, and the API must state it (peek beyond → fail closed,
  not assert). `WriterBuffer`: the accumulation block (64 KiB) plus the
  32-KiB match history across emitted blocks ≈ 96 KiB, with the encoder hash
  table (2^15 × u16 = 64 KiB, or u32 = 128 KiB if klauspost's wraparound
  arithmetic is ported) as comptime-sized stack scratch like snappy's, and
  the compressed-output scratch stack-local. Sizes are API-sketch decisions;
  the 32-KiB-retain invariant is not (it is the format's).
- **OQ5 — Error taxonomy for decode.** std's set (`InvalidCode`,
  `InvalidMatch`, `WrongStoredBlockNlen`, `InvalidBlockType`,
  `InvalidDynamicBlockHeader`, `OversubscribedHuffmanTree`,
  `IncompleteHuffmanTree`, `MissingEndOfBlockCode`, `EndOfStream`) plus
  zlib's wire messages ("too many length or distance symbols", "invalid
  distance too far back", "invalid literal/length code") cover the space;
  snappy's pattern (a coarse public error + a detailed `err` field) is the
  house fit. Includes the T2/T3 calls: missing-EOB (reject — where is a
  decision), 286-287/30-31 (reject, matching the reference lineage),
  single-code trees (accept), HDIST > 30 codes (reject). Recommendation:
  follow the reference lineage everywhere the RFC is silent, and document
  each as a divergence row (T-table above) so the conformance suite pins
  the behavior deliberately.
- **OQ6 — Preset dictionaries.** Out of scope for M2 (the plan's flate
  milestone says nothing about them; the RFC's preset-dictionary note is a
  parenthetical in `§3.2.3`). The decoder surface should not preclude adding
  them (Go's `Resetter`/`NewReaderDict` is the precedent), but nothing in
  the API sketch should carry them. Deferred, not designed.

## 7. Ranked ambiguities — the three most likely to bite

1. **The extra-bits order (T1).** `rfc1951-deflate.txt §3.1.1` bullet 2 and
   `§3.2.5`'s "most-significant bit first... bits 1110 represent the value
   14" read as opposite rules, and `§3.1.1`'s right-to-left-printing
   paragraph muddies it further. The wire truth — first extra bit on the
   wire is the value's **LSB** — is settled only by the reference lineage;
   it was verified here empirically in both directions (length extra bits
   and distance extra bits; see the streams in §3.2). Every implementer who
   reads only `§3.2.5` emits MSB-first and produces streams that reference
   decoders misread by a bit-reversal — or worse, that still round-trip
   against their own decoder while failing every other one. The tests must
   carry the §3.2 streams as fixtures, and the encoder's bit writer must
   name the two paths differently (`writeCode` vs `writeBits`) so the
   distinction cannot be lost.
2. **Degenerate dynamic trees (T2 + D5).** A single 1-bit distance code, and
   zero distance codes, are explicitly legal (`§3.2.7`); a literal/length
   tree whose only code is the EOB (an empty block) is legal by reference
   behavior but unaddressed by the RFC; a complete tree missing the EOB code
   is unaddressed and the references split (std rejects up front; zlib
   accepts the tree and dies at stream end). A decoder that builds its
   tables without the single-code special case rejects legal streams (the
   exact Go regressions 11030/11033); one that accepts incomplete trees
   generally accepts illegal ones. The completeness check must be: reject
   oversubscribed always; reject incomplete unless the longest code is 1 bit
   (zlib `inftrees.c:147`, std `checkCompleteness`, Go's `TestStreams`
   vectors 14-20).
3. **The alphabet caps (T3).** The RFC's parenthetical ranges ("(257 - 286)"
   for HLIT, "(1 - 32)" for HDIST) read as permitting dynamic headers that
   declare distance codes 30-31 and literal/length codes 286-287, and
   `§3.2.6` even says 286-287 "participate in the code construction" — but
   no base/extra values exist for those codes anywhere, and the entire
   reference lineage (zlib, Go, std; oracle-verified here) rejects headers
   that declare beyond 286/30 and rejects decoding those symbols at all
   ("fixed block, use reserved symbol 287" fails). An RFC-literal decoder
   and a reference-compatible decoder disagree on legal input; ours must be
   the reference-compatible one, and the conformance table must pin it.
   Same family, one rank down: T5 — the table's stated ranges are narrower
   than its own arithmetic (284 + extra 31 = 258), and the references
   compute unclamped, so range-clamping is also a legal-input rejection.
