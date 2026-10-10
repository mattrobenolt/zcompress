# zcompress bench: the fleet harness

The claim-maker. Local `just bench` numbers iterate; numbers that close a
milestone come from a fleet run through this harness, and every claim names
its run directory under `docs/results/` (docs/zcompress-plan.md, "Benchmark
methodology").

The harness ports fastmem's (`~/code/fastmem-zig/bench/`, design:
`docs/bench-design.md` there): `ec2bench/` is the generic EC2 fleet core,
copied verbatim; `zcompress_bench/` is the zcompress adapter — the suite,
the cross builds, the schema, the analysis.

## Arms

A run measures **arms**, one binary each, interleaved per round through a
seeded balanced Latin square under CPU isolation (the last physical core,
via systemd; `ec2bench/isolation.py`):

| Arm | Binary | Rows | Build |
|---|---|---|---|
| `zc` | `zig build fleet-bench` (bench/zig/bench_zcompress.zig) | zcompress one-shots (flate/gzip/zlib level `.fast`, snappy block), both directions, **plus the `std` rows**: std.compress.flate raw/gzip/zlib at `level_1` | cross per target: `-Dtarget=<arch>-linux-musl -Dcpu=<model>`, ReleaseFast, static |
| `klauspost` | bench/drivers/klauspost (Go) | klauspost/compress flate/gzip/zlib level 1 + snappy, both directions | `go build`, GOOS=linux per arch; module pins v1.18.1-0.20250402062133-8df4d013ff17 (the research's local checkout commit) |
| `libdeflate` | bench/drivers/c/bench_libdeflate.c | libdeflate v1.26 gzip/zlib/deflate one-shots, level 1 | `zig cc -static` per target/CPU from the pinned tarball (sha256 in build.py) |
| `zlibng` | bench/drivers/c/bench_zlibng.c | zlib-ng 2.3.3 streaming (zlib-compat API, windowBits -15/15/31), level 1 | cmake (ZLIB_COMPAT, static) with a zig-cc wrapper, per target/CPU |
| `googlesnappy` | bench/drivers/google-snappy/bench_snappy.cc | google/snappy 1.3.1 raw blocks (`snappy::RawCompress`/`RawUncompress`), both directions | cmake (static `snappy`) with zig-cc/zig-c++ wrappers, per target/CPU from the pinned tarball (sha256 in build.py) |
| `aa` | the `zc` binary again | the A/A noise floor | — |

Snappy competitor coverage: klauspost plus google/snappy C++ (the plan's
pinned canonical implementation, `docs/zcompress-plan.md`, "Benchmark
methodology"), both over raw blocks. The M3 run carried klauspost only —
the results file records that gap — and the google/snappy rows ride the M4
fleet run.

## Corpus

`bench/corpus/` is committed, fixed, and hashed (`SHA256SUMS`). Shapes and
sizes mirror the codec bench files (src/flate/bench.zig): text, random,
html, rle, mixed at 32 KiB and 64 KiB. The generator is
bench/zig/corpus.zig (`zig build corpus`); it is deterministic and rewrites
only changed bytes. Next to each raw file sit the **reference blobs**
(`.flate`, `.gz`, `.zz`, `.snappy`), produced by the zcompress encoders:
every arm's decompression rows decode these identical bytes. Each driver's
meta record carries the SHA-256 of every raw file it read; the parser
rejects a round whose hashes disagree with the committed corpus.

## Schema v1 (the JSONL contract)

One file per (arm, round): a `meta` record (arm, tool, rev, toolchain,
target, cpu, optimize, suite, seed, samples, sample_ms, impls, corpus
hashes), one `sample` record per (case, impl, sample) — case is
`<codec>/<direction>/<shape>/<size>`, plus iters, ns, out_len — and an `end`
record. `zcompress_bench/jsonl.py` is the strict contract; every fleet
driver (Zig, Go, C, C++) emits it.

## Analysis

The estimator core ports verbatim from fastmem: per-cell round medians,
two-sample Hodges-Lehmann + exact Mann-Whitney intervals across arms (and
A/A), one-sample Hodges-Lehmann + exact Wilcoxon signed-rank intervals for
rows sharing a process, outlier rounds flagged and never removed,
significance gated on ≥5 rounds and the A/A noise floor. Comparisons:

- `A/A` — aa vs zc: the noise floor.
- `<arm>/zc` — a competitor arm against zc (two-sample, cross-binary).
- `zc/std` — zc against the in-binary std rows (paired).
- `container/flate` — each gzip/zlib row against the flate row of the SAME
  implementation in the SAME processes: the honest container-overhead
  reference. Cross-binary code-layout interference inflates cross-binary
  comparisons on latency-bound shapes; the paired row is the reference for
  the container story.

`sizes` rows record the median compressed length per cell: the ratio half
of the story.

## Credentials and infrastructure

The fleet shares fastmem's: profile `fastmem-bench`, the same launch
templates and reaper, `tofu_dir` pointing (read-only — the harness only
runs `tofu output`) at `~/code/fastmem-zig/infra/base`. The IAM policy pins
`Project=fastmem-bench`, so `project.name` in `bench.toml` stays
`fastmem-bench` and both repos' boxes appear in either's `bench ls` —
check before running concurrently with a fastmem run. A dedicated
`zcompress-bench` stack needs the human bootstrap in fastmem's
`infra/README.md` ("Copy into another project"), which needs the
`playground-ops` SSO profile.

## Commands

```sh
just bench-up                 # launch the seven targets (2h TTL default)
just bench-ls                 # show the fleet
just bench-test               # correctness gate: every arm's --check on every box
just bench-run --rounds 5 --label m3   # the measurement
just b analyze <run-dir>      # re-analyze a run without AWS/SSH/builds
just bench watch <run-dir>    # via `just b watch`: exit when summary.json exists
just bench-down               # terminate the fleet
just bench-check              # ruff + ty over the harness
```

A run directory (`bench-results/<run-id>/`) holds the manifest (seed,
schedule, corpus hashes, competitor pins, build cache keys and binary
SHA-256s, git provenance), per-target raw rounds and host facts, the
summary.json, and report.md. The committed claim lives under
`docs/results/<run-id>/`.

## Dropped in the port

fastmem's goals.py (the G1-G6 gates), stability.py (spike/process-share
tables), codegen.py/libc probes (fastmem kernel evidence), the dist/large
suites, and the runtime-dispatch machinery (zcompress has no dispatch yet).
The harness test suite (fastmem's bench/tests) is not ported; the adapter
is covered by a local end-to-end smoke (see the run notes) instead.
