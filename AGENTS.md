# zcompress: agent notes

zcompress gives Zig fast compression codecs. `README.md` is the user overview.
`docs/zcompress-plan.md` is the plan: mission, architecture, the codec
development loop, methodology, and milestones with acceptance criteria. Read
it before you change a kernel or make a performance claim.

## Layout

- `src/root.zig`: the umbrella module. One pub decl per codec.
- `src/snappy/`: raw-block snappy, the first codec, lifted from kafka-zig
  with fastmem wired into its copy paths. `encode.zig` ports the klauspost
  encoder algorithm (THIRD_PARTY.md); `decode.zig` is original, with golden
  vectors from golang/snappy; `bench.zig` is the local benchmark.
- `docs/research/specs/`: vendored specs (RFC 1950/1951/1952, RFC 8878, the
  snappy format description) with provenance.
- `docs/results/`: fleet results, one file per measurement (from M1).
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
  Must pass before a commit. `-Dfuzz` switches to the default runner for
  `--fuzz` runs.
- `just lint`: ziglint over the `.ziglint.zon` paths and `zig fmt --check`.
  Run it before you call Zig work done.
- `just bench`: local benchmarks (zig-benchmark). Local numbers are never
  quoted as claims.

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
  allocation is documented at the API.
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
