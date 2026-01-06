const std = @import("std");
const glob_impl = @import("glob");

const mem = std.mem;

// Re-export for C API compatibility
pub const glob_t = glob_impl.glob_t;

// FFI helper type for languages that support Zig ABI
pub const zlob_slice_t = extern struct {
    ptr: [*]const u8,
    len: usize,
};

// Internal constants
const GLOB_NOMATCH = glob_impl.GLOB_NOMATCH;
const GLOB_NOSPACE = glob_impl.GLOB_NOSPACE;
const GLOB_ABORTED = glob_impl.GLOB_ABORTED;
const ZLOB_FLAGS_SHARED_STRINGS = glob_impl.ZLOB_FLAGS_SHARED_STRINGS;

// ============================================================================
// C API - POSIX-compatible glob functions
// ============================================================================

/// POSIX glob() - Match pattern against filesystem
///
/// This is the standard C-compatible glob function that uses c_allocator.
/// For Zig code with custom allocators, use the Zig API in lib.zig instead.
pub export fn glob(pattern: [*:0]const u8, flags: c_int, errfunc: ?*anyopaque, pglob: *glob_t) c_int {
    const allocator = std.heap.c_allocator;

    if (glob_impl.glob(allocator, pattern, flags, errfunc, pglob)) |opt_result| {
        if (opt_result) |_| {
            return 0; // Success with matches
        } else {
            return GLOB_NOMATCH; // No matches
        }
    } else |err| {
        return switch (err) {
            error.OutOfMemory => GLOB_NOSPACE,
            error.Aborted => GLOB_ABORTED,
        };
    }
}

/// POSIX globfree() - Free memory allocated by glob()
///
/// This is the standard C-compatible globfree function.
pub export fn globfree(pglob: *glob_t) void {
    glob_impl.globfreeInternal(std.heap.c_allocator, pglob);
}

// ============================================================================
// Extended C API - Additional functionality
// ============================================================================

/// Match glob pattern against array of paths (C-compatible).
///
/// Populates glob_t with matches found in the provided array of path strings.
/// The paths are owned by the caller and must remain valid until globfree() is called.
///
/// This is a zero-copy operation - the returned glob_t points to caller's memory.
pub export fn glob_match_paths(
    pattern: [*:0]const u8,
    paths: [*]const [*:0]const u8,
    path_count: usize,
    flags: c_int,
    pglob: *glob_t,
) c_int {
    const allocator = std.heap.c_allocator;

    // Convert to Zig slices (zero-copy view)
    const pattern_slice = mem.sliceTo(pattern, 0);

    // Use stack allocation for common case to avoid heap allocation
    const STACK_LIMIT = 256;
    var stack_buf: [STACK_LIMIT][]const u8 = undefined;
    const zig_paths_storage = if (path_count <= STACK_LIMIT)
        stack_buf[0..path_count]
    else
        allocator.alloc([]const u8, path_count) catch return GLOB_NOSPACE;
    defer if (path_count > STACK_LIMIT) allocator.free(zig_paths_storage);

    for (0..path_count) |i| {
        zig_paths_storage[i] = mem.sliceTo(paths[i], 0);
    }

    var results = glob_impl.internalMatchPaths(allocator, pattern_slice, zig_paths_storage, @intCast(flags)) catch |err| {
        return switch (err) {
            error.OutOfMemory => GLOB_NOSPACE,
        };
    };
    defer results.deinit();

    if (results.match_count == 0) {
        return GLOB_NOMATCH;
    }

    // Allocate result arrays (pointers only!)
    const pathv_buf = allocator.alloc([*c]u8, results.match_count + 1) catch return GLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, results.match_count) catch {
        allocator.free(pathv_buf);
        return GLOB_NOSPACE;
    };

    // Point to original memory (zero-copy!)
    for (results.paths, 0..) |path, i| {
        pathv_buf[i] = @ptrCast(@constCast(path.ptr)); // Point to caller's memory
        pathlen_buf[i] = path.len;
    }
    pathv_buf[results.match_count] = null;

    // Populate glob_t
    pglob.gl_pathc = results.match_count;
    pglob.gl_pathv = @ptrCast(pathv_buf.ptr);
    pglob.gl_offs = 0;
    pglob.gl_pathlen = pathlen_buf.ptr;
    pglob.gl_flags = ZLOB_FLAGS_SHARED_STRINGS;

    return 0;
}

/// Match glob pattern against array of paths (slice-based FFI).
///
/// This function uses Zig slices for pattern and paths, which relies on the
/// Zig ABI. Only use this from languages that understand Zig ABI (unstable).
///
/// For stable C API, use glob_match_paths() instead.
pub export fn glob_match_paths_slice(
    pattern: *const zlob_slice_t,
    paths: [*]const zlob_slice_t,
    path_count: usize,
    flags: c_int,
    pglob: *glob_t,
) c_int {
    const allocator = std.heap.c_allocator;
    const pattern_slice = pattern.ptr[0..pattern.len];

    // UNSAFE: Relies on Zig ABI compatibility
    const zig_paths: []const []const u8 = @ptrCast(paths[0..path_count]);

    var results = glob_impl.internalMatchPaths(allocator, pattern_slice, zig_paths, @intCast(flags)) catch |err| {
        return switch (err) {
            error.OutOfMemory => GLOB_NOSPACE,
        };
    };
    defer results.deinit();

    if (results.match_count == 0) {
        return GLOB_NOMATCH;
    }

    // Allocate result arrays (pointers only, NOT string copies!)
    const pathv_buf = allocator.alloc([*c]u8, results.match_count + 1) catch return GLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, results.match_count) catch {
        allocator.free(pathv_buf);
        return GLOB_NOSPACE;
    };

    // Point to original memory (zero-copy!)
    for (results.paths, 0..) |path, i| {
        pathv_buf[i] = @ptrCast(@constCast(path.ptr)); // Point to caller's memory
        pathlen_buf[i] = path.len;
    }
    pathv_buf[results.match_count] = null;

    // Populate glob_t
    pglob.gl_pathc = results.match_count;
    pglob.gl_pathv = @ptrCast(pathv_buf.ptr);
    pglob.gl_offs = 0;
    pglob.gl_pathlen = pathlen_buf.ptr;
    pglob.gl_flags = ZLOB_FLAGS_SHARED_STRINGS;

    return 0;
}

// ============================================================================
// Version information
// ============================================================================

export const ZLOB_VERSION_MAJOR: c_int = 1;
export const ZLOB_VERSION_MINOR: c_int = 0;
export const ZLOB_VERSION_PATCH: c_int = 0;
