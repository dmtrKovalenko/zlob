//! SIMD-accelerated glob implementation
//! This module provides a Zig-friendly API wrapper around the high-performance C-style glob

const std = @import("std");
const Allocator = std.mem.Allocator;
const glob_libc = @import("glob_libc.zig");

// Re-export glob_libc constants
pub const GLOB_APPEND = glob_libc.GLOB_APPEND;
pub const GLOB_DOOFFS = glob_libc.GLOB_DOOFFS;
pub const GLOB_ERR = glob_libc.GLOB_ERR;
pub const GLOB_MARK = glob_libc.GLOB_MARK;
pub const GLOB_NOCHECK = glob_libc.GLOB_NOCHECK;
pub const GLOB_NOSORT = glob_libc.GLOB_NOSORT;
pub const GLOB_NOESCAPE = glob_libc.GLOB_NOESCAPE;
pub const GLOB_BRACE = glob_libc.GLOB_BRACE;

// Additional flags for API compatibility
pub const GLOB_MAGCHAR = 0x0100;
pub const GLOB_NOMAGIC = 0x0200;
pub const GLOB_TILDE = 0x0800;
pub const GLOB_LIMIT = 0x2000;

pub const GlobError = error{
    OutOfMemory,
    NoMatch,
    Aborted,
    InvalidPattern,
};

pub const GlobResult = struct {
    paths: [][]const u8,
    match_count: usize,
    allocator: Allocator,
    // Store full glob_t for zero-copy glob results (null if paths are Zig-allocated)
    // This allows proper cleanup via globfree() which handles arena allocator
    pglob: ?glob_libc.glob_t = null,
    // Whether we own the path strings (true for glob(), false for matchPaths())
    owns_paths: bool = true,

    pub fn deinit(self: *GlobResult) void {
        if (self.pglob) |*pglob_ptr| {
            // Zero-copy mode: use globfree() which handles allocated paths
            glob_libc.globfree(self.allocator, pglob_ptr);
            // Free only the slice array, not the strings themselves (already freed by globfree)
            self.allocator.free(self.paths);
        } else if (self.owns_paths) {
            // Normal mode: paths are Zig-allocated, free them
            for (self.paths) |path| {
                self.allocator.free(path);
            }
            self.allocator.free(self.paths);
        } else {
            // matchPaths mode: we don't own the path strings, only free the array
            self.allocator.free(self.paths);
        }
    }
};

pub const Glob = struct {
    allocator: Allocator,
    flags: u32,
    match_count: usize,

    pub fn init(allocator: Allocator, flags: u32) Glob {
        return .{
            .allocator = allocator,
            .flags = flags,
            .match_count = 0,
        };
    }

    pub fn deinit(self: *Glob) void {
        _ = self;
    }

    pub fn reset(self: *Glob) void {
        self.match_count = 0;
    }

    pub fn glob(self: *Glob, pattern: []const u8) !GlobResult {
        // Call the module-level glob function
        const pattern_z = try self.allocator.dupeZ(u8, pattern);
        defer self.allocator.free(pattern_z);

        var pglob: glob_libc.glob_t = undefined;
        const result = glob_libc.glob(self.allocator, pattern_z.ptr, @intCast(self.flags), null, &pglob);

        switch (result) {
            0 => {
                // Success - zero-copy: wrap C pointers directly without duplication
                var paths = try self.allocator.alloc([]const u8, pglob.gl_pathc);
                errdefer self.allocator.free(paths);

                var i: usize = 0;
                while (i < pglob.gl_pathc) : (i += 1) {
                    const c_path = pglob.gl_pathv[i];
                    paths[i] = std.mem.sliceTo(c_path, 0);
                }

                self.match_count = pglob.gl_pathc;
                return GlobResult{
                    .paths = paths,
                    .match_count = pglob.gl_pathc,
                    .allocator = self.allocator,
                    .pglob = pglob,
                };
            },
            glob_libc.GLOB_NOSPACE => return error.OutOfMemory,
            glob_libc.GLOB_ABORTED => return error.Aborted,
            glob_libc.GLOB_NOMATCH => {
                if (self.flags & GLOB_NOCHECK != 0) {
                    var paths = try self.allocator.alloc([]const u8, 1);
                    errdefer self.allocator.free(paths);
                    paths[0] = try self.allocator.dupe(u8, pattern);
                    self.match_count = 1;
                    return GlobResult{
                        .paths = paths,
                        .match_count = 1,
                        .allocator = self.allocator,
                    };
                }
                return error.NoMatch;
            },
            else => return error.Aborted,
        }
    }

    /// Match glob pattern against array of paths with full ** recursive support
    /// This is an instance method version of the standalone matchPaths function
    pub fn matchPaths(self: *Glob, pattern: []const u8, paths: []const []const u8) !GlobResult {
        const path_matcher = @import("path_matcher.zig");
        const result = try path_matcher.matchPaths(self.allocator, pattern, paths, self.flags);
        self.match_count = result.match_count;
        return result;
    }
};

// Re-export SIMD functions for benchmarking
pub const simdFindChar = glob_libc.simdFindChar;
pub const hasWildcardsSIMD = glob_libc.hasWildcardsSIMD;
pub const simdSuffixMatch = glob_libc.simdSuffixMatch;
pub const fnmatch = glob_libc.fnmatch;

/// Main glob function - matches pattern against filesystem (public API)
pub fn glob(allocator: Allocator, pattern: []const u8, flags: u32) !GlobResult {
    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);

    var pglob: glob_libc.glob_t = undefined;
    const result = glob_libc.glob(allocator, pattern_z.ptr, @intCast(flags), null, &pglob);

    switch (result) {
        0 => {
            // Success - zero-copy: wrap C pointers directly without duplication
            // DON'T call globfree yet - we're taking ownership of the C memory

            var paths = try allocator.alloc([]const u8, pglob.gl_pathc);
            errdefer allocator.free(paths);

            var i: usize = 0;
            while (i < pglob.gl_pathc) : (i += 1) {
                const c_path = pglob.gl_pathv[i];
                // Zero-copy: just wrap the C pointer as a Zig slice
                paths[i] = std.mem.sliceTo(c_path, 0);
            }

            return GlobResult{
                .paths = paths,
                .match_count = pglob.gl_pathc,
                .allocator = allocator,
                .pglob = pglob, // Store full glob_t for proper cleanup
            };
        },
        glob_libc.GLOB_NOSPACE => return error.OutOfMemory,
        glob_libc.GLOB_ABORTED => return error.Aborted,
        glob_libc.GLOB_NOMATCH => {
            if (flags & GLOB_NOCHECK != 0) {
                // Return the pattern itself
                var paths = try allocator.alloc([]const u8, 1);
                errdefer allocator.free(paths);
                paths[0] = try allocator.dupe(u8, pattern);
                return GlobResult{
                    .paths = paths,
                    .match_count = 1,
                    .allocator = allocator,
                };
            }
            return error.NoMatch;
        },
        else => return error.Aborted,
    }
}
