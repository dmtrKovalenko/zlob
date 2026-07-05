const std = @import("std");
const Allocator = std.mem.Allocator;

const worker = @import("worker.zig");
const HandleRef = worker.HandleRef;
const IgnoreNode = worker.IgnoreNode;
const WalkError = @import("types.zig").WalkError;

pub const DirTask = struct {
    /// Root-relative directory path ("" = the root itself). Owned.
    rel: []u8,
    depth: u16,
    /// Nearest .gitignore chain (one ref owned by the task).
    ignore: ?*IgnoreNode,
    /// Parent directory handle the child opens relative to (one ref owned by
    /// the task). Null for the root task.
    parent: ?*HandleRef,
};

const LocalQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(*DirTask) = .empty,
    approx_len: std.atomic.Value(usize) = .init(0),

    fn deinit(lq: *LocalQueue, gpa: Allocator) void {
        lq.items.deinit(gpa);
    }
};

/// Work stealing queue for per worker walking, optimized for as least contention as possible
pub const Queue = struct {
    locals: []LocalQueue = &.{},
    wait_mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queued: std.atomic.Value(usize) = .init(0),
    /// Tasks pushed but not finished, including queued and in-flight
    outstanding: std.atomic.Value(usize) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),

    pub fn init(q: *Queue, gpa: Allocator, workers: u32) !void {
        const n: usize = @max(1, @as(usize, @intCast(workers)));
        q.locals = try gpa.alloc(LocalQueue, n);
        for (q.locals) |*local| local.* = .{};
    }

    pub fn deinit(q: *Queue, gpa: Allocator) void {
        for (q.locals) |*local| local.deinit(gpa);
        gpa.free(q.locals);
    }

    pub fn push(q: *Queue, gpa: Allocator, io: std.Io, worker_id: u32, t: *DirTask) !void {
        const local = &q.locals[q.localIndex(worker_id)];
        local.mutex.lockUncancelable(io);
        errdefer local.mutex.unlock(io);
        try local.items.append(gpa, t);
        _ = local.approx_len.fetchAdd(1, .release);
        _ = q.outstanding.fetchAdd(1, .release);
        const queued_before = q.queued.fetchAdd(1, .release);
        local.mutex.unlock(io);
        if (queued_before < q.locals.len) q.wakeOne(io);
    }

    pub fn pop(q: *Queue, io: std.Io, worker_id: u32) ?*DirTask {
        const home = q.localIndex(worker_id);
        while (true) {
            if (q.popFrom(io, home)) |task| return task;
            if (q.steal(io, home)) |task| return task;
            if (q.closed.load(.acquire)) return null;

            q.wait_mutex.lockUncancelable(io);
            while (q.queued.load(.acquire) == 0 and !q.closed.load(.acquire)) {
                q.cond.waitUncancelable(io, &q.wait_mutex);
            }
            q.wait_mutex.unlock(io);
        }
    }

    pub fn taskDone(q: *Queue, io: std.Io) void {
        if (q.outstanding.fetchSub(1, .acq_rel) == 1) {
            q.closed.store(true, .release);
            q.wakeAll(io);
        }
    }

    pub fn wakeAll(q: *Queue, io: std.Io) void {
        q.wait_mutex.lockUncancelable(io);
        defer q.wait_mutex.unlock(io);
        q.cond.broadcast(io);
    }

    fn wakeOne(q: *Queue, io: std.Io) void {
        q.wait_mutex.lockUncancelable(io);
        defer q.wait_mutex.unlock(io);
        q.cond.signal(io);
    }

    fn localIndex(q: *Queue, worker_id: u32) usize {
        return @as(usize, @intCast(worker_id)) % q.locals.len;
    }

    fn popFrom(q: *Queue, io: std.Io, index: usize) ?*DirTask {
        const local = &q.locals[index];
        if (local.approx_len.load(.acquire) == 0) return null;
        local.mutex.lockUncancelable(io);
        defer local.mutex.unlock(io);
        if (local.items.items.len == 0) return null;
        const task = local.items.pop();
        _ = local.approx_len.fetchSub(1, .release);
        _ = q.queued.fetchSub(1, .acq_rel);
        return task;
    }

    fn steal(q: *Queue, io: std.Io, home: usize) ?*DirTask {
        var offset: usize = 1;
        while (offset < q.locals.len) : (offset += 1) {
            const index = (home + offset) % q.locals.len;
            if (q.locals[index].approx_len.load(.acquire) == 0) continue;
            if (q.popFrom(io, index)) |task| return task;
        }
        return null;
    }
};
