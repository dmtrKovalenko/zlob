const std = @import("std");
const builtin = @import("builtin");
pub const suffix_match = @import("suffix_match.zig");
const brace_optimizer = @import("brace_optimizer.zig");
const pattern_context_internal = @import("pattern_context.zig");
const sorting = @import("sorting.zig");
const zlob_flags = @import("zlob_flags");
const walker = @import("walker");
const fnmatch_impl = @import("fnmatch.zig");
const utils = @import("utils.zig");

// std.c is only available on POSIX systems with libc
const has_libc = builtin.os.tag != .windows and builtin.link_libc;
const c = if (has_libc) std.c else struct {
    // Stubs for non-libc platforms (Windows)
    pub const dirent = extern struct {
        name: [256]u8,
        type: u8,
    };
    pub const DT = struct {
        pub const UNKNOWN: u8 = 0;
        pub const DIR: u8 = 4;
        pub const REG: u8 = 8;
    };
};
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const is_windows = builtin.os.tag == .windows;

/// Check if a character is a path separator.
/// On Windows, both '/' and '\\' are valid path separators.
inline fn isSep(ch: u8) bool {
    return ch == '/' or (is_windows and ch == '\\');
}

/// Find the last path separator in a slice.
/// On Windows, this checks for both '/' and '\\'.
fn lastSepPos(s: []const u8) ?usize {
    var i: usize = s.len;
    while (i > 0) {
        i -= 1;
        if (isSep(s[i])) return i;
    }
    return null;
}

const c_zlob = @cImport({
    @cInclude("zlob.h");
});

pub const fnmatch = fnmatch_impl;
pub const pattern_context = pattern_context_internal;

pub const PatternContext = pattern_context_internal.PatternContext;
pub const PatternTemplate = pattern_context_internal.PatternTemplate;
pub const hasWildcardsBasic = pattern_context_internal.hasWildcardsBasic;
pub const hasWildcards = pattern_context_internal.hasWildcards;
pub const indexOfCharSIMD = pattern_context_internal.indexOfCharSIMD;
pub const lastIndexOfCharSIMD = pattern_context_internal.lastIndexOfCharSIMD;
pub const lastIndexOfAnyTwoSIMD = pattern_context_internal.lastIndexOfAnyTwoSIMD;
pub const isPathSep = pattern_context_internal.isPathSep;
pub const containsExtglob = fnmatch_impl.containsExtglob;
pub const simdFindChar = fnmatch_impl.simdFindChar;
pub const gitignore = @import("gitignore.zig");
pub const GitIgnore = gitignore.GitIgnore;
pub const walk = @import("walker/walker.zig");

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

pub const opendir_t = ?*const fn (path: [*:0]const u8) callconv(.c) ?*anyopaque;
pub const readdir_t = ?*const fn (dir: ?*anyopaque) callconv(.c) ?*zlob_dirent_t;
pub const closedir_t = ?*const fn (dir: ?*anyopaque) callconv(.c) void;

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

    pub fn toFsProvider(self: *const zlob_t, flags: c_int) walker.AltFs {
        const use_altdirfunc = (flags & ZLOB_ALTDIRFUNC) != 0 and
            self.zlo_opendir != null and
            self.zlo_readdir != null and
            self.zlo_closedir != null;

        if (use_altdirfunc) {
            return .{
                .opendir = @ptrCast(self.zlo_opendir),
                .readdir = @ptrCast(self.zlo_readdir),
                .closedir = @ptrCast(self.zlo_closedir),
            };
        }
        return walker.AltFs.real_fs;
    }
};

fn globLiteralPath(allocator: Allocator, path: []const u8, flags: ZlobFlags, pzlob: *zlob_t, io: Io, base_dir: ?std.Io.Dir) !bool {
    const root = base_dir orelse std.Io.Dir.cwd();
    const stat = root.statFile(io, path, .{}) catch {
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
    try emitSingleResult(allocator, pzlob, return_path, needs_slash);

    return true;
}

pub const ZlobFlags = zlob_flags.ZlobFlags;
pub const ZlobError = zlob_flags.ZlobError;

const ZLOB_ALTDIRFUNC = zlob_flags.ZLOB_ALTDIRFUNC;
const ZLOB_MAGCHAR = zlob_flags.ZLOB_MAGCHAR;
const ZLOB_FLAGS_OWNS_STRINGS = zlob_flags.ZLOB_FLAGS_OWNS_STRINGS;
const ZLOB_FLAGS_SHARED_STRINGS = zlob_flags.ZLOB_FLAGS_SHARED_STRINGS;

pub const zlob_errfunc_t = ?*const fn (epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int;

pub const path_matcher = @import("path_matcher.zig");
pub const compiled_pattern = @import("compiled_pattern.zig");

pub const dirent = std.c.dirent;

pub const DT_UNKNOWN = std.c.DT.UNKNOWN;
pub const DT_DIR = std.c.DT.DIR;

/// Parallel arrays of paths and their lengths for zlob_t output.
/// Uses inline stack buffers for small result sets (up to 32 entries) to avoid
/// heap allocation entirely for common small-tree glob operations.
/// Falls back to heap-allocated arrays when the inline capacity is exceeded.
pub const ResultsList = struct {
    const INLINE_CAP = 32;

    /// Heap-allocated record buffers (null when using inline)
    heap_offsets: ?[*]usize = null,
    heap_lengths: ?[*]usize = null,

    count: usize = 0,
    capacity: usize = INLINE_CAP,
    allocator: Allocator,
    /// Backing storage for every path's bytes, each NUL-terminated. Records
    /// reference it by offset so it can realloc freely as results accumulate;
    /// offsets only become pointers in emit().
    bytes: std.ArrayList(u8) = .empty,
    // Inline record buffers for small result sets - avoids heap allocation
    // for the records of <=32 results
    inline_offsets: [INLINE_CAP]usize = undefined,
    inline_lengths: [INLINE_CAP]usize = undefined,

    /// Initialize with inline (stack) record capacity.
    pub fn init(allocator: Allocator) ResultsList {
        return .{ .allocator = allocator };
    }

    /// Initialize with pre-allocated record capacity.
    /// If requested capacity <= INLINE_CAP, uses the inline buffer (no heap alloc).
    /// Otherwise allocates on the heap.
    pub fn initWithCapacity(allocator: Allocator, capacity: usize) Allocator.Error!ResultsList {
        if (capacity <= INLINE_CAP) {
            return init(allocator);
        }
        const ho = try allocator.alloc(usize, capacity);
        errdefer allocator.free(ho);
        const hl = try allocator.alloc(usize, capacity);
        return .{
            .heap_offsets = ho.ptr,
            .heap_lengths = hl.ptr,
            .capacity = capacity,
            .allocator = allocator,
        };
    }

    inline fn isInline(self: *const ResultsList) bool {
        return self.heap_offsets == null;
    }

    /// Get pointer to current offsets storage
    inline fn offsetsPtr(self: *ResultsList) [*]usize {
        return self.heap_offsets orelse @as([*]usize, @ptrCast(&self.inline_offsets));
    }

    /// Get pointer to current lengths storage
    inline fn lengthsPtr(self: *ResultsList) [*]usize {
        return self.heap_lengths orelse @as([*]usize, @ptrCast(&self.inline_lengths));
    }

    pub fn deinit(self: *ResultsList) void {
        if (!self.isInline()) {
            self.allocator.free(self.heap_offsets.?[0..self.capacity]);
            self.allocator.free(self.heap_lengths.?[0..self.capacity]);
        }
        self.bytes.deinit(self.allocator);
    }

    /// Grow the record arrays to at least the given capacity, spilling from
    /// inline to heap if needed.
    fn grow(self: *ResultsList, min_capacity: usize) Allocator.Error!void {
        const new_cap = @max(min_capacity, self.capacity * 2);
        const new_offsets = try self.allocator.alloc(usize, new_cap);
        errdefer self.allocator.free(new_offsets);
        const new_lengths = try self.allocator.alloc(usize, new_cap);
        // Copy existing data
        if (self.count > 0) {
            @memcpy(new_offsets[0..self.count], self.offsetsPtr()[0..self.count]);
            @memcpy(new_lengths[0..self.count], self.lengthsPtr()[0..self.count]);
        }
        // Free old heap buffers (inline buffers are part of the struct, nothing to free)
        if (!self.isInline()) {
            self.allocator.free(self.heap_offsets.?[0..self.capacity]);
            self.allocator.free(self.heap_lengths.?[0..self.capacity]);
        }
        self.heap_offsets = new_offsets.ptr;
        self.heap_lengths = new_lengths.ptr;
        self.capacity = new_cap;
    }

    /// Reserve a record plus `path_len + 1` bytes and return the writable path
    /// slice for the caller to fill. The trailing NUL is already placed.
    pub fn addPath(self: *ResultsList, path_len: usize) Allocator.Error![]u8 {
        if (self.count >= self.capacity) {
            try self.grow(self.capacity + 1);
        }
        const off = self.bytes.items.len;
        try self.bytes.ensureUnusedCapacity(self.allocator, path_len + 1);
        self.bytes.items.len += path_len + 1;
        self.bytes.items[off + path_len] = 0;
        self.offsetsPtr()[self.count] = off;
        self.lengthsPtr()[self.count] = path_len;
        self.count += 1;
        return self.bytes.items[off..][0..path_len];
    }

    /// Copy a complete path into the shared buffer - O(1) amortized.
    pub fn appendPath(self: *ResultsList, path: []const u8) Allocator.Error!void {
        const dst = try self.addPath(path.len);
        @memcpy(dst, path);
    }

    /// Drop the most recently added path, for filters that reject it after
    /// it has already been built into the buffer.
    pub fn discardLast(self: *ResultsList) void {
        self.count -= 1;
        self.bytes.items.len = self.offsetsPtr()[self.count];
    }

    pub fn len(self: *const ResultsList) usize {
        return self.count;
    }

    /// View of the i-th path's bytes. Invalidated by any subsequent addPath.
    pub fn getPath(self: *ResultsList, i: usize) []const u8 {
        return self.bytes.items[self.offsetsPtr()[i]..][0..self.lengthsPtr()[i]];
    }

    /// Emit the collected results into `pzlob`:
    ///   pathv:   [offs nulls][count pointers][null]         (offs+count+1 slots)
    ///   pathlen: [count lengths][bytes base][bytes capacity] (count+2 slots)
    /// Ownership of the byte buffer moves into the zlob_t, and the two slots
    /// past the visible lengths let globfreeInternal release the whole result
    /// set in three frees. They are invisible to C callers, which only ever
    /// see zlo_pathlen as a pointer.
    /// On error the list is unchanged and still safe to deinit.
    pub fn emit(self: *ResultsList, offs: usize, pzlob: *zlob_t) Allocator.Error!void {
        const count = self.count;
        const pathv_buf = try self.allocator.alloc([*c]u8, offs + count + 1);
        errdefer self.allocator.free(pathv_buf);
        const pathlen_buf = try self.allocator.alloc(usize, count + 2);

        @memset(pathv_buf[0..offs], null);
        const base = self.bytes.items.ptr;
        const offsets = self.offsetsPtr();
        const lengths = self.lengthsPtr();
        for (0..count) |i| {
            pathv_buf[offs + i] = @ptrCast(base + offsets[i]);
            pathlen_buf[i] = lengths[i];
        }
        pathv_buf[offs + count] = null;
        pathlen_buf[count] = @intFromPtr(base);
        pathlen_buf[count + 1] = self.bytes.capacity;

        pzlob.zlo_pathc = count;
        pzlob.zlo_pathv = @ptrCast(pathv_buf.ptr);
        pzlob.zlo_pathlen = pathlen_buf.ptr;
        pzlob.zlo_flags = ZLOB_FLAGS_OWNS_STRINGS;

        // The byte buffer now belongs to pzlob; deinit must not free it.
        self.bytes = .empty;
    }
};

/// Emit a lone result path (NOCHECK pattern echo, literal path hit) in the
/// format ResultsList.emit produces, so globfreeInternal can treat every
/// OWNS_STRINGS zlob_t the same way.
pub fn emitSingleResult(allocator: Allocator, pzlob: *zlob_t, path: []const u8, append_slash: bool) Allocator.Error!void {
    var list = ResultsList.init(allocator);
    defer list.deinit();
    const total = path.len + @intFromBool(append_slash);
    const dst = try list.addPath(total);
    @memcpy(dst[0..path.len], path);
    if (append_slash) dst[path.len] = '/';
    try list.emit(0, pzlob);
}

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
        .is_absolute = if (is_windows)
            // Windows absolute paths: "C:\...", "\\...", or "/..."
            (pattern.len >= 3 and pattern[1] == ':' and (pattern[2] == '\\' or pattern[2] == '/')) or
                (pattern.len > 0 and (pattern[0] == '/' or pattern[0] == '\\'))
        else
            pattern.len > 0 and pattern[0] == '/',
        .fixed_component_count = 0,
        .simple_extension = null,
        .has_dir_wildcards = false,
        .directories_only = flags.onlydir,
    };

    // On Windows, backslash is a path separator, not an escape character.
    const enable_escape = !flags.noescape and !is_windows;
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

        if (isSep(ch)) {
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
        const sep_pos = if (is_windows)
            lastSepPos(info.wildcard_suffix)
        else
            mem.lastIndexOf(u8, info.wildcard_suffix, "/");
        if (sep_pos) |pos| {
            const dir_part = info.wildcard_suffix[0..pos];
            info.has_dir_wildcards = pattern_context_internal.hasWildcards(dir_part, flags);
        }
    }

    if (!info.has_recursive and !info.has_dir_wildcards and
        info.wildcard_suffix.len >= 2 and info.wildcard_suffix[0] == '*')
    {
        const suffix = info.wildcard_suffix[1..];
        const has_fwd_sep = indexOfCharSIMD(suffix, '/') != null;
        const has_sep = if (is_windows)
            has_fwd_sep or (indexOfCharSIMD(suffix, '\\') != null)
        else
            has_fwd_sep;
        if (!hasWildcardsBasic(suffix) and !has_sep) {
            info.simple_extension = suffix;
        }
    }

    if (!info.has_recursive) {
        var depth: usize = info.fixed_component_count;
        var remaining = info.wildcard_suffix;
        while (true) {
            const sep = indexOfCharSIMD(remaining, '/');
            const bsep = if (is_windows) indexOfCharSIMD(remaining, '\\') else null;
            const pos = if (sep != null and bsep != null)
                @min(sep.?, bsep.?)
            else
                (sep orelse bsep);
            if (pos) |p| {
                depth += 1;
                remaining = remaining[p + 1 ..];
            } else break;
        }
        if (remaining.len > 0) depth += 1;
        info.max_depth = depth;
    }

    return info;
}

inline fn matchWithAlternatives(name: []const u8, alternatives: []const []const u8) bool {
    for (alternatives) |alt| {
        const ctx = PatternContext.init(alt);
        if (ctx.single_suffix_matcher) |batched| {
            if (batched.matchSuffix(name)) return true;
        } else if (fnmatch_impl.fnmatchWithContext(&ctx, name, .{})) {
            return true;
        }
    }
    return false;
}

inline fn matchWithAlternativesExtglob(name: []const u8, alternatives: []const []const u8, enable_extglob: bool) bool {
    for (alternatives) |alt| {
        if (enable_extglob and fnmatch_impl.containsExtglob(alt)) {
            if (fnmatch_impl.matchExtglob(alt, name)) return true;
        } else {
            const ctx = PatternContext.init(alt);
            if (ctx.single_suffix_matcher) |batched| {
                if (batched.matchSuffix(name)) return true;
            } else if (fnmatch_impl.fnmatchWithContext(&ctx, name, .{})) {
                return true;
            }
        }
    }
    return false;
}

/// Bitmask of which alternatives contain extglob syntax, computed once per
/// glob call. Alternatives past 64 fall back to a live scan in altIsExtglob.
fn altExtglobMask(alternatives: anytype) u64 {
    var mask: u64 = 0;
    const alts = alternatives orelse return 0;
    for (alts, 0..) |alt, i| {
        if (i >= 64) break;
        if (fnmatch_impl.containsExtglob(alt)) mask |= @as(u64, 1) << @intCast(i);
    }
    return mask;
}

inline fn altIsExtglob(mask: u64, i: usize, pattern: []const u8) bool {
    if (i < 64) return (mask >> @intCast(i)) & 1 != 0;
    return fnmatch_impl.containsExtglob(pattern);
}

inline fn matchWithAlternativesPrecomputedExtglob(name: []const u8, patterns: []const []const u8, contexts: []const PatternContext, extglob_mask: u64) bool {
    for (patterns, contexts, 0..) |pat, *ctx, i| {
        if (altIsExtglob(extglob_mask, i, pat)) {
            if (fnmatch_impl.matchExtglob(pat, name)) return true;
        } else {
            if (ctx.single_suffix_matcher) |*batched| {
                if (batched.matchSuffix(name)) return true;
            } else if (fnmatch_impl.fnmatchWithContext(ctx, name, .{})) {
                return true;
            }
        }
    }
    return false;
}

const buildPathInBuffer = utils.buildPathInBuffer;

fn globWithWildcardDirsOptimized(allocator: std.mem.Allocator, pattern: []const u8, info: *const PatternInfo, flags: ZlobFlags, errfunc: zlob_errfunc_t, pzlob: *zlob_t, directories_only: bool, gitignore_filter: ?*GitIgnore, io: Io, base_dir: ?std.Io.Dir, fs_provider: walker.AltFs) !?void {
    // Note: gitignore filtering is not fully implemented in this path
    // The main recursive and filtered paths handle gitignore
    _ = gitignore_filter;

    var components: [64]WildcardComponent = undefined;
    var component_count: usize = 0;

    const effective_pattern = info.wildcard_suffix;

    var start: usize = 0;
    for (effective_pattern, 0..) |ch, idx| {
        if (isSep(ch)) {
            if (idx > start) {
                components[component_count] = WildcardComponent.init(effective_pattern[start..idx], flags);
                component_count += 1;
            }
            start = idx + 1;
        }
    }
    if (start < effective_pattern.len) {
        components[component_count] = WildcardComponent.init(effective_pattern[start..], flags);
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
    const start_dir = if (info.literal_prefix.len > 0)
        info.literal_prefix
    else
        ".";

    try expandWildcardComponents(allocator, start_dir, components[0..component_count], 0, &result_paths, directories_only, flags, errfunc, io, base_dir, fs_provider, base_dir, start_dir);

    if (result_paths.len() == 0) {
        if (flags.nocheck) {
            emitSingleResult(allocator, pzlob, pattern, false) catch return error.OutOfMemory;
            return;
        }
        return null;
    }

    return finalizeResults(allocator, &result_paths, flags, pzlob);
}

/// One path component of a wildcard-dirs pattern, with its match state
/// precomputed: expandWildcardComponents matches the same component against
/// every directory it visits.
const WildcardComponent = struct {
    text: []const u8,
    ctx: PatternContext,
    /// flags.extglob AND the component contains extglob syntax
    is_extglob: bool,

    fn init(text: []const u8, flags: ZlobFlags) WildcardComponent {
        return .{
            .text = text,
            .ctx = PatternContext.init(text),
            .is_extglob = flags.extglob and fnmatch_impl.containsExtglob(text),
        };
    }
};

/// `current_dir` is the full path from the walk root, used for results and
/// error reporting. `(rel_base, rel_path)` names the same directory relative
/// to an already-open ancestor fd where the platform offers one.
fn expandWildcardComponents(
    allocator: std.mem.Allocator,
    current_dir: []const u8,
    components: []const WildcardComponent,
    component_idx: usize,
    results: *ResultsList,
    directories_only: bool,
    flags: ZlobFlags,
    errfunc: zlob_errfunc_t,
    io: Io,
    base_dir: ?std.Io.Dir,
    fs_provider: walker.AltFs,
    rel_base: ?std.Io.Dir,
    rel_path: []const u8,
) !void {
    if (component_idx > 65536) {
        @branchHint(.unlikely);

        return error.Aborted;
    }

    if (component_idx >= components.len) {
        @branchHint(.unlikely);

        try results.appendPath(current_dir);
        return;
    }

    const component = &components[component_idx];
    const is_final = component_idx == components.len - 1;

    const component_ctx = &component.ctx;
    const has_extglob_pattern = component.is_extglob;
    const needs_wildcard_matching = component_ctx.has_wildcards or has_extglob_pattern;

    if (needs_wildcard_matching) {
        const hidden_config = walker.HiddenConfig.fromPatternAndFlags(
            component_ctx.starts_with_dot,
            component_ctx.is_dot_or_dotdot,
            flags.period,
        );

        var iter: walker.DirIterator = undefined;
        const opened = walker.DirIterator.openHandledInto(&iter, io, rel_path, rel_base, hidden_config, fs_provider, .{
            .err_callback = errfunc,
            .abort_on_error = flags.err,
            .report_path = current_dir,
        }) catch return error.Aborted;
        if (!opened) return;
        defer iter.close();

        const child_base = iter.relativeBase();

        while (iter.next()) |entry| {
            const name = entry.name;
            if (!is_final and entry.kind != .directory) continue;

            const matches = if (has_extglob_pattern) blk: {
                break :blk fnmatch_impl.matchExtglob(component.text, name);
            } else if (is_final and component_ctx.single_suffix_matcher != null)
                component_ctx.single_suffix_matcher.?.matchSuffix(name)
            else
                fnmatch_impl.fnmatchWithContext(component_ctx, name, .{});

            if (matches) {
                if (is_final) {
                    if (directories_only and entry.kind != .directory) continue;
                    // Build "dir/name" straight into the results buffer;
                    // recursing would stage it in a stack buffer first.
                    const use_dir = current_dir.len > 0 and !mem.eql(u8, current_dir, ".");
                    const total_len = if (use_dir) current_dir.len + 1 + name.len else name.len;
                    if (total_len >= 4096) continue;
                    const dst = try results.addPath(total_len);
                    if (use_dir) {
                        @memcpy(dst[0..current_dir.len], current_dir);
                        dst[current_dir.len] = '/';
                        @memcpy(dst[current_dir.len + 1 ..][0..name.len], name);
                    } else {
                        @memcpy(dst[0..name.len], name);
                    }
                    continue;
                }

                var new_path_buf: [4096]u8 = undefined;
                const new_path = buildPathInBuffer(&new_path_buf, current_dir, name);
                if (new_path.len >= 4096) continue;

                if (child_base) |cb| {
                    try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only, flags, errfunc, io, base_dir, fs_provider, cb, name);
                } else {
                    var rel_buf: [4096]u8 = undefined;
                    const new_rel = if (rel_path.len == current_dir.len and rel_path.ptr == current_dir.ptr)
                        new_path
                    else
                        buildPathInBuffer(&rel_buf, rel_path, name);
                    if (new_rel.len >= 4096) continue;
                    try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only, flags, errfunc, io, base_dir, fs_provider, rel_base, new_rel);
                }
            }
        }
    } else {
        // Literal component - just check if it exists
        var new_path_buf: [4096]u8 = undefined;
        const new_path = buildPathInBuffer(&new_path_buf, current_dir, component.text);

        if (new_path.len >= 4096) return;

        var rel_buf: [4096]u8 = undefined;
        const new_rel = if (rel_path.len == current_dir.len and rel_path.ptr == current_dir.ptr)
            new_path
        else
            buildPathInBuffer(&rel_buf, rel_path, component.text);
        if (new_rel.len >= 4096) return;

        if (!is_final) {
            // For non-final literal components, skip the stat() syscall entirely.
            // Just try to recurse - if the path doesn't exist, the next opendir will fail gracefully.
            try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only, flags, errfunc, io, base_dir, fs_provider, rel_base, new_rel);
        } else {
            // For final component, we need stat to check existence and directory-ness
            const root = rel_base orelse std.Io.Dir.cwd();
            const stat = root.statFile(io, new_rel, .{}) catch return;
            if (directories_only and stat.kind != .directory) return;
            try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only, flags, errfunc, io, base_dir, fs_provider, rel_base, new_rel);
        }
    }
}

fn globSingle(allocator: std.mem.Allocator, pattern: []const u8, brace_parsed: ?*const brace_optimizer.BracedPattern, flags_in: ZlobFlags, errfunc: zlob_errfunc_t, pzlob: *zlob_t, gitignore_filter: ?*GitIgnore, io: Io, base_dir: ?std.Io.Dir, fs_provider: walker.AltFs) !?void {
    var effective_pattern = pattern;
    var flags = flags_in;

    if (pattern.len > 0 and isSep(pattern[pattern.len - 1])) {
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
    const has_extglob_pattern = flags.extglob and fnmatch_impl.containsExtglob(effective_pattern);
    if (!hasWildcardsBasic(effective_pattern) and !needs_tilde_expansion and !has_brace_alternatives and !has_extglob_pattern) {
        // Check gitignore for literal path
        if (gitignore_filter) |gi| {
            const root = base_dir orelse std.Io.Dir.cwd();
            const stat = root.statFile(io, effective_pattern, .{}) catch null;
            const is_dir = if (stat) |s| s.kind == .directory else false;
            if (gi.isIgnored(effective_pattern, is_dir)) {
                if (flags.nocheck) {
                    return returnPatternAsResult(allocator, effective_pattern, pzlob);
                }
                return null;
            }
        }

        // Try to match literal path
        const found = try globLiteralPath(allocator, effective_pattern, flags, pzlob, io, base_dir);
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
                return globWithBracedComponents(allocator, parsed, &info, flags, errfunc, pzlob, info.directories_only, gitignore_filter, io, base_dir, fs_provider);
            }
        }
    }

    // Fast path: simple pattern with literal prefix (e.g., "src/foo/*.txt")
    if (info.simple_extension != null and info.literal_prefix.len > 0) {
        return globInSingleDirWithFnmatch(allocator, info.wildcard_suffix, info.literal_prefix, flags, errfunc, pzlob, info.directories_only, gitignore_filter, brace_parsed, io, base_dir, fs_provider);
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
                    if (isSep(effective_pattern[i])) {
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

            return globRecursive(allocator, pattern_from_doublestar, dirname, flags, errfunc, pzlob, info.directories_only, brace_parsed, gitignore_filter, io, base_dir, fs_provider);
        }
    }

    // If yes, need recursive directory expansion (slow path)
    var last_slash_pos: usize = 0;
    var i: usize = effective_pattern.len;
    while (i > 0) {
        i -= 1;
        if (isSep(effective_pattern[i])) {
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
        if (!has_wildcard_in_dir and flags.extglob and fnmatch_impl.containsExtglob(dir_part)) {
            has_wildcard_in_dir = true;
        }
    }

    // But skip if pattern has ** (needs special recursive handling)
    if (has_wildcard_in_dir and !info.has_recursive) {
        return globWithWildcardDirsOptimized(allocator, effective_pattern, &info, flags, errfunc, pzlob, info.directories_only, gitignore_filter, io, base_dir, fs_provider);
    }

    var dir_end: usize = 0;
    i = effective_pattern.len;
    while (i > 0) {
        i -= 1;
        if (isSep(effective_pattern[i])) {
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

    if (flags.doublestar_recursive and info.has_recursive) {
        return globRecursive(allocator, filename_pattern, dirname, flags, errfunc, pzlob, info.directories_only, brace_parsed, gitignore_filter, io, base_dir, fs_provider);
    }

    return globInSingleDirWithFnmatch(allocator, filename_pattern, dirname, flags, errfunc, pzlob, info.directories_only, gitignore_filter, brace_parsed, io, base_dir, fs_provider);
}

fn returnPatternAsResult(allocator: std.mem.Allocator, pattern: []const u8, pzlob: *zlob_t) !?void {
    try emitSingleResult(allocator, pzlob, pattern, false);
    return;
}

const expandTilde = utils.expandTilde;

/// Glob within a specific base directory.
/// base_path must be an absolute path, otherwise returns error.Aborted.
/// Absoluteness is platform-aware: POSIX `/foo`, Windows `C:\foo` / `\\server`.
pub fn globAt(allocator: std.mem.Allocator, io: Io, base_path: []const u8, pattern: [*:0]const u8, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t) !?void {
    // Validate that base_path is absolute
    if (base_path.len == 0 or !std.fs.path.isAbsolute(base_path)) {
        return error.Aborted;
    }

    // Open the base directory
    var base_dir = std.Io.Dir.openDirAbsolute(io, base_path, .{ .iterate = true }) catch {
        return error.Aborted;
    };
    defer base_dir.close(io);

    return globInternalZ(allocator, pattern, flags, errfunc, pzlob, io, base_dir);
}

pub fn glob(allocator: std.mem.Allocator, io: Io, pattern: [*:0]const u8, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t) !?void {
    return globInternalZ(allocator, pattern, flags, errfunc, pzlob, io, null);
}

pub fn globSlice(allocator: std.mem.Allocator, io: Io, pattern: []const u8, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t) !?void {
    return globInternalSlice(allocator, pattern, flags, errfunc, pzlob, io, null);
}

/// Internal glob implementation that accepts a slice pattern
fn globInternalSlice(allocator: std.mem.Allocator, pattern: []const u8, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t, io: Io, base_dir: ?std.Io.Dir) !?void {
    const gf = ZlobFlags.fromInt(flags);
    if (!gf.append) {
        pzlob.zlo_pathc = 0;
        pzlob.zlo_pathv = null;
        if (!gf.dooffs) {
            pzlob.zlo_offs = 0;
        }
    }

    const fs_provider = pzlob.toFsProvider(flags);
    var pattern_slice = pattern;

    // Check if pattern has magic characters (for ZLOB_MAGCHAR output flag)
    const has_magic = hasWildcards(pattern_slice, gf);

    // Handle tilde expansion (requires allocation for the expanded pattern)
    var expanded_pattern: ?[:0]const u8 = null;
    defer if (expanded_pattern) |exp| {
        allocator.free(exp[0 .. exp.len + 1]);
    };

    if (gf.tilde and pattern.len > 0 and pattern[0] == '~') {
        // Need null-terminated pattern for expandTilde
        const pattern_z = try allocator.allocSentinel(u8, pattern.len, 0);
        @memcpy(pattern_z, pattern);

        const result = try expandTilde(allocator, pattern_z, gf);
        if (result == null) {
            allocator.free(pattern_z[0 .. pattern.len + 1]);
            return null;
        }

        if (result.?.ptr == pattern_z.ptr) {
            // No expansion happened, free the temp allocation
            allocator.free(pattern_z[0 .. pattern.len + 1]);
        } else {
            // Expansion happened, free the temp and keep expanded
            allocator.free(pattern_z[0 .. pattern.len + 1]);
            expanded_pattern = result;
            pattern_slice = expanded_pattern.?;
        }
    }

    // Load gitignore if ZLOB_GITIGNORE flag is set
    var gitignore_instance: ?GitIgnore = null;
    defer if (gitignore_instance) |*gi| gi.deinit();

    if (gf.gitignore) {
        gitignore_instance = GitIgnore.loadFromCwd(allocator, io) catch null;
    }
    const gitignore_ptr: ?*GitIgnore = if (gitignore_instance) |*gi| gi else null;

    // Perform the actual globbing
    const result = blk: {
        if (gf.brace and brace_optimizer.containsBraces(pattern_slice)) {
            var opt = brace_optimizer.analyzeBracedPattern(allocator, pattern_slice) catch {
                break :blk try globBraceExpand(allocator, pattern_slice, gf, errfunc, pzlob, gitignore_ptr, io, base_dir, fs_provider);
            };
            defer opt.deinit();

            switch (opt) {
                .single_walk => |*brace_parsed| {
                    break :blk try globSingle(
                        allocator,
                        pattern_slice,
                        brace_parsed,
                        gf,
                        errfunc,
                        pzlob,
                        gitignore_ptr,
                        io,
                        base_dir,
                        fs_provider,
                    );
                },
                .fallback => {
                    break :blk try globBraceExpand(allocator, pattern_slice, gf, errfunc, pzlob, gitignore_ptr, io, base_dir, fs_provider);
                },
                .no_braces => {
                    break :blk try globBraceExpand(allocator, pattern_slice, gf, errfunc, pzlob, gitignore_ptr, io, base_dir, fs_provider);
                },
            }
        }

        break :blk try globSingle(allocator, pattern_slice, null, gf, errfunc, pzlob, gitignore_ptr, io, base_dir, fs_provider);
    };

    if (has_magic) {
        pzlob.zlo_flags |= ZLOB_MAGCHAR;
    }

    // BSD GLOB_NOMAGIC: if no matches and pattern has no magic characters,
    // return the pattern itself as the sole result (like NOCHECK but only
    // when there are no wildcards). See FreeBSD glob.c err_nomatch().
    if (result == null and gf.nomagic and !has_magic) {
        return returnPatternAsResult(allocator, pattern_slice, pzlob);
    }

    return result;
}

fn globInternalZ(allocator: std.mem.Allocator, pattern: [*:0]const u8, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t, io: Io, base_dir: ?std.Io.Dir) !?void {
    return globInternalSlice(allocator, mem.sliceTo(pattern, 0), flags, errfunc, pzlob, io, base_dir);
}

fn globBraceExpand(allocator: std.mem.Allocator, pattern: []const u8, flags: ZlobFlags, errfunc: zlob_errfunc_t, pzlob: *zlob_t, gitignore_filter: ?*GitIgnore, io: Io, base_dir: ?std.Io.Dir, fs_provider: walker.AltFs) !?void {
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

        _ = try globSingle(allocator, exp_slice, null, flags.without(.{ .append = true }), errfunc, &temp_pzlob, gitignore_filter, io, base_dir, fs_provider);

        // Copy each path's bytes into the shared buffer, then release the
        // sub-glob's result set.
        if (temp_pzlob.zlo_pathc > 0) {
            for (0..temp_pzlob.zlo_pathc) |i| {
                const path_ptr: [*]const u8 = @ptrCast(temp_pzlob.zlo_pathv[i]);
                try all_results.appendPath(path_ptr[0..temp_pzlob.zlo_pathlen[i]]);
            }
            globfreeInternal(allocator, &temp_pzlob);
        }
    }

    if (all_results.len() == 0) {
        if (flags.nocheck) {
            try emitSingleResult(allocator, pzlob, pattern, false);
            return;
        }
        return null;
    }

    const count = all_results.len();

    try all_results.emit(0, pzlob);

    // Sort using pre-computed lengths - no strlen() calls!
    if (!flags.nosort) {
        sorting.sortPaths(@ptrCast(pzlob.zlo_pathv), pzlob.zlo_pathlen, count);
    }
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
    /// Pre-compiled multi-suffix matcher for SIMD-parallel suffix matching
    multi_suffix_matcher: ?suffix_match.PrecompiledMultiSuffix = null,
    /// Optional gitignore filter (for ZLOB_GITIGNORE flag)
    gitignore_filter: ?*GitIgnore = null,
};

inline fn matchWithAlternativesPrecomputed(name: []const u8, contexts: []const PatternContext, multi_suffix: ?*const suffix_match.PrecompiledMultiSuffix) bool {
    // Fast path: use precompiled multi-suffix matcher for SIMD-parallel matching
    if (multi_suffix) |ms| {
        if (ms.all_simple_suffixes) {
            // All patterns are simple suffixes, use fast SIMD path
            return ms.matchAny(name);
        }
        // Try multi-suffix first, then fall through to complex patterns
        if (ms.matchAny(name)) return true;
        // Only check contexts that don't have single_suffix_matcher
        for (contexts) |*ctx| {
            if (ctx.single_suffix_matcher == null) {
                if (fnmatch_impl.fnmatchWithContext(ctx, name, .{})) {
                    return true;
                }
            }
        }
        return false;
    }

    // Fallback: iterate over each pattern context individually
    for (contexts) |*ctx| {
        if (ctx.single_suffix_matcher) |*batched| {
            if (batched.matchSuffix(name)) return true;
        } else {
            if (fnmatch_impl.fnmatchWithContext(ctx, name, .{})) {
                return true;
            }
        }
    }
    return false;
}

fn globRecursive(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: ZlobFlags, errfunc: zlob_errfunc_t, pzlob: *zlob_t, directories_only: bool, brace_parsed: ?*const brace_optimizer.BracedPattern, gitignore_filter: ?*GitIgnore, io: Io, base_dir: ?std.Io.Dir, fs_provider: walker.AltFs) !?void {
    const info = analyzePattern(pattern, flags);

    // Split pattern at **
    const double_star_pos = mem.indexOf(u8, pattern, "**") orelse return globInSingleDirWithFnmatch(allocator, pattern, dirname, flags, errfunc, pzlob, directories_only, gitignore_filter, brace_parsed, io, base_dir, fs_provider);

    var after_double_star = pattern[double_star_pos + 2 ..];

    if (after_double_star.len > 0 and isSep(after_double_star[0])) {
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
                if (comp.alternatives != null or hasWildcardsBasic(comp.text)) {
                    break;
                }
                literal_prefix_end = i + 1;
            }

            if (literal_prefix_end > 0) {
                var path_len: usize = 0;
                const is_absolute = dirname.len > 0 and dirname[0] == '/';

                // For absolute paths, restore the leading "/"
                if (is_absolute) {
                    start_dir_buf[0] = '/';
                    path_len = 1;
                }

                for (parsed.components[0..literal_prefix_end], 0..) |comp, i| {
                    if (i > 0 or (i == 0 and is_absolute)) {
                        if (path_len > 1 or (path_len == 1 and !is_absolute)) {
                            start_dir_buf[path_len] = '/';
                            path_len += 1;
                        }
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
        const last_slash_in_ads = if (is_windows)
            lastSepPos(after_double_star)
        else
            mem.lastIndexOf(u8, after_double_star, "/");
        if (last_slash_in_ads) |last_slash| {
            file_pattern = after_double_star[last_slash + 1 ..];
            const dir_path = after_double_star[0..last_slash];

            var start: usize = 0;
            for (dir_path, 0..) |ch, i| {
                if (isSep(ch)) {
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

    // OPTIMIZATION: if we have many alterantives suffixes precompile them to a single mask for SIMD
    const multi_suffix = if (file_pattern_contexts) |contexts|
        suffix_match.PrecompiledMultiSuffix.init(contexts)
    else
        null;

    const rec_pattern = RecursivePattern{
        .dir_components = post_ds_components_buf[0..post_ds_count],
        .file_pattern = file_pattern,
        .file_alternatives = file_alternatives,
        .file_pattern_contexts = file_pattern_contexts,
        .multi_suffix_matcher = multi_suffix,
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
            io,
            base_dir,
            fs_provider,
        );
    } else {
        // Use unified walker for both simple (**/*.txt) and complex (**/foo/*.txt) patterns
        try globRecursiveWalk(allocator, &rec_pattern, start_dir, flags, &all_results, &info, errfunc, io, base_dir, fs_provider);
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
    io: Io,
    base_dir: ?std.Io.Dir,
    fs_provider: walker.AltFs,
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
        if (flags.extglob and fnmatch_impl.containsExtglob(comp.text)) {
            has_wildcard = true;
        }
        if (has_wildcard) break;
        literal_prefix_end = i + 1;
    }

    // Build start directory from literal prefix components
    var start_dir_buf: [4096]u8 = undefined;
    var start_dir: []const u8 = ".";
    var start_component_idx: usize = 0;

    // on POSIX  "/tmp/foo/{a,b}.txt"
    //   split -> ["", "tmp", "foo", "{a,b}.txt"]
    //   The empty leading element is discarded, so the leading '/' is LOST
    // on Windows "C:/tmp/foo/{a,b}.txt"
    //   split -> ["C:", "tmp", "foo", "{a,b}.txt"]
    //   The drive letter survives as its own component
    const has_drive_letter = is_windows and info.is_absolute and
        parsed.components.len > 0 and
        parsed.components[0].text.len >= 2 and
        parsed.components[0].text[1] == ':';

    if (literal_prefix_end > 0) {
        var path_len: usize = 0;

        // For POSIX-style absolute paths, start with "/".
        // Drive-letter Windows absolutes preserve the drive prefix as-is.
        if (info.is_absolute and !has_drive_letter) {
            start_dir_buf[0] = '/';
            path_len = 1;
        }

        for (parsed.components[0..literal_prefix_end], 0..) |comp, i| {
            if (i > 0 or (i == 0 and info.is_absolute and !has_drive_letter)) {
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
    } else if (info.is_absolute and !has_drive_letter) {
        // No literal prefix but POSIX-absolute path - start from "/".
        start_dir = "/";
    }

    // If there are no wildcard/brace components left, just check if the path exists
    if (start_component_idx >= parsed.components.len) {
        // No wildcard components - just verify path exists and add it
        const root = base_dir orelse std.Io.Dir.cwd();
        _ = root.statFile(io, start_dir, .{}) catch return null;
        try all_results.appendPath(start_dir);
        return finalizeResults(allocator, &all_results, flags, pzlob);
    }

    // Convert remaining BracedComponents to ComponentMatcher format
    const remaining_components = parsed.components[start_component_idx..];
    var matchers: [32]BracedComponentMatcher = undefined;
    const matcher_count = @min(remaining_components.len, 32);
    for (remaining_components[0..matcher_count], 0..) |comp, i| {
        matchers[i] = BracedComponentMatcher.fromBracedComponent(&comp);
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
        io,
        base_dir,
        fs_provider,
        struct {
            fn onComplete(alloc: std.mem.Allocator, path: []const u8, results: *ResultsList, _: bool) !void {
                _ = alloc;
                try results.appendPath(path);
            }
        }.onComplete,
    );

    if (all_results.len() == 0) {
        return null;
    }

    // Note: sorting is now handled inside finalizeResults using pre-computed lengths
    return finalizeResults(allocator, &all_results, flags, pzlob);
}

const BracedComponentMatcher = struct {
    text: []const u8,
    alternatives: ?[]const []const u8,
    is_last: bool,
    /// Precomputed once per matcher, since matchesWithFlags runs per entry.
    ctx: PatternContext,
    /// text contains extglob syntax (flag-independent; gate with the flag)
    has_extglob: bool,

    fn fromBracedComponent(comp: *const brace_optimizer.BracedComponent) BracedComponentMatcher {
        return fromTextAndAlts(comp.text, comp.alternatives, comp.is_last);
    }

    fn fromTextAndAlts(text: []const u8, alts: ?[]const []const u8, is_last: bool) BracedComponentMatcher {
        return .{
            .text = text,
            .alternatives = alts,
            .is_last = is_last,
            .ctx = PatternContext.init(text),
            .has_extglob = fnmatch_impl.containsExtglob(text),
        };
    }

    /// Check if name matches this component
    fn matches(self: *const BracedComponentMatcher, name: []const u8) bool {
        return self.matchesWithFlags(name, false);
    }

    /// Check if name matches this component with extglob support
    fn matchesWithFlags(self: *const BracedComponentMatcher, name: []const u8, enable_extglob: bool) bool {
        if (self.alternatives) |alts| {
            return matchWithAlternativesExtglob(name, alts, enable_extglob);
        }
        if (enable_extglob and self.has_extglob) {
            return fnmatch_impl.matchExtglob(self.text, name);
        }
        return fnmatch_impl.fnmatchWithContext(&self.ctx, name, .{});
    }

    /// Check if any pattern/alternative starts with dot
    fn startsWithDot(self: *const BracedComponentMatcher) bool {
        if (self.text.len > 0 and self.text[0] == '.') return true;
        if (self.alternatives) |alts| {
            for (alts) |alt| {
                if (alt.len > 0 and alt[0] == '.') return true;
            }
        }
        return false;
    }
};

fn walkBracedComponents(
    allocator: std.mem.Allocator,
    matchers: []const BracedComponentMatcher,
    component_idx: usize,
    current_dir: []const u8,
    flags: ZlobFlags,
    results: *ResultsList,
    directories_only: bool,
    errfunc: zlob_errfunc_t,
    io: Io,
    base_dir: ?std.Io.Dir,
    fs_provider: walker.AltFs,
    comptime onComplete: fn (std.mem.Allocator, []const u8, *ResultsList, bool) error{ OutOfMemory, Aborted }!void,
) error{ OutOfMemory, Aborted }!void {
    if (component_idx >= matchers.len) {
        try onComplete(allocator, current_dir, results, directories_only);
        return;
    }

    const matcher = &matchers[component_idx];
    const is_final = component_idx == matchers.len - 1;

    // Compute hidden config from matcher and flags
    const hidden_config = walker.HiddenConfig{
        // Include "." and ".." if pattern starts with '.'
        .include_dot_entries = matcher.startsWithDot(),
        // Include hidden files if PERIOD flag is set OR pattern starts with '.'
        .include_hidden = flags.period or matcher.startsWithDot(),
    };

    // Use walker's DirIterator with FsProvider for ALTDIRFUNC support
    var iter: walker.DirIterator = undefined;
    const opened = walker.DirIterator.openHandledInto(&iter, io, current_dir, base_dir, hidden_config, fs_provider, .{
        .err_callback = errfunc,
        .abort_on_error = flags.err,
    }) catch return error.Aborted;
    if (!opened) return;
    defer iter.close();

    while (iter.next()) |entry| {
        // Note: Hidden file filtering is now done at iterator level
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
                io,
                base_dir,
                fs_provider,
                onComplete,
            );
        }
    }
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
    io: Io,
    base_dir: ?std.Io.Dir,
    fs_provider: walker.AltFs,
) !void {
    // If we've matched all pre-doublestar components, start the recursive walk
    if (component_idx >= pre_ds_components.len) {
        // Use unified walker for both simple and complex patterns
        try globRecursiveWalk(allocator, rec_pattern, current_dir, flags, results, info, errfunc, io, base_dir, fs_provider);
        return;
    }

    const matcher = BracedComponentMatcher.fromTextAndAlts(
        pre_ds_components[component_idx],
        pre_ds_alternatives[component_idx],
        false, // not last - always matching directories
    );

    // Compute hidden config from matcher and flags
    const hidden_config = walker.HiddenConfig{
        // Include "." and ".." if pattern starts with '.'
        .include_dot_entries = matcher.startsWithDot(),
        // Include hidden files if PERIOD flag is set OR pattern starts with '.'
        .include_hidden = flags.period or matcher.startsWithDot(),
    };

    // Use walker's DirIterator with FsProvider for ALTDIRFUNC support
    var iter: walker.DirIterator = undefined;
    const opened = walker.DirIterator.openHandledInto(&iter, io, current_dir, base_dir, hidden_config, fs_provider, .{
        .err_callback = errfunc,
        .abort_on_error = flags.err,
    }) catch return error.Aborted;
    if (!opened) return;
    defer iter.close();

    while (iter.next()) |entry| {
        // Note: Hidden file filtering is now done at iterator level
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
                io,
                base_dir,
                fs_provider,
            );
        }
    }
}

fn finalizeResults(allocator: std.mem.Allocator, results: *ResultsList, flags: ZlobFlags, pzlob: *zlob_t) !?void {
    const offs = if (flags.dooffs) pzlob.zlo_offs else 0;
    const new_count = results.len();

    // ZLOB_APPEND - merge with existing results. The emit format keeps all
    // owned strings in one buffer, so import the old set's bytes then the new
    // ones and release the old result set wholesale.
    if (flags.append and pzlob.zlo_pathv != null and pzlob.zlo_pathc > 0) {
        const old_count = pzlob.zlo_pathc;

        var combined = try ResultsList.initWithCapacity(allocator, old_count + new_count);
        defer combined.deinit();

        for (0..old_count) |i| {
            const path_ptr: [*]const u8 = @ptrCast(pzlob.zlo_pathv[offs + i]);
            try combined.appendPath(path_ptr[0..pzlob.zlo_pathlen[i]]);
        }
        for (0..new_count) |i| {
            try combined.appendPath(results.getPath(i));
        }

        // Frees the old arrays and, when owned, the old byte buffer.
        // Leaves zlo_offs alone for the emit() below.
        globfreeInternal(allocator, pzlob);

        try combined.emit(offs, pzlob);

        if (!flags.nosort and new_count > 0) {
            sorting.sortPaths(@ptrCast(pzlob.zlo_pathv + offs + old_count), pzlob.zlo_pathlen + old_count, new_count);
        }
        return;
    }

    try results.emit(offs, pzlob);

    if (!flags.nosort) {
        sorting.sortPaths(@ptrCast(pzlob.zlo_pathv + offs), pzlob.zlo_pathlen, new_count);
    }
    return;
}

fn globRecursiveWalk(
    allocator: std.mem.Allocator,
    rec_pattern: *const RecursivePattern,
    start_dir: []const u8,
    flags: ZlobFlags,
    results: *ResultsList,
    info: *const PatternInfo,
    errfunc: zlob_errfunc_t,
    io: Io,
    base_dir: ?std.Io.Dir,
    fs_provider: walker.AltFs,
) !void {
    const has_dir_components = rec_pattern.dir_components.len > 0;

    const pattern_ctx = PatternContext.init(rec_pattern.file_pattern);
    const enable_extglob = flags.extglob;
    // Loop-invariant, so keep it out of the per-entry match chain below.
    const file_pattern_is_extglob = enable_extglob and fnmatch_impl.containsExtglob(rec_pattern.file_pattern);
    const file_alt_extglob_mask: u64 = if (enable_extglob) altExtglobMask(rec_pattern.file_alternatives) else 0;

    var dir_component_contexts: [32]PatternContext = undefined;
    if (has_dir_components) {
        for (rec_pattern.dir_components, 0..) |comp, i| {
            dir_component_contexts[i] = PatternContext.init(comp);
        }
    }
    const dir_contexts = dir_component_contexts[0..rec_pattern.dir_components.len];

    // Check if any dir_component explicitly matches hidden dirs (starts with '.')
    // or if the file pattern starts with '.' (e.g., **/.hidden*)
    // If so, we can't skip hidden directories at the walker level
    var pattern_wants_hidden = pattern_ctx.starts_with_dot;
    if (has_dir_components and !pattern_wants_hidden) {
        for (rec_pattern.dir_components) |comp| {
            if (comp.len > 0 and comp[0] == '.') {
                pattern_wants_hidden = true;
                break;
            }
        }
    }

    const hidden_config = walker.HiddenConfig{
        // Never include "." and ".." in recursive walks - they don't make sense for **
        .include_dot_entries = false,
        // Include hidden files if PERIOD flag is set OR pattern explicitly wants hidden
        .include_hidden = flags.period or pattern_wants_hidden,
    };

    var walker_config = walker.WalkerConfig{
        .base_dir = base_dir,
        .err_callback = errfunc,
        .abort_on_error = flags.err,
        .hidden = hidden_config,
        .follow_symlinks = flags.follow_symlinks,
        .fs = fs_provider,
    };

    if (rec_pattern.gitignore_filter) |gi| {
        walker_config.dir_filter = .{
            .filterDirFn = struct {
                fn filter(ctx: *anyopaque, relative_path: []const u8, _: []const u8) bool {
                    const gi_ptr: *GitIgnore = @ptrCast(@alignCast(ctx));
                    return !gi_ptr.shouldSkipDirectory(relative_path);
                }
            }.filter,
            .context = @ptrCast(gi),
        };
    }

    var dir_walker = walker.DefaultWalker.init(allocator, io, start_dir, walker_config) catch |err| {
        return if (err == error.Aborted) error.Aborted else {};
    };
    defer dir_walker.deinit();

    // Determine if we need to prepend start_dir to paths
    const use_dirname = start_dir.len > 0 and !mem.eql(u8, start_dir, ".");
    while (dir_walker.next() catch null) |entry| {
        const is_dir = entry.kind == .directory;
        if (is_dir and !info.directories_only) continue;

        if (rec_pattern.gitignore_filter) |gi| {
            // The directory filter above prunes top-down, so every ancestor of
            // this entry is already known to be included. Avoid re-walking the
            // ancestor chain for every result.
            if (gi.checkInode(entry.path, entry.basename, is_dir) orelse false) continue;
        }

        // For patterns with dir_components like **/foo/bar/*.c:
        // Check if the path contains the dir_components in order
        if (has_dir_components) {
            // Find the parent directory path
            const last_slash = mem.lastIndexOf(u8, entry.path, "/") orelse continue;
            const parent_path = entry.path[0..last_slash];

            // Check if dir_components match at the end of parent_path
            if (!matchDirComponents(parent_path, rec_pattern.dir_components, rec_pattern.dir_component_alternatives, dir_contexts, enable_extglob)) {
                continue;
            }
        }

        const matches = if (rec_pattern.file_pattern_contexts) |contexts| blk: {
            if (enable_extglob and rec_pattern.file_alternatives != null) {
                break :blk matchWithAlternativesPrecomputedExtglob(entry.basename, rec_pattern.file_alternatives.?, contexts, file_alt_extglob_mask);
            }
            const multi_suffix_ptr = if (rec_pattern.multi_suffix_matcher) |*ms| ms else null;
            break :blk matchWithAlternativesPrecomputed(entry.basename, contexts, multi_suffix_ptr);
        } else if (rec_pattern.file_alternatives) |alts|
            matchWithAlternativesExtglob(entry.basename, alts, enable_extglob)
        else if (file_pattern_is_extglob) blk: {
            break :blk fnmatch_impl.matchExtglob(rec_pattern.file_pattern, entry.basename);
        } else if (pattern_ctx.single_suffix_matcher) |sufxi_matcher|
            sufxi_matcher.matchSuffix(entry.basename)
        else
            fnmatch_impl.fnmatchWithContext(&pattern_ctx, entry.basename, .{});

        if (matches) {
            if (info.directories_only and !is_dir) continue;

            // Build full path directly in the results' shared byte buffer
            const needs_mark = flags.mark and is_dir;
            const base_path_len = if (use_dirname) start_dir.len + 1 + entry.path.len else entry.path.len;
            const alloc_len = if (needs_mark) base_path_len + 1 else base_path_len;

            const path_buf = results.addPath(alloc_len) catch return error.OutOfMemory;

            if (use_dirname) {
                @memcpy(path_buf[0..start_dir.len], start_dir);
                path_buf[start_dir.len] = '/';
                @memcpy(path_buf[start_dir.len + 1 ..][0..entry.path.len], entry.path);
            } else {
                @memcpy(path_buf[0..entry.path.len], entry.path);
            }

            if (needs_mark) {
                path_buf[base_path_len] = '/';
            }
        }
    }
}

fn matchDirComponents(
    path: []const u8,
    dir_components: []const []const u8,
    dir_alternatives: ?[]const ?[]const []const u8,
    dir_contexts: []const PatternContext,
    enable_extglob: bool,
) bool {
    if (dir_components.len == 0) return true;

    // Split path into components from the end
    var path_components: [64][]const u8 = undefined;
    var path_count: usize = 0;

    var end = path.len;
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (isSep(path[i - 1])) {
            if (i < end and path_count < 64) {
                path_components[path_count] = path[i..end];
                path_count += 1;
            }
            end = i - 1;
        }
    }
    if (end > 0 and path_count < 64) {
        path_components[path_count] = path[0..end];
        path_count += 1;
    }

    // We need at least as many path components as dir_components
    if (path_count < dir_components.len) return false;

    // Match dir_components against the last N path components (in reverse order)
    // path_components is reversed, so path_components[0] is the last component
    for (0..dir_components.len) |j| {
        const dir_comp = dir_components[dir_components.len - 1 - j];
        const path_comp = path_components[j];

        // Check alternatives first
        if (dir_alternatives) |alts| {
            if (alts[dir_components.len - 1 - j]) |alt_list| {
                if (matchWithAlternativesExtglob(path_comp, alt_list, enable_extglob)) continue;
                return false;
            }
        }

        // Check extglob
        if (enable_extglob and fnmatch_impl.containsExtglob(dir_comp)) {
            if (!fnmatch_impl.matchExtglob(dir_comp, path_comp)) return false;
            continue;
        }

        // Use precomputed context
        if (!fnmatch_impl.fnmatchWithContext(&dir_contexts[dir_components.len - 1 - j], path_comp, .{})) {
            return false;
        }
    }

    return true;
}

fn globInSingleDirWithFnmatch(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: ZlobFlags, errfunc: zlob_errfunc_t, pzlob: *zlob_t, directories_only: bool, gitignore_filter: ?*GitIgnore, brace_parsed: ?*const brace_optimizer.BracedPattern, io: Io, base_dir: ?std.Io.Dir, fs_provider: walker.AltFs) !?void {
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
    // Loop-invariant, so keep it out of the per-entry match chain below.
    const pattern_is_extglob = enable_extglob and fnmatch_impl.containsExtglob(pattern);
    const alt_extglob_mask: u64 = if (enable_extglob) altExtglobMask(file_pattern_alts) else 0;

    var names = ResultsList.initWithCapacity(allocator, 256) catch ResultsList.init(allocator);
    defer names.deinit();

    // Compute hidden config from pattern and flags - filtering now happens at iterator level
    const hidden_config = walker.HiddenConfig.fromPatternAndFlags(
        pattern_ctx.starts_with_dot,
        pattern_ctx.is_dot_or_dotdot,
        flags.period,
    );

    // Use walker's DirIterator with FsProvider for ALTDIRFUNC support
    var iter: walker.DirIterator = undefined;
    const opened = walker.DirIterator.openHandledInto(&iter, io, dirname, base_dir, hidden_config, fs_provider, .{
        .err_callback = errfunc,
        .abort_on_error = flags.err,
    }) catch return error.Aborted;
    if (!opened) return null;
    defer iter.close();

    while (iter.next()) |entry| {
        const name = entry.name;
        // Note: Hidden file and dot entry filtering is now done at iterator level

        const matches = if (file_alternatives) |alts| blk: {
            // Check if we should use extglob matching
            if (enable_extglob and file_pattern_alts != null) {
                for (file_pattern_alts.?, alts, 0..) |raw_pat, alt_ctx, alt_i| {
                    if (altIsExtglob(alt_extglob_mask, alt_i, raw_pat)) {
                        if (fnmatch_impl.matchExtglob(raw_pat, name)) break :blk true;
                    } else if (alt_ctx.single_suffix_matcher) |batched_suffix_match| {
                        if (batched_suffix_match.matchSuffix(name)) break :blk true;
                    } else if (fnmatch_impl.fnmatchWithContext(&alt_ctx, name, .{})) {
                        break :blk true;
                    }
                }
                break :blk false;
            }
            for (alts) |alt_ctx| {
                if (alt_ctx.single_suffix_matcher) |batched_suffix_match| {
                    if (batched_suffix_match.matchSuffix(name)) break :blk true;
                } else if (fnmatch_impl.fnmatchWithContext(&alt_ctx, name, .{})) {
                    break :blk true;
                }
            }
            break :blk false;
        } else if (pattern_is_extglob) blk: {
            break :blk fnmatch_impl.matchExtglob(pattern, name);
        } else if (pattern_ctx.single_suffix_matcher) |batched_suffix_match|
            batched_suffix_match.matchSuffix(name)
        else
            fnmatch_impl.fnmatchWithContext(&pattern_ctx, name, .{});

        if (matches) {
            const is_dir = entry.kind == .directory;
            if (directories_only and !is_dir) continue;

            // Build the path directly in the results' shared byte buffer,
            // pre-sized for an optional trailing '/' mark
            const base_len = if (use_dirname) dirname.len + 1 + name.len else name.len;
            const needs_mark = flags.mark and is_dir;
            const alloc_len = if (needs_mark) base_len + 1 else base_len;

            const dst = names.addPath(alloc_len) catch return error.OutOfMemory;
            if (use_dirname) {
                @memcpy(dst[0..dirname.len], dirname);
                dst[dirname.len] = '/';
                @memcpy(dst[dirname.len + 1 ..][0..name.len], name);
            } else {
                @memcpy(dst[0..name.len], name);
            }
            if (needs_mark) {
                dst[base_len] = '/';
            }

            if (gitignore_filter) |gi| {
                const relative_path = if (use_dirname) dst[0..base_len] else name;
                if (gi.isIgnored(relative_path, is_dir)) {
                    names.discardLast();
                    continue;
                }
            }
        }
    }

    if (names.len() == 0) {
        if (flags.nocheck) {
            emitSingleResult(allocator, pzlob, pattern, false) catch return error.OutOfMemory;
            return;
        }
        return null;
    }

    return finalizeResults(allocator, &names, flags, pzlob);
}

/// Result of a glob operation containing matched paths.
///
/// Uses zero-copy access when backed by a zlob_t (filesystem glob results),
/// avoiding an extra allocation and re-iteration over the paths array.
/// For in-memory matching (matchPaths), stores an owned Zig slice directly.
///
/// Access paths via:
/// - `result.get(i)` for indexed access
/// - `var it = result.iterator(); while (it.next()) |path| { ... }` for iteration
/// - `result.len()` for the count
pub const ZlobResults = struct {
    /// Backing storage: either a zlob_t (zero-copy C arrays) or an owned Zig slice
    source: Source,
    allocator: Allocator,

    pub const Source = union(enum) {
        /// Zero-copy: reads directly from zlob_t's C arrays (zlo_pathv + zlo_pathlen)
        zlob: zlob_t,
        /// Owned Zig slice of path slices (from matchPaths or nocheck fallback)
        paths: OwnedPaths,
    };

    pub const OwnedPaths = struct {
        items: [][]const u8,
        owns_strings: bool,
    };

    /// Iterator over glob results. Yields one `[]const u8` path per call to `next()`.
    pub const Iterator = struct {
        results: *const ZlobResults,
        index: usize = 0,

        pub fn next(self: *Iterator) ?[]const u8 {
            if (self.index >= self.results.len()) return null;
            const path = self.results.get(self.index);
            self.index += 1;
            return path;
        }

        /// Reset the iterator to the beginning
        pub fn reset(self: *Iterator) void {
            self.index = 0;
        }
    };

    /// Return the number of matched paths
    pub fn len(self: *const ZlobResults) usize {
        return switch (self.source) {
            .zlob => |pzlob| pzlob.zlo_pathc,
            .paths => |owned| owned.items.len,
        };
    }

    /// Efficiently get zig slice from the zlob results without copying.
    pub fn get(self: *const ZlobResults, i: usize) []const u8 {
        return switch (self.source) {
            .zlob => |pzlob| {
                const c_path: [*]const u8 = @ptrCast(pzlob.zlo_pathv[i]);
                const path_len = pzlob.zlo_pathlen[i];
                return c_path[0..path_len];
            },
            .paths => |owned| owned.items[i],
        };
    }

    /// Return an iterator over all matched paths
    pub fn iterator(self: *const ZlobResults) Iterator {
        return .{ .results = self };
    }

    /// Materialize all paths into a `[][]const u8` slice.
    /// Caller owns the returned slice and must free it with `alloc.free(slice)`.
    /// The path strings themselves are NOT copied — they point into the original storage.
    pub fn toSlice(self: *const ZlobResults, alloc: Allocator) ![][]const u8 {
        const count = self.len();
        const slice = try alloc.alloc([]const u8, count);
        for (0..count) |i| {
            slice[i] = self.get(i);
        }
        return slice;
    }

    pub fn deinit(self: *ZlobResults) void {
        switch (self.source) {
            .zlob => |*pzlob_ptr| {
                // Zero-copy mode: use globfreeInternal() which handles allocated paths
                globfreeInternal(self.allocator, @constCast(pzlob_ptr));
            },
            .paths => |owned| {
                if (owned.owns_strings) {
                    for (owned.items) |path| {
                        self.allocator.free(path);
                    }
                }
                if (owned.items.len > 0) {
                    self.allocator.free(owned.items);
                }
            },
        }
    }
};

pub fn globfreeInternal(allocator: std.mem.Allocator, pzlob: *zlob_t) void {
    if (pzlob.zlo_pathv) |pathv| {
        // offs might be uninitialized if ZLOB_DOOFFS wasn't used - treat as 0
        const offs = pzlob.zlo_offs;

        const owns_strings = (pzlob.zlo_flags & ZLOB_FLAGS_OWNS_STRINGS) != 0;

        if (owns_strings) {
            // Owned strings share one buffer, whose base and capacity sit in
            // the two slots past the visible lengths. See ResultsList.emit.
            const base_addr = pzlob.zlo_pathlen[pzlob.zlo_pathc];
            const buf_cap = pzlob.zlo_pathlen[pzlob.zlo_pathc + 1];
            if (buf_cap > 0) {
                allocator.free(@as([*]u8, @ptrFromInt(base_addr))[0..buf_cap]);
            }
        }
        // Always free the pathv array including offset slots
        const pathv_slice = @as([*][*c]u8, @ptrCast(pathv))[0 .. offs + pzlob.zlo_pathc + 1];
        allocator.free(pathv_slice);

        // Free the pathlen array; owned results carry the two extra slots.
        const pathlen_extra: usize = if (owns_strings) 2 else 0;
        allocator.free(pzlob.zlo_pathlen[0 .. pzlob.zlo_pathc + pathlen_extra]);
    }
    pzlob.zlo_pathv = null;
    pzlob.zlo_pathc = 0;
    pzlob.zlo_flags = ZLOB_FLAGS_SHARED_STRINGS;
}
