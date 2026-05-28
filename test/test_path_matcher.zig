const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");
const zlob_flags = @import("zlob_flags");

// Create alias for easier access
const matchPaths = zlob.matchPaths;
const matchPathsAt = zlob.matchPathsAt;
const ZLOB_NOSORT = zlob_flags.ZLOB_NOSORT;
const ZLOB_NOCHECK = zlob_flags.ZLOB_NOCHECK;
const ZLOB_PERIOD = zlob_flags.ZLOB_PERIOD;
const ZLOB_DOUBLESTAR_RECURSIVE = zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE;

// Test basic ** patterns

test "matchPaths - ** matches zero directories" {
    const paths = [_][]const u8{
        "file.txt",
        "dir/file.txt",
        "dir/subdir/file.txt",
    };

    var result = try matchPaths(testing.allocator, "**/file.txt", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
}

// Tests for matchPathsAt

test "matchPathsAt - basic base_path strips directory prefix" {
    const paths = [_][]const u8{
        "/home/user/project/src/main.c",
        "/home/user/project/src/test/unit.c",
        "/home/user/project/lib/utils.c",
        "/home/user/project/docs/readme.md",
    };

    var result = try matchPathsAt(testing.allocator, "/home/user/project/", "**/*.c", &paths, ZLOB_PERIOD | ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
}

test "matchPathsAt - base_path without trailing slash" {
    const paths = [_][]const u8{
        "/home/user/project/src/main.c",
        "/home/user/project/src/test/unit.c",
        "/home/user/project/lib/utils.c",
        "/home/user/project/docs/readme.md",
    };

    var result = try matchPathsAt(testing.allocator, "/home/user/project", "**/*.c", &paths, ZLOB_PERIOD | ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
}

test "matchPathsAt - results contain original full paths" {
    const paths = [_][]const u8{
        "/home/user/project/src/main.c",
        "/home/user/project/lib/utils.c",
    };

    var result = try matchPathsAt(testing.allocator, "/home/user/project/", "src/*.c", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(1, result.len());
    try testing.expectEqualStrings("/home/user/project/src/main.c", result.get(0));
}

test "matchPathsAt - empty base_path behaves like matchPaths" {
    const paths = [_][]const u8{
        "src/main.c",
        "src/test/unit.c",
        "lib/utils.c",
        "docs/readme.md",
    };

    var result_at = try matchPathsAt(testing.allocator, "", "**/*.c", &paths, ZLOB_PERIOD | ZLOB_DOUBLESTAR_RECURSIVE);
    defer result_at.deinit();

    var result = try matchPaths(testing.allocator, "**/*.c", &paths, ZLOB_PERIOD | ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(result.len(), result_at.len());
}

test "matchPathsAt - literal pattern with base_path" {
    const paths = [_][]const u8{
        "/srv/data/config.json",
        "/srv/data/readme.md",
    };

    var result = try matchPathsAt(testing.allocator, "/srv/data", "config.json", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(1, result.len());
    try testing.expectEqualStrings("/srv/data/config.json", result.get(0));
}

test "matchPathsAt - doublestar with base_path" {
    const paths = [_][]const u8{
        "/opt/app/src/main.zig",
        "/opt/app/src/utils/helpers.zig",
        "/opt/app/test/test_main.zig",
        "/opt/app/README.md",
    };

    var result = try matchPathsAt(testing.allocator, "/opt/app/", "src/**/*.zig", &paths, ZLOB_PERIOD | ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(2, result.len());
}

test "matchPathsAt - paths shorter than base are skipped" {
    const paths = [_][]const u8{
        "/short",
        "/very/long/base/path/file.txt",
    };

    var result = try matchPathsAt(testing.allocator, "/very/long/base/path", "*.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(1, result.len());
    try testing.expectEqualStrings("/very/long/base/path/file.txt", result.get(0));
}

test "matchPathsAt - ./ prefix means relative to base_path" {
    const paths = [_][]const u8{
        "/home/user/project/src/main.c",
        "/home/user/project/lib/utils.c",
    };

    var result = try matchPathsAt(testing.allocator, "/home/user/project", "./**/*.c", &paths, ZLOB_PERIOD | ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(2, result.len());
}

test "matchPathsAt - no matches returns zero" {
    const paths = [_][]const u8{
        "/home/user/project/src/main.c",
        "/home/user/project/lib/utils.c",
    };

    var result = try matchPathsAt(testing.allocator, "/home/user/project/", "**/*.zig", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(0, result.len());
}

test "matchPaths - prefix before **" {
    const paths = [_][]const u8{
        "/users/alice/code/main.c",
        "/users/alice/code/src/main.c",
        "/users/bob/code/main.c",
        "/other/alice/code/main.c",
    };

    var result = try matchPaths(testing.allocator, "/users/**/main.c", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
}

test "matchPaths - ** in middle of pattern" {
    const paths = [_][]const u8{
        "src/foo/bar/test.zig",
        "src/test.zig",
        "lib/test.zig",
        "src/baz/test.zig",
    };

    var result = try matchPaths(testing.allocator, "src/**/test.zig", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
}

test "matchPaths - multiple ** in pattern" {
    const paths = [_][]const u8{
        "a/b/c/d/e.txt",
        "a/c/e.txt",
        "a/b/d/e.txt",
        "a/b/c/e.txt",
    };

    var result = try matchPaths(testing.allocator, "a/**/c/**/e.txt", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    // Should match paths that have 'a', then any depth, then 'c', then any depth, then 'e.txt'
    // Matches: a/b/c/d/e.txt (a→[b]→c→[d]→e.txt), a/c/e.txt (a→[]→c→[]→e.txt), a/b/c/e.txt (a→[b]→c→[]→e.txt)
    // Does not match: a/b/d/e.txt (no 'c' component)
    try testing.expectEqual(3, result.len());
}

// Test wildcard combinations

test "matchPaths - ** with * wildcard" {
    const paths = [_][]const u8{
        "dir1/code/test.c",
        "dir2/code/main.c",
        "dir1/test/file.c",
        "dir3/code/test.c",
    };

    var result = try matchPaths(testing.allocator, "dir?/**/test.c", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(2, result.len());
}

test "matchPaths - ** with character class" {
    const paths = [_][]const u8{
        "dir1/a/file.txt",
        "dir1/b/file.txt",
        "dir1/c/file.txt",
        "dir1/d/file.txt",
    };

    var result = try matchPaths(testing.allocator, "dir1/**/[ab]/file.txt", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(2, result.len());
}

// Test flags

test "matchPaths - ZLOB_NOSORT flag" {
    const paths = [_][]const u8{
        "zebra.txt",
        "alpha.txt",
        "beta.txt",
    };

    var result = try matchPaths(testing.allocator, "*.txt", &paths, ZLOB_NOSORT);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
    // Results should be in input order, not sorted
    try testing.expectEqualStrings("zebra.txt", result.get(0));
    try testing.expectEqualStrings("alpha.txt", result.get(1));
    try testing.expectEqualStrings("beta.txt", result.get(2));
}

test "matchPaths - ZLOB_NOCHECK flag" {
    const paths = [_][]const u8{"foo.txt"};

    var result = try matchPaths(testing.allocator, "*.zig", &paths, ZLOB_NOCHECK);
    defer result.deinit();

    try testing.expectEqual(1, result.len());
    try testing.expectEqualStrings("*.zig", result.get(0));
}

test "matchPaths - ZLOB_PERIOD allows hidden files" {
    const paths = [_][]const u8{
        ".hidden/file.txt",
        "visible/file.txt",
    };

    var result = try matchPaths(testing.allocator, "**/file.txt", &paths, ZLOB_PERIOD | ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(2, result.len());
}

test "matchPaths - hidden files blocked without ZLOB_PERIOD" {
    const paths = [_][]const u8{
        ".hidden/file.txt",
        "visible/file.txt",
    };

    var result = try matchPaths(testing.allocator, "**/file.txt", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(1, result.len());
    try testing.expectEqualStrings("visible/file.txt", result.get(0));
}

test "matchPaths - explicit dot in pattern matches hidden" {
    const paths = [_][]const u8{
        ".hidden/file.txt",
        "visible/file.txt",
    };

    var result = try matchPaths(testing.allocator, ".*/*", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(1, result.len());
    try testing.expectEqualStrings(".hidden/file.txt", result.get(0));
}

// Test edge cases

test "matchPaths - empty input array" {
    const paths = [_][]const u8{};

    var result = try matchPaths(testing.allocator, "*.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(0, result.len());
}

test "matchPaths - empty input array with ZLOB_NOCHECK" {
    const paths = [_][]const u8{};

    var result = try matchPaths(testing.allocator, "*.txt", &paths, ZLOB_NOCHECK);
    defer result.deinit();

    try testing.expectEqual(1, result.len());
    try testing.expectEqualStrings("*.txt", result.get(0));
}

test "matchPaths - no matches" {
    const paths = [_][]const u8{"foo.txt"};

    var result = try matchPaths(testing.allocator, "*.zig", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(0, result.len());
}

test "matchPaths - pattern is just **" {
    const paths = [_][]const u8{
        "a.txt",
        "b/c.txt",
        "d/e/f.txt",
    };

    var result = try matchPaths(testing.allocator, "**", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
}

test "matchPaths - absolute vs relative paths - absolute pattern" {
    const paths = [_][]const u8{
        "/absolute/path/file.txt",
        "relative/path/file.txt",
    };

    var result = try matchPaths(testing.allocator, "/**/file.txt", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(1, result.len());
    try testing.expectEqualStrings("/absolute/path/file.txt", result.get(0));
}

test "matchPaths - absolute vs relative paths - relative pattern" {
    const paths = [_][]const u8{
        "/absolute/path/file.txt",
        "relative/path/file.txt",
    };

    var result = try matchPaths(testing.allocator, "**/file.txt", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(2, result.len());
}

test "matchPaths - consecutive slashes in path" {
    const paths = [_][]const u8{
        "dir//file.txt",
        "dir/file.txt",
    };

    var result = try matchPaths(testing.allocator, "dir/file.txt", &paths, 0);
    defer result.deinit();

    // Only normalized paths match (paths must be pre-normalized)
    try testing.expectEqual(1, result.len());
    try testing.expectEqualStrings("dir/file.txt", result.get(0));
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

    var result = try matchPaths(testing.allocator, "**/*.c", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(4, result.len());
}

test "matchPaths - test files in any test directory" {
    const paths = [_][]const u8{
        "test/unit/test_foo.zig",
        "test/integration/test_bar.zig",
        "src/test/test_helper.zig",
        "src/main.zig",
        "test/test_immediate.zig",
    };

    var result = try matchPaths(testing.allocator, "**/test/test_*.zig", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    // Pattern **/test/test_*.zig means: any depth, then 'test' directory, then files matching 'test_*.zig'
    // Matches: src/test/test_helper.zig and test/test_immediate.zig
    // Does not match: test/unit/test_foo.zig (has 'unit' after 'test'), test/integration/test_bar.zig (has 'integration' after 'test')
    try testing.expectEqual(2, result.len());
}

test "matchPaths - src directory recursive" {
    const paths = [_][]const u8{
        "src/main.zig",
        "src/util/helpers.zig",
        "src/core/engine.zig",
        "lib/external.zig",
        "test/main_test.zig",
    };

    var result = try matchPaths(testing.allocator, "src/**/*.zig", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
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

    try testing.expectEqual(4, result.len());
    try testing.expectEqualStrings("alpha.txt", result.get(0));
    try testing.expectEqualStrings("beta.txt", result.get(1));
    try testing.expectEqualStrings("gamma.txt", result.get(2));
    try testing.expectEqualStrings("zebra.txt", result.get(3));
}

// Test pattern without wildcards

test "matchPaths - literal pattern without wildcards" {
    const paths = [_][]const u8{
        "exact/match/file.txt",
        "other/path/file.txt",
    };

    var result = try matchPaths(testing.allocator, "exact/match/file.txt", &paths, 0);
    defer result.deinit();

    try testing.expectEqual(1, result.len());
    try testing.expectEqualStrings("exact/match/file.txt", result.get(0));
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

    try testing.expectEqual(2, result.len());
}

test "matchPaths - ** at the beginning" {
    const paths = [_][]const u8{
        "code/main.c",
        "src/code/main.c",
        "app/src/code/main.c",
    };

    var result = try matchPaths(testing.allocator, "**/code/main.c", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
}

test "matchPaths - ** at the end" {
    const paths = [_][]const u8{
        "src/file.txt",
        "src/sub/file.txt",
        "src/sub/deep/file.txt",
        "other/file.txt",
    };

    var result = try matchPaths(testing.allocator, "src/**", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
}

// Test user's original examples

test "matchPaths - user example 1: **/code/*.c" {
    const paths = [_][]const u8{
        "/users/alice/code/main.c",
        "/users/bob/docs/readme.txt",
        "/users/alice/code/utils.c",
    };

    var result = try matchPaths(testing.allocator, "**/code/*.c", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(2, result.len());
}

test "matchPaths - user example 2: /users/**/code/*.c" {
    const paths = [_][]const u8{
        "/users/alice/code/main.c",
        "/users/alice/subdir/code/utils.c",
        "/other/alice/code/main.c",
    };

    var result = try matchPaths(testing.allocator, "/users/**/code/*.c", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(2, result.len());
}

test "matchPaths - user example 3: **/*.txt" {
    const paths = [_][]const u8{
        "foo/bar/baz.txt",
        "a.txt",
        "x/y.txt",
    };

    var result = try matchPaths(testing.allocator, "**/*.txt", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
}

// ============================================================================
// ZLOB_PERIOD with matchPaths - Test recursive patterns
// ============================================================================

test "matchPaths - ZLOB_PERIOD should NOT match hidden files by default" {
    const paths = [_][]const u8{
        "dir1/file1.txt",
        "dir1/.hidden.txt",
        ".hidden_dir/file2.txt",
        "dir2/subdir/file3.txt",
        "dir2/subdir/.dotfile",
    };

    var result = try matchPaths(testing.allocator, "**/*.txt", &paths, ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    // Should match dir1/file1.txt and dir2/subdir/file3.txt
    // Should NOT match dir1/.hidden.txt or .hidden_dir/file2.txt
    var has_hidden = false;
    var it = result.iterator();
    while (it.next()) |path| {
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
            path[idx + 1 ..]
        else
            path;

        if (basename.len > 0 and basename[0] == '.') {
            has_hidden = true;
        }

        if (std.mem.indexOf(u8, path, "/.") != null) {
            has_hidden = true;
        }
    }

    try testing.expect(!has_hidden);
    try testing.expectEqual(2, result.len()); // 2 non-hidden .txt files
}

test "matchPaths - ZLOB_PERIOD matches hidden files with flag" {
    const paths = [_][]const u8{
        "dir1/file1.txt",
        "dir1/.hidden.txt",
        ".hidden_dir/file2.txt",
        "dir2/subdir/file3.txt",
        "dir2/subdir/.dotfile",
    };

    var result = try matchPaths(testing.allocator, "**/*.txt", &paths, ZLOB_PERIOD | ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    // Should match all .txt files including hidden ones
    var hidden_count: usize = 0;
    var it2 = result.iterator();
    while (it2.next()) |path| {
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
            path[idx + 1 ..]
        else
            path;

        if (basename.len > 0 and basename[0] == '.') {
            hidden_count += 1;
        }

        // Files inside .hidden_dir
        if (std.mem.indexOf(u8, path, ".hidden_dir") != null) {
            hidden_count += 1;
        }
    }

    try testing.expect(hidden_count >= 1); // Should match hidden .txt files
    try testing.expectEqual(4, result.len()); // All 4 .txt files including hidden
}

test "matchPaths - allows ./ prefix for the pattern" {
    const paths = [_][]const u8{
        "src/main.c",
        "src/test/unit.c",
        "lib/utils.c",
        "docs/readme.md",
    };

    var result_abs = try matchPaths(testing.allocator, "**/*.c", &paths, ZLOB_PERIOD | ZLOB_DOUBLESTAR_RECURSIVE);
    defer result_abs.deinit();

    try testing.expectEqual(3, result_abs.len());

    var result = try matchPaths(testing.allocator, "./**/*.c", &paths, ZLOB_PERIOD | ZLOB_DOUBLESTAR_RECURSIVE);
    defer result.deinit();

    try testing.expectEqual(3, result.len());
}

// ===========================================================================
// CompiledPattern + indices API tests
// ===========================================================================

const compilePattern = zlob.compilePattern;
const matchPathIndices = zlob.matchPathIndices;
const matchPathIndicesAt = zlob.matchPathIndicesAt;
const matchPathsCompiled = zlob.matchPathsCompiled;
const matchPathIndicesCompiled = zlob.matchPathIndicesCompiled;
const matchPathIndicesAtCompiled = zlob.matchPathIndicesAtCompiled;

test "CompiledPattern - literal pattern" {
    var p = try compilePattern(testing.allocator, "src/main.zig", .{});
    defer p.deinit();

    try testing.expect(p.matches("src/main.zig", .{}));
    try testing.expect(!p.matches("src/test.zig", .{}));
    try testing.expect(!p.matches("src/main.zig.bak", .{}));
}

test "CompiledPattern - single suffix fast (1-4 byte ext)" {
    var p = try compilePattern(testing.allocator, "*.zig", .{});
    defer p.deinit();

    try testing.expect(p.matches("foo.zig", .{}));
    try testing.expect(p.matches("any/path/here/foo.zig", .{}));
    try testing.expect(!p.matches("foo.txt", .{}));
}

test "CompiledPattern - single suffix generic (5+ byte ext)" {
    var p = try compilePattern(testing.allocator, "*.markdown", .{});
    defer p.deinit();

    try testing.expect(p.matches("README.markdown", .{}));
    try testing.expect(!p.matches("README.md", .{}));
}

test "CompiledPattern - general pattern" {
    var p = try compilePattern(testing.allocator, "src/**/*.c", .{ .doublestar_recursive = true });
    defer p.deinit();

    const flags = zlob.ZlobFlags{ .doublestar_recursive = true };
    try testing.expect(p.matches("src/foo.c", flags));
    try testing.expect(p.matches("src/sub/dir/bar.c", flags));
    try testing.expect(!p.matches("src/foo.h", flags));
    try testing.expect(!p.matches("test/foo.c", flags));
}

test "CompiledPattern - brace multi_suffix" {
    var p = try compilePattern(testing.allocator, "*.{c,h}", .{ .brace = true });
    defer p.deinit();

    const flags = zlob.ZlobFlags{ .brace = true };
    try testing.expect(p.matches("foo.c", flags));
    try testing.expect(p.matches("any/foo.h", flags));
    try testing.expect(!p.matches("foo.txt", flags));
}

test "CompiledPattern - brace recursive_multi_suffix" {
    var p = try compilePattern(testing.allocator, "**/*.{rs,toml}", .{ .brace = true, .doublestar_recursive = true });
    defer p.deinit();

    const flags = zlob.ZlobFlags{ .brace = true, .doublestar_recursive = true };
    try testing.expect(p.matches("Cargo.toml", flags));
    try testing.expect(p.matches("src/lib.rs", flags));
    try testing.expect(p.matches("a/b/c/file.rs", flags));
    try testing.expect(!p.matches("file.md", flags));
}

test "CompiledPattern - brace_general" {
    var p = try compilePattern(testing.allocator, "{src,lib}/*.zig", .{ .brace = true });
    defer p.deinit();

    const flags = zlob.ZlobFlags{ .brace = true };
    try testing.expect(p.matches("src/foo.zig", flags));
    try testing.expect(p.matches("lib/bar.zig", flags));
    try testing.expect(!p.matches("test/baz.zig", flags));
}

test "CompiledPattern - reuse across many paths" {
    var p = try compilePattern(testing.allocator, "*.rs", .{});
    defer p.deinit();

    const paths = [_][]const u8{ "a.rs", "b.txt", "c.rs", "d.md", "e.rs" };
    var hits: usize = 0;
    for (paths) |path| {
        if (p.matches(path, .{})) hits += 1;
    }
    try testing.expectEqual(@as(usize, 3), hits);
}

test "matchPathIndices - basic" {
    const paths = [_][]const u8{ "foo.rs", "bar.txt", "baz.rs", "qux.md" };
    const indices = try matchPathIndices(testing.allocator, "*.rs", &paths, .{});
    defer testing.allocator.free(indices);

    try testing.expectEqual(@as(usize, 2), indices.len);
    try testing.expectEqual(@as(usize, 0), indices[0]);
    try testing.expectEqual(@as(usize, 2), indices[1]);
}

test "matchPathIndices - input order preserved (NOSORT ignored)" {
    // Purposely unsorted input — output should preserve input order
    // regardless of NOSORT being set or unset.
    const paths = [_][]const u8{ "z.rs", "a.rs", "m.rs" };
    const indices = try matchPathIndices(testing.allocator, "*.rs", &paths, .{});
    defer testing.allocator.free(indices);

    try testing.expectEqual(@as(usize, 3), indices.len);
    try testing.expectEqual(@as(usize, 0), indices[0]);
    try testing.expectEqual(@as(usize, 1), indices[1]);
    try testing.expectEqual(@as(usize, 2), indices[2]);
}

test "matchPathIndices - no match returns empty" {
    const paths = [_][]const u8{ "foo.rs", "bar.txt" };
    const indices = try matchPathIndices(testing.allocator, "*.zig", &paths, .{});
    defer testing.allocator.free(indices);

    try testing.expectEqual(@as(usize, 0), indices.len);
}

test "matchPathIndices - empty input returns empty" {
    const paths = [_][]const u8{};
    const indices = try matchPathIndices(testing.allocator, "*.rs", &paths, .{});
    defer testing.allocator.free(indices);

    try testing.expectEqual(@as(usize, 0), indices.len);
}

test "matchPathIndices - brace expansion" {
    const paths = [_][]const u8{ "a.c", "b.h", "c.txt", "d.h" };
    const indices = try matchPathIndices(testing.allocator, "*.{c,h}", &paths, zlob_flags.ZLOB_BRACE);
    defer testing.allocator.free(indices);

    try testing.expectEqual(@as(usize, 3), indices.len);
    try testing.expectEqual(@as(usize, 0), indices[0]);
    try testing.expectEqual(@as(usize, 1), indices[1]);
    try testing.expectEqual(@as(usize, 3), indices[2]);
}

test "matchPathIndices - recursive doublestar" {
    const paths = [_][]const u8{
        "src/main.rs",
        "src/lib/util.rs",
        "tests/test.rs",
        "Cargo.toml",
    };
    const indices = try matchPathIndices(
        testing.allocator,
        "src/**/*.rs",
        &paths,
        zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE,
    );
    defer testing.allocator.free(indices);

    try testing.expectEqual(@as(usize, 2), indices.len);
    try testing.expectEqual(@as(usize, 0), indices[0]);
    try testing.expectEqual(@as(usize, 1), indices[1]);
}

test "matchPathIndicesAt - base path" {
    const paths = [_][]const u8{
        "/home/me/proj/src/main.rs",
        "/home/me/proj/lib/util.rs",
        "/home/me/proj/README.md",
    };
    const indices = try matchPathIndicesAt(
        testing.allocator,
        "/home/me/proj",
        "src/*.rs",
        &paths,
        .{},
    );
    defer testing.allocator.free(indices);

    try testing.expectEqual(@as(usize, 1), indices.len);
    try testing.expectEqual(@as(usize, 0), indices[0]);
}

test "matchPathsCompiled - parity with matchPaths" {
    const paths = [_][]const u8{ "foo.rs", "bar.txt", "baz.rs" };
    var p = try compilePattern(testing.allocator, "*.rs", .{});
    defer p.deinit();

    var compiled_result = try matchPathsCompiled(testing.allocator, &p, &paths, .{});
    defer compiled_result.deinit();

    var direct_result = try matchPaths(testing.allocator, "*.rs", &paths, .{});
    defer direct_result.deinit();

    try testing.expectEqual(direct_result.len(), compiled_result.len());
    for (0..direct_result.len()) |i| {
        try testing.expectEqualSlices(u8, direct_result.get(i), compiled_result.get(i));
    }
}

test "matchPathIndicesCompiled - same pattern reused" {
    var p = try compilePattern(testing.allocator, "*.rs", .{});
    defer p.deinit();

    const paths1 = [_][]const u8{ "a.rs", "b.txt" };
    const idx1 = try matchPathIndicesCompiled(testing.allocator, &p, &paths1, .{});
    defer testing.allocator.free(idx1);
    try testing.expectEqual(@as(usize, 1), idx1.len);
    try testing.expectEqual(@as(usize, 0), idx1[0]);

    // Reuse the same compiled pattern against a different paths slice.
    const paths2 = [_][]const u8{ "x.txt", "y.rs", "z.rs" };
    const idx2 = try matchPathIndicesCompiled(testing.allocator, &p, &paths2, .{});
    defer testing.allocator.free(idx2);
    try testing.expectEqual(@as(usize, 2), idx2.len);
    try testing.expectEqual(@as(usize, 1), idx2[0]);
    try testing.expectEqual(@as(usize, 2), idx2[1]);
}

test "matchPathIndicesAtCompiled - base path" {
    var p = try compilePattern(testing.allocator, "src/*.rs", .{});
    defer p.deinit();

    const paths = [_][]const u8{
        "/proj/src/lib.rs",
        "/proj/src/main.rs",
        "/proj/README.md",
    };
    const indices = try matchPathIndicesAtCompiled(
        testing.allocator,
        "/proj",
        &p,
        &paths,
        .{},
    );
    defer testing.allocator.free(indices);

    try testing.expectEqual(@as(usize, 2), indices.len);
}

// ===========================================================================
// Path-separator handling: `/` always, `\\` on Windows only.
// ===========================================================================

const builtin = @import("builtin");
const zlob_core = @import("zlob_core");
const path_matcher_mod = zlob_core.compiled_pattern;

test "splitPathComponentsNormalized - forward slash always splits" {
    var buf: [16][]const u8 = undefined;
    const out = path_matcher_mod.splitPathComponentsNormalized("a/b/c", &buf).?;
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("a", out[0]);
    try testing.expectEqualStrings("b", out[1]);
    try testing.expectEqualStrings("c", out[2]);
}

test "getBasenameNormalized - forward slash always" {
    try testing.expectEqualStrings("file.txt", path_matcher_mod.getBasenameNormalized("a/b/file.txt"));
    try testing.expectEqualStrings("file.txt", path_matcher_mod.getBasenameNormalized("file.txt"));
}

test "splitPathComponentsNormalized - backslash splits only on Windows" {
    var buf: [16][]const u8 = undefined;
    const out = path_matcher_mod.splitPathComponentsNormalized("a\\b\\c", &buf).?;
    if (builtin.os.tag == .windows) {
        try testing.expectEqual(@as(usize, 3), out.len);
        try testing.expectEqualStrings("a", out[0]);
        try testing.expectEqualStrings("b", out[1]);
        try testing.expectEqualStrings("c", out[2]);
    } else {
        try testing.expectEqual(@as(usize, 1), out.len);
        try testing.expectEqualStrings("a\\b\\c", out[0]);
    }
}

test "getBasenameNormalized - backslash splits only on Windows" {
    const got = path_matcher_mod.getBasenameNormalized("dir\\sub\\file.txt");
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("file.txt", got);
    } else {
        try testing.expectEqualStrings("dir\\sub\\file.txt", got);
    }
}

test "splitPathComponentsNormalized - mixed separators on Windows" {
    var buf: [16][]const u8 = undefined;
    const out = path_matcher_mod.splitPathComponentsNormalized("a/b\\c/d", &buf).?;
    if (builtin.os.tag == .windows) {
        try testing.expectEqual(@as(usize, 4), out.len);
        try testing.expectEqualStrings("a", out[0]);
        try testing.expectEqualStrings("b", out[1]);
        try testing.expectEqualStrings("c", out[2]);
        try testing.expectEqualStrings("d", out[3]);
    } else {
        // On POSIX `\` is a literal byte, so the input splits on `/` only:
        // "a", "b\\c", "d".
        try testing.expectEqual(@as(usize, 3), out.len);
        try testing.expectEqualStrings("a", out[0]);
        try testing.expectEqualStrings("b\\c", out[1]);
        try testing.expectEqualStrings("d", out[2]);
    }
}

test "splitPathComponentsNormalized - returns null on component overflow" {
    var buf: [4][]const u8 = undefined;
    // 5 components into a 4-slot buffer: must report overflow, not truncate.
    try testing.expectEqual(@as(?[][]const u8, null), path_matcher_mod.splitPathComponentsNormalized("a/b/c/d/e", &buf));
    // Exactly buffer.len components fits.
    const ok = path_matcher_mod.splitPathComponentsNormalized("a/b/c/d", &buf);
    try testing.expectEqual(@as(usize, 4), ok.?.len);
}

test "matchPaths - deep path beyond MAX_PATH_COMPONENTS does not match doublestar" {
    // Build a path with far more components than the matcher buffer holds.
    const depth = path_matcher_mod.MAX_PATH_COMPONENTS + 5;
    var buf: [(path_matcher_mod.MAX_PATH_COMPONENTS + 5) * 2 + 16]u8 = undefined;
    var w: usize = 0;
    for (0..depth) |_| {
        buf[w] = 'a';
        buf[w + 1] = '/';
        w += 2;
    }
    @memcpy(buf[w..][0..5], "x.zig");
    w += 5;
    const deep = buf[0..w];

    const paths = [_][]const u8{deep};
    var result = try matchPaths(testing.allocator, "**/*.zig", &paths, .{ .doublestar_recursive = true });
    defer result.deinit();
    // Overflow → no-match (false negative is the documented, safe behaviour).
    try testing.expectEqual(@as(usize, 0), result.len());
}

// ===========================================================================
// Stack-only chunked C-string FFI: paths > STR_CHUNK should still produce
// correctly base-offset indices. Goes through the c_lib bridge.
// ===========================================================================

const c_lib = @import("c_lib");

test "zlob_match_paths - ZLOB_NOCHECK synthesizes pattern on no match (C string)" {
    const paths = [_][*:0]const u8{ "foo.txt", "bar.md" };
    var pzlob: c_lib.zlob_t = std.mem.zeroes(c_lib.zlob_t);
    const code = c_lib.zlob_match_paths(
        "*.zig",
        @ptrCast(&paths),
        paths.len,
        zlob_flags.ZLOB_NOCHECK,
        &pzlob,
    );
    defer c_lib.zlobfree(&pzlob);

    try testing.expectEqual(@as(c_int, 0), code);
    try testing.expectEqual(@as(usize, 1), pzlob.zlo_pathc);
    const got = std.mem.sliceTo(pzlob.zlo_pathv[0], 0);
    try testing.expectEqualStrings("*.zig", got);
}

test "zlob_match_paths - no match without ZLOB_NOCHECK returns NOMATCH (C string)" {
    const paths = [_][*:0]const u8{ "foo.txt", "bar.md" };
    var pzlob: c_lib.zlob_t = std.mem.zeroes(c_lib.zlob_t);
    const code = c_lib.zlob_match_paths(
        "*.zig",
        @ptrCast(&paths),
        paths.len,
        0,
        &pzlob,
    );
    defer c_lib.zlobfree(&pzlob);

    try testing.expectEqual(zlob_flags.ZLOB_NOMATCH, code);
}

test "matchPaths over chunked C-string array (> 256 paths)" {
    const path_count: usize = 1024;
    var paths_buf: [path_count][32:0]u8 = undefined;
    var paths: [path_count][*:0]const u8 = undefined;

    var matched_count: usize = 0;
    for (0..path_count) |i| {
        // Every 7th path matches *.zig; rest are .txt.
        const is_zig = (i % 7) == 0;
        const ext = if (is_zig) ".zig" else ".txt";
        if (is_zig) matched_count += 1;
        const written = std.fmt.bufPrintZ(&paths_buf[i], "p{d:0>5}{s}", .{ i, ext }) catch unreachable;
        paths[i] = written.ptr;
    }

    var out: c_lib.zlob_indices_t = .{ .indices = null, .count = 0 };
    const code = c_lib.zlob_match_paths_indices(
        "*.zig",
        @ptrCast(&paths),
        path_count,
        0,
        &out,
    );
    defer c_lib.zlob_indices_free(&out);

    try testing.expectEqual(@as(c_int, 0), code);
    try testing.expectEqual(matched_count, out.count);
    try testing.expect(out.indices != null);

    // Spot-check: every emitted index should land on a path ending in ".zig".
    const indices_slice = out.indices.?[0..out.count];
    for (indices_slice) |idx| {
        try testing.expect(idx < path_count);
        const path = std.mem.sliceTo(paths[idx], 0);
        try testing.expect(std.mem.endsWith(u8, path, ".zig"));
    }

    // Indices must be in input (ascending) order.
    for (1..indices_slice.len) |i| {
        try testing.expect(indices_slice[i] > indices_slice[i - 1]);
    }
}

// ===========================================================================
// Unified Windows-aware matching:
//   - On Windows, both `/` and `\\` are accepted in patterns AND paths;
//     they're equivalent at the matcher level.
//   - On POSIX, only `/` is a separator. `\\` stays literal.
// All dispatch arms (literal / single_suffix / multi_suffix / general / brace)
// must agree.
// ===========================================================================

test "unified separators: literal pattern + Windows-style path" {
    const paths = [_][]const u8{ "src\\main.zig", "src/main.zig", "src\\lib.zig" };
    var result = try matchPaths(testing.allocator, "src/main.zig", &paths, .{});
    defer result.deinit();

    if (builtin.os.tag == .windows) {
        // On Windows: both src\\main.zig and src/main.zig should match the
        // POSIX pattern `src/main.zig`.
        try testing.expectEqual(@as(usize, 2), result.len());
    } else {
        // On POSIX: `\\` is literal, only the exact `/` form matches.
        try testing.expectEqual(@as(usize, 1), result.len());
    }
}

test "unified separators: backslash pattern matches forward-slash path on Windows" {
    const paths = [_][]const u8{ "src/main.zig", "test/main.zig" };
    // Pattern uses `\\` — on Windows this normalises to `src/main.zig` at compile.
    var result = try matchPaths(testing.allocator, "src\\main.zig", &paths, .{});
    defer result.deinit();

    if (builtin.os.tag == .windows) {
        try testing.expectEqual(@as(usize, 1), result.len());
    } else {
        // On POSIX `src\\main.zig` is literal-byte, no path matches it.
        try testing.expectEqual(@as(usize, 0), result.len());
    }
}

test "unified separators: general pattern with `*` against Windows path" {
    const paths = [_][]const u8{ "src\\main.zig", "src\\lib.zig", "test\\foo.zig" };
    var result = try matchPaths(testing.allocator, "src/*.zig", &paths, .{});
    defer result.deinit();

    if (builtin.os.tag == .windows) {
        try testing.expectEqual(@as(usize, 2), result.len());
    } else {
        try testing.expectEqual(@as(usize, 0), result.len());
    }
}

test "unified separators: doublestar pattern against Windows path" {
    const paths = [_][]const u8{
        "src\\main.zig",
        "src\\sub\\dir\\foo.zig",
        "test\\bar.zig",
    };
    var result = try matchPaths(testing.allocator, "src/**/*.zig", &paths, .{ .doublestar_recursive = true });
    defer result.deinit();

    if (builtin.os.tag == .windows) {
        try testing.expectEqual(@as(usize, 2), result.len());
    } else {
        try testing.expectEqual(@as(usize, 0), result.len());
    }
}

test "unified separators: simple suffix matches regardless of separators" {
    // Suffix matching is byte-based — separator-agnostic on every platform.
    const paths = [_][]const u8{ "src\\main.zig", "src/lib.zig", "test\\foo.txt" };
    var result = try matchPaths(testing.allocator, "*.zig", &paths, .{});
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.len());
}

test "unified separators: brace pattern against mixed paths" {
    const paths = [_][]const u8{ "src\\main.zig", "src/lib.toml", "test/foo.txt" };
    var result = try matchPaths(testing.allocator, "src/*.{zig,toml}", &paths, .{ .brace = true });
    defer result.deinit();

    if (builtin.os.tag == .windows) {
        try testing.expectEqual(@as(usize, 2), result.len());
    } else {
        // On POSIX `src/*.toml` matches `src/lib.toml`, `src/*.zig` doesn't
        // match `src\\main.zig` (literal byte mismatch).
        try testing.expectEqual(@as(usize, 1), result.len());
    }
}

test "unified separators: CompiledPattern.matches per-path API" {
    var p = try compilePattern(testing.allocator, "src/main.zig", .{});
    defer p.deinit();

    try testing.expect(p.matches("src/main.zig", .{}));
    if (builtin.os.tag == .windows) {
        try testing.expect(p.matches("src\\main.zig", .{}));
    } else {
        try testing.expect(!p.matches("src\\main.zig", .{}));
    }
}
