//! In-memory path matching with recursive ** support
//! This module provides glob pattern matching against arrays of path strings
//! without any filesystem I/O operations.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const glob = @import("zlob.zig");
const suffix_match = @import("suffix_match.zig");

const hasWildcardsSIMD = glob.hasWildcardsSIMD;
const PatternContext = glob.PatternContext;
const fnmatchWithContext = glob.fnmatchWithContext;

// Re-export types and flags
pub const GlobResults = glob.GlobResults;
pub const ZLOB_NOSORT = glob.ZLOB_NOSORT;
pub const ZLOB_PERIOD = glob.ZLOB_PERIOD;
pub const ZLOB_NOCHECK = glob.ZLOB_NOCHECK;
pub const ZLOB_NOESCAPE = glob.ZLOB_NOESCAPE;
pub const ZLOB_BRACE = glob.ZLOB_BRACE;

const PatternSegments = struct {
    segments: [][]const u8,
    contexts: []PatternContext, // Pre-computed contexts to avoid redundant hasWildcardsSIMD calls
    allocator: Allocator,

    // Pre-computed metadata to avoid per-path checks
    has_doublestar: bool, // True if pattern contains **
    original_pattern: []const u8, // Original pattern string (for fast path without **)
    pattern_context: PatternContext, // Pre-computed context for fast path

    pub fn deinit(self: *PatternSegments) void {
        self.allocator.free(self.segments);
        self.allocator.free(self.contexts);
    }
};

const PathComponents = struct {
    components: [][]const u8,
    allocator: Allocator,

    pub fn deinit(self: *PathComponents) void {
        self.allocator.free(self.components);
    }
};

fn splitPatternByDoublestar(allocator: Allocator, pattern: []const u8) !PatternSegments {
    if (mem.indexOf(u8, pattern, "**") == null) {
        var segments = try allocator.alloc([]const u8, 1);
        segments[0] = pattern;

        var contexts = try allocator.alloc(PatternContext, 1);
        contexts[0] = PatternContext.init(pattern);

        return PatternSegments{
            .segments = segments,
            .contexts = contexts,
            .allocator = allocator,
            .has_doublestar = false,
            .original_pattern = pattern,
            .pattern_context = contexts[0],
        };
    }

    var segment_count: usize = 0;
    var iter = mem.splitScalar(u8, pattern, '/');
    while (iter.next()) |_| {
        segment_count += 1;
    }

    var segments = try allocator.alloc([]const u8, segment_count);
    errdefer allocator.free(segments);

    var contexts = try allocator.alloc(PatternContext, segment_count);
    errdefer allocator.free(contexts);

    var idx: usize = 0;
    iter = mem.splitScalar(u8, pattern, '/');
    while (iter.next()) |segment| {
        if (segment.len > 0) {
            segments[idx] = segment;
            contexts[idx] = PatternContext.init(segment);
            idx += 1;
        } else if (idx == 0 and pattern.len > 0 and pattern[0] == '/') {
            segments[idx] = "";
            contexts[idx] = PatternContext.init("");
            idx += 1;
        }
    }

    if (idx < segment_count) {
        segments = try allocator.realloc(segments, idx);
        contexts = try allocator.realloc(contexts, idx);
    }

    return PatternSegments{
        .segments = segments,
        .contexts = contexts,
        .allocator = allocator,
        .has_doublestar = true,
        .original_pattern = pattern,
        .pattern_context = PatternContext.init(pattern),
    };
}

fn splitPathComponentsFast(path: []const u8, buffer: [][]const u8) [][]const u8 {
    var idx: usize = 0;
    var iter = mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (component.len > 0 and idx < buffer.len) {
            buffer[idx] = component;
            idx += 1;
        }
    }
    return buffer[0..idx];
}

/// Simple glob pattern matching with ** support - no allocation required.
/// This is a lightweight alternative to matchSinglePath for cases where
/// you don't need ZLOB_PERIOD handling or pre-computed pattern contexts.
///
/// Supports:
/// - `*` matches any characters except `/`
/// - `?` matches exactly one character except `/`
/// - `[abc]` matches one character from the set
/// - `**` matches zero or more directories
///
/// Example patterns:
/// - `**/*.c` - All .c files at any depth
/// - `src/**/test_*.zig` - All test files under src/
/// - `*.txt` - All .txt files in root
pub fn matchGlobSimple(pattern: []const u8, path: []const u8) bool {
    // Fast path: no ** in pattern
    if (mem.indexOf(u8, pattern, "**") == null) {
        return glob.fnmatchFull(pattern, path);
    }

    // Split pattern and path into segments using stack buffers
    var pat_segments_buf: [32][]const u8 = undefined;
    var path_segments_buf: [64][]const u8 = undefined;

    const pat_segments = splitPathComponentsFast(pattern, &pat_segments_buf);
    const path_segments = splitPathComponentsFast(path, &path_segments_buf);

    return matchSegmentsSimple(pat_segments, path_segments, 0, 0);
}

/// Core recursive segment matching for ** patterns (no allocation, no ZLOB_PERIOD)
fn matchSegmentsSimple(
    pattern_segments: []const []const u8,
    path_segments: []const []const u8,
    pat_idx: usize,
    path_idx: usize,
) bool {
    // Base case: pattern exhausted
    if (pat_idx >= pattern_segments.len) {
        return path_idx >= path_segments.len;
    }

    const current_pattern = pattern_segments[pat_idx];

    // Handle ** (matches zero or more path segments)
    if (mem.eql(u8, current_pattern, "**")) {
        // Try matching ** with zero segments
        if (matchSegmentsSimple(pattern_segments, path_segments, pat_idx + 1, path_idx)) {
            return true;
        }
        // Try matching ** with one or more segments
        var skip: usize = 1;
        while (path_idx + skip <= path_segments.len) : (skip += 1) {
            if (matchSegmentsSimple(pattern_segments, path_segments, pat_idx + 1, path_idx + skip)) {
                return true;
            }
        }
        return false;
    }

    // Regular segment - must match current path segment
    if (path_idx >= path_segments.len) {
        return false;
    }

    // Use fnmatchFull to match the segment
    if (glob.fnmatchFull(current_pattern, path_segments[path_idx])) {
        return matchSegmentsSimple(pattern_segments, path_segments, pat_idx + 1, path_idx + 1);
    }

    return false;
}

pub fn extractSuffixFromPattern(pattern: []const u8) struct { suffix: ?[]const u8 } {
    const last_slash = mem.lastIndexOfScalar(u8, pattern, '/');
    const last_component = if (last_slash) |pos| pattern[pos + 1 ..] else pattern;

    if (last_component.len < 2) return .{ .suffix = null };
    if (last_component[0] != '*') return .{ .suffix = null };

    if (last_component.len >= 2 and last_component[1] == '*') return .{ .suffix = null };

    const after_star = last_component[1..];

    if (hasWildcardsSIMD(after_star)) return .{ .suffix = null };

    if (after_star.len == 0) return .{ .suffix = null };

    return .{ .suffix = after_star };
}

fn splitPathComponents(allocator: Allocator, path: []const u8) !PathComponents {
    var component_count: usize = 0;
    var iter = mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (component.len > 0) {
            component_count += 1;
        }
    }

    if (component_count == 0) {
        const components = try allocator.alloc([]const u8, 0);
        return PathComponents{
            .components = components,
            .allocator = allocator,
        };
    }

    var components = try allocator.alloc([]const u8, component_count);
    errdefer allocator.free(components);

    var idx: usize = 0;
    iter = mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (component.len > 0) {
            components[idx] = component;
            idx += 1;
        }
    }

    return PathComponents{
        .components = components,
        .allocator = allocator,
    };
}

// Helper to find matching closing brace
fn findClosingBrace(pattern: []const u8, start: usize) ?usize {
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

// Expand brace patterns like "{a,b,c}" into multiple patterns
fn expandBraces(allocator: Allocator, pattern: []const u8, results: *std.array_list.AlignedManaged([]const u8, null)) !void {
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
        try results.append(copy);
        return;
    }

    const brace_open = brace_start.?;
    const brace_close = findClosingBrace(pattern, brace_open + 1) orelse {
        // No matching closing brace, treat as literal
        const copy = try allocator.dupe(u8, pattern);
        try results.append(copy);
        return;
    };

    const prefix = pattern[0..brace_open];
    const suffix = pattern[brace_close + 1 ..];
    const brace_content = pattern[brace_open + 1 .. brace_close];

    // Split brace content by commas
    var start: usize = 0;
    var alternatives = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer {
        for (alternatives.items) |alt| {
            allocator.free(alt);
        }
        alternatives.deinit();
    }

    i = 0;
    while (i <= brace_content.len) : (i += 1) {
        if (i == brace_content.len or brace_content[i] == ',') {
            const alt = brace_content[start..i];

            const new_str = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, alt, suffix });
            try alternatives.append(new_str);
            start = i + 1;
        }
    }

    // Recursively expand each alternative
    for (alternatives.items) |alt_pattern| {
        try expandBraces(allocator, alt_pattern, results);
    }
}

fn shouldSkipHidden(path_component: []const u8, pattern: []const u8, flags: u32) bool {
    if (path_component.len == 0 or path_component[0] != '.') {
        return false;
    }

    if (mem.eql(u8, path_component, ".") or mem.eql(u8, path_component, "..")) {
        return true;
    }

    if (flags & ZLOB_PERIOD != 0) {
        return false;
    }

    if (pattern.len > 0 and pattern[0] == '.') {
        return false;
    }

    return true;
}

fn matchPathSegments(
    path_components: [][]const u8,
    pattern_segments: [][]const u8,
    pattern_contexts: []PatternContext,
    segment_idx: usize,
    path_idx: usize,
    flags: u32,
) bool {
    if (segment_idx >= pattern_segments.len) {
        return path_idx >= path_components.len;
    }

    const current_pattern = pattern_segments[segment_idx];

    const is_doublestar = mem.eql(u8, current_pattern, "**");

    if (is_doublestar) {
        if (matchPathSegments(path_components, pattern_segments, pattern_contexts, segment_idx + 1, path_idx, flags)) {
            return true;
        }

        var skip: usize = 1;
        while (path_idx + skip <= path_components.len) : (skip += 1) {
            var should_block = false;
            for (path_idx..path_idx + skip) |i| {
                if (i < path_components.len) {
                    if (shouldSkipHidden(path_components[i], "", flags)) {
                        should_block = true;
                        break;
                    }
                }
            }

            if (!should_block) {
                if (matchPathSegments(path_components, pattern_segments, pattern_contexts, segment_idx + 1, path_idx + skip, flags)) {
                    return true;
                }
            }
        }

        return false;
    } else {
        if (path_idx >= path_components.len) {
            return false;
        }

        const path_component = path_components[path_idx];

        if (shouldSkipHidden(path_component, current_pattern, flags)) {
            return false;
        }

        if (fnmatchWithContext(&pattern_contexts[segment_idx], path_component)) {
            return matchPathSegments(path_components, pattern_segments, pattern_contexts, segment_idx + 1, path_idx + 1, flags);
        }

        return false;
    }
}

fn matchSinglePath(
    pattern_segments: *const PatternSegments,
    path: []const u8,
    flags: u32,
) !bool {
    if (!pattern_segments.has_doublestar) {
        return fnmatchWithContext(&pattern_segments.pattern_context, path);
    }

    var component_buffer: [32][]const u8 = undefined;
    const path_components = splitPathComponentsFast(path, &component_buffer);

    const pattern_is_absolute = pattern_segments.segments.len > 0 and pattern_segments.segments[0].len == 0;
    const path_is_absolute = path.len > 0 and path[0] == '/';

    if (pattern_is_absolute and !path_is_absolute) {
        return false;
    }

    const pattern_start: usize = if (pattern_is_absolute) 1 else 0;
    const path_start: usize = 0;

    return matchPathSegments(
        path_components,
        pattern_segments.segments[pattern_start..],
        pattern_segments.contexts[pattern_start..],
        0,
        path_start,
        flags,
    );
}

/// Match glob pattern against array of paths (supports recursive **)
///
/// Supports full glob syntax including recursive `**` patterns:
/// - `*` matches any characters except `/`
/// - `?` matches exactly one character except `/`
/// - `[abc]` matches one character from the set
/// - `**` matches zero or more directories
///
/// Pattern examples:
/// - `**/*.c` - All .c files at any depth
/// - `/users/**/code/*.zig` - All .zig files in any 'code' directory under /users
/// - `src/**/test_*.zig` - All test files under src/
///
/// Supported flags:
/// - ZLOB_NOSORT: Don't sort results (return in input order)
/// - ZLOB_NOCHECK: Return pattern itself if no matches
/// - ZLOB_PERIOD: Allow wildcards to match files starting with '.'
/// - ZLOB_NOESCAPE: Treat backslashes as literal (not escape chars)
///
/// Requirements:
/// - Input paths MUST be normalized (no consecutive slashes like //)
/// - Paths from filesystem operations are typically already normalized
///
/// Returns: GlobResult containing matched paths (must call .deinit())
/// Errors: OutOfMemory
///
/// Performance notes:
/// - Parses pattern once, then matches against all paths
/// - O(n*m) where n=paths.len, m=pattern complexity
/// - Fast paths for simple patterns (no wildcards, *.ext, etc.)
/// - Uses SIMD-optimized fnmatch() for component matching
pub fn matchPaths(
    allocator: Allocator,
    pattern: []const u8,
    paths: []const []const u8,
    flags: u32,
) !GlobResults {
    // Handle ZLOB_BRACE expansion first
    if (flags & ZLOB_BRACE != 0) {
        var expanded_patterns = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer {
            for (expanded_patterns.items) |p| {
                allocator.free(p);
            }
            expanded_patterns.deinit();
        }

        try expandBraces(allocator, pattern, &expanded_patterns);

        // Match each expanded pattern and combine results
        var all_matches = std.StringHashMap(void).init(allocator);
        defer all_matches.deinit();

        for (expanded_patterns.items) |exp_pattern| {
            // Recursively call matchPaths without ZLOB_BRACE flag to avoid infinite recursion
            var result = try matchPaths(allocator, exp_pattern, paths, flags & ~@as(u32, ZLOB_BRACE));
            defer result.deinit();

            // Add matches to our set for deduplication
            for (result.paths) |path| {
                try all_matches.put(path, {});
            }
        }

        // Convert set back to array
        if (all_matches.count() == 0) {
            if (flags & ZLOB_NOCHECK != 0) {
                var result_paths = try allocator.alloc([]const u8, 1);
                result_paths[0] = try allocator.dupe(u8, pattern);
                return GlobResults{
                    .paths = result_paths,
                    .match_count = 1,
                    .allocator = allocator,
                    .owns_paths = true,
                };
            }
            const empty: [][]const u8 = &[_][]const u8{};
            return GlobResults{
                .paths = empty,
                .match_count = 0,
                .allocator = allocator,
                .owns_paths = false,
            };
        }

        var result_paths = try allocator.alloc([]const u8, all_matches.count());
        var i: usize = 0;
        var iter = all_matches.keyIterator();
        while (iter.next()) |key| {
            result_paths[i] = key.*;
            i += 1;
        }

        // Sort if needed
        if (flags & ZLOB_NOSORT == 0) {
            mem.sort([]const u8, result_paths, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
        }

        return GlobResults{
            .paths = result_paths,
            .match_count = result_paths.len,
            .allocator = allocator,
            .owns_paths = false,
        };
    }

    if (paths.len == 0) {
        if (flags & ZLOB_NOCHECK != 0) {
            var result_paths = try allocator.alloc([]const u8, 1);
            result_paths[0] = try allocator.dupe(u8, pattern);
            return GlobResults{
                .paths = result_paths,
                .match_count = 1,
                .allocator = allocator,
                .owns_paths = true,
            };
        }
        const empty: [][]const u8 = &[_][]const u8{};
        return GlobResults{
            .paths = empty,
            .match_count = 0,
            .allocator = allocator,
            .owns_paths = false,
        };
    }

    // OPTIMIZATION: Literal pattern fast path (no wildcards)
    // If pattern contains no wildcards, use direct string equality.
    // Paths must be normalized (no consecutive slashes).
    if (!hasWildcardsSIMD(pattern)) {
        var norm_pattern_buf: [4096]u8 = undefined;
        const norm_pattern = blk: {
            var len: usize = 0;
            var prev_slash = false;
            for (pattern) |c| {
                if (c == '/') {
                    if (!prev_slash and len < norm_pattern_buf.len) {
                        norm_pattern_buf[len] = c;
                        len += 1;
                    }
                    prev_slash = true;
                } else {
                    if (len < norm_pattern_buf.len) {
                        norm_pattern_buf[len] = c;
                        len += 1;
                    }
                    prev_slash = false;
                }
            }
            break :blk norm_pattern_buf[0..len];
        };

        var matches = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer matches.deinit();

        for (paths) |path| {
            if (mem.eql(u8, path, norm_pattern)) {
                try matches.append(path);
            }
        }

        if (matches.items.len == 0 and flags & ZLOB_NOCHECK != 0) {
            var result_paths = try allocator.alloc([]const u8, 1);
            result_paths[0] = try allocator.dupe(u8, pattern);
            return GlobResults{
                .paths = result_paths,
                .match_count = 1,
                .allocator = allocator,
                .owns_paths = true,
            };
        }

        if (matches.items.len == 0) {
            const empty: [][]const u8 = &[_][]const u8{};
            return GlobResults{
                .paths = empty,
                .match_count = 0,
                .allocator = allocator,
                .owns_paths = false,
            };
        }

        const result_paths = try matches.toOwnedSlice();
        return GlobResults{
            .paths = result_paths,
            .match_count = result_paths.len,
            .allocator = allocator,
            .owns_paths = false,
        };
    }

    // OPTIMIZATION: Extract suffix from pattern for pre-filtering.
    // For patterns like "*.c" or "drivers/**/*.c", we can pre-filter by suffix,
    // which dramatically reduces the number of paths that need expensive ** matching.
    const suffix_info = extractSuffixFromPattern(pattern);

    var pattern_segments = try splitPatternByDoublestar(allocator, pattern);
    defer pattern_segments.deinit();

    var matches = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer matches.deinit();

    const is_simple_suffix_only = suffix_info.suffix != null and
        mem.indexOfScalar(u8, pattern, '/') == null and
        pattern_segments.segments.len == 1 and
        !mem.eql(u8, pattern_segments.segments[0], "**");

    if (is_simple_suffix_only) {
        const suffix = suffix_info.suffix.?;
        if (suffix.len <= 4) {
            try suffix_match.SimdBatchedSuffixMatch.init(suffix).matchPathsBatchedSIMD(paths, &matches);
        } else {
            const suffix_matcher = suffix_match.SuffixMatch.new(suffix);
            for (paths) |path| {
                if (suffix_matcher.match(path)) {
                    try matches.append(path);
                }
            }
        }
    } else if (suffix_info.suffix) |suffix| {
        if (suffix.len <= 4) {
            var pre_filtered = std.array_list.AlignedManaged([]const u8, null).init(allocator);
            defer pre_filtered.deinit();
            try suffix_match.SimdBatchedSuffixMatch.init(suffix).matchPathsBatchedSIMD(paths, &pre_filtered);

            for (pre_filtered.items) |path| {
                if (try matchSinglePath(&pattern_segments, path, flags)) {
                    try matches.append(path);
                }
            }
        } else {
            const suffix_matcher = suffix_match.SuffixMatch.new(suffix);
            for (paths) |path| {
                if (suffix_matcher.match(path) and try matchSinglePath(&pattern_segments, path, flags)) {
                    try matches.append(path);
                }
            }
        }
    } else {
        for (paths) |path| {
            if (try matchSinglePath(&pattern_segments, path, flags)) {
                try matches.append(path);
            }
        }
    }

    if (matches.items.len == 0 and flags & ZLOB_NOCHECK != 0) {
        var result_paths = try allocator.alloc([]const u8, 1);
        result_paths[0] = try allocator.dupe(u8, pattern);
        return GlobResults{
            .paths = result_paths,
            .match_count = 1,
            .allocator = allocator,
            .owns_paths = true,
        };
    }

    if (matches.items.len == 0) {
        const empty: [][]const u8 = &[_][]const u8{};
        return GlobResults{
            .paths = empty,
            .match_count = 0,
            .allocator = allocator,
            .owns_paths = false,
        };
    }

    const result_paths = try matches.toOwnedSlice();

    if (flags & ZLOB_NOSORT == 0) {
        mem.sort([]const u8, result_paths, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
    }

    return GlobResults{
        .paths = result_paths,
        .match_count = result_paths.len,
        .allocator = allocator,
        .owns_paths = false,
    };
}
