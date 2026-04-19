//! Walker Performance Benchmark
//!
//! Compares the optimized getdents64 walker (Linux) against std.fs.Dir.walk()
const std = @import("std");
const walker_mod = @import("walker");

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // Try to use Linux kernel source as test directory
    std.process.setCurrentPath(io, "/home/neogoose/dev/fff.nvim/big-repo") catch {
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
        try runBenchmark(io, allocator, tc.path, tc.name);
    }

    std.debug.print("Benchmark complete.\n", .{});
}

fn runBenchmark(io: std.Io, allocator: std.mem.Allocator, test_path: []const u8, name: []const u8) !void {
    const iterations: usize = 10;

    std.debug.print("{s}\n", .{name});
    std.debug.print("{s}\n", .{"-" ** 50});

    // Verify directory exists
    std.Io.Dir.cwd().access(io, test_path, .{}) catch {
        std.debug.print("  Directory not found, skipping\n\n", .{});
        return;
    };

    // Benchmark std.Io.Dir.walk
    var total_std: u64 = 0;
    var count_std: usize = 0;
    for (0..iterations) |_| {
        const start = std.Io.Timestamp.now(io, .awake);
        var dir = try std.Io.Dir.cwd().openDir(io, test_path, .{ .iterate = true });
        defer dir.close(io);
        var w = try dir.walk(allocator);
        defer w.deinit();
        var count: usize = 0;
        while (try w.next(io)) |_| count += 1;
        const end = std.Io.Timestamp.now(io, .awake);
        total_std += @intCast(start.durationTo(end).nanoseconds);
        count_std = count;
    }

    // Benchmark optimized walker
    var total_optimized: u64 = 0;
    var count_optimized: usize = 0;
    for (0..iterations) |_| {
        const start = std.Io.Timestamp.now(io, .awake);
        var w = try walker_mod.DefaultWalker.init(allocator, io, test_path, .{});
        defer w.deinit();
        var count: usize = 0;
        while (try w.next()) |_| count += 1;
        const end = std.Io.Timestamp.now(io, .awake);
        total_optimized += @intCast(start.durationTo(end).nanoseconds);
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
