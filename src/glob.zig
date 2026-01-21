const std = @import("std");
const c = std.c;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const suffix_match = @import("suffix_match.zig");
const brace_optimizer = @import("brace_optimizer.zig");
const pattern_context_mod = @import("pattern_context.zig");

pub const PatternContext = pattern_context_mod.PatternContext;
pub const hasWildcardsSIMD = pattern_context_mod.hasWildcardsSIMD;
pub const gitignore = @import("gitignore.zig");
pub const GitIgnore = gitignore.GitIgnore;

const pwd = @cImport({
    @cInclude("pwd.h");
});

// Internal glob result structure (C-style, used internally during refactoring)
// TODO: Remove this entirely once refactoring to pure Zig slices is complete
pub const zlob_t = extern struct {
    gl_pathc: usize,
    gl_pathv: [*c][*c]u8,
    gl_offs: usize,
    gl_pathlen: [*]usize, // Array of path lengths (parallel to gl_pathv, for efficient FFI)
    gl_flags: c_int, // Internal flags (not exposed in C header)
};

pub const ZLOB_FLAGS_SHARED_STRINGS: c_int = 0;
pub const ZLOB_FLAGS_OWNS_STRINGS: c_int = 1 << 0;

fn globLiteralPath(allocator: Allocator, path: []const u8, flags: c_int, pzlob: *zlob_t) !bool {
    const cwd = std.fs.cwd();
    const stat = cwd.statFile(path) catch {
        return false;
    };

    const is_dir = stat.kind == .directory;
    if ((flags & ZLOB_ONLYDIR) != 0 and !is_dir) {
        return false;
    }

    var return_path = path;
    if (mem.startsWith(u8, path, "./")) {
        return_path = path[2..];
    }

    const needs_slash = (flags & ZLOB_MARK) != 0 and is_dir;
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

    pzlob.gl_pathc = 1;
    pzlob.gl_pathv = result;
    pzlob.gl_pathlen = pathlen_buf.ptr;
    pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;

    return true;
}

// Standard POSIX glob flags (matching glibc values exactly)
pub const ZLOB_ERR = 1 << 0; // 0x0001 - Return on read errors
pub const ZLOB_MARK = 1 << 1; // 0x0002 - Append a slash to each name
pub const ZLOB_NOSORT = 1 << 2; // 0x0004 - Don't sort the names
pub const ZLOB_DOOFFS = 1 << 3; // 0x0008 - Insert PZLOB->gl_offs NULLs
pub const ZLOB_NOCHECK = 1 << 4; // 0x0010 - If nothing matches, return the pattern
pub const ZLOB_APPEND = 1 << 5; // 0x0020 - Append to results of a previous call
pub const ZLOB_NOESCAPE = 1 << 6; // 0x0040 - Backslashes don't quote metacharacters
pub const ZLOB_PERIOD = 1 << 7; // 0x0080 - Leading `.` can be matched by metachars

// GNU extensions
pub const ZLOB_MAGCHAR = 1 << 8; // 0x0100 - Set in gl_flags if any metachars seen
pub const ZLOB_ALTDIRFUNC = 1 << 9; // 0x0200 - Use gl_opendir et al functions
pub const ZLOB_BRACE = 1 << 10; // 0x0400 - Expand "{a,b}" to "a" "b"
pub const ZLOB_NOMAGIC = 1 << 11; // 0x0800 - If no magic chars, return the pattern
pub const ZLOB_TILDE = 1 << 12; // 0x1000 - Expand ~user and ~ to home directories
pub const ZLOB_ONLYDIR = 1 << 13; // 0x2000 - Match only directories
pub const ZLOB_TILDE_CHECK = 1 << 14; // 0x4000 - Like ZLOB_TILDE but return error if user name not available

// zlob extensions
pub const ZLOB_GITIGNORE = 1 << 15; // 0x8000 - Filter results using .gitignore from cwd

// Error codes (C-style codes for compatibility)
pub const ZLOB_NOSPACE = 1;
pub const ZLOB_ABORTED = 2;
pub const ZLOB_NOMATCH = 3;

pub const zlob_errfunc_t = ?*const fn (epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int;

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
    directories_only: bool, // Only match directories (from ZLOB_ONLYDIR flag)
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
        .directories_only = (flags & ZLOB_ONLYDIR) != 0,
    };

    const enable_escape = (flags & ZLOB_NOESCAPE) == 0;
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
    // qsort passes pointers to elements, so we need to dereference to get the actual string pointers
    const ptr_a: *const [*c]const u8 = @ptrCast(@alignCast(a));
    const ptr_b: *const [*c]const u8 = @ptrCast(@alignCast(b));
    const str_a = ptr_a.*;
    const str_b = ptr_b.*;
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

fn globWithWildcardDirs(allocator: std.mem.Allocator, pattern: []const u8, flags: c_int, pzlob: *zlob_t, directories_only: bool) !?void {
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
        if (flags & ZLOB_NOCHECK != 0) {
            const pat_copy = allocator.allocSentinel(u8, pattern.len, 0) catch return error.OutOfMemory;
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = allocator.alloc([*c]u8, 2) catch return error.OutOfMemory;
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            const pathlen_buf = allocator.alloc(usize, 1) catch return error.OutOfMemory;
            pathlen_buf[0] = pattern.len;

            pzlob.gl_pathc = 1;
            pzlob.gl_pathv = result;
            pzlob.gl_pathlen = pathlen_buf.ptr;
            pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
            return;
        }
        return null;
    }

    if (flags & ZLOB_NOSORT == 0) {
        qsort(@ptrCast(result_paths.items.ptr), result_paths.items.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    // Handle ZLOB_APPEND flag - merge with existing results
    if (flags & ZLOB_APPEND != 0 and pzlob.gl_pathv != null and pzlob.gl_pathc > 0) {
        const old_count = pzlob.gl_pathc;
        const new_count = result_paths.items.len;
        const total_count = old_count + new_count;

        const pathv_buf = allocator.alloc([*c]u8, total_count + 1) catch return error.OutOfMemory;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        // Copy old results
        var i: usize = 0;
        while (i < old_count) : (i += 1) {
            result[i] = pzlob.gl_pathv[i];
        }

        // Append new results
        var j: usize = 0;
        while (j < new_count) : (j += 1) {
            result[old_count + j] = result_paths.items[j];
        }
        result[total_count] = null;

        const pathlen_buf = allocator.alloc(usize, total_count) catch return error.OutOfMemory;
        var li: usize = 0;
        while (li < old_count) : (li += 1) {
            pathlen_buf[li] = pzlob.gl_pathlen[li];
        }
        var lj: usize = 0;
        while (lj < new_count) : (lj += 1) {
            pathlen_buf[old_count + lj] = mem.len(result_paths.items[lj]);
        }

        const old_pathv_slice = @as([*][*c]u8, @ptrCast(pzlob.gl_pathv))[0 .. old_count + 1];
        allocator.free(old_pathv_slice);
        const old_pathlen_slice = pzlob.gl_pathlen[0..old_count];
        allocator.free(old_pathlen_slice);

        pzlob.gl_pathc = total_count;
        pzlob.gl_pathv = result;
        pzlob.gl_pathlen = pathlen_buf.ptr;
        pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    } else {
        // No APPEND or first call
        const pathv_buf = allocator.alloc([*c]u8, result_paths.items.len + 1) catch return error.OutOfMemory;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        const pathlen_buf = allocator.alloc(usize, result_paths.items.len) catch return error.OutOfMemory;

        var i: usize = 0;
        while (i < result_paths.items.len) : (i += 1) {
            result[i] = result_paths.items[i];
            pathlen_buf[i] = mem.len(result_paths.items[i]);
        }
        result[result_paths.items.len] = null;

        pzlob.gl_pathc = result_paths.items.len;
        pzlob.gl_pathv = result;
        pzlob.gl_pathlen = pathlen_buf.ptr;
        pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    }
}

// Optimized version that uses pattern info to start from literal prefix
fn globWithWildcardDirsOptimized(allocator: std.mem.Allocator, pattern: []const u8, info: *const PatternInfo, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t, directories_only: bool, gitignore_filter: ?*GitIgnore) !?void {
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
        if (flags & ZLOB_NOCHECK != 0) {
            const pat_copy = allocator.allocSentinel(u8, pattern.len, 0) catch return error.OutOfMemory;
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = allocator.alloc([*c]u8, 2) catch return error.OutOfMemory;
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            const pathlen_buf = allocator.alloc(usize, 1) catch return error.OutOfMemory;
            pathlen_buf[0] = pattern.len;

            pzlob.gl_pathc = 1;
            pzlob.gl_pathv = result;
            pzlob.gl_pathlen = pathlen_buf.ptr;
            pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
            return;
        }
        return null;
    }

    if (flags & ZLOB_NOSORT == 0) {
        qsort(@ptrCast(result_paths.items.ptr), result_paths.items.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    // Handle ZLOB_APPEND flag - merge with existing results
    if (flags & ZLOB_APPEND != 0 and pzlob.gl_pathv != null and pzlob.gl_pathc > 0) {
        const old_count = pzlob.gl_pathc;
        const new_count = result_paths.items.len;
        const total_count = old_count + new_count;

        const pathv_buf = allocator.alloc([*c]u8, total_count + 1) catch return error.OutOfMemory;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        // Copy old results
        var i: usize = 0;
        while (i < old_count) : (i += 1) {
            result[i] = pzlob.gl_pathv[i];
        }

        // Append new results
        var j: usize = 0;
        while (j < new_count) : (j += 1) {
            result[old_count + j] = result_paths.items[j];
        }
        result[total_count] = null;

        const pathlen_buf = allocator.alloc(usize, total_count) catch return error.OutOfMemory;
        var li: usize = 0;
        while (li < old_count) : (li += 1) {
            pathlen_buf[li] = pzlob.gl_pathlen[li];
        }
        var lj: usize = 0;
        while (lj < new_count) : (lj += 1) {
            pathlen_buf[old_count + lj] = mem.len(result_paths.items[lj]);
        }

        const old_pathv_slice = @as([*][*c]u8, @ptrCast(pzlob.gl_pathv))[0 .. old_count + 1];
        allocator.free(old_pathv_slice);
        const old_pathlen_slice = pzlob.gl_pathlen[0..old_count];
        allocator.free(old_pathlen_slice);

        pzlob.gl_pathc = total_count;
        pzlob.gl_pathv = result;
        pzlob.gl_pathlen = pathlen_buf.ptr;
        pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    } else {
        // No APPEND or first call
        const pathv_buf = allocator.alloc([*c]u8, result_paths.items.len + 1) catch return error.OutOfMemory;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        const pathlen_buf = allocator.alloc(usize, result_paths.items.len) catch return error.OutOfMemory;

        var i: usize = 0;
        while (i < result_paths.items.len) : (i += 1) {
            result[i] = result_paths.items[i];
            pathlen_buf[i] = mem.len(result_paths.items[i]);
        }
        result[result_paths.items.len] = null;

        pzlob.gl_pathc = result_paths.items.len;
        pzlob.gl_pathv = result;
        pzlob.gl_pathlen = pathlen_buf.ptr;
        pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    }
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
    errfunc: zlob_errfunc_t,
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
            // If ZLOB_ERR is set, abort on error
            if ((flags & ZLOB_ERR) != 0) {
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

fn globSingle(allocator: std.mem.Allocator, pattern: []const u8, brace_parsed: ?*const brace_optimizer.BracedPattern, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t, gitignore_filter: ?*GitIgnore) !?void {
    var effective_pattern = pattern;
    var effective_flags = flags;

    if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
        effective_flags |= ZLOB_ONLYDIR;
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
        // Check gitignore for literal path
        if (gitignore_filter) |gi| {
            const cwd = std.fs.cwd();
            const stat = cwd.statFile(effective_pattern) catch null;
            const is_dir = if (stat) |s| s.kind == .directory else false;
            if (gi.isIgnored(effective_pattern, is_dir)) {
                if (flags & ZLOB_NOCHECK != 0) {
                    return returnPatternAsResult(allocator, effective_pattern, pzlob);
                }
                return null;
            }
        }

        // Try to match literal path
        const found = try globLiteralPath(allocator, effective_pattern, effective_flags, pzlob);
        if (found) return;

        if (flags & ZLOB_NOCHECK != 0) {
            return returnPatternAsResult(allocator, effective_pattern, pzlob);
        }

        return null;
    }

    const info = analyzePattern(effective_pattern, effective_flags);

    // Fast path: simple pattern with literal prefix (e.g., "src/foo/*.txt")
    if (info.simple_extension != null and info.literal_prefix.len > 0) {
        return globInDirFiltered(allocator, info.wildcard_suffix, info.literal_prefix, effective_flags, errfunc, pzlob, info.directories_only, gitignore_filter);
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

        return globRecursive(allocator, pattern_from_doublestar, dirname, effective_flags, errfunc, pzlob, info.directories_only, brace_parsed, gitignore_filter);
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
        return globWithWildcardDirsOptimized(allocator, effective_pattern, &info, effective_flags, errfunc, pzlob, info.directories_only, gitignore_filter);
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
        return globRecursive(allocator, filename_pattern, dirname, effective_flags, errfunc, pzlob, info.directories_only, brace_parsed, gitignore_filter);
    }

    return globInDirFiltered(allocator, filename_pattern, dirname, effective_flags, errfunc, pzlob, info.directories_only, gitignore_filter);
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

    pzlob.gl_pathc = 1;
    pzlob.gl_pathv = result;
    pzlob.gl_pathlen = pathlen_buf.ptr;
    pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    return;
}

// Helper to expand tilde (~) in patterns

//   - The expanded pattern (allocated if expanded, original if no tilde)
//   - null if ZLOB_TILDE_CHECK is set and expansion fails (indicates no match)
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
            if (flags & ZLOB_TILDE_CHECK != 0) {
                return null; // Indicate no match
            }
            break :blk null;
        }
        @memcpy(username_z[0..username.len], username);
        username_z[username.len] = 0;

        const pw_entry = pwd.getpwnam(&username_z);
        if (pw_entry == null) {
            if (flags & ZLOB_TILDE_CHECK != 0) {
                return null; // Indicate no match
            }
            break :blk null;
        }

        const home_cstr = pw_entry.*.pw_dir;
        if (home_cstr == null) {
            if (flags & ZLOB_TILDE_CHECK != 0) {
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
    if (flags & ZLOB_APPEND == 0) {
        pzlob.gl_pathc = 0;
        pzlob.gl_pathv = null;
        if (flags & ZLOB_DOOFFS == 0) {
            pzlob.gl_offs = 0;
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

    if (flags & ZLOB_GITIGNORE != 0) {
        gitignore_instance = GitIgnore.loadFromCwd(allocator) catch null;
    }
    const gitignore_ptr: ?*GitIgnore = if (gitignore_instance) |*gi| gi else null;

    if (flags & ZLOB_TILDE != 0) {
        expanded_pattern = try expandTilde(allocator, pattern_slice, flags);
        if (expanded_pattern == null) {
            // ZLOB_TILDE_CHECK is set and tilde expansion failed - no match
            return null;
        }
        pattern_slice = expanded_pattern.?;
    }

    if ((flags & ZLOB_BRACE != 0) and brace_optimizer.containsBraces(pattern_slice)) {
        var opt = brace_optimizer.analyzeBracedPattern(allocator, pattern_slice) catch {
            // On error, fall back to standard brace expansion
            return try globBraceExpand(allocator, pattern_slice, flags, errfunc, pzlob, gitignore_ptr);
        };
        defer opt.deinit();

        switch (opt) {
            .single_walk => |*parsed| {
                // All single_walk patterns flow through globSingle
                // which handles braces in any position via globRecursive
                return try globSingle(
                    allocator,
                    pattern_slice,
                    parsed,
                    flags,
                    errfunc,
                    pzlob,
                    gitignore_ptr,
                );
            },
            .fallback, .no_braces => return try globBraceExpand(allocator, pattern_slice, flags, errfunc, pzlob, gitignore_ptr),
        }
    }

    return try globSingle(allocator, pattern_slice, null, flags, errfunc, pzlob, gitignore_ptr);
}

// Expand brace patterns and glob each independently (no ZLOB_APPEND manipulation)
fn globBraceExpand(allocator: std.mem.Allocator, pattern: []const u8, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t, gitignore_filter: ?*GitIgnore) !?void {
    var expanded = ResultsList.init(allocator);
    defer {
        for (expanded.items) |item| {
            const item_mem = mem.sliceTo(item, 0);
            allocator.free(item_mem);
        }
        expanded.deinit();
    }

    try expandBraces(allocator, pattern, &expanded);

    // Collect all results from all expanded patterns
    var all_results = ResultsList.init(allocator);
    defer all_results.deinit();

    // Glob each expanded pattern independently (NO ZLOB_APPEND)
    for (expanded.items) |exp_pattern| {
        const exp_slice = mem.sliceTo(exp_pattern, 0);

        // Create a temporary pzlob for this pattern
        var temp_pzlob: zlob_t = undefined;
        temp_pzlob.gl_pathc = 0;
        temp_pzlob.gl_pathv = null;
        temp_pzlob.gl_offs = 0;

        _ = try globSingle(allocator, exp_slice, null, flags & ~@as(c_int, ZLOB_APPEND), errfunc, &temp_pzlob, gitignore_filter);

        // Collect results from temp_pzlob
        if (temp_pzlob.gl_pathc > 0) {
            for (0..temp_pzlob.gl_pathc) |i| {
                try all_results.append(temp_pzlob.gl_pathv[i]);
            }
            // Don't free the paths yet, we're transferring ownership
            // Free the pathv array and pathlen array, but not the paths themselves
            if (temp_pzlob.gl_flags & ZLOB_FLAGS_OWNS_STRINGS != 0) {
                allocator.free(@as([*]const [*c]u8, @ptrCast(temp_pzlob.gl_pathv))[0 .. temp_pzlob.gl_pathc + 1]);
                allocator.free(@as([*]const usize, @ptrCast(temp_pzlob.gl_pathlen))[0..temp_pzlob.gl_pathc]);
            }
        }
    }

    if (all_results.items.len == 0) {
        if (flags & ZLOB_NOCHECK != 0) {
            const pat_copy = try allocator.allocSentinel(u8, pattern.len, 0);
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = try allocator.alloc([*c]u8, 2);
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            const pathlen_buf = try allocator.alloc(usize, 1);
            pathlen_buf[0] = pattern.len;

            pzlob.gl_pathc = 1;
            pzlob.gl_pathv = result;
            pzlob.gl_pathlen = pathlen_buf.ptr;
            pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
            return;
        }
        return null;
    }

    // Sort results if needed
    if (flags & ZLOB_NOSORT == 0) {
        qsort(@ptrCast(all_results.items.ptr), all_results.items.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    // Build final result
    const pathv_buf = try allocator.alloc([*c]u8, all_results.items.len + 1);
    const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

    const pathlen_buf = try allocator.alloc(usize, all_results.items.len);

    for (all_results.items, 0..) |path, i| {
        result[i] = path;
        pathlen_buf[i] = mem.len(path);
    }
    result[all_results.items.len] = null;

    pzlob.gl_pathc = all_results.items.len;
    pzlob.gl_pathv = result;
    pzlob.gl_pathlen = pathlen_buf.ptr;
    pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
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

/// Match filename against pre-computed pattern contexts (avoids redundant PatternContext.init calls)
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

/// Unified brace pattern glob - walks the tree ONCE regardless of where braces appear
fn globRecursive(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t, directories_only: bool, brace_parsed: ?*const brace_optimizer.BracedPattern, gitignore_filter: ?*GitIgnore) !?void {
    const info = analyzePattern(pattern, flags);

    // Split pattern at **
    const double_star_pos = mem.indexOf(u8, pattern, "**") orelse return globInDirFiltered(allocator, pattern, dirname, flags, errfunc, pzlob, directories_only, gitignore_filter);

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
                var path_buf: [4096]u8 = undefined;
                var path_len: usize = 0;
                for (parsed.components[0..literal_prefix_end], 0..) |comp, i| {
                    if (i > 0) {
                        path_buf[path_len] = '/';
                        path_len += 1;
                    }
                    @memcpy(path_buf[path_len..][0..comp.text.len], comp.text);
                    path_len += comp.text.len;
                }
                // Store in a static buffer that persists (we only use start_dir during this call)
                start_dir = path_buf[0..path_len];
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
    var all_results = ResultsList.init(allocator);
    defer all_results.deinit();

    all_results.ensureTotalCapacity(1024) catch {}; // Best effort

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
        );
    } else if (post_ds_count == 0) {
        // No dir components at all - use Zig walker which produces slices directly
        try globRecursiveWithZigWalk(allocator, &rec_pattern, start_dir, flags, &all_results, &info, errfunc);
    } else {
        // Has post-doublestar dir components - use C-based recursive helper
        try globRecursiveHelperCollect(allocator, &rec_pattern, start_dir, flags, &all_results, 0, &info, errfunc);
    }

    if (all_results.items.len == 0) {
        return null;
    }

    if (flags & ZLOB_NOSORT == 0) {
        qsort(@ptrCast(all_results.items.ptr), all_results.items.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    return finalizeResults(allocator, &all_results, flags, pzlob);
}

fn globRecursiveWithBracedPrefix(
    allocator: std.mem.Allocator,
    rec_pattern: *const RecursivePattern,
    current_dir: []const u8,
    pre_ds_components: []const []const u8,
    pre_ds_alternatives: []const ?[]const []const u8,
    component_idx: usize,
    flags: c_int,
    results: *ResultsList,
    info: *const PatternInfo,
    errfunc: zlob_errfunc_t,
) !void {
    // If we've matched all pre-doublestar components, start the recursive walk
    if (component_idx >= pre_ds_components.len) {
        // Now do the recursive walk from current_dir
        if (rec_pattern.dir_components.len == 0) {
            try globRecursiveWithZigWalk(allocator, rec_pattern, current_dir, flags, results, info, errfunc);
        } else {
            try globRecursiveHelperCollect(allocator, rec_pattern, current_dir, flags, results, 0, info, errfunc);
        }
        return;
    }

    const comp_text = pre_ds_components[component_idx];
    const comp_alts = pre_ds_alternatives[component_idx];

    // Open current directory to find matching subdirectories
    var dir = std.fs.cwd().openDir(current_dir, .{ .iterate = true }) catch |err| {
        if (errfunc) |efunc| {
            var path_buf: [4096:0]u8 = undefined;
            if (current_dir.len < 4096) {
                @memcpy(path_buf[0..current_dir.len], current_dir);
                path_buf[current_dir.len] = 0;
                const eerrno: c_int = switch (err) {
                    error.AccessDenied => @intFromEnum(std.posix.E.ACCES),
                    error.FileNotFound => @intFromEnum(std.posix.E.NOENT),
                    error.NotDir => @intFromEnum(std.posix.E.NOTDIR),
                    else => @intFromEnum(std.posix.E.IO),
                };
                _ = efunc(&path_buf, eerrno);
            }
        }
        if ((flags & ZLOB_ERR) != 0) {
            return error.Aborted;
        }
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const name = entry.name;

        // Skip . and ..
        if (name.len == 0) continue;
        if (name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) continue;

        // Skip hidden unless ZLOB_PERIOD or pattern starts with .
        if ((flags & ZLOB_PERIOD) == 0 and name[0] == '.') {
            if (comp_text.len == 0 or comp_text[0] != '.') {
                if (comp_alts) |alts| {
                    var any_starts_dot = false;
                    for (alts) |alt| {
                        if (alt.len > 0 and alt[0] == '.') {
                            any_starts_dot = true;
                            break;
                        }
                    }
                    if (!any_starts_dot) continue;
                } else {
                    continue;
                }
            }
        }

        // Only consider directories
        if (entry.kind != .directory) continue;

        // Check if name matches this component (with alternatives if present)
        const matches = if (comp_alts) |alts|
            matchWithAlternatives(name, alts)
        else blk: {
            const comp_ctx = PatternContext.init(comp_text);
            break :blk fnmatchWithContext(&comp_ctx, name);
        };

        if (matches) {
            // Build path to matched directory
            var path_buf: [4096]u8 = undefined;
            const path_len = if (mem.eql(u8, current_dir, "."))
                name.len
            else
                current_dir.len + 1 + name.len;

            if (path_len >= 4096) continue;

            const subdir = if (mem.eql(u8, current_dir, ".")) blk: {
                @memcpy(path_buf[0..name.len], name);
                break :blk path_buf[0..name.len];
            } else blk: {
                @memcpy(path_buf[0..current_dir.len], current_dir);
                path_buf[current_dir.len] = '/';
                @memcpy(path_buf[current_dir.len + 1 ..][0..name.len], name);
                break :blk path_buf[0..path_len];
            };

            // Recurse to next pre-ds component
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
            );
        }
    }
}

// Helper to finalize results from ArrayList to zlob_t
fn finalizeResults(allocator: std.mem.Allocator, results: *ResultsList, flags: c_int, pzlob: *zlob_t) !?void {
    const offs = if (flags & ZLOB_DOOFFS != 0) pzlob.gl_offs else 0;

    // Handle ZLOB_APPEND - merge with existing results
    if (flags & ZLOB_APPEND != 0 and pzlob.gl_pathv != null and pzlob.gl_pathc > 0) {
        const old_count = pzlob.gl_pathc;
        const new_count = results.items.len;
        const total_count = old_count + new_count;

        const pathv_buf = allocator.alloc([*c]u8, offs + total_count + 1) catch return error.OutOfMemory;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        var k: usize = 0;
        while (k < offs) : (k += 1) result[k] = null;

        var i: usize = 0;
        while (i < old_count) : (i += 1) {
            result[offs + i] = pzlob.gl_pathv[offs + i];
        }

        var j: usize = 0;
        while (j < new_count) : (j += 1) {
            result[offs + old_count + j] = results.items[j];
        }
        result[offs + total_count] = null;

        const pathlen_buf = allocator.alloc(usize, total_count) catch return error.OutOfMemory;
        var li: usize = 0;
        while (li < old_count) : (li += 1) {
            pathlen_buf[li] = pzlob.gl_pathlen[li];
        }
        var lj: usize = 0;
        while (lj < new_count) : (lj += 1) {
            pathlen_buf[old_count + lj] = mem.len(results.items[lj]);
        }

        const old_pathv_slice = @as([*][*c]u8, @ptrCast(pzlob.gl_pathv))[0 .. offs + old_count + 1];
        allocator.free(old_pathv_slice);
        const old_pathlen_slice = pzlob.gl_pathlen[0..old_count];
        allocator.free(old_pathlen_slice);

        pzlob.gl_pathc = total_count;
        pzlob.gl_pathv = result;
        pzlob.gl_pathlen = pathlen_buf.ptr;
        pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
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

        pzlob.gl_pathc = results.items.len;
        pzlob.gl_pathv = result;
        pzlob.gl_pathlen = pathlen_buf.ptr;
        pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    }
}

// Use Zig's std.fs.Dir.walk() for recursive directory traversal
// This produces string slices directly, avoiding mem.sliceTo overhead on every entry
inline fn globRecursiveWithZigWalk(
    allocator: std.mem.Allocator,
    rec_pattern: *const RecursivePattern,
    start_dir: []const u8,
    flags: c_int,
    results: *ResultsList,
    info: *const PatternInfo,
    errfunc: zlob_errfunc_t,
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
        // If ZLOB_ERR is set, abort on error
        if ((flags & ZLOB_ERR) != 0) {
            return error.Aborted;
        }
        // Otherwise, silently skip this directory
        return;
    };
    defer dir.close();

    // Note: std.fs.Dir.walk() doesn't support pruning, so we use iterate() for gitignore support
    // If gitignore is enabled, we need manual recursion to support directory pruning
    if (rec_pattern.gitignore_filter) |gi| {
        try walkWithGitignore(allocator, dir, start_dir, "", rec_pattern, &pattern_ctx, flags, results, info, gi);
    } else {
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
                if ((flags & ZLOB_PERIOD) == 0) {
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
                const matches = if (rec_pattern.file_pattern_contexts) |contexts|
                    matchWithAlternativesPrecomputed(entry.basename, contexts)
                else if (rec_pattern.file_alternatives) |alts|
                    matchWithAlternatives(entry.basename, alts)
                else if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
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
}

/// Manual recursive walk with gitignore support for directory pruning
fn walkWithGitignore(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    start_dir: []const u8,
    rel_path: []const u8,
    rec_pattern: *const RecursivePattern,
    pattern_ctx: *const PatternContext,
    flags: c_int,
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
        if ((flags & ZLOB_PERIOD) == 0 and name[0] == '.') {
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
            const matches = if (rec_pattern.file_pattern_contexts) |contexts|
                matchWithAlternativesPrecomputed(name, contexts)
            else if (rec_pattern.file_alternatives) |alts|
                matchWithAlternatives(name, alts)
            else if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
                batched_suffix_match.matchSuffix(name)
            else
                fnmatchWithContext(pattern_ctx, name);

            if (matches) {
                const full_path_len = start_dir.len + 1 + entry_rel_path.len;
                const path_buf_slice = allocator.allocSentinel(u8, full_path_len, 0) catch return error.OutOfMemory;

                @memcpy(path_buf_slice[0..start_dir.len], start_dir);
                path_buf_slice[start_dir.len] = '/';
                @memcpy(path_buf_slice[start_dir.len + 1 ..][0..entry_rel_path.len], entry_rel_path);

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

inline fn globRecursiveHelperCollect(allocator: std.mem.Allocator, rec_pattern: *const RecursivePattern, dirname: []const u8, flags: c_int, results: *ResultsList, depth: usize, info: *const PatternInfo, errfunc: zlob_errfunc_t) !void {
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
        try globInDirImplCollect(allocator, rec_pattern.file_pattern, rec_pattern.file_alternatives, rec_pattern.file_pattern_contexts, dirname, flags, results, info.directories_only, errfunc, rec_pattern.gitignore_filter);
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
        // If ZLOB_ERR is set, abort on error
        if ((flags & ZLOB_ERR) != 0) {
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
            if (flags & ZLOB_PERIOD != 0) {
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

                const matches_component = if (has_alternatives)
                    matchWithAlternatives(name, rec_pattern.dir_component_alternatives.?[0].?)
                else blk: {
                    const component_ctx = PatternContext.init(next_component);
                    break :blk fnmatchWithContext(&component_ctx, name);
                };

                if (!matches_component) continue;

                next_rec_pattern.dir_components = rec_pattern.dir_components[1..];
                // Also advance alternatives if present
                if (rec_pattern.dir_component_alternatives) |alts| {
                    next_rec_pattern.dir_component_alternatives = if (alts.len > 1) alts[1..] else null;
                }
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
            try globRecursiveHelperCollect(allocator, &next_rec_pattern, subdir, flags, results, depth + 1, info, errfunc);
        }
    }
}

fn globInDirImplCollect(allocator: std.mem.Allocator, pattern: []const u8, file_alternatives: ?[]const []const u8, file_pattern_contexts: ?[]const PatternContext, dirname: []const u8, flags: c_int, results: *ResultsList, directories_only: bool, errfunc: zlob_errfunc_t, gitignore_filter: ?*GitIgnore) !void {
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
        // If ZLOB_ERR is set, abort on error
        if ((flags & ZLOB_ERR) != 0) {
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

        // Match against file pattern (with alternatives if present)
        // KEY OPTIMIZATION: Use pre-computed pattern contexts to avoid redundant PatternContext.init() calls
        const matches = if (file_pattern_contexts) |contexts|
            matchWithAlternativesPrecomputed(name, contexts)
        else if (file_alternatives) |alts|
            matchWithAlternatives(name, alts)
        else if (pattern_ctx.simd_batched_suffix_match) |batched_suffix_match|
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

            // Gitignore filtering - skip ignored files
            if (gitignore_filter) |gi| {
                // Build relative path for gitignore check
                const rel_path = if (use_dirname)
                    path_buf_slice[0..path_len]
                else
                    name;
                if (gi.isIgnored(rel_path, is_dir)) {
                    allocator.free(path_buf_slice);
                    continue;
                }
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

        // ZLOB_PERIOD: allow wildcards to match hidden files
        if (flags & ZLOB_PERIOD != 0) return false;

        if (!pattern_ctx.starts_with_dot) return true;
    }
    return false;
}

// Helper to check if path is a directory and append '/' if ZLOB_MARK is set
pub inline fn maybeAppendSlash(allocator: std.mem.Allocator, path: [*c]u8, path_len: usize, is_dir: bool, flags: c_int) !?[*c]u8 {
    if (!is_dir or (flags & ZLOB_MARK == 0)) {
        return null; // No modification needed
    }

    // Need to append '/' - reallocate with extra space
    const old_slice = @as([*]u8, @ptrCast(path))[0 .. path_len + 1]; // includes sentinel
    const new_slice = try allocator.realloc(old_slice, path_len + 2); // +1 for '/', +1 for sentinel
    new_slice[path_len] = '/';
    new_slice[path_len + 1] = 0;
    return @ptrCast(new_slice.ptr);
}

fn globInDirFiltered(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: c_int, errfunc: zlob_errfunc_t, pzlob: *zlob_t, directories_only: bool, gitignore_filter: ?*GitIgnore) !?void {
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
        // If ZLOB_ERR is set, abort on error
        if ((flags & ZLOB_ERR) != 0) {
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

            if (gitignore_filter) |gi| {
                const rel_path = if (use_dirname)
                    path_buf_slice[0..path_len]
                else
                    name;
                if (gi.isIgnored(rel_path, is_dir)) {
                    allocator.free(path_buf_slice);
                    continue;
                }
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
        if (flags & ZLOB_NOCHECK != 0) {
            const pat_copy = allocator.allocSentinel(u8, pattern.len, 0) catch return error.OutOfMemory;
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = allocator.alloc([*c]u8, 2) catch return error.OutOfMemory;
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            const pathlen_buf = allocator.alloc(usize, 1) catch return error.OutOfMemory;
            pathlen_buf[0] = pattern.len;

            pzlob.gl_pathc = 1;
            pzlob.gl_pathv = result;
            pzlob.gl_pathlen = pathlen_buf.ptr;
            pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
            return;
        }
        return null;
    }

    if (flags & ZLOB_NOSORT == 0) {
        qsort(@ptrCast(names.items.ptr), names.items.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    // Handle ZLOB_APPEND flag - merge with existing results
    if (flags & ZLOB_APPEND != 0 and pzlob.gl_pathv != null and pzlob.gl_pathc > 0) {
        const old_count = pzlob.gl_pathc;
        const new_count = names.items.len;
        const total_count = old_count + new_count;
        const offs = if (flags & ZLOB_DOOFFS != 0) pzlob.gl_offs else 0;

        const pathv_buf = allocator.alloc([*c]u8, offs + total_count + 1) catch return error.OutOfMemory;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        var k: usize = 0;
        while (k < offs) : (k += 1) {
            result[k] = null;
        }

        var i: usize = 0;
        while (i < old_count) : (i += 1) {
            result[offs + i] = pzlob.gl_pathv[offs + i];
        }

        var j: usize = 0;
        while (j < new_count) : (j += 1) {
            result[offs + old_count + j] = names.items[j];
        }
        result[offs + total_count] = null;

        const pathlen_buf = allocator.alloc(usize, total_count) catch return error.OutOfMemory;
        var li: usize = 0;
        while (li < old_count) : (li += 1) {
            pathlen_buf[li] = pzlob.gl_pathlen[li];
        }
        var lj: usize = 0;
        while (lj < new_count) : (lj += 1) {
            pathlen_buf[old_count + lj] = mem.len(names.items[lj]);
        }

        const old_pathv_slice = @as([*][*c]u8, @ptrCast(pzlob.gl_pathv))[0 .. offs + old_count + 1];
        allocator.free(old_pathv_slice);
        const old_pathlen_slice = pzlob.gl_pathlen[0..old_count];
        allocator.free(old_pathlen_slice);

        pzlob.gl_pathc = total_count;
        pzlob.gl_pathv = result;
        pzlob.gl_pathlen = pathlen_buf.ptr;
        pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    } else {
        // No APPEND or first call - allocate fresh result array
        const offs = if (flags & ZLOB_DOOFFS != 0) pzlob.gl_offs else 0;
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

        pzlob.gl_pathc = names.items.len;
        pzlob.gl_pathv = result;
        pzlob.gl_pathlen = pathlen_buf.ptr;
        pzlob.gl_flags = ZLOB_FLAGS_OWNS_STRINGS;
    }
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

/// Full fnmatch implementation - exposed for gitignore module
/// Note: This treats ** as regular * (no special directory handling)
/// For ** directory matching, use the gitignore module's matchGlob
pub fn fnmatchFull(pattern: []const u8, string: []const u8) bool {
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

/// Internal globfree function - frees zlob_t structure
/// Used by GlobResults.deinit() and C API (c_lib.zig)
/// Exposed as public for C API compatibility
pub fn globfreeInternal(allocator: std.mem.Allocator, pzlob: *zlob_t) void {
    if (pzlob.gl_pathv) |pathv| {
        // gl_offs might be uninitialized if ZLOB_DOOFFS wasn't used - treat as 0
        const offs = pzlob.gl_offs;

        const owns_strings = (pzlob.gl_flags & ZLOB_FLAGS_OWNS_STRINGS) != 0;

        if (owns_strings) {
            var i: usize = 0;
            while (i < pzlob.gl_pathc) : (i += 1) {
                if (pathv[offs + i]) |path| {
                    const path_len = pzlob.gl_pathlen[i];
                    const path_slice = @as([*]u8, @ptrCast(path))[0 .. path_len + 1];
                    allocator.free(path_slice);
                }
            }
        }
        // Always free the pathv array including offset slots
        const pathv_slice = @as([*][*c]u8, @ptrCast(pathv))[0 .. offs + pzlob.gl_pathc + 1];
        allocator.free(pathv_slice);

        // Always free the pathlen array
        const pathlen_slice = pzlob.gl_pathlen[0..pzlob.gl_pathc];
        allocator.free(pathlen_slice);
    }
    pzlob.gl_pathv = null;
    pzlob.gl_pathc = 0;
    pzlob.gl_flags = ZLOB_FLAGS_SHARED_STRINGS;
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
