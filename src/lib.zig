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

// Re-export the glob module (contains all Zig implementation)
pub const glob = @import("glob");

pub const GlobResults = glob.GlobResults;
pub const GlobError = glob.GlobError;
pub const glob_t = glob.glob_t;

// Re-export utility functions
pub const analyzePattern = glob.analyzePattern;

// Re-export SIMD functions for benchmarking
pub const simdFindChar = glob.simdFindChar;
pub const hasWildcardsSIMD = glob.hasWildcardsSIMD;

// Re-export glob flags
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

// Re-export error codes
pub const GLOB_NOSPACE = glob.GLOB_NOSPACE;
pub const GLOB_ABORTED = glob.GLOB_ABORTED;
pub const GLOB_NOMATCH = glob.GLOB_NOMATCH;

/// Simple glob function for Zig users (recommended API).
///
/// Match pattern against filesystem paths in the given directory.
/// Returns an ArrayList of matching paths, or null if no matches.
/// Caller owns the returned ArrayList and all strings in it.
///
/// Example:
/// ```zig
/// // Basic usage - returns null if no matches
/// if (try simdglob.globZ(allocator, ".", "*.txt", 0)) |*result| {
///     defer {
///         for (result.items) |p| allocator.free(p);
///         result.deinit();
///     }
///     for (result.items) |p| {
///         std.debug.print("Found: {s}\n", .{p});
///     }
/// }
/// ```
pub fn globZ(allocator: std.mem.Allocator, base_path: []const u8, pattern: []const u8, flags: c_int) !?std.array_list.AlignedManaged([]const u8, null) {
    return glob.globZ(allocator, base_path, pattern, flags);
}


/// Perform glob matching on filesystem (legacy API)
///
/// Example:
/// ```zig
/// const result = try simdglob.match(allocator, "*.txt", 0);
/// defer result.deinit();
/// for (result.paths) |path| {
///     std.debug.print("Found: {s}\n", .{path});
/// }
/// ```
pub fn match(allocator: std.mem.Allocator, pattern: []const u8, flags: u32) !GlobResults {
    return glob.globMatch(allocator, pattern, flags);
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
