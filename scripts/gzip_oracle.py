"""The gzip external-oracle conformance lane.

Python's zlib (the C reference, via `wbits` 31) and the CPython `gzip`
module are the point: independent gzip implementations verifying ours in
both directions (our encode -> its decode, its encode -> our decode), over
generated shapes and the CLI rows; the gzip/gunzip 1.14 CLIs join as the
reference file-tool pair. Run via `just gzip-oracle`; python3 comes from the
flake. Incantations verified in docs/research/containers-notes.md §5.5.
"""

import gzip
import os
import random
import subprocess
import tempfile
import zlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
harness = root / "zig-out/bin/gzip-oracle"

# Our emitted-header policy (README, "The member format", OQ7): FLG=0,
# MTIME=0, OS=255 (T1); XFL is informational and follows the level bands
# (containers-notes.md §5.5: {0,1}->4, 9->2, else 0).
# The full band: {fast, 0, 1} -> 4, 9 -> 2, 2-8 -> 0 (encode.xflFor).
XFL_BY_LEVEL = {str(n): 4 if n <= 1 else 2 if n == 9 else 0 for n in range(10)} | {"fast": 4}


def our_compress(data: bytes, level: str = "fast") -> bytes:
    """Our encoder, through the oracle harness: one gzip member."""
    fd, path = tempfile.mkstemp()
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        p = subprocess.run([str(harness), "encode", path, level], capture_output=True, check=False)
        if p.returncode != 0:
            raise AssertionError(
                f"our encoder failed ({p.returncode}): {p.stderr.decode().strip()}"
            )
        return p.stdout
    finally:
        os.unlink(path)


def our_decompress(member: bytes, cap: int) -> bytes:
    """Our one-shot decoder, through the oracle harness."""
    fd, path = tempfile.mkstemp()
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(member)
        p = subprocess.run(
            [str(harness), "decode", path, str(cap)], capture_output=True, check=False
        )
        if p.returncode != 0:
            raise AssertionError(
                f"our decoder failed ({p.returncode}): {p.stderr.decode().strip()}"
            )
        return p.stdout
    finally:
        os.unlink(path)


def our_decompress_fails(member: bytes, cap: int) -> bool:
    fd, path = tempfile.mkstemp()
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(member)
        p = subprocess.run(
            [str(harness), "decode", path, str(cap)], capture_output=True, check=False
        )
        return p.returncode != 0
    finally:
        os.unlink(path)


def python_decompress(member: bytes) -> bytes:
    """The C reference's one-shot gzip decode (wbits 31)."""
    return zlib.decompress(member, 31)


def zlib_member(data: bytes, level: int) -> bytes:
    """C zlib's gzip wrapper: `compressobj(level, DEFLATED, 31)` — the
    research's verified incantation (OS=3, MTIME=0, XFL by band)."""
    co = zlib.compressobj(level, zlib.DEFLATED, 31)
    return co.compress(data) + co.flush()


def example(args, data: bytes) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["zig", "build", "example-gzip", "--"] + args,
        cwd=root,
        input=data,
        capture_output=True,
        check=False,
    )


def check_header(member: bytes, level: str) -> None:
    assert member[0] == 0x1F and member[1] == 0x8B and member[2] == 8, "magic/CM"
    assert member[3] == 0, f"FLG {member[3]:#x}: no optional fields, reserved bits clear"
    assert int.from_bytes(member[4:8], "little") == 0, "MTIME must be 0 (OQ7)"
    assert member[8] == XFL_BY_LEVEL[level], f"XFL {member[8]} for level {level}"
    assert member[9] == 255, f"OS {member[9]} (T1: 255)"


# 1. Our encode -> the C reference's decode, every level, over the shapes.
rng = random.Random(20261009)
text = (b"the quick brown fox jumps over the lazy dog. " * 200)[:8192]
random_bytes = bytes(rng.randrange(256) for _ in range(4096))
rle = b"\x5a" * 3000 + b"\x00" * 5 + b"q" * 130000  # spans a 64 KiB block split
long_text = b"the quick brown fox jumps over the lazy dog. " * 6000  # 264 KB
empty = b""
shapes = (
    ("empty", empty),
    ("text", text),
    ("random", random_bytes),
    ("rle", rle),
    ("long text (multi-block)", long_text),
)
levels = ("fast", "0", "1", "6", "9")
rows = 0
for desc, data in shapes:
    for level in levels:
        member = our_compress(data, level)
        check_header(member, level)
        got = python_decompress(member)
        assert got == data, f"our encode -> zlib decode ({desc}, {level}): {len(got)} bytes"
        # The trailer is the C reference's CRC-32 and size, little-endian.
        assert int.from_bytes(member[-8:-4], "little") == zlib.crc32(data), f"CRC ({desc})"
        assert int.from_bytes(member[-4:], "little") == len(data) & 0xFFFFFFFF, f"ISIZE ({desc})"
        assert gzip.decompress(member) == data, f"CPython gzip decode ({desc}, {level})"
        rows += 1

# 2. The C reference's encode -> our decode (levels 0, 1, 6, 9), and the
#    CPython module's emission (OS=255) -> our decode.
for desc, data in shapes:
    for level in (0, 1, 6, 9):
        member = zlib_member(data, level)
        got = our_decompress(member, len(data) + 1)
        assert got == data, f"zlib encode -> our decode ({desc}, {level}): {len(got)} bytes"
        rows += 1
    member = gzip.compress(data, compresslevel=6)
    assert member[9] == 255, "CPython emits OS=255"
    got = our_decompress(member, len(data) + 1)
    assert got == data, f"CPython gzip encode -> our decode ({desc})"
    rows += 1

# 3. The single-member boundary: the second member lands in the reference's
#    `unused_data`, and our one-shot ignores everything after the trailer
#    (README, "Contracts" — a boundary-aware caller uses the streaming
#    reader, which the CLI rows below exercise).
two = zlib_member(text, 6) * 2
do = zlib.decompressobj(31)
assert do.decompress(two) + do.flush() == text
assert do.unused_data == zlib_member(text, 6), "the reference leaves the second member"
assert our_decompress(two, len(text) + 1) == text, "our one-shot decodes the first member"

# 4. FHCRC (T3): a hand-built member with a correct CRC16 decodes; a
#    corrupted one fails closed. The value is the low 16 bits of the header
#    CRC-32 (§2.3.1).
raw = zlib.compressobj(6, zlib.DEFLATED, -15)
body = raw.compress(text) + raw.flush()
head = bytes([0x1F, 0x8B, 8, 0x02]) + (0).to_bytes(4, "little") + bytes([0, 255])
head += (zlib.crc32(head) & 0xFFFF).to_bytes(2, "little")
member = head + body + zlib.crc32(text).to_bytes(4, "little") + len(text).to_bytes(4, "little")
assert python_decompress(member) == text, "the reference verifies the FHCRC too (Go does)"
assert our_decompress(member, len(text) + 1) == text, "our FHCRC verification"
corrupt = bytearray(member)
corrupt[len(head) - 2] ^= 0x01
assert our_decompress_fails(bytes(corrupt), len(text) + 1), "a wrong FHCRC must fail closed"
rows += 2

# 5. The gzip/gunzip 1.14 CLI lane: the reference file tools both directions.
for desc, data in shapes:
    p = subprocess.run(["gzip", "-c"], input=data, capture_output=True, check=False)
    assert p.returncode == 0, f"gzip -c ({desc})"
    cli_member = p.stdout
    assert cli_member[9] == 3, "the gzip CLI emits OS=3 (T1)"
    assert our_decompress(cli_member, len(data) + 1) == data, f"gzip CLI -> our decode ({desc})"
    member = our_compress(data)
    p = subprocess.run(["gunzip", "-c"], input=member, capture_output=True, check=False)
    assert p.returncode == 0, f"gunzip -c ({desc}): {p.stderr.decode().strip()}"
    assert p.stdout == data, f"our encode -> gunzip ({desc})"
    rows += 2

# 6. Trailing bytes, the recorded boundary divergence (T2/OQ3): our one-shot
#    decodes the member and ignores the garbage; the CLI's caller loop fails
#    closed on the next header parse.
member = our_compress(text)
garbage = member + b"garbage!!!"
assert our_decompress(garbage, len(text) + 1) == text, "the one-shot ignores trailing bytes"
p = example(["decode", "-"], garbage)
assert p.returncode != 0, "the CLI fails closed on trailing garbage"

# 7. The streaming rows through the example CLI (flate.Writer/flate.Reader
#    underneath, the container framing on top): its own round trip, the C
#    reference's decode of its stream, and the multi-member caller loop.
for desc, data in (("streaming text", text), ("streaming multi-block", long_text)):
    p = example(["encode", "-"], data)
    assert p.returncode == 0, f"example encode ({desc}): {p.stderr.decode().strip()}"
    member = p.stdout
    check_header(member, "fast")
    assert python_decompress(member) == data, f"example encode -> zlib decode ({desc})"
    p = example(["decode", "-"], member)
    assert p.returncode == 0, f"example decode ({desc}): {p.stderr.decode().strip()}"
    assert p.stdout == data, f"example round trip ({desc})"
    rows += 2

doubled = zlib_member(text, 6) * 3
p = example(["decode", "-"], doubled)
assert p.returncode == 0, f"example decode (multi-member): {p.stderr.decode().strip()}"
assert p.stdout == text * 3, "the CLI's caller loop walks every member"

print(
    "gzip-oracle: "
    f"{rows} container rows (our encode -> zlib/CPython/gunzip, zlib/CPython/gzip -> our decode), "
    "both directions, + FHCRC verification + the boundary pins + 2 streaming rows through the CLI: OK"
)
