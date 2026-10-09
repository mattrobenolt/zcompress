# zcompress: fast compression codecs for Zig. docs/zcompress-plan.md is the
# plan: mission, architecture, methodology, milestones with acceptance criteria.

default: test

# Unit tests for every codec
test:
    zig build test

# Fuzz every codec's targets for an iteration budget (K/M/G suffix, e.g.
# `just fuzz 1M`). ReleaseSafe only: a Debug-mode fuzz run hits
# ziglang/zig#30655. The budget is per fuzz target.
fuzz LIMIT="10M":
    zig build test -Doptimize=ReleaseSafe -Dfuzz --fuzz={{ LIMIT }}

# Lint Zig + Python: ziglint + zig fmt over the .ziglint.zon paths,
# ruff + ty over the scripts (uv-managed tooling, no project files)
lint:
    ziglint
    zig fmt --check src build.zig
    uvx ruff check --line-length 100 scripts
    uvx ruff format --check --line-length 100 scripts
    uvx ty check scripts

# Apply zig fmt
fmt:
    zig fmt src build.zig

# Compile-only cross-target gate: every portable fallback path must compile
# (freestanding targets are excluded: the ztest runner needs an OS)
check-baseline:
    zig build check -Dtarget=x86_64-linux
    zig build check -Dtarget=x86-linux
    zig build check -Dtarget=arm-linux
    zig build check -Dtarget=riscv64-linux
    zig build check -Dtarget=wasm32-wasi

# External-oracle lane for flate: python3's zlib cross-checks the committed
# fixtures and freshly generated shapes in both directions, raw deflate
# (wbits=-15) — the incantations of docs/research/flate-notes.md §4.3. Both
# sides run through the harness built from src/flate/oracle.zig: the decode
# direction (oracle encode -> our decode) and the encode direction (our encode
# -> oracle decode), which is the only lane that catches a bit-packing bug
# invisible to a self-round-trip (the T1 `writeBits`/`writeCode` split). The
# streaming row drives the same both-directions check through the example CLI,
# which pumps through flate.Reader/flate.Writer (src/flate/README.md,
# "Streaming") — the only lane that covers the streaming layer end to end.
# The flate external-oracle conformance lane: our codec vs python3 zlib
# raw-deflate, both directions (python is the point — an independent
# implementation). Fixtures, generated shapes, and CLI streaming rows.
flate-oracle:
    zig build flate-oracle-harness
    uv run scripts/flate_oracle.py

bench *ARGS:
    zig build bench -Doptimize=ReleaseFast -- {{ ARGS }}

# Run an example CLI (e.g. just example snappy encode README.md > out)
example example *args:
    zig build example-{{ example }} -- {{ args }}

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache zig-pkg
