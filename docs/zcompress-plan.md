# zcompress plan

## Mission

zcompress gives Zig fast compression codecs. The performance class is
klauspost/compress. The usability class is std.compress. Every codec is a
self-contained directory that builds alone, with the shared `src/internal/`
layer in tow. Every performance claim is measured, and every number names its
evidence.

Pure Zig: SIMD work uses `@Vector`, `@shuffle`, `@select`, and `std.simd`.
Memory copies go through fastmem, the same-author fast memcpy/memmove/memset
library. Assembly appears only when Zig cannot express an instruction, only in
a thin feature-gated kernel with a generic fallback, and only after
disassembly proves the Zig route loses.

Non-goals until the core codec set ships: archiving formats (zip, tar),
parallel codecs (pgzip-style), dictionary training, s2 extensions, xz/lzma
(std.compress already ships those).

## Facts that the plan uses

- Zig 0.16.0 is the only toolchain. The flake pins it. Zig 0.17.0 (released
  2026-10-02) ships LLVM 22.1.8 with the loop vectorization pass disabled, a
  workaround for an LLVM 22 miscompilation (LLVM issue 186922; the pass returns
  in 0.18 with LLVM 23). `std.simd` in 0.17.0 is the 0.16.0 file modulo
  cosmetic changes. 0.16 keeps the auto-vectorizer and the std.simd toolbox
  (`interlace`, `deinterlace`, `extract`, `mergeShift`, `prefixScan`,
  `suggestVectorLengthForCpu`).
- std.compress 0.16 ships flate (Compress/Decompress), zstd, lzma, lzma2, and
  xz. It ships no snappy, lzw, gzip, or zlib container. Those are ours.
- klauspost/compress covers zstd, s2, flate (with gzip/zlib/zip containers),
  snappy, lzw, huff0, fse, and xpress. License: BSD-3-Clause.
- golang/snappy is BSD-3-Clause. Its test tables are the snappy golden
  vectors, including an exhaustive `length x offset x suffixLen` sweep.
- The raw-block snappy codec is finished: a port of klauspost's
  `encodeBlockSnappyGo64K` encoder, an original SIMD decoder, and the
  golang/snappy golden vectors (attribution in THIRD_PARTY.md).
- fastmem (same author, MIT) is the blessed copy primitive. Its inline layer
  has no loops, and large sizes call its own `no_builtin` kernels, so
  consumer-side inlining cannot idiom-match back into a `memcpy` call.
- Zig 0.16 removed run-time indexing of `@Vector` values, and `@splat` is
  single-argument. `std.Io` is the reader/writer interface; `main` takes
  `std.process.Init`.
- Zig 0.16 fuzz mode takes an iteration budget (`--fuzz=10M`). Debug fuzz hits
  ziglang/zig#30655, so fuzz runs use ReleaseSafe.

## Scope and build order

Codecs, one at a time, each shippable alone:

1. snappy — raw-block codec. (M0, M1)
2. flate — fast encoder plus full inflate. The core value. (M2)
3. gzip + zlib — containers over flate, plus checksum kernels. (M3)
4. zstd — decoder first, then the fast encoder. (M4, M5)
5. lzw — both directions, the Go stdlib formats. (M6)

Order rationale: snappy is nearly free and calibrates the whole measurement
pipeline. flate is the biggest standalone win and unblocks two containers.
zstd is the largest surface, so it splits decoder-first. lzw is the smallest
value and the smallest effort, so it goes last.

## Architecture

### Modules

One directory per codec under `src/`, and ONE build module for the whole
library: `zcompress`, rooted at `src/root.zig` (owner's call, 2026-10-09).
The barrel re-exports each codec directory as a namespace
(`zcompress.snappy`, `zcompress.flate`), so the consumer surface is
`zcompress.<codec>.<name>` and there is no module graph to keep in sync.
Codecs import only `std` and `fastmem`, plus in-repo relative imports: a
container imports the codec it wraps (gzip/zlib over flate, M3) by relative
path.

A shared `src/internal/` layer may hold codec-agnostic primitives (history
windows, match-finder skeletons, checksum kernels, huffman tables). Rules: it
imports only `std` and `fastmem`; it holds no codec-specific state; a codec
that uses it lifts with `internal/` in tow. Nothing lands there before two
codecs need it.

The lift story: a codec directory plus `src/internal/`, under one module
root — a two-line barrel file, exactly what `src/root.zig` is — build and
test alone against the fastmem dependency, importing each other relatively,
with no build-graph surgery. The root file must be an ancestor of both
directories: relative imports cannot escape the module root's directory.

### API layers

Each codec exposes two layers, built in this order:

1. Block functions: pure functions over caller-owned buffers. Zero heap
   allocation. A worst-case sizing helper bounds the output buffer. (snappy:
   `compressBlock`, `decompressBlock`, `maxCompressedLength`,
   `decompressedBlockLen`, `max_block_size`.)
2. Streaming, where the format has framing: `std.Io`-native, in-package — a
   compressing `Io.Writer` and a decompressing `Io.Reader` over the codec's
   canonical stream format (snappy: `snappy.Writer`/`snappy.Reader` over the
   `u32-le compressed length + raw block` framing; the `std.compress.flate`
   `Compress`/`Decompress` pair is the in-tree precedent for the shape).
   The caller provides every buffer through exported named buffer types
   (`snappy.WriterBuffer`, `snappy.ReaderBuffer`); scratch is comptime-sized
   stack, so the whole path allocates nothing.

An API sketch gets Matt's review before implementation. APIs are felt, not
just specified.

### Memory and ownership

- Zero heap allocation on codec hot paths. Tables and windows live on the
  stack or in caller-provided buffers.
- Setup-time allocation (encoder state, huffman tables, dictionaries) takes
  a caller-provided allocator, or an arena the state machine owns for its
  lifetime. Ownership is documented at each API.
- Decode output buffers are exact-sized. Tests prove that no byte past the
  decoded length is written (sentinel overrun checks).

### SIMD

- Vector width is comptime, from `std.simd.suggestVectorLengthForCpu` per
  build target.
- Per-model comptime selection lands when fleet data shows divergence
  (fastmem's `tuning.zig` pattern).
- Runtime dispatch is deferred until a baseline-compatible binary is needed.
- Known-good shapes to reuse: comptime shuffle masks for overlapping copies
  (`tbl`/`pshufb`), u64 XOR plus `@ctz` match extension (`eor`/`rbit`/`clz`
  on aarch64), padded pattern loads before the last vector so the tail cannot
  overread.

## The codec development loop

Every codec runs the same loop, one at a time:

1. Research (spec-researcher): vendor the spec into `docs/research/specs/`,
   record provenance, extract the requirements matrix, list fixture sources.
   No code.
2. API sketch (parent): the public surface, error sets, buffer ownership,
   `std.Io` integration. The sketch lands as the module's `README.md`,
   written before any implementation. Matt reviews it before code exists.
3. Data structures: windows, finders, tables. A shared candidate goes to
   `internal/` only when a second codec needs it.
4. Implementation (slice-worker) under an explicit acceptance contract.
5. Correctness (fuzz-engineer, conformance-planner): golden vectors with
   spec-section citations, sentinel overrun checks, conformance lanes, fuzz
   targets.
6. Performance (perf-engineer): disassembly first, vector kernels, per-model
   selection when the fleet demands it.
7. Numbers (benchmark-methodologist + fleet-watcher): fleet runs, confidence
   intervals, results committed under `docs/results/`.

A lane's review runs at the same time as its correctness gate. Only the merge
waits for both.

## Correctness methodology

- Golden vectors from the reference suites, committed as fixtures. Every
  format test cites the spec file and section it validates:
  `// RFC 1951 §3.2.5 — fixed Huffman`.
- Sentinel overrun checks on every decode: the output is pre-filled with
  cycling sentinels, and every byte past the decoded length must survive.
- Conformance lanes: round-trip through reference CLIs (gzip, zstd, snappy)
  on the committed corpus, in both directions.
- Amplification limits are tests, not comments: a corrupt length prefix must
  fail closed, and a decode must never write past its declared output.
- Fuzz: round-trip and differential targets, `--fuzz=<budget>` iterations,
  ReleaseSafe only (ziglang/zig#30655).

## Benchmark methodology

- Iteration is local-first (Matt, 2026-10-08): remote machines slow the
  iteration cycle, so the fleet is on demand, not the default feedback loop.
  Local `just bench` (zig-benchmark, benchstat-friendly `--count=N`) drives
  development. Local numbers are never quoted as claims.
- Claims: the fleet harness, ported from fastmem at M1. Seven EC2 targets
  (c7i, c8i, c7a, c8a, c7g, c8g, c9g), n>=5 rounds, exact confidence
  intervals, outlier rounds reported and never removed.
- Every claim names its run directory and a results file under
  `docs/results/`. No number without provenance.
- Competitors per codec: klauspost/compress (Go) and std.compress (Zig)
  always, plus the strongest native library on the box (libdeflate/zlib-ng
  for the flate family, zstd C for zstd, google/snappy C++ for snappy).
- Corpus: committed, fixed, hashed. The same bytes for every implementation.
  Throughput is measured over uncompressed bytes.

## Licensing

zcompress is MIT. klauspost/compress, golang/snappy, and the Go stdlib are
BSD-3-Clause: reading is unrestricted, ports are permitted with attribution
in THIRD_PARTY.md. The posture stays the same anyway: reimplement from the
spec and the algorithm description where practical. When code is ported, keep
the upstream notice in the file header and name the upstream file and commit
in THIRD_PARTY.md.

## Agents and orchestration

The parent stays the orchestrator. Work dispatches to the roster in
`.pi/agents/`. Model pins live in the roster and come from the model guide;
they are never copied from another repo's roster.

Roster: slice-worker, implementation-reviewer, spec-researcher,
conformance-planner, fuzz-engineer, perf-engineer, benchmark-methodologist,
fleet-watcher, evidence-auditor, footgun-reviewer, matt-nits. herald joins
when there is a public surface to voice.

Decode of untrusted input is the security surface. It belongs to
fuzz-engineer (amplification and corruption targets) and conformance-planner
(reference-suite lanes), not to a separate security roster.

A fleet run gets a watcher: a delegate agent runs `bench watch <run-dir>` and
exits when `summary.json` exists. The parent never polls.

## Milestones

M0 — scaffold. Repo skeleton, build, Justfile, lint config, vendored specs,
the agent roster, snappy lifted and green under 0.16 with fastmem wired in.
Acceptance: `zig build test` and `just lint` pass on the host, `just bench`
runs, and the commit exists.

M1 — snappy API review. The module `README.md` documents the public surface;
Matt reviews it (README-first). Acceptance: the README merged, the API settled.
The fleet baseline against golang/snappy, google/snappy C++, and klauspost s2
(snappy-compat mode) runs on demand, before the first public performance
claim, and lands under `docs/results/` with its run directory cited.

M2 — flate. Fast encoder (klauspost level-1 class) plus full inflate. Golden
vectors from the Go flate suite; conformance via the gzip CLI; fuzz targets
for the huffman and match machinery.
Acceptance: conformance lanes green; a fleet run against klauspost,
libdeflate, zlib-ng, and std.compress.flate, committed with confidence
intervals.

M3 — gzip + zlib. Containers over flate; crc32 and adler32 kernels; the
PCLMULQDQ decision (study `std.crypto.ghash_polyval` first; no inline asm
before a vector route is proven slower). `GzipWriter`/`GzipReader` over
`std.Io`.
Acceptance: gzip and zlib conformance green; a fleet run committed. The
conformance half is green (`just gzip-oracle`, `just zlib-oracle`, and
`just flate-oracle`); the fleet run is outstanding — `docs/results/` does
not exist yet, and the fleet wave owns committing the run against the
pinned competitors. M3 is not called shipped against the plan text until
that run lands.

M4 — zstd decoder. huff0, fse, block, and frame layers. A decode-side fleet
run against zstd C, klauspost, and std.compress.zstd.
Acceptance: zstd CLI conformance green; amplification-limit tests green; a
fleet run committed.

M5 — zstd encoder, fast level. M6 — lzw (the TIFF 6.0 and PDF 32000
variants; vendor those spec sections at M6).

## Decisions made

- Zig 0.16.0 only (2026-10-08). Revisit at 0.18: LLVM 23 restores loop
  vectorization.
- Codec order as in Scope.
- fastmem is a direct dependency and the blessed copy primitive on codec hot
  paths (2026-10-08).
- Block functions before streaming cores before `std.Io` adapters.
- Zero allocation on codec hot paths; an arena for setup.
- The fleet harness ports from fastmem at M1.
- API sketches get Matt's review before implementation; each module's
  README is written first and is the API sketch (2026-10-08).
- Local-first iteration: the fleet runs on demand, not as the default loop
  (2026-10-08).
- No `@memcpy`/`@memmove`/`@memset` anywhere in this repo's source —
  `fastmem.copy`/`move`/`set` only (2026-10-08).
- One `zcompress` build module, codecs as namespaces under it, `src/internal/`
  reached by relative import (2026-10-09, owner's call). The retired wiring
  was one build module per codec plus a private `internal` module.

## Decisions deferred

- Runtime dispatch (baseline+avx2 single binary) versus per-model builds:
  M1 fleet data decides.
- crc32 via PCLMULQDQ inline asm versus folded-vector arithmetic: M3, after
  the ghash_polyval study.
- s2 extensions: after M6, only if wanted.
- Shared `internal/` primitives: the first candidate lands when flate needs a
  second user of a snappy shape.
- flate dynamic-Huffman ratio mode (OQ1): after the fast path wins —
  `Level.ratio` reserves the seat with `error.Unimplemented`, never silent
  aliasing.
- flate preset dictionaries (OQ6): deferred; the decoder surface does not
  preclude a dictionary entry point later.
