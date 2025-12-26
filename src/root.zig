//! SIMD-accelerated glob pattern matching library
//!
//! This library provides high-performance file pattern matching (globbing) using
//! SIMD optimizations for improved performance on pattern matching operations.
//!
//! Based on the OpenBSD glob implementation with modern SIMD enhancements.

const std = @import("std");

// Re-export the glob module
pub const glob = @import("glob.zig");

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

/// Convenience function to perform glob matching on filesystem
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

/// Match a pattern against a pre-built array of filenames
/// This avoids filesystem I/O when you already have a file list
///
/// For better performance when calling repeatedly, pass a reusable Glob instance:
/// ```zig
/// var g = simdglob.Glob.init(allocator, 0);
/// defer g.deinit();
/// const result1 = try simdglob.matchFiles(allocator, "*.txt", &files1, 0, &g);
/// defer result1.deinit();
/// const result2 = try simdglob.matchFiles(allocator, "*.zig", &files2, 0, &g);
/// defer result2.deinit();
/// ```
///
/// Or pass null for one-off calls (less efficient):
/// ```zig
/// const result = try simdglob.matchFiles(allocator, "*.txt", &files, 0, null);
/// defer result.deinit();
/// ```
pub fn matchFiles(allocator: std.mem.Allocator, pattern: []const u8, files: []const []const u8, flags: u32, reusable_glob: ?*Glob) !GlobResult {
    if (reusable_glob) |g| {
        g.reset();
        g.flags = flags;
        return try g.matchFiles(pattern, files);
    } else {
        var g = glob.Glob.init(allocator, flags);
        defer g.deinit();
        return try g.matchFiles(pattern, files);
    }
}

test {
    // Import all tests from glob module
    std.testing.refAllDecls(@This());
    _ = @import("glob_test.zig");

    // Import comprehensive Rust-ported tests
    _ = @import("glob_rust_tests.zig");
}
