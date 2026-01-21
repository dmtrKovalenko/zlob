const std = @import("std");
const zlob_impl = @import("glob");

const mem = std.mem;

// Re-export for C API compatibility
pub const zlob_t = zlob_impl.zlob_t;

// FFI helper type for languages that support Zig ABI
pub const zlob_slice_t = extern struct {
    ptr: [*]const u8,
    len: usize,
};

// Re-export glob flags for tests
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

// Re-export error codes for tests
pub const ZLOB_NOSPACE = zlob_impl.ZLOB_NOSPACE;
pub const ZLOB_ABORTED = zlob_impl.ZLOB_ABORTED;
pub const ZLOB_NOMATCH = zlob_impl.ZLOB_NOMATCH;

// Internal constants
const ZLOB_FLAGS_SHARED_STRINGS = zlob_impl.ZLOB_FLAGS_SHARED_STRINGS;

// ============================================================================
// C API - POSIX-compatible glob functions
// ============================================================================

/// POSIX glob() - Match pattern against filesystem
///
/// This is the standard C-compatible glob function that uses c_allocator.
/// For Zig code with custom allocators, use the Zig API in lib.zig instead.
pub export fn glob(pattern: [*:0]const u8, flags: c_int, errfunc: zlob_impl.zlob_errfunc_t, pzlob: *zlob_t) c_int {
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

/// POSIX globfree() - Free memory allocated by glob()
///
/// This is the standard C-compatible globfree function.
pub export fn globfree(pzlob: *zlob_t) void {
    zlob_impl.globfreeInternal(std.heap.c_allocator, pzlob);
}

// ============================================================================
// Extended C API - Additional functionality
// ============================================================================

/// Match glob pattern against array of paths (C-compatible).
///
/// Populates zlob_t with matches found in the provided array of path strings.
/// The paths are owned by the caller and must remain valid until globfree() is called.
///
/// This is a zero-copy operation - the returned zlob_t points to caller's memory.
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

    var results = zlob_impl.internalMatchPaths(allocator, pattern_slice, zig_paths_storage, @intCast(flags)) catch |err| {
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

    pzlob.gl_pathc = results.match_count;
    pzlob.gl_pathv = @ptrCast(pathv_buf.ptr);
    pzlob.gl_offs = 0;
    pzlob.gl_pathlen = pathlen_buf.ptr;
    pzlob.gl_flags = ZLOB_FLAGS_SHARED_STRINGS;

    return 0;
}

/// Match glob pattern against array of paths (slice-based FFI).
///
/// This function uses Zig slices for pattern and paths, which relies on the
/// Zig ABI. Only use this from languages that understand Zig ABI (unstable).
///
/// For stable C API, use zlob_match_paths() instead.
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

    var results = zlob_impl.internalMatchPaths(allocator, pattern_slice, zig_paths, @intCast(flags)) catch |err| {
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

    pzlob.gl_pathc = results.match_count;
    pzlob.gl_pathv = @ptrCast(pathv_buf.ptr);
    pzlob.gl_offs = 0;
    pzlob.gl_pathlen = pathlen_buf.ptr;
    pzlob.gl_flags = ZLOB_FLAGS_SHARED_STRINGS;

    return 0;
}

// ============================================================================
// Version information
// ============================================================================

export const ZLOB_VERSION_MAJOR: c_int = 1;
export const ZLOB_VERSION_MINOR: c_int = 0;
export const ZLOB_VERSION_PATCH: c_int = 0;
