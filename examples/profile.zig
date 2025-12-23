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

    // Test 3: matchFiles (in-memory, no I/O)
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
            var result = try simdglob.matchFiles(allocator, "src/*.zig", &files, 0);
            result.deinit();
        }

        const elapsed = timer.read() - start;
        const avg_ns = elapsed / (iterations * 10);
        const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;
        std.debug.print("matchFiles (in-memory, 6 files): {d:.2}μs per call\n", .{avg_us});
    }

    std.debug.print("\n=== Analysis ===\n", .{});
    std.debug.print("Directory iteration ~= Full glob → filesystem I/O is the bottleneck\n", .{});
    std.debug.print("matchFiles shows pure pattern matching performance (no I/O)\n", .{});
    std.debug.print("\nBottleneck breakdown:\n", .{});
    std.debug.print("- If dir iteration is 80%+ of total: I/O bound (expected)\n", .{});
    std.debug.print("- If memory allocation is high: need pooling/caching\n", .{});
    std.debug.print("- matchFiles vs Full glob shows pattern matching overhead\n", .{});
}
