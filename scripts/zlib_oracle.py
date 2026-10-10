"""The zlib external-oracle conformance lane.

Python's zlib (the C reference, via `wbits` 15) is the point: an independent
zlib implementation verifying ours in both directions (our encode -> its
decode, its encode -> our decode), over generated shapes and the CLI
streaming rows, plus the FDICT refusal cases, the FLEVEL/FCHECK emissions,
and the exact stream boundary. Run via `just zlib-oracle`; python3 comes from
the flake. Incantations verified in docs/research/containers-notes.md §5.5.
"""

import os
import random
import subprocess
import tempfile
import zlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
harness = root / "zig-out/bin/zlib-oracle"

# Our emitted-header policy (README, "The stream format", OQ7): CMF 0x78
# (CM=8, CINFO=7); FLG carries only the level's FLEVEL band and the minimal
# FCHECK, FDICT clear. The bands follow the C reference (containers-notes.md
# §5.5: {0,1}->0, {2-5}->1, {6,-1}->2, {7-9}->3).
FLEVEL_BY_LEVEL = {"fast": 2, "0": 0, "1": 0, "2": 1, "5": 1, "6": 2, "9": 3}


def our_compress(data: bytes, level: str = "fast") -> bytes:
    """Our encoder, through the oracle harness: one zlib stream."""
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


def our_decompress(stream: bytes, cap: int) -> bytes:
    """Our one-shot decoder, through the oracle harness."""
    fd, path = tempfile.mkstemp()
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(stream)
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


def our_decompress_error(stream: bytes, cap: int) -> str:
    """Our one-shot decoder's error name, through the oracle harness."""
    fd, path = tempfile.mkstemp()
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(stream)
        p = subprocess.run(
            [str(harness), "decode", path, str(cap)], capture_output=True, check=False
        )
        assert p.returncode != 0, "expected a decoder failure"
        return p.stderr.decode().strip().removeprefix("zlib-oracle: ")
    finally:
        os.unlink(path)


def example(args, data: bytes) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["zig", "build", "example-zlib", "--"] + args,
        cwd=root,
        input=data,
        capture_output=True,
        check=False,
    )


def check_header(stream: bytes, level: str) -> None:
    assert stream[0] == 0x78, f"CMF {stream[0]:#x}: CM=8, CINFO=7"
    assert (stream[0] << 8 | stream[1]) % 31 == 0, "FCHECK: CMF*256 + FLG must be 0 mod 31"
    assert stream[1] >> 6 == FLEVEL_BY_LEVEL[level], f"FLEVEL for level {level}"
    assert stream[1] & 0x20 == 0, "FDICT must be clear (ZE2)"


def check_trailer(stream: bytes, data: bytes) -> None:
    assert int.from_bytes(stream[-4:], "big") == zlib.adler32(data), "big-endian ADLER32"


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
        stream = our_compress(data, level)
        check_header(stream, level)
        check_trailer(stream, data)
        assert zlib.decompress(stream) == data, f"our encode -> zlib decode ({desc}, {level})"
        rows += 1

# 2. The C reference's encode -> our decode: `zlib.compress` and the
#    `compressobj` form, levels {-1, 0, 1, 6, 9} (-1 is the reference's
#    default-compression level, FLEVEL 2).
for desc, data in shapes:
    for level in (-1, 0, 1, 6, 9):
        stream = zlib.compress(data, level)
        got = our_decompress(stream, len(data) + 1)
        assert got == data, f"zlib.compress -> our decode ({desc}, {level}): {len(got)} bytes"
        co = zlib.compressobj(level, zlib.DEFLATED, 15)
        stream = co.compress(data) + co.flush()
        got = our_decompress(stream, len(data) + 1)
        assert got == data, f"compressobj -> our decode ({desc}, {level}): {len(got)} bytes"
        rows += 2

# 3. The stream boundary: the second stream lands in the reference's
#    `unused_data`, and our one-shot ignores everything after ADLER32
#    (README, "Contracts": bytes after the trailer are not part of the
#    stream). The CLI rows below exercise the streaming reader's boundary.
two = zlib.compress(text, 6) * 2
do = zlib.decompressobj(15)
assert do.decompress(two) + do.flush() == text
assert do.unused_data == zlib.compress(text, 6), "the reference leaves the second stream"
assert our_decompress(two, len(text) + 1) == text, "our one-shot decodes the first stream"
rows += 1

# 4. FDICT (ZD3/ZD4, T5): the C reference emits a dictionary stream with
#    header 78 bb + the dictionary's big-endian Adler-32; ours refuses it
#    before any body byte — with the right dictionary or a wrong one, since
#    the API has no dictionary registry at all. The dict + FLEVEL-0 corner
#    emits 78 3f (FCHECK = 31, conformant and must not be rejected as a bad
#    header).
dictionary = b"she sells seashells by the seashore\n"
dict_stream = None
for level, expected_flg in ((6, 0xBB), (0, 0x3F)):
    co = zlib.compressobj(level, zlib.DEFLATED, 15, 9, zlib.Z_DEFAULT_STRATEGY, dictionary)
    stream = co.compress(text) + co.flush()
    assert stream[0] == 0x78 and stream[1] == expected_flg, f"dict header {stream[:2].hex()}"
    assert int.from_bytes(stream[2:6], "big") == zlib.adler32(dictionary), "DICTID"
    assert (stream[0] << 8 | stream[1]) % 31 == 0, "FCHECK=31 is 0 mod 31 (T5)"
    assert zlib.decompressobj(15, dictionary).decompress(stream) == text, "the reference decodes"
    assert our_decompress_error(stream, len(text) + 1) == "DictionaryRequired", (
        f"our FDICT refusal (level {level}, FCHECK corner)"
    )
    if level == 6:
        dict_stream = stream
    rows += 1
assert dict_stream is not None
rows += 1  # the dict_stream reuse below

# The FDICT refusal through the streaming CLI: the input is a real dictionary
# stream, and the decode fails closed instead of misreading the DICTID as
# deflate data (std's T6 behavior).
p = example(["decode", "-"], dict_stream)
assert p.returncode != 0, "the CLI fails closed on an FDICT stream"

# 5. The FLEVEL/FCHECK emissions the research verified: 78 9c at level 6,
#    78 01 at levels 0/1, 78 da at level 9.
assert zlib.compress(text, 6)[:2] == b"\x78\x9c", "78 9c at level 6"
assert zlib.compress(text, 0)[:2] == b"\x78\x01", "78 01 at level 0"
assert zlib.compress(text, 1)[:2] == b"\x78\x01", "78 01 at level 1"
assert zlib.compress(text, 9)[:2] == b"\x78\xda", "78 da at level 9"
rows += 1

# 6. Trailing bytes, the spec's own boundary (§2.2: "Any data which may
#    appear after ADLER32 are not part of the zlib stream"): the one-shot and
#    the thin CLI pump both decode the stream and stop; nothing is
#    interpreted past ADLER32.
stream = our_compress(text)
assert our_decompress(stream + b"garbage!!!", len(text) + 1) == text
p = example(["decode", "-"], stream + b"garbage!!!")
assert p.returncode == 0, f"the CLI stops at the stream end: {p.stderr.decode().strip()}"
assert p.stdout == text
rows += 1

# 7. The streaming rows through the example CLI (zlib.Writer/zlib.Reader
#    underneath): its own round trip, the C reference's decode of its stream,
#    and the reference's stream through the CLI.
for desc, data in (("streaming text", text), ("streaming multi-block", long_text)):
    p = example(["encode", "-"], data)
    assert p.returncode == 0, f"example encode ({desc}): {p.stderr.decode().strip()}"
    stream = p.stdout
    check_header(stream, "fast")
    check_trailer(stream, data)
    assert zlib.decompress(stream) == data, f"example encode -> zlib decode ({desc})"
    p = example(["decode", "-"], stream)
    assert p.returncode == 0, f"example decode ({desc}): {p.stderr.decode().strip()}"
    assert p.stdout == data, f"example round trip ({desc})"
    reference = zlib.compress(data, 6)
    p = example(["decode", "-"], reference)
    assert p.returncode == 0, f"zlib stream -> example decode ({desc})"
    assert p.stdout == data, f"zlib encode -> example decode ({desc})"
    rows += 3

print(
    "zlib-oracle: "
    f"{rows} container rows (our encode -> zlib decode, zlib/compressobj -> our decode), "
    "both directions, + the FDICT/T5 refusal + the FLEVEL/FCHECK emissions + the boundary "
    "pins + 6 streaming rows through the CLI: OK"
)
