const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const zlob_flags = @import("zlob_flags");

pub const ZlobFlags = zlob_flags.ZlobFlags;

// pwd.h is only available on POSIX systems
const pwd = if (builtin.os.tag != .windows) @cImport({
    @cInclude("pwd.h");
}) else struct {
    // Stub for Windows - these functions don't exist
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
        // ~username expansion - only supported on POSIX systems
        if (builtin.os.tag == .windows) {
            // Windows doesn't support ~username expansion
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

/// Get the current user's home directory.
/// On Windows, returns an allocated string that must be freed.
/// On POSIX, returns a borrowed slice from the environment.
fn getHomeDirectory(allocator: Allocator) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // On Windows, try USERPROFILE first, then HOMEDRIVE+HOMEPATH
        if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |user_profile| {
            return user_profile;
        } else |_| {
            // Try HOMEDRIVE + HOMEPATH
            const home_drive = std.process.getEnvVarOwned(allocator, "HOMEDRIVE") catch return null;
            defer allocator.free(home_drive);
            const home_path = std.process.getEnvVarOwned(allocator, "HOMEPATH") catch return null;
            defer allocator.free(home_path);

            // Concatenate HOMEDRIVE and HOMEPATH
            const combined = allocator.alloc(u8, home_drive.len + home_path.len) catch return null;
            @memcpy(combined[0..home_drive.len], home_drive);
            @memcpy(combined[home_drive.len..], home_path);
            return combined;
        }
    } else {
        return std.posix.getenv("HOME");
    }
}
