//! SIMD-accelerated glob pattern matching library
//!
//! This library provides high-performance file pattern matching (globbing) using
//! SIMD optimizations for improved performance on pattern matching operations.
//!
//! Based on the OpenBSD glob implementation with modern SIMD enhancements.
//!
//! This is the pure Zig API. For C-compatible API, see c_lib.zig which provides
//! POSIX glob() and globfree() functions with a C header (include/zlob.h).

const std = @import("std");

const glob_impl = @import("zlob");

pub const GlobResults = glob_impl.GlobResults;
pub const GlobError = glob_impl.GlobError;
pub const zlob_t = glob_impl.zlob_t;
pub const analyzePattern = glob_impl.analyzePattern;
pub const simdFindChar = glob_impl.simdFindChar;
pub const hasWildcardsSIMD = glob_impl.hasWildcardsSIMD;

/// ZlobFlags is a packed struct for type-safe flag handling.
/// Use this instead of raw integer constants for better ergonomics.
pub const ZlobFlags = glob_impl.ZlobFlags;

/// Internal glob module - exposed for tests that need low-level access.
/// Not part of the stable public API.
pub const glob = glob_impl;

// Legacy integer flag constants (for backward compatibility and C interop)
pub const ZLOB_APPEND = glob_impl.ZLOB_APPEND;
pub const ZLOB_DOOFFS = glob_impl.ZLOB_DOOFFS;
pub const ZLOB_ERR = glob_impl.ZLOB_ERR;
pub const ZLOB_MARK = glob_impl.ZLOB_MARK;
pub const ZLOB_NOCHECK = glob_impl.ZLOB_NOCHECK;
pub const ZLOB_NOSORT = glob_impl.ZLOB_NOSORT;
pub const ZLOB_NOESCAPE = glob_impl.ZLOB_NOESCAPE;
pub const ZLOB_MAGCHAR = glob_impl.ZLOB_MAGCHAR;
pub const ZLOB_NOMAGIC = glob_impl.ZLOB_NOMAGIC;
pub const ZLOB_TILDE = glob_impl.ZLOB_TILDE;
pub const ZLOB_BRACE = glob_impl.ZLOB_BRACE;
pub const ZLOB_PERIOD = glob_impl.ZLOB_PERIOD;
pub const ZLOB_ONLYDIR = glob_impl.ZLOB_ONLYDIR;
pub const ZLOB_TILDE_CHECK = glob_impl.ZLOB_TILDE_CHECK;
pub const ZLOB_GITIGNORE = glob_impl.ZLOB_GITIGNORE;
pub const ZLOB_DOUBLESTAR_RECURSIVE = glob_impl.ZLOB_DOUBLESTAR_RECURSIVE;
pub const ZLOB_RECOMMENDED = glob_impl.ZLOB_RECOMMENDED;
pub const ZLOB_NOSPACE = glob_impl.ZLOB_NOSPACE;
pub const ZLOB_ABORTED = glob_impl.ZLOB_ABORTED;
pub const ZLOB_NOMATCH = glob_impl.ZLOB_NOMATCH;

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
    return glob_impl.path_matcher.matchPaths(allocator, pattern, paths, zflags.toU32());
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
