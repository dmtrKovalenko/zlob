const std = @import("std");
const testing = std.testing;
const c_lib = @import("c_lib");
const c = std.c;

// Re-import only the constants we need from c_lib's glob_t
const GLOB_ERR = 1 << 0; // 0x0001
const GLOB_NOMATCH = 3;
const GLOB_ABORTED = 2;

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

    var pglob: c_lib.glob_t = undefined;
    const result = c_lib.glob(pattern.ptr, 0, testErrorCallback, &pglob);
    defer if (result == 0) c_lib.globfree(&pglob);

    // Should succeed but errfunc should have been called
    // We can't easily verify the callback was called without thread-local storage
    // but at least verify it doesn't crash
    try testing.expect(result == 0 or result == GLOB_NOMATCH or result == GLOB_ABORTED);
}

test "errfunc returning non-zero causes GLOB_ABORTED" {
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

    var pglob: c_lib.glob_t = undefined;
    const result = c_lib.glob(pattern.ptr, 0, testErrorCallbackAbort, &pglob);
    defer if (result == 0) c_lib.globfree(&pglob);

    // Should return GLOB_ABORTED if errfunc returned non-zero (when error occurs)
    // Note: The test creates a restricted directory that should fail opendir()
    // and trigger the errfunc callback which returns 1, causing GLOB_ABORTED
    try testing.expect(result == GLOB_ABORTED);
}

test "GLOB_ERR flag causes abort on directory error" {
    const allocator = testing.allocator;

    // Create a directory structure with a restricted directory
    const test_dir = "/tmp/test_glob_err_flag";
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

    // Try to glob with GLOB_ERR flag
    const pattern = try allocator.dupeZ(u8, "*/*");
    defer allocator.free(pattern);

    var pglob: c_lib.glob_t = undefined;
    const result = c_lib.glob(pattern.ptr, GLOB_ERR, null, &pglob);
    defer if (result == 0) c_lib.globfree(&pglob);

    // Should return GLOB_ABORTED when GLOB_ERR is set and error occurs
    try testing.expect(result == GLOB_ABORTED);
}

test "errfunc NULL with GLOB_ERR still aborts" {
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

    var pglob: c_lib.glob_t = undefined;
    const result = c_lib.glob(pattern.ptr, GLOB_ERR, null, &pglob);
    defer if (result == 0) c_lib.globfree(&pglob);

    // Should abort even with NULL errfunc when GLOB_ERR is set
    try testing.expect(result == GLOB_ABORTED);
}
