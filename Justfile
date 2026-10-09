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

# External-oracle lane for the flate decoder: python3's zlib cross-checks the
# committed fixtures and freshly generated shapes in both directions, raw
# deflate (wbits=-15) — the incantations of docs/research/flate-notes.md §4.3.
# The decoder side runs through the harness built from src/flate/oracle.zig.
flate-oracle:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build flate-oracle-harness
    python3 - "{{justfile_directory()}}" <<'PY'
    import os, random, subprocess, sys, tempfile, zlib
    from pathlib import Path

    root = Path(sys.argv[1])
    harness = root / "zig-out/bin/flate-oracle"
    testdata = root / "src/flate/testdata"
    # Raw-deflate shapes the oracle can emit. zlib has no level -2 (that is
    # Go's `flate.HuffmanOnly`); the huffman-only stream is the Z_HUFFMAN_ONLY
    # strategy here, which is the shape that exercises dynamic blocks.
    def make_raw(level, strategy=zlib.Z_DEFAULT_STRATEGY):
        def compress(data):
            co = zlib.compressobj(level, zlib.DEFLATED, -15, zlib.DEF_MEM_LEVEL, strategy)
            return co.compress(data) + co.flush()
        return compress


    shapes = (
        ("stored (level 0)", make_raw(0)),
        ("huffman-only", make_raw(6, zlib.Z_HUFFMAN_ONLY)),
        ("level 1", make_raw(1)),
        ("level 6", make_raw(6)),
        ("level 9", make_raw(9)),
    )


    def our_decompress(raw: bytes, cap: int) -> bytes:
        """Our decoder, through the oracle harness: raw deflate, target cap."""
        fd, path = tempfile.mkstemp()
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
            p = subprocess.run([str(harness), path, str(cap)], capture_output=True)
            if p.returncode != 0:
                raise AssertionError(
                    "our decoder failed (%s): %s" % (p.returncode, p.stderr.decode().strip())
                )
            return p.stdout
        finally:
            os.unlink(path)


    def our_decompress_fails(raw: bytes, cap: int) -> bool:
        fd, path = tempfile.mkstemp()
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
            p = subprocess.run([str(harness), path, str(cap)], capture_output=True)
            return p.returncode != 0
        finally:
            os.unlink(path)


    def python_decompress(raw: bytes) -> bytes:
        do = zlib.decompressobj(-15)
        return do.decompress(raw) + do.flush()


    def check(desc: str, data: bytes, cap: int) -> None:
        """Both directions: an oracle-compressed stream decodes to `data` in our
        decoder, and the oracle itself round-trips the same bytes."""
        for shape, compress in shapes:
            raw = compress(data)
            assert python_decompress(raw) == data, "oracle round trip (%s, %s)" % (desc, shape)
            got = our_decompress(raw, cap)
            assert got == data, "our decode (%s, %s): %d bytes, want %d" % (
                desc, shape, len(got), len(data))


    # 1. The committed golang/go pairs: `.golden` is a single non-final block,
    #    so verbatim it must fail closed, and with BFINAL set on that block it
    #    must decode to `.in` (both verified against the oracle).
    pairs = 0
    for golden in sorted(testdata.glob("*.golden")):
        inp = golden.parent / (golden.name[: -len(".golden")] + ".in")
        data = inp.read_bytes()
        raw = golden.read_bytes()
        assert python_decompress(raw) == data, "oracle decode (%s)" % golden.name
        assert our_decompress_fails(raw, len(data)), "%s: non-final block accepted" % golden.name
        completed = bytearray(raw)
        completed[0] |= 1  # BFINAL on the fixture's single block header
        assert python_decompress(bytes(completed)) == data, "oracle decode (%s, final)" % golden.name
        got = our_decompress(bytes(completed), len(data))
        assert got == data, "our decode (%s): %d bytes, want %d" % (golden.name, len(got), len(data))
        pairs += 1
    assert pairs == 9, "expected 9 testdata pairs, found %d" % pairs

    # 2. The oracle's own streams over the same inputs, every level.
    for inp in sorted(testdata.glob("*.in")):
        check(inp.name, inp.read_bytes(), len(inp.read_bytes()) + 1)

    # 3. Generated shapes: text, random, and single-byte runs.
    rng = random.Random(20261008)
    text = (b"the quick brown fox jumps over the lazy dog. " * 200)[:8192]
    random_bytes = bytes(rng.randrange(256) for _ in range(4096))
    rle = b"\x5a" * 3000 + b"\x00" * 5 + b"q" * 130000  # spans a 64 KiB block split
    for desc, data in (("text", text), ("random", random_bytes), ("rle", rle)):
        check(desc, data, len(data) + 1)

    print("flate-oracle: %d fixture pairs + %d inputs x %d raw-deflate shapes: OK"
          % (pairs, len(list(testdata.glob("*.in"))) + 3, len(shapes)))
    PY

# Run codec benchmarks (e.g. just bench -- --count=10 > bench.txt)
bench *ARGS:
    zig build bench -Doptimize=ReleaseFast -- {{ ARGS }}

# Run an example CLI (e.g. just example snappy encode README.md > out)
example example *args:
    zig build example-{{ example }} -- {{ args }}

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache zig-pkg
