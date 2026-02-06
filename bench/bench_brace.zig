const std = @import("std");
const c_lib = @import("c_lib");
const zlob_flags = @import("zlob_flags");
const zlob_t = c_lib.zlob_t;

const Timer = std.time.Timer;

const TestCase = struct {
    name: []const u8,
    pattern: [:0]const u8,
    iterations: usize,
    description: []const u8,
    category: Category,

    const Category = enum {
        suffix_brace, // *.{c,h}
        prefix_brace, // {src,lib}/*.zig
        mid_path_brace, // path/{a,b}/folder/*.rs
        literal_brace, // file.{spec,nonspec}.ts
        multi_brace, // {a,b}/*.{c,h}
    };
};

const BenchmarkResult = struct {
    name: []const u8,
    category: TestCase.Category,
    matches: usize,
    avg_ns: u64,
    total_ns: u64,
    iterations: usize,

    fn avgUs(self: BenchmarkResult) f64 {
        return @as(f64, @floatFromInt(self.avg_ns)) / 1000.0;
    }

    fn avgMs(self: BenchmarkResult) f64 {
        return self.avgUs() / 1000.0;
    }

    fn throughput(self: BenchmarkResult) f64 {
        return @as(f64, @floatFromInt(self.iterations)) /
            (@as(f64, @floatFromInt(self.total_ns)) / 1_000_000_000.0);
    }
};

fn getRepoPath(allocator: std.mem.Allocator) ![]const u8 {
    // Try PROFILE_BIG_REPO env var first
    if (std.process.getEnvVarOwned(allocator, "PROFILE_BIG_REPO")) |path| {
        return path;
    } else |_| {
        // Fallback to default path
        return try allocator.dupe(u8, "/Users/neogoose/dev/lightsource");
    }
}

fn runBenchmark(tc: TestCase, warmup_iterations: usize) !BenchmarkResult {
    const flags: c_int = zlob_flags.ZLOB_RECOMMENDED | zlob_flags.ZLOB_GITIGNORE;
    var matches: usize = 0;
    for (0..warmup_iterations) |_| {
        var pzlob: zlob_t = undefined;
        const result = c_lib.zlob(tc.pattern.ptr, flags, null, &pzlob);
        if (result == 0) {
            matches = pzlob.zlo_pathc;
            c_lib.zlobfree(&pzlob);
        }
    }

    // Timed benchmark runs
    var timer = try Timer.start();
    const start = timer.read();

    for (0..tc.iterations) |_| {
        var pzlob: zlob_t = undefined;
        const result = c_lib.zlob(tc.pattern.ptr, flags, null, &pzlob);
        if (result == 0) {
            matches = pzlob.zlo_pathc;
            c_lib.zlobfree(&pzlob);
        }
    }

    const end = timer.read();
    const elapsed_ns = end - start;
    const avg_ns = elapsed_ns / tc.iterations;

    return BenchmarkResult{
        .name = tc.name,
        .category = tc.category,
        .matches = matches,
        .avg_ns = avg_ns,
        .total_ns = elapsed_ns,
        .iterations = tc.iterations,
    };
}

fn printResult(result: BenchmarkResult) void {
    const category_str = switch (result.category) {
        .suffix_brace => "SUFFIX",
        .prefix_brace => "PREFIX",
        .mid_path_brace => "MID-PATH",
        .literal_brace => "LITERAL",
        .multi_brace => "MULTI",
    };

    std.debug.print("  [{s:^8}] {s}\n", .{ category_str, result.name });
    std.debug.print("           Matches: {d}\n", .{result.matches});
    std.debug.print("           Average: {d:.3}ms ({d:.1}us)\n", .{ result.avgMs(), result.avgUs() });
    std.debug.print("           Throughput: {d:.1} globs/sec\n", .{result.throughput()});
    std.debug.print("\n", .{});
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Get repository path
    const repo_path = try getRepoPath(allocator);
    defer allocator.free(repo_path);

    // Change to repository directory
    std.posix.chdir(repo_path) catch |err| {
        std.debug.print("Error: Cannot change to directory '{s}': {}\n", .{ repo_path, err });
        std.debug.print("\nSet PROFILE_BIG_REPO environment variable to a valid repository path.\n", .{});
        std.debug.print("Example: PROFILE_BIG_REPO=/path/to/repo zig build bench-brace -Doptimize=ReleaseFast\n", .{});
        std.process.exit(1);
    };

    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  Brace Pattern Optimization Benchmark\n", .{});
    std.debug.print("========================================\n\n", .{});
    std.debug.print("Repository: {s}\n", .{repo_path});
    std.debug.print("NOTE: Compile with -Doptimize=ReleaseFast for accurate results\n\n", .{});

    const warmup_iterations: usize = 3;
    const base_iterations: usize = 50;
    const recursive_iterations: usize = 5; // Fewer iterations for ** patterns

    // Define test cases for each brace pattern category
    // These patterns work with Rust monorepos (like lightsource) and general codebases
    const test_cases = [_]TestCase{
        // Suffix brace patterns - most common, currently optimized
        .{
            .name = "Extension alternatives",
            .pattern = "common/*/*.{rs,toml}",
            .iterations = base_iterations,
            .description = "Match Rust source and config files",
            .category = .suffix_brace,
        },
        .{
            .name = "Deep recursive",
            .pattern = "common/**/*.{rs,toml}",
            .iterations = recursive_iterations,
            .description = "Recursive match with brace extension",
            .category = .suffix_brace,
        },

        // Prefix brace patterns - directories at start
        .{
            .name = "Directory alternatives",
            .pattern = "{common,metrics}/*/*.rs",
            .iterations = base_iterations,
            .description = "Match Rust files in specific service directories",
            .category = .prefix_brace,
        },
        .{
            .name = "Recursive prefix",
            .pattern = "{common,metrics}/**/*.rs",
            .iterations = recursive_iterations,
            .description = "Recursive match with prefix brace",
            .category = .prefix_brace,
        },

        // Mid-path brace patterns - directories in middle
        .{
            .name = "Mid-path common",
            .pattern = "common/{error,logging}/*/*.rs",
            .iterations = base_iterations,
            .description = "Match Rust files in common subdirectories",
            .category = .mid_path_brace,
        },
        .{
            .name = "Mid-path recursive",
            .pattern = "common/{error,logging}/**/*.rs",
            .iterations = recursive_iterations,
            .description = "Recursive match with mid-path brace",
            .category = .mid_path_brace,
        },

        // Literal brace patterns - no wildcards in brace content
        .{
            .name = "Cargo files",
            .pattern = "*/Cargo.{toml,lock}",
            .iterations = base_iterations,
            .description = "Match Cargo.toml and Cargo.lock files",
            .category = .literal_brace,
        },
        .{
            .name = "Recursive Cargo",
            .pattern = "**/Cargo.{toml,lock}",
            .iterations = recursive_iterations,
            .description = "Recursive Cargo file search",
            .category = .literal_brace,
        },

        // Multi-brace patterns - multiple brace groups
        .{
            .name = "Dir + extension",
            .pattern = "{common,metrics}/*/*.{rs,toml}",
            .iterations = base_iterations,
            .description = "Combined directory and extension alternatives",
            .category = .multi_brace,
        },
        .{
            .name = "Recursive multi",
            .pattern = "{common,metrics}/**/*.{rs,toml}",
            .iterations = recursive_iterations,
            .description = "Recursive multi-brace pattern",
            .category = .multi_brace,
        },
    };

    std.debug.print("Warmup iterations: {d}\n", .{warmup_iterations});
    std.debug.print("Benchmark iterations: {d}\n\n", .{base_iterations});
    std.debug.print("----------------------------------------\n\n", .{});

    var results: [test_cases.len]BenchmarkResult = undefined;
    var total_time_ns: u64 = 0;
    var total_matches: usize = 0;

    // Run all benchmarks
    for (test_cases, 0..) |tc, i| {
        std.debug.print("Running: {s}...\n", .{tc.name});

        results[i] = try runBenchmark(tc, warmup_iterations);
        total_time_ns += results[i].total_ns;
        total_matches += results[i].matches;

        printResult(results[i]);

        // Small pause between tests
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    std.debug.print("\n========================================\n", .{});
    std.debug.print("  Overall Statistics\n", .{});
    std.debug.print("========================================\n\n", .{});
    std.debug.print("  Total tests:      {d}\n", .{test_cases.len});
    std.debug.print("  Total matches:    {d}\n", .{total_matches});
    std.debug.print("  Total time:       {d:.2}s\n", .{@as(f64, @floatFromInt(total_time_ns)) / 1_000_000_000.0});
    std.debug.print("  Avg per pattern:  {d:.3}ms\n", .{@as(f64, @floatFromInt(total_time_ns / test_cases.len)) / 1_000_000.0});
    std.debug.print("\n", .{});
}
