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

test "matchPaths - recursive pattern" {
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

    try testing.expectEqual(@as(usize, 3), result.match_count);
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
    try testing.expect(result.match_count > 0);
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
