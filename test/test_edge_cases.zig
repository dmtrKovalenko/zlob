//! Additional edge case tests for zlob
//!
//! Tests for:
//! - ZLOB_NOESCAPE flag behavior
//! - Nested brace expansion
//! - Character class edge cases
//! - Various corner cases

const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");
const zlob_flags = @import("zlob_flags");
const fnmatch = zlob.fnmatch;
const test_utils = @import("test_utils");
const testMatchPathsOnly = test_utils.testMatchPathsOnly;
const zlobIsomorphicTest = test_utils.zlobIsomorphicTest;
const TestResult = test_utils.TestResult;

/// Helper to call fnmatch with default options
fn fnmatchFull(pattern: []const u8, string: []const u8) bool {
    return fnmatch.fnmatch(pattern, string, .{});
}

test "fnmatch - reversed range is skipped (empty)" {
    // [z-a] with z > a results in an empty range (implementation skips invalid ranges)
    // POSIX says behavior is undefined; this implementation skips the range
    try testing.expect(!fnmatchFull("[z-a]", "z")); // Doesn't match 'z'
    try testing.expect(!fnmatchFull("[z-a]", "-")); // Doesn't match '-'
    try testing.expect(!fnmatchFull("[z-a]", "a")); // Doesn't match 'a'
    try testing.expect(!fnmatchFull("[z-a]", "m")); // Doesn't match anything
}

test "fnmatch - bracket with exclamation mark as second char" {
    // [a!b] matches a, !, or b (! is literal when not first)
    try testing.expect(fnmatchFull("[a!b]", "a"));
    try testing.expect(fnmatchFull("[a!b]", "!"));
    try testing.expect(fnmatchFull("[a!b]", "b"));
    try testing.expect(!fnmatchFull("[a!b]", "c"));
}

test "fnmatch - bracket with caret as second char" {
    // [a^b] matches a, ^, or b (^ is literal when not first)
    try testing.expect(fnmatchFull("[a^b]", "a"));
    try testing.expect(fnmatchFull("[a^b]", "^"));
    try testing.expect(fnmatchFull("[a^b]", "b"));
    try testing.expect(!fnmatchFull("[a^b]", "c"));
}

test "fnmatch - negated bracket with closing bracket first" {
    // [!]abc] means NOT ], a, b, or c
    try testing.expect(!fnmatchFull("[!]abc]", "]"));
    try testing.expect(!fnmatchFull("[!]abc]", "a"));
    try testing.expect(!fnmatchFull("[!]abc]", "b"));
    try testing.expect(!fnmatchFull("[!]abc]", "c"));
    try testing.expect(fnmatchFull("[!]abc]", "d"));
    try testing.expect(fnmatchFull("[!]abc]", "x"));
}

test "fnmatch - bracket with hyphen in middle position" {
    // [a-c-e] should match a, b, c (range), -, e
    try testing.expect(fnmatchFull("[a-c-e]", "a"));
    try testing.expect(fnmatchFull("[a-c-e]", "b"));
    try testing.expect(fnmatchFull("[a-c-e]", "c"));
    try testing.expect(fnmatchFull("[a-c-e]", "-"));
    try testing.expect(fnmatchFull("[a-c-e]", "e"));
    try testing.expect(!fnmatchFull("[a-c-e]", "d"));
}

test "fnmatch - only closing bracket in class" {
    // []] matches only ]
    try testing.expect(fnmatchFull("[]]", "]"));
    try testing.expect(!fnmatchFull("[]]", "["));
    try testing.expect(!fnmatchFull("[]]", "a"));
}

test "fnmatch - bracket with backslash" {
    // [\\] matches backslash (escaped)
    try testing.expect(fnmatchFull("[\\\\]", "\\"));
    try testing.expect(!fnmatchFull("[\\\\]", "a"));
}

// ============================================================================
// Pattern edge cases
// ============================================================================

test "fnmatch - pattern with only special chars" {
    try testing.expect(fnmatchFull("*?*", "ab"));
    try testing.expect(fnmatchFull("*?*", "a"));
    try testing.expect(!fnmatchFull("*?*", ""));

    try testing.expect(fnmatchFull("?*?", "ab"));
    try testing.expect(!fnmatchFull("?*?", "a"));

    try testing.expect(fnmatchFull("**?**", "x"));
}

test "fnmatch - very long pattern with wildcards" {
    // Pattern: prefix*suffix with long prefix and suffix
    const pattern = "abcdefghij*klmnopqrst";
    try testing.expect(fnmatchFull(pattern, "abcdefghijXXXklmnopqrst"));
    try testing.expect(fnmatchFull(pattern, "abcdefghijklmnopqrst"));
    try testing.expect(!fnmatchFull(pattern, "abcdefghijklmnopqrs")); // Missing 't'
    try testing.expect(!fnmatchFull(pattern, "bcdefghijXXXklmnopqrst")); // Missing 'a'
}

test "fnmatch - alternating wildcards and literals" {
    try testing.expect(fnmatchFull("a*b*c*d", "abcd"));
    try testing.expect(fnmatchFull("a*b*c*d", "aXbYcZd"));
    try testing.expect(fnmatchFull("a*b*c*d", "aXXXbYYYcZZZd"));
    try testing.expect(!fnmatchFull("a*b*c*d", "abcde")); // Extra 'e' at end
    try testing.expect(!fnmatchFull("a*b*c*d", "Xabcd")); // Missing 'a' at start
}

test "fnmatch - unicode in pattern and string" {
    // Basic unicode support
    try testing.expect(fnmatchFull("*.txt", "file.txt"));
    // Note: Full unicode support depends on implementation
}

// ============================================================================
// matchPaths edge cases
// ============================================================================

test "matchPaths - pattern starting with dot" {
    const files = [_][]const u8{
        ".hidden",
        ".gitignore",
        "visible.txt",
        ".config/settings",
    };

    var result = try zlob.matchPaths(testing.allocator, ".*", &files, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.len());
}

test "matchPaths - double star in matchPaths" {
    const files = [_][]const u8{
        "a/b/c/d.txt",
        "a/x.txt",
        "b.txt",
    };

    var result = try zlob.matchPaths(testing.allocator, "**/*.txt", &files, zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.len());
}

test "matchPaths - pattern ending with slash" {
    const files = [_][]const u8{
        "dir/",
        "dir/file.txt",
        "other/",
    };

    var result = try zlob.matchPaths(testing.allocator, "*/", &files, 0);
    defer result.deinit();

    // Should match directory entries ending with /
    try testing.expectEqual(@as(usize, 2), result.len());
}
