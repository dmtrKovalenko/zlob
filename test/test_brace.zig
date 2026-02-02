const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");
const test_utils = @import("test_utils");
const zlobIsomorphicTest = test_utils.zlobIsomorphicTest;
const testMatchPathsOnly = test_utils.testMatchPathsOnly;
const TestResult = test_utils.TestResult;

test "ZLOB_BRACE - basic brace expansion" {
    const files = [_][]const u8{
        "a.txt",
        "b.txt",
        "c.txt",
        "d.txt",
    };

    try zlobIsomorphicTest(&files, "{a,b,c}.txt", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(result.hasPath("a.txt"));
            try testing.expect(result.hasPath("b.txt"));
            try testing.expect(result.hasPath("c.txt"));
            try testing.expect(!result.hasPath("d.txt"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - brace with wildcards" {
    const files = [_][]const u8{
        "foo.txt",
        "foo.log",
        "bar.txt",
        "bar.log",
        "baz.txt",
    };

    try zlobIsomorphicTest(&files, "{foo,bar}.*", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(4, result.count);
            try testing.expect(result.hasPath("foo.txt"));
            try testing.expect(result.hasPath("foo.log"));
            try testing.expect(result.hasPath("bar.txt"));
            try testing.expect(result.hasPath("bar.log"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - wildcard with brace extension" {
    const files = [_][]const u8{
        "test.txt",
        "test.log",
        "test.md",
        "test2.log",
        "test3.md",
        "test.rs",
        "readme.txt",
    };

    try zlobIsomorphicTest(&files, "test.{txt,log,md}", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(result.hasPath("test.txt"));
            try testing.expect(result.hasPath("test.log"));
            try testing.expect(result.hasPath("test.md"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - recursive" {
    const files = [_][]const u8{
        "dir1/test.txt",
        "dir1/test.log",
        "dir2/test.md",
        "dir2/test2.log",
        "dir3/test3.md",
        "dir4/test.rs",
    };

    // Recursive + brace: use testMatchPathsOnly for deterministic results
    try testMatchPathsOnly(&files, "**/*.{md,log}", zlob.ZLOB_BRACE | zlob.ZLOB_DOUBLESTAR_RECURSIVE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(4, result.count);
        }
    }.assert);
}

test "ZLOB_BRACE - wildcard extension" {
    const files = [_][]const u8{
        "test.txt",
        "test.log",
        "test.md",
        "test2.log",
        "test3.md",
        "test.rs",
        "readme.txt",
    };

    try zlobIsomorphicTest(&files, "*.{txt,log,md}", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(6, result.count);
        }
    }.assert, @src());
}

test "ZLOB_BRACE - two alternatives" {
    const files = [_][]const u8{
        "main.c",
        "test.c",
        "main.h",
        "test.h",
    };

    try zlobIsomorphicTest(&files, "main.{c,h}", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(2, result.count);
            try testing.expect(result.hasPath("main.c"));
            try testing.expect(result.hasPath("main.h"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - single alternative" {
    const files = [_][]const u8{
        "test.txt",
        "test.log",
    };

    try zlobIsomorphicTest(&files, "test.{txt}", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(1, result.count);
            try testing.expect(result.hasPath("test.txt"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - multiple brace groups" {
    const files = [_][]const u8{
        "a/x.txt",
        "a/y.txt",
        "b/x.txt",
        "b/y.txt",
        "c/x.txt",
    };

    try zlobIsomorphicTest(&files, "{a,b}/{x,y}.txt", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(4, result.count);
            try testing.expect(result.hasPath("a/x.txt"));
            try testing.expect(result.hasPath("a/y.txt"));
            try testing.expect(result.hasPath("b/x.txt"));
            try testing.expect(result.hasPath("b/y.txt"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - without flag treats as literal" {
    const files = [_][]const u8{
        "a.txt",
        "b.txt",
        "{a,b}.txt",
    };

    // Without ZLOB_BRACE flag, braces should be treated as literal characters
    // Use testMatchPathsOnly since literal braces can't be filesystem names
    try testMatchPathsOnly(&files, "{a,b}.txt", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(1, result.count);
            try testing.expect(result.hasPath("{a,b}.txt"));
        }
    }.assert);
}

test "ZLOB_BRACE - prefix and suffix" {
    const files = [_][]const u8{
        "prefix_a_suffix.txt",
        "prefix_b_suffix.txt",
        "prefix_c_suffix.txt",
        "prefix_d_suffix.txt",
    };

    try zlobIsomorphicTest(&files, "prefix_{a,b,c}_suffix.txt", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(result.hasPath("prefix_a_suffix.txt"));
            try testing.expect(result.hasPath("prefix_b_suffix.txt"));
            try testing.expect(result.hasPath("prefix_c_suffix.txt"));
            try testing.expect(!result.hasPath("prefix_d_suffix.txt"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - with paths" {
    const files = [_][]const u8{
        "src/main.zig",
        "src/test.zig",
        "lib/main.zig",
        "lib/test.zig",
        "docs/readme.md",
    };

    try zlobIsomorphicTest(&files, "{src,lib}/*.zig", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(4, result.count);
            try testing.expect(result.hasPath("src/main.zig"));
            try testing.expect(result.hasPath("src/test.zig"));
            try testing.expect(result.hasPath("lib/main.zig"));
            try testing.expect(result.hasPath("lib/test.zig"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - numeric alternatives" {
    const files = [_][]const u8{
        "file1.txt",
        "file2.txt",
        "file3.txt",
        "file4.txt",
    };

    try zlobIsomorphicTest(&files, "file{1,2,3}.txt", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(result.hasPath("file1.txt"));
            try testing.expect(result.hasPath("file2.txt"));
            try testing.expect(result.hasPath("file3.txt"));
            try testing.expect(!result.hasPath("file4.txt"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - empty alternatives" {
    const files = [_][]const u8{
        "test.txt",
        "test_suffix.txt",
        "other.txt",
    };

    // {,_suffix} should match both empty string and "_suffix"
    try zlobIsomorphicTest(&files, "test{,_suffix}.txt", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(2, result.count);
            try testing.expect(result.hasPath("test.txt"));
            try testing.expect(result.hasPath("test_suffix.txt"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - complex real-world pattern" {
    const files = [_][]const u8{
        "src/main.c",
        "src/main.h",
        "src/test.c",
        "src/test.h",
        "lib/util.c",
        "lib/util.h",
        "include/api.h",
        "docs/readme.md",
    };

    try zlobIsomorphicTest(&files, "{src,lib}/*.{c,h}", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(6, result.count);
            try testing.expect(result.hasPath("src/main.c"));
            try testing.expect(result.hasPath("src/main.h"));
            try testing.expect(result.hasPath("src/test.c"));
            try testing.expect(result.hasPath("src/test.h"));
            try testing.expect(result.hasPath("lib/util.c"));
            try testing.expect(result.hasPath("lib/util.h"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - no matches" {
    const files = [_][]const u8{
        "a.txt",
        "b.txt",
    };

    try zlobIsomorphicTest(&files, "{x,y,z}.txt", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(0, result.count);
        }
    }.assert, @src());
}

test "ZLOB_BRACE - combined with character class" {
    const files = [_][]const u8{
        "a1.txt",
        "a2.txt",
        "b1.txt",
        "b2.txt",
        "c1.txt",
    };

    try zlobIsomorphicTest(&files, "{a,b}[12].txt", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(4, result.count);
            try testing.expect(result.hasPath("a1.txt"));
            try testing.expect(result.hasPath("a2.txt"));
            try testing.expect(result.hasPath("b1.txt"));
            try testing.expect(result.hasPath("b2.txt"));
            try testing.expect(!result.hasPath("c1.txt"));
        }
    }.assert, @src());
}

test "ZLOB_BRACE - long alternatives" {
    const files = [_][]const u8{
        "very_long_alternative_name_one.txt",
        "very_long_alternative_name_two.txt",
        "very_long_alternative_name_three.txt",
    };

    try zlobIsomorphicTest(&files, "very_long_alternative_name_{one,two,three}.txt", zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(result.hasPath("very_long_alternative_name_one.txt"));
            try testing.expect(result.hasPath("very_long_alternative_name_two.txt"));
            try testing.expect(result.hasPath("very_long_alternative_name_three.txt"));
        }
    }.assert, @src());
}

// ============================================================================
// Real Directory Walking Tests for ZLOB_BRACE
// These tests create actual files on disk and use the glob C API
// ============================================================================

const c = std.c;
const c_lib = @import("c_lib");

/// Helper to create test directory structure for brace tests
fn createBraceTestFiles(allocator: std.mem.Allocator, base_path: []const u8) !void {
    const dirs = [_][]const u8{
        "test_brace",
        "test_brace/src",
        "test_brace/lib",
        "test_brace/docs",
        "test_brace/include",
        "test_brace/src/core",
        "test_brace/src/utils",
        "test_brace/lib/common",
        "test_brace/.hidden",
    };

    const files = [_][]const u8{
        // Root level with various extensions
        "test_brace/Cargo.toml",
        "test_brace/Cargo.lock",
        "test_brace/package.json",
        "test_brace/README.md",
        "test_brace/LICENSE",
        // Source files
        "test_brace/src/main.c",
        "test_brace/src/main.h",
        "test_brace/src/test.c",
        "test_brace/src/test.h",
        "test_brace/src/utils.c",
        "test_brace/src/core/engine.c",
        "test_brace/src/core/engine.h",
        "test_brace/src/utils/helper.c",
        "test_brace/src/utils/helper.h",
        // Lib files
        "test_brace/lib/lib.c",
        "test_brace/lib/lib.h",
        "test_brace/lib/common/shared.c",
        "test_brace/lib/common/shared.h",
        // Docs
        "test_brace/docs/guide.md",
        "test_brace/docs/api.md",
        "test_brace/docs/readme.txt",
        // Include
        "test_brace/include/api.h",
        "test_brace/include/types.h",
        // Multiple extensions
        "test_brace/data.json",
        "test_brace/config.yaml",
        "test_brace/config.yml",
        "test_brace/style.css",
        "test_brace/app.js",
        "test_brace/app.ts",
        // Hidden files
        "test_brace/.hidden/secret.txt",
        "test_brace/.gitignore",
        "test_brace/.env",
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
        _ = f.write("test content\n") catch {};
    }
}

fn cleanupBraceTestFiles(allocator: std.mem.Allocator, base_path: []const u8) !void {
    const full_path_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{base_path});
    defer allocator.free(full_path_str);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "rm", "-rf", full_path_str },
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

/// Helper to change to test directory and restore on defer
fn withTestDir(allocator: std.mem.Allocator, base_path: []const u8, cwd_buf: *[4096]u8) ![]const u8 {
    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{base_path});
    const old_cwd = try std.posix.getcwd(cwd_buf);
    try std.posix.chdir(test_dir_str);
    return old_cwd;
}

/// Helper to count results with a specific substring
fn countResultsWithSubstring(pzlob: *const zlob.zlob_t, substr: []const u8) usize {
    var count: usize = 0;
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        if (std.mem.indexOf(u8, path, substr) != null) {
            count += 1;
        }
    }
    return count;
}

/// Helper to count results ending with a specific suffix
fn countResultsWithSuffix(pzlob: *const zlob.zlob_t, suffix: []const u8) usize {
    var count: usize = 0;
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        if (std.mem.endsWith(u8, path, suffix)) {
            count += 1;
        }
    }
    return count;
}

/// Helper to check if a specific path exists in results
fn hasPath(pzlob: *const zlob.zlob_t, expected: []const u8) bool {
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        if (std.mem.eql(u8, path, expected)) {
            return true;
        }
    }
    return false;
}

// ============================================================================
// Real directory walking
// ============================================================================

test "ZLOB_BRACE filesystem - simple extension alternatives" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*.{toml,lock}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(2, pzlob.zlo_pathc);
    try testing.expect(hasPath(&pzlob, "Cargo.toml"));
    try testing.expect(hasPath(&pzlob, "Cargo.lock"));
}

test "ZLOB_BRACE filesystem - wildcard with extension alternatives" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "config.{yaml,yml}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(2, pzlob.zlo_pathc);
    try testing.expect(hasPath(&pzlob, "config.yaml"));
    try testing.expect(hasPath(&pzlob, "config.yml"));
}

test "ZLOB_BRACE filesystem - directory alternatives" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "{src,lib}/*.c");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // src/main.c, src/test.c, src/utils.c, lib/lib.c
    try testing.expectEqual(4, pzlob.zlo_pathc);
}

test "ZLOB_BRACE filesystem - C source and header files" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "src/*.{c,h}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // src/main.c, src/main.h, src/test.c, src/test.h, src/utils.c
    try testing.expectEqual(5, pzlob.zlo_pathc);

    const c_count = countResultsWithSuffix(&pzlob, ".c");
    const h_count = countResultsWithSuffix(&pzlob, ".h");
    try testing.expectEqual(3, c_count);
    try testing.expectEqual(2, h_count);
}

// ============================================================================
// Recursive brace expansion with **
// ============================================================================

test "ZLOB_BRACE filesystem - recursive with extension alternatives" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "**/*.{c,h}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE | zlob.ZLOB_DOUBLESTAR_RECURSIVE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // All .c and .h files in the tree
    // src/main.c, src/main.h, src/test.c, src/test.h, src/utils.c
    // src/core/engine.c, src/core/engine.h
    // src/utils/helper.c, src/utils/helper.h
    // lib/lib.c, lib/lib.h
    // lib/common/shared.c, lib/common/shared.h
    // include/api.h, include/types.h
    try testing.expect(pzlob.zlo_pathc >= 15);

    const c_count = countResultsWithSuffix(&pzlob, ".c");
    const h_count = countResultsWithSuffix(&pzlob, ".h");
    try testing.expect(c_count >= 7); // All .c files
    try testing.expect(h_count >= 8); // All .h files
}

test "ZLOB_BRACE filesystem - recursive with directory alternatives" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "{src,lib}/**/*.c");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE | zlob.ZLOB_DOUBLESTAR_RECURSIVE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // src/main.c, src/test.c, src/utils.c, src/core/engine.c, src/utils/helper.c
    // lib/lib.c, lib/common/shared.c
    try testing.expect(pzlob.zlo_pathc >= 7);
}

test "ZLOB_BRACE filesystem - complex pattern with multiple brace groups" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "{src,lib}/**/*.{c,h}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE | zlob.ZLOB_DOUBLESTAR_RECURSIVE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // All .c and .h files in src/ and lib/ trees
    try testing.expect(pzlob.zlo_pathc >= 13);
}

// ============================================================================
// Edge cases and special patterns
// ============================================================================

test "ZLOB_BRACE filesystem - single alternative (should still work)" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*.{json}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // package.json, data.json
    try testing.expectEqual(2, pzlob.zlo_pathc);
}

test "ZLOB_BRACE filesystem - many alternatives" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*.{json,yaml,yml,toml,lock,md,txt,css,js,ts}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // package.json, data.json, config.yaml, config.yml, Cargo.toml, Cargo.lock, README.md, style.css, app.js, app.ts
    try testing.expect(pzlob.zlo_pathc >= 10);
}

test "ZLOB_BRACE filesystem - no matches returns NOMATCH" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*.{xyz,abc,nonexistent}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(@as(c_int, zlob.ZLOB_NOMATCH), result);
}

test "ZLOB_BRACE filesystem - without flag treats braces as literal" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    // Without ZLOB_BRACE, {toml,lock} is treated as literal
    const pattern = try allocator.dupeZ(u8, "*.{toml,lock}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, 0, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    // Should not match anything because there's no file named "*.{toml,lock}"
    try testing.expectEqual(@as(c_int, zlob.ZLOB_NOMATCH), result);
}

// ============================================================================
// Combined flags with ZLOB_BRACE
// ============================================================================

test "ZLOB_BRACE filesystem - combined with ZLOB_MARK" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "{src,lib,docs}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE | zlob.ZLOB_MARK, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(3, pzlob.zlo_pathc);

    // All should have trailing slash since they're directories
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        try testing.expect(path.len > 0 and path[path.len - 1] == '/');
    }
}

test "ZLOB_BRACE filesystem - combined with ZLOB_NOSORT" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*.{toml,lock,json}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE | zlob.ZLOB_NOSORT, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // Cargo.toml, Cargo.lock, package.json, data.json
    try testing.expectEqual(4, pzlob.zlo_pathc);
}

test "ZLOB_BRACE filesystem - combined with ZLOB_NOCHECK" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*.{nonexistent1,nonexistent2}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE | zlob.ZLOB_NOCHECK, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(1, pzlob.zlo_pathc);
    // Returns the original pattern
    try testing.expectEqualStrings("*.{nonexistent1,nonexistent2}", std.mem.sliceTo(pzlob.zlo_pathv[0], 0));
}

test "ZLOB_BRACE filesystem - combined with ZLOB_ONLYDIR" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    // Pattern that could match both files and directories
    const pattern = try allocator.dupeZ(u8, "{src,lib,docs,README.md}/");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // Only directories: src, lib, docs (README.md is a file, should be skipped)
    try testing.expectEqual(3, pzlob.zlo_pathc);
}

// ============================================================================
// ZLOB_BRACE with ZLOB_APPEND
// ============================================================================

test "ZLOB_BRACE filesystem - with ZLOB_APPEND" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    var pzlob: zlob.zlob_t = undefined;

    // First glob: get .toml files
    const pattern1 = try allocator.dupeZ(u8, "*.toml");
    defer allocator.free(pattern1);
    const result1 = c_lib.zlob(pattern1.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    try testing.expectEqual(0, result1);
    const first_count = pzlob.zlo_pathc;
    try testing.expectEqual(1, first_count); // Cargo.toml

    // Second glob: append .lock files
    const pattern2 = try allocator.dupeZ(u8, "*.lock");
    defer allocator.free(pattern2);
    const result2 = c_lib.zlob(pattern2.ptr, zlob.ZLOB_BRACE | zlob.ZLOB_APPEND, null, &pzlob);
    defer c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result2);
    try testing.expectEqual(2, pzlob.zlo_pathc); // Cargo.toml + Cargo.lock
}

// ============================================================================
// Performance and stress tests
// ============================================================================

test "ZLOB_BRACE filesystem - many files with brace pattern" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    // Pattern that will scan many directories
    const pattern = try allocator.dupeZ(u8, "**/*.{c,h,txt,md,json,yaml,yml,toml,lock,css,js,ts}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE | zlob.ZLOB_DOUBLESTAR_RECURSIVE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // Should find many files
    try testing.expect(pzlob.zlo_pathc >= 20);
}

// ============================================================================
// Real-world patterns
// ============================================================================

test "ZLOB_BRACE filesystem - Cargo pattern (Rust project)" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "Cargo.{toml,lock}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    try testing.expectEqual(2, pzlob.zlo_pathc);
    try testing.expect(hasPath(&pzlob, "Cargo.toml"));
    try testing.expect(hasPath(&pzlob, "Cargo.lock"));
}

test "ZLOB_BRACE filesystem - documentation pattern" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "**/*.{md,txt}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE | zlob.ZLOB_DOUBLESTAR_RECURSIVE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // README.md, docs/guide.md, docs/api.md, docs/readme.txt
    try testing.expect(pzlob.zlo_pathc >= 4);
}

test "ZLOB_BRACE filesystem - web assets pattern" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*.{js,ts,css}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // app.js, app.ts, style.css
    try testing.expectEqual(3, pzlob.zlo_pathc);
}

test "ZLOB_BRACE filesystem - config files pattern" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*.{json,yaml,yml,toml}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // package.json, data.json, config.yaml, config.yml, Cargo.toml
    try testing.expectEqual(5, pzlob.zlo_pathc);
}

test "ZLOB_BRACE filesystem - header files in multiple directories" {
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "{src,lib,include}/**/*.h");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE | zlob.ZLOB_DOUBLESTAR_RECURSIVE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // src/main.h, src/test.h, src/core/engine.h, src/utils/helper.h
    // lib/lib.h, lib/common/shared.h
    // include/api.h, include/types.h
    try testing.expect(pzlob.zlo_pathc >= 8);
}

// ============================================================================
// Wildcard directory + brace filename tests
// These test patterns like "dir/*/*.{a,b}" which combine wildcards in directory
// components with brace alternatives in filename
// ============================================================================

test "ZLOB_BRACE filesystem - wildcard dir with brace extension" {
    // Pattern: */*.{c,h} - wildcard in dir, braces in filename
    // This was broken: wildcards in dirs + braces in filename returned no results
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*/*.{c,h}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // src/main.c, src/main.h, src/test.c, src/test.h, src/utils.c
    // lib/lib.c, lib/lib.h
    // include/api.h, include/types.h
    try testing.expect(pzlob.zlo_pathc >= 9);

    // Verify we have both .c and .h files
    var c_count: usize = 0;
    var h_count: usize = 0;
    for (0..pzlob.zlo_pathc) |i| {
        const path = std.mem.sliceTo(pzlob.zlo_pathv[i], 0);
        if (std.mem.endsWith(u8, path, ".c")) c_count += 1;
        if (std.mem.endsWith(u8, path, ".h")) h_count += 1;
    }
    try testing.expect(c_count >= 4);
    try testing.expect(h_count >= 4);
}

test "ZLOB_BRACE filesystem - literal prefix with wildcard dir and brace extension" {
    // Pattern: src/*/*.{c,h} - literal prefix + wildcard + braces
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "src/*/*.{c,h}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // src/core/engine.c, src/core/engine.h, src/utils/helper.c, src/utils/helper.h
    try testing.expect(pzlob.zlo_pathc >= 4);
}

test "ZLOB_BRACE filesystem - question mark wildcard with brace extension" {
    // Pattern: src/????.{c,h} - ? wildcard + braces
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "src/????.{c,h}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // src/main.c, src/main.h, src/test.c, src/test.h
    try testing.expect(pzlob.zlo_pathc >= 4);
}

test "ZLOB_BRACE filesystem - multiple wildcard dirs with brace extension" {
    // Pattern: */*/*.{c,h} - two wildcard levels + braces
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "*/*/*.{c,h}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // src/core/engine.c, src/core/engine.h
    // src/utils/helper.c, src/utils/helper.h
    // lib/common/shared.c, lib/common/shared.h
    try testing.expect(pzlob.zlo_pathc >= 6);
}

test "ZLOB_BRACE filesystem - brace dir AND wildcard dir AND brace extension" {
    // Pattern: {src,lib}/*/*.{c,h} - braces in dir + wildcard + braces in filename
    const allocator = testing.allocator;
    const tmp_dir = "/tmp";

    try createBraceTestFiles(allocator, tmp_dir);
    defer cleanupBraceTestFiles(allocator, tmp_dir) catch {};

    const test_dir_str = try std.fmt.allocPrint(allocator, "{s}/test_brace", .{tmp_dir});
    defer allocator.free(test_dir_str);

    var cwd_buf: [4096]u8 = undefined;
    const old_cwd = try std.posix.getcwd(&cwd_buf);
    try std.posix.chdir(test_dir_str);
    defer std.posix.chdir(old_cwd) catch {};

    const pattern = try allocator.dupeZ(u8, "{src,lib}/*/*.{c,h}");
    defer allocator.free(pattern);

    var pzlob: zlob.zlob_t = undefined;
    const result = c_lib.zlob(pattern.ptr, zlob.ZLOB_BRACE, null, &pzlob);
    defer if (result == 0) c_lib.zlobfree(&pzlob);

    try testing.expectEqual(0, result);
    // src/core/engine.c, src/core/engine.h, src/utils/helper.c, src/utils/helper.h
    // lib/common/shared.c, lib/common/shared.h
    try testing.expect(pzlob.zlo_pathc >= 6);
}
