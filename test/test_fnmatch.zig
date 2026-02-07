//! Comprehensive tests for fnmatch core functionality
//!
//! Tests edge cases and corner cases in pattern matching:
//! - Escape sequences (\*, \?, \[)
//! - Character class edge cases (reversed ranges, special chars)
//! - Empty patterns and strings
//! - Bracket expression edge cases
//! - Consecutive wildcards
//! - Extended glob patterns (?(), *(), +(), @(), !())
//! - POSIX character classes ([[:alpha:]], [[:digit:]], etc.)
//! - ZlobFlags-based API (noescape, extglob)

const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");
const zlob_flags = @import("zlob_flags");
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
    return fnmatch.fnmatch(pattern, string, .{});
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
    var result = try zlob.matchPaths(testing.allocator, "*.txt", &paths, zlob_flags.ZLOB_NOCHECK);
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

test "hasWildcards - detects braces" {
    try testing.expect(fnmatch.hasWildcards("{a,b}"));
    try testing.expect(fnmatch.hasWildcards("src/{lib,main}.rs"));
    try testing.expect(fnmatch.hasWildcards("{foo}"));
    try testing.expect(!fnmatch.hasWildcards("no_braces"));
}

test "hasWildcards - detects extglob" {
    try testing.expect(fnmatch.hasWildcards("?(foo)"));
    try testing.expect(fnmatch.hasWildcards("*(bar)"));
    try testing.expect(fnmatch.hasWildcards("+(baz)"));
    try testing.expect(fnmatch.hasWildcards("@(qux)"));
    try testing.expect(fnmatch.hasWildcards("!(quux)"));
    try testing.expect(!fnmatch.hasWildcards("plain(text)"));
}

test "hasWildcardsWithFlags - respects flags" {
    const ZlobFlags = zlob_flags.ZlobFlags;
    // No flags: only basic wildcards
    try testing.expect(pattern_context.hasWildcards("*.txt", ZlobFlags{}));
    try testing.expect(!pattern_context.hasWildcards("{a,b}", ZlobFlags{}));
    // Note: "?(foo)" contains '?' which IS a basic wildcard, so it's always detected.
    // To test extglob-only detection, use a pattern where extglob prefix is NOT a basic wildcard.
    try testing.expect(!pattern_context.hasWildcards("@(foo)", ZlobFlags{})); // '@' is not a wildcard
    try testing.expect(!pattern_context.hasWildcards("+(foo)", ZlobFlags{})); // '+' is not a wildcard

    // Brace flag only
    try testing.expect(pattern_context.hasWildcards("{a,b}", ZlobFlags{ .brace = true }));
    try testing.expect(!pattern_context.hasWildcards("@(foo)", ZlobFlags{ .brace = true }));

    // Extglob flag only
    try testing.expect(pattern_context.hasWildcards("@(foo)", ZlobFlags{ .extglob = true }));
    try testing.expect(pattern_context.hasWildcards("+(bar)", ZlobFlags{ .extglob = true }));
    try testing.expect(!pattern_context.hasWildcards("{a,b}", ZlobFlags{ .extglob = true }));

    // Both flags
    try testing.expect(pattern_context.hasWildcards("{a,b}", ZlobFlags{ .brace = true, .extglob = true }));
    try testing.expect(pattern_context.hasWildcards("@(foo)", ZlobFlags{ .brace = true, .extglob = true }));
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

// ============================================================================
// Extglob unit tests (via fnmatch.fnmatch with .extglob = true)
// ============================================================================

const extglob_flags = zlob.ZlobFlags{ .extglob = true };

fn matchExtglob(pattern: []const u8, string: []const u8) bool {
    return fnmatch.fnmatch(pattern, string, extglob_flags);
}

test "fnmatch extglob - @() matches exactly one alternative" {
    try testing.expect(matchExtglob("@(foo|bar)", "foo"));
    try testing.expect(matchExtglob("@(foo|bar)", "bar"));
    try testing.expect(!matchExtglob("@(foo|bar)", "baz"));
    try testing.expect(!matchExtglob("@(foo|bar)", "foobar"));
    try testing.expect(!matchExtglob("@(foo|bar)", ""));
}

test "fnmatch extglob - @() with prefix and suffix" {
    try testing.expect(matchExtglob("test.@(c|h|cpp)", "test.c"));
    try testing.expect(matchExtglob("test.@(c|h|cpp)", "test.h"));
    try testing.expect(matchExtglob("test.@(c|h|cpp)", "test.cpp"));
    try testing.expect(!matchExtglob("test.@(c|h|cpp)", "test.txt"));
}

test "fnmatch extglob - ?(pattern) zero or one" {
    try testing.expect(matchExtglob("file?(.bak).txt", "file.txt"));
    try testing.expect(matchExtglob("file?(.bak).txt", "file.bak.txt"));
    try testing.expect(!matchExtglob("file?(.bak).txt", "file.bak.bak.txt"));
}

test "fnmatch extglob - *(pattern) zero or more" {
    try testing.expect(matchExtglob("a*(X)b", "ab"));
    try testing.expect(matchExtglob("a*(X)b", "aXb"));
    try testing.expect(matchExtglob("a*(X)b", "aXXb"));
    try testing.expect(matchExtglob("a*(X)b", "aXXXb"));
    try testing.expect(!matchExtglob("a*(X)b", "aYb"));
}

test "fnmatch extglob - +(pattern) one or more" {
    try testing.expect(!matchExtglob("a+(X)b", "ab"));
    try testing.expect(matchExtglob("a+(X)b", "aXb"));
    try testing.expect(matchExtglob("a+(X)b", "aXXb"));
    try testing.expect(matchExtglob("a+(X)b", "aXXXb"));
}

test "fnmatch extglob - !(pattern) negation" {
    try testing.expect(matchExtglob("*.!(js)", "file.txt"));
    try testing.expect(matchExtglob("*.!(js)", "file.ts"));
    try testing.expect(!matchExtglob("*.!(js)", "file.js"));
}

test "fnmatch extglob - !(pattern) with multiple alternatives" {
    try testing.expect(!matchExtglob("*.!(js|ts)", "app.js"));
    try testing.expect(!matchExtglob("*.!(js|ts)", "app.ts"));
    try testing.expect(matchExtglob("*.!(js|ts)", "app.zig"));
    try testing.expect(matchExtglob("*.!(js|ts)", "app.html"));
}

test "fnmatch extglob - combined with regular wildcards" {
    try testing.expect(matchExtglob("test_@(foo|bar).*", "test_foo.c"));
    try testing.expect(matchExtglob("test_@(foo|bar).*", "test_bar.h"));
    try testing.expect(!matchExtglob("test_@(foo|bar).*", "test_baz.c"));
}

test "fnmatch extglob - single alternative" {
    try testing.expect(matchExtglob("@(foo).txt", "foo.txt"));
    try testing.expect(!matchExtglob("@(foo).txt", "bar.txt"));
}

test "fnmatch extglob - multiple extglobs in pattern" {
    try testing.expect(matchExtglob("@(src|lib)/*.@(c|h)", "src/main.c"));
    try testing.expect(matchExtglob("@(src|lib)/*.@(c|h)", "lib/util.h"));
    try testing.expect(!matchExtglob("@(src|lib)/*.@(c|h)", "test/test.c"));
}

test "fnmatch extglob - disabled by default" {
    // Without extglob flag, these should NOT match as extglob patterns
    // @(foo|bar) should be treated as literal characters
    try testing.expect(!fnmatchFull("@(foo|bar)", "foo"));
    try testing.expect(!fnmatchFull("+(X)", "X"));
}

test "fnmatch extglob - malformed extglob treated as literal" {
    // Missing closing paren - should fall back to literal matching
    try testing.expect(!matchExtglob("@(foo", "foo"));
}

test "fnmatch extglob - +(a|b) with mixed alternatives" {
    try testing.expect(matchExtglob("+(a|b)", "a"));
    try testing.expect(matchExtglob("+(a|b)", "b"));
    try testing.expect(matchExtglob("+(a|b)", "ab"));
    try testing.expect(matchExtglob("+(a|b)", "ba"));
    try testing.expect(matchExtglob("+(a|b)", "aaa"));
    try testing.expect(!matchExtglob("+(a|b)", ""));
    try testing.expect(!matchExtglob("+(a|b)", "c"));
}

test "fnmatch extglob - empty alternatives" {
    // @(|foo) means empty string or "foo"
    try testing.expect(matchExtglob("@(|foo)bar", "bar"));
    try testing.expect(matchExtglob("@(|foo)bar", "foobar"));
}

// ============================================================================
// POSIX bracket expression tests
// ============================================================================

test "fnmatch - POSIX character class [[:alpha:]]" {
    try testing.expect(fnmatchFull("[[:alpha:]]", "a"));
    try testing.expect(fnmatchFull("[[:alpha:]]", "Z"));
    try testing.expect(!fnmatchFull("[[:alpha:]]", "0"));
    try testing.expect(!fnmatchFull("[[:alpha:]]", " "));
}

test "fnmatch - POSIX character class [[:digit:]]" {
    try testing.expect(fnmatchFull("[[:digit:]]", "0"));
    try testing.expect(fnmatchFull("[[:digit:]]", "9"));
    try testing.expect(!fnmatchFull("[[:digit:]]", "a"));
}

test "fnmatch - POSIX character class [[:alnum:]]" {
    try testing.expect(fnmatchFull("[[:alnum:]]", "a"));
    try testing.expect(fnmatchFull("[[:alnum:]]", "5"));
    try testing.expect(!fnmatchFull("[[:alnum:]]", "-"));
}

test "fnmatch - POSIX [[:lower:]] and [[:upper:]]" {
    try testing.expect(fnmatchFull("[[:lower:]]", "a"));
    try testing.expect(!fnmatchFull("[[:lower:]]", "A"));
    try testing.expect(fnmatchFull("[[:upper:]]", "A"));
    try testing.expect(!fnmatchFull("[[:upper:]]", "a"));
}

test "fnmatch - POSIX [[:space:]]" {
    try testing.expect(fnmatchFull("[[:space:]]", " "));
    try testing.expect(fnmatchFull("[[:space:]]", "\t"));
    try testing.expect(fnmatchFull("[[:space:]]", "\n"));
    try testing.expect(!fnmatchFull("[[:space:]]", "a"));
}

test "fnmatch - POSIX [[:xdigit:]]" {
    try testing.expect(fnmatchFull("[[:xdigit:]]", "a"));
    try testing.expect(fnmatchFull("[[:xdigit:]]", "F"));
    try testing.expect(fnmatchFull("[[:xdigit:]]", "9"));
    try testing.expect(!fnmatchFull("[[:xdigit:]]", "g"));
}

test "fnmatch - POSIX negated character class" {
    try testing.expect(!fnmatchFull("[![:digit:]]", "5"));
    try testing.expect(fnmatchFull("[![:digit:]]", "a"));
}

test "fnmatch - POSIX class in pattern with prefix and suffix" {
    try testing.expect(fnmatchFull("file[[:digit:]].txt", "file0.txt"));
    try testing.expect(fnmatchFull("file[[:digit:]].txt", "file9.txt"));
    try testing.expect(!fnmatchFull("file[[:digit:]].txt", "filea.txt"));
}

// ============================================================================
// noescape flag tests
// ============================================================================

test "fnmatch - noescape flag treats backslash as literal" {
    const noescape = zlob.ZlobFlags{ .noescape = true };
    // With noescape, \* should match literal backslash followed by anything
    try testing.expect(!fnmatch.fnmatch("\\*", "*", noescape));
    try testing.expect(fnmatch.fnmatch("\\*", "\\anything", noescape));
}
