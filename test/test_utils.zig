const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const zlob = @import("zlob");

pub const TestResult = struct {
    paths: []const []const u8,
    count: usize,

    pub fn hasPath(self: TestResult, expected: []const u8) bool {
        for (self.paths) |path| {
            if (std.mem.eql(u8, path, expected)) return true;
            // Also check if it ends with the expected (for absolute paths)
            if (std.mem.endsWith(u8, path, expected)) return true;
        }
        return false;
    }

    pub fn hasPathEndingWith(self: TestResult, suffix: []const u8) bool {
        for (self.paths) |path| {
            if (std.mem.endsWith(u8, path, suffix)) return true;
        }
        return false;
    }

    pub fn noPathEndsWith(self: TestResult, suffix: []const u8) bool {
        for (self.paths) |path| {
            if (std.mem.endsWith(u8, path, suffix)) return false;
        }
        return true;
    }

    pub fn hasPathContaining(self: TestResult, substr: []const u8) bool {
        for (self.paths) |path| {
            if (std.mem.indexOf(u8, path, substr) != null) return true;
        }
        return false;
    }

    pub fn debugPrint(self: TestResult) void {
        std.debug.print("TestResult ({d} paths):\n", .{self.count});
        for (self.paths) |path| {
            std.debug.print("  - {s}\n", .{path});
        }
    }
};

pub const AssertFn = *const fn (result: TestResult) anyerror!void;

/// Convert backslashes to forward slashes in-place. zlob's parser accepts
/// either separator on Windows (per README.md:17), but its assertion-side
/// outputs are normalised to whatever the OS produced. Tests in this suite
/// always assert against forward-slash literals, so we normalise both the
/// absolute prefix used in the pattern and any result paths returned by zlob.
fn normalizeSlashes(buf: []u8) void {
    if (builtin.os.tag != .windows) return;
    for (buf) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
}

/// Run a glob test against both matchPaths (in-memory) and filesystem match.
///
/// This helper:
/// 1. Tests the pattern against the provided file list using matchPaths
/// 2. Creates a temp directory with the files and tests filesystem glob
/// 3. Runs the assertion function against both results
///
/// Cross-platform: uses `std.testing.tmpDir` rather than a hardcoded `/tmp`,
/// so the same tests pass on Linux, macOS, and Windows. Path separators in
/// the absolute prefix and in zlob's filesystem results are normalised to
/// forward slashes so test assertions can use POSIX-style literals.
///
/// Example:
/// ```zig
/// test "my pattern test" {
///     const files = [_][]const u8{ "foo.js", "bar.ts", "baz.zig" };
///     try zlobIsomorphicTest(&files, "*.@(js|ts)", zlob.ZLOB_EXTGLOB, struct {
///         fn assert(result: TestResult) !void {
///             try testing.expectEqual(@as(usize, 2), result.count);
///             try testing.expect(result.hasPath("foo.js")); try testing.expect(result.hasPath("bar.ts"));
///         }
///     }.assert);
/// }
/// ```
pub fn zlobIsomorphicTest(
    comptime files: []const []const u8,
    pattern: []const u8,
    flags: u32,
    assertFn: AssertFn,
    src: std.builtin.SourceLocation,
) !void {
    _ = src; // tmp dir uniqueness is now provided by std.testing.tmpDir.
    const allocator = testing.allocator;

    // ========================================
    // Part 1: Test with matchPaths (in-memory)
    // ========================================
    {
        var result = try zlob.matchPaths(allocator, pattern, files, flags);
        defer result.deinit();

        const result_slice = try result.toSlice(allocator);
        defer allocator.free(result_slice);

        const test_result = TestResult{
            .paths = result_slice,
            .count = result.len(),
        };

        try assertFn(test_result);
    }

    // ========================================
    // Part 2: Test with filesystem match
    // ========================================
    {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Cross-platform tmp dir: /tmp/... on POSIX, %TEMP%\... on Windows.
        // Cleanup is automatic on scope exit.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        // Resolve to an absolute path so the glob pattern is unambiguous.
        const tmp_path_z = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path_z);
        const tmp_path = tmp_path_z[0..tmp_path_z.len];
        normalizeSlashes(tmp_path);

        // Create test files relative to the tmp dir. createDirPath handles
        // arbitrary depth and is portable across separators.
        for (files) |file| {
            if (std.fs.path.dirname(file)) |dir_path| {
                tmp.dir.createDirPath(io, dir_path) catch |err| {
                    if (err != error.PathAlreadyExists) return err;
                };
            }
            const f = try tmp.dir.createFile(io, file, .{});
            f.close(io);
        }

        // Build the absolute pattern with forward slashes, which zlob accepts
        // on every platform (see src/zlob.zig:392-396 for Windows handling).
        const full_pattern = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_path, pattern });
        defer allocator.free(full_pattern);

        var fs_result_opt = try zlob.match(allocator, io, full_pattern, flags);
        if (fs_result_opt) |*fs_result| {
            defer fs_result.deinit();

            const result_len = fs_result.len();
            // Allocate owned, normalised copies so we can rewrite separators
            // without mutating the result-managed memory.
            var owned_paths = try allocator.alloc([]u8, result_len);
            defer {
                for (owned_paths) |p| allocator.free(p);
                allocator.free(owned_paths);
            }
            var stripped_paths = try allocator.alloc([]const u8, result_len);
            defer allocator.free(stripped_paths);

            const prefix_len = tmp_path.len + 1; // +1 for the '/'
            for (0..result_len) |i| {
                owned_paths[i] = try allocator.dupe(u8, fs_result.get(i));
                normalizeSlashes(owned_paths[i]);
                if (owned_paths[i].len > prefix_len and std.mem.startsWith(u8, owned_paths[i], tmp_path)) {
                    stripped_paths[i] = owned_paths[i][prefix_len..];
                } else {
                    stripped_paths[i] = owned_paths[i];
                }
            }

            const test_result = TestResult{
                .paths = stripped_paths,
                .count = result_len,
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

pub fn testMatchPathsOnly(
    comptime files: []const []const u8,
    pattern: []const u8,
    flags: u32,
    assertFn: AssertFn,
) !void {
    const allocator = testing.allocator;

    var result = try zlob.matchPaths(allocator, pattern, files, flags);
    defer result.deinit();

    const result_slice = try result.toSlice(allocator);
    defer allocator.free(result_slice);

    const test_result = TestResult{
        .paths = result_slice,
        .count = result.len(),
    };

    try assertFn(test_result);
}

pub fn testFilesystemOnly(
    dir_path: []const u8,
    pattern: []const u8,
    flags: u32,
    assertFn: AssertFn,
) !void {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Build full pattern
    const full_pattern = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, pattern });
    defer allocator.free(full_pattern);

    var fs_result_opt = try zlob.match(allocator, io, full_pattern, flags);
    if (fs_result_opt) |*fs_result| {
        defer fs_result.deinit();

        const result_slice = try fs_result.toSlice(allocator);
        defer allocator.free(result_slice);

        const test_result = TestResult{
            .paths = result_slice,
            .count = fs_result.len(),
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
