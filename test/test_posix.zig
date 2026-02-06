const std = @import("std");
const testing = std.testing;
const glob = @import("zlob");
const zlob_flags = @import("zlob_flags");
const c_lib = @import("c_lib");
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
// ZLOB_MARK - Append '/' to directories
// ============================================================================

test "ZLOB_MARK - appends slash to directories" {
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

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_MARK, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expect(pzlob.zlo_pathc >= 3); // At least 3 directories

    // Count directories with trailing slash
    var dir_with_slash_count: usize = 0;
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        if (path.len > 0 and path[path.len - 1] == '/') {
            dir_with_slash_count += 1;
        }
    }

    // Should have at least 2 directories with slashes (dir1/, dir2/)
    // .hidden_dir may or may not be matched depending on other logic
    try testing.expect(dir_with_slash_count >= 2);
}

test "ZLOB_MARK - does not append slash to files" {
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

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_MARK, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expect(pzlob.zlo_pathc >= 1);

    // Files should NOT have trailing slash
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        try testing.expect(path.len == 0 or path[path.len - 1] != '/');
    }
}

test "ZLOB_MARK - works with recursive glob" {
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

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_MARK | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expect(result == 0 or result == zlob_flags.ZLOB_NOMATCH);
    if (result == 0) {
        // All matches should be directories with trailing slash
        for (0..pzlob.zlo_pathc) |i| {
            const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
            try testing.expect(path.len > 0 and path[path.len - 1] == '/');
        }
    }
}

// ============================================================================
// ZLOB_DOOFFS - Reserve offs slots at beginning
// ============================================================================

test "ZLOB_DOOFFS - reserves offset slots at beginning" {
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

    var pzlob: glob.zlob_t = undefined;
    pzlob.zlo_offs = 3; // Request 3 offset slots

    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_DOOFFS, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expect(pzlob.zlo_pathc >= 1);

    // First offs entries should be NULL
    try testing.expect(pzlob.zlo_pathv[0] == null);
    try testing.expect(pzlob.zlo_pathv[1] == null);
    try testing.expect(pzlob.zlo_pathv[2] == null);

    // First actual match should be at pathv[offs]
    const first_match = pzlob.zlo_pathv[pzlob.zlo_offs];
    try testing.expect(first_match != null);
    const path = std.mem.sliceTo(first_match, 0);
    try testing.expect(path.len > 0);
    try testing.expect(std.mem.endsWith(u8, path, ".txt"));
}

test "ZLOB_DOOFFS - works with ZLOB_APPEND" {
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

    var pzlob: glob.zlob_t = undefined;
    pzlob.zlo_offs = 2;

    // First glob
    const pattern1 = try allocator.dupeZ(u8, "*.txt");
    defer allocator.free(pattern1);
    const result1 = c_lib.zlob(pattern1.ptr, zlob_flags.ZLOB_DOOFFS, null, &pzlob);
    try testing.expectEqual(0, result1);
    const first_count = pzlob.zlo_pathc;

    // Second glob with APPEND
    const pattern2 = try allocator.dupeZ(u8, "*.c");
    defer allocator.free(pattern2);
    const result2 = c_lib.zlob(pattern2.ptr, zlob_flags.ZLOB_DOOFFS | zlob_flags.ZLOB_APPEND, null, &pzlob);
    defer c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result2);
    try testing.expect(pzlob.zlo_pathc > first_count);

    // Offset slots still NULL
    try testing.expect(pzlob.zlo_pathv[0] == null);
    try testing.expect(pzlob.zlo_pathv[1] == null);
}

// ============================================================================
// ZLOB_PERIOD - Allow leading '.' to match metacharacters
// ============================================================================

test "ZLOB_PERIOD - matches hidden files with wildcard" {
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

    // Define ZLOB_PERIOD
    const ZLOB_PERIOD = zlob_flags.ZLOB_PERIOD;

    const pattern = try allocator.dupeZ(u8, "*");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, ZLOB_PERIOD, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);

    // Count matches that start with '.'
    var hidden_count: usize = 0;
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        if (path.len > 0 and path[0] == '.') {
            hidden_count += 1;
        }
    }

    // Should match .hidden_file and .hidden_dir
    try testing.expect(hidden_count >= 1);
}

test "ZLOB_PERIOD - without flag does not match hidden files" {
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

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, 0, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);

    // Should NOT match hidden files
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        try testing.expect(path.len == 0 or path[0] != '.');
    }
}

test "ZLOB_PERIOD - explicit dot still matches" {
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

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, 0, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);

    // Should match hidden files even without ZLOB_PERIOD
    var hidden_count: usize = 0;
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        if (path.len > 0 and path[0] == '.') {
            hidden_count += 1;
        }
    }
    try testing.expect(hidden_count >= 1);
}

// ============================================================================
// ZLOB_TILDE - Expand tilde (~) to home directory
// ============================================================================

test "ZLOB_TILDE - expands tilde to home directory" {
    const allocator = testing.allocator;

    // Get $HOME environment variable
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;

    // Create a test file in home directory
    const test_file = try std.fmt.allocPrint(allocator, "{s}/.zlob_test_tilde_12345.txt", .{home});
    defer allocator.free(test_file);

    const f = std.fs.cwd().createFile(test_file, .{}) catch return error.SkipZigTest;
    f.close();
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const pattern = try allocator.dupeZ(u8, "~/.zlob_test_tilde_*.txt");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_TILDE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);

    const matched_path = std.mem.sliceTo(pzlob.zlo_pathv[0], 0);
    try testing.expect(std.mem.startsWith(u8, matched_path, home));
}

test "ZLOB_TILDE - expands ~username to user home" {
    const allocator = testing.allocator;

    // Get current username
    const username = std.posix.getenv("USER") orelse return error.SkipZigTest;
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;

    // Create test file
    const test_file = try std.fmt.allocPrint(allocator, "{s}/.zlob_test_user_12345.txt", .{home});
    defer allocator.free(test_file);

    const f = std.fs.cwd().createFile(test_file, .{}) catch return error.SkipZigTest;
    f.close();
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const pattern_str = try std.fmt.allocPrint(allocator, "~{s}/.zlob_test_user_*.txt", .{username});
    defer allocator.free(pattern_str);

    const pattern = try allocator.dupeZ(u8, pattern_str);
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_TILDE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);

    const matched_path = std.mem.sliceTo(pzlob.zlo_pathv[0], 0);
    try testing.expect(std.mem.startsWith(u8, matched_path, home));
}

test "ZLOB_TILDE - without flag treats tilde as literal" {
    const allocator = testing.allocator;

    const pattern = try allocator.dupeZ(u8, "~/*.txt");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, 0, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    // Without ZLOB_TILDE, should try to find literal ~ directory
    // Most likely ZLOB_NOMATCH or ZLOB_ABORTED
    try testing.expect(result == zlob_flags.ZLOB_NOMATCH or result == zlob_flags.ZLOB_ABORTED);
}

// ============================================================================
// ZLOB_TILDE_CHECK - Error if username not found
// ============================================================================

test "ZLOB_TILDE_CHECK - errors on nonexistent username" {
    const allocator = testing.allocator;

    const pattern = try allocator.dupeZ(u8, "~nonexistentuser99999/*.txt");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_TILDE | zlob_flags.ZLOB_TILDE_CHECK, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    // Should return ZLOB_NOMATCH for nonexistent user
    try testing.expectEqual(@as(c_int, zlob_flags.ZLOB_NOMATCH), result);
}

test "ZLOB_TILDE_CHECK - without flag returns tilde literal on unknown user" {
    const allocator = testing.allocator;

    const pattern = try allocator.dupeZ(u8, "~nonexistentuser99999");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_TILDE | zlob_flags.ZLOB_NOCHECK, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    // Without ZLOB_TILDE_CHECK, should fall back to literal tilde
    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);

    const path = std.mem.sliceTo(pzlob.zlo_pathv[0], 0);
    try testing.expect(std.mem.startsWith(u8, path, "~nonexistentuser99999"));
}

// ============================================================================
// ZLOB_NOMAGIC - Return nothing if no magic and no match
// ============================================================================

test "ZLOB_NOMAGIC - returns NOMATCH for literal with no match" {
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

    // Literal pattern (no wildcards) that doesn't exist
    const pattern = try allocator.dupeZ(u8, "nonexistent.txt");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_NOMAGIC, null, &pzlob);

    try testing.expectEqual(@as(c_int, zlob_flags.ZLOB_NOMATCH), result);
}

test "ZLOB_NOMAGIC - returns NOMATCH for wildcard pattern with no match" {
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

    // Pattern with wildcards that doesn't match
    const pattern = try allocator.dupeZ(u8, "*.nonexistent");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_NOMAGIC, null, &pzlob);

    // Has metacharacters, so still returns NOMATCH
    try testing.expectEqual(@as(c_int, zlob_flags.ZLOB_NOMATCH), result);
}

test "ZLOB_NOMAGIC - succeeds for literal that exists" {
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

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_NOMAGIC, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);
}

// ============================================================================
// Combined flags tests
// ============================================================================

test "ZLOB_MARK and ZLOB_PERIOD together" {
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

    const ZLOB_PERIOD = zlob_flags.ZLOB_PERIOD;

    const pattern = try allocator.dupeZ(u8, "*");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_MARK | ZLOB_PERIOD, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);

    // Should match hidden files/dirs AND add trailing slash to directories
    var hidden_dir_with_slash: bool = false;
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        if (path.len > 0 and path[0] == '.' and path[path.len - 1] == '/') {
            hidden_dir_with_slash = true;
        }
    }
    try testing.expect(hidden_dir_with_slash); // .hidden_dir/
}

test "ZLOB_TILDE with recursive glob" {
    const allocator = testing.allocator;

    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;

    // Create nested test directory in home
    const test_dir_path = try std.fmt.allocPrint(allocator, "{s}/.zlob_test_nested", .{home});
    defer allocator.free(test_dir_path);

    std.fs.cwd().makeDir(test_dir_path) catch {};
    defer std.fs.cwd().deleteTree(test_dir_path) catch {};

    const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{test_dir_path});
    defer allocator.free(test_file);

    const f = std.fs.cwd().createFile(test_file, .{}) catch return error.SkipZigTest;
    f.close();

    const pattern = try allocator.dupeZ(u8, "~/**/.zlob_test_nested/*.txt");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_TILDE | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expect(pzlob.zlo_pathc >= 1);
}

// ============================================================================
// ZLOB_PERIOD with recursive patterns - Test both directory walking and matchPaths
// ============================================================================

test "ZLOB_PERIOD - recursive glob should not match hidden files by default" {
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

    // Test with ** recursive pattern - should NOT match hidden files without ZLOB_PERIOD
    const pattern = try allocator.dupeZ(u8, "**/*");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);

    // Should NOT match any hidden files or files inside hidden directories
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);

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
            std.debug.print("ERROR: Matched hidden file without ZLOB_PERIOD: {s}\n", .{path});
        }
        try testing.expect(basename.len == 0 or basename[0] != '.');
    }
}

test "ZLOB_PERIOD - recursive glob matches hidden files with flag" {
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

    const ZLOB_PERIOD = zlob_flags.ZLOB_PERIOD;

    // Test with ** recursive pattern WITH ZLOB_PERIOD - should match hidden files
    const pattern = try allocator.dupeZ(u8, "**/*");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, ZLOB_PERIOD | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);

    // Count hidden files/directories
    var hidden_file_count: usize = 0;
    var hidden_in_path_count: usize = 0;

    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);

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

test "ZLOB_PERIOD - explicit dot pattern still matches without flag in recursive glob" {
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

    // Pattern explicitly starts with . - should match even without ZLOB_PERIOD
    const pattern = try allocator.dupeZ(u8, "**/.hidden*");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    // Note: ZLOB_DOUBLESTAR_RECURSIVE is needed for ** to recurse, but ZLOB_PERIOD is NOT needed
    // because the pattern explicitly contains a dot prefix in the filename portion
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);

    // Should match .hidden_file and .hidden_dir because pattern explicitly starts with '.'
    try testing.expect(pzlob.zlo_pathc >= 1);

    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        try testing.expect(std.mem.indexOf(u8, path, ".hidden") != null);
    }
}

// ============================================================================
// Literal path tests (no wildcards) - testing globLiteralPath function
// ============================================================================

test "literal path - file exists" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "file1.txt");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, 0, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);
    try testing.expectEqualStrings("file1.txt", std.mem.sliceTo(pzlob.zlo_pathv[0], 0));
    try testing.expectEqual(9, pzlob.zlo_pathlen[0]);
}

test "literal path - directory exists" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "dir1");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, 0, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);
    try testing.expectEqualStrings("dir1", std.mem.sliceTo(pzlob.zlo_pathv[0], 0));
}

test "literal path - ZLOB_ONLYDIR with directory" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "dir1");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_ONLYDIR, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);
    try testing.expectEqualStrings("dir1", std.mem.sliceTo(pzlob.zlo_pathv[0], 0));
}

test "literal path - ZLOB_ONLYDIR with file (should fail)" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "file1.txt");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_ONLYDIR, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(@as(c_int, zlob_flags.ZLOB_NOMATCH), result);
}

test "literal path - ZLOB_MARK with directory" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "dir1");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_MARK, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);
    const path = std.mem.sliceTo(pzlob.zlo_pathv[0], 0);
    try testing.expectEqualStrings("dir1/", path);
    try testing.expectEqual(5, pzlob.zlo_pathlen[0]);
}

test "literal path - ZLOB_MARK with file (no slash)" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "file1.txt");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_MARK, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);
    const path = std.mem.sliceTo(pzlob.zlo_pathv[0], 0);
    try testing.expectEqualStrings("file1.txt", path);
}

test "literal path - ./ prefix normalization" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "./file1.txt");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, 0, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);
    // Should normalize away the "./" prefix
    try testing.expectEqualStrings("file1.txt", std.mem.sliceTo(pzlob.zlo_pathv[0], 0));
}

test "literal path - ZLOB_NOCHECK returns pattern when not found" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "nonexistent.txt");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_NOCHECK, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);
    // Should return the pattern itself
    try testing.expectEqualStrings("nonexistent.txt", std.mem.sliceTo(pzlob.zlo_pathv[0], 0));
}

test "literal path - not found without ZLOB_NOCHECK" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "nonexistent.txt");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, 0, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(@as(c_int, zlob_flags.ZLOB_NOMATCH), result);
}

test "literal path - ZLOB_MARK and ZLOB_ONLYDIR together" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createTestFiles(allocator, tmp_dir);
    defer cleanupTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_missing_flags", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "dir1");
    defer allocator.free(pattern);

    var pzlob: glob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_MARK | zlob_flags.ZLOB_ONLYDIR, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);
    const path = std.mem.sliceTo(pzlob.zlo_pathv[0], 0);
    try testing.expectEqualStrings("dir1/", path);
    try testing.expectEqual(5, pzlob.zlo_pathlen[0]);
}

// ============================================================================
// ALTDIRFUNC tests - virtual filesystem support
// ============================================================================

test "ZLOB_ALTDIRFUNC - single directory with wildcard pattern" {
    // Mock a flat directory with these entries:
    //   file1.txt, file2.txt, data.csv, README.md
    // Pattern "*.txt" should match file1.txt and file2.txt

    const MockSingleDir = struct {
        const Entry = struct {
            name: [:0]const u8,
            d_type: u8,
        };

        // DT_REG = 8 (regular file), DT_DIR = 4 (directory)
        const entries = [_]Entry{
            .{ .name = "file1.txt", .d_type = 8 },
            .{ .name = "file2.txt", .d_type = 8 },
            .{ .name = "data.csv", .d_type = 8 },
            .{ .name = "README.md", .d_type = 8 },
        };

        var index: usize = 0;
        var dirent_storage: c_lib.zlob_dirent_t = undefined;

        fn opendir(_: [*:0]const u8) callconv(.c) ?*anyopaque {
            index = 0;
            // Return non-null handle to indicate success
            return @ptrFromInt(0xDEADBEEF);
        }

        fn readdir(_: ?*anyopaque) callconv(.c) ?*c_lib.zlob_dirent_t {
            if (index >= entries.len) return null;
            dirent_storage.d_name = entries[index].name.ptr;
            dirent_storage.d_type = entries[index].d_type;
            index += 1;
            return &dirent_storage;
        }

        fn closedir(_: ?*anyopaque) callconv(.c) void {
            index = 0;
        }
    };

    const allocator = testing.allocator;

    const pattern = try allocator.dupeZ(u8, "*.txt");
    defer allocator.free(pattern);

    // Initialize zlob_t with ALTDIRFUNC callbacks
    var pzlob = glob.zlob_t{
        .zlo_pathc = 0,
        .zlo_pathv = null,
        .zlo_offs = 0,
        .zlo_pathlen = undefined,
        .zlo_flags = 0,
        .zlo_opendir = MockSingleDir.opendir,
        .zlo_readdir = @ptrCast(&MockSingleDir.readdir),
        .zlo_closedir = MockSingleDir.closedir,
    };

    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_ALTDIRFUNC, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 2), pzlob.zlo_pathc);

    // Collect matched paths
    var found_file1 = false;
    var found_file2 = false;
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        if (std.mem.eql(u8, path, "file1.txt")) found_file1 = true;
        if (std.mem.eql(u8, path, "file2.txt")) found_file2 = true;
    }

    try testing.expect(found_file1);
    try testing.expect(found_file2);
}

test "ZLOB_ALTDIRFUNC - nested directory with wildcard pattern" {
    // Mock a directory tree:
    //   . (root)
    //     ├── root.txt
    //     ├── src/           (directory)
    //     │   ├── main.zig
    //     │   └── util.zig
    //     └── test/          (directory)
    //         └── test_main.zig
    //
    // Pattern "src/*.zig" should match: src/main.zig, src/util.zig
    // Note: This tests ALTDIRFUNC with multi-level paths but not recursive ** walking,
    // since ** recursive walking uses platform-optimized getdents64 which doesn't
    // support ALTDIRFUNC (by design for performance).

    const MockNestedDir = struct {
        const Entry = struct {
            name: [:0]const u8,
            d_type: u8,
        };

        // Directory contents indexed by path
        const root_entries = [_]Entry{
            .{ .name = "root.txt", .d_type = 8 },
            .{ .name = "src", .d_type = 4 },
            .{ .name = "test", .d_type = 4 },
        };

        const src_entries = [_]Entry{
            .{ .name = "main.zig", .d_type = 8 },
            .{ .name = "util.zig", .d_type = 8 },
        };

        const test_entries = [_]Entry{
            .{ .name = "test_main.zig", .d_type = 8 },
        };

        // State tracking
        var current_entries: []const Entry = &root_entries;
        var index: usize = 0;
        var dirent_storage: c_lib.zlob_dirent_t = undefined;

        fn opendir(path: [*:0]const u8) callconv(.c) ?*anyopaque {
            const path_slice = std.mem.sliceTo(path, 0);

            // Determine which directory is being opened based on path
            if (std.mem.endsWith(u8, path_slice, "/src") or std.mem.eql(u8, path_slice, "src")) {
                current_entries = &src_entries;
            } else if (std.mem.endsWith(u8, path_slice, "/test") or std.mem.eql(u8, path_slice, "test")) {
                current_entries = &test_entries;
            } else {
                // Root directory (., empty path, or anything else)
                current_entries = &root_entries;
            }

            index = 0;
            return @ptrFromInt(0xCAFEBABE);
        }

        fn readdir(_: ?*anyopaque) callconv(.c) ?*c_lib.zlob_dirent_t {
            if (index >= current_entries.len) return null;
            dirent_storage.d_name = current_entries[index].name.ptr;
            dirent_storage.d_type = current_entries[index].d_type;
            index += 1;
            return &dirent_storage;
        }

        fn closedir(_: ?*anyopaque) callconv(.c) void {
            index = 0;
        }
    };

    const allocator = testing.allocator;

    const pattern = try allocator.dupeZ(u8, "src/*.zig");
    defer allocator.free(pattern);

    // Initialize zlob_t with ALTDIRFUNC callbacks
    var pzlob = glob.zlob_t{
        .zlo_pathc = 0,
        .zlo_pathv = null,
        .zlo_offs = 0,
        .zlo_pathlen = undefined,
        .zlo_flags = 0,
        .zlo_opendir = MockNestedDir.opendir,
        .zlo_readdir = @ptrCast(&MockNestedDir.readdir),
        .zlo_closedir = MockNestedDir.closedir,
    };

    const result = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_ALTDIRFUNC, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 2), pzlob.zlo_pathc);

    // Collect matched paths
    var found_main = false;
    var found_util = false;
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        if (std.mem.eql(u8, path, "src/main.zig")) found_main = true;
        if (std.mem.eql(u8, path, "src/util.zig")) found_util = true;
    }

    try testing.expect(found_main);
    try testing.expect(found_util);
}

// SIMD helper function tests
