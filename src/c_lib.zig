const std = @import("std");
const zlob_impl = @import("zlob");
const zlob_flags = @import("zlob_flags");

const mem = std.mem;
const ZlobFlags = zlob_flags.ZlobFlags;
const pattern_context = zlob_impl.pattern_context;

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

pub export fn zlob(pattern: [*:0]const u8, flags: c_int, errfunc: zlob_impl.zlob_errfunc_t, pzlob: *zlob_t) callconv(.c) c_int {
    const allocator = std.heap.c_allocator;

    if (zlob_impl.glob(allocator, pattern, flags, errfunc, pzlob)) |opt_result| {
        if (opt_result) |_| {
            return 0; // Success with matches
        } else {
            return zlob_flags.ZLOB_NOMATCH; // No matches
        }
    } else |err| {
        return switch (err) {
            error.OutOfMemory => zlob_flags.ZLOB_NOSPACE,
            error.Aborted => zlob_flags.ZLOB_ABORTED,
        };
    }
}

pub export fn zlobfree(pzlob: *zlob_t) callconv(.c) void {
    zlob_impl.globfreeInternal(std.heap.c_allocator, pzlob);
}

/// Glob within a specific base directory.
/// base_path must be an absolute path (starts with '/'), otherwise returns zlob_flags.ZLOB_ABORTED.
/// This is the C-compatible version of globAt().
pub export fn zlob_at(
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
            return zlob_flags.ZLOB_NOMATCH; // No matches
        }
    } else |err| {
        return switch (err) {
            error.OutOfMemory => zlob_flags.ZLOB_NOSPACE,
            error.Aborted => zlob_flags.ZLOB_ABORTED,
        };
    }
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
        allocator.alloc([]const u8, path_count) catch return zlob_flags.ZLOB_NOSPACE;
    defer if (path_count > STACK_LIMIT) allocator.free(zig_paths_storage);

    for (0..path_count) |i| {
        zig_paths_storage[i] = mem.sliceTo(paths[i], 0);
    }

    var results = zlob_impl.path_matcher.matchPaths(allocator, pattern_slice, zig_paths_storage, ZlobFlags.fromInt(flags)) catch |err| {
        return switch (err) {
            error.OutOfMemory => zlob_flags.ZLOB_NOSPACE,
        };
    };
    defer results.deinit();

    if (results.match_count == 0) {
        return zlob_flags.ZLOB_NOMATCH;
    }

    const pathv_buf = allocator.alloc([*c]u8, results.match_count + 1) catch return zlob_flags.ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, results.match_count) catch {
        allocator.free(pathv_buf);
        return zlob_flags.ZLOB_NOSPACE;
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
    pzlob.zlo_flags = zlob_flags.ZLOB_FLAGS_SHARED_STRINGS;

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

    var results = zlob_impl.path_matcher.matchPaths(allocator, pattern_slice, zig_paths, ZlobFlags.fromInt(flags)) catch |err| {
        return switch (err) {
            error.OutOfMemory => zlob_flags.ZLOB_NOSPACE,
        };
    };
    defer results.deinit();

    if (results.match_count == 0) {
        return zlob_flags.ZLOB_NOMATCH;
    }

    const pathv_buf = allocator.alloc([*c]u8, results.match_count + 1) catch return zlob_flags.ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, results.match_count) catch {
        allocator.free(pathv_buf);
        return zlob_flags.ZLOB_NOSPACE;
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
    pzlob.zlo_flags = zlob_flags.ZLOB_FLAGS_SHARED_STRINGS;

    return 0;
}

/// Match paths against a glob pattern relative to a base directory (C string version).
/// The base_path may or may not end with '/'.
pub export fn zlob_match_paths_at(
    base_path: [*:0]const u8,
    pattern: [*:0]const u8,
    paths: [*]const [*:0]const u8,
    path_count: usize,
    flags: c_int,
    pzlob: *zlob_t,
) c_int {
    const allocator = std.heap.c_allocator;

    const base_slice = mem.sliceTo(base_path, 0);
    const pattern_slice = mem.sliceTo(pattern, 0);

    const STACK_LIMIT = 256;
    var stack_buf: [STACK_LIMIT][]const u8 = undefined;
    const zig_paths_storage = if (path_count <= STACK_LIMIT)
        stack_buf[0..path_count]
    else
        allocator.alloc([]const u8, path_count) catch return zlob_flags.ZLOB_NOSPACE;
    defer if (path_count > STACK_LIMIT) allocator.free(zig_paths_storage);

    for (0..path_count) |i| {
        zig_paths_storage[i] = mem.sliceTo(paths[i], 0);
    }

    var results = zlob_impl.path_matcher.matchPathsAt(allocator, base_slice, pattern_slice, zig_paths_storage, ZlobFlags.fromInt(flags)) catch |err| {
        return switch (err) {
            error.OutOfMemory => zlob_flags.ZLOB_NOSPACE,
        };
    };
    defer results.deinit();

    if (results.match_count == 0) {
        return zlob_flags.ZLOB_NOMATCH;
    }

    const pathv_buf = allocator.alloc([*c]u8, results.match_count + 1) catch return zlob_flags.ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, results.match_count) catch {
        allocator.free(pathv_buf);
        return zlob_flags.ZLOB_NOSPACE;
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
    pzlob.zlo_flags = zlob_flags.ZLOB_FLAGS_SHARED_STRINGS;

    return 0;
}

/// Match paths against a glob pattern relative to a base directory (slice version).
/// Zero-copy FFI variant for Rust/Zig interop.
pub export fn zlob_match_paths_at_slice(
    base_path: *const zlob_slice_t,
    pattern: *const zlob_slice_t,
    paths: [*]const zlob_slice_t,
    path_count: usize,
    flags: c_int,
    pzlob: *zlob_t,
) c_int {
    const allocator = std.heap.c_allocator;
    const base_slice = base_path.ptr[0..base_path.len];
    const pattern_slice = pattern.ptr[0..pattern.len];

    // UNSAFE: Relies on Zig ABI compatibility
    const zig_paths: []const []const u8 = @ptrCast(paths[0..path_count]);

    var results = zlob_impl.path_matcher.matchPathsAt(allocator, base_slice, pattern_slice, zig_paths, ZlobFlags.fromInt(flags)) catch |err| {
        return switch (err) {
            error.OutOfMemory => zlob_flags.ZLOB_NOSPACE,
        };
    };
    defer results.deinit();

    if (results.match_count == 0) {
        return zlob_flags.ZLOB_NOMATCH;
    }

    const pathv_buf = allocator.alloc([*c]u8, results.match_count + 1) catch return zlob_flags.ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, results.match_count) catch {
        allocator.free(pathv_buf);
        return zlob_flags.ZLOB_NOSPACE;
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
    pzlob.zlo_flags = zlob_flags.ZLOB_FLAGS_SHARED_STRINGS;

    return 0;
}

/// Check if a pattern string contains any glob special characters.
///
/// Detects all glob syntax in a single SIMD-accelerated pass:
/// - Basic wildcards: *, ?, [
/// - Brace expansion: {
/// - Extended glob patterns: ?(, *(, +(, @(, !(
///
/// Returns 1 (true) if the pattern contains glob syntax, 0 (false) otherwise.
/// This is useful for determining whether a string should be treated as a glob
/// pattern or as a literal path.
pub export fn zlob_has_wildcards(
    pattern_str: [*:0]const u8,
    flags: c_int,
) callconv(.c) c_int {
    const pattern_slice = mem.sliceTo(pattern_str, 0);
    return @intFromBool(pattern_context.hasWildcards(pattern_slice, ZlobFlags.fromInt(flags)));
}
