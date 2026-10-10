"""The fleet correctness gate: every arm's --check matrix on every box.

Cross-builds the four arms per target, uploads them with the committed
corpus, and runs each driver's correctness matrix (round trip plus
reference-blob decode for every case) without CPU isolation. The gate of a
benchmark run: a box whose drivers do not pass never measures.
"""

import json
import shlex
import subprocess
from pathlib import Path
from typing import Any

import click
from rich.console import Console
from rich.table import Table

from ec2bench.cli import box_for, ensure_up
from ec2bench.config import Config
from ec2bench.fleet import Fleet, tags
from ec2bench.parallel import parallel
from ec2bench.runs import create_run, write_manifest
from zcompress_bench.build import ARMS, build_all, source_hash
from zcompress_bench.corpus import load as load_corpus


def parse_summary(text: str, arm: str) -> dict[str, Any]:
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) != 1:
        raise ValueError(f"{arm}: expected one correctness JSON summary, got {len(lines)}")
    result = json.loads(lines[0])
    if not isinstance(result, dict) or result.get("type") != "check" or result.get("schema") != 1:
        raise ValueError(f"{arm}: invalid correctness summary schema")
    if result.get("status") not in {"pass", "fail"}:
        raise ValueError(f"{arm}: invalid correctness status")
    if type(result.get("cases")) is not int or result["cases"] <= 0:
        raise ValueError(f"{arm}: correctness ran no cases")
    return result


def check_target(  # noqa: PLR0917 — the target lifecycle stays together
    config: Config,
    fleet: Fleet,
    outputs: dict[str, Any],
    name: str,
    builds: dict[str, Any],
    path: Path,
    corpus_dir: Path,
) -> dict[str, Any]:
    instance = fleet.one(name)
    box = box_for(fleet, instance, outputs)
    box.ready(config.project["image_version"])
    remote = f"{config.project['remote_dir'].rstrip('/')}/{path.name}-{name}"
    box.run(f"mkdir -p {shlex.quote(remote)}")
    box.upload(corpus_dir, remote)
    local = path / name
    results: dict[str, Any] = {}
    for arm in ARMS:
        outcome = builds.get(f"{arm}/{name}")
        if outcome is None or outcome.error is not None or outcome.value is None:
            results[arm] = {"error": str(outcome.error) if outcome else "no build"}
            continue
        build = outcome.value
        box.upload(build.binary, f"{remote}/bin")
        remote_binary = f"{remote}/bin/{build.binary.name}"
        arm_remote = f"{remote}/{arm}"
        command = (
            f"mkdir -p {shlex.quote(arm_remote)} && cd {shlex.quote(arm_remote)} && "
            f"(ulimit -c 0; {shlex.quote(remote_binary)} --corpus {shlex.quote(remote + '/corpus')}"
            " --check >check.json 2>check.stderr; printf '%s\\n' \"$?\" >check.exit)"
        )
        try:
            box.run(command, timeout=600)
            box.download(f"{remote}/{arm}", local / arm)
            summary = parse_summary((local / arm / "check.json").read_text(), arm)
            summary["exit_status"] = int((local / arm / "check.exit").read_text().strip())
            if summary["exit_status"] != 0 or summary["status"] != "pass":
                summary["error"] = (
                    f"check failed: exit={summary['exit_status']}, "
                    f"detail={summary.get('detail', '')}"
                )
            results[arm] = summary
        except Exception as error:  # noqa: BLE001 — preserve the other arms' evidence
            results[arm] = {"error": str(error)}
    return {"instance": instance["InstanceId"], "arms": results}


@click.command(name="test")
@click.option("--target", "targets", multiple=True)
@click.option("--up", "launch", is_flag=True, help="Launch missing targets first.")
@click.option("--ttl", default=None, help="Lifetime for --up launches.")
@click.pass_obj
def test_fleet(config: Config, targets: tuple[str, ...], launch: bool, ttl: str | None) -> None:
    """Run every arm's correctness matrix on each box."""
    fleet = Fleet(config)
    names = config.select(targets)
    startup = {}
    if launch:
        names = names or list(config.targets)
        startup = ensure_up(fleet, names, ttl)
        names = [name for name, outcome in startup.items() if outcome.error is None]
    elif not names:
        names = config.select(
            [
                tags(instance)["Target"]
                for instance in fleet.instances()
                if instance["State"]["Name"] == "running" and "Target" in tags(instance)
            ]
        )
    if not names and not startup:
        raise click.ClickException("No running targets. Use --up or select a target.")
    path, manifest = create_run(
        config.root,
        "test",
        list(startup) if launch else names,
        {},
        results_dir=config.results_dir,
    )
    corpus = load_corpus(config.root)
    manifest.update(
        {
            "kind": "correctness",
            "source_hash": source_hash(config.root),
            "corpus": corpus.hashes,
            "zig_version": subprocess.run(
                ["zig", "version"],
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            ).stdout.strip(),
        }
    )
    write_manifest(path, manifest)
    from zcompress_bench.build import resolve

    source = resolve(config, "WORKTREE")
    builds = build_all(config, source, names)
    outputs = fleet.outputs() if names else {}

    results = parallel(
        names,
        lambda name: check_target(config, fleet, outputs, name, builds, path, corpus.dir),
    )
    summary: dict[str, Any] = {
        name: outcome.value if outcome.error is None else {"error": str(outcome.error)}
        for name, outcome in results.items()
    }
    summary.update(
        {
            name: {"error": str(outcome.error)}
            for name, outcome in startup.items()
            if outcome.error is not None
        }
    )
    (path / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    table = Table("Target", *ARMS)
    failed = False
    for name, result in summary.items():
        arms = result.get("arms", {})
        statuses = [
            "PASS"
            if arms.get(arm, {}).get("status") == "pass" and "error" not in arms[arm]
            else "FAIL"
            for arm in ARMS
        ]
        table.add_row(name, *statuses)
        failed |= "FAIL" in statuses
        manifest.setdefault("status", {})[name] = "failed" if "FAIL" in statuses else "complete"
    Console().print(table)
    write_manifest(path, manifest)
    click.echo(str(path))
    if failed:
        raise click.ClickException("Correctness failed. Read summary.json and per-arm raw files.")
