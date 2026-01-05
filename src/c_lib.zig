const std = @import("std");
const glob_impl = @import("glob.zig");
const path_matcher = @import("path_matcher.zig");

const mem = std.mem;

pub const glob_t = glob_impl.glob_t;

pub const zlob_slice_t = extern struct {
    ptr: [*]const u8,
    len: usize,
};

pub const GLOB_ERR = glob_impl.GLOB_ERR;
pub const GLOB_MARK = glob_impl.GLOB_MARK;
pub const GLOB_NOSORT = glob_impl.GLOB_NOSORT;
pub const GLOB_DOOFFS = glob_impl.GLOB_DOOFFS;
pub const GLOB_NOCHECK = glob_impl.GLOB_NOCHECK;
pub const GLOB_APPEND = glob_impl.GLOB_APPEND;
pub const GLOB_NOESCAPE = glob_impl.GLOB_NOESCAPE;
pub const GLOB_PERIOD = glob_impl.GLOB_PERIOD;
pub const GLOB_MAGCHAR = glob_impl.GLOB_MAGCHAR;
pub const GLOB_ALTDIRFUNC = glob_impl.GLOB_ALTDIRFUNC;
pub const GLOB_BRACE = glob_impl.GLOB_BRACE;
pub const GLOB_NOMAGIC = glob_impl.GLOB_NOMAGIC;
pub const GLOB_TILDE = glob_impl.GLOB_TILDE;
pub const GLOB_ONLYDIR = glob_impl.GLOB_ONLYDIR;
pub const GLOB_TILDE_CHECK = glob_impl.GLOB_TILDE_CHECK;
pub const GLOB_NOSPACE = glob_impl.GLOB_NOSPACE;
pub const GLOB_ABORTED = glob_impl.GLOB_ABORTED;
pub const GLOB_NOMATCH = glob_impl.GLOB_NOMATCH;

export fn glob(pattern: [*:0]const u8, flags: c_int, errfunc: ?*anyopaque, pglob: *glob_t) c_int {
    const allocator = std.heap.c_allocator;

    // Call low-level C-style implementation directly
    // This is necessary for features like GLOB_DOOFFS which require
    // reading gl_offs from the pre-initialized pglob
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

/// Internal implementation of globfree
fn globfreeImpl(pglob: *glob_t) void {
    // Simply delegate to internal globfree which handles everything
    glob_impl.globfreeInternal(std.heap.c_allocator, pglob);
}

/// Zig-friendly wrapper for glob() (for compatibility with old code that passes allocator)
/// Note: allocator parameter is ignored, we use c_allocator internally
pub fn glob_c(allocator: std.mem.Allocator, pattern: [*:0]const u8, flags: c_int, errfunc: ?*anyopaque, pglob: *glob_t) c_int {
    _ = allocator; // Ignored - we use c_allocator internally
    return glob(pattern, flags, errfunc, pglob);
}

/// glob_match_paths version that is using slices for pattern and paths 
/// this function only exists for FFI compatibility with langauges like rust/c++
/// that usually know the length of the slices at compile time. 
///
/// It relies on the zig ABI which is unsatble so there is no guarantee this function
/// will work stably across zig versions.
///
/// For stability - use glob_match_paths instead.
pub export fn glob_match_paths_slice(
    pattern: *const zlob_slice_t,
    paths: [*]const zlob_slice_t,
    path_count: usize,
    flags: c_int,
    pglob: *glob_t,
) c_int {
    const allocator = std.heap.c_allocator;
    const pattern_slice = pattern.ptr[0..pattern.len];

    // THIS IS SAFE UNTIL IT DOESN'T 
    const zig_paths: []const []const u8 = @ptrCast(paths[0..path_count]);

    var results = path_matcher.matchPaths(allocator, pattern_slice, zig_paths, @intCast(flags)) catch |err| {
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
    pglob.gl_flags = 0; // We DON'T own the strings (caller owns them)

    return 0;
}

/// Match glob pattern against array of paths.
///
/// Populates glob_t with matches found in the provided array of path strings.
/// The paths are owned by the caller and must remain valid until globfree() is called
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

    var results = path_matcher.matchPaths(allocator, pattern_slice, zig_paths_storage, @intCast(flags)) catch |err| {
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
    pglob.gl_flags = 0; // We DON'T own the strings (caller owns them)

    return 0;
}

/// C export of unified globfree (works for both glob() and glob_match_paths_*)
export fn globfree(pglob: *glob_t) void {
    glob_impl.globfreeInternal(std.heap.c_allocator, pglob);
}

/// Zig-friendly globfree wrapper (for API compatibility with old code that passes allocator)
/// Note: allocator parameter is ignored, we use c_allocator internally
pub fn globfreeZ(allocator: std.mem.Allocator, pglob: *glob_t) void {
    _ = allocator;
    globfree(pglob);
}

// Re-export internal functions for testing
pub const analyzePattern = glob_impl.analyzePattern;

// Export version information
export const ZLOB_VERSION_MAJOR: c_int = 1;
export const ZLOB_VERSION_MINOR: c_int = 0;
export const ZLOB_VERSION_PATCH: c_int = 0;
