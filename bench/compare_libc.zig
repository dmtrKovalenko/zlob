const std = @import("std");
const c_lib = @import("c_lib");

// libc glob types and functions
extern "c" fn glob(pattern: [*:0]const u8, flags: c_int, errfunc: ?*const anyopaque, pzlob: *GlobT) c_int;
extern "c" fn globfree(pzlob: *GlobT) void;

const GlobT = extern struct {
    pathc: usize,
    pathv: [*c][*c]u8,
    offs: usize,
};

fn benchmarkLibcGlob(io: std.Io, pattern: [*:0]const u8, iterations: usize) !u64 {
    const start = std.Io.Timestamp.now(io, .awake);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var zlob_buf: GlobT = undefined;
        const result = glob(pattern, 0, null, &zlob_buf);
        if (result == 0) {
            globfree(&zlob_buf);
        }
    }

    const end = std.Io.Timestamp.now(io, .awake);
    return @intCast(start.durationTo(end).nanoseconds);
}

fn benchmarkZlobGlob(io: std.Io, pattern: [*:0]const u8, iterations: usize) !u64 {
    const start = std.Io.Timestamp.now(io, .awake);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var zlob_buf: c_lib.zlob_t = undefined;
        const result = c_lib.zlob(pattern, 0, null, &zlob_buf);
        if (result == 0) {
            c_lib.zlobfree(&zlob_buf);
        }
    }

    const end = std.Io.Timestamp.now(io, .awake);
    return @intCast(start.durationTo(end).nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Use C allocator for fair comparison - it's just malloc/free like libc uses
    const allocator = std.heap.c_allocator;

    // Parse command-line arguments via juicy main's Args iterator
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_iter.deinit();

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv_list.items) |a| allocator.free(a);
        argv_list.deinit(allocator);
    }

    while (args_iter.next()) |arg| {
        const dup = try allocator.dupe(u8, arg);
        try argv_list.append(allocator, dup);
    }

    const args = argv_list.items;

    if (args.len != 3) {
        std.debug.print("Usage: {s} <path> <pattern>\n", .{if (args.len > 0) args[0] else "compare_libc"});
        std.debug.print("Example: {s} /home/user/big-repo './**/*.c'\n", .{if (args.len > 0) args[0] else "compare_libc"});
        std.process.exit(1);
    }

    const path = args[1];
    const pattern = args[2];
    const iterations: usize = 1000;

    // Change to the specified directory
    std.process.setCurrentPath(io, path) catch |err| {
        std.debug.print("Error: Cannot change to directory '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };

    std.debug.print("=== zlob vs libc glob() Benchmark ===\n\n", .{});
    std.debug.print("Directory: {s}\n", .{path});
    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Iterations: {d}\n", .{iterations});
    std.debug.print("NOTE: For best results, compile with -Doptimize=ReleaseFast\n\n", .{});

    // Create null-terminated string for libc
    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);

    // First, count the matches
    var zlob_buf: GlobT = undefined;
    const result = glob(pattern_z.ptr, 0, null, &zlob_buf);
    const libc_count = if (result == 0) zlob_buf.pathc else 0;
    if (result == 0) {
        globfree(&zlob_buf);
    }

    var zlob_count: usize = 0;
    var zlob_buf2: c_lib.zlob_t = undefined;
    const zlob_result = c_lib.zlob(pattern_z.ptr, 0, null, &zlob_buf2);
    if (zlob_result == 0) {
        zlob_count = zlob_buf2.zlo_pathc;
        c_lib.zlobfree(&zlob_buf2);
    }

    std.debug.print("Match count: libc={d}, zlob={d}\n\n", .{ libc_count, zlob_count });

    // Benchmark libc glob
    const libc_time = try benchmarkLibcGlob(io, pattern_z.ptr, iterations);
    const libc_avg_ns = libc_time / iterations;
    const libc_avg_us = @as(f64, @floatFromInt(libc_avg_ns)) / 1000.0;
    const libc_total_ms = @as(f64, @floatFromInt(libc_time)) / 1_000_000.0;

    // Benchmark zlob glob
    const zlob_time = try benchmarkZlobGlob(io, pattern_z.ptr, iterations);
    const zlob_avg_ns = zlob_time / iterations;
    const zlob_avg_us = @as(f64, @floatFromInt(zlob_avg_ns)) / 1000.0;
    const zlob_total_ms = @as(f64, @floatFromInt(zlob_time)) / 1_000_000.0;

    // Calculate speedup
    const speedup = @as(f64, @floatFromInt(libc_time)) / @as(f64, @floatFromInt(zlob_time));

    std.debug.print("=== Results ===\n", .{});
    std.debug.print("libc glob:\n", .{});
    std.debug.print("  Average: {d:.2}μs per call\n", .{libc_avg_us});
    std.debug.print("  Total:   {d:.2}ms for {d} iterations\n", .{ libc_total_ms, iterations });
    std.debug.print("\n", .{});

    std.debug.print("zlob glob:\n", .{});
    std.debug.print("  Average: {d:.2}μs per call\n", .{zlob_avg_us});
    std.debug.print("  Total:   {d:.2}ms for {d} iterations\n", .{ zlob_total_ms, iterations });
    std.debug.print("\n", .{});

    if (speedup > 1.0) {
        std.debug.print("Result: zlob is {d:.2}x FASTER\n", .{speedup});
    } else {
        std.debug.print("Result: libc is {d:.2}x faster\n", .{1.0 / speedup});
    }

    std.debug.print("\nBenchmark completed!\n", .{});
}
