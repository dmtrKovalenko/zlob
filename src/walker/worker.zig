const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const queue_mod = @import("queue.zig");
const scan = @import("scan.zig");
const scan_linux = @import("scan_linux.zig");
const win = @import("scan_windows.zig");
const gitignore_mod = @import("../gitignore.zig");
const compiled_pattern = @import("../compiled_pattern.zig");
const pattern_context = @import("../pattern_context.zig");
const ignore_rules = @import("ignore_rules.zig");
const git_excludes = @import("git_excludes.zig");
const thread_mod = @import("thread.zig");

pub const IgnoreRules = ignore_rules.IgnoreRules;
pub const Thread = thread_mod.Thread;

const posix = std.posix;
const linux = std.os.linux;
const backend = types.backend;
const is_posix_backend = types.is_posix_backend;
const is_windows_backend = types.is_windows_backend;
const Handle = types.Handle;
const Entry = types.Entry;
const EntryKind = types.EntryKind;
const Metadata = types.Metadata;
const Options = types.Options;
const VisitAction = types.VisitAction;
const MAX_PATH = types.MAX_PATH;
const NAME_MAX = types.NAME_MAX;
const NAME_BUF = types.NAME_BUF_Z_LENGTH;
// A path read from a directory listing can fit even when opening that
// child's assembled path would exceed the operating system's limit.
const MAX_ENTRY_PATH = MAX_PATH + NAME_MAX;
const closeFd = types.closeFd;
const closeHandle = types.closeHandle;

const GitIgnore = gitignore_mod.GitIgnore;
const CompiledPattern = compiled_pattern.CompiledPattern;
const Queue = queue_mod.Queue;
const DirTask = queue_mod.DirTask;

pub const WalkError = types.WalkError;
pub const SinkFn = *const fn (ctx: *anyopaque, worker_id: u32, entry: *const Entry) VisitAction;
/// Called once by every worker (on its own thread) after it has drained the
/// queue, before the helper thread exits. `sh.spawned` is final by then: the
/// spawn ramp only runs while a task is outstanding, so nothing spawns after
/// the queue has closed.
pub const FinishFn = *const fn (ctx: *anyopaque, worker_id: u32, sh: *SharedWorkerState) void;

const Failure = enum(u8) { none = 0, aborted = 1, oom = 2, read_failed = 3, permission_denied = 4, name_too_long = 5 };
const InodeKey = struct { dev: u64, ino: u64 };

// ---------------------------------------------------------------------------
// Refcounted resources shared across tasks
// ---------------------------------------------------------------------------

/// A directory fd shared by a parent task and all of its child tasks. Closed
/// when the last holder releases it.
pub const HandleRef = struct {
    handle: Handle,
    refs: std.atomic.Value(u32),

    pub fn retain(self: *HandleRef) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *HandleRef, sh: *SharedWorkerState) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            closeHandle(self.handle, sh.io);
            sh.allocator.destroy(self);
        }
    }
};

/// One parsed .gitignore, linked to the nearest ancestor .gitignore. Immutable
/// after creation, so matching is lock-free from any thread. Refcounted: held
/// by tasks and child nodes.
pub const IgnoreNode = struct {
    parent: ?*IgnoreNode,
    gi: GitIgnore,
    /// Offset into the match path (worktree-relative when inheriting rules)
    /// where paths relative to this node's directory start.
    relative_offset: u32,
    refs: std.atomic.Value(u32),
    chain_last: gitignore_mod.LastByteFilter = .{},
    source: enum { git, dot_ignore } = .git,
    git_boundary: bool = false,

    pub fn retain(self: *IgnoreNode) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self_in: *IgnoreNode, gpa: Allocator) void {
        var node: ?*IgnoreNode = self_in;
        while (node) |n| {
            if (n.refs.fetchSub(1, .acq_rel) != 1) return;
            const parent = n.parent;
            n.gi.deinit();
            gpa.destroy(n);
            node = parent;
        }
    }
};

pub const SharedWorkerState = struct {
    allocator: Allocator,
    io: std.Io,
    options: Options,
    root_path: []const u8,
    /// "root/" — copied into each worker's path buffer at init.
    root_path_with_slash: []const u8,
    /// Length of the root prefix (root + trailing '/') inside path buffers.
    root_prefix_len: u32,
    queue: Queue = .{},
    abort_signal: std.atomic.Value(bool) = .init(false),
    failure: std.atomic.Value(u8) = .init(0),
    sink: SinkFn,
    sink_ctx: *anyopaque,
    finish: ?FinishFn = null,
    pattern: ?*const CompiledPattern = null,
    /// Literal directory prefix of the pattern, used to prune traversal
    /// outside the pattern's scope ("src/lib" for "src/lib/**/*.c").
    pattern_prefix: []const u8 = &.{},
    /// Synthetic gitignore from `Options.extra_ignore`. Sits at the deepest
    /// position in every chain so its `!negation` rules win over the
    /// project's discovered `.gitignore` files (the same precedence a nested
    /// `.gitignore` would give a deeper directory).
    extra_ignore_root: ?*IgnoreNode = null,
    /// Repository exclude files (`$GIT_DIR/info/exclude`, core.excludesFile),
    /// consulted only for directories with a repository boundary.
    git: git_excludes.Resolver,
    /// Linux only: the per-entry `statx()` mask, precomputed once from
    /// `options.meta` so the hot scan loop doesn't rebuild it per entry. Other
    /// backends also fetch only the requested attributes, but build that
    /// request elsewhere — macOS bakes it into the per-directory
    /// `BulkScanner` AttrList, Windows into its info-class selection — so no
    /// shared field is needed there.
    statx_mask: if (builtin.os.tag == .linux) linux.STATX else void,
    /// Linux: a short getdents64 return proves EOF, so the confirming call is
    /// skipped. Decided once from the root fd (see dirent.trustShortReaddir)
    /// before helper threads exist; only ever cleared afterwards (a followed
    /// symlink left the root's device), hence the atomic.
    trust_short: std.atomic.Value(bool) = .init(false),
    /// Device of the walk root, for the cross-device check above.
    root_dev: u64 = 0,
    /// Linux only: directories are opened with O_NOATIME so getdents64 never
    /// dirties directory inodes (on relatime mounts the first walk after 24h
    /// otherwise rewrites every directory's atime inline in getdents64 and
    /// queues a metadata writeback per directory). O_NOATIME is refused with
    /// EPERM when the caller neither owns the directory nor has CAP_FOWNER;
    /// the first refusal retries once without the flag and clears this for the
    /// rest of the walk, so a foreign tree costs one extra open, not one per
    /// directory.
    noatime_ok: std.atomic.Value(bool) = .init(true),
    /// Symlink-cycle bookkeeping, only touched when follow_symlinks is set.
    visited_mutex: std.Io.Mutex = .init,
    visited: std.AutoHashMapUnmanaged(InodeKey, void) = .empty,
    /// (dev, ino) of the walk root, seeded by `recordRootVisited`; the root
    /// task inherits it and every child task derives its key from there.
    root_key: InodeKey = .{ .dev = 0, .ino = 0 },
    /// Linux: set once openat2 fails with ENOSYS so the follow_symlinks open
    /// path stops retrying it (pre-5.6 kernels, seccomp).
    openat2_unavailable: std.atomic.Value(bool) = .init(false),
    /// Reusable ignore rules. Workers register each parsed `.gitignore`/ `.ignore`
    ignore_rules: *IgnoreRules,
    retain_rules: bool,
    retain_mutex: std.Io.Mutex = .init,
    /// Lazy worker spawning: helper threads are created only once the walk has
    /// demonstrably parallel work, so shallow trees never pay the spawn cost.
    workers: []Worker = &.{},
    threads: []Thread = &.{},
    /// Number of helper threads started so far (`threads[0..spawned]` are live).
    /// Only grows while some task is still outstanding (the ramp check runs
    /// before `taskDone`), so it is final once the queue has closed. Read by
    /// every worker after each directory until the pool is full, so it gets
    /// its own cache line away from the mutexes above.
    spawned: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    spawn_lock: std.atomic.Value(bool) = .init(false),
    /// Set (under `spawn_lock`) once a spawn failed; no further attempts.
    spawn_failed: bool = false,

    pub fn fail(sh: *SharedWorkerState, f: Failure) void {
        sh.abort_signal.store(true, .release);
        _ = sh.failure.cmpxchgStrong(@backingInt(Failure.none), @backingInt(f), .acq_rel, .acquire);
    }

    pub fn failureResult(sh: *SharedWorkerState) WalkError!void {
        return switch (@as(Failure, @fromBackingInt(@intCast(sh.failure.load(.acquire))))) {
            .none => {},
            .aborted => error.Aborted,
            .oom => error.OutOfMemory,
            .read_failed => error.ReadFailed,
            .permission_denied => error.PermissionDenied,
            .name_too_long => error.NameTooLong,
        };
    }

    /// Demand-driven helper spawn: any worker that finds more queued
    /// directories than running threads starts up to `want` more, so the
    /// thread count ramps with the discovered fan-out. A shallow tree with a
    /// handful of subdirectories gets a handful of helpers instead of the
    /// full complement; a wide tree still gets everything it can use within
    /// a couple of directory listings. Serialized by a try-lock: a worker that
    /// loses the race just carries on, the winner covers the backlog.
    ///
    /// A failed spawn is not fatal -- the work stays with the threads already
    /// running (worker 0 at minimum), so the walk completes with less
    /// parallelism.
    fn spawnHelpers(sh: *SharedWorkerState, want: usize) void {
        if (sh.spawn_lock.swap(true, .acquire)) return;
        defer sh.spawn_lock.store(false, .release);
        var n = sh.spawned.load(.monotonic);
        if (sh.spawn_failed) return;
        const target = @min(sh.threads.len, n +| want);
        while (n < target) : (n += 1) {
            sh.threads[n] = Thread.spawn(workerThreadMain, @ptrCast(&sh.workers[n + 1]), sh.options.thread_stack_size) catch {
                sh.spawn_failed = true;
                break;
            };
            sh.spawned.store(n + 1, .release);
        }
    }

    fn visitedBefore(sh: *SharedWorkerState, key: InodeKey) Allocator.Error!bool {
        sh.visited_mutex.lockUncancelable(sh.io);
        defer sh.visited_mutex.unlock(sh.io);
        const gop = try sh.visited.getOrPut(sh.allocator, key);
        return gop.found_existing;
    }
};

/// Per-entry scratch record. Metadata lives in the parallel `Worker.metas`
/// list and only when the caller requested it (`options.meta.any()`), so the
/// common no-metadata walk moves 12 bytes per entry instead of ~90.
pub const Scratch = struct {
    name_off: u32,
    name_len: u32,
    kind: EntryKind,
    metadata_deferred: bool = false,
};

pub const Worker = struct {
    id: u32,
    sh: *SharedWorkerState,
    /// Full-path assembly buffer; [0..root_prefix_len) holds "root/".
    path_buf: [MAX_ENTRY_PATH + 1]u8 = undefined,
    /// Per-directory name bytes (reset per task, capacity retained).
    names: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Scratch) = .empty,
    /// Parallel to `entries`; filled only when `options.meta.any()`.
    metas: std.ArrayList(Metadata) = .empty,
    /// Parallel to `entries`; listing inode numbers (`RawEntry.ino`), filled
    /// only when `options.follow_symlinks` so cycle keys need no statx.
    inos: std.ArrayList(u64) = .empty,
    /// d_ino of the "." record of the directory just scanned (Linux), 0 when
    /// the listing didn't start with one. See `resolveTaskKey`.
    dot_ino: u64 = 0,
    saw_gitignore: bool = false,
    saw_ignore: bool = false,
    /// The listing's `.git` entry, if any: this directory is a repository
    /// root whose exclude files apply.
    dot_git: ?git_excludes.DotGit = null,
    saw_exact_dot_git: bool = false,
    saw_dot_jj: bool = false,
    /// Kernel buffer for getdents64 / getattrlistbulk.
    io_buf: []align(8) u8 = &.{},
    /// Worktree-relative match path, allocated only when inheriting rules.
    scoped_path: ?[]u8 = null,

    pub fn init(w: *Worker, id: u32, sh: *SharedWorkerState) !void {
        w.* = .{ .id = id, .sh = sh };
        const buf_size: usize = switch (backend) {
            .linux_getdents => 64 * 1024,
            .darwin_bulk => 64 * 1024,
            .windows_ntdll => 128 * 1024,
            .std_fs => 0,
        };
        if (buf_size > 0) {
            w.io_buf = try sh.allocator.alignedAlloc(u8, .@"8", buf_size);
        }
        errdefer if (w.io_buf.len > 0) sh.allocator.free(w.io_buf);
        const scope_prefix = sh.ignore_rules.scope_prefix;
        if (scope_prefix.len > 0) {
            const path = try sh.allocator.alloc(u8, scope_prefix.len + MAX_ENTRY_PATH);
            @memcpy(path[0..scope_prefix.len], scope_prefix);
            w.scoped_path = path;
        }
        @memcpy(w.path_buf[0..sh.root_prefix_len], sh.root_path_with_slash);
    }

    pub fn deinit(w: *Worker) void {
        const allocator = w.sh.allocator;

        w.names.deinit(allocator);
        w.entries.deinit(allocator);
        w.metas.deinit(allocator);
        w.inos.deinit(allocator);
        if (w.io_buf.len > 0) allocator.free(w.io_buf);
        if (w.scoped_path) |path| allocator.free(path);
    }
};

pub fn freeTask(sh: *SharedWorkerState, t: DirTask) void {
    if (t.parent) |p| p.release(sh);
    if (t.ignore) |ig| ig.release(sh.allocator);
    sh.allocator.free(t.rel);
}

fn workerThreadMain(ctx: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(ctx));
    workerLoop(w.sh, w);
}

// ---------------------------------------------------------------------------
// Scratch accumulation
// ---------------------------------------------------------------------------

inline fn noteIgnoreFile(w: *Worker, name: []const u8, kind: EntryKind) void {
    if (name.len == 10 and mem.eql(u8, name, ".gitignore")) {
        w.saw_gitignore = true;
    } else if (name.len == 7 and mem.eql(u8, name, ".ignore")) {
        w.saw_ignore = true;
    } else if (name.len == 4 and mem.eql(u8, name, ".git")) {
        w.dot_git = .fromKind(kind);
        w.saw_exact_dot_git = true;
    } else if (w.sh.options.respect_git) {
        // These are candidates on case-insensitive filesystems. All opens
        // and stats still use the canonical name to check the actual lookup.
        switch (name.len) {
            3 => w.saw_dot_jj = w.saw_dot_jj or std.ascii.eqlIgnoreCase(name, ".jj"),
            4 => if (w.dot_git == null and std.ascii.eqlIgnoreCase(name, ".git")) {
                w.dot_git = .unknown;
            },
            7 => w.saw_ignore = w.saw_ignore or std.ascii.eqlIgnoreCase(name, ".ignore"),
            10 => w.saw_gitignore = w.saw_gitignore or std.ascii.eqlIgnoreCase(name, ".gitignore"),
            else => {},
        }
    }
}

pub inline fn appendScratch(sh: *SharedWorkerState, w: *Worker, raw: types.RawEntry) WalkError!void {
    const name = raw.name;
    if (name.len == 0) {
        @branchHint(.unlikely);
        return;
    }
    if (name[0] == '.') {
        @branchHint(.unlikely);
        if (name.len == 1 or (name.len == 2 and name[1] == '.')) return;
        noteIgnoreFile(w, name, raw.kind);
    }
    const off: u32 = @intCast(w.names.items.len);
    try w.names.appendSlice(sh.allocator, name);
    try w.entries.append(sh.allocator, .{
        .name_off = off,
        .name_len = @intCast(name.len),
        .kind = raw.kind,
        .metadata_deferred = raw.metadata_deferred,
    });
    // Metadata rides in the parallel list only when the caller asked for it;
    // processDir indexes it by entry position.
    if (sh.options.meta.any()) {
        try w.metas.append(sh.allocator, raw.meta);
    }
    if (backend != .darwin_bulk and sh.options.follow_symlinks) {
        try w.inos.append(sh.allocator, raw.ino);
    }
}

pub inline fn appendScratchNoMeta(sh: *SharedWorkerState, w: *Worker, name: []const u8, kind: EntryKind) WalkError!void {
    if (name.len == 0) {
        @branchHint(.unlikely);
        return;
    }
    if (name[0] == '.') {
        @branchHint(.unlikely);
        if (name.len == 1 or (name.len == 2 and name[1] == '.')) return;
        noteIgnoreFile(w, name, kind);
    }
    const off: u32 = @intCast(w.names.items.len);
    try w.names.appendSlice(sh.allocator, name);
    try w.entries.append(sh.allocator, .{
        .name_off = off,
        .name_len = @intCast(name.len),
        .kind = kind,
    });
}

pub fn workerLoop(state: *SharedWorkerState, worker: *Worker) void {
    // Demand-driven spawning (see spawnHelpers): after each directory, a
    // worker that sees more queued directories than there are threads to take
    // them starts enough helpers to cover the backlog. Once this worker has
    // seen the pool full it stops looking, so the steady-state loop carries
    // no shared loads. The check must stay ahead of `taskDone` so `spawned`
    // is final by the time the queue closes (the collect barrier in
    // walker.zig relies on that).
    var may_spawn = state.threads.len > 0;

    while (state.queue.pop(state.io, worker.id)) |next_task| {
        var task = next_task;
        if (!state.abort_signal.load(.acquire)) {
            processDir(state, worker, &task) catch |err| switch (err) {
                error.OutOfMemory => state.fail(.oom),
                error.ReadFailed => state.fail(.read_failed),
                error.PermissionDenied => state.fail(.permission_denied),
                error.NameTooLong => state.fail(.name_too_long),
                error.Aborted => state.fail(.aborted),
            };

            if (may_spawn) {
                const spawned = state.spawned.load(.monotonic);
                if (spawned >= state.threads.len) {
                    may_spawn = false;
                } else {
                    const queued = state.queue.queued.load(.monotonic);
                    if (queued > spawned + SPAWN_SLACK) state.spawnHelpers(spawnBurst(spawned, queued));
                }
            }
        }
        freeTask(state, task);
        state.queue.taskDone(state.io);
    }
    if (state.finish) |f| f(state.sink_ctx, worker.id, state);
}

/// Queued directories beyond the running thread count (worker 0 plus the
/// helpers) before another helper is worth starting.
const SPAWN_SLACK: usize = 1;

/// How many helpers to start when `queued` directories are waiting and
/// `spawned` helpers exist: enough to cover the backlog, or the full
/// remainder once the backlog shows real fan-out. Covering exactly the
/// backlog would leave a 10-subdir root with 9 helpers and pay for the rest
/// one clone at a time on some worker's critical path; the full burst at
/// `FULL_BURST_QUEUED` keeps wide roots at the old single-burst cost while a
/// 4-subdir tree still starts 3 threads instead of 15 (LICENSES: -63%).
inline fn spawnBurst(spawned: usize, queued: usize) usize {
    if (queued >= FULL_BURST_QUEUED) return std.math.maxInt(usize);
    return queued - spawned;
}

const FULL_BURST_QUEUED: usize = 8;

fn processDir(sh: *SharedWorkerState, w: *Worker, task: *DirTask) WalkError!void {
    const handle = (try openTaskDir(sh, w, task)) orelse return;
    var handle_consumed = false;
    defer if (!handle_consumed) closeHandle(handle, sh.io);

    if (backend == .darwin_bulk and sh.options.follow_symlinks) {
        // Claim the opened directory after the visitor and traversal filters
        // allow descent. A link can be retargeted before the queued open, and
        // a mount or firmlink can make its listing inode differ from the target.
        var st: std.c.Stat = undefined;
        if (std.c.fstat(handle, &st) != 0) {
            const plen = taskPrefixLen(sh, w, task);
            return reportError(sh, w.path_buf[0..plen -| 1], error.ReadFailed);
        }
        const key: InodeKey = .{
            .dev = @bitCast(@as(i64, @intCast(st.dev))),
            .ino = @intCast(st.ino),
        };
        if (try sh.visitedBefore(key)) return;
    }

    // The root is the first and only task before any helper thread is
    // spawned, so this plain store is published to them by the spawn.
    if (comptime backend == .linux_getdents) {
        if (task.depth == 0 and sh.options.trust_short_getdents == .auto) {
            sh.trust_short.store(scan_linux.trustShortReaddir(handle), .monotonic);
        }
    }

    // A task whose open crossed a mount (openat2 EXDEV, or openat2
    // unavailable) is re-keyed BEFORE its scan: the directory may sit on a
    // filesystem the short-read gate never examined, so its own listing
    // must already run with trust cleared, not just its children's.
    const verify_first = builtin.os.tag == .linux and sh.options.follow_symlinks and task.depth != 0 and task.verify_key;
    if (verify_first) {
        if (!try resolveTaskKey(sh, task, handle, 0)) return;
    }

    w.names.clearRetainingCapacity();
    w.entries.clearRetainingCapacity();
    w.metas.clearRetainingCapacity();
    w.inos.clearRetainingCapacity();
    w.dot_ino = 0;
    w.saw_gitignore = false;
    w.saw_ignore = false;
    w.dot_git = null;
    w.saw_exact_dot_git = false;
    w.saw_dot_jj = false;
    scan.scanDir(sh, w, handle) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            @branchHint(.cold);
            const prefix = taskPrefixLen(sh, w, task);
            try reportError(sh, w.path_buf[0..prefix -| 1], err);
            return;
        },
    };
    // Same-filesystem opens are keyed by the listing's d_ino and checked
    // against the "." record the scan just produced (no syscall when they
    // agree, see resolveTaskKey).
    if (builtin.os.tag == .linux and sh.options.follow_symlinks and task.depth != 0 and !verify_first) {
        if (!try resolveTaskKey(sh, task, handle, w.dot_ino)) return;
    }

    const prefix_len = taskPrefixLen(sh, w, task);
    if (w.scoped_path) |path| {
        const prefix = w.path_buf[sh.root_prefix_len..prefix_len];
        @memcpy(path[sh.ignore_rules.scope_prefix.len..][0..prefix.len], prefix);
    }

    var ignore: ?*IgnoreNode = task.ignore;
    var own_ignore = false;
    defer if (own_ignore) ignore.?.release(sh.allocator);
    const load_gitignore = w.saw_gitignore and !sh.options.skip_gitignore;
    const load_dot_ignore = w.saw_ignore and !sh.options.skip_dot_ignore;
    const load_vcs = w.dot_git != null or w.saw_dot_jj;
    if (sh.options.respect_git and (load_gitignore or load_dot_ignore or load_vcs)) {
        @branchHint(.unlikely);
        const dir = if (prefix_len == 0) "." else w.path_buf[0..@max(prefix_len - 1, 1)];
        const dir_offset = if (task.rel.len > 0) task.rel.len + 1 else 0;
        const offset = sh.ignore_rules.scope_prefix.len + dir_offset;
        if (try loadIgnoreNode(sh, handle, task.ignore, dir, offset, w.dot_git, w.saw_dot_jj, load_gitignore, load_dot_ignore)) |node| {
            ignore = node;
            own_ignore = true;
            if (sh.retain_rules) {
                sh.retain_mutex.lockUncancelable(sh.io);
                defer sh.retain_mutex.unlock(sh.io);
                sh.ignore_rules.put(task.rel, node) catch return error.OutOfMemory;
            }
        }
    }

    const opts = &sh.options;
    const entry_depth: u16 = task.depth +| 1;
    const may_descend = opts.max_depth == 0 or entry_depth < opts.max_depth;
    const want_meta = opts.meta.any();
    const have_inos = backend != .darwin_bulk and opts.follow_symlinks and w.inos.items.len == w.entries.items.len;
    var child_ref: ?*HandleRef = null;
    defer if (child_ref) |cr| cr.release(sh);

    for (w.entries.items, 0..) |se, i| {
        const name = w.names.items[se.name_off..][0..se.name_len];
        const meta: ?*const Metadata = if (want_meta) &w.metas.items[i] else null;
        const ino: u64 = if (have_inos) w.inos.items[i] else 0;
        try processEntry(sh, w, task, handle, name, se.kind, meta, se.metadata_deferred, ino, ignore, prefix_len, entry_depth, may_descend, &child_ref, &handle_consumed);
    }
}

fn isGitDirectory(w: *const Worker, handle: Handle, name: []const u8) bool {
    if (mem.eql(u8, name, ".git")) return true;
    if (w.saw_exact_dot_git or !std.ascii.eqlIgnoreCase(name, ".git")) return false;

    // Compare the entries themselves so a distinct directory reached through
    // a symlink named `.git` does not become the repository metadata entry.
    const dir: std.Io.Dir = if (is_posix_backend or is_windows_backend) .{ .handle = handle } else handle;
    const canonical = dir.statFile(w.sh.io, ".git", .{ .follow_symlinks = false }) catch return false;
    if (canonical.kind != .directory) return false;
    const candidate = dir.statFile(w.sh.io, name, .{ .follow_symlinks = false }) catch return false;
    return candidate.kind == .directory and candidate.inode == canonical.inode;
}

fn processEntry(
    sh: *SharedWorkerState,
    w: *Worker,
    task: *DirTask,
    handle: Handle,
    name: []const u8,
    entry_kind: EntryKind,
    meta: ?*const Metadata,
    metadata_deferred: bool,
    ino: u64,
    cur_ignore: ?*IgnoreNode,
    prefix_len: usize,
    entry_depth: u16,
    may_descend: bool,
    child_ref: *?*HandleRef,
    handle_consumed: *bool,
) WalkError!void {
    const opts = &sh.options;
    if (sh.abort_signal.load(.monotonic) or name.len == 0) {
        @branchHint(.unlikely);
        return;
    }
    if (!opts.include_hidden and name[0] == '.') return;

    var is_dir = entry_kind == .directory;
    const path_len = prefix_len + name.len;
    const too_long_to_open = path_len >= MAX_PATH;
    if (too_long_to_open and (!opts.respect_git or path_len > MAX_ENTRY_PATH or
        entry_kind == .sym_link or entry_kind == .unknown))
    {
        @branchHint(.cold);
        return;
    }
    @memcpy(w.path_buf[prefix_len..][0..name.len], name);
    w.path_buf[prefix_len + name.len] = 0;
    const full = w.path_buf[0 .. prefix_len + name.len];
    const basename = w.path_buf[prefix_len..full.len :0];
    const relative_path = full[sh.root_prefix_len..];

    if (is_dir and opts.respect_git and opts.skip_git_dir and name.len == 4 and isGitDirectory(w, handle, name)) return;

    if (chainMayIgnore(cur_ignore, sh.extra_ignore_root, basename[basename.len - 1])) {
        // Extra rules are walk-relative and take precedence over discovered rules.
        const extra_verdict = if (sh.extra_ignore_root) |extra|
            extra.gi.checkInode(relative_path, basename, is_dir)
        else
            null;
        if (extra_verdict) |ignored| {
            if (ignored) return;
        } else {
            const match_path = if (w.scoped_path) |path| blk: {
                const start = sh.ignore_rules.scope_prefix.len + prefix_len - sh.root_prefix_len;
                @memcpy(path[start..][0..basename.len], basename);
                break :blk path[0 .. start + basename.len];
            } else relative_path;
            if (IgnoreRules.verdict(cur_ignore, match_path, basename, is_dir) == true) return;
        }
    }

    // Linux usually gets directory keys from the listing and rechecks mount
    // crossings after opening. Darwin claims the opened directory instead.
    var child_key: InodeKey = .{ .dev = task.dev, .ino = ino };
    if (backend != .darwin_bulk and !is_dir and opts.follow_symlinks and entry_kind == .sym_link) {
        // stat(FOLLOW): a directory target not yet visited is descended
        if (statForSymlink(sh, handle, name, true)) |res| {
            // Leaving the root's device may land on a filesystem the
            // short-read gate never examined; stop trusting short reads for
            // the rest of the walk. Ordered before the child task is pushed,
            // so the worker that scans it observes the cleared flag.
            if (res.is_dir and res.key.dev != sh.root_dev) sh.trust_short.store(false, .release);
            is_dir = res.is_dir and !try sh.visitedBefore(res.key);
            child_key = res.key;
        }
    } else if (backend != .darwin_bulk and is_dir and opts.follow_symlinks) {
        // A real directory whose inode was already claimed (reached first
        // through a symlink, on another thread or earlier in this one) is
        // still reported -- only the descent is skipped. Every directory is
        // then listed exactly once and every listing entry reported exactly
        // once, so the result size does not depend on which path won the
        // race; only the subtree's placement does.
        if (ino != 0) {
            if (try sh.visitedBefore(child_key)) is_dir = false;
        } else if (statForSymlink(sh, handle, name, false)) |res| {
            // Listing gave no inode (non-Linux backends, DT_UNKNOWN).
            if (try sh.visitedBefore(res.key)) is_dir = false;
            child_key = res.key;
        }
    }

    var action: VisitAction = .cont;
    var report = entry_kind != .directory or opts.report_dirs;
    if (report) {
        if (sh.pattern) |cp| report = cp.matches(relative_path, opts.pattern_flags);
    }
    if (report) {
        var deferred_meta: Metadata = undefined;
        var reported_meta = meta;
        if (comptime backend == .linux_getdents) {
            if (metadata_deferred) {
                deferred_meta = scan_linux.readMetadata(handle, @ptrCast(basename.ptr), opts.meta, sh.statx_mask);
                reported_meta = &deferred_meta;
            }
        }
        var entry = Entry{
            .path = full,
            .meta = reported_meta,
            .relative_offset = sh.root_prefix_len,
            .basename_offset = @intCast(prefix_len),
            .depth = entry_depth,
            .worker_id = @intCast(w.id),
            .kind = entry_kind,
        };
        action = sh.sink(sh.sink_ctx, w.id, &entry);
        if (action == .stop) {
            @branchHint(.cold);
            sh.abort_signal.store(true, .release);
            return;
        }
    }

    const follow_link = backend == .darwin_bulk and opts.follow_symlinks and entry_kind == .sym_link;
    if ((is_dir or follow_link) and may_descend and action != .skip_dir) {
        if (sh.pattern != null and !dirInPatternScope(sh.pattern_prefix, relative_path)) return;
        if (follow_link) {
            const target = statForSymlink(sh, handle, name, true) orelse return;
            if (!target.is_dir) return;
        }
        if (too_long_to_open) return reportError(sh, full, error.NameTooLong);
        const cr = child_ref.* orelse blk: {
            const cr = try sh.allocator.create(HandleRef);
            cr.* = .{ .handle = handle, .refs = .init(1) };
            child_ref.* = cr;
            handle_consumed.* = true;
            break :blk cr;
        };

        const rel = full[sh.root_prefix_len..];
        const child_rel = try sh.allocator.dupe(u8, rel);
        errdefer sh.allocator.free(child_rel);
        cr.retain();
        errdefer cr.release(sh);
        if (cur_ignore) |ig| ig.retain();
        errdefer if (cur_ignore) |ig| ig.release(sh.allocator);

        const child: DirTask = .{
            .rel = child_rel,
            .depth = entry_depth,
            .ignore = cur_ignore,
            .parent = cr,
            .dev = child_key.dev,
            .ino = child_key.ino,
            .follow_link = follow_link,
        };
        try sh.queue.push(sh.allocator, sh.io, w.id, child);
    }
}

// ---------------------------------------------------------------------------
// Path assembly
// ---------------------------------------------------------------------------

/// Lays down "rel/" after the root prefix in the worker path buffer and
/// returns the offset entries should be appended at.
fn taskPrefixLen(sh: *SharedWorkerState, w: *Worker, task: *DirTask) usize {
    var pos: usize = sh.root_prefix_len;
    if (task.rel.len > 0) {
        @memcpy(w.path_buf[pos..][0..task.rel.len], task.rel);
        pos += task.rel.len;
        w.path_buf[pos] = '/';
        pos += 1;
    }
    return pos;
}

inline fn basenameOf(rel: []const u8) []const u8 {
    if (mem.lastIndexOfScalar(u8, rel, '/')) |pos| return rel[pos + 1 ..];
    return rel;
}

// ---------------------------------------------------------------------------
// Opening directories
// ---------------------------------------------------------------------------

/// Opens the task directory relative to the refcounted parent handle when
/// available. Returns null when an error was reported but tolerated.
fn openTaskDir(sh: *SharedWorkerState, w: *Worker, task: *DirTask) WalkError!?Handle {
    defer if (task.parent) |p| {
        p.release(sh);
        task.parent = null;
    };

    const open_result: anyerror!Handle = blk: {
        if (task.parent) |p| {
            break :blk openChild(sh, p.handle, basenameOf(task.rel), task);
        }
        const root = if (sh.root_path.len == 0) "." else sh.root_path;
        break :blk openRoot(sh, root);
    };

    const handle = open_result catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // The visitor already saw this link. Its target may have stopped
        // being a directory since the stat that queued the descent.
        if (backend == .darwin_bulk and task.follow_link and err == error.NotDir) return null;
        const plen = taskPrefixLen(sh, w, task);
        const display = if (plen > 0) w.path_buf[0 .. plen - 1] else sh.root_path;
        try reportError(sh, display, err);
        return null;
    };
    return handle;
}

fn openChild(sh: *SharedWorkerState, parent: Handle, name: []const u8, task: *DirTask) anyerror!Handle {
    if (is_posix_backend) {
        var name_z: [NAME_BUF:0]u8 = undefined;
        if (name.len > NAME_MAX) return error.NameTooLong;
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;
        const flags: posix.O = .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
            .NOFOLLOW = !sh.options.follow_symlinks or (backend == .darwin_bulk and !task.follow_link),
        };
        if (builtin.os.tag == .linux and sh.options.follow_symlinks) {
            // The task's inherited (dev, d_ino) key is only right while the
            // open stays on the parent's filesystem. RESOLVE_NO_XDEV makes a
            // mount-point crossing fail with EXDEV; then (and when openat2 is
            // unavailable) the task is re-keyed by statx once opened.
            if (!sh.openat2_unavailable.load(.monotonic)) {
                switch (openat2NoXdevNoatime(sh, parent, name_z[0..name.len :0], flags)) {
                    .opened => |fd| return fd,
                    .xdev => {},
                    .unavailable => sh.openat2_unavailable.store(true, .monotonic),
                    .other => {}, // let openat report the error
                }
            }
            task.verify_key = true;
        }
        return openDirNoatime(sh, parent, name_z[0..name.len :0], flags);
    } else if (is_windows_backend) {
        return win.openChildDir(parent, name);
    } else {
        return parent.openDir(sh.io, name, .{ .iterate = true });
    }
}

/// POSIX directory open with O_NOATIME on Linux (see
/// `SharedWorkerState.noatime_ok`). EPERM is the only way a read-only
/// directory open can fail *because of* O_NOATIME, so on EPERM with the flag
/// set retry once without it and stop asking for it for the rest of the walk.
fn openDirNoatime(sh: *SharedWorkerState, dir_fd: posix.fd_t, name_z: [*:0]const u8, base_flags: posix.O) posix.OpenError!posix.fd_t {
    if (comptime builtin.os.tag != .linux) return posix.openatZ(dir_fd, name_z, base_flags, 0);
    var flags = base_flags;
    const noatime = sh.noatime_ok.load(.monotonic);
    flags.NOATIME = noatime;
    return posix.openatZ(dir_fd, name_z, flags, 0) catch |err| {
        if (!noatime or err != error.PermissionDenied) return err;
        sh.noatime_ok.store(false, .monotonic);
        flags.NOATIME = false;
        return posix.openatZ(dir_fd, name_z, flags, 0);
    };
}

fn openRoot(sh: *SharedWorkerState, root: []const u8) anyerror!Handle {
    if (is_posix_backend) {
        var path_z: [MAX_PATH:0]u8 = undefined;
        if (root.len >= MAX_PATH) return error.NameTooLong;
        @memcpy(path_z[0..root.len], root);
        path_z[root.len] = 0;
        return openDirNoatime(sh, posix.AT.FDCWD, path_z[0..root.len :0], .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        });
    } else if (is_windows_backend) {
        // Reuse std's path normalization for the single root open; children
        // open NT-natively relative to it afterwards.
        const dir = try std.Io.Dir.cwd().openDir(sh.io, root, .{ .iterate = true });
        return dir.handle;
    } else {
        return std.Io.Dir.cwd().openDir(sh.io, root, .{ .iterate = true });
    }
}

// ---------------------------------------------------------------------------
// .gitignore
// ---------------------------------------------------------------------------

/// One bit test against the union last-byte filter of the whole chain (the
/// node's own document, every ancestor and the synthetic root): if no rule
/// anywhere in scope can end a match on this byte, the 2.4 KB GitIgnore nodes
/// are never touched. Deliberately not `inline`: nested in the
/// worker's matching path it miscompiled in Debug on the self-hosted backend.
fn chainMayIgnore(start: ?*IgnoreNode, extra: ?*IgnoreNode, last: u8) bool {
    const f: *const gitignore_mod.LastByteFilter = if (start) |n| &n.chain_last else if (extra) |x| &x.chain_last else return false;
    return f.mayContainByte(last);
}

fn loadIgnoreNode(
    sh: *SharedWorkerState,
    handle: Handle,
    parent: ?*IgnoreNode,
    dir: []const u8,
    offset: usize,
    dot_git: ?git_excludes.DotGit,
    saw_dot_jj: bool,
    saw_gitignore: bool,
    saw_dot_ignore: bool,
) WalkError!?*IgnoreNode {
    const git_exists = if (dot_git) |hint| switch (hint) {
        .directory, .file => true,
        .unknown => hasBoundaryMarker(sh, handle, ".git"),
    } else false;
    const vcs = git_exists or (saw_dot_jj and hasBoundaryMarker(sh, handle, ".jj"));
    const repo = if (!vcs or !sh.git.enabled())
        git_excludes.Docs{}
    else if (git_exists)
        sh.git.load(dir, dot_git.?)
    else
        sh.git.loadGlobal(dir);
    const git = if (saw_gitignore)
        readSmallFile(sh, handle, ".gitignore", .no_follow)
    else
        null;
    const git_node = try parseIgnoreNode(sh, parent, offset, repo, git, .git, vcs);
    errdefer if (git_node) |node| node.release(sh.allocator);
    if (saw_dot_ignore) {
        const ign = readSmallFile(sh, handle, ".ignore", .follow);
        if (try parseIgnoreNode(sh, git_node orelse parent, offset, .{}, ign, .dot_ignore, false)) |node| {
            if (git_node) |g| g.release(sh.allocator);
            return node;
        }
    }
    return git_node;
}

fn hasBoundaryMarker(sh: *SharedWorkerState, handle: Handle, name: []const u8) bool {
    const dir: std.Io.Dir = if (is_posix_backend or is_windows_backend) .{ .handle = handle } else handle;
    _ = dir.statFile(sh.io, name, .{ .follow_symlinks = true }) catch return false;
    return true;
}

fn parseIgnoreNode(
    sh: *SharedWorkerState,
    parent: ?*IgnoreNode,
    offset: usize,
    repo: git_excludes.Docs,
    rules: ?[]u8,
    source: @FieldType(IgnoreNode, "source"),
    git_boundary: bool,
) WalkError!?*IgnoreNode {
    const n: usize = repo.count() + @intFromBool(rules != null);
    if (n == 0 and !git_boundary) return null;
    const sources = sh.allocator.alloc([]const u8, n) catch {
        repo.deinit(sh.allocator);
        if (rules) |b| sh.allocator.free(b);
        return error.OutOfMemory;
    };
    var i: usize = 0;
    for ([_]?[]u8{ repo.excludes_file, repo.info_exclude, rules }) |src| {
        if (src) |b| {
            sources[i] = b;
            i += 1;
        }
    }

    const syntax: GitIgnore.Syntax = if (source == .dot_ignore) .ignore_compat else .git;
    var gi = GitIgnore.parseOwnedMultiWithSyntax(sh.allocator, sources, syntax) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };

    const node = sh.allocator.create(IgnoreNode) catch |err| {
        gi.deinit();
        return err;
    };
    if (parent) |p| p.retain();
    node.* = .{
        .parent = parent,
        .gi = gi,
        .relative_offset = @intCast(offset),
        .refs = .init(1),
        .chain_last = gi.any_last,
        .source = source,
        .git_boundary = git_boundary,
    };
    if (parent) |p| node.chain_last.merge(p.chain_last) else if (sh.extra_ignore_root) |x| node.chain_last.merge(x.chain_last);
    return node;
}

/// Build the ancestor rule chain from the filesystem root to the walk root.
pub fn loadParentIgnoreRules(sh: *SharedWorkerState) WalkError!void {
    const root = if (sh.root_path.len == 0) "." else sh.root_path;
    const absolute = std.Io.Dir.cwd().realPathFileAlloc(sh.io, root, sh.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return, // The walker reports an inaccessible root as usual.
    };
    defer sh.allocator.free(absolute);
    if (absolute.len >= MAX_PATH) return;

    var dirs: [MAX_PATH / 2 + 1][]const u8 = undefined;
    var count: usize = 0;
    var dir: []const u8 = absolute;
    while (std.fs.path.dirname(dir)) |parent| {
        dirs[count] = parent;
        count += 1;
        dir = parent;
    }
    var parents: ?*IgnoreNode = null;
    errdefer if (parents) |parent| parent.release(sh.allocator);
    while (count > 0) {
        count -= 1;
        const path = dirs[count];
        const handle = openRoot(sh, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer closeHandle(handle, sh.io);
        const offset = path.len + @intFromBool(!std.fs.path.isSep(path[path.len - 1]));
        if (try loadIgnoreNode(sh, handle, parents, path, offset, .unknown, true, !sh.options.skip_gitignore, !sh.options.skip_dot_ignore)) |node| {
            if (parents) |parent| parent.release(sh.allocator);
            parents = node;
        }
    }
    if (parents == null) return;
    const need_slash = !std.fs.path.isSep(absolute[absolute.len - 1]);
    const prefix = try sh.allocator.alloc(u8, absolute.len + @intFromBool(need_slash));
    @memcpy(prefix[0..absolute.len], absolute);
    if (need_slash) prefix[absolute.len] = '/';
    if (builtin.os.tag == .windows) {
        for (prefix) |*byte| {
            if (byte.* == '\\') byte.* = '/';
        }
    }
    sh.ignore_rules.scope_prefix = prefix;
    sh.ignore_rules.parents = parents;
}

const max_gitignore_size = 1024 * 1024;
const RuleFileSymlinks = enum { follow, no_follow };

fn readSmallFile(sh: *SharedWorkerState, handle: Handle, name: [:0]const u8, symlinks: RuleFileSymlinks) ?[]u8 {
    if (is_posix_backend) {
        const fd = posix.openatZ(handle, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = symlinks == .no_follow, .NONBLOCK = true }, 0) catch return null;
        defer closeFd(fd);

        // tries to read the file into the small bufefer cause most of gitignore files are tiny
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(sh.allocator);
        list.ensureTotalCapacity(sh.allocator, 8192) catch return null;
        while (true) {
            const spare = list.unusedCapacitySlice();
            if (spare.len == 0) {
                if (list.items.len >= max_gitignore_size) break;
                list.ensureUnusedCapacity(sh.allocator, list.items.len) catch return null;
                continue;
            }
            const n = posix.read(fd, spare) catch return null;
            if (n == 0) break;
            list.items.len += n;
        }
        return list.toOwnedSlice(sh.allocator) catch null;
    } else if (is_windows_backend) {
        return win.readSmallFileAt(sh.allocator, handle, name, max_gitignore_size, symlinks == .no_follow);
    } else {
        const file = handle.openFile(sh.io, name, .{ .follow_symlinks = symlinks == .follow }) catch return null;
        defer file.close(sh.io);
        var reader = file.reader(sh.io, &.{});
        return reader.interface.allocRemaining(sh.allocator, .limited(max_gitignore_size)) catch null;
    }
}

/// Literal leading *directory* components of a glob pattern (no glob syntax).
/// "src/lib/**/*.c" -> "src/lib"; "**/*.c" -> ""; "src/*.c" -> "src";
/// "src/foo" -> "src". Used to prune traversal outside the pattern's scope.
pub fn literalPatternPrefixDirs(pattern: []const u8, flags: types.ZlobFlags) []const u8 {
    const lit = pattern[0..pattern_context.firstWildcardPos(pattern, flags)];
    if (mem.lastIndexOfScalar(u8, lit, '/')) |pos| return lit[0..pos];
    return &.{};
}

/// True when a directory may contain entries matched by a pattern whose
/// literal prefix is `prefix`: the dir is an ancestor of the prefix or lives
/// inside it.
fn dirInPatternScope(prefix: []const u8, dir_rel: []const u8) bool {
    if (prefix.len == 0) return true;
    if (dir_rel.len <= prefix.len) {
        return mem.startsWith(u8, prefix, dir_rel) and
            (dir_rel.len == prefix.len or prefix[dir_rel.len] == '/');
    }
    return mem.startsWith(u8, dir_rel, prefix) and dir_rel[prefix.len] == '/';
}

const SymlinkStat = struct { is_dir: bool, key: InodeKey };

/// Inode number of every btrfs subvolume root as seen from inside it. A
/// subvolume's entry in its parent's listing carries the subvolume id instead,
/// so the "." check below already catches the crossing unless that id is 256
/// itself; treating 256 as always-suspect closes the gap.
const BTRFS_FIRST_FREE_OBJECTID: u64 = 256;

const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };
const RESOLVE_NO_XDEV: u64 = 0x01;

fn openat2NoXdev(dirfd: posix.fd_t, name_z: [*:0]const u8, flags: posix.O) usize {
    if (comptime builtin.os.tag != .linux) unreachable;
    var how: OpenHow = .{ .flags = @as(u32, @bitCast(flags)), .mode = 0, .resolve = RESOLVE_NO_XDEV };
    return linux.syscall4(.openat2, @bitCast(@as(isize, dirfd)), @intFromPtr(name_z), @intFromPtr(&how), @sizeOf(OpenHow));
}

const Openat2Result = union(enum) { opened: posix.fd_t, xdev, unavailable, other };

/// openat2(RESOLVE_NO_XDEV) with the same O_NOATIME policy as
/// `openDirNoatime`. EPERM is ambiguous here: O_NOATIME refused on a foreign
/// directory, or openat2 itself filtered by seccomp. With the flag set, a
/// first EPERM retries once without it; only an EPERM without the flag (or
/// ENOSYS) marks openat2 unavailable.
fn openat2NoXdevNoatime(sh: *SharedWorkerState, dirfd: posix.fd_t, name_z: [*:0]const u8, base_flags: posix.O) Openat2Result {
    var flags = base_flags;
    var noatime = sh.noatime_ok.load(.monotonic);
    flags.NOATIME = noatime;
    while (true) {
        const rc = openat2NoXdev(dirfd, name_z, flags);
        switch (linux.errno(rc)) {
            .SUCCESS => return .{ .opened = @intCast(rc) },
            .XDEV => return .xdev,
            .NOSYS => return .unavailable,
            .PERM => {
                if (!noatime) return .unavailable;
                sh.noatime_ok.store(false, .monotonic);
                noatime = false;
                flags.NOATIME = false;
            },
            else => return .other,
        }
    }
}

/// Linux, follow_symlinks: a child task was keyed by its parent's device and
/// the parent listing's d_ino. Inside the directory, the "." record reports
/// the inode as the directory's own filesystem sees it; when the two agree the
/// key is exact and no statx is needed. They disagree across a btrfs
/// subvolume boundary (listing: subvolume id, ".": 256) and a mount point
/// (listing: covered inode; the EXDEV open path also sets `verify_key`), so
/// those pay one statx to learn the real (dev, ino). The task's own key is
/// already in the visited set, so only a *different* real key can mean the
/// directory was visited before; then this returns false.
fn resolveTaskKey(sh: *SharedWorkerState, task: *DirTask, handle: Handle, dot_ino: u64) Allocator.Error!bool {
    if (!task.verify_key and dot_ino != 0 and dot_ino == task.ino and dot_ino != BTRFS_FIRST_FREE_OBJECTID) {
        @branchHint(.likely);
        return true;
    }
    var stx: linux.Statx = undefined;
    const rc = linux.statx(handle, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return true;
    const key: InodeKey = .{
        .dev = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor),
        .ino = stx.ino,
    };
    if (key.dev == task.dev and key.ino == task.ino) return true;
    // A real (dev, ino) off the root's device: that filesystem was never
    // examined by the short-read gate (see the symlink branch of
    // processEntry). Tasks that crossed a mount (`verify_key`) reach here
    // before their own scan, so the listing of this very directory is
    // already read without trust; the btrfs-subvolume case stays on the
    // root's device and its scan is unaffected.
    if (key.dev != sh.root_dev) sh.trust_short.store(false, .release);
    if (try sh.visitedBefore(key)) return false;
    task.dev = key.dev;
    task.ino = key.ino;
    return true;
}

pub fn recordRootVisited(sh: *SharedWorkerState) Allocator.Error!void {
    const root = if (sh.root_path.len == 0) "." else sh.root_path;
    if (is_windows_backend) {
        return; // symlink following unimplemented on the ntdll backend
    } else if (is_posix_backend) {
        var path_z: [MAX_PATH:0]u8 = undefined;
        if (root.len >= MAX_PATH) return;
        @memcpy(path_z[0..root.len], root);
        path_z[root.len] = 0;
        if (builtin.os.tag == .linux) {
            var stx: linux.Statx = undefined;
            const rc = linux.statx(types.AT_FDCWD, path_z[0..root.len :0], 0, .{ .INO = true }, &stx);
            if (linux.errno(rc) != .SUCCESS) return;
            const dev = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor);
            sh.root_dev = dev;
            sh.root_key = .{ .dev = dev, .ino = stx.ino };
        } else {
            var st: std.c.Stat = undefined;
            if (std.c.fstatat(types.AT_FDCWD, path_z[0..root.len :0], &st, 0) != 0) return;
            sh.root_key = .{
                .dev = @bitCast(@as(i64, @intCast(st.dev))),
                .ino = @intCast(st.ino),
            };
        }
    } else {
        const stat = std.Io.Dir.cwd().statFile(sh.io, root, .{ .follow_symlinks = true }) catch return;
        sh.root_key = .{ .dev = 0, .ino = @intCast(stat.inode) };
    }
    _ = try sh.visitedBefore(sh.root_key);
}

/// Stats the handle as fast as possible
fn statForSymlink(sh: *SharedWorkerState, handle: Handle, name: []const u8, follow: bool) ?SymlinkStat {
    if (is_windows_backend) {
        return null; // reparse-point targets are never descended
    } else if (builtin.os.tag == .linux) {
        var name_z: [NAME_BUF:0]u8 = undefined;
        if (name.len > NAME_MAX) return null;
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;
        // request as few infromation as is_posix_backend
        var stx: linux.Statx = undefined;
        const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
        const rc = linux.statx(handle, name_z[0..name.len :0], flags, .{ .TYPE = true, .INO = true }, &stx);
        if (linux.errno(rc) != .SUCCESS) return null;
        const dev = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor);
        return .{
            .is_dir = (@as(u32, stx.mode) & 0o170000) == 0o040000,
            .key = .{ .dev = dev, .ino = stx.ino },
        };
    } else if (is_posix_backend) {
        var name_z: [NAME_BUF:0]u8 = undefined;
        if (name.len > NAME_MAX) return null;
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;
        var st: std.c.Stat = undefined;
        const flags: u32 = if (follow) 0 else std.c.AT.SYMLINK_NOFOLLOW;
        if (std.c.fstatat(handle, name_z[0..name.len :0], &st, flags) != 0) return null;
        return .{
            .is_dir = (@as(u32, @intCast(st.mode)) & 0o170000) == 0o040000,
            .key = .{ .dev = @bitCast(@as(i64, @intCast(st.dev))), .ino = @intCast(st.ino) },
        };
    } else {
        const stat = handle.statFile(sh.io, name, .{ .follow_symlinks = follow }) catch return null;
        return .{
            .is_dir = stat.kind == .directory,
            .key = .{ .dev = 0, .ino = @intCast(stat.inode) },
        };
    }
}

// ---------------------------------------------------------------------------
// Error reporting
// ---------------------------------------------------------------------------

fn reportError(sh: *SharedWorkerState, full_path: []const u8, err: anyerror) WalkError!void {
    if (sh.options.err_callback) |cb| {
        var path_z: [MAX_PATH:0]u8 = undefined;
        const len = @min(full_path.len, MAX_PATH - 1);
        @memcpy(path_z[0..len], full_path[0..len]);
        path_z[len] = 0;
        if (cb(&path_z, errnoFromOpenError(err)) != 0) return error.Aborted;
    }
    if (sh.options.abort_on_error) return abortError(err);
}

/// Narrows an arbitrary open/scan error to the surfaceable `WalkError` set.
fn abortError(err: anyerror) WalkError {
    return switch (err) {
        error.ReadFailed => error.ReadFailed,
        error.PermissionDenied, error.AccessDenied => error.PermissionDenied,
        error.NameTooLong => error.NameTooLong,
        else => error.Aborted,
    };
}

/// Maps an open/scan error to the platform errno (values differ across OSes).
pub fn errnoFromOpenError(err: anyerror) c_int {
    const e: std.c.E = switch (err) {
        error.AccessDenied, error.PermissionDenied => .ACCES,
        error.FileNotFound => .NOENT,
        error.NotDir => .NOTDIR,
        error.SymLinkLoop => .LOOP,
        error.NameTooLong => .NAMETOOLONG,
        error.SystemResources, error.OutOfMemory => .NOMEM,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => .MFILE,
        else => .IO,
    };

    return @backingInt(e);
}
