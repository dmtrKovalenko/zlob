//! Bytewise sorting for glob paths and walker records.
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Thread = @import("walker/thread.zig").Thread;

fn simdStrCmp(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (min_len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = @Int(.unsigned, vec_len);
        const all_ones: MaskInt = @as(MaskInt, 0) -% 1;

        var i: usize = 0;
        while (i + vec_len <= min_len) : (i += vec_len) {
            const a_vec: Vec = a[i..][0..vec_len].*;
            const b_vec: Vec = b[i..][0..vec_len].*;
            const eq = a_vec == b_vec;
            const mask = @as(MaskInt, @bitCast(eq));

            if (mask != all_ones) {
                const first_diff = @ctz(~mask);
                const a_byte = a[i + first_diff];
                const b_byte = b[i + first_diff];
                if (a_byte < b_byte) return .lt;
                return .gt;
            }
        }
        for (a[i..min_len], b[i..min_len]) |ab, bb| {
            if (ab < bb) return .lt;
            if (ab > bb) return .gt;
        }
    } else {
        for (a[0..min_len], b[0..min_len]) |ab, bb| {
            if (ab < bb) return .lt;
            if (ab > bb) return .gt;
        }
    }

    return std.math.order(a.len, b.len);
}

/// Sort context for in-place pdqsort of parallel paths + lengths arrays.
/// Implements the swap/lessThan interface expected by std.mem.sortUnstableContext.
const PathSortCtx = struct {
    paths: [*][*c]u8,
    lengths: [*]usize,

    pub fn swap(ctx: PathSortCtx, a: usize, b: usize) void {
        const tmp_path = ctx.paths[a];
        ctx.paths[a] = ctx.paths[b];
        ctx.paths[b] = tmp_path;

        const tmp_len = ctx.lengths[a];
        ctx.lengths[a] = ctx.lengths[b];
        ctx.lengths[b] = tmp_len;
    }

    pub fn lessThan(ctx: PathSortCtx, a: usize, b: usize) bool {
        const slice_a = @as([*]const u8, @ptrCast(ctx.paths[a]))[0..ctx.lengths[a]];
        const slice_b = @as([*]const u8, @ptrCast(ctx.paths[b]))[0..ctx.lengths[b]];
        return simdStrCmp(slice_a, slice_b) == .lt;
    }
};

/// Sort path pointers and their lengths in place.
pub fn sortPaths(paths: [*][*c]u8, lengths: [*]usize, count: usize) void {
    if (count <= 1) return;
    std.mem.sortUnstableContext(0, count, PathSortCtx{
        .paths = paths,
        .lengths = lengths,
    });
}

const Keys = []const []const u8;

/// Partitions at or below this size finish with insertion sort.
const insertion_max = 12;
/// Partitions above this size may be pushed to the pool instead of sorted inline.
const par_min = 2048;
/// Never spawn more helper threads than this (plus the calling thread).
const max_helpers = 15;

/// Sort records by path. Optimized for paths with shared prefixes.
/// Sorts indices first and moves each record once. Large inputs can use helpers.
/// For fewer than two records, returns `entries` directly. Otherwise, frees
/// `entries` on success. On error, the caller still owns `entries`.
pub fn sortPathsParallel(
    comptime Record: type,
    comptime path: fn (*const Record) callconv(.@"inline") []const u8,
    allocator: Allocator,
    io: std.Io,
    entries: []Record,
    threads: u32,
) Allocator.Error![]Record {
    const n = entries.len;
    if (n < 2) return entries;
    // The permutation is a u32 index; more entries than that would truncate.
    if (n > std.math.maxInt(u32)) return error.OutOfMemory;

    // Compact 16-byte keys instead of touching whole records in the hot loop.
    const keys = try allocator.alloc([]const u8, n);
    defer allocator.free(keys);
    for (keys, entries) |*k, *e| k.* = path(e);

    const idx = try allocator.alloc(u32, n);
    defer allocator.free(idx);
    for (idx, 0..) |*v, i| v.* = @intCast(i);

    const helpers: u32 = if (threads > 1 and n >= 2 * par_min) @min(threads - 1, max_helpers) else 0;
    if (helpers == 0) {
        mkqs(keys, idx, 0);
    } else {
        parallelSort(allocator, io, keys, idx, helpers);
    }

    // Apply the permutation: one record move per entry, sequential writes.
    const sorted = try allocator.alloc(Record, n);
    for (sorted, idx) |*dst, src| dst.* = entries[src];
    allocator.free(entries);
    return sorted;
}

inline fn charAt(k: []const u8, d: usize) i32 {
    return if (d < k.len) @as(i32, k[d]) else -1;
}

inline fn suffix(k: []const u8, d: usize) []const u8 {
    return if (d < k.len) k[d..] else k[k.len..];
}

inline fn med3(a: i32, b: i32, c: i32) i32 {
    if (a < b) {
        if (b < c) return b;
        return if (a < c) c else a;
    }
    if (a < c) return a;
    return if (b < c) c else b;
}

const Split = struct { lt: usize, gt: usize, pv: i32 };

/// Three-way partition of `a` on the byte at depth `d`:
/// `a[0..lt] < pv`, `a[lt..gt] == pv`, `a[gt..] > pv`.
fn partition(keys: Keys, a: []u32, d: usize) Split {
    const pv = med3(
        charAt(keys[a[0]], d),
        charAt(keys[a[a.len / 2]], d),
        charAt(keys[a[a.len - 1]], d),
    );
    var lt: usize = 0;
    var i: usize = 0;
    var gt: usize = a.len;
    while (i < gt) {
        const c = charAt(keys[a[i]], d);
        if (c < pv) {
            mem.swap(u32, &a[lt], &a[i]);
            lt += 1;
            i += 1;
        } else if (c > pv) {
            gt -= 1;
            mem.swap(u32, &a[i], &a[gt]);
        } else {
            i += 1;
        }
    }
    return .{ .lt = lt, .gt = gt, .pv = pv };
}

fn insertionSort(keys: Keys, a: []u32, d: usize) void {
    var i: usize = 1;
    while (i < a.len) : (i += 1) {
        const v = a[i];
        const kv = suffix(keys[v], d);
        var j = i;
        while (j > 0 and mem.order(u8, suffix(keys[a[j - 1]], d), kv) == .gt) : (j -= 1) {
            a[j] = a[j - 1];
        }
        a[j] = v;
    }
}

/// Serial multikey quicksort of the index slice `a` whose keys all agree on
/// the first `d` bytes. Recurses into the two smaller partitions and loops on
/// the largest, so the stack depth is bounded by log2(len).
fn mkqs(keys: Keys, a_in: []u32, d_in: usize) void {
    var a = a_in;
    var d = d_in;
    while (a.len > insertion_max) {
        const s = partition(keys, a, d);
        const l = a[0..s.lt];
        const e = a[s.lt..s.gt];
        const g = a[s.gt..];
        if (s.pv < 0) {
            // `e` holds keys that end at `d`: all identical, already in place.
            if (l.len >= g.len) {
                mkqs(keys, g, d);
                a = l;
            } else {
                mkqs(keys, l, d);
                a = g;
            }
        } else if (l.len >= e.len and l.len >= g.len) {
            mkqs(keys, e, d + 1);
            mkqs(keys, g, d);
            a = l;
        } else if (e.len >= g.len) {
            mkqs(keys, l, d);
            mkqs(keys, g, d);
            a = e;
            d += 1;
        } else {
            mkqs(keys, l, d);
            mkqs(keys, e, d + 1);
            a = g;
        }
    }
    insertionSort(keys, a, d);
}

const Task = struct { lo: u32, hi: u32, depth: u32 };
const Pool = struct {
    keys: Keys,
    idx: []u32,
    allocator: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    tasks: std.ArrayList(Task) = .empty,
    /// Tasks pushed but not yet finished; the pool drains when it hits zero.
    pending: u32 = 0,

    /// Returns false (and does nothing) when the task list cannot grow; the
    /// caller then sorts the range inline so correctness never depends on it.
    fn push(p: *Pool, t: Task) bool {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        p.tasks.append(p.allocator, t) catch return false;
        p.pending += 1;
        p.cond.signal(p.io);
        return true;
    }

    fn threadMain(ctx: *anyopaque) void {
        const p: *Pool = @ptrCast(@alignCast(ctx));
        p.work();
    }

    fn work(p: *Pool) void {
        p.mutex.lockUncancelable(p.io);
        while (true) {
            if (p.tasks.pop()) |t| {
                p.mutex.unlock(p.io);
                p.runTask(t);
                p.mutex.lockUncancelable(p.io);
                p.pending -= 1;
                if (p.pending == 0) p.cond.broadcast(p.io);
            } else if (p.pending == 0) {
                p.mutex.unlock(p.io);
                return;
            } else {
                p.cond.waitUncancelable(p.io, &p.mutex);
            }
        }
    }

    /// Hand a sub-partition to the pool when it is worth it, otherwise sort it now.
    fn spawnOrSort(p: *Pool, lo: usize, hi: usize, d: usize) void {
        if (hi - lo <= par_min or !p.push(.{ .lo = @intCast(lo), .hi = @intCast(hi), .depth = @intCast(d) })) {
            mkqs(p.keys, p.idx[lo..hi], d);
        }
    }

    fn runTask(p: *Pool, t: Task) void {
        var lo: usize = t.lo;
        var hi: usize = t.hi;
        var d: usize = t.depth;
        while (hi - lo > par_min) {
            const s = partition(p.keys, p.idx[lo..hi], d);
            const l_lo = lo;
            const l_hi = lo + s.lt;
            const e_lo = l_hi;
            const e_hi = lo + s.gt;
            const g_lo = e_hi;
            const g_hi = hi;
            const l_len = l_hi - l_lo;
            const e_len = e_hi - e_lo;
            const g_len = g_hi - g_lo;
            if (s.pv < 0) {
                // Ended keys in `e` are identical: nothing to do for them.
                if (l_len >= g_len) {
                    p.spawnOrSort(g_lo, g_hi, d);
                    lo = l_lo;
                    hi = l_hi;
                } else {
                    p.spawnOrSort(l_lo, l_hi, d);
                    lo = g_lo;
                    hi = g_hi;
                }
            } else if (l_len >= e_len and l_len >= g_len) {
                p.spawnOrSort(e_lo, e_hi, d + 1);
                p.spawnOrSort(g_lo, g_hi, d);
                lo = l_lo;
                hi = l_hi;
            } else if (e_len >= g_len) {
                p.spawnOrSort(l_lo, l_hi, d);
                p.spawnOrSort(g_lo, g_hi, d);
                lo = e_lo;
                hi = e_hi;
                d += 1;
            } else {
                p.spawnOrSort(l_lo, l_hi, d);
                p.spawnOrSort(e_lo, e_hi, d + 1);
                lo = g_lo;
                hi = g_hi;
            }
        }
        mkqs(p.keys, p.idx[lo..hi], d);
    }
};

fn parallelSort(allocator: Allocator, io: std.Io, keys: Keys, idx: []u32, helpers: u32) void {
    var pool: Pool = .{ .keys = keys, .idx = idx, .allocator = allocator, .io = io };
    defer pool.tasks.deinit(allocator);
    // Reserve room for tasks before the helpers start.
    pool.tasks.ensureTotalCapacity(allocator, 256) catch {};
    if (!pool.push(.{ .lo = 0, .hi = @intCast(idx.len), .depth = 0 })) {
        mkqs(keys, idx, 0);
        return;
    }

    var threads: [max_helpers]Thread = undefined;
    var spawned: usize = 0;
    // A failed spawn is not fatal: the remaining threads (this one at minimum)
    // drain the pool, just with less parallelism.
    for (threads[0..helpers]) |*t| {
        // Default stack: mkqs recursion is bounded by log2(n) small frames.
        t.* = Thread.spawn(Pool.threadMain, @ptrCast(&pool), 0) catch break;
        spawned += 1;
    }
    pool.work();
    for (threads[0..spawned]) |t| t.join();
}

const testing = std.testing;

test "simdStrCmp - equal strings" {
    try testing.expectEqual(std.math.Order.eq, simdStrCmp("hello", "hello"));
    try testing.expectEqual(std.math.Order.eq, simdStrCmp("", ""));
    try testing.expectEqual(std.math.Order.eq, simdStrCmp("a", "a"));
}

test "simdStrCmp - less than" {
    try testing.expectEqual(std.math.Order.lt, simdStrCmp("a", "b"));
    try testing.expectEqual(std.math.Order.lt, simdStrCmp("abc", "abd"));
    try testing.expectEqual(std.math.Order.lt, simdStrCmp("abc", "abcd"));
    try testing.expectEqual(std.math.Order.lt, simdStrCmp("", "a"));
}

test "simdStrCmp - greater than" {
    try testing.expectEqual(std.math.Order.gt, simdStrCmp("b", "a"));
    try testing.expectEqual(std.math.Order.gt, simdStrCmp("abd", "abc"));
    try testing.expectEqual(std.math.Order.gt, simdStrCmp("abcd", "abc"));
    try testing.expectEqual(std.math.Order.gt, simdStrCmp("a", ""));
}

test "simdStrCmp - long strings with SIMD" {
    const a = "this is a fairly long string that should use SIMD comparison";
    const b = "this is a fairly long string that should use SIMD comparison";
    const c = "this is a fairly long string that should use SIMD comparisoN";

    try testing.expectEqual(std.math.Order.eq, simdStrCmp(a, b));
    try testing.expectEqual(std.math.Order.gt, simdStrCmp(a, c)); // 'n' > 'N'
}

test "sortPaths - basic sorting" {
    var paths: [3][*c]u8 = undefined;
    var lengths: [3]usize = undefined;

    var str1: [10:0]u8 = "charlie\x00\x00\x00".*;
    var str2: [10:0]u8 = "alpha\x00\x00\x00\x00\x00".*;
    var str3: [10:0]u8 = "bravo\x00\x00\x00\x00\x00".*;

    paths[0] = &str1;
    paths[1] = &str2;
    paths[2] = &str3;
    lengths[0] = 7;
    lengths[1] = 5;
    lengths[2] = 5;

    sortPaths(&paths, &lengths, 3);

    const sorted0 = @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]];
    const sorted1 = @as([*]const u8, @ptrCast(paths[1]))[0..lengths[1]];
    const sorted2 = @as([*]const u8, @ptrCast(paths[2]))[0..lengths[2]];

    try testing.expectEqualStrings("alpha", sorted0);
    try testing.expectEqualStrings("bravo", sorted1);
    try testing.expectEqualStrings("charlie", sorted2);
}

test "sortPaths - empty and single element" {
    var paths: [1][*c]u8 = undefined;
    var lengths: [1]usize = undefined;

    // Empty case
    sortPaths(&paths, &lengths, 0);

    // Single element case
    var str: [5:0]u8 = "test\x00".*;
    paths[0] = &str;
    lengths[0] = 4;
    sortPaths(&paths, &lengths, 1);

    const result = @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]];
    try testing.expectEqualStrings("test", result);
}

test "sortPaths - already sorted" {
    var paths: [3][*c]u8 = undefined;
    var lengths: [3]usize = undefined;

    var str1: [6:0]u8 = "alpha\x00".*;
    var str2: [6:0]u8 = "bravo\x00".*;
    var str3: [8:0]u8 = "charlie\x00".*;

    paths[0] = &str1;
    paths[1] = &str2;
    paths[2] = &str3;
    lengths[0] = 5;
    lengths[1] = 5;
    lengths[2] = 7;

    sortPaths(&paths, &lengths, 3);

    try testing.expectEqualStrings("alpha", @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]]);
    try testing.expectEqualStrings("bravo", @as([*]const u8, @ptrCast(paths[1]))[0..lengths[1]]);
    try testing.expectEqualStrings("charlie", @as([*]const u8, @ptrCast(paths[2]))[0..lengths[2]]);
}

test "sortPaths - reverse sorted" {
    var paths: [3][*c]u8 = undefined;
    var lengths: [3]usize = undefined;

    var str1: [8:0]u8 = "charlie\x00".*;
    var str2: [6:0]u8 = "bravo\x00".*;
    var str3: [6:0]u8 = "alpha\x00".*;

    paths[0] = &str1;
    paths[1] = &str2;
    paths[2] = &str3;
    lengths[0] = 7;
    lengths[1] = 5;
    lengths[2] = 5;

    sortPaths(&paths, &lengths, 3);

    try testing.expectEqualStrings("alpha", @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]]);
    try testing.expectEqualStrings("bravo", @as([*]const u8, @ptrCast(paths[1]))[0..lengths[1]]);
    try testing.expectEqualStrings("charlie", @as([*]const u8, @ptrCast(paths[2]))[0..lengths[2]]);
}

test "sortPaths - POSIX byte ordering (paths with slashes)" {
    var paths: [4][*c]u8 = undefined;
    var lengths: [4]usize = undefined;

    var s1: [12:0]u8 = "dir/file.c\x00\x00".*;
    var s2: [14:0]u8 = "dir/subdir/a\x00\x00".*;
    var s3: [10:0]u8 = "dir/aaa.c\x00".*;
    var s4: [8:0]u8 = "abc.txt\x00".*;

    paths[0] = &s1;
    paths[1] = &s2;
    paths[2] = &s3;
    paths[3] = &s4;
    lengths[0] = 10;
    lengths[1] = 12;
    lengths[2] = 9;
    lengths[3] = 7;

    sortPaths(&paths, &lengths, 4);

    try testing.expectEqualStrings("abc.txt", @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]]);
    try testing.expectEqualStrings("dir/aaa.c", @as([*]const u8, @ptrCast(paths[1]))[0..lengths[1]]);
    try testing.expectEqualStrings("dir/file.c", @as([*]const u8, @ptrCast(paths[2]))[0..lengths[2]]);
    try testing.expectEqualStrings("dir/subdir/a", @as([*]const u8, @ptrCast(paths[3]))[0..lengths[3]]);
}

test "sortPaths - duplicate paths" {
    var paths: [4][*c]u8 = undefined;
    var lengths: [4]usize = undefined;

    var s1: [6:0]u8 = "bravo\x00".*;
    var s2: [6:0]u8 = "alpha\x00".*;
    var s3: [6:0]u8 = "bravo\x00".*;
    var s4: [6:0]u8 = "alpha\x00".*;

    paths[0] = &s1;
    paths[1] = &s2;
    paths[2] = &s3;
    paths[3] = &s4;
    lengths[0] = 5;
    lengths[1] = 5;
    lengths[2] = 5;
    lengths[3] = 5;

    sortPaths(&paths, &lengths, 4);

    try testing.expectEqualStrings("alpha", @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]]);
    try testing.expectEqualStrings("alpha", @as([*]const u8, @ptrCast(paths[1]))[0..lengths[1]]);
    try testing.expectEqualStrings("bravo", @as([*]const u8, @ptrCast(paths[2]))[0..lengths[2]]);
    try testing.expectEqualStrings("bravo", @as([*]const u8, @ptrCast(paths[3]))[0..lengths[3]]);
}
