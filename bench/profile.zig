const std = @import("std");
const simdglob = @import("simdglob");

const Timer = std.time.Timer;

// Detailed profiling of each stage of glob operation
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== SIMD Glob Performance Profiling ===\n\n", .{});

    const iterations: usize = 10000;
    const pattern = "src/*.zig";

    // Test 1: Full glob operation
    {
        var timer = try Timer.start();
        const start = timer.lap();

        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var result = try simdglob.match(allocator, pattern, 0);
            result.deinit();
        }

        const elapsed = timer.read() - start;
        const avg_ns = elapsed / iterations;
        const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;
        std.debug.print("Full glob operation: {d:.2}μs per call ({d} iterations)\n", .{ avg_us, iterations });
    }

    // Test 2: Directory reading overhead
    {
        var timer = try Timer.start();
        const start = timer.lap();

        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
            defer dir.close();

            var it = dir.iterate();
            var count: usize = 0;
            while (try it.next()) |_| {
                count += 1;
            }
        }

        const elapsed = timer.read() - start;
        const avg_ns = elapsed / iterations;
        const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;
        std.debug.print("Directory iteration only: {d:.2}μs per call\n", .{avg_us});
    }

    // Test 3: matchPaths without reuse (worst case)
    {
        const files = [_][]const u8{
            "src/main.zig",
            "src/test.zig",
            "src/lib.zig",
            "src/glob.zig",
            "src/root.zig",
            "src/helper.c",
        };

        var timer = try Timer.start();
        const start = timer.lap();

        var i: usize = 0;
        while (i < iterations * 10) : (i += 1) {
            var result = try simdglob.matchPaths(allocator, "src/*.zig", &files, 0);
            result.deinit();
        }

        const elapsed = timer.read() - start;
        const avg_ns = elapsed / (iterations * 10);
        const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;
        std.debug.print("matchPaths (no reuse, 6 files): {d:.2}μs per call\n", .{avg_us});
    }

    // Test 4: matchPaths WITH reuse (optimized)
    {
        const files = [_][]const u8{
            "src/main.zig",
            "src/test.zig",
            "src/lib.zig",
            "src/glob.zig",
            "src/root.zig",
            "src/helper.c",
        };

        var g = simdglob.Glob.init(allocator, 0);
        defer g.deinit();

        var timer = try Timer.start();
        const start = timer.lap();

        var i: usize = 0;
        while (i < iterations * 10) : (i += 1) {
            var result = try g.matchPaths("src/*.zig", &files);
            result.deinit();
        }

        const elapsed = timer.read() - start;
        const avg_ns = elapsed / (iterations * 10);
        const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;
        std.debug.print("matchPaths (with reuse, 6 files): {d:.2}μs per call\n", .{avg_us});
    }

    std.debug.print("\n=== Analysis ===\n", .{});
    std.debug.print("Compare 'matchPaths (no reuse)' vs 'matchPaths (with reuse)' to see allocation overhead\n", .{});
    std.debug.print("The 'with reuse' version should be significantly faster if allocation was the bottleneck\n", .{});
}
