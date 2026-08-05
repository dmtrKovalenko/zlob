const std = @import("std");
const glob = @import("zlob.zig");
const compiled_pattern = @import("compiled_pattern.zig");

const mem = std.mem;
const fnmatch_mod = glob.fnmatch;
const splitPathComponentsNormalized = compiled_pattern.splitPathComponentsNormalized;

/// Match pre-split pattern segments against a path that still needs splitting.
pub fn matchGlobSimplePresplit(pat_segments: [][]const u8, path: []const u8) bool {
    var path_segments_buf: [compiled_pattern.MAX_PATH_COMPONENTS][]const u8 = undefined;
    if (splitPathComponentsNormalized(path, &path_segments_buf)) |path_segments| {
        return matchSegmentsSimple(pat_segments, path_segments, 0, 0);
    }

    // Deep paths exceed the fixed stack buffer. Match directly against the raw
    // path instead of turning a valid pattern into a false negative or
    // allocating on this hot path.
    return matchSegmentsStreaming(pat_segments, path, 0, 0);
}

/// Match pre-split pattern segments against pre-split path segments.
pub fn matchGlobSimplePresplitWithPath(
    pat_segments: [][]const u8,
    path_segments: [][]const u8,
) bool {
    return matchSegmentsSimple(pat_segments, path_segments, 0, 0);
}

/// True when a pattern segment acts as a recursive `**`
/// (git matcher treats double stars as anything that is more than 2 stars while glibc not)
inline fn isDoubleStarSegment(seg: []const u8) bool {
    return seg.len >= 2 and mem.allEqual(u8, seg, '*');
}

const PathSegment = struct {
    text: []const u8,
    next_offset: usize,
};

inline fn nextPathSegment(path: []const u8, initial_offset: usize) ?PathSegment {
    var start = initial_offset;
    while (start < path.len and glob.isPathSep(path[start])) : (start += 1) {}
    if (start == path.len) return null;

    var end = start;
    while (end < path.len and !glob.isPathSep(path[end])) : (end += 1) {}
    return .{ .text = path[start..end], .next_offset = end };
}

/// Unbounded fallback for paths that do not fit the fixed pre-split buffer.
/// Pattern segments are already compiled; only the path is consumed lazily.
fn matchSegmentsStreaming(
    pattern_segments: []const []const u8,
    path: []const u8,
    initial_pat_idx: usize,
    initial_path_offset: usize,
) bool {
    var pat_idx = initial_pat_idx;
    var path_offset = initial_path_offset;

    while (true) {
        if (pat_idx >= pattern_segments.len) {
            return nextPathSegment(path, path_offset) == null;
        }

        const current_pattern = pattern_segments[pat_idx];
        if (isDoubleStarSegment(current_pattern)) {
            if (pat_idx + 1 >= pattern_segments.len) {
                return nextPathSegment(path, path_offset) != null;
            }

            if (matchSegmentsStreaming(pattern_segments, path, pat_idx + 1, path_offset)) {
                return true;
            }

            var scan_offset = path_offset;
            while (nextPathSegment(path, scan_offset)) |segment| {
                scan_offset = segment.next_offset;
                if (matchSegmentsStreaming(pattern_segments, path, pat_idx + 1, scan_offset)) {
                    return true;
                }
            }
            return false;
        }

        const segment = nextPathSegment(path, path_offset) orelse return false;
        if (!fnmatch_mod.fnmatch(current_pattern, segment.text, .{})) return false;

        pat_idx += 1;
        path_offset = segment.next_offset;
    }
}

/// Core recursive segment matching for `**` patterns (no allocation, no PERIOD).
fn matchSegmentsSimple(
    pattern_segments: []const []const u8,
    path_segments: []const []const u8,
    initial_pat_idx: usize,
    initial_path_idx: usize,
) bool {
    var pat_idx = initial_pat_idx;
    var path_idx = initial_path_idx;

    while (true) {
        if (pat_idx >= pattern_segments.len) {
            return path_idx >= path_segments.len;
        }

        const current_pattern = pattern_segments[pat_idx];

        if (isDoubleStarSegment(current_pattern)) {
            if (pat_idx + 1 >= pattern_segments.len) {
                // A trailing `**` means "everything below", so it has to consume
                // at least one segment: git matches `a/**` against `a/f.txt` but
                // not against `a` itself.
                return path_idx < path_segments.len;
            }

            if (matchSegmentsSimple(pattern_segments, path_segments, pat_idx + 1, path_idx)) {
                return true;
            }

            var skip: usize = 1;
            while (path_idx + skip <= path_segments.len) : (skip += 1) {
                if (matchSegmentsSimple(pattern_segments, path_segments, pat_idx + 1, path_idx + skip)) {
                    return true;
                }
            }
            return false;
        }

        if (path_idx >= path_segments.len) {
            return false;
        }

        if (!fnmatch_mod.fnmatch(current_pattern, path_segments[path_idx], .{})) {
            return false;
        }

        pat_idx += 1;
        path_idx += 1;
    }
}
