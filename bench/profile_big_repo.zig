const std = @import("std");
const glob = @import("glob");

const TestCase = struct {
    name: []const u8,
    pattern: [:0]const u8,
    iterations: usize,
    description: []const u8,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    // Change to big repo
    try std.process.changeCurDir("/home/neogoose/dev/fff.nvim/big-repo");
    std.debug.print("Changed to big-repo directory\n", .{});
    std.debug.print("Profiling glob.zig implementation\n", .{});
    std.debug.print("========================================\n\n", .{});

    const test_cases = [_]TestCase{
        .{
            .name = "Simple wildcard",
            .pattern = "fs/*.c",
            .iterations = 5000,
            .description = "Single directory, ~71 matches",
        },
        .{
            .name = "Multi-directory wildcard",
            .pattern = "*/Makefile",
            .iterations = 3000,
            .description = "Top-level dirs, ~50-100 matches",
        },
        .{
            .name = "Bracket pattern",
            .pattern = "[fk]*/*.c",
            .iterations = 2000,
            .description = "Bracket matching + wildcard, hundreds of matches",
        },
        .{
            .name = "Nested wildcard",
            .pattern = "drivers/*/*.c",
            .iterations = 500,
            .description = "Two-level directory expansion, thousands of matches",
        },
        .{
            .name = "Deep recursive glob",
            .pattern = "drivers/**/*.c",
            .iterations = 50,
            .description = "Recursive pattern in drivers/, 20,000+ matches - STRESS TEST",
        },
    };

    var total_matches: usize = 0;
    var total_iterations: usize = 0;
    var total_time_ns: u64 = 0;

    for (test_cases) |tc| {
        std.debug.print("Test: {s}\n", .{tc.name});
        std.debug.print("  Pattern: {s}\n", .{tc.pattern});
        std.debug.print("  Description: {s}\n", .{tc.description});
        std.debug.print("  Iterations: {d}\n", .{tc.iterations});

        // Warmup run to avoid cold cache
        {
            var pglob: glob.glob_t = undefined;
            const result = glob.glob_c(allocator, tc.pattern.ptr, 0, null, &pglob);
            if (result == 0) {
                std.debug.print("  Matches: {d}\n", .{pglob.gl_pathc});
                glob.globfree(allocator, &pglob);
            } else {
                std.debug.print("  Matches: 0 (error code: {d})\n", .{result});
            }
        }

        // Timed run
        var timer = try std.time.Timer.start();
        const start = timer.read();

        var i: usize = 0;
        var matches_this_test: usize = 0;
        while (i < tc.iterations) : (i += 1) {
            var pglob: glob.glob_t = undefined;
            const result = glob.glob_c(allocator, tc.pattern.ptr, 0, null, &pglob);
            if (result == 0) {
                matches_this_test = pglob.gl_pathc;
                glob.globfree(allocator, &pglob);
            }
        }

        const end = timer.read();
        const elapsed_ns = end - start;
        const avg_ns = elapsed_ns / tc.iterations;
        const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;
        const avg_ms = avg_us / 1000.0;

        std.debug.print("  Average time: {d:.3}ms ({d:.1}μs)\n", .{ avg_ms, avg_us });
        std.debug.print("  Throughput: {d:.0} globs/sec\n", .{@as(f64, @floatFromInt(tc.iterations)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)});

        total_matches += matches_this_test;
        total_iterations += tc.iterations;
        total_time_ns += elapsed_ns;

        std.debug.print("\n", .{});

        // Small sleep between tests to let system settle
        std.Thread.sleep(100 * std.time.ns_per_ms); // 100ms
    }

    std.debug.print("========================================\n", .{});
    std.debug.print("Overall Statistics:\n", .{});
    std.debug.print("  Total iterations: {d}\n", .{total_iterations});
    std.debug.print("  Total time: {d:.2}s\n", .{@as(f64, @floatFromInt(total_time_ns)) / 1_000_000_000.0});
    std.debug.print("  Overall throughput: {d:.0} globs/sec\n", .{@as(f64, @floatFromInt(total_iterations)) / (@as(f64, @floatFromInt(total_time_ns)) / 1_000_000_000.0)});
    std.debug.print("\nProfiling complete. Analyze with: perf report\n", .{});
}
