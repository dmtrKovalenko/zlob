const std = @import("std");
const simdglob = @import("simdglob");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Generate 10K test paths
    var paths = try allocator.alloc([]const u8, 10000);
    defer allocator.free(paths);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const extensions = [_][]const u8{ ".zig", ".c", ".txt", ".md" };
    const dirs = [_][]const u8{ "src", "lib", "test", "docs" };
    const subdirs = [_][]const u8{ "utils", "core", "impl" };
    const names = [_][]const u8{ "main", "test", "helper", "lib" };

    for (0..10000) |i| {
        const depth = random.intRangeAtMost(usize, 1, 4);
        const ext = extensions[random.intRangeAtMost(usize, 0, extensions.len - 1)];
        const name = names[random.intRangeAtMost(usize, 0, names.len - 1)];

        var path_buf: [256]u8 = undefined;
        var path_len: usize = 0;

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

        @memcpy(path_buf[path_len..][0..name.len], name);
        path_len += name.len;
        @memcpy(path_buf[path_len..][0..ext.len], ext);
        path_len += ext.len;

        paths[i] = try allocator.dupe(u8, path_buf[0..path_len]);
    }
    defer for (paths) |path| allocator.free(path);

    std.debug.print("Running recursive pattern benchmark...\n", .{});
    std.debug.print("Pattern: **/*.zig on 10,000 paths\n\n", .{});

    // Warmup
    for (0..10) |_| {
        var result = try simdglob.matchPaths(allocator, "**/*.zig", paths, 0);
        result.deinit();
    }

    // Run 1000 iterations for profiling
    const iterations = 1000;
    for (0..iterations) |_| {
        var result = try simdglob.matchPaths(allocator, "**/*.zig", paths, 0);
        result.deinit();
    }

    std.debug.print("Completed {d} iterations\n", .{iterations});
}
