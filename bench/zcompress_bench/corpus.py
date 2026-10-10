"""The committed corpus: bench/corpus/, hashed, identical bytes for every arm.

The generator is bench/zig/corpus.zig (`zig build corpus`); the shapes mirror
the codec bench files (src/flate/bench.zig). This module verifies the
committed tree against its SHA256SUMS and hands the raw-file hashes to the
runner, the manifest, and the per-round parser (every arm's meta record
carries the hashes it actually read on the box).
"""

import hashlib
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Corpus:
    dir: Path
    # The ten raw files, name to SHA-256 hex.
    hashes: dict[str, str]
    # Every file, reference blobs included.
    all_hashes: dict[str, str]
    # The committed SHA256SUMS text.
    sums: str


def load(root: Path) -> Corpus:
    """Verify bench/corpus against SHA256SUMS and return its descriptor."""
    directory = root / "bench" / "corpus"
    sums = (directory / "SHA256SUMS").read_text()
    recorded = {}
    for line in sums.splitlines():
        digest, name = line.split("  ", 1)
        recorded[name] = digest
    if not recorded:
        raise ValueError(f"{directory}: empty SHA256SUMS")
    for name, digest in sorted(recorded.items()):
        data = (directory / name).read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if actual != digest:
            raise ValueError(f"{directory}/{name}: corpus bytes disagree with SHA256SUMS")
    raw = {name: digest for name, digest in recorded.items() if "." not in name}
    if len(raw) != 10:
        raise ValueError(f"{directory}: expected 10 raw corpus files, found {len(raw)}")
    return Corpus(directory, raw, recorded, sums)
