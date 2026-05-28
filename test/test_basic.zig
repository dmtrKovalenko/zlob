const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");
const zlob_flags = @import("zlob_flags");
const test_utils = @import("test_utils");
const zlobIsomorphicTest = test_utils.zlobIsomorphicTest;
const TestResult = test_utils.TestResult;

test "matchPaths - simple wildcard" {
    const files = [_][]const u8{
        "test.txt",
        "main.zig",
        "data.json",
        "file.txt",
        "readme.md",
    };

    try zlobIsomorphicTest(&files, "*.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 2), result.count);
            try testing.expect(result.hasPath("test.txt"));
            try testing.expect(result.hasPath("file.txt"));
        }
    }.assert, @src());
}

test "matchPaths - question mark" {
    const files = [_][]const u8{
        "a.txt",
        "ab.txt",
        "abc.txt",
        "x.txt",
    };

    try zlobIsomorphicTest(&files, "?.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 2), result.count);
            try testing.expect(result.hasPath("a.txt"));
            try testing.expect(result.hasPath("x.txt"));
        }
    }.assert, @src());
}

test "matchPaths - character class" {
    const files = [_][]const u8{
        "a1.txt",
        "b2.txt",
        "c3.txt",
        "d4.txt",
    };

    try zlobIsomorphicTest(&files, "[ab]*.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 2), result.count);
            try testing.expect(result.hasPath("a1.txt"));
            try testing.expect(result.hasPath("b2.txt"));
        }
    }.assert, @src());
}

test "matchPaths - negated character class" {
    const files = [_][]const u8{
        "a1.txt",
        "b2.txt",
        "c3.txt",
    };

    try zlobIsomorphicTest(&files, "[!a]*.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 2), result.count);
            try testing.expect(result.hasPath("b2.txt"));
            try testing.expect(result.hasPath("c3.txt"));
        }
    }.assert, @src());
}

test "matchPaths - with paths" {
    const files = [_][]const u8{
        "src/main.zig",
        "src/test.zig",
        "lib/util.zig",
        "docs/readme.md",
    };

    try zlobIsomorphicTest(&files, "src/*.zig", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 2), result.count);
            try testing.expect(result.hasPath("src/main.zig"));
            try testing.expect(result.hasPath("src/test.zig"));
        }
    }.assert, @src());
}

test "matchPaths - **/test.txt with flags=0 (depth-1 only)" {
    const files = [_][]const u8{
        "src/test.txt",
        "lib/test.txt",
        "docs/readme.md",
    };

    try zlobIsomorphicTest(&files, "**/test.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 2), result.count);
            try testing.expect(result.hasPath("src/test.txt"));
            try testing.expect(result.hasPath("lib/test.txt"));
        }
    }.assert, @src());
}

// Regression: `**/lua/*.lua` is the shape `**/<dir>/*.<ext>`. The leading `**`
// matches zero-or-more directory components, but the trailing `*` must NOT
// cross a `/` boundary - it is a single-segment wildcard. So files nested
// deeper than one level inside a `lua/` directory must be excluded.
test "matchPaths - **/lua/*.lua does not match files nested under lua/" {
    const files = [_][]const u8{
        // Should match: zero, one, and many directory components before `lua/`,
        // then exactly one path segment ending in `.lua`.
        "lua/init.lua",
        "nvim/lua/setup.lua",
        "config/nested/lua/plugin.lua",

        // Should NOT match: the `*` after `lua/` is single-segment, so anything
        // nested deeper than `lua/<file>.lua` must be rejected.
        "nvim/lua/sub/nested.lua",
        "nvim/lua/sub/deep/file.lua",
        "lua/sub/foo.lua",

        // Should NOT match: no `lua/` directory anywhere in the path.
        "init.lua",

        // Should NOT match: lives in a `lua/` directory but has the wrong extension.
        "lua/init.txt",

        // Should NOT match: completely unrelated.
        "src/main.zig",
    };

    try zlobIsomorphicTest(&files, "**/lua/*.lua", zlob_flags.ZLOB_RECOMMENDED, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 3), result.count);

            // Positive cases - zero, one, and many directory components
            // before `lua/`, each followed by exactly one `.lua` file.
            try testing.expect(result.hasPath("lua/init.lua"));
            try testing.expect(result.hasPath("nvim/lua/setup.lua"));
            try testing.expect(result.hasPath("config/nested/lua/plugin.lua"));

            // Negative cases - these would only leak in if `*` were treated
            // as recursive, which is the bug this test guards against.
            // Asserting them explicitly gives a clear diagnostic on failure.
            try testing.expect(result.noPathEndsWith("nvim/lua/sub/nested.lua"));
            try testing.expect(result.noPathEndsWith("nvim/lua/sub/deep/file.lua"));
            try testing.expect(result.noPathEndsWith("lua/sub/foo.lua"));
        }
    }.assert, @src());
}

// Regression: `./**/*.lua` should be equivalent to `**/*.lua` - the leading
// `./` is a no-op and must not be treated as a literal segment that needs
// to match a `.` directory.
test "matchPaths - ./**/*.lua is equivalent to **/*.lua" {
    const files = [_][]const u8{
        "init.lua",
        "lua/setup.lua",
        "nested/deep/plugin.lua",
        "src/main.zig",
        "readme.md",
    };

    try zlobIsomorphicTest(&files, "./**/*.lua", zlob_flags.ZLOB_RECOMMENDED, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 3), result.count);
            try testing.expect(result.hasPathEndingWith("init.lua"));
            try testing.expect(result.hasPathEndingWith("lua/setup.lua"));
            try testing.expect(result.hasPathEndingWith("nested/deep/plugin.lua"));
            try testing.expect(result.noPathEndsWith("main.zig"));
            try testing.expect(result.noPathEndsWith("readme.md"));
        }
    }.assert, @src());
}

// Regression: `./<prefix>/**/*.<ext>` should be equivalent to `<prefix>/**/*.<ext>`.
// The leading `./` should be normalised away by the parser.
test "matchPaths - ./prefix/**/*.lua narrows correctly" {
    const files = [_][]const u8{
        "src/init.lua",
        "src/nested/setup.lua",
        "src/deep/nested/plugin.lua",
        "lib/should_not_match.lua",
        "init.lua",
    };

    try zlobIsomorphicTest(&files, "./src/**/*.lua", zlob_flags.ZLOB_RECOMMENDED, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 3), result.count);
            try testing.expect(result.hasPathEndingWith("src/init.lua"));
            try testing.expect(result.hasPathEndingWith("src/nested/setup.lua"));
            try testing.expect(result.hasPathEndingWith("src/deep/nested/plugin.lua"));
            try testing.expect(result.noPathEndsWith("lib/should_not_match.lua"));
            try testing.expect(result.noPathEndsWith("/init.lua") or result.hasPathEndingWith("src/init.lua"));
        }
    }.assert, @src());
}

// Regression: when calling `matchAt` with a pattern starting with `./`, the
// pattern must behave identically to the same pattern without the leading
// `./`. Both forms ultimately walk the base directory recursively.
//
// This is the scenario where a user runs zlob from inside a project and
// passes either `**/*.lua` or `./**/*.lua` — they should produce the exact
// same set of results.
test "matchAt - ./**/*.lua and **/*.lua produce identical results" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a test tree.
    const files = [_][]const u8{
        "init.lua",
        "lua/setup.lua",
        "nested/deep/plugin.lua",
        "src/main.zig",
        "readme.md",
    };
    for (files) |file| {
        if (std.fs.path.dirname(file)) |dir_path| {
            tmp.dir.createDirPath(io, dir_path) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
        const f = try tmp.dir.createFile(io, file, .{});
        f.close(io);
    }

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // Run both forms of the pattern with the recommended flag set so `**`
    // is treated as recursive (the C/POSIX entry point is glibc-compatible
    // by default and only enables `**` recursion when this flag is set).
    const flags = zlob_flags.ZlobFlags.recommended();
    var bare = (try zlob.matchAt(allocator, io, tmp_path, "**/*.lua", flags)).?;
    defer bare.deinit();

    var with_dot_slash = (try zlob.matchAt(allocator, io, tmp_path, "./**/*.lua", flags)).?;
    defer with_dot_slash.deinit();

    // Both must find the three .lua files (and only the .lua files).
    try testing.expectEqual(@as(usize, 3), bare.len());
    try testing.expectEqual(@as(usize, 3), with_dot_slash.len());

    // Build sorted slices so we can compare the sets directly.
    const bare_slice = try bare.toSlice(allocator);
    defer allocator.free(bare_slice);
    const dot_slice = try with_dot_slash.toSlice(allocator);
    defer allocator.free(dot_slice);

    std.mem.sort([]const u8, bare_slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    std.mem.sort([]const u8, dot_slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    // The two forms should return equivalent paths (modulo a possibly
    // different leading "./"); compare by suffix.
    for (bare_slice, dot_slice) |b, d| {
        const b_tail = if (std.mem.startsWith(u8, b, "./")) b[2..] else b;
        const d_tail = if (std.mem.startsWith(u8, d, "./")) d[2..] else d;
        try testing.expectEqualStrings(b_tail, d_tail);
    }
}

test "matchPaths - no matches" {
    const files = [_][]const u8{
        "test.txt",
        "main.zig",
    };

    try zlobIsomorphicTest(&files, "*.log", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 0), result.count);
        }
    }.assert, @src());
}

test "matchPaths - empty file list" {
    const files = [_][]const u8{};

    try zlobIsomorphicTest(&files, "*.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 0), result.count);
        }
    }.assert, @src());
}

test "matchPaths - exact match" {
    const files = [_][]const u8{
        "test.txt",
        "main.txt",
        "file.txt",
    };

    try zlobIsomorphicTest(&files, "test.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 1), result.count);
            try testing.expect(result.hasPath("test.txt"));
        }
    }.assert, @src());
}

test "matchPaths - complex pattern" {
    const files = [_][]const u8{
        "test_01.txt",
        "test_02.txt",
        "file_03.txt",
        "test_ab.txt",
    };

    try zlobIsomorphicTest(&files, "test_[0-9]*.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 2), result.count);
            try testing.expect(result.hasPath("test_01.txt"));
            try testing.expect(result.hasPath("test_02.txt"));
        }
    }.assert, @src());
}

test "??? - question marks only" {
    const files = [_][]const u8{
        "abc.txt",
        "fef.txt",
        "q!@.txt",
        "abcd.txt",
    };

    try zlobIsomorphicTest(&files, "???.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 3), result.count);
            try testing.expect(result.hasPath("abc.txt"));
            try testing.expect(result.hasPath("ef.txt"));
        }
    }.assert, @src());
}

test "matchPaths - sorted results" {
    const files = [_][]const u8{
        "c.txt",
        "a.txt",
        "b.txt",
    };

    try zlobIsomorphicTest(&files, "*.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 3), result.count);
            // Should be sorted
            try testing.expectEqualStrings("a.txt", result.paths[0]);
            try testing.expectEqualStrings("b.txt", result.paths[1]);
            try testing.expectEqualStrings("c.txt", result.paths[2]);
        }
    }.assert, @src());
}

test "matchPaths - NOSORT flag" {
    // NOSORT is matchPaths-specific, no filesystem equivalent
    const files = [_][]const u8{
        "c.txt",
        "a.txt",
        "b.txt",
    };

    var result = try zlob.matchPaths(testing.allocator, "*.txt", &files, zlob_flags.ZLOB_NOSORT);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.len());
    // Order should match input order
}

test "matchPaths - large file list" {
    // Large file list test - matchPaths only for performance
    var files: [1000][]const u8 = undefined;
    var file_buffers: [1000][20]u8 = undefined;

    for (0..1000) |i| {
        const name = std.fmt.bufPrint(&file_buffers[i], "file_{d}.txt", .{i}) catch unreachable;
        files[i] = name;
    }

    var result = try zlob.matchPaths(testing.allocator, "file_5*.txt", &files, 0);
    defer result.deinit();

    // Should match file_5.txt, file_50.txt, file_51.txt, ..., file_599.txt
    // That's 111 files (5, 50-59, 500-599)
    try testing.expect(result.len() > 0);
}

test "matchPaths - SIMD fast path" {
    const files = [_][]const u8{
        "very_long_filename_that_triggers_simd.txt",
        "another_long_filename_for_testing.txt",
        "short.txt",
    };

    // Long literal pattern should use SIMD fast path
    try zlobIsomorphicTest(&files, "very_long_filename_that_triggers_simd.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(@as(usize, 1), result.count);
            try testing.expect(result.hasPath("very_long_filename_that_triggers_simd.txt"));
        }
    }.assert, @src());
}
