"""Per-target interleaved rounds. Ported from fastmem_bench/protocol.py."""

import json
import random
import shlex
from pathlib import Path
from typing import Any

from ec2bench.box import Box
from ec2bench.config import Config
from ec2bench.facts import collect
from ec2bench.isolation import isolate, run_isolated, stop_isolated
from ec2bench.parallel import progress
from zcompress_bench.build import Build
from zcompress_bench.jsonl import parse


def orders(variants: list[str], rounds: int, seed: int) -> list[list[str]]:
    rng = random.Random(seed)  # noqa: S311 — recorded experimental randomization
    labels = variants.copy()
    rng.shuffle(labels)
    count = len(labels)
    if not count:
        raise ValueError("The schedule requires at least one variant")
    # Williams balanced Latin square: every position and predecessor balance per block.
    first = [0]
    first.extend((index + 1) // 2 if index % 2 else count - index // 2 for index in range(1, count))
    rows = [[labels[(value + offset) % count] for value in first] for offset in range(count)]
    if count % 2 and count > 1:
        rows += [list(reversed(row)) for row in rows]
    result = []
    while len(result) < rounds:
        # Shuffle Latin-square blocks separately to balance positions within count rounds.
        blocks = [rows[index : index + count] for index in range(0, len(rows), count)]
        rng.shuffle(blocks)
        for block in blocks:
            rng.shuffle(block)
            result.extend(block)
    return result[:rounds]


def execute(
    config: Config,
    box: Box,
    builds: dict[str, Build],
    path: Path,
    *,
    suite: str,
    schedule: list[list[str]],
    aa: bool,
    seed: int,
    corpus_dir: Path,
    corpus_hashes: dict[str, str],
    binary_args: list[str] | None = None,
) -> dict[str, Any]:
    target = next(iter(builds.values())).target
    destination = path / target
    destination.mkdir(parents=True, exist_ok=True)
    remote = config.project["remote_dir"].rstrip("/") + "/" + path.name
    progress("upload corpus and binaries")
    box.run(f"mkdir -p {shlex.quote(remote)}")
    box.upload(corpus_dir, remote)  # lands as <remote>/corpus
    by_arm = dict(builds)
    if aa:
        by_arm["aa"] = builds["zc"]
    for arm, build in by_arm.items():
        box.upload(build.binary, f"{remote}/bin/{arm}")
    binary_args = list(binary_args or [])
    progress("host facts")
    facts = collect(box, config.results_dir)
    (destination / "facts.json").write_text(json.dumps(facts, indent=2) + "\n")
    arms = list(by_arm)
    box.run("mkdir -p " + " ".join(shlex.quote(f"{remote}/raw/{arm}") for arm in arms))
    cpu = None
    try:
        if not facts.get("topology"):
            error = facts.get("errors", {}).get("topology", "empty probe")
            raise ValueError(f"CPU topology unavailable: {error}")
        with isolate(box, facts["topology"]) as cpu:
            try:
                for round_index, order in enumerate(schedule):
                    for arm in order:
                        progress(f"round {round_index + 1}/{len(schedule)}: {arm}")
                        binary = f"{remote}/bin/{arm}/{by_arm[arm].binary.name}"
                        output = f"{remote}/raw/{arm}/r{round_index}.jsonl"
                        error = f"{remote}/raw/{arm}/r{round_index}.stderr"
                        run_isolated(
                            box,
                            cpu,
                            [
                                binary,
                                "--corpus",
                                f"{remote}/corpus",
                                "--suite",
                                suite,
                                "--seed",
                                str(seed),
                                *(binary_args or []),
                            ],
                            unit=f"{path.name}-{arm}-r{round_index}",
                            output=output,
                            error=error,
                        )
                        box.download(f"{remote}/raw/{arm}", destination / "raw" / arm)
                        measurement = parse(
                            destination / "raw" / arm / f"r{round_index}.jsonl",
                            corpus=corpus_hashes,
                        )
                        expected = "zc" if arm == "aa" else arm
                        if measurement.meta["arm"] != expected:
                            raise ValueError(
                                f"Raw meta arm disagrees: {measurement.meta['arm']} != {expected}"
                            )
            finally:
                stop_isolated(box, path.name)
    finally:
        box.download(remote, destination)
    return {
        "cpu": cpu,
        "schedule": schedule,
        "instance_id": box.instance_id,
        "warnings": [],
    }
