const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");
const glob = @import("zlob_core");
const root = zlob;

// SIMD Character Search Tests
// These tests verify the core SIMD optimization functionality

test "SIMD - find character in string" {
    const haystack = "abcdefghijklmnopqrstuvwxyz0123456789";
    const needle = 'z';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 25);
}

test "SIMD - character not found" {
    const haystack = "abcdefghijklmnopqrstuvwxyz";
    const needle = '1';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result == null);
}

test "SIMD - short string" {
    const haystack = "abc";
    const needle = 'b';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 1);
}

test "SIMD - first character match" {
    const haystack = "zebra";
    const needle = 'z';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 0);
}

test "SIMD - last character match" {
    const haystack = "abcdefghijklmnopqrstuvwxyz";
    const needle = 'z';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 25);
}

test "SIMD - empty string" {
    const haystack = "";
    const needle = 'a';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result == null);
}

test "SIMD - long string with early match" {
    const haystack = "x" ++ "a" ** 100;
    const needle = 'x';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 0);
}

test "SIMD - long string with late match" {
    const haystack = "a" ** 100 ++ "x";
    const needle = 'x';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 100);
}

test "SIMD - exactly 16 bytes" {
    const haystack = "0123456789abcdef";
    const needle = 'f';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 15);
}

test "SIMD - multiple matches returns first" {
    const haystack = "hello world";
    const needle = 'l';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 2); // First 'l' is at position 2
}

test "SIMD - 32 byte string" {
    const haystack = "abcdefghijklmnopqrstuvwxyz012345";
    const needle = '5';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 31);
}

test "SIMD - special characters" {
    const haystack = "hello@world.com";
    const needle = '@';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 5);
}

test "SIMD - digit search" {
    const haystack = "abc123def456";
    const needle = '1';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 3);
}

test "SIMD - space character" {
    const haystack = "hello world";
    const needle = ' ';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 5);
}

test "SIMD - newline character" {
    const haystack = "line1\nline2";
    const needle = '\n';

    const result = glob.simdFindChar(haystack, needle);
    try testing.expect(result != null);
    try testing.expect(result.? == 5);
}

// matchPaths() API Tests
// These tests verify the in-memory path matching API with recursive ** support

test "matchPaths - simple wildcard" {
    const files = [_][]const u8{
        "test.zig",
        "main.c",
        "lib.zig",
        "readme.md",
    };

    var result = try root.matchPaths(testing.allocator, "*.zig", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
    // Results are sorted alphabetically
    try testing.expectEqualStrings("lib.zig", result.paths[0]);
    try testing.expectEqualStrings("test.zig", result.paths[1]);
}

test "matchPaths - question mark wildcard" {
    const files = [_][]const u8{
        "a.c",
        "b.c",
        "ab.c",
        "abc.c",
    };

    var result = try root.matchPaths(testing.allocator, "?.c", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
    try testing.expectEqualStrings("a.c", result.paths[0]);
    try testing.expectEqualStrings("b.c", result.paths[1]);
}

test "matchPaths - character class" {
    const files = [_][]const u8{
        "test1.txt",
        "test2.txt",
        "test3.txt",
        "testa.txt",
        "testb.txt",
    };

    var result = try root.matchPaths(testing.allocator, "test[123].txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
    try testing.expectEqualStrings("test1.txt", result.paths[0]);
    try testing.expectEqualStrings("test2.txt", result.paths[1]);
    try testing.expectEqualStrings("test3.txt", result.paths[2]);
}

test "matchPaths - negated character class" {
    const files = [_][]const u8{
        "test1.txt",
        "test2.txt",
        "testa.txt",
        "testb.txt",
    };

    var result = try root.matchPaths(testing.allocator, "test[!12].txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
    try testing.expectEqualStrings("testa.txt", result.paths[0]);
    try testing.expectEqualStrings("testb.txt", result.paths[1]);
}

test "matchPaths - no matches" {
    const files = [_][]const u8{
        "test.c",
        "main.c",
        "lib.c",
    };

    var result = try root.matchPaths(testing.allocator, "*.zig", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.match_count);
}

test "matchPaths - all match" {
    const files = [_][]const u8{
        "test.zig",
        "main.zig",
        "lib.zig",
    };

    var result = try root.matchPaths(testing.allocator, "*.zig", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

test "matchPaths - empty file list" {
    const files = [_][]const u8{};

    var result = try root.matchPaths(testing.allocator, "*.zig", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.match_count);
}

test "matchPaths - exact match pattern" {
    const files = [_][]const u8{
        "exact.txt",
        "not-exact.txt",
        "exact-not.txt",
    };

    var result = try root.matchPaths(testing.allocator, "exact.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expectEqualStrings("exact.txt", result.paths[0]);
}

test "matchPaths - complex pattern" {
    const files = [_][]const u8{
        "test_01.txt",
        "test_02.txt",
        "test_99.txt",
        "test_ab.txt",
        "prod_01.txt",
    };

    var result = try root.matchPaths(testing.allocator, "test_[0-9][0-9].txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
    try testing.expectEqualStrings("test_01.txt", result.paths[0]);
    try testing.expectEqualStrings("test_02.txt", result.paths[1]);
    try testing.expectEqualStrings("test_99.txt", result.paths[2]);
}

test "matchPaths - paths with directories" {
    const files = [_][]const u8{
        "src/main.zig",
        "src/test.zig",
        "lib/helper.zig",
        "main.c",
    };

    var result = try root.matchPaths(testing.allocator, "src/*.zig", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
    try testing.expectEqualStrings("src/main.zig", result.paths[0]);
    try testing.expectEqualStrings("src/test.zig", result.paths[1]);
}

test "matchPaths - special characters in filenames" {
    const files = [_][]const u8{
        "test-file.txt",
        "test_file.txt",
        "test.file.txt",
        "testfile.txt",
    };

    var result = try root.matchPaths(testing.allocator, "test*.txt", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.match_count);
}
