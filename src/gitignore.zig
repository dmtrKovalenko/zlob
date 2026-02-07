//! This is a very simple gitignoire parser using already existing code for wildcard matching
//! it was easy to implement but it is not 100% optimized.
//!
//! There are a bunch of things other libs are doing to optimize ignoring like grouping, pattern combination,
//! caching and so on, imporving the performance but this is a good start for what it worth.
const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const glob = @import("zlob.zig");
const path_matcher = @import("path_matcher.zig");

/// A single gitignore pattern with pre-computed metadata
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
    /// Pattern has no wildcards (can use literal matching)
    is_literal: bool,
    /// Pattern text contains / (requires full path matching if not anchored)
    has_slash: bool,
    /// For simple suffix patterns like *.rs - the suffix without * (e.g., ".rs")
    /// Used for both suffix_patterns hash map grouping and fast matching
    suffix: ?[]const u8,
    /// Pre-computed suffix length for fast comparison
    suffix_len: u8,
    /// Pre-computed u32 of suffix for SIMD-style matching (suffixes <= 4 bytes)
    suffix_u32: u32,
    /// Index in original pattern list (for negation ordering)
    index: u16,
};

/// String hash map for O(1) literal lookups
const StringHashMap = std.StringHashMap(PatternMatch);

const PatternMatch = struct {
    negated: bool,
    dir_only: bool,
    index: u16,
};

/// Gitignore pattern set with optimized matching
pub const GitIgnore = struct {
    /// All patterns for full matching
    patterns: []Pattern,
    /// Wildcard patterns only (excludes literals)
    wildcard_patterns: []Pattern,
    /// Literal directory patterns for O(1) lookup (e.g., "target", "node_modules")
    literal_dirs: StringHashMap,
    /// Literal file patterns for O(1) lookup
    literal_files: StringHashMap,
    /// Suffix patterns grouped by extension (e.g., ".rs" -> [pattern for *.rs])
    suffix_patterns: std.StringHashMap([]Pattern),
    /// Whether any negation pattern exists (enables early termination)
    has_negations: bool,
    /// Index of first negation pattern (for early termination)
    first_negation_index: u16,
    /// Allocator for cleanup
    allocator: Allocator,
    /// Original file content - patterns slice into this
    source: []const u8,
    /// Cache for directory decisions: path -> should_skip
    dir_cache: std.StringHashMap(bool),

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

    /// Check if a pattern text contains any glob wildcards (SIMD-accelerated)
    fn hasWildcards(text: []const u8) bool {
        return glob.hasWildcardsBasic(text);
    }

    /// Extract suffix from a simple *.ext pattern
    fn extractSuffix(text: []const u8) ?[]const u8 {
        // Must start with * and have no other wildcards
        if (text.len < 2 or text[0] != '*') return null;
        // Check it's not **
        if (text.len >= 2 and text[1] == '*') return null;
        const rest = text[1..];
        // Rest must have no wildcards
        if (hasWildcards(rest)) return null;
        return rest;
    }

    /// Parse gitignore content - takes ownership of the content slice
    fn parseOwned(allocator: Allocator, content: []const u8) !Self {
        const PatternList = std.array_list.AlignedManaged(Pattern, null);

        var patterns_list = PatternList.init(allocator);
        defer patterns_list.deinit();

        var wildcard_list = PatternList.init(allocator);
        defer wildcard_list.deinit();

        var literal_dirs = StringHashMap.init(allocator);
        errdefer literal_dirs.deinit();

        var literal_files = StringHashMap.init(allocator);
        errdefer literal_files.deinit();

        var suffix_map = std.StringHashMap(PatternList).init(allocator);
        defer {
            var iter = suffix_map.valueIterator();
            while (iter.next()) |list| {
                list.deinit();
            }
            suffix_map.deinit();
        }

        var has_negations = false;
        var first_negation_index: u16 = std.math.maxInt(u16);
        var index: u16 = 0;

        var line_iter = mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |raw_line| {
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;

            if (parseLine(line, index)) |pattern| {
                try patterns_list.append(pattern);

                if (pattern.negated) {
                    has_negations = true;
                    if (index < first_negation_index) {
                        first_negation_index = index;
                    }
                }

                // Categorize pattern for optimized lookup
                if (pattern.is_literal and !pattern.anchored) {
                    // Simple literal pattern - add to hash map
                    const match = PatternMatch{
                        .negated = pattern.negated,
                        .dir_only = pattern.dir_only,
                        .index = index,
                    };
                    if (pattern.dir_only) {
                        try literal_dirs.put(pattern.text, match);
                    } else {
                        try literal_files.put(pattern.text, match);
                    }
                } else if (pattern.suffix) |suffix| {
                    // Suffix pattern like *.rs
                    const result = try suffix_map.getOrPut(suffix);
                    if (!result.found_existing) {
                        result.value_ptr.* = PatternList.init(allocator);
                    }
                    try result.value_ptr.append(pattern);
                } else {
                    // Wildcard pattern OR anchored literal pattern
                    try wildcard_list.append(pattern);
                }

                index += 1;
            }
        }

        // Convert suffix ArrayLists to slices
        var suffix_patterns = std.StringHashMap([]Pattern).init(allocator);
        errdefer suffix_patterns.deinit();

        var suffix_iter = suffix_map.iterator();
        while (suffix_iter.next()) |entry| {
            const slice = try entry.value_ptr.toOwnedSlice();
            try suffix_patterns.put(entry.key_ptr.*, slice);
        }

        return Self{
            .patterns = try patterns_list.toOwnedSlice(),
            .wildcard_patterns = try wildcard_list.toOwnedSlice(),
            .literal_dirs = literal_dirs,
            .literal_files = literal_files,
            .suffix_patterns = suffix_patterns,
            .has_negations = has_negations,
            .first_negation_index = first_negation_index,
            .allocator = allocator,
            .source = content,
            .dir_cache = std.StringHashMap(bool).init(allocator),
        };
    }

    /// Parse gitignore content from a borrowed string (for testing)
    pub fn parse(allocator: Allocator, content: []const u8) !Self {
        const owned = try allocator.dupe(u8, content);
        return try parseOwned(allocator, owned);
    }

    /// Parse a single line - returns pattern with text as slice into line
    fn parseLine(line: []const u8, index: u16) ?Pattern {
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

        const is_literal = !hasWildcards(text);
        const suffix = if (!anchored) extractSuffix(text) else null;
        const has_slash = glob.indexOfCharSIMD(text, '/') != null;

        // Pre-compute suffix values for fast matching
        var suffix_len: u8 = 0;
        var suffix_u32: u32 = 0;
        if (suffix) |s| {
            suffix_len = @intCast(s.len);
            if (s.len <= 4) {
                @memcpy(@as([*]u8, @ptrCast(&suffix_u32))[0..s.len], s);
            }
        }

        return Pattern{
            .text = text,
            .negated = negated,
            .dir_only = dir_only,
            .anchored = anchored,
            .has_double_star = mem.indexOf(u8, text, "**") != null,
            .is_literal = is_literal,
            .has_slash = has_slash,
            .suffix = suffix,
            .suffix_len = suffix_len,
            .suffix_u32 = suffix_u32,
            .index = index,
        };
    }

    /// Check if a path should be ignored - optimized version
    pub fn isIgnored(self: *const Self, path: []const u8, is_dir: bool) bool {
        // Fast path: skip ./ prefix if present (common case: no prefix)
        const normalized_path = if (path.len > 2 and path[0] == '.' and path[1] == '/') path[2..] else path;

        const basename = if (glob.lastIndexOfCharSIMD(normalized_path, '/')) |pos|
            normalized_path[pos + 1 ..]
        else
            normalized_path;

        // Fast path: if no negations exist, we can use optimized lookups
        if (!self.has_negations) {
            if (is_dir) {
                if (self.literal_dirs.get(basename)) |_| {
                    return true;
                }
            }
            if (self.literal_files.get(basename)) |match| {
                if (!match.dir_only or is_dir) {
                    return true;
                }
            }

            if (glob.lastIndexOfCharSIMD(basename, '.')) |dot_pos| {
                const suffix = basename[dot_pos..];
                if (self.suffix_patterns.get(suffix)) |patterns| {
                    // Any matching suffix pattern means ignored (check dir_only constraint)
                    for (patterns) |pattern| {
                        if (!pattern.dir_only or is_dir) return true;
                    }
                }
            }

            // Check wildcard patterns - these require actual pattern matching
            // OPTIMIZATION: Most wildcard patterns in typical .gitignore files
            // are basename-only (no /), so we only need to check against basename
            for (self.wildcard_patterns) |pattern| {
                if (pattern.dir_only and !is_dir) continue;
                if (matchPatternFast(&pattern, normalized_path, basename)) {
                    return true;
                }
            }

            return false;
        }

        // Slow path: has negations, must process all patterns in order
        var ignored = false;
        for (self.patterns) |pattern| {
            if (pattern.dir_only and !is_dir) continue;

            if (matchPatternFast(&pattern, normalized_path, basename)) {
                ignored = !pattern.negated;
            }
        }

        return ignored;
    }
    inline fn matchPatternFast(pattern: *const Pattern, path: []const u8, basename: []const u8) bool {
        const text = pattern.text;

        // Anchored patterns match against full path only
        if (pattern.anchored) {
            return path_matcher.matchGlobSimple(text, path);
        }

        // Non-anchored patterns without / match against basename only
        if (!pattern.has_slash) {
            // Fast path for simple suffix patterns (*.o, *.rs)
            // Use SIMD-style matching with pre-computed u32
            if (pattern.suffix_len > 0) {
                if (basename.len < pattern.suffix_len) return false;

                const suffix_len = pattern.suffix_len;
                return switch (suffix_len) {
                    1 => basename[basename.len - 1] == @as(u8, @truncate(pattern.suffix_u32)),
                    2 => blk: {
                        const tail_ptr = basename.ptr + basename.len - 2;
                        const tail: u16 = @as(*align(1) const u16, @ptrCast(tail_ptr)).*;
                        break :blk tail == @as(u16, @truncate(pattern.suffix_u32));
                    },
                    3 => blk: {
                        const tail_ptr = basename.ptr + basename.len - 3;
                        const tail_u16: u16 = @as(*align(1) const u16, @ptrCast(tail_ptr)).*;
                        const suffix_u16: u16 = @truncate(pattern.suffix_u32);
                        break :blk tail_u16 == suffix_u16 and tail_ptr[2] == pattern.suffix.?[2];
                    },
                    4 => blk: {
                        const tail_ptr = basename.ptr + basename.len - 4;
                        const tail: u32 = @as(*align(1) const u32, @ptrCast(tail_ptr)).*;
                        break :blk tail == pattern.suffix_u32;
                    },
                    else => mem.endsWith(u8, basename, pattern.suffix.?),
                };
            }
            // Literal patterns
            if (pattern.is_literal) {
                return mem.eql(u8, text, basename);
            }
            // Complex wildcard patterns (*.o.*, .*,  etc)
            return glob.fnmatch.fnmatch(text, basename, .{});
        }

        // Non-anchored patterns with / - match full path
        return path_matcher.matchGlobSimple(text, path);
    }

    /// Check if a directory should be skipped entirely (not traversed)
    /// This is called for every directory during traversal, so it must be fast.
    /// We only skip directories that are DEFINITELY ignored with no possibility
    /// of negation patterns affecting their children.
    pub fn shouldSkipDirectory(self: *Self, dir_path: []const u8) bool {
        const normalized_path = if (dir_path.len > 2 and dir_path[0] == '.' and dir_path[1] == '/') dir_path[2..] else dir_path;

        // Check cache first - this is critical for performance
        if (self.dir_cache.get(normalized_path)) |cached| {
            return cached;
        }

        const basename = if (glob.lastIndexOfCharSIMD(normalized_path, '/')) |pos|
            normalized_path[pos + 1 ..]
        else
            normalized_path;

        // FAST PATH: Check literal directory patterns (O(1) lookup)
        // Common patterns like "node_modules/", "target/", ".git/"
        if (self.literal_dirs.get(basename)) |match| {
            if (!match.negated) {
                // Check if any negation could affect this directory or its children
                if (!self.has_negations) {
                    // No negations at all - safe to skip
                    self.cacheResult(normalized_path, true);
                    return true;
                }

                // Has negations - check if any could affect this directory
                // A negation can affect this directory if:
                // 1. It directly re-includes this directory path
                // 2. It re-includes something under this directory (starts with our path + /)
                var dominated_by_negation = false;
                for (self.patterns) |pattern| {
                    if (!pattern.negated) continue;

                    // Check if negation could affect this dir or its children
                    if (pattern.has_double_star) {
                        // ** negation could match anywhere - must be conservative
                        dominated_by_negation = true;
                        break;
                    }

                    // Check if negation pattern matches or is under our path
                    if (mem.startsWith(u8, pattern.text, normalized_path)) {
                        dominated_by_negation = true;
                        break;
                    }
                    if (mem.startsWith(u8, pattern.text, basename)) {
                        dominated_by_negation = true;
                        break;
                    }
                }

                if (!dominated_by_negation) {
                    self.cacheResult(normalized_path, true);
                    return true;
                }
            }
        }

        // For non-literal patterns or when negations might interfere,
        // we need to be conservative and NOT skip
        self.cacheResult(normalized_path, false);
        return false;
    }

    /// Cache a directory skip result - duplicates the key since it may be from a stack buffer
    fn cacheResult(self: *Self, path: []const u8, should_skip: bool) void {
        // Duplicate the key since it may point to a temporary stack buffer
        const key_copy = self.allocator.dupe(u8, path) catch return;
        self.dir_cache.put(key_copy, should_skip) catch {
            self.allocator.free(key_copy);
        };
    }

    pub fn deinit(self: *Self) void {
        // Free suffix pattern slices
        var suffix_iter = self.suffix_patterns.valueIterator();
        while (suffix_iter.next()) |slice| {
            self.allocator.free(slice.*);
        }
        self.suffix_patterns.deinit();

        // Free duplicated keys in dir_cache
        var cache_iter = self.dir_cache.keyIterator();
        while (cache_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.dir_cache.deinit();

        self.literal_dirs.deinit();
        self.literal_files.deinit();
        self.allocator.free(self.patterns);
        self.allocator.free(self.wildcard_patterns);
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

test "literal pattern optimization" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\target/
        \\node_modules/
        \\.git/
    );
    defer gi.deinit();

    // These should use O(1) hash lookup
    try std.testing.expect(gi.isIgnored("target", true));
    try std.testing.expect(gi.isIgnored("node_modules", true));
    try std.testing.expect(gi.isIgnored(".git", true));
    try std.testing.expect(gi.isIgnored("foo/target", true));
    try std.testing.expect(!gi.isIgnored("target", false)); // dir_only
}

test "suffix pattern optimization" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\*.rs
        \\*.log
    );
    defer gi.deinit();

    try std.testing.expect(gi.isIgnored("main.rs", false));
    try std.testing.expect(gi.isIgnored("src/lib.rs", false));
    try std.testing.expect(gi.isIgnored("debug.log", false));
    try std.testing.expect(!gi.isIgnored("main.txt", false));
}
