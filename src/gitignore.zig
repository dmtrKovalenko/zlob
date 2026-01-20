//! Gitignore pattern parser and matcher
//!
//! Parses .gitignore files and provides efficient path filtering.
//! Supports the full gitignore pattern format including negation patterns.
//!
//! Pattern format:
//! - Blank lines are ignored
//! - Lines starting with # are comments
//! - Leading ! negates the pattern (re-includes previously ignored files)
//! - Trailing / means the pattern only matches directories
//! - Patterns with / (except trailing) are anchored to the gitignore location
//! - * matches anything except /
//! - ? matches any single character except /
//! - [...] matches one character in the range
//! - ** matches zero or more directories
//!
//! Reference: https://git-scm.com/docs/gitignore

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const glob = @import("glob.zig");
const path_matcher = @import("path_matcher.zig");

/// A single gitignore pattern - text is a slice into the source content
pub const Pattern = struct {
    /// The pattern text (slice into source)
    text: []const u8,
    /// Pattern is negated (starts with !)
    negated: bool,
    /// Pattern only matches directories (ends with /)
    dir_only: bool,
    /// Pattern is anchored (contains / other than trailing)
    anchored: bool,
    /// Pattern contains ** for recursive matching
    has_double_star: bool,
};

/// Gitignore pattern set - stores source content and patterns as slices
pub const GitIgnore = struct {
    patterns: []Pattern,
    allocator: Allocator,
    /// Original file content - patterns slice into this
    source: []const u8,

    const Self = @This();

    /// Load and parse .gitignore from current working directory
    /// Returns null if no .gitignore file exists
    pub fn loadFromCwd(allocator: Allocator) !?Self {
        const cwd = std.fs.cwd();
        const file = cwd.openFile(".gitignore", .{}) catch |err| {
            if (err == error.FileNotFound) {
                return null;
            }
            return err;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
            if (err == error.StreamTooLong) {
                return null;
            }
            return err;
        };

        return try parseOwned(allocator, content);
    }

    /// Load and parse .gitignore from a specific directory
    /// Returns null if no .gitignore file exists
    pub fn loadFromDir(allocator: Allocator, dir_path: []const u8) !?Self {
        var path_buf: [4096]u8 = undefined;
        const gitignore_path = if (dir_path.len > 0 and !mem.eql(u8, dir_path, "."))
            std.fmt.bufPrint(&path_buf, "{s}/.gitignore", .{dir_path}) catch return null
        else
            ".gitignore";

        const cwd = std.fs.cwd();
        const file = cwd.openFile(gitignore_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return null;
            }
            return err;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
            if (err == error.StreamTooLong) {
                return null;
            }
            return err;
        };

        return try parseOwned(allocator, content);
    }

    /// Parse gitignore content - takes ownership of the content slice
    fn parseOwned(allocator: Allocator, content: []const u8) !Self {
        var patterns = std.array_list.AlignedManaged(Pattern, null).init(allocator);
        defer patterns.deinit();

        var line_iter = mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |raw_line| {
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;

            if (parseLine(line)) |pattern| {
                try patterns.append(pattern);
            }
        }

        return Self{
            .patterns = try patterns.toOwnedSlice(),
            .allocator = allocator,
            .source = content,
        };
    }

    /// Parse gitignore content from a borrowed string (for testing)
    pub fn parse(allocator: Allocator, content: []const u8) !Self {
        const owned = try allocator.dupe(u8, content);
        return try parseOwned(allocator, owned);
    }

    /// Parse a single line - returns pattern with text as slice into line
    fn parseLine(line: []const u8) ?Pattern {
        var text = line;

        if (text.len == 0 or text[0] == '#') {
            return null;
        }

        // Trim trailing unescaped spaces
        while (text.len > 0 and text[text.len - 1] == ' ') {
            if (text.len >= 2 and text[text.len - 2] == '\\') break;
            text = text[0 .. text.len - 1];
        }

        if (text.len == 0) return null;

        var negated = false;
        if (text[0] == '!') {
            negated = true;
            text = text[1..];
            if (text.len == 0) return null;
        }

        var dir_only = false;
        if (text[text.len - 1] == '/') {
            dir_only = true;
            text = text[0 .. text.len - 1];
            if (text.len == 0) return null;
        }

        var anchored = false;
        if (text[0] == '/') {
            anchored = true;
            text = text[1..];
        } else {
            for (text) |ch| {
                if (ch == '/') {
                    anchored = true;
                    break;
                }
            }
        }

        return Pattern{
            .text = text,
            .negated = negated,
            .dir_only = dir_only,
            .anchored = anchored,
            .has_double_star = mem.indexOf(u8, text, "**") != null,
        };
    }

    /// Check if a path should be ignored
    pub fn isIgnored(self: *const Self, path: []const u8, is_dir: bool) bool {
        var ignored = false;

        const normalized_path = if (mem.startsWith(u8, path, "./")) path[2..] else path;

        for (self.patterns) |pattern| {
            if (pattern.dir_only and !is_dir) continue;

            if (matchPattern(&pattern, normalized_path)) {
                ignored = !pattern.negated;
            }
        }

        return ignored;
    }

    /// Check if a directory should be skipped entirely (not traversed)
    pub fn shouldSkipDirectory(self: *const Self, dir_path: []const u8) bool {
        var ignored = false;
        var explicitly_included = false;

        const normalized_path = if (mem.startsWith(u8, dir_path, "./")) dir_path[2..] else dir_path;

        for (self.patterns) |pattern| {
            if (matchPattern(&pattern, normalized_path)) {
                if (pattern.negated) {
                    explicitly_included = true;
                    ignored = false;
                } else {
                    ignored = true;
                    explicitly_included = false;
                }
            }
        }

        if (ignored and !explicitly_included) {
            for (self.patterns) |pattern| {
                if (pattern.negated) {
                    if (pattern.has_double_star) return false;
                    if (mem.startsWith(u8, pattern.text, normalized_path)) return false;
                }
            }
            return true;
        }

        return false;
    }

    fn matchPattern(pattern: *const Pattern, path: []const u8) bool {
        const text = pattern.text;

        if (pattern.anchored) {
            return path_matcher.matchGlobSimple(text, path);
        }

        if (path_matcher.matchGlobSimple(text, path)) return true;

        // Try basename
        if (mem.lastIndexOf(u8, path, "/")) |last_slash| {
            if (path_matcher.matchGlobSimple(text, path[last_slash + 1 ..])) return true;
        }

        // For patterns without /, try each segment
        if (mem.indexOf(u8, text, "/") == null) {
            var remaining = path;
            while (mem.indexOf(u8, remaining, "/")) |slash_pos| {
                if (path_matcher.matchGlobSimple(text, remaining[0..slash_pos])) return true;
                remaining = remaining[slash_pos + 1 ..];
            }
            if (path_matcher.matchGlobSimple(text, remaining)) return true;
        }

        return false;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.patterns);
        self.allocator.free(self.source);
    }
};

// Tests
test "parse empty content" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator, "");
    defer gi.deinit();
    try std.testing.expectEqual(@as(usize, 0), gi.patterns.len);
}

test "parse comments and blank lines" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\# This is a comment
        \\
        \\# Another comment
        \\
    );
    defer gi.deinit();
    try std.testing.expectEqual(@as(usize, 0), gi.patterns.len);
}

test "parse simple patterns" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\*.log
        \\build/
        \\!important.log
    );
    defer gi.deinit();

    try std.testing.expectEqual(@as(usize, 3), gi.patterns.len);
    try std.testing.expectEqualStrings("*.log", gi.patterns[0].text);
    try std.testing.expect(!gi.patterns[0].negated);
    try std.testing.expectEqualStrings("build", gi.patterns[1].text);
    try std.testing.expect(gi.patterns[1].dir_only);
    try std.testing.expectEqualStrings("important.log", gi.patterns[2].text);
    try std.testing.expect(gi.patterns[2].negated);
}

test "parse anchored patterns" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\/root.txt
        \\src/temp
    );
    defer gi.deinit();

    try std.testing.expectEqual(@as(usize, 2), gi.patterns.len);
    try std.testing.expectEqualStrings("root.txt", gi.patterns[0].text);
    try std.testing.expect(gi.patterns[0].anchored);
    try std.testing.expectEqualStrings("src/temp", gi.patterns[1].text);
    try std.testing.expect(gi.patterns[1].anchored);
}

test "isIgnored basic patterns" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\*.log
        \\build/
    );
    defer gi.deinit();

    try std.testing.expect(gi.isIgnored("test.log", false));
    try std.testing.expect(gi.isIgnored("src/debug.log", false));
    try std.testing.expect(!gi.isIgnored("test.txt", false));
    try std.testing.expect(gi.isIgnored("build", true));
    try std.testing.expect(!gi.isIgnored("build", false));
}

test "isIgnored with negation" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\*.log
        \\!important.log
    );
    defer gi.deinit();

    try std.testing.expect(gi.isIgnored("test.log", false));
    try std.testing.expect(!gi.isIgnored("important.log", false));
}

test "isIgnored double star" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\**/logs
        \\src/**/*.o
    );
    defer gi.deinit();

    try std.testing.expect(gi.isIgnored("logs", true));
    try std.testing.expect(gi.isIgnored("app/logs", true));
    try std.testing.expect(gi.isIgnored("src/main.o", false));
    try std.testing.expect(gi.isIgnored("src/lib/util.o", false));
    try std.testing.expect(!gi.isIgnored("other/main.o", false));
}

test "shouldSkipDirectory" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\node_modules/
        \\build/
        \\!build/keep/
    );
    defer gi.deinit();

    try std.testing.expect(gi.shouldSkipDirectory("node_modules"));
    try std.testing.expect(!gi.shouldSkipDirectory("build"));
}
