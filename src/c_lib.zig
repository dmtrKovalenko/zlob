const std = @import("std");
const zlob_impl = @import("zlob");

const mem = std.mem;

pub const zlob_t = zlob_impl.zlob_t;
pub const zlob_dirent_t = zlob_impl.zlob_dirent_t;
pub const DirIterator = zlob_impl.DirIterator;

/// Zig or Rust compatible string slice type
/// which makes FFI code execute signficantly faster than using C-style null-terminated strings
/// at a cost of relying on the unstable Rust/Zig ABI compatiblitiy.
///
/// Meaning that any api that is accepting this type may break in any future version of Zig or Rust
/// but it comes with a significant 15% performance boost for some hot paths so it may be worth the risk
pub const zlob_slice_t = extern struct {
    ptr: [*]const u8,
    len: usize,
};

// Re-export flags from zlob module
pub const ZlobFlags = zlob_impl.ZlobFlags;

// Standard POSIX glob flags
pub const ZLOB_ERR = zlob_impl.ZLOB_ERR;
pub const ZLOB_MARK = zlob_impl.ZLOB_MARK;
pub const ZLOB_NOSORT = zlob_impl.ZLOB_NOSORT;
pub const ZLOB_DOOFFS = zlob_impl.ZLOB_DOOFFS;
pub const ZLOB_NOCHECK = zlob_impl.ZLOB_NOCHECK;
pub const ZLOB_APPEND = zlob_impl.ZLOB_APPEND;
pub const ZLOB_NOESCAPE = zlob_impl.ZLOB_NOESCAPE;
pub const ZLOB_PERIOD = zlob_impl.ZLOB_PERIOD;

pub const ZLOB_MAGCHAR = zlob_impl.ZLOB_MAGCHAR;
pub const ZLOB_ALTDIRFUNC = zlob_impl.ZLOB_ALTDIRFUNC;
pub const ZLOB_BRACE = zlob_impl.ZLOB_BRACE;
pub const ZLOB_NOMAGIC = zlob_impl.ZLOB_NOMAGIC;
pub const ZLOB_TILDE = zlob_impl.ZLOB_TILDE;
pub const ZLOB_ONLYDIR = zlob_impl.ZLOB_ONLYDIR;
pub const ZLOB_TILDE_CHECK = zlob_impl.ZLOB_TILDE_CHECK;

pub const ZLOB_GITIGNORE = zlob_impl.ZLOB_GITIGNORE;
pub const ZLOB_DOUBLESTAR_RECURSIVE = zlob_impl.ZLOB_DOUBLESTAR_RECURSIVE;
pub const ZLOB_EXTGLOB = zlob_impl.ZLOB_EXTGLOB;
pub const ZLOB_RECOMMENDED = zlob_impl.ZLOB_RECOMMENDED;

pub const ZLOB_NOSPACE = zlob_impl.ZLOB_NOSPACE;
pub const ZLOB_ABORTED = zlob_impl.ZLOB_ABORTED;
pub const ZLOB_NOMATCH = zlob_impl.ZLOB_NOMATCH;

const ZLOB_FLAGS_SHARED_STRINGS = zlob_impl.ZLOB_FLAGS_SHARED_STRINGS;

pub fn zlob(pattern: [*:0]const u8, flags: c_int, errfunc: zlob_impl.zlob_errfunc_t, pzlob: *zlob_t) callconv(.c) c_int {
    const allocator = std.heap.c_allocator;

    if (zlob_impl.glob(allocator, pattern, flags, errfunc, pzlob)) |opt_result| {
        if (opt_result) |_| {
            return 0; // Success with matches
        } else {
            return ZLOB_NOMATCH; // No matches
        }
    } else |err| {
        return switch (err) {
            error.OutOfMemory => ZLOB_NOSPACE,
            error.Aborted => ZLOB_ABORTED,
        };
    }
}

pub fn zlobfree(pzlob: *zlob_t) callconv(.c) void {
    zlob_impl.globfreeInternal(std.heap.c_allocator, pzlob);
}

// pub functions avaialble as C symbols
comptime {
    @export(&zlob, .{ .name = "zlob" });
    @export(&zlobfree, .{ .name = "zlobfree" });
}

/// Glob within a specific base directory.
/// base_path must be an absolute path (starts with '/'), otherwise returns ZLOB_ABORTED.
/// This is the C-compatible version of globAt().
pub fn zlob_at(
    base_path: [*:0]const u8,
    pattern: [*:0]const u8,
    flags: c_int,
    errfunc: zlob_impl.zlob_errfunc_t,
    pzlob: *zlob_t,
) callconv(.c) c_int {
    const allocator = std.heap.c_allocator;
    const base_slice = mem.sliceTo(base_path, 0);

    if (zlob_impl.globAt(allocator, base_slice, pattern, flags, errfunc, pzlob)) |opt_result| {
        if (opt_result) |_| {
            return 0; // Success with matches
        } else {
            return ZLOB_NOMATCH; // No matches
        }
    } else |err| {
        return switch (err) {
            error.OutOfMemory => ZLOB_NOSPACE,
            error.Aborted => ZLOB_ABORTED,
        };
    }
}

// Export zlob_at
comptime {
    @export(&zlob_at, .{ .name = "zlob_at" });
}

/// Extnesion to the standard C api allowing to match the pattern against the flat list of paths
/// and do not access the filesystem at all.
pub export fn zlob_match_paths(
    pattern: [*:0]const u8,
    paths: [*]const [*:0]const u8,
    path_count: usize,
    flags: c_int,
    pzlob: *zlob_t,
) c_int {
    const allocator = std.heap.c_allocator;

    const pattern_slice = mem.sliceTo(pattern, 0);

    const STACK_LIMIT = 256;
    var stack_buf: [STACK_LIMIT][]const u8 = undefined;
    const zig_paths_storage = if (path_count <= STACK_LIMIT)
        stack_buf[0..path_count]
    else
        allocator.alloc([]const u8, path_count) catch return ZLOB_NOSPACE;
    defer if (path_count > STACK_LIMIT) allocator.free(zig_paths_storage);

    for (0..path_count) |i| {
        zig_paths_storage[i] = mem.sliceTo(paths[i], 0);
    }

    var results = zlob_impl.path_matcher.matchPaths(allocator, pattern_slice, zig_paths_storage, @intCast(flags)) catch |err| {
        return switch (err) {
            error.OutOfMemory => ZLOB_NOSPACE,
        };
    };
    defer results.deinit();

    if (results.match_count == 0) {
        return ZLOB_NOMATCH;
    }

    const pathv_buf = allocator.alloc([*c]u8, results.match_count + 1) catch return ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, results.match_count) catch {
        allocator.free(pathv_buf);
        return ZLOB_NOSPACE;
    };

    for (results.paths, 0..) |path, i| {
        pathv_buf[i] = @ptrCast(@constCast(path.ptr));
        pathlen_buf[i] = path.len;
    }
    pathv_buf[results.match_count] = null;

    pzlob.zlo_pathc = results.match_count;
    pzlob.zlo_pathv = @ptrCast(pathv_buf.ptr);
    pzlob.zlo_offs = 0;
    pzlob.zlo_pathlen = pathlen_buf.ptr;
    pzlob.zlo_flags = ZLOB_FLAGS_SHARED_STRINGS;

    return 0;
}

/// The same as `zlob_match_paths` but using specific string slice type with a known length.
/// Used primarily for FFI compatiblitiy with languates with normal string type as first-class citizens.
pub export fn zlob_match_paths_slice(
    pattern: *const zlob_slice_t,
    paths: [*]const zlob_slice_t,
    path_count: usize,
    flags: c_int,
    pzlob: *zlob_t,
) c_int {
    const allocator = std.heap.c_allocator;
    const pattern_slice = pattern.ptr[0..pattern.len];

    // UNSAFE: Relies on Zig ABI compatibility
    const zig_paths: []const []const u8 = @ptrCast(paths[0..path_count]);

    var results = zlob_impl.path_matcher.matchPaths(allocator, pattern_slice, zig_paths, @intCast(flags)) catch |err| {
        return switch (err) {
            error.OutOfMemory => ZLOB_NOSPACE,
        };
    };
    defer results.deinit();

    if (results.match_count == 0) {
        return ZLOB_NOMATCH;
    }

    const pathv_buf = allocator.alloc([*c]u8, results.match_count + 1) catch return ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, results.match_count) catch {
        allocator.free(pathv_buf);
        return ZLOB_NOSPACE;
    };

    for (results.paths, 0..) |path, i| {
        pathv_buf[i] = @ptrCast(@constCast(path.ptr));
        pathlen_buf[i] = path.len;
    }
    pathv_buf[results.match_count] = null;

    pzlob.zlo_pathc = results.match_count;
    pzlob.zlo_pathv = @ptrCast(pathv_buf.ptr);
    pzlob.zlo_offs = 0;
    pzlob.zlo_pathlen = pathlen_buf.ptr;
    pzlob.zlo_flags = ZLOB_FLAGS_SHARED_STRINGS;

    return 0;
}
