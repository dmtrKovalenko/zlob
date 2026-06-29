const std = @import("std");
const builtin = @import("builtin");
const zlob_impl = @import("zlob");
const zlob_flags = @import("zlob_flags");
const compiled_pattern = zlob_impl.compiled_pattern;
const mem = std.mem;
const ZlobFlags = zlob_flags.ZlobFlags;
const pattern_context = zlob_impl.pattern_context;

const c_zlob = @cImport({
    @cInclude("zlob.h");
});

// zig just added a ton of bullshit to the default std options which causes
// a lot of different behavior changes for the standard C library this is
// a minimal set of exclusion to keep all the bs out and work like a normal C lib
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
/// at a cost of relying on the unstable Rust/Zig ABI compatibility.
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

const STR_CHUNK: usize = 256;

/// Materialise C-string `paths` into Zig slices STR_CHUNK at a time and match
/// each chunk. The runtime `path_offset == 0` decision is made once here so
/// the comptime `at` flag stays fixed for the whole loop.
fn chunkedMatchFromCStr(
    comptime kind: compiled_pattern.CollectorKind,
    compiled: *const compiled_pattern.CompiledPattern,
    paths: [*]const [*:0]const u8,
    path_count: usize,
    path_offset: usize,
    flags: ZlobFlags,
    out: *compiled_pattern.ListOf(kind),
) !void {
    if (path_offset == 0) {
        try chunkedMatchImpl(kind, false, compiled, paths, path_count, 0, flags, out);
    } else {
        try chunkedMatchImpl(kind, true, compiled, paths, path_count, path_offset, flags, out);
    }
}

fn chunkedMatchImpl(
    comptime kind: compiled_pattern.CollectorKind,
    comptime at: bool,
    compiled: *const compiled_pattern.CompiledPattern,
    paths: [*]const [*:0]const u8,
    path_count: usize,
    path_offset: usize,
    flags: ZlobFlags,
    out: *compiled_pattern.ListOf(kind),
) !void {
    var stack_buf: [STR_CHUNK][]const u8 = undefined;

    var chunk_start: usize = 0;
    while (chunk_start < path_count) : (chunk_start += STR_CHUNK) {
        const chunk_len = @min(STR_CHUNK, path_count - chunk_start);
        for (0..chunk_len) |i| {
            stack_buf[i] = mem.sliceTo(paths[chunk_start + i], 0);
        }
        const chunk_paths = stack_buf[0..chunk_len];

        try compiled_pattern.matchPathsCompiledImpl(
            kind,
            at,
            compiled,
            chunk_paths,
            path_offset,
            flags,
            out,
            chunk_start,
        );
    }
}

fn finalizeSharedSliceResult(matches: []const []const u8, pzlob: *zlob_t) c_int {
    const result_len = matches.len;
    const pathv_buf = allocator.alloc([*c]u8, result_len + 1) catch return zlob_flags.ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);

    const pathlen_buf = allocator.alloc(usize, result_len) catch {
        allocator.free(pathv_buf);
        return zlob_flags.ZLOB_NOSPACE;
    };

    for (matches, 0..) |path, i| {
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

/// On an empty match set, honor ZLOB_NOCHECK by synthesizing the pattern
/// itself as the single result (an owned copy, freed by zlobfree). Returns
/// ZLOB_NOMATCH when NOCHECK is not set.
fn finalizeNoMatch(pattern: []const u8, nocheck: bool, pzlob: *zlob_t) c_int {
    if (!nocheck) return zlob_flags.ZLOB_NOMATCH;

    const pathv_buf = allocator.alloc([*c]u8, 2) catch return zlob_flags.ZLOB_NOSPACE;
    errdefer allocator.free(pathv_buf);
    const pathlen_buf = allocator.alloc(usize, 1) catch {
        allocator.free(pathv_buf);
        return zlob_flags.ZLOB_NOSPACE;
    };
    errdefer allocator.free(pathlen_buf);

    // NUL-terminated owned copy so C callers can treat it as a C string.
    const owned = allocator.allocSentinel(u8, pattern.len, 0) catch {
        allocator.free(pathv_buf);
        allocator.free(pathlen_buf);
        return zlob_flags.ZLOB_NOSPACE;
    };
    @memcpy(owned[0..pattern.len], pattern);

    pathv_buf[0] = @ptrCast(owned.ptr);
    pathv_buf[1] = null;
    pathlen_buf[0] = pattern.len;

    pzlob.zlo_pathc = 1;
    pzlob.zlo_pathv = @ptrCast(pathv_buf.ptr);
    pzlob.zlo_offs = 0;
    pzlob.zlo_pathlen = pathlen_buf.ptr;
    pzlob.zlo_flags = zlob_flags.ZLOB_FLAGS_OWNS_STRINGS;
    return 0;
}

/// Extension to the standard C api: match the pattern against a flat list of
/// paths without touching the filesystem.
pub export fn zlob_match_paths(
    pattern: [*:0]const u8,
    paths: [*]const [*:0]const u8,
    path_count: usize,
    flags: c_int,
    pzlob: *zlob_t,
) c_int {
    const pattern_slice = mem.sliceTo(pattern, 0);
    const zflags = ZlobFlags.fromInt(flags);

    var compiled = compiled_pattern.compilePattern(allocator, pattern_slice, zflags) catch
        return zlob_flags.ZLOB_NOSPACE;
    defer compiled.deinit();

    var matches = std.array_list.AlignedManaged([]const u8, null)
        .initCapacity(allocator, @min(path_count, STR_CHUNK)) catch
        std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer matches.deinit();

    chunkedMatchFromCStr(.slices, &compiled, paths, path_count, 0, zflags, &matches) catch
        return zlob_flags.ZLOB_NOSPACE;

    if (matches.items.len == 0) return finalizeNoMatch(compiled.pattern_storage, zflags.nocheck, pzlob);

    if (!zflags.nosort) compiled_pattern.sortPathSlices(matches.items);

    return finalizeSharedSliceResult(matches.items, pzlob);
}

/// The same as `zlob_match_paths` but using specific string slice type with a known length.
/// Used primarily for FFI compatibility with languages with normal string type as first-class citizens.
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

    var results = compiled_pattern.matchPaths(allocator, pattern_slice, zig_paths, ZlobFlags.fromInt(flags)) catch |err| {
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
    const zflags = ZlobFlags.fromInt(flags);
    const path_offset = compiled_pattern.computePathOffset(base_slice);

    var compiled = compiled_pattern.compilePattern(allocator, pattern_slice, zflags) catch
        return zlob_flags.ZLOB_NOSPACE;
    defer compiled.deinit();

    var matches = std.array_list.AlignedManaged([]const u8, null)
        .initCapacity(allocator, @min(path_count, STR_CHUNK)) catch
        std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer matches.deinit();

    chunkedMatchFromCStr(.slices, &compiled, paths, path_count, path_offset, zflags, &matches) catch
        return zlob_flags.ZLOB_NOSPACE;

    if (matches.items.len == 0) return finalizeNoMatch(compiled.pattern_storage, zflags.nocheck, pzlob);

    if (!zflags.nosort) compiled_pattern.sortPathSlices(matches.items);

    return finalizeSharedSliceResult(matches.items, pzlob);
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

    var results = compiled_pattern.matchPathsAt(allocator, base_slice, pattern_slice, zig_paths, ZlobFlags.fromInt(flags)) catch |err| {
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

// ============================================================================
// Compiled patterns + indices APIs
//
// `zlob_pattern_t` is exported as an opaque pointer; on the Zig side it is
// just a heap-allocated `CompiledPattern`. No wrapper struct — the opaque
// pointer points directly at the CompiledPattern, saving an indirection on
// every `zlob_pattern_matches` call.
//
// `zlob_indices_t` is a layout-asserted extern struct — the C header has the
// matching definition.
// ============================================================================

pub const zlob_indices_t = extern struct {
    indices: ?[*]usize,
    count: usize,

    comptime {
        const zig_t = zlob_indices_t;
        const c_t = c_zlob.zlob_indices_t;

        if (@sizeOf(zig_t) != @sizeOf(c_t)) {
            @compileError("zlob_indices_t size mismatch");
        }
        if (@offsetOf(zig_t, "indices") != @offsetOf(c_t, "indices")) {
            @compileError("zlob_indices_t indices offset mismatch");
        }
        if (@offsetOf(zig_t, "count") != @offsetOf(c_t, "count")) {
            @compileError("zlob_indices_t count offset mismatch");
        }
    }
};

inline fn patternPtr(p: *anyopaque) *compiled_pattern.CompiledPattern {
    return @ptrCast(@alignCast(p));
}

inline fn patternConstPtr(p: *const anyopaque) *const compiled_pattern.CompiledPattern {
    return @ptrCast(@alignCast(p));
}

pub export fn zlob_pattern_compile(
    pattern: [*:0]const u8,
    flags: c_int,
) ?*anyopaque {
    const pattern_slice = mem.sliceTo(pattern, 0);
    return zlob_pattern_compile_impl(pattern_slice, flags);
}

pub export fn zlob_pattern_compile_slice(
    pattern: *const zlob_slice_t,
    flags: c_int,
) ?*anyopaque {
    const pattern_slice = pattern.ptr[0..pattern.len];
    return zlob_pattern_compile_impl(pattern_slice, flags);
}

fn zlob_pattern_compile_impl(pattern_slice: []const u8, flags: c_int) ?*anyopaque {
    const cp = allocator.create(compiled_pattern.CompiledPattern) catch return null;
    cp.* = compiled_pattern.compilePattern(allocator, pattern_slice, ZlobFlags.fromInt(flags)) catch {
        allocator.destroy(cp);
        return null;
    };
    return @ptrCast(cp);
}

pub export fn zlob_pattern_free(p: ?*anyopaque) void {
    if (p) |raw| {
        const cp = patternPtr(raw);
        cp.deinit();
        allocator.destroy(cp);
    }
}

pub export fn zlob_pattern_matches(
    p: ?*const anyopaque,
    path: [*]const u8,
    path_len: usize,
    flags: c_int,
) c_int {
    const raw = p orelse return 0;
    const cp = patternConstPtr(raw);
    const path_slice = path[0..path_len];
    return @intFromBool(cp.matches(path_slice, ZlobFlags.fromInt(flags)));
}

pub export fn zlob_indices_free(out: ?*zlob_indices_t) void {
    const o = out orelse return;
    if (o.indices) |ptr| {
        const slice = ptr[0..o.count];
        allocator.free(slice);
    }
    o.indices = null;
    o.count = 0;
}

// -------- Indices APIs (uncompiled; compile internally per call) ----------

fn writeIndicesResult(out: *zlob_indices_t, indices: []usize) c_int {
    if (indices.len == 0) {
        allocator.free(indices);
        out.indices = null;
        out.count = 0;
        return zlob_flags.ZLOB_NOMATCH;
    }
    out.indices = indices.ptr;
    out.count = indices.len;
    return 0;
}

fn matchIndicesFromCStrPaths(
    pattern_slice: []const u8,
    paths: [*]const [*:0]const u8,
    path_count: usize,
    flags: c_int,
    out: *zlob_indices_t,
    base_path: ?[]const u8,
) c_int {
    const zflags = ZlobFlags.fromInt(flags);

    var compiled = compiled_pattern.compilePattern(allocator, pattern_slice, zflags) catch
        return zlob_flags.ZLOB_NOSPACE;
    defer compiled.deinit();

    const path_offset = if (base_path) |bp| compiled_pattern.computePathOffset(bp) else 0;

    var indices = std.array_list.AlignedManaged(usize, null)
        .initCapacity(allocator, @min(path_count, STR_CHUNK)) catch
        std.array_list.AlignedManaged(usize, null).init(allocator);

    chunkedMatchFromCStr(.indices, &compiled, paths, path_count, path_offset, zflags, &indices) catch {
        indices.deinit();
        return zlob_flags.ZLOB_NOSPACE;
    };

    const owned = indices.toOwnedSlice() catch {
        indices.deinit();
        return zlob_flags.ZLOB_NOSPACE;
    };
    return writeIndicesResult(out, owned);
}

fn matchIndicesFromSlicePaths(
    pattern_slice: []const u8,
    paths: [*]const zlob_slice_t,
    path_count: usize,
    flags: c_int,
    out: *zlob_indices_t,
    base_path: ?[]const u8,
) c_int {
    // UNSAFE: relies on Zig ABI compatibility (same as the existing slice APIs).
    const zig_paths: []const []const u8 = @ptrCast(paths[0..path_count]);

    const zflags = ZlobFlags.fromInt(flags);
    const indices = if (base_path) |bp|
        compiled_pattern.matchPathIndicesAt(allocator, bp, pattern_slice, zig_paths, zflags) catch |err| switch (err) {
            error.OutOfMemory => return zlob_flags.ZLOB_NOSPACE,
        }
    else
        compiled_pattern.matchPathIndices(allocator, pattern_slice, zig_paths, zflags) catch |err| switch (err) {
            error.OutOfMemory => return zlob_flags.ZLOB_NOSPACE,
        };

    return writeIndicesResult(out, indices);
}

pub export fn zlob_match_paths_indices(
    pattern: [*:0]const u8,
    paths: [*]const [*:0]const u8,
    path_count: usize,
    flags: c_int,
    out: *zlob_indices_t,
) c_int {
    return matchIndicesFromCStrPaths(mem.sliceTo(pattern, 0), paths, path_count, flags, out, null);
}

pub export fn zlob_match_paths_indices_slice(
    pattern: *const zlob_slice_t,
    paths: [*]const zlob_slice_t,
    path_count: usize,
    flags: c_int,
    out: *zlob_indices_t,
) c_int {
    return matchIndicesFromSlicePaths(pattern.ptr[0..pattern.len], paths, path_count, flags, out, null);
}

pub export fn zlob_match_paths_indices_at(
    base_path: [*:0]const u8,
    pattern: [*:0]const u8,
    paths: [*]const [*:0]const u8,
    path_count: usize,
    flags: c_int,
    out: *zlob_indices_t,
) c_int {
    return matchIndicesFromCStrPaths(
        mem.sliceTo(pattern, 0),
        paths,
        path_count,
        flags,
        out,
        mem.sliceTo(base_path, 0),
    );
}

pub export fn zlob_match_paths_indices_at_slice(
    base_path: *const zlob_slice_t,
    pattern: *const zlob_slice_t,
    paths: [*]const zlob_slice_t,
    path_count: usize,
    flags: c_int,
    out: *zlob_indices_t,
) c_int {
    return matchIndicesFromSlicePaths(
        pattern.ptr[0..pattern.len],
        paths,
        path_count,
        flags,
        out,
        base_path.ptr[0..base_path.len],
    );
}

// -------- Compiled-pattern batch APIs ------------------------------------

fn finalizeCompiledSliceResult(results: *zlob_impl.ZlobResults, pzlob: *zlob_t) c_int {
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

pub export fn zlob_pattern_match_paths_slice(
    p: ?*const anyopaque,
    paths: [*]const zlob_slice_t,
    path_count: usize,
    flags: c_int,
    pzlob: *zlob_t,
) c_int {
    const raw = p orelse return zlob_flags.ZLOB_ABORTED;
    const cp = patternConstPtr(raw);

    // UNSAFE: relies on Zig ABI compatibility.
    const zig_paths: []const []const u8 = @ptrCast(paths[0..path_count]);

    var results = compiled_pattern.matchPathsCompiled(allocator, cp, zig_paths, ZlobFlags.fromInt(flags)) catch |err| switch (err) {
        error.OutOfMemory => return zlob_flags.ZLOB_NOSPACE,
    };
    defer results.deinit();

    return finalizeCompiledSliceResult(&results, pzlob);
}

pub export fn zlob_pattern_match_paths_at_slice(
    p: ?*const anyopaque,
    base_path: *const zlob_slice_t,
    paths: [*]const zlob_slice_t,
    path_count: usize,
    flags: c_int,
    pzlob: *zlob_t,
) c_int {
    const raw = p orelse return zlob_flags.ZLOB_ABORTED;
    const cp = patternConstPtr(raw);

    const zig_paths: []const []const u8 = @ptrCast(paths[0..path_count]);
    const base_slice = base_path.ptr[0..base_path.len];

    var results = compiled_pattern.matchPathsAtCompiled(allocator, base_slice, cp, zig_paths, ZlobFlags.fromInt(flags)) catch |err| switch (err) {
        error.OutOfMemory => return zlob_flags.ZLOB_NOSPACE,
    };
    defer results.deinit();

    return finalizeCompiledSliceResult(&results, pzlob);
}

pub export fn zlob_pattern_match_paths_indices_slice(
    p: ?*const anyopaque,
    paths: [*]const zlob_slice_t,
    path_count: usize,
    flags: c_int,
    out: *zlob_indices_t,
) c_int {
    const raw = p orelse return zlob_flags.ZLOB_ABORTED;
    const cp = patternConstPtr(raw);

    const zig_paths: []const []const u8 = @ptrCast(paths[0..path_count]);

    const indices = compiled_pattern.matchPathIndicesCompiled(allocator, cp, zig_paths, ZlobFlags.fromInt(flags)) catch |err| switch (err) {
        error.OutOfMemory => return zlob_flags.ZLOB_NOSPACE,
    };

    return writeIndicesResult(out, indices);
}

pub export fn zlob_pattern_match_paths_indices_at_slice(
    p: ?*const anyopaque,
    base_path: *const zlob_slice_t,
    paths: [*]const zlob_slice_t,
    path_count: usize,
    flags: c_int,
    out: *zlob_indices_t,
) c_int {
    const raw = p orelse return zlob_flags.ZLOB_ABORTED;
    const cp = patternConstPtr(raw);

    const zig_paths: []const []const u8 = @ptrCast(paths[0..path_count]);
    const base_slice = base_path.ptr[0..base_path.len];

    const indices = compiled_pattern.matchPathIndicesAtCompiled(allocator, base_slice, cp, zig_paths, ZlobFlags.fromInt(flags)) catch |err| switch (err) {
        error.OutOfMemory => return zlob_flags.ZLOB_NOSPACE,
    };

    return writeIndicesResult(out, indices);
}

// ============================================================================
// Parallel file walker C API (see include/zlob.h "Parallel recursive file
// walker" section). Callbacks may run concurrently from worker threads.
// ============================================================================

const walk = zlob_impl.walk;

pub const zlob_walk_errfunc_t = ?*const fn (epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int;
pub const zlob_walk_cb = *const fn (entry: *const zlob_walk_entry_t, ctx: ?*anyopaque) callconv(.c) c_int;

pub const zlob_walk_options_t = extern struct {
    flags: u32 = 0,
    meta_mask: u32 = 0,
    threads: u16 = 0,
    max_depth: u16 = 0,
    errfunc: zlob_walk_errfunc_t = null,
    pattern: ?[*:0]const u8 = null,
    pattern_flags: u32 = 0,
};

pub const zlob_walk_entry_t = extern struct {
    path: [*:0]const u8,
    path_len: usize,
    rel_off: u32,
    basename_off: u32,
    kind: u8,
    depth: u16,
    meta_valid: u32,
    size: u64,
    mtime_ns: i64,
    atime_ns: i64,
    ctime_ns: i64,
    btime_ns: i64,
    inode: u64,
    nlink: u32,
    mode: u32,
    uid: u32,
    gid: u32,
};

pub const zlob_walk_result_t = extern struct {
    entries: ?[*]zlob_walk_entry_t,
    count: usize,
    _storage: ?*anyopaque,
};

// ABI consistency with the C header.
comptime {
    std.debug.assert(@sizeOf(zlob_walk_options_t) == @sizeOf(c_zlob.zlob_walk_options_t));
    std.debug.assert(@sizeOf(zlob_walk_entry_t) == @sizeOf(c_zlob.zlob_walk_entry_t));
    std.debug.assert(@sizeOf(zlob_walk_result_t) == @sizeOf(c_zlob.zlob_walk_result_t));
    std.debug.assert(@offsetOf(zlob_walk_entry_t, "kind") == @offsetOf(c_zlob.zlob_walk_entry_t, "kind"));
    std.debug.assert(@offsetOf(zlob_walk_entry_t, "meta_valid") == @offsetOf(c_zlob.zlob_walk_entry_t, "meta_valid"));
    std.debug.assert(@offsetOf(zlob_walk_entry_t, "gid") == @offsetOf(c_zlob.zlob_walk_entry_t, "gid"));
}

const ZLOB_WALK_GITIGNORE: u32 = 1 << 0;
const ZLOB_WALK_SKIP_HIDDEN: u32 = 1 << 1;
const ZLOB_WALK_FOLLOW_SYMLINKS: u32 = 1 << 2;
const ZLOB_WALK_NO_REPORT_DIRS: u32 = 1 << 3;
const ZLOB_WALK_SORT: u32 = 1 << 4;
const ZLOB_WALK_ABORT_ON_ERROR: u32 = 1 << 5;
const ZLOB_WALK_KEEP_GIT_DIR: u32 = 1 << 6;
const ZLOB_WALK_RETAIN_IGNORE_RULES: u32 = 1 << 7;

fn walkOptionsFromC(options: ?*const zlob_walk_options_t) walk.Options {
    const v: zlob_walk_options_t = if (options) |p| p.* else .{};
    const f = v.flags;
    return .{
        .threads = v.threads,
        .max_depth = v.max_depth,
        .follow_symlinks = f & ZLOB_WALK_FOLLOW_SYMLINKS != 0,
        .include_hidden = f & ZLOB_WALK_SKIP_HIDDEN == 0,
        .respect_git = f & ZLOB_WALK_GITIGNORE != 0,
        .skip_git_dir = f & ZLOB_WALK_KEEP_GIT_DIR == 0,
        .retain_ignore_rules = f & ZLOB_WALK_RETAIN_IGNORE_RULES != 0,
        .report_dirs = f & ZLOB_WALK_NO_REPORT_DIRS == 0,
        .pattern = if (v.pattern) |p| mem.sliceTo(p, 0) else null,
        .pattern_flags = if (v.pattern_flags != 0)
            ZlobFlags.fromU32(v.pattern_flags)
        else
            .{ .brace = true, .doublestar_recursive = true },
        .meta = walk.MetaMask.fromInt(v.meta_mask),
        .sort = f & ZLOB_WALK_SORT != 0,
        .err_callback = v.errfunc,
        .abort_on_error = f & ZLOB_WALK_ABORT_ON_ERROR != 0,
    };
}

inline fn fillCWalkEntry(out: *zlob_walk_entry_t, e: *const walk.Entry) void {
    out.* = .{
        .path = @ptrCast(e.path.ptr),
        .path_len = e.path.len,
        .rel_off = e.rel_off,
        .basename_off = @intCast(e.path.len - e.basename.len),
        .kind = switch (e.kind) {
            .file => 1,
            .directory => 2,
            .sym_link => 3,
            else => 0,
        },
        .depth = e.depth,
        .meta_valid = e.meta.valid.toInt(),
        .size = e.meta.size,
        .mtime_ns = e.meta.mtime_ns,
        .atime_ns = e.meta.atime_ns,
        .ctime_ns = e.meta.ctime_ns,
        .btime_ns = e.meta.btime_ns,
        .inode = e.meta.inode,
        .nlink = e.meta.nlink,
        .mode = e.meta.mode,
        .uid = e.meta.uid,
        .gid = e.meta.gid,
    };
}

const CWalkCtx = struct {
    cb: zlob_walk_cb,
    user: ?*anyopaque,
};

fn cWalkVisit(ctx: ?*anyopaque, entry: *const walk.Entry) walk.VisitAction {
    const c: *const CWalkCtx = @ptrCast(@alignCast(ctx.?));
    var ce: zlob_walk_entry_t = undefined;
    fillCWalkEntry(&ce, entry);
    return switch (c.cb(&ce, c.user)) {
        0 => .cont,
        1 => .skip_dir,
        else => .stop,
    };
}

pub export fn zlob_walk(
    root: [*:0]const u8,
    options: ?*const zlob_walk_options_t,
    cb: zlob_walk_cb,
    ctx: ?*anyopaque,
) c_int {
    const root_slice = mem.sliceTo(root, 0);
    var cctx = CWalkCtx{ .cb = cb, .user = ctx };
    walk.run(allocator, root_slice, walkOptionsFromC(options), .{
        .context = @ptrCast(&cctx),
        .visit = cWalkVisit,
    }) catch |err| return switch (err) {
        error.Aborted => zlob_flags.ZLOB_ABORTED,
        error.OutOfMemory => zlob_flags.ZLOB_NOSPACE,
        error.ReadFailed => zlob_flags.ZLOB_READ_FAILED,
        error.PermissionDenied => zlob_flags.ZLOB_PERMISSION_DENIED,
        error.NameTooLong => zlob_flags.ZLOB_NAME_TOO_LONG,
    };
    return 0;
}

const WalkResultHolder = struct {
    results: walk.WalkerResult,
};

pub export fn zlob_walk_collect(
    root: [*:0]const u8,
    options: ?*const zlob_walk_options_t,
    out: *zlob_walk_result_t,
) c_int {
    out.* = .{ .entries = null, .count = 0, ._storage = null };

    const root_slice = mem.sliceTo(root, 0);
    var results = walk.collect(allocator, root_slice, walkOptionsFromC(options)) catch |err|
        return switch (err) {
            error.Aborted => zlob_flags.ZLOB_ABORTED,
            error.OutOfMemory => zlob_flags.ZLOB_NOSPACE,
            error.ReadFailed => zlob_flags.ZLOB_READ_FAILED,
            error.PermissionDenied => zlob_flags.ZLOB_PERMISSION_DENIED,
            error.NameTooLong => zlob_flags.ZLOB_NAME_TOO_LONG,
        };

    if (results.entries.len == 0) {
        // Keep a holder when reusable ignore rules were retained, even with no
        // entries — the caller still wants to query them.
        if (results.ignore_rules == null) {
            results.deinit();
            return 0;
        }
        const holder = allocator.create(WalkResultHolder) catch {
            results.deinit();
            return zlob_flags.ZLOB_NOSPACE;
        };
        holder.* = .{ .results = results };
        out.* = .{ .entries = null, .count = 0, ._storage = @ptrCast(holder) };
        return 0;
    }

    const holder = allocator.create(WalkResultHolder) catch {
        results.deinit();
        return zlob_flags.ZLOB_NOSPACE;
    };
    holder.* = .{ .results = results };

    const centries = allocator.alloc(zlob_walk_entry_t, results.entries.len) catch {
        holder.results.deinit();
        allocator.destroy(holder);
        return zlob_flags.ZLOB_NOSPACE;
    };
    for (holder.results.entries, centries) |*e, *ce| {
        fillCWalkEntry(ce, e);
    }

    out.* = .{
        .entries = centries.ptr,
        .count = centries.len,
        ._storage = @ptrCast(holder),
    };
    return 0;
}

pub export fn zlob_walk_result_free(result: ?*zlob_walk_result_t) void {
    const r = result orelse return;
    if (r.entries) |entries| {
        allocator.free(entries[0..r.count]);
    }
    if (r._storage) |storage| {
        const holder: *WalkResultHolder = @ptrCast(@alignCast(storage));
        holder.results.deinit();
        allocator.destroy(holder);
    }
    r.* = .{ .entries = null, .count = 0, ._storage = null };
}

/// Borrowed handle to the reusable ignore rules retained during the walk
/// (requires ZLOB_WALK_RETAIN_IGNORE_RULES). Owned by `result`; valid until
/// zlob_walk_result_free(). NULL when no rules were retained.
pub export fn zlob_walk_result_ignore_rules(result: ?*const zlob_walk_result_t) ?*anyopaque {
    const r = result orelse return null;
    const storage = r._storage orelse return null;
    const holder: *WalkResultHolder = @ptrCast(@alignCast(storage));
    return @ptrCast(holder.results.ignore_rules orelse return null);
}

/// Returns nonzero when `path` (walk-root-relative) is ignored by the retained
/// rules. `is_dir` should be nonzero for directories. `rules` is a handle from
/// zlob_walk_result_ignore_rules().
pub export fn zlob_ignore_rules_match(
    rules: ?*anyopaque,
    path: [*:0]const u8,
    is_dir: c_int,
) c_int {
    const r: *const walk.IgnoreRules = @ptrCast(@alignCast(rules orelse return 0));
    return @intFromBool(r.isIgnored(mem.sliceTo(path, 0), is_dir != 0));
}

/// Like zlob_ignore_rules_match but infers directory-ness from the path with
/// zero syscalls: a trailing '/' marks a directory, otherwise a file.
pub export fn zlob_ignore_rules_match_path(
    rules: ?*anyopaque,
    path: [*:0]const u8,
) c_int {
    const r: *const walk.IgnoreRules = @ptrCast(@alignCast(rules orelse return 0));
    return @intFromBool(r.isIgnoredPath(mem.sliceTo(path, 0)));
}

/// Like zlob_ignore_rules_match but lstat()s `path` to determine
/// directory-ness (symlinks not followed). A missing/unstattable path is
/// treated as a non-directory. One syscall.
pub export fn zlob_ignore_rules_match_untrusted(
    rules: ?*anyopaque,
    path: [*:0]const u8,
) c_int {
    const r: *const walk.IgnoreRules = @ptrCast(@alignCast(rules orelse return 0));
    return @intFromBool(r.isIgnoredUntrusted(mem.sliceTo(path, 0)));
}
