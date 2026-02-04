//! Walker Performance Benchmark
//!
//! Compares the optimized getdents64 walker (Linux) against std.fs.Dir.walk()
const std = @import("std");
const walker_mod = @import("walker");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Try to use Linux kernel source as test directory
    std.process.changeCurDir("/home/neogoose/dev/fff.nvim/big-repo") catch {
        std.debug.print("Cannot find big-repo, using current directory\n", .{});
    };

    std.debug.print("\n=== Walker Performance Benchmark ===\n", .{});
    std.debug.print("Backend: {s}\n\n", .{@tagName(walker_mod.default_backend)});

    const test_cases = [_]struct { path: []const u8, name: []const u8 }{
        .{ .path = "fs", .name = "fs/ (~2.3k files)" },
        .{ .path = "drivers/gpu", .name = "drivers/gpu/ (~8k files)" },
        .{ .path = "drivers", .name = "drivers/ (~39k files)" },
    };

    for (test_cases) |tc| {
        try runBenchmark(allocator, tc.path, tc.name);
    }

    std.debug.print("Benchmark complete.\n", .{});
}

fn runBenchmark(allocator: std.mem.Allocator, test_path: []const u8, name: []const u8) !void {
    const iterations: usize = 10;

    std.debug.print("{s}\n", .{name});
    std.debug.print("{s}\n", .{"-" ** 50});

    // Verify directory exists
    std.fs.cwd().access(test_path, .{}) catch {
        std.debug.print("  Directory not found, skipping\n\n", .{});
        return;
    };

    // Benchmark std.fs.Dir.walk
    var total_std: u64 = 0;
    var count_std: usize = 0;
    for (0..iterations) |_| {
        var timer = try std.time.Timer.start();
        var dir = try std.fs.cwd().openDir(test_path, .{ .iterate = true });
        defer dir.close();
        var w = try dir.walk(allocator);
        defer w.deinit();
        var count: usize = 0;
        while (try w.next()) |_| count += 1;
        total_std += timer.read();
        count_std = count;
    }

    // Benchmark optimized walker
    var total_optimized: u64 = 0;
    var count_optimized: usize = 0;
    for (0..iterations) |_| {
        var timer = try std.time.Timer.start();
        var w = try walker_mod.DefaultWalker.init(allocator, test_path, .{});
        defer w.deinit();
        var count: usize = 0;
        while (try w.next()) |_| count += 1;
        total_optimized += timer.read();
        count_optimized = count;
    }

    const avg_std = total_std / iterations;
    const avg_optimized = total_optimized / iterations;

    std.debug.print("  std.fs.Dir.walk:  {d:>7}μs  ({d} entries)\n", .{ avg_std / 1000, count_std });
    std.debug.print("  DefaultWalker:    {d:>7}μs  ({d} entries)\n", .{ avg_optimized / 1000, count_optimized });

    const ratio = @as(f64, @floatFromInt(avg_optimized)) / @as(f64, @floatFromInt(avg_std));
    if (ratio > 1.0) {
        std.debug.print("  Result: {d:.1}% SLOWER\n\n", .{(ratio - 1.0) * 100});
    } else {
        std.debug.print("  Result: {d:.1}% FASTER\n\n", .{(1.0 - ratio) * 100});
    }
}
