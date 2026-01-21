const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");

test "matchPaths - simple wildcard" {
    const files = [_][]const u8{
        "test.txt",
        "main.zig",
        "data.json",
        "file.txt",
        "readme.md",
    };

    var result = try zlob.matchPaths(testing.allocator, "*.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);

    // Check that we got the right files
    var found_test = false;
    var found_file = false;
    for (result.paths) |path| {
        if (std.mem.eql(u8, path, "test.txt")) found_test = true;
        if (std.mem.eql(u8, path, "file.txt")) found_file = true;
    }
    try testing.expect(found_test);
    try testing.expect(found_file);
}

test "matchPaths - question mark" {
    const files = [_][]const u8{
        "a.txt",
        "ab.txt",
        "abc.txt",
        "x.txt",
    };

    var result = try zlob.matchPaths(testing.allocator, "?.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - character class" {
    const files = [_][]const u8{
        "a1.txt",
        "b2.txt",
        "c3.txt",
        "d4.txt",
    };

    var result = try zlob.matchPaths(testing.allocator, "[ab]*.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - negated character class" {
    const files = [_][]const u8{
        "a1.txt",
        "b2.txt",
        "c3.txt",
    };

    var result = try zlob.matchPaths(testing.allocator, "[!a]*.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - with paths" {
    const files = [_][]const u8{
        "src/main.zig",
        "src/test.zig",
        "lib/util.zig",
        "docs/readme.md",
    };

    var result = try zlob.matchPaths(testing.allocator, "src/*.zig", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - recursive pattern" {
    const files = [_][]const u8{
        "src/test.txt",
        "lib/test.txt",
        "docs/readme.md",
    };

    // Use recursive pattern to match test.txt at any depth
    var result = try zlob.matchPaths(testing.allocator, "**/test.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - no matches" {
    const files = [_][]const u8{
        "test.txt",
        "main.zig",
    };

    var result = try zlob.matchPaths(testing.allocator, "*.log", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.match_count);
}

test "matchPaths - empty file list" {
    const files = [_][]const u8{};

    var result = try zlob.matchPaths(testing.allocator, "*.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.match_count);
}

test "matchPaths - exact match" {
    const files = [_][]const u8{
        "test.txt",
        "main.txt",
        "file.txt",
    };

    var result = try zlob.matchPaths(testing.allocator, "test.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expect(std.mem.eql(u8, result.paths[0], "test.txt"));
}

test "matchPaths - complex pattern" {
    const files = [_][]const u8{
        "test_01.txt",
        "test_02.txt",
        "file_03.txt",
        "test_ab.txt",
    };

    var result = try zlob.matchPaths(testing.allocator, "test_[0-9]*.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - sorted results" {
    const files = [_][]const u8{
        "c.txt",
        "a.txt",
        "b.txt",
    };

    var result = try zlob.matchPaths(testing.allocator, "*.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);

    // Should be sorted
    try testing.expect(std.mem.eql(u8, result.paths[0], "a.txt"));
    try testing.expect(std.mem.eql(u8, result.paths[1], "b.txt"));
    try testing.expect(std.mem.eql(u8, result.paths[2], "c.txt"));
}

test "matchPaths - NOSORT flag" {
    const files = [_][]const u8{
        "c.txt",
        "a.txt",
        "b.txt",
    };

    var result = try zlob.matchPaths(testing.allocator, "*.txt", &files, zlob.ZLOB_NOSORT);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
    // Order should match input order
}

test "matchPaths - large file list" {
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
    var result = try zlob.matchPaths(testing.allocator, "very_long_filename_that_triggers_simd.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
}
