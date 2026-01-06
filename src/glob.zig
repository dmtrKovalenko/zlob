const std = @import("std");
const c = std.c;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const suffix_match = @import("suffix_match.zig");

const pwd = @cImport({
    @cInclude("pwd.h");
});

// Internal glob result structure (C-style, used internally during refactoring)
// TODO: Remove this entirely once refactoring to pure Zig slices is complete
pub const glob_t = extern struct {
    gl_pathc: usize,
    gl_pathv: [*c][*c]u8,
    gl_offs: usize,
    gl_pathlen: [*]usize, // Array of path lengths (parallel to gl_pathv, for efficient FFI)
    gl_flags: c_int, // Internal flags (not exposed in C header)
};

pub const ZLOB_FLAGS_SHARED_STRINGS: c_int = 0;
pub const ZLOB_FLAGS_OWNS_STRINGS: c_int = 1 << 0;

fn globLiteralPath(allocator: Allocator, path: []const u8, flags: c_int, pglob: *glob_t) !bool {
    const cwd = std.fs.cwd();
    const stat = cwd.statFile(path) catch {
        return false;
    };

    const is_dir = stat.kind == .directory;
    if ((flags & GLOB_ONLYDIR) != 0 and !is_dir) {
        return false;
    }

    var return_path = path;
    if (mem.startsWith(u8, path, "./")) {
        return_path = path[2..];
    }

    const needs_slash = (flags & GLOB_MARK) != 0 and is_dir;
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

    pglob.gl_pathc = 1;
    pglob.gl_pathv = result;
    pglob.gl_pathlen = pathlen_buf.ptr;
    pglob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;

    return true;
}

// Standard POSIX glob flags (matching glibc values exactly)
pub const GLOB_ERR = 1 << 0; // 0x0001 - Return on read errors
pub const GLOB_MARK = 1 << 1; // 0x0002 - Append a slash to each name
pub const GLOB_NOSORT = 1 << 2; // 0x0004 - Don't sort the names
pub const GLOB_DOOFFS = 1 << 3; // 0x0008 - Insert PGLOB->gl_offs NULLs
pub const GLOB_NOCHECK = 1 << 4; // 0x0010 - If nothing matches, return the pattern
pub const GLOB_APPEND = 1 << 5; // 0x0020 - Append to results of a previous call
pub const GLOB_NOESCAPE = 1 << 6; // 0x0040 - Backslashes don't quote metacharacters
pub const GLOB_PERIOD = 1 << 7; // 0x0080 - Leading `.` can be matched by metachars

// GNU extensions
pub const GLOB_MAGCHAR = 1 << 8; // 0x0100 - Set in gl_flags if any metachars seen
pub const GLOB_ALTDIRFUNC = 1 << 9; // 0x0200 - Use gl_opendir et al functions
pub const GLOB_BRACE = 1 << 10; // 0x0400 - Expand "{a,b}" to "a" "b"
pub const GLOB_NOMAGIC = 1 << 11; // 0x0800 - If no magic chars, return the pattern
pub const GLOB_TILDE = 1 << 12; // 0x1000 - Expand ~user and ~ to home directories
pub const GLOB_ONLYDIR = 1 << 13; // 0x2000 - Match only directories
pub const GLOB_TILDE_CHECK = 1 << 14; // 0x4000 - Like GLOB_TILDE but return error if user name not available

// Error codes (C-style codes for compatibility)
pub const GLOB_NOSPACE = 1;
pub const GLOB_ABORTED = 2;
pub const GLOB_NOMATCH = 3;

pub const glob_errfunc_t = ?*const fn (epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int;

// Re-export path_matcher for c_lib to use
pub fn internalMatchPaths(allocator: std.mem.Allocator, pattern: []const u8, paths: []const []const u8, flags: u32) !GlobResults {
    const path_matcher = @import("path_matcher.zig");
    return path_matcher.matchPaths(allocator, pattern, paths, flags);
}

// Use Zig's cross-platform dirent structure
pub const dirent = std.c.dirent;

pub const DT_UNKNOWN = std.c.DT.UNKNOWN;
pub const DT_DIR = std.c.DT.DIR;

pub const ResultsList = std.array_list.AlignedManaged([*c]u8, null);

// Pattern analysis structure for optimization
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
    directories_only: bool, // Only match directories (from GLOB_ONLYDIR flag)
};

// Fast to analyze pattern context created for every independent global pattern block
// when the appropriate directory is already visited
pub const PatternContext = struct {
    pattern: []const u8,
    has_wildcards: bool, // Pattern contains wildcards
    starts_with_dot: bool, // Pattern starts with '.'
    is_dot_or_dotdot: bool, // Pattern is exactly "." or ".."

    // prebuilt patterns for varios suffix matching optimizations
    simd_batched_suffix_match: ?suffix_match.SimdBatchedSuffixMatch,
    only_suffix_match: ?suffix_match.SuffixMatch,

    pub fn init(pattern: []const u8) PatternContext {
        const has_wildcards = hasWildcardsSIMD(pattern);

        const starts_with_dot = pattern.len > 0 and pattern[0] == '.';
        const is_dot_or_dotdot = mem.eql(u8, pattern, ".") or mem.eql(u8, pattern, "..");
        const simd_batched_suffix_match, const only_suffix_match = if (has_wildcards)
            suffix_match.check_simple_star_sufix(pattern)
        else
            .{ null, null };

        return PatternContext{
            .pattern = pattern,
            .has_wildcards = has_wildcards,
            .simd_batched_suffix_match = simd_batched_suffix_match,
            .only_suffix_match = only_suffix_match,
            .starts_with_dot = starts_with_dot,
            .is_dot_or_dotdot = is_dot_or_dotdot,
        };
    }
};

pub fn analyzePattern(pattern: []const u8, flags: c_int) PatternInfo {
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
        .directories_only = (flags & GLOB_ONLYDIR) != 0,
    };

    const enable_escape = (flags & GLOB_NOESCAPE) == 0;
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

        if (ch == '*' or ch == '?') {
            if (ch == '*' and i + 1 < pattern.len and pattern[i + 1] == '*') {
                info.has_recursive = true;
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
            info.has_dir_wildcards = hasWildcardsSIMD(dir_part);
        }
    }

    if (!info.has_recursive and !info.has_dir_wildcards and
        info.wildcard_suffix.len >= 2 and info.wildcard_suffix[0] == '*')
    {
        const suffix = info.wildcard_suffix[1..];
        if (!hasWildcardsSIMD(suffix) and mem.indexOf(u8, suffix, "/") == null) {
            info.simple_extension = suffix;
        }
    }

    if (!info.has_recursive) {
        var depth: usize = info.fixed_component_count;
        var remaining = info.wildcard_suffix;
        while (mem.indexOf(u8, remaining, "/")) |pos| {
            depth += 1;
            remaining = remaining[pos + 1 ..];
        }
        if (remaining.len > 0) depth += 1;
        info.max_depth = depth;
    }

    return info;
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

// SIMD string comparison for sorting
fn simdStrCmp(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);

    // SIMD comparison for long strings
    if (min_len >= 32) {
        const Vec32 = @Vector(32, u8);
        var i: usize = 0;
        while (i + 32 <= min_len) : (i += 32) {
            const a_vec: Vec32 = a[i..][0..32].*;
            const b_vec: Vec32 = b[i..][0..32].*;
            const eq = a_vec == b_vec;
            const mask = @as(u32, @bitCast(eq));

            if (mask != 0xFFFFFFFF) {
                // Found difference, find first differing byte
                const first_diff = @ctz(~mask);
                const a_byte = a[i + first_diff];
                const b_byte = b[i + first_diff];
                if (a_byte < b_byte) return .lt;
                if (a_byte > b_byte) return .gt;
            }
        }
        // Compare remainder
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


fn c_cmp_strs(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    const str_a: [*c]const u8 = @ptrCast(@alignCast(a));
    const str_b: [*c]const u8 = @ptrCast(@alignCast(b));
    const slice_a = mem.sliceTo(str_a, 0);
    const slice_b = mem.sliceTo(str_b, 0);
    return switch (simdStrCmp(slice_a, slice_b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

extern "c" fn qsort(base: ?*anyopaque, nmemb: usize, size: usize, compar: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int) void;


fn findClosingBrace(pattern: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '{') {
            depth += 1;
        } else if (pattern[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        } else if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1; // Skip escaped character
        }
    }
    return null;
}


fn expandBraces(allocator: std.mem.Allocator, pattern: []const u8, results: *ResultsList) !void {
    // Find first unescaped opening brace
    var brace_start: ?usize = null;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1; // Skip escaped character
            continue;
        }
        if (pattern[i] == '{') {
            brace_start = i;
            break;
        }
    }

    // No braces found, just copy the pattern
    if (brace_start == null) {
        const copy = try allocator.allocSentinel(u8, pattern.len, 0);
        @memcpy(copy[0..pattern.len], pattern);
        const str: [*c]u8 = @ptrCast(copy.ptr);
        try results.append(str);
        return;
    }

    const brace_open = brace_start.?;
    const brace_close = findClosingBrace(pattern, brace_open + 1) orelse {
        // No matching closing brace, treat as literal
        const copy = try allocator.allocSentinel(u8, pattern.len, 0);
        @memcpy(copy[0..pattern.len], pattern);
        const str: [*c]u8 = @ptrCast(copy.ptr);
        try results.append(str);
        return;
    };

    const prefix = pattern[0..brace_open];
    const suffix = pattern[brace_close + 1 ..];
    const brace_content = pattern[brace_open + 1 .. brace_close];

    // Split brace content by commas
    var start: usize = 0;
    var alternatives = ResultsList.init(allocator);
    defer alternatives.deinit();

    i = 0;
    while (i <= brace_content.len) : (i += 1) {
        if (i == brace_content.len or brace_content[i] == ',') {
            const alt = brace_content[start..i];

            const new_len = prefix.len + alt.len + suffix.len;
            const new_str_buf = try allocator.allocSentinel(u8, new_len, 0);
            const new_str: [*c]u8 = @ptrCast(new_str_buf.ptr);

            if (prefix.len > 0) @memcpy(new_str_buf[0..prefix.len], prefix);
            if (alt.len > 0) @memcpy(new_str_buf[prefix.len..][0..alt.len], alt);
            if (suffix.len > 0) @memcpy(new_str_buf[prefix.len + alt.len ..][0..suffix.len], suffix);

            try alternatives.append(new_str);
            start = i + 1;
        }
    }

    // Recursively expand each alternative
    for (alternatives.items) |alt_pattern| {
        const alt_slice = mem.sliceTo(alt_pattern, 0);
        try expandBraces(allocator, alt_slice, results);
        allocator.free(alt_slice);
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


fn globWithWildcardDirs(allocator: std.mem.Allocator, pattern: []const u8, flags: c_int, pglob: *glob_t, directories_only: bool) !?void {
    var components: [64][]const u8 = undefined;
    var component_count: usize = 0;

    var start: usize = 0;
    for (pattern, 0..) |ch, idx| {
        if (ch == '/') {
            if (idx > start) {
                components[component_count] = pattern[start..idx];
                component_count += 1;
            }
            start = idx + 1;
        }
    }
    if (start < pattern.len) {
        components[component_count] = pattern[start..];
        component_count += 1;
    }

    var result_paths = ResultsList.init(allocator);
    defer result_paths.deinit();
    errdefer {
        for (result_paths.items) |path| {
            const path_slice = mem.sliceTo(path, 0);
            allocator.free(path_slice);
        }
    }

    try expandWildcardComponents(allocator, ".", components[0..component_count], 0, &result_paths, directories_only);

    
    if (result_paths.items.len == 0) {
        if (flags & GLOB_NOCHECK != 0) {
            const pat_copy = allocator.allocSentinel(u8, pattern.len, 0) catch return error.OutOfMemory;
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = allocator.alloc([*c]u8, 2) catch return error.OutOfMemory;
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            const pathlen_buf = allocator.alloc(usize, 1) catch return error.OutOfMemory;
            pathlen_buf[0] = pattern.len;

            pglob.gl_pathc = 1;
            pglob.gl_pathv = result;
            pglob.gl_pathlen = pathlen_buf.ptr;
            pglob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
            return;
        }
        return null;
    }

    
    if (flags & GLOB_NOSORT == 0) {
        qsort(@ptrCast(result_paths.items.ptr), result_paths.items.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    
    const pathv_buf = allocator.alloc([*c]u8, result_paths.items.len + 1) catch return error.OutOfMemory;
    const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

    const pathlen_buf = allocator.alloc(usize, result_paths.items.len) catch return error.OutOfMemory;

    var i: usize = 0;
    while (i < result_paths.items.len) : (i += 1) {
        result[i] = result_paths.items[i];
        pathlen_buf[i] = mem.len(result_paths.items[i]);
    }
    result[result_paths.items.len] = null;

    pglob.gl_pathc = result_paths.items.len;
    pglob.gl_pathv = result;
    pglob.gl_pathlen = pathlen_buf.ptr;
    pglob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
}

// Optimized version that uses pattern info to start from literal prefix
fn globWithWildcardDirsOptimized(allocator: std.mem.Allocator, pattern: []const u8, info: *const PatternInfo, flags: c_int, errfunc: glob_errfunc_t, pglob: *glob_t, directories_only: bool) !?void {
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

    var result_paths = ResultsList.init(allocator);
    defer result_paths.deinit();
    errdefer {
        for (result_paths.items) |path| {
            const path_slice = mem.sliceTo(path, 0);
            allocator.free(path_slice);
        }
    }

    const estimated_capacity: usize = if (info.has_recursive)
        1024 // Recursive patterns can match many files
    else if (info.has_dir_wildcards)
        256 // Directory wildcards match moderate number
    else
        64; // Simple wildcards match fewer files
    result_paths.ensureTotalCapacity(estimated_capacity) catch {}; // Best effort

    const start_dir = if (info.literal_prefix.len > 0)
        info.literal_prefix
    else
        ".";

    try expandWildcardComponents(allocator, start_dir, components[0..component_count], 0, &result_paths, directories_only, flags, errfunc);

    
    if (result_paths.items.len == 0) {
        if (flags & GLOB_NOCHECK != 0) {
            const pat_copy = allocator.allocSentinel(u8, pattern.len, 0) catch return error.OutOfMemory;
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = allocator.alloc([*c]u8, 2) catch return error.OutOfMemory;
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            const pathlen_buf = allocator.alloc(usize, 1) catch return error.OutOfMemory;
            pathlen_buf[0] = pattern.len;

            pglob.gl_pathc = 1;
            pglob.gl_pathv = result;
            pglob.gl_pathlen = pathlen_buf.ptr;
            pglob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
            return;
        }
        return null;
    }

    
    if (flags & GLOB_NOSORT == 0) {
        qsort(@ptrCast(result_paths.items.ptr), result_paths.items.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    
    const pathv_buf = allocator.alloc([*c]u8, result_paths.items.len + 1) catch return error.OutOfMemory;
    const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

    const pathlen_buf = allocator.alloc(usize, result_paths.items.len) catch return error.OutOfMemory;

    var i: usize = 0;
    while (i < result_paths.items.len) : (i += 1) {
        result[i] = result_paths.items[i];
        pathlen_buf[i] = mem.len(result_paths.items[i]);
    }
    result[result_paths.items.len] = null;

    pglob.gl_pathc = result_paths.items.len;
    pglob.gl_pathv = result;
    pglob.gl_pathlen = pathlen_buf.ptr;
    pglob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
}

// Recursive helper to expand wildcard components level by level
fn expandWildcardComponents(
    allocator: std.mem.Allocator,
    current_dir: []const u8,
    components: []const []const u8,
    component_idx: usize,
    results: *ResultsList,
    directories_only: bool,
    flags: c_int,
    errfunc: glob_errfunc_t,
) !void {
    if (component_idx > 65536) {
        @branchHint(.unlikely);
        return error.Aborted;
    }

    if (component_idx >= components.len) {
        const path_copy = try allocator.allocSentinel(u8, current_dir.len, 0);
        @memcpy(path_copy[0..current_dir.len], current_dir);
        const path: [*c]u8 = @ptrCast(path_copy.ptr);
        try results.append(path);
        return;
    }

    const component = components[component_idx];
    const is_final = component_idx == components.len - 1;

    const component_ctx = PatternContext.init(component);

    if (component_ctx.has_wildcards) {
        // Wildcard component - match against directory entries
        var dirname_z: [4096:0]u8 = undefined;
        if (current_dir.len >= 4096) return error.OutOfMemory;
        @memcpy(dirname_z[0..current_dir.len], current_dir);
        dirname_z[current_dir.len] = 0;

        const dir = c.opendir(&dirname_z) orelse {
            // Directory open error - call errfunc if provided
            if (errfunc) |efunc| {
                const eerrno = @as(c_int, @intFromEnum(std.posix.errno(-1)));
                if (efunc(&dirname_z, eerrno) != 0) {
                    return error.Aborted;
                }
            }
            // If GLOB_ERR is set, abort on error
            if ((flags & GLOB_ERR) != 0) {
                return error.Aborted;
            }
            // Otherwise, silently skip this directory
            return;
        };
        defer _ = c.closedir(dir);

        while (c.readdir(dir)) |entry_raw| {
            const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
            const name = mem.sliceTo(&entry.name, 0);

            // For non-final components, only traverse directories
            if (!is_final and entry.type != DT_DIR) continue;
            if (shouldSkipFile(name, &component_ctx, 0)) continue;

            const matches = if (is_final and component_ctx.simd_batched_suffix_match != null)
                component_ctx.simd_batched_suffix_match.?.matchSuffix(name)
            else
                fnmatchWithContext(&component_ctx, name);

            if (matches) {
                // For final component with directories_only flag, only keep directories
                if (is_final and directories_only and entry.type != DT_DIR) continue;

                var new_path_buf: [4096]u8 = undefined;
                const new_path = buildPathInBuffer(&new_path_buf, current_dir, name);

                if (new_path.len >= 4096) continue;

                // Recurse with next component
                try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only, flags, errfunc);
            }
        }
    } else {
        // Literal component - just check if it exists
        var new_path_buf: [4096]u8 = undefined;
        const new_path = buildPathInBuffer(&new_path_buf, current_dir, component);

        if (new_path.len >= 4096) return;

        var path_z: [4096:0]u8 = undefined;
        @memcpy(path_z[0..new_path.len], new_path);
        path_z[new_path.len] = 0;

        var stat_buf: std.c.Stat = undefined;
        if (std.c.stat(&path_z, &stat_buf) == 0) {
            // For non-final components, must be a directory
            if (!is_final and !std.c.S.ISDIR(stat_buf.mode)) return;

            // For final component with directories_only, must be directory
            if (is_final and directories_only and !std.c.S.ISDIR(stat_buf.mode)) return;

            // Path exists and is valid, recurse
            try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only, flags, errfunc);
        }
    }
}

fn globSingle(allocator: std.mem.Allocator, pattern: []const u8, flags: c_int, errfunc: glob_errfunc_t, pglob: *glob_t) !?void {
    var effective_pattern = pattern;
    var effective_flags = flags;

    if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
        effective_flags |= GLOB_ONLYDIR;
        effective_pattern = pattern[0 .. pattern.len - 1];

        if (effective_pattern.len == 0) {
            effective_pattern = ".";
        }
    }

    // FAST PATH: Literal pattern optimization (no wildcards)
    // This is the most common case and libc glob optimizes it to a single stat() call
    // NOTE: Skip if pattern starts with tilde (needs tilde expansion first)
    const needs_tilde_expansion = effective_pattern.len > 0 and effective_pattern[0] == '~';
    if (!hasWildcardsSIMD(effective_pattern) and !needs_tilde_expansion) {
        // Try to match literal path
        const found = try globLiteralPath(allocator, effective_pattern, effective_flags, pglob);
        if (found) return;

        if (flags & GLOB_NOCHECK != 0) {
            const path_copy = try allocator.allocSentinel(u8, effective_pattern.len, 0);
            @memcpy(path_copy[0..effective_pattern.len], effective_pattern);
            const path: [*c]u8 = @ptrCast(path_copy.ptr);

            const pathv_buf = try allocator.alloc([*c]u8, 2);
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            const pathlen_buf = try allocator.alloc(usize, 1);
            pathlen_buf[0] = effective_pattern.len;

            pglob.gl_pathc = 1;
            pglob.gl_pathv = result;
            pglob.gl_pathlen = pathlen_buf.ptr;
            pglob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
            return;
        }

        return null;
    }

    const info = analyzePattern(effective_pattern, effective_flags);

    // Fast path: simple pattern with literal prefix (e.g., "src/foo/*.txt")
    if (info.simple_extension != null and info.literal_prefix.len > 0) {
        return globInDirFiltered(allocator, info.wildcard_suffix, info.literal_prefix, effective_flags, errfunc, pglob, info.directories_only);
    }

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

        return globRecursive(allocator, pattern_from_doublestar, dirname, effective_flags, errfunc, pglob, info.directories_only);
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
        for (effective_pattern[0..last_slash_pos]) |ch| {
            if (ch == '*' or ch == '?' or ch == '[') {
                has_wildcard_in_dir = true;
                break;
            }
        }
    }

    // But skip if pattern has ** (needs special recursive handling)
    if (has_wildcard_in_dir and !info.has_recursive) {
        return globWithWildcardDirsOptimized(allocator, effective_pattern, &info, effective_flags, errfunc, pglob, info.directories_only);
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

    if (mem.indexOf(u8, filename_pattern, "**")) |_| {
        return globRecursive(allocator, filename_pattern, dirname, effective_flags, errfunc, pglob, info.directories_only);
    }

    return globInDirFiltered(allocator, filename_pattern, dirname, effective_flags, errfunc, pglob, info.directories_only);
}

// Helper to expand tilde (~) in patterns

//   - The expanded pattern (allocated if expanded, original if no tilde)
//   - null if GLOB_TILDE_CHECK is set and expansion fails (indicates no match)
fn expandTilde(allocator: std.mem.Allocator, pattern: [:0]const u8, flags: c_int) !?[:0]const u8 {
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
            if (flags & GLOB_TILDE_CHECK != 0) {
                return null; // Indicate no match
            }
            break :blk null;
        }
        @memcpy(username_z[0..username.len], username);
        username_z[username.len] = 0;

        const pw_entry = pwd.getpwnam(&username_z);
        if (pw_entry == null) {
            if (flags & GLOB_TILDE_CHECK != 0) {
                return null; // Indicate no match
            }
            break :blk null;
        }

        const home_cstr = pw_entry.*.pw_dir;
        if (home_cstr == null) {
            if (flags & GLOB_TILDE_CHECK != 0) {
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
pub fn glob(allocator: std.mem.Allocator, pattern: [*:0]const u8, flags: c_int, errfunc: glob_errfunc_t, pglob: *glob_t) !?void {
    if (flags & GLOB_APPEND == 0) {
        pglob.gl_pathc = 0;
        pglob.gl_pathv = null;
        if (flags & GLOB_DOOFFS == 0) {
            pglob.gl_offs = 0;
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

    if (flags & GLOB_TILDE != 0) {
        expanded_pattern = try expandTilde(allocator, pattern_slice, flags);
        if (expanded_pattern == null) {
            // GLOB_TILDE_CHECK is set and tilde expansion failed - no match
            return null;
        }
        pattern_slice = expanded_pattern.?;
    }

    if (flags & GLOB_BRACE != 0) {
        var expanded = ResultsList.init(allocator);
        defer {
            for (expanded.items) |item| {
                const item_mem = mem.sliceTo(item, 0);
                allocator.free(item_mem);
            }
            expanded.deinit();
        }

        try expandBraces(allocator, pattern_slice, &expanded);

        // Glob each expanded pattern
        var first = true;
        for (expanded.items) |exp_pattern| {
            const exp_slice = mem.sliceTo(exp_pattern, 0);
            _ = try globSingle(allocator, exp_slice, if (first) flags else flags | GLOB_APPEND, errfunc, pglob);
            first = false;
        }

        if (pglob.gl_pathc == 0) {
            return null;
        }
        return;
    }

    return try globSingle(allocator, pattern_slice, flags, errfunc, pglob);
}

// Pattern components for recursive glob
const RecursivePattern = struct {
    dir_components: []const []const u8, // Directory components to match (e.g., [".glob_test_nested"])
    file_pattern: []const u8, // Final filename pattern (e.g., "*.txt")
};

// Recursive glob implementation for ** patterns
fn globRecursive(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: c_int, errfunc: glob_errfunc_t, pglob: *glob_t, directories_only: bool) !?void {
    const info = analyzePattern(pattern, flags);

    // Split pattern at **
    const double_star_pos = mem.indexOf(u8, pattern, "**") orelse return globInDirFiltered(allocator, pattern, dirname, flags, errfunc, pglob, directories_only);

    var after_double_star = pattern[double_star_pos + 2 ..];

    if (after_double_star.len > 0 and after_double_star[0] == '/') {
        after_double_star = after_double_star[1..];
    }

    // If ** is at the end, match everything recursively
    if (after_double_star.len == 0) {
        after_double_star = "*";
    }

    const start_dir = if (info.literal_prefix.len > 0)
        info.literal_prefix
    else
        dirname;

    // For pattern like ".glob_test_nested/*.txt", we get:
    //   dir_components = [".glob_test_nested"]
    //   file_pattern = "*.txt"
    var dir_components_buf: [32][]const u8 = undefined;
    var dir_component_count: usize = 0;
    var file_pattern = after_double_star;

    if (mem.lastIndexOf(u8, after_double_star, "/")) |last_slash| {
        file_pattern = after_double_star[last_slash + 1 ..];
        const dir_path = after_double_star[0..last_slash];

        var start: usize = 0;
        for (dir_path, 0..) |ch, i| {
            if (ch == '/') {
                if (i > start and dir_component_count < 32) {
                    dir_components_buf[dir_component_count] = dir_path[start..i];
                    dir_component_count += 1;
                }
                start = i + 1;
            }
        }
        if (start < dir_path.len and dir_component_count < 32) {
            dir_components_buf[dir_component_count] = dir_path[start..];
            dir_component_count += 1;
        }
    }

    const rec_pattern = RecursivePattern{
        .dir_components = dir_components_buf[0..dir_component_count],
        .file_pattern = file_pattern,
    };

    // OPTIMIZATION: Use ArrayList to accumulate ALL results, avoiding O(n²) append behavior
    // Instead of using GLOB_APPEND which reallocates pathv for every directory,
    // we collect all results in a list and convert to pathv once at the end
    var all_results = ResultsList.init(allocator);
    defer all_results.deinit();

    all_results.ensureTotalCapacity(1024) catch {}; // Best effort

    // HOTPATH OPTIMIZATION: For deep recursive patterns with no dir_components (e.g., "drivers/**/*.c"),
    // use Zig's std.fs.Dir.walk() which is faster and avoids mem.sliceTo overhead
    if (dir_component_count == 0) {
        try globRecursiveWithZigWalk(allocator, &rec_pattern, start_dir, flags, &all_results, &info, errfunc);
    } else {
        // Recursively collect all matching paths (old C-based approach for complex patterns)
        try globRecursiveHelperCollect(allocator, &rec_pattern, start_dir, flags, &all_results, 0, &info, errfunc);
    }

    if (all_results.items.len == 0) {
        return null;
    }

    
    if (flags & GLOB_NOSORT == 0) {
        qsort(@ptrCast(all_results.items.ptr), all_results.items.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    return finalizeResults(allocator, &all_results, flags, pglob);
}

// Helper to finalize results from ArrayList to glob_t
fn finalizeResults(allocator: std.mem.Allocator, results: *ResultsList, flags: c_int, pglob: *glob_t) !?void {
    const offs = if (flags & GLOB_DOOFFS != 0) pglob.gl_offs else 0;

    // Handle GLOB_APPEND - merge with existing results
    if (flags & GLOB_APPEND != 0 and pglob.gl_pathv != null and pglob.gl_pathc > 0) {
        const old_count = pglob.gl_pathc;
        const new_count = results.items.len;
        const total_count = old_count + new_count;

        const pathv_buf = allocator.alloc([*c]u8, offs + total_count + 1) catch return error.OutOfMemory;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        var k: usize = 0;
        while (k < offs) : (k += 1) result[k] = null;

        var i: usize = 0;
        while (i < old_count) : (i += 1) {
            result[offs + i] = pglob.gl_pathv[offs + i];
        }

        var j: usize = 0;
        while (j < new_count) : (j += 1) {
            result[offs + old_count + j] = results.items[j];
        }
        result[offs + total_count] = null;

        const pathlen_buf = allocator.alloc(usize, total_count) catch return error.OutOfMemory;
        var li: usize = 0;
        while (li < old_count) : (li += 1) {
            pathlen_buf[li] = pglob.gl_pathlen[li];
        }
        var lj: usize = 0;
        while (lj < new_count) : (lj += 1) {
            pathlen_buf[old_count + lj] = mem.len(results.items[lj]);
        }

        const old_pathv_slice = @as([*][*c]u8, @ptrCast(pglob.gl_pathv))[0 .. offs + old_count + 1];
        allocator.free(old_pathv_slice);
        const old_pathlen_slice = pglob.gl_pathlen[0..old_count];
        allocator.free(old_pathlen_slice);

        pglob.gl_pathc = total_count;
        pglob.gl_pathv = result;
        pglob.gl_pathlen = pathlen_buf.ptr;
        pglob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    } else {
        // Fresh allocation
        const pathv_buf = allocator.alloc([*c]u8, offs + results.items.len + 1) catch return error.OutOfMemory;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        const pathlen_buf = allocator.alloc(usize, results.items.len) catch return error.OutOfMemory;

        var k: usize = 0;
        while (k < offs) : (k += 1) result[k] = null;

        // Copy results and lengths
        var i: usize = 0;
        while (i < results.items.len) : (i += 1) {
            result[offs + i] = results.items[i];
            pathlen_buf[i] = mem.len(results.items[i]);
        }
        result[offs + results.items.len] = null;

        pglob.gl_pathc = results.items.len;
        pglob.gl_pathv = result;
        pglob.gl_pathlen = pathlen_buf.ptr;
        pglob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    }
}

// once we need to actually recurse the directory tree we suppose that we will have a lot of
// matches, so having zig's std.fs.Dir.walk() is faster becuase it does all the smart opimziations
// of the stack mangement *AND* even it does a bunch of overhead on top of C it produces string
// slices which is way faster than repeating mem.sliceTo on every file patten
inline fn globRecursiveWithZigWalk(
    allocator: std.mem.Allocator,
    rec_pattern: *const RecursivePattern,
    start_dir: []const u8,
    flags: c_int,
    results: *ResultsList,
    info: *const PatternInfo,
    errfunc: glob_errfunc_t,
) !void {
    // Pattern context for file matching
    const pattern_ctx = PatternContext.init(rec_pattern.file_pattern);

    // Open the starting directory using Zig's std.fs
    var dir = std.fs.cwd().openDir(start_dir, .{ .iterate = true }) catch |err| {
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
        // If GLOB_ERR is set, abort on error
        if ((flags & GLOB_ERR) != 0) {
            return error.Aborted;
        }
        // Otherwise, silently skip this directory
        return;
    };
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
            // GLOB_PERIOD: Check if path contains hidden components
            // If GLOB_PERIOD is NOT set, skip files whose path contains hidden directories
            if ((flags & GLOB_PERIOD) == 0) {
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

            // GLOB_PERIOD: Skip hidden files unless explicitly allowed
            // Note: shouldSkipFile handles GLOB_PERIOD logic for basename
            if (shouldSkipFile(entry.basename, &pattern_ctx, flags)) continue;

            // Fast path: use optimized suffix matching for *.ext patterns
            const matches = if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
                batched_suffix_match.matchSuffix(entry.basename)
            else
                fnmatchWithContext(&pattern_ctx, entry.basename);

            if (matches) {
                const full_path_len = start_dir.len + 1 + entry.path.len;
                const path_buf_slice = allocator.allocSentinel(u8, full_path_len, 0) catch return error.OutOfMemory;

                @memcpy(path_buf_slice[0..start_dir.len], start_dir);
                path_buf_slice[start_dir.len] = '/';

                @memcpy(path_buf_slice[start_dir.len + 1 ..][0..entry.path.len], entry.path);

                var path: [*c]u8 = @ptrCast(path_buf_slice.ptr);

                if (maybeAppendSlash(allocator, path, full_path_len, is_dir, flags) catch {
                    allocator.free(path_buf_slice);
                    return error.OutOfMemory;
                }) |new_path| {
                    path = new_path;
                }

                results.append(path) catch return error.OutOfMemory;
            }
        }
    }
}

inline fn globRecursiveHelperCollect(allocator: std.mem.Allocator, rec_pattern: *const RecursivePattern, dirname: []const u8, flags: c_int, results: *ResultsList, depth: usize, info: *const PatternInfo, errfunc: glob_errfunc_t) !void {
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
        try globInDirImplCollect(allocator, rec_pattern.file_pattern, dirname, flags, results, info.directories_only, errfunc);
        // Continue recursing even if no matches in this directory
    }

    // Open directory to find subdirectories
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
        // If GLOB_ERR is set, abort on error
        if ((flags & GLOB_ERR) != 0) {
            return error.Aborted;
        }
        // Otherwise, silently skip this directory
        return;
    };
    defer _ = c.closedir(dir);

    // Recursively search subdirectories
    while (c.readdir(dir)) |entry_raw| {
        const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
        const name = mem.sliceTo(&entry.name, 0);

        if (name.len == 0 or name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) {
            continue;
        }

        if (name[0] == '.') {
            if (flags & GLOB_PERIOD != 0) {
                // GLOB_PERIOD allows wildcards to match hidden files
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
                const component_ctx = PatternContext.init(next_component);
                if (!fnmatchWithContext(&component_ctx, name)) continue;
                next_rec_pattern.dir_components = rec_pattern.dir_components[1..];
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

            // Recurse into subdirectory
            try globRecursiveHelperCollect(allocator, &next_rec_pattern, subdir, flags, results, depth + 1, info, errfunc);
        }
    }
}

fn globInDirImplCollect(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: c_int, results: *ResultsList, directories_only: bool, errfunc: glob_errfunc_t) !void {
    const pattern_ctx = PatternContext.init(pattern);

    const use_dirname = dirname.len > 0 and !mem.eql(u8, dirname, ".");

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
        // If GLOB_ERR is set, abort on error
        if ((flags & GLOB_ERR) != 0) {
            return error.Aborted;
        }
        // Otherwise, silently skip this directory
        return;
    };
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry_raw| {
        const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
        const name = mem.sliceTo(&entry.name, 0);

        if (shouldSkipFile(name, &pattern_ctx, flags)) continue;

        // Fast path: use optimized suffix matching for *.ext patterns
        const matches = if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
            batched_suffix_match.matchSuffix(name)
        else
            fnmatchWithContext(&pattern_ctx, name);

        if (matches) {
            // Filter directories if needed
            if (directories_only) {
                const entry_dtype = entry.type;
                if (entry_dtype != DT_DIR and entry_dtype != DT_UNKNOWN) continue;
            }

            const path_buf_slice = buildFullPath(allocator, dirname, name, use_dirname) catch return error.OutOfMemory;
            var path: [*c]u8 = @ptrCast(path_buf_slice.ptr);
            const path_len = path_buf_slice.len;

            var is_dir = entry.type == DT_DIR;
            if (entry.type == DT_UNKNOWN) {
                @branchHint(.unlikely);
                var stat_buf: std.c.Stat = undefined;
                if (std.c.stat(path, &stat_buf) == 0) {
                    is_dir = std.c.S.ISDIR(stat_buf.mode);
                } else {
                    allocator.free(path_buf_slice);
                    continue;
                }
            }

            if (directories_only and !is_dir) {
                allocator.free(path_buf_slice);
                continue;
            }

            if (maybeAppendSlash(allocator, path, path_len, is_dir, flags) catch {
                @branchHint(.unlikely);
                allocator.free(path_buf_slice);
                return error.OutOfMemory;
            }) |new_path| {
                path = new_path;
            }

            results.append(path) catch return error.OutOfMemory;
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

// Helper to check if filename should be skipped (returns true to skip)
pub inline fn shouldSkipFile(name: []const u8, pattern_ctx: *const PatternContext, flags: c_int) bool {
    if (name.len == 0) return true;

    const first_byte = name[0];
    if (first_byte == '.') {
        const is_dot = name.len == 1;
        const is_dotdot = name.len == 2 and name[1] == '.';

        // Don't skip if pattern explicitly asks for "." or ".."
        if (is_dot or is_dotdot) {
            if (pattern_ctx.is_dot_or_dotdot) return false;
            return true;
        }

        // GLOB_PERIOD: allow wildcards to match hidden files
        if (flags & GLOB_PERIOD != 0) return false;

        if (!pattern_ctx.starts_with_dot) return true;
    }
    return false;
}

// Helper to check if path is a directory and append '/' if GLOB_MARK is set
pub inline fn maybeAppendSlash(allocator: std.mem.Allocator, path: [*c]u8, path_len: usize, is_dir: bool, flags: c_int) !?[*c]u8 {
    if (!is_dir or (flags & GLOB_MARK == 0)) {
        return null; // No modification needed
    }

    // Need to append '/' - reallocate with extra space
    const old_slice = @as([*]u8, @ptrCast(path))[0 .. path_len + 1]; // includes sentinel
    const new_slice = try allocator.realloc(old_slice, path_len + 2); // +1 for '/', +1 for sentinel
    new_slice[path_len] = '/';
    new_slice[path_len + 1] = 0;
    return @ptrCast(new_slice.ptr);
}

fn globInDirFiltered(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: c_int, errfunc: glob_errfunc_t, pglob: *glob_t, directories_only: bool) !?void {
    const pattern_ctx = PatternContext.init(pattern);
    const use_dirname = dirname.len > 0 and !mem.eql(u8, dirname, ".");

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
        // If GLOB_ERR is set, abort on error
        if ((flags & GLOB_ERR) != 0) {
            return error.Aborted;
        }
        // Otherwise, silently skip this directory and return no matches
        return null;
    };
    defer _ = c.closedir(dir);

    var names = ResultsList.init(allocator);
    defer names.deinit();

    while (c.readdir(dir)) |entry_raw| {
        const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
        const name = mem.sliceTo(&entry.name, 0);
        if (shouldSkipFile(name, &pattern_ctx, flags)) continue;

        // Fast path: use optimized suffix matching for *.ext patterns
        const matches = if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
            batched_suffix_match.matchSuffix(name)
        else
            fnmatchWithContext(&pattern_ctx, name);

        if (matches) {
            if (directories_only) {
                const entry_dtype = entry.type;
                if (entry_dtype != DT_DIR and entry_dtype != DT_UNKNOWN) continue;
            }

            const path_buf_slice = buildFullPath(allocator, dirname, name, use_dirname) catch return error.OutOfMemory;
            var path: [*c]u8 = @ptrCast(path_buf_slice.ptr);
            const path_len = path_buf_slice.len;

            var is_dir = entry.type == DT_DIR;
            if (entry.type == DT_UNKNOWN) {
                var stat_buf: std.c.Stat = undefined;
                if (std.c.stat(path, &stat_buf) == 0) {
                    is_dir = std.c.S.ISDIR(stat_buf.mode);
                } else {
                    allocator.free(path_buf_slice);
                    continue;
                }
            }

            if (directories_only and !is_dir) {
                allocator.free(path_buf_slice);
                continue;
            }

            if (maybeAppendSlash(allocator, path, path_len, is_dir, flags) catch {
                allocator.free(path_buf_slice);
                return error.OutOfMemory;
            }) |new_path| {
                path = new_path;
            }

            names.append(path) catch return error.OutOfMemory;
        }
    }

    
    if (names.items.len == 0) {
        if (flags & GLOB_NOCHECK != 0) {
            const pat_copy = allocator.allocSentinel(u8, pattern.len, 0) catch return error.OutOfMemory;
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = allocator.alloc([*c]u8, 2) catch return error.OutOfMemory;
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            const pathlen_buf = allocator.alloc(usize, 1) catch return error.OutOfMemory;
            pathlen_buf[0] = pattern.len;

            pglob.gl_pathc = 1;
            pglob.gl_pathv = result;
            pglob.gl_pathlen = pathlen_buf.ptr;
            pglob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
            return;
        }
        return null;
    }

    
    if (flags & GLOB_NOSORT == 0) {
        qsort(@ptrCast(names.items.ptr), names.items.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    // Handle GLOB_APPEND flag - merge with existing results
    if (flags & GLOB_APPEND != 0 and pglob.gl_pathv != null and pglob.gl_pathc > 0) {
        const old_count = pglob.gl_pathc;
        const new_count = names.items.len;
        const total_count = old_count + new_count;
        const offs = if (flags & GLOB_DOOFFS != 0) pglob.gl_offs else 0;

        const pathv_buf = allocator.alloc([*c]u8, offs + total_count + 1) catch return error.OutOfMemory;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        var k: usize = 0;
        while (k < offs) : (k += 1) {
            result[k] = null;
        }

        var i: usize = 0;
        while (i < old_count) : (i += 1) {
            result[offs + i] = pglob.gl_pathv[offs + i];
        }

        var j: usize = 0;
        while (j < new_count) : (j += 1) {
            result[offs + old_count + j] = names.items[j];
        }
        result[offs + total_count] = null;

        const pathlen_buf = allocator.alloc(usize, total_count) catch return error.OutOfMemory;
        var li: usize = 0;
        while (li < old_count) : (li += 1) {
            pathlen_buf[li] = pglob.gl_pathlen[li];
        }
        var lj: usize = 0;
        while (lj < new_count) : (lj += 1) {
            pathlen_buf[old_count + lj] = mem.len(names.items[lj]);
        }

        const old_pathv_slice = @as([*][*c]u8, @ptrCast(pglob.gl_pathv))[0 .. offs + old_count + 1];
        allocator.free(old_pathv_slice);
        const old_pathlen_slice = pglob.gl_pathlen[0..old_count];
        allocator.free(old_pathlen_slice);

        pglob.gl_pathc = total_count;
        pglob.gl_pathv = result;
        pglob.gl_pathlen = pathlen_buf.ptr;
        pglob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    } else {
        // No APPEND or first call - allocate fresh result array
        const offs = if (flags & GLOB_DOOFFS != 0) pglob.gl_offs else 0;
        const pathv_buf = allocator.alloc([*c]u8, offs + names.items.len + 1) catch return error.OutOfMemory;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        var k: usize = 0;
        while (k < offs) : (k += 1) {
            result[k] = null;
        }

        const pathlen_buf = allocator.alloc(usize, names.items.len) catch return error.OutOfMemory;

        var i: usize = 0;
        while (i < names.items.len) : (i += 1) {
            result[offs + i] = names.items[i];
            pathlen_buf[i] = mem.len(names.items[i]);
        }
        result[offs + names.items.len] = null;

        pglob.gl_pathc = names.items.len;
        pglob.gl_pathv = result;
        pglob.gl_pathlen = pathlen_buf.ptr;
        pglob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    }
}

// SIMD wildcard detection
pub fn hasWildcardsSIMD(s: []const u8) bool {
    if (s.len >= 32) {
        const Vec32 = @Vector(32, u8);
        const star_vec: Vec32 = @splat('*');
        const question_vec: Vec32 = @splat('?');
        const bracket_vec: Vec32 = @splat('[');

        var i: usize = 0;
        while (i + 32 <= s.len) : (i += 32) {
            const chunk: Vec32 = s[i..][0..32].*;
            const has_star = chunk == star_vec;
            const has_question = chunk == question_vec;
            const has_bracket = chunk == bracket_vec;
            const combined = has_star | has_question | has_bracket;
            const mask = @as(u32, @bitCast(combined));
            if (mask != 0) return true;
        }
        for (s[i..]) |ch| {
            if (ch == '*' or ch == '?' or ch == '[') return true;
        }
        return false;
    }
    for (s) |ch| {
        if (ch == '*' or ch == '?' or ch == '[') return true;
    }
    return false;
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

fn fnmatchFull(pattern: []const u8, string: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;

    while (pi < pattern.len) {
        const p = pattern[pi];

        switch (p) {
            '*' => {
                pi += 1;
                while (pi < pattern.len and pattern[pi] == '*') pi += 1;
                if (pi >= pattern.len) return true;

                // If next pattern char is a literal, use SIMD to find it
                const next = pattern[pi];
                if (next != '*' and next != '?' and next != '[') {
                    // SIMD search for next literal character
                    var search_start = si;
                    while (search_start <= string.len) {
                        if (simdFindChar(string[search_start..], next)) |offset| {
                            const pos = search_start + offset;
                            if (fnmatchFull(pattern[pi..], string[pos..])) {
                                return true;
                            }
                            search_start = pos + 1;
                        } else {
                            return false;
                        }
                    }
                    return false;
                } else {
                    // Fallback for wildcards/brackets
                    while (si <= string.len) : (si += 1) {
                        if (fnmatchFull(pattern[pi..], string[si..])) {
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
                if (pi < pattern.len and pattern[pi] == '!') {
                    negate = true;
                    pi += 1;
                }

                // Remember start position - first char after '[' can be ']' as literal
                const bracket_start = pi;

                var matched = false;
                while (pi < pattern.len) {
                    const set_c = pattern[pi];

                    // First character is always part of set (even if it's ']')
                    // Only subsequent ']' closes the bracket expression
                    if (set_c == ']' and pi > bracket_start) break;

                    pi += 1;

                    if (pi + 1 < pattern.len and pattern[pi] == '-' and pattern[pi + 1] != ']') {
                        pi += 1;
                        const range_end = pattern[pi];
                        pi += 1;
                        if (ch >= set_c and ch <= range_end) {
                            matched = true;
                        }
                    } else {
                        if (ch == set_c) matched = true;
                    }
                }

                if (pi < pattern.len and pattern[pi] == ']') pi += 1;

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

/// Internal globfree function - frees glob_t structure
/// Used by GlobResults.deinit() and C API (c_lib.zig)
/// Exposed as public for C API compatibility
pub fn globfreeInternal(allocator: std.mem.Allocator, pglob: *glob_t) void {
    if (pglob.gl_pathv) |pathv| {
        // gl_offs might be uninitialized if GLOB_DOOFFS wasn't used - treat as 0
        const offs = pglob.gl_offs;

        const owns_strings = (pglob.gl_flags & ZLOB_FLAGS_OWNS_STRINGS) != 0;

        if (owns_strings) {
            var i: usize = 0;
            while (i < pglob.gl_pathc) : (i += 1) {
                if (pathv[offs + i]) |path| {
                    const path_len = pglob.gl_pathlen[i];
                    const path_slice = @as([*]u8, @ptrCast(path))[0 .. path_len + 1];
                    allocator.free(path_slice);
                }
            }
        }
        // Always free the pathv array including offset slots
        const pathv_slice = @as([*][*c]u8, @ptrCast(pathv))[0 .. offs + pglob.gl_pathc + 1];
        allocator.free(pathv_slice);

        // Always free the pathlen array
        const pathlen_slice = pglob.gl_pathlen[0..pglob.gl_pathc];
        allocator.free(pathlen_slice);
    }
    pglob.gl_pathv = null;
    pglob.gl_pathc = 0;
    pglob.gl_flags = ZLOB_FLAGS_SHARED_STRINGS;
}

pub const GlobError = error{
    OutOfMemory,
    Aborted,
};

/// Result of a glob operation containing matched paths
pub const GlobResults = struct {
    paths: [][]const u8,
    match_count: usize,
    allocator: Allocator,
    // Store full glob_t for zero-copy glob results (null if paths are Zig-allocated)
    // This allows proper cleanup via globfreeInternal() which handles arena allocator
    pglob: ?glob_t = null,
    // Whether we own the path strings (true for glob(), false for matchPaths())
    owns_paths: bool = true,

    pub fn deinit(self: *GlobResults) void {
        if (self.pglob) |*pglob_ptr| {
            // Zero-copy mode: use globfreeInternal() which handles allocated paths
            globfreeInternal(self.allocator, pglob_ptr);
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

    /// Extract the internal glob_t for C API use (transfers ownership)
    /// After calling this, deinit() will not free the glob_t data
    pub fn extractGlobT(self: *GlobResults) ?glob_t {
        const result = self.pglob;
        self.pglob = null; // Mark as extracted, so deinit won't free it
        return result;
    }
};
