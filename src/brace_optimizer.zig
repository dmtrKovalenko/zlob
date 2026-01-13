const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

pub const OptimizedBracePattern = struct {
    dir_pattern: []const u8, // e.g., "drivers/*/*"
    alternatives: [][]const u8, // e.g., ["*.c", "*.h"]
    allocator: Allocator,

    pub fn deinit(self: *OptimizedBracePattern) void {
        self.allocator.free(self.dir_pattern);
        for (self.alternatives) |alt| {
            self.allocator.free(alt);
        }
        self.allocator.free(self.alternatives);
    }
};

pub fn canOptimizeBracePattern(pattern: []const u8) bool {
    const brace_start = mem.indexOf(u8, pattern, "{") orelse return false;
    const brace_end = mem.indexOf(u8, pattern[brace_start..], "}") orelse return false;

    const after_brace = brace_start + brace_end + 1;
    if (after_brace >= pattern.len) return true;

    const suffix = pattern[after_brace..];
    if (mem.indexOfAny(u8, suffix, "*?[/") != null) return false;

    return true;
}

pub fn decomposeBracePattern(allocator: Allocator, pattern: []const u8) !OptimizedBracePattern {
    const brace_start = mem.indexOf(u8, pattern, "{") orelse return error.NoBraces;
    const brace_end_rel = mem.indexOf(u8, pattern[brace_start..], "}") orelse return error.NoClosingBrace;
    const brace_end = brace_start + brace_end_rel;

    const prefix = pattern[0..brace_start];
    const brace_content = pattern[brace_start + 1..brace_end];
    const suffix = pattern[brace_end + 1..];

    // Find the last path component before the brace
    // E.g., for "test/*.{c,h}", component_start points to "*" after "test/"
    var component_start: usize = 0;
    if (mem.lastIndexOf(u8, prefix, "/")) |last_slash| {
        component_start = last_slash + 1;
    }
    const component_prefix = prefix[component_start..];
    const dir_prefix = prefix[0..component_start]; // Everything before the last component

    const dir_pattern = try std.fmt.allocPrint(allocator, "{s}*", .{dir_prefix});

    // Split brace content into alternatives, including the component prefix
    // E.g., for "*.{c,h}", create alternatives "*.c", "*.h"
    var alt_list = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    errdefer {
        for (alt_list.items) |alt| allocator.free(alt);
        alt_list.deinit();
    }

    var iter = mem.splitScalar(u8, brace_content, ',');
    while (iter.next()) |alt| {
        const full_alt = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ component_prefix, alt, suffix });
        try alt_list.append(full_alt);
    }

    return OptimizedBracePattern{
        .dir_pattern = dir_pattern,
        .alternatives = try alt_list.toOwnedSlice(),
        .allocator = allocator,
    };
}

/// SIMD-optimized batch matching of a filename against multiple alternatives
/// Returns true if the filename matches ANY of the alternatives
pub fn batchMatchAlternatives(filename: []const u8, alternatives: []const []const u8) bool {
    // For suffix-only alternatives (most common case), use SIMD
    var all_suffixes = true;
    for (alternatives) |alt| {
        if (alt.len == 0 or alt[0] != '.') {
            all_suffixes = false;
            break;
        }
    }

    if (all_suffixes and alternatives.len >= 2) {
        return batchMatchSuffixesSIMD(filename, alternatives);
    }

    // Fallback to simple loop for complex patterns
    for (alternatives) |alt| {
        if (matchSimple(filename, alt)) return true;
    }
    return false;
}

// todo actually make SIMD here
fn batchMatchSuffixesSIMD(filename: []const u8, suffixes: []const []const u8) bool {
    var min_len: usize = std.math.maxInt(usize);
    for (suffixes) |suffix| {
        if (suffix.len < min_len) min_len = suffix.len;
    }
    if (filename.len < min_len) return false;

    var i: usize = 0;
    while (i < suffixes.len) : (i += 4) {
        const batch_size = @min(4, suffixes.len - i);
        var matched = false;

        inline for (0..4) |j| {
            if (j < batch_size) {
                if (mem.endsWith(u8, filename, suffixes[i + j])) {
                    matched = true;
                    break;
                }
            }
        }

        if (matched) return true;
    }

    return false;
}

/// Simple wildcard matching without full fnmatch complexity
fn matchSimple(name: []const u8, pattern: []const u8) bool {
    // Handle suffix matching (most common case)
    if (pattern.len > 0 and pattern[0] == '.') {
        return mem.endsWith(u8, name, pattern);
    }

    // Handle *.suffix pattern (e.g., *.c, *.h)
    if (pattern.len > 1 and pattern[0] == '*' and pattern[1] == '.') {
        const suffix = pattern[1..];
        return mem.endsWith(u8, name, suffix);
    }

    // Handle prefix matching
    if (pattern.len > 0 and pattern[pattern.len - 1] == '*') {
        const prefix = pattern[0 .. pattern.len - 1];
        return mem.startsWith(u8, name, prefix);
    }

    // Exact match
    return mem.eql(u8, name, pattern);
}

/// Statistics for optimization analysis
pub const BraceOptimizationStats = struct {
    directory_walks_saved: usize = 0,
    patterns_optimized: usize = 0,
    patterns_fallback: usize = 0,
};

test "canOptimizeBracePattern - basic detection" {
    const testing = std.testing;

    try testing.expect(canOptimizeBracePattern("*.{c,h}"));
    try testing.expect(canOptimizeBracePattern("test/*.{c,h}"));
    try testing.expect(canOptimizeBracePattern("drivers/*/*.{c,h}"));
    try testing.expect(canOptimizeBracePattern("path/to/file.{txt,md}"));

    try testing.expect(!canOptimizeBracePattern("no braces"));
    try testing.expect(!canOptimizeBracePattern("{a,b}/*/*.c")); // Complex structure after brace
}

test "decomposeBracePattern - basic decomposition" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pattern = try decomposeBracePattern(allocator, "test/*.{c,h}");
    defer pattern.deinit();

    try testing.expectEqualStrings("test/*", pattern.dir_pattern);
    try testing.expectEqual(@as(usize, 2), pattern.alternatives.len);
    try testing.expectEqualStrings("*.c", pattern.alternatives[0]);
    try testing.expectEqualStrings("*.h", pattern.alternatives[1]);
}

test "batchMatchAlternatives - suffix matching" {
    const testing = std.testing;

    const alternatives = [_][]const u8{ ".c", ".h" };
    try testing.expect(batchMatchAlternatives("test.c", &alternatives));
    try testing.expect(batchMatchAlternatives("test.h", &alternatives));
    try testing.expect(!batchMatchAlternatives("test.txt", &alternatives));
    try testing.expect(!batchMatchAlternatives("test", &alternatives));
}

test "batchMatchAlternatives - pattern matching" {
    const testing = std.testing;

    const alternatives = [_][]const u8{ "*.c", "*.h" };
    try testing.expect(batchMatchAlternatives("test.c", &alternatives));
    try testing.expect(batchMatchAlternatives("test.h", &alternatives));
    try testing.expect(!batchMatchAlternatives("test.txt", &alternatives));
}
