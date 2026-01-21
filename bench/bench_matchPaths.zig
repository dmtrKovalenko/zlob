const std = @import("std");
const zlob = @import("zlob");
const time = std.time;

// Benchmark configuration
const ITERATIONS = 1000;
const WARMUP_ITERATIONS = 100;

fn benchmark(
    allocator: std.mem.Allocator,
    name: []const u8,
    pattern: []const u8,
    paths: []const []const u8,
) !void {
    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        var result = try zlob.matchPaths(allocator, pattern, paths, 0);
        result.deinit();
    }

    // Actual benchmark
    const start = time.nanoTimestamp();
    for (0..ITERATIONS) |_| {
        var result = try zlob.matchPaths(allocator, pattern, paths, 0);
        result.deinit();
    }
    const end = time.nanoTimestamp();

    const total_ns = @as(u64, @intCast(end - start));
    const avg_ns = total_ns / ITERATIONS;
    const avg_us = avg_ns / 1000;

    std.debug.print("{s:50} | {d:8} µs/op | {d:6} matches\n", .{
        name,
        avg_us,
        blk: {
            var result = try zlob.matchPaths(allocator, pattern, paths, 0);
            defer result.deinit();
            break :blk result.match_count;
        },
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Pattern Matching Benchmarks ===\n\n", .{});
    std.debug.print("{s:50} | {s:13} | {s}\n", .{ "Benchmark", "Time", "Matches" });
    std.debug.print("{s:-<50}-+-{s:-<13}-+-{s:-<10}\n", .{ "", "", "" });

    // Generate test data
    const small_paths = try generatePaths(allocator, 100);
    defer freePaths(allocator, small_paths);

    const medium_paths = try generatePaths(allocator, 1000);
    defer freePaths(allocator, medium_paths);

    const large_paths = try generatePaths(allocator, 10000);
    defer freePaths(allocator, large_paths);

    // 1. Literal pattern (no wildcards)
    std.debug.print("\n--- Literal Patterns (No Wildcards) ---\n", .{});
    try benchmark(allocator, "Literal - small (100 paths)", "src/utils/helper.zig", small_paths);
    try benchmark(allocator, "Literal - medium (1K paths)", "src/utils/helper.zig", medium_paths);
    try benchmark(allocator, "Literal - large (10K paths)", "src/utils/helper.zig", large_paths);

    // 2. Simple suffix patterns (*.ext)
    std.debug.print("\n--- Suffix Patterns (*.ext) ---\n", .{});
    try benchmark(allocator, "Suffix *.zig - small (100 paths)", "*.zig", small_paths);
    try benchmark(allocator, "Suffix *.zig - medium (1K paths)", "*.zig", medium_paths);
    try benchmark(allocator, "Suffix *.zig - large (10K paths)", "*.zig", large_paths);

    // 3. Directory prefix patterns (src/*.zig)
    std.debug.print("\n--- Directory Prefix (dir/*.ext) ---\n", .{});
    try benchmark(allocator, "Dir prefix src/*.zig - small", "src/*.zig", small_paths);
    try benchmark(allocator, "Dir prefix src/*.zig - medium", "src/*.zig", medium_paths);
    try benchmark(allocator, "Dir prefix src/*.zig - large", "src/*.zig", large_paths);

    // 4. Recursive patterns (**/*.ext)
    std.debug.print("\n--- Recursive Patterns (**/*.ext) ---\n", .{});
    try benchmark(allocator, "Recursive **/*.zig - small", "**/*.zig", small_paths);
    try benchmark(allocator, "Recursive **/*.zig - medium", "**/*.zig", medium_paths);
    try benchmark(allocator, "Recursive **/*.zig - large", "**/*.zig", large_paths);

    // 5. Complex recursive patterns (prefix/**/suffix/*.ext)
    std.debug.print("\n--- Complex Recursive (dir/**/dir/*.ext) ---\n", .{});
    try benchmark(allocator, "Complex src/**/test/*.zig - small", "src/**/test/*.zig", small_paths);
    try benchmark(allocator, "Complex src/**/test/*.zig - medium", "src/**/test/*.zig", medium_paths);
    try benchmark(allocator, "Complex src/**/test/*.zig - large", "src/**/test/*.zig", large_paths);

    // 6. Character class patterns
    std.debug.print("\n--- Character Classes ([abc], [0-9]) ---\n", .{});
    try benchmark(allocator, "Char class test[0-9].zig - small", "test[0-9].zig", small_paths);
    try benchmark(allocator, "Char class test[0-9].zig - medium", "test[0-9].zig", medium_paths);
    try benchmark(allocator, "Char class **/test[0-9].zig - large", "**/test[0-9].zig", large_paths);

    // 7. Question mark patterns
    std.debug.print("\n--- Question Mark (?) Patterns ---\n", .{});
    try benchmark(allocator, "Question mark test?.zig - small", "test?.zig", small_paths);
    try benchmark(allocator, "Question mark src/???.zig - medium", "src/???.zig", medium_paths);
    try benchmark(allocator, "Question mark **/?est.zig - large", "**/?est.zig", large_paths);

    // 8. No matches scenario
    std.debug.print("\n--- No Matches (Worst Case) ---\n", .{});
    try benchmark(allocator, "No match *.xyz - small", "*.xyz", small_paths);
    try benchmark(allocator, "No match *.xyz - medium", "*.xyz", medium_paths);
    try benchmark(allocator, "No match *.xyz - large", "*.xyz", large_paths);

    std.debug.print("\n", .{});
}

// Generate realistic file paths for testing
fn generatePaths(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    var paths = try allocator.alloc([]const u8, count);
    errdefer allocator.free(paths);

    var prng = std.Random.DefaultPrng.init(42); // Fixed seed for reproducibility
    const random = prng.random();

    const extensions = [_][]const u8{ ".zig", ".c", ".txt", ".md", ".rs", ".go", ".js", ".py" };
    const dirs = [_][]const u8{ "src", "lib", "test", "docs", "utils", "core", "api", "cli" };
    const subdirs = [_][]const u8{ "utils", "models", "views", "controllers", "test", "impl", "foo", "bar" };
    const names = [_][]const u8{ "main", "test", "helper", "utils", "lib", "core", "api", "client", "server", "config" };

    for (0..count) |i| {
        const depth = random.intRangeAtMost(usize, 1, 4);
        const ext = extensions[random.intRangeAtMost(usize, 0, extensions.len - 1)];
        const name = names[random.intRangeAtMost(usize, 0, names.len - 1)];

        var path_buf: [256]u8 = undefined;
        var path_len: usize = 0;

        // Build path with random depth
        for (0..depth) |d| {
            const dir = if (d == 0)
                dirs[random.intRangeAtMost(usize, 0, dirs.len - 1)]
            else
                subdirs[random.intRangeAtMost(usize, 0, subdirs.len - 1)];

            @memcpy(path_buf[path_len..][0..dir.len], dir);
            path_len += dir.len;
            path_buf[path_len] = '/';
            path_len += 1;
        }

        // Add filename
        @memcpy(path_buf[path_len..][0..name.len], name);
        path_len += name.len;

        // Maybe add a number
        if (random.intRangeAtMost(usize, 0, 2) == 0) {
            const num = random.intRangeAtMost(usize, 0, 9);
            path_buf[path_len] = '0' + @as(u8, @intCast(num));
            path_len += 1;
        }

        // Add extension
        @memcpy(path_buf[path_len..][0..ext.len], ext);
        path_len += ext.len;

        paths[i] = try allocator.dupe(u8, path_buf[0..path_len]);
    }

    return paths;
}

fn freePaths(allocator: std.mem.Allocator, paths: [][]const u8) void {
    for (paths) |path| {
        allocator.free(path);
    }
    allocator.free(paths);
}
