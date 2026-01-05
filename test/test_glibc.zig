const std = @import("std");
const testing = std.testing;
const glob = @import("c_lib");
const c = std.c;

// Helper to create test directory structure
fn createTestDirStructure(allocator: std.mem.Allocator, base_path: []const u8) !void {
    const dirs = [_][]const u8{
        "test_glob_recursive",
        "test_glob_recursive/dir1",
        "test_glob_recursive/dir1/subdir1",
        "test_glob_recursive/dir1/subdir2",
        "test_glob_recursive/dir2",
        "test_glob_recursive/dir2/subdir1",
        "test_glob_recursive/dir2/subdir1/deep",
        "test_glob_recursive/dir3",
    };

    const files = [_][]const u8{
        "test_glob_recursive/file1.c",
        "test_glob_recursive/file2.txt",
        "test_glob_recursive/dir1/file1.c",
        "test_glob_recursive/dir1/file2.h",
        "test_glob_recursive/dir1/subdir1/file1.c",
        "test_glob_recursive/dir1/subdir1/file2.c",
        "test_glob_recursive/dir1/subdir2/file1.txt",
        "test_glob_recursive/dir2/file1.c",
        "test_glob_recursive/dir2/subdir1/file1.c",
        "test_glob_recursive/dir2/subdir1/deep/file1.c",
        "test_glob_recursive/dir2/subdir1/deep/file2.c",
        "test_glob_recursive/dir3/file1.h",
    };

    // Create base directory
    var base_buf: [4096:0]u8 = undefined;
    @memcpy(base_buf[0..base_path.len], base_path);
    base_buf[base_path.len] = 0;

    // Create all directories
    for (dirs) |dir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, dir });
        defer allocator.free(full_path);

        var path_z: [4096:0]u8 = undefined;
        @memcpy(path_z[0..full_path.len], full_path);
        path_z[full_path.len] = 0;
        _ = c.mkdir(&path_z, 0o755);
    }

    // Create all files
    for (files) |file| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, file });
        defer allocator.free(full_path);

        const f = std.fs.cwd().createFile(full_path, .{}) catch continue;
        defer f.close();
        const content = "test content\n";
        _ = f.write(content) catch {};
    }
}

// Helper to cleanup test directory structure
fn cleanupTestDirStructure(allocator: std.mem.Allocator, base_path: []const u8) !void {
    const full_path_str = try std.fmt.allocPrint(allocator, "{s}/test_glob_recursive", .{base_path});
    defer allocator.free(full_path_str);

    var full_path: [4096:0]u8 = undefined;
    @memcpy(full_path[0..full_path_str.len], full_path_str);
    full_path[full_path_str.len] = 0;

    // Use system rm -rf to recursively delete
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "rm", "-rf", full_path_str },
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

// Tests for recursive glob patterns (**)

test "recursive glob - **/*.c finds all C files" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestDirStructure(allocator, tmp_dir);
    defer cleanupTestDirStructure(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_glob_recursive", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    // Save current directory
    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);

    // Change to test directory
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "**/*.c");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(testing.allocator, pattern.ptr, 0, null, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    // Should find 8 .c files:
    // file1.c, dir1/file1.c, dir1/subdir1/file1.c, dir1/subdir1/file2.c,
    // dir2/file1.c, dir2/subdir1/file1.c, dir2/subdir1/deep/file1.c, dir2/subdir1/deep/file2.c
    try testing.expectEqual(@as(usize, 8), pglob.gl_pathc);
}

test "recursive glob - dir1/**/*.c finds C files in dir1" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestDirStructure(allocator, tmp_dir);
    defer cleanupTestDirStructure(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_glob_recursive", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "dir1/**/*.c");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(testing.allocator, pattern.ptr, 0, null, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    // Should find 3 .c files: dir1/file1.c, dir1/subdir1/file1.c, dir1/subdir1/file2.c
    try testing.expectEqual(@as(usize, 3), pglob.gl_pathc);
}

test "recursive glob - **/*.h finds all header files" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestDirStructure(allocator, tmp_dir);
    defer cleanupTestDirStructure(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_glob_recursive", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "**/*.h");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(testing.allocator, pattern.ptr, 0, null, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    // Should find 2 .h files: dir1/file2.h, dir3/file1.h
    try testing.expectEqual(@as(usize, 2), pglob.gl_pathc);
}

test "recursive glob - dir2/**/*.c finds files in dir2 subdirectories" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestDirStructure(allocator, tmp_dir);
    defer cleanupTestDirStructure(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_glob_recursive", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "dir2/**/*.c");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(testing.allocator, pattern.ptr, 0, null, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    // Should find 3 .c files: dir2/file1.c, dir2/subdir1/file1.c, dir2/subdir1/deep/file1.c, dir2/subdir1/deep/file2.c
    try testing.expectEqual(@as(usize, 4), pglob.gl_pathc);
}

test "recursive glob - **/*.txt finds all text files" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestDirStructure(allocator, tmp_dir);
    defer cleanupTestDirStructure(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_glob_recursive", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "**/*.txt");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(testing.allocator, pattern.ptr, 0, null, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    // Should find 2 .txt files: file2.txt, dir1/subdir2/file1.txt
    try testing.expectEqual(@as(usize, 2), pglob.gl_pathc);
}

test "recursive glob - no matches returns GLOB_NOMATCH" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestDirStructure(allocator, tmp_dir);
    defer cleanupTestDirStructure(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_glob_recursive", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "**/*.nonexistent");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(testing.allocator, pattern.ptr, 0, null, &pglob);

    // Recursive glob returns GLOB_NOMATCH when no matches found (consistent with glibc)
    try testing.expectEqual(@as(c_int, glob.GLOB_NOMATCH), result);
}

test "recursive glob - GLOB_APPEND correctly accumulates results" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestDirStructure(allocator, tmp_dir);
    defer cleanupTestDirStructure(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_glob_recursive", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    var pglob: glob.glob_t = undefined;

    // First glob for .c files
    const pattern1 = try allocator.dupeZ(u8, "**/*.c");
    defer allocator.free(pattern1);
    const result1 = glob.glob_c(testing.allocator, pattern1.ptr, 0, null, &pglob);
    try testing.expectEqual(@as(c_int, 0), result1);
    const first_count = pglob.gl_pathc;
    try testing.expectEqual(@as(usize, 8), first_count);

    // Second glob for .h files with GLOB_APPEND
    const pattern2 = try allocator.dupeZ(u8, "**/*.h");
    defer allocator.free(pattern2);
    const result2 = glob.glob_c(testing.allocator, pattern2.ptr, glob.GLOB_APPEND, null, &pglob);
    defer glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result2);
    // Should have 8 .c files + 2 .h files = 10 total
    try testing.expectEqual(@as(usize, 10), pglob.gl_pathc);
}

test "recursive glob - empty pattern component" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestDirStructure(allocator, tmp_dir);
    defer cleanupTestDirStructure(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_glob_recursive", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "**/");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(testing.allocator, pattern.ptr, 0, null, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    // Should handle gracefully, either finding directories or returning NOMATCH
    try testing.expect(result == 0 or result == glob.GLOB_NOMATCH);
}

// Tests for pattern analysis and optimization

test "analyzePattern - simple pattern" {
    const pattern = "src/foo/*.c";
    const info = glob.analyzePattern(pattern, 0);

    try testing.expectEqualStrings("src/foo", info.literal_prefix);
    try testing.expectEqualStrings("*.c", info.wildcard_suffix);
    try testing.expectEqual(false, info.has_recursive);
    try testing.expectEqualStrings(".c", info.simple_extension.?);
}

test "analyzePattern - recursive pattern" {
    const pattern = "arch/x86/**/*.c";
    const info = glob.analyzePattern(pattern, 0);

    try testing.expectEqualStrings("arch/x86", info.literal_prefix);
    try testing.expectEqualStrings("**/*.c", info.wildcard_suffix);
    try testing.expectEqual(true, info.has_recursive);
    // Recursive patterns don't use simple_extension optimization
    try testing.expectEqual(@as(?[]const u8, null), info.simple_extension);
}

test "analyzePattern - no literal prefix" {
    const pattern = "**/*.c";
    const info = glob.analyzePattern(pattern, 0);

    try testing.expectEqualStrings("", info.literal_prefix);
    try testing.expectEqualStrings("**/*.c", info.wildcard_suffix);
    try testing.expectEqual(true, info.has_recursive);
    // Recursive patterns don't use simple_extension optimization
    try testing.expectEqual(@as(?[]const u8, null), info.simple_extension);
}

test "analyzePattern - no wildcards" {
    const pattern = "src/main.c";
    const info = glob.analyzePattern(pattern, 0);

    // When pattern has a slash but no wildcards, it treats the last component as wildcard suffix
    // This is a quirk of the implementation but doesn't affect glob functionality
    try testing.expectEqualStrings("src", info.literal_prefix);
    try testing.expectEqualStrings("main.c", info.wildcard_suffix);
    try testing.expectEqual(false, info.has_recursive);
}

test "analyzePattern - complex extension" {
    const pattern = "docs/**/*.md";
    const info = glob.analyzePattern(pattern, 0);

    try testing.expectEqualStrings("docs", info.literal_prefix);
    try testing.expectEqualStrings("**/*.md", info.wildcard_suffix);
    try testing.expectEqual(true, info.has_recursive);
    // Recursive patterns don't use simple_extension optimization
    try testing.expectEqual(@as(?[]const u8, null), info.simple_extension);
}

test "analyzePattern - multiple wildcards no simple extension" {
    const pattern = "src/**/test_*.c";
    const info = glob.analyzePattern(pattern, 0);

    try testing.expectEqualStrings("src", info.literal_prefix);
    try testing.expectEqualStrings("**/test_*.c", info.wildcard_suffix);
    try testing.expectEqual(true, info.has_recursive);
    try testing.expectEqual(@as(?[]const u8, null), info.simple_extension);
}

// Tests for matchPaths C API (zero-copy filtering)

test "glob_match_paths - basic filtering" {
    const paths = [_][*:0]const u8{
        "foo.txt",
        "bar.c",
        "baz.txt",
        "test.h",
    };

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_match_paths("*.txt", &paths, paths.len, 0, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 2), pglob.gl_pathc);

    // Verify matches (order not guaranteed, so check for presence)
    const path0 = std.mem.sliceTo(pglob.gl_pathv[0], 0);
    const path1 = std.mem.sliceTo(pglob.gl_pathv[1], 0);

    const has_foo = std.mem.eql(u8, path0, "foo.txt") or std.mem.eql(u8, path1, "foo.txt");
    const has_baz = std.mem.eql(u8, path0, "baz.txt") or std.mem.eql(u8, path1, "baz.txt");
    try testing.expect(has_foo);
    try testing.expect(has_baz);

    // Verify lengths are correct (both should be 7)
    try testing.expectEqual(@as(usize, 7), pglob.gl_pathlen[0]);
    try testing.expectEqual(@as(usize, 7), pglob.gl_pathlen[1]);
}

test "glob_match_paths - zero-copy semantics" {
    const paths = [_][*:0]const u8{
        "test.txt",
        "main.c",
    };

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_match_paths("*.txt", &paths, paths.len, 0, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 1), pglob.gl_pathc);

    // Verify pointer references original memory (zero-copy!)
    try testing.expectEqual(paths[0], @as([*:0]const u8, @ptrCast(pglob.gl_pathv[0])));
}

test "glob_match_paths - no matches returns GLOB_NOMATCH" {
    const paths = [_][*:0]const u8{
        "foo.txt",
        "bar.txt",
    };

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_match_paths("*.c", &paths, paths.len, 0, &pglob);

    try testing.expectEqual(@as(c_int, glob.GLOB_NOMATCH), result);
}

test "glob_match_paths - complex pattern" {
    const paths = [_][*:0]const u8{
        "src/main.c",
        "src/test.h",
        "test/unit_test.c",
        "docs/readme.md",
    };

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_match_paths("*/*.c", &paths, paths.len, 0, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 2), pglob.gl_pathc);
}

test "glob_match_paths_slice - basic filtering" {
    const path_strings = [_][]const u8{
        "foo.txt",
        "bar.c",
        "baz.txt",
        "test.h",
    };

    // Create slice array
    var path_slices: [4]glob.zlob_slice_t = undefined;
    for (path_strings, 0..) |str, i| {
        path_slices[i] = glob.zlob_slice_t{
            .ptr = str.ptr,
            .len = str.len,
        };
    }

    const pattern = glob.zlob_slice_t{
        .ptr = "*.txt".ptr,
        .len = 5,
    };

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_match_paths_slice(&pattern, &path_slices, path_slices.len, 0, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 2), pglob.gl_pathc);

    // Verify matches (order not guaranteed, so check for presence)
    const path0 = pglob.gl_pathv[0][0..pglob.gl_pathlen[0]];
    const path1 = pglob.gl_pathv[1][0..pglob.gl_pathlen[1]];

    const has_foo = std.mem.eql(u8, path0, "foo.txt") or std.mem.eql(u8, path1, "foo.txt");
    const has_baz = std.mem.eql(u8, path0, "baz.txt") or std.mem.eql(u8, path1, "baz.txt");
    try testing.expect(has_foo);
    try testing.expect(has_baz);
}

test "glob_match_paths_slice - zero-copy semantics" {
    const path_strings = [_][]const u8{
        "test.txt",
        "main.c",
    };

    var path_slices: [2]glob.zlob_slice_t = undefined;
    for (path_strings, 0..) |str, i| {
        path_slices[i] = glob.zlob_slice_t{
            .ptr = str.ptr,
            .len = str.len,
        };
    }

    const pattern = glob.zlob_slice_t{
        .ptr = "*.txt".ptr,
        .len = 5,
    };

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_match_paths_slice(&pattern, &path_slices, path_slices.len, 0, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 1), pglob.gl_pathc);

    // Verify pointer references original memory (zero-copy!)
    try testing.expectEqual(path_strings[0].ptr, @as([*]const u8, @ptrCast(pglob.gl_pathv[0])));
}

test "glob_match_paths_slice - recursive pattern" {
    const path_strings = [_][]const u8{
        "src/main.c",
        "src/test/unit.c",
        "docs/readme.md",
        "lib/helpers.c",
    };

    var path_slices: [4]glob.zlob_slice_t = undefined;
    for (path_strings, 0..) |str, i| {
        path_slices[i] = glob.zlob_slice_t{
            .ptr = str.ptr,
            .len = str.len,
        };
    }

    const pattern = glob.zlob_slice_t{
        .ptr = "**/*.c".ptr,
        .len = 6,
    };

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_match_paths_slice(&pattern, &path_slices, path_slices.len, 0, &pglob);
    defer if (result == 0) glob.globfreeZ(testing.allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 3), pglob.gl_pathc);
}

test "globfreeZ - only frees arrays not strings" {
    const paths = [_][*:0]const u8{
        "test.txt",
        "main.c",
    };

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_match_paths("*.txt", &paths, paths.len, 0, &pglob);
    try testing.expectEqual(@as(c_int, 0), result);

    // Free should work without issues (doesn't try to free caller's memory)
    glob.globfreeZ(testing.allocator, &pglob);

    // Verify glob_t was reset
    try testing.expectEqual(@as(usize, 0), pglob.gl_pathc);
    try testing.expectEqual(@as(?[*][*c]u8, null), pglob.gl_pathv);
}
