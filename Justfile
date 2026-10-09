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

# Lint Zig sources: ziglint over the .ziglint.zon paths + the format check
lint:
    ziglint
    zig fmt --check src build.zig

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

# Run codec benchmarks (e.g. just bench -- --count=10 > bench.txt)
bench *ARGS:
    zig build bench -Doptimize=ReleaseFast -- {{ ARGS }}

# Run an example CLI (e.g. just example snappy encode README.md > out)
example example *args:
    zig build example-{{ example }} -- {{ args }}

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache zig-pkg
