const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const pattern_context = @import("pattern_context.zig");
const PatternContext = pattern_context.PatternContext;

/// Pre-computed suffix data for fast matching of *.ext patterns
pub const PrecomputedSuffix = struct {
    suffix: []const u8, // The suffix (e.g., ".rs", ".toml")
    suffix_u32: u32, // Pre-computed u32 for fast comparison
    suffix_u16: u16, // Pre-computed u16 for 2-3 byte suffixes
    len: u8,

    pub fn init(suffix: []const u8) PrecomputedSuffix {
        var suffix_u32: u32 = 0;
        var suffix_u16: u16 = 0;
        const len: u8 = @intCast(@min(suffix.len, 16));

        if (suffix.len >= 1) {
            @memcpy(@as([*]u8, @ptrCast(&suffix_u32))[0..@min(suffix.len, 4)], suffix[0..@min(suffix.len, 4)]);
            if (suffix.len >= 2) {
                suffix_u16 = @as(*align(1) const u16, @ptrCast(suffix.ptr)).*;
            }
        }

        return .{
            .suffix = suffix,
            .suffix_u32 = suffix_u32,
            .suffix_u16 = suffix_u16,
            .len = len,
        };
    }

    /// Fast suffix match using pre-computed values
    pub inline fn match(self: *const PrecomputedSuffix, name: []const u8) bool {
        if (name.len < self.len) return false;

        const name_end = name.ptr + name.len;

        return switch (self.len) {
            1 => name[name.len - 1] == self.suffix[0],
            2 => @as(*align(1) const u16, @ptrCast(name_end - 2)).* == self.suffix_u16,
            3 => blk: {
                const tail_u16 = @as(*align(1) const u16, @ptrCast(name_end - 3)).*;
                break :blk tail_u16 == self.suffix_u16 and (name_end - 1)[0] == self.suffix[2];
            },
            4 => @as(*align(1) const u32, @ptrCast(name_end - 4)).* == self.suffix_u32,
            else => mem.endsWith(u8, name, self.suffix),
        };
    }
};

pub const BracedComponent = struct {
    /// The raw text of this component (may contain {a,b} braces)
    text: []const u8,
    /// If this component has braces, the expanded alternatives
    /// e.g., for "{a,b}" -> ["a", "b"], for "*.rs" -> null
    alternatives: ?[][]const u8,
    /// Pre-computed suffix matchers for *.ext alternatives (null if not applicable)
    suffix_matchers: ?[]PrecomputedSuffix,
    /// Pre-computed pattern contexts for alternatives (avoids re-computing during matching)
    pattern_contexts: ?[]PatternContext,
    /// Whether this is the last component (filename or dir)
    is_last: bool,
};

pub const BracedPattern = struct {
    allocator: Allocator,
    components: []BracedComponent,
    has_recursive: bool,

    pub fn deinit(self: *BracedPattern) void {
        for (self.components) |comp| {
            if (comp.pattern_contexts) |contexts| {
                self.allocator.free(contexts);
            }
            if (comp.suffix_matchers) |matchers| {
                self.allocator.free(matchers);
            }
            if (comp.alternatives) |alts| {
                for (alts) |alt| {
                    self.allocator.free(alt);
                }
                self.allocator.free(alts);
            }
        }
        self.allocator.free(self.components);
    }

    pub fn parse(allocator: Allocator, pattern: []const u8) !BracedPattern {
        var components = std.ArrayListUnmanaged(BracedComponent){};
        errdefer {
            for (components.items) |comp| {
                if (comp.pattern_contexts) |contexts| allocator.free(contexts);
                if (comp.suffix_matchers) |matchers| allocator.free(matchers);
                if (comp.alternatives) |alts| {
                    for (alts) |alt| allocator.free(alt);
                    allocator.free(alts);
                }
            }
            components.deinit(allocator);
        }

        var has_recursive = false;

        // Split by /
        var start: usize = 0;

        var i: usize = 0;
        while (i <= pattern.len) : (i += 1) {
            if (i == pattern.len or pattern[i] == '/') {
                if (i > start) {
                    const comp_text = pattern[start..i];
                    const is_last = i == pattern.len;

                    // Check for **
                    if (mem.eql(u8, comp_text, "**")) {
                        has_recursive = true;
                    }

                    const alts = expandBracesAsAlternatives(allocator, comp_text) catch null;

                    // Pre-compute suffix matchers for *.ext patterns
                    const suffix_matchers = if (alts) |alternatives| blk: {
                        // Check if all alternatives are *.suffix patterns
                        var all_suffix_patterns = true;
                        for (alternatives) |alt| {
                            if (!isSimpleSuffixPattern(alt)) {
                                all_suffix_patterns = false;
                                break;
                            }
                        }

                        if (all_suffix_patterns) {
                            const matchers = try allocator.alloc(PrecomputedSuffix, alternatives.len);
                            for (alternatives, 0..) |alt, idx| {
                                // Extract suffix from "*.ext" -> ".ext"
                                const suffix = if (alt.len > 1 and alt[0] == '*') alt[1..] else alt;
                                matchers[idx] = PrecomputedSuffix.init(suffix);
                            }
                            break :blk matchers;
                        } else {
                            break :blk null;
                        }
                    } else null;

                    // Pre-compute pattern contexts for ALL alternatives (key optimization!)
                    const pattern_contexts_val = if (alts) |alternatives| blk: {
                        const contexts = try allocator.alloc(PatternContext, alternatives.len);
                        for (alternatives, 0..) |alt, idx| {
                            contexts[idx] = PatternContext.init(alt);
                        }
                        break :blk contexts;
                    } else null;

                    try components.append(allocator, .{
                        .text = comp_text,
                        .alternatives = alts,
                        .suffix_matchers = suffix_matchers,
                        .pattern_contexts = pattern_contexts_val,
                        .is_last = is_last,
                    });
                }
                start = i + 1;
            }
        }

        return BracedPattern{
            .components = try components.toOwnedSlice(allocator),
            .has_recursive = has_recursive,
            .allocator = allocator,
        };
    }

    /// Expand a parsed pattern into all concrete patterns
    /// e.g., "{src,lib}/**/*.{rs,toml}" -> ["src/**/*.rs", "src/**/*.toml", "lib/**/*.rs", "lib/**/*.toml"]
    pub fn expandToPatterns(self: *const BracedPattern, allocator: Allocator) ![][]const u8 {
        var patterns = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        errdefer {
            for (patterns.items) |p| allocator.free(p);
            patterns.deinit();
        }

        try patterns.append(try allocator.dupe(u8, ""));

        // For each component, either append it or expand alternatives
        for (self.components, 0..) |comp, idx| {
            const need_slash = idx > 0;

            if (comp.alternatives) |alts| {
                // Expand: multiply existing patterns by alternatives
                var new_patterns = std.array_list.AlignedManaged([]const u8, null).init(allocator);
                errdefer {
                    for (new_patterns.items) |p| allocator.free(p);
                    new_patterns.deinit();
                }

                for (patterns.items) |existing| {
                    for (alts) |alt| {
                        const new = if (need_slash)
                            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ existing, alt })
                        else
                            try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, alt });
                        try new_patterns.append(new);
                    }
                }

                for (patterns.items) |p| allocator.free(p);
                patterns.deinit();
                patterns = new_patterns;
            } else {
                // No braces - just append this component to all patterns
                var new_patterns = std.array_list.AlignedManaged([]const u8, null).init(allocator);
                errdefer {
                    for (new_patterns.items) |p| allocator.free(p);
                    new_patterns.deinit();
                }

                for (patterns.items) |existing| {
                    const new = if (need_slash)
                        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ existing, comp.text })
                    else
                        try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, comp.text });
                    try new_patterns.append(new);
                }

                for (patterns.items) |p| allocator.free(p);
                patterns.deinit();
                patterns = new_patterns;
            }
        }

        return try patterns.toOwnedSlice();
    }
};

/// Check if a pattern is a simple *.suffix pattern (e.g., "*.rs", "*.toml")
/// These can use fast pre-computed suffix matching
fn isSimpleSuffixPattern(pattern: []const u8) bool {
    // Must start with "*"
    if (pattern.len < 2 or pattern[0] != '*') return false;

    // Rest should be a simple suffix with no wildcards
    const suffix = pattern[1..];
    for (suffix) |c| {
        if (c == '*' or c == '?' or c == '[' or c == '{') return false;
    }
    return true;
}

fn hasNestedBraces(pattern: []const u8) bool {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1;
            continue;
        }
        if (pattern[i] == '{') {
            depth += 1;
            if (depth > 1) return true;
        } else if (pattern[i] == '}') {
            if (depth > 0) depth -= 1;
        }
    }
    return false;
}

pub fn containsBraces(s: []const u8) bool {
    return mem.indexOf(u8, s, "{") != null and mem.indexOf(u8, s, "}") != null;
}

fn splitBraceContent(allocator: Allocator, content: []const u8) ![][]const u8 {
    var alternatives = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    errdefer {
        for (alternatives.items) |alt| allocator.free(alt);
        alternatives.deinit();
    }

    var start: usize = 0;
    var i: usize = 0;

    while (i < content.len) : (i += 1) {
        if (content[i] == '\\' and i + 1 < content.len) {
            i += 1;
            continue;
        }
        if (content[i] == ',') {
            const alt = try allocator.dupe(u8, content[start..i]);
            try alternatives.append(alt);
            start = i + 1;
        }
    }

    const alt = try allocator.dupe(u8, content[start..]);
    try alternatives.append(alt);

    return try alternatives.toOwnedSlice();
}

fn expandBracesAsAlternatives(allocator: Allocator, component: []const u8) !?[][]const u8 {
    const brace_start = mem.indexOf(u8, component, "{") orelse return null;
    const brace_end = mem.indexOf(u8, component[brace_start..], "}") orelse return null;
    const brace_end_abs = brace_start + brace_end;

    const prefix = component[0..brace_start];
    const brace_content = component[brace_start + 1 .. brace_end_abs];
    const suffix = component[brace_end_abs + 1 ..];

    const inner_alts = try splitBraceContent(allocator, brace_content);
    defer {
        for (inner_alts) |a| allocator.free(a);
        allocator.free(inner_alts);
    }

    var alternatives = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    errdefer {
        for (alternatives.items) |alt| allocator.free(alt);
        alternatives.deinit();
    }

    for (inner_alts) |inner| {
        const full = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, inner, suffix });
        try alternatives.append(full);
    }

    return try alternatives.toOwnedSlice();
}

pub fn canOptimize(pattern: []const u8) bool {
    if (!containsBraces(pattern)) return false;
    if (hasNestedBraces(pattern)) return false;
    return true;
}

/// SIMD-optimized batch suffix matching
pub fn batchMatchSuffixes(filename: []const u8, suffixes: []const []const u8) bool {
    const Vec16 = @Vector(16, u8);

    for (suffixes) |suffix| {
        if (suffix.len > filename.len) continue;

        const filename_end = filename[filename.len - suffix.len ..];

        if (suffix.len <= 16) {
            var suffix_vec: Vec16 = @splat(0);
            var filename_vec: Vec16 = @splat(0);

            for (0..suffix.len) |j| {
                suffix_vec[j] = suffix[j];
                filename_vec[j] = filename_end[j];
            }

            const cmp = suffix_vec == filename_vec;
            var all_match = true;
            for (0..suffix.len) |j| {
                if (!cmp[j]) {
                    all_match = false;
                    break;
                }
            }
            if (all_match) return true;
        } else {
            if (mem.eql(u8, filename_end, suffix)) return true;
        }
    }
    return false;
}

/// Match filename against multiple patterns (simple wildcard matching)
pub fn batchMatchPatterns(filename: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (matchSimple(filename, pattern)) return true;
    }
    return false;
}

/// Simple wildcard matching for a single pattern
fn matchSimple(name: []const u8, pattern: []const u8) bool {
    // *.suffix
    if (pattern.len > 1 and pattern[0] == '*' and pattern[1] == '.') {
        return mem.endsWith(u8, name, pattern[1..]);
    }

    // *suffix (any suffix)
    if (pattern.len > 0 and pattern[0] == '*') {
        return mem.endsWith(u8, name, pattern[1..]);
    }

    // prefix*
    if (pattern.len > 0 and pattern[pattern.len - 1] == '*') {
        return mem.startsWith(u8, name, pattern[0 .. pattern.len - 1]);
    }

    // Exact match
    return mem.eql(u8, name, pattern);
}

pub const OptimizationResult = union(enum) {
    no_braces,
    fallback,
    single_walk: BracedPattern,
    pub fn deinit(self: *OptimizationResult) void {
        switch (self.*) {
            .single_walk => |*parsed| parsed.deinit(),
            .no_braces, .fallback => {},
        }
    }
};

/// Analyze a pattern and determine the optimal strategy for globbing.
/// Always returns a result - never null.
pub fn analyzeBracedPattern(allocator: Allocator, pattern: []const u8) !OptimizationResult {
    // Check if pattern contains braces at all
    if (!containsBraces(pattern)) {
        return .no_braces;
    }

    const parsed = BracedPattern.parse(allocator, pattern) catch {
        return .fallback;
    };

    return .{ .single_walk = parsed };
}

test "canOptimize" {
    const testing = std.testing;

    try testing.expect(canOptimize("*.{c,h}"));
    try testing.expect(canOptimize("{src,lib}/**/*.ts"));
    try testing.expect(canOptimize("path/{a,b}/file.rs"));

    try testing.expect(!canOptimize("no braces"));
    try testing.expect(!canOptimize("{a,{b,c}}/file")); // nested
}

test "BracedPattern.parse - simple" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var parsed = try BracedPattern.parse(allocator, "src/**/*.rs");
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 3), parsed.components.len);
    try testing.expect(parsed.has_recursive);
}

test "BracedPattern.parse - with braces" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var parsed = try BracedPattern.parse(allocator, "{src,lib}/**/*.{rs,toml}");
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 3), parsed.components.len);

    // First component should have alternatives
    try testing.expect(parsed.components[0].alternatives != null);
    try testing.expectEqual(@as(usize, 2), parsed.components[0].alternatives.?.len);
    try testing.expectEqualStrings("src", parsed.components[0].alternatives.?[0]);
    try testing.expectEqualStrings("lib", parsed.components[0].alternatives.?[1]);

    // Last component should have alternatives
    try testing.expect(parsed.components[2].alternatives != null);
    try testing.expectEqual(@as(usize, 2), parsed.components[2].alternatives.?.len);
    try testing.expectEqualStrings("*.rs", parsed.components[2].alternatives.?[0]);
    try testing.expectEqualStrings("*.toml", parsed.components[2].alternatives.?[1]);
}

test "BracedPattern.expandToPatterns" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var parsed = try BracedPattern.parse(allocator, "{src,lib}/**/*.{rs,toml}");
    defer parsed.deinit();

    const expanded = try parsed.expandToPatterns(allocator);
    defer {
        for (expanded) |p| allocator.free(p);
        allocator.free(expanded);
    }

    try testing.expectEqual(@as(usize, 4), expanded.len);
    try testing.expectEqualStrings("src/**/*.rs", expanded[0]);
    try testing.expectEqualStrings("src/**/*.toml", expanded[1]);
    try testing.expectEqualStrings("lib/**/*.rs", expanded[2]);
    try testing.expectEqualStrings("lib/**/*.toml", expanded[3]);
}

test "BracedPattern.expandToPatterns - mid-path brace" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var parsed = try BracedPattern.parse(allocator, "common/{error,logging}/**/*.rs");
    defer parsed.deinit();

    const expanded = try parsed.expandToPatterns(allocator);
    defer {
        for (expanded) |p| allocator.free(p);
        allocator.free(expanded);
    }

    try testing.expectEqual(@as(usize, 2), expanded.len);
    try testing.expectEqualStrings("common/error/**/*.rs", expanded[0]);
    try testing.expectEqualStrings("common/logging/**/*.rs", expanded[1]);
}

test "batchMatchPatterns" {
    const testing = std.testing;

    const patterns = [_][]const u8{ "*.rs", "*.toml" };
    try testing.expect(batchMatchPatterns("main.rs", &patterns));
    try testing.expect(batchMatchPatterns("Cargo.toml", &patterns));
    try testing.expect(!batchMatchPatterns("readme.md", &patterns));
}

test "batchMatchSuffixes" {
    const testing = std.testing;

    const suffixes = [_][]const u8{ ".rs", ".toml" };
    try testing.expect(batchMatchSuffixes("main.rs", &suffixes));
    try testing.expect(batchMatchSuffixes("Cargo.toml", &suffixes));
    try testing.expect(!batchMatchSuffixes("readme.md", &suffixes));
}

test "BracedPattern.parse - cargo pattern" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var parsed = try BracedPattern.parse(allocator, "**/Cargo.{toml,lock}");
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.components.len);
    try testing.expectEqualStrings("**", parsed.components[0].text);
    try testing.expect(parsed.components[0].alternatives == null);
    try testing.expectEqualStrings("Cargo.{toml,lock}", parsed.components[1].text);
    try testing.expect(parsed.components[1].alternatives != null);
    try testing.expectEqual(@as(usize, 2), parsed.components[1].alternatives.?.len);
    try testing.expectEqualStrings("Cargo.toml", parsed.components[1].alternatives.?[0]);
    try testing.expectEqualStrings("Cargo.lock", parsed.components[1].alternatives.?[1]);
    try testing.expect(parsed.has_recursive);
}

test "analyzePatternForGlob - single_walk with alternatives" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Pattern like **/*.{rs,toml} should use single_walk
    var result = try analyzeBracedPattern(allocator, "**/*.{rs,toml}");
    defer result.deinit();

    try testing.expect(result == .single_walk);

    const parsed = result.single_walk;
    try testing.expectEqual(@as(usize, 2), parsed.components.len);
    try testing.expect(parsed.has_recursive);

    // Last component should have alternatives
    const last_comp = parsed.components[1];
    try testing.expect(last_comp.alternatives != null);
    try testing.expectEqual(@as(usize, 2), last_comp.alternatives.?.len);
}

test "analyzePatternForGlob - single_walk with dir alternatives" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Pattern like {src,lib}/**/*.rs should use single_walk
    var result = try analyzeBracedPattern(allocator, "{src,lib}/**/*.rs");
    defer result.deinit();

    try testing.expect(result == .single_walk);

    const parsed = result.single_walk;
    try testing.expectEqual(@as(usize, 3), parsed.components.len);

    // First component should have alternatives
    const first_comp = parsed.components[0];
    try testing.expect(first_comp.alternatives != null);
    try testing.expectEqual(@as(usize, 2), first_comp.alternatives.?.len);
}

test "analyzePatternForGlob - no braces returns no_braces strategy" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var result = try analyzeBracedPattern(allocator, "**/*.rs");
    defer result.deinit();

    try testing.expect(result == .no_braces);
}
