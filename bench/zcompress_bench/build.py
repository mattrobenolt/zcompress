"""Source resolution and content-addressed cross builds for the five arms.

Every arm cross-builds on this host; the boxes only execute. The zc arm is
`zig build fleet-bench` from the measured source tree. The klauspost arm is
`go build` of bench/drivers/klauspost (the module pins klauspost/compress to
the research's local checkout commit). The libdeflate, zlib-ng, and
google/snappy arms compile the release tarballs pinned by url+hash in
bench/build.zig.zon — the bench tool's own build root, which `zig build
bench-vendor` delegates to; it fetches and materializes them under
bench/zig-out/bench-src/ — with `zig cc`/`zig c++` (zlib-ng and google/snappy
configure through cmake with zig toolchain wrappers; the flake provides cmake
and go).
"""

import errno
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ec2bench.config import Config
from ec2bench.parallel import Outcome, parallel, progress
from ec2bench.runs import git

ARMS = ("zc", "klauspost", "libdeflate", "zlibng", "googlesnappy", "zstd-c")
# The competitor version labels (docs/research/containers-notes.md names the
# flate-family sources; google/snappy is docs/zcompress-plan.md's pinned
# snappy competitor; zstd v1.5.7 is the zstd notes' pinned tag,
# docs/research/zstd-notes.md §6.1). The content pins — the release-tarball
# url+hash — live in bench/build.zig.zon; `zig build bench-vendor`
# materializes the fetched trees.
LIBDEFLATE_VERSION = "v1.26"
ZLIBNG_VERSION = "2.3.3"
SNAPPY_VERSION = "1.3.1"
ZSTD_C_VERSION = "v1.5.7"
# The local research checkout (~/code/klauspost-compress), pinned in go.mod.
KLAUSPOST_VERSION = "v1.18.1-0.20250402062133-8df4d013ff17"
# The C-arm sources, as `zig build bench-vendor` installs them (the bench
# tool's own build root: bench/build.zig, bench/build.zig.zon).
VENDOR_ARMS = ("libdeflate", "zlibng", "googlesnappy", "zstd")
VENDOR_DIR = Path("bench") / "zig-out" / "bench-src"

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


@dataclass(frozen=True)
class Vendor:
    """One materialized competitor source tree and its content hash."""

    name: str
    path: Path
    tree_hash: str


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


def tree_hash(root: Path) -> str:
    """Content hash of a materialized vendor tree (names, modes, bytes)."""
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        digest.update(path.relative_to(root).as_posix().encode() + b"\0")
        if path.is_symlink():
            digest.update(b"link:" + os.fsencode(path.readlink()))
        elif path.is_file():
            digest.update(str(path.stat().st_mode).encode() + b"\0" + path.read_bytes())
        else:
            digest.update(b"dir")
    return digest.hexdigest()


def vendor(config: Config) -> dict[str, Vendor]:
    """Materialize the pinned competitor sources through zig's own fetcher.

    The pins are bench/build.zig.zon's lazy url+hash entries; `zig build
    bench-vendor` delegates to the bench tool's build root, which fetches each
    tarball through zig's own fetcher and installs the verified tree under
    bench/zig-out/bench-src/<name>/ (the ztls conformance precedent: the
    tool-local zon pins the tool's competitors). The harness never downloads
    or unpacks a tarball itself, and the root package's zon stays clean.
    """
    log = config.cache_dir / "build" / "bench-vendor.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    progress("vendor competitor sources")
    checked(["zig", "build", "bench-vendor"], config.root, log)
    vendors: dict[str, Vendor] = {}
    for name in VENDOR_ARMS:
        path = config.root / VENDOR_DIR / name
        if not path.is_dir():
            raise ValueError(f"bench-vendor did not materialize {path}")
        vendors[name] = Vendor(name, path, tree_hash(path))
    return vendors


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


def build_libdeflate(config: Config, source: Vendor, target: str, zig_version: str) -> Build:
    settings = config.targets[target]
    driver = config.root / "bench" / "drivers" / "c"
    driver_hash = hash_paths([driver / "cbench.h", driver / "bench_libdeflate.c"])
    key_data = [
        "libdeflate",
        driver_hash,
        settings["zig_target"],
        settings["zig_cpu"],
        zig_version,
        LIBDEFLATE_VERSION,
        source.tree_hash,
        "v2",
    ]

    def install(temporary: Path) -> None:
        (temporary / "bin").mkdir()
        arch_dir = "x86" if settings["arch"] == "x86_64" else "arm"
        arch_sources = sorted((source.path / "lib" / arch_dir).glob("*.c"))
        checked(
            [
                "zig",
                "cc",
                *cc_flags(settings),
                f'-DCBENCH_TARGET="{settings["zig_target"]}"',
                f'-DCBENCH_CPU="{settings["zig_cpu"]}"',
                f'-DZIG_VERSION="{zig_version}"',
                f'-DCOMPETITOR_VERSION="{LIBDEFLATE_VERSION}"',
                f"-I{source.path}",
                *[str(path) for path in sorted((source.path / "lib").glob("*.c"))],
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


def build_zlibng(config: Config, source: Vendor, target: str, zig_version: str) -> Build:
    settings = config.targets[target]
    driver = config.root / "bench" / "drivers" / "c"
    driver_hash = hash_paths([driver / "cbench.h", driver / "bench_zlibng.c"])
    key_data = [
        "zlibng",
        driver_hash,
        settings["zig_target"],
        settings["zig_cpu"],
        zig_version,
        ZLIBNG_VERSION,
        source.tree_hash,
        "v2",
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
                str(source.path),
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
                f"-I{source.path}",
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


def build_googlesnappy(config: Config, source: Vendor, target: str, zig_version: str) -> Build:
    settings = config.targets[target]
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
        source.tree_hash,
        "v2",
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
                str(source.path),
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
                f"-I{source.path}",
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


def build_zstdc(config: Config, source: Vendor, target: str, zig_version: str) -> Build:
    """The zstd-c arm: facebook/zstd's cmake (build/cmake) under a zig-cc
    wrapper, the zlib-ng pattern; the driver links the static libzstd."""
    settings = config.targets[target]
    driver = config.root / "bench" / "drivers" / "c"
    driver_hash = hash_paths([driver / "cbench.h", driver / "bench_zstd.c"])
    key_data = [
        "zstd-c",
        driver_hash,
        settings["zig_target"],
        settings["zig_cpu"],
        zig_version,
        ZSTD_C_VERSION,
        source.tree_hash,
        "v1",
    ]

    def install(temporary: Path) -> None:
        # cmake wants a single compiler path: wrap the zig cc cross flags.
        wrapper = temporary / "zig-cc"
        wrapper.write_text(
            '#!/bin/sh\nexec zig cc {} "$@"\n'.format(" ".join(target_flags(settings)))
        )
        wrapper.chmod(0o755)
        library = temporary / "zstd-build"
        checked(
            [
                "cmake",
                "-S",
                str(source.path / "build" / "cmake"),
                "-B",
                str(library),
                "-DCMAKE_SYSTEM_NAME=Linux",
                "-DCMAKE_SYSTEM_PROCESSOR="
                + ("aarch64" if settings["arch"] == "arm64" else "x86_64"),
                f"-DCMAKE_C_COMPILER={wrapper}",
                "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
                "-DZSTD_BUILD_PROGRAMS=OFF",
                "-DZSTD_BUILD_TESTS=OFF",
                "-DZSTD_BUILD_SHARED=OFF",
                "-DZSTD_BUILD_STATIC=ON",
                "-DZSTD_MULTITHREAD_SUPPORT=OFF",
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
        archives = sorted(library.glob("lib/libzstd*.a"))
        if not archives:
            raise RuntimeError(f"zstd cmake built no static library under {library}/lib")
        (temporary / "bin").mkdir()
        checked(
            [
                "zig",
                "cc",
                *cc_flags(settings),
                f'-DCBENCH_TARGET="{settings["zig_target"]}"',
                f'-DCBENCH_CPU="{settings["zig_cpu"]}"',
                f'-DZIG_VERSION="{zig_version}"',
                f'-DCOMPETITOR_VERSION="{ZSTD_C_VERSION}"',
                f"-I{source.path}/lib",
                str(driver / "bench_zstd.c"),
                str(archives[0]),
                "-o",
                str(temporary / "bin" / "bench-zstd-c"),
            ],
            config.root,
            temporary / "build.log",
        )

    prefix = finalize(config, key_data, install)
    return Build("zstd-c", target, prefix, prefix / "bin" / "bench-zstd-c", sha_key(key_data))


def build_all(
    config: Config, source: Source, targets: list[str]
) -> tuple[dict[str, Outcome[Build]], dict[str, Vendor]]:
    """Cross-build every arm for every target; the vendor pins ride along."""
    zig_version = tool_version(["zig", "version"])
    vendors = vendor(config)
    pairs = {f"{arm}/{target}": (arm, target) for arm in ARMS for target in targets}

    def build(name: str) -> Build:
        arm, target = pairs[name]
        match arm:
            case "zc":
                return build_zc(config, source, target, zig_version)
            case "klauspost":
                return build_klauspost(config, target)
            case "libdeflate":
                return build_libdeflate(config, vendors["libdeflate"], target, zig_version)
            case "zlibng":
                return build_zlibng(config, vendors["zlibng"], target, zig_version)
            case "googlesnappy":
                return build_googlesnappy(config, vendors["googlesnappy"], target, zig_version)
            case _:
                return build_zstdc(config, vendors["zstd"], target, zig_version)

    return parallel(pairs, build, workers=os.cpu_count() or 1), vendors


def arm_revisions(source: Source) -> dict[str, str]:
    """The revision label of each arm, for the report's arm table."""
    return {
        "zc": source.revision,
        "klauspost": KLAUSPOST_VERSION,
        "libdeflate": LIBDEFLATE_VERSION,
        "zlibng": ZLIBNG_VERSION,
        "googlesnappy": SNAPPY_VERSION,
        "zstd-c": ZSTD_C_VERSION,
    }


def provenance(
    source: Source, results: dict[str, Outcome[Build]], vendors: dict[str, Vendor]
) -> dict[str, Any]:
    return {
        "source": {
            "revision": source.revision,
            "hash": source.source_hash,
            "path": str(source.path),
        },
        "competitors": {
            "klauspost": {"module": "github.com/klauspost/compress", "version": KLAUSPOST_VERSION},
            "libdeflate": {
                "version": LIBDEFLATE_VERSION,
                "tree_sha256": vendors["libdeflate"].tree_hash,
            },
            "zlib-ng": {"version": ZLIBNG_VERSION, "tree_sha256": vendors["zlibng"].tree_hash},
            "google-snappy": {
                "version": SNAPPY_VERSION,
                "tree_sha256": vendors["googlesnappy"].tree_hash,
            },
            "zstd": {"version": ZSTD_C_VERSION, "tree_sha256": vendors["zstd"].tree_hash},
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
