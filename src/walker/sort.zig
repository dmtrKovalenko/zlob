//! `Options.sort` implementation for collected walker entries.
//!
//! `std.sort.pdq(Entry, ..)` with a by-value comparator on full paths cost
//! 5-15x the walk itself on large trees: every compare copied two 120-byte
//! Entries and rescanned the shared root prefix plus the long common directory
//! prefix, and every swap moved 120 bytes. Here we sort a u32 permutation over
//! the root-relative paths with Bentley-Sedgewick multikey (ternary) quicksort:
//! each byte of a shared prefix is examined once per partition instead of once
//! per compare, swaps are 4 bytes, and the permutation is applied with a single
//! gather (one Entry move per element). The order is identical to a byte-wise
//! sort of the full paths because every entry carries the same root prefix.
//!
//! When the collect ran with several threads, partitions larger than `par_min`
//! are handed to a small pool (task stack + condvar) so the sort scales with
//! the walk; below that size everything is sorted inline.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const thread_mod = @import("thread.zig");

const Entry = types.Entry;
const Thread = thread_mod.Thread;
const Keys = []const []const u8;

/// Partitions at or below this size finish with insertion sort.
const insertion_max = 12;
/// Partitions above this size may be pushed to the pool instead of sorted inline.
const par_min = 2048;
/// Never spawn more helper threads than this (plus the calling thread).
const max_helpers = 15;

/// Sort `entries` by path and return the sorted array, freeing `entries` on
/// success. On error `entries` is untouched and still owned by the caller.
/// `threads` is the walk's worker count; helper threads are spawned only for
/// `threads > 1` and inputs large enough to split.
pub fn sortEntries(gpa: Allocator, io: std.Io, entries: []Entry, threads: u32) Allocator.Error![]Entry {
    return sortAs(Entry, Entry.relativePath, gpa, io, entries, threads);
}

/// `sortEntries` for any record type a `collectAs` adapter materializes:
/// `key` returns the record's root-relative path (every record shares the
/// same root prefix, so ordering by it equals ordering by the full path).
pub fn sortAs(
    comptime Out: type,
    comptime key: fn (*const Out) callconv(.@"inline") []const u8,
    gpa: Allocator,
    io: std.Io,
    entries: []Out,
    threads: u32,
) Allocator.Error![]Out {
    const n = entries.len;
    if (n < 2) return entries;

    // Compact 16-byte keys instead of touching whole records in the hot loop.
    const keys = try gpa.alloc([]const u8, n);
    defer gpa.free(keys);
    for (keys, entries) |*k, *e| k.* = key(e);

    const idx = try gpa.alloc(u32, n);
    defer gpa.free(idx);
    for (idx, 0..) |*v, i| v.* = @intCast(i);

    const helpers: u32 = if (threads > 1 and n >= 2 * par_min) @min(threads - 1, max_helpers) else 0;
    if (helpers == 0) {
        mkqs(keys, idx, 0);
    } else {
        parallelSort(gpa, io, keys, idx, helpers);
    }

    // Apply the permutation: one record move per entry, sequential writes.
    const sorted = try gpa.alloc(Out, n);
    for (sorted, idx) |*dst, src| dst.* = entries[src];
    gpa.free(entries);
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

// ---------------------------------------------------------------------------
// Parallel variant: a task stack of (range, depth) shared by a few threads.
// ---------------------------------------------------------------------------

const Task = struct { lo: u32, hi: u32, depth: u32 };

const Pool = struct {
    keys: Keys,
    idx: []u32,
    gpa: Allocator,
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
        p.tasks.append(p.gpa, t) catch return false;
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

fn parallelSort(gpa: Allocator, io: std.Io, keys: Keys, idx: []u32, helpers: u32) void {
    var pool: Pool = .{ .keys = keys, .idx = idx, .gpa = gpa, .io = io };
    defer pool.tasks.deinit(gpa);
    // Growing the task list under the lock is rare after this.
    pool.tasks.ensureTotalCapacity(gpa, 256) catch {};
    // Cannot fail: capacity was reserved above, and even if it were not the
    // fallback would be an inline sort of the whole input.
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
