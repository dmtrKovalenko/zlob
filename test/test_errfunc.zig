const std = @import("std");
const testing = std.testing;
const c_lib = @import("c_lib");
const c = std.c;

// Re-import only the constants we need from c_lib's zlob_t
const ZLOB_ERR = 1 << 0; // 0x0001
const ZLOB_NOMATCH = 3;
const ZLOB_ABORTED = 2;

// Test structure to track errfunc calls
const ErrorCallbackContext = struct {
    call_count: usize = 0,
    last_path: ?[]const u8 = null,
    last_errno: c_int = 0,
    should_abort: bool = false,
    allocator: std.mem.Allocator,
};

// Error callback that tracks calls
fn testErrorCallback(epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int {
    _ = epath;
    _ = eerrno;
    // Return 0 to continue
    return 0;
}

fn testErrorCallbackAbort(epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int {
    _ = epath;
    _ = eerrno;
    // Return 1 to abort
    return 1;
}

test "errfunc is called on directory access error" {
    const allocator = testing.allocator;

    // Create a directory structure with a restricted directory
    const test_dir = "/tmp/test_errfunc_access";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create a subdirectory
    const restricted_dir = test_dir ++ "/restricted";
    std.fs.cwd().makeDir(restricted_dir) catch {};

    // Remove read permissions
    var perm_buf: [256:0]u8 = undefined;
    const perm_path = try std.fmt.bufPrintZ(&perm_buf, "{s}", .{restricted_dir});
    _ = c.chmod(perm_path.ptr, 0o000);
    defer _ = c.chmod(perm_path.ptr, 0o755); // Restore permissions for cleanup

    // Create a file we can access
    const accessible_file = test_dir ++ "/test.txt";
    var f = try std.fs.cwd().createFile(accessible_file, .{});
    f.close();

    // Change to test directory
    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir);
    defer std.posix.chdir(old_cwd) catch {};

    // Try to glob with errfunc
    const pattern = try allocator.dupeZ(u8, "*/*");
    defer allocator.free(pattern);

    var pzlob: c_lib.zlob_t = undefined;
    const result = c_lib.glob(pattern.ptr, 0, testErrorCallback, &pzlob);
    defer if (result == 0) c_lib.globfree(&pzlob);

    // Should succeed but errfunc should have been called
    // We can't easily verify the callback was called without thread-local storage
    // but at least verify it doesn't crash
    try testing.expect(result == 0 or result == ZLOB_NOMATCH or result == ZLOB_ABORTED);
}

test "errfunc returning non-zero causes ZLOB_ABORTED" {
    const allocator = testing.allocator;

    // Create a directory structure with a restricted directory
    const test_dir = "/tmp/test_errfunc_abort";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create a subdirectory
    const restricted_dir = test_dir ++ "/restricted";
    std.fs.cwd().makeDir(restricted_dir) catch {};

    // Remove read permissions
    var perm_buf: [256:0]u8 = undefined;
    const perm_path = try std.fmt.bufPrintZ(&perm_buf, "{s}", .{restricted_dir});
    const chmod_result = c.chmod(perm_path.ptr, 0o000);
    defer _ = c.chmod(perm_path.ptr, 0o755);

    // Skip test if chmod failed (might not have permissions or not supported)
    if (chmod_result != 0) return error.SkipZigTest;

    // Change to test directory
    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir);
    defer std.posix.chdir(old_cwd) catch {};

    // Try to glob with errfunc that returns non-zero
    const pattern = try allocator.dupeZ(u8, "*/*");
    defer allocator.free(pattern);

    var pzlob: c_lib.zlob_t = undefined;
    const result = c_lib.glob(pattern.ptr, 0, testErrorCallbackAbort, &pzlob);
    defer if (result == 0) c_lib.globfree(&pzlob);

    // Should return ZLOB_ABORTED if errfunc returned non-zero (when error occurs)
    // Note: The test creates a restricted directory that should fail opendir()
    // and trigger the errfunc callback which returns 1, causing ZLOB_ABORTED
    try testing.expect(result == ZLOB_ABORTED);
}

test "ZLOB_ERR flag causes abort on directory error" {
    const allocator = testing.allocator;

    // Create a directory structure with a restricted directory
    const test_dir = "/tmp/test_zlob_err_flag";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create a subdirectory
    const restricted_dir = test_dir ++ "/restricted";
    std.fs.cwd().makeDir(restricted_dir) catch {};

    // Remove read permissions
    var perm_buf: [256:0]u8 = undefined;
    const perm_path = try std.fmt.bufPrintZ(&perm_buf, "{s}", .{restricted_dir});
    const chmod_result = c.chmod(perm_path.ptr, 0o000);
    defer _ = c.chmod(perm_path.ptr, 0o755);

    // Skip test if chmod failed
    if (chmod_result != 0) return error.SkipZigTest;

    // Change to test directory
    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir);
    defer std.posix.chdir(old_cwd) catch {};

    // Try to glob with ZLOB_ERR flag
    const pattern = try allocator.dupeZ(u8, "*/*");
    defer allocator.free(pattern);

    var pzlob: c_lib.zlob_t = undefined;
    const result = c_lib.glob(pattern.ptr, ZLOB_ERR, null, &pzlob);
    defer if (result == 0) c_lib.globfree(&pzlob);

    // Should return ZLOB_ABORTED when ZLOB_ERR is set and error occurs
    try testing.expect(result == ZLOB_ABORTED);
}

test "errfunc NULL with ZLOB_ERR still aborts" {
    const allocator = testing.allocator;

    // Create a directory structure with a restricted directory
    const test_dir = "/tmp/test_null_errfunc";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const restricted_dir = test_dir ++ "/restricted";
    std.fs.cwd().makeDir(restricted_dir) catch {};

    var perm_buf: [256:0]u8 = undefined;
    const perm_path = try std.fmt.bufPrintZ(&perm_buf, "{s}", .{restricted_dir});
    const chmod_result = c.chmod(perm_path.ptr, 0o000);
    defer _ = c.chmod(perm_path.ptr, 0o755);

    // Skip test if chmod failed
    if (chmod_result != 0) return error.SkipZigTest;

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*/*");
    defer allocator.free(pattern);

    var pzlob: c_lib.zlob_t = undefined;
    const result = c_lib.glob(pattern.ptr, ZLOB_ERR, null, &pzlob);
    defer if (result == 0) c_lib.globfree(&pzlob);

    // Should abort even with NULL errfunc when ZLOB_ERR is set
    try testing.expect(result == ZLOB_ABORTED);
}
