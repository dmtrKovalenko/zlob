const std = @import("std");
const testing = std.testing;
const simdglob = @import("simdglob");

test "GLOB_BRACE - basic brace expansion" {
    const files = [_][]const u8{
        "a.txt",
        "b.txt",
        "c.txt",
        "d.txt",
    };

    var result = try simdglob.matchPaths(testing.allocator, "{a,b,c}.txt", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);

    // Check that we got the right files
    var found_a = false;
    var found_b = false;
    var found_c = false;
    for (result.paths) |path| {
        if (std.mem.eql(u8, path, "a.txt")) found_a = true;
        if (std.mem.eql(u8, path, "b.txt")) found_b = true;
        if (std.mem.eql(u8, path, "c.txt")) found_c = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
    try testing.expect(found_c);
}

test "GLOB_BRACE - brace with wildcards" {
    const files = [_][]const u8{
        "foo.txt",
        "foo.log",
        "bar.txt",
        "bar.log",
        "baz.txt",
    };

    var result = try simdglob.matchPaths(testing.allocator, "{foo,bar}.*", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.match_count);

    // Should match foo.txt, foo.log, bar.txt, bar.log
    var found_foo_txt = false;
    var found_foo_log = false;
    var found_bar_txt = false;
    var found_bar_log = false;
    for (result.paths) |path| {
        if (std.mem.eql(u8, path, "foo.txt")) found_foo_txt = true;
        if (std.mem.eql(u8, path, "foo.log")) found_foo_log = true;
        if (std.mem.eql(u8, path, "bar.txt")) found_bar_txt = true;
        if (std.mem.eql(u8, path, "bar.log")) found_bar_log = true;
    }
    try testing.expect(found_foo_txt);
    try testing.expect(found_foo_log);
    try testing.expect(found_bar_txt);
    try testing.expect(found_bar_log);
}

test "GLOB_BRACE - wildcard with brace extension" {
    const files = [_][]const u8{
        "test.txt",
        "test.log",
        "test.md",
        "test.rs",
        "readme.txt",
    };

    var result = try simdglob.matchPaths(testing.allocator, "test.{txt,log,md}", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

test "GLOB_BRACE - two alternatives" {
    const files = [_][]const u8{
        "main.c",
        "test.c",
        "main.h",
        "test.h",
    };

    var result = try simdglob.matchPaths(testing.allocator, "main.{c,h}", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);

    var found_main_c = false;
    var found_main_h = false;
    for (result.paths) |path| {
        if (std.mem.eql(u8, path, "main.c")) found_main_c = true;
        if (std.mem.eql(u8, path, "main.h")) found_main_h = true;
    }
    try testing.expect(found_main_c);
    try testing.expect(found_main_h);
}

test "GLOB_BRACE - single alternative" {
    const files = [_][]const u8{
        "test.txt",
        "test.log",
    };

    var result = try simdglob.matchPaths(testing.allocator, "test.{txt}", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expect(std.mem.eql(u8, result.paths[0], "test.txt"));
}

test "GLOB_BRACE - multiple brace groups" {
    const files = [_][]const u8{
        "a/x.txt",
        "a/y.txt",
        "b/x.txt",
        "b/y.txt",
        "c/x.txt",
    };

    var result = try simdglob.matchPaths(testing.allocator, "{a,b}/{x,y}.txt", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.match_count);

    var found_ax = false;
    var found_ay = false;
    var found_bx = false;
    var found_by = false;
    for (result.paths) |path| {
        if (std.mem.eql(u8, path, "a/x.txt")) found_ax = true;
        if (std.mem.eql(u8, path, "a/y.txt")) found_ay = true;
        if (std.mem.eql(u8, path, "b/x.txt")) found_bx = true;
        if (std.mem.eql(u8, path, "b/y.txt")) found_by = true;
    }
    try testing.expect(found_ax);
    try testing.expect(found_ay);
    try testing.expect(found_bx);
    try testing.expect(found_by);
}

test "GLOB_BRACE - without flag treats as literal" {
    const files = [_][]const u8{
        "a.txt",
        "b.txt",
        "{a,b}.txt",
    };

    // Without GLOB_BRACE flag, braces should be treated as literal characters
    var result = try simdglob.matchPaths(testing.allocator, "{a,b}.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expect(std.mem.eql(u8, result.paths[0], "{a,b}.txt"));
}

test "GLOB_BRACE - prefix and suffix" {
    const files = [_][]const u8{
        "prefix_a_suffix.txt",
        "prefix_b_suffix.txt",
        "prefix_c_suffix.txt",
        "prefix_d_suffix.txt",
    };

    var result = try simdglob.matchPaths(testing.allocator, "prefix_{a,b,c}_suffix.txt", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

test "GLOB_BRACE - with paths" {
    const files = [_][]const u8{
        "src/main.zig",
        "src/test.zig",
        "lib/main.zig",
        "lib/test.zig",
        "docs/readme.md",
    };

    var result = try simdglob.matchPaths(testing.allocator, "{src,lib}/*.zig", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.match_count);
}

test "GLOB_BRACE - numeric alternatives" {
    const files = [_][]const u8{
        "file1.txt",
        "file2.txt",
        "file3.txt",
        "file4.txt",
    };

    var result = try simdglob.matchPaths(testing.allocator, "file{1,2,3}.txt", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

test "GLOB_BRACE - empty alternatives" {
    const files = [_][]const u8{
        "test.txt",
        "test_suffix.txt",
        "other.txt",
    };

    // {,_suffix} should match both empty string and "_suffix"
    var result = try simdglob.matchPaths(testing.allocator, "test{,_suffix}.txt", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);

    var found_test = false;
    var found_test_suffix = false;
    for (result.paths) |path| {
        if (std.mem.eql(u8, path, "test.txt")) found_test = true;
        if (std.mem.eql(u8, path, "test_suffix.txt")) found_test_suffix = true;
    }
    try testing.expect(found_test);
    try testing.expect(found_test_suffix);
}

test "GLOB_BRACE - complex real-world pattern" {
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

    var result = try simdglob.matchPaths(testing.allocator, "{src,lib}/*.{c,h}", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 6), result.match_count);
}

test "GLOB_BRACE - no matches" {
    const files = [_][]const u8{
        "a.txt",
        "b.txt",
    };

    var result = try simdglob.matchPaths(testing.allocator, "{x,y,z}.txt", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.match_count);
}

test "GLOB_BRACE - combined with character class" {
    const files = [_][]const u8{
        "a1.txt",
        "a2.txt",
        "b1.txt",
        "b2.txt",
        "c1.txt",
    };

    var result = try simdglob.matchPaths(testing.allocator, "{a,b}[12].txt", &files, simdglob.GLOB_BRACE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.match_count);
}

test "GLOB_BRACE - long alternatives" {
    const files = [_][]const u8{
        "very_long_alternative_name_one.txt",
        "very_long_alternative_name_two.txt",
        "very_long_alternative_name_three.txt",
    };

    var result = try simdglob.matchPaths(
        testing.allocator,
        "very_long_alternative_name_{one,two,three}.txt",
        &files,
        simdglob.GLOB_BRACE,
    );
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}
