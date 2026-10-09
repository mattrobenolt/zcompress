# gzip and zlib research notes

The research stage of the codec development loop for the M3 containers: gzip
(RFC 1952) and zlib (RFC 1950) over the completed raw-flate module. Specs:
`docs/research/specs/rfc1952-gzip.txt` and `docs/research/specs/rfc1950-zlib.txt`
(vendored, verbatim). Every requirement line below cites one of those files and
its section; where an RFC is ambiguous or silent, that is stated explicitly and
the divergence is recorded as a decision for the parent, never silently picked.
The flate module these containers wrap is `src/flate/` (README.md, its API and
its contracts); flate's own research file — `docs/research/flate-notes.md`,
cited below as `flate-notes.md` — is the pattern this file follows and the
authority on everything inside the deflate body.

## 0. Provenance

- Specs: `rfc1952-gzip.txt` — RFC 1952, "GZIP file format specification version
  4.3" (Deutsch, May 1996), 25,037 bytes — and `rfc1950-zlib.txt` — RFC 1950,
  "ZLIB Compressed Data Format Specification version 3.3" (Deutsch and Gailly,
  May 1996), 20,502 bytes. Both verified by title line and byte count; both
  provenance rows already in `docs/research/specs/README.md` (fetched
  2026-10-08 from rfc-editor.org). Each document's own Notices grant copying
  for any purpose with the notice preserved.
- Reference implementations read for this file (cited inline as
  `repo path:file:line`): golang/go `src/compress/gzip/` and
  `src/compress/zlib/` (BSD-3-Clause, local checkout `~/code/golang/go`),
  klauspost/compress `gzip/` and `zlib/` (BSD-3-Clause, local checkout
  `~/code/klauspost-compress`), Zig 0.16 std `std/compress/flate/` (MIT,
  local: `/nix/store/amh3bnymjncd56jwmd2hqdkciz9d7pys-zig-0.16.0/lib/zig/`),
  ebiggers/libdeflate `lib/crc32.c`, `lib/gzip_compress.c`,
  `lib/gzip_decompress.c` (MIT, fetched from master), and zlib-ng `crc32.c`,
  `zutil.h`, `arch/**` (zlib license, fetched from develop). madler/zlib's
  emission rules were verified through the oracle rather than read.
- Local oracle: python3 3.14.7's `zlib` and `gzip` modules (CPython, PSF
  license — run as a CLI, nothing vendored; the `zlib` module links the C
  reference, so `zlib.compressobj` behaviors are C zlib behaviors) and the
  gzip/gunzip 1.14 CLIs (nix store, on PATH). Every incantation in §5.5 was
  run and round-tripped here before being written down; every "verified" fact
  below names its evidence.
- Two premises in the task brief needed correction, recorded rather than
  smoothed over (the flate-notes §0 precedent): (1) the brief asked whether
  std has the ISO 3309 polynomial "or only Iscsi" — std has both, and
  `std.hash.crc.Crc32` IS the ISO one (`std/hash/crc.zig:13`,
  `pub const Crc32 = Crc32IsoHdlc`; verified against known check values in
  §3.1). (2) `std.hash.Adler32` exists (`std/hash/Adler32.zig`, the RFC 1950
  §9 deferred-mod shape) and matches C zlib exactly on the values tested
  (§3.2). Neither fixup is needed; the one-liner trap is the *other* name in
  the same file, `Crc32Iscsi` — CRC-32C, the wrong polynomial for gzip.

## 1. Format summary

### 1.1 gzip (`rfc1952-gzip.txt`)

A gzip **file** is "a series of 'members' (compressed data sets)"; "the members
simply appear one after another in the file, with no additional information
before, between, or after them" (`§2.2`). A **member** is a 10-byte fixed
header, optional fields, one raw deflate body, and an 8-byte trailer (`§2.3`).

The fixed header (`§2.3.1`):

| bytes | field | rule |
|-------|-------|------|
| 0-1 | ID1, ID2 | fixed 0x1f, 0x8b (`§2.3.1`) |
| 2 | CM | 8 = deflate; 0-7 reserved (`§2.3.1`) |
| 3 | FLG | bit 0 FTEXT, 1 FHCRC, 2 FEXTRA, 3 FNAME, 4 FCOMMENT, 5-7 reserved (`§2.3.1`) |
| 4-7 | MTIME | u32, Unix seconds; 0 = no timestamp (`§2.3.1`) |
| 8 | XFL | deflate: 2 = max compression, 4 = fastest (`§2.3.1`) |
| 9 | OS | the `§2.3.1` table, 0-13 plus 255 unknown |

Optional fields, in order (`§2.3`, `§2.3.1`): FEXTRA → XLEN (u16) then XLEN
bytes of SI1/SI2/LEN subfields (`§2.3.1.1`); FNAME → the original file name,
NUL-terminated, ISO 8859-1, directory components removed, case-insensitive
names lower-cased (`§2.3.1`); FCOMMENT → a NUL-terminated Latin-1 comment,
"not interpreted... only intended for human consumption" (`§2.3.1`); FHCRC →
CRC16, "the two least significant bytes of the CRC32 for all bytes of the gzip
header up to and not including the CRC16" (`§2.3.1`).

The trailer (`§2.3.1`): CRC32 — "a Cyclic Redundancy Check value of the
uncompressed data computed according to CRC-32 algorithm used in the ISO 3309
standard" — then ISIZE — "the size of the original (uncompressed) input data
modulo 2^32". Both u32, both little-endian: "All multi-byte numbers in the
format described here are stored with the least-significant byte first (at
the lower memory address)" (`§2.1`; its 520 example is `|00001000|00000010|`).

### 1.2 zlib (`rfc1950-zlib.txt`)

A zlib stream is a 2-byte header, optionally a 4-byte DICTID, one raw deflate
body, and a 4-byte trailer; "any data which may appear after ADLER32 are not
part of the zlib stream" (`§2.2`).

The header (`§2.2`): CMF — bits 0-3 CM (8 = deflate, "with a window size up
to 32K"; 15 reserved), bits 4-7 CINFO (the base-2 log of the window size minus
8; "values of CINFO above 7 are not allowed in this version") — and FLG —
bits 0-4 FCHECK, bit 5 FDICT, bits 6-7 FLEVEL. FCHECK "must be such that CMF
and FLG, when viewed as a 16-bit unsigned integer stored in MSB order
(CMF*256 + FLG), is a multiple of 31" (`§2.2`). FDICT set → DICTID follows,
the Adler-32 of the preset dictionary (`§2.2`). FLEVEL is "not needed for
decompression; it is there to indicate if recompression might be worthwhile"
(`§2.2`).

The trailer (`§2.2`): ADLER32 of "the uncompressed data (excluding any
dictionary data)", stored "in most-significant-byte first (network) order".
Adler-32: s1 = sum of bytes plus 1, s2 = sum of the s1 values, both mod 65521,
the value s2*65536 + s1 (`§2.2`, algorithm in `§8.2`, sample in `§9`).

zlib's byte order is the opposite of gzip's, in the same family, from the
sibling RFC: "All multi-byte numbers in the format described here are stored
with the MOST-significant byte first (at the lower memory address)" — RFC
1950's 520 example is `|00000010|00001000|`, the same number, the opposite
order of RFC 1952's (`rfc1950-zlib.txt §2.1` vs `rfc1952-gzip.txt §2.1`). The
FCHECK arithmetic reads CMF/FLG as one big-endian u16; DICTID and ADLER32 are
big-endian; flate's own LEN/NLEN under the same wrapper are little-endian
(`rfc1951-deflate.txt §3.2.4`).

## 2. Requirements matrix

The two RFCs' compliance sections are the root obligations. RFC 1952 `§1.4`:
"a compliant decompressor must be able to accept and decompress any file that
conforms to all the specifications presented here; a compliant compressor
must produce files that conform to all the specifications presented here."
RFC 1950 `§1.4` says the same of streams, and adds a decoder-side checksum
duty in `§2.3` (D5 below).

### 2.1 A conformant gzip decoder

| # | requirement | cite |
|---|-------------|------|
| GD1 | Check ID1, ID2, CM; error indication on wrong values | `rfc1952-gzip.txt §2.3.1.2` ("must check ID1, ID2, and CM, and provide an error indication if any of these have incorrect values") |
| GD2 | Examine FEXTRA/XLEN, FNAME, FCOMMENT, FHCRC at least enough to skip the optional fields when present | `§2.3.1.2` |
| GD3 | Error indication if any reserved FLG bit is non-zero — a set reserved bit "could indicate the presence of a new field that would cause subsequent data to be interpreted incorrectly" | `§2.3.1.2` |
| GD4 | Accept any deflate body that conforms to RFC 1951 (block types, sizes, trees, distances — flate's own D1-D11 matrix, `flate-notes.md §2.1`) | `§1.4`, `§2.3.1` (CM=8 "documented elsewhere") |
| GD5 | The trailer check is not a MUST: "It need not examine any other part of the header or trailer" — CRC32/ISIZE verification is optional for compliance, recommended for security | `§2.3.1.2`, `§4` ("provide some means of validating the integrity... such as by setting and checking the CRC-32 check value") |
| GD6 | May ignore FTEXT and OS "and always produce binary output, and still be compliant" — FTEXT is advisory both directions ("We deliberately do not specify the algorithm used to set this bit") | `§2.3.1.2`, `§2.3.1` |
| GD7 | XFL, MTIME: no decoder obligation (covered by GD5's "need not examine"); MTIME=0 means no timestamp available | `§2.3.1.2`, `§2.3.1` |

GD5 is the asymmetry to record: RFC 1950 makes the trailer checksum a decoder
MUST (ZD1) and RFC 1952 does not. Every reference gzip reader verifies anyway
(Go, CPython, the gzip CLI, libdeflate; std's Decompress does not — §2.5 T4).
Our house posture — decode fails closed, "no partial output is trusted past the
error" (`src/flate/README.md`, "Contracts") — says verify; the call is recorded
as a decision in §2.5, not as a spec fact.

### 2.2 A conformant gzip encoder

| # | requirement | cite |
|---|-------------|------|
| GE1 | Correct ID1, ID2, CM, CRC32, ISIZE; all other fixed-header fields may take the defaults — "255 for OS, 0 for all others" | `§2.3.1.2` |
| GE2 | All reserved bits zero | `§2.3.1.2` ("The compressor must set all reserved bits to zero") |
| GE3 | Multi-byte numbers little-endian: MTIME, XLEN, CRC32, ISIZE | `§2.1` |
| GE4 | FNAME/FCOMMENT, when present: ISO 8859-1 (Latin-1), NUL-terminated; the name is the original name with directory components removed, lower-cased on case-insensitive file systems; no name when the source was not a named file | `§2.3.1` |
| GE5 | FEXTRA, when present: XLEN-bounded subfields of SI1/SI2/LEN; SI2=0 subfield IDs "reserved for future use" | `§2.3.1.1` |
| GE6 | FHCRC, when present: the low 16 bits of the CRC32 over all header bytes before the CRC16 | `§2.3.1` |
| GE7 | XFL under deflate: 2 = maximum compression, 4 = fastest | `§2.3.1` |
| GE8 | FTEXT is optional and its setting algorithm is deliberately unspecified; a compressor "always has the option of leaving it cleared" | `§2.3.1` |
| GE9 | CRC32 of the uncompressed data per ISO 3309; ISIZE = the uncompressed size mod 2^32 | `§2.3.1` |
| GE10 | One member per stream is compliant: a file is "a series" of members and the compressor writes as many as it has data sets for | `§2.2` |

### 2.3 A conformant zlib decoder

| # | requirement | cite |
|---|-------------|------|
| ZD1 | Check CMF, FLG, and ADLER32; error indication on incorrect values — the trailer checksum is a decoder MUST here (the RFC 1950/1952 asymmetry, GD5) | `rfc1950-zlib.txt §2.3` |
| ZD2 | Error indication if CM is not 8 — "another value could indicate the presence of new features that would cause subsequent data to be interpreted incorrectly" | `§2.3` |
| ZD3 | Error indication if FDICT is set and DICTID is not the identifier of a known preset dictionary | `§2.3` |
| ZD4 | Reject FDICT streams when the embedding format has no preset-dictionary feature — standalone zlib has no dictionary registry, so a dict-less decoder rejects every FDICT stream | `§2.3` (last two sentences, read together) |
| ZD5 | CINFO above 7 is invalid on its face ("not allowed in this version") | `§2.2` |
| ZD6 | May ignore FLEVEL | `§2.3` |
| ZD7 | The stream ends at ADLER32; bytes after it are not part of the stream | `§2.2` |

Go's reader implements ZD1-ZD5 exactly (`src/compress/zlib/reader.go:150`
checks CM, CINFO ≤ 7, and `h%31 != 0` in one line; `:154-165` reads DICTID and
errors `ErrDictionary` on mismatch with the caller's dictionary). C zlib
returns Z_NEED_DICT for the ZD3/ZD4 case (verified through the oracle: a dict
stream decoded without a dict raises "Error 2 while decompressing data").

### 2.4 A conformant zlib encoder

| # | requirement | cite |
|---|-------------|------|
| ZE1 | Correct CMF, FLG, ADLER32 | `§2.3` |
| ZE2 | Need not support preset dictionaries at all; when the embedding format does not use them, must not set FDICT | `§2.3` |
| ZE3 | FDICT, when set, is followed by DICTID = the Adler-32 of the dictionary | `§2.2` |
| ZE4 | FCHECK such that (CMF*256 + FLG) as an MSB-order u16 is a multiple of 31 | `§2.2` |
| ZE5 | FLEVEL is informational; no decoder may require a value | `§2.2` |
| ZE6 | ADLER32 covers the uncompressed data excluding dictionary data, stored big-endian | `§2.2` |
| ZE7 | Multi-byte numbers MSB-first: DICTID, ADLER32; the FCHECK arithmetic reads CMF/FLG big-endian | `§2.1`, `§2.2` |

### 2.5 Spec-vs-reference divergences (decisions for the parent)

The RFCs are silent exactly where every container implementation picks.
Both sides recorded; none silently picked.

- **T1 — the OS byte: emitted values vs the RFC table.** `rfc1952-gzip.txt
  §2.3.1` defines 0-13 plus 255; `§2.3.1.2` allows a compressor to default
  everything to "255 for OS, 0 for all others". What real emitters write
  (all header bytes read directly, not inferred): the gzip 1.14 CLI writes 3
  (verified: `1f 8b 08 08 <mtime> 00 03`); the C zlib gzip wrapper writes 3
  (verified: `zlib.compressobj(6, DEFLATED, 31)` → `...00 03`); Go writes
  255 (`src/compress/gzip/gzip.go:76`, `OS: 255 // unknown`); klauspost
  writes 255 (`gzip/gzip.go:108`, the same file); libdeflate writes
  `GZIP_OS_UNKNOWN` = 255 (`lib/gzip_compress.c`); CPython's `gzip` module
  writes 255 (verified: `gzip.compress` → `1f 8b 08 00 ... 00 ff`); std writes
  3 (`std/compress/flate/flate.zig`, `Container.header`: `0x03`); zlib-ng
  writes `OS_CODE` from `zutil.h` — 3 default, 10 on Win32, **19 on Apple**,
  a value outside the RFC's table entirely. A decoder must accept any OS byte
  (`§2.3.1.2`, GD6). Decision: our emitted value (recommendation: 255, the
  compliance-section default, matching Go/libdeflate/CPython; std's 3 is the
  CLI heritage).
- **T2 — trailing bytes, member cardinality, the empty file.** `§2.2` says a
  file is "a series" of members with nothing between or after them, and never
  says whether "series" means one-or-more or zero-or-more (Go's own test
  comment: `src/compress/gzip/gunzip.go`, `TestNilStream`, "Other than this,
  the specification does not clarify..."). The references split four ways on
  trailing bytes and the empty input: Go reads a next member's header —
  garbage after a complete member is `ErrHeader`, a truncated next header is
  `io.ErrUnexpectedEOF`, clean EOF is `io.EOF`, and an empty input is accepted
  as a zero-member file (`gunzip_test.go`'s "+ garbage", "+ not enough
  header", and `TestNilStream` vectors); the gzip CLI decompresses the member
  and *warns* "trailing garbage ignored" (exit 2), silently tolerates
  trailing zero bytes (verified: one appended 0x00 → exit 0), and *errors* on
  a zero-byte file ("unexpected end of file", verified); CPython's
  `gzip.decompress` errors on garbage, accepts 8 trailing zeros, and accepts
  an empty input (all verified); libdeflate decodes exactly one member and
  reports its end via `actual_in_nbytes_ret` (`lib/gzip_decompress.c`),
  leaving concatenation to the caller; std is single-member and its own
  harness notes it "expects... multiple streams to not be concatenated"
  (`std/compress/flate/Compress.zig:1873`). Decision: our reader's member
  boundary and trailing-byte policy (recommendation in §4 OQ3: single member,
  exact boundary, fail closed on trailing garbage).
- **T3 — FHCRC verification.** `§2.3.1` defines the value precisely; `§2.3.1.2`
  requires examining the field only "so it can skip over the optional
  fields". The references split: Go verifies — `gunzip.go:231`,
  `if digest != uint16(z.digest) { return hdr, ErrHeader }`; CPython does
  not (verified: a member with a corrupted FHCRC decodes without error);
  libdeflate skips without verifying (`lib/gzip_decompress.c`,
  `in_next += 2`); std discards without verifying (`std/compress/flate/
  Decompress.zig:305-307`, `try in.discardAll(2)`). Decision: verify or skip
  (recommendation: verify — the cost is one CRC-32 over ≤ a few hundred
  header bytes, and Go — the conformance suite's fixture source — pins it).
- **T4 — gzip trailer verification vs the zlib MUST.** GD5: RFC 1952 makes the
  CRC32/ISIZE checks optional ("need not examine any other part of the header
  or trailer"); ZD1: RFC 1950 makes the ADLER32 check a MUST. Every reference
  gzip reader verifies the trailer anyway (Go `gunzip.go:267`, CPython, the
  CLI, libdeflate's `gzip_decompress.c` checks both CRC32 and ISIZE); the one
  that does not is std — its `Decompress` reads the footer into
  `container_metadata` and never compares it, and the `WrongGzipChecksum`/
  `WrongGzipSize`/`WrongZlibChecksum` errors exist only as declarations
  (`std/compress/flate/flate.zig:55-57`; searched: no return site anywhere).
  Decision: verify both containers' trailers, fail closed (the house posture;
  the divergence row documents that this exceeds RFC 1952's minimum).
- **T5 — the FCHECK=31 corner.** `§2.2` requires only that (CMF*256+FLG) be a
  multiple of 31; both common emission formulas satisfy it, but they differ
  in one corner: with CMF=0x78, FLEVEL=0, FDICT=1, the partial FLG is 0x20
  and (CMF*256+0x20) % 31 == 0 — the naive `FCHECK = 31 - remainder` (no
  outer modulo) emits **31** (FLG=0x3f, FCHECK=11111b), the minimal
  `(31 - remainder) % 31` emits 0 (FLG=0x20). Both C zlib and Go use the
  naive form (Go: `zlib/writer.go:118`,
  `z.scratch[1] += uint8(31 - binary.BigEndian.Uint16(z.scratch[:2])%31)`;
  C zlib verified through the oracle: `zlib.compressobj(0, DEFLATED, 15, 9,
  Z_DEFAULT_STRATEGY, dict)` emits header `78 3f`). FCHECK=31 is conformant
  — 31 ≡ 0 mod 31, and it fits the 5-bit field — so a decoder must accept
  it (a decoder that validates FCHECK by re-deriving with the minimal formula
  and comparing rejects the entire Go/C-zlib output family in this corner;
  validate by `h % 31 == 0`, never by re-derivation).
- **T6 — std's zlib header parse is the lax outlier.** std checks CM and
  CINFO only (`std/compress/flate/Decompress.zig:310-314`,
  `if (cmf.cm != 8 or cmf.cinfo > 7) return error.BadZlibHeader`) — no FCHECK
  validation (a `78 9f` header fails in Go and C zlib, decodes in std) and no
  FDICT handling (an FDICT stream's 4 DICTID bytes are decoded as deflate
  data — a misparse, not an error). Go checks FCHECK (`reader.go:150`) and
  handles FDICT (`:154-165`). The reference lineage (Go + C zlib) is the
  conformance bar; std's laxness is a divergence to note, not to copy.
- **T7 — header-field caps on hostile input.** The RFCs bound nothing beyond
  XLEN being a u16 (≤ 65,535 bytes of extra field) and the deflate body's own
  limits; FNAME/FCOMMENT are unbounded NUL-terminated strings on the wire. Go
  caps both at 512 bytes (`gunzip.go:145`, `if i >= len(z.buf) { return "",
  ErrHeader }` — a house rule, not a spec rule); libdeflate requires each
  skipped field to fit the declared input with room for the footer
  (`lib/gzip_decompress.c` bounds checks). Decision: our caps and the
  amplification story (the security surface; the fuzz lane's target). A
  zero-alloc reader cannot stage a 64-KiB extra field — hash it streaming
  from the input buffer, never stage it (§4 OQ6).

## 3. The checksums

### 3.1 CRC-32 (gzip)

The value: CRC-32 as used in "the ISO 3309 standard and in section 8.1.1.6.2
of ITU-T recommendation V.42" (`rfc1952-gzip.txt §2.3.1`), over the
uncompressed data (GE9). The algorithm, in the RFC's own sample code (`§8`,
marked "not part of the specification per se" by `§1.4` — the normative
reference is ISO 3309, the sample is the description of it): a reflected
bytewise table built from the polynomial 0xEDB88320 (`§8 make_crc_table`),
a running `crc` with the one's-complement pre/post-conditioning inside
`update_crc` (`c = crc ^ 0xffffffffL` at entry and exit, init 0), one table
lookup and one shift per byte. The same CRC also computes FHCRC (the low 16
bits over the header bytes, `§2.3.1`) — verified against the Go golden
"header with all fields used" vector: the CRC32 over the reconstructed
header bytes (10 fixed + XLEN + subfield + name+NUL + comment+NUL) is
0xF46EFD92, low 16 = 0xFD92, exactly the vector's FHCRC.

What std has, verified by running (`zig run` against the 0.16.0 store):

- `std.hash.crc.Crc32` **is** the gzip CRC-32: `crc.zig:13` aliases
  `Crc32IsoHdlc` — polynomial 0x04C11DB7, `reflect_input`/`reflect_output`
  true, initial and xor-output 0xFFFFFFFF (`crc.zig:808-814`) — the reflected
  form whose bytewise table constant is 0xEDB88320. Verified:
  `Crc32("123456789")` = 0xCBF43926 (the standard check value) and
  `Crc32("hello world\n")` = 0xAF083B2D, the bytes Go's gzip golden trailer
  carries little-endian (`2d 3b 08 af`, `src/compress/gzip/gunzip_test.go`
  "hello.txt"). The implementation: a comptime-generated 256-entry bytewise
  table and a per-byte scalar `update` (`std/hash/crc/impl.zig:39-83`) —
  correct and scalar, the day-one kernel.
- `std.hash.crc.Crc32Iscsi` is CRC-32C (polynomial 0x1EDC6F41, `crc.zig:800`;
  check value 0xE3069283, verified) — **the wrong polynomial for gzip**. It is
  the CRC snappy's stream framing uses, not this repo's snappy and not
  here.
- `std.hash.crc.Crc32SmallWithPoly` is a dangling declaration in the 0.16.0
  tree: `crc.zig:8` references `impl.Crc32SmallWithPoly`, which does not
  exist in `crc/impl.zig` (102 lines, `Algorithm` + `Crc` only; compile error
  reproduced here). Use the direct `Crc(...)`-derived names only.

### 3.2 Adler-32 (zlib)

The value: two sums mod 65521 — "s1 is the sum of all bytes, s2 is the sum of
all s1 values... s1 is initialized to 1, s2 to zero. The Adler-32 checksum is
stored as s2*65536 + s1 in most-significant-byte first (network) order"
(`rfc1950-zlib.txt §2.2`), over the uncompressed data excluding dictionary
data (ZE6). The rationale appendix fixes the implementation shape: "The
modulo on unsigned long accumulators can be delayed for 5552 bytes" (`§8.2`),
s1 starts at 1 "to make the length of the sequence part of s2" (`§8.2`), and
65521 is prime to kill a class of two-byte errors the Fletcher checksum
(255, non-prime) misses (`§8.2`). The sample (`§9`) is the per-byte form with
`% BASE` on every step — informative, not the fast shape.

What std has, verified by running: `std.hash.Adler32` (`std/hash/Adler32.zig`,
header citing `rfc1950 §9` and madler/zlib's `adler32.c`) — the 5552-block
deferred-modulo form with a 16-byte comptime-unrolled inner loop
(`Adler32.zig:39-77`, `nmax = 5552`, `n = nmax / 16`, `comptime` `j` 0..16)
plus short-input paths, state `adler: u32 = 1`, and a pure `permute(state,
input) u32` alongside `update`/`hash`. Verified:
`Adler32("Wikipedia")` = 0x11E60398 (the standard check value) and
`Adler32("Hello world\n")` = 0x1CF20447 = std's own zlib test footer `1c f2 04
47` big-endian = C zlib's value (`python3 zlib.adler32` agrees). Day-one
kernel: std's, correct and in-tree.

### 3.3 The kernel plan (deferred decisions, recorded not decided)

- The M3 milestone carries "crc32 and adler32 kernels" and the plan defers
  "crc32 via PCLMULQDQ inline asm versus folded-vector arithmetic: M3, after
  the ghash_polyval study" (`docs/zcompress-plan.md`, "Milestones" and
  "Decisions deferred"). The study target exists in-tree:
  `std/crypto/ghash_polyval.zig` — comptime-precomputed powers h^1..h^16,
  aggregation thresholds at 22/84/328 blocks (`ghash_polyval.zig:47-49`),
  Karatsuba/schoolbook Zig arithmetic off x86 and `vpclmulqdq` inline asm on
  x86 (`:44`, `:92-113`). Not decided here; the slice-by-8 table method is
  the scalar ceiling (libdeflate's default, `lib/crc32.c crc32_slice8`, 8
  interleaved 256-entry tables) and PCLMUL folding is the known-native
  ceiling (libdeflate's x86 dispatch; zlib-ng's `arch/x86/
  crc32_pclmulqdq_tpl.h`, its AVX2/AVX512 vpclmulqdq variants, ARMv8's CRC32
  instructions `arch/arm/crc32_armv8.c`).
- Kernel placement: `src/internal/` needs two codecs per primitive
  (`docs/zcompress-plan.md`, "Architecture") and neither kernel has a second
  user — CRC-32's only user is gzip (snappy's framing CRC is CRC-32C and not
  in this repo's snappy; zstd at M4 uses xxhash; lzw uses none), Adler-32's
  only user is zlib. The kernels land inside their codec directories;
  `src/internal/checksum.zig` waits for a second user.
- Kernel API shape: libdeflate's — `libdeflate_crc32(crc, p, len)` with the
  pre/post-conditioning inside and a documented "return initial value" for
  null (`lib/crc32.c`), the incremental form a streaming container needs.
  Wrapping std's day-one kernels behind our own function boundary of that
  shape makes the perf-lane swap invisible to the containers.

### 3.4 Where our container hashes — the constraint

flate's std cross-check already named this: std "hashes bytes as they enter
the history buffer — the container checksum never gets a separate pass. When
gzip/zlib wrap this module, hashing at the Writer's accept/drain boundary
(bytes as they enter the history) is the zero-pass option"
(`flate-notes.md §8`, "Steal for M3"). std gets that for free because its
container lives *inside* flate (`Compress.zig:82`, `hasher:
flate.Container.Hasher`, updated at `:518`, `:533`, `:1677`); our flate is
raw-only by the M2 decision (`src/flate/README.md`: "No container... M3
builds them over this module"), and its buffers are flate-owned once handed
over — a wrapping container cannot reach the history bytes at all. The
options, enumerated with costs, are §4 OQ1.

## 4. The wrapping design questions

Decisions deferred to the README sketches; each labeled with its
recommendation. The surfaces wrap `src/flate/` exactly as it shipped: the
four-namespace barrel (`flate.encode`, `flate.decode`, `flate.Writer`,
`flate.Reader`), `Reader`'s exact-consumption contract ("The Reader consumes
`input` exactly through the stream's last byte... and stops there; bytes
after the stream are not consumed. (That is what lets M3's gzip/zlib readers
find their footers.)" — `src/flate/README.md`, "Streaming"), and
`Writer.finish` as the terminal call.

- **OQ1 — where the container hashes.** The one-shot encode side is trivial:
  the container holds `source`, so `gzip.encode.compress` writes the header,
  calls `flate.encode.compress(source, target[h..], options)`, CRC-32s
  `source` directly, and writes the trailer — one hash pass over the input,
  no flate involvement. The one-shot decode side is nearly trivial: post-hoc
  hash `target[0..n]` (one extra pass) with the trailer located through the
  fixed-reader route (OQ2). The **streaming** sides are the real question,
  and the answer differs per side. *Encode:* (a) container-writer front —
  the container is its own `Io.Writer` with its own embedded buffer; its
  `drain`/`flush`/`rebase` hash the drained bytes and forward through
  `&flate_writer.writer` (Go's shape: `gzip.go:229`,
  `z.digest = crc32.Update(z.digest, crc32.IEEETable, p)` on the write path;
  `zlib/writer.go:161`, `z.digest.Write(p)`). Cost: a second buffer and a
  second copy of every byte (caller → container buffer → flate buffer), and
  the hash sees caller-write-shaped slices. (b) flate hook — an optional,
  default-null checksum field on `flate.Writer`, updated inside `emitBlock`,
  which is the single funnel every emitted byte already passes through
  (`Writer.zig`: drain `:228`, flush `:247`, rebase `:261`, finish `:127` all
  call `emitBlock`). Cost: a post-review change to the M2 surface; benefit:
  zero extra copies, block-sized (≤ 64 KiB) hash slices, no container
  buffer. (c) hash the container's own buffer — impossible: the flate
  `Writer.Buffer` is handed to flate and slid continuously; bytes leave it
  as it rebases. *Decode:* (a') interposed hashing writer for the `stream`
  path — leaves `readVec`/`discard` to separate mechanisms, the messiest;
  (b') a staging serve loop — every vtable method funnels through one loop
  that peeks/takes from the inner flate `Reader` into a small staging buffer,
  hashes, and serves (std's own test harness pattern,
  `Compress.zig:1435-1438`: `peekGreedy` + `data_hash.update` + `toss`);
  cost: one extra copy per served byte plus a staging buffer; (c') the flate
  hook at the window-fill write points — the literal store, the match copy,
  and the stored copy (`Reader.zig:347`, `:382`, `:326`), plus the one-shot
  decode path in `decode.zig`; zero copies, covers `stream`, `readVec`, and
  `discard` uniformly, but four hook sites and the same M2-surface cost.
  *Recommendation:* the hook (b)/(c'), default-null so the raw module pays
  nothing and its API gains one optional field — it is the only option that
  covers every consumer path with zero extra copies, and flate's own notes
  already pointed at it as "the zero-pass option" (`flate-notes.md §8`);
  the container-side (a)/(b') is the fallback if the M2 surface is ruled
  frozen, and the decision is the parent's, not the implementer's.
- **OQ2 — surface shape and the one-shot trailer location.** Both layers,
  mirroring flate's surface: one-shot `gzip.encode.compress(source, target,
  options)` + `gzip.decode.decompress(source, target)`, streaming
  `gzip.Writer`/`gzip.Reader` over `std.Io`, `streamAll` conveniences — the
  same for zlib. Constraint: `flate.decode.decompress` returns only the
  decoded length, not the consumed input length (`decode.zig:424`), so a
  one-shot container decode cannot locate its trailer in `source` from that
  call. Two routes: route the one-shot decode through the streaming reader
  over `Io.Reader.fixed(source[h..])` — the fixed reader's `seek` after the
  decode is the exact trailer position, the same contract `Reader.streamAll`
  already rides (`Reader.zig:1060`, stack-buffered, zero allocation) — or
  expose a consumed count from flate (another M2-surface change).
  *Recommendation:* the fixed-reader route; no flate change, and the exact
  consumption contract was built for exactly this. Module wiring: the
  containers are build modules importing `fastmem` *and* `flate`
  (`build.zig`'s one-module-per-codec pattern gains
  `gzip_mod.addImport("flate", flate_mod)`) — the plan's "containers over
  flate" (`docs/zcompress-plan.md`, "Scope and build order") is the sanctioned
  exception to the no-cross-codec-imports rule; a container lifts out with
  flate in tow. Confirm at the sketch.
- **OQ3 — the multi-member surface.** `§2.2` allows concatenated members;
  the references split (T2). Our flate `Reader`'s exact-consumption contract
  already yields the natural member boundary (the input position after the
  final block's padded byte). *Recommendation:* single-member readers whose
  end is exact and trailing bytes unconsumed — multi-member composes outside
  the reader (a caller loop, or a later `.multi` wrapper if wanted), the
  libdeflate shape (`actual_in_nbytes_ret`). Trailing garbage: fail closed
  (the next member's header would be garbage — Go's `ErrHeader` is the
  reference behavior; the CLI's "trailing garbage ignored" warning and
  CPython's silent trailing-zero tolerance are recorded divergences, not our
  behavior). The conformance suite pins Go's "hello.txt x2" concatenation
  golden decoded member-by-member. The empty input (zero members): decide
  explicitly — Go accepts (io.EOF), the CLI errors, CPython accepts; erroring
  (Truncated) is the fail-closed choice, accepting is the Go choice; record
  either way.
- **OQ4 — the FDICT surface.** ZD3/ZD4 make rejecting FDICT streams
  conformant for a dictionary-less standalone decoder — Go's `NewReader`
  (nil dict) rejects every FDICT stream via `ErrDictionary` (`reader.go:164`,
  DICTID ≠ adler32(nil)=1). Decoding an FDICT stream's body needs flate's
  preset-dictionary entry point, which flate deferred (OQ6,
  `flate-notes.md §6`; `src/flate/README.md`: "No preset dictionaries...
  nothing here precludes a dictionary entry point later") — the first block's
  matches reference the dictionary as pre-history. *Recommendation:* a named,
  sticky decode error for FDICT (its own error name, so the Go "dictionary"
  and "wrong dictionary" goldens pin it), no dictionary-carrying init until
  flate's OQ6 lands and the flate surface gains the entry point; the encoder
  never sets FDICT (ZE2's "need not support" covers it — Go's writer supports
  dicts via `NewWriterLevelDict`, C zlib via `deflateSetDictionary`; ours
  writes FDICT=0 always, which every reference decoder accepts).
- **OQ5 — error taxonomy.** Compose, do not wrap: the container's detailed
  `err` union is the flate detail union plus the container's own entries —
  std's precedent (`std/compress/flate/Decompress.zig:48`,
  `pub const Error = Container.Error || error{...}`), our house shape (the
  coarse `error.ReadFailed`/`EndOfStream` through the `Io` interface, the
  specific failure beside it in `err`). Container entries to sketch: gzip —
  bad magic/CM/reserved-bits (one `BadHeader` or split; Go has one
  `ErrHeader`, std one `BadGzipHeader`), `WrongHeaderChecksum` (FHCRC, if
  verified per T3), `WrongChecksum` (CRC32), `WrongSize` (ISIZE), `Truncated`;
  zlib — `BadHeader` (CM/CINFO/FCHECK), `DictionaryRequired` (OQ4),
  `WrongChecksum`, `Truncated`. Keep CRC32-mismatch and ISIZE-mismatch as
  separate errors (Go collapses both into `ErrChecksum` at `gunzip.go:267`,
  losing which half failed; std declares both separately).
- **OQ6 — buffer types and header scratch.** The containers are framing: the
  real memory is flate's `Reader.Buffer` (64 KiB) and `Writer.Buffer`
  (98,303 bytes), and the container takes those pointers and hands them to
  its internal flate `Reader`/`Writer`. The container's own needs: a gzip
  reader header scratch — 10 fixed bytes plus the optional fields, bounded:
  the extra field may declare up to 65,535 bytes (u16 XLEN) and must be
  hashed streaming from the input buffer, never staged; a name/comment
  length cap is a house rule (Go: 512 bytes, `gunzip.go:145`, T7); zlib
  needs 6 bytes. A gzip/zlib writer under OQ1(b) needs nothing beyond the
  flate buffer and a few stack bytes (header at `init`, trailer at
  `finish`); under OQ1(a) it needs an embedded-writer buffer — the one case
  that forces a container `Buffer` type. *Recommendation:* pure framing, no
  container buffer types unless OQ1 lands on the container-writer front.
- **OQ7 — emitted header fields (the deterministic-header policy).** The
  compliance section lets a compressor default everything: "255 for OS, 0
  for all others" (`rfc1952-gzip.txt §2.3.1.2`), and Go's writer does exactly
  that — `OS: 255`, MTIME only when set, XFL 2/4/0 by level band, FTEXT
  never, no optional fields (`gzip.go:76,163-167`); libdeflate the same
  (`FLG=0`, MTIME 0, XFL by band, OS 255). Deterministic output (no clock,
  no locale) is the reproducibility requirement Go's own tree enforces for
  Debian (`src/compress/gzip/issue14937_test.go`: every `.gz` in the tree
  must have MTIME 0). *Recommendation:* gzip — FLG=0, MTIME=0, XFL by level
  band (2 for max-compression levels, 4 for the fast/stored levels, 0 else),
  OS=255 (T1); zlib — CINFO=7, CM=8, FLEVEL by level band, FDICT=0, FCHECK
  minimal (`(31 - r) % 31`, accepting that the references' naive form
  differs only in the T5 corner, which is legal either way).

## 5. Fixture inventory

### 5.1 golang/go `src/compress/gzip/` (BSD-3-Clause)

- **`gunzip_test.go` — `gunzipTests` (15 vectors): the primary gzip
  conformance table.** Valid members: empty with FNAME, empty with no name,
  "hello.txt" with FNAME, **the concatenation vector ("hello.txt x2" — two
  complete members in one input)**, a fixed-Huffman member with
  length-distance pairs, and the Gettysburg dynamic-Huffman member (1.5 KB
  payload). Corrupt/truncated members with pinned errors: trailing garbage
  → `ErrHeader`; a truncated second-member header → `io.ErrUnexpectedEOF`;
  corrupt CRC32 → `ErrChecksum`; corrupt ISIZE → `ErrChecksum`; **the
  all-fields header** (FLG=0x1e: FHCRC+FEXTRA+FNAME+FCOMMENT, an 'zz'
  subfield, a 256-byte comment, FHCRC=0xfd92 — verified against the CRC
  arithmetic in §3.1); truncation amid a raw block, amid a fixed block, and
  inside truncated name/comment headers → `io.ErrUnexpectedEOF`.
- `TestTruncatedStreams` (4 vectors, the newer table), `TestIssue6550`
  (testdata/issue6550.gz.base64, 85.3 KB — the decompression-hang
  regression, must fail closed without hanging), `TestMultistreamFalse` (the
  per-member Reset semantics), `TestNilStream` (the zero-member reading,
  T2).
- **`gzip_test.go` (writer tests):** `TestEmpty` (an empty payload is a valid
  member; the readback Header is `Header{OS: 255}` — the emitted-header
  policy pinned), `TestRoundTrip` (comment/extra/mtime/name round-trip),
  `TestLatin1RoundTrip` (names: ASCII and Latin-1 pass, NUL and non-Latin-1
  fail — the GE4 surface), `TestWriterFlush`. As encoder goldens these do
  not port byte-for-byte (deflate mandates no canonical form, the flate
  rationale); as round-trip and policy fixtures they do.
- `issue14937_test.go`: every `.gz` in the Go tree has MTIME 0 — the
  reproducibility constraint behind OQ7.
- `example_test.go`, `fuzz_test.go` (seed corpus).

### 5.2 golang/go `src/compress/zlib/` (BSD-3-Clause)

- **`reader_test.go` — `zlibTests` (11 vectors): the primary zlib conformance
  table**, its own comment: "Compare-to-golden test data was generated by
  the ZLIB example program at https://www.zlib.net/zpipe.c" — golden bytes
  from the C reference itself. Vectors: truncated empty / truncated dict /
  truncated checksum → `io.ErrUnexpectedEOF`; the empty stream
  (`78 9c 03 00 00 00 00 01`); "goodbye, world"; bad CINFO (`88 98`) →
  `ErrHeader`; **bad FCHECK (`78 9f`) → `ErrHeader`**; bad checksum →
  `ErrChecksum`; not-enough-data → `io.ErrUnexpectedEOF`; **excess data
  silently ignored** (trailing bytes past ADLER32 — ZD7's boundary); the
  **dictionary** vector (`78 bb` + DICTID + a dict-compressed body);
  **wrong dictionary** → `ErrDictionary`.
- `writer_test.go`: round-trip and level tests (the writer's FLEVEL/FCHECK
  arithmetic exercised through readback); no testdata directory.

### 5.3 klauspost/compress `gzip/`, `zlib/` (BSD-3-Clause, local checkout)

The containers are the Go stdlib code over the klauspost flate engine —
diff-verified (only the `compress/flate` import and `ConstantCompression`
differ), so the golden tables above are also klauspost's. Extra:
`gzip/testdata/issue6550.gz` (the raw 64 KB binary of the hang regression)
and `gzip/testdata/test.json` (145.7 KB of real-world JSON, a corpus
candidate); `gunzip_test.go` (22.8 KB, a superset of the stdlib suite).

### 5.4 Zig 0.16 std in-tree (MIT)

`std/compress/flate/Decompress.zig`'s container tests are the nearest native
goldens and port with near-zero friction: gzip stored/fixed/dynamic
"Hello world\n" members with headers and footers, "gzip header with name"
(FNAME), the **FHCRC member** (`:1118-1126`, FLG=0x12, CRC16 `99 d6`),
zlib stored/fixed/dynamic members, **"zlib should not overshoot"** (the
exact-consumption case: 4 bytes after the trailer stay unconsumed), the
bad-CM / bad-CINFO / truncated-header / truncated-checksum failures, and
`testdata/fuzz/{bug_18966,end-of-stream}` inputs. MIT, in-tree under the
flake. Use as decoder goldens and as divergence pins for std's own
behavior (T4, T6 — std accepts inputs Go rejects: no FCHECK check, no
FHCRC verification, no trailer comparison).

### 5.5 The local oracle (verified by running) and the CLIs

CPython 3.14.7's `zlib` (which links the C reference) and `gzip`; every line
below was run here and round-tripped on a 225-byte buffer before being
written down:

```python
import zlib, gzip

data = b"The quick brown fox jumps over the lazy dog. " * 5

# zlib container (RFC 1950), both directions. wbits=15 is the zlib wrapper.
zw = zlib.compress(data, 6)                    # header 78 9c (FLEVEL 2), footer
assert zlib.decompress(zw) == data             # is the big-endian Adler-32
do = zlib.decompressobj(15)                    # streaming: exact boundary in
out = do.decompress(zw) + do.flush()            # do.unused_data (trailing bytes)
assert out == data

# gzip container (RFC 1952), both directions, via the C zlib wrapper:
gz = zlib.compressobj(6, zlib.DEFLATED, 16 + 15).compress(data) \
     + zlib.compressobj(6, zlib.DEFLATED, 16 + 15).flush()  # messy; prefer:
co = zlib.compressobj(6, zlib.DEFLATED, 31)     # 31 = 16+15: gzip header+trailer
gz = co.compress(data) + co.flush()             # emits OS=3, MTIME=0, XFL=0
assert zlib.decompress(gz, 31) == data         # one-shot decode
do = zlib.decompressobj(31)                     # single member only: the second
out = do.decompress(gz*2) + do.flush()          # member lands in do.unused_data

# autodetect (32+15): zlib or gzip from the first bytes
assert zlib.decompress(zw, 47) == data and zlib.decompress(gz, 47) == data

# CPython's own gzip module (OS=255, multi-member, no FHCRC verification)
assert gzip.decompress(gzip.compress(data)) == data
assert gzip.decompress(gzip.compress(data) * 2) == data * 2   # multi-member

# FDICT: encode with a dictionary, decode with it (and the failure cases)
d = b"she sells seashells by the seashore\n"
co = zlib.compressobj(6, zlib.DEFLATED, 15, 9, zlib.Z_DEFAULT_STRATEGY, d)
zwd = co.compress(data) + co.flush()            # header 78 bb + BE adler32(d)
out = zlib.decompressobj(15, d).decompress(zwd) + zlib.decompressobj(15, d).flush()
assert out == data                              # wrong d / no d: errors
```

Verified emissions worth pinning in tests: `zlib.compress(data, 6)` →
`78 9c`; level bands → FLEVEL 0/1/2/3 for levels {0,1}/{2-5}/{6,-1}/{7-9}
(= Go's `writer.go:104-110` mapping); the dict+FLEVEL0 corner → `78 3f`
(FCHECK=31, T5); `compressobj(·, DEFLATED, 31)` → OS=3, XFL 2/4/0 for
levels 9/{0,1}/other; `gzip.compress` → OS=255. CLIs: `gzip`/`gunzip` 1.14
on PATH (verified emissions in §2.5 T1 and OQ7); no `zlib-flate` binary on
PATH (checked — `command -v` fails). Conformance lanes run both directions
over the committed corpus at levels {0, -2, 1, 6, 9} (the flate-notes §4.3
precedent) with the gzip CLI joining as the reference decompressor.

## 6. Competitor inventory

The plan pins the family set: klauspost/compress and std always, plus the
strongest native library on each box — libdeflate and zlib-ng for the flate
family (`docs/zcompress-plan.md`, "Benchmark methodology"). What each one's
container numbers will mean, and what each does around the flate core:

### 6.1 klauspost/compress gzip/zlib (BSD-3-Clause) — the class target

The Go stdlib containers over the klauspost flate engine (diff-verified):
lazy headers (first Write/Flush/Close), Go's deterministic defaults (OS=255,
MTIME=0, no optional fields), hash-on-the-write-path (`gzip/gzip.go:229`,
`zlib/writer.go:161`), trailer verified at end-of-read (`gunzip.go:267`),
FHCRC verified (`gunzip.go:231`), multistream by default with
`Multistream(false)` for the per-member boundary. Checksum machinery: Go's
`hash/crc32` with `crc32.IEEETable` — the scalar bytewise table, one lookup
per byte, no folding, no hardware path (the Castagnoli table has one; IEEE
does not) — and `hash/adler32`, likewise scalar with the deferred modulo.
Numbers mean: the container overhead of the speed-class Go engine; its
scalar checksums are the known gap our slice-by-8/folding kernels attack.

### 6.2 std.compress (Zig 0.16, MIT) — the in-tree baseline

No `std.compress.gzip` or `std.compress.zlib` module exists
(`std/compress/` ships flate, zstd, lzma, lzma2, xz only — verified); the
container machinery lives *inside* flate as `flate.Container`
(`std/compress/flate/flate.zig:60-175`): an enum with `header()` (a fixed
10-byte gzip header with OS=3, MTIME=0, no optional fields; a fixed
`78 9c` zlib header), `Hasher` (`std.hash.Crc32` + a u32 count for gzip,
`std.hash.Adler32` for zlib), `writeFooter` (LE crc+count for gzip, BE
adler for zlib), and `Metadata`. The fleet row at M3 is
`flate.Compress`/`flate.Decompress` with `container = .gzip`/`.zlib`.
Divergences to record against, not copy: no trailer verification (T4 —
the footer lands in `container_metadata`, unchecked), no FCHECK check and
no FDICT handling (T6), FHCRC discarded unchecked (T3), no reserved-bit
check, single member with no concatenation expected (`Compress.zig:1873`).
Checksums: `std.hash.crc.Crc32` (scalar bytewise, comptime table) and
`std.hash.Adler32` (the 5552 deferred-mod, 16-byte comptime unroll). The
M2 README's decision — our flate stays raw-only, the containers wrap from
outside — is why this design is a competitor datapoint and not our shape.

### 6.3 ebiggers/libdeflate (MIT) — the strongest native container

Whole-buffer API, no streaming; `lib/gzip_compress.c` / `lib/gzip_decompress.c`
/ the zlib pair wrap `libdeflate_deflate_*`. Compression: fixed minimal
header — FLG=0, MTIME=`GZIP_MTIME_UNAVAILABLE`, XFL 4 (level < 2) / 2
(level ≥ 8) / 0, OS=`GZIP_OS_UNKNOWN` — then the body, then LE CRC32+ISIZE,
computed from the input buffer in one call. Decompression: ID1/ID2/CM
checked, **reserved bits rejected** (`if (flg & GZIP_FRESERVED) return
LIBDEFLATE_BAD_DATA` — the RFC's MUST, enforced), optional fields skipped
with bounds checks, FHCRC skipped unchecked, **trailer verified (CRC32 and
ISIZE)**, single member with the boundary reported (`actual_in_nbytes_ret`)
so concatenation composes in the caller. Checksum machinery:
`lib/crc32.c` — slice-by-8 default (8 interleaved 256-entry tables), runtime
dispatch to PCLMUL folding on x86 and CRC32 instructions on ARM
(`crc32_multipliers.h`, `x86/crc32_impl.h`, `arm/crc32_impl.h`), the
pre/post-conditioning inside `libdeflate_crc32`; `lib/adler32.c` with the
same dispatch pattern. Numbers mean: the native whole-buffer ceiling per
box; its folding CRC-32 is the throughput target band for our kernel (the
reason the plan's PCLMULQDQ decision exists).

### 6.4 zlib-ng (zlib license) — the streaming-API native ceiling

zlib API-compatible; the zlib-format header is written in `deflate.c` with
the same CMF/CINFO/FLEVEL/FCHECK arithmetic as zlib; the gzip file layer is
`gzlib.c`/`gzread.c`/`gzwrite.c` with `OS_CODE` from `zutil.h` — 3 default
(Unix), 10 on Win32, **19 on Apple** (T1's out-of-table value).
`crc32.c`: the interleaved table method ("This interleaved implementation
of a CRC makes use of pipelined multiple arithmetic-logic units... due to
Kadatch and Jenkins (2010)", the file's header) plus runtime-dispatched
arch kernels — `arch/x86/crc32_pclmulqdq_tpl.h` (PCLMUL folding) and the
vpclmulqdq AVX2/AVX512 variants, `arch/arm/crc32_armv8.c` (CRC32
instructions) and the PMULL/EOR3 variant, `arch/s390/crc32_vx.c`,
`arch/power/crc32_power8.c`, `arch/riscv/crc32_zbc.c`, and the newer
"chorba" methods (`arch/generic/crc32_chorba_c.c`, x86 SSE2/SSE4.1) —
selected by `x86_features.c`/`arm_features.c` CPU detection. Adler-32:
`adler32.c` + `arch/x86/adler32_{avx2,avx2_vnni,avx512,avx512_vnni,sse42,
ssse3}.c`, `arch/arm/adler32_neon{,_dotprod}.c`, RVV, VMX/VSX, MSA, LASX.
Numbers mean: the fastest zlib-format streaming implementation per box,
with the strongest hand-tuned checksum kernels — the fleet's native
reference for both containers.

### 6.5 madler/zlib (zlib license) — the emission rules

Read through the oracle, not the source: the FLEVEL band mapping
({0,1}→0, {2-5}→1, {6,-1}→2, {7-9}→3, verified), the XFL rule (2 at level
9, 4 below level 2 or with the huffman-only strategy, 0 else, verified),
the FCHECK naive form (T5, `78 3f` verified), OS=3, and the gzip wrapper's
fixed MTIME=0. The classic behavior every other implementation inherited.

## 7. Ranked ambiguities — the ones most likely to bite

1. **The OS byte (T1).** `rfc1952-gzip.txt §2.3.1`'s table ends at 13+255 and
   the references emit all of {3, 10, 19, 255} — zlib-ng's 19 is not in the
   table at all, and the compliance text explicitly frees the field to 255.
   Nothing here breaks a decoder (any byte is legal input), so the trap is
   purely on the emit side: a test that pins our OS byte to the table, or a
   reader that validates OS against the table, rejects real files. Pin the
   emitted value in a test (OQ7: 255), accept any byte on decode.
2. **Trailing bytes and member cardinality (T2 + OQ3).** "A series of
   members" with nothing after them — the RFC never says one-or-more vs
   zero-or-more, and the references land on four different behaviors for
   the same inputs (Go ErrHeader / CLI warning+exit-2 / CPython error /
   libdeflate boundary-reported). Our exact-consumption reader forces an
   explicit choice at the very first test that appends a byte after a
   member; decide before the sketch, pin with Go's "+ garbage" and "x2"
   goldens.
3. **FHCRC verification (T3) and the trailer-check asymmetry (T4).** The
   compliance text only requires *skipping* the optional fields; Go
   verifies the CRC16, CPython and libdeflate do not, std discards it
   unchecked — and on the trailer, RFC 1952 makes the checksum check
   optional while RFC 1950 makes it a MUST, yet std checks neither. Both
   calls are ours to make (recommendation: verify everything — FHCRC,
   CRC32/ISIZE, ADLER32 — the cost is small and the house posture is
   fail-closed); the conformance table must pin each deliberately.
4. **The zlib byte-order family (§1.2) and the FCHECK corner (T5).** One
   wrapper, three byte orders: zlib's header arithmetic and trailer are
   big-endian, gzip's fields are little-endian, and the deflate LEN/NLEN
   under both are little-endian. The FCHECK check must be `h % 31 == 0`,
   never re-derivation — the references emit FCHECK=31 in the FLEVEL0+FDICT
   corner (`78 3f`), which a re-deriving validator rejects. Both are the
   wire-bug family for the container slice; the §5.2 golden table catches
   the first, the T5 fact catches the second.
5. **Header caps on hostile input (T7).** The RFCs bound nothing: a
   zero-alloc reader meets a 65,535-byte extra field and unbounded
   NUL-terminated strings. Go caps name/comment at 512 bytes as a house
   rule; libdeflate bounds each field against the declared input length.
   The amplification story (a tiny member declaring a giant header must
   fail closed, never allocate) is the fuzz lane's first target; the caps
   are a parent decision at the sketch.

The three design questions most likely to bite the container implementation
(§4's OQs, ranked): **OQ1** — where the container hashes, which decides
whether flate gains an optional checksum field (the only zero-copy,
all-paths-covered option) or the containers carry their own buffers and
extra copies; **OQ2/OQ3** — the surface shape and member boundary, which
decide the one-shot decode's trailer location and the reader's
trailing-byte policy; **OQ4/OQ5** — the FDICT surface and the error-set
composition, which decide what "conformant" means for the golden tables
that pin the whole module.
