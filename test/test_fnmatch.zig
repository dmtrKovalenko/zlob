//! Comprehensive tests for fnmatch core functionality
//!
//! Tests edge cases and corner cases in pattern matching:
//! - Escape sequences (\*, \?, \[)
//! - Character class edge cases (reversed ranges, special chars)
//! - Empty patterns and strings
//! - Bracket expression edge cases
//! - Consecutive wildcards

const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");
const fnmatch = zlob.fnmatch;
const pattern_context = zlob.pattern_context;
const PatternContext = pattern_context.PatternContext;
const PatternTemplate = pattern_context.PatternTemplate;
const test_utils = @import("test_utils");
const testMatchPathsOnly = test_utils.testMatchPathsOnly;
const zlobIsomorphicTest = test_utils.zlobIsomorphicTest;
const TestResult = test_utils.TestResult;

/// Helper to call fnmatch with default options
fn fnmatchFull(pattern: []const u8, string: []const u8) bool {
    return fnmatch.match(pattern, string, .{});
}

// Empty string and empty pattern tests
test "fnmatch - empty string matches empty pattern" {
    try testing.expect(fnmatchFull("", ""));
}

test "fnmatch - empty pattern does not match non-empty string" {
    try testing.expect(!fnmatchFull("", "hello"));
}

test "fnmatch - non-empty pattern does not match empty string" {
    try testing.expect(!fnmatchFull("hello", ""));
}

test "fnmatch - star matches empty string" {
    try testing.expect(fnmatchFull("*", ""));
}

test "fnmatch - star only matches anything" {
    try testing.expect(fnmatchFull("*", "hello"));
    try testing.expect(fnmatchFull("*", "x"));
    try testing.expect(fnmatchFull("*", ""));
    try testing.expect(fnmatchFull("*", "a/b/c"));
}

test "fnmatch - question mark does not match empty string" {
    try testing.expect(!fnmatchFull("?", ""));
}

test "fnmatch - question mark matches single char" {
    try testing.expect(fnmatchFull("?", "x"));
    try testing.expect(!fnmatchFull("?", "xy"));
}

// ============================================================================
// Escape sequence tests (POSIX behavior)
// Backslash quotes the following character, making it literal.
// ============================================================================

test "fnmatch - escaped star matches literal star" {
    try testing.expect(fnmatchFull("\\*", "*"));
    try testing.expect(!fnmatchFull("\\*", "a"));
    try testing.expect(!fnmatchFull("\\*", ""));
}

test "fnmatch - escaped question mark matches literal question mark" {
    try testing.expect(fnmatchFull("\\?", "?"));
    try testing.expect(!fnmatchFull("\\?", "a"));
    try testing.expect(!fnmatchFull("\\?", ""));
}

test "fnmatch - escaped bracket matches literal bracket" {
    try testing.expect(fnmatchFull("\\[", "["));
    try testing.expect(!fnmatchFull("\\[", "a"));
}

test "fnmatch - backslash at end of pattern" {
    // Trailing backslash matches literal backslash
    try testing.expect(fnmatchFull("foo\\", "foo\\"));
}

test "fnmatch - escaped backslash" {
    try testing.expect(fnmatchFull("\\\\", "\\"));
}

test "fnmatch - escape followed by regular char" {
    // \a should match literal 'a'
    try testing.expect(fnmatchFull("\\a", "a"));
}

test "fnmatch - escape in middle of pattern" {
    try testing.expect(fnmatchFull("foo\\*bar", "foo*bar"));
    try testing.expect(!fnmatchFull("foo\\*bar", "fooXbar"));
}

// ============================================================================
// Character class (bracket expression) tests
// ============================================================================

test "fnmatch - basic character class" {
    try testing.expect(fnmatchFull("[abc]", "a"));
    try testing.expect(fnmatchFull("[abc]", "b"));
    try testing.expect(fnmatchFull("[abc]", "c"));
    try testing.expect(!fnmatchFull("[abc]", "d"));
    try testing.expect(!fnmatchFull("[abc]", ""));
}

test "fnmatch - character range" {
    try testing.expect(fnmatchFull("[a-z]", "m"));
    try testing.expect(fnmatchFull("[a-z]", "a"));
    try testing.expect(fnmatchFull("[a-z]", "z"));
    try testing.expect(!fnmatchFull("[a-z]", "A"));
    try testing.expect(!fnmatchFull("[a-z]", "0"));
}

test "fnmatch - numeric range" {
    try testing.expect(fnmatchFull("[0-9]", "0"));
    try testing.expect(fnmatchFull("[0-9]", "5"));
    try testing.expect(fnmatchFull("[0-9]", "9"));
    try testing.expect(!fnmatchFull("[0-9]", "a"));
}

test "fnmatch - negated character class" {
    try testing.expect(!fnmatchFull("[!abc]", "a"));
    try testing.expect(!fnmatchFull("[!abc]", "b"));
    try testing.expect(!fnmatchFull("[!abc]", "c"));
    try testing.expect(fnmatchFull("[!abc]", "d"));
    try testing.expect(fnmatchFull("[!abc]", "x"));
}

test "fnmatch - negated range" {
    try testing.expect(!fnmatchFull("[!0-9]", "5"));
    try testing.expect(fnmatchFull("[!0-9]", "a"));
    try testing.expect(fnmatchFull("[!0-9]", "Z"));
}

test "fnmatch - bracket expression with closing bracket as first char" {
    // ]abc] matches ], a, b, or c
    try testing.expect(fnmatchFull("[]abc]", "]"));
    try testing.expect(fnmatchFull("[]abc]", "a"));
    try testing.expect(fnmatchFull("[]abc]", "b"));
    try testing.expect(fnmatchFull("[]abc]", "c"));
    try testing.expect(!fnmatchFull("[]abc]", "d"));
}

test "fnmatch - bracket expression with hyphen" {
    // [-abc] matches -, a, b, or c (hyphen at start is literal)
    try testing.expect(fnmatchFull("[-abc]", "-"));
    try testing.expect(fnmatchFull("[-abc]", "a"));
}

test "fnmatch - bracket expression with hyphen at end" {
    // [abc-] matches a, b, c, or - (hyphen at end is literal)
    try testing.expect(fnmatchFull("[abc-]", "-"));
    try testing.expect(fnmatchFull("[abc-]", "a"));
}

test "fnmatch - multiple ranges in bracket expression" {
    try testing.expect(fnmatchFull("[a-zA-Z]", "m"));
    try testing.expect(fnmatchFull("[a-zA-Z]", "M"));
    try testing.expect(!fnmatchFull("[a-zA-Z]", "5"));
}

test "fnmatch - bracket with special characters" {
    // Note: [!@#$%] is a NEGATED class (! at start means NOT @#$%)
    // Use [@#$%!] to match these chars literally (! not at start)
    try testing.expect(fnmatchFull("[@#$%!]", "!"));
    try testing.expect(fnmatchFull("[@#$%!]", "@"));
    try testing.expect(fnmatchFull("[@#$%!]", "#"));
    try testing.expect(!fnmatchFull("[@#$%!]", "a"));
}

// ============================================================================
// Consecutive wildcard tests
// ============================================================================

test "fnmatch - consecutive stars" {
    try testing.expect(fnmatchFull("**", "hello"));
    try testing.expect(fnmatchFull("**", ""));
    try testing.expect(fnmatchFull("***", "hello"));
}

test "fnmatch - star star star pattern" {
    try testing.expect(fnmatchFull("a***b", "ab"));
    try testing.expect(fnmatchFull("a***b", "aXb"));
    try testing.expect(fnmatchFull("a***b", "aXXXb"));
}

test "fnmatch - question and star combination" {
    try testing.expect(fnmatchFull("?*", "a"));
    try testing.expect(fnmatchFull("?*", "ab"));
    try testing.expect(fnmatchFull("?*", "abc"));
    try testing.expect(!fnmatchFull("?*", ""));
}

test "fnmatch - star and question combination" {
    try testing.expect(fnmatchFull("*?", "a"));
    try testing.expect(fnmatchFull("*?", "ab"));
    try testing.expect(fnmatchFull("*?", "abc"));
    try testing.expect(!fnmatchFull("*?", ""));
}

test "fnmatch - multiple question marks" {
    try testing.expect(fnmatchFull("???", "abc"));
    try testing.expect(!fnmatchFull("???", "ab"));
    try testing.expect(!fnmatchFull("???", "abcd"));
}

test "fnmatch - mixed wildcards" {
    try testing.expect(fnmatchFull("a*b?c", "aXXbYc"));
    try testing.expect(fnmatchFull("a*b?c", "abXc"));
    try testing.expect(!fnmatchFull("a*b?c", "abc"));
    try testing.expect(!fnmatchFull("a*b?c", "aXXbc"));
}

// ============================================================================
// Complex pattern tests
// ============================================================================

test "fnmatch - complex real-world patterns" {
    // Git-style patterns
    try testing.expect(fnmatchFull("*.c", "main.c"));
    try testing.expect(fnmatchFull("*.c", "test.c"));
    try testing.expect(!fnmatchFull("*.c", "main.h"));

    // Multiple extensions
    try testing.expect(fnmatchFull("test.[ch]", "test.c"));
    try testing.expect(fnmatchFull("test.[ch]", "test.h"));
    try testing.expect(!fnmatchFull("test.[ch]", "test.o"));

    // Prefix matching
    try testing.expect(fnmatchFull("test_*.txt", "test_001.txt"));
    try testing.expect(fnmatchFull("test_*.txt", "test_.txt"));
    try testing.expect(!fnmatchFull("test_*.txt", "test.txt"));
}

test "fnmatch - pattern with literal dot" {
    try testing.expect(fnmatchFull("a.b", "a.b"));
    try testing.expect(!fnmatchFull("a.b", "aXb"));
}

test "fnmatch - pattern ending with star" {
    try testing.expect(fnmatchFull("hello*", "hello"));
    try testing.expect(fnmatchFull("hello*", "hello world"));
    try testing.expect(!fnmatchFull("hello*", "hell"));
}

test "fnmatch - pattern starting with star" {
    try testing.expect(fnmatchFull("*world", "world"));
    try testing.expect(fnmatchFull("*world", "hello world"));
    try testing.expect(!fnmatchFull("*world", "worlds"));
}

test "fnmatch - star in middle" {
    try testing.expect(fnmatchFull("a*z", "az"));
    try testing.expect(fnmatchFull("a*z", "abcdefghijklmnopqrstuvwxyz"));
    try testing.expect(!fnmatchFull("a*z", "a"));
    try testing.expect(!fnmatchFull("a*z", "z"));
}

// ============================================================================
// matchPaths integration tests for edge cases
// ============================================================================

test "matchPaths - empty file list with NOCHECK" {
    const paths = [_][]const u8{};
    var result = try zlob.matchPaths(testing.allocator, "*.txt", &paths, zlob.ZLOB_NOCHECK);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expectEqualStrings("*.txt", result.paths[0]);
}

test "matchPaths - literal pattern matching" {
    const paths = [_][]const u8{
        "exact_match.txt",
        "no_match.txt",
    };
    var result = try zlob.matchPaths(testing.allocator, "exact_match.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expectEqualStrings("exact_match.txt", result.paths[0]);
}

test "matchPaths - pattern with all wildcards" {
    const paths = [_][]const u8{
        "a",
        "abc",
        "xyz123",
    };
    var result = try zlob.matchPaths(testing.allocator, "*", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

test "matchPaths - bracket expression with path" {
    const paths = [_][]const u8{
        "file1.txt",
        "file2.txt",
        "file3.txt",
        "filea.txt",
    };
    var result = try zlob.matchPaths(testing.allocator, "file[123].txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

test "matchPaths - case sensitivity" {
    const paths = [_][]const u8{
        "Test.TXT",
        "test.txt",
        "TEST.txt",
    };
    var result = try zlob.matchPaths(testing.allocator, "test.txt", &paths, 0);
    defer result.deinit();

    // Glob is case-sensitive by default
    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expectEqualStrings("test.txt", result.paths[0]);
}

// ============================================================================
// Pattern template fast-path tests
// ============================================================================

test "PatternContext - literal template" {
    const ctx = PatternContext.init("exact.txt");
    try testing.expectEqual(PatternTemplate.literal, ctx.template);
    try testing.expect(!ctx.has_wildcards);
}

test "PatternContext - star_only template" {
    const ctx = PatternContext.init("*");
    try testing.expectEqual(PatternTemplate.star_only, ctx.template);
    try testing.expect(ctx.has_wildcards);
}

test "PatternContext - star_dot_ext template" {
    const ctx = PatternContext.init("*.txt");
    try testing.expectEqual(PatternTemplate.star_dot_ext, ctx.template);
    try testing.expectEqualStrings(".txt", ctx.template_suffix);
}

test "PatternContext - prefix_star template" {
    const ctx = PatternContext.init("test_*");
    try testing.expectEqual(PatternTemplate.prefix_star, ctx.template);
    try testing.expectEqualStrings("test_", ctx.template_prefix);
}

test "PatternContext - prefix_star_ext template" {
    const ctx = PatternContext.init("test_*.txt");
    try testing.expectEqual(PatternTemplate.prefix_star_ext, ctx.template);
    try testing.expectEqualStrings("test_", ctx.template_prefix);
    try testing.expectEqualStrings(".txt", ctx.template_suffix);
}

test "PatternContext - bracket_with_affixes template" {
    const ctx = PatternContext.init("file[123].txt");
    try testing.expectEqual(PatternTemplate.bracket_with_affixes, ctx.template);
    try testing.expectEqualStrings("file", ctx.template_prefix);
    try testing.expectEqualStrings(".txt", ctx.template_suffix);
    try testing.expect(ctx.bracket_bitmap != null);
}

test "PatternContext - required_last_char extraction" {
    const ctx1 = PatternContext.init("*.txt");
    try testing.expectEqual(@as(?u8, 't'), ctx1.required_last_char);

    const ctx2 = PatternContext.init("test*");
    try testing.expectEqual(@as(?u8, null), ctx2.required_last_char);

    const ctx3 = PatternContext.init("exact");
    try testing.expectEqual(@as(?u8, 't'), ctx3.required_last_char);
}

// SIMD helper function tests

test "hasWildcardsSIMD - detects wildcards" {
    try testing.expect(fnmatch.hasWildcards("*.txt"));
    try testing.expect(fnmatch.hasWildcards("file?.c"));
    try testing.expect(fnmatch.hasWildcards("[abc]"));
    try testing.expect(!fnmatch.hasWildcards("no_wildcards"));
    try testing.expect(!fnmatch.hasWildcards(""));
}

test "indexOfCharSIMD - finds character" {
    try testing.expectEqual(@as(?usize, 5), pattern_context.indexOfCharSIMD("hello world", ' '));
    try testing.expectEqual(@as(?usize, 0), pattern_context.indexOfCharSIMD("hello", 'h'));
    try testing.expectEqual(@as(?usize, null), pattern_context.indexOfCharSIMD("hello", 'x'));
}

test "lastIndexOfCharSIMD - finds last occurrence" {
    // "a/b/c/d" has slashes at indices 1, 3, 5. Last is at 5.
    try testing.expectEqual(@as(?usize, 5), pattern_context.lastIndexOfCharSIMD("a/b/c/d", '/'));
    try testing.expectEqual(@as(?usize, 0), pattern_context.lastIndexOfCharSIMD("/single", '/'));
    try testing.expectEqual(@as(?usize, null), pattern_context.lastIndexOfCharSIMD("no_slash", '/'));
}
