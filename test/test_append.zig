const std = @import("std");
const testing = std.testing;
const c_lib = @import("c_lib");

test "GLOB_APPEND - basic append two patterns" {
    const allocator = testing.allocator;

    try std.fs.cwd().makePath("test_append_basic");
    defer std.fs.cwd().deleteTree("test_append_basic") catch {};
    var test_dir = try std.fs.cwd().openDir("test_append_basic", .{});
    defer test_dir.close();

    // Create test files
    try test_dir.writeFile(.{ .sub_path = "file1.txt", .data = "" });
    try test_dir.writeFile(.{ .sub_path = "file2.txt", .data = "" });
    try test_dir.writeFile(.{ .sub_path = "file3.log", .data = "" });
    try test_dir.writeFile(.{ .sub_path = "file4.log", .data = "" });

    var pglob: c_lib.glob_t = undefined;

    // First glob: *.txt
    const pattern1 = try allocator.dupeZ(u8, "test_append_basic/*.txt");
    defer allocator.free(pattern1);
    const result1 = c_lib.glob(pattern1.ptr, 0, null, &pglob);
    try testing.expectEqual(@as(c_int, 0), result1);
    try testing.expectEqual(@as(usize, 2), pglob.gl_pathc);

    // Second glob with APPEND: *.log
    const pattern2 = try allocator.dupeZ(u8, "test_append_basic/*.log");
    defer allocator.free(pattern2);
    const result2 = c_lib.glob(pattern2.ptr, c_lib.GLOB_APPEND, null, &pglob);
    try testing.expectEqual(@as(c_int, 0), result2);
    try testing.expectEqual(@as(usize, 4), pglob.gl_pathc);

    // Verify all files are present
    var found_txt1 = false;
    var found_txt2 = false;
    var found_log3 = false;
    var found_log4 = false;

    for (0..pglob.gl_pathc) |i| {
        const path = std.mem.span(pglob.gl_pathv[i]);
        if (std.mem.endsWith(u8, path, "file1.txt")) found_txt1 = true;
        if (std.mem.endsWith(u8, path, "file2.txt")) found_txt2 = true;
        if (std.mem.endsWith(u8, path, "file3.log")) found_log3 = true;
        if (std.mem.endsWith(u8, path, "file4.log")) found_log4 = true;
    }

    try testing.expect(found_txt1);
    try testing.expect(found_txt2);
    try testing.expect(found_log3);
    try testing.expect(found_log4);

    c_lib.globfree(&pglob);
}

test "GLOB_APPEND - three consecutive appends" {
    const allocator = testing.allocator;

    try std.fs.cwd().makePath("test_append_three");
    defer std.fs.cwd().deleteTree("test_append_three") catch {};
    var test_dir = try std.fs.cwd().openDir("test_append_three", .{});
    defer test_dir.close();

    // Create test files
    try test_dir.writeFile(.{ .sub_path = "a.c", .data = "" });
    try test_dir.writeFile(.{ .sub_path = "b.h", .data = "" });
    try test_dir.writeFile(.{ .sub_path = "c.zig", .data = "" });

    var pglob: c_lib.glob_t = undefined;

    // First glob: *.c
    const pattern1 = try allocator.dupeZ(u8, "test_append_three/*.c");
    defer allocator.free(pattern1);
    _ = c_lib.glob(pattern1.ptr, 0, null, &pglob);
    try testing.expectEqual(@as(usize, 1), pglob.gl_pathc);

    // Second glob with APPEND: *.h
    const pattern2 = try allocator.dupeZ(u8, "test_append_three/*.h");
    defer allocator.free(pattern2);
    _ = c_lib.glob(pattern2.ptr, c_lib.GLOB_APPEND, null, &pglob);
    try testing.expectEqual(@as(usize, 2), pglob.gl_pathc);

    // Third glob with APPEND: *.zig
    const pattern3 = try allocator.dupeZ(u8, "test_append_three/*.zig");
    defer allocator.free(pattern3);
    _ = c_lib.glob(pattern3.ptr, c_lib.GLOB_APPEND, null, &pglob);
    try testing.expectEqual(@as(usize, 3), pglob.gl_pathc);

    c_lib.globfree(&pglob);
}

test "GLOB_APPEND - append to empty results" {
    const allocator = testing.allocator;

    try std.fs.cwd().makePath("test_append_empty");
    defer std.fs.cwd().deleteTree("test_append_empty") catch {};
    var test_dir = try std.fs.cwd().openDir("test_append_empty", .{});
    defer test_dir.close();

    try test_dir.writeFile(.{ .sub_path = "file.txt", .data = "" });

    var pglob: c_lib.glob_t = undefined;

    // First glob: pattern that matches nothing
    const pattern1 = try allocator.dupeZ(u8, "test_append_empty/*.nonexistent");
    defer allocator.free(pattern1);
    const result1 = c_lib.glob(pattern1.ptr, 0, null, &pglob);
    try testing.expectEqual(@as(c_int, c_lib.GLOB_NOMATCH), result1);

    // Second glob with APPEND: pattern that matches something
    const pattern2 = try allocator.dupeZ(u8, "test_append_empty/*.txt");
    defer allocator.free(pattern2);
    const result2 = c_lib.glob(pattern2.ptr, c_lib.GLOB_APPEND, null, &pglob);
    try testing.expectEqual(@as(c_int, 0), result2);
    try testing.expectEqual(@as(usize, 1), pglob.gl_pathc);

    c_lib.globfree(&pglob);
}

test "GLOB_APPEND - preserve order with sorting" {
    const allocator = testing.allocator;

    try std.fs.cwd().makePath("test_append_order");
    defer std.fs.cwd().deleteTree("test_append_order") catch {};
    var test_dir = try std.fs.cwd().openDir("test_append_order", .{});
    defer test_dir.close();

    try test_dir.writeFile(.{ .sub_path = "z.txt", .data = "" });
    try test_dir.writeFile(.{ .sub_path = "a.txt", .data = "" });
    try test_dir.writeFile(.{ .sub_path = "m.log", .data = "" });
    try test_dir.writeFile(.{ .sub_path = "b.log", .data = "" });

    var pglob: c_lib.glob_t = undefined;

    // First glob: *.txt (should be sorted: a.txt, z.txt)
    const pattern1 = try allocator.dupeZ(u8, "test_append_order/*.txt");
    defer allocator.free(pattern1);
    _ = c_lib.glob(pattern1.ptr, 0, null, &pglob);

    // Second glob with APPEND: *.log (should append sorted: b.log, m.log)
    const pattern2 = try allocator.dupeZ(u8, "test_append_order/*.log");
    defer allocator.free(pattern2);
    _ = c_lib.glob(pattern2.ptr, c_lib.GLOB_APPEND, null, &pglob);

    try testing.expectEqual(@as(usize, 4), pglob.gl_pathc);

    // Results should be: a.txt, z.txt, b.log, m.log
    // (first batch sorted, second batch sorted, but not globally sorted)
    const path0 = std.mem.span(pglob.gl_pathv[0]);
    const path1 = std.mem.span(pglob.gl_pathv[1]);
    const path2 = std.mem.span(pglob.gl_pathv[2]);
    const path3 = std.mem.span(pglob.gl_pathv[3]);

    try testing.expect(std.mem.endsWith(u8, path0, "a.txt"));
    try testing.expect(std.mem.endsWith(u8, path1, "z.txt"));
    try testing.expect(std.mem.endsWith(u8, path2, "b.log"));
    try testing.expect(std.mem.endsWith(u8, path3, "m.log"));

    c_lib.globfree(&pglob);
}

test "GLOB_APPEND - with subdirectories" {
    const allocator = testing.allocator;

    try std.fs.cwd().makePath("test_append_dirs/dir1");
    try std.fs.cwd().makePath("test_append_dirs/dir2");
    defer std.fs.cwd().deleteTree("test_append_dirs") catch {};

    var test_dir = try std.fs.cwd().openDir("test_append_dirs", .{});
    defer test_dir.close();

    var dir1 = try test_dir.openDir("dir1", .{});
    defer dir1.close();
    var dir2 = try test_dir.openDir("dir2", .{});
    defer dir2.close();

    try dir1.writeFile(.{ .sub_path = "file.txt", .data = "" });
    try dir2.writeFile(.{ .sub_path = "file.txt", .data = "" });

    var pglob: c_lib.glob_t = undefined;

    // First glob: dir1/*
    const pattern1 = try allocator.dupeZ(u8, "test_append_dirs/dir1/*.txt");
    defer allocator.free(pattern1);
    _ = c_lib.glob(pattern1.ptr, 0, null, &pglob);
    try testing.expectEqual(@as(usize, 1), pglob.gl_pathc);

    // Second glob with APPEND: dir2/*
    const pattern2 = try allocator.dupeZ(u8, "test_append_dirs/dir2/*.txt");
    defer allocator.free(pattern2);
    _ = c_lib.glob(pattern2.ptr, c_lib.GLOB_APPEND, null, &pglob);
    try testing.expectEqual(@as(usize, 2), pglob.gl_pathc);

    c_lib.globfree(&pglob);
}

test "GLOB_APPEND - append many results" {
    const allocator = testing.allocator;

    try std.fs.cwd().makePath("test_append_many");
    defer std.fs.cwd().deleteTree("test_append_many") catch {};
    var test_dir = try std.fs.cwd().openDir("test_append_many", .{});
    defer test_dir.close();

    // Create many files
    for (0..50) |i| {
        const name = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        defer allocator.free(name);
        try test_dir.writeFile(.{ .sub_path = name, .data = "" });
    }

    for (0..50) |i| {
        const name = try std.fmt.allocPrint(allocator, "data{d}.log", .{i});
        defer allocator.free(name);
        try test_dir.writeFile(.{ .sub_path = name, .data = "" });
    }

    var pglob: c_lib.glob_t = undefined;

    // First glob: *.txt (50 files)
    const pattern1 = try allocator.dupeZ(u8, "test_append_many/*.txt");
    defer allocator.free(pattern1);
    _ = c_lib.glob(pattern1.ptr, 0, null, &pglob);
    try testing.expectEqual(@as(usize, 50), pglob.gl_pathc);

    // Second glob with APPEND: *.log (50 more files)
    const pattern2 = try allocator.dupeZ(u8, "test_append_many/*.log");
    defer allocator.free(pattern2);
    _ = c_lib.glob(pattern2.ptr, c_lib.GLOB_APPEND, null, &pglob);
    try testing.expectEqual(@as(usize, 100), pglob.gl_pathc);

    c_lib.globfree(&pglob);
}

test "GLOB_APPEND - without initial glob should work" {
    const allocator = testing.allocator;

    try std.fs.cwd().makePath("test_append_first");
    defer std.fs.cwd().deleteTree("test_append_first") catch {};
    var test_dir = try std.fs.cwd().openDir("test_append_first", .{});
    defer test_dir.close();

    try test_dir.writeFile(.{ .sub_path = "file.txt", .data = "" });

    var pglob: c_lib.glob_t = undefined;
    pglob.gl_pathc = 0;
    pglob.gl_pathv = null;
    pglob.gl_offs = 0;

    // Use GLOB_APPEND on first call (should work like normal glob)
    const pattern = try allocator.dupeZ(u8, "test_append_first/*.txt");
    defer allocator.free(pattern);
    const result = c_lib.glob(pattern.ptr, c_lib.GLOB_APPEND, null, &pglob);
    try testing.expectEqual(@as(c_int, 0), result);
    try testing.expectEqual(@as(usize, 1), pglob.gl_pathc);

    if (result == 0) {
        c_lib.globfree(&pglob);
    }
}

test "GLOB_APPEND - combined with GLOB_NOSORT" {
    const allocator = testing.allocator;

    try std.fs.cwd().makePath("test_append_nosort");
    defer std.fs.cwd().deleteTree("test_append_nosort") catch {};
    var test_dir = try std.fs.cwd().openDir("test_append_nosort", .{});
    defer test_dir.close();

    try test_dir.writeFile(.{ .sub_path = "z.txt", .data = "" });
    try test_dir.writeFile(.{ .sub_path = "a.txt", .data = "" });
    try test_dir.writeFile(.{ .sub_path = "m.log", .data = "" });

    var pglob: c_lib.glob_t = undefined;

    // First glob with NOSORT
    const pattern1 = try allocator.dupeZ(u8, "test_append_nosort/*.txt");
    defer allocator.free(pattern1);
    _ = c_lib.glob(pattern1.ptr, c_lib.GLOB_NOSORT, null, &pglob);
    try testing.expectEqual(@as(usize, 2), pglob.gl_pathc);

    // Append with NOSORT
    const pattern2 = try allocator.dupeZ(u8, "test_append_nosort/*.log");
    defer allocator.free(pattern2);
    _ = c_lib.glob(pattern2.ptr, c_lib.GLOB_APPEND | c_lib.GLOB_NOSORT, null, &pglob);
    try testing.expectEqual(@as(usize, 3), pglob.gl_pathc);

    c_lib.globfree(&pglob);
}
