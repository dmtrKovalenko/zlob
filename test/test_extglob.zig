//! Extended glob (extglob) pattern tests
//!
//! Tests bash-style extended globbing patterns: ?(), *(), +(), @(), !()
//! Each test validates both in-memory matchPaths and filesystem-based match.

const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");
const test_utils = @import("test_utils");
const zlobIsomorphicTest = test_utils.zlobIsomorphicTest;
const testMatchPathsOnly = test_utils.testMatchPathsOnly;
const TestResult = test_utils.TestResult;

// ============================================================================
// @(pattern) - Matches exactly one of the alternatives
// ============================================================================

test "@(pattern) matches exactly one alternative" {
    const files = [_][]const u8{ "foo.js", "bar.js", "baz.js", "qux.js" };

    try zlobIsomorphicTest(&files, "@(foo|bar).js", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(2, result.count);
            try testing.expect(result.hasPath("foo.js"));
            try testing.expect(result.hasPath("bar.js"));
            try testing.expect(!result.hasPath("baz.js"));
            try testing.expect(!result.hasPath("qux.js"));
        }
    }.assert, @src());
}

test "@(a|b|c) multiple alternatives" {
    const files = [_][]const u8{ "test.c", "test.h", "test.cpp", "test.txt" };

    try zlobIsomorphicTest(&files, "test.@(c|h|cpp)", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(result.hasPath("test.c"));
            try testing.expect(result.hasPath("test.h"));
            try testing.expect(result.hasPath("test.cpp"));
            try testing.expect(!result.hasPath("test.txt"));
        }
    }.assert, @src());
}

test "*.@(js|ts) extension matching" {
    const files = [_][]const u8{ "app.js", "app.ts", "app.zig", "index.js", "index.json", "style.zig" };

    try zlobIsomorphicTest(&files, "*.@(js|ts)", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(result.hasPath("app.js"));
            try testing.expect(result.hasPath("app.ts"));
            try testing.expect(result.hasPath("index.js"));
        }
    }.assert, @src());
}

test "@(foo) single alternative" {
    const files = [_][]const u8{ "foo.txt", "bar.txt" };

    try zlobIsomorphicTest(&files, "@(foo).txt", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(1, result.count);
            try testing.expect(result.hasPath("foo.txt"));
        }
    }.assert, @src());
}

// ============================================================================
// ?(pattern) - Matches zero or one occurrence
// ============================================================================

test "?(pattern) matches zero occurrences" {
    const files = [_][]const u8{ "test.txt", "test_suffix.txt" };

    try zlobIsomorphicTest(&files, "test?(_suffix).txt", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(2, result.count);
            try testing.expect(result.hasPath("test.txt"));
            try testing.expect(result.hasPath("test_suffix.txt"));
        }
    }.assert, @src());
}

test "?(pattern) matches one occurrence" {
    const files = [_][]const u8{ "file.txt", "file.backup.txt" };

    try zlobIsomorphicTest(&files, "file?(.backup).txt", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(2, result.count);
        }
    }.assert, @src());
}

test "?(a|b) with multiple alternatives" {
    const files = [_][]const u8{ "main.c", "main_debug.c", "main_release.c", "main_test.c" };

    try zlobIsomorphicTest(&files, "main?(_debug|_release).c", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(result.hasPath("main.c"));
            try testing.expect(result.hasPath("main_debug.c"));
            try testing.expect(result.hasPath("main_release.c"));
            try testing.expect(!result.hasPath("main_test.c"));
        }
    }.assert, @src());
}

// ============================================================================
// *(pattern) - Matches zero or more occurrences
// ============================================================================

test "*(pattern) matches zero occurrences" {
    const files = [_][]const u8{ "ab", "aXb", "aXXb" };

    try zlobIsomorphicTest(&files, "a*(X)b", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
        }
    }.assert, @src());
}

test "*(pattern) matches multiple occurrences" {
    const files = [_][]const u8{ "test", "testABC", "testABCABC", "testABCABCABC" };

    try zlobIsomorphicTest(&files, "test*(ABC)", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(4, result.count);
        }
    }.assert, @src());
}

// ============================================================================
// +(pattern) - Matches one or more occurrences
// ============================================================================

test "+(pattern) requires at least one match" {
    const files = [_][]const u8{ "ab", "aXb", "aXXb", "aXXXb" };

    try zlobIsomorphicTest(&files, "a+(X)b", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            // Should NOT match "ab" (zero X's), but should match the others
            try testing.expectEqual(3, result.count);
            try testing.expect(!result.hasPath("ab"));
            try testing.expect(result.hasPath("aXb"));
            try testing.expect(result.hasPath("aXXb"));
            try testing.expect(result.hasPath("aXXXb"));
        }
    }.assert, @src());
}

test "+(a|b) with alternatives" {
    const files = [_][]const u8{ "X", "Xa", "Xb", "Xab", "Xba", "Xaaa" };

    try zlobIsomorphicTest(&files, "X+(a|b)", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            // Should NOT match "X" (zero occurrences)
            try testing.expectEqual(5, result.count);
            try testing.expect(!result.hasPath("X"));
        }
    }.assert, @src());
}

// ============================================================================
// !(pattern) - Matches anything except the pattern
// ============================================================================

test "*.!(js) matches non-js files" {
    const files = [_][]const u8{ "app.js", "app.json", "app.ts", "app.zig", "app.html" };

    try zlobIsomorphicTest(&files, "*.!(js)", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(4, result.count);
            try testing.expect(result.noPathEndsWith(".js"));
            try testing.expect(result.hasPathEndingWith(".json"));
            try testing.expect(result.hasPathEndingWith(".ts"));
            try testing.expect(result.hasPathEndingWith(".zig"));
            try testing.expect(result.hasPathEndingWith(".html"));
        }
    }.assert, @src());
}

test "*.!(js|ts) matches non-js-ts files" {
    const files = [_][]const u8{ "app.js", "app.ts", "app.zig", "app.html", "app.json" };

    try zlobIsomorphicTest(&files, "*.!(js|ts)", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(result.noPathEndsWith(".js"));
            try testing.expect(result.noPathEndsWith(".ts"));
        }
    }.assert, @src());
}

test "prefix.!(ext) with prefix" {
    const files = [_][]const u8{ "config.json", "config.yaml", "config.yml", "config.toml" };

    try zlobIsomorphicTest(&files, "config.!(json)", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(result.noPathEndsWith(".json"));
        }
    }.assert, @src());
}

test "negation with wildcards *.!(j*)" {
    const files = [_][]const u8{ "app.js", "app.json", "app.jsx", "app.zig", "app.txt" };

    try zlobIsomorphicTest(&files, "*.!(j*)", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(2, result.count);
            // Should not include files with extension starting with 'j'
            for (result.paths) |path| {
                const ext_start = std.mem.lastIndexOfScalar(u8, path, '.') orelse continue;
                const ext = path[ext_start + 1 ..];
                try testing.expect(ext.len == 0 or ext[0] != 'j');
            }
        }
    }.assert, @src());
}

// ============================================================================
// Recursive patterns with **
// ============================================================================

test "**/*.!(js) recursive negation" {
    const files = [_][]const u8{
        "src/app.js",
        "src/app.ts",
        "src/lib/util.js",
        "src/lib/util.zig",
        "test/test.js",
        "test/test.txt",
    };

    try zlobIsomorphicTest(&files, "**/*.!(js)", zlob.ZLOB_EXTGLOB | zlob.ZLOB_DOUBLESTAR_RECURSIVE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(result.noPathEndsWith(".js"));
        }
    }.assert, @src());
}

test "**/@(foo|bar)/*.txt recursive with extglob directory" {
    const files = [_][]const u8{
        "src/foo/test.txt",
        "src/bar/test.txt",
        "src/baz/test.txt",
        "lib/foo/data.txt",
    };

    try zlobIsomorphicTest(&files, "**/@(foo|bar)/*.txt", zlob.ZLOB_EXTGLOB | zlob.ZLOB_DOUBLESTAR_RECURSIVE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(!result.hasPathEndingWith("baz/test.txt"));
        }
    }.assert, @src());
}

// ============================================================================
// Combined patterns
// ============================================================================

test "@() combined with regular wildcards" {
    const files = [_][]const u8{ "test_foo.c", "test_bar.c", "test_baz.h", "other_foo.c" };

    try zlobIsomorphicTest(&files, "test_@(foo|bar).*", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(2, result.count);
            try testing.expect(result.hasPath("test_foo.c"));
            try testing.expect(result.hasPath("test_bar.c"));
        }
    }.assert, @src());
}

test "complex pattern with multiple extglobs" {
    const files = [_][]const u8{ "src/main.c", "lib/util.c", "src/main.h", "test/test.c" };

    try zlobIsomorphicTest(&files, "@(src|lib)/*.@(c|h)", zlob.ZLOB_EXTGLOB, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(3, result.count);
            try testing.expect(!result.hasPathEndingWith("test/test.c"));
        }
    }.assert, @src());
}

test "extglob combined with brace expansion" {
    const files = [_][]const u8{ "src/main.c", "src/main.h", "lib/util.c", "lib/util.h" };

    try zlobIsomorphicTest(&files, "{src,lib}/*.!(h)", zlob.ZLOB_EXTGLOB | zlob.ZLOB_BRACE, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(2, result.count);
            // Should only include .c files
            for (result.paths) |path| {
                try testing.expect(std.mem.endsWith(u8, path, ".c"));
            }
        }
    }.assert, @src());
}

// ============================================================================
// Backward compatibility - without ZLOB_EXTGLOB flag
// These use testMatchPathsOnly because literal filenames with special chars
// like '@(foo|bar).js' can't be created on all filesystems
// ============================================================================

test "without ZLOB_EXTGLOB - @( is treated as literal" {
    const files = [_][]const u8{ "foo.js", "bar.js", "@(foo|bar).js" };

    try testMatchPathsOnly(&files, "@(foo|bar).js", 0, struct {
        fn assert(result: TestResult) !void {
            // Should only match the literal filename
            try testing.expectEqual(1, result.count);
            try testing.expect(result.hasPath("@(foo|bar).js"));
        }
    }.assert);
}

test "without ZLOB_EXTGLOB - +( is treated as literal" {
    const files = [_][]const u8{ "aXb", "a+(X)b" };

    try testMatchPathsOnly(&files, "a+(X)b", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(1, result.count);
            try testing.expect(result.hasPath("a+(X)b"));
        }
    }.assert);
}

test "without ZLOB_EXTGLOB - !( is treated as literal" {
    const files = [_][]const u8{ "test.js", "test.!(js)" };

    try testMatchPathsOnly(&files, "test.!(js)", 0, struct {
        fn assert(result: TestResult) !void {
            try testing.expectEqual(1, result.count);
            try testing.expect(result.hasPath("test.!(js)"));
        }
    }.assert);
}
