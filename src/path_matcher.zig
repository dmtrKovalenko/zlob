//! In-memory path matching with recursive ** support
//! This module provides glob pattern matching against arrays of path strings
//! without any filesystem I/O operations.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const glob_libc = @import("glob_libc.zig");
const glob = @import("glob.zig");

// Import existing functions
const fnmatch = glob_libc.fnmatch;
const hasWildcardsSIMD = glob_libc.hasWildcardsSIMD;

// Re-export types and flags
pub const GlobResult = glob.GlobResult;
pub const GLOB_NOSORT = glob_libc.GLOB_NOSORT;
pub const GLOB_PERIOD = glob_libc.GLOB_PERIOD;
pub const GLOB_NOCHECK = glob_libc.GLOB_NOCHECK;
pub const GLOB_NOESCAPE = glob_libc.GLOB_NOESCAPE;

/// Internal structure to hold pattern segments split by **
const PatternSegments = struct {
    segments: [][]const u8,
    allocator: Allocator,

    pub fn deinit(self: *PatternSegments) void {
        self.allocator.free(self.segments);
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
        return PatternSegments{
            .segments = segments,
            .allocator = allocator,
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

    // Split and populate segments
    var idx: usize = 0;
    iter = mem.splitScalar(u8, pattern, '/');
    while (iter.next()) |segment| {
        if (segment.len > 0) {
            segments[idx] = segment;
            idx += 1;
        } else if (idx == 0 and pattern.len > 0 and pattern[0] == '/') {
            // Leading slash - preserve as empty segment to indicate absolute path
            segments[idx] = "";
            idx += 1;
        }
    }

    // Trim to actual count
    if (idx < segment_count) {
        segments = try allocator.realloc(segments, idx);
    }

    return PatternSegments{
        .segments = segments,
        .allocator = allocator,
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
        if (matchPathSegments(path_components, pattern_segments, segment_idx + 1, path_idx, flags)) {
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
                if (matchPathSegments(path_components, pattern_segments, segment_idx + 1, path_idx + skip, flags)) {
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

        // Match using fnmatch
        if (fnmatch(current_pattern, path_component)) {
            return matchPathSegments(path_components, pattern_segments, segment_idx + 1, path_idx + 1, flags);
        }

        return false;
    }
}

/// Match a single path against pattern (with ** support)
fn matchSinglePath(
    pattern_segments: *const PatternSegments,
    path: []const u8,
    flags: u32,
) !bool {

    // Check if pattern contains **
    var has_doublestar = false;
    for (pattern_segments.segments) |segment| {
        if (mem.eql(u8, segment, "**")) {
            has_doublestar = true;
            break;
        }
    }

    // Fast path: no ** in pattern, just reconstruct and use fnmatch
    // This is faster than component-by-component matching for simple patterns
    if (!has_doublestar) {
        // Reconstruct pattern from segments
        var pattern_buf: [4096]u8 = undefined;
        var pattern_len: usize = 0;

        for (pattern_segments.segments, 0..) |segment, i| {
            if (i > 0 and pattern_len < pattern_buf.len) {
                pattern_buf[pattern_len] = '/';
                pattern_len += 1;
            }
            const copy_len = @min(segment.len, pattern_buf.len - pattern_len);
            @memcpy(pattern_buf[pattern_len..][0..copy_len], segment[0..copy_len]);
            pattern_len += copy_len;
        }

        // Normalize path by removing consecutive slashes for comparison
        var normalized_path_buf: [4096]u8 = undefined;
        var norm_len: usize = 0;
        var prev_was_slash = false;

        for (path) |c| {
            if (c == '/') {
                if (!prev_was_slash and norm_len < normalized_path_buf.len) {
                    normalized_path_buf[norm_len] = c;
                    norm_len += 1;
                }
                prev_was_slash = true;
            } else {
                if (norm_len < normalized_path_buf.len) {
                    normalized_path_buf[norm_len] = c;
                    norm_len += 1;
                }
                prev_was_slash = false;
            }
        }

        return fnmatch(pattern_buf[0..pattern_len], normalized_path_buf[0..norm_len]);
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
) !GlobResult {
    // Handle empty input
    if (paths.len == 0) {
        if (flags & GLOB_NOCHECK != 0) {
            var result_paths = try allocator.alloc([]const u8, 1);
            result_paths[0] = try allocator.dupe(u8, pattern);
            return GlobResult{
                .paths = result_paths,
                .match_count = 1,
                .allocator = allocator,
                .owns_paths = true, // NOCHECK allocates the pattern
            };
        }
        const empty: [][]const u8 = &[_][]const u8{};
        return GlobResult{
            .paths = empty,
            .match_count = 0,
            .allocator = allocator,
            .owns_paths = false,
        };
    }

    // OPTIMIZATION #1: Literal pattern fast path (no wildcards)
    // If pattern contains no wildcards, use direct string equality
    // Need to normalize paths to handle consecutive slashes (dir//file.txt == dir/file.txt)
    if (!hasWildcardsSIMD(pattern)) {
        // Normalize pattern first
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

        // Single pass: collect matches directly
        var matches = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer matches.deinit();

        var norm_path_buf: [4096]u8 = undefined;
        for (paths) |path| {
            // Normalize path
            const norm_path = blk: {
                var len: usize = 0;
                var prev_slash = false;
                for (path) |c| {
                    if (c == '/') {
                        if (!prev_slash and len < norm_path_buf.len) {
                            norm_path_buf[len] = c;
                            len += 1;
                        }
                        prev_slash = true;
                    } else {
                        if (len < norm_path_buf.len) {
                            norm_path_buf[len] = c;
                            len += 1;
                        }
                        prev_slash = false;
                    }
                }
                break :blk norm_path_buf[0..len];
            };

            if (mem.eql(u8, norm_path, norm_pattern)) {
                try matches.append(path);
            }
        }

        // Handle NOCHECK
        if (matches.items.len == 0 and flags & GLOB_NOCHECK != 0) {
            var result_paths = try allocator.alloc([]const u8, 1);
            result_paths[0] = try allocator.dupe(u8, pattern);
            return GlobResult{
                .paths = result_paths,
                .match_count = 1,
                .allocator = allocator,
                .owns_paths = true, // NOCHECK allocates the pattern
            };
        }

        // Handle no matches
        if (matches.items.len == 0) {
            const empty: [][]const u8 = &[_][]const u8{};
            return GlobResult{
                .paths = empty,
                .match_count = 0,
                .allocator = allocator,
                .owns_paths = false,
            };
        }

        // Transfer ownership to result
        const result_paths = try matches.toOwnedSlice();
        return GlobResult{
            .paths = result_paths,
            .match_count = result_paths.len,
            .allocator = allocator,
            .owns_paths = false, // References to input paths
        };
    }

    // OPTIMIZATION #2: Suffix pattern fast path (*.ext only, not **/*.ext)
    // Detect patterns like "*.txt" and use SIMD suffix matching
    // Note: We don't optimize **/*.ext because it requires hidden file filtering
    const is_simple_suffix = pattern.len > 2 and pattern[0] == '*' and pattern[1] != '*' and
        mem.indexOf(u8, pattern[1..], "*") == null and
        mem.indexOf(u8, pattern[1..], "?") == null and
        mem.indexOf(u8, pattern[1..], "[") == null and
        mem.indexOf(u8, pattern[1..], "/") == null; // No directory separators

    if (is_simple_suffix) {
        const suffix = pattern[1..];
        const simdSuffixMatch = glob_libc.simdSuffixMatch;

        // Single pass: collect matches directly
        var matches = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer matches.deinit();

        for (paths) |path| {
            if (simdSuffixMatch(path, suffix)) {
                try matches.append(path);
            }
        }

        // Handle NOCHECK
        if (matches.items.len == 0 and flags & GLOB_NOCHECK != 0) {
            var result_paths = try allocator.alloc([]const u8, 1);
            result_paths[0] = try allocator.dupe(u8, pattern);
            return GlobResult{
                .paths = result_paths,
                .match_count = 1,
                .allocator = allocator,
                .owns_paths = true, // NOCHECK allocates the pattern
            };
        }

        // Handle no matches
        if (matches.items.len == 0) {
            const empty: [][]const u8 = &[_][]const u8{};
            return GlobResult{
                .paths = empty,
                .match_count = 0,
                .allocator = allocator,
                .owns_paths = false,
            };
        }

        const result_paths = try matches.toOwnedSlice();

        // Sort unless NOSORT
        if (flags & GLOB_NOSORT == 0) {
            mem.sort([]const u8, result_paths, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
        }

        return GlobResult{
            .paths = result_paths,
            .match_count = result_paths.len,
            .allocator = allocator,
            .owns_paths = false, // References to input paths
        };
    }

    // Parse pattern once
    var pattern_segments = try splitPatternByDoublestar(allocator, pattern);
    defer pattern_segments.deinit();

    // Single pass: collect matches directly
    var matches = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer matches.deinit();

    for (paths) |path| {
        if (try matchSinglePath(&pattern_segments, path, flags)) {
            try matches.append(path);
        }
    }

    // Handle NOCHECK
    if (matches.items.len == 0 and flags & GLOB_NOCHECK != 0) {
        var result_paths = try allocator.alloc([]const u8, 1);
        result_paths[0] = try allocator.dupe(u8, pattern);
        return GlobResult{
            .paths = result_paths,
            .match_count = 1,
            .allocator = allocator,
            .owns_paths = true, // NOCHECK allocates the pattern
        };
    }

    // Handle no matches
    if (matches.items.len == 0) {
        const empty: [][]const u8 = &[_][]const u8{};
        return GlobResult{
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

    return GlobResult{
        .paths = result_paths,
        .match_count = result_paths.len,
        .allocator = allocator,
        .owns_paths = false, // References to input paths
    };
}
