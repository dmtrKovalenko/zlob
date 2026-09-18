const std = @import("std");
const types = @import("types.zig");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const worker = @import("worker.zig");
const scan = @import("scan.zig");
const scan_linux = @import("scan_linux.zig");
const compiled_pattern = @import("../compiled_pattern.zig");
const ignore_rules_mod = @import("ignore_rules.zig");

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
pub const IgnoreRules = ignore_rules_mod.IgnoreRules;

/// internal constructors and resolution hooks used by `test/test_walk.zig`.
/// the namespace is empty in normal library builds.
pub const __internal_test_api = if (builtin.is_test) struct {
    pub const IgnoreNode = worker.IgnoreNode;
    pub const max_dir_chain = ignore_rules_mod.__internal_test_api.max_dir_chain;
    pub const isIgnoredResolved = ignore_rules_mod.__internal_test_api.isIgnoredResolved;
    pub const isIgnoredPathSlow = ignore_rules_mod.__internal_test_api.isIgnoredPathSlow;
} else struct {};

pub const WalkError = types.WalkError;
/// Result of `collectAs`: entries of the caller-chosen record type `Out`
/// plus the chunk storage that owns every path they point into.
pub fn CollectResult(comptime Out: type) type {
    return struct {
        const Self = @This();

        entries: []Out,
        chunks: [][]u8,
        /// Out-of-line metadata storage; `Entry.meta` points into it. Empty
        /// unless `Options.meta` requested at least one attribute and the
        /// adapter retains metadata (`Adapter.retain_meta`).
        metas: []Metadata,
        allocator: Allocator,
        /// Inferred set of ignore rules, valid until the .gitignore/.ignore file is changed
        ignore_rules: *IgnoreRules,

        pub fn deinit(self: *Self) void {
            self.ignore_rules.deinit();
            self.allocator.destroy(self.ignore_rules);
            for (self.chunks) |c| self.allocator.free(c);
            self.allocator.free(self.chunks);
            self.allocator.free(self.metas);
            self.allocator.free(self.entries);
            self.* = undefined;
        }
    };
}

pub const WalkerResult = CollectResult(Entry);

/// Identity adapter for `collectAs`: records are plain `Entry`s whose `meta`
/// points into `WalkerResult.metas`.
pub const EntryAdapter = struct {
    pub const Out = Entry;
    pub const retain_meta = true;
    pub inline fn convert(out: *Entry, e: *const Entry) void {
        out.* = e.*;
    }
    pub inline fn path(o: *const Entry) []const u8 {
        return o.path;
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

    try walkImpl(allocator, root, options, runSink, @constCast(&visitor), effectiveThreads(&options), rules, null);
    return rules;
}

/// Walks and returns all entries. Optimized for allocation, so use this only if you need in-memory result
pub fn collect(gpa: Allocator, root: []const u8, options: Options) WalkError!WalkerResult {
    return collectAs(gpa, root, options, EntryAdapter);
}

/// Like `collect`, but the merged result holds records of `Adapter.Out`,
/// materialized once (in parallel for big results, see `collectFinish`)
/// straight from the sink's 16-byte records via
/// `Adapter.convert(out: *Out, entry: *const Entry) void`, so a foreign
/// record layout (e.g. the C ABI's `zlob_walk_entry_t`) never goes through
/// an intermediate `Entry[]` plus a second fill pass. `Adapter.path` must
/// return the path an `Out` record points at (used by `Options.sort`).
/// `entry.path` handed to `convert` already lives in chunk storage: stable
/// for the result's lifetime and NUL-terminated. `entry.meta` is only stable
/// past `convert` when `Adapter.retain_meta` is true (it then points into
/// `CollectResult.metas`); adapters that copy the metadata into `Out` set it
/// false and no metadata array is allocated.
pub fn collectAs(gpa: Allocator, root: []const u8, options: Options, comptime Adapter: type) WalkError!CollectResult(Adapter.Out) {
    const Out = Adapter.Out;
    const Col = Collector(Adapter);
    const n_workers = effectiveThreads(&options);

    var col = Col{ .gpa = gpa, .sinks = try gpa.alloc(WorkerSink, n_workers), .with_meta = options.meta.any() };
    for (col.sinks) |*ws| ws.* = .{ .gpa = gpa };
    col.offsets = gpa.alloc(usize, n_workers) catch {
        gpa.free(col.sinks);
        return error.OutOfMemory;
    };
    defer {
        for (col.sinks) |*ws| ws.deinit();
        gpa.free(col.offsets);
        // Non-empty only when the parallel merge ran but collect() failed
        // afterwards (walk error, chunk-table OOM); the success path hands
        // `dest`/`dest_metas` over and leaves empty slices here.
        gpa.free(col.dest);
        gpa.free(col.dest_metas);
        gpa.free(col.sinks);
    }

    const rules = try gpa.create(IgnoreRules);
    rules.* = .{ .allocator = gpa };
    errdefer {
        rules.deinit();
        gpa.destroy(rules);
    }
    try rules.setWalkRoot(root);

    // With helpers the workers materialize their own shards into the final
    // slice before exiting (see collectFinish); a lone worker skips the
    // barrier and the serial path below materializes its records.
    const finish: ?worker.FinishFn = if (n_workers > 1) Col.finish else null;
    try walkImpl(gpa, root, options, Col.sink, @ptrCast(&col), n_workers, rules, finish);

    var failed = false;
    var total: usize = 0;
    for (col.sinks) |*ws| {
        if (ws.failed) failed = true;
        total += ws.recs.len;
    }
    if (failed) return error.OutOfMemory;

    var n_chunks: usize = 0;
    for (col.sinks) |*ws| n_chunks += ws.chunks.items.len;

    var entries: []Out = undefined;
    var metas: []Metadata = undefined;
    if (col.merged) {
        // Multi-sink, big result: every worker already materialized its shard
        // into col.dest / col.dest_metas in parallel (collectFinish). Only the
        // small chunk table is gathered here.
        std.debug.assert(col.dest.len == total);
        entries = col.dest;
        metas = col.dest_metas;
        col.dest = &.{}; // ownership moved to Results
        col.dest_metas = &.{};
    } else {
        if (col.merge_failed) return error.OutOfMemory;
        // Serial path (single sink, or fewer than PARALLEL_MERGE_MIN_TOTAL
        // entries): materialize the public Entry once per record, straight
        // into the final array (the sink only kept 16-byte records + shared
        // string chunks). With metadata on, every reported entry carries one
        // record (same order as `entries`), so the lists line up by index.
        entries = try gpa.alloc(Out, total);
        errdefer gpa.free(entries);
        metas = try gpa.alloc(Metadata, if (col.with_meta and Adapter.retain_meta) total else 0);
        var ei: usize = 0;
        for (col.sinks, 0..) |*ws, wid| ei = ws.materialize(Adapter, entries, metas, ei, @intCast(wid));
        std.debug.assert(ei == total);
    }
    errdefer gpa.free(entries);
    errdefer gpa.free(metas);

    const chunks = try gpa.alloc([]u8, n_chunks);
    var ci: usize = 0;
    for (col.sinks) |*ws| {
        @memcpy(chunks[ci..][0..ws.chunks.items.len], ws.chunks.items);
        ci += ws.chunks.items.len;
        ws.chunks.clearRetainingCapacity(); // ownership moved to Results
    }

    if (options.sort) std.sort.pdq(Out, entries, {}, struct {
        fn lessThan(_: void, a: Out, b: Out) bool {
            return mem.order(u8, Adapter.path(&a), Adapter.path(&b)) == .lt;
        }
    }.lessThan);

    return .{ .entries = entries, .chunks = chunks, .metas = metas, .allocator = gpa, .ignore_rules = rules };
}

pub fn effectiveThreads(opts: *const Options) u32 {
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
    finish: ?worker.FinishFn,
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
    // custom ignore rules are treated as an extra ignore node in the very root of the tree
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
        .statx_mask = scan_linux.statxMask(options.meta),
        .ignore_rules = ignore_rules,
        .finish = finish,
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

    const threads: []worker.Thread = if (n_workers > 1)
        try allocator.alloc(worker.Thread, n_workers - 1)
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

/// Path string storage: kept below glibc's default 128 KiB mmap threshold so
/// freed chunks stay in the malloc arena and are re-served on the next walk
/// without first-touch page faults (256 KiB chunks were mmap'd fresh each
/// walk and unmapped at deinit).
const CHUNK_SIZE = 120 * 1024;

/// Fixed-size segments for the sink's record lists. Appending never moves
/// existing records (no ArrayList doubling / realloc memmove); each segment
/// is malloc'd once at this byte size.
const SEG_BYTES = 120 * 1024;

/// Compact per-entry record kept by `Collector.sink`; the 40-byte public
/// `Entry` is only built at merge time. `relative_offset` and `worker_id`
/// are per-walk / per-sink constants, so they are not stored.
const SinkRec = extern struct {
    /// Index into `WorkerSink.chunks`.
    chunk_idx: u32,
    /// Byte offset of the path inside that chunk (NUL follows the path).
    off: u32,
    len: u16,
    basename_off: u16,
    depth: u16,
    kind: u8,
    _pad: u8 = 0,
};

comptime {
    std.debug.assert(@sizeOf(SinkRec) == 16);
    // path lengths are bounded by MAX_PATH, which fits the u16 fields
    std.debug.assert(types.MAX_PATH <= std.math.maxInt(u16));
}

/// Append-only list of `T` in fixed segments; `items`-style indexing is
/// replaced by segment/offset arithmetic at materialization.
fn Segmented(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const per_seg: usize = @max(1, SEG_BYTES / @sizeOf(T));

        segs: std.ArrayList([]T) = .empty,
        /// Total number of records stored.
        len: usize = 0,

        fn push(self: *Self, gpa: Allocator, v: T) Allocator.Error!void {
            const seg_i = self.len / per_seg;
            if (seg_i == self.segs.items.len) {
                @branchHint(.unlikely);
                const seg = try gpa.alloc(T, per_seg);
                errdefer gpa.free(seg);
                try self.segs.append(gpa, seg);
            }
            self.segs.items[seg_i][self.len % per_seg] = v;
            self.len += 1;
        }

        /// Records [seg*per_seg .. ] of segment `seg`, clipped to `len`.
        fn segment(self: *const Self, seg: usize) []const T {
            const start = seg * per_seg;
            return self.segs.items[seg][0..@min(per_seg, self.len - start)];
        }

        fn deinit(self: *Self, gpa: Allocator) void {
            for (self.segs.items) |seg| gpa.free(seg);
            self.segs.deinit(gpa);
        }
    };
}

fn Collector(comptime Adapter: type) type {
    return struct {
        const Self = @This();
        const Out = Adapter.Out;

        gpa: Allocator,
        sinks: []WorkerSink,
        /// `Options.meta.any()`: whether sinks keep an index-aligned Metadata list.
        with_meta: bool,
        /// Prefix offset of each sink's shard inside `dest`, indexed by worker id.
        offsets: []usize = &.{},
        /// Final entry slice, allocated once by worker 0 inside the finish barrier.
        dest: []Out = &.{},
        /// Final metadata slice (empty unless `with_meta`), same lifetime as `dest`.
        dest_metas: []Metadata = &.{},
        /// True when the parallel merge ran and filled `dest`/`dest_metas`.
        merged: bool = false,
        /// True when worker 0 could not allocate `dest` (collect() reports OOM).
        merge_failed: bool = false,
        /// Barrier: helpers count themselves in, worker 0 waits for all of them.
        arrived: std.atomic.Value(u32) = .init(0),
        /// Barrier: worker 0 publishes offsets/dest, helpers wait for it.
        ready: std.atomic.Value(u32) = .init(0),

        fn sink(ctx: *anyopaque, worker_id: u32, entry: *const Entry) VisitAction {
            const col: *Self = @ptrCast(@alignCast(ctx));
            const ws = &col.sinks[worker_id];
            if (ws.failed) return .stop;

            const off = ws.storePath(entry.path) orelse {
                ws.failed = true;
                return .stop;
            };
            ws.relative_offset = entry.relative_offset;
            ws.recs.push(ws.gpa, .{
                .chunk_idx = @intCast(ws.chunks.items.len - 1),
                .off = off,
                .len = @intCast(entry.path.len),
                .basename_off = @intCast(entry.basename_offset),
                .depth = entry.depth,
                .kind = @intFromEnum(entry.kind),
            }) catch {
                ws.failed = true;
                return .stop;
            };
            if (col.with_meta) {
                ws.metas.push(ws.gpa, if (entry.meta) |m| m.* else .{}) catch {
                    ws.failed = true;
                    return .stop;
                };
            }
            return .cont;
        }

        /// Runs on every worker thread once its loop has drained (`FinishFn`).
        /// Two-phase futex barrier: helpers arrive and (if their shard is large) park;
        /// worker 0 waits for all `sh.spawned` helpers, computes the prefix offsets,
        /// allocates the result slices once, and releases everyone; then each parked
        /// worker materializes its own shard of 16-byte records into 40-byte entries
        /// (plus its metadata records) in place, so the gather and the fresh-page
        /// faults of the destination are spread across the threads instead of
        /// serialized on the calling thread after join.
        fn finish(ctx: *anyopaque, worker_id: u32, sh: *SharedWorkerState) void {
            const col: *Self = @ptrCast(@alignCast(ctx));
            const own = &col.sinks[worker_id];
            if (worker_id == 0) {
                // Only worker 0 spawns helpers, and only from inside its own loop, so
                // sh.spawned is final here. Helpers that were never spawned never
                // enter this function.
                const want: u32 = @intCast(sh.spawned);
                while (true) {
                    const cur = col.arrived.load(.acquire);
                    if (cur >= want) break;
                    sh.io.futexWaitUncancelable(u32, &col.arrived.raw, cur);
                }

                var total: usize = 0;
                var failed = false;
                var any_parked = false;
                for (col.sinks, 0..) |*ws, i| {
                    if (ws.failed) failed = true;
                    if (ws.parked) any_parked = true;
                    col.offsets[i] = total;
                    total += ws.recs.len;
                }
                if (!failed and total >= PARALLEL_MERGE_MIN_TOTAL) {
                    // An allocation failure must still release the parked helpers;
                    // collect() reports it as OutOfMemory via `merge_failed`.
                    if (col.gpa.alloc(Out, total)) |dest| {
                        if (col.gpa.alloc(Metadata, if (col.with_meta and Adapter.retain_meta) total else 0)) |dm| {
                            col.dest = dest;
                            col.dest_metas = dm;
                            col.merged = true;
                        } else |_| {
                            col.gpa.free(dest);
                            col.merge_failed = true;
                        }
                    } else |_| {
                        col.merge_failed = true;
                    }
                }
                col.ready.store(1, .release);
                if (any_parked) sh.io.futexWake(u32, &col.ready.raw, std.math.maxInt(u32));

                if (col.merged) {
                    // Own shard plus every shard whose helper already left.
                    for (col.sinks, 0..) |*ws, i| {
                        if (i != 0 and ws.parked) continue;
                        _ = ws.materialize(Adapter, col.dest, col.dest_metas, col.offsets[i], @intCast(i));
                    }
                }
                return;
            }

            // Helper: publish the parking decision before counting in (the fetchAdd
            // releases it to worker 0), then either park for the copy or leave.
            own.parked = own.recs.len >= PARALLEL_MERGE_MIN_ENTRIES;
            _ = col.arrived.fetchAdd(1, .acq_rel);
            sh.io.futexWake(u32, &col.arrived.raw, 1);
            if (!own.parked) return;

            while (col.ready.load(.acquire) == 0)
                sh.io.futexWaitUncancelable(u32, &col.ready.raw, 0);
            if (col.merged)
                _ = own.materialize(Adapter, col.dest, col.dest_metas, col.offsets[worker_id], @intCast(worker_id));
        }
    };
}

/// A helper only stays for the parallel materialization when its shard is big
/// enough to pay for the extra futex wake it costs before `join` can return;
/// smaller shards are handled by worker 0 instead, so shallow trees keep the
/// baseline "helpers exit as soon as they drain" behavior.
const PARALLEL_MERGE_MIN_ENTRIES = 2048;

/// Below this many entries in total the whole merge is done serially by the
/// calling thread after join: the barrier round-trip and the cross-thread
/// cache traffic cost more than the ~40 B/entry materialization saves on
/// small trees (the 2.4k-entry kernel fs/ tree regressed 6-25% without it).
const PARALLEL_MERGE_MIN_TOTAL = 16384;

const WorkerSink = struct {
    gpa: Allocator,
    chunks: std.ArrayList([]u8) = .empty,
    cur: []u8 = &.{},
    off: usize = 0,
    recs: Segmented(SinkRec) = .{},
    /// Index-aligned with `recs`; only populated when `Options.meta.any()`.
    /// The worker's metadata record is scratch, so the sink keeps a copy and
    /// `collect` re-points `Entry.meta` into the gathered `WalkerResult.metas`.
    metas: Segmented(Metadata) = .{},
    /// `Entry.relative_offset` is the same for every entry of a walk (the
    /// "root/" prefix length); remembered from the sunk entries.
    relative_offset: u32 = 0,
    failed: bool = false,
    /// Set by the owning helper in collectFinish: it stays to copy its own
    /// shard (true) or leaves and lets worker 0 copy it (false).
    parked: bool = false,

    /// Copies the path (plus NUL) into chunk storage; returns its offset in
    /// the current (last) chunk.
    fn storePath(ws: *WorkerSink, path: []const u8) ?u32 {
        const need = path.len + 1;
        if (ws.cur.len - ws.off < need) {
            @branchHint(.unlikely);
            const size = @max(CHUNK_SIZE, need);
            const chunk = ws.gpa.alloc(u8, size) catch return null;
            ws.chunks.append(ws.gpa, chunk) catch {
                ws.gpa.free(chunk);
                return null;
            };
            ws.cur = chunk;
            ws.off = 0;
        }
        const off = ws.off;
        @memcpy(ws.cur[off..][0..path.len], path);
        ws.cur[off + path.len] = 0;
        ws.off += need;
        return @intCast(off);
    }

    /// Builds the public entries for this sink into `dest[start..]` (and,
    /// when metadata was collected, the records into `metas[start..]` with
    /// `Entry.meta` pointing at them); returns the index one past the last
    /// written entry.
    fn materialize(ws: *WorkerSink, comptime Adapter: type, dest: []Adapter.Out, metas: []Metadata, start: usize, worker_id: u16) usize {
        var ei = start;
        const relative_offset = ws.relative_offset;
        const with_meta = ws.metas.len != 0;
        std.debug.assert(!with_meta or ws.metas.len == ws.recs.len);
        // Retaining adapters get the records copied into the result's
        // `metas` array and `Entry.meta` pointing there; copying adapters
        // read the metadata straight from the sink's segment (scratch).
        const retain = comptime Adapter.retain_meta;
        if (with_meta and retain) {
            var mi = start;
            for (ws.metas.segs.items, 0..) |_, si| {
                const seg = ws.metas.segment(si);
                @memcpy(metas[mi..][0..seg.len], seg);
                mi += seg.len;
            }
        }
        const meta_per_seg = Segmented(Metadata).per_seg;
        for (ws.recs.segs.items, 0..) |_, si| {
            for (ws.recs.segment(si)) |rec| {
                const path: []const u8 = ws.chunks.items[rec.chunk_idx][rec.off..][0..rec.len];
                const meta: ?*const Metadata = if (!with_meta)
                    null
                else if (retain)
                    &metas[ei]
                else blk: {
                    const i = ei - start;
                    break :blk &ws.metas.segs.items[i / meta_per_seg][i % meta_per_seg];
                };
                const entry: Entry = .{
                    .path = path,
                    .meta = meta,
                    .relative_offset = relative_offset,
                    .basename_offset = rec.basename_off,
                    .depth = rec.depth,
                    .worker_id = worker_id,
                    .kind = @enumFromInt(rec.kind),
                };
                Adapter.convert(&dest[ei], &entry);
                ei += 1;
            }
        }
        return ei;
    }

    fn deinit(ws: *WorkerSink) void {
        for (ws.chunks.items) |c| ws.gpa.free(c);
        ws.chunks.deinit(ws.gpa);
        ws.recs.deinit(ws.gpa);
        ws.metas.deinit(ws.gpa);
    }
};
