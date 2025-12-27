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

    pub fn deinit(self: *GlobResult) void {
        if (self.pglob) |*pglob_ptr| {
            // Zero-copy mode: use globfree() which handles both arena and malloc'd paths
            glob_libc.globfree(pglob_ptr);
            // Free only the slice array, not the strings themselves
            self.allocator.free(self.paths);
        } else {
            // Normal mode: paths are Zig-allocated, free them
            for (self.paths) |path| {
                self.allocator.free(path);
            }
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
        const result = try glob_internal(self.allocator, pattern, self.flags);
        self.match_count = result.paths.len;
        return result;
    }

    pub fn matchFiles(self: *Glob, pattern: []const u8, files: []const []const u8) !GlobResult {
        // Count matches first
        var count: usize = 0;
        for (files) |file| {
            if (glob_libc.fnmatch(pattern, file)) {
                count += 1;
            }
        }

        // Handle NOCHECK flag
        if (count == 0 and self.flags & GLOB_NOCHECK != 0) {
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

        // Allocate and populate matches
        var paths = try self.allocator.alloc([]const u8, count);
        errdefer self.allocator.free(paths);

        var idx: usize = 0;
        for (files) |file| {
            if (glob_libc.fnmatch(pattern, file)) {
                paths[idx] = try self.allocator.dupe(u8, file);
                idx += 1;
            }
        }

        // Sort results unless NOSORT flag is set
        if (self.flags & GLOB_NOSORT == 0) {
            std.mem.sort([]const u8, paths, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
        }

        self.match_count = count;
        return GlobResult{
            .paths = paths,
            .match_count = count,
            .allocator = self.allocator,
        };
    }
};

// Re-export SIMD functions for benchmarking
pub const simdFindChar = glob_libc.simdFindChar;
pub const hasWildcardsSIMD = glob_libc.hasWildcardsSIMD;
pub const simdSuffixMatch = glob_libc.simdSuffixMatch;
pub const fnmatch = glob_libc.fnmatch;

/// Main glob function - matches pattern against filesystem (public API)
pub fn glob(allocator: Allocator, pattern: []const u8, flags: u32) !GlobResult {
    return glob_internal(allocator, pattern, flags);
}

/// Internal glob function - matches pattern against filesystem
fn glob_internal(allocator: Allocator, pattern: []const u8, flags: u32) !GlobResult {
    // Allocate null-terminated pattern for C API
    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);

    var pglob: glob_libc.glob_t = undefined;
    const result = glob_libc.glob(pattern_z.ptr, @intCast(flags), null, &pglob);

    switch (result) {
        0 => {
            // Success - zero-copy: wrap C pointers directly without duplication
            // DON'T call globfree - we're taking ownership of the C memory

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
