"""Independent tasks with a live status table."""

from collections.abc import Callable, Iterable
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextvars import ContextVar
from dataclasses import dataclass
from threading import Event, Lock

from rich.live import Live
from rich.table import Table

_progress: ContextVar[Callable[[str], None] | None] = ContextVar("progress", default=None)


_cancelled: ContextVar[Event | None] = ContextVar("cancelled", default=None)


def check_cancelled() -> None:
    if (event := _cancelled.get()) is not None and event.is_set():
        raise InterruptedError("Run interrupted")


def progress(message: str) -> None:
    check_cancelled()
    if callback := _progress.get():
        callback(message)


@dataclass
class Outcome[T]:
    value: T | None = None
    error: Exception | None = None


def parallel[T](
    names: Iterable[str], function: Callable[[str], T], *, workers: int | None = None
) -> dict[str, Outcome[T]]:
    states = dict.fromkeys(names, "pending")
    results: dict[str, Outcome[T]] = {}
    lock = Lock()
    cancelled = Event()

    def table() -> Table:
        result = Table("Task", "State")
        for name, state in states.items():
            result.add_row(name, state)
        return result

    with (
        Live(table(), refresh_per_second=4) as live,
        ThreadPoolExecutor(max_workers=workers) as pool,
    ):

        def update(name: str, message: str) -> None:
            with lock:
                states[name] = message
                live.update(table())

        def task(name: str) -> T:
            cancellation = _cancelled.set(cancelled)
            token = _progress.set(lambda message: update(name, message))
            try:
                progress("running")
                return function(name)
            finally:
                _progress.reset(token)
                _cancelled.reset(cancellation)

        futures = {pool.submit(task, name): name for name in states}
        try:
            for future in as_completed(futures):
                name = futures[future]
                try:
                    results[name] = Outcome(value=future.result())
                    update(name, "done")
                except Exception as error:  # noqa: BLE001 — isolate each remote task
                    results[name] = Outcome(error=error)
                    update(name, f"failed: {error}")
        except BaseException:
            cancelled.set()
            raise
    return results
