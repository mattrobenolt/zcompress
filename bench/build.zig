const std = @import("std");
const Build = std.Build;

// The bench harness's vendor build root (bench/README.md, "Arms"): fetches the
// pinned C-competitor release tarballs through zig — url+hash in
// bench/build.zig.zon, hash-verified by zig's fetcher — and materializes each
// verified tree under bench/zig-out/bench-src/<name>/ for the harness's
// zig-cc/cmake builds (bench/zcompress_bench/build.py). `dep.path(...)` is the
// hand-off, exactly as in ztls's conformance build; the tarballs carry no
// build.zig, so there is nothing to import.
//
// It is a separate build root on purpose: a `b.lazyDependency` call in the
// repo root's build.zig would mark the dependency needed at configure time,
// and the build runner fetches every marked dependency on any invocation —
// `zig build test` included. The fetch trigger is the call site, not the
// requested step, so the call site lives here, where only `zig build
// bench-vendor` reaches it.
pub fn build(b: *Build) void {
    const step = b.step(
        "bench-vendor",
        "Materialize the pinned bench competitor sources (zig-out/bench-src/)",
    );
    inline for (.{ "libdeflate", "zlibng", "googlesnappy", "zstd" }) |name| {
        if (b.lazyDependency(name, .{})) |dep| {
            const install = b.addInstallDirectory(.{
                .source_dir = dep.path("."),
                .install_dir = .{ .custom = "bench-src" },
                .install_subdir = name,
            });
            step.dependOn(&install.step);
        }
    }
}
