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
    // zlob core module (for internal use - the actual implementation in zlob.zig)
    const zlob_core_mod = b.addModule("zlob_core", .{
        .root_source_file = b.path("src/zlob.zig"),
        .target = target,
        .link_libc = true,
    });

    // Main zlob module (public API via lib.zig)
    const mod = b.addModule("zlob", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/lib.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zlob", .module = zlob_core_mod },
        },
    });

    // C-compatible module (for C exports, depends on zlob core)
    const c_lib_mod = b.addModule("c_lib", .{
        .root_source_file = b.path("src/c_lib.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zlob", .module = zlob_core_mod },
        },
    });

    // C-compatible shared library (libzlob.so/.dylib/.dll)
    // Provides POSIX glob() and globfree() functions with C header
    const c_lib = b.addLibrary(.{
        .name = "zlob",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zlob", .module = zlob_core_mod },
            },
        }),
    });
    // Install C header
    c_lib.installHeader(b.path("include/zlob.h"), "zlob.h");
    b.installArtifact(c_lib);

    // C-compatible static library (libzlob.a) for Rust FFI and static linking
    const c_lib_static = b.addLibrary(.{
        .name = "zlob",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zlob", .module = zlob_core_mod },
            },
        }),
    });

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
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe_mod = b.createModule(.{
        // b.createModule defines a new module just like b.addModule but,
        // unlike b.addModule, it does not expose the module to consumers of
        // this package, which is why in this case we don't have to give it a name.
        .root_source_file = b.path("src/main.zig"),
        // Target and optimization levels must be explicitly wired in when
        // defining an executable or library (in the root module), and you
        // can also hardcode a specific target for an executable or library
        // definition if desireable (e.g. firmware for embedded devices).
        .target = target,
        .optimize = optimize,
        // List of modules available for import in source files part of the
        // root module.
        .imports = &.{
            // Here "zlob" is the name you will use in your source code to
            // import this module (e.g. `@import("zlob")`). The name is
            // repeated because you are allowed to rename your imports, which
            // can be extremely useful in case of collisions (which can happen
            // importing modules from different packages).
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

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
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
        // files with inline tests
        "src/brace_optimizer.zig",
        "src/gitignore.zig",
    };

    for (test_files) |test_file| {
        const test_exe = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "zlob", .module = mod },
                    .{ .name = "zlob_core", .module = zlob_core_mod },
                    .{ .name = "c_lib", .module = c_lib_mod },
                },
            }),
        });
        const run_test = b.addRunArtifact(test_exe);
        test_step.dependOn(&run_test.step);
    }

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

    // libc comparison benchmark executable
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
            },
        }),
    });
    bench_brace.linkLibC();
    b.installArtifact(bench_brace);

    const bench_brace_cmd = b.addRunArtifact(bench_brace);
    bench_brace_cmd.step.dependOn(b.getInstallStep());
    const bench_brace_step = b.step("bench-brace", "Benchmark brace pattern optimizations");
    bench_brace_step.dependOn(&bench_brace_cmd.step);

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
