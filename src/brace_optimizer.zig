const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const pattern_context = @import("pattern_context.zig");
const PatternContext = pattern_context.PatternContext;

pub fn findClosingBrace(pattern: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '{') {
            depth += 1;
        } else if (pattern[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        } else if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1; // Skip escaped character
        }
    }
    return null;
}

pub fn expandBraces(allocator: Allocator, pattern: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8){};
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    try recursivelyExpandBraces(allocator, pattern, &results);

    return results.toOwnedSlice(allocator);
}

fn recursivelyExpandBraces(allocator: Allocator, pattern: []const u8, results: *std.ArrayList([]const u8)) !void {
    // Find first unescaped opening brace
    var brace_start: ?usize = null;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1; // Skip escaped character
            continue;
        }
        if (pattern[i] == '{') {
            brace_start = i;
            break;
        }
    }

    // No braces found, just copy the pattern
    if (brace_start == null) {
        const copy = try allocator.dupe(u8, pattern);
        try results.append(allocator, copy);
        return;
    }

    const brace_open = brace_start.?;
    const brace_close = findClosingBrace(pattern, brace_open + 1) orelse {
        // No matching closing brace, treat as literal
        const copy = try allocator.dupe(u8, pattern);
        try results.append(allocator, copy);
        return;
    };

    const prefix = pattern[0..brace_open];
    const suffix = pattern[brace_close + 1 ..];
    const brace_content = pattern[brace_open + 1 .. brace_close];

    // Split brace content by commas (respecting nested braces)
    const alternatives = try splitBraceContent(allocator, brace_content);
    defer {
        for (alternatives) |alt| allocator.free(alt);
        allocator.free(alternatives);
    }

    // For each alternative, construct new pattern and recursively expand
    for (alternatives) |alt| {
        const new_pattern = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, alt, suffix });
        defer allocator.free(new_pattern);
        try recursivelyExpandBraces(allocator, new_pattern, results);
    }
}

pub fn containsBraces(pattern: []const u8) bool {
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (pattern.len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const brace_vec: Vec = @splat('{');
        var i: usize = 0;
        while (i + vec_len <= pattern.len) : (i += vec_len) {
            const chunk: Vec = pattern[i..][0..vec_len].*;
            const mask = @as(MaskInt, @bitCast(chunk == brace_vec));
            if (mask != 0) return true;
        }
        // Handle remainder
        for (pattern[i..]) |c| {
            if (c == '{') return true;
        }
        return false;
    }
    // Fallback for short patterns
    for (pattern) |c| {
        if (c == '{') return true;
    }
    return false;
}

pub const BracedComponent = struct {
    /// The raw text of this component (may contain {a,b} braces)
    text: []const u8,
    /// If this component has braces, the expanded alternatives
    /// e.g., for "{a,b}" -> ["a", "b"], for "*.rs" -> null
    alternatives: ?[][]const u8,
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
        var components = std.ArrayList(BracedComponent){};
        errdefer {
            for (components.items) |comp| {
                if (comp.pattern_contexts) |contexts| allocator.free(contexts);
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
};

fn splitBraceContent(allocator: Allocator, content: []const u8) ![][]const u8 {
    var alternatives = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    errdefer {
        for (alternatives.items) |alt| allocator.free(alt);
        alternatives.deinit();
    }

    var start: usize = 0;
    var i: usize = 0;
    var brace_depth: usize = 0;

    while (i < content.len) : (i += 1) {
        const ch = content[i];
        if (ch == '\\' and i + 1 < content.len) {
            i += 1;
            continue;
        }
        if (ch == '{') {
            brace_depth += 1;
            continue;
        }
        if (ch == '}') {
            if (brace_depth > 0) brace_depth -= 1;
            continue;
        }
        // Only split on commas at depth 0 (top-level)
        if (ch == ',' and brace_depth == 0) {
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
    const brace_end_abs = findClosingBrace(component, brace_start + 1) orelse return null;

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
        if (mem.indexOf(u8, full, "{") != null) {
            const expanded = try expandBracesAsAlternatives(allocator, full);
            allocator.free(full);
            if (expanded) |exps| {
                defer allocator.free(exps);
                for (exps) |exp| {
                    try alternatives.append(exp);
                }
            }
        } else {
            try alternatives.append(full);
        }
    }

    return try alternatives.toOwnedSlice();
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

test "analyzePatternForGlob - dir alternatives uses single_walk" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Pattern like {src,lib}/**/*.rs should use single_walk with pre-doublestar components
    var result = try analyzeBracedPattern(allocator, "{src,lib}/**/*.rs");
    defer result.deinit();

    // Directory-level braces now use single_walk for optimized single tree traversal
    try testing.expect(result == .single_walk);

    // Verify the parsed pattern has correct structure
    const parsed = result.single_walk;
    try testing.expectEqual(@as(usize, 3), parsed.components.len);
    // First component should have alternatives
    try testing.expect(parsed.components[0].alternatives != null);
    try testing.expectEqual(@as(usize, 2), parsed.components[0].alternatives.?.len);
}

test "analyzePatternForGlob - no braces returns no_braces strategy" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var result = try analyzeBracedPattern(allocator, "**/*.rs");
    defer result.deinit();

    try testing.expect(result == .no_braces);
}
