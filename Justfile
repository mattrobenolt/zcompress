# zcompress: fast compression codecs for Zig. docs/zcompress-plan.md is the
# plan: mission, architecture, methodology, milestones with acceptance criteria.

default: test

# Unit tests for every codec
test:
    zig build test

# Lint Zig sources: ziglint over the .ziglint.zon paths + the format check
lint:
    ziglint
    zig fmt --check src build.zig

# Apply zig fmt
fmt:
    zig fmt src build.zig

# Run codec benchmarks (e.g. just bench -- --count=10 > bench.txt)
bench *ARGS:
    zig build bench -Doptimize=ReleaseFast -- {{ ARGS }}

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache zig-pkg
