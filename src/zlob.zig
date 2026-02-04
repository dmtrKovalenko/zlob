const std = @import("std");
const builtin = @import("builtin");
const suffix_match = @import("suffix_match.zig");
const brace_optimizer = @import("brace_optimizer.zig");
const pattern_context_mod = @import("pattern_context.zig");
const flags_mod = @import("flags.zig");
const extglob = @import("extglob.zig");
const walker_mod = @import("walker");
const c = std.c;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const c_zlob = @cImport({
    @cInclude("zlob.h");
});

pub const PatternContext = pattern_context_mod.PatternContext;
pub const PatternTemplate = pattern_context_mod.PatternTemplate;
pub const hasWildcardsSIMD = pattern_context_mod.hasWildcardsSIMD;
pub const indexOfCharSIMD = pattern_context_mod.indexOfCharSIMD;
pub const lastIndexOfCharSIMD = pattern_context_mod.lastIndexOfCharSIMD;
pub const containsExtglob = extglob.containsExtglob;
pub const gitignore = @import("gitignore.zig");
pub const GitIgnore = gitignore.GitIgnore;

const pwd = @cImport({
    @cInclude("pwd.h");
});

/// Directory entry returned by readdir callback
pub const zlob_dirent_t = extern struct {
    d_name: [*:0]const u8, // Null-terminated entry name
    d_type: u8, // Entry type: DT_DIR, DT_REG, DT_UNKNOWN, etc.

    // Comptime assertion: verify Zig struct matches C header struct
    comptime {
        const zig_t = zlob_dirent_t;
        const c_t = c_zlob.zlob_dirent_t;

        if (@sizeOf(zig_t) != @sizeOf(c_t)) {
            @compileError("zlob_dirent_t size mismatch");
        }
        if (@offsetOf(zig_t, "d_name") != @offsetOf(c_t, "d_name")) {
            @compileError("d_name offset mismatch");
        }
        if (@offsetOf(zig_t, "d_type") != @offsetOf(c_t, "d_type")) {
            @compileError("d_type offset mismatch");
        }
    }
};

/// Function pointer types for custom directory access (matches glibc glob_t)
pub const opendir_t = ?*const fn (path: [*:0]const u8) callconv(.c) ?*anyopaque;
pub const readdir_t = ?*const fn (dir: ?*anyopaque) callconv(.c) ?*zlob_dirent_t;
pub const closedir_t = ?*const fn (dir: ?*anyopaque) callconv(.c) void;

// Internal glob result structure (C-style, used internally during refactoring)
// TODO: Remove this entirely once refactoring to pure Zig slices is complete
pub const zlob_t = extern struct {
    zlo_pathc: usize,
    zlo_pathv: [*c][*c]u8,
    zlo_offs: usize,
    zlo_pathlen: [*]usize, // Array of path lengths (parallel to zlo_pathv, for efficient FFI)
    zlo_flags: c_int, // Internal flags

    // ALTDIRFUNC: Custom directory access functions (GNU extension)
    // These are only used when ZLOB_ALTDIRFUNC flag is set
    zlo_opendir: opendir_t = null,
    zlo_readdir: readdir_t = null,
    zlo_closedir: closedir_t = null,

    // Comptime assertion: verify Zig struct matches C header struct
    comptime {
        const zig_t = zlob_t;
        const c_t = c_zlob.zlob_t;

        // Verify struct sizes match
        if (@sizeOf(zig_t) != @sizeOf(c_t)) {
            @compileError("zlob_t size mismatch: Zig=" ++ @typeName(zig_t) ++ " C=" ++ @typeName(c_t));
        }

        // Verify field offsets match
        if (@offsetOf(zig_t, "zlo_pathc") != @offsetOf(c_t, "zlo_pathc")) {
            @compileError("zlo_pathc offset mismatch");
        }
        if (@offsetOf(zig_t, "zlo_pathv") != @offsetOf(c_t, "zlo_pathv")) {
            @compileError("zlo_pathv offset mismatch");
        }
        if (@offsetOf(zig_t, "zlo_offs") != @offsetOf(c_t, "zlo_offs")) {
            @compileError("zlo_offs offset mismatch");
        }
        if (@offsetOf(zig_t, "zlo_pathlen") != @offsetOf(c_t, "zlo_pathlen")) {
            @compileError("zlo_pathlen offset mismatch");
        }
        if (@offsetOf(zig_t, "zlo_flags") != @offsetOf(c_t, "zlo_flags")) {
            @compileError("zlo_flags offset mismatch");
        }
        if (@offsetOf(zig_t, "zlo_opendir") != @offsetOf(c_t, "zlo_opendir")) {
            @compileError("zlo_opendir offset mismatch");
        }
        if (@offsetOf(zig_t, "zlo_readdir") != @offsetOf(c_t, "zlo_readdir")) {
            @compileError("zlo_readdir offset mismatch");
        }
        if (@offsetOf(zig_t, "zlo_closedir") != @offsetOf(c_t, "zlo_closedir")) {
            @compileError("zlo_closedir offset mismatch");
        }
    }
};

pub const DirIterator = struct {
    // For std.fs mode
    std_dir: ?std.fs.Dir = null,
    std_iter: ?std.fs.Dir.Iterator = null,

    // For ALTDIRFUNC mode
    custom_handle: ?*anyopaque = null,
    readdir_fn: readdir_t = null,
    closedir_fn: closedir_t = null,

    // Shared state
    is_altdirfunc: bool = false,

    pub const Entry = struct {
        name: []const u8,
        kind: std.fs.Dir.Entry.Kind,
    };

    pub fn open(path: []const u8, flags: c_int, pzlob: *const zlob_t) !DirIterator {
        return openAt(path, flags, pzlob, null);
    }

    /// Open a directory iterator, optionally relative to a base directory.
    /// If base_dir is null, uses cwd(). ALTDIRFUNC takes precedence if set.
    pub fn openAt(path: []const u8, flags: c_int, pzlob: *const zlob_t, base_dir: ?std.fs.Dir) !DirIterator {
        const use_altdirfunc = (flags & ZLOB_ALTDIRFUNC) != 0 and
            pzlob.zlo_opendir != null and
            pzlob.zlo_readdir != null and
            pzlob.zlo_closedir != null;

        if (use_altdirfunc) {
            // ALTDIRFUNC takes precedence over base_dir
            var path_buf: [4096:0]u8 = undefined;
            if (path.len >= 4096) return error.NameTooLong;
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = 0;

            const handle = pzlob.zlo_opendir.?(&path_buf);
            if (handle == null) return error.FileNotFound;

            return DirIterator{
                .is_altdirfunc = true,
                .custom_handle = handle,
                .readdir_fn = pzlob.zlo_readdir,
                .closedir_fn = pzlob.zlo_closedir,
            };
        } else {
            // Use base_dir if provided, otherwise use cwd
            const root = base_dir orelse std.fs.cwd();
            var dir = root.openDir(path, .{ .iterate = true }) catch |err| {
                return err;
            };
            return DirIterator{
                .is_altdirfunc = false,
                .std_dir = dir,
                .std_iter = dir.iterate(),
            };
        }
    }

    pub fn next(self: *DirIterator) ?Entry {
        if (self.is_altdirfunc) {
            const dir_entry = self.readdir_fn.?(self.custom_handle) orelse return null;
            const name = mem.sliceTo(dir_entry.d_name, 0);
            const kind: std.fs.Dir.Entry.Kind = switch (dir_entry.d_type) {
                4 => .directory, // DT_DIR
                8 => .file, // DT_REG
                10 => .sym_link, // DT_LNK
                else => .unknown,
            };
            return Entry{ .name = name, .kind = kind };
        } else {
            const entry = self.std_iter.?.next() catch return null;
            if (entry) |e| {
                return Entry{ .name = e.name, .kind = e.kind };
            }
            return null;
        }
    }

    pub fn close(self: *DirIterator) void {
        if (self.is_altdirfunc) {
            if (self.closedir_fn) |closedir| {
                closedir(self.custom_handle);
            }
        } else {
            if (self.std_dir) |*dir| {
                dir.close();
            }
        }
    }
};

fn globLiteralPath(allocator: Allocator, path: []const u8, flags: ZlobFlags, pzlob: *zlob_t, base_dir: ?std.fs.Dir) !bool {
    const root = base_dir orelse std.fs.cwd();
    const stat = root.statFile(path) catch {
        return false;
    };

    const is_dir = stat.kind == .directory;
    if (flags.onlydir and !is_dir) {
        return false;
    }

    var return_path = path;
    if (mem.startsWith(u8, path, "./")) {
        return_path = path[2..];
    }

    const needs_slash = flags.mark and is_dir;
    const final_len = return_path.len + (if (needs_slash) @as(usize, 1) else 0);

    var path_copy = try allocator.allocSentinel(u8, final_len, 0);
    @memcpy(path_copy[0..return_path.len], return_path);
    if (needs_slash) {
        path_copy[return_path.len] = '/';
    }

    const path_ptr: [*c]u8 = @ptrCast(path_copy.ptr);

    const pathv_buf = try allocator.alloc([*c]u8, 2);
    const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
    result[0] = path_ptr;
    result[1] = null;

    const pathlen_buf = try allocator.alloc(usize, 1);
    pathlen_buf[0] = final_len; // Length from slice - no strlen()!

    pzlob.zlo_pathc = 1;
    pzlob.zlo_pathv = result;
    pzlob.zlo_pathlen = pathlen_buf.ptr;
    pzlob.zlo_flags = ZLOB_FLAGS_OWNS_STRINGS;

    return true;
}

// ============================================================================
// Flag constants and types - imported from flags.zig (single source of truth)
// ============================================================================
pub const ZLOB_ERR = flags_mod.ZLOB_ERR;
pub const ZLOB_MARK = flags_mod.ZLOB_MARK;
pub const ZLOB_NOSORT = flags_mod.ZLOB_NOSORT;
pub const ZLOB_DOOFFS = flags_mod.ZLOB_DOOFFS;
pub const ZLOB_NOCHECK = flags_mod.ZLOB_NOCHECK;
pub const ZLOB_APPEND = flags_mod.ZLOB_APPEND;
pub const ZLOB_NOESCAPE = flags_mod.ZLOB_NOESCAPE;
pub const ZLOB_PERIOD = flags_mod.ZLOB_PERIOD;
pub const ZLOB_MAGCHAR = flags_mod.ZLOB_MAGCHAR;
pub const ZLOB_ALTDIRFUNC = flags_mod.ZLOB_ALTDIRFUNC;
pub const ZLOB_BRACE = flags_mod.ZLOB_BRACE;
pub const ZLOB_NOMAGIC = flags_mod.ZLOB_NOMAGIC;
pub const ZLOB_TILDE = flags_mod.ZLOB_TILDE;
pub const ZLOB_ONLYDIR = flags_mod.ZLOB_ONLYDIR;
pub const ZLOB_TILDE_CHECK = flags_mod.ZLOB_TILDE_CHECK;
pub const ZLOB_GITIGNORE = flags_mod.ZLOB_GITIGNORE;
pub const ZLOB_DOUBLESTAR_RECURSIVE = flags_mod.ZLOB_DOUBLESTAR_RECURSIVE;
pub const ZLOB_EXTGLOB = flags_mod.ZLOB_EXTGLOB;
pub const ZLOB_RECOMMENDED = flags_mod.ZLOB_RECOMMENDED;
pub const ZLOB_FLAGS_SHARED_STRINGS = flags_mod.ZLOB_FLAGS_SHARED_STRINGS;
pub const ZLOB_FLAGS_OWNS_STRINGS = flags_mod.ZLOB_FLAGS_OWNS_STRINGS;
pub const ZLOB_NOSPACE = flags_mod.ZLOB_NOSPACE;
pub const ZLOB_ABORTED = flags_mod.ZLOB_ABORTED;
pub const ZLOB_NOMATCH = flags_mod.ZLOB_NOMATCH;
pub const ZlobFlags = flags_mod.ZlobFlags;
pub const GlobError = flags_mod.GlobError;

pub const zlob_errfunc_t = ?*const fn (epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int;

// Re-export path_matcher for consumers that need in-memory path matching
pub const path_matcher = @import("path_matcher.zig");

// Use Zig's cross-platform dirent structure
pub const dirent = std.c.dirent;

pub const DT_UNKNOWN = std.c.DT.UNKNOWN;
pub const DT_DIR = std.c.DT.DIR;

/// SIMD-optimized strlen for dirent d_name (max 256 bytes).
/// Uses CPU-optimal vector size to find null terminator quickly.
inline fn direntNameSlice(d_name: *const [256]u8) []const u8 {
    // Use CPU-optimal vector size, fallback to 16 if not available
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
    const Vec = @Vector(vec_len, u8);
    const zeros: Vec = @splat(0);

    // Calculate number of iterations needed (256 / vec_len)
    const iterations = 256 / vec_len;

    inline for (0..iterations) |iter| {
        const i = iter * vec_len;
        const chunk: Vec = d_name[i..][0..vec_len].*;
        const eq = chunk == zeros;
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const mask = @as(MaskInt, @bitCast(eq));
        if (mask != 0) {
            return d_name[0 .. i + @ctz(mask)];
        }
    }
    // Full 256 bytes with no null (shouldn't happen in practice)
    return d_name[0..256];
}

/// List of paths with their lengths tracked in parallel arrays.
/// Maps directly to zlob_t's zlo_pathv and zlo_pathlen fields.
pub const ResultsList = struct {
    paths: std.ArrayListUnmanaged([*c]u8),
    lengths: std.ArrayListUnmanaged(usize),
    allocator: Allocator,

    /// Initialize with zero capacity
    pub fn init(allocator: Allocator) ResultsList {
        return .{
            .paths = .{},
            .lengths = .{},
            .allocator = allocator,
        };
    }

    /// Initialize with pre-allocated capacity to avoid reallocations
    pub fn initWithCapacity(allocator: Allocator, capacity: usize) Allocator.Error!ResultsList {
        var paths = std.ArrayListUnmanaged([*c]u8){};
        var lengths = std.ArrayListUnmanaged(usize){};
        try paths.ensureTotalCapacity(allocator, capacity);
        try lengths.ensureTotalCapacity(allocator, capacity);
        return .{
            .paths = paths,
            .lengths = lengths,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResultsList) void {
        self.paths.deinit(self.allocator);
        self.lengths.deinit(self.allocator);
    }

    pub fn ensureTotalCapacity(self: *ResultsList, capacity: usize) Allocator.Error!void {
        try self.paths.ensureTotalCapacity(self.allocator, capacity);
        try self.lengths.ensureTotalCapacity(self.allocator, capacity);
    }

    /// Add a path with its known length - O(1), no scanning
    pub fn append(self: *ResultsList, ptr: [*c]u8, path_len: usize) Allocator.Error!void {
        try self.paths.append(self.allocator, ptr);
        try self.lengths.append(self.allocator, path_len);
    }

    pub fn len(self: *const ResultsList) usize {
        return self.paths.items.len;
    }

    /// Transfer ownership of the paths array, adding a null terminator.
    /// Returns the buffer with null terminator appended (exact-sized allocation).
    /// After calling this, the ResultsList paths array is invalidated.
    pub fn toOwnedPathv(self: *ResultsList) Allocator.Error![][*c]u8 {
        // Append null terminator - this may realloc if needed
        try self.paths.append(self.allocator, null);
        // Transfer ownership with exact-sized reallocation
        return self.paths.toOwnedSlice(self.allocator);
    }

    /// Transfer ownership of the lengths array (exact-sized allocation).
    /// After calling this, the ResultsList lengths array is invalidated.
    pub fn toOwnedLengths(self: *ResultsList) Allocator.Error![]usize {
        return self.lengths.toOwnedSlice(self.allocator);
    }
};

const PatternInfo = struct {
    literal_prefix: []const u8, // e.g., "src/foo" from "src/foo/*.txt"
    wildcard_start_pos: usize, // Where wildcards begin in pattern
    has_recursive: bool, // Contains **
    wildcard_suffix: []const u8, // Pattern after literal prefix
    max_depth: ?usize, // Max depth for non-recursive patterns
    is_absolute: bool, // Starts with /
    fixed_component_count: usize, // # of fixed dirs before wildcards
    simple_extension: ?[]const u8, // For *.ext patterns (fast path)
    has_dir_wildcards: bool, // Wildcards in directory components
    directories_only: bool, // Only match directories (from ZLOB_ONLYDIR flag)
};

pub fn analyzePattern(pattern: []const u8, flags: ZlobFlags) PatternInfo {
    var info = PatternInfo{
        .literal_prefix = "",
        .wildcard_start_pos = 0,
        .has_recursive = false,
        .wildcard_suffix = pattern,
        .max_depth = null,
        .is_absolute = pattern.len > 0 and pattern[0] == '/',
        .fixed_component_count = 0,
        .simple_extension = null,
        .has_dir_wildcards = false,
        .directories_only = flags.onlydir,
    };

    const enable_escape = !flags.noescape;
    var i: usize = 0;
    var last_slash: usize = 0;
    var component_count: usize = 0;
    var in_bracket = false;

    while (i < pattern.len) : (i += 1) {
        const ch = pattern[i];

        if (enable_escape and ch == '\\' and i + 1 < pattern.len) {
            break;
        }

        if (ch == '[' and !in_bracket) {
            in_bracket = true;
            break; // Can't continue literal prefix through bracket
        }
        if (ch == ']' and in_bracket) {
            in_bracket = false;
        }

        // Check for extglob patterns: ?(...) *(...) +(...) @(...) !(...)
        // When extglob flag is set, these act as wildcards
        if (flags.extglob and i + 1 < pattern.len and pattern[i + 1] == '(') {
            switch (ch) {
                '?', '*', '+', '@', '!' => break, // Extglob pattern found - stop here
                else => {},
            }
        }

        if (ch == '*' or ch == '?') {
            if (ch == '*' and i + 1 < pattern.len and pattern[i + 1] == '*') {
                // Only enable recursive behavior if ZLOB_DOUBLESTAR_RECURSIVE is set
                // Without it, ** is treated as * (glibc-compatible behavior)
                if (flags.doublestar_recursive) {
                    info.has_recursive = true;
                }
            }
            break;
        }

        if (ch == '/') {
            last_slash = i;
            component_count += 1;
        }
    }

    if (i > 0) {
        info.wildcard_start_pos = i;
        if (last_slash > 0) {
            info.literal_prefix = pattern[0..last_slash];
            info.wildcard_suffix = pattern[last_slash + 1 ..];
            info.fixed_component_count = component_count;
        } else if (i == pattern.len) {
            info.literal_prefix = pattern;
            info.wildcard_suffix = "";
            info.fixed_component_count = component_count;
        } else {
            info.literal_prefix = "";
            info.wildcard_suffix = pattern;
            info.fixed_component_count = 0;
        }
    }

    if (info.wildcard_suffix.len > 0) {
        if (mem.lastIndexOf(u8, info.wildcard_suffix, "/")) |pos| {
            const dir_part = info.wildcard_suffix[0..pos];
            info.has_dir_wildcards = pattern_context_mod.hasWildcardsOrExtglob(dir_part, flags.extglob);
        }
    }

    if (!info.has_recursive and !info.has_dir_wildcards and
        info.wildcard_suffix.len >= 2 and info.wildcard_suffix[0] == '*')
    {
        const suffix = info.wildcard_suffix[1..];
        if (!hasWildcardsSIMD(suffix) and indexOfCharSIMD(suffix, '/') == null) {
            info.simple_extension = suffix;
        }
    }

    if (!info.has_recursive) {
        var depth: usize = info.fixed_component_count;
        var remaining = info.wildcard_suffix;
        while (indexOfCharSIMD(remaining, '/')) |pos| {
            depth += 1;
            remaining = remaining[pos + 1 ..];
        }
        if (remaining.len > 0) depth += 1;
        info.max_depth = depth;
    }

    return info;
}

/// Match a name against multiple alternative patterns (from brace expansion)
/// Returns true if name matches ANY of the alternatives
inline fn matchWithAlternatives(name: []const u8, alternatives: []const []const u8) bool {
    for (alternatives) |alt| {
        const ctx = PatternContext.init(alt);
        if (ctx.simd_batched_suffix_match) |batched| {
            if (batched.matchSuffix(name)) return true;
        } else if (fnmatchWithContext(&ctx, name)) {
            return true;
        }
    }
    return false;
}

/// Match a name against a pattern with extglob support
/// Uses extglob matching if enable_extglob is true and pattern contains extglob syntax
inline fn matchWithExtglobSupport(name: []const u8, pattern: []const u8, ctx: *const PatternContext, enable_extglob: bool) bool {
    if (enable_extglob and extglob.containsExtglob(pattern)) {
        initExtglob();
        return extglob.fnmatchExtglob(pattern, name);
    }
    if (ctx.simd_batched_suffix_match) |batched| {
        return batched.matchSuffix(name);
    }
    return fnmatchWithContext(ctx, name);
}

/// Match a name against multiple alternative patterns with extglob support
inline fn matchWithAlternativesExtglob(name: []const u8, alternatives: []const []const u8, enable_extglob: bool) bool {
    for (alternatives) |alt| {
        if (enable_extglob and extglob.containsExtglob(alt)) {
            initExtglob();
            if (extglob.fnmatchExtglob(alt, name)) return true;
        } else {
            const ctx = PatternContext.init(alt);
            if (ctx.simd_batched_suffix_match) |batched| {
                if (batched.matchSuffix(name)) return true;
            } else if (fnmatchWithContext(&ctx, name)) {
                return true;
            }
        }
    }
    return false;
}

/// Match with precomputed contexts, with extglob support
inline fn matchWithAlternativesPrecomputedExtglob(name: []const u8, patterns: []const []const u8, contexts: []const PatternContext, enable_extglob: bool) bool {
    for (patterns, contexts) |pat, *ctx| {
        if (enable_extglob and extglob.containsExtglob(pat)) {
            initExtglob();
            if (extglob.fnmatchExtglob(pat, name)) return true;
        } else {
            if (ctx.simd_batched_suffix_match) |*batched| {
                if (batched.matchSuffix(name)) return true;
            } else if (fnmatchWithContext(ctx, name)) {
                return true;
            }
        }
    }
    return false;
}

fn canMatchPattern(
    dir_path: []const u8,
    current_depth: usize,
    info: *const PatternInfo,
) bool {
    if (info.max_depth) |max| {
        if (current_depth >= max) return false;
    }

    if (info.literal_prefix.len > 0) {
        // or literal_prefix must be a prefix of directory
        if (dir_path.len < info.literal_prefix.len) {
            // dir_path is shorter - must be a prefix of literal_prefix
            return mem.startsWith(u8, info.literal_prefix, dir_path) and
                (info.literal_prefix.len == dir_path.len or
                    info.literal_prefix[dir_path.len] == '/');
        } else {
            // dir_path is longer - literal_prefix must be a prefix
            return mem.startsWith(u8, dir_path, info.literal_prefix) and
                (dir_path.len == info.literal_prefix.len or
                    dir_path[info.literal_prefix.len] == '/');
        }
    }

    return true;
}

fn simdStrCmp(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);

    // Use CPU-optimal vector size
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (min_len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const all_ones: MaskInt = @as(MaskInt, 0) -% 1; // All bits set

        var i: usize = 0;
        while (i + vec_len <= min_len) : (i += vec_len) {
            const a_vec: Vec = a[i..][0..vec_len].*;
            const b_vec: Vec = b[i..][0..vec_len].*;
            const eq = a_vec == b_vec;
            const mask = @as(MaskInt, @bitCast(eq));

            if (mask != all_ones) {
                // Found difference, find first differing byte
                const first_diff = @ctz(~mask);
                const a_byte = a[i + first_diff];
                const b_byte = b[i + first_diff];
                if (a_byte < b_byte) return .lt;
                if (a_byte > b_byte) return .gt;
            }
        }
        // Compare remainder byte-by-byte
        for (a[i..min_len], b[i..min_len]) |a_byte, b_byte| {
            if (a_byte < b_byte) return .lt;
            if (a_byte > b_byte) return .gt;
        }
    } else {
        // Fallback for short strings
        for (a[0..min_len], b[0..min_len]) |a_byte, b_byte| {
            if (a_byte < b_byte) return .lt;
            if (a_byte > b_byte) return .gt;
        }
    }

    // All bytes equal up to min_len, compare lengths
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return .eq;
}

/// Sort context for sorting paths with pre-computed lengths
/// This avoids the O(n) strlen() call per comparison that mem.sliceTo would require
const PathSortContext = struct {
    paths: [*][*c]u8,
    lengths: [*]usize,

    /// Compare two paths using their pre-computed lengths
    /// This is significantly faster than mem.sliceTo which scans for null terminators
    fn lessThan(ctx: PathSortContext, a_idx: usize, b_idx: usize) bool {
        const a_ptr = ctx.paths[a_idx];
        const b_ptr = ctx.paths[b_idx];
        const a_len = ctx.lengths[a_idx];
        const b_len = ctx.lengths[b_idx];

        // Create slices using known lengths - O(1) instead of O(n) for mem.sliceTo
        const slice_a = @as([*]const u8, @ptrCast(a_ptr))[0..a_len];
        const slice_b = @as([*]const u8, @ptrCast(b_ptr))[0..b_len];

        return simdStrCmp(slice_a, slice_b) == .lt;
    }
};

/// Sort paths in-place using pre-computed lengths from zlo_pathlen
/// This is much faster than C's qsort with mem.sliceTo because:
/// 1. We use known lengths instead of scanning for null terminators
/// 2. Zig's sort is cache-friendly and doesn't require function pointer indirection
fn sortPathsWithLengths(paths: [*][*c]u8, lengths: [*]usize, count: usize) void {
    if (count <= 1) return;

    // Create index array for indirect sorting
    // We sort indices and then rearrange paths/lengths accordingly
    var indices_buf: [4096]usize = undefined;
    const indices = indices_buf[0..count];
    for (indices, 0..) |*idx, i| {
        idx.* = i;
    }

    const ctx = PathSortContext{ .paths = paths, .lengths = lengths };
    std.mem.sort(usize, indices, ctx, PathSortContext.lessThan);

    // Rearrange paths and lengths according to sorted indices using cycle sort
    // This is O(n) with O(1) extra space for the swap temps
    var visited_buf: [4096]bool = undefined;
    const visited = visited_buf[0..count];
    @memset(visited, false);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (visited[i] or indices[i] == i) {
            visited[i] = true;
            continue;
        }

        // Follow the cycle
        var j = i;
        const temp_path = paths[i];
        const temp_len = lengths[i];

        while (indices[j] != i) {
            const next = indices[j];
            paths[j] = paths[next];
            lengths[j] = lengths[next];
            visited[j] = true;
            j = next;
        }

        paths[j] = temp_path;
        lengths[j] = temp_len;
        visited[j] = true;
    }
}

fn buildPathInBuffer(buf: []u8, dir: []const u8, name: []const u8) []const u8 {
    var len: usize = 0;

    if (dir.len > 0 and !mem.eql(u8, dir, ".")) {
        @memcpy(buf[0..dir.len], dir);
        len = dir.len;
        buf[len] = '/';
        len += 1;
    }

    @memcpy(buf[len..][0..name.len], name);
    len += name.len;

    return buf[0..len];
}

fn globWithWildcardDirsOptimized(allocator: std.mem.Allocator, pattern: []const u8, info: *const PatternInfo, flags: ZlobFlags, errfunc: zlob_errfunc_t, pzlob: *zlob_t, directories_only: bool, gitignore_filter: ?*GitIgnore, base_dir: ?std.fs.Dir) !?void {
    // Note: gitignore filtering is not fully implemented in this path
    // The main recursive and filtered paths handle gitignore
    _ = gitignore_filter;

    var components: [64][]const u8 = undefined;
    var component_count: usize = 0;

    const effective_pattern = info.wildcard_suffix;

    var start: usize = 0;
    for (effective_pattern, 0..) |ch, idx| {
        if (ch == '/') {
            if (idx > start) {
                components[component_count] = effective_pattern[start..idx];
                component_count += 1;
            }
            start = idx + 1;
        }
    }
    if (start < effective_pattern.len) {
        components[component_count] = effective_pattern[start..];
        component_count += 1;
    }

    const estimated_capacity: usize = if (info.has_recursive)
        1024 // Recursive patterns can match many files
    else if (info.has_dir_wildcards)
        256 // Directory wildcards match moderate number
    else
        64; // Simple wildcards match fewer files

    var result_paths = ResultsList.initWithCapacity(allocator, estimated_capacity) catch ResultsList.init(allocator);
    defer result_paths.deinit();
    errdefer {
        for (result_paths.paths.items, result_paths.lengths.items) |path, path_len| {
            const path_slice = @as([*]u8, @ptrCast(path))[0 .. path_len + 1];
            allocator.free(path_slice);
        }
    }

    const start_dir = if (info.literal_prefix.len > 0)
        info.literal_prefix
    else
        ".";

    try expandWildcardComponents(allocator, start_dir, components[0..component_count], 0, &result_paths, directories_only, flags, errfunc, base_dir);

    if (result_paths.len() == 0) {
        if (flags.nocheck) {
            const pat_copy = allocator.allocSentinel(u8, pattern.len, 0) catch return error.OutOfMemory;
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = allocator.alloc([*c]u8, 2) catch return error.OutOfMemory;
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            const pathlen_buf = allocator.alloc(usize, 1) catch return error.OutOfMemory;
            pathlen_buf[0] = pattern.len;

            pzlob.zlo_pathc = 1;
            pzlob.zlo_pathv = result;
            pzlob.zlo_pathlen = pathlen_buf.ptr;
            pzlob.zlo_flags = ZLOB_FLAGS_OWNS_STRINGS;
            return;
        }
        return null;
    }

    // Note: sorting is now handled inside finalizeResults using pre-computed lengths
    return finalizeResults(allocator, &result_paths, flags, pzlob);
}

// Recursive helper to expand wildcard components level by level
fn expandWildcardComponents(
    allocator: std.mem.Allocator,
    current_dir: []const u8,
    components: []const []const u8,
    component_idx: usize,
    results: *ResultsList,
    directories_only: bool,
    flags: ZlobFlags,
    errfunc: zlob_errfunc_t,
    base_dir: ?std.fs.Dir,
) !void {
    if (component_idx > 65536) {
        @branchHint(.unlikely);
        return error.Aborted;
    }

    if (component_idx >= components.len) {
        const path_copy = try allocator.allocSentinel(u8, current_dir.len, 0);
        @memcpy(path_copy[0..current_dir.len], current_dir);
        const path: [*c]u8 = @ptrCast(path_copy.ptr);
        try results.append(path, current_dir.len);
        return;
    }

    const component = components[component_idx];
    const is_final = component_idx == components.len - 1;

    const component_ctx = PatternContext.init(component);
    const enable_extglob = flags.extglob;
    const has_extglob_pattern = enable_extglob and extglob.containsExtglob(component);
    const needs_wildcard_matching = component_ctx.has_wildcards or has_extglob_pattern;

    if (needs_wildcard_matching) {
        // Wildcard or extglob component - match against directory entries
        // If base_dir is provided, use Zig's fs; otherwise use C's opendir
        if (base_dir) |bd| {
            var dir = bd.openDir(current_dir, .{ .iterate = true }) catch {
                if (flags.err) return error.Aborted;
                return;
            };
            defer dir.close();

            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                const name = entry.name;
                if (!is_final and entry.kind != .directory) continue;
                if (shouldSkipFile(name, &component_ctx, flags)) continue;

                const matches = if (has_extglob_pattern) blk: {
                    initExtglob();
                    break :blk extglob.fnmatchExtglob(component, name);
                } else if (is_final and component_ctx.simd_batched_suffix_match != null)
                    component_ctx.simd_batched_suffix_match.?.matchSuffix(name)
                else
                    fnmatchWithContext(&component_ctx, name);

                if (matches) {
                    if (is_final and directories_only and entry.kind != .directory) continue;

                    var new_path_buf: [4096]u8 = undefined;
                    const new_path = buildPathInBuffer(&new_path_buf, current_dir, name);
                    if (new_path.len >= 4096) continue;

                    try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only, flags, errfunc, base_dir);
                }
            }
        } else {
            // C-based path
            var dirname_z: [4096:0]u8 = undefined;
            if (current_dir.len >= 4096) return error.OutOfMemory;
            @memcpy(dirname_z[0..current_dir.len], current_dir);
            dirname_z[current_dir.len] = 0;

            const dir = c.opendir(&dirname_z) orelse {
                if (errfunc) |efunc| {
                    const eerrno = @as(c_int, @intFromEnum(std.posix.errno(-1)));
                    if (efunc(&dirname_z, eerrno) != 0) {
                        return error.Aborted;
                    }
                }
                if (flags.err) return error.Aborted;
                return;
            };
            defer _ = c.closedir(dir);

            while (c.readdir(dir)) |entry_raw| {
                const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
                const name = direntNameSlice(&entry.name);

                if (!is_final and entry.type != DT_DIR) continue;
                if (shouldSkipFile(name, &component_ctx, flags)) continue;

                const matches = if (has_extglob_pattern) blk: {
                    initExtglob();
                    break :blk extglob.fnmatchExtglob(component, name);
                } else if (is_final and component_ctx.simd_batched_suffix_match != null)
                    component_ctx.simd_batched_suffix_match.?.matchSuffix(name)
                else
                    fnmatchWithContext(&component_ctx, name);

                if (matches) {
                    if (is_final and directories_only and entry.type != DT_DIR) continue;

                    var new_path_buf: [4096]u8 = undefined;
                    const new_path = buildPathInBuffer(&new_path_buf, current_dir, name);
                    if (new_path.len >= 4096) continue;

                    try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only, flags, errfunc, null);
                }
            }
        }
    } else {
        // Literal component - just check if it exists
        var new_path_buf: [4096]u8 = undefined;
        const new_path = buildPathInBuffer(&new_path_buf, current_dir, component);

        if (new_path.len >= 4096) return;

        if (base_dir) |bd| {
            const stat = bd.statFile(new_path) catch return;
            if (!is_final and stat.kind != .directory) return;
            if (is_final and directories_only and stat.kind != .directory) return;
            try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only, flags, errfunc, base_dir);
        } else {
            var path_z: [4096:0]u8 = undefined;
            @memcpy(path_z[0..new_path.len], new_path);
            path_z[new_path.len] = 0;

            var stat_buf: std.c.Stat = undefined;
            if (std.c.stat(&path_z, &stat_buf) == 0) {
                if (!is_final and !std.c.S.ISDIR(stat_buf.mode)) return;
                if (is_final and directories_only and !std.c.S.ISDIR(stat_buf.mode)) return;
                try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only, flags, errfunc, null);
            }
        }
    }
}

fn globSingle(allocator: std.mem.Allocator, pattern: []const u8, brace_parsed: ?*const brace_optimizer.BracedPattern, flags_in: ZlobFlags, errfunc: zlob_errfunc_t, pzlob: *zlob_t, gitignore_filter: ?*GitIgnore, base_dir: ?std.fs.Dir) !?void {
    var effective_pattern = pattern;
    var flags = flags_in;

    if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
        flags.onlydir = true;
        effective_pattern = pattern[0 .. pattern.len - 1];

        if (effective_pattern.len == 0) {
            effective_pattern = ".";
        }
    }

    // FAST PATH: Literal pattern optimization (no wildcards)
    // This is the most common case and libc glob optimizes it to a single stat() call
    // NOTE: Skip if pattern starts with tilde (needs tilde expansion first)
    // NOTE: Skip if we have brace alternatives - they need to be expanded
    // NOTE: Skip if extglob is enabled and pattern contains extglob syntax
    const needs_tilde_expansion = effective_pattern.len > 0 and effective_pattern[0] == '~';
    const has_brace_alternatives = brace_parsed != null;
    const has_extglob_pattern = flags.extglob and extglob.containsExtglob(effective_pattern);
    if (!hasWildcardsSIMD(effective_pattern) and !needs_tilde_expansion and !has_brace_alternatives and !has_extglob_pattern) {
        // Check gitignore for literal path
        if (gitignore_filter) |gi| {
            const root = base_dir orelse std.fs.cwd();
            const stat = root.statFile(effective_pattern) catch null;
            const is_dir = if (stat) |s| s.kind == .directory else false;
            if (gi.isIgnored(effective_pattern, is_dir)) {
                if (flags.nocheck) {
                    return returnPatternAsResult(allocator, effective_pattern, pzlob);
                }
                return null;
            }
        }

        // Try to match literal path
        const found = try globLiteralPath(allocator, effective_pattern, flags, pzlob, base_dir);
        if (found) return;

        if (flags.nocheck) {
            return returnPatternAsResult(allocator, effective_pattern, pzlob);
        }

        return null;
    }

    const info = analyzePattern(effective_pattern, flags);

    // Handle braced patterns without ** using single-walk approach
    // This covers:
    // - "{src,lib}/*.c" - braces in directory
    // - "common/*/*.{rs,toml}" - braces in filename with wildcard dirs
    // - "{src,lib}/*/*.{c,h}" - braces in both
    // Skip if pattern has ** - those go through globRecursive
    if (brace_parsed) |parsed| {
        if (!parsed.has_recursive) {
            // Check if we need the braced component walker:
            // 1. Any non-last component has alternatives, OR
            // 2. Last component has alternatives AND there are wildcards in directory part
            var has_dir_alternatives = false;
            var has_file_alternatives = false;
            var has_dir_wildcards = false;

            for (parsed.components) |comp| {
                if (comp.is_last) {
                    has_file_alternatives = comp.alternatives != null;
                } else {
                    if (comp.alternatives != null) {
                        has_dir_alternatives = true;
                    }
                    // Check for wildcards in non-last components
                    for (comp.text) |ch| {
                        if (ch == '*' or ch == '?' or ch == '[') {
                            has_dir_wildcards = true;
                            break;
                        }
                    }
                }
            }

            if (has_dir_alternatives or (has_file_alternatives and has_dir_wildcards)) {
                return globWithBracedComponents(allocator, parsed, &info, flags, errfunc, pzlob, info.directories_only, gitignore_filter, base_dir);
            }
        }
    }

    // Fast path: simple pattern with literal prefix (e.g., "src/foo/*.txt")
    if (info.simple_extension != null and info.literal_prefix.len > 0) {
        return globInDirFiltered(allocator, info.wildcard_suffix, info.literal_prefix, flags, errfunc, pzlob, info.directories_only, gitignore_filter, brace_parsed, base_dir);
    }

    // Only use recursive glob handling if ZLOB_DOUBLESTAR_RECURSIVE is set
    // Without it, ** is treated as * (glibc-compatible behavior)
    if (flags.doublestar_recursive) {
        if (mem.indexOf(u8, effective_pattern, "**")) |double_star_pos| {
            var dirname_buf: [4096:0]u8 = undefined;
            var dirname: []const u8 = ".";
            var pattern_from_doublestar: []const u8 = effective_pattern;

            // Look for slash before **
            if (double_star_pos > 0) {
                var last_slash_before: ?usize = null;
                var i: usize = double_star_pos;
                while (i > 0) {
                    i -= 1;
                    if (effective_pattern[i] == '/') {
                        last_slash_before = i;
                        break;
                    }
                }

                if (last_slash_before) |slash_pos| {
                    // e.g., "foo/bar/**/*.c" → dirname="foo/bar", pattern="**/*.c"
                    @memcpy(dirname_buf[0..slash_pos], effective_pattern[0..slash_pos]);
                    dirname_buf[slash_pos] = 0;
                    dirname = dirname_buf[0..slash_pos];
                    pattern_from_doublestar = effective_pattern[slash_pos + 1 ..];
                } else {
                    // e.g., "./**/*.c" → dirname=".", pattern="**/*.c"
                    @memcpy(dirname_buf[0..double_star_pos], effective_pattern[0..double_star_pos]);
                    dirname_buf[double_star_pos] = 0;
                    dirname = dirname_buf[0..double_star_pos];
                    pattern_from_doublestar = effective_pattern[double_star_pos..];
                }
            }

            return globRecursive(allocator, pattern_from_doublestar, dirname, flags, errfunc, pzlob, info.directories_only, brace_parsed, gitignore_filter, base_dir);
        }
    }

    // If yes, need recursive directory expansion (slow path)
    var last_slash_pos: usize = 0;
    var i: usize = effective_pattern.len;
    while (i > 0) {
        i -= 1;
        if (effective_pattern[i] == '/') {
            last_slash_pos = i;
            break;
        }
    }

    var has_wildcard_in_dir = false;
    if (last_slash_pos > 0) {
        const dir_part = effective_pattern[0..last_slash_pos];
        // Check for traditional wildcards
        for (dir_part) |ch| {
            if (ch == '*' or ch == '?' or ch == '[') {
                has_wildcard_in_dir = true;
                break;
            }
        }
        // Also check for extglob patterns when extglob is enabled
        if (!has_wildcard_in_dir and flags.extglob and extglob.containsExtglob(dir_part)) {
            has_wildcard_in_dir = true;
        }
    }

    // But skip if pattern has ** (needs special recursive handling)
    if (has_wildcard_in_dir and !info.has_recursive) {
        return globWithWildcardDirsOptimized(allocator, effective_pattern, &info, flags, errfunc, pzlob, info.directories_only, gitignore_filter, base_dir);
    }

    var dir_end: usize = 0;
    i = effective_pattern.len;
    while (i > 0) {
        i -= 1;
        if (effective_pattern[i] == '/') {
            dir_end = i;
            break;
        }
    }

    var dirname_buf: [4096:0]u8 = undefined;
    var dirname: []const u8 = ".";
    var filename_pattern: []const u8 = effective_pattern;

    if (dir_end > 0) {
        @memcpy(dirname_buf[0..dir_end], effective_pattern[0..dir_end]);
        dirname_buf[dir_end] = 0;
        dirname = dirname_buf[0..dir_end];
        filename_pattern = effective_pattern[dir_end + 1 ..];
    }

    // Only check for ** in filename if doublestar_recursive is enabled
    if (flags.doublestar_recursive) {
        if (mem.indexOf(u8, filename_pattern, "**")) |_| {
            return globRecursive(allocator, filename_pattern, dirname, flags, errfunc, pzlob, info.directories_only, brace_parsed, gitignore_filter, base_dir);
        }
    }

    return globInDirFiltered(allocator, filename_pattern, dirname, flags, errfunc, pzlob, info.directories_only, gitignore_filter, brace_parsed, base_dir);
}

/// Helper to return pattern as result (for ZLOB_NOCHECK)
fn returnPatternAsResult(allocator: std.mem.Allocator, pattern: []const u8, pzlob: *zlob_t) !?void {
    const path_copy = try allocator.allocSentinel(u8, pattern.len, 0);
    @memcpy(path_copy[0..pattern.len], pattern);
    const path: [*c]u8 = @ptrCast(path_copy.ptr);

    const pathv_buf = try allocator.alloc([*c]u8, 2);
    const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
    result[0] = path;
    result[1] = null;

    const pathlen_buf = try allocator.alloc(usize, 1);
    pathlen_buf[0] = pattern.len;

    pzlob.zlo_pathc = 1;
    pzlob.zlo_pathv = result;
    pzlob.zlo_pathlen = pathlen_buf.ptr;
    pzlob.zlo_flags = ZLOB_FLAGS_OWNS_STRINGS;
    return;
}

// Helper to expand tilde (~) in patterns

//   - The expanded pattern (allocated if expanded, original if no tilde)
//   - null if ZLOB_TILDE_CHECK is set and expansion fails (indicates no match)
fn expandTilde(allocator: std.mem.Allocator, pattern: [:0]const u8, flags: ZlobFlags) !?[:0]const u8 {
    if (pattern.len == 0 or pattern[0] != '~') {
        return pattern; // No tilde, return as-is
    }

    var username_end: usize = 1;
    while (username_end < pattern.len and pattern[username_end] != '/') : (username_end += 1) {}

    const home_dir = if (username_end == 1) blk: {
        // Just "~" or "~/..." - expand to $HOME
        break :blk std.posix.getenv("HOME");
    } else blk: {
        // "~username" - use getpwnam to look up user's home directory
        const username = pattern[1..username_end];

        // Need null-terminated username for getpwnam
        var username_z: [256]u8 = undefined;
        if (username.len >= 256) {
            if (flags.tilde_check) {
                return null; // Indicate no match
            }
            break :blk null;
        }
        @memcpy(username_z[0..username.len], username);
        username_z[username.len] = 0;

        const pw_entry = pwd.getpwnam(&username_z);
        if (pw_entry == null) {
            if (flags.tilde_check) {
                return null; // Indicate no match
            }
            break :blk null;
        }

        const home_cstr = pw_entry.*.pw_dir;
        if (home_cstr == null) {
            if (flags.tilde_check) {
                return null; // Indicate no match
            }
            break :blk null;
        }
        break :blk mem.sliceTo(home_cstr, 0);
    };

    if (home_dir) |home| {
        const rest = pattern[username_end..];
        const new_pattern = try allocator.allocSentinel(u8, home.len + rest.len, 0);
        @memcpy(new_pattern[0..home.len], home);
        @memcpy(new_pattern[home.len..][0..rest.len], rest);
        return new_pattern;
    }

    // No home directory found - return pattern as-is (literal ~)
    return pattern;
}

/// This is the root logic function for globbing
pub fn glob(allocator: std.mem.Allocator, pattern: [*:0]const u8, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t) !?void {
    return globInternal(allocator, pattern, flags, errfunc, pzlob, null);
}

/// Glob within a specific base directory.
/// base_path must be an absolute path (starts with '/'), otherwise returns error.Aborted.
pub fn globAt(allocator: std.mem.Allocator, base_path: []const u8, pattern: [*:0]const u8, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t) !?void {
    // Validate that base_path is absolute
    if (base_path.len == 0 or base_path[0] != '/') {
        return error.Aborted;
    }

    // Open the base directory
    var base_dir = std.fs.openDirAbsolute(base_path, .{ .iterate = true }) catch {
        return error.Aborted;
    };
    defer base_dir.close();

    return globInternal(allocator, pattern, flags, errfunc, pzlob, base_dir);
}

/// Internal glob implementation that accepts an optional base directory
fn globInternal(allocator: std.mem.Allocator, pattern: [*:0]const u8, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t, base_dir: ?std.fs.Dir) !?void {
    const gf = ZlobFlags.fromInt(flags);
    if (!gf.append) {
        pzlob.zlo_pathc = 0;
        pzlob.zlo_pathv = null;
        if (!gf.dooffs) {
            pzlob.zlo_offs = 0;
        }
    }

    var pattern_slice = mem.sliceTo(pattern, 0);
    const original_pattern_ptr = pattern_slice.ptr;

    var expanded_pattern: ?[:0]const u8 = null;
    defer if (expanded_pattern) |exp| {
        // Only free if we allocated a new pattern (not the original)
        if (exp.ptr != original_pattern_ptr) {
            const exp_mem = @as([*]const u8, exp.ptr)[0 .. exp.len + 1];
            allocator.free(exp_mem);
        }
    };

    // Load gitignore if ZLOB_GITIGNORE flag is set
    var gitignore_instance: ?GitIgnore = null;
    defer if (gitignore_instance) |*gi| gi.deinit();

    if (gf.gitignore) {
        // TODO: For globAt, we should load .gitignore relative to base_dir
        gitignore_instance = GitIgnore.loadFromCwd(allocator) catch null;
    }
    const gitignore_ptr: ?*GitIgnore = if (gitignore_instance) |*gi| gi else null;

    if (gf.tilde) {
        expanded_pattern = try expandTilde(allocator, pattern_slice, gf);
        if (expanded_pattern == null) {
            // ZLOB_TILDE_CHECK is set and tilde expansion failed - no match
            return null;
        }
        pattern_slice = expanded_pattern.?;
    }

    if (gf.brace and brace_optimizer.containsBraces(pattern_slice)) {
        var opt = brace_optimizer.analyzeBracedPattern(allocator, pattern_slice) catch {
            // On error, fall back to standard brace expansion
            return try globBraceExpand(allocator, pattern_slice, gf, errfunc, pzlob, gitignore_ptr, base_dir);
        };
        defer opt.deinit();

        switch (opt) {
            .single_walk => |*brace_parsed| {
                // All single_walk patterns flow through globSingle
                // which handles braces in any position via globRecursive
                return try globSingle(
                    allocator,
                    pattern_slice,
                    brace_parsed,
                    gf,
                    errfunc,
                    pzlob,
                    gitignore_ptr,
                    base_dir,
                );
            },
            .fallback => {
                return try globBraceExpand(allocator, pattern_slice, gf, errfunc, pzlob, gitignore_ptr, base_dir);
            },
            .no_braces => {
                return try globBraceExpand(allocator, pattern_slice, gf, errfunc, pzlob, gitignore_ptr, base_dir);
            },
        }
    }

    return try globSingle(allocator, pattern_slice, null, gf, errfunc, pzlob, gitignore_ptr, base_dir);
}

// Expand brace patterns and glob each independently (no ZLOB_APPEND manipulation)
fn globBraceExpand(allocator: std.mem.Allocator, pattern: []const u8, flags: ZlobFlags, errfunc: zlob_errfunc_t, pzlob: *zlob_t, gitignore_filter: ?*GitIgnore, base_dir: ?std.fs.Dir) !?void {
    // Use brace_optimizer.expandBraces for consistent nested brace handling
    const expanded = try brace_optimizer.expandBraces(allocator, pattern);
    defer {
        for (expanded) |item| {
            allocator.free(item);
        }
        allocator.free(expanded);
    }

    // Collect all results from all expanded patterns
    // Estimate capacity based on number of expanded patterns
    var all_results = ResultsList.initWithCapacity(allocator, expanded.len * 64) catch ResultsList.init(allocator);
    defer all_results.deinit();

    // Glob each expanded pattern independently (NO ZLOB_APPEND)
    for (expanded) |exp_slice| {
        // Create a temporary pzlob for this pattern
        var temp_pzlob: zlob_t = undefined;
        temp_pzlob.zlo_pathc = 0;
        temp_pzlob.zlo_pathv = null;
        temp_pzlob.zlo_offs = 0;

        _ = try globSingle(allocator, exp_slice, null, flags.without(.{ .append = true }), errfunc, &temp_pzlob, gitignore_filter, base_dir);

        // Collect results from temp_pzlob
        if (temp_pzlob.zlo_pathc > 0) {
            for (0..temp_pzlob.zlo_pathc) |i| {
                try all_results.append(temp_pzlob.zlo_pathv[i], temp_pzlob.zlo_pathlen[i]);
            }
            // Don't free the paths yet, we're transferring ownership
            // Free the pathv array and pathlen array, but not the paths themselves
            if (temp_pzlob.zlo_flags & ZLOB_FLAGS_OWNS_STRINGS != 0) {
                allocator.free(@as([*]const [*c]u8, @ptrCast(temp_pzlob.zlo_pathv))[0 .. temp_pzlob.zlo_pathc + 1]);
                allocator.free(@as([*]const usize, @ptrCast(temp_pzlob.zlo_pathlen))[0..temp_pzlob.zlo_pathc]);
            }
        }
    }

    if (all_results.len() == 0) {
        if (flags.nocheck) {
            const pat_copy = try allocator.allocSentinel(u8, pattern.len, 0);
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = try allocator.alloc([*c]u8, 2);
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            const pathlen_buf = try allocator.alloc(usize, 1);
            pathlen_buf[0] = pattern.len;

            pzlob.zlo_pathc = 1;
            pzlob.zlo_pathv = result;
            pzlob.zlo_pathlen = pathlen_buf.ptr;
            pzlob.zlo_flags = ZLOB_FLAGS_OWNS_STRINGS;
            return;
        }
        return null;
    }

    const count = all_results.len();

    // Transfer ownership directly from ResultsList - avoids allocation and copy
    const pathv_buf = try all_results.toOwnedPathv();
    const pathlen_buf = try all_results.toOwnedLengths();

    const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

    // Sort using pre-computed lengths - no strlen() calls!
    if (!flags.nosort) {
        sortPathsWithLengths(@ptrCast(result), pathlen_buf.ptr, count);
    }

    pzlob.zlo_pathc = count;
    pzlob.zlo_pathv = result;
    pzlob.zlo_pathlen = pathlen_buf.ptr;
    pzlob.zlo_flags = ZLOB_FLAGS_OWNS_STRINGS;
    return;
}

const RecursivePattern = struct {
    dir_components: []const []const u8, // Directory components to match (e.g., [".zlob_test_nested"])
    file_pattern: []const u8, // Final filename pattern (e.g., "*.txt")
    /// Optional: alternatives for each dir component (from brace expansion)
    /// If non-null, dir_component_alternatives[i] contains alternatives for dir_components[i]
    dir_component_alternatives: ?[]const ?[]const []const u8 = null,
    /// Optional: alternatives for file pattern (from brace expansion like *.{rs,toml})
    file_alternatives: ?[]const []const u8 = null,
    /// Pre-computed pattern contexts for file alternatives (key optimization!)
    file_pattern_contexts: ?[]const PatternContext = null,
    /// Optional gitignore filter (for ZLOB_GITIGNORE flag)
    gitignore_filter: ?*GitIgnore = null,
};

inline fn matchWithAlternativesPrecomputed(name: []const u8, contexts: []const PatternContext) bool {
    for (contexts) |*ctx| {
        if (ctx.simd_batched_suffix_match) |*batched| {
            if (batched.matchSuffix(name)) return true;
        } else if (fnmatchWithContext(ctx, name)) {
            return true;
        }
    }
    return false;
}

fn globRecursive(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: ZlobFlags, errfunc: zlob_errfunc_t, pzlob: *zlob_t, directories_only: bool, brace_parsed: ?*const brace_optimizer.BracedPattern, gitignore_filter: ?*GitIgnore, base_dir: ?std.fs.Dir) !?void {
    const info = analyzePattern(pattern, flags);

    // Split pattern at **
    const double_star_pos = mem.indexOf(u8, pattern, "**") orelse return globInDirFiltered(allocator, pattern, dirname, flags, errfunc, pzlob, directories_only, gitignore_filter, brace_parsed, base_dir);

    var after_double_star = pattern[double_star_pos + 2 ..];

    if (after_double_star.len > 0 and after_double_star[0] == '/') {
        after_double_star = after_double_star[1..];
    }

    // If ** is at the end, match everything recursively
    if (after_double_star.len == 0) {
        after_double_star = "*";
    }

    // Determine start directory and components
    // For patterns like "{src,lib}/**/*.rs", we need to:
    // 1. Identify "pre-doublestar" components that must be matched FIRST
    // 2. Then do recursive walk with "post-doublestar" components
    var start_dir_buf: [4096]u8 = undefined;
    var start_dir: []const u8 = dirname;
    var pre_ds_components_buf: [32][]const u8 = undefined;
    var pre_ds_alternatives_buf: [32]?[]const []const u8 = undefined;
    var pre_ds_count: usize = 0;
    var post_ds_components_buf: [32][]const u8 = undefined;
    var post_ds_alternatives_buf: [32]?[]const []const u8 = undefined;
    var post_ds_count: usize = 0;
    var file_pattern = after_double_star;
    var file_alternatives: ?[]const []const u8 = null;
    var file_pattern_contexts: ?[]const PatternContext = null;

    if (brace_parsed) |parsed| {
        // Find the ** component index
        var double_star_idx: ?usize = null;
        for (parsed.components, 0..) |comp, i| {
            if (mem.eql(u8, comp.text, "**")) {
                double_star_idx = i;
                break;
            }
        }

        if (double_star_idx) |ds_idx| {
            // Process components BEFORE **
            var literal_prefix_end: usize = 0;
            for (parsed.components[0..ds_idx], 0..) |comp, i| {
                if (comp.alternatives != null or hasWildcardsSIMD(comp.text)) {
                    break;
                }
                literal_prefix_end = i + 1;
            }

            // Build start directory from literal prefix components
            if (literal_prefix_end > 0) {
                // Build full path from literal components
                var path_len: usize = 0;
                for (parsed.components[0..literal_prefix_end], 0..) |comp, i| {
                    if (i > 0) {
                        start_dir_buf[path_len] = '/';
                        path_len += 1;
                    }
                    @memcpy(start_dir_buf[path_len..][0..comp.text.len], comp.text);
                    path_len += comp.text.len;
                }
                start_dir = start_dir_buf[0..path_len];
            } else {
                // No literal prefix - braces start immediately (e.g., "{src,lib}/**/*.rs")
                // Start from "." and use pre_ds_components to match braced dirs
                start_dir = ".";
            }

            // Components with wildcards/braces BEFORE ** are "pre-doublestar" components
            for (parsed.components[literal_prefix_end..ds_idx]) |comp| {
                if (pre_ds_count < 32) {
                    pre_ds_components_buf[pre_ds_count] = comp.text;
                    pre_ds_alternatives_buf[pre_ds_count] = comp.alternatives;
                    pre_ds_count += 1;
                }
            }

            // Components AFTER ** (excluding file pattern)
            const after_ds = parsed.components[ds_idx + 1 ..];
            if (after_ds.len > 0) {
                // Last component is file pattern
                const last_comp = after_ds[after_ds.len - 1];
                file_pattern = last_comp.text;
                file_alternatives = last_comp.alternatives;
                file_pattern_contexts = last_comp.pattern_contexts;

                // Middle components (between ** and file) are post-doublestar dir components
                for (after_ds[0 .. after_ds.len - 1]) |comp| {
                    if (post_ds_count < 32) {
                        post_ds_components_buf[post_ds_count] = comp.text;
                        post_ds_alternatives_buf[post_ds_count] = comp.alternatives;
                        post_ds_count += 1;
                    }
                }
            }
        } else {
            // No ** in parsed pattern - shouldn't happen but handle gracefully
            if (parsed.components.len > 0) {
                const last_comp = parsed.components[parsed.components.len - 1];
                file_alternatives = last_comp.alternatives;
                file_pattern_contexts = last_comp.pattern_contexts;
            }
        }
    } else {
        // No brace_parsed - use traditional pattern parsing
        if (info.literal_prefix.len > 0) {
            start_dir = info.literal_prefix;
        }

        // Parse dir components from after_double_star
        if (mem.lastIndexOf(u8, after_double_star, "/")) |last_slash| {
            file_pattern = after_double_star[last_slash + 1 ..];
            const dir_path = after_double_star[0..last_slash];

            var start: usize = 0;
            for (dir_path, 0..) |ch, i| {
                if (ch == '/') {
                    if (i > start and post_ds_count < 32) {
                        post_ds_components_buf[post_ds_count] = dir_path[start..i];
                        post_ds_alternatives_buf[post_ds_count] = null;
                        post_ds_count += 1;
                    }
                    start = i + 1;
                }
            }
            if (start < dir_path.len and post_ds_count < 32) {
                post_ds_components_buf[post_ds_count] = dir_path[start..];
                post_ds_alternatives_buf[post_ds_count] = null;
                post_ds_count += 1;
            }
        }
    }

    // RecursivePattern only handles post-doublestar components
    const rec_pattern = RecursivePattern{
        .dir_components = post_ds_components_buf[0..post_ds_count],
        .file_pattern = file_pattern,
        .file_alternatives = file_alternatives,
        .file_pattern_contexts = file_pattern_contexts,
        .dir_component_alternatives = if (post_ds_count > 0) post_ds_alternatives_buf[0..post_ds_count] else null,
        .gitignore_filter = gitignore_filter,
    };

    // OPTIMIZATION: Use ArrayList to accumulate ALL results, avoiding O(n²) append behavior
    // Instead of using ZLOB_APPEND which reallocates pathv for every directory,
    // we collect all results in a list and convert to pathv once at the end
    // Pre-allocate capacity - recursive globs can match many thousands of files
    var all_results = ResultsList.initWithCapacity(allocator, 8192) catch ResultsList.init(allocator);
    defer all_results.deinit();

    // Handle pre-doublestar components (braces BEFORE **)
    // e.g., "{src,lib}/**/*.rs" - need to find matching dirs first, then recurse into each
    if (pre_ds_count > 0) {
        try globRecursiveWithBracedPrefix(
            allocator,
            &rec_pattern,
            start_dir,
            pre_ds_components_buf[0..pre_ds_count],
            pre_ds_alternatives_buf[0..pre_ds_count],
            0, // start at first pre-ds component
            flags,
            &all_results,
            &info,
            errfunc,
            base_dir,
        );
    } else if (post_ds_count == 0) {
        // No dir components at all - use Zig walker which produces slices directly
        try globRecursiveWithZigWalk(allocator, &rec_pattern, start_dir, flags, &all_results, &info, errfunc, base_dir);
    } else {
        // Has post-doublestar dir components - use C-based recursive helper
        try globRecursiveHelperCollect(allocator, &rec_pattern, start_dir, flags, &all_results, 0, &info, errfunc, base_dir);
    }

    if (all_results.len() == 0) {
        return null;
    }

    // Note: sorting is now handled inside finalizeResults using pre-computed lengths
    return finalizeResults(allocator, &all_results, flags, pzlob);
}

/// Handle non-recursive patterns with braced directory components
/// e.g., "{src,lib}/*.c", "{a,b}/{x,y}/*.txt"
/// Walks components using alternatives where present
fn globWithBracedComponents(
    allocator: std.mem.Allocator,
    parsed: *const brace_optimizer.BracedPattern,
    info: *const PatternInfo,
    flags: ZlobFlags,
    errfunc: zlob_errfunc_t,
    pzlob: *zlob_t,
    directories_only: bool,
    gitignore_filter: ?*GitIgnore,
    base_dir: ?std.fs.Dir,
) !?void {
    _ = gitignore_filter; // TODO: Apply gitignore filtering

    var all_results = ResultsList.initWithCapacity(allocator, 2048) catch ResultsList.init(allocator);
    defer all_results.deinit();

    // Find the literal prefix - components without wildcards or braces
    var literal_prefix_end: usize = 0;
    for (parsed.components, 0..) |comp, i| {
        // Stop if we find wildcards or braces
        if (comp.alternatives != null) break;
        var has_wildcard = false;
        for (comp.text) |ch| {
            if (ch == '*' or ch == '?' or ch == '[') {
                has_wildcard = true;
                break;
            }
        }
        // Also check for extglob patterns if extglob is enabled
        if (flags.extglob and extglob.containsExtglob(comp.text)) {
            has_wildcard = true;
        }
        if (has_wildcard) break;
        literal_prefix_end = i + 1;
    }

    // Build start directory from literal prefix components
    var start_dir_buf: [4096]u8 = undefined;
    var start_dir: []const u8 = ".";
    var start_component_idx: usize = 0;

    if (literal_prefix_end > 0) {
        var path_len: usize = 0;

        // For absolute paths, start with "/"
        if (info.is_absolute) {
            start_dir_buf[0] = '/';
            path_len = 1;
        }

        for (parsed.components[0..literal_prefix_end], 0..) |comp, i| {
            if (i > 0 or (i == 0 and info.is_absolute)) {
                if (path_len > 1 or (path_len == 1 and !info.is_absolute)) {
                    start_dir_buf[path_len] = '/';
                    path_len += 1;
                }
            }
            @memcpy(start_dir_buf[path_len..][0..comp.text.len], comp.text);
            path_len += comp.text.len;
        }
        start_dir = start_dir_buf[0..path_len];
        start_component_idx = literal_prefix_end;
    } else if (info.is_absolute) {
        // No literal prefix but absolute path - start from "/"
        start_dir = "/";
    }

    // If there are no wildcard/brace components left, just check if the path exists
    if (start_component_idx >= parsed.components.len) {
        // No wildcard components - just verify path exists and add it
        const root = base_dir orelse std.fs.cwd();
        _ = root.statFile(start_dir) catch return null;
        const path_copy = try allocator.allocSentinel(u8, start_dir.len, 0);
        @memcpy(path_copy[0..start_dir.len], start_dir);
        try all_results.append(@ptrCast(path_copy.ptr), start_dir.len);
        return finalizeResults(allocator, &all_results, flags, pzlob);
    }

    // Convert remaining BracedComponents to ComponentMatcher format
    const remaining_components = parsed.components[start_component_idx..];
    var matchers: [32]ComponentMatcher = undefined;
    const matcher_count = @min(remaining_components.len, 32);
    for (remaining_components[0..matcher_count], 0..) |comp, i| {
        matchers[i] = ComponentMatcher.fromBracedComponent(&comp);
    }

    try walkBracedComponents(
        allocator,
        matchers[0..matcher_count],
        0,
        start_dir,
        flags,
        &all_results,
        directories_only,
        errfunc,
        base_dir,
        struct {
            fn onComplete(alloc: std.mem.Allocator, path: []const u8, results: *ResultsList, _: bool) !void {
                const path_copy = try alloc.allocSentinel(u8, path.len, 0);
                @memcpy(path_copy[0..path.len], path);
                try results.append(@ptrCast(path_copy.ptr), path.len);
            }
        }.onComplete,
    );

    if (all_results.len() == 0) {
        return null;
    }

    // Note: sorting is now handled inside finalizeResults using pre-computed lengths
    return finalizeResults(allocator, &all_results, flags, pzlob);
}

/// Unified component matcher - can match against text or alternatives
const ComponentMatcher = struct {
    text: []const u8,
    alternatives: ?[]const []const u8,
    is_last: bool,

    fn fromBracedComponent(comp: *const brace_optimizer.BracedComponent) ComponentMatcher {
        return .{
            .text = comp.text,
            .alternatives = comp.alternatives,
            .is_last = comp.is_last,
        };
    }

    fn fromTextAndAlts(text: []const u8, alts: ?[]const []const u8, is_last: bool) ComponentMatcher {
        return .{ .text = text, .alternatives = alts, .is_last = is_last };
    }

    /// Check if name matches this component
    fn matches(self: *const ComponentMatcher, name: []const u8) bool {
        return self.matchesWithFlags(name, false);
    }

    /// Check if name matches this component with extglob support
    fn matchesWithFlags(self: *const ComponentMatcher, name: []const u8, enable_extglob: bool) bool {
        if (self.alternatives) |alts| {
            return matchWithAlternativesExtglob(name, alts, enable_extglob);
        }
        // Check for extglob pattern
        if (enable_extglob and extglob.containsExtglob(self.text)) {
            initExtglob();
            return extglob.fnmatchExtglob(self.text, name);
        }
        const ctx = PatternContext.init(self.text);
        return fnmatchWithContext(&ctx, name);
    }

    /// Check if any pattern/alternative starts with dot
    fn startsWithDot(self: *const ComponentMatcher) bool {
        if (self.text.len > 0 and self.text[0] == '.') return true;
        if (self.alternatives) |alts| {
            for (alts) |alt| {
                if (alt.len > 0 and alt[0] == '.') return true;
            }
        }
        return false;
    }
};

/// Check if entry should be skipped (. and .., hidden files)
/// When is_hidden_ok is true (pattern starts with '.'), we allow . and .. through
/// to be tested against the pattern - this is POSIX compliant behavior
inline fn shouldSkipEntry(name: []const u8, is_hidden_ok: bool) bool {
    if (name.len == 0) return true;
    if (name[0] == '.') {
        // When pattern starts with '.', allow . and .. through to be matched
        // This is POSIX compliant: if pattern explicitly matches leading period,
        // then . and .. should be eligible for matching
        if (name.len == 1 or (name.len == 2 and name[1] == '.')) {
            // Only allow . and .. if pattern starts with '.' (is_hidden_ok)
            return !is_hidden_ok;
        }
        // Skip other hidden files unless allowed
        if (!is_hidden_ok) return true;
    }
    return false;
}

fn walkBracedComponents(
    allocator: std.mem.Allocator,
    matchers: []const ComponentMatcher,
    component_idx: usize,
    current_dir: []const u8,
    flags: ZlobFlags,
    results: *ResultsList,
    directories_only: bool,
    errfunc: zlob_errfunc_t,
    base_dir: ?std.fs.Dir,
    comptime onComplete: fn (std.mem.Allocator, []const u8, *ResultsList, bool) error{ OutOfMemory, Aborted }!void,
) error{ OutOfMemory, Aborted }!void {
    if (component_idx >= matchers.len) {
        try onComplete(allocator, current_dir, results, directories_only);
        return;
    }

    const matcher = &matchers[component_idx];
    const is_final = component_idx == matchers.len - 1;
    const is_hidden_ok = flags.period or matcher.startsWithDot();

    // Open directory
    const root = base_dir orelse std.fs.cwd();
    var dir = root.openDir(current_dir, .{ .iterate = true }) catch |err| {
        if (errfunc) |efunc| {
            var path_buf: [4096:0]u8 = undefined;
            if (current_dir.len < 4096) {
                @memcpy(path_buf[0..current_dir.len], current_dir);
                path_buf[current_dir.len] = 0;
                _ = efunc(&path_buf, errToErrno(err));
            }
        }
        if (flags.err) return error.Aborted;
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (shouldSkipEntry(entry.name, is_hidden_ok)) continue;
        if (!is_final and entry.kind != .directory) continue;

        if (matcher.matchesWithFlags(entry.name, flags.extglob)) {
            if (is_final and directories_only and entry.kind != .directory) continue;

            var path_buf: [4096]u8 = undefined;
            const subpath = buildPathInBuffer(&path_buf, current_dir, entry.name);
            if (subpath.len >= 4096) continue;

            try walkBracedComponents(
                allocator,
                matchers,
                component_idx + 1,
                subpath,
                flags,
                results,
                directories_only,
                errfunc,
                base_dir,
                onComplete,
            );
        }
    }
}

/// Convert error to errno for error callback
inline fn errToErrno(err: anyerror) c_int {
    return switch (err) {
        error.AccessDenied => @intFromEnum(std.posix.E.ACCES),
        error.FileNotFound => @intFromEnum(std.posix.E.NOENT),
        error.NotDir => @intFromEnum(std.posix.E.NOTDIR),
        else => @intFromEnum(std.posix.E.IO),
    };
}

fn globRecursiveWithBracedPrefix(
    allocator: std.mem.Allocator,
    rec_pattern: *const RecursivePattern,
    current_dir: []const u8,
    pre_ds_components: []const []const u8,
    pre_ds_alternatives: []const ?[]const []const u8,
    component_idx: usize,
    flags: ZlobFlags,
    results: *ResultsList,
    info: *const PatternInfo,
    errfunc: zlob_errfunc_t,
    base_dir: ?std.fs.Dir,
) !void {
    // If we've matched all pre-doublestar components, start the recursive walk
    if (component_idx >= pre_ds_components.len) {
        if (rec_pattern.dir_components.len == 0) {
            try globRecursiveWithZigWalk(allocator, rec_pattern, current_dir, flags, results, info, errfunc, base_dir);
        } else {
            try globRecursiveHelperCollect(allocator, rec_pattern, current_dir, flags, results, 0, info, errfunc, base_dir);
        }
        return;
    }

    const matcher = ComponentMatcher.fromTextAndAlts(
        pre_ds_components[component_idx],
        pre_ds_alternatives[component_idx],
        false, // not last - always matching directories
    );
    const is_hidden_ok = flags.period or matcher.startsWithDot();

    const root = base_dir orelse std.fs.cwd();
    var dir = root.openDir(current_dir, .{ .iterate = true }) catch |err| {
        if (errfunc) |efunc| {
            var path_buf: [4096:0]u8 = undefined;
            if (current_dir.len < 4096) {
                @memcpy(path_buf[0..current_dir.len], current_dir);
                path_buf[current_dir.len] = 0;
                _ = efunc(&path_buf, errToErrno(err));
            }
        }
        if (flags.err) return error.Aborted;
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (shouldSkipEntry(entry.name, is_hidden_ok)) continue;
        if (entry.kind != .directory) continue;

        if (matcher.matchesWithFlags(entry.name, flags.extglob)) {
            var path_buf: [4096]u8 = undefined;
            const subdir = buildPathInBuffer(&path_buf, current_dir, entry.name);
            if (subdir.len >= 4096) continue;

            try globRecursiveWithBracedPrefix(
                allocator,
                rec_pattern,
                subdir,
                pre_ds_components,
                pre_ds_alternatives,
                component_idx + 1,
                flags,
                results,
                info,
                errfunc,
                base_dir,
            );
        }
    }
}

fn finalizeResults(allocator: std.mem.Allocator, results: *ResultsList, flags: ZlobFlags, pzlob: *zlob_t) !?void {
    const offs = if (flags.dooffs) pzlob.zlo_offs else 0;
    const new_count = results.len();

    // ZLOB_APPEND - merge with existing results
    if (flags.append and pzlob.zlo_pathv != null and pzlob.zlo_pathc > 0) {
        const old_count = pzlob.zlo_pathc;
        const total_count = old_count + new_count;

        const pathv_buf = allocator.alloc([*c]u8, offs + total_count + 1) catch return error.OutOfMemory;
        const pathlen_buf = allocator.alloc(usize, total_count) catch return error.OutOfMemory;

        @memset(pathv_buf[0..offs], null);

        const old_pathv = @as([*][*c]u8, @ptrCast(pzlob.zlo_pathv))[offs..][0..old_count];
        @memcpy(pathv_buf[offs..][0..old_count], old_pathv);
        @memcpy(pathlen_buf[0..old_count], pzlob.zlo_pathlen[0..old_count]);
        @memcpy(pathv_buf[offs + old_count ..][0..new_count], results.paths.items);
        @memcpy(pathlen_buf[old_count..][0..new_count], results.lengths.items);

        pathv_buf[offs + total_count] = null;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        // Free old arrays
        const old_pathv_slice = @as([*][*c]u8, @ptrCast(pzlob.zlo_pathv))[0 .. offs + old_count + 1];
        allocator.free(old_pathv_slice);
        const old_pathlen_slice = pzlob.zlo_pathlen[0..old_count];
        allocator.free(old_pathlen_slice);

        pzlob.zlo_pathc = total_count;
        pzlob.zlo_pathv = result;
        pzlob.zlo_pathlen = pathlen_buf.ptr;
        pzlob.zlo_flags = ZLOB_FLAGS_OWNS_STRINGS;

        if (!flags.nosort and new_count > 0) {
            sortPathsWithLengths(@ptrCast(result + offs + old_count), pathlen_buf.ptr + old_count, new_count);
        }
    } else if (offs == 0) {
        // Fast path: no offset slots needed, transfer ownership directly from ResultsList
        // This avoids allocating new buffers and copying data (just shrinks to exact size)
        const pathv_buf = results.toOwnedPathv() catch return error.OutOfMemory;
        const pathlen_buf = results.toOwnedLengths() catch return error.OutOfMemory;

        pzlob.zlo_pathc = new_count;
        pzlob.zlo_pathv = @ptrCast(pathv_buf.ptr);
        pzlob.zlo_pathlen = pathlen_buf.ptr;
        pzlob.zlo_flags = ZLOB_FLAGS_OWNS_STRINGS;

        if (!flags.nosort) {
            sortPathsWithLengths(@ptrCast(pzlob.zlo_pathv), pathlen_buf.ptr, new_count);
        }
    } else {
        // ZLOB_DOOFFS: need offset slots at the beginning, must allocate fresh buffers
        const pathv_buf = allocator.alloc([*c]u8, offs + new_count + 1) catch return error.OutOfMemory;
        const pathlen_buf = allocator.alloc(usize, new_count) catch return error.OutOfMemory;

        @memset(pathv_buf[0..offs], null);
        @memcpy(pathv_buf[offs..][0..new_count], results.paths.items);
        @memcpy(pathlen_buf, results.lengths.items);

        pathv_buf[offs + new_count] = null;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        pzlob.zlo_pathc = new_count;
        pzlob.zlo_pathv = result;
        pzlob.zlo_pathlen = pathlen_buf.ptr;
        pzlob.zlo_flags = ZLOB_FLAGS_OWNS_STRINGS;

        if (!flags.nosort) {
            sortPathsWithLengths(@ptrCast(result + offs), pathlen_buf.ptr, new_count);
        }
    }
}

// Use Zig's std.fs.Dir.walk() for recursive directory traversal
// This produces string slices directly, avoiding mem.sliceTo overhead on every entry
inline fn globRecursiveWithZigWalk(
    allocator: std.mem.Allocator,
    rec_pattern: *const RecursivePattern,
    start_dir: []const u8,
    flags: ZlobFlags,
    results: *ResultsList,
    info: *const PatternInfo,
    errfunc: zlob_errfunc_t,
    base_dir: ?std.fs.Dir,
) !void {
    // Pattern context for file matching
    const pattern_ctx = PatternContext.init(rec_pattern.file_pattern);

    // Open the starting directory using Zig's std.fs
    const root = base_dir orelse std.fs.cwd();
    var dir = root.openDir(start_dir, .{ .iterate = true }) catch |err| {
        // If we can't open the directory, call errfunc if provided
        if (errfunc) |efunc| {
            // Convert start_dir to null-terminated string for errfunc
            var path_buf: [4096:0]u8 = undefined;
            if (start_dir.len >= 4096) return error.Aborted;
            @memcpy(path_buf[0..start_dir.len], start_dir);
            path_buf[start_dir.len] = 0;

            const eerrno: c_int = switch (err) {
                error.AccessDenied => @intFromEnum(std.posix.E.ACCES),
                error.FileNotFound => @intFromEnum(std.posix.E.NOENT),
                error.NotDir => @intFromEnum(std.posix.E.NOTDIR),
                else => @intFromEnum(std.posix.E.IO),
            };

            if (efunc(&path_buf, eerrno) != 0) {
                return error.Aborted;
            }
        }
        // If ZLOB_ERR is set, abort on error
        if (flags.err) {
            return error.Aborted;
        }
        // Otherwise, silently skip this directory
        return;
    };

    // Note: std.fs.Dir.walk() doesn't support pruning, so we use iterate() for gitignore support
    // If gitignore is enabled, we need manual recursion to support directory pruning
    if (rec_pattern.gitignore_filter) |gi| {
        defer dir.close();
        try walkWithGitignore(allocator, dir, start_dir, "", rec_pattern, &pattern_ctx, flags, results, info, gi);
    } else {
        // Use platform-optimized walker (direct getdents64 on Linux, std.fs elsewhere)
        // Comptime selection ensures zero runtime dispatch overhead
        const use_optimized_walker = comptime (builtin.os.tag == .linux);

        if (use_optimized_walker) {
            // Close dir since the optimized walker opens it internally - DO NOT use defer here
            // since the walker will manage its own fd
            dir.close();
            var walker = walker_mod.DefaultWalker.init(allocator, start_dir, .{}) catch return error.OutOfMemory;
            defer walker.deinit();

            while (try walker.next()) |entry| {
                const is_dir = entry.kind == .directory;
                if (info.directories_only and !is_dir) continue;

                if (entry.kind == .file or is_dir) {
                    if (!flags.period) {
                        if (mem.indexOf(u8, entry.path, "/.") != null) continue;
                        if (entry.path.len > 0 and entry.path[0] == '.') {
                            if (!pattern_ctx.starts_with_dot) continue;
                        }
                    }
                    if (shouldSkipFile(entry.basename, &pattern_ctx, flags)) continue;

                    const enable_extglob = flags.extglob;
                    const matches = if (rec_pattern.file_pattern_contexts) |contexts| blk: {
                        if (enable_extglob and rec_pattern.file_alternatives != null) {
                            break :blk matchWithAlternativesPrecomputedExtglob(entry.basename, rec_pattern.file_alternatives.?, contexts, true);
                        }
                        break :blk matchWithAlternativesPrecomputed(entry.basename, contexts);
                    } else if (rec_pattern.file_alternatives) |alts|
                        matchWithAlternativesExtglob(entry.basename, alts, enable_extglob)
                    else if (enable_extglob and extglob.containsExtglob(rec_pattern.file_pattern)) blk: {
                        initExtglob();
                        break :blk extglob.fnmatchExtglob(rec_pattern.file_pattern, entry.basename);
                    } else if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
                        batched_suffix_match.matchSuffix(entry.basename)
                    else
                        fnmatchWithContext(&pattern_ctx, entry.basename);

                    if (matches) {
                        const needs_mark = flags.mark and is_dir;
                        const base_path_len = start_dir.len + 1 + entry.path.len;
                        const alloc_len = if (needs_mark) base_path_len + 1 else base_path_len;
                        const path_buf_slice = allocator.allocSentinel(u8, alloc_len, 0) catch return error.OutOfMemory;
                        @memcpy(path_buf_slice[0..start_dir.len], start_dir);
                        path_buf_slice[start_dir.len] = '/';
                        @memcpy(path_buf_slice[start_dir.len + 1 ..][0..entry.path.len], entry.path);
                        const final_path_len = if (needs_mark) blk: {
                            path_buf_slice[base_path_len] = '/';
                            path_buf_slice[base_path_len + 1] = 0;
                            break :blk base_path_len + 1;
                        } else base_path_len;
                        results.append(@ptrCast(path_buf_slice.ptr), final_path_len) catch return error.OutOfMemory;
                    }
                }
            }
            return; // Early return - walker manages its own cleanup via defer walker.deinit()
        }

        // Fallback path: use std.fs.Dir.walk and close dir when done
        defer dir.close();

        var walker = dir.walk(allocator) catch return error.OutOfMemory;
        defer walker.deinit();

        // Walk all entries recursively
        while (walker.next() catch null) |entry| {
            // entry.path is already a []const u8 - NO mem.sliceTo needed!
            // entry.basename is the filename without directory path

            const is_dir = entry.kind == .directory;

            if (info.directories_only and !is_dir) continue;

            if (entry.kind == .file or is_dir) {
                // ZLOB_PERIOD: Check if path contains hidden components
                // If ZLOB_PERIOD is NOT set, skip files whose path contains hidden directories
                if (!flags.period) {
                    // entry.path can be like ".hidden_dir/file.txt" or "dir/.hidden/file.txt"
                    if (mem.indexOf(u8, entry.path, "/.") != null) {
                        continue; // Path contains /. (hidden directory)
                    }
                    // Also check if path itself starts with '.' (hidden directory at root)
                    if (entry.path.len > 0 and entry.path[0] == '.') {
                        // But allow patterns that explicitly match hidden dirs
                        if (!pattern_ctx.starts_with_dot) {
                            continue;
                        }
                    }
                }

                // ZLOB_PERIOD: Skip hidden files unless explicitly allowed
                // Note: shouldSkipFile handles ZLOB_PERIOD logic for basename
                if (shouldSkipFile(entry.basename, &pattern_ctx, flags)) continue;

                // Match against file pattern (with alternatives if present)
                // KEY OPTIMIZATION: Use pre-computed pattern contexts to avoid redundant PatternContext.init() calls
                const enable_extglob = flags.extglob;
                const matches = if (rec_pattern.file_pattern_contexts) |contexts| blk: {
                    // When extglob is enabled and we have alternatives, check each one
                    if (enable_extglob and rec_pattern.file_alternatives != null) {
                        break :blk matchWithAlternativesPrecomputedExtglob(entry.basename, rec_pattern.file_alternatives.?, contexts, true);
                    }
                    break :blk matchWithAlternativesPrecomputed(entry.basename, contexts);
                } else if (rec_pattern.file_alternatives) |alts|
                    matchWithAlternativesExtglob(entry.basename, alts, enable_extglob)
                else if (enable_extglob and extglob.containsExtglob(rec_pattern.file_pattern)) blk: {
                    initExtglob();
                    break :blk extglob.fnmatchExtglob(rec_pattern.file_pattern, entry.basename);
                } else if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
                    batched_suffix_match.matchSuffix(entry.basename)
                else
                    fnmatchWithContext(&pattern_ctx, entry.basename);

                if (matches) {
                    const needs_mark = flags.mark and is_dir;
                    const base_path_len = start_dir.len + 1 + entry.path.len;
                    const alloc_len = if (needs_mark) base_path_len + 1 else base_path_len;

                    const path_buf_slice = allocator.allocSentinel(u8, alloc_len, 0) catch return error.OutOfMemory;

                    @memcpy(path_buf_slice[0..start_dir.len], start_dir);
                    path_buf_slice[start_dir.len] = '/';
                    @memcpy(path_buf_slice[start_dir.len + 1 ..][0..entry.path.len], entry.path);

                    const final_path_len = if (needs_mark) blk: {
                        path_buf_slice[base_path_len] = '/';
                        path_buf_slice[base_path_len + 1] = 0;
                        break :blk base_path_len + 1;
                    } else base_path_len;

                    results.append(@ptrCast(path_buf_slice.ptr), final_path_len) catch return error.OutOfMemory;
                }
            }
        }
    }
}

/// Manual recursive walk with gitignore support for directory pruning
fn walkWithGitignore(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    start_dir: []const u8,
    rel_path: []const u8,
    rec_pattern: *const RecursivePattern,
    pattern_ctx: *const PatternContext,
    flags: ZlobFlags,
    results: *ResultsList,
    info: *const PatternInfo,
    gi: *GitIgnore,
) !void {
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const name = entry.name;

        // Skip . and ..
        if (name.len == 0) continue;
        if (name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) continue;

        // Build relative path for gitignore checking
        var entry_rel_path_buf: [4096]u8 = undefined;
        const entry_rel_path = if (rel_path.len > 0) blk: {
            const len = rel_path.len + 1 + name.len;
            if (len >= 4096) continue;
            @memcpy(entry_rel_path_buf[0..rel_path.len], rel_path);
            entry_rel_path_buf[rel_path.len] = '/';
            @memcpy(entry_rel_path_buf[rel_path.len + 1 ..][0..name.len], name);
            break :blk entry_rel_path_buf[0..len];
        } else blk: {
            @memcpy(entry_rel_path_buf[0..name.len], name);
            break :blk entry_rel_path_buf[0..name.len];
        };

        const is_dir = entry.kind == .directory;

        // Check gitignore - skip if ignored
        if (gi.isIgnored(entry_rel_path, is_dir)) {
            continue;
        }

        // ZLOB_PERIOD handling
        if (!flags.period and name[0] == '.') {
            if (!pattern_ctx.starts_with_dot) {
                continue;
            }
        }

        if (is_dir) {
            // Check if we should prune this directory
            if (gi.shouldSkipDirectory(entry_rel_path)) {
                continue;
            }

            // Recurse into subdirectory
            var subdir = dir.openDir(name, .{ .iterate = true }) catch continue;
            defer subdir.close();

            try walkWithGitignore(allocator, subdir, start_dir, entry_rel_path, rec_pattern, pattern_ctx, flags, results, info, gi);
        }

        if (entry.kind == .file or is_dir) {
            if (info.directories_only and !is_dir) continue;
            if (shouldSkipFile(name, pattern_ctx, flags)) continue;

            // Match against file pattern
            const enable_extglob = flags.extglob;
            const matches = if (rec_pattern.file_pattern_contexts) |contexts| blk: {
                if (enable_extglob and rec_pattern.file_alternatives != null) {
                    break :blk matchWithAlternativesPrecomputedExtglob(name, rec_pattern.file_alternatives.?, contexts, true);
                }
                break :blk matchWithAlternativesPrecomputed(name, contexts);
            } else if (rec_pattern.file_alternatives) |alts|
                matchWithAlternativesExtglob(name, alts, enable_extglob)
            else if (enable_extglob and extglob.containsExtglob(rec_pattern.file_pattern)) blk: {
                initExtglob();
                break :blk extglob.fnmatchExtglob(rec_pattern.file_pattern, name);
            } else if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
                batched_suffix_match.matchSuffix(name)
            else
                fnmatchWithContext(pattern_ctx, name);

            if (matches) {
                const needs_mark = flags.mark and is_dir;
                const base_path_len = start_dir.len + 1 + entry_rel_path.len;
                const alloc_len = if (needs_mark) base_path_len + 1 else base_path_len;

                const path_buf_slice = allocator.allocSentinel(u8, alloc_len, 0) catch return error.OutOfMemory;

                @memcpy(path_buf_slice[0..start_dir.len], start_dir);
                path_buf_slice[start_dir.len] = '/';
                @memcpy(path_buf_slice[start_dir.len + 1 ..][0..entry_rel_path.len], entry_rel_path);

                const final_path_len = if (needs_mark) blk: {
                    path_buf_slice[base_path_len] = '/';
                    path_buf_slice[base_path_len + 1] = 0;
                    break :blk base_path_len + 1;
                } else base_path_len;

                results.append(@ptrCast(path_buf_slice.ptr), final_path_len) catch return error.OutOfMemory;
            }
        }
    }
}

fn globRecursiveHelperCollect(allocator: std.mem.Allocator, rec_pattern: *const RecursivePattern, dirname: []const u8, flags: ZlobFlags, results: *ResultsList, depth: usize, info: *const PatternInfo, errfunc: zlob_errfunc_t, base_dir: ?std.fs.Dir) !void {
    // Limit recursion depth
    if (depth > 100) return;

    // Early exit if this directory can't match
    if (!canMatchPattern(dirname, depth, info)) {
        return;
    }

    // Should we match files in this directory?
    const should_match_here = if (info.literal_prefix.len > 0)
        mem.startsWith(u8, dirname, info.literal_prefix) and (dirname.len >= info.literal_prefix.len)
    else
        true;

    if (should_match_here and rec_pattern.dir_components.len == 0) {
        try globInDirImplCollect(allocator, rec_pattern.file_pattern, rec_pattern.file_alternatives, rec_pattern.file_pattern_contexts, dirname, flags, results, info.directories_only, errfunc, rec_pattern.gitignore_filter, base_dir);
        // Continue recursing even if no matches in this directory
    }

    // Open directory to find subdirectories
    // If base_dir is provided, use Zig's fs; otherwise use C's opendir for performance
    if (base_dir) |bd| {
        var dir = bd.openDir(dirname, .{ .iterate = true }) catch {
            if (flags.err) return error.Aborted;
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            const name = entry.name;
            if (name.len == 0 or (name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.')))) continue;

            if (name[0] == '.' and !flags.period) {
                if (rec_pattern.dir_components.len > 0 and rec_pattern.dir_components[0].len > 0 and rec_pattern.dir_components[0][0] == '.') {
                    // First directory component explicitly starts with '.'
                } else if (rec_pattern.dir_components.len == 0 and rec_pattern.file_pattern.len > 0 and rec_pattern.file_pattern[0] == '.') {
                    // File pattern explicitly starts with '.'
                } else {
                    continue;
                }
            }

            if (entry.kind == .directory) {
                var subdir_buf: [4096]u8 = undefined;
                const subdir = if (mem.eql(u8, dirname, ".")) blk: {
                    @memcpy(subdir_buf[0..name.len], name);
                    break :blk subdir_buf[0..name.len];
                } else blk: {
                    @memcpy(subdir_buf[0..dirname.len], dirname);
                    subdir_buf[dirname.len] = '/';
                    @memcpy(subdir_buf[dirname.len + 1 ..][0..name.len], name);
                    break :blk subdir_buf[0 .. dirname.len + 1 + name.len];
                };

                var next_rec_pattern = rec_pattern.*;
                if (rec_pattern.dir_components.len > 0) {
                    const next_component = rec_pattern.dir_components[0];
                    const has_alternatives = rec_pattern.dir_component_alternatives != null and
                        rec_pattern.dir_component_alternatives.?[0] != null;

                    const enable_extglob = flags.extglob;
                    const has_extglob_pattern = enable_extglob and extglob.containsExtglob(next_component);

                    const matches_component = if (has_alternatives)
                        matchWithAlternatives(name, rec_pattern.dir_component_alternatives.?[0].?)
                    else if (has_extglob_pattern) blk: {
                        initExtglob();
                        break :blk extglob.fnmatchExtglob(next_component, name);
                    } else blk: {
                        const component_ctx = PatternContext.init(next_component);
                        break :blk fnmatchWithContext(&component_ctx, name);
                    };

                    if (matches_component) {
                        next_rec_pattern.dir_components = rec_pattern.dir_components[1..];
                        if (rec_pattern.dir_component_alternatives) |alts| {
                            next_rec_pattern.dir_component_alternatives = if (alts.len > 1) alts[1..] else null;
                        }
                    }
                }
                try globRecursiveHelperCollect(allocator, &next_rec_pattern, subdir, flags, results, depth + 1, info, errfunc, base_dir);
            }
        }
        return;
    }

    // C-based path (no base_dir)
    var dirname_z: [4096:0]u8 = undefined;
    @memcpy(dirname_z[0..dirname.len], dirname);
    dirname_z[dirname.len] = 0;

    const dir = c.opendir(&dirname_z) orelse {
        // Directory open error - call errfunc if provided
        if (errfunc) |efunc| {
            const eerrno = @as(c_int, @intFromEnum(std.posix.errno(-1)));
            if (efunc(&dirname_z, eerrno) != 0) {
                return error.Aborted;
            }
        }
        // If ZLOB_ERR is set, abort on error
        if (flags.err) {
            return error.Aborted;
        }
        // Otherwise, silently skip this directory
        return;
    };
    defer _ = c.closedir(dir);

    // Recursively search subdirectories
    while (c.readdir(dir)) |entry_raw| {
        const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
        const name = direntNameSlice(&entry.name);

        if (name.len == 0 or name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) {
            continue;
        }

        if (name[0] == '.') {
            if (flags.period) {
                // ZLOB_PERIOD allows wildcards to match hidden files
            } else if (rec_pattern.dir_components.len > 0 and rec_pattern.dir_components[0].len > 0 and rec_pattern.dir_components[0][0] == '.') {
                // First directory component explicitly starts with '.'
            } else if (rec_pattern.dir_components.len == 0 and rec_pattern.file_pattern.len > 0 and rec_pattern.file_pattern[0] == '.') {
                // File pattern explicitly starts with '.'
            } else {
                continue;
            }
        }

        var is_dir = entry.type == DT_DIR;
        if (entry.type == DT_UNKNOWN) {
            var subdir_buf_tmp: [4096:0]u8 = undefined;
            var subdir_len_tmp: usize = 0;

            if (dirname.len > 0 and !mem.eql(u8, dirname, ".")) {
                @memcpy(subdir_buf_tmp[0..dirname.len], dirname);
                subdir_buf_tmp[dirname.len] = '/';
                subdir_len_tmp = dirname.len + 1;
            }

            @memcpy(subdir_buf_tmp[subdir_len_tmp..][0..name.len], name);
            subdir_len_tmp += name.len;
            subdir_buf_tmp[subdir_len_tmp] = 0;

            var stat_buf: std.c.Stat = undefined;
            if (std.c.stat(&subdir_buf_tmp, &stat_buf) == 0) {
                is_dir = std.c.S.ISDIR(stat_buf.mode);
            }
        }

        if (is_dir) {
            var next_rec_pattern = rec_pattern.*;
            if (rec_pattern.dir_components.len > 0) {
                const next_component = rec_pattern.dir_components[0];

                // Check if this component has alternatives
                const has_alternatives = rec_pattern.dir_component_alternatives != null and
                    rec_pattern.dir_component_alternatives.?[0] != null;

                const enable_extglob = flags.extglob;
                const has_extglob_pattern = enable_extglob and extglob.containsExtglob(next_component);

                const matches_component = if (has_alternatives)
                    matchWithAlternatives(name, rec_pattern.dir_component_alternatives.?[0].?)
                else if (has_extglob_pattern) blk: {
                    initExtglob();
                    break :blk extglob.fnmatchExtglob(next_component, name);
                } else blk: {
                    const component_ctx = PatternContext.init(next_component);
                    break :blk fnmatchWithContext(&component_ctx, name);
                };

                // If matches, consume the dir component for next recursion
                // But ALWAYS recurse into directories to support ** behavior
                if (matches_component) {
                    next_rec_pattern.dir_components = rec_pattern.dir_components[1..];
                    // Also advance alternatives if present
                    if (rec_pattern.dir_component_alternatives) |alts| {
                        next_rec_pattern.dir_component_alternatives = if (alts.len > 1) alts[1..] else null;
                    }
                }
                // Note: we removed the "if (!matches_component) continue;" to allow
                // recursion into non-matching directories for ** glob behavior
            }

            var subdir_buf: [4096]u8 = undefined;
            var subdir_len: usize = 0;
            if (dirname.len > 0 and !mem.eql(u8, dirname, ".")) {
                @memcpy(subdir_buf[0..dirname.len], dirname);
                subdir_buf[dirname.len] = '/';
                subdir_len = dirname.len + 1;
            }
            @memcpy(subdir_buf[subdir_len..][0..name.len], name);
            subdir_len += name.len;
            const subdir = subdir_buf[0..subdir_len];

            // Filter by pattern
            if (!canMatchPattern(subdir, depth + 1, info)) continue;

            // Gitignore filtering - skip ignored directories entirely (pruning)
            if (rec_pattern.gitignore_filter) |gi| {
                if (gi.shouldSkipDirectory(subdir)) {
                    continue;
                }
            }

            // Recurse into subdirectory
            try globRecursiveHelperCollect(allocator, &next_rec_pattern, subdir, flags, results, depth + 1, info, errfunc, null);
        }
    }
}

fn globInDirImplCollect(allocator: std.mem.Allocator, pattern: []const u8, file_alternatives: ?[]const []const u8, file_pattern_contexts: ?[]const PatternContext, dirname: []const u8, flags: ZlobFlags, results: *ResultsList, directories_only: bool, errfunc: zlob_errfunc_t, gitignore_filter: ?*GitIgnore, base_dir: ?std.fs.Dir) !void {
    const pattern_ctx = PatternContext.init(pattern);

    const use_dirname = dirname.len > 0 and !mem.eql(u8, dirname, ".");

    // If base_dir is provided, use Zig's fs; otherwise use C's opendir for performance
    if (base_dir) |bd| {
        var dir = bd.openDir(dirname, .{ .iterate = true }) catch {
            if (flags.err) return error.Aborted;
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            const name = entry.name;
            if (shouldSkipFile(name, &pattern_ctx, flags)) continue;

            const enable_extglob = flags.extglob;
            const matches = if (file_pattern_contexts) |contexts| blk: {
                if (enable_extglob and file_alternatives != null) {
                    break :blk matchWithAlternativesPrecomputedExtglob(name, file_alternatives.?, contexts, true);
                }
                break :blk matchWithAlternativesPrecomputed(name, contexts);
            } else if (file_alternatives) |alts|
                matchWithAlternativesExtglob(name, alts, enable_extglob)
            else if (enable_extglob and extglob.containsExtglob(pattern)) blk: {
                initExtglob();
                break :blk extglob.fnmatchExtglob(pattern, name);
            } else if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
                batched_suffix_match.matchSuffix(name)
            else
                fnmatchWithContext(&pattern_ctx, name);

            if (matches) {
                if (directories_only and entry.kind != .directory) continue;

                const is_dir = entry.kind == .directory;

                // Use optimized path builder that pre-allocates for trailing slash
                const path_result = buildFullPathWithMark(allocator, dirname, name, use_dirname, is_dir, flags) catch return error.OutOfMemory;

                if (directories_only and !is_dir) {
                    allocator.free(path_result.buf);
                    continue;
                }

                if (gitignore_filter) |gi| {
                    // Use base path length (without trailing slash) for gitignore check
                    const base_len = if (use_dirname) dirname.len + 1 + name.len else name.len;
                    const rel_path = if (use_dirname) path_result.buf[0..base_len] else name;
                    if (gi.isIgnored(rel_path, is_dir)) {
                        allocator.free(path_result.buf);
                        continue;
                    }
                }

                results.append(path_result.ptr, path_result.len) catch return error.OutOfMemory;
            }
        }
        return;
    }

    // C-based path (no base_dir)
    var dirname_z: [4096:0]u8 = undefined;
    @memcpy(dirname_z[0..dirname.len], dirname);
    dirname_z[dirname.len] = 0;

    const dir = c.opendir(&dirname_z) orelse {
        // Directory open error - call errfunc if provided
        if (errfunc) |efunc| {
            const eerrno = @as(c_int, @intFromEnum(std.posix.errno(-1)));
            if (efunc(&dirname_z, eerrno) != 0) {
                return error.Aborted;
            }
        }
        // If ZLOB_ERR is set, abort on error
        if (flags.err) {
            return error.Aborted;
        }
        // Otherwise, silently skip this directory
        return;
    };
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry_raw| {
        const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
        const name = direntNameSlice(&entry.name);

        if (shouldSkipFile(name, &pattern_ctx, flags)) continue;

        // Match against file pattern (with alternatives if present)
        // KEY OPTIMIZATION: Use pre-computed pattern contexts to avoid redundant PatternContext.init() calls
        const enable_extglob_c = flags.extglob;
        const matches = if (file_pattern_contexts) |contexts| blk: {
            if (enable_extglob_c and file_alternatives != null) {
                break :blk matchWithAlternativesPrecomputedExtglob(name, file_alternatives.?, contexts, true);
            }
            break :blk matchWithAlternativesPrecomputed(name, contexts);
        } else if (file_alternatives) |alts|
            matchWithAlternativesExtglob(name, alts, enable_extglob_c)
        else if (enable_extglob_c and extglob.containsExtglob(pattern)) blk: {
            initExtglob();
            break :blk extglob.fnmatchExtglob(pattern, name);
        } else if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
            batched_suffix_match.matchSuffix(name)
        else
            fnmatchWithContext(&pattern_ctx, name);

        if (matches) {
            // Filter directories if needed
            if (directories_only) {
                const entry_dtype = entry.type;
                if (entry_dtype != DT_DIR and entry_dtype != DT_UNKNOWN) continue;
            }

            // Determine is_dir early if we can (avoid stat when possible)
            var is_dir = entry.type == DT_DIR;
            const needs_stat = entry.type == DT_UNKNOWN;

            // If we know is_dir already, use optimized path builder
            // Otherwise, fall back to old method since we need path for stat
            if (!needs_stat) {
                const path_result = buildFullPathWithMark(allocator, dirname, name, use_dirname, is_dir, flags) catch return error.OutOfMemory;

                if (directories_only and !is_dir) {
                    allocator.free(path_result.buf);
                    continue;
                }

                if (gitignore_filter) |gi| {
                    const base_len = if (use_dirname) dirname.len + 1 + name.len else name.len;
                    const rel_path = if (use_dirname) path_result.buf[0..base_len] else name;
                    if (gi.isIgnored(rel_path, is_dir)) {
                        allocator.free(path_result.buf);
                        continue;
                    }
                }

                results.append(path_result.ptr, path_result.len) catch return error.OutOfMemory;
            } else {
                // DT_UNKNOWN: need to stat to determine if directory
                @branchHint(.unlikely);
                const path_buf_slice = buildFullPath(allocator, dirname, name, use_dirname) catch return error.OutOfMemory;
                var path: [*c]u8 = @ptrCast(path_buf_slice.ptr);
                var final_path_len = path_buf_slice.len;

                var stat_buf: std.c.Stat = undefined;
                if (std.c.stat(path, &stat_buf) == 0) {
                    is_dir = std.c.S.ISDIR(stat_buf.mode);
                } else {
                    allocator.free(path_buf_slice);
                    continue;
                }

                if (directories_only and !is_dir) {
                    allocator.free(path_buf_slice);
                    continue;
                }

                if (gitignore_filter) |gi| {
                    const rel_path = if (use_dirname) path_buf_slice[0..final_path_len] else name;
                    if (gi.isIgnored(rel_path, is_dir)) {
                        allocator.free(path_buf_slice);
                        continue;
                    }
                }

                if (maybeAppendSlash(allocator, path, final_path_len, is_dir, flags) catch {
                    @branchHint(.unlikely);
                    allocator.free(path_buf_slice);
                    return error.OutOfMemory;
                }) |new_path| {
                    path = new_path;
                    final_path_len += 1;
                }

                results.append(path, final_path_len) catch return error.OutOfMemory;
            }
        }
    }
}

// Helper to build full path from dirname and filename
pub inline fn buildFullPath(allocator: std.mem.Allocator, dirname: []const u8, name: []const u8, use_dirname: bool) ![]u8 {
    const path_len = if (use_dirname)
        dirname.len + 1 + name.len
    else
        name.len;

    const path_buf_slice = try allocator.allocSentinel(u8, path_len, 0);

    if (use_dirname) {
        @branchHint(.unlikely);

        @memcpy(path_buf_slice[0..dirname.len], dirname);
        path_buf_slice[dirname.len] = '/';
        @memcpy(path_buf_slice[dirname.len + 1 ..][0..name.len], name);
    } else {
        @memcpy(path_buf_slice[0..name.len], name);
    }

    return path_buf_slice;
}

/// Result of buildFullPathWithMark - contains buffer and final length
pub const PathBuildResult = struct {
    ptr: [*c]u8,
    len: usize,
    buf: []u8, // For cleanup on error
};

/// Optimized path builder that pre-allocates space for trailing slash if ZLOB_MARK is set.
/// This avoids a realloc when the entry is a directory.
/// Returns the path pointer and final length (including trailing slash if added).
pub inline fn buildFullPathWithMark(
    allocator: std.mem.Allocator,
    dirname: []const u8,
    name: []const u8,
    use_dirname: bool,
    is_dir: bool,
    flags: ZlobFlags,
) !PathBuildResult {
    const base_len = if (use_dirname)
        dirname.len + 1 + name.len
    else
        name.len;

    // Pre-allocate extra byte for trailing slash if MARK flag is set and it's a directory
    const needs_mark = flags.mark and is_dir;
    const alloc_len = if (needs_mark) base_len + 1 else base_len;

    const path_buf_slice = try allocator.allocSentinel(u8, alloc_len, 0);

    if (use_dirname) {
        @memcpy(path_buf_slice[0..dirname.len], dirname);
        path_buf_slice[dirname.len] = '/';
        @memcpy(path_buf_slice[dirname.len + 1 ..][0..name.len], name);
    } else {
        @memcpy(path_buf_slice[0..name.len], name);
    }

    // Add trailing slash if needed (no realloc required - space already allocated)
    const final_len = if (needs_mark) blk: {
        path_buf_slice[base_len] = '/';
        path_buf_slice[base_len + 1] = 0; // Update sentinel
        break :blk base_len + 1;
    } else base_len;

    return .{
        .ptr = @ptrCast(path_buf_slice.ptr),
        .len = final_len,
        .buf = path_buf_slice,
    };
}

pub inline fn shouldSkipFile(name: []const u8, pattern_ctx: *const PatternContext, flags: ZlobFlags) bool {
    if (name.len == 0) return true;

    const first_byte = name[0];
    if (first_byte == '.') {
        const is_dot = name.len == 1;
        const is_dotdot = name.len == 2 and name[1] == '.';

        // Handle "." and ".." entries
        // POSIX: if pattern explicitly starts with '.', then '.' and '..'
        // should be eligible for matching (e.g., ".*" matches "." and "..")
        if (is_dot or is_dotdot) {
            // Don't skip if pattern explicitly asks for "." or ".."
            if (pattern_ctx.is_dot_or_dotdot) return false;
            // Don't skip if pattern starts with '.' - allow through to match
            // This is POSIX compliant: ".*" should match "." and ".."
            if (pattern_ctx.starts_with_dot) return false;
            // Skip otherwise (e.g., pattern is "*")
            return true;
        }

        // ZLOB_PERIOD: allow wildcards to match hidden files
        if (flags.period) return false;

        if (!pattern_ctx.starts_with_dot) return true;
    }
    return false;
}

// Helper to check if path is a directory and append '/' if ZLOB_MARK is set
pub inline fn maybeAppendSlash(allocator: std.mem.Allocator, path: [*c]u8, path_len: usize, is_dir: bool, flags: ZlobFlags) !?[*c]u8 {
    if (!is_dir or (!flags.mark)) {
        return null; // No modification needed
    }

    // Need to append '/' - reallocate with extra space
    const old_slice = @as([*]u8, @ptrCast(path))[0 .. path_len + 1]; // includes sentinel
    const new_slice = try allocator.realloc(old_slice, path_len + 2); // +1 for '/', +1 for sentinel
    new_slice[path_len] = '/';
    new_slice[path_len + 1] = 0;
    return @ptrCast(new_slice.ptr);
}

fn globInDirFiltered(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: ZlobFlags, errfunc: zlob_errfunc_t, pzlob: *zlob_t, directories_only: bool, gitignore_filter: ?*GitIgnore, brace_parsed: ?*const brace_optimizer.BracedPattern, base_dir: ?std.fs.Dir) !?void {
    // If we have brace alternatives for the filename pattern, use them for matching
    // e.g., "*.{toml,lock}" -> alternatives = ["*.toml", "*.lock"]
    const file_alternatives: ?[]const PatternContext = if (brace_parsed) |bp| blk: {
        // Find the last component (should be the filename pattern)
        if (bp.components.len > 0) {
            const last_comp = bp.components[bp.components.len - 1];
            if (last_comp.is_last and last_comp.pattern_contexts != null) {
                break :blk last_comp.pattern_contexts;
            }
        }
        break :blk null;
    } else null;

    // Get raw pattern alternatives for extglob matching
    const file_pattern_alts: ?[][]const u8 = if (brace_parsed) |bp| blk: {
        if (bp.components.len > 0) {
            const last_comp = bp.components[bp.components.len - 1];
            if (last_comp.is_last and last_comp.alternatives != null) {
                break :blk last_comp.alternatives;
            }
        }
        break :blk null;
    } else null;

    const pattern_ctx = PatternContext.init(pattern);
    const use_dirname = dirname.len > 0 and !mem.eql(u8, dirname, ".");
    const enable_extglob = flags.extglob;

    // If base_dir is provided, use Zig's fs; otherwise use C's opendir for performance
    if (base_dir) |bd| {
        var dir = bd.openDir(dirname, .{ .iterate = true }) catch {
            if (flags.err) return error.Aborted;
            return null;
        };
        defer dir.close();

        var names = ResultsList.initWithCapacity(allocator, 256) catch ResultsList.init(allocator);
        defer names.deinit();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            const name = entry.name;
            if (shouldSkipFile(name, &pattern_ctx, flags)) continue;

            const matches = if (file_alternatives) |alts| blk: {
                // Check if we should use extglob matching
                if (enable_extglob and file_pattern_alts != null) {
                    for (file_pattern_alts.?, alts) |raw_pat, alt_ctx| {
                        if (extglob.containsExtglob(raw_pat)) {
                            initExtglob();
                            if (extglob.fnmatchExtglob(raw_pat, name)) break :blk true;
                        } else if (alt_ctx.simd_batched_suffix_match) |batched_suffix_match| {
                            if (batched_suffix_match.matchSuffix(name)) break :blk true;
                        } else if (fnmatchWithContext(&alt_ctx, name)) {
                            break :blk true;
                        }
                    }
                    break :blk false;
                }
                for (alts) |alt_ctx| {
                    if (alt_ctx.simd_batched_suffix_match) |batched_suffix_match| {
                        if (batched_suffix_match.matchSuffix(name)) break :blk true;
                    } else if (fnmatchWithContext(&alt_ctx, name)) {
                        break :blk true;
                    }
                }
                break :blk false;
            } else if (enable_extglob and extglob.containsExtglob(pattern)) blk: {
                initExtglob();
                break :blk extglob.fnmatchExtglob(pattern, name);
            } else if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
                batched_suffix_match.matchSuffix(name)
            else
                fnmatchWithContext(&pattern_ctx, name);

            if (matches) {
                if (directories_only and entry.kind != .directory) continue;

                const is_dir = entry.kind == .directory;

                // Use optimized path builder that pre-allocates for trailing slash
                const path_result = buildFullPathWithMark(allocator, dirname, name, use_dirname, is_dir, flags) catch return error.OutOfMemory;

                if (directories_only and !is_dir) {
                    allocator.free(path_result.buf);
                    continue;
                }

                if (gitignore_filter) |gi| {
                    const base_len = if (use_dirname) dirname.len + 1 + name.len else name.len;
                    const rel_path = if (use_dirname) path_result.buf[0..base_len] else name;
                    if (gi.isIgnored(rel_path, is_dir)) {
                        allocator.free(path_result.buf);
                        continue;
                    }
                }

                names.append(path_result.ptr, path_result.len) catch return error.OutOfMemory;
            }
        }

        // Zig's iterator skips "." and "..", but when pattern
        // starts with '.', we need to check if they match the pattern.
        // This is because POSIX says: "if a filename begins with a <period>, the
        // <period> shall be explicitly matched" - meaning patterns like ".*"
        // should match "." and ".."
        if (pattern_ctx.starts_with_dot and !directories_only) {
            const dot_entries = [_][]const u8{ ".", ".." };

            for (dot_entries) |dot_name| {
                const dot_matches = if (enable_extglob and extglob.containsExtglob(pattern)) blk: {
                    initExtglob();
                    break :blk extglob.fnmatchExtglob(pattern, dot_name);
                } else fnmatchWithContext(&pattern_ctx, dot_name);

                if (dot_matches) {
                    // no gitignore check for . and .. (they're special)
                    // . and .. are always directories
                    const path_result = buildFullPathWithMark(allocator, dirname, dot_name, use_dirname, true, flags) catch return error.OutOfMemory;
                    names.append(path_result.ptr, path_result.len) catch return error.OutOfMemory;
                }
            }
        }

        if (names.len() == 0) return null;
        return finalizeResults(allocator, &names, flags, pzlob);
    }

    // C-based path (no base_dir)
    var dirname_z: [4096:0]u8 = undefined;
    @memcpy(dirname_z[0..dirname.len], dirname);
    dirname_z[dirname.len] = 0;

    const dir = c.opendir(&dirname_z) orelse {
        // Directory open error - call errfunc if provided
        if (errfunc) |efunc| {
            const eerrno = @as(c_int, @intFromEnum(std.posix.errno(-1)));
            if (efunc(&dirname_z, eerrno) != 0) {
                return error.Aborted;
            }
        }
        // If ZLOB_ERR is set, abort on error
        if (flags.err) {
            return error.Aborted;
        }
        // Otherwise, return null to indicate no matches
        return null;
    };
    defer _ = c.closedir(dir);

    var names = ResultsList.initWithCapacity(allocator, 256) catch ResultsList.init(allocator);
    defer names.deinit();

    while (c.readdir(dir)) |entry_raw| {
        const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
        const name = direntNameSlice(&entry.name);
        if (shouldSkipFile(name, &pattern_ctx, flags)) continue;

        // Match using brace alternatives if available, otherwise use single pattern
        const matches = if (file_alternatives) |alts| blk: {
            // Check if we should use extglob matching
            if (enable_extglob and file_pattern_alts != null) {
                for (file_pattern_alts.?, alts) |raw_pat, alt_ctx| {
                    if (extglob.containsExtglob(raw_pat)) {
                        initExtglob();
                        if (extglob.fnmatchExtglob(raw_pat, name)) break :blk true;
                    } else if (alt_ctx.simd_batched_suffix_match) |batched_suffix_match| {
                        if (batched_suffix_match.matchSuffix(name)) break :blk true;
                    } else if (fnmatchWithContext(&alt_ctx, name)) {
                        break :blk true;
                    }
                }
                break :blk false;
            }
            // Try each alternative pattern
            for (alts) |alt_ctx| {
                if (alt_ctx.simd_batched_suffix_match) |batched_suffix_match| {
                    if (batched_suffix_match.matchSuffix(name)) break :blk true;
                } else if (fnmatchWithContext(&alt_ctx, name)) {
                    break :blk true;
                }
            }
            break :blk false;
        } else if (enable_extglob and extglob.containsExtglob(pattern)) blk: {
            initExtglob();
            break :blk extglob.fnmatchExtglob(pattern, name);
        } else if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
            batched_suffix_match.matchSuffix(name)
        else
            fnmatchWithContext(&pattern_ctx, name);

        if (matches) {
            if (directories_only) {
                const entry_dtype = entry.type;
                if (entry_dtype != DT_DIR and entry_dtype != DT_UNKNOWN) continue;
            }

            var is_dir = entry.type == DT_DIR;
            const needs_stat = entry.type == DT_UNKNOWN;

            // If we know is_dir already, use optimized path builder
            if (!needs_stat) {
                const path_result = buildFullPathWithMark(allocator, dirname, name, use_dirname, is_dir, flags) catch return error.OutOfMemory;

                if (directories_only and !is_dir) {
                    allocator.free(path_result.buf);
                    continue;
                }

                if (gitignore_filter) |gi| {
                    const base_len = if (use_dirname) dirname.len + 1 + name.len else name.len;
                    const rel_path = if (use_dirname) path_result.buf[0..base_len] else name;
                    if (gi.isIgnored(rel_path, is_dir)) {
                        allocator.free(path_result.buf);
                        continue;
                    }
                }

                names.append(path_result.ptr, path_result.len) catch return error.OutOfMemory;
            } else {
                // DT_UNKNOWN: need to stat to determine if directory
                @branchHint(.unlikely);
                const path_buf_slice = buildFullPath(allocator, dirname, name, use_dirname) catch return error.OutOfMemory;
                var path: [*c]u8 = @ptrCast(path_buf_slice.ptr);
                var final_path_len = path_buf_slice.len;

                var stat_buf: std.c.Stat = undefined;
                if (std.c.stat(path, &stat_buf) == 0) {
                    is_dir = std.c.S.ISDIR(stat_buf.mode);
                } else {
                    allocator.free(path_buf_slice);
                    continue;
                }

                if (directories_only and !is_dir) {
                    allocator.free(path_buf_slice);
                    continue;
                }

                if (gitignore_filter) |gi| {
                    const rel_path = if (use_dirname) path_buf_slice[0..final_path_len] else name;
                    if (gi.isIgnored(rel_path, is_dir)) {
                        allocator.free(path_buf_slice);
                        continue;
                    }
                }

                if (maybeAppendSlash(allocator, path, final_path_len, is_dir, flags) catch {
                    allocator.free(path_buf_slice);
                    return error.OutOfMemory;
                }) |new_path| {
                    path = new_path;
                    final_path_len += 1;
                }

                names.append(path, final_path_len) catch return error.OutOfMemory;
            }
        }
    }

    if (names.len() == 0) {
        if (flags.nocheck) {
            const pat_copy = allocator.allocSentinel(u8, pattern.len, 0) catch return error.OutOfMemory;
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = allocator.alloc([*c]u8, 2) catch return error.OutOfMemory;
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            const pathlen_buf = allocator.alloc(usize, 1) catch return error.OutOfMemory;
            pathlen_buf[0] = pattern.len;

            pzlob.zlo_pathc = 1;
            pzlob.zlo_pathv = result;
            pzlob.zlo_pathlen = pathlen_buf.ptr;
            pzlob.zlo_flags = ZLOB_FLAGS_OWNS_STRINGS;
            return;
        }
        return null;
    }

    return finalizeResults(allocator, &names, flags, pzlob);
}

// SIMD character search - find all positions of a character
pub fn simdFindChar(haystack: []const u8, needle: u8) ?usize {
    if (haystack.len >= 32) {
        const Vec32 = @Vector(32, u8);
        const needle_vec: Vec32 = @splat(needle);

        var i: usize = 0;
        while (i + 32 <= haystack.len) : (i += 32) {
            const chunk: Vec32 = haystack[i..][0..32].*;
            const matches = chunk == needle_vec;
            const mask = @as(u32, @bitCast(matches));
            if (mask != 0) {
                // Found a match, find first set bit
                const first_bit = @ctz(mask);
                return i + first_bit;
            }
        }
        for (haystack[i..], i..) |ch, idx| {
            if (ch == needle) return idx;
        }
        return null;
    }
    // Fallback for short strings
    for (haystack, 0..) |ch, idx| {
        if (ch == needle) return idx;
    }
    return null;
}

// SIMD-optimized fnmatch with pre-computed pattern context (avoids redundant wildcard checks)
pub inline fn fnmatchWithContext(ctx: *const PatternContext, string: []const u8) bool {
    // Early rejection: if we know the required last character and it doesn't match, reject immediately
    // This is a very cheap check that can avoid expensive pattern matching
    if (ctx.required_last_char) |required_last| {
        if (string.len == 0 or string[string.len - 1] != required_last) {
            return false;
        }
    }

    // Try template-based fast path first
    if (ctx.matchTemplate(string)) |result| {
        return result;
    }

    // Fast path: exact match with SIMD for long strings (only if no wildcards)
    if (ctx.pattern.len == string.len and !ctx.has_wildcards) {
        if (ctx.pattern.len >= 32) {
            const Vec32 = @Vector(32, u8);
            var i: usize = 0;
            while (i + 32 <= ctx.pattern.len) : (i += 32) {
                const p_vec: Vec32 = ctx.pattern[i..][0..32].*;
                const s_vec: Vec32 = string[i..][0..32].*;
                const eq = p_vec == s_vec;
                const mask = @as(u32, @bitCast(eq));
                if (mask != 0xFFFFFFFF) return false;
            }
            return mem.eql(u8, ctx.pattern[i..], string[i..]);
        }
        return mem.eql(u8, ctx.pattern, string);
    }

    if (ctx.only_suffix_match) |suffix_matcher| {
        return suffix_matcher.match(string);
    }

    return fnmatchFull(ctx.pattern, string);
}

/// Full fnmatch implementation - exposed for gitignore module
/// Note: This treats ** as regular * (no special directory handling)
/// For ** directory matching, use the gitignore module's matchGlob
/// By default, processes POSIX escape sequences (backslash escapes next char)
pub fn fnmatchFull(pattern: []const u8, string: []const u8) bool {
    return fnmatchWithFlags(pattern, string, true);
}

/// fnmatch implementation with configurable escape handling
/// enable_escapes: if true, backslash escapes the next character (POSIX default)
///                 if false, backslash is treated as literal (NOESCAPE mode)
pub fn fnmatchWithFlags(pattern: []const u8, string: []const u8, enable_escapes: bool) bool {
    var pi: usize = 0;
    var si: usize = 0;

    // Fast path: check literal prefix before first wildcard or escape
    // This avoids entering the slow recursive path for non-matching strings
    while (pi < pattern.len) {
        const p = pattern[pi];
        if (p == '*' or p == '?' or p == '[') break;
        if (enable_escapes and p == '\\') break;

        if (si >= string.len or string[si] != p) return false;
        pi += 1;
        si += 1;
    }

    // If pattern exhausted, check if string also exhausted
    if (pi >= pattern.len) return si == string.len;

    // Continue with wildcard matching from current position
    while (pi < pattern.len) {
        const p = pattern[pi];

        if (enable_escapes and p == '\\') {
            // POSIX escape: backslash quotes the next character
            pi += 1;
            if (pi >= pattern.len) {
                // Trailing backslash matches literal backslash
                if (si >= string.len or string[si] != '\\') return false;
                si += 1;
            } else {
                // Match the escaped character literally
                const escaped = pattern[pi];
                pi += 1;
                if (si >= string.len or string[si] != escaped) return false;
                si += 1;
            }
            continue;
        }

        switch (p) {
            '*' => {
                pi += 1;
                while (pi < pattern.len and pattern[pi] == '*') pi += 1;
                if (pi >= pattern.len) return true;

                // If next pattern char is a literal (not wildcard/bracket/escape), use SIMD
                const next = pattern[pi];
                const is_special = next == '*' or next == '?' or next == '[' or (enable_escapes and next == '\\');
                if (!is_special) {
                    // SIMD search for next literal character
                    var search_start = si;
                    while (search_start <= string.len) {
                        if (simdFindChar(string[search_start..], next)) |offset| {
                            const pos = search_start + offset;
                            if (fnmatchWithFlags(pattern[pi..], string[pos..], enable_escapes)) {
                                return true;
                            }
                            search_start = pos + 1;
                        } else {
                            return false;
                        }
                    }
                    return false;
                } else {
                    // Fallback for wildcards/brackets/escapes
                    while (si <= string.len) : (si += 1) {
                        if (fnmatchWithFlags(pattern[pi..], string[si..], enable_escapes)) {
                            return true;
                        }
                    }
                    return false;
                }
            },
            '?' => {
                if (si >= string.len) return false;
                si += 1;
                pi += 1;
            },
            '[' => {
                if (si >= string.len) return false;
                pi += 1;

                const ch = string[si];
                si += 1;

                var negate = false;
                // POSIX allows both ! and ^ for negation
                if (pi < pattern.len and (pattern[pi] == '!' or pattern[pi] == '^')) {
                    negate = true;
                    pi += 1;
                }

                // Use branchless bitmap matching for bracket expressions
                const result = matchBracketExpressionFast(pattern, pi, ch);
                pi = result.new_pi;
                var matched = result.matched;

                if (negate) matched = !matched;
                if (!matched) return false;
            },
            else => {
                if (si >= string.len or string[si] != p) return false;
                si += 1;
                pi += 1;
            },
        }
    }

    return si == string.len;
}

/// Initialize extglob module with fnmatchFull function pointer
/// This must be called before using extglob functionality
fn initExtglob() void {
    extglob.initFnmatch(&fnmatchFull);
}

/// fnmatch with extglob support - use this when ZLOB_EXTGLOB flag is set
/// If extglob is disabled or pattern doesn't contain extglob syntax, falls back to fnmatchFull
pub fn fnmatchWithExtglob(pattern: []const u8, string: []const u8, enable_extglob: bool) bool {
    if (enable_extglob and extglob.containsExtglob(pattern)) {
        // Ensure extglob module is initialized
        initExtglob();
        return extglob.fnmatchExtglob(pattern, string);
    }
    return fnmatchFull(pattern, string);
}

/// Fast bracket expression matching using branchless techniques
/// Returns the match result and the new pattern index after the closing ']'
/// Supports POSIX character classes like [[:alpha:]], [[:digit:]], etc.
inline fn matchBracketExpressionFast(pattern: []const u8, start_pi: usize, ch: u8) struct { matched: bool, new_pi: usize } {
    var pi = start_pi;
    const bracket_start = pi;

    // Build a 256-bit bitmap for the character set
    // Each bit represents whether that byte value is in the set
    var bitmap: [32]u8 = [_]u8{0} ** 32;

    while (pi < pattern.len) {
        const set_c = pattern[pi];

        // First character is always part of set (even if it's ']')
        // Only subsequent ']' closes the bracket expression
        if (set_c == ']' and pi > bracket_start) break;

        // Check for POSIX character class [[:class:]]
        if (set_c == '[' and pi + 2 < pattern.len and pattern[pi + 1] == ':') {
            // Find the closing :]]
            const class_result = parsePosixCharClass(pattern, pi);
            if (class_result.valid) {
                // Add all characters matching this class to the bitmap
                addPosixClassToBitmap(&bitmap, class_result.class_type);
                pi = class_result.end_pi;
                continue;
            }
        }

        pi += 1;

        if (pi + 1 < pattern.len and pattern[pi] == '-' and pattern[pi + 1] != ']') {
            // Range like [a-z]
            pi += 1;
            const range_end = pattern[pi];
            pi += 1;

            // Fill bitmap for range - unroll for common small ranges
            const start_byte = set_c;
            const end_byte = range_end;
            if (start_byte <= end_byte) {
                var range_c = start_byte;
                while (range_c <= end_byte) : (range_c += 1) {
                    bitmap[range_c >> 3] |= @as(u8, 1) << @as(u3, @truncate(range_c & 7));
                    if (range_c == 255) break; // Prevent overflow
                }
            }
        } else {
            // Single character
            bitmap[set_c >> 3] |= @as(u8, 1) << @as(u3, @truncate(set_c & 7));
        }
    }

    // Skip the closing ']'
    if (pi < pattern.len and pattern[pi] == ']') pi += 1;

    // Branchless bitmap lookup
    const matched = (bitmap[ch >> 3] & (@as(u8, 1) << @as(u3, @truncate(ch & 7)))) != 0;

    return .{ .matched = matched, .new_pi = pi };
}

/// POSIX character class types
const PosixCharClass = enum {
    alpha, // [[:alpha:]] - alphabetic
    digit, // [[:digit:]] - digits
    alnum, // [[:alnum:]] - alphanumeric
    space, // [[:space:]] - whitespace
    blank, // [[:blank:]] - space and tab
    lower, // [[:lower:]] - lowercase
    upper, // [[:upper:]] - uppercase
    punct, // [[:punct:]] - punctuation
    xdigit, // [[:xdigit:]] - hex digits
    cntrl, // [[:cntrl:]] - control characters
    graph, // [[:graph:]] - visible characters
    print, // [[:print:]] - printable characters
    invalid,
};

/// Parse a POSIX character class starting at pattern[pi] which should be '['
/// Returns the class type and the index after the closing ']]'
fn parsePosixCharClass(pattern: []const u8, start_pi: usize) struct { valid: bool, class_type: PosixCharClass, end_pi: usize } {
    // Pattern should be [[:classname:]]
    // start_pi points to the first '['
    if (start_pi + 2 >= pattern.len) return .{ .valid = false, .class_type = .invalid, .end_pi = start_pi };
    if (pattern[start_pi] != '[' or pattern[start_pi + 1] != ':') {
        return .{ .valid = false, .class_type = .invalid, .end_pi = start_pi };
    }

    // Find the closing :]]
    var pi = start_pi + 2;
    const class_start = pi;

    while (pi + 1 < pattern.len) {
        if (pattern[pi] == ':' and pattern[pi + 1] == ']') {
            const class_name = pattern[class_start..pi];
            const class_type = getPosixClassType(class_name);
            if (class_type != .invalid) {
                return .{ .valid = true, .class_type = class_type, .end_pi = pi + 2 };
            }
            return .{ .valid = false, .class_type = .invalid, .end_pi = start_pi };
        }
        pi += 1;
    }

    return .{ .valid = false, .class_type = .invalid, .end_pi = start_pi };
}

/// Get POSIX class type from class name
fn getPosixClassType(name: []const u8) PosixCharClass {
    if (mem.eql(u8, name, "alpha")) return .alpha;
    if (mem.eql(u8, name, "digit")) return .digit;
    if (mem.eql(u8, name, "alnum")) return .alnum;
    if (mem.eql(u8, name, "space")) return .space;
    if (mem.eql(u8, name, "blank")) return .blank;
    if (mem.eql(u8, name, "lower")) return .lower;
    if (mem.eql(u8, name, "upper")) return .upper;
    if (mem.eql(u8, name, "punct")) return .punct;
    if (mem.eql(u8, name, "xdigit")) return .xdigit;
    if (mem.eql(u8, name, "cntrl")) return .cntrl;
    if (mem.eql(u8, name, "graph")) return .graph;
    if (mem.eql(u8, name, "print")) return .print;
    return .invalid;
}

/// Add all characters matching a POSIX class to the bitmap
fn addPosixClassToBitmap(bitmap: *[32]u8, class_type: PosixCharClass) void {
    switch (class_type) {
        .alpha => {
            // A-Z
            addRangeToBitmap(bitmap, 'A', 'Z');
            // a-z
            addRangeToBitmap(bitmap, 'a', 'z');
        },
        .digit => {
            // 0-9
            addRangeToBitmap(bitmap, '0', '9');
        },
        .alnum => {
            // A-Z, a-z, 0-9
            addRangeToBitmap(bitmap, 'A', 'Z');
            addRangeToBitmap(bitmap, 'a', 'z');
            addRangeToBitmap(bitmap, '0', '9');
        },
        .space => {
            // space, \t, \n, \r, \f, \v
            const space_chars = [_]u8{ ' ', '\t', '\n', '\r', 0x0C, 0x0B };
            for (space_chars) |sc| {
                bitmap[sc >> 3] |= @as(u8, 1) << @as(u3, @truncate(sc & 7));
            }
        },
        .blank => {
            // space and tab only
            bitmap[' ' >> 3] |= @as(u8, 1) << @as(u3, @truncate(' ' & 7));
            bitmap['\t' >> 3] |= @as(u8, 1) << @as(u3, @truncate('\t' & 7));
        },
        .lower => {
            // a-z
            addRangeToBitmap(bitmap, 'a', 'z');
        },
        .upper => {
            // A-Z
            addRangeToBitmap(bitmap, 'A', 'Z');
        },
        .punct => {
            // Punctuation: !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~
            const punct_chars = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";
            for (punct_chars) |pc| {
                bitmap[pc >> 3] |= @as(u8, 1) << @as(u3, @truncate(pc & 7));
            }
        },
        .xdigit => {
            // 0-9, A-F, a-f
            addRangeToBitmap(bitmap, '0', '9');
            addRangeToBitmap(bitmap, 'A', 'F');
            addRangeToBitmap(bitmap, 'a', 'f');
        },
        .cntrl => {
            // Control characters: 0x00-0x1F and 0x7F
            addRangeToBitmap(bitmap, 0x00, 0x1F);
            bitmap[0x7F >> 3] |= @as(u8, 1) << @as(u3, @truncate(0x7F & 7));
        },
        .graph => {
            // Visible characters: 0x21-0x7E (printable except space)
            addRangeToBitmap(bitmap, 0x21, 0x7E);
        },
        .print => {
            // Printable characters: 0x20-0x7E
            addRangeToBitmap(bitmap, 0x20, 0x7E);
        },
        .invalid => {},
    }
}

/// Helper to add a range of characters to the bitmap
inline fn addRangeToBitmap(bitmap: *[32]u8, start: u8, end: u8) void {
    var ch: u8 = start;
    while (ch <= end) : (ch += 1) {
        bitmap[ch >> 3] |= @as(u8, 1) << @as(u3, @truncate(ch & 7));
        if (ch == 255) break; // Prevent overflow
    }
}

/// Internal globfree function - frees zlob_t structure
/// Used by GlobResults.deinit() and C API (c_lib.zig)
/// Exposed as public for C API compatibility
pub fn globfreeInternal(allocator: std.mem.Allocator, pzlob: *zlob_t) void {
    if (pzlob.zlo_pathv) |pathv| {
        // offs might be uninitialized if ZLOB_DOOFFS wasn't used - treat as 0
        const offs = pzlob.zlo_offs;

        const owns_strings = (pzlob.zlo_flags & ZLOB_FLAGS_OWNS_STRINGS) != 0;

        if (owns_strings) {
            var i: usize = 0;
            while (i < pzlob.zlo_pathc) : (i += 1) {
                if (pathv[offs + i]) |path| {
                    const path_len = pzlob.zlo_pathlen[i];
                    const path_slice = @as([*]u8, @ptrCast(path))[0 .. path_len + 1];
                    allocator.free(path_slice);
                }
            }
        }
        // Always free the pathv array including offset slots
        const pathv_slice = @as([*][*c]u8, @ptrCast(pathv))[0 .. offs + pzlob.zlo_pathc + 1];
        allocator.free(pathv_slice);

        // Always free the pathlen array
        const pathlen_slice = pzlob.zlo_pathlen[0..pzlob.zlo_pathc];
        allocator.free(pathlen_slice);
    }
    pzlob.zlo_pathv = null;
    pzlob.zlo_pathc = 0;
    pzlob.zlo_flags = ZLOB_FLAGS_SHARED_STRINGS;
}

/// Result of a glob operation containing matched paths
pub const GlobResults = struct {
    paths: [][]const u8,
    match_count: usize,
    allocator: Allocator,
    // Store full zlob_t for zero-copy glob results (null if paths are Zig-allocated)
    // This allows proper cleanup via globfreeInternal() which handles arena allocator
    pzlob: ?zlob_t = null,
    // Whether we own the path strings (true for glob(), false for matchPaths())
    owns_paths: bool = true,

    pub fn deinit(self: *GlobResults) void {
        if (self.pzlob) |*pzlob_ptr| {
            // Zero-copy mode: use globfreeInternal() which handles allocated paths
            globfreeInternal(self.allocator, pzlob_ptr);
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

    /// Extract the internal zlob_t for C API use (transfers ownership)
    /// After calling this, deinit() will not free the zlob_t data
    pub fn extractGlobT(self: *GlobResults) ?zlob_t {
        const result = self.pzlob;
        self.pzlob = null; // Mark as extracted, so deinit won't free it
        return result;
    }
};

// ============================================================================
// Tests for ZlobFlags packed struct
// ============================================================================

test "ZlobFlags bit positions match integer constants" {
    const testing = std.testing;

    // Verify each flag maps to the correct bit position
    const f_err = ZlobFlags{ .err = true };
    const f_mark = ZlobFlags{ .mark = true };
    const f_nosort = ZlobFlags{ .nosort = true };
    const f_dooffs = ZlobFlags{ .dooffs = true };
    const f_nocheck = ZlobFlags{ .nocheck = true };
    const f_append = ZlobFlags{ .append = true };
    const f_noescape = ZlobFlags{ .noescape = true };
    const f_period = ZlobFlags{ .period = true };
    const f_magchar = ZlobFlags{ .magchar = true };
    const f_altdirfunc = ZlobFlags{ .altdirfunc = true };
    const f_brace = ZlobFlags{ .brace = true };
    const f_nomagic = ZlobFlags{ .nomagic = true };
    const f_tilde = ZlobFlags{ .tilde = true };
    const f_onlydir = ZlobFlags{ .onlydir = true };
    const f_tilde_check = ZlobFlags{ .tilde_check = true };
    const f_gitignore = ZlobFlags{ .gitignore = true };

    try testing.expectEqual(@as(u32, ZLOB_ERR), f_err.toU32());
    try testing.expectEqual(@as(u32, ZLOB_MARK), f_mark.toU32());
    try testing.expectEqual(@as(u32, ZLOB_NOSORT), f_nosort.toU32());
    try testing.expectEqual(@as(u32, ZLOB_DOOFFS), f_dooffs.toU32());
    try testing.expectEqual(@as(u32, ZLOB_NOCHECK), f_nocheck.toU32());
    try testing.expectEqual(@as(u32, ZLOB_APPEND), f_append.toU32());
    try testing.expectEqual(@as(u32, ZLOB_NOESCAPE), f_noescape.toU32());
    try testing.expectEqual(@as(u32, ZLOB_PERIOD), f_period.toU32());
    try testing.expectEqual(@as(u32, ZLOB_MAGCHAR), f_magchar.toU32());
    try testing.expectEqual(@as(u32, ZLOB_ALTDIRFUNC), f_altdirfunc.toU32());
    try testing.expectEqual(@as(u32, ZLOB_BRACE), f_brace.toU32());
    try testing.expectEqual(@as(u32, ZLOB_NOMAGIC), f_nomagic.toU32());
    try testing.expectEqual(@as(u32, ZLOB_TILDE), f_tilde.toU32());
    try testing.expectEqual(@as(u32, ZLOB_ONLYDIR), f_onlydir.toU32());
    try testing.expectEqual(@as(u32, ZLOB_TILDE_CHECK), f_tilde_check.toU32());
    try testing.expectEqual(@as(u32, ZLOB_GITIGNORE), f_gitignore.toU32());
}

test "ZlobFlags roundtrip conversion" {
    const testing = std.testing;

    // Test multiple flags combined
    const combined: u32 = ZLOB_MARK | ZLOB_NOSORT | ZLOB_BRACE | ZLOB_GITIGNORE;
    const flags = ZlobFlags.fromU32(combined);

    try testing.expect(flags.mark);
    try testing.expect(flags.nosort);
    try testing.expect(flags.brace);
    try testing.expect(flags.gitignore);
    try testing.expect(!flags.err);
    try testing.expect(!flags.period);

    // Roundtrip back to integer
    try testing.expectEqual(combined, flags.toU32());

    // Test c_int conversion
    const combined_cint: c_int = @bitCast(combined);
    try testing.expectEqual(combined_cint, flags.toInt());

    const from_cint = ZlobFlags.fromInt(flags.toInt());
    try testing.expectEqual(combined, from_cint.toU32());
}

test "DirIterator with standard filesystem" {
    const testing = std.testing;

    // Test that DirIterator works with standard filesystem (no ALTDIRFUNC)
    var pzlob = zlob_t{
        .zlo_pathc = 0,
        .zlo_pathv = null,
        .zlo_offs = 0,
        .zlo_pathlen = undefined,
        .zlo_flags = 0,
    };

    // Open current directory without ALTDIRFUNC
    var iter = DirIterator.open(".", 0, &pzlob) catch |err| {
        std.debug.print("Failed to open directory: {}\n", .{err});
        return err;
    };
    defer iter.close();

    // Should be able to iterate
    var count: usize = 0;
    while (iter.next()) |entry| {
        _ = entry;
        count += 1;
        if (count > 100) break; // Safety limit
    }

    // Current directory should have at least some entries
    try testing.expect(count > 0);
}

test "DirIterator with ALTDIRFUNC" {
    const testing = std.testing;

    // Mock directory state - must be at file scope for C callbacks
    const MockDir = struct {
        const Entry = struct {
            name: [:0]const u8,
            d_type: u8,
        };

        const entries = [_]Entry{
            .{ .name = "file1.txt", .d_type = 8 }, // DT_REG
            .{ .name = "file2.zig", .d_type = 8 },
            .{ .name = "subdir", .d_type = 4 }, // DT_DIR
        };

        var index: usize = 0;
        var dirent_storage: zlob_dirent_t = undefined;

        fn opendir(_: [*:0]const u8) callconv(.c) ?*anyopaque {
            index = 0;
            // Return non-null to indicate success
            return @ptrFromInt(0x12345678);
        }

        fn readdir(_: ?*anyopaque) callconv(.c) ?*zlob_dirent_t {
            if (index >= entries.len) return null;
            dirent_storage.d_name = entries[index].name.ptr;
            dirent_storage.d_type = entries[index].d_type;
            index += 1;
            return &dirent_storage;
        }

        fn closedir(_: ?*anyopaque) callconv(.c) void {
            index = 0;
        }
    };

    // Set up zlob_t with ALTDIRFUNC callbacks
    var pzlob = zlob_t{
        .zlo_pathc = 0,
        .zlo_pathv = null,
        .zlo_offs = 0,
        .zlo_pathlen = undefined,
        .zlo_flags = 0,
        .zlo_opendir = MockDir.opendir,
        .zlo_readdir = MockDir.readdir,
        .zlo_closedir = MockDir.closedir,
    };

    // Open with ALTDIRFUNC flag
    var iter = DirIterator.open("mock_path", ZLOB_ALTDIRFUNC, &pzlob) catch |err| {
        std.debug.print("Failed to open mock directory: {}\n", .{err});
        return err;
    };
    defer iter.close();

    // Verify we get the mock entries
    var found_file1 = false;
    var found_file2 = false;
    var found_subdir = false;
    var count: usize = 0;

    while (iter.next()) |entry| {
        if (mem.eql(u8, entry.name, "file1.txt")) {
            found_file1 = true;
            try testing.expectEqual(std.fs.Dir.Entry.Kind.file, entry.kind);
        } else if (mem.eql(u8, entry.name, "file2.zig")) {
            found_file2 = true;
            try testing.expectEqual(std.fs.Dir.Entry.Kind.file, entry.kind);
        } else if (mem.eql(u8, entry.name, "subdir")) {
            found_subdir = true;
            try testing.expectEqual(std.fs.Dir.Entry.Kind.directory, entry.kind);
        }
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
    try testing.expect(found_file1);
    try testing.expect(found_file2);
    try testing.expect(found_subdir);
}
