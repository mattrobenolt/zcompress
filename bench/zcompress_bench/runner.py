"""Build, execute, and analyze one reproducible codec experiment.

Ported from fastmem_bench/runner.py: variants become arms (one per
implementation binary: zc, klauspost, libdeflate, zlibng, googlesnappy,
plus the aa duplicate of the zc binary for the noise floor). A run
cross-builds every arm for every target, interleaves per-round process runs
through the seeded balanced Latin square under CPU isolation, and analyzes
round medians with exact rank intervals.
"""

import secrets
from pathlib import Path

import click

from ec2bench.cli import box_for, ensure_up
from ec2bench.config import Config
from ec2bench.fleet import Fleet, tags
from ec2bench.parallel import Outcome, parallel, progress
from ec2bench.runs import create_run, validate_label, write_manifest
from zcompress_bench.analysis import BOOTSTRAP_SEED, analyze, validate_effect
from zcompress_bench.build import ARMS, arm_revisions, build_all, provenance, resolve
from zcompress_bench.corpus import load as load_corpus
from zcompress_bench.protocol import execute, orders
from zcompress_bench.report import write

ARM_TOOLS = {
    "zc": "zcompress",
    "klauspost": "klauspost/compress",
    "libdeflate": "libdeflate",
    "zlibng": "zlib-ng",
    "googlesnappy": "google/snappy",
}


@click.command()
@click.option("--rev", "revision", default="WORKTREE", show_default=True)
@click.option("--target", "targets", multiple=True)
@click.option(
    "--suite",
    type=click.Choice(["quick", "standard"]),
    default="standard",
)
@click.option("--rounds", type=click.IntRange(min=1), default=5, show_default=True)
@click.option(
    "--no-aa", is_flag=True, help="Disable the baseline duplicate and significance marks."
)
@click.option("--up", "launch", is_flag=True, help="Launch missing targets first.")
@click.option("--ttl", default=None, help="Lifetime for --up launches.")
@click.option("--label", default="run", show_default=True)
@click.option("--filter", "case_filter", default=None, help="Case substring passed to the binary.")
@click.option("--samples", type=click.IntRange(min=1), default=None)
@click.option("--sample-ms", type=click.IntRange(min=1), default=None)
@click.option(
    "--minimum-effect",
    type=click.FloatRange(min=0),
    default=None,
    help="Minimum fractional effect for marks. Default: project.minimum_effect or 0.",
)
@click.pass_obj
def run(  # noqa: C901, PLR0915 — orchestration keeps the experiment lifecycle visible
    config: Config,
    *,
    revision: str,
    targets: tuple[str, ...],
    suite: str,
    rounds: int,
    no_aa: bool,
    launch: bool,
    ttl: str | None,
    label: str,
    case_filter: str | None,
    samples: int | None,
    sample_ms: int | None,
    minimum_effect: float | None,
) -> None:
    """Cross-build the arms and measure interleaved rounds across the fleet."""
    effect = (
        minimum_effect if minimum_effect is not None else config.project.get("minimum_effect", 0.0)
    )
    validate_effect(effect)
    try:
        validate_label(label)
    except ValueError as error:
        raise click.ClickException(str(error)) from error
    binary_args = []
    for option, value in (
        ("--filter", case_filter),
        ("--samples", samples),
        ("--sample-ms", sample_ms),
    ):
        if value is not None:
            binary_args.extend([option, str(value)])
    fleet = Fleet(config)
    fleet.reap()
    names = config.select(targets)
    startup = {}
    if launch:
        names = names or list(config.targets)
        startup = ensure_up(fleet, names, ttl)
        names = [name for name, outcome in startup.items() if outcome.error is None]
    if not names and not launch:
        names = config.select(
            [
                tags(instance)["Target"]
                for instance in fleet.instances()
                if instance["State"]["Name"] == "running" and "Target" in tags(instance)
            ]
        )
    if not names and not startup:
        raise click.ClickException("No running targets. Use --up or select a target.")
    instances = {name: fleet.one(name) for name in names}
    path, manifest = create_run(
        config.root,
        label,
        list(startup) if launch else names,
        {name: instance["InstanceId"] for name, instance in instances.items()},
        results_dir=config.results_dir,
    )
    seed = secrets.randbits(32)
    source = resolve(config, revision)
    corpus = load_corpus(config.root)
    schedule = orders([*ARMS, *([] if no_aa else ["aa"])], rounds, seed)
    manifest.update(
        {
            "seed": seed,
            "bootstrap_seed": BOOTSTRAP_SEED,
            "rounds": rounds,
            "suite": suite,
            "arms": list(ARMS),
            "aa": not no_aa,
            "schedule": schedule,
            "schedule_method": "seeded-balanced-latin-square",
            "binary_args": binary_args,
            "minimum_effect": effect,
            "corpus": {"hashes": corpus.hashes, "sha256sums": corpus.sums},
            "config": {"project": config.project, "targets": config.targets},
        }
    )
    write_manifest(path, manifest)
    progress("cross builds")
    builds, vendors = build_all(config, source, names)
    manifest.update(provenance(source, builds, vendors))
    write_manifest(path, manifest)
    outputs = fleet.outputs()

    def measure(name: str) -> dict:
        selected = {}
        for arm in ARMS:
            outcome = builds[f"{arm}/{name}"]
            if outcome.error:
                raise RuntimeError(f"Build failed: {arm}: {outcome.error}") from outcome.error
            if outcome.value is None:
                raise RuntimeError("Build returned no artifact")
            selected[arm] = outcome.value
        box = box_for(fleet, instances[name], outputs)
        try:
            box.ready(config.project["image_version"])
        except Exception:
            fleet.terminate([instances[name]["InstanceId"]])
            raise
        protocol = execute(
            config,
            box,
            selected,
            path,
            suite=suite,
            schedule=schedule,
            aa=not no_aa,
            seed=seed,
            corpus_dir=corpus.dir,
            corpus_hashes=corpus.hashes,
            binary_args=binary_args,
        )
        progress("analysis")
        result = analyze(
            path / name / "raw",
            list(ARMS),
            aa=None if no_aa else "aa",
            minimum_effect=effect,
            expected_round_count=rounds,
            corpus=corpus.hashes,
            expected_cpu=config.targets[name]["zig_cpu"],
        )
        result["protocol"] = protocol
        return result

    results = parallel(names, measure)
    results.update(
        {name: Outcome(error=outcome.error) for name, outcome in startup.items() if outcome.error}
    )
    revisions = arm_revisions(source)
    summary = {
        "run_id": path.name,
        "arms": {arm: {"tool": ARM_TOOLS[arm], "revision": revisions[arm]} for arm in ARMS},
        "bootstrap_seed": BOOTSTRAP_SEED,
        "targets": {
            name: outcome.value if outcome.error is None else {"error": str(outcome.error)}
            for name, outcome in results.items()
        },
    }
    write(path, summary)
    manifest["status"] = {
        name: "failed" if outcome.error else "complete" for name, outcome in results.items()
    }
    write_manifest(path, manifest)
    click.echo(str(path))
    if any(outcome.error for outcome in results.values()):
        raise click.ClickException(
            "One or more targets failed. Successful target results remain available."
        )


@click.command(name="analyze")
@click.argument("run_dir", type=click.Path(exists=True, file_okay=False, path_type=Path))
@click.option(
    "--minimum-effect",
    type=click.FloatRange(min=0),
    default=None,
    help="Override the recorded minimum fractional effect.",
)
def analyze_run(run_dir: Path, minimum_effect: float | None) -> None:
    """Analyze saved raw rounds without AWS, SSH, or builds."""
    import json

    manifest = json.loads((run_dir / "manifest.json").read_text())
    effect = minimum_effect if minimum_effect is not None else manifest.get("minimum_effect", 0.0)
    corpus_hashes = manifest["corpus"]["hashes"]
    targets: dict[str, dict] = {}
    for target in manifest["targets"]:
        try:
            targets[target] = analyze(
                run_dir / target / "raw",
                list(manifest["arms"]),
                aa="aa" if manifest["aa"] else None,
                minimum_effect=effect,
                expected_round_count=manifest["rounds"],
                corpus=corpus_hashes,
                expected_cpu=manifest["config"]["targets"][target]["zig_cpu"],
            )
        except (ValueError, OSError) as error:
            targets[target] = {"error": str(error)}
    revisions = {
        "zc": manifest["source"]["revision"],
        "klauspost": manifest["competitors"]["klauspost"]["version"],
        "libdeflate": manifest["competitors"]["libdeflate"]["version"],
        "zlibng": manifest["competitors"]["zlib-ng"]["version"],
        "googlesnappy": manifest["competitors"].get("google-snappy", {}).get("version", "unknown"),
    }
    arms = {arm: {"tool": ARM_TOOLS[arm], "revision": revisions[arm]} for arm in manifest["arms"]}
    write(
        run_dir,
        {
            "run_id": manifest["run_id"],
            "arms": arms,
            "bootstrap_seed": BOOTSTRAP_SEED,
            "targets": targets,
        },
    )
    for target, result in targets.items():
        for warning in result.get("warnings", []):
            click.echo(f"{target}: {warning}")
    if any("error" in result for result in targets.values()):
        raise click.ClickException("One or more targets failed analysis. Read summary.json.")
