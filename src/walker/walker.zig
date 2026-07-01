const std = @import("std");
const types = @import("types.zig");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
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
    /// Inferred set of ignore rules, valid until the .gitignore/.ignore file is changed
    ignore_rules: *IgnoreRules,

    pub fn deinit(self: *WalkerResult) void {
        self.ignore_rules.deinit();
        self.allocator.destroy(self.ignore_rules);
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

/// Streaming parallel walk. The visitor is called for every entry (has to be thread safe if threads != 1)
pub fn run(allocator: Allocator, root: []const u8, options: Options, visitor: Visitor) WalkError!*IgnoreRules {
    const rules = try allocator.create(IgnoreRules);
    rules.* = .{ .allocator = allocator };
    errdefer {
        rules.deinit();
        allocator.destroy(rules);
    }
    try rules.setWalkRoot(root);

    try walkImpl(allocator, root, options, runSink, @constCast(&visitor), effectiveThreads(&options), rules);
    return rules;
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

    const rules = try gpa.create(IgnoreRules);
    rules.* = .{ .allocator = gpa };
    errdefer {
        rules.deinit();
        gpa.destroy(rules);
    }
    try rules.setWalkRoot(root);

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

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return mem.order(u8, a.path, b.path) == .lt;
}

fn effectiveThreads(opts: *const Options) u32 {
    if (opts.threads != 0) return @min(opts.threads, 1024);
    const n: u32 = @intCast(@max(std.Thread.getCpuCount() catch 1, 1));
    // Directory enumeration is syscall-bound and contends on per-process and
    // per-mount kernel locks (the fd table, vnode/namecache locks).
    // Beyond a low count more workers only fight over those locks rather than doing useful I/O.
    //
    // macOS (APFS): throughput climbs to a low single-digit worker count and
    // then regresses as the shared VFS name-cache / vnode locks dominate
    // (below single-threaded past ~12). The peak depends on how long each
    // syscall holds those locks:
    //   - name-only walks (getdirentries64) hold them briefly -> peak ~6.
    //   - metadata walks (getattrlistbulk) assemble attribute records under
    //     the same locks, so contention bites one worker earlier -> peak ~5.
    // Measured on Apple-silicon (M-series); we never oversubscribe past the
    // logical core count on smaller machines.
    //
    // Linux: the dcache lock scales further, so allow more workers there.
    if (backend == .darwin_bulk) {
        const cap: u32 = if (opts.meta.any()) 8 else 6;
        return @min(n, cap);
    }
    return @min(n, 16);
}

fn walkImpl(
    allocator: Allocator,
    root: []const u8,
    options: Options,
    sink: worker.SinkFn,
    sink_ctx: *anyopaque,
    n_workers: u32,
    ignore_rules: *IgnoreRules,
) WalkError!void {
    const MAX_PATH = types.MAX_PATH;

    // Root prefix: root/ (or "" for an empty root meaning cwd-relative
    // output, or "root" when it already ends with /).
    var prefix_buf: [types.MAX_PATH]u8 = undefined;
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

    // Extra-ignore root: caller-supplied patterns turned into a synthetic
    // .gitignore. `chainIgnored` checks it FIRST (deepest), so `!negation`
    // rules override the project's discovered .gitignore — same precedence a
    // deeper nested .gitignore would have. The walker holds one ref; the
    // IgnoreRules surface holds another so post-walk `isIgnored` matches the
    // same source set the walk used.
    const extra_root = try buildExtraIgnoreRoot(allocator, options.extra_ignore);
    defer if (extra_root) |root_node| root_node.release(allocator);
    if (extra_root) |x| ignore_rules.setExtra(x);

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
        .extra_ignore_root = extra_root,
        .statx_mask = scan.linuxStatxMask(options.meta),
        .ignore_rules = ignore_rules,
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

/// Build the synthetic .gitignore IgnoreNode the walker layers on top of any
/// project-discovered rules. `doc` is a `.gitignore`-style document (one rule
/// per line). Returns null on null/empty input. Refcount = 1; caller owns
/// that ref and must `.release()` when done.
fn buildExtraIgnoreRoot(allocator: Allocator, doc: ?[]const u8) WalkError!?*worker.IgnoreNode {
    const content = doc orelse return null;
    if (content.len == 0) return null;
    var gi = try GitIgnore.parse(allocator, content);
    errdefer gi.deinit();
    const node = try allocator.create(worker.IgnoreNode);
    errdefer allocator.destroy(node);
    node.* = .{
        .parent = null,
        .gi = gi,
        .relative_offset = 0,
        .refs = .init(1),
    };
    return node;
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
