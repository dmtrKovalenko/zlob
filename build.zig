const std = @import("std");

// Parse version from build.zig.zon at comptime (single source of truth)
const zon = @import("build.zig.zon");
const version_string: []const u8 = zon.version;
const version = std.SemanticVersion.parse(version_string) catch @compileError("Invalid version in build.zig.zon");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // On Windows MSVC, don't link libc to avoid ___chkstk_ms vs __chkstk symbol
    // mismatch when MSVC's link.exe links the static library. All Zig code already
    // handles link_libc=false on Windows with proper stubs (walker uses std.fs,
    // zlob.zig/utils.zig stub out libc-only headers, c_lib.zig uses page_allocator).
    const is_windows_msvc = target.result.os.tag == .windows and
        target.result.abi == .msvc;

    // On Android, Zig cannot provide bionic libc headers/libraries for
    // cross-compilation. Android targets use link_libc=false and fall back
    // to std.fs-based iteration (same as Windows MSVC path).
    const is_android = target.result.abi == .android or target.result.abi == .androideabi;

    // On iOS/tvOS/watchOS/visionOS, Zig doesn't ship Apple mobile SDK headers
    // (unlike macOS where headers are bundled). These targets need link_libc=false.
    const is_apple_mobile = switch (target.result.os.tag) {
        .ios, .tvos, .watchos, .visionos => true,
        else => false,
    };

    const use_libc = !is_windows_msvc and !is_android and !is_apple_mobile;

    // Source directory option - allows overriding for Rust crate builds
    const src_dir = b.option([]const u8, "src-dir", "Source directory (default: src)") orelse "src";

    // Skip benchmarks option - useful for Rust crate builds that don't include bench/
    const skip_bench = b.option(bool, "skip-bench", "Skip building benchmark executables") orelse false;

    // Static-only option - skip building dynamic library. Useful for Rust crate builds
    // to avoid providing both dynamic and static libraries, force the build to only produce a single static lib
    const static_only = b.option(bool, "static-only", "Only build static library, skip dynamic library") orelse false;

    // Helper to create source paths
    const srcPath = struct {
        fn get(builder: *std.Build, dir: []const u8, file: []const u8) std.Build.LazyPath {
            const full_path = std.fmt.allocPrint(builder.allocator, "{s}/{s}", .{ dir, file }) catch @panic("OOM");
            return builder.path(full_path);
        }
    }.get;

    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    // Walker module (platform-optimized directory walker)
    const walker_mod = b.addModule("walker", .{
        .root_source_file = srcPath(b, src_dir, "walker.zig"),
        .target = target,
        .link_libc = use_libc,
    });

    // Flags module (canonical source of all ZLOB_* constants)
    const flags_mod = b.addModule("zlob_flags", .{
        .root_source_file = srcPath(b, src_dir, "flags.zig"),
        .target = target,
        .link_libc = use_libc,
    });
    flags_mod.addIncludePath(b.path("include"));

    // zlob core module (for internal use - the actual implementation in zlob.zig)
    const zlob_core_mod = b.addModule("zlob_core", .{
        .root_source_file = srcPath(b, src_dir, "zlob.zig"),
        .target = target,
        .link_libc = use_libc,
        .imports = &.{
            .{ .name = "walker", .module = walker_mod },
            .{ .name = "zlob_flags", .module = flags_mod },
        },
    });
    // Add include path for C header imports (flags.zig uses @cImport)
    zlob_core_mod.addIncludePath(b.path("include"));

    // Main zlob module (public API via lib.zig)
    const mod = b.addModule("zlob", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = srcPath(b, src_dir, "lib.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .link_libc = use_libc,
        .imports = &.{
            .{ .name = "zlob", .module = zlob_core_mod },
            .{ .name = "zlob_flags", .module = flags_mod },
        },
    });

    // C-compatible module (for C exports, depends on zlob core)
    const c_lib_mod = b.addModule("c_lib", .{
        .root_source_file = srcPath(b, src_dir, "c_lib.zig"),
        .target = target,
        .link_libc = use_libc,
        .imports = &.{
            .{ .name = "zlob", .module = zlob_core_mod },
            .{ .name = "zlob_flags", .module = flags_mod },
        },
    });

    // Test utilities module (shared helpers for tests)
    const test_utils_mod = b.addModule("test_utils", .{
        .root_source_file = b.path("test/test_utils.zig"),
        .target = target,
        .link_libc = use_libc,
        .imports = &.{
            .{ .name = "zlob", .module = mod },
        },
    });

    // C-compatible shared library (libzlob.so/.dylib/.dll)
    // Provides POSIX glob() and globfree() functions with C header
    // Skipped when static_only is set to avoid import lib / static lib name collision
    // on Windows MSVC (both produce zlob.lib, causing the linker to pick the import lib
    // and creating an unintended runtime dependency on zlob.dll).
    if (!static_only) {
        const c_lib = b.addLibrary(.{
            .name = "zlob",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = srcPath(b, src_dir, "c_lib.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = use_libc,
                .imports = &.{
                    .{ .name = "zlob", .module = zlob_core_mod },
                    .{ .name = "zlob_flags", .module = flags_mod },
                },
            }),
        });
        // Install C header
        c_lib.installHeader(b.path("include/zlob.h"), "zlob.h");
        b.installArtifact(c_lib);
    }

    // C-compatible static library (libzlob.a) for Rust FFI and static linking
    const c_lib_static = b.addLibrary(.{
        .name = "zlob",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = srcPath(b, src_dir, "c_lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = use_libc,
            // required for shared libraries on musl
            .pic = true,
            .imports = &.{
                .{ .name = "zlob", .module = zlob_core_mod },
                .{ .name = "zlob_flags", .module = flags_mod },
            },
        }),
    });
    // Install C header alongside static library when dynamic lib is skipped
    if (static_only) {
        c_lib_static.installHeader(b.path("include/zlob.h"), "zlob.h");
    }

    b.installArtifact(c_lib_static);

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // CLI executable - skip when building only the static library (e.g., Rust crate builds,
    // or cross-compiling for targets like Android where the exe can't link without a full SDK).
    if (!static_only) {
        const exe_mod = b.createModule(.{
            .root_source_file = srcPath(b, src_dir, "main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zlob", .module = mod },
            },
        });

        // Pass version from build.zig.zon to the CLI
        const options = b.addOptions();
        options.addOption([]const u8, "version", version_string);
        exe_mod.addOptions("build_options", options);

        const exe = b.addExecutable(.{
            .name = "zlob",
            .root_module = exe_mod,
        });

        b.installArtifact(exe);

        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    const test_step = b.step("test", "Run tests");

    const test_files = [_][]const u8{
        "test/test_basic.zig",
        "test/test_brace.zig",
        "test/test_append.zig",
        "test/test_glibc.zig",
        "test/test_internal.zig",
        "test/test_posix.zig",
        "test/test_rust_glob.zig",
        "test/test_path_matcher.zig",
        "test/test_errfunc.zig",
        "test/test_gitignore.zig",
        "test/test_gitignore_e2e.zig",
        "test/test_extglob.zig",
        "test/test_utils.zig",
        "test/test_fnmatch.zig",
        "test/test_edge_cases.zig",
        // files with inline tests
        "src/brace_optimizer.zig",
        "src/gitignore.zig",
        "src/fnmatch.zig",
        "src/sorting.zig",
    };

    for (test_files) |test_file| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
            .link_libc = use_libc,
            .imports = &.{
                .{ .name = "zlob", .module = mod },
                .{ .name = "zlob_core", .module = zlob_core_mod },
                .{ .name = "c_lib", .module = c_lib_mod },
                .{ .name = "test_utils", .module = test_utils_mod },
                .{ .name = "walker", .module = walker_mod },
                .{ .name = "zlob_flags", .module = flags_mod },
            },
        });
        // Add include path for C header imports (flags.zig uses @cImport)
        test_mod.addIncludePath(b.path("include"));
        test_mod.addIncludePath(b.path("include"));

        const test_exe = b.addTest(.{
            .root_module = test_mod,
        });
        const run_test = b.addRunArtifact(test_exe);
        test_step.dependOn(&run_test.step);
    }

    // Benchmark executables (only if not skipped)
    if (!skip_bench) {
        const is_windows = target.result.os.tag == .windows;

        // Benchmark executable
        const benchmark = b.addExecutable(.{
            .name = "benchmark",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/benchmark.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zlob", .module = mod },
                },
            }),
        });
        b.installArtifact(benchmark);

        // Benchmark run step
        const benchmark_cmd = b.addRunArtifact(benchmark);
        benchmark_cmd.step.dependOn(b.getInstallStep());
        const benchmark_step = b.step("benchmark", "Run SIMD benchmark");
        benchmark_step.dependOn(&benchmark_cmd.step);

        // matchPaths benchmark executable
        const bench_matchpaths = b.addExecutable(.{
            .name = "bench_matchpaths",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/bench_matchPaths.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zlob", .module = mod },
                },
            }),
        });
        b.installArtifact(bench_matchpaths);

        // matchPaths benchmark run step
        const bench_matchpaths_cmd = b.addRunArtifact(bench_matchpaths);
        bench_matchpaths_cmd.step.dependOn(b.getInstallStep());
        const bench_matchpaths_step = b.step("bench-matchpaths", "Benchmark matchPaths() performance");
        bench_matchpaths_step.dependOn(&bench_matchpaths_cmd.step);

        const bench_fnmatch = b.addExecutable(.{
            .name = "bench_fnmatch",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/bench_fnmatch.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "zlob", .module = mod },
                },
            }),
        });
        b.installArtifact(bench_fnmatch);

        const bench_fnmatch_cmd = b.addRunArtifact(bench_fnmatch);
        bench_fnmatch_cmd.step.dependOn(b.getInstallStep());
        const bench_fnmatch_step = b.step("bench-fnmatch", "Benchmark fnmatch pattern matching");
        bench_fnmatch_step.dependOn(&bench_fnmatch_cmd.step);

        // Multi-suffix matching benchmark
        const bench_multi_suffix = b.addExecutable(.{
            .name = "bench_multi_suffix",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/bench_multi_suffix.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "zlob", .module = mod },
                },
            }),
        });
        b.installArtifact(bench_multi_suffix);

        const bench_multi_suffix_cmd = b.addRunArtifact(bench_multi_suffix);
        bench_multi_suffix_cmd.step.dependOn(b.getInstallStep());
        const bench_multi_suffix_step = b.step("bench-multi-suffix", "Benchmark multi-suffix matching");
        bench_multi_suffix_step.dependOn(&bench_multi_suffix_cmd.step);

        // Recursive pattern benchmark for perf profiling
        const bench_recursive = b.addExecutable(.{
            .name = "bench_recursive",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/bench_recursive.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zlob", .module = mod },
                },
            }),
        });
        b.installArtifact(bench_recursive);

        if (!is_windows) {
            const compare_libc = b.addExecutable(.{
                .name = "compare_libc",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("bench/compare_libc.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "c_lib", .module = c_lib_mod },
                    },
                }),
            });
            compare_libc.linkLibC(); // Link against libc for glob()
            b.installArtifact(compare_libc);

            // libc comparison run step
            const compare_libc_cmd = b.addRunArtifact(compare_libc);
            compare_libc_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                compare_libc_cmd.addArgs(args);
            }
            const compare_libc_step = b.step("compare-libc", "Compare SIMD glob vs libc glob()");
            compare_libc_step.dependOn(&compare_libc_cmd.step);
        }

        // Benchmarks that need libc - skip on Windows MSVC (Zig can't provide libc for MSVC targets)
        if (!is_windows_msvc) {
            // Perf test for C-style glob
            const perf_test_libc = b.addExecutable(.{
                .name = "perf_test_libc",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("bench/perf_test_libc.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "zlob", .module = mod },
                        .{ .name = "c_lib", .module = c_lib_mod },
                    },
                }),
            });
            perf_test_libc.linkLibC();
            b.installArtifact(perf_test_libc);

            const perf_test_libc_cmd = b.addRunArtifact(perf_test_libc);
            perf_test_libc_cmd.step.dependOn(b.getInstallStep());
            const perf_test_libc_step = b.step("perf-test-libc", "Perf profiling for C-style glob");
            perf_test_libc_step.dependOn(&perf_test_libc_cmd.step);

            // Profile big repo with zlob_libc
            const profile_big_repo = b.addExecutable(.{
                .name = "profile_big_repo",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("bench/profile_big_repo.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "zlob", .module = mod },
                        .{ .name = "c_lib", .module = c_lib_mod },
                        .{ .name = "zlob_flags", .module = flags_mod },
                    },
                }),
            });
            profile_big_repo.linkLibC();
            b.installArtifact(profile_big_repo);

            const profile_big_repo_cmd = b.addRunArtifact(profile_big_repo);
            profile_big_repo_cmd.step.dependOn(b.getInstallStep());
            const profile_big_repo_step = b.step("profile-big-repo", "Profile zlob_libc on Linux kernel repository");
            profile_big_repo_step.dependOn(&profile_big_repo_cmd.step);

            const bench_brace = b.addExecutable(.{
                .name = "bench_brace",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("bench/bench_brace.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "zlob", .module = mod },
                        .{ .name = "c_lib", .module = c_lib_mod },
                        .{ .name = "zlob_flags", .module = flags_mod },
                    },
                }),
            });
            bench_brace.linkLibC();
            b.installArtifact(bench_brace);

            const bench_brace_cmd = b.addRunArtifact(bench_brace);
            bench_brace_cmd.step.dependOn(b.getInstallStep());
            const bench_brace_step = b.step("bench-brace", "Benchmark brace pattern optimizations");
            bench_brace_step.dependOn(&bench_brace_cmd.step);

            // Compare walker backends
            const compare_walker = b.addExecutable(.{
                .name = "compare_walker",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("bench/compare_walker.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "walker", .module = walker_mod },
                    },
                }),
            });
            compare_walker.linkLibC();
            b.installArtifact(compare_walker);

            const compare_walker_cmd = b.addRunArtifact(compare_walker);
            compare_walker_cmd.step.dependOn(b.getInstallStep());
            const compare_walker_step = b.step("compare-walker", "Compare walker backends");
            compare_walker_step.dependOn(&compare_walker_cmd.step);

            // Test recursive benchmark
            const test_recursive = b.addExecutable(.{
                .name = "test_recursive",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("bench/test_recursive.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "zlob", .module = mod },
                        .{ .name = "c_lib", .module = c_lib_mod },
                    },
                }),
            });
            test_recursive.linkLibC();
            b.installArtifact(test_recursive);

            const test_recursive_cmd = b.addRunArtifact(test_recursive);
            test_recursive_cmd.step.dependOn(b.getInstallStep());
            const test_recursive_step = b.step("test-recursive", "Test recursive glob");
            test_recursive_step.dependOn(&test_recursive_cmd.step);

            // Perf recursive benchmark
            const perf_recursive = b.addExecutable(.{
                .name = "perf_recursive",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("bench/perf_recursive.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "zlob", .module = mod },
                        .{ .name = "c_lib", .module = c_lib_mod },
                    },
                }),
            });
            perf_recursive.linkLibC();
            b.installArtifact(perf_recursive);
        }

        // Tree-size scaling benchmark (not available on Windows - no libc glob())
        if (!is_windows) {
            const bench_tree_sizes = b.addExecutable(.{
                .name = "bench_tree_sizes",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("bench/bench_tree_sizes.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
                    .imports = &.{
                        .{ .name = "c_lib", .module = c_lib_mod },
                        .{ .name = "zlob_flags", .module = flags_mod },
                    },
                }),
            });
            bench_tree_sizes.linkLibC();
            b.installArtifact(bench_tree_sizes);

            const bench_tree_sizes_cmd = b.addRunArtifact(bench_tree_sizes);
            bench_tree_sizes_cmd.step.dependOn(b.getInstallStep());
            const bench_tree_sizes_step = b.step("bench-tree-sizes", "Benchmark zlob vs libc across small/medium/large directory trees");
            bench_tree_sizes_step.dependOn(&bench_tree_sizes_cmd.step);
        }
    }

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
