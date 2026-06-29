const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const worker = @import("worker.zig");
const scan = @import("scan.zig");
const compiled_pattern = @import("../compiled_pattern.zig");

const SharedWorkerState = worker.SharedWorkerState;
const Worker = worker.Worker;
const DirTask = @import("queue.zig").DirTask;
const CompiledPattern = compiled_pattern.CompiledPattern;

pub const Backend = types.Backend;
pub const backend = types.backend;
pub const MetaMask = types.MetaMask;
pub const Metadata = types.Metadata;
pub const Entry = types.Entry;
pub const EntryKind = types.EntryKind;
pub const VisitAction = types.VisitAction;
pub const Visitor = types.Visitor;
pub const Options = types.Options;
pub const ErrCallbackFn = types.ErrCallbackFn;
pub const ZlobFlags = types.ZlobFlags;
pub const GitIgnore = @import("../gitignore.zig").GitIgnore;
pub const IgnoreRules = @import("ignore_rules.zig").IgnoreRules;

pub const WalkError = types.WalkError;

pub const WalkerResult = struct {
    entries: []Entry,
    chunks: [][]u8,
    allocator: Allocator,
    /// Reusable ignore rules, present only when `Options.retain_ignore_rules`
    /// was set. Owned by these results; valid until `deinit`.
    ignore_rules: ?*IgnoreRules = null,

    pub fn deinit(self: *WalkerResult) void {
        if (self.ignore_rules) |r| {
            r.deinit();
            self.allocator.destroy(r);
        }
        for (self.chunks) |c| self.allocator.free(c);
        self.allocator.free(self.chunks);
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

fn runSink(ctx: *anyopaque, walk_id: u32, entry: *const Entry) VisitAction {
    _ = walk_id;
    // std.debug.print("sink from walker {}: {}", ctx, walk_id);
    const v: *const Visitor = @ptrCast(@alignCast(ctx));
    return v.visit(v.context, entry);
}

/// Streaming parallel walk: the visitor is called for every entry, from
///jmultiple threads when `options.threads != 1`.
///
/// Entry slices are valid only during the callback.
pub fn run(gpa: Allocator, root: []const u8, options: Options, visitor: Visitor) WalkError!void {
    var v = visitor;
    return walkImpl(gpa, root, options, runSink, &v, effectiveThreads(&options), null);
}

/// Walks and returns all entries. Optimized for allocation, so use this only if you need in-memory result
pub fn collect(gpa: Allocator, root: []const u8, options: Options) WalkError!WalkerResult {
    const n_workers = effectiveThreads(&options);

    var col = Collector{ .sinks = try gpa.alloc(WorkerSink, n_workers) };
    for (col.sinks) |*ws| ws.* = .{ .gpa = gpa };
    defer {
        for (col.sinks) |*ws| ws.deinit();
        gpa.free(col.sinks);
    }

    const want_rules = options.respect_git and options.retain_ignore_rules;
    var rules: ?*IgnoreRules = null;
    if (want_rules) {
        rules = try gpa.create(IgnoreRules);
        rules.?.* = .{ .gpa = gpa };
    }
    errdefer if (rules) |r| {
        r.deinit();
        gpa.destroy(r);
    };

    try walkImpl(gpa, root, options, collectSink, @ptrCast(&col), n_workers, rules);

    var failed = false;
    var total: usize = 0;
    for (col.sinks) |*ws| {
        if (ws.failed) failed = true;
        total += ws.entries.items.len;
    }
    if (failed) return error.OutOfMemory;

    const entries = try gpa.alloc(Entry, total);
    errdefer gpa.free(entries);
    var n_chunks: usize = 0;
    for (col.sinks) |*ws| n_chunks += ws.chunks.items.len;
    const chunks = try gpa.alloc([]u8, n_chunks);

    var ei: usize = 0;
    var ci: usize = 0;
    for (col.sinks) |*ws| {
        @memcpy(entries[ei..][0..ws.entries.items.len], ws.entries.items);
        ei += ws.entries.items.len;
        @memcpy(chunks[ci..][0..ws.chunks.items.len], ws.chunks.items);
        ci += ws.chunks.items.len;
        ws.chunks.clearRetainingCapacity(); // ownership moved to Results
    }

    if (options.sort) std.sort.pdq(Entry, entries, {}, entryLessThan);

    return .{ .entries = entries, .chunks = chunks, .allocator = gpa, .ignore_rules = rules };
}

fn effectiveThreads(opts: *const Options) u32 {
    if (opts.threads != 0) return @min(opts.threads, 1024);
    const n = std.Thread.getCpuCount() catch 1;
    // Directory enumeration is syscall-bound and contends on per-process and
    // per-mount kernel locks (the fd table, vnode/namecache locks). Beyond a
    // low count more workers only fight over those locks: on macOS throughput
    // peaks around 4 threads and regresses below single-threaded past ~8 on
    // large trees. Linux scales further before the dcache lock bites.
    const cap: u32 = if (backend == .darwin_bulk) 4 else 16;
    return @intCast(@min(@max(n, 1), cap));
}

fn walkImpl(
    allocator: Allocator,
    root: []const u8,
    options: Options,
    sink: worker.SinkFn,
    sink_ctx: *anyopaque,
    n_workers: u32,
    retain: ?*IgnoreRules,
) WalkError!void {
    const MAX_PATH = types.MAX_PATH;

    // Root prefix: root/ (or "" for an empty root meaning cwd-relative
    // output, or "root" when it already ends with /).
    var prefix_buf: [MAX_PATH]u8 = undefined;
    var prefix_len: usize = 0;
    if (root.len > 0) {
        if (root.len >= MAX_PATH - 1) {
            // Root doesn't fit the path-assembly buffer; report it like any
            // other directory error and produce an empty walk.
            if (options.err_callback) |cb| {
                var path_z: [MAX_PATH:0]u8 = undefined;
                @memcpy(path_z[0 .. MAX_PATH - 1], root[0 .. MAX_PATH - 1]);
                path_z[MAX_PATH - 1] = 0;
                if (cb(&path_z, worker.errnoFromOpenError(error.NameTooLong)) != 0)
                    return error.Aborted;
            }
            if (options.abort_on_error) return error.Aborted;
            return;
        }
        @memcpy(prefix_buf[0..root.len], root);
        prefix_len = root.len;
        if (root[root.len - 1] != '/') {
            prefix_buf[prefix_len] = '/';
            prefix_len += 1;
        }
    }

    var compiled: ?CompiledPattern = null;
    if (options.pattern) |p| {
        compiled = compiled_pattern.compilePattern(allocator, p, options.pattern_flags) catch
            return error.OutOfMemory;
    }
    defer if (compiled) |*c| c.deinit();

    var sh = SharedWorkerState{
        .allocator = allocator,
        .io = options.io orelse std.Io.Threaded.global_single_threaded.io(),
        .options = options,
        .root_path = root,
        .root_path_with_slash = prefix_buf[0..prefix_len],
        .root_prefix_len = @intCast(prefix_len),
        .sink = sink,
        .sink_ctx = sink_ctx,
        .pattern = if (compiled) |*c| c else null,
        .pattern_prefix = if (options.pattern) |p|
            worker.literalPatternPrefixDirs(p, options.pattern_flags)
        else
            &.{},
        .statx_mask = scan.linuxStatxMask(options.meta),
        .retain = retain,
    };
    try sh.queue.init(allocator, n_workers);
    defer {
        sh.queue.deinit(allocator);
        sh.visited.deinit(allocator);
    }

    if (options.follow_symlinks) worker.recordRootVisited(&sh);

    // All fallible allocations happen before the root task is queued so an
    // early error can't leak in-flight tasks.
    const workers = try allocator.alloc(Worker, n_workers);
    defer allocator.free(workers);
    var inited: usize = 0;
    defer for (workers[0..inited]) |*w| w.deinit();
    for (workers, 0..) |*w, i| {
        try w.init(@intCast(i), &sh);
        inited += 1;
    }

    const threads: []std.Thread = if (n_workers > 1)
        try allocator.alloc(std.Thread, n_workers - 1)
    else
        &.{};
    defer if (threads.len > 0) allocator.free(threads);

    sh.workers = workers;
    sh.threads = threads;

    const root_task = try allocator.create(DirTask);
    root_task.* = .{ .rel = try allocator.dupe(u8, ""), .depth = 0, .ignore = null, .parent = null };
    sh.queue.push(allocator, sh.io, 0, root_task) catch |err| {
        worker.freeTask(&sh, root_task);
        return err;
    };

    // Worker 0 is the calling thread; it spawns the rest on demand so shallow
    // trees never create a single helper thread.
    worker.workerLoop(&sh, &workers[0]);
    for (sh.threads[0..sh.spawned]) |t| t.join();

    return sh.failureResult();
}

const CHUNK_SIZE = 256 * 1024;

const Collector = struct { sinks: []WorkerSink };

const WorkerSink = struct {
    gpa: Allocator,
    chunks: std.ArrayList([]u8) = .empty,
    cur: []u8 = &.{},
    off: usize = 0,
    entries: std.ArrayList(Entry) = .empty,
    failed: bool = false,

    /// Copies the path (plus NUL) into chunk storage; returns the stable slice.
    fn storePath(ws: *WorkerSink, path: []const u8) ?[]const u8 {
        const need = path.len + 1;
        if (ws.cur.len - ws.off < need) {
            const size = @max(CHUNK_SIZE, need);
            const chunk = ws.gpa.alloc(u8, size) catch return null;
            ws.chunks.append(ws.gpa, chunk) catch {
                ws.gpa.free(chunk);
                return null;
            };
            ws.cur = chunk;
            ws.off = 0;
        }
        const dst = ws.cur[ws.off..][0..path.len];
        @memcpy(dst, path);
        ws.cur[ws.off + path.len] = 0;
        ws.off += need;
        return dst;
    }

    fn deinit(ws: *WorkerSink) void {
        for (ws.chunks.items) |c| ws.gpa.free(c);
        ws.chunks.deinit(ws.gpa);
        ws.entries.deinit(ws.gpa);
    }
};

fn collectSink(ctx: *anyopaque, worker_id: u32, entry: *const Entry) VisitAction {
    const col: *Collector = @ptrCast(@alignCast(ctx));
    const ws = &col.sinks[worker_id];
    if (ws.failed) return .stop;

    const path = ws.storePath(entry.path) orelse {
        ws.failed = true;
        return .stop;
    };
    var copy = entry.*;
    copy.path = path;
    copy.basename = path[path.len - entry.basename.len ..];
    ws.entries.append(ws.gpa, copy) catch {
        ws.failed = true;
        return .stop;
    };
    return .cont;
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return mem.order(u8, a.path, b.path) == .lt;
}
