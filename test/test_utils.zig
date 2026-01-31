//! Test utilities for zlob tests
//!
//! Provides helpers for testing both in-memory matchPaths and filesystem-based match
//! with a unified interface.

const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");

/// Result wrapper for unified test assertions
pub const TestResult = struct {
    paths: []const []const u8,
    count: usize,

    /// Check if a specific path (or path suffix) exists in results
    pub fn hasPath(self: TestResult, expected: []const u8) bool {
        for (self.paths) |path| {
            if (std.mem.eql(u8, path, expected)) return true;
            // Also check if it ends with the expected (for absolute paths)
            if (std.mem.endsWith(u8, path, expected)) return true;
        }
        return false;
    }

    /// Check if any path ends with the given suffix
    pub fn hasPathEndingWith(self: TestResult, suffix: []const u8) bool {
        for (self.paths) |path| {
            if (std.mem.endsWith(u8, path, suffix)) return true;
        }
        return false;
    }

    /// Check that NO path ends with the given suffix
    pub fn noPathEndsWith(self: TestResult, suffix: []const u8) bool {
        for (self.paths) |path| {
            if (std.mem.endsWith(u8, path, suffix)) return false;
        }
        return true;
    }

    /// Check if any path contains the given substring
    pub fn hasPathContaining(self: TestResult, substr: []const u8) bool {
        for (self.paths) |path| {
            if (std.mem.indexOf(u8, path, substr) != null) return true;
        }
        return false;
    }

    /// Get all paths as a slice (for debugging)
    pub fn debugPrint(self: TestResult) void {
        std.debug.print("TestResult ({d} paths):\n", .{self.count});
        for (self.paths) |path| {
            std.debug.print("  - {s}\n", .{path});
        }
    }
};

/// Assertion function type for test validation
pub const AssertFn = *const fn (result: TestResult) anyerror!void;

/// Create directories recursively (like mkdir -p)
fn makeDirRecursive(path: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;

    for (path) |char| {
        path_buf[pos] = char;
        pos += 1;
        if (char == '/' and pos > 1) {
            std.fs.makeDirAbsolute(path_buf[0..pos]) catch |err| {
                if (err != error.PathAlreadyExists) continue;
            };
        }
    }
    std.fs.makeDirAbsolute(path_buf[0..pos]) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

/// Run a glob test against both matchPaths (in-memory) and filesystem match.
///
/// This helper:
/// 1. Tests the pattern against the provided file list using matchPaths
/// 2. Creates a temp directory with the files and tests filesystem glob
/// 3. Runs the assertion function against both results
///
/// Example:
/// ```zig
/// test "my pattern test" {
///     const files = [_][]const u8{ "foo.js", "bar.ts", "baz.zig" };
///     try zlobIsomorphicTest(&files, "*.@(js|ts)", zlob.ZLOB_EXTGLOB, struct {
///         fn assert(result: TestResult) !void {
///             try testing.expectEqual(@as(usize, 2), result.count);
///             try testing.expect(result.hasPath("foo.js"));
///             try testing.expect(result.hasPath("bar.ts"));
///         }
///     }.assert);
/// }
/// ```
pub fn zlobIsomorphicTest(
    comptime files: []const []const u8,
    pattern: []const u8,
    flags: u32,
    assertFn: AssertFn,
) !void {
    const allocator = testing.allocator;

    // ========================================
    // Part 1: Test with matchPaths (in-memory)
    // ========================================
    {
        var result = try zlob.matchPaths(allocator, pattern, files, flags);
        defer result.deinit();

        const test_result = TestResult{
            .paths = result.paths,
            .count = result.match_count,
        };

        try assertFn(test_result);
    }

    // ========================================
    // Part 2: Test with filesystem match
    // ========================================
    {
        // Create temp directory with unique name
        var tmp_dir_buf: [256]u8 = undefined;
        const tmp_dir = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/zlob_test_{d}", .{std.time.milliTimestamp()});

        // Create the temp directory
        std.fs.makeDirAbsolute(tmp_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

        // Create test files
        for (files) |file| {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, file });
            defer allocator.free(full_path);

            // Create all parent directories recursively
            if (std.fs.path.dirname(full_path)) |dir_path| {
                try makeDirRecursive(dir_path);
            }

            // Create the file
            const f = try std.fs.createFileAbsolute(full_path, .{});
            f.close();
        }

        // Build full pattern with temp dir prefix
        const full_pattern = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, pattern });
        defer allocator.free(full_pattern);

        // Run filesystem glob
        var fs_result_opt = try zlob.match(allocator, full_pattern, flags);
        if (fs_result_opt) |*fs_result| {
            defer fs_result.deinit();

            // Strip tmp_dir prefix from paths for comparison
            var stripped_paths = try allocator.alloc([]const u8, fs_result.match_count);
            defer allocator.free(stripped_paths);

            const prefix_len = tmp_dir.len + 1; // +1 for the '/'
            for (fs_result.paths, 0..) |path, i| {
                if (path.len > prefix_len and std.mem.startsWith(u8, path, tmp_dir)) {
                    stripped_paths[i] = path[prefix_len..];
                } else {
                    stripped_paths[i] = path;
                }
            }

            const test_result = TestResult{
                .paths = stripped_paths,
                .count = fs_result.match_count,
            };

            try assertFn(test_result);
        } else {
            // No matches - create empty result
            const test_result = TestResult{
                .paths = &[_][]const u8{},
                .count = 0,
            };
            try assertFn(test_result);
        }
    }
}

/// Run a glob test against matchPaths only (no filesystem).
/// Useful for testing patterns with special characters that can't be filenames.
pub fn testMatchPathsOnly(
    comptime files: []const []const u8,
    pattern: []const u8,
    flags: u32,
    assertFn: AssertFn,
) !void {
    const allocator = testing.allocator;

    var result = try zlob.matchPaths(allocator, pattern, files, flags);
    defer result.deinit();

    const test_result = TestResult{
        .paths = result.paths,
        .count = result.match_count,
    };

    try assertFn(test_result);
}

/// Run a glob test against filesystem only (no matchPaths).
/// Useful when you need to test against an existing directory structure.
pub fn testFilesystemOnly(
    dir_path: []const u8,
    pattern: []const u8,
    flags: u32,
    assertFn: AssertFn,
) !void {
    const allocator = testing.allocator;

    // Build full pattern
    const full_pattern = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, pattern });
    defer allocator.free(full_pattern);

    var fs_result_opt = try zlob.match(allocator, full_pattern, flags);
    if (fs_result_opt) |*fs_result| {
        defer fs_result.deinit();

        const test_result = TestResult{
            .paths = fs_result.paths,
            .count = fs_result.match_count,
        };

        try assertFn(test_result);
    } else {
        const test_result = TestResult{
            .paths = &[_][]const u8{},
            .count = 0,
        };
        try assertFn(test_result);
    }
}
