# zstd research notes

The research stage of the codec development loop for M4: the zstd decoder —
the huff0, fse, block, and frame layers (`docs/zcompress-plan.md`,
"Milestones": "M4 — zstd decoder"; the encoder is M5). Spec:
`docs/research/specs/rfc8878-zstd.txt` (vendored, verbatim). Every requirement
line below cites that file and its section; where the RFC is ambiguous, silent,
or self-inconsistent, that is stated explicitly and the divergence is recorded
as a decision for the parent, never silently picked. The lane shape is M3's
`containers-notes.md` (the OQ decision log, the verified oracle incantations,
the pinned reference versions, the fixture inventory) and M2's
`flate-notes.md` (the codec-scale format study, the hand-built streams decoded
by the oracle to settle bit-order questions). zstd wraps nothing — it is a
codec, not a container — so M3's "wrapping design" questions become M4's
"layering design" questions, and the streaming frame boundary (the
`src/internal/README.md` wrapper-rebase entry) is where the two meet again.

## 0. Provenance

- Spec: `rfc8878-zstd.txt` — RFC 8878, "Zstandard Compression and the
  'application/zstd' Media Type" (Y. Collet, M. Kucherawy, Ed., February 2021;
  obsoletes RFC 8478), **112,425 bytes, verified by title line and byte
  count**. Provenance row already in `docs/research/specs/README.md`
  (fetched 2026-10-08 from rfc-editor.org); the same README's zstd note — the
  C reference supplements the RFC where the frame/block layer leaves behavior
  unstated — is the posture this file follows. IETF RFCs are freely
  distributable (the document's own Status of This Memo).
- **The errata register.** RFC 8878 is not self-consistent. Three errata are
  IETF-Verified (6441, 6442, 7297), one more is Reported and **proven here by
  oracle** (8195 — the §4.2.2 worked example's bitstream is wrong; §4 T1
  proves it on two independent decoders), and three are editorial/Reported
  (7567, 8085, 8668). The vendored file is verbatim, so it carries the
  errata'd text; every row below that touches one records it:
  - **6441 (Verified)**: each Appendix A table opens with a spurious
    all-zero state-0 row (state 0, symbol 0, 0 bits, base 0) — the real
    state-0 entries are the second rows. Verified here: a from-scratch
    implementation of §4.1.1's construction reproduces all 64/64/32 real rows
    of A.1/A.2/A.3 exactly once the artifact row is dropped (§4 T2).
  - **6442 (Verified)**: Table 18's second-to-last row's offset_value should
    be 3, not 1 — the row demonstrates the literals_length==0 corner, which
    offset_value 1 does not trigger.
  - **7297 (Verified)**: the 4-stream literals size ranges are 6-1023 /
    6-16383 / 6-262143, not 0-1023 / 0-16383 / 0-262143 — the fourth stream's
    size underflows below 6 regenerated literals.
  - **8195 (Reported; proven here)**: the §4.2.2 example encodes "0145" as
    `00010000 00001101` using Table 26's codes (5→0000, 4→0001), contradicting
    Table 25 and §4.2.1.3's own distribution rule (4→0000, 5→0001). The
    correct bitstream is `00000001 00001101` (§4 T1).
- Reference implementations read for this file (cited inline as `path:line`):
  facebook/zstd at tag **v1.5.7** (dual BSD-3-Clause/GPL-2.0; fetched to
  `/tmp/zstd-notes-verify/zstd-c` for this research — 13 MB shallow; the
  box's CLI binary, `/run/current-system/sw/bin/zstd`, reports the same
  **v1.5.7**), klauspost/compress at **v1.18.0-5-g8df4d01** (2025-04-02,
  BSD-3-Clause, local checkout `~/code/klauspost-compress`) — `zstd/`,
  `fse/`, `huff0/` — and Zig 0.16.0 std (MIT, the flake's store
  `/nix/store/amh3bnymjncd56jwmd2hqdkciz9d7pys-zig-0.16.0/lib/zig/`) —
  `std/compress/zstd/` (a 1,961-line `Decompress.zig` plus a 178-line barrel)
  and `std/hash/xxhash.zig`.
- Oracles run for this file — every incantation in §5-§6 was executed here and
  its output recorded before being written down (the M3 lesson): the zstd CLI
  v1.5.7 (round-trips, corruption lanes, `zstd -l`, `zstd -t`, the golden
  corpus), `zig run` scratch harnesses against the 0.16.0 store
  (`std.compress.zstd` decode + `std.hash.XxHash64` check values), and a
  scratch Go module running klauspost `DecodeAll` over the same files.
  golang/go ships no zstd (verified: `~/code/golang/go/src/compress/` is
  bzip2, flate, gzip, lzw, zlib — no zstd — so the Go reference for zstd is
  klauspost, exactly as the plan's competitor set says).
- A note on the task brief (the `flate-notes.md` §0 precedent): the brief's
  section numbering does not match RFC 8878 as published. The block layer is
  §3.1.1.2 (Blocks), not "§3.1.1.4" (that is Sequence Execution); the literals
  section is §3.1.1.3.1 with its header at §3.1.1.3.1.1 (not
  "§3.1.1.3.2.1.1", which is the literals length code table inside the
  sequences section); huff0's tree description is §4.2.1; FSE is §4.1 (right);
  and "§5 the tree from weights" is §4.2 — §5 is the Dictionary Format. The
  true numbering is used throughout this file. The brief's std premise is
  **true** this time — `std.hash.XxHash64` exists and matches the reference
  (§3; the CRC-32 lesson applied and passed) — but the audit still found the
  trap: std's zstd decoder ships with its checksum verification unwired
  (§6.3, T8), and std ships no zstd tests or testdata at all (§5).

## 1. Format summary

zstd is a LZ77-family codec with two entropy layers (FSE for the sequence
symbols, Huffman for the literals) over a frame/block structure. Four layers,
each a named piece of an M4 module: **frame** (magic, header, block chain,
checksum, skippable frames), **block** (raw/RLE/compressed dispatch and
execution), **literals** (huff0), **sequences** (fse). Everything is
little-endian on the wire except the two backwards-read bitstream families,
which are read from the end toward the beginning without reversing bit order
(`rfc8878-zstd.txt §4.1`).

### 1.1 The frame layer (`rfc8878-zstd.txt §3.1`)

"Zstandard compressed data is made up of one or more frames. Each frame is
independent and can be decompressed independently of other frames. The
decompressed content of multiple concatenated frames is the concatenation of
each frame's decompressed content" (`§3.1`). Two frame kinds: Zstandard frames
(compressed data) and skippable frames (user metadata) (`§3.1`).

A Zstandard frame (`§3.1.1`, Table 1): Magic_Number (4 bytes, little-endian,
value 0xFD2FB528), Frame_Header (2-14 bytes), one or more Data_Blocks, an
optional Content_Checksum (4 bytes). The checksum: "the result of the XXH64()
hash function digesting the original (decoded) data as input, and a seed of
zero. The low 4 bytes of the checksum are stored in little-endian format"
(`§3.1.1`). Skippable frames (`§3.1.2`, Table 19): Magic_Number
0x184D2A50-0x184D2A5F (all 16 values valid), a 4-byte little-endian
Frame_Size (the User_Data length), and User_Data — "From a compliant decoder
perspective, skippable frames simply need to be skipped, and their content
ignored, resuming decoding after the skippable frame" (`§3.1.2`).

The Frame_Header (`§3.1.1.1`, Table 2): a 1-byte Frame_Header_Descriptor,
then an optional Window_Descriptor (0-1 byte), an optional Dictionary_ID
(0-4 bytes), and an optional Frame_Content_Size (0-8 bytes). The descriptor's
fields (`§3.1.1.1.1`, Table 3; bit 7 is the highest):

| bits | field | notes |
|---|---|---|
| 7-6 | Frame_Content_Size_Flag | FCS_Field_Size 0-or-1 / 2 / 4 / 8 (`§3.1.1.1.1.1`, Table 4) |
| 5 | Single_Segment_Flag | no Window_Descriptor; FCS necessarily present; Window_Size = FCS (`§3.1.1.1.1.2`) |
| 4 | (unused) | a decoder "shall not interpret this bit"; an encoder must set zero (`§3.1.1.1.1.3`) |
| 3 | (reserved) | "A decoder compliant with this specification version must ensure it is not set" (`§3.1.1.1.1.4`) |
| 2 | Content_Checksum_Flag | the 4-byte trailer rides the frame end (`§3.1.1.1.1.5`) |
| 1-0 | Dictionary_ID_Flag | DID_Field_Size 0 / 1 / 2 / 4 (`§3.1.1.1.1.6`, Table 5) |

The Window_Descriptor (`§3.1.1.1.2`): bits 7-3 Exponent, bits 2-0 Mantissa;
`windowLog = 10 + Exponent; windowBase = 1 << windowLog; windowAdd =
(windowBase / 8) * Mantissa; Window_Size = windowBase + windowAdd`. Minimum
1 KB, maximum `(1<<41) + 7*(1<<38)` bytes = 3.75 TB. "a decoder is allowed to
reject a compressed frame that requests a memory size beyond the decoder's
authorized range", and "it's recommended for decoders to support
values of Window_Size up to 8 MB" (`§3.1.1.1.2`). When Single_Segment_Flag is set,
Window_Size is instead Frame_Content_Size itself (`§3.1.1.1.2`).

Frame_Content_Size (`§3.1.1.1.4`, Table 7): little-endian; FCS_Field_Size 2
adds an offset of 256 (range 256-65791); "It's allowed to represent a small
size (for example, 18) using any compatible variant". Dictionary_ID
(`§3.1.1.1.3`): little-endian, any width for any value ("It is permitted to
represent a small ID (for example, 13) with a large 4-byte dictionary ID");
the public ranges (<= 32767, >= 2^31) are reserved for IANA-registered
dictionaries and "Any payload presented for decompression that references an
unregistered reserved dictionary ID results in an error".

### 1.2 The block layer (`rfc8878-zstd.txt §3.1.1.2`)

"Each frame must have at least 1 block, but there is no upper limit on the
number of blocks per frame" (`§3.1.1.2`). A block is a 3-byte little-endian
Block_Header (bit 0 Last_Block, bits 1-2 Block_Type, bits 3-23 Block_Size)
followed by Block_Content (Table 8, Table 9). Four types (Table 10): Raw_Block
(Block_Content is Block_Size literal bytes), RLE_Block (one byte "repeated
Block_Size times" on the decompression side), Compressed_Block (Block_Size is
the compressed length; the decompressed size is unknown but bounded), and
Reserved — "If such a value is present, it is considered to be corrupt data,
and a compliant decoder must reject it" (`§3.1.1.2.2`).

Block_Maximum_Size (`§3.1.1.2.4`): "the smallest of: Window_Size, 128 KB" —
"constant for a given frame" and "applicable to both the decompressed size and
the compressed size of any block in the frame". Verified live: the v1.5.7
encoder splits a 300-KB incompressible input into raw blocks of exactly
131072 + 131072 + 37856 bytes, and 300 KB of zeros into one compressed block
(10 bytes) then RLE blocks of 131072 + 37856 — and both references reject an
oversized block in a single-segment frame (§4 T7).

### 1.3 The literals section (`rfc8878-zstd.txt §3.1.1.3.1`)

Literals first, then sequences. Four Literals_Block_Types (`§3.1.1.3.1.1`,
Table 13): Raw (0), RLE (1), Compressed (2 — carries a Huffman tree
description), Treeless (3 — reuses "the Huffman tree from the previous
Compressed_Literals_Block or a dictionary"; "if this mode is triggered without
any previous Huffman table in the frame (or dictionary, per Section 5), it
should be treated as data corruption").

The Literals_Section_Header is a byte-aligned 1-to-5-byte little-endian
bitfield (`§3.1.1.3.1.1`, Table 12): the 2-bit type, a 1-2-bit Size_Format, a
5-20-bit Regenerated_Size, and for the compressed family a 0-18-bit
Compressed_Size ("Compressed_Size includes the size of the
Huffman_Tree_Description when it is present"). Two families of size formats:
- Raw/RLE: Size_Format 00 or 10 → 1 byte, 5-bit Regenerated_Size;
  01 → 2 bytes, 12-bit; 11 → 3 bytes, 20-bit.
- Compressed/Treeless: Size_Format 00 → 1 stream, 3-byte header, 10-bit both
  sizes; 01 → 4 streams, 3-byte header, 10-bit; 10 → 4 streams, 4-byte
  header, 14-bit; 11 → 4 streams, 5-byte header, 18-bit. (The 4-stream forms
  require >= 6 regenerated literals — errata 7297; the C enforces
  `MIN_LITERALS_FOR_4_STREAMS = 6` at `zstd_decompress_block.c:188`.)

Four-stream mode carries a Jump_Table (`§3.1.1.3.1.6`): 6 bytes, three
2-byte little-endian compressed sizes for streams 1-3;
`Stream4_Size = Total_Streams_Size - 6 - Stream1_Size - Stream2_Size -
Stream3_Size`, where `Total_Streams_Size = Compressed_Size -
Huffman_Tree_Description_Size` (`§3.1.1.3.1.5`). "if Stream1_Size +
Stream2_Size + Stream3_Size exceeds Total_Streams_Size, the data are
considered corrupted". Each stream's decompressed size is
`(Regenerated_Size+3)/4`, "except for the last stream, which may be up to 3
bytes smaller" (`§3.1.1.3.1.6`).

### 1.4 huff0 (`rfc8878-zstd.txt §4.2`)

Huffman-coded streams are read backwards like FSE streams: the last byte
cannot be zero (the padding rule — a final 1 bit then zero fill), and the
decoder "needs to skip the up to 7 bits of 0-padding as well as the first 1
bit that occurs" (`§4.2.2`, restated at `§3.1.1.3.2.1.2`). "This specification
limits the maximum code length to 11 bits" (`§4.2.1`).

The tree is transmitted as **weights**: `Number_of_Bits = Max_Number_of_Bits +
1 - Weight` for Weight > 0, else 0 (`§4.2.1`); values 0 to last-present-minus-1
are listed and the last symbol's Weight is deduced "by completing to the
nearest power of 2" (`§4.2.1`'s worked example: weights 4,3,2,0,1 for literals
0-4 sum 2^(w-1) = 15, the next power of 2 is 16, so Max_Number_of_Bits = 4 and
weight[5] = 16 - 15 = 1). The Huffman_Tree_Description is one header byte
(`§4.2.1.1`): >= 128 → direct mode, each Weight a 4-bit field, two per byte
(high nibble first), `Number_of_Symbols = headerByte - 127`, at most 128
(literals above 128 force FSE mode); < 128 → the weights are FSE-compressed
into headerByte bytes.

The FSE-compressed weights (`§4.2.1.2`): one bitstream, two interleaved
states sharing one distribution table, maximum accuracy log 6; "The first
state (State1) encodes the even-numbered index symbols, and the second
(State2) encodes the odd-numbered index symbols. State1 is initialized
first... and they take turns decoding a single symbol and updating their
state". Termination is by overflow: "if updating state after decoding a
symbol would require more bits than remain in the stream, it is assumed that
extra bits are zero. Then, symbols for each of the final states are decoded
and the process is complete" — the `truncated_huff_state.zst` golden error
fixture pins this corner.

Codes from weights (`§4.2.1.3`, Tables 24-25): sort by Weight (natural order
within a Weight), drop Weight-0 symbols, "starting from the lowest Weight,
prefix codes are distributed in sequential order" — the weight-1 symbols 4 and
5 get 0000 and 0001 respectively. The worked bitstream in `§4.2.2` (Table 26)
contradicts this (5→0000, 4→0001); the algorithm text is normative and both
references implement it — proven here with hand-built frames (§4 T1).

### 1.5 The sequences section (`rfc8878-zstd.txt §3.1.1.3.2`)

`Sequences_Section_Size = Block_Size - Literals_Section_Header -
Literals_Section_Content` (`§3.1.1.3.2`). The section is a header, then an
optional table for each symbol type, then one bitstream.

Number_of_Sequences (`§3.1.1.3.2.1`): 1-3 bytes — byte0 == 0 → "there are no
sequences. The sequence section stops here. Decompressed content is defined
entirely as Literals_Section content. The FSE tables used in Repeat_Mode are
not updated"; byte0 < 128 → byte0; byte0 < 255 → `((byte0 - 128) << 8) +
byte1`; byte0 == 255 → `byte1 + (byte2 << 8) + 0x7F00` (the C's `LONGNBSEQ`,
`zstd_internal.h:96`). Symbol_Compression_Modes (`Table 14`): one byte, bits
7-6 Literal_Lengths_Mode, 5-4 Offsets_Mode, 3-2 Match_Lengths_Mode, 1-0
Reserved — "The last field, Reserved, must be all zeroes." Each mode follows
Table 15: Predefined (the §3.1.1.3.2.2 distributions), RLE (one symbol byte
for all sequences), FSE_Compressed (a distribution table; "the maximum
allowed accuracy log for literals length code and match length code tables is
9, and the maximum accuracy log for the offset code table is 8. This mode
must not be used when only one symbol is present"), Repeat ("the table used
in the previous Compressed_Block with Number_Of_Sequences > 0 will be used
again, or... the table in the dictionary"; "If this mode is used without any
previous sequence table in the frame (or dictionary...) to repeat, this should
be treated as corruption").

The three code alphabets (`§3.1.1.3.2.1.1`, Tables 16-17): literals length
codes 0-35 (lengths 0-131071; codes 0-15 are the literal length, then
baseline+extra-bits bands); match length codes 0-52 (lengths 3-131074, codes
0-31 are code+3); offset codes 0-N — "A decoder is free to limit its maximum
supported value for N. Support for values of at least 22 is recommended. At
the time of this writing, the reference decoder supports a maximum N value of
31" — with `Offset_Value = (1 << offsetCode) + readNBits(offsetCode); if
(Offset_Value > 3) Offset = Offset_Value - 3` and Offset_Value 1-3 the repeat
codes. The predefined offset distribution tops out at 28 (`§3.1.1.3.2.2.3`).

The sequences bitstream (`§3.1.1.3.2.1.2`): read backwards from the block's
last byte; the last byte cannot be zero; skip the zero padding and the first
1 bit. Initial states in order Literals_Length, Offset, Match_Length, each
reading its table's accuracy log in bits. Per sequence: read the offset's
Number_of_Bits, then match length, then literals length; if not the last
sequence, update the states in order Literals_Length, Match_Length, Offset.
The compressor writes forward, so "the compressor must encode the sequences
starting with the last one and ending with the first". "At the end, the
bitstream shall be entirely consumed; otherwise, the bitstream is considered
corrupted" — `zeroSeq_extraneous.zst` pins the sibling rule for the
zero-sequence section end.

### 1.6 Sequence execution and repeat offsets (`rfc8878-zstd.txt §3.1.1.4`,
`§3.1.1.5`)

Each sequence: copy literals_length bytes from the decoded literals, then
match_length bytes "from previous decoded data" at the offset ("an offset of
6 and a match length of 3 means that 3 bytes should be copied from 6 bytes
back"; overlapping matches are legal). "all offsets leading to previously
decoded data must be smaller than Window_Size" (`§3.1.1.4`). Leftover
literals after the last sequence "are added at the end of the block"
(`§3.1.1.3.2`).

Repeat offsets (`§3.1.1.5`): Repeated_Offset1/2/3 seeded {1, 4, 8} for the
first block ("unless a dictionary is used"); offset_value 1-3 select them,
with the one exception: "when the current sequence's literals_length is 0,
repeated offsets are shifted by 1, so an offset_value of 1 means
Repeated_Offset2, an offset_value of 2 means Repeated_Offset3, and an
offset_value of 3 means Repeated_Offset1 - 1_byte". Non-compressed blocks are
skipped: "each block gets its starting offset history from the ending values
of the most recent Compressed_Block. Note that blocks that are not
Compressed_Block are skipped; they do not contribute to offset history."
Table 18 is the worked example (carrying errata 6442's typo — read its
second-to-last row as offset_value 3).

### 1.7 FSE (`rfc8878-zstd.txt §4.1`)

"FSE decoding involves a decoding table that has a power-of-2 size and
contains three elements: Symbol, Num_Bits, and Baseline. The base 2 logarithm
of the table size is its Accuracy_Log. An FSE state value represents an index
in this table." Initial state: consume Accuracy_Log bits little-endian; the
symbol is the table entry's; the next state: "consume Num_Bits bits from the
stream as a little-endian value and add it to Baseline" (`§4.1`). All FSE
data bitstreams are read end-to-beginning, bit order unreversed (`§4.1`).

The table description (`§4.1.1`) is the one zstd bitstream read **forward**:
"A bitstream is read forward, in little-endian fashion" — it starts
with `Accuracy_Log = low4bits + 5` in the first byte, then per-symbol
probabilities on a normalized scale of `1 << Accuracy_Log`. Field widths
follow Table 20's scheme (small values use one fewer bit); the probability is
`P = Value - 1`, so Value 0 is the "less than 1" probability (-1), which
counts as one point for totals. A zero-probability symbol is followed by
2-bit repeat flags (a 3 extends with another flag). Corruption rules: "there
must be two or more symbols with nonzero probability"; "If the last symbol
makes the cumulated total go above (1 << Accuracy_Log), distribution is
considered corrupted"; "If the number of symbols decoded is not equal to the
expected, the header should be considered corrupt" (read against the
references at §4 T9).

Table construction (`§4.1.1`): "less than 1" symbols get one cell each
"starting from the end of the table and retreating" — "These symbols define a
full state reset, reading Accuracy_Log bits"; the remaining symbols are laid
out in natural order with the spread `position += (tableSize >> 1) +
(tableSize >> 3) + 3; position &= tableSize - 1`, skipping occupied cells;
then per symbol the states (natural order) get their widths — "The lower
states will need 1 more bit than higher ones" — and Baselines are assigned
"starting from the higher states using fewer bits, and proceeding naturally,
then resuming at the first state" (Table 21's worked example). **Verified
here**: a from-scratch Python implementation of exactly this construction
reproduces Appendix A's three predefined tables row-for-row (all 64 + 64 + 32
real rows; A.1's state 0 is symbol 0 / 4 bits / baseline 0, matching the
second row, not errata-6441's artifact first row). Appendix A's own caption
says it: "The tables here can be used as examples to crosscheck that an
implementation has built its decoding tables correctly" — they are the
day-one golden vectors for the FSE table builder.

### 1.8 Dictionaries (`rfc8878-zstd.txt §5`, `§6`)

Out of band: "the Dictionary_ID identifies which should be used, but this
specification does not describe the mechanism by which the dictionary is
obtained prior to use" (`§5`). A formatted dictionary is Magic_Number
0xEC30A437 (little-endian; verified: `zstd --train` emits exactly these
bytes), a 4-byte little-endian Dictionary_ID (any value except 0), Entropy_Tables
("Huffman table for literals, FSE table for offsets, FSE table for match
lengths, and FSE table for literals lengths... finally followed by 3 offset
values, populating repeat offsets (instead of using {1,4,8}), stored in order,
4 bytes little-endian each... Each repeat offset must have a value less than
the dictionary size"), and the Content, which "acts as a 'past' in front of
data" with the window rule: while the total decoded data is <= Window_Size,
"sequence commands may specify offsets longer than the total length of decoded
output so far to reference back to the dictionary, even parts of the
dictionary with offsets larger than Window_Size. After the total output has
surpassed Window_Size, however, this is no longer allowed." Raw-content
dictionaries (>= 8 bytes, format-free) are also legal (`§5`). `§6`'s media
type says content "should not use a dictionary" for public interchange.

## 2. Requirements matrix — a conformant zstd decoder

RFC 8878's own compliance bar (`§2`): "A compliant decompressor must be able to
decompress at least one working set of parameters that conforms to the
specifications presented here. It may also ignore informative fields, such as
the checksum. Whenever it does not support a parameter defined in the
compressed stream, it must produce an unambiguous error code and associated
error message explaining which parameter is unsupported." The rows below are
the decoder-side obligations for the M4 scope (dictionaries out, per §7 OQ4);
encoder-side MUSTs (the descriptor's unused and reserved bits zero, FSE
mode never with one symbol, the Reserved block type unused) are M5's
matrix.

| # | requirement | cite |
|---|-------------|------|
| ZD1 | Unambiguous, named errors for every unsupported or invalid parameter — the root duty that shapes the error taxonomy (§7 OQ5) | `rfc8878-zstd.txt §2` |
| ZD2 | The checksum may be ignored for compliance — but see T8: every reference verifies it, and the house posture is fail-closed | `§2`, `§3.1.1` |
| ZD3 | Accept concatenated frames; each frame decodes independently; the output is the concatenation | `§3.1` |
| ZD4 | Skip skippable frames (all 16 magics 0x184D2A50-5F) and resume after them; their content is ignored | `§3.1.2` |
| ZD5 | Frame header sizes: 2-14 bytes; the descriptor alone fixes the size | `§3.1.1.1` |
| ZD6 | Reject a set reserved descriptor bit — "must ensure it is not set" | `§3.1.1.1.1.4` |
| ZD7 | Do not interpret the unused bit (accept any value; never reject on it) | `§3.1.1.1.1.3` |
| ZD8 | Single_Segment_Flag: no Window_Descriptor; FCS necessarily present; Window_Size = FCS; the frame decodes within one segment of >= FCS bytes; reject beyond the authorized range; support >= 8 MB recommended | `§3.1.1.1.1.2`, `§3.1.1.1.2` |
| ZD9 | Window arithmetic: `windowLog = 10 + Exponent`, `Window_Size = windowBase + (windowBase/8)*Mantissa`; min 1 KB, max 3.75 TB; rejection beyond the authorized range is allowed and the 8 MB recommendation stands | `§3.1.1.1.2` |
| ZD10 | FCS: little-endian, the +256 offset for the 2-byte field, any compatible variant accepted | `§3.1.1.1.4` |
| ZD11 | A dictionary-ID frame errors when the dictionary is not available (the reserved-range rule plus §2's unsupported-parameter duty) | `§3.1.1.1.3`, `§2` |
| ZD12 | At least one block per frame; the 3-byte LE block header; Last_Block ends the frame (checksum follows if flagged) | `§3.1.1.2`, `§3.1.1.2.1` |
| ZD13 | Reject the Reserved block type — "a compliant decoder must reject it" | `§3.1.1.2.2` |
| ZD14 | RLE blocks: repeat the single content byte Block_Size times | `§3.1.1.2.2` |
| ZD15 | Block_Maximum_Size = min(Window_Size, 128 KB), constant per frame, bounding both the compressed and the decompressed size of every block | `§3.1.1.2.4` |
| ZD16 | Carry the four cross-block states: window history (<= Window_Size), the three repeat offsets, the previous Huffman tree (Treeless), the three previous FSE tables (Repeat) — any may instead come from a dictionary | `§3.1.1.3` |
| ZD17 | Treeless literals without a previous tree (or dictionary) is corruption | `§3.1.1.3.1.1` |
| ZD18 | The two literals size-format families (1-5 byte headers); Compressed_Size includes the tree description | `§3.1.1.3.1.1` |
| ZD19 | 4-stream mode requires >= 6 regenerated literals (errata 7297; the vendored text says 0-1023) | `§3.1.1.3.1.1`, errata 7297 |
| ZD20 | The jump table: three u16-LE stream sizes; Stream4 = Total - 6 - s1 - s2 - s3; s1+s2+s3 > Total is corruption | `§3.1.1.3.1.6` |
| ZD21 | Number_of_Sequences forms (0, 1-127, 2-byte, 3-byte +0x7F00); byte0==0 ends the section, the block is the literals, and Repeat tables survive | `§3.1.1.3.2.1` |
| ZD22 | Symbol_Compression_Modes' reserved bits "must be all zeroes" | `§3.1.1.3.2.1` (Table 14) |
| ZD23 | FSE_Compressed accuracy caps: 9 (LL), 9 (ML), 8 (OF); one-symbol tables must use RLE mode instead | `§3.1.1.3.2.1` |
| ZD24 | Repeat mode without a previous table (or dictionary) is corruption | `§3.1.1.3.2.1` |
| ZD25 | The LL/ML/OF code tables (baselines and extra bits); offset codes 0-N, N >= 22 recommended, the reference supports 31; Offset_Value > 3 subtracts 3 | `§3.1.1.3.2.1.1` |
| ZD26 | The sequences bitstream reads backwards; the last byte is nonzero; skip <= 7 zero bits plus the first 1 bit; initial states LL, OF, ML; per-sequence reads OF, ML, LL; updates LL, ML, OF; at the end the bitstream "shall be entirely consumed" | `§3.1.1.3.2.1.2` |
| ZD27 | Execution: literals then match; matches may overlap; every offset < Window_Size; trailing literals append | `§3.1.1.4`, `§3.1.1.3.2` |
| ZD28 | Repeat offsets: {1,4,8} seeds (or dictionary values); the literals_length==0 shift (offset_value 3 → Repeated_Offset1 - 1); the recency rotation; non-compressed blocks do not contribute | `§3.1.1.5` |
| ZD29 | FSE decoding: power-of-2 table, accuracy-log state reads, Num_Bits + Baseline state updates; data bitstreams read end-to-beginning, bit order unreversed | `§4.1` |
| ZD30 | The FSE table description reads forward; Accuracy_Log = low4bits + 5; >= 2 nonzero-probability symbols; the cumulative total must land exactly on 1 << Accuracy_Log; the context fixes the expected symbol count (never > 256) | `§4.1.1` |
| ZD31 | The FSE table construction (spread + retreat + baseline assignment) — Appendix A crosschecks it | `§4.1.1`, Appendix A |
| ZD32 | Huffman: max code length 11; weights ↔ Number_of_Bits; the implied last weight completes to a power of 2; the header's two modes; FSE-compressed weights cap at accuracy 6, two interleaved even/odd states, overflow termination | `§4.2.1`, `§4.2.1.1`, `§4.2.1.2` |
| ZD33 | Huffman streams read backwards; the last byte is nonzero and carries the final-bit flag, which is not part of the stream (the padding rule + the flag reading proven at §4 T1); a stream must be exactly consumed | `§4.2.2` |
| ZD34 | The frame checksum: XXH64 of the original decoded data, seed 0, the low 4 bytes little-endian | `§3.1.1` |
| ZD35 | Security: detect and prevent any tampering from causing out-of-bounds reads or writes; the named vectors are Number_of_Sequences reading past the block and FCS smaller than the actual output; enforce memory limits; fuzz the decoder | `§8` |

(The decoder-side checksum duty is ZD2's "may ignore" — the house posture
exceeds it deliberately, recorded as T8, the RFC-1952-GD5 asymmetry in
reverse: here the RFC makes it optional and every reference verifies anyway.)

## 3. The frame checksum: XXH64 (the std-availability audit)

The spec's definition is one sentence (`§3.1.1`): "The content checksum is
the result of the XXH64() hash function digesting the original (decoded) data
as input, and a seed of zero. The low 4 bytes of the checksum are stored in
little-endian format." The CLI's own name for it is XXH64 (`zstd -l` prints
"Check: XXH64").

What std ships, **verified by running** (`zig run` against the 0.16.0 store,
the CRC-32 lesson applied — verify, never assume):

- `std.hash.XxHash64` exists (`std/hash/xxhash.zig:9`) with exactly the
  incremental shape a frame-decoder boundary needs: `init(seed: u64)`,
  `update(self, input: anytype)`, `final() u64`, and one-shot
  `hash(seed, input)` — a four-lane accumulator (`acc1..acc4`), a 32-byte
  staging buffer for tails, the five documented primes, so the streaming form
  needs no extra staging of its own.
- **Check values**: `XxHash64.hash(0, "")` = 0xEF46DB3751D8E999, the canonical
  reference value; the streaming form (three `update` chunks) equals the
  one-shot form on the tested input; a seed-1 hash differs (the seed-0 pin is
  observable, not vacuous).
- **The zstd cross-check**, the one that matters (std's XxHash64 vs the C
  library's own XXH64 through the CLI's frame trailer, which is the exact
  zstd usage): `zstd -3` of a 225-byte input with the checksum on, trailer =
  `1f 4e 77 a8` = the low 4 bytes, little-endian, of `XxHash64.hash(0,
  decoded)`; and a 2.55 MB input compressed with `--long=26` (window 64 MB,
  checksum on), trailer = `c4 91 79 15` = the low 4 bytes of a chunk-streamed
  `XxHash64` over the whole decoded file (the >= 32-byte accumulator path).
  The checksum-on and `--no-check` frames are byte-identical except
  descriptor bit 2 and the 4 trailer bytes (verified with `cmp`), which pins
  the trailer as the only checksum overhead.
- Verdict: **std's XxHash64 is the day-one kernel** — correct on the check
  value, on two real frames' trailers, and in the incremental shape the
  streaming layer needs. No kernel is written at M4; the perf lane may replace
  it later behind our own function boundary (the M3 `internal/checksum`
  precedent: placement in `src/zstd/`, since zstd is the only XXH64 user in
  the codec set — `src/internal/` waits for a second user).

std's own zstd decoder uses exactly this shape (`std/compress/zstd/
Decompress.zig:403` `hasher_opt: ?std.hash.XxHash64`, `:951`
`std.hash.XxHash64.init(0)`, `:385` `@truncate(hasher.final())` against the
little-endian u32) — but never wires the update (§6.3, T8).

## 4. Spec-vs-reference divergences (decisions for the parent)

The RFC text, the C reference, klauspost, and std — all four recorded; none
silently picked. `zstd-c` cites the v1.5.7 checkout; `klauspost` cites
v1.18.0-5-g8df4d01; `std` cites the 0.16.0 store.

- **T1 — the §4.2.2 worked example is wrong (errata 8195, proven here).**
  Table 25 and §4.2.1.3's rule give 4→0000, 5→0001 (weight-1 symbols in
  natural order take codes sequentially); Table 26 and the example bitstream
  `00010000 00001101` use the swap. Settled empirically: two hand-built
  frames (single compressed block, direct-4-bit weights [4,3,2,0,1] for
  literals 0-4, one Huffman stream, nbSeq = 0 — the construction in §5.4),
  differing only in the stream bytes `01 0D` (Table 25) vs `10 0D` (Table 26):
  **both the C CLI v1.5.7 and std decode `01 0D` to `00 01 04 05` ("0145")
  and `10 0D` to `00 01 05 04` ("0154")** — the algorithm's assignment is what
  every implementation decodes; the example's bytes are the erratum. This
  also settles the within-code bit order empirically (codes are written
  LSB-at-lower-bit-position and read MSB-first downward from the final-bit
  flag) and the final-bit-flag reading (the highest *set* bit of the last
  byte, with the zero padding above it skipped — the RFC's "highest bit"
  phrasing plus the padding rule, settled by the same experiment). The fixture pair is a
  golden candidate (§5.4). Decision: fixtures and tests cite Table 25's
  assignment; the vendored §4.2.2 text is annotated errata-8195 in the module
  README, never copied into a test.
- **T2 — Appendix A's spurious first row (errata 6441, verified here).** Each
  appendix table's first data row is the all-zero state-0 duplicate; the real
  state-0 row is the second. A from-scratch build of §4.1.1's construction
  matches all remaining rows of all three tables exactly (§1.7). Decision:
  the ported Appendix A fixtures drop one row per table; a test comment cites
  errata 6441.
- **T3 — Table 18's offset_value typo (errata 6442).** The vendored table's
  second-to-last row reads offset_value 1; it must be 3 (the
  literals_length==0 insert corner). Reported erratum 8085 additionally argues
  the last row's Repeated_Offset3 should be 1111 rather than 3333 (Reported
  only; the vendored text stands). Decision: tests that pin the repeat-offset
  machinery derive expectations from §3.1.1.5's rules, not from Table 18's
  literal cells.
- **T4 — the 4-stream literals minimum (errata 7297).** The vendored text
  says Regenerated_Size "values 0-1023" for 4-stream Size_Format 01 (and
  0-16383 / 0-262143 for 10 / 11); the verified erratum and the C
  (`MIN_LITERALS_FOR_4_STREAMS = 6`, `zstd_internal.h:92`, enforced at
  `zstd_decompress_block.c:188` with its own error) say 6-1023 / 6-16383 /
  6-262143 — the fourth stream's size underflows below 6. Decision: enforce
  >= 6 for 4-stream mode (compatibility with the reference family; the
  arithmetic forces a rejection below 6 anyway).
- **T5 — nbSeq = 0 via the 2-byte form.** `§3.1.1.3.2.1` ends the sequences
  section only on `byte0 == 0`; the C additionally ends it whenever the
  *decoded* count is zero (`zstd_decompress_block.c:721-725`: "No sequence :
  section ends immediately"), and ships the golden fixture
  `golden-decompression/zeroSeq_2B.zst` (a 2-byte `80 00` count) precisely to
  pin that corner. klauspost accepts it too (verified: 13 bytes decoded).
  std rejects it with EndOfStream — its header decode ends the section only
  on byte0 == 0 and then demands the modes byte (`Decompress.zig:1383,1401`).
  Decision: accept the decoded-zero corner (the C's own golden corpus pins
  it; a streamAll over a real corpus will meet it). Recorded as a std
  divergence, not copied.
- **T6 — the offset-0 corner.** The RFC never says offset 0 is invalid; it
  arises when literals_length == 0 and offset_value == 3 with
  Repeated_Offset1 == 1 ("Repeated_Offset1 - 1_byte", `§3.1.1.5`). The C
  forces the resolved offset to wrap so the execution check rejects it
  (`zstd_decompress_block.c`, `ZSTD_decodeSequence`: `temp -= !temp; /* 0 is
  not valid: input corrupted => force offset to -1 => corruption detected at
  execSequence */`), and ships `golden-decompression-errors/off0.bin.zst` to
  pin it (verified: the CLI fails "Data corruption detected"; std fails
  InvalidBitStream). **klauspost instead substitutes offset 1 and decodes**
  (`zstd/seqdec.go:286-293`: "0 is not valid; input is corrupted; force
  offset to 1" — verified: it decodes off0.bin.zst to 18 bytes without
  error). Decision: fail closed on offset 0 (the C's behavior, the golden
  corpus, and the house posture; klauspost's silent substitution is a
  recorded divergence, never a model). A named error (`InvalidOffset` /
  `ZeroOffset`) with the off0 fixture in the bad-frame corpus.
- **T7 — the window/block coupling in single-segment frames.** Window_Size =
  FCS (`§3.1.1.1.2`) and Block_Maximum_Size bounds the *compressed* size too
  (`§3.1.1.2.4`), so a single-segment frame with a small FCS cannot carry a
  compressed block at all — the encoder family falls back to raw/RLE for tiny
  payloads (verified: the empty-input frame is a 0-size raw block). Verified
  live: a hand-built single-segment FCS=4 frame carrying a 202-byte block is
  rejected by the C ("Src size is incorrect", error 36) and by std
  (`BlockOversize`) — two error labels for the same spec rule. Decision:
  reject with one named error (`BlockOversize`); record the C's differing
  label.
- **T8 — the checksum-verification duty.** `§2` makes ignoring the checksum
  compliant ("It may also ignore informative fields, such as the checksum");
  every working reference verifies: the C ("Restored data doesn't match
  checksum", verified by corrupting a trailer byte), klauspost
  (`ErrCRCMismatch`, verified via the Go oracle), and std — *in shape only*:
  `Options.verify_checksum` defaults false and panics if true once any byte
  is written (`Decompress.zig:30-32`: "Verifying checksums is not implemented
  yet and will cause a panic if you set this to true"; `:374-377`: the hasher
  update is a TODO panic). Decision: verify, fail closed (the house posture;
  the M3 precedent where std also skipped its trailer checks, T4 there).
- **T9 — the FSE distribution symbol-count rule.** `§4.1.1`: "The context in
  which the table is to be used specifies an expected number of symbols. That
  expected number of symbols never exceeds 256. If the number of symbols
  decoded is not equal to the expected, the header should be considered
  corrupt." Read literally this would reject every short distribution — but
  the description only covers "all symbols from 0 to the last present one",
  and the reference encoder routinely emits tables that spend their
  probability budget before the context maximum (e.g. an ML table over codes
  0-20). The C rejects only *exceeding*: `FSE_readNCount` breaks when the
  budget is spent and errors on `charnum > maxSV1`
  (`common/entropy_common.c`, `maxSymbolValue_tooSmall`). Decision: enforce
  the budget-exactness and exceed-only-count rules (the reference reading);
  the RFC's "not equal to" phrasing is recorded as an ambiguity, and the
  fuzz lane pins the corner.
- **T10 — trailing bytes, cardinality, the empty input.** `§3.1` defines
  one-or-more frames per "data set" and says nothing about bytes after the
  last frame. The CLI: trailing non-frame bytes after complete frames decode
  the frames and then fail the next magic ("unsupported format", exit 1;
  verified); `-f/--force` additionally passes unrecognized formats through
  as-is (documented in `--help`; verified: a corrupted-magic file exits 0
  and copies the input through — a CLI convenience, not a decoder
  behavior); the empty input fails "unexpected end of file"; a stream of
  only skippable frames (verified: 16 of them, all 16 magics) decodes to
  zero bytes cleanly. Decision: the M3 member-boundary policy maps over —
  one frame per `Reader` with the exact boundary visible, `streamAll` walks
  frames at that boundary and fails `BadMagic` on garbage in the next frame's
  place, the zero-frame input is the clean end for the walk and `Truncated`
  for the single-frame decode (§7 OQ3).
- **T11 — dictionaries.** The C errors "Dictionary mismatch" without the
  dictionary and with the wrong one (verified: `zstd -D` round-trip works,
  no-dict and wrong-dict both fail, exit 1); klauspost *supports* dictionaries
  (`WithDecoderDicts`/`WithDecoderDictRaw`, `ErrUnknownDictionary`);
  std rejects every frame with a nonzero Dictionary_ID_Flag before any body
  byte (`Decompress.zig:933-934`, `DictionaryIdFlagUnsupported`). The RFC
  leaves acquisition out of band (`§5`) and `§2` requires the unambiguous
  error. Decision: M4 fails closed on dictionaries (OQ4) — the std/zlib-FDICT
  posture; klauspost's support is a recorded divergence.

## 5. Fixture inventory (every entry verified live where a decoder can run it)

### 5.1 facebook/zstd `tests/` (BSD-3-Clause / GPL-2.0 dual, tag v1.5.7)

- **`golden-decompression/` (4 files, all decoded here through the CLI)**:
  `block-128k.zst` (131,068 decoded — the Block_Maximum_Size neighborhood),
  `empty-block.zst` (0 bytes decoded from an 11-byte frame), `rle-first-block.zst`
  (1,048,576 bytes from a 45-byte frame — RLE as the *first* block; the
  harness comment: "the zstd cli do not generate them, to maintain
  compatibility with older versions"), `zeroSeq_2B.zst` (13 bytes — the T5
  corner). Used by `playTests.sh:525-532` and `zstd -t -r` at `:1289`.
- **`golden-decompression-errors/` (3 bad frames, all failed here through the
  CLI, std, and klauspost)**: `off0.bin.zst` (offset 0 — the C and std reject,
  klauspost accepts, T6), `truncated_huff_state.zst` (the FSE-weights
  overflow termination), `zeroSeq_extraneous.zst` (bytes after a
  zero-sequence section). This is **the bad-frame corpus**: three pinned
  error vectors, each naming a corruption class the matrix must catch.
- `golden-compression/` (encoder-side inputs: `http`, `large-literal-and-match-lengths`,
  `PR-3517-block-splitter-corruption-test`), `golden-dictionaries/`
  (`http-dict-missing-symbols`), `dict-files/zero-weight-dict`.
- **`decodecorpus.c` (71.5 KB)**: the reference's random valid-frame
  generator with built-in verification — the differential conformance
  generator for the fuzz lane (the amplification corpus source).
- The harnesses: `playTests.sh` (69 KB of CLI conformance, the lane script),
  `zstreamtest.c` (163 KB, the streaming API fuzzer), `fuzzer.c` (241 KB of
  unit tests), `seqgen.c`, `longmatch.c`, `invalidDictionaries.c`,
  `tests/fuzz/` (the oss-fuzz corpora: `simple_decompress`, `block_decompress`,
  `huf_decompress`, `fse_read_ncount`, `decompress_dstSize_tooSmall`, ...),
  `tests/regression/` (the regression corpus). Licensing: the repo is dual
  BSD-3/GPL-2; reading and porting fixtures under BSD-3 is unrestricted, and
  data fixtures carry no code anyway.
- Load-bearing constants (not fixtures — numbers, all matching the RFC):
  `lib/zstd.h`'s
  (ZSTD_MAGICNUMBER 0xFD2FB528, ZSTD_MAGIC_DICTIONARY 0xEC30A437,
  ZSTD_BLOCKSIZE_MAX 1<<17, ZSTD_WINDOWLOG_LIMIT_DEFAULT 27) and
  `lib/common/zstd_internal.h`'s MaxLL 35 / MaxML 52 / MaxOff 31 /
  LLFSELog 9 / MLFSELog 9 / OffFSELog 8 / LONGNBSEQ 0x7F00 — the C's exact
  caps, all matching the RFC's numbers.

### 5.2 klauspost/compress `zstd/` (BSD-3-Clause, v1.18.0-5-g8df4d01)

- **`testdata/headers.zip` + `testdata/headers-want.json.zst`** — a frame
  header golden table: JSON mapping each fixture name to the parsed Header
  (SingleSegment, WindowSize, DictionaryID, HasFCS, FrameContentSize,
  Skippable fields, HeaderSize, FirstBlock{Last, Compressed, sizes},
  HasCheckSum). Verified: `zstd -d -c headers-want.json.zst` is the JSON
  (the golden table ships zstd-compressed). The nearest thing to a
  frame-layer conformance table anywhere; ports almost as-is
  (`decodeheader_test.go`).
- `testdata/seqs.zip` + `seqs-want.zip` (sequence-level goldens),
  `decoder.zip` (6.6 MB), `bad.zip` (9 KB of corrupt frames),
  `comp-crashers.zip`, `decode-regression.zip`, `regression.zip` (1.6 MB),
  `dict-tests-small.zip`, `large.zip`, `z000028(.zst)`.
- `fse/testdata/` (`fse_compress.zip`, `fse_decompress.zip`),
  `huff0/testdata/` (`fse_compress.zip`, `huff0_decompress1x.zip`,
  `decompress1x_regression.zip`, `regression.zip`) — the two entropy
  packages' own corpora; the huff0 one-stream regression set is directly
  relevant to the literals lane.
- Error taxonomy to mirror (their decoder surfaces): ErrMagicMismatch,
  ErrWindowSizeExceeded, ErrWindowSizeTooSmall, ErrDecoderSizeExceeded,
  ErrUnknownDictionary, ErrFrameSizeExceeded, ErrFrameSizeMismatch,
  ErrCRCMismatch (`zstd/zstd.go:60-100`); the block layer's own reserved-bit
  check (`blockdec.go:554`).

### 5.3 Zig 0.16 std (MIT, in-tree)

`std/compress/zstd` ships **no tests and no testdata** — one `test { _ =
Table; }` block (`Decompress.zig:1959-1961`) and an empty
`std/compress/testdata/` directory. The M3 pattern ("std's container tests
are the nearest native goldens") does not hold for zstd: std's decoder is a
competitor datapoint and a divergence pin (T5, T8, §6.3), not a fixture
source. Its default distributions (`zstd.zig:12-30`) match the RFC's
§3.1.1.3.2.2 tables verbatim — a cross-check for our own constants.

### 5.4 The hand-built fixtures from this research (golden candidates)

- The **T1 pair**: two 19-byte frames (no FCS, 1 KB window, one compressed
  block, direct weights, nbSeq = 0) whose literals streams are `01 0D` and
  `10 0D` — decoding to `00 01 04 05` and `00 01 05 04` respectively on both
  the C CLI and std. Pins: the Table-25 code assignment, the within-code bit
  order, the final-bit flag, the direct-weights tree description, the
  literals-only compressed block, the 1-stream size format, the
  decoded-zero sequences section end (T5).
- The **single-segment FCS=4 frames** with oversized blocks (T7): both
  references' rejection behavior.
- The **skippable-frame set**: one 0x184D2A53 frame prepended to a good
  frame; sixteen skippable frames alone (all 16 magics); a 0x184D2A60
  (out-of-range) frame that must fail the magic check.
- The **corruption set**: the flipped trailer byte (checksum), the flipped
  magic, the set reserved descriptor bit, the corrupted FCS, trailing `zzzz`.

## 6. Competitor inventory

The plan pins the zstd set: klauspost and std always, plus "the strongest
native library on the box — zstd C for zstd" (`docs/zcompress-plan.md`,
"Benchmark methodology"; the M4 line names the fleet arms: zstd C,
klauspost, std.compress.zstd).

### 6.1 zstd C v1.5.7 — the native ceiling

The fleet's native arm (the CLI binary on this box is the same version; the
fleet boxes run whatever libzstd they carry, recorded per run). Decode-side
shape: whole-frame `ZSTD_decompress`, streaming `ZSTD_decompressStream`, and
the block decoder with hand-written x86-64 assembly paths for the sequence
loop and huff0 (`decompress/zstd_decompress_block.c`, `huf_decompress.c`,
BMI2 dispatch). The reference's own caps worth quoting against:
`ZSTD_WINDOWLOG_LIMIT_DEFAULT 27` (128 MB — the streaming decoder's default
window rejection), block max 1<<17, offset FSE tables to code 31, the CLI's
`--memory`/`-M` knob (verified: a 64 MB-window frame fails with "Frame
requires too much memory for decoding" under 16/32 MB caps and passes at
64 MB). Numbers mean: the native ceiling per box, the target band for the
M4 fleet run.

### 6.2 klauspost/compress zstd v1.18.0-5 — the class target

`DecodeAll` (whole-buffer) and `NewReader` (streaming, io.Reader-native);
multi-frame native; dictionaries supported; the sequence decoder has a
hand-tuned amd64 assembly path (`zstd/seqdec_amd64.s`, 81.6 KB) plus generic
Go; its own vendored `internal/xxhash` (BSD-3, theirs) computes the checksum.
Default window cap `MaxWindowSize = 1<<29` (512 MB, `framedec.go:43`), floor
`MinWindowSize = 1<<10`; knobs `WithDecoderMaxWindow`,
`WithDecoderMaxMemory`, `WithDecoderLowmem`. Numbers mean: the speed class
the plan names ("The performance class is klauspost/compress"); its
single-buffer `DecodeAll` is the arm our one-shot decode races, its
`NewReader` the streaming arm.

### 6.3 std.compress.zstd (Zig 0.16) — the in-tree baseline

Decode-only (`pub const Decompress` — no Compress; M4's decoder-first shape
is std's own scope), `std.Io.Reader`-native with direct/indirect vtable
variants (`Decompress.zig:76-84`), a caller-provided buffer asserted to hold
`window_len + block_size_max` (default 8 MB + 128 KB, `:94-101`), skippable
frames skipped via a `skipping_frame` state, FCS verified against the decoded
total (`MalformedFrame`), dictionaries rejected up front, window rejection
via `WindowOversize` at the option cap. Divergences already recorded: the
unwired checksum (T8), the nbSeq 2-byte-zero corner (T5), plus its own
notes: "This could be improved so that when an amount is discarded that
includes an entire frame, skip decoding that frame" (`:157-158`, a discard
inefficiency) and the `@field`-based state dispatch TODOs. Numbers mean: the
in-tree bar for a Zig decoder — the M4 fleet run's third arm, and the
stealables list: the ReverseBitReader shape, the literals/sequences decode
split, the FSE table representation (`Table.Fse`), and the error-set naming
(BlockOversize, TreelessLiteralsFirst, RepeatModeFirst, ... — §7 OQ5's
starting vocabulary).

## 7. The layering design questions (decisions for the README sketch)

Each labeled with its recommendation; each feeds the M4 README sketch
(`src/zstd/README.md`, written before any implementation). The M3 OQ
numbering is mirrored so the two files read together.

- **OQ1 — the window buffer and cap: the one real memory-design question.**
  flate's history is fixed (32 KB window, `Reader.Buffer` = 64 KiB, one
  type); zstd's window is a frame-declared 1 KB..3.75 TB (`§3.1.1.1.2`), and
  the decoder "is allowed to reject a compressed frame that requests a memory
  size beyond the decoder's authorized range" with 8 MB the recommended
  support floor. The pins from this research: the CLI's level-19 frames carry
  windowLog 23 = **8 MiB** on size-unknown input, and size-known inputs
  single-segment down to Window_Size = FCS (both verified here), so an
  8 MiB cap decodes the default fleet corpus; `--long=26` emits 64 MiB and needs the cap raised. The
  one-shot decode needs **no window buffer
  at all** — the decoded output *is* the history (matches reference back
  into `target[0..n]`; a frame whose match reaches before the target's start
  fails the offset bound). The window problem is therefore streaming-only.
  *Options*: (a) a single fixed `zstd.Reader.Buffer` type sized 8 MiB +
  128 KB — the spec's own recommendation, std's default, but an 8 MB
  caller-owned buffer for every reader; (b) a comptime-parameterized named
  buffer type (`zstd.Reader.Buffer(comptime window_len)`, an exported
  constant for the 8 MiB default) so small-window callers pay small — the
  fastmem `tuning.zig` pattern the plan cites; (c) runtime window_len at
  `init` — rejected: exact-pointer buffer types are the house rule
  (`AGENTS.md`, "Rules"). *Recommendation*: (b) — the named buffer is
  `[window_len + block_size_max]u8` with `window_len` comptime and a
  default constant at 8 MiB (ZD8/ZD9's floor, the level-19 pin), the frame's
  window checked against it with a named `WindowTooLarge` failure (the
  "authorized range", fail closed; the C's own default rejects beyond 128 MB,
  klauspost beyond 512 MB — ours is tighter and honest about it).
  → *README*: the `Reader.Buffer` type and the cap semantics.
- **OQ2 — the M4 surface shape.** The plan's M4 line is decoder-first; the
  barrel rule ("each namespace exposes exactly `{Reader, Writer, encode,
  decode}`") completes at M5. *Recommendation*: M4 ships `zstd.Reader` +
  `zstd.decode` (one-shot) with the four layers named and reachable inside
  the namespace (`zstd.decode.literals`, `.sequences`, `.fse`, `.frame` —
  the flate precedent of reachable internals like `BitWriter`/`copyMatch`),
  and the README states the M5 extension (encode/Writer land then, the
  reserved seat explicit, never silently absent). One-shot
  `zstd.decode.decompress(source, target) !usize` with `target` a cap (the
  flate contract), FCS-when-present checked against the decoded total (T7;
  the C and std both verify), and the caller's window = the target itself.
  → *README*: the namespace map and the M5 boundary.
- **OQ3 — the streaming frame boundary.** zstd is multi-frame the way gzip
  is multi-member (`§3.1`), and the frame checksum makes the frame end a
  trailer the wrapper must verify — the `src/internal/README.md`
  wrapper-rebase entry applies verbatim ("the zstd frame checksum rides this
  exact shape"): an over-the-end peek or record request at a frame's tail
  must route through the trailer step (checksum read + verify + boundary
  advance), never pass `EndOfStream` through with the state still streaming
  (fca3604's bug class). *Recommendation*: `Reader` = one frame with the
  exact boundary visible (the M3 contract), `Reader.streamAll` = the frame
  walk at that boundary (garbage in the next frame's place fails `BadMagic`;
  a skippable frame's 16 magics all skip; a file of only skippable frames is
  the clean end; the zero-byte input is `Truncated` for the single-frame
  decode and the clean end for the walk — the gzip T2/OQ3 decision mapped
  over, T10's CLI behaviors recorded beside it). → *README*: the Reader
  contract, the walk, the B1-pattern citation.
- **OQ4 — the dictionary surface.** `§5` leaves dictionaries out of band;
  `§2` demands the unambiguous error; the C fails "Dictionary mismatch"
  without the exact dict (verified); klauspost supports them; std rejects
  every DID-flagged frame up front. M4 has no dictionary entry points (none
  planned in the M4/M5 text), and the plan's standing rules are
  fail-closed. *Recommendation*: a named `DictionaryRequired` error at the
  first Dictionary_ID byte, before any body byte (the zlib-FDICT precedent,
  `zlib/README.md`'s OQ4), for both formatted and raw-content dictionaries;
  no silent skip, no std-style misparse; revisit only if a dictionary use
  case lands (the flate OQ6 deferral pattern).
- **OQ5 — the error taxonomy.** Compose, never wrap (the M3 OQ5 rule): the
  coarse `error.ReadFailed`/`error.EndOfStream` through the `Io` interface,
  the specific detail beside it in `err`, one name per corruption class so
  ZD1's "unambiguous error code" is real. The starting vocabulary, borrowed
  from all three references with our additions: `BadMagic` (unknown magic —
  the C's "unsupported format"), `ReservedBitSet` (descriptor; std's name),
  `ReservedBlock` (block type 3), `DictionaryRequired` (OQ4), `WindowTooLarge`
  (OQ1's cap; the C's "requires too much memory"), `BlockOversize` (ZD15,
  T7's shared label), `LiteralsTooLarge`/`MalformedLiteralsHeader` (ZD18-19),
  `MalformedFseTable` (the §4.1.1 rules: accuracy, budget, count),
  `MalformedHuffmanWeights` (ZD32's completion rules), `TreelessLiteralsFirst`
  / `RepeatModeFirst` (ZD17/ZD24; std's names), `MissingStartBit` (the
  last-byte-nonzero rule), `InvalidBitStream` / `BitstreamNotConsumed` (ZD26,
  ZD33's exact-consumption rules), `ZeroOffset` (T6), `OffsetTooFar` (ZD27's
  window bound), `ContentSizeMismatch` (FCS vs actual; T7), `WrongChecksum`
  (the XXH64 trailer; T8 — verify, never skip), `Truncated`. Keep the
  checksum and FCS mismatches as separate errors (std's example splits
  `ChecksumFailure` from `MalformedFrame`; klauspost splits `ErrCRCMismatch`
  from `ErrFrameSizeMismatch`).
- **OQ6 — the block staging and the two-pass decode.** The backwards
  bitstreams (sequences and literals) read from a block's *end*, so the whole
  compressed block must be staged before decoding — inherent to the format,
  not a choice (`§3.1.1.3.2.1.2`: "it is necessary to know the offset of the
  last byte"). The choice is the literals: "They can be decoded first and
  then copied during Sequence Execution, or they can be decoded on the flow"
  (`§3.1.1.3.1`). *Recommendation*: the references' shape — decode the
  literals into a comptime `[block_size_max]u8` scratch, then execute
  sequences from it into the window (std does exactly this:
  `literals_buffer` + `sequence_buffer`, both `[1 << 17]u8`, `:315-327`).
  Total stack scratch ~256 KB, comptime, zero allocation; the trailing
  literals (ZD27) come out of the same buffer. The one-shot decode writes
  literals into the target directly when the frame is literals-only.
- **OQ7 — where the XXH64 rides.** The M3 OQ1 question, answered far more
  simply here: zstd's decode is block-batched, and every decoded byte of a
  block lands in the window/output through one per-block funnel (raw: the
  block bytes; RLE: the splat; compressed: the sequence-execution writes plus
  the trailing literals). *Recommendation*: hash at that one per-block
  emission boundary — every byte hashed exactly once, no second pass, no
  container buffer, and the same hook covers the one-shot decode (hash each
  block's output as it lands in `target`). The `err` path never needs the
  hash; the checksum compares only at the frame end (`§3.1.1`).

## 8. Ranked ambiguities — the ones most likely to bite

1. **OQ1 — the window buffer and cap.** The largest surface decision of the
   milestone: zstd's window is frame-declared (1 KB..3.75 TB) against flate's
   fixed 32 KB history, the spec explicitly authorizes rejection beyond the
   decoder's range, and the level-19 corpus needs 8 MiB. Decide before the
   sketch; every streaming test sizes a buffer against it.
2. **T6 — the offset-0 corner.** The RFC is silent, the C and std reject,
   klauspost silently substitutes offset 1 and *decodes corrupt frames* —
   the exact divergence a golden corpus must pin (off0.bin.zst) and the
   fail-closed posture answers. A wire-level bug in the repeat-offset
   resolution shows up here first.
3. **T1 + T2 + T3 — the spec's own errata.** The §4.2.2 example's bytes,
   Appendix A's artifact rows, Table 18's offset_value: three places the
   vendored text misleads a literal implementer. The T1 fixture pair proves
   the code assignment on two decoders; the ported fixtures drop the
   artifact rows; the repeat-offset tests derive from the rules, not the
   table cells.
4. **T5 — the nbSeq decoded-zero corner.** RFC text ends the section on
   byte0 == 0; the reference family ends it on a decoded zero in any form,
   with a golden fixture; std gets it wrong. A conformance lane built only
   from the RFC text fails a real fixture.
5. **T8 — the checksum duty.** The RFC makes it optional, the references
   verify, std's verification is a documented panic. Ours verifies; the
   one-line trap (hashing the *compressed* instead of the decoded data, or
   the full 8 bytes instead of the low 4) is caught by the §3 cross-check
   pattern (std's XxHash64 vs the CLI trailer).
6. **OQ3 + T10 — the frame boundary and cardinality.** The wrapper-rebase
   B1 shape (the frame checksum at the frame end) plus the
   trailing-garbage/empty-input policy; the gzip decisions map over but the
   skippable-frame handling (silent skip, 16 magics, watermark note at
   `§3.1.2`) is new surface.
7. **T9 — the FSE symbol-count rule.** The RFC's "not equal to the expected"
   read literally rejects legal short distributions; the references enforce
   exceed-only. The fuzz lane owns the corner; the notes record the
   reading.

The three that gate the README sketch: **OQ1** (the buffer type and cap),
**OQ2/OQ3** (the surface shape and the frame boundary), and **OQ4/OQ5**
(the dictionary refusal and the error names) — the same trio M3's ranked
list ended on, one milestone later.
