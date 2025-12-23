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
    arena: std.heap.ArenaAllocator,
    match_count: usize,
    flags: u32,
    // Single buffer optimization
    path_buffer: []u8,
    uses_buffer: bool,

    pub fn deinit(self: *GlobResult) void {
        if (self.uses_buffer) {
            // Free single buffer and paths array
            self.allocator.free(self.path_buffer);
            self.allocator.free(self.paths);
        } else {
            // Arena owns all strings - free it all at once
            self.arena.deinit();
            // Free the paths array itself
            self.allocator.free(self.paths);
        }
    }
};

const GlobLimits = struct {
    malloc: usize = 0,
    stat: usize = 0,
    readdir: usize = 0,
};

const PatternFlags = struct {
    has_wildcard: bool = false,
    has_charclass: bool = false,
    is_literal_only: bool = false,
};

pub const Glob = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    paths: std.ArrayList([]const u8),
    flags: u32,
    match_count: usize,
    limits: GlobLimits,
    pattern_flags: PatternFlags,
    // Single buffer optimization - stores all path bytes
    path_buffer: std.ArrayList(u8),
    path_offsets: std.ArrayList(usize),

    pub fn init(allocator: Allocator, flags: u32) Glob {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .paths = std.ArrayList([]const u8).empty,
            .flags = flags,
            .match_count = 0,
            .limits = .{},
            .pattern_flags = .{},
            .path_buffer = std.ArrayList(u8).empty,
            .path_offsets = std.ArrayList(usize).empty,
        };
    }

    pub fn deinit(self: *Glob) void {
        // Free arena and paths list
        self.arena.deinit();
        self.paths.deinit(self.allocator);
        self.path_buffer.deinit(self.allocator);
        self.path_offsets.deinit(self.allocator);
    }

    /// Reset the glob state for reuse without deallocating memory
    pub fn reset(self: *Glob) void {
        // Reset arena - keeps allocated memory for reuse
        _ = self.arena.reset(.retain_capacity);
        // Clear paths but keep capacity
        self.paths.clearRetainingCapacity();
        self.path_buffer.clearRetainingCapacity();
        self.path_offsets.clearRetainingCapacity();
        self.match_count = 0;
        self.limits = .{};
        self.pattern_flags = .{};
    }

    /// Estimate ArrayList capacity based on pattern complexity
    fn estimateCapacity(self: *Glob, pattern: []const Char) usize {
        var dir_depth: usize = 1;
        const has_wildcard = self.pattern_flags.has_wildcard;

        // Count directory depth
        for (pattern) |c| {
            if (c == CHAR('/')) {
                dir_depth += 1;
            }
        }

        // Heuristic:
        // - Simple patterns without wildcards: 16 matches expected
        // - Patterns with wildcards: 50 matches per directory level
        // - Deep patterns: multiply by depth
        if (!has_wildcard) {
            return 16;
        } else {
            return dir_depth * 50;
        }
    }

    pub fn glob(self: *Glob, pattern: []const u8) !GlobResult {
        if (pattern.len >= fs.max_path_bytes) {
            return GlobError.NoMatch;
        }

        // Convert pattern to internal representation
        var patbuf: [fs.max_path_bytes]Char = undefined;
        const patlen = try self.convertPattern(pattern, &patbuf);

        // Pre-allocate capacity based on pattern complexity
        const capacity = self.estimateCapacity(patbuf[0..patlen]);
        try self.path_offsets.ensureTotalCapacity(self.allocator, capacity);
        // Pre-allocate buffer for path data (estimate 64 bytes per path)
        try self.path_buffer.ensureTotalCapacity(self.allocator, capacity * 64);

        // Handle brace expansion if requested
        if (self.flags & GLOB_BRACE != 0) {
            try self.expandBraces(patbuf[0..patlen]);
        } else {
            try self.glob0(patbuf[0..patlen]);
        }

        // Build paths from single buffer optimization
        const owned_buffer = try self.path_buffer.toOwnedSlice(self.allocator);
        const offsets = self.path_offsets.items;

        const owned_paths = try self.allocator.alloc([]const u8, offsets.len);
        for (offsets, 0..) |start_offset, i| {
            const end_offset = if (i + 1 < offsets.len)
                offsets[i + 1]
            else
                owned_buffer.len;
            owned_paths[i] = owned_buffer[start_offset..end_offset];
        }

        // Sort results if requested
        if (self.flags & GLOB_NOSORT == 0) {
            mem.sort([]const u8, owned_paths, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
        }

        // Save values
        const count = self.match_count;
        const flags = self.flags;

        // Transfer arena ownership - create new arena for next use
        const old_arena = self.arena;
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        self.path_offsets.clearRetainingCapacity();
        self.match_count = 0;
        self.limits = .{};

        // Create result with single buffer
        const result = GlobResult{
            .paths = owned_paths,
            .allocator = self.allocator,
            .arena = old_arena,
            .match_count = count,
            .flags = flags,
            .path_buffer = owned_buffer,
            .uses_buffer = true,
        };

        return result;
    }

    /// Match a pattern against a pre-built list of filenames
    /// This is useful when you already have the file list and want to avoid filesystem I/O
    pub fn matchFiles(self: *Glob, pattern: []const u8, files: []const []const u8) !GlobResult {
        if (pattern.len >= fs.max_path_bytes) {
            return GlobError.NoMatch;
        }

        // Convert pattern to internal representation
        var patbuf: [fs.max_path_bytes]Char = undefined;
        const patlen = try self.convertPattern(pattern, &patbuf);

        // Pre-allocate assuming most files will match (worst case)
        try self.path_offsets.ensureTotalCapacity(self.allocator, files.len);
        try self.path_buffer.ensureTotalCapacity(self.allocator, files.len * 64);

        // Check if pattern has path separators
        var has_separator = false;
        for (patbuf[0..patlen]) |c| {
            if (c == CHAR('/')) {
                has_separator = true;
                break;
            }
        }

        // Match each file against the pattern
        for (files) |file| {
            if (has_separator) {
                // Pattern has directory components - match full path
                if (try self.matchFullPath(file, patbuf[0..patlen])) {
                    try self.addPath(file);
                }
            } else {
                // Simple pattern - match just the filename
                const basename = fs.path.basename(file);
                if (try self.matchPattern(basename, patbuf[0..patlen])) {
                    try self.addPath(file);
                }
            }
        }

        // Build paths from single buffer optimization
        const owned_buffer = try self.path_buffer.toOwnedSlice(self.allocator);
        const offsets = self.path_offsets.items;

        const owned_paths = try self.allocator.alloc([]const u8, offsets.len);
        for (offsets, 0..) |start_offset, i| {
            const end_offset = if (i + 1 < offsets.len)
                offsets[i + 1]
            else
                owned_buffer.len;
            owned_paths[i] = owned_buffer[start_offset..end_offset];
        }

        // Sort results if requested
        if (self.flags & GLOB_NOSORT == 0) {
            mem.sort([]const u8, owned_paths, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
        }

        // Save values
        const count = self.match_count;
        const flags = self.flags;

        // Transfer arena ownership - create new arena for next use
        const old_arena = self.arena;
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        self.path_offsets.clearRetainingCapacity();
        self.match_count = 0;
        self.limits = .{};

        // Create result with single buffer
        const result = GlobResult{
            .paths = owned_paths,
            .allocator = self.allocator,
            .arena = old_arena,
            .match_count = count,
            .flags = flags,
            .path_buffer = owned_buffer,
            .uses_buffer = true,
        };

        return result;
    }

    /// Match a full path including directory components
    fn matchFullPath(self: *Glob, path: []const u8, pattern: []const Char) !bool {
        // Split path into segments
        var path_segments: [32][]const u8 = undefined;
        var path_count: usize = 0;

        var it = mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len > 0 and path_count < path_segments.len) {
                path_segments[path_count] = segment;
                path_count += 1;
            }
        }

        // Split pattern into segments
        var pattern_segments: [32][]const Char = undefined;
        var pattern_count: usize = 0;
        var seg_start: usize = 0;

        for (pattern, 0..) |c, i| {
            if (c == CHAR('/')) {
                if (i > seg_start and pattern_count < pattern_segments.len) {
                    pattern_segments[pattern_count] = pattern[seg_start..i];
                    pattern_count += 1;
                }
                seg_start = i + 1;
            }
        }
        if (seg_start < pattern.len and pattern_count < pattern_segments.len) {
            pattern_segments[pattern_count] = pattern[seg_start..];
            pattern_count += 1;
        }

        // Must have same number of segments (no ** support yet)
        if (path_count != pattern_count) return false;

        // Match each segment
        for (0..path_count) |i| {
            if (!try self.matchPattern(path_segments[i], pattern_segments[i])) {
                return false;
            }
        }

        return true;
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

        // Analyze pattern characteristics for optimization (cache once)
        for (patbuf[0..idx]) |c| {
            const masked = c & M_MASK;
            if (masked == M_ALL or masked == M_ONE) {
                self.pattern_flags.has_wildcard = true;
            }
            if (masked == M_SET) {
                self.pattern_flags.has_charclass = true;
            }
        }

        // Check if pattern is literal-only (no wildcards or char classes)
        if (!self.pattern_flags.has_wildcard and !self.pattern_flags.has_charclass) {
            self.pattern_flags.is_literal_only = true;
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
                // Reuse pathbuf instead of allocating new buffer
                // Check if there's enough space
                if (pathend + entry.name.len >= pathbuf.len) return GlobError.NoSpace;

                // Append filename directly to existing buffer
                @memcpy(pathbuf[pathend .. pathend + entry.name.len], entry.name);
                var new_pathlen = pathend + entry.name.len;

                if (rest.len > 0) {
                    // More pattern to match, or just a trailing slash
                    if (rest[0] == CHAR('/')) {
                        if (rest.len > 1) {
                            // More pattern after the slash
                            if (new_pathlen >= pathbuf.len) return GlobError.NoSpace;
                            pathbuf[new_pathlen] = '/';
                            new_pathlen += 1;
                            try self.glob2(rest[1..], pathbuf, new_pathlen);
                        } else {
                            // Just a trailing slash - match only directories
                            // Use entry.kind directly - no stat needed
                            if (entry.kind == .directory) {
                                try self.addPath(pathbuf[0..new_pathlen]);
                            }
                        }
                    }
                } else {
                    // This is the final match
                    // Only add trailing slash if GLOB_MARK is set
                    if (self.flags & GLOB_MARK != 0 and entry.kind == .directory) {
                        if (new_pathlen >= pathbuf.len) return GlobError.NoSpace;
                        pathbuf[new_pathlen] = '/';
                        new_pathlen += 1;
                    }

                    try self.addPath(pathbuf[0..new_pathlen]);
                }

                // Pathbuf will be automatically truncated for next iteration
                // since we use pathend (unchanged) for the next entry
            }
        }
    }

    /// SIMD-optimized pattern matching
    inline fn matchPattern(self: *Glob, name: []const u8, pattern: []const Char) !bool {
        // Fast path: use cached pattern analysis
        // If no wildcards and no char classes, use SIMD literal matching
        if (self.pattern_flags.is_literal_only and pattern.len <= name.len) {
            if (pattern.len >= 4) {
                // Build literal string
                var literal_buf: [256]u8 = undefined;
                for (pattern, 0..) |c, i| {
                    literal_buf[i] = @intCast(c & M_ASCII);
                }
                return simdMatchLiteral(name, literal_buf[0..pattern.len]);
            }
        }

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
                        // Check if we have multiple literals following
                        var literal_len: usize = 1;
                        var temp_pi = pi + 1;
                        while (temp_pi < pattern.len and !ismeta(pattern[temp_pi]) and literal_len < 8) {
                            literal_len += 1;
                            temp_pi += 1;
                        }

                        if (literal_len >= 2 and ni + literal_len <= name.len) {
                            // Multiple literals - use batch anchor finding
                            var literal_buf: [8]u8 = undefined;
                            for (0..literal_len) |i| {
                                literal_buf[i] = @intCast(pattern[pi + i] & M_ASCII);
                            }

                            // Find all possible anchor points
                            var positions: [256]usize = undefined;
                            const anchor_count = simdFindAllAnchors(
                                name[ni..],
                                literal_buf[0..literal_len],
                                &positions,
                                positions.len,
                            );

                            // Try matching at each anchor point
                            for (positions[0..anchor_count]) |anchor_pos| {
                                const abs_pos = ni + anchor_pos;
                                if (try self.matchPatternRecur(name, abs_pos, pattern, pi, recur - 1)) {
                                    return true;
                                }
                            }
                            return false;
                        } else {
                            // Single literal or short - use existing SIMD single-char search
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
                        }
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

                    // Collect characters and ranges for SIMD matching
                    var class_chars: [256]u8 = undefined;
                    var class_count: usize = 0;
                    var ranges: [32]Range = undefined;
                    var range_count: usize = 0;

                    var match = false;
                    while (pi < pattern.len) {
                        const set_c = pattern[pi];
                        pi += 1;

                        if ((set_c & M_MASK) == M_END) break;

                        if (pi < pattern.len and (pattern[pi] & M_MASK) == M_RNG) {
                            // Range match - collect for SIMD range checking
                            pi += 1;
                            if (pi < pattern.len) {
                                const range_end = pattern[pi];
                                pi += 1;
                                const range_start: u8 = @intCast(set_c & M_ASCII);
                                const range_end_val: u8 = @intCast(range_end & M_ASCII);

                                if (range_count < ranges.len) {
                                    ranges[range_count] = .{ .start = range_start, .end = range_end_val };
                                    range_count += 1;
                                }

                                // Also check immediately
                                if (k >= range_start and k <= range_end_val) {
                                    match = true;
                                }
                            }
                        } else {
                            // Single character - collect for SIMD class matching
                            const match_char: u8 = @intCast(set_c & M_ASCII);
                            if (class_count < class_chars.len) {
                                class_chars[class_count] = match_char;
                                class_count += 1;
                            }
                            if (k == match_char) {
                                match = true;
                            }
                        }
                    }

                    // If we haven't matched yet and we have enough data, use SIMD
                    if (!match and class_count > 0) {
                        match = simdMatchCharClass(k, class_chars[0..class_count]);
                    }
                    if (!match and range_count > 0) {
                        match = simdMatchRanges(k, ranges[0..range_count]);
                    }

                    if (match == negate) return false;
                },
                else => {
                    // Literal character match - try to match multiple literals with SIMD
                    const literal_start = pi - 1;
                    var literal_end = pi;

                    // Collect consecutive literal characters
                    while (literal_end < pattern.len and !ismeta(pattern[literal_end])) {
                        literal_end += 1;
                    }

                    const literal_count = literal_end - literal_start;

                    if (literal_count >= 4 and ni + literal_count <= name.len) {
                        // Multiple literals - build literal string and use SIMD
                        var literal_buf: [256]u8 = undefined;
                        for (0..literal_count) |i| {
                            literal_buf[i] = @intCast(pattern[literal_start + i] & M_ASCII);
                        }

                        if (!simdMatchLiteral(name[ni..], literal_buf[0..literal_count])) {
                            return false;
                        }

                        ni += literal_count;
                        pi = literal_end;
                    } else {
                        // Single literal or short sequence - simple comparison
                        if (ni >= name.len) return false;
                        const name_char = name[ni];
                        const pat_char: u8 = @intCast(c & M_ASCII);
                        if (name_char != pat_char) return false;
                        ni += 1;
                    }
                },
            }
        }

        return ni == name.len;
    }

    inline fn addPath(self: *Glob, path: []const u8) !void {
        if (self.flags & GLOB_LIMIT != 0) {
            self.limits.malloc += path.len;
            if (self.limits.malloc >= GLOB_LIMIT_MALLOC) {
                return GlobError.NoSpace;
            }
        }

        // Fast path normalization: calculate final length without allocating
        var start: usize = 0;
        var end: usize = path.len;

        // Strip leading "./" - inline for speed
        if (path.len >= 2 and path[0] == '.' and path[1] == '/') {
            start = 2;
        }

        // Strip trailing slash (unless it's the root)
        if (end > 1 and path[end - 1] == '/') {
            end -= 1;
        }

        // Append to single buffer
        const offset = self.path_buffer.items.len;
        try self.path_buffer.appendSlice(self.allocator, path[start..end]);
        try self.path_offsets.append(self.allocator, offset);
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
pub inline fn simdFindChar(haystack: []const u8, needle: u8) ?usize {
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

/// SIMD-optimized literal substring matching
/// Returns true if needle is found at the start of haystack
pub inline fn simdMatchLiteral(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;

    // For short needles or short haystacks, use simple comparison
    if (needle.len < 16) {
        return mem.eql(u8, haystack[0..needle.len], needle);
    }

    // SIMD comparison for longer strings
    const Vec16 = @Vector(16, u8);
    var i: usize = 0;

    // Compare 16 bytes at a time
    while (i + 16 <= needle.len) : (i += 16) {
        const hay_vec: Vec16 = haystack[i..][0..16].*;
        const needle_vec: Vec16 = needle[i..][0..16].*;
        const matches = hay_vec == needle_vec;
        const match_mask = @as(u16, @bitCast(matches));

        // All 16 bytes must match
        if (match_mask != 0xFFFF) return false;
    }

    // Check remaining bytes
    return mem.eql(u8, haystack[i..needle.len], needle[i..]);
}

/// SIMD-optimized character class matching using bitmask
/// Tests if character matches any in a character class
pub fn simdMatchCharClass(char: u8, class_chars: []const u8) bool {
    if (class_chars.len == 0) return false;

    // For small classes, simple loop is faster
    if (class_chars.len < 8) {
        for (class_chars) |c| {
            if (c == char) return true;
        }
        return false;
    }

    // For larger classes, use SIMD
    if (class_chars.len >= 16) {
        const Vec16 = @Vector(16, u8);
        const char_vec: Vec16 = @splat(char);

        var i: usize = 0;
        while (i + 16 <= class_chars.len) : (i += 16) {
            const class_vec: Vec16 = class_chars[i..][0..16].*;
            const matches = class_vec == char_vec;
            const match_mask = @as(u16, @bitCast(matches));

            if (match_mask != 0) return true;
        }

        // Check remaining
        for (class_chars[i..]) |c| {
            if (c == char) return true;
        }
        return false;
    }

    // Medium size: unroll manually
    for (class_chars) |c| {
        if (c == char) return true;
    }
    return false;
}

/// Range type for SIMD range matching
const Range = struct { start: u8, end: u8 };

/// SIMD-optimized range checking
/// Tests if character is within any of the provided ranges
pub fn simdMatchRanges(char: u8, ranges: []const Range) bool {
    if (ranges.len == 0) return false;

    // For multiple ranges, SIMD can help
    if (ranges.len >= 8) {
        const Vec8 = @Vector(8, u8);
        const char_vec: Vec8 = @splat(char);

        var i: usize = 0;
        while (i + 8 <= ranges.len) : (i += 8) {
            // Build start and end vectors
            var starts: [8]u8 = undefined;
            var ends: [8]u8 = undefined;
            for (0..8) |j| {
                starts[j] = ranges[i + j].start;
                ends[j] = ranges[i + j].end;
            }

            const start_vec: Vec8 = starts;
            const end_vec: Vec8 = ends;

            // Check if char >= start AND char <= end for each range
            const ge_start = char_vec >= start_vec;
            const le_end = char_vec <= end_vec;
            const in_range = ge_start & le_end;

            const match_mask = @as(u8, @bitCast(in_range));
            if (match_mask != 0) return true;
        }

        // Check remaining ranges
        for (ranges[i..]) |range| {
            if (char >= range.start and char <= range.end) return true;
        }
        return false;
    }

    // Few ranges: simple loop
    for (ranges) |range| {
        if (char >= range.start and char <= range.end) return true;
    }
    return false;
}

/// SIMD-optimized directory name filtering
/// Quickly reject names that don't match basic criteria
pub fn simdQuickReject(name: []const u8, has_dot: bool, starts_with: ?u8) bool {
    if (name.len == 0) return true;

    // Check if name starts with dot when not wanted
    if (has_dot and name[0] == '.') return true;

    // Check if name starts with specific character
    if (starts_with) |ch| {
        if (name[0] != ch) return true;
    }

    return false;
}

/// SIMD-optimized wildcard anchor finder
/// Finds all positions where a literal sequence could match after wildcard
pub fn simdFindAllAnchors(haystack: []const u8, needle: []const u8, positions: []usize, max_positions: usize) usize {
    if (needle.len == 0 or needle.len > haystack.len) return 0;

    var count: usize = 0;
    const first_char = needle[0];

    if (haystack.len >= 16 and needle.len >= 2) {
        const Vec16 = @Vector(16, u8);
        const first_vec: Vec16 = @splat(first_char);
        const second_char = needle[1];
        const second_vec: Vec16 = @splat(second_char);

        var i: usize = 0;
        while (i + 16 < haystack.len and count < max_positions) : (i += 1) {
            // Find first character
            const chunk: Vec16 = haystack[i..][0..16].*;
            const matches = chunk == first_vec;
            const match_mask = @as(u16, @bitCast(matches));

            if (match_mask != 0) {
                // Check second character at next position
                if (i + 1 < haystack.len) {
                    const next_chunk: Vec16 = haystack[i + 1 ..][0..16].*;
                    const next_matches = next_chunk == second_vec;
                    const next_mask = @as(u16, @bitCast(next_matches));

                    // Positions where both first and second char match
                    const both_match = match_mask & next_mask;

                    if (both_match != 0) {
                        // Extract individual positions
                        var mask = both_match;
                        while (mask != 0 and count < max_positions) {
                            const offset = @ctz(mask);
                            positions[count] = i + offset;
                            count += 1;
                            mask &= mask - 1; // Clear lowest bit
                        }
                    }
                }
            }
        }

        // Check remaining with simple search
        while (i <= haystack.len - needle.len and count < max_positions) : (i += 1) {
            if (haystack[i] == first_char and haystack[i + 1] == second_char) {
                positions[count] = i;
                count += 1;
            }
        }
    } else {
        // Fallback for short strings
        var i: usize = 0;
        while (i <= haystack.len - needle.len and count < max_positions) : (i += 1) {
            if (simdFindChar(haystack[i..], first_char)) |_| {
                if (i + needle.len <= haystack.len) {
                    positions[count] = i;
                    count += 1;
                }
            }
        }
    }

    return count;
}

// Public convenience function
pub fn glob(allocator: Allocator, pattern: []const u8, flags: u32) !GlobResult {
    var g = Glob.init(allocator, flags);
    defer g.deinit();
    return try g.glob(pattern);
}
