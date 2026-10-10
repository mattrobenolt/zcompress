"""Run directories and provenance."""

import json
import re
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=root, check=True, capture_output=True, text=True, timeout=60
    ).stdout.strip()


LABEL = re.compile(r"[A-Za-z0-9_-]+")


def validate_label(label: str) -> None:
    """Fail before any work (for example a launch) that a bad label would waste."""
    if not LABEL.fullmatch(label):
        raise ValueError("Run label must contain only letters, numbers, underscores, or hyphens")


def create_run(
    root: Path,
    label: str,
    targets: list[str],
    instances: dict[str, str],
    *,
    results_dir: Path | None = None,
) -> tuple[Path, dict[str, Any]]:
    validate_label(label)
    run_id = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ") + "-" + label
    path = (results_dir or root / "bench-results") / run_id
    path.mkdir(parents=True)  # Refuse to overwrite another run in the same second.
    manifest = {
        "run_id": run_id,
        "command": sys.argv,
        "targets": targets,
        "instances": instances,
        "git": {
            "head": git(root, "rev-parse", "HEAD"),
            "status": git(root, "status", "--porcelain"),
            "diff": git(root, "diff", "HEAD", "--binary"),
        },
    }
    write_manifest(path, manifest)
    return path, manifest


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    (path / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def watch(path: str, timeout_s: int) -> int:
    """Wait for the run at path to finish. Returns 0 when summary.json exists.

    summary.json appears when the analysis is done. The loop checks it, the
    fleet, and the deadline every minute. A run whose boxes are all gone and
    that has no summary means the driver died; it ends in 1.
    """
    import time
    from pathlib import Path

    deadline = time.time() + timeout_s
    summary = Path(path) / "summary.json"
    while True:
        if summary.exists():
            return 0
        if time.time() >= deadline:
            return 1
        time.sleep(60)
