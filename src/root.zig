//! SIMD-accelerated glob pattern matching library
//!
//! This library provides high-performance file pattern matching (globbing) using
//! SIMD optimizations for improved performance on pattern matching operations.
//!
//! Based on the OpenBSD glob implementation with modern SIMD enhancements.

const std = @import("std");

// Re-export the glob module
pub const glob = @import("glob.zig");

// Re-export glob_libc module for C-style glob API
pub const glob_libc = @import("glob_libc.zig");

// Re-export common types and functions for convenience
pub const Glob = glob.Glob;
pub const GlobResult = glob.GlobResult;
pub const GlobError = glob.GlobError;

// Re-export SIMD function for benchmarking
pub const simdFindChar = glob.simdFindChar;

// Re-export flags
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
pub const GLOB_LIMIT = glob.GLOB_LIMIT;
pub const GLOB_PERIOD = glob_libc.GLOB_PERIOD;

/// Perform glob matching on filesystem
///
/// Example:
/// ```zig
/// const result = try simdglob.match(allocator, "*.txt", 0);
/// defer result.deinit();
/// for (result.paths) |path| {
///     std.debug.print("Found: {s}\n", .{path});
/// }
/// ```
pub fn match(allocator: std.mem.Allocator, pattern: []const u8, flags: u32) !GlobResult {
    return glob.glob(allocator, pattern, flags);
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
pub fn matchPaths(allocator: std.mem.Allocator, pattern: []const u8, paths: []const []const u8, flags: u32) !GlobResult {
    const path_matcher = @import("path_matcher.zig");
    return path_matcher.matchPaths(allocator, pattern, paths, flags);
}

test {
    // Import all tests from glob module
    std.testing.refAllDecls(@This());
}
