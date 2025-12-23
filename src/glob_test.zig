const std = @import("std");
const testing = std.testing;
const glob = @import("glob.zig");

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

// Data structure tests

test "Glob - init and deinit" {
    var g = glob.Glob.init(testing.allocator, 0);
    defer g.deinit();

    try testing.expect(g.match_count == 0);
    try testing.expect(g.flags == 0);
}

test "Glob - init with flags" {
    var g = glob.Glob.init(testing.allocator, glob.GLOB_MARK | glob.GLOB_NOSORT);
    defer g.deinit();

    try testing.expect(g.flags == (glob.GLOB_MARK | glob.GLOB_NOSORT));
}

test "Constants - check flag values" {
    try testing.expect(glob.GLOB_MARK == 0x0008);
    try testing.expect(glob.GLOB_NOSORT == 0x0020);
    try testing.expect(glob.GLOB_NOESCAPE == 0x1000);
}
