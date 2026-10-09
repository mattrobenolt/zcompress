# zcompress: agent notes

zcompress gives Zig fast compression codecs. `README.md` is the user overview.
`docs/zcompress-plan.md` is the plan: mission, architecture, the codec
development loop, methodology, and milestones with acceptance criteria. Read
it before you change a kernel or make a performance claim.

## Layout

- `src/root.zig`: the umbrella module. One pub decl per codec.
- `src/snappy/`: raw-block snappy, with fastmem wired into its copy paths.
  `encode.zig` ports the klauspost encoder algorithm (THIRD_PARTY.md);
  `decode.zig` is original, with golden vectors in `golden.zig` (ported
  golang/snappy fixtures, shared by every layer's tests); `Writer.zig` +
  `Reader.zig` are the streaming `Io` layer (a compressing `Io.Writer` and a
  decompressing `Io.Reader` over the framed stream — see
  `src/snappy/README.md`, "Streaming"); `bench.zig` is the local benchmark;
  `fuzz.zig` ships fuzz targets; `common.zig` (LEB128 varint) is a shared
  helper. One-call pumps: `Writer.streamAll`, `Reader.streamAll`.
- `src/flate/`: raw deflate (RFC 1951). `encode.zig` ports the klauspost
  level-1 match-finder (THIRD_PARTY.md); `decode.zig` carries inflate, the
  bit reader, and the canonical Huffman-table construction shared by both
  sides; `Writer.zig` + `Reader.zig` are the streaming `Io` layer over raw
  deflate (BFINAL self-delimits; there is no in-package framing — see
  `src/flate/README.md`, "Streaming"); `golden.zig` shares the Go flate
  fixtures across every layer's tests; `bench.zig` is the local benchmark;
  `oracle.zig` is the external-oracle harness behind `just flate-oracle`.
  Fuzz targets land in `fuzz.zig` (fuzz-engineer lane).
- `docs/research/specs/`: vendored specs (RFC 1950/1951/1952, RFC 8878, the
  snappy format description) with provenance.
- `examples/`: one CLI per codec, thin streaming pumps (`encode`/`decode`)
  over a file or stdin on shared scaffolding (`examples/cli.zig`). The codec
  package owns the framing (snappy's: `src/snappy/README.md`, "Streaming").
- `docs/results/`: fleet results, one file per measurement (on demand).
- `.pi/agents/`: the roster. The parent orchestrates; agents own lanes.

## Toolchain

- Zig 0.16.0 from the flake. Read the zig skill before you write Zig here.
  0.15-era patterns are wrong in 0.16 in silent ways (`std.Io`, `main(init)`,
  run-time vector indexing). Run `zigdoc` to verify any std API before you
  use it.
- The flake is the environment. A missing tool goes in `flake.nix`; do not
  install it globally.

## Commands

- `just test`: unit tests for every codec, under the ztest plain-text runner.
  Must pass before a commit.
- `just fuzz [BUDGET]`: per-target fuzz over `--fuzz=<budget>` iterations
  (default 10M). ReleaseSafe only (Debug fuzz hits ziglang/zig#30655).
- `just lint`: ziglint over `.ziglint.zon` paths, `zig fmt --check` over
  `src/` and `build.zig`, and `uvx ruff`/`uvx ty` over `scripts/`. Run it
  before you call Zig work done.
- `just fmt`: apply `zig fmt` to `src/` and `build.zig`.
- `just check-baseline`: cross-target `zig build check` covering every
  portable target (freestanding targets excluded — the ztest runner needs an
  OS).
- `just flate-oracle`: external-oracle conformance for flate — `python3
  zlib` raw, both directions (catches bit-packing bugs invisible to a
  self-round-trip; the layer is `scripts/flate_oracle.py`).
- `just bench [ARGS]`: local benchmarks (zig-benchmark). Local numbers are
  never quoted as claims.
- `just example <codec> ...`: run a codec's example CLI (e.g. `just example
  snappy encode README.md > /tmp/out` runs `zig build example-snappy --
  encode README.md`).
- `just clean`: drop `zig-out/`, `.zig-cache/`, `zig-pkg/`.

## Dependencies

- fastmem (non-lazy): the only memory-copy primitive in this repo. Never
  write `@memcpy`, `@memmove`, or `@memset` in this repo's source — not on
  codec hot paths, not in tests, not in bench corpus builders. Use
  `fastmem.copy`, `fastmem.move`, `fastmem.set` (all `(comptime T, dest,
  ...)`). `copy` and `set` are non-overlapping only; `move` handles overlap.
  A stray `@memcpy` in a diff is a review blocker.
- benchmark, ztest (lazy): bench and test steps only, never imported by
  codecs. In `build.zig`, lazy deps must go through `b.lazyImport` /
  `b.lazyDependency`, never `b.dependency`.

## Tiger style

The snappy package is the reference application of Tiger Style (the
`tiger-style` skill — safety > performance > developer experience). Copy its
patterns into every codec:

- Centralize control flow in the parent; push pure logic down into helpers
  with primitive arguments. `decompressBlock` (46 lines) owns the tag
  dispatch; `decodeLiteral`/`decodeCopy`/`copyMatch` are the leaves.
  `encodeBlock`'s labeled scan cascade stays in the parent for the same
  reason — see Deviations.
- Byte-buffer pairs are named `source`/`target` (equal length, data-flow
  order: `compressBlock(source, target)`). `in`/`out` name `*Io.Reader` /
  `*Io.Writer` params. Units go last (`scratch_len`, `max_block_size`,
  `decoded_region_len`).
- State machines are enums, not bools: `Reader.State` is
  `streaming`/`done`/`failed` with the detailed error beside it.
- Assertions are useful, not ceremonial: caller-guaranteed preconditions
  (`assert(source.len >= input_margin)` — the gate above guarantees it) and
  postconditions (`assert(w.writer.end == 0)` after an emit). Hostile input
  gets error returns, never asserts.
- Zero dynamic allocation; comptime-sized stack scratch.
- Batching: whole blocks through the data plane; framing is the control
  plane.

Deviations, on purpose:

- No Tracy zones — no profiler dependency in this repo. Observability is
  the benchmark harness plus disassembly.
- The 70-line function limit is consciously overridden on `encodeBlock`'s
  scan cascade (154 lines): centralizing that labeled control flow in the
  parent is the Tiger rule that wins; its pure logic is already extracted
  (`hash6`, `load64`, `emitLiteral`, `emitCopy`).
- House lint is 100 columns (tighter than Tiger's 120).

## Rules

- Spec-first: a codec's work starts from `docs/research/specs/`. Every format
  test cites the spec file and section it validates:
  `// RFC 1951 §3.2.5 — fixed Huffman`.
- README-first: each codec directory carries its own `README.md` documenting
  the public API. Write it before the implementation — it is the API sketch
  Matt reviews. An API change updates the module README in the same commit.
- A codec imports only `std` and `fastmem`. No cross-codec imports; shared
  primitives go to `src/internal/` only when two codecs need them.
- Zero heap allocation on codec hot paths. Caller owns buffers; setup
  allocation is documented at the API. Streaming layers take no allocator at
  all: caller-provided buffers through exported named buffer types
  (`snappy.WriterBuffer`, `snappy.ReaderBuffer`), comptime-sized stack scratch
  — the whole path allocates nothing.
- Export named buffer-type constants for every caller-provided buffer
  (ztls pattern), and take exact pointers of them at `init`, not slices with
  asserts.
- A single `*Io.Reader`/`*Io.Writer` param is named `input`/`output` (the
  `std.compress.flate` precedent); `in`/`out` name reader/writer pairs.
- The umbrella barrel exposes exactly `{Reader, Writer, encode, decode}` —
  everything else composes through those namespaces
  (`snappy.encode.compressBlock`, `snappy.Reader.streamAll`,
  `snappy.Writer.Buffer`). No flat re-export menu at the root.
- CamelCase API names spell `Length` unabbreviated
  (`maxCompressedLength`, `decompressedBlockLength`); snake_case
  identifiers keep `len` (std's `.len` convention: `scratch_len`,
  `dots_len`).
- Style, per Matt's own edits (2026-10-09): hoist short aliases to the top of
  the file for anything used more than once (`const print = std.debug.print;`,
  `const mem = std.mem;`, `const Allocator = mem.Allocator;`);
  type-on-left with dot-init (`var rng: DefaultPrng = .init(seed);`); named
  enums with `std.meta.stringToEnum` over inline enum chains; a blank line
  between the std import/alias block and the fastmem import block; `in`/`out`
  param names for reader/writer pairs; `try` propagation over catch-and-print
  scaffolding.
- Decode never writes past the decoded length; sentinel overrun checks prove
  it in tests.
- A performance claim names a fleet run directory and a results file in
  `docs/results/`. A change that helps one target and hurts another needs a
  comptime per-model selection.
- Fuzz runs use ReleaseSafe (`-Doptimize=ReleaseSafe -Dfuzz --fuzz=<budget>`)
  with an iteration budget; Debug fuzz hits ziglang/zig#30655.
- Licensing: BSD-3 reference code (klauspost/compress, golang/snappy) is
  readable without restriction; ports carry attribution in THIRD_PARTY.md.
  Prefer reimplementation from the spec.

## Agents

Work dispatches to `.pi/agents/`. Model pins live in the roster and come
from the model guide; they are never copied from another repo's roster.

- A lane's review runs at the same time as its correctness gate. Only the
  merge waits for both.
- A fleet run gets a watcher: a delegate agent runs `bench watch <run-dir>`
  and exits when `summary.json` exists. The parent never polls.

## Git

- Never `git add -A` or `git add .`. Stage tracked changes with `git add -u`,
  and add a new file by its path after you read `git status --short`.
  Untracked files can hold secrets: core dumps (`*.core`) contain the whole
  process environment.
