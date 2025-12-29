const std = @import("std");
const c = std.c;
const mem = std.mem;

const pwd = @cImport({
    @cInclude("pwd.h");
});

// C-style glob result matching glibc exactly
pub const glob_t = extern struct {
    gl_pathc: usize,
    gl_pathv: [*c][*c]u8,
    gl_offs: usize,
};

// Standard POSIX glob flags (matching glibc values exactly)
pub const GLOB_ERR = 1 << 0; // 0x0001 - Return on read errors
pub const GLOB_MARK = 1 << 1; // 0x0002 - Append a slash to each name
pub const GLOB_NOSORT = 1 << 2; // 0x0004 - Don't sort the names
pub const GLOB_DOOFFS = 1 << 3; // 0x0008 - Insert PGLOB->gl_offs NULLs
pub const GLOB_NOCHECK = 1 << 4; // 0x0010 - If nothing matches, return the pattern
pub const GLOB_APPEND = 1 << 5; // 0x0020 - Append to results of a previous call
pub const GLOB_NOESCAPE = 1 << 6; // 0x0040 - Backslashes don't quote metacharacters
pub const GLOB_PERIOD = 1 << 7; // 0x0080 - Leading `.' can be matched by metachars

// GNU extensions
pub const GLOB_MAGCHAR = 1 << 8; // 0x0100 - Set in gl_flags if any metachars seen
pub const GLOB_ALTDIRFUNC = 1 << 9; // 0x0200 - Use gl_opendir et al functions
pub const GLOB_BRACE = 1 << 10; // 0x0400 - Expand "{a,b}" to "a" "b"
pub const GLOB_NOMAGIC = 1 << 11; // 0x0800 - If no magic chars, return the pattern
pub const GLOB_TILDE = 1 << 12; // 0x1000 - Expand ~user and ~ to home directories
pub const GLOB_ONLYDIR = 1 << 13; // 0x2000 - Match only directories
pub const GLOB_TILDE_CHECK = 1 << 14; // 0x4000 - Like GLOB_TILDE but return error if user name not available

// Error codes
pub const GLOB_NOSPACE = 1;
pub const GLOB_ABORTED = 2;
pub const GLOB_NOMATCH = 3;

// Use Zig's cross-platform dirent structure
const dirent = std.c.dirent;

const DT_UNKNOWN = std.c.DT.UNKNOWN;
const DT_DIR = std.c.DT.DIR;

const NameArray = struct {
    items: [*c][*c]u8,
    len: usize,
    cap: usize,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) NameArray {
        return .{ .items = null, .len = 0, .cap = 0, .allocator = allocator };
    }

    fn append(self: *NameArray, item: [*c]u8) !void {
        if (self.len >= self.cap) {
            const new_cap = if (self.cap == 0) 8 else self.cap * 2;

            // Use Zig allocator instead of c.realloc
            if (self.items) |items| {
                // Realloc existing memory
                const old_mem = @as([*]u8, @ptrCast(items))[0 .. self.cap * @sizeOf([*c]u8)];
                const new_mem = try self.allocator.realloc(old_mem, new_cap * @sizeOf([*c]u8));
                self.items = @ptrCast(@alignCast(new_mem.ptr));
            } else {
                // First allocation
                const new_mem = try self.allocator.alloc(u8, new_cap * @sizeOf([*c]u8));
                self.items = @ptrCast(@alignCast(new_mem.ptr));
            }
            self.cap = new_cap;
        }

        self.items[self.len] = item;
        self.len += 1;
    }

    fn deinit(self: *NameArray) void {
        if (self.items) |items| {
            const items_mem = @as([*]u8, @ptrCast(items))[0 .. self.cap * @sizeOf([*c]u8)];
            self.allocator.free(items_mem);
        }
    }
};

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

// Pre-computed pattern matching context to avoid redundant hasWildcardsSIMD calls
const PatternContext = struct {
    pattern: []const u8,
    has_wildcards: bool, // Pattern contains wildcards
    is_simple_star_ext: bool, // Pattern is *.ext form
    simple_ext: []const u8, // The extension for *.ext patterns

    fn init(pattern: []const u8) PatternContext {
        const has_wc = hasWildcardsSIMD(pattern);
        var is_simple = false;
        var ext: []const u8 = "";

        // Check for *.ext pattern
        if (pattern.len >= 2 and pattern[0] == '*' and !hasWildcardsSIMD(pattern[1..])) {
            is_simple = true;
            ext = pattern[1..];
        }

        return PatternContext{
            .pattern = pattern,
            .has_wildcards = has_wc,
            .is_simple_star_ext = is_simple,
            .simple_ext = ext,
        };
    }
};

// Extract literal prefix from pattern for optimization
pub fn extractLiteralPrefix(pattern: []const u8, flags: c_int) PatternInfo {
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

        // Handle escape sequences - can't use as literal path
        if (enable_escape and ch == '\\' and i + 1 < pattern.len) {
            break;
        }

        // Track bracket expressions
        if (ch == '[' and !in_bracket) {
            in_bracket = true;
            break; // Can't continue literal prefix through bracket
        }
        if (ch == ']' and in_bracket) {
            in_bracket = false;
        }

        // Check for wildcards
        if (ch == '*' or ch == '?') {
            // Check for **
            if (ch == '*' and i + 1 < pattern.len and pattern[i + 1] == '*') {
                info.has_recursive = true;
            }
            break;
        }

        // Track slashes for component counting
        if (ch == '/') {
            last_slash = i;
            component_count += 1;
        }
    }

    // Set prefix to everything up to (but not including) last slash before wildcard
    if (i > 0) {
        info.wildcard_start_pos = i;
        if (last_slash > 0) {
            info.literal_prefix = pattern[0..last_slash];
            info.wildcard_suffix = pattern[last_slash + 1 ..];
            info.fixed_component_count = component_count;
        } else if (i == pattern.len) {
            // No wildcards at all - entire pattern is literal
            info.literal_prefix = pattern;
            info.wildcard_suffix = "";
            info.fixed_component_count = component_count;
        } else {
            // Wildcard in first component - no literal prefix
            info.literal_prefix = "";
            info.wildcard_suffix = pattern;
            info.fixed_component_count = 0;
        }
    }

    // Check for wildcards in directory components
    if (info.wildcard_suffix.len > 0) {
        if (mem.lastIndexOf(u8, info.wildcard_suffix, "/")) |pos| {
            const dir_part = info.wildcard_suffix[0..pos];
            info.has_dir_wildcards = hasWildcardsSIMD(dir_part);
        }
    }

    // Detect simple *.ext pattern for fast path
    if (!info.has_recursive and !info.has_dir_wildcards and
        info.wildcard_suffix.len >= 2 and info.wildcard_suffix[0] == '*')
    {
        const suffix = info.wildcard_suffix[1..];
        if (!hasWildcardsSIMD(suffix) and mem.indexOf(u8, suffix, "/") == null) {
            info.simple_extension = suffix;
        }
    }

    // Calculate max depth if no recursive glob
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

// Check if a directory path can possibly lead to matches
fn canMatchPattern(
    dir_path: []const u8,
    current_depth: usize,
    info: *const PatternInfo,
) bool {
    // Depth pruning: If max_depth set and exceeded, skip
    if (info.max_depth) |max| {
        if (current_depth >= max) return false;
    }

    // If we have a literal prefix, directory must be compatible
    if (info.literal_prefix.len > 0) {
        // Directory must either be a prefix of literal_prefix,
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

    // No literal prefix means pattern starts with wildcard - can't prune
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

// used for the qsort but uses simd for string comparison
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

// Brace expansion helper - find matching closing brace
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

// Expand brace pattern into multiple patterns
fn expandBraces(allocator: std.mem.Allocator, pattern: []const u8, results: *NameArray) !void {
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
    var alternatives = NameArray.init(allocator);
    defer alternatives.deinit();

    i = 0;
    while (i <= brace_content.len) : (i += 1) {
        if (i == brace_content.len or brace_content[i] == ',') {
            const alt = brace_content[start..i];

            // Build new pattern: prefix + alternative + suffix
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
    for (alternatives.items[0..alternatives.len]) |alt_pattern| {
        const alt_slice = mem.sliceTo(alt_pattern, 0);
        try expandBraces(allocator, alt_slice, results);
        allocator.free(alt_slice);
    }
}

// Helper to build path from components
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

// Recursive wildcard directory expansion for patterns like */*/*.txt
fn globWithWildcardDirs(allocator: std.mem.Allocator, pattern: []const u8, flags: c_int, pglob: *glob_t, directories_only: bool) c_int {
    // Split pattern by '/' into components
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

    // Collect all matching paths
    var result_paths = NameArray.init(allocator);
    defer result_paths.deinit();

    // Start recursive expansion from current directory
    expandWildcardComponents(allocator, ".", components[0..component_count], 0, &result_paths, directories_only) catch |err| {
        // Clean up any allocated paths on error
        for (result_paths.items[0..result_paths.len]) |path| {
            const path_slice = mem.sliceTo(path, 0);
            allocator.free(path_slice);
        }
        return if (err == error.OutOfMemory) GLOB_NOSPACE else GLOB_ABORTED;
    };

    // Handle no matches
    if (result_paths.len == 0) {
        if (flags & GLOB_NOCHECK != 0) {
            const pat_copy = allocator.allocSentinel(u8, pattern.len, 0) catch return GLOB_NOSPACE;
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = allocator.alloc([*c]u8, 2) catch return GLOB_NOSPACE;
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            pglob.gl_pathc = 1;
            pglob.gl_pathv = result;
            return 0;
        }
        return GLOB_NOMATCH;
    }

    // Sort unless NOSORT
    if (flags & GLOB_NOSORT == 0) {
        qsort(@ptrCast(result_paths.items), result_paths.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    // Build result
    const pathv_buf = allocator.alloc([*c]u8, result_paths.len + 1) catch return GLOB_NOSPACE;
    const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

    var i: usize = 0;
    while (i < result_paths.len) : (i += 1) {
        result[i] = result_paths.items[i];
    }
    result[result_paths.len] = null;

    pglob.gl_pathc = result_paths.len;
    pglob.gl_pathv = result;

    return 0;
}

// Optimized version that uses pattern info to start from literal prefix
fn globWithWildcardDirsOptimized(allocator: std.mem.Allocator, pattern: []const u8, info: *const PatternInfo, flags: c_int, pglob: *glob_t, directories_only: bool) c_int {
    // Split pattern by '/' into components (use wildcard_suffix if we have prefix)
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

    // Collect all matching paths
    var result_paths = NameArray.init(allocator);
    defer result_paths.deinit();

    // Start from literal prefix instead of "."
    const start_dir = if (info.literal_prefix.len > 0)
        info.literal_prefix
    else
        ".";

    expandWildcardComponents(allocator, start_dir, components[0..component_count], 0, &result_paths, directories_only) catch |err| {
        // Clean up any allocated paths on error
        for (result_paths.items[0..result_paths.len]) |path| {
            const path_slice = mem.sliceTo(path, 0);
            allocator.free(path_slice);
        }
        return if (err == error.OutOfMemory) GLOB_NOSPACE else GLOB_ABORTED;
    };

    // Handle no matches
    if (result_paths.len == 0) {
        if (flags & GLOB_NOCHECK != 0) {
            const pat_copy = allocator.allocSentinel(u8, pattern.len, 0) catch return GLOB_NOSPACE;
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = allocator.alloc([*c]u8, 2) catch return GLOB_NOSPACE;
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            pglob.gl_pathc = 1;
            pglob.gl_pathv = result;
            return 0;
        }
        return GLOB_NOMATCH;
    }

    // Sort unless NOSORT
    if (flags & GLOB_NOSORT == 0) {
        qsort(@ptrCast(result_paths.items), result_paths.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    // Build result
    const pathv_buf = allocator.alloc([*c]u8, result_paths.len + 1) catch return GLOB_NOSPACE;
    const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

    var i: usize = 0;
    while (i < result_paths.len) : (i += 1) {
        result[i] = result_paths.items[i];
    }
    result[result_paths.len] = null;

    pglob.gl_pathc = result_paths.len;
    pglob.gl_pathv = result;

    return 0;
}

// Recursive helper to expand wildcard components level by level
fn expandWildcardComponents(
    allocator: std.mem.Allocator,
    current_dir: []const u8,
    components: []const []const u8,
    component_idx: usize,
    results: *NameArray,
    directories_only: bool,
) !void {
    // Safety: limit recursion depth
    if (component_idx > 65536) return error.Aborted;

    // Base case: processed all components
    if (component_idx >= components.len) {
        // Add current_dir to results
        const path_copy = try allocator.allocSentinel(u8, current_dir.len, 0);
        @memcpy(path_copy[0..current_dir.len], current_dir);
        const path: [*c]u8 = @ptrCast(path_copy.ptr);
        try results.append(path);
        return;
    }

    const component = components[component_idx];
    const is_final = component_idx == components.len - 1;

    // Check if component has wildcards
    const has_wildcards = hasWildcardsSIMD(component);

    if (has_wildcards) {
        // Fast path: detect simple *.ext pattern
        var simple_ext: ?[]const u8 = null;
        if (component.len >= 2 and component[0] == '*' and
            !hasWildcardsSIMD(component[1..]))
        {
            simple_ext = component[1..];
        }

        // Wildcard component - match against directory entries
        var dirname_z: [4096:0]u8 = undefined;
        if (current_dir.len >= 4096) return error.OutOfMemory;
        @memcpy(dirname_z[0..current_dir.len], current_dir);
        dirname_z[current_dir.len] = 0;

        const dir = c.opendir(&dirname_z) orelse return error.Aborted;
        defer _ = c.closedir(dir);

        while (c.readdir(dir)) |entry_raw| {
            const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
            const name = mem.sliceTo(&entry.name, 0);

            // Skip . and ..
            if (shouldSkipFile(name, component, 0)) continue;

            // Match against component pattern (use fast path for simple extensions)
            const matches = if (simple_ext) |ext|
                simdSuffixMatch(name, ext)
            else
                fnmatch(component, name);

            if (matches) {
                // For non-final components, only traverse directories
                if (!is_final and entry.type != DT_DIR) continue;

                // For final component with directories_only flag, only keep directories
                if (is_final and directories_only and entry.type != DT_DIR) continue;

                // Build new path
                var new_path_buf: [4096]u8 = undefined;
                const new_path = buildPathInBuffer(&new_path_buf, current_dir, name);

                if (new_path.len >= 4096) continue;

                // Recurse with next component
                try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only);
            }
        }
    } else {
        // Literal component - just check if it exists
        var new_path_buf: [4096]u8 = undefined;
        const new_path = buildPathInBuffer(&new_path_buf, current_dir, component);

        if (new_path.len >= 4096) return;

        // Check if path exists and is appropriate type
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
            try expandWildcardComponents(allocator, new_path, components, component_idx + 1, results, directories_only);
        }
    }
}

fn globSingle(allocator: std.mem.Allocator, pattern: []const u8, flags: c_int, pglob: *glob_t) c_int {
    // Check for trailing slash (indicates "directories only")
    var effective_pattern = pattern;
    var effective_flags = flags;

    if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
        effective_flags |= GLOB_ONLYDIR;
        effective_pattern = pattern[0 .. pattern.len - 1];

        // Handle special case: pattern is just "/"
        if (effective_pattern.len == 0) {
            effective_pattern = ".";
        }
    }

    // Extract pattern info for optimization (will set info.directories_only from GLOB_ONLYDIR flag)
    const info = extractLiteralPrefix(effective_pattern, effective_flags);

    // Fast path: simple pattern with literal prefix (e.g., "src/foo/*.txt")
    if (info.simple_extension != null and info.literal_prefix.len > 0) {
        return globInDirFiltered(allocator, info.wildcard_suffix, info.literal_prefix, effective_flags, pglob, info.directories_only);
    }

    // Check for ** recursive glob FIRST before parsing dirname
    if (mem.indexOf(u8, effective_pattern, "**")) |double_star_pos| {
        // Find the last slash BEFORE ** to get the directory prefix
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

        return globRecursive(allocator, pattern_from_doublestar, dirname, effective_flags, pglob, info.directories_only);
    }

    // Check if pattern has wildcards in directory components (before last slash)
    // If yes, need recursive directory expansion (slow path)
    // Find last slash
    var last_slash_pos: usize = 0;
    var i: usize = effective_pattern.len;
    while (i > 0) {
        i -= 1;
        if (effective_pattern[i] == '/') {
            last_slash_pos = i;
            break;
        }
    }

    // Check if there are wildcards before the last slash
    var has_wildcard_in_dir = false;
    if (last_slash_pos > 0) {
        for (effective_pattern[0..last_slash_pos]) |ch| {
            if (ch == '*' or ch == '?' or ch == '[') {
                has_wildcard_in_dir = true;
                break;
            }
        }
    }

    // Use recursive wildcard expansion for complex patterns
    // But skip if pattern has ** (needs special recursive handling)
    if (has_wildcard_in_dir and !info.has_recursive) {
        return globWithWildcardDirsOptimized(allocator, effective_pattern, &info, effective_flags, pglob, info.directories_only);
    }

    // Parse directory and pattern (fast path for simple patterns)
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

    // Check for recursive glob **
    if (mem.indexOf(u8, filename_pattern, "**")) |_| {
        return globRecursive(allocator, filename_pattern, dirname, effective_flags, pglob, info.directories_only);
    }

    return globInDirFiltered(allocator, filename_pattern, dirname, effective_flags, pglob, info.directories_only);
}

// Helper to expand tilde (~) in patterns
fn expandTilde(allocator: std.mem.Allocator, pattern: [:0]const u8, flags: c_int) ![:0]const u8 {
    if (pattern.len == 0 or pattern[0] != '~') {
        return pattern; // No tilde, return as-is
    }

    // Find end of username (slash or end of string)
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
            // Username too long
            if (flags & GLOB_TILDE_CHECK != 0) {
                return error.NoMatch;
            }
            break :blk null;
        }
        @memcpy(username_z[0..username.len], username);
        username_z[username.len] = 0;

        const pw_entry = pwd.getpwnam(&username_z);
        if (pw_entry == null) {
            // User not found
            if (flags & GLOB_TILDE_CHECK != 0) {
                return error.NoMatch;
            }
            break :blk null;
        }

        // Return home directory from passwd entry
        const home_cstr = pw_entry.*.pw_dir;
        if (home_cstr == null) {
            if (flags & GLOB_TILDE_CHECK != 0) {
                return error.NoMatch;
            }
            break :blk null;
        }
        break :blk mem.sliceTo(home_cstr, 0);
    };

    if (home_dir) |home| {
        // Build new pattern: home + rest_of_pattern (with sentinel)
        const rest = pattern[username_end..];
        const new_pattern = try allocator.allocSentinel(u8, home.len + rest.len, 0);
        @memcpy(new_pattern[0..home.len], home);
        @memcpy(new_pattern[home.len..][0..rest.len], rest);
        return new_pattern;
    }

    // No home directory found - return pattern as-is (literal ~)
    return pattern;
}

pub fn glob(allocator: std.mem.Allocator, pattern: [*:0]const u8, flags: c_int, errfunc: ?*const anyopaque, pglob: *glob_t) c_int {
    _ = errfunc;

    if (flags & GLOB_APPEND == 0) {
        pglob.gl_pathc = 0;
        pglob.gl_pathv = null;
        // Initialize gl_offs if not using GLOB_DOOFFS
        if (flags & GLOB_DOOFFS == 0) {
            pglob.gl_offs = 0;
        }
    }

    var pattern_slice = mem.sliceTo(pattern, 0);
    const original_pattern_ptr = pattern_slice.ptr;

    // Handle tilde expansion if GLOB_TILDE is set
    var expanded_pattern: ?[:0]const u8 = null;
    defer if (expanded_pattern) |exp| {
        // Only free if we allocated a new pattern (not the original)
        if (exp.ptr != original_pattern_ptr) {
            // Free sentinel-terminated string
            const exp_mem = @as([*]const u8, exp.ptr)[0 .. exp.len + 1];
            allocator.free(exp_mem);
        }
    };

    if (flags & GLOB_TILDE != 0) {
        expanded_pattern = expandTilde(allocator, pattern_slice, flags) catch |err| {
            if (err == error.NoMatch) return GLOB_NOMATCH;
            return GLOB_NOSPACE;
        };
        pattern_slice = expanded_pattern.?;
    }

    // Handle brace expansion if GLOB_BRACE is set
    if (flags & GLOB_BRACE != 0) {
        var expanded = NameArray.init(allocator);
        defer {
            for (expanded.items[0..expanded.len]) |item| {
                const item_mem = mem.sliceTo(item, 0);
                allocator.free(item_mem);
            }
            expanded.deinit();
        }

        expandBraces(allocator, pattern_slice, &expanded) catch return GLOB_NOSPACE;

        // Glob each expanded pattern
        var first = true;
        for (expanded.items[0..expanded.len]) |exp_pattern| {
            const exp_slice = mem.sliceTo(exp_pattern, 0);
            const result = globSingle(allocator, exp_slice, if (first) flags else flags | GLOB_APPEND, pglob);

            if (result != 0 and result != GLOB_NOMATCH) {
                return result;
            }
            first = false;
        }

        if (pglob.gl_pathc == 0) {
            return GLOB_NOMATCH;
        }
        return 0;
    }

    return globSingle(allocator, pattern_slice, flags, pglob);
}

// Pattern components for recursive glob
const RecursivePattern = struct {
    dir_components: []const []const u8,  // Directory components to match (e.g., [".glob_test_nested"])
    file_pattern: []const u8,             // Final filename pattern (e.g., "*.txt")
};

// Recursive glob implementation for ** patterns
fn globRecursive(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: c_int, pglob: *glob_t, directories_only: bool) c_int {
    // Extract pattern info for optimization (will set directories_only from GLOB_ONLYDIR flag)
    const info = extractLiteralPrefix(pattern, flags);

    // Split pattern at **
    const double_star_pos = mem.indexOf(u8, pattern, "**") orelse return globInDirFiltered(allocator, pattern, dirname, flags, pglob, directories_only);

    // Get the pattern after **
    var after_double_star = pattern[double_star_pos + 2 ..];

    // Skip leading slash if present
    if (after_double_star.len > 0 and after_double_star[0] == '/') {
        after_double_star = after_double_star[1..];
    }

    // If ** is at the end, match everything recursively
    if (after_double_star.len == 0) {
        after_double_star = "*";
    }

    // Start from literal prefix if available
    const start_dir = if (info.literal_prefix.len > 0)
        info.literal_prefix
    else
        dirname;

    // Parse pattern once: split into directory components and filename pattern
    // For pattern like ".glob_test_nested/*.txt", we get:
    //   dir_components = [".glob_test_nested"]
    //   file_pattern = "*.txt"
    var dir_components_buf: [32][]const u8 = undefined;
    var dir_component_count: usize = 0;
    var file_pattern = after_double_star;

    // Find the last slash to separate directory path from filename pattern
    if (mem.lastIndexOf(u8, after_double_star, "/")) |last_slash| {
        file_pattern = after_double_star[last_slash + 1 ..];
        const dir_path = after_double_star[0..last_slash];

        // Split directory path by '/'
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
        // Add last component
        if (start < dir_path.len and dir_component_count < 32) {
            dir_components_buf[dir_component_count] = dir_path[start..];
            dir_component_count += 1;
        }
    }

    const rec_pattern = RecursivePattern{
        .dir_components = dir_components_buf[0..dir_component_count],
        .file_pattern = file_pattern,
    };

    // Helper function to recursively glob a directory
    return globRecursiveHelper(allocator, &rec_pattern, start_dir, flags, pglob, 0, &info);
}

fn globRecursiveHelper(allocator: std.mem.Allocator, rec_pattern: *const RecursivePattern, dirname: []const u8, flags: c_int, pglob: *glob_t, depth: usize, info: *const PatternInfo) c_int {
    // Limit recursion depth to prevent stack overflow
    if (depth > 100) return 0;

    // Early exit if this directory can't possibly match
    if (!canMatchPattern(dirname, depth, info)) {
        return 0;
    }

    // Only match files if we've reached the literal prefix
    const should_match_here = if (info.literal_prefix.len > 0)
        mem.startsWith(u8, dirname, info.literal_prefix) and
            (dirname.len >= info.literal_prefix.len)
    else
        true;

    // Match files in current directory if we have no more directory components to match
    if (should_match_here and rec_pattern.dir_components.len == 0) {
        // Always use APPEND flag for recursive helper to accumulate results
        // The initial call from globRecursive will pass clean pglob
        const match_flags = if (depth > 0 or pglob.gl_pathc > 0)
            flags | GLOB_APPEND
        else
            flags;

        const result = globInDirFiltered(allocator, rec_pattern.file_pattern, dirname, match_flags, pglob, info.directories_only);

        // Continue even if glob fails - we still want to recurse into subdirectories
        // Only fatal errors should stop us
        if (result == GLOB_NOSPACE) {
            return result;
        }
        // If first call returned GLOB_NOMATCH, initialize pglob so APPEND works
        if (result == GLOB_NOMATCH and depth == 0 and pglob.gl_pathc == 0) {
            pglob.gl_pathv = null;
        }
        // Ignore other errors like GLOB_ABORTED or GLOB_NOMATCH and continue recursing
    }

    // Open directory to find subdirectories
    var dirname_z: [4096:0]u8 = undefined;
    @memcpy(dirname_z[0..dirname.len], dirname);
    dirname_z[dirname.len] = 0;

    const dir = c.opendir(&dirname_z) orelse return 0;
    defer _ = c.closedir(dir);

    // Recursively search subdirectories
    while (c.readdir(dir)) |entry_raw| {
        const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
        const name = mem.sliceTo(&entry.name, 0);

        // Skip . and ..
        if (name.len == 0 or name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) {
            continue;
        }

        // Skip hidden files/directories unless GLOB_PERIOD is set or pattern explicitly starts with '.'
        if (name[0] == '.') {
            // Allow if GLOB_PERIOD flag is set
            if (flags & GLOB_PERIOD != 0) {
                // GLOB_PERIOD allows wildcards to match hidden files
            } else if (rec_pattern.dir_components.len > 0 and rec_pattern.dir_components[0].len > 0 and rec_pattern.dir_components[0][0] == '.') {
                // First directory component explicitly starts with '.' (e.g., ".glob_test_nested")
            } else if (rec_pattern.dir_components.len == 0 and rec_pattern.file_pattern.len > 0 and rec_pattern.file_pattern[0] == '.') {
                // File pattern explicitly starts with '.' (e.g., ".hidden")
            } else {
                // Skip hidden directories by default
                continue;
            }
        }

        // Check if it's a directory (with fallback to stat if d_type unknown)
        var is_dir = entry.type == DT_DIR;
        if (entry.type == DT_UNKNOWN) {
            // Fallback to stat for filesystems that don't support d_type
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
            // If we have directory components, check if this directory matches the next component
            var next_rec_pattern = rec_pattern.*;
            if (rec_pattern.dir_components.len > 0) {
                const next_component = rec_pattern.dir_components[0];

                // Check if directory name matches the component (could be wildcard pattern)
                if (!fnmatch(next_component, name)) {
                    continue; // Doesn't match, skip this directory
                }

                // Match! Advance to next component
                next_rec_pattern.dir_components = rec_pattern.dir_components[1..];
            }

            // Build subdirectory path
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

            // Smart filtering: only recurse if this path can match the pattern
            if (!canMatchPattern(subdir, depth + 1, info)) continue;

            // Recursively glob subdirectory with remaining pattern components
            const sub_result = globRecursiveHelper(allocator, &next_rec_pattern, subdir, flags, pglob, depth + 1, info);
            if (sub_result != 0 and sub_result != GLOB_NOMATCH) {
                return sub_result;
            }
        }
    }

    return 0;
}

// Helper to check if filename should be skipped (returns true to skip)
inline fn shouldSkipFile(name: []const u8, pattern: []const u8, flags: c_int) bool {
    if (name.len == 0) return true;

    const first_byte = name[0];
    if (first_byte == '.') {
        // Check for "." and ".." using branchless comparison
        const is_dot = name.len == 1;
        const is_dotdot = name.len == 2 and name[1] == '.';

        // Don't skip if pattern explicitly asks for "." or ".."
        if (is_dot or is_dotdot) {
            if (mem.eql(u8, name, pattern)) return false;
            return true;
        }

        // GLOB_PERIOD: allow wildcards to match hidden files
        if (flags & GLOB_PERIOD != 0) return false;

        // Skip hidden files unless pattern starts with '.'
        if (pattern.len > 0 and pattern[0] != '.') return true;
    }
    return false;
}

// Helper to check if path is a directory and append '/' if GLOB_MARK is set
inline fn maybeAppendSlash(allocator: std.mem.Allocator, path: [*c]u8, path_len: usize, is_dir: bool, flags: c_int) !?[*c]u8 {
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

// Wrapper that filters results to directories only if needed (uses d_type - avoids stat!)
fn globInDirFiltered(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: c_int, pglob: *glob_t, directories_only: bool) c_int {
    // Use optimized implementation that checks d_type during directory reading
    // This avoids expensive stat() calls - only falls back to stat if d_type == DT_UNKNOWN (rare)
    return globInDirImpl(allocator, pattern, dirname, flags, pglob, directories_only);
}

fn globInDir(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: c_int, pglob: *glob_t) c_int {
    return globInDirImpl(allocator, pattern, dirname, flags, pglob, false);
}

// Implementation with optional directory filtering using d_type (avoids stat calls)
fn globInDirImpl(allocator: std.mem.Allocator, pattern: []const u8, dirname: []const u8, flags: c_int, pglob: *glob_t, directories_only: bool) c_int {
    // Pre-compute pattern properties once to avoid redundant hasWildcardsSIMD calls in hot loop
    const pattern_ctx = PatternContext.init(pattern);

    // Open directory
    var dirname_z: [4096:0]u8 = undefined;
    @memcpy(dirname_z[0..dirname.len], dirname);
    dirname_z[dirname.len] = 0;

    const dir = c.opendir(&dirname_z) orelse return GLOB_ABORTED;
    defer _ = c.closedir(dir);

    // Zig-style array with allocator
    var names = NameArray.init(allocator);
    defer names.deinit();

    // Batch processing buffer for parallel matching
    const BatchSize = 4;
    var batch_names: [BatchSize][]const u8 = undefined;
    var batch_entries: [BatchSize]*const dirent = undefined;
    var batch_count: usize = 0;

    // Read entries with batching
    while (c.readdir(dir)) |entry_raw| {
        const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
        const name = mem.sliceTo(&entry.name, 0);

        // Skip check using inlined function
        if (shouldSkipFile(name, pattern, flags)) continue;

        // Add to bach
        batch_names[batch_count] = name;
        batch_entries[batch_count] = entry;
        batch_count += 1;

        // Process batch when full
        if (batch_count == BatchSize) {
            // SIMD-accelerated parallel matching using mask with pre-computed context
            var match_mask: u4 = 0;
            for (batch_names[0..batch_count], 0..) |bname, i| {
                if (fnmatchWithContext(&pattern_ctx, bname)) {
                    match_mask |= @as(u4, 1) << @intCast(i);
                }
            }

            // Process matches
            for (0..batch_count) |i| {
                if ((match_mask & (@as(u4, 1) << @intCast(i))) != 0) {
                    // Use d_type to filter directories if needed (avoids stat syscall!)
                    if (directories_only) {
                        const entry_dtype = batch_entries[i].type;
                        // Skip non-directories (d_type == DT_DIR is 4 on Linux)
                        if (entry_dtype != DT_DIR and entry_dtype != DT_UNKNOWN) continue;
                        // If DT_UNKNOWN, we'll do stat check below (rare on modern filesystems)
                    }

                    const name_to_add = batch_names[i];
                    // Build full path with allocator
                    const path_len = if (dirname.len > 0 and !mem.eql(u8, dirname, "."))
                        dirname.len + 1 + name_to_add.len
                    else
                        name_to_add.len;
                    const path_buf_slice = allocator.allocSentinel(u8, path_len, 0) catch return GLOB_NOSPACE;
                    var path: [*c]u8 = @ptrCast(path_buf_slice.ptr);

                    if (dirname.len > 0 and !mem.eql(u8, dirname, ".")) {
                        @memcpy(path_buf_slice[0..dirname.len], dirname);
                        path_buf_slice[dirname.len] = '/';
                        @memcpy(path_buf_slice[dirname.len + 1 ..][0..name_to_add.len], name_to_add);
                    } else {
                        @memcpy(path_buf_slice[0..name_to_add.len], name_to_add);
                    }

                    // Check if it's a directory for GLOB_MARK or directories_only
                    var is_dir = batch_entries[i].type == DT_DIR;
                    if (batch_entries[i].type == DT_UNKNOWN) {
                        var stat_buf: std.c.Stat = undefined;
                        if (std.c.stat(path, &stat_buf) == 0) {
                            is_dir = std.c.S.ISDIR(stat_buf.mode);
                        } else {
                            allocator.free(path_buf_slice);
                            continue;
                        }
                    }

                    // Skip non-directories if directories_only
                    if (directories_only and !is_dir) {
                        allocator.free(path_buf_slice);
                        continue;
                    }

                    // Append '/' to directories if GLOB_MARK is set
                    if (maybeAppendSlash(allocator, path, path_len, is_dir, flags) catch {
                        allocator.free(path_buf_slice);
                        return GLOB_NOSPACE;
                    }) |new_path| {
                        path = new_path;
                    }

                    names.append(path) catch return GLOB_NOSPACE;
                }
            }
            batch_count = 0;
        }
    }

    // Process remaining batch
    if (batch_count > 0) {
        for (batch_names[0..batch_count], 0..) |name, i| {
            if (fnmatchWithContext(&pattern_ctx, name)) {
                // Use d_type to filter directories if needed (avoids stat syscall!)
                if (directories_only) {
                    const entry_dtype = batch_entries[i].type;
                    if (entry_dtype != DT_DIR and entry_dtype != DT_UNKNOWN) continue;
                }

                // Build full path with allocator
                const path_len = if (dirname.len > 0 and !mem.eql(u8, dirname, "."))
                    dirname.len + 1 + name.len
                else
                    name.len;
                const path_buf_slice = allocator.allocSentinel(u8, path_len, 0) catch return GLOB_NOSPACE;
                var path: [*c]u8 = @ptrCast(path_buf_slice.ptr);

                if (dirname.len > 0 and !mem.eql(u8, dirname, ".")) {
                    @memcpy(path_buf_slice[0..dirname.len], dirname);
                    path_buf_slice[dirname.len] = '/';
                    @memcpy(path_buf_slice[dirname.len + 1 ..][0..name.len], name);
                } else {
                    @memcpy(path_buf_slice[0..name.len], name);
                }

                // Check if it's a directory for GLOB_MARK or directories_only
                var is_dir = batch_entries[i].type == DT_DIR;
                if (batch_entries[i].type == DT_UNKNOWN) {
                    var stat_buf: std.c.Stat = undefined;
                    if (std.c.stat(path, &stat_buf) == 0) {
                        is_dir = std.c.S.ISDIR(stat_buf.mode);
                    } else {
                        allocator.free(path_buf_slice);
                        continue;
                    }
                }

                // Skip non-directories if directories_only
                if (directories_only and !is_dir) {
                    allocator.free(path_buf_slice);
                    continue;
                }

                // Append '/' to directories if GLOB_MARK is set
                if (maybeAppendSlash(allocator, path, path_len, is_dir, flags) catch {
                    allocator.free(path_buf_slice);
                    return GLOB_NOSPACE;
                }) |new_path| {
                    path = new_path;
                }

                names.append(path) catch return GLOB_NOSPACE;
            }
        }
    }

    // Handle no matches
    if (names.len == 0) {
        if (flags & GLOB_NOCHECK != 0) {
            const pat_copy = allocator.allocSentinel(u8, pattern.len, 0) catch return GLOB_NOSPACE;
            @memcpy(pat_copy[0..pattern.len], pattern);
            const path: [*c]u8 = @ptrCast(pat_copy.ptr);

            const pathv_buf = allocator.alloc([*c]u8, 2) catch return GLOB_NOSPACE;
            const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);
            result[0] = path;
            result[1] = null;

            pglob.gl_pathc = 1;
            pglob.gl_pathv = result;
            return 0;
        }
        return GLOB_NOMATCH;
    }

    // Sort unless NOSORT
    if (flags & GLOB_NOSORT == 0) {
        qsort(@ptrCast(names.items), names.len, @sizeOf([*c]u8), c_cmp_strs);
    }

    // Handle GLOB_APPEND flag - merge with existing results
    if (flags & GLOB_APPEND != 0 and pglob.gl_pathv != null and pglob.gl_pathc > 0) {
        const old_count = pglob.gl_pathc;
        const new_count = names.len;
        const total_count = old_count + new_count;
        const offs = if (flags & GLOB_DOOFFS != 0) pglob.gl_offs else 0;

        // Allocate new array: offs + old + new + null terminator
        const pathv_buf = allocator.alloc([*c]u8, offs + total_count + 1) catch return GLOB_NOSPACE;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        // Fill offset slots with NULL (if GLOB_DOOFFS)
        var k: usize = 0;
        while (k < offs) : (k += 1) {
            result[k] = null;
        }

        // Copy old results (they already account for offset from first glob)
        var i: usize = 0;
        while (i < old_count) : (i += 1) {
            result[offs + i] = pglob.gl_pathv[offs + i];
        }

        // Append new results
        var j: usize = 0;
        while (j < new_count) : (j += 1) {
            result[offs + old_count + j] = names.items[j];
        }
        result[offs + total_count] = null;

        // Free old pathv array (but not the strings inside - they're still referenced)
        const old_pathv_slice = @as([*][*c]u8, @ptrCast(pglob.gl_pathv))[0 .. offs + old_count + 1];
        allocator.free(old_pathv_slice);

        pglob.gl_pathc = total_count;
        pglob.gl_pathv = result;
    } else {
        // No APPEND or first call - allocate fresh result array
        const offs = if (flags & GLOB_DOOFFS != 0) pglob.gl_offs else 0;
        const pathv_buf = allocator.alloc([*c]u8, offs + names.len + 1) catch return GLOB_NOSPACE;
        const result: [*c][*c]u8 = @ptrCast(pathv_buf.ptr);

        // Fill offset slots with NULL (if GLOB_DOOFFS)
        var k: usize = 0;
        while (k < offs) : (k += 1) {
            result[k] = null;
        }

        // Copy matches starting after offset
        var i: usize = 0;
        while (i < names.len) : (i += 1) {
            result[offs + i] = names.items[i];
        }
        result[offs + names.len] = null;

        pglob.gl_pathc = names.len;
        pglob.gl_pathv = result;
    }

    return 0;
}

// SIMD wildcard detection
fn hasWildcardsSIMD(s: []const u8) bool {
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
        // Check remainder
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

// SIMD suffix comparison for *.ext patterns
fn simdSuffixMatch(string: []const u8, suffix: []const u8) bool {
    if (string.len < suffix.len) return false;
    const start = string.len - suffix.len;
    const tail = string[start..];

    // SIMD comparison for longer suffixes
    if (suffix.len >= 16) {
        const Vec16 = @Vector(16, u8);
        var i: usize = 0;
        while (i + 16 <= suffix.len) : (i += 16) {
            const s_vec: Vec16 = tail[i..][0..16].*;
            const p_vec: Vec16 = suffix[i..][0..16].*;
            const eq = s_vec == p_vec;
            const mask = @as(u16, @bitCast(eq));
            if (mask != 0xFFFF) return false;
        }
        // Check remainder
        return mem.eql(u8, tail[i..], suffix[i..]);
    }
    return mem.eql(u8, tail, suffix);
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
        // Check remainder
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
inline fn fnmatchWithContext(ctx: *const PatternContext, string: []const u8) bool {
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

    // Fast path: *.ext (most common) with SIMD - use pre-computed check
    if (ctx.is_simple_star_ext) {
        return simdSuffixMatch(string, ctx.simple_ext);
    }

    return fnmatchFull(ctx.pattern, string);
}

// SIMD-optimized fnmatch (public API - for backward compatibility)
pub fn fnmatch(pattern: []const u8, string: []const u8) bool {
    // Fast path: exact match with SIMD for long strings (only if no wildcards)
    if (pattern.len == string.len and !hasWildcardsSIMD(pattern)) {
        if (pattern.len >= 32) {
            const Vec32 = @Vector(32, u8);
            var i: usize = 0;
            while (i + 32 <= pattern.len) : (i += 32) {
                const p_vec: Vec32 = pattern[i..][0..32].*;
                const s_vec: Vec32 = string[i..][0..32].*;
                const eq = p_vec == s_vec;
                const mask = @as(u32, @bitCast(eq));
                if (mask != 0xFFFFFFFF) return false;
            }
            return mem.eql(u8, pattern[i..], string[i..]);
        }
        return mem.eql(u8, pattern, string);
    }

    // Fast path: *.ext (most common) with SIMD
    if (pattern.len >= 2 and pattern[0] == '*') {
        if (!hasWildcardsSIMD(pattern[1..])) {
            return simdSuffixMatch(string, pattern[1..]);
        }
    }

    return fnmatchFull(pattern, string);
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

                // Skip closing ']'
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

pub fn globfree(allocator: std.mem.Allocator, pglob: *glob_t) void {
    if (pglob.gl_pathv) |pathv| {
        // gl_offs might be uninitialized if GLOB_DOOFFS wasn't used - treat as 0
        const offs = pglob.gl_offs;

        // Free actual paths (starting from offset)
        var i: usize = 0;
        while (i < pglob.gl_pathc) : (i += 1) {
            if (pathv[offs + i]) |path| {
                // Free sentinel-terminated string (includes sentinel)
                const path_len = mem.len(path);
                const path_slice = @as([*]u8, @ptrCast(path))[0 .. path_len + 1];
                allocator.free(path_slice);
            }
        }
        // Free the pathv array including offset slots
        const pathv_slice = @as([*][*c]u8, @ptrCast(pathv))[0 .. offs + pglob.gl_pathc + 1];
        allocator.free(pathv_slice);
    }
    pglob.gl_pathv = null;
    pglob.gl_pathc = 0;
}
