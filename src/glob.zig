//! SIMD-optimized glob pattern matching implementation
//! Based on OpenBSD glob.c with SIMD optimizations for pattern matching

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

// Glob flags
pub const GLOB_APPEND = 0x0001;
pub const GLOB_DOOFFS = 0x0002;
pub const GLOB_ERR = 0x0004;
pub const GLOB_MARK = 0x0008;
pub const GLOB_NOCHECK = 0x0010;
pub const GLOB_NOSORT = 0x0020;
pub const GLOB_NOESCAPE = 0x1000;
pub const GLOB_MAGCHAR = 0x0100;
pub const GLOB_NOMAGIC = 0x0200;
pub const GLOB_TILDE = 0x0800;
pub const GLOB_BRACE = 0x0080;
pub const GLOB_LIMIT = 0x2000;

// Error codes
pub const GlobError = error{
    NoMatch,
    NoSpace,
    Aborted,
    OutOfMemory,
};

// Limits
const GLOB_LIMIT_MALLOC = 65536;
const GLOB_LIMIT_STAT = 2048;
const GLOB_LIMIT_READDIR = 16384;
const GLOB_LIMIT_RECUR = 64;

// Pattern meta characters
const M_QUOTE: u16 = 0x8000;
const M_PROTECT: u16 = 0x4000;
const M_MASK: u16 = 0xffff;
const M_ASCII: u16 = 0x00ff;

const Char = u16;

fn CHAR(c: u8) Char {
    return @as(Char, c) & M_ASCII;
}

fn META(c: u8) Char {
    return @as(Char, c) | M_QUOTE;
}

fn ismeta(c: Char) bool {
    return (c & M_QUOTE) != 0;
}

// Special pattern characters
const M_ALL = META('*');
const M_END = META(']');
const M_NOT = META('!');
const M_ONE = META('?');
const M_RNG = META('-');
const M_SET = META('[');
const M_CLASS = META(':');

pub const GlobResult = struct {
    paths: [][]const u8,
    allocator: Allocator,
    match_count: usize,
    flags: u32,

    pub fn deinit(self: *GlobResult) void {
        for (self.paths) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.paths);
    }
};

const GlobLimits = struct {
    malloc: usize = 0,
    stat: usize = 0,
    readdir: usize = 0,
};

pub const Glob = struct {
    allocator: Allocator,
    paths: std.ArrayList([]const u8),
    flags: u32,
    match_count: usize,
    limits: GlobLimits,

    pub fn init(allocator: Allocator, flags: u32) Glob {
        return .{
            .allocator = allocator,
            .paths = std.ArrayList([]const u8).empty,
            .flags = flags,
            .match_count = 0,
            .limits = .{},
        };
    }

    pub fn deinit(self: *Glob) void {
        for (self.paths.items) |path| {
            self.allocator.free(path);
        }
        self.paths.deinit(self.allocator);
    }

    pub fn glob(self: *Glob, pattern: []const u8) !GlobResult {
        if (pattern.len >= fs.max_path_bytes) {
            return GlobError.NoMatch;
        }

        // Convert pattern to internal representation
        var patbuf: [fs.max_path_bytes]Char = undefined;
        const patlen = try self.convertPattern(pattern, &patbuf);

        // Handle brace expansion if requested
        if (self.flags & GLOB_BRACE != 0) {
            try self.expandBraces(patbuf[0..patlen]);
        } else {
            try self.glob0(patbuf[0..patlen]);
        }

        // Sort results if requested
        if (self.flags & GLOB_NOSORT == 0) {
            mem.sort([]const u8, self.paths.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
        }

        // Create result
        const result = GlobResult{
            .paths = try self.paths.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
            .match_count = self.match_count,
            .flags = self.flags,
        };

        return result;
    }

    fn convertPattern(self: *Glob, pattern: []const u8, patbuf: []Char) !usize {
        var idx: usize = 0;
        var i: usize = 0;

        while (i < pattern.len and idx < patbuf.len) : (i += 1) {
            const c = pattern[i];

            if (self.flags & GLOB_NOESCAPE != 0) {
                // No escape processing, but still handle wildcards
                switch (c) {
                    '*' => {
                        patbuf[idx] = M_ALL;
                        idx += 1;
                    },
                    '?' => {
                        patbuf[idx] = M_ONE;
                        idx += 1;
                    },
                    '[' => {
                        patbuf[idx] = M_SET;
                        idx += 1;
                        i += 1;

                        // Check for negation
                        if (i < pattern.len and pattern[i] == '!') {
                            patbuf[idx] = M_NOT;
                            idx += 1;
                            i += 1;
                        }

                        // Special case: ] immediately after [ or [! is literal
                        if (i < pattern.len and pattern[i] == ']') {
                            patbuf[idx] = CHAR(']');
                            idx += 1;
                            i += 1;
                        }

                        // Copy characters until ]
                        while (i < pattern.len and pattern[i] != ']') {
                            if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                                // Range [a-z]
                                patbuf[idx] = CHAR(pattern[i]);
                                idx += 1;
                                patbuf[idx] = M_RNG;
                                idx += 1;
                                i += 2;
                                patbuf[idx] = CHAR(pattern[i]);
                                idx += 1;
                            } else {
                                patbuf[idx] = CHAR(pattern[i]);
                                idx += 1;
                            }
                            i += 1;
                        }

                        if (i < pattern.len and pattern[i] == ']') {
                            patbuf[idx] = M_END;
                            idx += 1;
                        }
                    },
                    else => {
                        patbuf[idx] = CHAR(c);
                        idx += 1;
                    },
                }
            } else {
                // Handle escape sequences
                if (c == '\\') {
                    i += 1;
                    if (i >= pattern.len) {
                        patbuf[idx] = CHAR('\\');
                        idx += 1;
                        break;
                    }
                    patbuf[idx] = @as(Char, pattern[i]) | M_PROTECT;
                    idx += 1;
                } else {
                    // Handle wildcards
                    switch (c) {
                        '*' => {
                            patbuf[idx] = M_ALL;
                            idx += 1;
                        },
                        '?' => {
                            patbuf[idx] = M_ONE;
                            idx += 1;
                        },
                        '[' => {
                            patbuf[idx] = M_SET;
                            idx += 1;
                            i += 1;

                            // Check for negation
                            if (i < pattern.len and pattern[i] == '!') {
                                patbuf[idx] = M_NOT;
                                idx += 1;
                                i += 1;
                            }

                            // Special case: ] immediately after [ or [! is literal
                            if (i < pattern.len and pattern[i] == ']') {
                                patbuf[idx] = CHAR(']');
                                idx += 1;
                                i += 1;
                            }

                            // Copy characters until ]
                            while (i < pattern.len and pattern[i] != ']') {
                                if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                                    // Range [a-z]
                                    patbuf[idx] = CHAR(pattern[i]);
                                    idx += 1;
                                    patbuf[idx] = M_RNG;
                                    idx += 1;
                                    i += 2;
                                    patbuf[idx] = CHAR(pattern[i]);
                                    idx += 1;
                                } else {
                                    patbuf[idx] = CHAR(pattern[i]);
                                    idx += 1;
                                }
                                i += 1;
                            }

                            if (i < pattern.len and pattern[i] == ']') {
                                patbuf[idx] = M_END;
                                idx += 1;
                            }
                        },
                        else => {
                            patbuf[idx] = CHAR(c);
                            idx += 1;
                        },
                    }
                }
            }
        }

        return idx;
    }

    fn glob0(self: *Glob, pattern: []const Char) (GlobError || Allocator.Error || fs.File.OpenError || fs.File.StatError || fs.Dir.OpenError || fs.Dir.StatFileError)!void {
        var pathbuf: [fs.max_path_bytes]u8 = undefined;
        try self.glob1(pattern, &pathbuf, 0);
    }

    fn glob1(self: *Glob, pattern: []const Char, pathbuf: []u8, pathlen: usize) (GlobError || Allocator.Error || fs.File.OpenError || fs.File.StatError || fs.Dir.OpenError || fs.Dir.StatFileError)!void {
        if (pattern.len == 0) return;

        try self.glob2(pattern, pathbuf, pathlen);
    }

    fn glob2(self: *Glob, pattern: []const Char, pathbuf: []u8, pathend: usize) (GlobError || Allocator.Error || fs.File.OpenError || fs.File.StatError || fs.Dir.OpenError || fs.Dir.StatFileError)!void {
        var i: usize = 0;
        var seg_start: usize = 0;
        var has_meta = false;
        var pathlen = pathend;

        // Find the next segment
        while (i < pattern.len) : (i += 1) {
            const c = pattern[i];

            if (c == CHAR('/')) {
                if (!has_meta) {
                    // Literal segment, just append it
                    const seg = pattern[seg_start..i];
                    for (seg) |ch| {
                        if (pathlen >= pathbuf.len) return GlobError.NoSpace;
                        pathbuf[pathlen] = @intCast(ch & M_ASCII);
                        pathlen += 1;
                    }
                    if (pathlen >= pathbuf.len) return GlobError.NoSpace;
                    pathbuf[pathlen] = '/';
                    pathlen += 1;
                    seg_start = i + 1;
                } else {
                    // Meta segment, need to expand
                    try self.glob3(pattern[seg_start..i], pattern[i..], pathbuf, pathlen);
                    return;
                }
                has_meta = false;
            } else if (ismeta(c)) {
                has_meta = true;
                self.flags |= GLOB_MAGCHAR;
            }
        }

        // Handle final segment
        if (has_meta) {
            try self.glob3(pattern[seg_start..], &[_]Char{}, pathbuf, pathlen);
        } else {
            // No meta characters, check if path exists
            const seg = pattern[seg_start..];
            for (seg) |ch| {
                if (pathlen >= pathbuf.len) return GlobError.NoSpace;
                pathbuf[pathlen] = @intCast(ch & M_ASCII);
                pathlen += 1;
            }

            // Try to stat the path
            if (pathlen == 0) return;

            const path = pathbuf[0..pathlen];
            const stat_result = fs.cwd().statFile(path) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };

            // Check if we should mark directories
            if (self.flags & GLOB_MARK != 0 and stat_result.kind == .directory) {
                if (pathlen >= pathbuf.len) return GlobError.NoSpace;
                pathbuf[pathlen] = '/';
                pathlen += 1;
            }

            try self.addPath(pathbuf[0..pathlen]);
        }
    }

    fn glob3(self: *Glob, segment: []const Char, rest: []const Char, pathbuf: []u8, pathend: usize) (GlobError || Allocator.Error || fs.File.OpenError || fs.File.StatError || fs.Dir.OpenError || fs.Dir.StatFileError)!void {
        // Open directory
        const dir_path = if (pathend == 0) "." else pathbuf[0..pathend];
        var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (self.flags & GLOB_LIMIT != 0) {
                self.limits.readdir += 1;
                if (self.limits.readdir >= GLOB_LIMIT_READDIR) {
                    return GlobError.NoSpace;
                }
            }

            // Skip . files unless pattern explicitly matches them
            if (entry.name[0] == '.' and segment.len > 0 and segment[0] != CHAR('.')) {
                continue;
            }

            // Match the filename against the segment pattern using SIMD
            if (try self.matchPattern(entry.name, segment)) {
                var new_pathbuf: [fs.max_path_bytes]u8 = undefined;
                var new_pathlen: usize = 0;

                // Copy existing path
                if (pathend > 0) {
                    @memcpy(new_pathbuf[0..pathend], pathbuf[0..pathend]);
                    new_pathlen = pathend;
                }

                // Add filename
                @memcpy(new_pathbuf[new_pathlen .. new_pathlen + entry.name.len], entry.name);
                new_pathlen += entry.name.len;

                if (rest.len > 0) {
                    // More pattern to match, or just a trailing slash
                    if (rest[0] == CHAR('/')) {
                        if (rest.len > 1) {
                            // More pattern after the slash
                            new_pathbuf[new_pathlen] = '/';
                            new_pathlen += 1;
                            try self.glob2(rest[1..], &new_pathbuf, new_pathlen);
                        } else {
                            // Just a trailing slash - match only directories
                            const stat_result = dir.statFile(entry.name) catch continue;
                            if (stat_result.kind == .directory) {
                                try self.addPath(new_pathbuf[0..new_pathlen]);
                            }
                        }
                    }
                } else {
                    // This is the final match
                    const stat_result = dir.statFile(entry.name) catch continue;

                    if (self.flags & GLOB_MARK != 0 and stat_result.kind == .directory) {
                        if (new_pathlen >= new_pathbuf.len) return GlobError.NoSpace;
                        new_pathbuf[new_pathlen] = '/';
                        new_pathlen += 1;
                    }

                    try self.addPath(new_pathbuf[0..new_pathlen]);
                }
            }
        }
    }

    /// SIMD-optimized pattern matching
    fn matchPattern(self: *Glob, name: []const u8, pattern: []const Char) !bool {
        return self.matchPatternRecur(name, 0, pattern, 0, GLOB_LIMIT_RECUR);
    }

    fn matchPatternRecur(self: *Glob, name: []const u8, name_idx: usize, pattern: []const Char, pat_idx: usize, recur: usize) error{NoSpace}!bool {
        if (recur == 0) return error.NoSpace;

        var ni = name_idx;
        var pi = pat_idx;

        while (pi < pattern.len) {
            const c = pattern[pi];
            pi += 1;

            switch (c & M_MASK) {
                M_ALL => {
                    // Consume consecutive wildcards
                    while (pi < pattern.len and (pattern[pi] & M_MASK) == M_ALL) {
                        pi += 1;
                    }

                    // If this is the last pattern character, match everything
                    if (pi >= pattern.len) return true;

                    // Try matching the rest of the pattern at each position
                    // Use SIMD to find potential match positions
                    const next_char = pattern[pi];
                    if (!ismeta(next_char)) {
                        // Optimize: use SIMD to find the next literal character
                        const target: u8 = @intCast(next_char & M_ASCII);
                        var search_idx = ni;

                        // SIMD search for the character
                        while (search_idx < name.len) {
                            const found_idx = simdFindChar(name[search_idx..], target);
                            if (found_idx == null) return false;

                            search_idx += found_idx.?;
                            if (try self.matchPatternRecur(name, search_idx, pattern, pi, recur - 1)) {
                                return true;
                            }
                            search_idx += 1;
                        }
                        return false;
                    } else {
                        // Try matching at each position
                        while (ni <= name.len) : (ni += 1) {
                            if (try self.matchPatternRecur(name, ni, pattern, pi, recur - 1)) {
                                return true;
                            }
                        }
                        return false;
                    }
                },
                M_ONE => {
                    if (ni >= name.len) return false;
                    ni += 1;
                },
                M_SET => {
                    if (ni >= name.len) return false;
                    const k = name[ni];
                    ni += 1;

                    // Check if this is a negated set
                    var negate = false;
                    if (pi < pattern.len and (pattern[pi] & M_MASK) == M_NOT) {
                        negate = true;
                        pi += 1;
                    }

                    var match = false;
                    while (pi < pattern.len) {
                        const set_c = pattern[pi];
                        pi += 1;

                        if ((set_c & M_MASK) == M_END) break;

                        if (pi < pattern.len and (pattern[pi] & M_MASK) == M_RNG) {
                            // Range match
                            pi += 1;
                            if (pi < pattern.len) {
                                const range_end = pattern[pi];
                                pi += 1;
                                const range_start: u8 = @intCast(set_c & M_ASCII);
                                const range_end_val: u8 = @intCast(range_end & M_ASCII);
                                if (k >= range_start and k <= range_end_val) {
                                    match = true;
                                }
                            }
                        } else {
                            // Single character match
                            const match_char: u8 = @intCast(set_c & M_ASCII);
                            if (k == match_char) {
                                match = true;
                            }
                        }
                    }

                    if (match == negate) return false;
                },
                else => {
                    // Literal character match
                    if (ni >= name.len) return false;
                    const name_char = name[ni];
                    const pat_char: u8 = @intCast(c & M_ASCII);
                    if (name_char != pat_char) return false;
                    ni += 1;
                },
            }
        }

        return ni == name.len;
    }

    fn addPath(self: *Glob, path: []const u8) !void {
        if (self.flags & GLOB_LIMIT != 0) {
            self.limits.malloc += path.len;
            if (self.limits.malloc >= GLOB_LIMIT_MALLOC) {
                return GlobError.NoSpace;
            }
        }

        // Normalize path: strip trailing slash (unless it's just "/")
        // and strip leading "./"
        var normalized_path = path;

        // Strip leading "./"
        if (normalized_path.len >= 2 and normalized_path[0] == '.' and normalized_path[1] == '/') {
            normalized_path = normalized_path[2..];
        }

        // Strip trailing slash (unless it's the root)
        if (normalized_path.len > 1 and normalized_path[normalized_path.len - 1] == '/') {
            normalized_path = normalized_path[0 .. normalized_path.len - 1];
        }

        const path_copy = try self.allocator.dupe(u8, normalized_path);
        try self.paths.append(self.allocator, path_copy);
        self.match_count += 1;
    }

    fn expandBraces(self: *Glob, pattern: []const Char) !void {
        // Check if pattern contains braces
        var has_braces = false;
        for (pattern) |c| {
            if (c == CHAR('{')) {
                has_braces = true;
                break;
            }
        }

        if (!has_braces) {
            return self.glob0(pattern);
        }

        // Simplified brace expansion - full implementation would be more complex
        return self.glob0(pattern);
    }
};

/// SIMD-optimized character search - public for testing
pub fn simdFindChar(haystack: []const u8, needle: u8) ?usize {
    if (haystack.len == 0) return null;

    // For longer strings, use SIMD
    if (haystack.len >= 16) {
        const Vec16 = @Vector(16, u8);
        const needle_vec: Vec16 = @splat(needle);

        var i: usize = 0;
        while (i + 16 <= haystack.len) : (i += 16) {
            const chunk: Vec16 = haystack[i..][0..16].*;
            const matches = chunk == needle_vec;

            // Check if any matches
            const match_mask = @as(u16, @bitCast(matches));
            if (match_mask != 0) {
                // Find first match
                return i + @ctz(match_mask);
            }
        }

        // Check remaining bytes
        while (i < haystack.len) : (i += 1) {
            if (haystack[i] == needle) return i;
        }
    } else {
        // For short strings, use simple loop
        for (haystack, 0..) |c, i| {
            if (c == needle) return i;
        }
    }

    return null;
}

// Public convenience function
pub fn glob(allocator: Allocator, pattern: []const u8, flags: u32) !GlobResult {
    var g = Glob.init(allocator, flags);
    defer g.deinit();
    return try g.glob(pattern);
}
