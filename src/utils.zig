const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const zlob_flags = @import("zlob_flags");

pub const ZlobFlags = zlob_flags.ZlobFlags;

/// Find the first index `i` such that `s[i] == '/' and s[i+1] == '/'`.
/// SIMD-accelerated lane-paired compare for inputs >= vec_len + 1.
inline fn indexOfDoubleSlash(s: []const u8) ?usize {
    if (s.len < 2) return null;

    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    const Vec = @Vector(vec_len, u8);
    const MaskInt = std.meta.Int(.unsigned, vec_len);
    const slash_vec: Vec = @splat('/');

    if (s.len >= vec_len + 1) {
        var i: usize = 0;
        while (i + vec_len + 1 <= s.len) : (i += vec_len) {
            const cur: Vec = s[i..][0..vec_len].*;
            const nxt: Vec = s[i + 1 ..][0..vec_len].*;
            const cur_mask = @as(MaskInt, @bitCast(cur == slash_vec));
            const nxt_mask = @as(MaskInt, @bitCast(nxt == slash_vec));
            const mask = cur_mask & nxt_mask;
            if (mask != 0) return i + @ctz(mask);
        }

        var j = i;
        while (j + 1 < s.len) : (j += 1) {
            if (s[j] == '/' and s[j + 1] == '/') return j;
        }
        return null;
    }

    var j: usize = 0;
    while (j + 1 < s.len) : (j += 1) {
        if (s[j] == '/' and s[j + 1] == '/') return j;
    }
    return null;
}

const is_windows = builtin.os.tag == .windows;

/// Collapse runs of `/` in `src` into a single `/` (output <= `src.len`, so
/// `dst.len >= src.len` suffices; in-place `dst.ptr == src.ptr` is safe).
/// On Windows `\\` is also treated as a separator and rewritten to `/`
/// (POSIX comptime-elides that branch). Fast path: no `//` run (and no `\\`
/// on Windows) → plain `@memcpy` / no-op.
pub fn normalizeSlashes(src: []const u8, dst: []u8) []const u8 {
    std.debug.assert(dst.len >= src.len);

    const first_dup = indexOfDoubleSlash(src);
    const first_back: ?usize = if (is_windows)
        std.mem.indexOfScalar(u8, src, '\\')
    else
        null;

    if (first_dup == null and first_back == null) {
        if (dst.ptr != src.ptr) @memcpy(dst[0..src.len], src);
        return dst[0..src.len];
    }

    // Slow path: copy the clean prefix, then process the rest with
    // combined `//` collapse and (Windows-only) `\\` → `/` rewrite.
    const start: usize = blk: {
        const d = first_dup orelse src.len;
        const b = first_back orelse src.len;
        break :blk @min(d, b);
    };

    if (dst.ptr != src.ptr and start > 0) {
        @memcpy(dst[0..start], src[0..start]);
    }

    // Prime prev_slash from the byte before `start` so a `\\` immediately
    // after a `/` (Windows) is treated as a continuation of the slash run.
    var w: usize = start;
    var prev_slash = if (start > 0) src[start - 1] == '/' else false;
    for (src[start..]) |c| {
        const ch: u8 = if (is_windows and c == '\\') '/' else c;
        const is_slash = ch == '/';
        const skip = is_slash and prev_slash;
        dst[w] = ch;
        w += @intFromBool(!skip);
        prev_slash = is_slash;
    }
    return dst[0..w];
}

/// Rewrite `\\` → `/` in `src` on Windows, returning either `src` itself
/// (if the input is already `\\`-free) or a freshly-rewritten slice in
/// `scratch`. POSIX always returns `src` (comptime no-op).
pub fn normalizePathSeparators(src: []const u8, scratch: []u8) []const u8 {
    if (comptime !is_windows) return src;
    if (std.mem.indexOfScalar(u8, src, '\\') == null) return src;
    if (src.len > scratch.len) return src;
    @memcpy(scratch[0..src.len], src);
    for (scratch[0..src.len]) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return scratch[0..src.len];
}

// pwd.h is only available on POSIX systems where libc headers are present.
// Excluded on: Windows (no pwd.h), Android (Zig can't provide bionic headers),
// and Apple mobile platforms (iOS/tvOS/watchOS/visionOS — Zig doesn't ship their SDK headers).
// Note: Zig force-enables link_libc for Darwin-based targets, so we must check os.tag directly.
const has_pwd = switch (builtin.os.tag) {
    .windows, .ios, .tvos, .watchos, .visionos => false,
    else => builtin.link_libc,
};
const pwd = if (has_pwd) @cImport({
    @cInclude("pwd.h");
}) else struct {
    // Stub for platforms without pwd.h (Windows, Android, Apple mobile, no-libc builds)
    pub const passwd = opaque {};
    pub fn getpwnam(_: anytype) ?*passwd {
        return null;
    }
};

/// Build a path from directory and name components into the provided buffer.
pub fn buildPathInBuffer(buf: []u8, dir: []const u8, name: []const u8) []const u8 {
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

pub const PathBuildResult = struct {
    ptr: [*c]u8,
    len: usize,
    buf: []u8,
};

/// Optimized path builder that pre-allocates space for trailing slash if ZLOB_MARK is set.
pub inline fn buildFullPathWithMark(
    allocator: Allocator,
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

    const final_len = if (needs_mark) blk: {
        path_buf_slice[base_len] = '/';
        path_buf_slice[base_len + 1] = 0;
        break :blk base_len + 1;
    } else base_len;

    return .{
        .ptr = @ptrCast(path_buf_slice.ptr),
        .len = final_len,
        .buf = path_buf_slice,
    };
}

/// Expand tilde (~) in patterns to home directory.
/// Returns null if ZLOB_TILDE_CHECK is set and expansion fails.
pub fn expandTilde(allocator: Allocator, pattern: [:0]const u8, flags: ZlobFlags) !?[:0]const u8 {
    if (pattern.len == 0 or pattern[0] != '~') {
        return pattern;
    }

    var username_end: usize = 1;
    while (username_end < pattern.len and pattern[username_end] != '/' and pattern[username_end] != '\\') : (username_end += 1) {}

    // Handle ~ (current user's home) vs ~username (other user's home)
    if (username_end == 1) {
        // Simple ~ expansion - get current user's home directory
        const home_dir = getHomeDirectory(allocator);
        if (home_dir) |home| {
            defer if (builtin.os.tag == .windows) allocator.free(home);
            const rest = pattern[username_end..];
            const new_pattern = try allocator.allocSentinel(u8, home.len + rest.len, 0);
            @memcpy(new_pattern[0..home.len], home);
            @memcpy(new_pattern[home.len..][0..rest.len], rest);
            return new_pattern;
        } else {
            if (flags.tilde_check) {
                return null;
            }
            return pattern;
        }
    } else {
        // ~username expansion - only supported on POSIX systems with libc (pwd.h)
        if (!has_pwd) {
            // No pwd.h support (Windows, Android, no-libc builds)
            if (flags.tilde_check) {
                return null;
            }
            return pattern;
        }

        const username = pattern[1..username_end];

        var username_z: [256]u8 = undefined;
        if (username.len >= 256) {
            if (flags.tilde_check) {
                return null;
            }
            return pattern;
        }
        @memcpy(username_z[0..username.len], username);
        username_z[username.len] = 0;

        const pw_entry = pwd.getpwnam(&username_z);
        if (pw_entry == null) {
            if (flags.tilde_check) {
                return null;
            }
            return pattern;
        }

        const home_cstr = pw_entry.*.pw_dir;
        if (home_cstr == null) {
            if (flags.tilde_check) {
                return null;
            }
            return pattern;
        }

        const home = mem.sliceTo(home_cstr, 0);
        const rest = pattern[username_end..];
        const new_pattern = try allocator.allocSentinel(u8, home.len + rest.len, 0);
        @memcpy(new_pattern[0..home.len], home);
        @memcpy(new_pattern[home.len..][0..rest.len], rest);
        return new_pattern;
    }
}

/// Look up an environment variable via libc's `getenv`, returning a borrowed
/// slice. Returns null if libc is not available, the variable is unset, or
/// the name cannot be null-terminated.
fn getEnvVarBorrowed(allocator: Allocator, name: []const u8) ?[]const u8 {
    if (!builtin.link_libc) return null;
    const name_z = allocator.dupeZ(u8, name) catch return null;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z.ptr) orelse return null;
    return mem.sliceTo(ptr, 0);
}

/// Get the current user's home directory.
/// On Windows, returns an allocated string that must be freed.
/// On POSIX, returns a borrowed slice from the environment.
fn getHomeDirectory(allocator: Allocator) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // On Windows, try USERPROFILE first, then HOMEDRIVE+HOMEPATH
        if (getEnvVarBorrowed(allocator, "USERPROFILE")) |user_profile| {
            return allocator.dupe(u8, user_profile) catch null;
        }

        const home_drive = getEnvVarBorrowed(allocator, "HOMEDRIVE") orelse return null;
        const home_path = getEnvVarBorrowed(allocator, "HOMEPATH") orelse return null;

        // Concatenate HOMEDRIVE and HOMEPATH
        const combined = allocator.alloc(u8, home_drive.len + home_path.len) catch return null;
        @memcpy(combined[0..home_drive.len], home_drive);
        @memcpy(combined[home_drive.len..], home_path);
        return combined;
    } else {
        return getEnvVarBorrowed(allocator, "HOME");
    }
}
