const std = @import("std");
const testing = std.testing;
const simdglob = @import("simdglob");
const glob = @import("glob");
const GitIgnore = glob.GitIgnore;

// Test gitignore pattern parsing
test "gitignore parse - empty content" {
    var gi = try GitIgnore.parse(testing.allocator, "");
    defer gi.deinit();
    try testing.expectEqual(@as(usize, 0), gi.patterns.len);
}

test "gitignore parse - comments and blank lines" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\# This is a comment
        \\
        \\# Another comment
        \\
    );
    defer gi.deinit();
    try testing.expectEqual(@as(usize, 0), gi.patterns.len);
}

test "gitignore parse - simple patterns" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\*.log
        \\build/
        \\!important.log
    );
    defer gi.deinit();

    try testing.expectEqual(@as(usize, 3), gi.patterns.len);

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

    try testing.expectEqual(@as(usize, 2), gi.patterns.len);

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

    try testing.expectEqual(@as(usize, 2), gi.patterns.len);
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

test "gitignore shouldSkipDirectory" {
    var gi = try GitIgnore.parse(testing.allocator,
        \\node_modules/
        \\build/
        \\!build/keep/
    );
    defer gi.deinit();

    // node_modules should be skipped
    try testing.expect(gi.shouldSkipDirectory("node_modules"));

    // build has a negation for children, so we shouldn't prune
    // (conservative approach to handle !build/keep/)
    try testing.expect(!gi.shouldSkipDirectory("build"));
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

// Test glob matching helpers
test "glob fnmatchFull - basic patterns" {
    try testing.expect(glob.fnmatchFull("*.txt", "file.txt"));
    try testing.expect(!glob.fnmatchFull("*.txt", "file.log"));
    try testing.expect(glob.fnmatchFull("test?", "test1"));
    try testing.expect(!glob.fnmatchFull("test?", "test12"));
    try testing.expect(glob.fnmatchFull("[abc]", "a"));
    try testing.expect(glob.fnmatchFull("[abc]", "b"));
    try testing.expect(!glob.fnmatchFull("[abc]", "d"));
    try testing.expect(glob.fnmatchFull("[a-z]", "m"));
    try testing.expect(!glob.fnmatchFull("[a-z]", "5"));
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
