const std = @import("std");
const simdglob = @import("simdglob");

const Timer = std.time.Timer;

// libc glob types and functions
extern "c" fn glob(pattern: [*:0]const u8, flags: c_int, errfunc: ?*const anyopaque, pglob: *GlobT) c_int;
extern "c" fn globfree(pglob: *GlobT) void;

const GlobT = extern struct {
    gl_pathc: usize,
    gl_pathv: [*c][*c]u8,
    gl_offs: usize,
};

fn benchmarkLibcGlob(pattern: [*:0]const u8, iterations: usize) !u64 {
    var timer = try Timer.start();
    const start = timer.lap();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var glob_buf: GlobT = undefined;
        const result = glob(pattern, 0, null, &glob_buf);
        if (result == 0) {
            globfree(&glob_buf);
        }
    }

    const end = timer.read();
    return end - start;
}

fn benchmarkSimdGlob(allocator: std.mem.Allocator, pattern: []const u8, iterations: usize) !u64 {
    // Reuse Glob instance across iterations for better performance
    var g = simdglob.Glob.init(allocator, 0);
    defer g.deinit();

    var timer = try Timer.start();
    const start = timer.lap();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var result = try g.glob(pattern);
        result.deinit();
        // Glob automatically resets itself after returning result
    }

    const end = timer.read();
    return end - start;
}

pub fn main() !void {
    // Use C allocator for fair comparison - it's just malloc/free like libc uses
    const allocator = std.heap.c_allocator;

    std.debug.print("=== SIMD Glob vs libc glob() Benchmark ===\n\n", .{});
    std.debug.print("Comparing performance on real filesystem operations\n", .{});
    std.debug.print("Each test runs multiple iterations and reports average time\n", .{});
    std.debug.print("NOTE: For best results, compile with -Doptimize=ReleaseFast\n\n", .{});

    const test_cases = [_]struct {
        name: []const u8,
        pattern: []const u8,
        iterations: usize,
    }{
        .{
            .name = "Simple wildcard in current directory",
            .pattern = "*.zig",
            .iterations = 10000,
        },
        .{
            .name = "Source files pattern",
            .pattern = "src/*.zig",
            .iterations = 10000,
        },
        .{
            .name = "Wildcard directory expansion",
            .pattern = "*/*.zig",
            .iterations = 5000,
        },
        .{
            .name = "Specific character class",
            .pattern = "src/[gmr]*.zig",
            .iterations = 10000,
        },
        .{
            .name = "Prefix wildcard pattern",
            .pattern = "src/glob*.zig",
            .iterations = 10000,
        },
    };

    for (test_cases) |tc| {
        std.debug.print("{s}:\n", .{tc.name});
        std.debug.print("  Pattern: {s}\n", .{tc.pattern});
        std.debug.print("  Iterations: {d}\n", .{tc.iterations});

        // Create null-terminated string for libc
        const pattern_z = try allocator.dupeZ(u8, tc.pattern);
        defer allocator.free(pattern_z);

        // Benchmark libc glob
        const libc_time = try benchmarkLibcGlob(pattern_z.ptr, tc.iterations);
        const libc_avg_ns = libc_time / tc.iterations;
        const libc_avg_us = @as(f64, @floatFromInt(libc_avg_ns)) / 1000.0;

        // Benchmark SIMD glob
        const simd_time = try benchmarkSimdGlob(allocator, tc.pattern, tc.iterations);
        const simd_avg_ns = simd_time / tc.iterations;
        const simd_avg_us = @as(f64, @floatFromInt(simd_avg_ns)) / 1000.0;

        // Calculate speedup
        const speedup = @as(f64, @floatFromInt(libc_time)) / @as(f64, @floatFromInt(simd_time));

        std.debug.print("  libc glob:  {d:.2}μs per call\n", .{libc_avg_us});
        std.debug.print("  SIMD glob:  {d:.2}μs per call\n", .{simd_avg_us});

        if (speedup > 1.0) {
            std.debug.print("  Result: SIMD is {d:.2}x FASTER\n", .{speedup});
        } else {
            std.debug.print("  Result: libc is {d:.2}x faster\n", .{1.0 / speedup});
        }
        std.debug.print("\n", .{});
    }

    // Also test match count to ensure correctness
    std.debug.print("=== Correctness Check ===\n\n", .{});

    const verify_patterns = [_][]const u8{
        "src/*.zig",
        "*.md",
        "examples/*.zig",
    };

    for (verify_patterns) |pattern| {
        const pattern_z = try allocator.dupeZ(u8, pattern);
        defer allocator.free(pattern_z);

        // Count with libc
        var glob_buf: GlobT = undefined;
        const result = glob(pattern_z.ptr, 0, null, &glob_buf);
        const libc_count = if (result == 0) glob_buf.gl_pathc else 0;
        if (result == 0) {
            globfree(&glob_buf);
        }

        // Count with SIMD
        var simd_count: usize = 0;
        if (simdglob.match(allocator, pattern, 0)) |simd_result| {
            simd_count = simd_result.match_count;
            var mut_result = simd_result;
            mut_result.deinit();
        } else |err| {
            if (err != error.NoMatch) return err;
        }

        const match = if (libc_count == simd_count) "✓" else "✗";
        std.debug.print("{s} Pattern '{s}': libc={d}, SIMD={d}\n", .{
            match,
            pattern,
            libc_count,
            simd_count,
        });
    }

    std.debug.print("\nBenchmark completed!\n", .{});
}
