//! In-memory path matching with recursive ** support
//! This module provides glob pattern matching against arrays of path strings
//! without any filesystem I/O operations.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const glob = @import("zlob.zig");
const suffix_match = @import("suffix_match.zig");
const brace_optimizer = @import("brace_optimizer.zig");

const hasWildcardsBasic = glob.hasWildcardsBasic;
const indexOfCharSIMD = glob.indexOfCharSIMD;
const lastIndexOfCharSIMD = glob.lastIndexOfCharSIMD;
const PatternContext = glob.PatternContext;
const containsExtglob = glob.containsExtglob;
const fnmatch_mod = glob.fnmatch;

const GlobResults = glob.GlobResults;
const ZlobFlags = glob.ZlobFlags;

const PatternSegments = struct {
    segments: [][]const u8,
    contexts: []PatternContext, // Pre-computed contexts to avoid redundant hasWildcardsBasic calls
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

const MultiSuffixMatcherResult = struct {
    matcher: suffix_match.UnifiedMultiSuffix,
    all_simple_suffixes: bool,
};

/// Try to build a unified multi-suffix matcher from expanded patterns.
/// Returns a matcher if ALL patterns are simple suffix patterns (*.ext).
fn tryBuildMultiSuffixMatcher(expanded_patterns: []const []const u8) MultiSuffixMatcherResult {
    var result = MultiSuffixMatcherResult{
        .matcher = suffix_match.UnifiedMultiSuffix{},
        .all_simple_suffixes = true,
    };

    for (expanded_patterns) |pattern| {
        // Check if pattern is *.ext (simple suffix)
        if (pattern.len < 2 or pattern[0] != '*') {
            result.all_simple_suffixes = false;
            return result;
        }

        // Check there are no other wildcards or path separators
        const suffix = pattern[1..];
        if (hasWildcardsBasic(suffix) or mem.indexOfScalar(u8, suffix, '/') != null) {
            result.all_simple_suffixes = false;
            return result;
        }

        // Suffix must be 1-4 bytes to fit in SIMD matcher
        if (suffix.len < 1 or suffix.len > 4) {
            result.all_simple_suffixes = false;
            return result;
        }

        // Add to matcher using MaskedSuffix.init
        if (result.matcher.count < suffix_match.UnifiedMultiSuffix.MAX_SUFFIXES) {
            result.matcher.suffixes[result.matcher.count] = suffix_match.MaskedSuffix.init(suffix);
            result.matcher.count += 1;
            if (suffix.len < result.matcher.min_suffix_len) {
                result.matcher.min_suffix_len = @intCast(suffix.len);
            }
        } else {
            result.all_simple_suffixes = false;
            return result;
        }
    }

    if (result.matcher.min_suffix_len == 255) {
        result.matcher.min_suffix_len = 1;
    }

    return result;
}

/// Result of trying to build a recursive suffix matcher
const RecursiveSuffixMatcherResult = struct {
    matcher: suffix_match.UnifiedMultiSuffix,
    all_recursive_suffix: bool,
};

/// Try to build a multi-suffix matcher for **/*.ext style patterns
fn tryBuildRecursiveSuffixMatcher(expanded_patterns: []const []const u8) RecursiveSuffixMatcherResult {
    var result = RecursiveSuffixMatcherResult{
        .matcher = suffix_match.UnifiedMultiSuffix{},
        .all_recursive_suffix = true,
    };

    for (expanded_patterns) |pattern| {
        // Check if pattern is **/*.ext or just *.ext (both work for suffix matching)
        var suffix_pattern = pattern;

        // Strip leading **/ if present
        if (mem.startsWith(u8, pattern, "**/")) {
            suffix_pattern = pattern[3..];
        }

        // Now check if remaining is *.ext
        if (suffix_pattern.len < 2 or suffix_pattern[0] != '*') {
            result.all_recursive_suffix = false;
            return result;
        }

        const suffix = suffix_pattern[1..];
        if (hasWildcardsBasic(suffix) or mem.indexOfScalar(u8, suffix, '/') != null) {
            result.all_recursive_suffix = false;
            return result;
        }

        if (suffix.len < 1 or suffix.len > 4) {
            result.all_recursive_suffix = false;
            return result;
        }

        // Add to matcher using MaskedSuffix.init
        if (result.matcher.count < suffix_match.UnifiedMultiSuffix.MAX_SUFFIXES) {
            result.matcher.suffixes[result.matcher.count] = suffix_match.MaskedSuffix.init(suffix);
            result.matcher.count += 1;
            if (suffix.len < result.matcher.min_suffix_len) {
                result.matcher.min_suffix_len = @intCast(suffix.len);
            }
        } else {
            result.all_recursive_suffix = false;
            return result;
        }
    }

    if (result.matcher.min_suffix_len == 255) {
        result.matcher.min_suffix_len = 1;
    }

    return result;
}

/// Get the basename (filename) from a path
fn getBasename(path: []const u8) []const u8 {
    if (lastIndexOfCharSIMD(path, '/')) |last_slash| {
        return path[last_slash + 1 ..];
    }
    return path;
}

/// Finalize brace match results - handle sorting and empty results
fn finalizeBraceMatches(
    allocator: Allocator,
    matches: *std.array_list.AlignedManaged([]const u8, null),
    pattern: []const u8,
    flags: ZlobFlags,
) !GlobResults {
    // Handle no matches
    if (matches.items.len == 0) {
        if (flags.nocheck) {
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

    const result_paths = try matches.toOwnedSlice();

    // Sort if needed
    if (!flags.nosort) {
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
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (path.len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const slash_vec: Vec = @splat('/');
        var idx: usize = 0;
        var start: usize = 0;
        var i: usize = 0;

        // process vec_len bytes at a time
        while (i + vec_len <= path.len) : (i += vec_len) {
            const chunk: Vec = path[i..][0..vec_len].*;
            var mask = @as(MaskInt, @bitCast(chunk == slash_vec));
            while (mask != 0) {
                const offset = @ctz(mask);
                const pos = i + offset;
                if (pos > start and idx < buffer.len) {
                    buffer[idx] = path[start..pos];
                    idx += 1;
                }
                start = pos + 1;
                mask &= mask - 1; // Clear lowest set bit
            }
        }

        while (i < path.len) : (i += 1) {
            if (path[i] == '/') {
                if (i > start and idx < buffer.len) {
                    buffer[idx] = path[start..i];
                    idx += 1;
                }
                start = i + 1;
            }
        }

        if (start < path.len and idx < buffer.len) {
            buffer[idx] = path[start..];
            idx += 1;
        }

        return buffer[0..idx];
    }

    // Fallback for short paths
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
        return fnmatch_mod.fnmatch(pattern, path, .{});
    }

    // Split pattern and path into segments using stack buffers
    var pat_segments_buf: [32][]const u8 = undefined;
    var path_segments_buf: [64][]const u8 = undefined;

    const pat_segments = splitPathComponentsFast(pattern, &pat_segments_buf);
    const path_segments = splitPathComponentsFast(path, &path_segments_buf);

    return matchSegmentsSimple(pat_segments, path_segments, 0, 0);
}

/// Core recursive segment matching for ** patterns (no allocation, no ZLOB_PERIOD)
/// Optimized version with early suffix rejection and tail-call-friendly structure
fn matchSegmentsSimple(
    pattern_segments: []const []const u8,
    path_segments: []const []const u8,
    initial_pat_idx: usize,
    initial_path_idx: usize,
) bool {
    var pat_idx = initial_pat_idx;
    var path_idx = initial_path_idx;

    while (true) {
        // Base case: pattern exhausted
        if (pat_idx >= pattern_segments.len) {
            return path_idx >= path_segments.len;
        }

        const current_pattern = pattern_segments[pat_idx];

        // Handle ** (matches zero or more path segments)
        if (current_pattern.len == 2 and current_pattern[0] == '*' and current_pattern[1] == '*') {
            // Optimization: if this is the last pattern segment, ** matches everything remaining
            if (pat_idx + 1 >= pattern_segments.len) {
                return true;
            }

            // Try matching ** with zero segments first
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
        if (!fnmatch_mod.fnmatch(current_pattern, path_segments[path_idx], .{})) {
            return false;
        }

        // Tail-call optimization: continue iteratively instead of recursing
        pat_idx += 1;
        path_idx += 1;
    }
}

pub fn extractSuffixFromPattern(pattern: []const u8) struct { suffix: ?[]const u8 } {
    const last_slash = lastIndexOfCharSIMD(pattern, '/');
    const last_component = if (last_slash) |pos| pattern[pos + 1 ..] else pattern;

    if (last_component.len < 2) return .{ .suffix = null };
    if (last_component[0] != '*') return .{ .suffix = null };

    if (last_component.len >= 2 and last_component[1] == '*') return .{ .suffix = null };

    const after_star = last_component[1..];

    // Check for wildcards OR extglob patterns
    if (hasWildcardsBasic(after_star)) return .{ .suffix = null };
    if (containsExtglob(after_star)) return .{ .suffix = null };

    if (after_star.len == 0) return .{ .suffix = null };

    return .{ .suffix = after_star };
}

fn shouldSkipHidden(path_component: []const u8, pattern: []const u8, flags: ZlobFlags) bool {
    if (path_component.len == 0 or path_component[0] != '.') {
        return false;
    }

    if (mem.eql(u8, path_component, ".") or mem.eql(u8, path_component, "..")) {
        return true;
    }

    if (flags.period) {
        return false;
    }

    if (pattern.len > 0 and pattern[0] == '.') {
        return false;
    }

    return true;
}

/// Helper function to match a pattern segment against a path component
/// Uses extglob-aware matching when enable_extglob is true
inline fn matchSegment(pat_seg: []const u8, path_comp: []const u8, ctx: *const PatternContext, enable_extglob: bool) bool {
    if (enable_extglob and containsExtglob(pat_seg)) {
        return fnmatch_mod.fnmatch(pat_seg, path_comp, .{ .extglob = true });
    }
    return fnmatch_mod.fnmatchWithContext(ctx, path_comp, .{});
}

/// Optimized iterative segment matching using a single-row DP approach
/// This avoids deep recursion which was causing 34% of CPU time
fn matchPathSegments(
    path_components: [][]const u8,
    pattern_segments: [][]const u8,
    pattern_contexts: []PatternContext,
    initial_segment_idx: usize,
    initial_path_idx: usize,
    flags: ZlobFlags,
) bool {
    const pat_len = pattern_segments.len - initial_segment_idx;
    const path_len = path_components.len - initial_path_idx;
    const enable_extglob = flags.extglob;

    if (pat_len == 0) return path_len == 0;

    // Use stack-allocated DP array for small paths (most common case)
    var dp_storage: [65]bool = undefined;
    const dp = dp_storage[0 .. path_len + 1];
    @memset(dp, false);
    dp[0] = true; // Empty pattern matches empty path

    // Process each pattern segment
    var seg_i: usize = 0;
    while (seg_i < pat_len) : (seg_i += 1) {
        const pat_seg = pattern_segments[initial_segment_idx + seg_i];
        const is_doublestar = pat_seg.len == 2 and pat_seg[0] == '*' and pat_seg[1] == '*';

        if (is_doublestar) {
            // ** can match zero or more path segments
            // dp[j] = dp[j] OR dp[j-1] OR dp[j-2] OR ...
            // This is equivalent to: once we have a true, all subsequent positions are true
            // (unless blocked by hidden files)
            var saw_true = false;
            var j: usize = 0;
            while (j <= path_len) : (j += 1) {
                if (dp[j]) {
                    saw_true = true;
                }
                if (saw_true) {
                    // Check if path component at j-1 is hidden (would block **)
                    if (j > 0) {
                        const comp_idx = initial_path_idx + j - 1;
                        if (comp_idx < path_components.len) {
                            if (shouldSkipHidden(path_components[comp_idx], "", flags)) {
                                saw_true = false; // Reset - can't cross hidden boundary
                            }
                        }
                    }
                    dp[j] = saw_true;
                } else {
                    dp[j] = false;
                }
            }
        } else {
            // Regular segment - must match exactly one path component
            // Process backwards to avoid overwriting values we need
            var j: usize = path_len;
            while (j > 0) : (j -= 1) {
                const path_comp_idx = initial_path_idx + j - 1;
                const path_comp = path_components[path_comp_idx];

                // Check: dp[j-1] was true AND current segment matches path_comp
                if (dp[j - 1]) {
                    if (shouldSkipHidden(path_comp, pat_seg, flags)) {
                        dp[j] = false;
                    } else if (matchSegment(pat_seg, path_comp, &pattern_contexts[initial_segment_idx + seg_i], enable_extglob)) {
                        dp[j] = true;
                    } else {
                        dp[j] = false;
                    }
                } else {
                    dp[j] = false;
                }
            }
            dp[0] = false; // Can't match non-empty pattern with empty path (except **)
        }
    }

    return dp[path_len];
}

fn matchSinglePath(
    pattern_segments: *const PatternSegments,
    path: []const u8,
    flags: ZlobFlags,
) !bool {
    const enable_extglob = flags.extglob;
    const enable_escapes = !flags.noescape; // NOESCAPE means escapes are disabled

    if (!pattern_segments.has_doublestar) {
        if (enable_extglob and containsExtglob(pattern_segments.original_pattern)) {
            return fnmatch_mod.fnmatch(pattern_segments.original_pattern, path, .{ .extglob = true });
        }
        return fnmatch_mod.fnmatch(pattern_segments.original_pattern, path, .{ .noescape = !enable_escapes });
    }

    var component_buffer: [64][]const u8 = undefined;
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
    raw_pattern: []const u8,
    paths: []const []const u8,
    flags: ZlobFlags,
) !GlobResults {
    // Strip leading "./" from pattern - paths are relative to the current directory by default
    const pattern = if (raw_pattern.len >= 2 and raw_pattern[0] == '.' and raw_pattern[1] == '/')
        raw_pattern[2..]
    else
        raw_pattern;
    return matchPathsImpl(allocator, pattern, paths, 0, flags);
}

/// Match glob pattern against an array of absolute paths, treating each path as relative
/// to the given base directory.
///
/// The `base_path` may or may not end with a trailing `/` — the offset into each path
/// is computed automatically. If the pattern starts with `./`, it is interpreted as
/// relative to `base_path` (i.e. stripped, since matching already operates relative to
/// the base).
///
/// Matched results contain the **original full paths** as submitted by the caller.
///
/// Example:
///   base_path: "/home/user/project"
///   Paths:  ["/home/user/project/src/main.c", "/home/user/project/lib/utils.c"]
///   Pattern: "src/*.c"
///   → matches ["/home/user/project/src/main.c"]
pub fn matchPathsAt(
    allocator: Allocator,
    base_path: []const u8,
    raw_pattern: []const u8,
    paths: []const []const u8,
    flags: ZlobFlags,
) !GlobResults {
    // Compute offset: for empty base_path, offset is 0.
    // Otherwise, base_path length plus 1 for the separator if it doesn't already
    // end with '/'.
    const path_offset = if (base_path.len == 0)
        0
    else if (base_path[base_path.len - 1] == '/')
        base_path.len
    else
        base_path.len + 1;

    // we can afely strip the path becuase if the path_offset passed to the impl function would be
    // larger than the provided path it won't be matched anyway
    const pattern = if (raw_pattern.len >= 2 and raw_pattern[0] == '.' and raw_pattern[1] == '/')
        raw_pattern[2..]
    else
        raw_pattern;

    return matchPathsImpl(allocator, pattern, paths, path_offset, flags);
}

fn matchPathsImpl(
    allocator: Allocator,
    pattern: []const u8,
    paths: []const []const u8,
    path_offset: usize,
    flags: ZlobFlags,
) !GlobResults {
    // Handle ZLOB_BRACE - expand pattern and match against any alternative
    if (flags.brace) {
        const expanded_patterns = try brace_optimizer.expandBraces(allocator, pattern);
        defer {
            for (expanded_patterns) |p| {
                allocator.free(p);
            }
            allocator.free(expanded_patterns);
        }

        // If only one pattern after expansion (no actual braces), just match it directly
        if (expanded_patterns.len == 1) {
            return matchPathsImpl(allocator, expanded_patterns[0], paths, path_offset, flags.without(.{ .brace = true }));
        }

        // OPTIMIZATION: Check if all expanded patterns are simple suffix patterns (*.ext)
        // If so, use the unified multi-suffix SIMD matcher for a single-pass match
        const multi_suffix_result = tryBuildMultiSuffixMatcher(expanded_patterns);
        if (multi_suffix_result.all_simple_suffixes and multi_suffix_result.matcher.count > 0) {
            var matches = std.array_list.AlignedManaged([]const u8, null).init(allocator);
            defer matches.deinit();

            // Fast path: use unified multi-suffix SIMD matching
            for (paths) |path| {
                if (path.len < path_offset) continue;
                // For simple suffix patterns, match against the full path (basename check)
                const basename = getBasename(path);
                if (multi_suffix_result.matcher.matchAny(basename)) {
                    try matches.append(path);
                }
            }

            return finalizeBraceMatches(allocator, &matches, pattern, flags);
        }

        // Check if patterns are **/*.ext style (recursive with suffix)
        const recursive_suffix_result = tryBuildRecursiveSuffixMatcher(expanded_patterns);
        if (recursive_suffix_result.all_recursive_suffix and recursive_suffix_result.matcher.count > 0) {
            var matches = std.array_list.AlignedManaged([]const u8, null).init(allocator);
            defer matches.deinit();

            // Fast path: use unified multi-suffix SIMD matching on basename
            for (paths) |path| {
                if (path.len < path_offset) continue;
                const basename = getBasename(path);
                if (recursive_suffix_result.matcher.matchAny(basename)) {
                    try matches.append(path);
                }
            }

            return finalizeBraceMatches(allocator, &matches, pattern, flags);
        }

        // Pre-compute pattern segments for each alternative
        var pattern_segments_list = try allocator.alloc(PatternSegments, expanded_patterns.len);
        defer {
            for (pattern_segments_list) |*ps| ps.deinit();
            allocator.free(pattern_segments_list);
        }
        for (expanded_patterns, 0..) |exp_pattern, i| {
            pattern_segments_list[i] = try splitPatternByDoublestar(allocator, exp_pattern);
        }

        var matches = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer matches.deinit();

        const inner_flags = flags.without(.{ .brace = true, .nocheck = true });

        // Single pass through paths - check if ANY alternative matches
        for (paths) |path| {
            if (path.len < path_offset) continue;

            const rel_path = path[path_offset..];
            for (pattern_segments_list) |*ps| {
                if (try matchSinglePath(ps, rel_path, inner_flags)) {
                    try matches.append(path);
                    break; // Path matched, no need to check other alternatives
                }
            }
        }

        return finalizeBraceMatches(allocator, &matches, pattern, flags);
    }

    if (paths.len == 0) {
        if (flags.nocheck) {
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
    // Note: If extglob is enabled, we need to check for extglob patterns too
    const has_extglob = flags.extglob and containsExtglob(pattern);
    if (!hasWildcardsBasic(pattern) and !has_extglob) {
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
            if (path.len < path_offset) continue;

            const rel_path = path[path_offset..];
            if (mem.eql(u8, rel_path, norm_pattern)) {
                try matches.append(path);
            }
        }

        if (matches.items.len == 0 and flags.nocheck) {
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
        indexOfCharSIMD(pattern, '/') == null and
        pattern_segments.segments.len == 1 and
        !mem.eql(u8, pattern_segments.segments[0], "**");

    if (is_simple_suffix_only) {
        const suffix = suffix_info.suffix.?;
        if (suffix.len <= 4) {
            try suffix_match.SingleSuffixMatcher.init(suffix).matchPathsBatched(paths, &matches);
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
            try suffix_match.SingleSuffixMatcher.init(suffix).matchPathsBatched(paths, &pre_filtered);

            for (pre_filtered.items) |path| {
                if (path.len < path_offset) continue;
                const rel_path = path[path_offset..];
                if (try matchSinglePath(&pattern_segments, rel_path, flags)) {
                    try matches.append(path);
                }
            }
        } else {
            const suffix_matcher = suffix_match.SuffixMatch.new(suffix);
            for (paths) |path| {
                if (path.len < path_offset) continue;
                const rel_path = path[path_offset..];
                if (suffix_matcher.match(path) and try matchSinglePath(&pattern_segments, rel_path, flags)) {
                    try matches.append(path);
                }
            }
        }
    } else {
        for (paths) |path| {
            if (path.len < path_offset) continue;
            const rel_path = path[path_offset..];
            if (try matchSinglePath(&pattern_segments, rel_path, flags)) {
                try matches.append(path);
            }
        }
    }

    if (matches.items.len == 0 and flags.nocheck) {
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

    if (!flags.nosort) {
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
