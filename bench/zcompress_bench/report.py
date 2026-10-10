"""Machine-readable results and compact human reports. Ported shapes from
fastmem_bench/report.py; the goal and stability tables do not port."""

import json
import math
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.table import Table


def write(path: Path, summary: dict[str, Any]) -> None:  # noqa: C901 — the report layout stays in one function
    (path / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    text = [
        "# Benchmark report",
        "",
        "Ratios below 1 indicate a faster candidate. Throughput is measured over",
        "uncompressed bytes; the compared quantity is nanoseconds per operation",
        "(one compress or decompress of the case's raw corpus file).",
        "",
        "Each round contributes the median of its samples for each case and",
        "implementation. Two arms run in separate processes. A/A rows and",
        "competitor/zc rows use the two-sample Hodges-Lehmann ratio and the exact",
        "Mann-Whitney interval (96.8% for 5 against 5 rounds). Rows within one arm",
        "(zc/std, container/flate) share processes: the one-sample Hodges-Lehmann",
        "ratio of the per-round ratios and the exact Wilcoxon signed-rank interval",
        "(93.75% for 5 rounds: the range of the per-round ratios).",
        "container/flate pairs each container with the flate row of the SAME",
        "implementation in the SAME processes: the honest container-overhead",
        "reference (cross-binary code-layout interference inflates cross-binary",
        "comparisons on latency-bound shapes).",
        "The Level column gives the nominal coverage of each interval.",
        "Flagged outlier rounds are reported only. They stay in every ratio and",
        "interval. The noise floor is the 95th percentile of |log A/A ratio| in",
        "the direction/size group, pooled across codecs, shapes, and",
        "implementations. An asterisk requires at least five rounds and an",
        "interval entirely outside [1/(1+m), 1+m], where m is the larger of the",
        "noise floor and the minimum effect.",
        "",
        "## Arms",
        "",
        "| Arm | Tool | Revision |",
        "|---|---|---|",
    ]
    for arm, info in summary["arms"].items():
        text.append(f"| {arm} | {info['tool']} | {info['revision']} |")
    text.append("")
    table = Table("Target", "Comparison", "Arm", "Codec", "Direction", "Geomean")
    for target, result in summary["targets"].items():
        text += [f"## {target}", ""]
        if "error" in result:
            text += [f"Target failed: {result['error']}", ""]
            continue
        for warning in result.get("warnings", []):
            text += [f"Warning: {warning}", ""]
        text += [f"Minimum effect: {result['minimum_effect']:.4%}.", ""]
        if result["noise_floors"]:
            text += ["| A/A floor group | Noise floor |", "|---|---:|"]
            for group, floor in sorted(result["noise_floors"].items()):
                text.append(f"| {group} | {floor:.4%} |")
        else:
            text.append("A/A is disabled. The report does not mark significance.")
        text += ["", *outlier_table(result.get("outliers", []))]
        text += [
            "| Case | Comparison | Arm | Ratio | Interval | Level | Outlier rounds |",
            "|---|---|---|---:|---|---:|---|",
        ]
        for row in result["rows"]:
            mark = " *" if row["significant"] else ""
            lo, hi = row["ci95"]
            level = f"{row['ci_level']:.2%}"
            if row.get("evidence") == "insufficient":
                level += " (insufficient evidence)"
            comparison = row["comparison"]
            if row["reference_case"] != row["case"]:
                comparison += f" (vs {row['reference_case']})"
            text.append(
                f"| {row['case']} | {comparison} | {row['arm']} | "
                f"{row['ratio']:.4f}{mark} | {lo:.4f}-{hi:.4f} | {level} | {outlier_cell(row)} |"
            )
        text += [
            "",
            "### Geomeans",
            "",
            "| Comparison | Arm | Codec | Direction | Geomean | Cases |",
            "|---|---|---|---|---:|---:|",
        ]
        for row in result["groups"]:
            values = [
                row["comparison"],
                row["arm"],
                row["codec"],
                row["direction"],
                f"{row['geomean']:.4f}",
                str(row["cases"]),
            ]
            table.add_row(target, *values[:5])
            text.append("| " + " | ".join(values) + " |")
        text += ["", *sizes_table(result.get("sizes", []))]
    (path / "report.md").write_text("\n".join(text))
    Console().print(table)


OUTLIER_LIMIT = 50


def outlier_cell(row: dict[str, Any]) -> str:
    flagged = row.get("outlier_rounds", {})
    return " ".join(
        f"{side[0]}:r{index}"
        for side in ("candidate", "baseline")
        for index in flagged.get(side, [])
    )


def outlier_table(outliers: list[dict[str, Any]]) -> list[str]:
    text = ["### Outlier rounds", ""]
    if not outliers:
        return [*text, "No round was flagged.", ""]
    counts: dict[str, int] = {}
    for item in outliers:
        counts[item["arm"]] = counts.get(item["arm"], 0) + 1
    text += [
        "A flagged round departs from the other rounds of its arm, case, and implementation.",
        "It stays in every ratio and interval. Flagged rounds per arm: "
        + ", ".join(f"{arm} {count}" for arm, count in sorted(counts.items()))
        + ".",
        "",
        "| Arm | Case | Implementation | Round | Ratio to other rounds |",
        "|---|---|---|---:|---:|",
    ]
    ordered = sorted(outliers, key=lambda item: -abs(math.log(item["ratio"])))
    text += [
        f"| {item['arm']} | {item['case']} | {item['impl']} | {item['round']} | "
        f"{item['ratio']:.3f} |"
        for item in ordered[:OUTLIER_LIMIT]
    ]
    if len(ordered) > OUTLIER_LIMIT:
        text.append("")
        text.append(
            f"The largest {OUTLIER_LIMIT} of {len(ordered)} appear. `summary.json` has all."
        )
    return [*text, ""]


def sizes_table(sizes: list[dict[str, Any]]) -> list[str]:
    """Compressed sizes per cell: the ratio half of the codec story."""
    text = [
        "### Compressed sizes",
        "",
        "Median produced bytes per compress row, and the ratio over the raw size.",
        "",
        "| Case | Arm | Bytes | Ratio |",
        "|---|---|---:|---:|",
    ]
    for row in sizes:
        if row["arm"] == "aa":
            continue
        text.append(
            f"| {row['case']} | {row['arm']}:{row['impl']} | {row['bytes']} | {row['ratio']:.4f} |"
        )
    return [*text, ""]
