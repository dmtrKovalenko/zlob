const std = @import("std");
const mem = std.mem;

const glob = @import("zlob.zig");
const compiled_pattern = @import("compiled_pattern.zig");

const fnmatch_mod = glob.fnmatch;
const splitPathComponentsNormalized = compiled_pattern.splitPathComponentsNormalized;

/// Simple glob pattern matching with `**` support — no allocation required.
/// Lightweight alternative to `compiled_pattern.matchSinglePath` for cases
/// that don't need `ZLOB_PERIOD` handling or pre-computed pattern contexts.
///
/// Note: `**` is always treated as recursive doublestar here (gitignore
/// semantics). The full matcher's `ZLOB_DOUBLESTAR_RECURSIVE`-gated
/// behaviour lives in `compiled_pattern.zig`.
///
/// Supports:
/// - `*` matches any characters except `/`
/// - `?` matches exactly one character except `/`
/// - `[abc]` matches one character from the set
/// - `**` matches zero or more directories
pub fn matchGlobSimple(pattern: []const u8, path: []const u8, flags: glob.ZlobFlags) bool {
    if (mem.indexOf(u8, pattern, "**") == null) {
        return fnmatch_mod.fnmatch(pattern, path, flags);
    }

    var pat_segments_buf: [32][]const u8 = undefined;
    var path_segments_buf: [compiled_pattern.MAX_PATH_COMPONENTS][]const u8 = undefined;

    const pat_segments = splitPathComponentsNormalized(pattern, &pat_segments_buf) orelse return false;
    const path_segments = splitPathComponentsNormalized(path, &path_segments_buf) orelse return false;

    return matchSegmentsSimple(pat_segments, path_segments, 0, 0);
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

        if (current_pattern.len == 2 and current_pattern[0] == '*' and current_pattern[1] == '*') {
            if (pat_idx + 1 >= pattern_segments.len) {
                return true;
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
