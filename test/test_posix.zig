const std = @import("std");
const testing = std.testing;
const glob = @import("glob");
const c = std.c;

// Test structure helper
fn createTestFiles(allocator: std.mem.Allocator, base_path: []const u8) !void {
    const dirs = [_][]const u8{
        "test_missing_flags",
        "test_missing_flags/dir1",
        "test_missing_flags/dir2",
        "test_missing_flags/.hidden_dir",
    };

    const files = [_][]const u8{
        "test_missing_flags/file1.txt",
        "test_missing_flags/file2.c",
        "test_missing_flags/.hidden_file",
        "test_missing_flags/dir1/file3.txt",
        "test_missing_flags/dir2/file4.c",
        "test_missing_flags/.hidden_dir/file5.txt",
    };

    // Create directories
    for (dirs) |dir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, dir });
        defer allocator.free(full_path);

        var path_z: [4096:0]u8 = undefined;
        @memcpy(path_z[0..full_path.len], full_path);
        path_z[full_path.len] = 0;
        _ = c.mkdir(&path_z, 0o755);
    }

    // Create files
    for (files) |file| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, file });
        defer allocator.free(full_path);

        const f = std.fs.cwd().createFile(full_path, .{}) catch continue;
        defer f.close();
        const content = "test content\n";
        _ = f.write(content) catch {};
    }
}

fn cleanupTestFiles(allocator: std.mem.Allocator, base_path: []const u8) !void {
    const full_path_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{base_path});
    defer allocator.free(full_path_str);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "rm", "-rf", full_path_str },
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

// ============================================================================
// GLOB_MARK - Append '/' to directories
// ============================================================================

test "GLOB_MARK - appends slash to directories" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, glob.GLOB_MARK, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expect(pglob.gl_pathc >= 3); // At least 3 directories

    // Count directories with trailing slash
    var dir_with_slash_count: usize = 0;
    for (0..pglob.gl_pathc) |i| {
        const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
        if (path.len > 0 and path[path.len - 1] == '/') {
            dir_with_slash_count += 1;
        }
    }

    // Should have at least 2 directories with slashes (dir1/, dir2/)
    // .hidden_dir may or may not be matched depending on other logic
    try testing.expect(dir_with_slash_count >= 2);
}

test "GLOB_MARK - does not append slash to files" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*.txt");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, glob.GLOB_MARK, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expect(pglob.gl_pathc >= 1);

    // Files should NOT have trailing slash
    for (0..pglob.gl_pathc) |i| {
        const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
        try testing.expect(path.len == 0 or path[path.len - 1] != '/');
    }
}

test "GLOB_MARK - works with recursive glob" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
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
    const result = glob.glob_c(allocator, pattern.ptr, glob.GLOB_MARK, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expect(result == 0 or result == glob.GLOB_NOMATCH);
    if (result == 0) {
        // All matches should be directories with trailing slash
        for (0..pglob.gl_pathc) |i| {
            const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
            try testing.expect(path.len > 0 and path[path.len - 1] == '/');
        }
    }
}

// ============================================================================
// GLOB_DOOFFS - Reserve gl_offs slots at beginning
// ============================================================================

test "GLOB_DOOFFS - reserves offset slots at beginning" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*.txt");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    pglob.gl_offs = 3; // Request 3 offset slots

    const result = glob.glob_c(allocator, pattern.ptr, glob.GLOB_DOOFFS, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expect(pglob.gl_pathc >= 1);

    // First gl_offs entries should be NULL
    try testing.expect(pglob.gl_pathv[0] == null);
    try testing.expect(pglob.gl_pathv[1] == null);
    try testing.expect(pglob.gl_pathv[2] == null);

    // First actual match should be at gl_pathv[gl_offs]
    const first_match = pglob.gl_pathv[pglob.gl_offs];
    try testing.expect(first_match != null);
    const path = std.mem.sliceTo(first_match, 0);
    try testing.expect(path.len > 0);
    try testing.expect(std.mem.endsWith(u8, path, ".txt"));
}

test "GLOB_DOOFFS - works with GLOB_APPEND" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    var pglob: glob.glob_t = undefined;
    pglob.gl_offs = 2;

    // First glob
    const pattern1 = try allocator.dupeZ(u8, "*.txt");
    defer allocator.free(pattern1);
    const result1 = glob.glob_c(allocator, pattern1.ptr, glob.GLOB_DOOFFS, null, &pglob);
    try testing.expectEqual(@as(c_int, 0), result1);
    const first_count = pglob.gl_pathc;

    // Second glob with APPEND
    const pattern2 = try allocator.dupeZ(u8, "*.c");
    defer allocator.free(pattern2);
    const result2 = glob.glob_c(allocator, pattern2.ptr, glob.GLOB_DOOFFS | glob.GLOB_APPEND, null, &pglob);
    defer glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result2);
    try testing.expect(pglob.gl_pathc > first_count);

    // Offset slots still NULL
    try testing.expect(pglob.gl_pathv[0] == null);
    try testing.expect(pglob.gl_pathv[1] == null);
}

// ============================================================================
// GLOB_PERIOD - Allow leading '.' to match metacharacters
// ============================================================================

test "GLOB_PERIOD - matches hidden files with wildcard" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    // Define GLOB_PERIOD
    const GLOB_PERIOD: c_int = 0x0080;

    const pattern = try allocator.dupeZ(u8, "*");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, GLOB_PERIOD, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);

    // Count matches that start with '.'
    var hidden_count: usize = 0;
    for (0..pglob.gl_pathc) |i| {
        const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
        if (path.len > 0 and path[0] == '.') {
            hidden_count += 1;
        }
    }

    // Should match .hidden_file and .hidden_dir
    try testing.expect(hidden_count >= 1);
}

test "GLOB_PERIOD - without flag does not match hidden files" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, 0, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);

    // Should NOT match hidden files
    for (0..pglob.gl_pathc) |i| {
        const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
        try testing.expect(path.len == 0 or path[0] != '.');
    }
}

test "GLOB_PERIOD - explicit dot still matches" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, ".*");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, 0, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);

    // Should match hidden files even without GLOB_PERIOD
    var hidden_count: usize = 0;
    for (0..pglob.gl_pathc) |i| {
        const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
        if (path.len > 0 and path[0] == '.') {
            hidden_count += 1;
        }
    }
    try testing.expect(hidden_count >= 1);
}

// ============================================================================
// GLOB_TILDE - Expand tilde (~) to home directory
// ============================================================================

test "GLOB_TILDE - expands tilde to home directory" {
    const allocator = testing.allocator;

    // Get $HOME environment variable
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;

    // Create a test file in home directory
    const test_file = try std.fmt.allocPrint(allocator, "{s}/.glob_test_tilde_12345.txt", .{home});
    defer allocator.free(test_file);

    const f = std.fs.cwd().createFile(test_file, .{}) catch return error.SkipZigTest;
    f.close();
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const pattern = try allocator.dupeZ(u8, "~/.glob_test_tilde_*.txt");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, glob.GLOB_TILDE, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 1), pglob.gl_pathc);

    const matched_path = std.mem.sliceTo(pglob.gl_pathv[0], 0);
    try testing.expect(std.mem.startsWith(u8, matched_path, home));
}

test "GLOB_TILDE - expands ~username to user home" {
    const allocator = testing.allocator;

    // Get current username
    const username = std.posix.getenv("USER") orelse return error.SkipZigTest;
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;

    // Create test file
    const test_file = try std.fmt.allocPrint(allocator, "{s}/.glob_test_user_12345.txt", .{home});
    defer allocator.free(test_file);

    const f = std.fs.cwd().createFile(test_file, .{}) catch return error.SkipZigTest;
    f.close();
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const pattern_str = try std.fmt.allocPrint(allocator, "~{s}/.glob_test_user_*.txt", .{username});
    defer allocator.free(pattern_str);

    const pattern = try allocator.dupeZ(u8, pattern_str);
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, glob.GLOB_TILDE, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 1), pglob.gl_pathc);

    const matched_path = std.mem.sliceTo(pglob.gl_pathv[0], 0);
    try testing.expect(std.mem.startsWith(u8, matched_path, home));
}

test "GLOB_TILDE - without flag treats tilde as literal" {
    const allocator = testing.allocator;

    const pattern = try allocator.dupeZ(u8, "~/*.txt");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, 0, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    // Without GLOB_TILDE, should try to find literal ~ directory
    // Most likely GLOB_NOMATCH or GLOB_ABORTED
    try testing.expect(result == glob.GLOB_NOMATCH or result == glob.GLOB_ABORTED);
}

// ============================================================================
// GLOB_TILDE_CHECK - Error if username not found
// ============================================================================

test "GLOB_TILDE_CHECK - errors on nonexistent username" {
    const allocator = testing.allocator;

    const pattern = try allocator.dupeZ(u8, "~nonexistentuser99999/*.txt");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, glob.GLOB_TILDE | glob.GLOB_TILDE_CHECK, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    // Should return GLOB_NOMATCH for nonexistent user
    try testing.expectEqual(@as(c_int, glob.GLOB_NOMATCH), result);
}

test "GLOB_TILDE_CHECK - without flag returns tilde literal on unknown user" {
    const allocator = testing.allocator;

    const pattern = try allocator.dupeZ(u8, "~nonexistentuser99999");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, glob.GLOB_TILDE | glob.GLOB_NOCHECK, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    // Without GLOB_TILDE_CHECK, should fall back to literal tilde
    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 1), pglob.gl_pathc);

    const path = std.mem.sliceTo(pglob.gl_pathv[0], 0);
    try testing.expect(std.mem.startsWith(u8, path, "~nonexistentuser99999"));
}

// ============================================================================
// GLOB_NOMAGIC - Return nothing if no magic and no match
// ============================================================================

test "GLOB_NOMAGIC - returns NOMATCH for literal with no match" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const GLOB_NOMAGIC: c_int = 0x0200;

    // Literal pattern (no wildcards) that doesn't exist
    const pattern = try allocator.dupeZ(u8, "nonexistent.txt");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, GLOB_NOMAGIC, null, &pglob);

    try testing.expectEqual(@as(c_int, glob.GLOB_NOMATCH), result);
}

test "GLOB_NOMAGIC - returns NOMATCH for wildcard pattern with no match" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const GLOB_NOMAGIC: c_int = 0x0200;

    // Pattern with wildcards that doesn't match
    const pattern = try allocator.dupeZ(u8, "*.nonexistent");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, GLOB_NOMAGIC, null, &pglob);

    // Has metacharacters, so still returns NOMATCH
    try testing.expectEqual(@as(c_int, glob.GLOB_NOMATCH), result);
}

test "GLOB_NOMAGIC - succeeds for literal that exists" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const GLOB_NOMAGIC: c_int = 0x0200;

    const pattern = try allocator.dupeZ(u8, "file1.txt");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, GLOB_NOMAGIC, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 1), pglob.gl_pathc);
}

// ============================================================================
// Combined flags tests
// ============================================================================

test "GLOB_MARK and GLOB_PERIOD together" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const GLOB_PERIOD: c_int = 0x0080;

    const pattern = try allocator.dupeZ(u8, "*");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, glob.GLOB_MARK | GLOB_PERIOD, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);

    // Should match hidden files/dirs AND add trailing slash to directories
    var hidden_dir_with_slash: bool = false;
    for (0..pglob.gl_pathc) |i| {
        const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
        if (path.len > 0 and path[0] == '.' and path[path.len - 1] == '/') {
            hidden_dir_with_slash = true;
        }
    }
    try testing.expect(hidden_dir_with_slash); // .hidden_dir/
}

test "GLOB_TILDE with recursive glob" {
    const allocator = testing.allocator;

    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;

    // Create nested test directory in home
    const test_dir_path = try std.fmt.allocPrint(allocator, "{s}/.glob_test_nested", .{home});
    defer allocator.free(test_dir_path);

    std.fs.cwd().makeDir(test_dir_path) catch {};
    defer std.fs.cwd().deleteTree(test_dir_path) catch {};

    const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{test_dir_path});
    defer allocator.free(test_file);

    const f = std.fs.cwd().createFile(test_file, .{}) catch return error.SkipZigTest;
    f.close();

    const pattern = try allocator.dupeZ(u8, "~/**/.glob_test_nested/*.txt");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, glob.GLOB_TILDE, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expect(pglob.gl_pathc >= 1);
}

// ============================================================================
// GLOB_PERIOD with recursive patterns - Test both directory walking and matchPaths
// ============================================================================

test "GLOB_PERIOD - recursive glob should not match hidden files by default" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    // Test with ** recursive pattern - should NOT match hidden files without GLOB_PERIOD
    const pattern = try allocator.dupeZ(u8, "**/*");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, 0, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);

    // Should NOT match any hidden files or files inside hidden directories
    for (0..pglob.gl_pathc) |i| {
        const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);

        // Check that path doesn't contain /.hidden anywhere
        if (std.mem.indexOf(u8, path, "/.hidden") != null) {
            std.debug.print("ERROR: Path contains /.hidden: {s}\n", .{path});
        }
        try testing.expect(std.mem.indexOf(u8, path, "/.hidden") == null);

        // Check basename doesn't start with '.'
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
            path[idx + 1 ..]
        else
            path;

        if (basename.len > 0 and basename[0] == '.') {
            std.debug.print("ERROR: Matched hidden file without GLOB_PERIOD: {s}\n", .{path});
        }
        try testing.expect(basename.len == 0 or basename[0] != '.');
    }
}

test "GLOB_PERIOD - recursive glob matches hidden files with flag" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    const GLOB_PERIOD: c_int = 0x0080;

    // Test with ** recursive pattern WITH GLOB_PERIOD - should match hidden files
    const pattern = try allocator.dupeZ(u8, "**/*");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, GLOB_PERIOD, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);

    // Count hidden files/directories
    var hidden_file_count: usize = 0;
    var hidden_in_path_count: usize = 0;

    for (0..pglob.gl_pathc) |i| {
        const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);

        // Check if path contains .hidden_dir
        if (std.mem.indexOf(u8, path, ".hidden_dir") != null) {
            hidden_in_path_count += 1;
        }

        // Check basename starts with '.'
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
            path[idx + 1 ..]
        else
            path;

        if (basename.len > 0 and basename[0] == '.') {
            hidden_file_count += 1;
        }
    }

    // Should match .hidden_file, .hidden_dir, and file5.txt inside .hidden_dir
    try testing.expect(hidden_file_count >= 1); // At least .hidden_file and .hidden_dir
    try testing.expect(hidden_in_path_count >= 1); // At least .hidden_dir/file5.txt
}

test "GLOB_PERIOD - explicit dot pattern still matches without flag in recursive glob" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var test_dir: [4096:0]u8 = undefined;
    @memcpy(test_dir[0..test_dir_str.len], test_dir_str);
    test_dir[test_dir_str.len] = 0;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir[0..test_dir_str.len :0]);
    defer std.posix.chdir(old_cwd) catch {};

    // Pattern explicitly starts with . - should match even without GLOB_PERIOD
    const pattern = try allocator.dupeZ(u8, "**/.hidden*");
    defer allocator.free(pattern);

    var pglob: glob.glob_t = undefined;
    const result = glob.glob_c(allocator, pattern.ptr, 0, null, &pglob);
    defer if (result == 0) glob.globfree(allocator, &pglob);

    try testing.expectEqual(@as(c_int, 0), result);

    // Should match .hidden_file and .hidden_dir because pattern explicitly starts with '.'
    try testing.expect(pglob.gl_pathc >= 1);

    for (0..pglob.gl_pathc) |i| {
        const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
        try testing.expect(std.mem.indexOf(u8, path, ".hidden") != null);
    }
}
