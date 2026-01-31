//! SIMD-accelerated glob pattern matching library
//!
//! This library provides high-performance file pattern matching (globbing) using
//! SIMD optimizations for improved performance on pattern matching operations.
//!
//! This is the pure Zig API. For C-compatible API, see c_lib.zig which provides
//! POSIX glob() and globfree() functions and C header (include/zlob.h).

const std = @import("std");
const glob = @import("zlob");

pub const GlobResults = glob.GlobResults;
pub const GlobError = glob.GlobError;
pub const zlob_t = glob.zlob_t;
pub const analyzePattern = glob.analyzePattern;
pub const simdFindChar = glob.simdFindChar;
pub const hasWildcardsSIMD = glob.hasWildcardsSIMD;
pub const ZlobFlags = glob.ZlobFlags;

// used mostloy by the tests
pub const ZLOB_APPEND = glob.ZLOB_APPEND;
pub const ZLOB_DOOFFS = glob.ZLOB_DOOFFS;
pub const ZLOB_ERR = glob.ZLOB_ERR;
pub const ZLOB_MARK = glob.ZLOB_MARK;
pub const ZLOB_NOCHECK = glob.ZLOB_NOCHECK;
pub const ZLOB_NOSORT = glob.ZLOB_NOSORT;
pub const ZLOB_NOESCAPE = glob.ZLOB_NOESCAPE;
pub const ZLOB_MAGCHAR = glob.ZLOB_MAGCHAR;
pub const ZLOB_NOMAGIC = glob.ZLOB_NOMAGIC;
pub const ZLOB_TILDE = glob.ZLOB_TILDE;
pub const ZLOB_BRACE = glob.ZLOB_BRACE;
pub const ZLOB_PERIOD = glob.ZLOB_PERIOD;
pub const ZLOB_ONLYDIR = glob.ZLOB_ONLYDIR;
pub const ZLOB_TILDE_CHECK = glob.ZLOB_TILDE_CHECK;
pub const ZLOB_GITIGNORE = glob.ZLOB_GITIGNORE;
pub const ZLOB_DOUBLESTAR_RECURSIVE = glob.ZLOB_DOUBLESTAR_RECURSIVE;
pub const ZLOB_EXTGLOB = glob.ZLOB_EXTGLOB;
pub const ZLOB_RECOMMENDED = glob.ZLOB_RECOMMENDED;
pub const ZLOB_NOSPACE = glob.ZLOB_NOSPACE;
pub const ZLOB_ABORTED = glob.ZLOB_ABORTED;
pub const ZLOB_NOMATCH = glob.ZLOB_NOMATCH;

/// Perform file system walking and collect matching results to GlobResults
///
/// Example with ZlobFlags (recommended):
/// ```zig
/// const flags = zlob.ZlobFlags{ .brace = true, .gitignore = true };
/// if (try zlob.match(allocator, "**/*.zig", flags)) |*result| {
///     defer result.deinit();
///     for (result.paths) |path| {
///         std.debug.print("{s}\n", .{path});
///     }
/// }
/// ```
///
/// Example with integer flags (legacy):
/// ```zig
/// if (try zlob.match(allocator, "**/*.zig", zlob.ZLOB_BRACE | zlob.ZLOB_GITIGNORE)) |*result| {
///     defer result.deinit();
///     for (result.paths) |path| {
///         std.debug.print("{s}\n", .{path});
///     }
/// }
/// ```
pub fn match(allocator: std.mem.Allocator, pattern: []const u8, flags_param: anytype) !?GlobResults {
    const zflags = flagsToZlobFlags(flags_param);
    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);

    var pzlob: zlob_t = undefined;
    const opt_result = try glob.glob(allocator, pattern_z.ptr, zflags.toInt(), null, &pzlob);

    if (opt_result) |_| {
        var paths = try allocator.alloc([]const u8, pzlob.gl_pathc);
        errdefer allocator.free(paths);

        var i: usize = 0;
        while (i < pzlob.gl_pathc) : (i += 1) {
            const c_path = pzlob.gl_pathv[i];
            const path_len = pzlob.gl_pathlen[i];
            paths[i] = c_path[0..path_len];
        }

        return GlobResults{
            .paths = paths,
            .match_count = pzlob.gl_pathc,
            .allocator = allocator,
            .pzlob = pzlob,
        };
    } else {
        if (zflags.nocheck) {
            var paths = try allocator.alloc([]const u8, 1);
            errdefer allocator.free(paths);
            paths[0] = try allocator.dupe(u8, pattern);
            return GlobResults{
                .paths = paths,
                .match_count = 1,
                .allocator = allocator,
            };
        }
        return null;
    }
}

/// Match glob pattern against array of paths with full ** recursive support
///
/// This function provides in-memory pattern matching against an array of path strings
/// WITHOUT any filesystem I/O. It properly handles recursive ** patterns that match
/// zero or more directory components.
///
/// Pattern examples:
/// - `**/*.c` - All .c files at any depth
/// - `/users/**/code/*.zig` - All .zig files in any 'code' directory under /users
/// - `src/**/test_*.zig` - All test files under src/
///
/// Example with ZlobFlags (recommended):
/// ```zig
/// const paths = [_][]const u8{
///     "/users/alice/code/main.c",
///     "/users/alice/code/src/utils.c",
///     "/users/bob/docs/readme.md",
/// };
///
/// const result = try zlob.matchPaths(allocator, "/users/**/code/*.c", &paths, .{});
/// defer result.deinit();
///
/// for (result.paths) |path| {
///     std.debug.print("Match: {s}\n", .{path});
/// }
/// ```
///
/// Supported flags:
/// - .nosort: Don't sort results
/// - .nocheck: Return pattern itself if no matches
/// - .period: Allow wildcards to match hidden files (starting with '.')
/// - .noescape: Treat backslashes as literal characters
///
/// Requirements:
/// - Input paths MUST be normalized (no consecutive slashes like //)
/// - Paths from filesystem operations are typically already normalized
pub fn matchPaths(allocator: std.mem.Allocator, pattern: []const u8, paths: []const []const u8, flags_param: anytype) !GlobResults {
    const zflags = flagsToZlobFlags(flags_param);
    return glob.path_matcher.matchPaths(allocator, pattern, paths, zflags.toU32());
}

/// Perform file system walking within a specified base directory and collect matching results.
///
/// This is similar to `match()` but operates relative to the given `base_path` instead of
/// the current working directory. The `base_path` must be an absolute path.
///
/// Example:
/// ```zig
/// // Find all .zig files under /home/user/project
/// if (try zlob.matchAt(allocator, "/home/user/project", "**/*.zig", .{ .brace = true })) |*result| {
///     defer result.deinit();
///     for (result.paths) |path| {
///         std.debug.print("{s}\n", .{path});
///     }
/// }
/// ```
///
/// Returns `error.Aborted` if `base_path` is not an absolute path (doesn't start with '/').
pub fn matchAt(allocator: std.mem.Allocator, base_path: []const u8, pattern: []const u8, flags_param: anytype) !?GlobResults {
    const zflags = flagsToZlobFlags(flags_param);
    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);

    var pzlob: zlob_t = undefined;
    const opt_result = try glob.globAt(allocator, base_path, pattern_z.ptr, zflags.toInt(), null, &pzlob);

    if (opt_result) |_| {
        var paths = try allocator.alloc([]const u8, pzlob.gl_pathc);
        errdefer allocator.free(paths);

        var i: usize = 0;
        while (i < pzlob.gl_pathc) : (i += 1) {
            const c_path = pzlob.gl_pathv[i];
            const path_len = pzlob.gl_pathlen[i];
            paths[i] = c_path[0..path_len];
        }

        return GlobResults{
            .paths = paths,
            .match_count = pzlob.gl_pathc,
            .allocator = allocator,
            .pzlob = pzlob,
        };
    } else {
        if (zflags.nocheck) {
            var paths = try allocator.alloc([]const u8, 1);
            errdefer allocator.free(paths);
            paths[0] = try allocator.dupe(u8, pattern);
            return GlobResults{
                .paths = paths,
                .match_count = 1,
                .allocator = allocator,
            };
        }
        return null;
    }
}

/// Convert any supported flags type to ZlobFlags.
/// Supports: ZlobFlags, u32, c_int, comptime_int, or struct literals like .{ .mark = true }
fn flagsToZlobFlags(flags_param: anytype) ZlobFlags {
    const T = @TypeOf(flags_param);
    if (T == ZlobFlags) {
        return flags_param;
    } else if (T == u32) {
        return ZlobFlags.fromU32(flags_param);
    } else if (T == c_int) {
        return ZlobFlags.fromInt(flags_param);
    } else if (T == comptime_int) {
        return ZlobFlags.fromU32(@intCast(flags_param));
    } else if (@typeInfo(T) == .@"struct") {
        // Handle anonymous struct literals like .{ .mark = true }
        const gf: ZlobFlags = flags_param;
        return gf;
    } else {
        @compileError("flags must be ZlobFlags, u32, c_int, or a struct literal");
    }
}
