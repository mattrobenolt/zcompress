const std = @import("std");
const Build = std.Build;
const comptimePrint = std.fmt.comptimePrint;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `--fuzz` test runs need the default test runner (the server protocol
    // that ztest's `.mode = .simple` skips), so ztest is only used for
    // normal test runs.
    const fuzz_mode =
        b.option(bool, "fuzz", "Enable fuzzing (uses the default test runner)") orelse false;

    // fastmem: the blessed memory-copy primitive for every codec
    // (docs/zcompress-plan.md, Architecture).
    const fastmem_dep = b.dependency("fastmem", .{
        .target = target,
        .optimize = optimize,
    });
    const fastmem_mod = fastmem_dep.module("fastmem");

    // ONE module, `zcompress`, rooted at src/root.zig. Codecs are
    // namespaces under it (`zcompress.snappy`, `zcompress.flate`); the
    // codec-agnostic shares in `src/internal/` are reached by relative
    // import, never a module import and never re-exported. A codec lifts
    // out of the repo with its directory plus `src/internal/` in tow
    // (docs/zcompress-plan.md, "Architecture").
    const zcompress_mod = b.addModule("zcompress", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zcompress_mod.addImport("fastmem", fastmem_mod);

    // ztest: plain-text test runner. Lazy — only fetched when the test step
    // is actually built, not when consumers use zcompress as a dependency.
    const ztest_dep = b.lazyDependency("ztest", .{});
    const test_runner: ?Build.Step.Compile.TestRunner = if (fuzz_mode) null else if (ztest_dep) |z|
        .{ .path = z.path("src/test_runner.zig"), .mode = .simple }
    else
        null;
    const test_step = b.step("test", "Run unit tests");

    // Example CLIs: one per codec (examples/), sharing examples/cli.zig.
    // The framing decision per codec lives in its example file, and both
    // consume the one module through its namespaces. Run:
    //   zig build example-snappy -- encode README.md > out
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("examples/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    inline for (.{ "snappy", "flate", "gzip", "zlib", "zstd" }) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(comptimePrint("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cli", .module = cli_mod },
                .{ .name = "zcompress", .module = zcompress_mod },
            },
        });
        const example = b.addExecutable(.{
            .name = name,
            .root_module = mod,
        });
        const run = b.addRunArtifact(example);
        run.has_side_effects = true;
        if (b.args) |args| run.addArgs(args);
        const example_step = b.step(
            comptimePrint("example-{s}", .{name}),
            comptimePrint("Run the {s} example CLI (encode|decode [FILE|-])", .{name}),
        );
        example_step.dependOn(&run.step);
        const example_tests = b.addTest(.{
            .root_module = mod,
            .test_runner = test_runner,
        });
        const run_example_tests = b.addRunArtifact(example_tests);
        run_example_tests.has_side_effects = true;
        test_step.dependOn(&run_example_tests.step);
    }

    // External-oracle harness (src/flate/oracle.zig): decodes one stream from
    // a file into a caller-sized buffer, for the `just flate-oracle` lane.
    // Installed, not part of the module surface or the test/check steps.
    const flate_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/flate/oracle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcompress", .module = zcompress_mod },
        },
    });
    const flate_oracle = b.addExecutable(.{
        .name = "flate-oracle",
        .root_module = flate_oracle_mod,
    });
    const install_flate_oracle = b.addInstallArtifact(flate_oracle, .{});
    const flate_oracle_step = b.step(
        "flate-oracle-harness",
        "Install the flate oracle-lane harness (zig-out/bin/flate-oracle)",
    );
    flate_oracle_step.dependOn(&install_flate_oracle.step);

    // External-oracle harness (src/gzip/oracle.zig): decodes one member from
    // a file into a caller-sized buffer (and encodes an input at a chosen
    // level), for the `just gzip-oracle` lane. Installed, not part of the
    // module surface or the test/check steps.
    const gzip_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/gzip/oracle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcompress", .module = zcompress_mod },
        },
    });
    const gzip_oracle = b.addExecutable(.{
        .name = "gzip-oracle",
        .root_module = gzip_oracle_mod,
    });
    const install_gzip_oracle = b.addInstallArtifact(gzip_oracle, .{});
    const gzip_oracle_step = b.step(
        "gzip-oracle-harness",
        "Install the gzip oracle-lane harness (zig-out/bin/gzip-oracle)",
    );
    gzip_oracle_step.dependOn(&install_gzip_oracle.step);

    // External-oracle harness (src/zlib/oracle.zig): decodes one stream from
    // a file into a caller-sized buffer (and encodes an input at a chosen
    // level), for the `just zlib-oracle` lane. Installed, not part of the
    // module surface or the test/check steps.
    const zlib_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/zlib/oracle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcompress", .module = zcompress_mod },
        },
    });
    const zlib_oracle = b.addExecutable(.{
        .name = "zlib-oracle",
        .root_module = zlib_oracle_mod,
    });
    const install_zlib_oracle = b.addInstallArtifact(zlib_oracle, .{});
    const zlib_oracle_step = b.step(
        "zlib-oracle-harness",
        "Install the zlib oracle-lane harness (zig-out/bin/zlib-oracle)",
    );
    zlib_oracle_step.dependOn(&install_zlib_oracle.step);

    // Unit tests: one test executable over the one module. The codec
    // suites, their shared-layer consumers, and the barrel's own tests all
    // land in one binary; ztest still reports each test by name.
    const zcompress_tests = b.addTest(.{
        .root_module = zcompress_mod,
        .test_runner = test_runner,
    });
    const run_zcompress_tests = b.addRunArtifact(zcompress_tests);
    run_zcompress_tests.has_side_effects = true; // always run tests, don't cache
    test_step.dependOn(&run_zcompress_tests.step);

    // Compile-only gate: compiles the module's test binary without running
    // it, for cross-target checks (the portable fallbacks only compile on
    // non-native targets):
    //   zig build check -Dtarget=x86_64-linux
    const check_step = b.step("check", "Compile the tests without running (cross-target gate)");
    check_step.dependOn(&zcompress_tests.step);

    // The fleet benchmark driver (bench/README.md): one binary carrying the
    // zcompress one-shot rows and the std.compress.flate competitor rows,
    // cross-built per fleet target by the bench/ harness and uploaded to the
    // boxes. `-Drev` stamps the measured revision into the meta record.
    const rev =
        b.option([]const u8, "rev", "Revision label for the fleet bench driver") orelse "dev";
    const fleet_options = b.addOptions();
    fleet_options.addOption([]const u8, "rev", rev);
    const fleet_bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/zig/bench_zcompress.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcompress", .module = zcompress_mod },
            .{ .name = "fastmem", .module = fastmem_mod },
        },
    });
    fleet_bench_mod.addOptions("build_options", fleet_options);
    const fleet_bench = b.addExecutable(.{
        .name = "bench-zcompress",
        .root_module = fleet_bench_mod,
    });
    const install_fleet_bench = b.addInstallArtifact(fleet_bench, .{});
    const fleet_bench_step = b.step(
        "fleet-bench",
        "Install the fleet benchmark driver (zig-out/bin/bench-zcompress)",
    );
    fleet_bench_step.dependOn(&install_fleet_bench.step);

    // The fleet corpus generator (bench/README.md): deterministic,
    // byte-identical across hosts; writes bench/corpus/ (run from the repo
    // root): `zig build corpus`.
    const corpus_mod = b.createModule(.{
        .root_source_file = b.path("bench/zig/corpus.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcompress", .module = zcompress_mod },
            .{ .name = "fastmem", .module = fastmem_mod },
        },
    });
    const corpus_tool = b.addExecutable(.{
        .name = "corpus",
        .root_module = corpus_mod,
    });
    const run_corpus = b.addRunArtifact(corpus_tool);
    run_corpus.has_side_effects = true;
    if (b.args) |args| run_corpus.addArgs(args);
    const corpus_step = b.step(
        "corpus",
        "Regenerate the committed fleet corpus (bench/corpus/)",
    );
    corpus_step.dependOn(&run_corpus.step);

    // Bench competitor sources (bench/README.md, "Arms"): the C arms build
    // libdeflate, zlib-ng, and google/snappy from the release tarballs pinned
    // by url+hash in bench/build.zig.zon. The bench tool's own build root
    // fetches them (zig's fetcher verifies each hash) and installs the trees
    // under bench/zig-out/bench-src/<name>/ for the harness's zig-cc/cmake
    // builds (the ztls conformance precedent: dep.path(...) straight out of
    // the fetched tree — no module import, no build.zig inside the dep). This
    // step only delegates to it, and the dependency deliberately stays out of
    // THIS build graph: a `b.lazyDependency` call here would mark it needed at
    // configure time, and the build runner fetches every marked dependency on
    // any invocation, `zig build test` included — the fetch trigger is the
    // call site, not the requested step.
    const bench_vendor_step = b.step(
        "bench-vendor",
        "Materialize the pinned bench competitor sources (bench/zig-out/bench-src/)",
    );
    const zig_exe: []const u8 = b.graph.zig_exe;
    const bench_vendor = b.addSystemCommand(&.{ zig_exe, "build", "bench-vendor" });
    bench_vendor.setCwd(b.path("bench"));
    bench_vendor_step.dependOn(&bench_vendor.step);

    // Benchmarks. The benchmark dependency is lazy: b.lazyImport fetches it
    // on the first `zig build bench` and returns null meanwhile, so the
    // codec modules and the test step build without it.
    if (b.lazyImport(@This(), "benchmark")) |benchmark| {
        // The dependency is lazy in the zon, so it must come through
        // lazyDependency. lazyImport already confirmed it is fetched, so
        // this call returns non-null.
        const benchmark_dep = b.lazyDependency("benchmark", .{
            .target = target,
            .optimize = optimize,
        }).?;

        // zig-benchmark's addRunTest injects @import("benchmark") into the
        // bench root module and generates the runner executable.
        const snappy_bench_root = b.createModule(.{
            .root_source_file = b.path("src/snappy/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
                .{ .name = "fastmem", .module = fastmem_mod },
            },
        });
        const run_snappy_bench = benchmark.addRunTest(b, .{
            .dependency = benchmark_dep,
            .root_module = snappy_bench_root,
        });
        if (b.args) |args| run_snappy_bench.addArgs(args);

        const flate_bench_root = b.createModule(.{
            .root_source_file = b.path("src/flate/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
                .{ .name = "fastmem", .module = fastmem_mod },
            },
        });
        const run_flate_bench = benchmark.addRunTest(b, .{
            .dependency = benchmark_dep,
            .root_module = flate_bench_root,
        });
        if (b.args) |args| run_flate_bench.addArgs(args);

        const gzip_bench_root = b.createModule(.{
            .root_source_file = b.path("src/gzip/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
                .{ .name = "fastmem", .module = fastmem_mod },
            },
        });
        const run_gzip_bench = benchmark.addRunTest(b, .{
            .dependency = benchmark_dep,
            .root_module = gzip_bench_root,
        });
        if (b.args) |args| run_gzip_bench.addArgs(args);

        const zlib_bench_root = b.createModule(.{
            .root_source_file = b.path("src/zlib/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcompress", .module = zcompress_mod },
                .{ .name = "fastmem", .module = fastmem_mod },
            },
        });
        const run_zlib_bench = benchmark.addRunTest(b, .{
            .dependency = benchmark_dep,
            .root_module = zlib_bench_root,
        });
        if (b.args) |args| run_zlib_bench.addArgs(args);

        const bench_step = b.step("bench", "Run codec benchmarks (use -Doptimize=ReleaseFast)");
        bench_step.dependOn(&run_snappy_bench.step);
        bench_step.dependOn(&run_flate_bench.step);
        bench_step.dependOn(&run_gzip_bench.step);
        bench_step.dependOn(&run_zlib_bench.step);
    }
}
