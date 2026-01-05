//! In-memory path matching with recursive ** support
//! This module provides glob pattern matching against arrays of path strings
//! without any filesystem I/O operations.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const glob = @import("glob.zig");
const suffix_match = @import("suffix_match.zig");

const hasWildcardsSIMD = glob.hasWildcardsSIMD;
const PatternContext = glob.PatternContext;
const fnmatchWithContext = glob.fnmatchWithContext;

// Re-export types and flags
pub const GlobResults = glob.GlobResults;
pub const GLOB_NOSORT = glob.GLOB_NOSORT;
pub const GLOB_PERIOD = glob.GLOB_PERIOD;
pub const GLOB_NOCHECK = glob.GLOB_NOCHECK;
pub const GLOB_NOESCAPE = glob.GLOB_NOESCAPE;

/// Internal structure to hold pattern segments split by **
const PatternSegments = struct {
    segments: [][]const u8,
    contexts: []PatternContext, // Pre-computed contexts to avoid redundant hasWildcardsSIMD calls
    allocator: Allocator,

    // Pre-computed metadata to avoid per-path checks
    has_doublestar: bool,           // True if pattern contains **
    original_pattern: []const u8,   // Original pattern string (for fast path without **)
    pattern_context: PatternContext, // Pre-computed context for fast path

    pub fn deinit(self: *PatternSegments) void {
        self.allocator.free(self.segments);
        self.allocator.free(self.contexts);
    }
};

/// Internal structure to hold path components split by /
const PathComponents = struct {
    components: [][]const u8,
    allocator: Allocator,

    pub fn deinit(self: *PathComponents) void {
        self.allocator.free(self.components);
    }
};

/// Split pattern by ** into segments
/// For example: "src/**/test/*.zig" -> ["src", "**", "test", "**", "*.zig"]
/// Returns segments where ** is represented as the literal string "**"
fn splitPatternByDoublestar(allocator: Allocator, pattern: []const u8) !PatternSegments {
    // Quick check: if no **, return single segment
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

    // Count segments by splitting on /
    var segment_count: usize = 0;
    var iter = mem.splitScalar(u8, pattern, '/');
    while (iter.next()) |_| {
        segment_count += 1;
    }

    // Allocate segment array
    var segments = try allocator.alloc([]const u8, segment_count);
    errdefer allocator.free(segments);

    var contexts = try allocator.alloc(PatternContext, segment_count);
    errdefer allocator.free(contexts);

    // Split and populate segments
    var idx: usize = 0;
    iter = mem.splitScalar(u8, pattern, '/');
    while (iter.next()) |segment| {
        if (segment.len > 0) {
            segments[idx] = segment;
            contexts[idx] = PatternContext.init(segment);
            idx += 1;
        } else if (idx == 0 and pattern.len > 0 and pattern[0] == '/') {
            // Leading slash - preserve as empty segment to indicate absolute path
            segments[idx] = "";
            contexts[idx] = PatternContext.init("");
            idx += 1;
        }
    }

    // Trim to actual count
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
        .pattern_context = PatternContext.init(pattern), // Pre-compute even though not used for ** patterns
    };
}

/// Split path into components by / using a stack buffer (no heap allocation)
/// For example: "/users/alice/code/main.c" -> ["users", "alice", "code", "main.c"]
/// Empty components (from consecutive slashes) are filtered out
/// Returns a slice pointing into the provided buffer
fn splitPathComponentsFast(path: []const u8, buffer: [][]const u8) [][]const u8 {
    // Single pass: split and populate simultaneously
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

/// Extract suffix from pattern for pre-filtering optimization
/// Returns the suffix if pattern ends with *.ext (where ext has no wildcards)
/// Only works for patterns where last component is exactly "*.ext" (e.g., "*.c", "drivers/**/*.c")
/// Does NOT work for "test_*.zig" because the prefix "test_" would be ignored
pub fn extractSuffixFromPattern(pattern: []const u8) struct { suffix: ?[]const u8 } {
    // Find the last path component
    const last_slash = mem.lastIndexOfScalar(u8, pattern, '/');
    const last_component = if (last_slash) |pos| pattern[pos + 1 ..] else pattern;

    // Check if last component is exactly *.ext pattern (star must be at position 0)
    if (last_component.len < 2) return .{ .suffix = null };
    if (last_component[0] != '*') return .{ .suffix = null };

    // Handle ** - not a suffix pattern
    if (last_component.len >= 2 and last_component[1] == '*') return .{ .suffix = null };

    const after_star = last_component[1..];

    // Check that suffix has no wildcards
    if (hasWildcardsSIMD(after_star)) return .{ .suffix = null };

    // Must have some suffix after the star
    if (after_star.len == 0) return .{ .suffix = null };

    return .{ .suffix = after_star };
}

/// Split path into components by / (heap-allocated, fallback for deep paths)
/// For example: "/users/alice/code/main.c" -> ["users", "alice", "code", "main.c"]
/// Empty components (from consecutive slashes) are filtered out
fn splitPathComponents(allocator: Allocator, path: []const u8) !PathComponents {
    // Count non-empty components
    var component_count: usize = 0;
    var iter = mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (component.len > 0) {
            component_count += 1;
        }
    }

    // Handle empty path
    if (component_count == 0) {
        const components = try allocator.alloc([]const u8, 0);
        return PathComponents{
            .components = components,
            .allocator = allocator,
        };
    }

    // Allocate components array
    var components = try allocator.alloc([]const u8, component_count);
    errdefer allocator.free(components);

    // Split and populate components (skip empty)
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

/// Check if a path component should be skipped based on GLOB_PERIOD flag
/// Without GLOB_PERIOD, wildcards don't match files starting with '.'
fn shouldSkipHidden(path_component: []const u8, pattern: []const u8, flags: u32) bool {
    // If component doesn't start with '.', never skip
    if (path_component.len == 0 or path_component[0] != '.') {
        return false;
    }

    // Skip . and .. always
    if (mem.eql(u8, path_component, ".") or mem.eql(u8, path_component, "..")) {
        return true;
    }

    // If GLOB_PERIOD is set, don't skip hidden files
    if (flags & GLOB_PERIOD != 0) {
        return false;
    }

    // If pattern explicitly starts with '.', don't skip
    if (pattern.len > 0 and pattern[0] == '.') {
        return false;
    }

    // Pattern doesn't explicitly match '.', and GLOB_PERIOD not set -> skip
    return true;
}

/// Recursive matching of path components against pattern segments
/// Handles ** by trying to match at multiple depths with backtracking
fn matchPathSegments(
    path_components: [][]const u8,
    pattern_segments: [][]const u8,
    pattern_contexts: []PatternContext,
    segment_idx: usize,
    path_idx: usize,
    flags: u32,
) bool {
    // Base case: all pattern segments consumed
    if (segment_idx >= pattern_segments.len) {
        // Success if we've also consumed all path components
        return path_idx >= path_components.len;
    }

    const current_pattern = pattern_segments[segment_idx];

    // Check if this segment is ** (literal string "**")
    const is_doublestar = mem.eql(u8, current_pattern, "**");

    if (is_doublestar) {
        // ** can match zero or more path components

        // Try matching 0 directories (** matches nothing)
        if (matchPathSegments(path_components, pattern_segments, pattern_contexts, segment_idx + 1, path_idx, flags)) {
            return true;
        }

        // Try matching 1, 2, 3... directories (backtracking)
        var skip: usize = 1;
        while (path_idx + skip <= path_components.len) : (skip += 1) {
            // Check if any of the components we're skipping are hidden and should be blocked
            var should_block = false;
            for (path_idx..path_idx + skip) |i| {
                if (i < path_components.len) {
                    // ** is a wildcard pattern that doesn't explicitly start with '.', so check hidden files
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
        // Regular pattern segment - must match current path component
        if (path_idx >= path_components.len) {
            return false;
        }

        const path_component = path_components[path_idx];

        // Handle hidden file rules
        if (shouldSkipHidden(path_component, current_pattern, flags)) {
            return false;
        }

        // Match using pre-computed context to avoid redundant hasWildcardsSIMD calls
        if (fnmatchWithContext(&pattern_contexts[segment_idx], path_component)) {
            return matchPathSegments(path_components, pattern_segments, pattern_contexts, segment_idx + 1, path_idx + 1, flags);
        }

        return false;
    }
}

/// Match a single path against pattern (with ** support)
/// Note: paths must be normalized (no consecutive slashes like //)
fn matchSinglePath(
    pattern_segments: *const PatternSegments,
    path: []const u8,
    flags: u32,
) !bool {
    // Fast path: no ** in pattern, use pre-computed pattern and context
    // This is faster than component-by-component matching for simple patterns
    if (!pattern_segments.has_doublestar) {
        // Use pre-computed pattern context directly with the normalized path
        return fnmatchWithContext(&pattern_segments.pattern_context, path);
    }

    // Slow path: pattern contains **, do component-by-component matching
    // Use stack buffer to avoid heap allocation (most paths have < 32 components)
    var component_buffer: [32][]const u8 = undefined;
    const path_components = splitPathComponentsFast(path, &component_buffer);

    // Handle absolute vs relative paths
    const pattern_is_absolute = pattern_segments.segments.len > 0 and pattern_segments.segments[0].len == 0;
    const path_is_absolute = path.len > 0 and path[0] == '/';

    if (pattern_is_absolute and !path_is_absolute) {
        return false; // Pattern is absolute but path is relative
    }

    // Adjust starting indices for absolute paths
    const pattern_start: usize = if (pattern_is_absolute) 1 else 0;
    const path_start: usize = 0; // path_components already skips leading slash

    // Recursive matching
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
/// - GLOB_NOSORT: Don't sort results (return in input order)
/// - GLOB_NOCHECK: Return pattern itself if no matches
/// - GLOB_PERIOD: Allow wildcards to match files starting with '.'
/// - GLOB_NOESCAPE: Treat backslashes as literal (not escape chars)
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
    // Handle empty input
    if (paths.len == 0) {
        if (flags & GLOB_NOCHECK != 0) {
            var result_paths = try allocator.alloc([]const u8, 1);
            result_paths[0] = try allocator.dupe(u8, pattern);
            return GlobResults{
                .paths = result_paths,
                .match_count = 1,
                .allocator = allocator,
                .owns_paths = true, // NOCHECK allocates the pattern
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

    // OPTIMIZATION #1: Literal pattern fast path (no wildcards)
    // If pattern contains no wildcards, use direct string equality
    // Paths must be normalized (no consecutive slashes)
    if (!hasWildcardsSIMD(pattern)) {
        // Normalize pattern (patterns from users may have // in them)
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

        // Single pass: collect matches directly (no path normalization needed)
        var matches = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer matches.deinit();

        for (paths) |path| {
            if (mem.eql(u8, path, norm_pattern)) {
                try matches.append(path);
            }
        }

        // Handle NOCHECK
        if (matches.items.len == 0 and flags & GLOB_NOCHECK != 0) {
            var result_paths = try allocator.alloc([]const u8, 1);
            result_paths[0] = try allocator.dupe(u8, pattern);
            return GlobResults{
                .paths = result_paths,
                .match_count = 1,
                .allocator = allocator,
                .owns_paths = true, // NOCHECK allocates the pattern
            };
        }

        // Handle no matches
        if (matches.items.len == 0) {
            const empty: [][]const u8 = &[_][]const u8{};
            return GlobResults{
                .paths = empty,
                .match_count = 0,
                .allocator = allocator,
                .owns_paths = false,
            };
        }

        // Transfer ownership to result
        const result_paths = try matches.toOwnedSlice();
        return GlobResults{
            .paths = result_paths,
            .match_count = result_paths.len,
            .allocator = allocator,
            .owns_paths = false, // References to input paths
        };
    }

    // OPTIMIZATION #2: Extract suffix from pattern for pre-filtering
    // For patterns like "*.c" or "drivers/**/*.c", we can pre-filter by suffix
    // This dramatically reduces the number of paths that need expensive ** matching
    const suffix_info = extractSuffixFromPattern(pattern);

    // Parse pattern once (needed for both suffix-only and complex patterns)
    var pattern_segments = try splitPatternByDoublestar(allocator, pattern);
    defer pattern_segments.deinit();

    // Single pass: collect matches directly
    var matches = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer matches.deinit();

    // Check if this is a simple suffix-only pattern (e.g., "*.c" with no directory components)
    // Must have no path separators to be a pure suffix pattern
    const is_simple_suffix_only = suffix_info.suffix != null and
        mem.indexOfScalar(u8, pattern, '/') == null and
        pattern_segments.segments.len == 1 and
        !mem.eql(u8, pattern_segments.segments[0], "**");

    if (is_simple_suffix_only) {
        // Fast path: pure suffix matching with SIMD batching
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
        // Hybrid path: pre-filter by suffix, then apply full pattern matching
        // This is the optimization for patterns like "drivers/**/*.c"
        if (suffix.len <= 4) {
            // SIMD batch pre-filter
            var pre_filtered = std.array_list.AlignedManaged([]const u8, null).init(allocator);
            defer pre_filtered.deinit();
            try suffix_match.SimdBatchedSuffixMatch.init(suffix).matchPathsBatchedSIMD(paths, &pre_filtered);

            // Apply full pattern to pre-filtered paths
            for (pre_filtered.items) |path| {
                if (try matchSinglePath(&pattern_segments, path, flags)) {
                    try matches.append(path);
                }
            }
        } else {
            // Scalar suffix pre-filter for longer suffixes
            const suffix_matcher = suffix_match.SuffixMatch.new(suffix);
            for (paths) |path| {
                if (suffix_matcher.match(path) and try matchSinglePath(&pattern_segments, path, flags)) {
                    try matches.append(path);
                }
            }
        }
    } else {
        // No suffix optimization possible, match all paths
        for (paths) |path| {
            if (try matchSinglePath(&pattern_segments, path, flags)) {
                try matches.append(path);
            }
        }
    }

    // Handle NOCHECK
    if (matches.items.len == 0 and flags & GLOB_NOCHECK != 0) {
        var result_paths = try allocator.alloc([]const u8, 1);
        result_paths[0] = try allocator.dupe(u8, pattern);
        return GlobResults{
            .paths = result_paths,
            .match_count = 1,
            .allocator = allocator,
            .owns_paths = true, // NOCHECK allocates the pattern
        };
    }

    // Handle no matches
    if (matches.items.len == 0) {
        const empty: [][]const u8 = &[_][]const u8{};
        return GlobResults{
            .paths = empty,
            .match_count = 0,
            .allocator = allocator,
            .owns_paths = false,
        };
    }

    // Transfer ownership to result
    const result_paths = try matches.toOwnedSlice();

    // Sort unless NOSORT
    if (flags & GLOB_NOSORT == 0) {
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
        .owns_paths = false, // References to input paths
    };
}
