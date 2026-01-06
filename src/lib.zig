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

pub const glob = @import("glob");
pub const GlobResults = glob.GlobResults;
pub const GlobError = glob.GlobError;
pub const glob_t = glob.glob_t;
pub const analyzePattern = glob.analyzePattern;
pub const simdFindChar = glob.simdFindChar;
pub const hasWildcardsSIMD = glob.hasWildcardsSIMD;

pub const GLOB_APPEND = glob.GLOB_APPEND;
pub const GLOB_DOOFFS = glob.GLOB_DOOFFS;
pub const GLOB_ERR = glob.GLOB_ERR;
pub const GLOB_MARK = glob.GLOB_MARK;
pub const GLOB_NOCHECK = glob.GLOB_NOCHECK;
pub const GLOB_NOSORT = glob.GLOB_NOSORT;
pub const GLOB_NOESCAPE = glob.GLOB_NOESCAPE;
pub const GLOB_MAGCHAR = glob.GLOB_MAGCHAR;
pub const GLOB_NOMAGIC = glob.GLOB_NOMAGIC;
pub const GLOB_TILDE = glob.GLOB_TILDE;
pub const GLOB_BRACE = glob.GLOB_BRACE;
pub const GLOB_PERIOD = glob.GLOB_PERIOD;
pub const GLOB_ONLYDIR = glob.GLOB_ONLYDIR;
pub const GLOB_TILDE_CHECK = glob.GLOB_TILDE_CHECK;
pub const GLOB_NOSPACE = glob.GLOB_NOSPACE;
pub const GLOB_ABORTED = glob.GLOB_ABORTED;
pub const GLOB_NOMATCH = glob.GLOB_NOMATCH;

/// Perform file system walking and collect matching results to GlobResults
///
/// Example:
/// ```zig
/// if (try glob.match(allocator, "**/*.zig", 0)) |*result| {
///     defer result.deinit();
///     for (result.paths) |path| {
///         std.debug.print("{s}\n", .{path});
///     }
/// } else {
///     std.debug.print("No matches found\n", .{});
/// }
/// ```
pub fn match(allocator: std.mem.Allocator, pattern: []const u8, flags: u32) !?GlobResults {
    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);

    var pglob: glob_t = undefined;
    const opt_result = try glob.glob(allocator, pattern_z.ptr, @intCast(flags), null, &pglob);

    if (opt_result) |_| {
        // Matches found
        var paths = try allocator.alloc([]const u8, pglob.gl_pathc);
        errdefer allocator.free(paths);

        var i: usize = 0;
        while (i < pglob.gl_pathc) : (i += 1) {
            const c_path = pglob.gl_pathv[i];
            // Zero-copy: wrap the C pointer as a Zig slice using cached length
            const path_len = pglob.gl_pathlen[i];
            paths[i] = c_path[0..path_len];
        }

        return GlobResults{
            .paths = paths,
            .match_count = pglob.gl_pathc,
            .allocator = allocator,
            .pglob = pglob, // Store full glob_t for proper cleanup
        };
    } else {
        // No matches (null return)
        if (flags & GLOB_NOCHECK != 0) {
            // Return the pattern itself
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
/// Example:
/// ```zig
/// const paths = [_][]const u8{
///     "/users/alice/code/main.c",
///     "/users/alice/code/src/utils.c",
///     "/users/bob/docs/readme.md",
/// };
///
/// const result = try simdglob.matchPaths(allocator, "/users/**/code/*.c", &paths, 0);
/// defer result.deinit();
///
/// for (result.paths) |path| {
///     std.debug.print("Match: {s}\n", .{path});
/// }
/// ```
///
/// Supported flags:
/// - GLOB_NOSORT: Don't sort results
/// - GLOB_NOCHECK: Return pattern itself if no matches
/// - GLOB_PERIOD: Allow wildcards to match hidden files (starting with '.')
/// - GLOB_NOESCAPE: Treat backslashes as literal characters
///
/// Requirements:
/// - Input paths MUST be normalized (no consecutive slashes like //)
/// - Paths from filesystem operations are typically already normalized
pub fn matchPaths(allocator: std.mem.Allocator, pattern: []const u8, paths: []const []const u8, flags: u32) !GlobResults {
    return glob.internalMatchPaths(allocator, pattern, paths, flags);
}

test {
    // Import all tests from glob module
    std.testing.refAllDecls(@This());
}
