"""SSH transport with bounded commands and multiplexed connections."""

import hashlib
import shlex
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path


class RemoteError(subprocess.SubprocessError):
    """A transport error with remote diagnostics."""


def checked(args: list[str], *, timeout: float) -> str:
    try:
        return subprocess.run(
            args, check=True, capture_output=True, text=True, timeout=timeout
        ).stdout
    except subprocess.CalledProcessError as error:
        raise RemoteError(f"{error}: {error.stderr[-2000:] if error.stderr else ''}") from error
    except subprocess.TimeoutExpired as error:
        raise RemoteError(f"{error}: {error.stderr[-2000:] if error.stderr else ''}") from error


class Box:
    def __init__(
        self, instance_id: str, host: str, key: Path, cache: Path, *, user: str = "root"
    ) -> None:
        self.instance_id = instance_id
        self.host = host
        self.user = user
        cache.mkdir(parents=True, exist_ok=True)
        # Unix socket paths have a short limit. Hash the repository-specific directory.
        digest = hashlib.sha256(str(cache.resolve()).encode()).hexdigest()[:12]
        socket = f"/tmp/ec2bench-{digest}-%C"  # noqa: S108 — SSH includes user/host in %C
        self.options = [
            "-i",
            str(key),
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "ServerAliveInterval=15",
            "-o",
            "ServerAliveCountMax=3",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            f"HostKeyAlias={instance_id}",
            "-o",
            "ControlMaster=auto",
            "-o",
            "ControlPersist=120",
            "-o",
            f"ControlPath={socket}",
            "-o",
            f"UserKnownHostsFile={cache / 'known_hosts'}",
        ]

    @property
    def destination(self) -> str:
        return f"{self.user}@{self.host}"

    def run(
        self, command: str, *, timeout: float = 120, stream: Callable[[str], None] | None = None
    ) -> str:
        args = ["ssh", *self.options, self.destination, command]
        if stream is None:
            return checked(args, timeout=timeout)
        output: list[str] = []
        with subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        ) as process:
            timed_out = threading.Event()

            def kill() -> None:
                timed_out.set()
                process.kill()

            timer = threading.Timer(timeout, kill)
            timer.start()
            try:
                if process.stdout is not None:
                    for line in process.stdout:
                        output.append(line)
                        stream(line.rstrip())
                process.wait()
            finally:
                timer.cancel()
            if timed_out.is_set():
                raise subprocess.TimeoutExpired(args, timeout)
            if process.returncode:
                raise RemoteError(f"SSH exit {process.returncode}: {''.join(output)[-2000:]}")
        return "".join(output)

    def ready(self, image_version: str, *, timeout: float = 900) -> None:
        deadline = time.monotonic() + timeout
        last_error = "image marker absent"
        while time.monotonic() < deadline:
            try:
                actual = self.run("cat /etc/bench-image", timeout=15).strip()
                if actual == image_version:
                    return
                last_error = f"image version {actual!r}, expected {image_version!r}"
            except subprocess.SubprocessError as error:
                last_error = str(error)
            time.sleep(5)
        raise TimeoutError(f"{self.instance_id}: SSH/image deadline: {last_error}")

    def upload(self, source: Path, destination: str) -> None:
        self.run(f"mkdir -p {shlex.quote(destination)}")
        self._rsync(str(source), f"{self.destination}:{destination}/")

    def download(self, source: str, destination: Path) -> None:
        destination.mkdir(parents=True, exist_ok=True)
        self._rsync(f"{self.destination}:{source}/", str(destination) + "/")

    def _rsync(self, source: str, destination: str) -> None:
        checked(
            [
                "rsync",
                "-az",
                "--protect-args",
                "-e",
                shlex.join(["ssh", *self.options]),
                source,
                destination,
            ],
            timeout=300,
        )

    def shell(self, command: tuple[str, ...]) -> int:
        # ssh semantics: the words join with spaces and the remote shell parses
        # them, so `bench ssh t -- 'a | b'` and `bench ssh t -- ls -l` both work.
        tty = ["-t"] if not command or sys.stdin.isatty() else []
        remote = [" ".join(command)] if command else []
        argv = ["ssh", *self.options, *tty, self.destination, *remote]
        return subprocess.run(argv, check=False).returncode
