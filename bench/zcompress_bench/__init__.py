"""Adapter registration."""

import click


def register(group: click.Group) -> None:
    from zcompress_bench.correctness import test_fleet
    from zcompress_bench.runner import analyze_run, run

    group.add_command(test_fleet)
    group.add_command(run)
    group.add_command(analyze_run)
