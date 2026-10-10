"""Robust round-level ratios and exact rank intervals for codec rows.

Ported from the fastmem harness (fastmem_bench/analysis.py); the estimator
core is verbatim. One round is one process run, and the round is the unit of
independence. Each (arm, case, implementation) cell reduces to the median of
its samples. A ratio compares the round medians of two cells on the log
scale. Cells of two arms come from separate processes: a two-sample
comparison (A/A and competitor arms against the zc arm). Cells of one arm
come from the same processes: a paired comparison (zc against the in-binary
std rows, and each container against its paired flate row — the honest
reference, since cross-binary code-layout interference inflates cross-binary
comparisons on latency-bound shapes). Outlier rounds are reported only. They
never leave an estimate or interval. Ratios below 1 indicate a faster
candidate; throughput is over uncompressed bytes.
"""

import logging
import math
import statistics
from collections import defaultdict
from functools import cache
from pathlib import Path
from typing import Any

from zcompress_bench.jsonl import Measurement, parse

# The estimator has no random component. The runner still records this value.
BOOTSTRAP_SEED = 20261021
CONFIDENCE = 0.95
FLOOR_QUANTILE = 0.95
OUTLIER_Z = 5.0
OUTLIER_MIN = math.log1p(0.05)
OUTLIER_SCALE_MIN = 0.005
OUTLIER_MIN_ROUNDS = 5
# Fewer rounds give insufficient evidence: no mark.
MIN_ROUNDS = 5
MAD_TO_SD = 1.4826

BASELINE_ARM = "zc"


def round_medians(rounds: list[list[float]]) -> list[float]:
    if not rounds or any(not samples for samples in rounds):
        raise ValueError("Every round requires samples")
    values = [statistics.median(samples) for samples in rounds]
    if any(value <= 0 for value in values):
        raise ValueError("Round medians must be positive")
    return values


def outlier_rounds(values: list[float]) -> list[int]:
    """Return the one round that departs from the other rounds of its cell, if any.

    The flag is for reports only. No estimate or interval removes the round.
    """
    if len(values) < OUTLIER_MIN_ROUNDS:
        return []
    logs = [math.log(value) for value in values]
    flagged = []
    for index, value in enumerate(logs):
        others = logs[:index] + logs[index + 1 :]
        center = statistics.median(others)
        spread = MAD_TO_SD * statistics.median(abs(other - center) for other in others)
        if abs(value - center) > max(OUTLIER_Z * max(spread, OUTLIER_SCALE_MIN), OUTLIER_MIN):
            flagged.append(index)
    return flagged if len(flagged) == 1 else []


@cache
def rank_counts(n: int, m: int) -> tuple[int, ...]:
    """Count the orderings of n + m values by the Mann-Whitney statistic U."""
    if n == 0 or m == 0:
        return (1,)
    counts = [0] * (n * m + 1)
    # The largest value is either in the first sample (it exceeds all m) or in the second.
    for u, count in enumerate(rank_counts(n - 1, m)):
        counts[u + m] += count
    for u, count in enumerate(rank_counts(n, m - 1)):
        counts[u] += count
    return tuple(counts)


@cache
def signed_rank_counts(n: int) -> tuple[int, ...]:
    """Count the sign assignments of n paired differences by the signed-rank statistic T."""
    counts = [1]
    for rank in range(1, n + 1):
        extended = [0] * (len(counts) + rank)
        for total, count in enumerate(counts):
            extended[total] += count
            extended[total + rank] += count
        counts = extended
    return tuple(counts)


def order_statistic_rank(counts: tuple[int, ...], size: int, level: float) -> tuple[int, float]:
    """Return k and the coverage of [x_(k), x_(size+1-k)] for a null count distribution."""
    total = sum(counts)
    k, below = 1, counts[0]
    while 2 * (k + 1) <= size + 1 and 1 - 2 * (below + counts[k]) / total >= level:
        below += counts[k]
        k += 1
    return k, 1 - 2 * below / total


@cache
def rank_interval(n: int, m: int, level: float = CONFIDENCE) -> tuple[int, float]:
    """Exact Mann-Whitney rank and coverage for n against m independent rounds."""
    if n < 1 or m < 1:
        raise ValueError("Intervals require nonempty samples")
    return order_statistic_rank(rank_counts(n, m), n * m, level)


@cache
def signed_rank_interval(n: int, level: float = CONFIDENCE) -> tuple[int, float]:
    """Exact Wilcoxon signed-rank rank and coverage for n paired rounds."""
    if n < 1:
        raise ValueError("Intervals require nonempty samples")
    return order_statistic_rank(signed_rank_counts(n), n * (n + 1) // 2, level)


def interval_row(
    point: float, ordered: list[float], rank: tuple[int, float], method: str
) -> dict[str, Any]:
    k, coverage = rank
    return {
        "ratio": math.exp(point),
        "ci95": [math.exp(ordered[k - 1]), math.exp(ordered[-k])],
        "ci_level": coverage,
        "ci_method": method,
    }


def compare_independent(candidate: list[float], baseline: list[float]) -> dict[str, Any]:
    """Compare round medians of separate processes (A/A and competitor arms).

    The ratio is the two-sample Hodges-Lehmann estimate. The interval is the
    exact Mann-Whitney interval over all rounds.
    """
    left = [math.log(value) for value in candidate]
    right = [math.log(value) for value in baseline]
    differences = sorted(x - y for x in left for y in right)
    rank = rank_interval(len(left), len(right))
    return interval_row(statistics.median(differences), differences, rank, "mann-whitney")


def compare_paired(candidate: list[float], baseline: list[float]) -> dict[str, Any]:
    """Compare round medians of two implementations measured in the same processes.

    Round i of the candidate and round i of the baseline share one process.
    The ratio is the one-sample Hodges-Lehmann estimate of the per-round log
    ratios. The interval is the exact Wilcoxon signed-rank interval over
    their Walsh averages. It needs no independence between the two rows.
    """
    if len(candidate) != len(baseline) or not candidate:
        raise ValueError("A paired comparison requires matched nonempty rounds")
    ratios = [math.log(x / y) for x, y in zip(candidate, baseline, strict=True)]
    walsh = sorted(
        (ratios[i] + ratios[j]) / 2 for i in range(len(ratios)) for j in range(i, len(ratios))
    )
    rank = signed_rank_interval(len(ratios))
    return interval_row(statistics.median(walsh), walsh, rank, "signed-rank")


def quantile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("Quantiles require values")
    position = (len(ordered) - 1) * fraction
    below = math.floor(position)
    above = min(below + 1, len(ordered) - 1)
    return ordered[below] + (ordered[above] - ordered[below]) * (position - below)


def significant(interval: tuple[float, float], floor: float | None) -> bool:
    """The whole interval lies outside the band [1 / (1 + floor), 1 + floor]."""
    return floor is not None and (interval[0] > 1 + floor or interval[1] < 1 / (1 + floor))


def geomean(values: list[float]) -> float:
    if not values or any(value <= 0 for value in values):
        raise ValueError("Geometric means require positive ratios")
    return math.exp(statistics.fmean(math.log(value) for value in values))


def validate_effect(minimum_effect: float) -> None:
    if not math.isfinite(minimum_effect) or minimum_effect < 0:
        raise ValueError("The minimum effect must be a finite nonnegative fraction")


Series = dict[tuple[str, str, str], dict[int, list[float]]]
SizeSeries = dict[tuple[str, str, str], dict[int, list[int]]]


class Rounds:
    def __init__(self) -> None:
        self.data: Series = defaultdict(lambda: defaultdict(list))
        self.sizes: SizeSeries = defaultdict(lambda: defaultdict(list))
        self.details: dict[str, dict[str, Any]] = {}
        self.warnings: list[str] = []
        self.metas: dict[str, dict[str, Any]] = {}
        self.cpus: set[str] = set()


def add_samples(
    measurement: Measurement,
    arm: str,
    index: int,
    rounds: Rounds,
) -> None:
    for sample in measurement.samples:
        case = sample["case"]
        detail = {key: sample[key] for key in ("codec", "direction", "shape", "size")}
        if case in rounds.details and detail != rounds.details[case]:
            raise ValueError(f"Case metadata changed for {case}")
        rounds.details[case] = detail
        key = (arm, case, sample["impl"])
        rounds.data[key][index].append(sample["ns"] / sample["iters"])
        rounds.sizes[key][index].append(sample["out_len"])


def load_rounds(  # noqa: C901 — validate clusters before warnings
    raw: Path,
    arms: list[str],
    *,
    expected_round_count: int | None = None,
    corpus: dict[str, str] | None = None,
    expected_cpu: str | None = None,
) -> Rounds:
    loaded = Rounds()
    arm_cases: dict[str, set[tuple[str, str]]] = {}
    expected_rounds: set[int] | None = None
    for arm in arms:
        paths = sorted((raw / arm).glob("r*.jsonl"))
        if not paths:
            raise ValueError(f"No complete rounds for {arm}")
        rounds = {int(path.stem[1:]) for path in paths}
        if expected_rounds is not None and rounds != expected_rounds:
            raise ValueError("Arms have different round sets")
        if rounds != set(range(expected_round_count or len(rounds))):
            raise ValueError(f"Incomplete round set for {arm}: {sorted(rounds)}")
        expected_rounds = rounds
        for path in paths:
            measurement = parse(path, corpus=corpus)
            meta = measurement.meta
            if meta["arm"] != ("zc" if arm == "aa" else arm):
                raise ValueError(f"{path}: meta arm {meta['arm']} disagrees with {arm}")
            cpu = meta["cpu"]
            # Only the zc build's CPU is pinned exactly (zig -Dcpu); the
            # competitor toolchains report their own CPU naming.
            if expected_cpu is not None and arm in {"zc", "aa"} and cpu != expected_cpu:
                raise ValueError(f"{path}: the build CPU is {cpu}, not {expected_cpu}")
            loaded.cpus.add(cpu)
            recorded = {key: meta[key] for key in ("samples", "sample_ms", "suite", "seed")}
            if arm in loaded.metas and loaded.metas[arm] != recorded:
                raise ValueError(f"Meta changed within {arm}")
            loaded.metas[arm] = recorded
            cases = {(sample["case"], sample["impl"]) for sample in measurement.samples}
            if arm in arm_cases and cases != arm_cases[arm]:
                raise ValueError(f"Rounds have different case/implementation sets within {arm}")
            arm_cases[arm] = cases
            add_samples(measurement, arm, int(path.stem[1:]), loaded)
    # Implementation labels are arm-specific (zc carries zc+std, the
    # competitor arms carry their own name) and codec coverage differs
    # per arm (libdeflate/zlib-ng have no snappy), so there is no global
    # intersection: comparisons pair cells that exist, and an arm missing
    # a case is a warning, never a filter.
    union_cases = set.union(*[{case for case, _ in cases} for cases in arm_cases.values()])
    for arm, cases in arm_cases.items():
        arm_case_set = {case for case, _ in cases}
        if missing := union_cases - arm_case_set:
            warning = f"{arm}: no rows for {len(missing)} cases: " + ", ".join(sorted(missing))
            loaded.warnings.append(warning)
            logging.getLogger(__name__).warning("%s", warning)
    return loaded


def floor_group(detail: dict[str, Any]) -> str:
    return f"{detail['direction']}/{detail['size']}"


def analyze(  # noqa: C901, PLR0912 — the comparison matrix stays in one place
    raw: Path,
    arms: list[str],
    *,
    aa: str | None = "aa",
    minimum_effect: float = 0.0,
    expected_round_count: int | None = None,
    corpus: dict[str, str] | None = None,
    expected_cpu: str | None = None,
) -> dict[str, Any]:
    validate_effect(minimum_effect)
    loaded = load_rounds(
        raw,
        [*arms, *([aa] if aa else [])],
        expected_round_count=expected_round_count,
        corpus=corpus,
        expected_cpu=expected_cpu,
    )
    data, details, warnings = loaded.data, loaded.details, loaded.warnings
    cells: dict[tuple[str, str, str], tuple[list[float], list[int]]] = {}
    for key in sorted(data):
        rounds = data[key]
        values = round_medians([rounds[index] for index in sorted(rounds)])
        cells[key] = (values, outlier_rounds(values))
    outliers = [
        {
            "arm": arm,
            "case": case,
            "impl": impl,
            "round": index,
            "ratio": values[index] / statistics.median(values[:index] + values[index + 1 :]),
        }
        for (arm, case, impl), (values, flagged) in cells.items()
        for index in flagged
    ]

    rows: list[dict[str, Any]] = []

    def compare(  # noqa: PLR0917 — paired arm/implementation identifiers
        case: str,
        kind: str,
        candidate: str,
        candidate_impl: str,
        reference: str,
        reference_impl: str,
        reference_case: str | None = None,
    ) -> None:
        left = cells.get((candidate, case, candidate_impl))
        right = cells.get((reference, reference_case or case, reference_impl))
        if left is None or right is None:
            return
        # One arm runs all of its implementations in the same processes.
        method = compare_paired if candidate == reference else compare_independent
        estimate = method(left[0], right[0])
        rounds = min(len(left[0]), len(right[0]))
        rows.append(
            {
                "case": case,
                **details[case],
                "reference_case": reference_case or case,
                "comparison": kind,
                "arm": candidate,
                "reference": reference,
                "candidate_impl": candidate_impl,
                "reference_impl": reference_impl,
                "candidate_ns": statistics.median(left[0]),
                "baseline_ns": statistics.median(right[0]),
                **estimate,
                "outlier_rounds": {"candidate": left[1], "baseline": right[1]},
                "rounds": rounds,
                "evidence": "sufficient" if rounds >= MIN_ROUNDS else "insufficient",
                "floor_group": floor_group(details[case]),
            }
        )

    for case in sorted(details):
        detail = details[case]
        if aa:
            for impl in {i for a, c, i in cells if c == case and a == BASELINE_ARM}:
                compare(case, "A/A", aa, impl, BASELINE_ARM, impl)
        for arm in arms:
            if arm == BASELINE_ARM:
                # The in-binary competitor: the zc rows pair with the std rows
                # inside the same process.
                compare(case, "zc/std", arm, "zc", arm, "std")
            else:
                # Cross-binary: the competitor arm's row against the zc row.
                compare(case, f"{arm}/zc", arm, arm, BASELINE_ARM, "zc")
        # The paired flate reference: each container against the flate row of
        # the same implementation in the same processes (code-layout noise is
        # shared). Rows pair on (arm, impl) across the two cases.
        if detail["codec"] in {"gzip", "zlib"}:
            flate_case = case.replace(f"{detail['codec']}/", "flate/", 1)
            if flate_case in details:
                for arm in [aa, *arms]:
                    if arm is None:
                        continue
                    # The zc binary (and its A/A duplicate) carries two
                    # implementations; every other arm carries its own name.
                    impls = ("zc", "std") if arm in {"zc", "aa"} else (arm,)
                    for impl in impls:
                        compare(
                            case,
                            "container/flate",
                            arm,
                            impl,
                            arm,
                            impl,
                            reference_case=flate_case,
                        )
    # Compressed sizes: the median produced length per cell (compress rows).
    sizes = []
    for (arm, case, impl), rounds in sorted(loaded.sizes.items()):
        if details[case]["direction"] != "compress":
            continue
        values = [statistics.median(rounds[index]) for index in sorted(rounds)]
        sizes.append(
            {
                "arm": arm,
                "case": case,
                "impl": impl,
                "bytes": statistics.median(values),
                "ratio": statistics.median(values) / details[case]["size"],
            }
        )
    result = summarize(rows, warnings, minimum_effect)
    result["outliers"] = outliers
    result["cpu"] = {"models": sorted(loaded.cpus)}
    result["sizes"] = sizes
    return result


def summarize(
    rows: list[dict[str, Any]], warnings: list[str], minimum_effect: float
) -> dict[str, Any]:
    departures: dict[str, list[float]] = defaultdict(list)
    for row in rows:
        if row["comparison"] == "A/A":
            departures[row["floor_group"]].append(abs(math.log(row["ratio"])))
    noise_floors = {
        group: math.expm1(quantile(values, FLOOR_QUANTILE)) for group, values in departures.items()
    }
    if any(row["evidence"] == "insufficient" for row in rows):
        warnings.append(
            f"Fewer than {MIN_ROUNDS} rounds: insufficient evidence."
            " Significance marks are disabled."
        )
    groups: dict[tuple[str, str, str, str], list[float]] = defaultdict(list)
    for row in rows:
        floor = noise_floors.get(row["floor_group"])
        row["noise_floor"] = floor
        row["minimum_effect"] = minimum_effect
        row["significant"] = (
            row["comparison"] != "A/A"
            and row["evidence"] == "sufficient"
            and significant(
                tuple(row["ci95"]),
                max(floor, minimum_effect) if floor is not None else None,
            )
        )
        groups[row["comparison"], row["arm"], row["codec"], row["direction"]].append(row["ratio"])
    summaries = [
        {
            "comparison": key[0],
            "arm": key[1],
            "codec": key[2],
            "direction": key[3],
            "geomean": geomean(values),
            "cases": len(values),
        }
        for key, values in sorted(groups.items())
    ]
    return {
        "noise_floors": noise_floors,
        "floor_quantile": FLOOR_QUANTILE,
        "minimum_effect": minimum_effect,
        "rows": rows,
        "groups": summaries,
        "warnings": warnings,
    }
