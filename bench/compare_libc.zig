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
        var result = try g.glob_match(pattern);
        result.deinit();
        // Glob automatically resets itself after returning result
    }

    const end = timer.read();
    return end - start;
}

pub fn main() !void {
    // Use C allocator for fair comparison - it's just malloc/free like libc uses
    const allocator = std.heap.c_allocator;

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.debug.print("Usage: {s} <path> <pattern>\n", .{args[0]});
        std.debug.print("Example: {s} /home/user/big-repo './**/*.c'\n", .{args[0]});
        std.process.exit(1);
    }

    const path = args[1];
    const pattern = args[2];
    const iterations: usize = 1000;

    // Change to the specified directory
    std.posix.chdir(path) catch |err| {
        std.debug.print("Error: Cannot change to directory '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };

    std.debug.print("=== SIMD Glob vs libc glob() Benchmark ===\n\n", .{});
    std.debug.print("Directory: {s}\n", .{path});
    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Iterations: {d}\n", .{iterations});
    std.debug.print("NOTE: For best results, compile with -Doptimize=ReleaseFast\n\n", .{});

    // Create null-terminated string for libc
    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);

    // First, count the matches
    var glob_buf: GlobT = undefined;
    const result = glob(pattern_z.ptr, 0, null, &glob_buf);
    const libc_count = if (result == 0) glob_buf.gl_pathc else 0;
    if (result == 0) {
        globfree(&glob_buf);
    }

    var simd_count: usize = 0;
    if (simdglob.match(allocator, pattern, 0)) |simd_result| {
        simd_count = simd_result.match_count;
        var mut_result = simd_result;
        mut_result.deinit();
    } else |err| {
        if (err != error.NoMatch) return err;
    }

    std.debug.print("Match count: libc={d}, SIMD={d}\n\n", .{ libc_count, simd_count });

    // Benchmark libc glob
    const libc_time = try benchmarkLibcGlob(pattern_z.ptr, iterations);
    const libc_avg_ns = libc_time / iterations;
    const libc_avg_us = @as(f64, @floatFromInt(libc_avg_ns)) / 1000.0;
    const libc_total_ms = @as(f64, @floatFromInt(libc_time)) / 1_000_000.0;

    // Benchmark SIMD glob
    const simd_time = try benchmarkSimdGlob(allocator, pattern, iterations);
    const simd_avg_ns = simd_time / iterations;
    const simd_avg_us = @as(f64, @floatFromInt(simd_avg_ns)) / 1000.0;
    const simd_total_ms = @as(f64, @floatFromInt(simd_time)) / 1_000_000.0;

    // Calculate speedup
    const speedup = @as(f64, @floatFromInt(libc_time)) / @as(f64, @floatFromInt(simd_time));

    std.debug.print("=== Results ===\n", .{});
    std.debug.print("libc glob:\n", .{});
    std.debug.print("  Average: {d:.2}μs per call\n", .{libc_avg_us});
    std.debug.print("  Total:   {d:.2}ms for {d} iterations\n", .{ libc_total_ms, iterations });
    std.debug.print("\n", .{});

    std.debug.print("SIMD glob:\n", .{});
    std.debug.print("  Average: {d:.2}μs per call\n", .{simd_avg_us});
    std.debug.print("  Total:   {d:.2}ms for {d} iterations\n", .{ simd_total_ms, iterations });
    std.debug.print("\n", .{});

    if (speedup > 1.0) {
        std.debug.print("Result: SIMD is {d:.2}x FASTER\n", .{speedup});
    } else {
        std.debug.print("Result: libc is {d:.2}x faster\n", .{1.0 / speedup});
    }

    std.debug.print("\nBenchmark completed!\n", .{});
}
