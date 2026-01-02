const std = @import("std");
const testing = std.testing;
const glob = @import("glob");
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
    defer if (result == 0) glob.globfree(testing.allocator, &pglob);

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
    defer if (result == 0) glob.globfree(testing.allocator, &pglob);

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
    defer if (result == 0) glob.globfree(testing.allocator, &pglob);

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
    defer if (result == 0) glob.globfree(testing.allocator, &pglob);

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
    defer if (result == 0) glob.globfree(testing.allocator, &pglob);

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
    defer glob.globfree(testing.allocator, &pglob);

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
    defer if (result == 0) glob.globfree(testing.allocator, &pglob);

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
