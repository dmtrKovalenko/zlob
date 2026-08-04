const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");
const zlobcore = @import("zlob_core");
const fnmatch = zlob.fnmatch;
const GitIgnore = zlobcore.GitIgnore;

// Test gitignore pattern parsing
test "gitignore parse - empty content" {
    var gi = try GitIgnore.parse(testing.allocator, "");
    defer gi.deinit();
    try testing.expectEqual(0, gi.patterns.len);
}

test "gitignore parse - comments and blank lines" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\# This is a comment
        \\
        \\# Another comment
        \\
    );
    defer gi.deinit();
    try testing.expectEqual(0, gi.patterns.len);
}

test "gitignore parse - simple patterns" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\*.log
        \\build/
        \\!important.log
    );
    defer gi.deinit();

    try testing.expectEqual(3, gi.patterns.len);

    // *.log
    try testing.expectEqualStrings("*.log", gi.patterns[0].text);
    try testing.expect(!gi.patterns[0].negated);
    try testing.expect(!gi.patterns[0].dir_only);
    try testing.expect(!gi.patterns[0].anchored);

    // build/
    try testing.expectEqualStrings("build", gi.patterns[1].text);
    try testing.expect(!gi.patterns[1].negated);
    try testing.expect(gi.patterns[1].dir_only);
    try testing.expect(!gi.patterns[1].anchored);

    // !important.log
    try testing.expectEqualStrings("important.log", gi.patterns[2].text);
    try testing.expect(gi.patterns[2].negated);
    try testing.expect(!gi.patterns[2].dir_only);
}

test "gitignore parse - anchored patterns" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\/root.txt
        \\src/temp
    );
    defer gi.deinit();

    try testing.expectEqual(2, gi.patterns.len);

    // /root.txt - leading / makes it anchored
    try testing.expectEqualStrings("root.txt", gi.patterns[0].text);
    try testing.expect(gi.patterns[0].anchored);

    // src/temp - contains / so anchored
    try testing.expectEqualStrings("src/temp", gi.patterns[1].text);
    try testing.expect(gi.patterns[1].anchored);
}

test "gitignore parse - double star patterns" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\**/logs
        \\src/**/*.o
    );
    defer gi.deinit();

    try testing.expectEqual(2, gi.patterns.len);
    try testing.expect(gi.patterns[0].has_double_star);
    try testing.expect(gi.patterns[1].has_double_star);
}

// Test gitignore matching
test "gitignore isIgnored - basic patterns" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\*.log
        \\build/
    );
    defer gi.deinit();

    // *.log should match any .log file
    try testing.expect(gi.isIgnored("test.log", false));
    try testing.expect(gi.isIgnored("src/debug.log", false));
    try testing.expect(!gi.isIgnored("test.txt", false));

    // build/ should only match directories
    try testing.expect(gi.isIgnored("build", true));
    try testing.expect(!gi.isIgnored("build", false)); // Not a directory
    try testing.expect(gi.isIgnored("src/build", true));
}

test "gitignore isIgnored - with negation" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\*.log
        \\!important.log
    );
    defer gi.deinit();

    try testing.expect(gi.isIgnored("test.log", false));
    try testing.expect(gi.isIgnored("debug.log", false));
    try testing.expect(!gi.isIgnored("important.log", false)); // Negated
}

test "gitignore isIgnored - anchored patterns" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\/root.txt
        \\src/temp.o
    );
    defer gi.deinit();

    // /root.txt only matches at root
    try testing.expect(gi.isIgnored("root.txt", false));
    try testing.expect(!gi.isIgnored("subdir/root.txt", false));

    // src/temp.o is anchored due to /
    try testing.expect(gi.isIgnored("src/temp.o", false));
    try testing.expect(!gi.isIgnored("other/src/temp.o", false));
}

test "gitignore isIgnored - double star patterns" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\**/logs
        \\src/**/*.o
    );
    defer gi.deinit();

    // **/logs matches logs directory anywhere
    try testing.expect(gi.isIgnored("logs", true));
    try testing.expect(gi.isIgnored("app/logs", true));
    try testing.expect(gi.isIgnored("app/server/logs", true));

    // src/**/*.o matches .o files anywhere under src/
    try testing.expect(gi.isIgnored("src/main.o", false));
    try testing.expect(gi.isIgnored("src/lib/util.o", false));
    try testing.expect(gi.isIgnored("src/a/b/c/deep.o", false));
    try testing.expect(!gi.isIgnored("other/main.o", false));
}

// Regression: https://github.com/dmtrKovalenko/fff/issues/723
//
// The "deny everything, then allow back" idiom. `*` ignores every entry at
// every level, `!*.*` re-includes anything whose basename contains a dot, and
// the dir-only `!/**/` re-includes every directory so the walk can actually
// descend. Without that last rule every subdirectory stays ignored and a
// walker only ever sees the top level.
//
// Expectations below are the verbatim output of `git add -A -n` on a tree with
// this exact .gitignore (git 2.x), which the `ignore` crate reproduces too.
test "gitignore isIgnored - allowlist idiom: '*' then '!*.*' and '!/**/'" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\# Ignore all
        \\*
        \\
        \\# Unignore all with extensions
        \\!*.*
        \\
        \\# Unignore all dirs
        \\!/**/
    );
    defer gi.deinit();

    // `!/**/` is dir-only, so every directory is re-included at any depth.
    try testing.expect(!gi.isIgnored("src", true));
    try testing.expect(!gi.isIgnored("src/deep", true));
    try testing.expect(!gi.isIgnored("a/b/c/d/e", true));

    // ...which is also what keeps the walker from pruning the whole subtree.
    try testing.expect(!gi.shouldSkipDirectory("src"));
    try testing.expect(!gi.shouldSkipDirectory("src/deep"));

    // `!*.*` re-includes extensioned files at any depth, not just the root.
    try testing.expect(!gi.isIgnored("main.rs", false));
    try testing.expect(!gi.isIgnored("src/lib.rs", false));
    try testing.expect(!gi.isIgnored("src/deep/a.txt", false));
    try testing.expect(!gi.isIgnored("dir.d/x.md", false));

    // A leading `*` matches the empty string, so dotfiles match `*.*` too.
    try testing.expect(!gi.isIgnored(".gitignore", false));
    try testing.expect(!gi.isIgnored(".keep", false));

    // Extensionless files stay ignored — `!*.*` never re-includes them.
    try testing.expect(gi.isIgnored("Makefile", false));
    try testing.expect(gi.isIgnored("src/noext", false));
    try testing.expect(gi.isIgnored("dir.d/noext", false));
}

test "gitignore isIgnored - allowlist idiom with unanchored '!**/'" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\*
        \\!*.*
        \\!**/
    );
    defer gi.deinit();

    try testing.expect(!gi.isIgnored("src", true));
    try testing.expect(!gi.isIgnored("src/deep", true));
    try testing.expect(!gi.shouldSkipDirectory("src"));
    try testing.expect(!gi.isIgnored("src/deep/a.txt", false));
    try testing.expect(gi.isIgnored("src/noext", false));
}

// Regression guard. This has been reverted twice by simplifying the doublestar
// check in path_matcher.zig to `mem.eql(seg, "**")`, which looks equivalent and
// is not: git treats a segment of *any* run of stars as a recursive doublestar.
// Previously only the Rust differential suite caught it, so the feedback arrived
// far from the edit — hence this test, next to the semantics it protects.
//
// Ground truth (git 2.x), tree a/b/noext:
//   $ printf '***/noext\n' > .gitignore && git check-ignore -q a/b/noext  # -> ignored
test "gitignore - runs of stars behave as **" {
    inline for (.{ "**/noext", "***/noext", "****/noext" }) |doc| {
        var gi = try GitIgnore.parse(testing.allocator, doc);
        defer gi.deinit();
        try testing.expect(gi.isIgnored("noext", false));
        try testing.expect(gi.isIgnored("src/noext", false));
        try testing.expect(gi.isIgnored("a/b/c/noext", false));
        try testing.expect(!gi.isIgnored("src/other", false));
    }

    // Dir-only spelling, at any depth.
    inline for (.{ "**/", "***/", "****/" }) |doc| {
        var gi = try GitIgnore.parse(testing.allocator, doc);
        defer gi.deinit();
        try testing.expect(gi.isIgnored("src", true));
        try testing.expect(gi.isIgnored("a/b/c", true));
    }

    // A segment that merely *contains* stars is NOT a doublestar: it matches
    // within one path component only.
    inline for (.{ "**a/x", "a**/x", "b**c/x" }) |doc| {
        var gi = try GitIgnore.parse(testing.allocator, doc);
        defer gi.deinit();
        try testing.expect(!gi.isIgnored("deep/nested/a/x", false));
    }
}

test "gitignore - wildcard matching beyond the fixed component buffer" {
    var path_buf: [512]u8 = undefined;
    var path_len: usize = 0;
    for (0..129) |_| {
        @memcpy(path_buf[path_len..][0..2], "a/");
        path_len += 2;
    }
    @memcpy(path_buf[path_len..][0..5], "x.txt");
    path_len += 5;

    // A short recursive pattern exercises the streaming path fallback
    var recursive = try GitIgnore.parse(testing.allocator, "**/*.txt");
    defer recursive.deinit();
    try testing.expect(recursive.isIgnored(path_buf[0..path_len], false));

    // An equally deep anchored pattern also exercises unbounded pattern
    // compilation; previously its empty segment list could never match
    var pattern_buf: [512]u8 = undefined;
    var pattern_len: usize = 0;
    for (0..129) |_| {
        @memcpy(pattern_buf[pattern_len..][0..2], "a/");
        pattern_len += 2;
    }
    @memcpy(pattern_buf[pattern_len..][0..5], "?.txt");
    pattern_len += 5;

    var anchored = try GitIgnore.parse(testing.allocator, pattern_buf[0..pattern_len]);
    defer anchored.deinit();
    try testing.expect(anchored.isIgnored(path_buf[0..path_len], false));
}

test "gitignore shouldSkipDirectory" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\node_modules/
        \\build/
        \\!build/keep/
    );
    defer gi.deinit();

    // node_modules should be skipped
    try testing.expect(gi.shouldSkipDirectory("node_modules"));

    // `build/` excludes the directory itself, and git cannot re-include a path
    // whose ancestor is excluded, so `!build/keep/` is inert and build is skipped.
    try testing.expect(gi.shouldSkipDirectory("build"));
}

test "gitignore shouldSkipDirectory - anchored patterns" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\rust/target/
    );
    defer gi.deinit();

    // rust/target should be skipped (anchored pattern)
    try testing.expect(gi.shouldSkipDirectory("rust/target"));

    // rust itself should not be skipped
    try testing.expect(!gi.shouldSkipDirectory("rust"));

    // other target dirs should not be skipped (pattern is anchored)
    try testing.expect(!gi.shouldSkipDirectory("other/target"));
    try testing.expect(!gi.shouldSkipDirectory("target"));
}

test "gitignore shouldSkipDirectory - anchored pattern with negated subdir" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\rust/target/
        \\!rust/target/rust-analyzer/
    );
    defer gi.deinit();

    try testing.expect(gi.shouldSkipDirectory("rust/target"));
    // A sibling outside the excluded tree is untouched.
    try testing.expect(!gi.shouldSkipDirectory("rust/src"));
}

test "gitignore isIgnored - anchored pattern with negated subdir" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\rust/target/
        \\!rust/target/rust-analyzer/
    );
    defer gi.deinit();

    // rust/target dir is ignored
    try testing.expect(gi.isIgnored("rust/target", true));

    // rust/target/debug dir is ignored (child of ignored dir)
    try testing.expect(gi.isIgnored("rust/target/debug", true));

    // rust/target/debug/app.rs file - should be ignored
    // (files inside ignored directories are also ignored)
    try testing.expect(gi.isIgnored("rust/target/debug/app.rs", false));

    // The negation cannot take effect: git refuses to re-include anything whose
    // ancestor directory is excluded, and `rust/target/` excludes the parent.
    // Verified with git:
    //   $ printf 'rust/target/\n!rust/target/rust-analyzer/\n' > .gitignore
    //   $ git check-ignore -v rust/target/rust-analyzer/analysis.rs
    //   .gitignore:1:rust/target/  rust/target/rust-analyzer/analysis.rs
    // To actually re-include it the parent has to be un-excluded first, e.g.
    // `rust/target/*` instead of `rust/target/`.
    try testing.expect(gi.isIgnored("rust/target/rust-analyzer", true));
    try testing.expect(gi.isIgnored("rust/target/rust-analyzer/analysis.rs", false));
}

// The working spelling of the above: excluding the *contents* rather than the
// directory leaves the parent un-excluded, so the negation can take effect.
// Verified against `git ls-files -o --exclude-standard`.
test "gitignore isIgnored - re-include works when parent is not excluded" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\rust/target/*
        \\!rust/target/rust-analyzer
    );
    defer gi.deinit();

    try testing.expect(gi.isIgnored("rust/target/debug", true));
    try testing.expect(gi.isIgnored("rust/target/debug/app.rs", false));
    try testing.expect(!gi.isIgnored("rust/target/rust-analyzer", true));
    try testing.expect(!gi.isIgnored("rust/target/rust-analyzer/analysis.rs", false));
}

// Test common real-world patterns
test "gitignore - common patterns" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\# Dependencies
        \\node_modules/
        \\vendor/
        \\
        \\# Build outputs
        \\*.o
        \\*.a
        \\*.so
        \\dist/
        \\build/
        \\
        \\# IDE
        \\.idea/
        \\.vscode/
        \\*.swp
        \\
        \\# OS
        \\.DS_Store
        \\Thumbs.db
    );
    defer gi.deinit();

    // Dependencies
    try testing.expect(gi.isIgnored("node_modules", true));
    try testing.expect(gi.isIgnored("vendor", true));

    // Build outputs
    try testing.expect(gi.isIgnored("main.o", false));
    try testing.expect(gi.isIgnored("src/lib.o", false));
    try testing.expect(gi.isIgnored("libfoo.a", false));
    try testing.expect(gi.isIgnored("dist", true));

    // IDE
    try testing.expect(gi.isIgnored(".idea", true));
    try testing.expect(gi.isIgnored(".vscode", true));
    try testing.expect(gi.isIgnored("test.swp", false));

    // OS
    try testing.expect(gi.isIgnored(".DS_Store", false));
    try testing.expect(gi.isIgnored("Thumbs.db", false));

    // Should NOT be ignored
    try testing.expect(!gi.isIgnored("src/main.c", false));
    try testing.expect(!gi.isIgnored("README.md", false));
    try testing.expect(!gi.isIgnored("package.json", false));
}

// Test zlob matching helpers
test "zlob fnmatchFull - basic patterns" {
    try testing.expect(fnmatch.fnmatch("*.txt", "file.txt", .{}));
    try testing.expect(!fnmatch.fnmatch("*.txt", "file.log", .{}));
    try testing.expect(fnmatch.fnmatch("test?", "test1", .{}));
    try testing.expect(!fnmatch.fnmatch("test?", "test12", .{}));
    try testing.expect(fnmatch.fnmatch("[abc]", "a", .{}));
    try testing.expect(fnmatch.fnmatch("[abc]", "b", .{}));
    try testing.expect(!fnmatch.fnmatch("[abc]", "d", .{}));
    try testing.expect(fnmatch.fnmatch("[a-z]", "m", .{}));
    try testing.expect(!fnmatch.fnmatch("[a-z]", "5", .{}));
}

// Note: GitIgnore.matchGlob is internal (not pub), so we test ** patterns
// through isIgnored which uses matchGlob internally
test "gitignore double star matching through isIgnored" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\**/*.c
        \\a/**/b
    );
    defer gi.deinit();

    // Test ** patterns through isIgnored
    try testing.expect(gi.isIgnored("src/main.c", false));
    try testing.expect(gi.isIgnored("main.c", false));
    try testing.expect(gi.isIgnored("a/b", false));
    try testing.expect(gi.isIgnored("a/x/b", false));
    try testing.expect(gi.isIgnored("a/x/y/b", false));
}
