const std = @import("std");
const builtin = @import("builtin");
const zlob_impl = @import("zlob");
const zlob_flags = @import("zlob_flags");

const mem = std.mem;
const ZlobFlags = zlob_flags.ZlobFlags;
const pattern_context = zlob_impl.pattern_context;

// Strip Zig std's crash-handling / self-introspection machinery.
//
// zlob is a static-lib FFI dependency: the host (fff-nvim, fff-node, nvim
// itself, node, etc.) owns signal handling and process-wide panic/trace
// reporting. We don't want Zig's extra machinery riding along into every
// consumer because:
//  1. Per-thread TLS: std.Thread.maybeAttachSignalStack declares a 256 KB
//     `threadlocal var signal_stack`. When a downstream `.so` linking zlob
//     statically is `dlopen`'d late (e.g. neovim loading a plugin), glibc
//     fails with `cannot allocate memory in static TLS block` (fff.nvim
//     issue #298).
//  2. Upstream bug: on aarch64-windows-msvc, Zig 0.16.0's
//     std.debug.SelfInfo.Windows.zig has an `@ptrCast increases pointer
//     alignment` compile error that fails our build.
//
// Three knobs turn all this off at compile time:
//
// * `signal_stack_size = null` — maybeAttachSignalStack early-returns, the
//   256 KB threadlocal is never instantiated.
//
// * `enable_segfault_handler = false` — don't install Zig's SIGSEGV/SIGILL/
//   SIGBUS/SIGFPE handler. The host's handler runs instead (normal FFI).
//
// * `allow_stack_tracing = false` — disables debug.captureCurrentStackTrace
//   and friends; keeps std.debug.SelfInfo (incl. the broken Windows path)
//   out of the compilation entirely.
//
// None of this disables threads — std.Thread.spawn still works.
pub const std_options: std.Options = .{
    .signal_stack_size = null,
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};

// When libc is linked (most POSIX targets), use c_allocator (backed by malloc/free)
// for better small-alloc performance. Otherwise (Windows MSVC, Android, etc.)
// fall back to page_allocator (backed by VirtualAlloc / mmap).
const allocator = if (builtin.link_libc)
    std.heap.c_allocator
else
    std.heap.page_allocator;

/// C callers can't hand us an `Io`, so the C ABI wrappers below use the
/// stdlib's pre-initialized single-threaded Io. Zig callers should instead
/// use the `zlob` module directly and pass their own `Io`.
inline fn cIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

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
    if (zlob_impl.glob(allocator, cIo(), pattern, flags, errfunc, pzlob)) |opt_result| {
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
    zlob_impl.globfreeInternal(allocator, pzlob);
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
    const base_slice = mem.sliceTo(base_path, 0);

    if (zlob_impl.globAt(allocator, cIo(), base_slice, pattern, flags, errfunc, pzlob)) |opt_result| {
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

    const result_len = results.len();
    if (result_len == 0) {
        return zlob_flags.ZLOB_NOMATCH;
    }

    const pathv_buf = allocator.alloc([*c]u8, result_len + 1) catch return zlob_flags.ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, result_len) catch {
        allocator.free(pathv_buf);
        return zlob_flags.ZLOB_NOSPACE;
    };

    for (0..result_len) |i| {
        const path = results.get(i);
        pathv_buf[i] = @ptrCast(@constCast(path.ptr));
        pathlen_buf[i] = path.len;
    }
    pathv_buf[result_len] = null;

    pzlob.zlo_pathc = result_len;
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
    const pattern_slice = pattern.ptr[0..pattern.len];

    // UNSAFE: Relies on Zig ABI compatibility
    const zig_paths: []const []const u8 = @ptrCast(paths[0..path_count]);

    var results = zlob_impl.path_matcher.matchPaths(allocator, pattern_slice, zig_paths, ZlobFlags.fromInt(flags)) catch |err| {
        return switch (err) {
            error.OutOfMemory => zlob_flags.ZLOB_NOSPACE,
        };
    };
    defer results.deinit();

    const result_len = results.len();
    if (result_len == 0) {
        return zlob_flags.ZLOB_NOMATCH;
    }

    const pathv_buf = allocator.alloc([*c]u8, result_len + 1) catch return zlob_flags.ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, result_len) catch {
        allocator.free(pathv_buf);
        return zlob_flags.ZLOB_NOSPACE;
    };

    for (0..result_len) |i| {
        const path = results.get(i);
        pathv_buf[i] = @ptrCast(@constCast(path.ptr));
        pathlen_buf[i] = path.len;
    }
    pathv_buf[result_len] = null;

    pzlob.zlo_pathc = result_len;
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

    const result_len = results.len();
    if (result_len == 0) {
        return zlob_flags.ZLOB_NOMATCH;
    }

    const pathv_buf = allocator.alloc([*c]u8, result_len + 1) catch return zlob_flags.ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, result_len) catch {
        allocator.free(pathv_buf);
        return zlob_flags.ZLOB_NOSPACE;
    };

    for (0..result_len) |i| {
        const path = results.get(i);
        pathv_buf[i] = @ptrCast(@constCast(path.ptr));
        pathlen_buf[i] = path.len;
    }
    pathv_buf[result_len] = null;

    pzlob.zlo_pathc = result_len;
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

    const result_len = results.len();
    if (result_len == 0) {
        return zlob_flags.ZLOB_NOMATCH;
    }

    const pathv_buf = allocator.alloc([*c]u8, result_len + 1) catch return zlob_flags.ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, result_len) catch {
        allocator.free(pathv_buf);
        return zlob_flags.ZLOB_NOSPACE;
    };

    for (0..result_len) |i| {
        const path = results.get(i);
        pathv_buf[i] = @ptrCast(@constCast(path.ptr));
        pathlen_buf[i] = path.len;
    }
    pathv_buf[result_len] = null;

    pzlob.zlo_pathc = result_len;
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
