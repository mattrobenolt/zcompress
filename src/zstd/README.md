# zstd

A zstd decoder (RFC 8878) in pure Zig: the frame layer, the block layer, the
literals (huff0) and sequences (FSE) entropy layers, the XXH64 frame
checksum, and the `std.Io` streaming layer. Imports only `std` and `fastmem`;
no heap allocation on any decode path. The `zcompress.zstd` namespace of the
zcompress module.

zstd wraps nothing — it is a codec, not a container: the frame is its own
framing (a magic, a 2-14 byte header, a block chain, an optional checksum
trailer). The format is [RFC 8878][rfc8878], vendored verbatim at
`docs/research/specs/rfc8878-zstd.txt`. The research stage — the requirements
matrix, the reference-lineage divergence rows, the oracle survey, and the
errata register this document cites — is `docs/research/zstd-notes.md` (cited
below as `zstd-notes.md`). Section citations (`§x.y.z`) are sections of
`rfc8878-zstd.txt` throughout; the notes' `T<n>` rows are its divergence
decisions, cited where they bind.

**M4 is decoder-first, and the surface says so.** `zstd.Reader` (streaming
frame decode) and `zstd.decode` (one-shot decode) ship now; `zstd.Writer` and
`zstd.encode` (the fast encoder) are M5. The barrel rule — each codec
namespace exposes exactly `{Reader, Writer, encode, decode}`
(`AGENTS.md`, "Rules") — therefore completes at M5, and this document states
the M4 shape rather than leaving a gap: the namespace is exactly
`{Reader, decode}` today, and M5 adds the other two names without reshaping
these two. Everything in "Contracts" below is a decoder contract; the
encoder's mirror (`maxCompressedLength`, `Options`, `.ratio`) is M5's to
state.

**The errata register.** RFC 8878 is not self-consistent (`zstd-notes.md`
§0): three errata are IETF-Verified, one more is Reported and was proven by
oracle here, and three are editorial. The vendored file is verbatim, so it
carries the errata'd text; every place this document touches one, it records
it:

- **6441 (Verified)**: each Appendix A table opens with a spurious all-zero
  state-0 row; the real state-0 entries are the second rows. The ported
  Appendix A fixtures drop one row per table (T2).
- **6442 (Verified)**: Table 18's second-to-last row's `offset_value` is 3,
  not 1 — the `literals_length == 0` corner. Repeat-offset tests derive their
  expectations from §3.1.1.5's rules, never from the table's literal cells
  (T3).
- **7297 (Verified)**: 4-stream literals need **6-1023 / 6-16383 / 6-262143**
  regenerated literals, not 0-1023 / 0-16383 / 0-262143 — the fourth stream's
  size underflows below 6 (T4).
- **8195 (Reported; proven here)**: §4.2.2's worked example encodes "0145"
  with the weight-1 codes swapped. Table 25 and §4.2.1.3's distribution rule
  are normative; the hand-built T1 fixture pair pins the correct assignment on
  two independent decoders, and no test copies the example's bytes (T1).

## The layering design, stated once here

The M3 containers stated their wrapping design once, in
`src/gzip/README.md`; zstd needs its own statement, because it is one codec
rather than a codec plus a container. Five decisions, each the answer to a
layering question in `zstd-notes.md` §7:

- **The window is the caller's and comptime-sized** (OQ1). zstd's history is
  frame-declared — 1 KB to 3.75 TB (`§3.1.1.1.2`) — against flate's fixed
  32 KB, and the spec explicitly authorizes rejection beyond a decoder's range
  while recommending support to 8 MB. So the streaming buffer type is
  `zstd.Reader.Buffer(comptime window_len)` = `[window_len + max_block_size]u8`
  with a default constant of 8 MiB (the recommendation, and the pin from the
  CLI's level-19 frames: `windowLog` 23), and a frame declaring a larger
  Window_Size fails `WindowTooLarge` — fail closed, never a silent
  truncation. The **one-shot decode needs no window at all**: its history is
  `target` itself, so the cap is a streaming concern and `WindowTooLarge` is
  not in the one-shot's error set.
- **One Zstandard frame per reader, at the exact boundary** (OQ3). The reader
  consumes `input` through the frame's last byte — the checksum trailer's last
  byte when the flag is set, the last block's last byte otherwise — and stops
  there, so the input position at the clean end is the next frame unit's first
  byte. Multi-frame is `Reader.streamAll`'s walk at that boundary (gzip's
  member walk, `src/gzip/README.md` "The wrapping design"), and the frame
  checksum at the frame end rides the wrapper-rebase funnel
  (`src/internal/README.md`, "A wrapper's rebase routes the inner end through
  the same ending as fill" — the B1 entry names this exact shape).
- **Skippable frames are skipped, in every layer** (OQ3, §3.1.2). All 16
  magics 0x184D2A50-0x184D2A5F are consumed and their content ignored,
  "resuming decoding after the skippable frame" (`§3.1.2`) — before a frame,
  between frames in the walk, and in the one-shot. The cardinality rules are
  the CLI's own (T10): a **zero-byte input** is `error.Truncated` for
  `Reader`, `streamFrame`, and `decompress` (no frame unit began — the gzip
  decision mapped over) and the walk's clean end (zero frames served), while
  a stream of **only skippable frames** is a clean end with zero bytes served
  for every entry point (the CLI's verified behavior: sixteen skippable
  frames, all 16 magics, decode to nothing cleanly). A `Frame_Size` of up to 4 GiB
  costs no memory: the bytes are skipped by streaming through the input,
  never staged.
- **Dictionaries are refused, never skipped** (OQ4). A frame with a nonzero
  Dictionary_ID_Flag is `DictionaryRequired`, raised at the first Dictionary_ID
  byte, before any body byte — for formatted and raw-content dictionaries
  alike (`§3.1.1.1.3`, `§5`; the zlib-FDICT precedent, `src/zlib/README.md`
  "FDICT is rejected, never skipped"). §2's duty is an unambiguous error for
  every unsupported parameter; the reference C fails "Dictionary mismatch"
  without the exact dictionary, klauspost supports them, and std rejects every
  DID frame up front — ours is the fail-closed refusal, and no dictionary
  entry point exists (T11).
- **The checksum rides the block emission funnel** (OQ7). Every decoded byte
  lands in the window or `target` through one per-block funnel (raw: the block
  bytes; RLE: the splat; compressed: the sequence-execution writes plus the
  trailing literals), and the XXH64 is folded exactly there — every byte
  hashed once, in order, no second pass, no container buffer. The trailer is
  read and compared once at the frame's end, and a mismatch is
  `WrongChecksum`: the RFC makes ignoring the checksum compliant ("It may also
  ignore informative fields, such as the checksum", `§2`), every working
  reference verifies it anyway, and std's verification is a documented panic —
  ours verifies, fail closed (T8).

## API

M4's public surface is two namespaces — everything else composes through
them: `zstd.decode` (one-shot decode) and `zstd.Reader` (streaming decode).
`zstd.encode` and `zstd.Writer` are M5 (see the header).

```zig
const zstd = @import("zcompress").zstd;

// The one-shot decoder (zstd.decode):
zstd.decode.max_block_size            // 128 KiB: Block_Maximum_Size's ceiling
                                      // (§3.1.1.2.4; the frame's own bound is
                                      // min(Window_Size, this)).
zstd.decode.decompress(source, target) DecompressError!usize
        // `target` is a cap; returns the decoded length. One frame is
        // located by exact consumption: leading skippable frames are
        // consumed and ignored (§3.1.2), the frame's bytes are decoded, and
        // bytes after the frame are ignored (the flate/gzip one-shot
        // boundary rule — the one-shot reports no consumed count, so a
        // boundary-aware caller uses the streaming reader). The C's
        // ZSTD_decompress and klauspost's DecodeAll walk every frame in one
        // call; ours is the M3 boundary rule, and `Reader.streamAll` is the
        // walk — a multi-frame file's tail is the caller's loop, exactly as
        // gzip's one-shot treats a second member.
        // The one-shot needs no window buffer: the decoded output is the
        // history, and every match offset is bounded by it (§3.1.1.4).
zstd.decode.DecompressError = error{
    BufferTooSmall,          // `target` cannot hold the frame's output
    BadMagic,                // not 0xFD2FB528, not a skippable magic (§3.1)
    ReservedBitSet,          // descriptor bit 3 (§3.1.1.1.1.4)
    DictionaryRequired,      // Dictionary_ID_Flag set (§3.1.1.1.3, §5)
    BlockOversize,           // Block_Size > min(Window_Size, 128 KB) (§3.1.1.2.4)
    ReservedBlock,           // block type 3 (§3.1.1.2.2)
    MalformedLiteralsHeader, // the 1-5 byte literals header (§3.1.1.3.1.1)
    LiteralsTooLarge,        // literals sizes beyond the block; 4-stream < 6
                             // regenerated literals (errata 7297, §3.1.1.3.1.6)
    TreelessLiteralsFirst,   // Treeless with no previous tree (§3.1.1.3.1.1)
    MalformedHuffmanWeights, // the weight series and its completion (§4.2.1)
    MalformedFseTable,       // accuracy log, budget, or symbol count (§4.1.1)
    MalformedSequencesHeader,// the sequences section's fixed-size fields
                             // running past the block (§3.1.1.3.2.1)
    RepeatModeFirst,         // Repeat with no previous table (§3.1.1.3.2.1)
    ReservedModeBits,        // Symbol_Compression_Modes bits 1-0 (§3.1.1.3.2.1)
    MissingStartBit,         // a backwards bitstream's last byte is zero
                             // (§3.1.1.3.2.1.2, §4.2.2)
    InvalidBitStream,        // a state or code that cannot decode (§4.1, §4.2)
    BitstreamNotConsumed,    // bits left over at a bitstream's end (§3.1.1.3.2.1.2)
    ZeroOffset,              // offset 0: offset_value 3 with Repeated_Offset1 == 1 (T6)
    OffsetTooFar,            // an offset outside the frame's decoded output or
                             // its Window_Size (§3.1.1.4)
    ContentSizeMismatch,     // Frame_Content_Size != the frame's decoded total (§3.1.1.1.4)
    WrongChecksum,           // the XXH64 trailer (§3.1.1; T8 — verify, never skip)
    Truncated,               // the input ended inside the frame
};

// The streaming frame decoder (zstd.Reader): one Zstandard frame per reader,
// with the exact boundary visible. Buffer ownership is the caller's; there is
// no allocator anywhere in the API.
zstd.Reader.Buffer(comptime window_len: usize) type
        // [window_len + max_block_size]u8 — the caller-owned window buffer:
        // window_len bytes of retained history (§3.1.1.1.2's Window_Size,
        // capped by the caller) plus the largest decoded block
        // (Block_Maximum_Size <= 128 KB, §3.1.1.2.4). The buffer IS the cap:
        // init takes its exact pointer and derives the authorized window from
        // its type, so the two cannot disagree.
zstd.Reader.default_window_len
        // 8 MiB — §3.1.1.1.2's recommendation ("support values of
        // Window_Size up to 8 MB") and the CLI level-19 pin (windowLog 23).
zstd.Reader.DefaultBuffer
        // Reader.Buffer(default_window_len) — 8 MiB + 128 KiB. A caller
        // choosing smaller pays smaller: any window_len >= 1 KiB is legal
        // (§3.1.1.1.2's minimum), and frames that need more fail
        // `WindowTooLarge`.
var rbuf: zstd.Reader.DefaultBuffer = undefined;
// The comptime window and the buffer's type must agree — the compiler is
// the check — so the cap and the buffer cannot disagree. No allocator.
var r: zstd.Reader = .init(zstd.Reader.default_window_len, in, &rbuf);
// Consume through &r.reader (stream, read-family, peek-family); the reader
// ends with error.EndOfStream once the frame's checksum is verified, details
// in r.err. A failed or done reader is sticky.
zstd.Reader.Error = error{
    // The zstd.decode.DecompressError detail set, minus `BufferTooSmall`
    // (the window is the caller's buffer, not a target cap), plus:
    WindowTooLarge,          // the frame's Window_Size exceeds the buffer's
                             // window (the "authorized range", §3.1.1.1.2)
    StreamTooLong,           // a contiguous request past the serving region
    ReadFailed, EndOfStream, // the interface's coarse pair, detail in `err`
};

// The one-call pumps: one frame / every frame through the caller's window
// buffer, zero allocation, and no stack buffer of their own (8 MiB + 128 KiB
// does not belong on a stack — a caller who wants a small pump instantiates a
// small window).
zstd.Reader.streamFrame(window_len, in, out, buffer) error{ReadFailed, WriteFailed}!usize
zstd.Reader.streamAll(window_len, in, out, buffer) error{ReadFailed, WriteFailed}!usize
        // `window_len` is comptime and `buffer` is the exact pointer to a
        // `Reader.Buffer(window_len)`: the two must agree at the call site.
```

`Reader.streamFrame` consumes and decodes one Zstandard frame — consuming and
ignoring any skippable frames before it (§3.1.2) — and leaves the rest of `in`
unconsumed; `Reader.streamAll` consumes every frame `in` holds, the walk
above. Both take the comptime `window_len` and the exact pointer to a
`Reader.Buffer(window_len)` — the compiler holds the two together; the pump
reports the coarse `error.ReadFailed`, so a caller who needs a failure's
detail drives a `Reader` (or `streamFrame`) directly.

Beyond the two namespaces, the layer types the decoder is built from stay
reachable, named, and stable (the flate precedent: `BitReader`, `copyMatch`):
`zstd.decode.frame` (magic, frame header, block chain, checksum trailer,
skippable frames), `zstd.decode.block` (the 3-byte block header, the
Raw/RLE/Compressed dispatch, sequence execution, the checksum funnel),
`zstd.decode.literals` (the literals section and its Huffman streams),
`zstd.decode.sequences` (the sequences section), `zstd.decode.fse` (the FSE
tables, shared by the sequences and the Huffman weights), and the
`zstd.decode.window` arithmetic (`windowLog`/`windowBase`/`windowAdd`,
`§3.1.1.1.2`) both layers check a frame against. They are public because the
one-shot and the streaming reader are composed from them and the golden and
fuzz lanes pin the same functions; the namespace stays the two barrels, and
these are the named parts the barrels are built from.

Contracts, stated plainly:

- **Ownership**: the caller owns every buffer. Nothing is allocated, freed,
  or retained. There is no allocator in the API at all.
- **Sizing**: `decompress` takes `target` as a cap and returns the decoded
  length; a frame that does not fit is `error.BufferTooSmall`, reported before
  the overflowing write, never a truncated success. `Frame_Content_Size`
  cannot size the target for you when it is absent (it is optional,
  `§3.1.1.1.4`), and when present it is checked *against* the decode, not
  trusted for it. The streaming reader sizes nothing: the caller's buffer is
  the window, and a frame that declares more fails `WindowTooLarge`.
- **The match-offset bound** (the one-shot's whole window story): every match
  offset must point at bytes already decoded within the frame, and be smaller
  than the frame's declared Window_Size — `§3.1.1.4`: "all offsets leading to
  previously decoded data must be smaller than Window_Size" — or the frame is
  `OffsetTooFar`. Overlapping matches (offset < match length) are legal and
  replicate the pattern (`§3.1.1.4`). Offset 0 is corrupt: the repeat-offset
  arithmetic can produce it (`§3.1.1.5`'s "Repeated_Offset1 - 1_byte"), the C
  and std reject it, klauspost silently substitutes offset 1 and decodes a
  corrupt frame — ours is `ZeroOffset`, pinned by the `off0` fixture (T6).
- **Corruption**: decode fails closed at the first invalid byte — header,
  block, entropy tables, bitstreams, trailer — and no partial output is
  trusted past the error. Every decode test pre-fills the target with cycling
  sentinels and proves the bytes past the decoded length are untouched
  (`src/internal/README.md`, "API").
- **No hidden copies**: every copy goes through `fastmem.copy` /
  `fastmem.move` / `fastmem.set`; there is no `@memcpy`/`@memmove`/`@memset`
  anywhere in this module, tests included. An overlapping match (offset <
  match length) replicates the offset-byte pattern — the snappy decoder's
  shuffle technique applies — or rides `fastmem.move`; never `fastmem.copy`,
  which is non-overlapping only.
- **Stack**: a compressed block runs on ~256 KiB of comptime stack scratch
  (the staged compressed block, up to 128 KiB, plus the literals scratch, up
  to 128 KiB — the backwards bitstreams force the staging, "The block and
  entropy layers" below). The one-shot decode adds nothing else; the streaming
  reader's window is the caller's buffer, not a stack local. Size thread
  stacks accordingly when embedding.
- **Allocation**: zero, end to end. The one-shot takes no allocator; the
  reader takes none either (caller-provided buffers through the named buffer
  type).

## The frame format

```text
zstandard frame :=
  +-------------------------+-----------------------------------------+------------+
  | Magic_Number            | 4 bytes, LE: 0xFD2FB528                 | §3.1.1     |
  +-------------------------+-----------------------------------------+------------+
  | Frame_Header            | 2-14 bytes, the fields below            | §3.1.1.1   |
  +-------------------------+-----------------------------------------+------------+
  | Data_Block              | n bytes, then more blocks               | §3.1.1.2   |
  +-------------------------+-----------------------------------------+------------+
  | [Content_Checksum]      | 4 bytes, LE: XXH64 low 32 bits          | §3.1.1     |
  +-------------------------+-----------------------------------------+------------+

Frame_Header :=
  +-------------------------+-----------------------------------------+------------+
  | Frame_Header_Descriptor | 1 byte: the flag bits, Table 3          | §3.1.1.1.1 |
  +-------------------------+-----------------------------------------+------------+
  | [Window_Descriptor]     | 0-1 byte, absent on Single_Segment_Flag | §3.1.1.1.2 |
  +-------------------------+-----------------------------------------+------------+
  | [Dictionary_ID]         | 0-4 bytes, refused here (OQ4)           | §3.1.1.1.3 |
  +-------------------------+-----------------------------------------+------------+
  | [Frame_Content_Size]    | 0-8 bytes, LE, +256 on the 2-byte form  | §3.1.1.1.4 |
  +-------------------------+-----------------------------------------+------------+

skippable frame :=
  +-------------------------+-----------------------------------------+------------+
  | Magic_Number            | 4 bytes, LE: 0x184D2A50-0x184D2A5F      | §3.1.2     |
  +-------------------------+-----------------------------------------+------------+
  | Frame_Size              | 4 bytes, LE: the User_Data length       | §3.1.2     |
  +-------------------------+-----------------------------------------+------------+
  | User_Data               | n bytes, skipped, content ignored       | §3.1.2     |
  +-------------------------+-----------------------------------------+------------+
```

The Frame_Header_Descriptor (`§3.1.1.1.1`, Table 3; bit 7 highest):

| bits | field | our handling |
|------|-------|--------------|
| 7-6 | Frame_Content_Size_Flag | FCS_Field_Size 0-or-1 / 2 / 4 / 8 (Table 4); flag 0 with Single_Segment_Flag set means a 1-byte FCS (`§3.1.1.1.1.1`) |
| 5 | Single_Segment_Flag | no Window_Descriptor; FCS necessarily present; Window_Size = Frame_Content_Size (`§3.1.1.1.1.2`) |
| 4 | (unused) | accepted with either value, never interpreted (`§3.1.1.1.1.3`: "shall not interpret this bit") |
| 3 | (reserved) | "must ensure it is not set" (`§3.1.1.1.1.4`) — `ReservedBitSet` |
| 2 | Content_Checksum_Flag | the 4-byte trailer rides the frame end (`§3.1.1.1.1.5`) |
| 1-0 | Dictionary_ID_Flag | DID_Field_Size 0 / 1 / 2 / 4 (Table 5); nonzero → `DictionaryRequired` (`§3.1.1.1.1.6`) |

Window_Size (`§3.1.1.1.2`): `windowLog = 10 + Exponent`, `windowBase = 1 <<
windowLog`, `windowAdd = (windowBase / 8) * Mantissa`, `Window_Size =
windowBase + windowAdd` — minimum 1 KB, maximum `(1<<41) + 7*(1<<38)` bytes
(3.75 TB). The descriptor is one byte and always parses; the *cap* is ours
(OQ1). A decoder is allowed to reject beyond its authorized range, and the
streaming reader does, with `WindowTooLarge`; the one-shot materializes no
window and does not.

Frame_Content_Size (`§3.1.1.1.4`, Table 7): little-endian; the 2-byte field
carries 256-65791 (the +256 offset); "It's allowed to represent a small size
(for example, 18) using any compatible variant", so the size is checked
against the decode, never used to allocate. When present it is a running
bound: a frame that has already produced more bytes than it declared fails
`ContentSizeMismatch` at that block, not only at the frame end (std checks it
per block; `§8` names the smaller-than-actual FCS as an attack vector).

Blocks (`§3.1.1.2`): a 3-byte little-endian Block_Header — bit 0 Last_Block,
bits 1-2 Block_Type, bits 3-23 Block_Size (Table 9) — then Block_Content.
"Each frame must have at least 1 block, but there is no upper limit on the
number of blocks per frame." Four types (Table 10): Raw (Block_Content is
Block_Size literal bytes), RLE (one byte repeated Block_Size times), Compressed
(Block_Size is the compressed length; the decompressed size is bounded but
unknown), Reserved — "a compliant decoder must reject it" (`ReservedBlock`).
Block_Maximum_Size = the smaller of Window_Size and 128 KB, "constant for a
given frame" and "applicable to both the decompressed size and the compressed
size of any block in the frame" (`§3.1.1.2.4`) — so `BlockOversize` covers
both, and the window/block coupling is real: a single-segment frame with a
small FCS cannot carry a compressed block at all (the C says "Src size is
incorrect", std says `BlockOversize`; T7 — one name here).

The checksum trailer (`§3.1.1`): "the result of the XXH64() hash function
digesting the original (decoded) data as input, and a seed of zero. The low 4
bytes of the checksum are stored in little-endian format."

A conformant decoder's obligations, all enforced here:

- Accept concatenated frames; each decodes independently; the output is the
  concatenation (`§3.1`) — `Reader.streamAll` is the walk, and each `Reader`
  is one frame.
- Skip skippable frames and resume after them; all 16 magics are valid
  (`§3.1.2`).
- Reject the reserved descriptor bit (`§3.1.1.1.1.4`); never interpret the
  unused bit (`§3.1.1.1.1.3`).
- Reject the reserved block type (`§3.1.1.2.2`).
- Refuse a dictionary frame with a named error before any body byte
  (`§3.1.1.1.3`, `§2`; OQ4).
- Detect and prevent data tampering from reading or writing out of bounds
  (`§8`) — see "Amplification limits".
- Produce "an unambiguous error code and associated error message explaining
  which parameter is unsupported" for anything unsupported (`§2`) — the error
  vocabulary in the API block, one name per corruption class.
- Verify the checksum when present (T8; `§2` permits ignoring it, every
  reference verifies, ours fails closed).
- A frame cut off anywhere — header, block, trailer — is `error.Truncated`.

## The block and entropy layers

Two of the four block types never reach the entropy layers, and both are fast
paths: a **Raw block** (`§3.1.1.2.2`, Block_Content is Block_Size literal
bytes) is one `fastmem.copy` — from `source` on the one-shot, straight from
`input` on the streaming reader, since nothing needs staging to be read
forward — and an **RLE block** (one content byte repeated Block_Size times)
is one `fastmem.set` plus a doubling splat — the `rle-first-block.zst`
fixture pins RLE as a *first* block, which the CLI itself never emits. Both
are bounded by Block_Maximum_Size (`BlockOversize` otherwise, `§3.1.1.2.4`)
and both enter the same checksum funnel as a compressed block's output, so no
byte escapes the hash by taking a fast path.

A compressed block (`§3.1.1.3`) is a Literals_Section and a
Sequences_Section, combined by Sequence Execution. **The whole block is staged
before it is decoded**, and that is the format's own requirement, not a
choice: both backwards bitstreams (the sequences stream, `§3.1.1.3.2.1.2`,
and each Huffman literals stream, `§4.2.2`) are read from the block's *end*
toward its beginning, so the last byte's offset must be known before the first
symbol. The compressed block is staged into a comptime `[max_block_size]u8`
scratch (<= 128 KiB, `§3.1.1.2.4`), and every read is bounds-checked against
that staged region — never against the input's end, never against the frame's
end. That staging is the answer to `§8`'s named vector, "the encoding of
Number_of_Sequences values that cause the decoder to read into the block
header (and beyond)".

The literals (`§3.1.1.3.1`) come first: a byte-aligned 1-5 byte header
(Table 12: a 2-bit type, a 1-2 bit Size_Format, a 5-20 bit Regenerated_Size,
and a 0-18 bit Compressed_Size that includes the tree description), then —
for the compressed family — the Huffman_Tree_Description and 1 or 4 streams.
Four block types (`§3.1.1.3.1.1`, Table 13): Raw (0), RLE (1), Compressed (2),
Treeless (3, reusing the previous Compressed_Literals_Block's tree — "if this
mode is triggered without any previous Huffman table in the frame ... it
should be treated as data corruption", `TreelessLiteralsFirst`). 4-stream mode
requires >= 6 regenerated literals (errata 7297) and carries a 6-byte
Jump_Table of three u16-LE stream sizes, with
`Stream4_Size = Total_Streams_Size - 6 - s1 - s2 - s3`; "if Stream1_Size +
Stream2_Size + Stream3_Size exceeds Total_Streams_Size, the data are considered
corrupted" (`§3.1.1.3.1.5`, `§3.1.1.3.1.6`). Each stream's decompressed size
is `(Regenerated_Size+3)/4`, "except for the last stream, which may be up to 3
bytes smaller".

The Huffman tree (`§4.2.1`) arrives as **weights**: `Number_of_Bits =
Max_Number_of_Bits + 1 - Weight` for Weight > 0, else 0; the last symbol's
Weight is deduced "by completing to the nearest power of 2"; the maximum code
length is 11 bits. The tree header (`§4.2.1.1`) is one byte: >= 128 is the
direct mode, two 4-bit weights per byte (high nibble first),
`Number_of_Symbols = headerByte - 127`, at most 128; < 128 means the weights
are FSE-compressed into that many bytes (`§4.2.1.2`: one bitstream, two
interleaved states sharing one distribution, maximum accuracy log 6,
terminated by the bitstream-overflow rule — the `truncated_huff_state.zst`
fixture pins that corner). Codes are assigned by weight, "starting from the
lowest Weight ... in sequential order" (`§4.2.1.3`, Table 25) — Table 26's
worked bitstream contradicts it and is errata 8195, never copied into a test
(T1).

The literals are decoded into a second comptime `[max_block_size]u8` scratch,
then the sequences execute from it (`§3.1.1.3.1`: "They can be decoded first
and then copied during Sequence Execution, or they can be decoded on the
flow") — the references' shape, and the one the trailing literals come out of
too (`§3.1.1.3.2`: leftover literals "are added at the end of the block").
Total per-block stack scratch ~256 KiB, comptime, zero allocation. The
one-shot decode writes literals straight into `target` when the frame is
literals-only, and the streaming reader writes them straight into its serving
region in the same case.

The sequences section (`§3.1.1.3.2`) is a header, an optional table per symbol
type, and one bitstream. Number_of_Sequences (`§3.1.1.3.2.1`) is 1-3 bytes:
`byte0 == 0` ends the section — "Decompressed content is defined entirely as
Literals_Section content. The FSE tables used in Repeat_Mode are not updated";
`byte0 < 128` is the count; `byte0 < 255` is `((byte0 - 128) << 8) + byte1`;
`byte0 == 255` is `byte1 + (byte2 << 8) + 0x7F00`. The C additionally ends the
section whenever the *decoded* count is zero and ships `zeroSeq_2B.zst` to pin
that corner (a 2-byte `80 00` count); klauspost accepts it, std rejects it —
ours accepts it (T5, a recorded std divergence). The Symbol_Compression_Modes
byte follows: bits 7-6 literals lengths, 5-4 offsets, 3-2 match lengths, 1-0
Reserved, and "The last field, Reserved, must be all zeroes" — `ReservedModeBits`
(Table 14). Each mode is Predefined / RLE / FSE_Compressed / Repeat (Table 15);
the FSE_Compressed accuracy caps are 9 (literals lengths), 9 (match lengths),
8 (offsets), one-symbol tables must use RLE instead, and Repeat "used without
any previous sequence table in the frame ... should be treated as corruption"
(`RepeatModeFirst`). The three code alphabets (`§3.1.1.3.2.1.1`, Tables 16-17):
literals length codes 0-35 (lengths 0-131071), match length codes 0-52
(lengths 3-131074), offset codes 0-N with
`Offset_Value = (1 << offsetCode) + readNBits(offsetCode)`
and `Offset = Offset_Value - 3` for values above 3. "A decoder is free to
limit its maximum supported value for N. Support for values of at least 22 is
recommended" — we support the reference's 31.

The sequences bitstream (`§3.1.1.3.2.1.2`) reads backwards: the last byte
cannot be zero (`MissingStartBit`), the zero padding plus the first 1 bit are
skipped, and the initial states read in the order literals length, offset,
match length; per sequence the offset's bits, then match length, then literals
length; the states update in the order literals length, match length, offset;
and "At the end, the bitstream shall be entirely consumed; otherwise, the
bitstream is considered corrupted" (`BitstreamNotConsumed`). A structure that
runs past its staged block is that structure's own error, never `Truncated` —
`Truncated` is the input's end, before the frame's.

Sequence execution (`§3.1.1.4`) copies `literals_length` bytes from the
decoded literals, then `match_length` bytes from the offset ("an offset of 6
and a match length of 3 means that 3 bytes should be copied from 6 bytes
back"), with overlapping matches legal. Repeat offsets (`§3.1.1.5`) seed
{1, 4, 8} for the first block (no dictionary here), rotate on use, and carry
the `literals_length == 0` shift: an `offset_value` of 1 then means
Repeated_Offset2, 2 means Repeated_Offset3, and 3 means Repeated_Offset1 - 1
byte (Table 18's cells are errata 6442; the rules are the test source, T3).
"blocks that are not Compressed_Block are skipped; they do not contribute to
offset history."

FSE (`§4.1`) is the other entropy layer, used for the three sequence code
tables and for the Huffman weights. A decoding table has a power-of-2 size
(the Accuracy_Log), and an entry is Symbol / Num_Bits / Baseline: the state
reads Accuracy_Log bits to initialize, and each step consumes Num_Bits bits
and adds them to the Baseline. The table *description* (`§4.1.1`) is the one
zstd bitstream read **forward**: `Accuracy_Log = low4bits + 5`, then
probabilities on a `1 << Accuracy_Log` scale with Table 20's variable widths
(Value 0 is the "less than 1" probability, worth one point; zero-probability
symbols carry 2-bit repeat flags). The corruption rules are checked here:
"there must be two or more symbols with nonzero probability"; the cumulative
total must land exactly on `1 << Accuracy_Log`; and the expected symbol count
is the context's (never > 256). The RFC's literal "if the number of symbols
decoded is not equal to the expected" would reject legal short distributions —
the reference encoder spends its probability budget early and the C rejects
only *exceeding*; we enforce the budget-exactness and exceed-only rules, and
the fuzz lane owns the corner (T9). The construction (`§4.1.1`) is the spread
(`position += (tableSize >> 1) + (tableSize >> 3) + 3; position &= tableSize -
1`), the retreat for the "less than 1" symbols, and the baseline assignment
("The lower states will need 1 more bit than higher ones"); **Appendix A's
three tables are the day-one golden vectors** for it — all 64 + 64 + 32 real
rows, minus errata 6441's artifact row per table (T2).

**Amplification limits** — each one a named rule with its own test (see
"Testing"):

- A decode never writes past its declared output: the one-shot writes only
  into `target` and fails `BufferTooSmall` before the overflowing write; the
  streaming reader writes only into its serving region, and a block's output
  is bounded by Block_Maximum_Size (<= 128 KB) inside a buffer of
  `window_len + max_block_size`.
- A declared Frame_Content_Size is a running bound, not a hint: exceeding it
  fails at that block (`ContentSizeMismatch`; `§8`).
- Every read is bounded by the staged block, and the staging is the whole
  block (<= 128 KB) — `§8`'s Number_of_Sequences vector cannot read "into the
  block header (and beyond)".
- A skippable frame's `Frame_Size` is skipped by streaming through the input:
  a 4 GiB User_Data costs no memory, only the walk (gzip's XLEN rule:
  `src/gzip/README.md`, "The member format" — the extra field is skipped
  streaming, "never staged, so a 65,535-byte XLEN cannot amplify memory").
- The window is the caller's buffer: a frame that declares more than the
  buffer's window fails `WindowTooLarge`, so a hostile header cannot make the
  decoder grow anything.
- The one-shot's history is `target` alone: an offset that reaches before
  `target[0]` fails `OffsetTooFar`, so a small cap cannot be overrun by a
  frame that references data it never produced.

## The checksum

**XXH64** (`§3.1.1`): seed 0, the low 4 bytes little-endian. What std has,
verified by running (`zstd-notes.md` §3, the CRC-32 lesson applied — verify,
never assume):

- `std.hash.XxHash64` exists with exactly the incremental shape a frame
  boundary needs (`init(seed)`, `update(input)`, `final()`, and the one-shot
  `hash(seed, input)`), a four-lane accumulator with a 32-byte staging buffer
  for tails, so the streaming form needs no staging of its own.
- Check values: `XxHash64.hash(0, "")` = 0xEF46DB3751D8E999, the canonical
  reference value; the streaming form equals the one-shot form; a seed-1 hash
  differs (the seed-0 pin is observable, not vacuous).
- The zstd cross-check, the one that matters: the trailer of a
  checksum-enabled `zstd -3` frame is the low 4 bytes, little-endian, of
  `XxHash64.hash(0, decoded)`; the same holds for a 2.55 MB input compressed
  with `--long=26` (the >= 32-byte accumulator path). The checksum-on and
  `--no-check` frames are byte-identical except descriptor bit 2 and the four
  trailer bytes — the trailer is the only checksum overhead.

So `std.hash.XxHash64` is the day-one kernel; no kernel is written at M4. It
lives behind this module's own function boundary in `src/zstd/xxh64.zig` — a
fold state plus `xxh64(seed, bytes)`, the `src/gzip/crc32.zig` shape — so the
perf lane can swap a kernel in without touching a decoder (the M3
`internal/checksum` precedent: `src/zstd/`, not `src/internal/`, because zstd
is the only XXH64 user in the codec set). std's `XxHash64` stays as the test
oracle, and the CLI's trailers are the differential pin.

Where it folds (OQ7): at the **one per-block emission funnel** — the raw
block's bytes as they are copied to the output, the RLE block's splat, the
compressed block's sequence-execution writes and trailing literals, and the
literals-only shortcut's write. Every decoded byte hashed exactly once, in
order, with no second pass and no buffer of our own; the one-shot decode
hashes into `target` through the same funnel. That is the M3 OQ1 discipline
("hashing rides the codec boundary", `src/gzip/README.md`, "The checksums")
carried into a codec that owns its checksum rather than handing it to a
container. There is no `flate.Checksum`
style hook here and none is needed: zstd is a codec, the checksum state is
this module's, and the funnel is a direct call rather than a two-word
indirection. The trailer is read and compared exactly once, at the frame's
end, when the flag is set — `@truncate(hash.final())` against the
little-endian u32 — and a mismatch is `WrongChecksum`. A decode that fails
closed leaves the hash partial and reports the decode failure, never the
checksum.

## Streaming

`zstd.Reader` is a decompressing `Io.Reader` — the `std.Io` interface,
in-package, over one Zstandard frame with the exact boundary visible. The
machinery is the pattern book's (`src/internal/README.md`, "The Io codec
pattern book"): the generated vtable quartet, the fill-and-return-0 contract,
the zero-length poll, the sticky lifecycle (`State` + the detail in `err`),
the contiguity failure, and the wrapper-rebase funnel. Buffer ownership, in
full:

- `Reader.Buffer(window_len)` is `[window_len + max_block_size]u8`: the
  retained history (up to the frame's Window_Size, capped by `window_len`)
  plus the largest decoded block. `Reader.init(comptime window_len, input,
  buffer: *Buffer(window_len))` takes the comptime window and the exact
  pointer to the named buffer type; the two must agree, so the cap and the
  buffer cannot disagree.
- Zero allocation end to end: no allocator appears anywhere in the streaming
  API. The block staging and the literals scratch are comptime-sized stack
  locals.
- The one-call pumps take the same buffer pointer; there is no stack-buffered
  default-window pump, because 8 MiB + 128 KiB does not belong on a stack.

Semantics:

- The reader consumes `input` through the frame's last byte — the checksum
  trailer's last byte when the flag is set, the last block's last byte
  otherwise — and stops there; bytes after the frame are not consumed. (std's
  `Decompress` walks frames inside one reader; ours exposes the boundary and
  lets `streamAll` walk it — the M3 decision, recorded.) Any
  skippable frames before the frame were consumed and ignored (`§3.1.2`), so
  the input position at the clean end is the next frame unit's first byte. A
  multi-frame file is `Reader.streamAll`'s walk: after `error.EndOfStream`,
  the walk resumes at that position until a frame unit is not present (the
  file's clean end, zero frames served), and garbage in a unit's place fails
  `BadMagic`.
- The frame end runs in **one** place — read and verify the checksum trailer,
  advance the boundary — and both `fill` and `rebase` reach it. An over-the-end
  peek or record request at a frame's tail must not pass the input's end
  through with the trailer unread (the M3 B1 bug class, `fca3604`; the entry
  in `src/internal/README.md` names this exact shape: "the zstd frame checksum
  rides this exact shape"). The regression tests drive the over-the-end shapes
  on good and corrupted trailers, and the fuzz lane carries the
  unbounded-request op.
- At the frame's clean end the reader verifies the checksum exactly once, and
  only then reports `error.EndOfStream` (sticky). A mismatch is
  `error.ReadFailed` with `err == .WrongChecksum`; a truncated trailer is
  `err == .Truncated`. A caller that stops reading before the end never sees
  the check — the trailer is verified at the end of the frame, as every
  reference does.
- `Reader.Error` is the one-shot's `DecompressError` (minus `BufferTooSmall`,
  which never fires here) plus `WindowTooLarge`, `StreamTooLong`,
  `ReadFailed`, and `EndOfStream` — the specific detail recorded in `err`
  beside the interface's coarse pair.
- The contiguous-read cap: the reader serves decoded bytes from its serving
  region and slides the window forward only when the consumer has drained
  everything older than the retained history. A contiguous request beyond
  what the window can hold at the consumer's position fails closed with
  `error.ReadFailed` (`err == .StreamTooLong`), never an assert — a hostile or
  unusual consumer cannot crash the reader.
- The reader's input must buffer at least 4 bytes — the magic, the frame
  layer's largest fixed-size read (the 3-byte block header and the 4-byte
  checksum fit inside it) — or the input must end before then. std's decoder
  names the same class `InputBufferUndersize`.
- `Reader.streamFrame` / `Reader.streamAll` are the one-call pumps: one frame
  unit / every frame unit `in` holds, through the caller's buffer, zero
  allocation. `streamAll` is the walk above: skippable units pass through with
  zero bytes, a file of only skippable frames is the clean end with zero bytes
  served, the zero-byte input is the clean end (zero frames served), and
  garbage fails closed. `streamFrame` on a zero-byte input fails with the
  coarse interface error and the detail `.Truncated` in `err` — no frame
  unit began (the gzip decision mapped over, T10); the pumps report the
  interface's coarse `error.ReadFailed`, the reader carries the specific
  detail beside it (the M3 lifecycle trio's shape).

Files (the intended layout; the implementation lanes may split further):
`root.zig` (public surface), `decode.zig` (the one-shot and the shared decode
state), `frame.zig` (magic, frame header, block chain, checksum trailer,
skippable frames), `block.zig` (the block header dispatch, sequence execution,
the checksum funnel), `literals.zig` (the literals section), `huff0.zig`
(weights to decoding tables, the backwards Huffman stream), `fse.zig` (the FSE
table description and construction, shared by the sequences and the Huffman
weights), `xxh64.zig` (the checksum state over std's kernel), `Reader.zig`
(the streaming `Io` layer), `golden.zig` (ported golden fixtures, shared by
every layer's tests), `common.zig` (little-endian integer access), `bench.zig`
(local benchmark), `oracle.zig` (the external-oracle harness behind
`just zstd-oracle`), `fuzz.zig` (fuzz targets).

An example CLI (`examples/zstd.zig`, `zig build example-zstd -- decode
<file.zst> > out`) is a thin streaming pump over this surface, the same shape
as the other codecs' — decode-only until M5 adds the encoder direction. One
divergence from the other examples: its window is the 8.4 MiB default, which
cannot be a portable stack local (8 MiB is a common stack limit), so the
CLI scaffolding's arena owns the buffer for the run — the example is the
caller the pumps expect, and the codec itself still allocates nothing.

## Testing & golden vectors

The conformance bar is the reference suites and the reference decoder,
ported as fixtures and cross-checked as an oracle (the M3 pattern: `golden.zig`
holds the tables, and the frame, block, entropy, and streaming tests all read
them). The inventory is `zstd-notes.md` §5-§6, every incantation executed
before it was written down:

- **facebook/zstd v1.5.7 `tests/` (BSD-3-Clause/GPL-2.0 dual; the fixtures are
  data)** — the primary corpus. `golden-decompression/` (4 files, all decoded
  through the CLI): `block-128k.zst` (the Block_Maximum_Size neighborhood),
  `empty-block.zst` (0 bytes from an 11-byte frame), `rle-first-block.zst`
  (RLE as the *first* block — the CLI never emits it, so only a fixture
  covers it), `zeroSeq_2B.zst` (T5's 2-byte zero count).
  `golden-decompression-errors/` is **the bad-frame corpus**, each naming a
  corruption class the taxonomy must catch: `off0.bin.zst` (T6),
  `truncated_huff_state.zst` (the FSE-weights overflow termination),
  `zeroSeq_extraneous.zst` (bytes after a zero-sequence section).
  `decodecorpus.c` is the reference's random valid-frame generator with
  built-in verification — the differential corpus source for the fuzz lane —
  and `playTests.sh` is the CLI conformance script the oracle lane mirrors.
- **The zstd CLI v1.5.7** (the box's binary; the fleet records each box's
  version): the round-trip lanes in both directions where an encoder exists,
  `zstd -t` (verify), `zstd -l -v` (the frame listing: Window Size, Check),
  the golden corpus, and the corruption lanes. Verified here: a flipped
  trailer byte fails `zstd -t` with `Decoding error (36) : Restored data
  doesn't match checksum`, exit 1 (T8); a size-unknown level-19 frame reports
  `Window Size: 8.00 MiB` (the `windowLog` 23 pin; level 3 reports 2 MiB) and
  `Check: XXH64`; `--long=26` emits a 64 MB window (rejected by the default
  cap with `WindowTooLarge`, accepted by a caller who sizes for it). The lane is
  `src/zstd/oracle.zig` + `scripts/zstd_oracle.py` behind `just zstd-oracle`
  (the `flate-oracle` precedent).
- **CPython 3.14's `compression.zstd`** (PSF; libzstd underneath — the same
  shape as M3's python3 `zlib` lane, and the same `unused_data` boundary
  check): `compress`/`decompress` for the one-shot lanes and
  `ZstdDecompressor` for the boundary and streaming lanes. Verified on this
  box (3.14.7): a `level=3` frame round-trips, and the decompressor exposes
  `unused_data` after a frame — the exact-boundary pin.
- **std.compress.zstd** (MIT, in-tree) as the second oracle and the divergence
  pin: its FSE default distributions match the RFC's §3.1.1.3.2.2 tables
  verbatim (a cross-check for our constants), and it *rejects* the T5 corner
  (`EndOfStream` on `zeroSeq_2B`), *rejects* every DID frame up front
  (`DictionaryIdFlagUnsupported`), and ships with checksum verification
  unwired (`Options.verify_checksum` defaults false and panics when set) —
  T5, T11, T8 recorded, never copied. It also ships no tests and no testdata,
  so it is a datapoint, not a fixture source.
- **klauspost/compress zstd v1.18.0-5** as the third oracle (a scratch Go
  module running `DecodeAll` over the same files): `testdata/headers.zip` +
  `headers-want.json.zst` is the nearest thing to a frame-layer conformance
  table anywhere (a JSON table of parsed headers — SingleSegment, WindowSize,
  DictionaryID, HasFCS, Skippable fields, HeaderSize, FirstBlock, HasCheckSum
  — and it ships zstd-compressed, so the fixture is itself a decode test);
  `bad.zip` (9 KB of corrupt frames), `seqs.zip`/`seqs-want.zip`, `decoder.zip`,
  `comp-crashers.zip`, and `regression.zip` extend the corpus. Its
  divergence: T6 — it substitutes offset 1 for the offset-0 corner and decodes
  a corrupt frame.
- **The hand-built fixtures** (`zstd-notes.md` §5.4, each verified on two
  decoders): the T1 pair (two 19-byte frames whose literals streams are
  `01 0D` and `10 0D`, decoding to `00 01 04 05` and `00 01 05 04` — the
  Table-25 assignment, the within-code bit order, the final-bit flag, the
  direct-weights description, the literals-only compressed block, the 1-stream
  size format, and T5's decoded-zero end, all in one pair); the single-segment
  FCS=4 frames with oversized blocks (T7); the skippable set (a 0x184D2A53
  frame before a good frame; sixteen skippable frames alone, all 16 magics;
  0x184D2A60, which must fail the magic); the corruption set (flipped trailer,
  flipped magic, set reserved descriptor bit, corrupted FCS, trailing `zzzz`).
- **RFC 8878's own tables as fixtures**: Appendix A's three FSE tables
  row-for-row (minus errata 6441's artifact row) against a from-scratch build
  of §4.1.1's construction; §3.1.1.3.2.2's default distributions; §4.2.1.3's
  Table 25 assignment; §3.1.1.5's repeat-offset rules (never Table 18's
  cells, errata 6442).
- **Sentinel overrun checks on every decode**: the target is pre-filled with
  cycling sentinels, and every byte past the decoded length must be untouched
  (`internal.sentinel`, `src/internal/README.md`).
- **The amplification-limit tests are first-class citizens**, one per rule in
  "Amplification limits": a frame declaring a huge FCS whose data would
  overflow a small cap; an RLE block declaring 128 KB from one content byte; a
  frame with a very large block count; a 4 GiB skippable `Frame_Size`; a
  Number_of_Sequences that reads past the staged block (§8's named vector); an
  FCS smaller than the actual output (§8's other named vector); and the
  over-the-end contiguous request at a frame's tail (the B1 shape).
- **Fuzz**: `fuzz.zig` carries the round-trip target (over the golden corpus
  and generated shapes), the corruption target (never panic, never overrun —
  the bad-frame corpus plus `decodecorpus`-generated frames and mutations),
  and the **unbounded-request class**: the reader-machinery target must ask
  past a frame's tail (the M3 `over_end_peek` lesson — every earlier op
  bounded its request by the bytes still to come, which is exactly why the B1
  bug survived), so the trailer step is exercised through `rebase` from day
  one. Run under the default runner: `zig build test -Doptimize=ReleaseSafe
  -Dfuzz --fuzz=<budget>` (`just fuzz 10M`) — Debug fuzz hits
  ziglang/zig#30655. Fuzz-target creation is the fuzz-engineer's lane.

Run everything with `zig build test` / `just test` (the ztest plain-text
runner).

## Benchmarks

`zig build bench -Doptimize=ReleaseFast` (Go-style, via
[mattrobenolt/zig-benchmark][zigbench]) over the committed, fixed, hashed
corpus (`bench/corpus/`, SHA-256 per file in the manifest); throughput is
measured over uncompressed bytes, and local numbers are never quoted as
claims — a claim names a fleet run directory and a results file under
`docs/results/`.

M4 is decode-only, so the corpus's `.zst` blobs come from the **pinned zstd
CLI** (v1.5.7, the flake) at the recorded level 1 — the fast class every
other arm's rows measure — rather than from our encoder, each frame
verified byte-exact by our decoder (`bench/zig/corpus.zig --zstd`), hashed
and committed like every other reference blob. The corpus keeps the
family's sizes (32 KiB / 64 KiB): the one-shot needs no window (the target
is the history), so the window slide is the streaming layer's concern, not
the fleet corpus's.
Rows:

- `BenchmarkZstdDecompress` — the one-shot decode per shape and size.
- `BenchmarkStdZstdDecompress` — `std.compress.zstd` over the same bytes **in
  the same binary**: the paired in-binary comparison the code-layout rule
  demands (cross-binary rows are not comparable; `src/gzip/bench.zig`'s header
  records the finding).
- `BenchmarkZstdRatio` — frame size over uncompressed size, untimed.
- The streaming direction comes from the example pump (`just example zstd
  decode <file>`), which sizes the reader's window and times the real path
  with a file sink — the streaming bench row stays out of the bench binary
  for the same code-layout reason flate's was reverted (`src/flate/README.md`,
  "Benchmarks").

The fleet arms (the `bench/` harness, the M3 port): `zc` (ours, plus the
in-binary `std.compress.zstd` rows), `klauspost` (`DecodeAll` — the
single-buffer arm the one-shot races — and `NewReader`, the streaming arm),
and `zstd-c` (a new driver, `bench/drivers/c/bench_zstd.c`: `ZSTD_decompress`
and `ZSTD_decompressStream` against the box's libzstd, the pinned version
recorded per run; the plan's native ceiling). The `zstd-c` driver's rows must be built with the same
window-cap posture as ours (`ZSTD_d_windowLogMax`), or the comparison measures
two different acceptance policies.

## Licensing & attribution

This module is original Zig. The **format** is a public specification (RFC
8878, vendored with provenance under `docs/research/specs/`); the expression
here is ours. The references studied, all attributed in `THIRD_PARTY.md`:

- **[facebook/zstd][zstd-c]** (v1.5.7) — BSD-3-Clause/GPL-2.0 dual. The
  reference implementation and the fixture source: the golden corpus, the
  bad-frame corpus, `decodecorpus.c`'s generator shape, and the load-bearing
  constants (`ZSTD_BLOCKSIZE_MAX 1<<17`, `ZSTD_WINDOWLOG_LIMIT_DEFAULT 27`,
  MaxLL 35 / MaxML 52 / MaxOff 31 / the FSE accuracy logs) are read from here.
  Fixtures are data; no code is copied.
- **[klauspost/compress][kp]** (v1.18.0-5) — BSD-3-Clause. The Go reference:
  the frame-header golden table (`testdata/headers.zip`), the error-taxonomy
  vocabulary mirrored in OQ5, and the `bad.zip`/regression corpora.
- **Zig std's `std.compress.zstd`** (MIT, in-tree) — the shape study
  (`ReverseBitReader`, the literals/sequences split, the FSE table
  representation, the error-set naming) and the divergence pins T5, T8, and
  T11, never copied.
- **[XXHASH][xxhash]** (the spec's `[XXHASH]`) — the checksum algorithm;
  std's `XxHash64` is the day-one kernel and the test oracle.

python3's `compression.zstd` (PSF, backed by libzstd) is used as a CLI oracle,
nothing vendored; the zstd CLI binary on the box is v1.5.7, the same version
the fixtures come from. All upstream licenses are compatible with this
repository's MIT license; the BSD-3-Clause "no endorsement" clause is
satisfied by this attribution, and no code was copied verbatim.

[rfc8878]: https://www.rfc-editor.org/rfc/rfc8878.txt
[zstd-c]: https://github.com/facebook/zstd
[kp]: https://github.com/klauspost/compress
[xxhash]: https://github.com/Cyan4973/xxHash
[zigbench]: https://github.com/mattrobenolt/zig-benchmark
