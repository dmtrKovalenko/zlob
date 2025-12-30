const std = @import("std");
const testing = std.testing;
const simdglob = @import("simdglob");

// Create alias for easier access
const matchPaths = simdglob.matchPaths;
const GLOB_NOSORT = simdglob.GLOB_NOSORT;
const GLOB_NOCHECK = simdglob.GLOB_NOCHECK;
const GLOB_PERIOD = simdglob.GLOB_PERIOD;

// Test basic ** patterns

test "matchPaths - ** matches zero directories" {
    const paths = [_][]const u8{
        "file.txt",
        "dir/file.txt",
        "dir/subdir/file.txt",
    };

    var result = try matchPaths(testing.allocator, "**/file.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

test "matchPaths - ** matches multiple directories" {
    const paths = [_][]const u8{
        "a/b/c/file.c",
        "a/b/file.c",
        "a/file.c",
        "file.c",
    };

    var result = try matchPaths(testing.allocator, "**/file.c", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.match_count);
}

test "matchPaths - prefix before **" {
    const paths = [_][]const u8{
        "/users/alice/code/main.c",
        "/users/alice/code/src/main.c",
        "/users/bob/code/main.c",
        "/other/alice/code/main.c",
    };

    var result = try matchPaths(testing.allocator, "/users/**/main.c", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

test "matchPaths - ** in middle of pattern" {
    const paths = [_][]const u8{
        "src/foo/bar/test.zig",
        "src/test.zig",
        "lib/test.zig",
        "src/baz/test.zig",
    };

    var result = try matchPaths(testing.allocator, "src/**/test.zig", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

test "matchPaths - multiple ** in pattern" {
    const paths = [_][]const u8{
        "a/b/c/d/e.txt",
        "a/c/e.txt",
        "a/b/d/e.txt",
        "a/b/c/e.txt",
    };

    var result = try matchPaths(testing.allocator, "a/**/c/**/e.txt", &paths, 0);
    defer result.deinit();

    // Should match paths that have 'a', then any depth, then 'c', then any depth, then 'e.txt'
    // Matches: a/b/c/d/e.txt (a→[b]→c→[d]→e.txt), a/c/e.txt (a→[]→c→[]→e.txt), a/b/c/e.txt (a→[b]→c→[]→e.txt)
    // Does not match: a/b/d/e.txt (no 'c' component)
    try testing.expectEqual(@as(usize, 3), result.match_count);
}

// Test wildcard combinations

test "matchPaths - ** with * wildcard" {
    const paths = [_][]const u8{
        "dir1/code/test.c",
        "dir2/code/main.c",
        "dir1/test/file.c",
        "dir3/code/test.c",
    };

    var result = try matchPaths(testing.allocator, "dir?/**/test.c", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - ** with character class" {
    const paths = [_][]const u8{
        "dir1/a/file.txt",
        "dir1/b/file.txt",
        "dir1/c/file.txt",
        "dir1/d/file.txt",
    };

    var result = try matchPaths(testing.allocator, "dir1/**/[ab]/file.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

// Test flags

test "matchPaths - GLOB_NOSORT flag" {
    const paths = [_][]const u8{
        "zebra.txt",
        "alpha.txt",
        "beta.txt",
    };

    var result = try matchPaths(testing.allocator, "*.txt", &paths, GLOB_NOSORT);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
    // Results should be in input order, not sorted
    try testing.expectEqualStrings("zebra.txt", result.paths[0]);
    try testing.expectEqualStrings("alpha.txt", result.paths[1]);
    try testing.expectEqualStrings("beta.txt", result.paths[2]);
}

test "matchPaths - GLOB_NOCHECK flag" {
    const paths = [_][]const u8{"foo.txt"};

    var result = try matchPaths(testing.allocator, "*.zig", &paths, GLOB_NOCHECK);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expectEqualStrings("*.zig", result.paths[0]);
}

test "matchPaths - GLOB_PERIOD allows hidden files" {
    const paths = [_][]const u8{
        ".hidden/file.txt",
        "visible/file.txt",
    };

    var result = try matchPaths(testing.allocator, "**/file.txt", &paths, GLOB_PERIOD);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - hidden files blocked without GLOB_PERIOD" {
    const paths = [_][]const u8{
        ".hidden/file.txt",
        "visible/file.txt",
    };

    var result = try matchPaths(testing.allocator, "**/file.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expectEqualStrings("visible/file.txt", result.paths[0]);
}

test "matchPaths - explicit dot in pattern matches hidden" {
    const paths = [_][]const u8{
        ".hidden/file.txt",
        "visible/file.txt",
    };

    var result = try matchPaths(testing.allocator, ".*/*", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expectEqualStrings(".hidden/file.txt", result.paths[0]);
}

// Test edge cases

test "matchPaths - empty input array" {
    const paths = [_][]const u8{};

    var result = try matchPaths(testing.allocator, "*.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.match_count);
}

test "matchPaths - empty input array with GLOB_NOCHECK" {
    const paths = [_][]const u8{};

    var result = try matchPaths(testing.allocator, "*.txt", &paths, GLOB_NOCHECK);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expectEqualStrings("*.txt", result.paths[0]);
}

test "matchPaths - no matches" {
    const paths = [_][]const u8{"foo.txt"};

    var result = try matchPaths(testing.allocator, "*.zig", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.match_count);
}

test "matchPaths - pattern is just **" {
    const paths = [_][]const u8{
        "a.txt",
        "b/c.txt",
        "d/e/f.txt",
    };

    var result = try matchPaths(testing.allocator, "**", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

test "matchPaths - absolute vs relative paths - absolute pattern" {
    const paths = [_][]const u8{
        "/absolute/path/file.txt",
        "relative/path/file.txt",
    };

    var result = try matchPaths(testing.allocator, "/**/file.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expectEqualStrings("/absolute/path/file.txt", result.paths[0]);
}

test "matchPaths - absolute vs relative paths - relative pattern" {
    const paths = [_][]const u8{
        "/absolute/path/file.txt",
        "relative/path/file.txt",
    };

    var result = try matchPaths(testing.allocator, "**/file.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - consecutive slashes in path" {
    const paths = [_][]const u8{
        "dir//file.txt",
        "dir/file.txt",
    };

    var result = try matchPaths(testing.allocator, "dir/file.txt", &paths, 0);
    defer result.deinit();

    // Both should match (after normalization)
    try testing.expectEqual(@as(usize, 2), result.match_count);
}

// Test real-world patterns

test "matchPaths - **/*.c finds all C files" {
    const paths = [_][]const u8{
        "src/main.c",
        "src/util/helper.c",
        "src/util/io/file.c",
        "include/header.h",
        "tests/test_main.c",
    };

    var result = try matchPaths(testing.allocator, "**/*.c", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.match_count);
}

test "matchPaths - test files in any test directory" {
    const paths = [_][]const u8{
        "test/unit/test_foo.zig",
        "test/integration/test_bar.zig",
        "src/test/test_helper.zig",
        "src/main.zig",
        "test/test_immediate.zig",
    };

    var result = try matchPaths(testing.allocator, "**/test/test_*.zig", &paths, 0);
    defer result.deinit();

    // Pattern **/test/test_*.zig means: any depth, then 'test' directory, then files matching 'test_*.zig'
    // Matches: src/test/test_helper.zig and test/test_immediate.zig
    // Does not match: test/unit/test_foo.zig (has 'unit' after 'test'), test/integration/test_bar.zig (has 'integration' after 'test')
    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - src directory recursive" {
    const paths = [_][]const u8{
        "src/main.zig",
        "src/util/helpers.zig",
        "src/core/engine.zig",
        "lib/external.zig",
        "test/main_test.zig",
    };

    var result = try matchPaths(testing.allocator, "src/**/*.zig", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

// Test sorting behavior

test "matchPaths - results are sorted by default" {
    const paths = [_][]const u8{
        "zebra.txt",
        "alpha.txt",
        "beta.txt",
        "gamma.txt",
    };

    var result = try matchPaths(testing.allocator, "*.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.match_count);
    try testing.expectEqualStrings("alpha.txt", result.paths[0]);
    try testing.expectEqualStrings("beta.txt", result.paths[1]);
    try testing.expectEqualStrings("gamma.txt", result.paths[2]);
    try testing.expectEqualStrings("zebra.txt", result.paths[3]);
}

// Test pattern without wildcards

test "matchPaths - literal pattern without wildcards" {
    const paths = [_][]const u8{
        "exact/match/file.txt",
        "other/path/file.txt",
    };

    var result = try matchPaths(testing.allocator, "exact/match/file.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.match_count);
    try testing.expectEqualStrings("exact/match/file.txt", result.paths[0]);
}

// Test complex patterns

test "matchPaths - complex pattern with multiple wildcards" {
    const paths = [_][]const u8{
        "src/foo/test_bar.zig",
        "src/baz/test_qux.zig",
        "src/foo/main.zig",
        "lib/test_util.zig",
    };

    var result = try matchPaths(testing.allocator, "src/*/test_*.zig", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - ** at the beginning" {
    const paths = [_][]const u8{
        "code/main.c",
        "src/code/main.c",
        "app/src/code/main.c",
    };

    var result = try matchPaths(testing.allocator, "**/code/main.c", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

test "matchPaths - ** at the end" {
    const paths = [_][]const u8{
        "src/file.txt",
        "src/sub/file.txt",
        "src/sub/deep/file.txt",
        "other/file.txt",
    };

    var result = try matchPaths(testing.allocator, "src/**", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}

// Test user's original examples

test "matchPaths - user example 1: **/code/*.c" {
    const paths = [_][]const u8{
        "/users/alice/code/main.c",
        "/users/bob/docs/readme.txt",
        "/users/alice/code/utils.c",
    };

    var result = try matchPaths(testing.allocator, "**/code/*.c", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - user example 2: /users/**/code/*.c" {
    const paths = [_][]const u8{
        "/users/alice/code/main.c",
        "/users/alice/subdir/code/utils.c",
        "/other/alice/code/main.c",
    };

    var result = try matchPaths(testing.allocator, "/users/**/code/*.c", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.match_count);
}

test "matchPaths - user example 3: **/*.txt" {
    const paths = [_][]const u8{
        "foo/bar/baz.txt",
        "a.txt",
        "x/y.txt",
    };

    var result = try matchPaths(testing.allocator, "**/*.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.match_count);
}
