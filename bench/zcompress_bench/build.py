"""Source resolution and content-addressed cross builds for the five arms.

Every arm cross-builds on this host; the boxes only execute. The zc arm is
`zig build fleet-bench` from the measured source tree. The klauspost arm is
`go build` of bench/drivers/klauspost (the module pins klauspost/compress to
the research's local checkout commit). The libdeflate, zlib-ng, and
google/snappy arms fetch their pinned release tarballs (sha256 below) and
compile with `zig cc`/`zig c++` (zlib-ng and google/snappy configure through
cmake with zig toolchain wrappers; the flake provides cmake and go).
"""

import errno
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ec2bench.config import Config
from ec2bench.parallel import Outcome, parallel
from ec2bench.runs import git

ARMS = ("zc", "klauspost", "libdeflate", "zlibng", "googlesnappy")
# The competitor pins (docs/research/containers-notes.md names the sources;
# google/snappy is docs/zcompress-plan.md's pinned snappy competitor).
LIBDEFLATE_VERSION = "v1.26"
LIBDEFLATE_URL = (
    f"https://github.com/ebiggers/libdeflate/archive/refs/tags/{LIBDEFLATE_VERSION}.tar.gz"
)
LIBDEFLATE_SHA256 = "bba03fffc5538576213675ce6968fcff6ce2e67d82e4d5febea2d05f9f13cf85"
ZLIBNG_VERSION = "2.3.3"
ZLIBNG_URL = f"https://github.com/zlib-ng/zlib-ng/archive/refs/tags/{ZLIBNG_VERSION}.tar.gz"
ZLIBNG_SHA256 = "f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1"
SNAPPY_VERSION = "1.3.1"
SNAPPY_URL = f"https://github.com/google/snappy/archive/refs/tags/{SNAPPY_VERSION}.tar.gz"
SNAPPY_SHA256 = "893f708a0bf4b5529d555ffcee390e940e932fcf90261f682604475a76cd0247"
# The local research checkout (~/code/klauspost-compress), pinned in go.mod.
KLAUSPOST_VERSION = "v1.18.1-0.20250402062133-8df4d013ff17"

GO_ARCHES = {"x86_64": "amd64", "arm64": "arm64"}


@dataclass(frozen=True)
class Source:
    revision: str
    path: Path
    source_hash: str


@dataclass(frozen=True)
class Build:
    arm: str
    target: str
    prefix: Path
    binary: Path
    cache_key: str

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.binary.read_bytes()).hexdigest()


def source_hash(root: Path) -> str:
    digest = hashlib.sha256()
    files = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root,
        check=True,
        capture_output=True,
        timeout=60,
    ).stdout.split(b"\0")
    for name in sorted(set(files)):
        if not name:
            continue
        path = root / os.fsdecode(name)
        digest.update(name + b"\0")
        if path.is_symlink():
            digest.update(b"link:" + os.fsencode(path.readlink()))
        elif path.is_file():
            digest.update(str(path.stat().st_mode).encode() + b"\0" + path.read_bytes())
        else:
            digest.update(b"missing")
    return digest.hexdigest()


def resolve(config: Config, revision: str) -> Source:
    if revision == "WORKTREE":
        return Source(revision, config.root, source_hash(config.root))
    sha = git(config.root, "rev-parse", "--verify", f"{revision}^{{commit}}")
    path = config.cache_dir / "src" / sha
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        git(config.root, "worktree", "add", "--detach", str(path), sha)
    if git(path, "status", "--porcelain"):
        raise ValueError(f"Cached source worktree is dirty: {path}")
    return Source(revision, path, sha)


def hash_paths(paths: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path).encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def tool_version(args: list[str]) -> str:
    return subprocess.run(
        args, check=True, capture_output=True, text=True, timeout=60
    ).stdout.strip()


def vendor(config: Config, name: str, url: str, sha256: str) -> Path:
    """Fetch and extract a pinned release tarball into the cache, once."""
    directory = config.cache_dir / "vendor"
    tarball = directory / f"{name}.tar.gz"
    extracted = directory / f"{name}-src"
    if extracted.exists():
        return extracted
    directory.mkdir(parents=True, exist_ok=True)
    if not tarball.exists() or hashlib.sha256(tarball.read_bytes()).hexdigest() != sha256:
        with urllib.request.urlopen(url, timeout=120) as response:  # noqa: S310 — pinned URL+sha
            tarball.write_bytes(response.read())
    if hashlib.sha256(tarball.read_bytes()).hexdigest() != sha256:
        raise ValueError(f"{tarball}: sha256 mismatch against the pinned {sha256}")
    with tarfile.open(tarball) as archive:
        archive.extractall(directory, filter="data")
    children = [child for child in directory.iterdir() if child.name.startswith(name)]
    roots = [child for child in children if child.is_dir() and child.name != f"{name}-src"]
    if len(roots) != 1:
        raise ValueError(f"{tarball}: expected one top-level directory")
    roots[0].rename(extracted)
    return extracted


def finalize(config: Config, key_data: list[Any], install: Any) -> Path:
    """Run install(temporary) once per cache key; the prefix is content-addressed."""
    key = hashlib.sha256(json.dumps(key_data).encode()).hexdigest()
    prefix = config.cache_dir / "build" / key
    if (prefix / "complete.json").exists():
        return prefix
    prefix.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="build-", dir=prefix.parent))
    try:
        install(temporary)
        (temporary / "complete.json").write_text(json.dumps({"key": key_data}))
        try:
            temporary.rename(prefix)
        except OSError as error:
            if (
                error.errno not in {errno.EEXIST, errno.ENOTEMPTY}
                or not (prefix / "complete.json").exists()
            ):
                raise
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return prefix


def checked(args: list[str], cwd: Path, log: Path, env: dict[str, str] | None = None) -> None:
    completed = subprocess.run(
        args, cwd=cwd, capture_output=True, text=True, timeout=1800, check=False, env=env
    )
    log.write_text(completed.stdout + completed.stderr)
    if completed.returncode:
        # The build directory is temporary: keep failed logs.
        kept = log.parent.parent / f"{log.parent.name}-{log.name}.failed"
        log.replace(kept)
        raise RuntimeError(f"Build failed; read {kept}: {completed.stderr[-2000:]}")


def build_zc(config: Config, source: Source, target: str, zig_version: str) -> Build:
    settings = config.targets[target]
    triple, cpu = settings["zig_target"], settings["zig_cpu"]
    key_data = ["zc", source.source_hash, triple, cpu, zig_version, source.revision, "v1"]

    def install(temporary: Path) -> None:
        checked(
            [
                "zig",
                "build",
                "fleet-bench",
                f"-Dtarget={triple}",
                f"-Dcpu={cpu}",
                "-Doptimize=ReleaseFast",
                f"-Drev={source.revision}",
                "--prefix",
                str(temporary),
            ],
            source.path,
            temporary / "build.log",
        )

    prefix = finalize(config, key_data, install)
    return Build("zc", target, prefix, prefix / "bin" / "bench-zcompress", sha_key(key_data))


def sha_key(key_data: list[Any]) -> str:
    return hashlib.sha256(json.dumps(key_data).encode()).hexdigest()


def build_klauspost(config: Config, target: str) -> Build:
    settings = config.targets[target]
    goarch = GO_ARCHES[settings["arch"]]
    driver = config.root / "bench" / "drivers" / "klauspost"
    driver_hash = hash_paths([driver / "main.go", driver / "go.mod", driver / "go.sum"])
    go_version = tool_version(["go", "version"])
    key_data = ["klauspost", driver_hash, goarch, go_version, KLAUSPOST_VERSION, "v1"]

    def install(temporary: Path) -> None:
        env = {
            **os.environ,
            "GOOS": "linux",
            "GOARCH": goarch,
            "CGO_ENABLED": "0",
            "GOFLAGS": "-mod=readonly",
            "GOMODCACHE": str(config.cache_dir / "gomod"),
            "GOCACHE": str(config.cache_dir / "gobuild"),
        }
        (temporary / "bin").mkdir()
        checked(
            ["go", "build", "-o", str(temporary / "bin" / "bench-klauspost"), "."],
            driver,
            temporary / "build.log",
            env=env,
        )

    prefix = finalize(config, key_data, install)
    return Build("klauspost", target, prefix, prefix / "bin" / "bench-klauspost", sha_key(key_data))


def target_flags(settings: dict[str, Any]) -> list[str]:
    """The cross target flags: the musl static triple plus the per-model CPU.

    zig cc's argument mapping takes -target as a separate argument but
    -mcpu only in the joined form (neither -target=x nor -mcpu x works).
    """
    return ["-target", settings["zig_target"], f"-mcpu={settings['zig_cpu']}"]


def cc_flags(settings: dict[str, Any]) -> list[str]:
    return [*target_flags(settings), "-O2", "-static"]


def build_libdeflate(config: Config, target: str, zig_version: str) -> Build:
    settings = config.targets[target]
    source = vendor(config, "libdeflate-1.26", LIBDEFLATE_URL, LIBDEFLATE_SHA256)
    driver = config.root / "bench" / "drivers" / "c"
    driver_hash = hash_paths([driver / "cbench.h", driver / "bench_libdeflate.c"])
    key_data = [
        "libdeflate",
        driver_hash,
        settings["zig_target"],
        settings["zig_cpu"],
        zig_version,
        LIBDEFLATE_VERSION,
        LIBDEFLATE_SHA256,
        "v1",
    ]

    def install(temporary: Path) -> None:
        (temporary / "bin").mkdir()
        arch_dir = "x86" if settings["arch"] == "x86_64" else "arm"
        arch_sources = sorted((source / "lib" / arch_dir).glob("*.c"))
        checked(
            [
                "zig",
                "cc",
                *cc_flags(settings),
                f'-DCBENCH_TARGET="{settings["zig_target"]}"',
                f'-DCBENCH_CPU="{settings["zig_cpu"]}"',
                f'-DZIG_VERSION="{zig_version}"',
                f'-DCOMPETITOR_VERSION="{LIBDEFLATE_VERSION}"',
                f"-I{source}",
                *[str(path) for path in sorted((source / "lib").glob("*.c"))],
                *[str(path) for path in arch_sources],
                str(driver / "bench_libdeflate.c"),
                "-o",
                str(temporary / "bin" / "bench-libdeflate"),
            ],
            config.root,
            temporary / "build.log",
        )

    prefix = finalize(config, key_data, install)
    return Build(
        "libdeflate", target, prefix, prefix / "bin" / "bench-libdeflate", sha_key(key_data)
    )


def build_zlibng(config: Config, target: str, zig_version: str) -> Build:
    settings = config.targets[target]
    source = vendor(config, "zlib-ng-2.3.3", ZLIBNG_URL, ZLIBNG_SHA256)
    driver = config.root / "bench" / "drivers" / "c"
    driver_hash = hash_paths([driver / "cbench.h", driver / "bench_zlibng.c"])
    key_data = [
        "zlibng",
        driver_hash,
        settings["zig_target"],
        settings["zig_cpu"],
        zig_version,
        ZLIBNG_VERSION,
        ZLIBNG_SHA256,
        "v1",
    ]

    def install(temporary: Path) -> None:
        # cmake wants a single compiler path: wrap the zig cc cross flags.
        wrapper = temporary / "zig-cc"
        wrapper.write_text(
            '#!/bin/sh\nexec zig cc {} "$@"\n'.format(" ".join(target_flags(settings)))
        )
        wrapper.chmod(0o755)
        library = temporary / "zlib-ng-build"
        checked(
            [
                "cmake",
                "-S",
                str(source),
                "-B",
                str(library),
                "-DCMAKE_SYSTEM_NAME=Linux",
                "-DCMAKE_SYSTEM_PROCESSOR="
                + ("aarch64" if settings["arch"] == "arm64" else "x86_64"),
                f"-DCMAKE_C_COMPILER={wrapper}",
                "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
                "-DZLIB_COMPAT=ON",
                "-DZLIB_ENABLE_TESTS=OFF",
                "-DBUILD_SHARED_LIBS=OFF",
                "-DWITH_GTEST=OFF",
                "-DCMAKE_BUILD_TYPE=Release",
            ],
            config.root,
            temporary / "cmake-configure.log",
        )
        checked(
            ["cmake", "--build", str(library), "-j", str(os.cpu_count() or 1)],
            config.root,
            temporary / "cmake-build.log",
        )
        (temporary / "bin").mkdir()
        checked(
            [
                "zig",
                "cc",
                *cc_flags(settings),
                f'-DCBENCH_TARGET="{settings["zig_target"]}"',
                f'-DCBENCH_CPU="{settings["zig_cpu"]}"',
                f'-DZIG_VERSION="{zig_version}"',
                f'-DCOMPETITOR_VERSION="{ZLIBNG_VERSION}"',
                f"-I{library}",
                f"-I{source}",
                str(driver / "bench_zlibng.c"),
                str(library / "libz.a"),
                "-o",
                str(temporary / "bin" / "bench-zlibng"),
            ],
            config.root,
            temporary / "build.log",
        )

    prefix = finalize(config, key_data, install)
    return Build("zlibng", target, prefix, prefix / "bin" / "bench-zlibng", sha_key(key_data))


def build_googlesnappy(config: Config, target: str, zig_version: str) -> Build:
    settings = config.targets[target]
    source = vendor(config, "snappy-1.3.1", SNAPPY_URL, SNAPPY_SHA256)
    driver = config.root / "bench" / "drivers" / "google-snappy"
    harness = config.root / "bench" / "drivers" / "c"
    driver_hash = hash_paths([driver / "bench_snappy.cc", harness / "cbench.h"])
    key_data = [
        "googlesnappy",
        driver_hash,
        settings["zig_target"],
        settings["zig_cpu"],
        zig_version,
        SNAPPY_VERSION,
        SNAPPY_SHA256,
        "v1",
    ]

    def install(temporary: Path) -> None:
        # cmake wants single compiler paths: wrap the zig cc / zig c++ cross
        # flags. The driver is a C++ translation unit (the google/snappy API
        # is C++), built by the same wrapper's c++ mode.
        cc = temporary / "zig-cc"
        cc.write_text('#!/bin/sh\nexec zig cc {} "$@"\n'.format(" ".join(target_flags(settings))))
        cc.chmod(0o755)
        cxx = temporary / "zig-cxx"
        cxx.write_text('#!/bin/sh\nexec zig c++ {} "$@"\n'.format(" ".join(target_flags(settings))))
        cxx.chmod(0o755)
        library = temporary / "snappy-build"
        checked(
            [
                "cmake",
                "-S",
                str(source),
                "-B",
                str(library),
                "-DCMAKE_SYSTEM_NAME=Linux",
                "-DCMAKE_SYSTEM_PROCESSOR="
                + ("aarch64" if settings["arch"] == "arm64" else "x86_64"),
                f"-DCMAKE_C_COMPILER={cc}",
                f"-DCMAKE_CXX_COMPILER={cxx}",
                "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
                "-DSNAPPY_BUILD_TESTS=OFF",
                "-DSNAPPY_BUILD_BENCHMARKS=OFF",
                "-DBUILD_SHARED_LIBS=OFF",
                "-DCMAKE_BUILD_TYPE=Release",
            ],
            config.root,
            temporary / "cmake-configure.log",
        )
        checked(
            ["cmake", "--build", str(library), "-j", str(os.cpu_count() or 1)],
            config.root,
            temporary / "cmake-build.log",
        )
        (temporary / "bin").mkdir()
        checked(
            [
                "zig",
                "c++",
                *cc_flags(settings),
                f'-DCBENCH_TARGET="{settings["zig_target"]}"',
                f'-DCBENCH_CPU="{settings["zig_cpu"]}"',
                f'-DZIG_VERSION="{zig_version}"',
                f'-DCOMPETITOR_VERSION="{SNAPPY_VERSION}"',
                f"-I{library}",
                f"-I{source}",
                str(driver / "bench_snappy.cc"),
                str(library / "libsnappy.a"),
                "-o",
                str(temporary / "bin" / "bench-googlesnappy"),
            ],
            config.root,
            temporary / "build.log",
        )

    prefix = finalize(config, key_data, install)
    return Build(
        "googlesnappy", target, prefix, prefix / "bin" / "bench-googlesnappy", sha_key(key_data)
    )


def build_all(config: Config, source: Source, targets: list[str]) -> dict[str, Outcome[Build]]:
    zig_version = tool_version(["zig", "version"])
    pairs = {f"{arm}/{target}": (arm, target) for arm in ARMS for target in targets}

    def build(name: str) -> Build:
        arm, target = pairs[name]
        if arm == "zc":
            return build_zc(config, source, target, zig_version)
        if arm == "klauspost":
            return build_klauspost(config, target)
        if arm == "libdeflate":
            return build_libdeflate(config, target, zig_version)
        if arm == "zlibng":
            return build_zlibng(config, target, zig_version)
        return build_googlesnappy(config, target, zig_version)

    return parallel(pairs, build, workers=os.cpu_count() or 1)


def arm_revisions(source: Source) -> dict[str, str]:
    """The revision label of each arm, for the report's arm table."""
    return {
        "zc": source.revision,
        "klauspost": KLAUSPOST_VERSION,
        "libdeflate": LIBDEFLATE_VERSION,
        "zlibng": ZLIBNG_VERSION,
        "googlesnappy": SNAPPY_VERSION,
    }


def provenance(source: Source, results: dict[str, Outcome[Build]]) -> dict[str, Any]:
    return {
        "source": {
            "revision": source.revision,
            "hash": source.source_hash,
            "path": str(source.path),
        },
        "competitors": {
            "klauspost": {"module": "github.com/klauspost/compress", "version": KLAUSPOST_VERSION},
            "libdeflate": {"version": LIBDEFLATE_VERSION, "sha256": LIBDEFLATE_SHA256},
            "zlib-ng": {"version": ZLIBNG_VERSION, "sha256": ZLIBNG_SHA256},
            "google-snappy": {"version": SNAPPY_VERSION, "sha256": SNAPPY_SHA256},
        },
        "builds": {
            key: {
                "cache_key": result.value.cache_key,
                "binary_sha256": result.value.sha256,
            }
            if result.value
            else {"error": str(result.error)}
            for key, result in results.items()
        },
    }
