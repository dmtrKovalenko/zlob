//! Parallel recursive directory walker — zlob's replacement for the Rust
//! `walkdir` + `ignore` crates, exposed to Zig, C and Rust.
//!
//! Design (performance is the north star):
//! - One task = one directory. Per-worker LIFO queues feed N worker threads,
//!   with stealing when a worker runs dry. LIFO keeps traversal depth-first,
//!   which bounds open fds and keeps the dcache hot.
//! - Directories are opened with openat() relative to a refcounted parent
//!   fd — no path re-resolution per directory.
//! - Platform scanners:
//!     * Linux: raw getdents64 into a per-worker 64 KiB buffer; metadata via
//!       statx only when requested (inode comes free from the dirent).
//!     * macOS: getattrlistbulk — one syscall per batch returns names AND
//!       all requested metadata (see walk_darwin.zig). Per-fs fallback to
//!       readdir+fstatat when the filesystem doesn't support it.
//!     * Windows: NtQueryDirectoryFile with File(Id)BothDirectoryInformation
//!       (see walk_windows.zig) — every batch already carries sizes, all
//!       four timestamps and the file id, so metadata is free. Directories
//!       open NT-natively relative to the parent handle.
//!     * Everything else: std.Io.Dir fallback.
//! - Metadata is selected with a runtime `MetaMask` so callers only pay for
//!   the attributes they need (this is what enables the macOS bulk path).
//! - .gitignore: nested files are supported. Each directory's .gitignore is
//!   detected from the directory listing itself (no speculative open),
//!   parsed once into an immutable `GitIgnore`, and shared down the tree via
//!   a refcounted parent chain. Matching is lock-free and runs in parallel
//!   on the worker that scanned the directory.
//!
//! The allocator passed to `run`/`collect` MUST be thread-safe when
//! `threads != 1` (e.g. `std.heap.smp_allocator`, `std.heap.c_allocator`).

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const gitignore_mod = @import("gitignore.zig");
const compiled_pattern = @import("compiled_pattern.zig");
const darwin = @import("walk_darwin.zig");
const win = @import("walk_windows.zig");
const winos = std.os.windows;

pub const ZlobFlags = @import("zlob.zig").ZlobFlags;
pub const CompiledPattern = compiled_pattern.CompiledPattern;

pub const GitIgnore = gitignore_mod.GitIgnore;
pub const EntryKind = std.Io.File.Kind;
pub const ErrCallbackFn = *const fn (epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int;

const MAX_PATH = 4096;

pub const Backend = enum { linux_getdents, darwin_bulk, windows_ntdll, std_fs };

pub const backend: Backend = if (builtin.os.tag == .linux)
    .linux_getdents
else if (darwin.supported)
    .darwin_bulk
else if (win.supported)
    .windows_ntdll
else
    .std_fs;

const is_posix_backend = backend == .linux_getdents or backend == .darwin_bulk;
const is_windows_backend = backend == .windows_ntdll;
const posix = std.posix;
const linux = std.os.linux;

/// Which metadata attributes to fetch per entry. Empty mask (default) means
/// the walker never stats anything — entry kind still comes free from the
/// directory listing on every backend.
pub const MetaMask = packed struct(u32) {
    size: bool = false,
    mtime: bool = false,
    atime: bool = false,
    ctime: bool = false,
    /// Creation (birth) time. Not available on all filesystems.
    btime: bool = false,
    inode: bool = false,
    nlink: bool = false,
    /// Permission bits (mode & 0o7777). File type comes from `Entry.kind`.
    mode: bool = false,
    uid: bool = false,
    gid: bool = false,
    _reserved: u22 = 0,

    pub const none: MetaMask = .{};
    pub const all: MetaMask = .{
        .size = true,
        .mtime = true,
        .atime = true,
        .ctime = true,
        .btime = true,
        .inode = true,
        .nlink = true,
        .mode = true,
        .uid = true,
        .gid = true,
    };

    pub inline fn any(self: MetaMask) bool {
        return @as(u32, @bitCast(self)) != 0;
    }

    pub inline fn toInt(self: MetaMask) u32 {
        return @bitCast(self);
    }

    pub inline fn fromInt(v: u32) MetaMask {
        var m: MetaMask = @bitCast(v);
        m._reserved = 0;
        return m;
    }
};

/// Per-entry metadata. Only fields whose bit is set in `valid` carry
/// meaningful values; a requested attribute can still be invalid when the
/// filesystem doesn't support it (e.g. btime on ext3).
/// Semantics are lstat-like: symlinks are never followed.
pub const Metadata = struct {
    size: u64 = 0,
    mtime_ns: i64 = 0,
    atime_ns: i64 = 0,
    ctime_ns: i64 = 0,
    btime_ns: i64 = 0,
    inode: u64 = 0,
    nlink: u32 = 0,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    valid: MetaMask = .{},
};

/// A reported filesystem entry. All slices are only valid for the duration
/// of the visitor callback (run()) — `collect()` returns owned copies.
pub const Entry = struct {
    /// Full path: walk root joined with the relative path.
    /// Guaranteed NUL-terminated at `path.len` for zero-cost C interop.
    path: []const u8,
    /// Offset into `path` where the root-relative part starts.
    rel_off: u32,
    /// Basename (slice into `path`).
    basename: []const u8,
    kind: EntryKind,
    /// Depth below the root: direct children of the root have depth 1.
    depth: u16,
    meta: Metadata,

    pub inline fn relPath(self: *const Entry) []const u8 {
        return self.path[self.rel_off..];
    }
};

pub const VisitAction = enum(c_int) {
    /// Keep walking.
    cont = 0,
    /// Don't descend into this directory (no effect on files).
    skip_dir = 1,
    /// Stop the whole walk as soon as possible.
    stop = 2,
};

/// Visitor for `run()`. With `threads != 1` the callback is invoked
/// concurrently from multiple worker threads — it must be thread-safe.
pub const Visitor = struct {
    context: ?*anyopaque = null,
    visit: *const fn (context: ?*anyopaque, entry: *const Entry) VisitAction,
};

pub const Options = struct {
    /// Worker thread count. 0 = one per CPU. 1 = run on the calling thread.
    threads: u16 = 0,
    /// Maximum entry depth to yield/descend (root children = 1). 0 = unlimited.
    max_depth: u16 = 0,
    /// Descend into symlinked directories (cycles are detected and broken).
    /// Not yet supported by the Windows ntdll backend — reparse points are
    /// reported but never descended there.
    follow_symlinks: bool = false,
    /// Report entries whose name starts with '.'. Hidden directories are not
    /// descended into when false.
    include_hidden: bool = true,
    /// Honor .gitignore files (nested ones included).
    respect_gitignore: bool = true,
    /// Skip ".git" directories (only when respect_gitignore is set).
    skip_git_dir: bool = true,
    /// Report directory entries (directories are traversed either way).
    report_dirs: bool = true,
    /// Glob filter: only entries whose root-relative path matches the
    /// pattern are reported (e.g. "**/*.rs", "src/**", "*.{c,h}").
    /// Traversal itself is also narrowed: directories outside the pattern's
    /// literal prefix (e.g. everything but "src/" for "src/**/*.c") are
    /// pruned without ever being opened. Compiled once per walk; matching
    /// runs lock-free on the workers.
    pattern: ?[]const u8 = null,
    /// Flags for compiling/matching `pattern`.
    /// Default: brace expansion + recursive `**`.
    pattern_flags: ZlobFlags = .{ .brace = true, .doublestar_recursive = true },
    /// Metadata to fetch per entry. Keep empty if you only need names/kinds.
    meta: MetaMask = .{},
    /// Sort collected results by path (collect() only). Parallel traversal
    /// is inherently unordered; sorting happens once at the end.
    sort: bool = false,
    err_callback: ?ErrCallbackFn = null,
    abort_on_error: bool = false,
    /// Io instance used for queue synchronization and by the std_fs
    /// fallback backend (platforms without a native scanner). Defaults to a
    /// blocking single-threaded Io that is safe to use from multiple workers.
    io: ?std.Io = null,
};

/// Entry produced by platform scanners before path assembly/filtering.
/// `name` points into a scanner-owned buffer; valid until the next scanner call.
pub const RawEntry = struct {
    name: []const u8,
    kind: EntryKind,
    meta: Metadata,
};

// ---------------------------------------------------------------------------
// Refcounted resources shared across tasks
// ---------------------------------------------------------------------------

const Handle = if (is_posix_backend)
    posix.fd_t
else if (is_windows_backend)
    winos.HANDLE
else
    std.Io.Dir;

const AT_FDCWD: posix.fd_t = if (builtin.os.tag == .linux) linux.AT.FDCWD else std.c.AT.FDCWD;

inline fn closeFd(fd: posix.fd_t) void {
    if (builtin.os.tag == .linux) {
        _ = linux.close(fd);
    } else {
        _ = std.c.close(fd);
    }
}

const HandleRef = struct {
    handle: Handle,
    refs: std.atomic.Value(u32),

    fn retain(self: *HandleRef) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *HandleRef, sh: *Shared) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            closeHandle(self.handle, sh.io);
            sh.gpa.destroy(self);
        }
    }
};

inline fn closeHandle(h: Handle, io: std.Io) void {
    if (is_posix_backend) {
        closeFd(h);
    } else if (is_windows_backend) {
        winos.CloseHandle(h);
    } else {
        var d = h;
        d.close(io);
    }
}

/// One parsed .gitignore, rooted at some directory of the walk, linked to
/// the nearest ancestor .gitignore. Immutable after creation — matching is
/// lock-free from any thread. Refcounted: held by tasks and child nodes.
const IgnoreNode = struct {
    parent: ?*IgnoreNode,
    gi: GitIgnore,
    /// Offset into the root-relative entry path where paths relative to this
    /// node's directory start.
    rel_off: u32,
    refs: std.atomic.Value(u32),

    fn retain(self: *IgnoreNode) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self_in: *IgnoreNode, gpa: Allocator) void {
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

/// Deepest-first resolution across nested .gitignore files: the first file
/// with a decisive answer (match or negation) wins, mirroring git. Note git
/// semantics make pruning exact: once a directory is ignored nothing inside
/// it can be re-included, so an ignored directory is never descended.
fn chainIgnored(start: *IgnoreNode, rel: []const u8, basename: []const u8, is_dir: bool) bool {
    var node: ?*IgnoreNode = start;
    while (node) |n| : (node = n.parent) {
        if (n.gi.checkWithBasename(rel[n.rel_off..], basename, is_dir)) |verdict| {
            return verdict;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Task queue — per-worker mutex-protected LIFO with work-stealing
// ---------------------------------------------------------------------------

const DirTask = struct {
    /// Root-relative directory path ("" = the root itself). Owned.
    rel: []u8,
    depth: u16,
    /// Nearest .gitignore chain (one ref owned by the task).
    ignore: ?*IgnoreNode,
    /// Parent directory handle (one ref owned by the task) — child is opened
    /// relative to it. Null for the root task.
    parent: ?*HandleRef,
};

const LocalQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(*DirTask) = .empty,
    /// Approximate item count for lock-free empty checks during stealing.
    approx_len: std.atomic.Value(usize) = .init(0),

    fn deinit(lq: *LocalQueue, gpa: Allocator) void {
        lq.items.deinit(gpa);
    }
};

const Queue = struct {
    locals: []LocalQueue = &.{},
    wait_mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queued: std.atomic.Value(usize) = .init(0),
    /// Tasks pushed but not yet finished, including queued and in-flight.
    outstanding: std.atomic.Value(usize) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),

    fn init(q: *Queue, gpa: Allocator, workers: u32) !void {
        const n: usize = @max(1, @as(usize, @intCast(workers)));
        q.locals = try gpa.alloc(LocalQueue, n);
        for (q.locals) |*local| local.* = .{};
    }

    fn localIndex(q: *Queue, worker_id: u32) usize {
        return @as(usize, @intCast(worker_id)) % q.locals.len;
    }

    fn wakeOne(q: *Queue, io: std.Io) void {
        q.wait_mutex.lockUncancelable(io);
        defer q.wait_mutex.unlock(io);
        q.cond.signal(io);
    }

    fn wakeAll(q: *Queue, io: std.Io) void {
        q.wait_mutex.lockUncancelable(io);
        defer q.wait_mutex.unlock(io);
        q.cond.broadcast(io);
    }

    fn push(q: *Queue, gpa: Allocator, io: std.Io, worker_id: u32, t: *DirTask) !void {
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

    /// Blocks until a task is available or the walk is finished.
    fn pop(q: *Queue, io: std.Io, worker_id: u32) ?*DirTask {
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

    fn taskDone(q: *Queue, io: std.Io) void {
        if (q.outstanding.fetchSub(1, .acq_rel) == 1) {
            q.closed.store(true, .release);
            q.wakeAll(io);
        }
    }

    fn deinit(q: *Queue, gpa: Allocator) void {
        for (q.locals) |*local| local.deinit(gpa);
        gpa.free(q.locals);
    }
};

// ---------------------------------------------------------------------------
// Shared walk state
// ---------------------------------------------------------------------------

const SinkFn = *const fn (ctx: *anyopaque, worker_id: u32, entry: *const Entry) VisitAction;

const Failure = enum(u8) { none = 0, aborted = 1, oom = 2 };

const InodeKey = struct { dev: u64, ino: u64 };

const Shared = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    root_path: []const u8,
    /// "root/" — copied into each worker's path buffer at init.
    root_path_with_slash: []const u8,
    /// Length of the root prefix (root + trailing '/') inside path buffers.
    root_prefix_len: u32,
    queue: Queue = .{},
    stop: std.atomic.Value(bool) = .init(false),
    failure: std.atomic.Value(u8) = .init(0),
    sink: SinkFn,
    sink_ctx: *anyopaque,
    /// Compiled glob filter (immutable — matched lock-free from any worker).
    pattern: ?*const CompiledPattern = null,
    /// Literal directory prefix of the pattern ("src/lib" for
    /// "src/lib/**/*.c", "" when the pattern starts with a wildcard) used to
    /// prune traversal outside the pattern's scope.
    pattern_prefix: []const u8 = &.{},
    /// Pre-computed statx mask (Linux) for the requested metadata.
    statx_mask: if (builtin.os.tag == .linux) linux.STATX else void,
    /// Symlink-cycle bookkeeping, only touched when follow_symlinks is set.
    visited_mutex: std.Io.Mutex = .init,
    visited: std.AutoHashMapUnmanaged(InodeKey, void) = .empty,

    /// Lazy worker spawning. Helper threads are only created once the walk
    /// has demonstrably parallel work, so shallow trees (a single directory,
    workers: []Worker = &.{},
    threads: []std.Thread = &.{},
    spawn_started: std.atomic.Value(bool) = .init(false),
    spawned: usize = 0,

    fn fail(sh: *Shared, f: Failure) void {
        sh.stop.store(true, .release);
        // Keep the first failure.
        _ = sh.failure.cmpxchgStrong(@intFromEnum(Failure.none), @intFromEnum(f), .acq_rel, .acquire);
    }

    /// Spawn the helper worker threads on first call (idempotent). Invoked by
    /// the calling thread once it sees enough queued work to justify the cost;
    /// trees too small to fan out never trigger it and stay single-threaded.
    fn ensureWorkers(sh: *Shared) void {
        if (sh.threads.len == 0) return;
        if (sh.spawn_started.swap(true, .acq_rel)) return;
        for (sh.threads, 1..) |*t, i| {
            t.* = std.Thread.spawn(.{}, workerLoop, .{ sh, &sh.workers[i] }) catch break;
            sh.spawned += 1;
        }
        // A worker may have parked between the empty-queue check and us
        // marking work available; make sure freshly spawned threads wake.
        sh.queue.wakeAll(sh.io);
    }

    /// Returns true when the (dev, ino) pair was already visited.
    fn visitedBefore(sh: *Shared, key: InodeKey) bool {
        sh.visited_mutex.lockUncancelable(sh.io);
        defer sh.visited_mutex.unlock(sh.io);
        const gop = sh.visited.getOrPut(sh.gpa, key) catch return true;
        return gop.found_existing;
    }
};

fn freeTask(sh: *Shared, t: *DirTask) void {
    if (t.parent) |p| p.release(sh);
    if (t.ignore) |ig| ig.release(sh.gpa);
    sh.gpa.free(t.rel);
    sh.gpa.destroy(t);
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

/// Scratch entry: name stored in the worker's per-directory name arena.
const Scratch = struct {
    name_off: u32,
    name_len: u32,
    kind: EntryKind,
    meta: Metadata,
};

const Worker = struct {
    id: u32,
    sh: *Shared,
    /// Full-path assembly buffer; [0..root_prefix_len) holds "root/".
    path_buf: [MAX_PATH + 1]u8 = undefined,
    /// Per-directory name bytes (reset per task, capacity retained).
    names: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Scratch) = .empty,
    saw_gitignore: bool = false,
    /// Kernel buffer for getdents64 / getattrlistbulk.
    io_buf: []align(8) u8 = &.{},

    fn init(w: *Worker, id: u32, sh: *Shared) !void {
        w.* = .{ .id = id, .sh = sh };
        const buf_size: usize = switch (backend) {
            .linux_getdents => 64 * 1024,
            .darwin_bulk => 64 * 1024,
            .windows_ntdll => 128 * 1024,
            .std_fs => 0,
        };
        if (buf_size > 0) {
            w.io_buf = try sh.gpa.alignedAlloc(u8, .@"8", buf_size);
        }
        @memcpy(w.path_buf[0..sh.root_prefix_len], pathPrefixSource(sh));
    }

    fn deinit(w: *Worker) void {
        const gpa = w.sh.gpa;
        w.names.deinit(gpa);
        w.entries.deinit(gpa);
        if (w.io_buf.len > 0) gpa.free(w.io_buf);
    }
};

/// "root" or "root/" — what worker path buffers start with.
fn pathPrefixSource(sh: *Shared) []const u8 {
    return sh.root_path_with_slash;
}

fn workerLoop(sh: *Shared, w: *Worker) void {
    // Spawn helper threads once the calling thread (worker 0) has uncovered
    // more than a couple of pending directories: enough fan-out to amortize
    // the spawn cost. Shallow trees never reach the threshold and run
    // entirely on the caller, with zero thread overhead.
    const spawn_threshold = 2;
    while (sh.queue.pop(sh.io, w.id)) |task| {
        if (!sh.stop.load(.acquire)) {
            processDir(sh, w, task) catch |err| switch (err) {
                error.Aborted => sh.fail(.aborted),
                error.OutOfMemory => sh.fail(.oom),
            };
            if (w.id == 0 and sh.queue.queued.load(.monotonic) > spawn_threshold)
                sh.ensureWorkers();
        }
        freeTask(sh, task);
        sh.queue.taskDone(sh.io);
    }
}

const WalkError = error{ Aborted, OutOfMemory };

/// Maps an open/scan error to the platform's errno value (they differ across
/// OSes — e.g. ELOOP is 40 on Linux but 62 on Darwin).
fn errnoFromOpenError(err: anyerror) c_int {
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
    return @intFromEnum(e);
}

/// Report a per-directory error through the callback; error.Aborted when the
/// callback or abort_on_error requests it.
fn reportError(sh: *Shared, full_path: []const u8, err: anyerror) WalkError!void {
    if (sh.options.err_callback) |cb| {
        var path_z: [MAX_PATH:0]u8 = undefined;
        const len = @min(full_path.len, MAX_PATH - 1);
        @memcpy(path_z[0..len], full_path[0..len]);
        path_z[len] = 0;
        if (cb(&path_z, errnoFromOpenError(err)) != 0) return error.Aborted;
    }
    if (sh.options.abort_on_error) return error.Aborted;
}

fn processDir(sh: *Shared, w: *Worker, task: *DirTask) WalkError!void {
    // -- 1. Open the directory ------------------------------------------------
    const handle = (try openTaskDir(sh, w, task)) orelse return;
    var handle_consumed = false;
    defer if (!handle_consumed) closeHandle(handle, sh.io);

    // -- 2. Scan all entries into per-worker scratch --------------------------
    w.names.clearRetainingCapacity();
    w.entries.clearRetainingCapacity();
    w.saw_gitignore = false;
    scanDir(sh, w, handle) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // Treat scan failures like open failures: report and move on.
            const plen = taskPrefixLen(sh, w, task);
            try reportError(sh, w.path_buf[0..plen -| 1], err);
            return;
        },
    };

    // -- 3. Load this directory's .gitignore (detected from the listing) ------
    var cur_ignore: ?*IgnoreNode = task.ignore;
    var own_ignore = false;
    if (sh.options.respect_gitignore and w.saw_gitignore) {
        if (try loadIgnoreNode(sh, handle, task)) |node| {
            cur_ignore = node;
            own_ignore = true;
        }
    }
    defer if (own_ignore) cur_ignore.?.release(sh.gpa);

    // -- 4. Filter, emit, and queue child directories -------------------------
    const prefix_len = taskPrefixLen(sh, w, task);
    const opts = &sh.options;
    const entry_depth: u16 = task.depth +| 1;
    const may_descend = opts.max_depth == 0 or entry_depth < opts.max_depth;
    const want_meta = opts.meta.any();
    var child_ref: ?*HandleRef = null;
    defer if (child_ref) |cr| cr.release(sh);

    for (w.entries.items) |se| {
        const name = w.names.items[se.name_off..][0..se.name_len];
        try processEntry(sh, w, handle, name, se.kind, if (want_meta) se.meta else .{}, cur_ignore, prefix_len, entry_depth, may_descend, &child_ref, &handle_consumed);
    }
}

fn processEntry(
    sh: *Shared,
    w: *Worker,
    handle: Handle,
    name: []const u8,
    entry_kind: EntryKind,
    meta: Metadata,
    cur_ignore: ?*IgnoreNode,
    prefix_len: usize,
    entry_depth: u16,
    may_descend: bool,
    child_ref: *?*HandleRef,
    handle_consumed: *bool,
) WalkError!void {
    const opts = &sh.options;
    if (sh.stop.load(.monotonic)) return;
    if (name.len == 0) return;
    if (!opts.include_hidden and name[0] == '.') return;

    var is_dir = entry_kind == .directory;
    if (opts.respect_gitignore and opts.skip_git_dir and is_dir and
        mem.eql(u8, name, ".git")) return;

    if (prefix_len + name.len >= MAX_PATH) return;
    @memcpy(w.path_buf[prefix_len..][0..name.len], name);
    w.path_buf[prefix_len + name.len] = 0;
    const full = w.path_buf[0 .. prefix_len + name.len];
    const basename = full[prefix_len..];
    const rel_path = full[sh.root_prefix_len..];

    if (cur_ignore) |ig| {
        if (chainIgnored(ig, rel_path, basename, is_dir)) return;
    }

    if (!is_dir and opts.follow_symlinks and entry_kind == .sym_link) {
        is_dir = symlinkIsNewDir(sh, handle, name);
    } else if (is_dir and opts.follow_symlinks) {
        if (dirKeyAt(sh, handle, name)) |key| {
            if (sh.visitedBefore(key)) return;
        }
    }

    var action: VisitAction = .cont;
    var report = entry_kind != .directory or opts.report_dirs;
    if (report) {
        if (sh.pattern) |cp| report = cp.matches(rel_path, opts.pattern_flags);
    }
    if (report) {
        var entry = Entry{
            .path = full,
            .rel_off = sh.root_prefix_len,
            .basename = basename,
            .kind = entry_kind,
            .depth = entry_depth,
            .meta = meta,
        };
        action = sh.sink(sh.sink_ctx, w.id, &entry);
        if (action == .stop) {
            sh.stop.store(true, .release);
            return;
        }
    }

    if (is_dir and sh.pattern != null and !dirInPatternScope(sh.pattern_prefix, rel_path))
        return;

    if (is_dir and may_descend and action != .skip_dir) {
        const cr = child_ref.* orelse blk: {
            const cr = try sh.gpa.create(HandleRef);
            cr.* = .{ .handle = handle, .refs = .init(1) };
            child_ref.* = cr;
            handle_consumed.* = true;
            break :blk cr;
        };

        const rel = full[sh.root_prefix_len..];
        const child_rel = try sh.gpa.dupe(u8, rel);
        errdefer sh.gpa.free(child_rel);
        const child = try sh.gpa.create(DirTask);
        errdefer sh.gpa.destroy(child);

        cr.retain();
        errdefer cr.release(sh);
        if (cur_ignore) |ig| ig.retain();
        errdefer if (cur_ignore) |ig| ig.release(sh.gpa);

        child.* = .{
            .rel = child_rel,
            .depth = entry_depth,
            .ignore = cur_ignore,
            .parent = cr,
        };
        try sh.queue.push(sh.gpa, sh.io, w.id, child);
    }
}

/// Literal directory prefix of a glob pattern: the leading path components
/// that contain no glob syntax. "src/lib/**/*.c" -> "src/lib";
/// "**/*.c" -> ""; "src/*.c" -> "src". Conservative: any potentially special
/// character ends the scan.
fn literalPatternPrefixDirs(pattern: []const u8, flags: ZlobFlags) []const u8 {
    var first_special: usize = pattern.len;
    for (pattern, 0..) |ch, i| {
        const special = switch (ch) {
            '*', '?', '[', '\\' => true,
            '{' => flags.brace,
            '(' => flags.extglob,
            else => false,
        };
        if (special) {
            first_special = i;
            break;
        }
    }
    // Truncate to the last completed directory component.
    const lit = pattern[0..first_special];
    if (first_special == pattern.len) {
        // Fully literal pattern: its parent dirs are the scope.
        if (mem.lastIndexOfScalar(u8, lit, '/')) |pos| return lit[0..pos];
        return &.{};
    }
    if (mem.lastIndexOfScalar(u8, lit, '/')) |pos| return lit[0..pos];
    return &.{};
}

/// True when a directory (root-relative path) may contain entries matched by
/// a pattern whose literal prefix is `prefix`: the dir is an ancestor of the
/// prefix, or lives inside it.
fn dirInPatternScope(prefix: []const u8, dir_rel: []const u8) bool {
    if (prefix.len == 0) return true;
    if (dir_rel.len <= prefix.len) {
        // dir must be a leading component chain of prefix: "src" vs "src/lib"
        return mem.startsWith(u8, prefix, dir_rel) and
            (dir_rel.len == prefix.len or prefix[dir_rel.len] == '/');
    }
    // dir inside prefix scope: "src/lib/util" vs "src/lib"
    return mem.startsWith(u8, dir_rel, prefix) and dir_rel[prefix.len] == '/';
}

/// Copies "rel/" after the root prefix in the worker path buffer and returns
/// the total prefix length entries should be appended at.
fn taskPrefixLen(sh: *Shared, w: *Worker, task: *DirTask) usize {
    var pos: usize = sh.root_prefix_len;
    if (task.rel.len > 0) {
        @memcpy(w.path_buf[pos..][0..task.rel.len], task.rel);
        pos += task.rel.len;
        w.path_buf[pos] = '/';
        pos += 1;
    }
    return pos;
}

/// Opens the task directory (relative to the refcounted parent handle when
/// available). Returns null when the directory was skipped due to an error
/// that the error callback chose to ignore.
fn openTaskDir(sh: *Shared, w: *Worker, task: *DirTask) WalkError!?Handle {
    // Release the parent ref as soon as the open attempt is done.
    defer if (task.parent) |p| {
        p.release(sh);
        task.parent = null;
    };

    const open_result: anyerror!Handle = blk: {
        if (task.parent) |p| {
            const base = basenameOf(task.rel);
            break :blk openChild(sh, p.handle, base);
        }
        // Root task: open the configured root path.
        const root = if (sh.root_path.len == 0) "." else sh.root_path;
        break :blk openRoot(sh, root);
    };

    const handle = open_result catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const plen = taskPrefixLen(sh, w, task);
        const display = if (plen > 0) w.path_buf[0 .. plen - 1] else sh.root_path;
        try reportError(sh, display, err);
        return null;
    };
    return handle;
}

inline fn basenameOf(rel: []const u8) []const u8 {
    if (mem.lastIndexOfScalar(u8, rel, '/')) |pos| return rel[pos + 1 ..];
    return rel;
}

fn openChild(sh: *Shared, parent: Handle, name: []const u8) anyerror!Handle {
    if (is_posix_backend) {
        var name_z: [256:0]u8 = undefined;
        if (name.len >= 256) return error.NameTooLong;
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;
        return posix.openatZ(parent, name_z[0..name.len :0], .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
            .NOFOLLOW = !sh.options.follow_symlinks,
        }, 0);
    } else if (is_windows_backend) {
        return win.openChildDir(parent, name);
    } else {
        return parent.openDir(sh.io, name, .{ .iterate = true });
    }
}

fn openRoot(sh: *Shared, root: []const u8) anyerror!Handle {
    if (is_posix_backend) {
        var path_z: [MAX_PATH:0]u8 = undefined;
        if (root.len >= MAX_PATH) return error.NameTooLong;
        @memcpy(path_z[0..root.len], root);
        path_z[root.len] = 0;
        return posix.openatZ(posix.AT.FDCWD, path_z[0..root.len :0], .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
    } else if (is_windows_backend) {
        // Reuse std's path normalization (relative paths, prefixes, WTF-8)
        // for the single root open; children open NT-natively after this.
        const dir = try std.Io.Dir.cwd().openDir(sh.io, root, .{ .iterate = true });
        return dir.handle;
    } else {
        return std.Io.Dir.cwd().openDir(sh.io, root, .{ .iterate = true });
    }
}

// ---------------------------------------------------------------------------
// Symlink follow helpers
// ---------------------------------------------------------------------------

/// stat(FOLLOW) on a directory entry; true when it resolves to a directory
/// that has not been visited yet (records it as visited).
fn symlinkIsNewDir(sh: *Shared, handle: Handle, name: []const u8) bool {
    if (statEntry(sh, handle, name, true)) |res| {
        if (!res.is_dir) return false;
        return !sh.visitedBefore(res.key);
    }
    return false;
}

fn dirKeyAt(sh: *Shared, handle: Handle, name: []const u8) ?InodeKey {
    if (statEntry(sh, handle, name, false)) |res| return res.key;
    return null;
}

/// Marks the walk root itself as visited so a symlink pointing back at the
/// root is not descended (child dirs are deduped individually, but the
/// root's own files would otherwise be reported twice).
fn recordRootVisited(sh: *Shared) void {
    const root = if (sh.root_path.len == 0) "." else sh.root_path;
    if (is_windows_backend) {
        // Symlink following is not implemented on the ntdll backend.
        return;
    } else if (is_posix_backend) {
        var path_z: [MAX_PATH:0]u8 = undefined;
        if (root.len >= MAX_PATH) return;
        @memcpy(path_z[0..root.len], root);
        path_z[root.len] = 0;
        if (builtin.os.tag == .linux) {
            var stx: linux.Statx = undefined;
            const rc = linux.statx(AT_FDCWD, path_z[0..root.len :0], 0, .{ .INO = true }, &stx);
            if (linux.errno(rc) != .SUCCESS) return;
            const dev = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor);
            _ = sh.visitedBefore(.{ .dev = dev, .ino = stx.ino });
        } else {
            var st: std.c.Stat = undefined;
            if (std.c.fstatat(AT_FDCWD, path_z[0..root.len :0], &st, 0) != 0) return;
            _ = sh.visitedBefore(.{
                .dev = @bitCast(@as(i64, @intCast(st.dev))),
                .ino = @intCast(st.ino),
            });
        }
    } else {
        const stat = std.Io.Dir.cwd().statFile(sh.io, root, .{ .follow_symlinks = true }) catch return;
        _ = sh.visitedBefore(.{ .dev = 0, .ino = @intCast(stat.inode) });
    }
}

const StatLite = struct { is_dir: bool, key: InodeKey };

fn statEntry(sh: *Shared, handle: Handle, name: []const u8, follow: bool) ?StatLite {
    if (is_windows_backend) {
        // Symlink following is not implemented for the ntdll backend yet:
        // reparse-point targets are never descended into.
        return null;
    } else if (builtin.os.tag == .linux) {
        var name_z: [256:0]u8 = undefined;
        if (name.len >= 256) return null;
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;
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
        var name_z: [256:0]u8 = undefined;
        if (name.len >= 256) return null;
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
            // std.Io stat doesn't expose the device id; same-inode dirs on
            // different devices can be falsely deduped under follow mode.
            .key = .{ .dev = 0, .ino = @intCast(stat.inode) },
        };
    }
}

// ---------------------------------------------------------------------------
// .gitignore loading
// ---------------------------------------------------------------------------

/// Reads and parses `<dir>/.gitignore`, chaining it to the task's node.
/// Returns null (and stays on the parent chain) on any read/parse problem.
fn loadIgnoreNode(sh: *Shared, handle: Handle, task: *DirTask) WalkError!?*IgnoreNode {
    const content = readSmallFile(sh, handle, ".gitignore") orelse return null;
    // parseOwned owns `content` on all paths, including errors.
    var gi = GitIgnore.parseOwned(sh.gpa, content) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };

    const node = sh.gpa.create(IgnoreNode) catch |err| {
        gi.deinit();
        return err;
    };
    if (task.ignore) |parent| parent.retain();
    node.* = .{
        .parent = task.ignore,
        .gi = gi,
        .rel_off = @intCast(if (task.rel.len > 0) task.rel.len + 1 else 0),
        .refs = .init(1),
    };
    return node;
}

const max_gitignore_size = 1024 * 1024;

/// Reads a file relative to an open directory handle. Returns null when the
/// file can't be read (caller treats it as absent).
fn readSmallFile(sh: *Shared, handle: Handle, name: [:0]const u8) ?[]u8 {
    if (is_posix_backend) {
        const fd = posix.openatZ(handle, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0) catch return null;
        defer closeFd(fd);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(sh.gpa);
        list.ensureTotalCapacity(sh.gpa, 8192) catch return null;
        while (true) {
            const spare = list.unusedCapacitySlice();
            if (spare.len == 0) {
                if (list.items.len >= max_gitignore_size) break;
                list.ensureUnusedCapacity(sh.gpa, list.items.len) catch return null;
                continue;
            }
            const n = posix.read(fd, spare) catch return null;
            if (n == 0) break;
            list.items.len += n;
        }
        return list.toOwnedSlice(sh.gpa) catch null;
    } else if (is_windows_backend) {
        return win.readSmallFileAt(sh.gpa, handle, name, max_gitignore_size);
    } else {
        return handle.readFileAlloc(sh.io, name, sh.gpa, .limited(max_gitignore_size)) catch null;
    }
}

// ---------------------------------------------------------------------------
// Platform scanners
// ---------------------------------------------------------------------------

inline fn appendScratch(sh: *Shared, w: *Worker, raw: RawEntry) error{OutOfMemory}!void {
    const name = raw.name;
    if (name.len == 0) return;
    if (name[0] == '.') {
        if (name.len == 1 or (name.len == 2 and name[1] == '.')) return;
        if (name.len == 10 and mem.eql(u8, name, ".gitignore")) w.saw_gitignore = true;
    }
    const off: u32 = @intCast(w.names.items.len);
    try w.names.appendSlice(sh.gpa, name);
    try w.entries.append(sh.gpa, .{
        .name_off = off,
        .name_len = @intCast(name.len),
        .kind = raw.kind,
        .meta = raw.meta,
    });
}

inline fn appendScratchNoMeta(sh: *Shared, w: *Worker, name: []const u8, kind: EntryKind) error{OutOfMemory}!void {
    if (name.len == 0) return;
    if (name[0] == '.') {
        if (name.len == 1 or (name.len == 2 and name[1] == '.')) return;
        if (name.len == 10 and mem.eql(u8, name, ".gitignore")) w.saw_gitignore = true;
    }
    const off: u32 = @intCast(w.names.items.len);
    try w.names.appendSlice(sh.gpa, name);
    try w.entries.append(sh.gpa, .{
        .name_off = off,
        .name_len = @intCast(name.len),
        .kind = kind,
        .meta = undefined,
    });
}

const ScanFailure = error{ OutOfMemory, ReadFailed, PermissionDenied };

fn scanDir(sh: *Shared, w: *Worker, handle: Handle) ScanFailure!void {
    // Comptime dispatch — dead backends are never analyzed (their Handle
    // types differ per platform).
    if (backend == .linux_getdents) {
        return scanLinux(sh, w, handle);
    } else if (backend == .darwin_bulk) {
        return scanDarwin(sh, w, handle);
    } else if (backend == .windows_ntdll) {
        return scanWindows(sh, w, handle);
    } else {
        return scanStdFs(sh, w, handle);
    }
}

fn scanWindows(sh: *Shared, w: *Worker, handle: winos.HANDLE) ScanFailure!void {
    if (comptime !win.supported) unreachable;
    var scanner = win.Scanner.init(handle, w.io_buf, sh.options.meta);
    while (true) {
        const raw = scanner.next() catch |err| switch (err) {
            error.PermissionDenied => return error.PermissionDenied,
            error.ReadFailed => return error.ReadFailed,
        };
        const entry = raw orelse return;
        try appendScratch(sh, w, entry);
    }
}

fn scanLinux(sh: *Shared, w: *Worker, fd: posix.fd_t) ScanFailure!void {
    if (builtin.os.tag != .linux) unreachable;
    const DT_UNKNOWN: u8 = 0;
    const DT_DIR: u8 = 4;
    const DT_REG: u8 = 8;
    const DT_LNK: u8 = 10;
    const S_IFMT: u32 = 0o170000;
    const want_stat = sh.options.meta.any();
    const only_inode = sh.options.meta.toInt() == (MetaMask{ .inode = true }).toInt();

    while (true) {
        const rc = linux.getdents64(fd, w.io_buf.ptr, w.io_buf.len);
        const n: isize = @bitCast(rc);
        if (n < 0) {
            return switch (linux.errno(rc)) {
                .ACCES => error.PermissionDenied,
                else => error.ReadFailed,
            };
        }
        if (n == 0) return;
        const len: usize = @intCast(n);

        var off: usize = 0;
        while (off + 19 <= len) {
            const base = off;
            const d_ino = mem.readInt(u64, w.io_buf[base..][0..8], .little);
            const reclen = mem.readInt(u16, w.io_buf[base + 16 ..][0..2], .little);
            const d_type = w.io_buf[base + 18];
            // A zero reclen would loop forever; only a malformed (FUSE)
            // filesystem can produce one.
            if (reclen == 0) return error.ReadFailed;
            off += reclen;

            const name_ptr: [*:0]const u8 = @ptrCast(w.io_buf.ptr + base + 19);
            const name = mem.sliceTo(name_ptr, 0);
            if (name.len == 0) continue;
            if (name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) continue;

            var kind: EntryKind = switch (d_type) {
                DT_REG => .file,
                DT_DIR => .directory,
                DT_LNK => .sym_link,
                DT_UNKNOWN => .unknown,
                else => .unknown,
            };

            var meta = Metadata{};
            if (want_stat or d_type == DT_UNKNOWN) {
                if (only_inode and d_type != DT_UNKNOWN) {
                    // Inode comes free with the dirent — no stat needed.
                    meta.inode = d_ino;
                    meta.valid.inode = true;
                } else {
                    var stx: linux.Statx = undefined;
                    var mask = sh.statx_mask;
                    if (d_type == DT_UNKNOWN) mask.TYPE = true;
                    const src = linux.statx(fd, name_ptr, linux.AT.SYMLINK_NOFOLLOW, mask, &stx);
                    if (linux.errno(src) == .SUCCESS) {
                        fillMetaFromStatx(&meta, &stx, sh.options.meta);
                        if (d_type == DT_UNKNOWN and stx.mask.TYPE) {
                            kind = switch (@as(u32, stx.mode) & S_IFMT) {
                                0o040000 => .directory,
                                0o100000 => .file,
                                0o120000 => .sym_link,
                                else => .unknown,
                            };
                        }
                    }
                }
            }

            try appendScratch(sh, w, .{ .name = name, .kind = kind, .meta = meta });
        }
    }
}

fn fillMetaFromStatx(meta: *Metadata, stx: *const linux.Statx, want: MetaMask) void {
    if (builtin.os.tag != .linux) unreachable;
    if (want.size and stx.mask.SIZE) {
        meta.size = stx.size;
        meta.valid.size = true;
    }
    if (want.mtime and stx.mask.MTIME) {
        meta.mtime_ns = stx.mtime.sec *% std.time.ns_per_s +% stx.mtime.nsec;
        meta.valid.mtime = true;
    }
    if (want.atime and stx.mask.ATIME) {
        meta.atime_ns = stx.atime.sec *% std.time.ns_per_s +% stx.atime.nsec;
        meta.valid.atime = true;
    }
    if (want.ctime and stx.mask.CTIME) {
        meta.ctime_ns = stx.ctime.sec *% std.time.ns_per_s +% stx.ctime.nsec;
        meta.valid.ctime = true;
    }
    if (want.btime and stx.mask.BTIME) {
        meta.btime_ns = stx.btime.sec *% std.time.ns_per_s +% stx.btime.nsec;
        meta.valid.btime = true;
    }
    if (want.inode and stx.mask.INO) {
        meta.inode = stx.ino;
        meta.valid.inode = true;
    }
    if (want.nlink and stx.mask.NLINK) {
        meta.nlink = stx.nlink;
        meta.valid.nlink = true;
    }
    if (want.mode and stx.mask.MODE) {
        meta.mode = @as(u32, stx.mode) & 0o7777;
        meta.valid.mode = true;
    }
    if (want.uid and stx.mask.UID) {
        meta.uid = stx.uid;
        meta.valid.uid = true;
    }
    if (want.gid and stx.mask.GID) {
        meta.gid = stx.gid;
        meta.valid.gid = true;
    }
}

fn linuxStatxMask(want: MetaMask) if (builtin.os.tag == .linux) linux.STATX else void {
    if (builtin.os.tag != .linux) return {};
    return .{
        .SIZE = want.size,
        .MTIME = want.mtime,
        .ATIME = want.atime,
        .CTIME = want.ctime,
        .BTIME = want.btime,
        .INO = want.inode,
        .NLINK = want.nlink,
        .MODE = want.mode,
        .UID = want.uid,
        .GID = want.gid,
    };
}

fn scanDarwin(sh: *Shared, w: *Worker, fd: posix.fd_t) ScanFailure!void {
    if (comptime !darwin.supported) unreachable;
    // No-metadata walks (the common case) only need names + kind. There,
    // getattrlistbulk is pure overhead: it makes the kernel assemble and copy
    // attribute records we never read, measuring ~25% slower per directory
    // than a plain getdirentries-backed readdir on APFS. d_type already
    // carries the kind, so route straight to the readdir scanner and never
    // pay for the bulk attribute machinery.
    if (!sh.options.meta.any()) {
        return scanDarwinNoMeta(sh, w, fd);
    }
    var scanner = darwin.BulkScanner.init(fd, w.io_buf, sh.options.meta);
    while (true) {
        const raw = scanner.next() catch |err| switch (err) {
            error.Unsupported => return scanPosixFallback(sh, w, fd),
            error.PermissionDenied => return error.PermissionDenied,
            error.ReadFailed => return error.ReadFailed,
        };
        const entry = raw orelse return;
        try appendScratch(sh, w, entry);
    }
}

/// Lean readdir-based scanner for no-metadata macOS walks. d_type carries
/// the kind directly, so there is no per-entry stat on filesystems that
/// populate it (APFS, HFS+); DT_UNKNOWN is resolved with a single fstatat
/// only for the rare filesystem that withholds the type. This is ~2.5x
/// faster per directory than getattrlistbulk, which would otherwise spend
/// the syscall assembling attribute records the caller never reads.
fn scanDarwinNoMeta(sh: *Shared, w: *Worker, fd: posix.fd_t) ScanFailure!void {
    if (comptime !darwin.supported) unreachable;
    var it = darwin.DirEntries.init(fd, w.io_buf);
    while (it.next() catch return error.ReadFailed) |entry| {
        var kind = entry.kind;
        // Only filesystems that don't fill d_type force a stat here; misreading
        // a directory as a file would silently drop a whole subtree.
        if (kind == .unknown) {
            var name_z: [1024:0]u8 = undefined;
            if (entry.name.len < 1024) {
                @memcpy(name_z[0..entry.name.len], entry.name);
                name_z[entry.name.len] = 0;
                var st: std.c.Stat = undefined;
                if (std.c.fstatat(fd, name_z[0..entry.name.len :0], &st, std.c.AT.SYMLINK_NOFOLLOW) == 0) {
                    kind = switch (@as(u32, @intCast(st.mode)) & 0o170000) {
                        0o040000 => .directory,
                        0o100000 => .file,
                        0o120000 => .sym_link,
                        else => .unknown,
                    };
                }
            }
        }
        try appendScratchNoMeta(sh, w, entry.name, kind);
    }
}

/// readdir+fstatat fallback for filesystems without getattrlistbulk support.
fn scanPosixFallback(sh: *Shared, w: *Worker, fd: posix.fd_t) ScanFailure!void {
    if (comptime !(is_posix_backend and builtin.os.tag != .linux)) unreachable;
    // fdopendir takes ownership of the fd; iterate on a dup so the caller's
    // fd stays valid for openat() of children.
    const dup_fd = std.c.dup(fd);
    if (dup_fd < 0) return error.ReadFailed;
    const dir = std.c.fdopendir(dup_fd) orelse {
        closeFd(dup_fd);
        return error.ReadFailed;
    };
    defer _ = std.c.closedir(dir);

    const want_stat = sh.options.meta.any();
    while (std.c.readdir(dir)) |entry| {
        const namlen: usize = @intCast(entry.namlen);
        const name: []const u8 = @as([*]const u8, @ptrCast(&entry.name))[0..namlen];
        if (name.len == 0) continue;
        if (name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) continue;

        var kind: EntryKind = switch (entry.type) {
            std.c.DT.REG => .file,
            std.c.DT.DIR => .directory,
            std.c.DT.LNK => .sym_link,
            else => .unknown,
        };

        var meta = Metadata{};
        if (want_stat or kind == .unknown) {
            var name_z: [1024:0]u8 = undefined;
            if (name.len < 1024) {
                @memcpy(name_z[0..name.len], name);
                name_z[name.len] = 0;
                var st: std.c.Stat = undefined;
                if (std.c.fstatat(fd, name_z[0..name.len :0], &st, std.c.AT.SYMLINK_NOFOLLOW) == 0) {
                    fillMetaFromCStat(&meta, &st, sh.options.meta);
                    if (kind == .unknown) {
                        kind = switch (@as(u32, @intCast(st.mode)) & 0o170000) {
                            0o040000 => .directory,
                            0o100000 => .file,
                            0o120000 => .sym_link,
                            else => .unknown,
                        };
                    }
                }
            }
        }
        try appendScratch(sh, w, .{ .name = name, .kind = kind, .meta = meta });
    }
}

fn fillMetaFromCStat(meta: *Metadata, st: *const std.c.Stat, want: MetaMask) void {
    if (want.size) {
        meta.size = @intCast(@max(st.size, 0));
        meta.valid.size = true;
    }
    if (want.inode) {
        meta.inode = @intCast(st.ino);
        meta.valid.inode = true;
    }
    if (want.nlink) {
        meta.nlink = @intCast(st.nlink);
        meta.valid.nlink = true;
    }
    if (want.mode) {
        meta.mode = @as(u32, @intCast(st.mode)) & 0o7777;
        meta.valid.mode = true;
    }
    if (want.uid) {
        meta.uid = st.uid;
        meta.valid.uid = true;
    }
    if (want.gid) {
        meta.gid = st.gid;
        meta.valid.gid = true;
    }
    if (want.mtime) {
        const ts = st.mtime();
        meta.mtime_ns = @as(i64, ts.sec) *% std.time.ns_per_s +% ts.nsec;
        meta.valid.mtime = true;
    }
    if (want.atime) {
        const ts = st.atime();
        meta.atime_ns = @as(i64, ts.sec) *% std.time.ns_per_s +% ts.nsec;
        meta.valid.atime = true;
    }
    if (want.ctime) {
        const ts = st.ctime();
        meta.ctime_ns = @as(i64, ts.sec) *% std.time.ns_per_s +% ts.nsec;
        meta.valid.ctime = true;
    }
    if (want.btime and @hasDecl(std.c.Stat, "birthtime")) {
        const ts = st.birthtime();
        meta.btime_ns = @as(i64, ts.sec) *% std.time.ns_per_s +% ts.nsec;
        meta.valid.btime = true;
    }
}

fn scanStdFs(sh: *Shared, w: *Worker, handle: Handle) ScanFailure!void {
    if (comptime is_posix_backend) unreachable;
    var reader_buffer: [4096]u8 align(@alignOf(usize)) = undefined;
    var batch: [64]std.Io.Dir.Entry = undefined;
    var reader: std.Io.Dir.Reader = .{
        .dir = handle,
        .state = .reset,
        .index = 0,
        .end = 0,
        .buffer = &reader_buffer,
    };
    const want_stat = sh.options.meta.any();

    while (true) {
        const n = reader.read(sh.io, &batch) catch return error.ReadFailed;
        if (n == 0) return;
        for (batch[0..n]) |entry| {
            const name = entry.name;
            if (name.len == 0) continue;
            if (name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) continue;

            var meta = Metadata{};
            if (want_stat) {
                if (handle.statFile(sh.io, name, .{ .follow_symlinks = false })) |st| {
                    fillMetaFromIoStat(&meta, &st, sh.options.meta);
                } else |_| {}
            }
            try appendScratch(sh, w, .{ .name = name, .kind = entry.kind, .meta = meta });
        }
    }
}

fn fillMetaFromIoStat(meta: *Metadata, st: *const std.Io.File.Stat, want: MetaMask) void {
    if (want.size) {
        meta.size = st.size;
        meta.valid.size = true;
    }
    if (want.inode) {
        meta.inode = @intCast(st.inode);
        meta.valid.inode = true;
    }
    if (want.nlink) {
        meta.nlink = @intCast(st.nlink);
        meta.valid.nlink = true;
    }
    if (want.mtime) {
        meta.mtime_ns = @intCast(st.mtime.nanoseconds);
        meta.valid.mtime = true;
    }
    if (want.ctime) {
        meta.ctime_ns = @intCast(st.ctime.nanoseconds);
        meta.valid.ctime = true;
    }
    if (want.atime) {
        if (st.atime) |at| {
            meta.atime_ns = @intCast(at.nanoseconds);
            meta.valid.atime = true;
        }
    }
}

// ---------------------------------------------------------------------------
// Walk driver
// ---------------------------------------------------------------------------

pub const RunError = error{ Aborted, OutOfMemory };

fn effectiveThreads(opts: *const Options) u32 {
    if (opts.threads != 0) return @min(opts.threads, 1024);
    const n = std.Thread.getCpuCount() catch 1;
    // Directory enumeration is syscall-bound and contends on per-process and
    // per-mount kernel locks (the fd table, vnode/namecache locks). Past a
    // low count more workers only fight over those locks: measured on macOS,
    // throughput peaks around 4 threads and *regresses below single-threaded*
    // beyond ~8 on large trees (getdirentries64/openat serialize in the
    // kernel). Linux scales further before the dcache lock bites, so it keeps
    // a higher cap. Callers who know their workload can override with `threads`.
    const cap: u32 = if (backend == .darwin_bulk) 4 else 16;
    return @intCast(@min(@max(n, 1), cap));
}

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Internal driver shared by run() and collect().
fn walkInternal(
    gpa: Allocator,
    root: []const u8,
    options: Options,
    sink: SinkFn,
    sink_ctx: *anyopaque,
    n_workers: u32,
) RunError!void {
    // Root prefix: "root/" (or "" for an empty root meaning cwd-relative
    // output, or "root" already ending with '/').
    var prefix_buf: [MAX_PATH]u8 = undefined;
    var prefix_len: usize = 0;
    if (root.len > 0) {
        if (root.len >= MAX_PATH - 1) {
            // The root doesn't fit the path-assembly buffer. Report it like
            // any other directory error rather than pretending the user
            // aborted; the walk is then empty.
            if (options.err_callback) |cb| {
                var path_z: [MAX_PATH:0]u8 = undefined;
                @memcpy(path_z[0 .. MAX_PATH - 1], root[0 .. MAX_PATH - 1]);
                path_z[MAX_PATH - 1] = 0;
                if (cb(&path_z, errnoFromOpenError(error.NameTooLong)) != 0)
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

    // Compile the glob filter once; matching is lock-free on the workers.
    var compiled: ?CompiledPattern = null;
    if (options.pattern) |p| {
        compiled = compiled_pattern.compilePattern(gpa, p, options.pattern_flags) catch
            return error.OutOfMemory;
    }
    defer if (compiled) |*c| c.deinit();

    var sh = Shared{
        .gpa = gpa,
        .io = options.io orelse defaultIo(),
        .options = options,
        .root_path = root,
        .root_path_with_slash = prefix_buf[0..prefix_len],
        .root_prefix_len = @intCast(prefix_len),
        .sink = sink,
        .sink_ctx = sink_ctx,
        .pattern = if (compiled) |*c| c else null,
        .pattern_prefix = if (options.pattern) |p|
            literalPatternPrefixDirs(p, options.pattern_flags)
        else
            &.{},
        .statx_mask = linuxStatxMask(options.meta),
    };
    try sh.queue.init(gpa, n_workers);
    defer {
        sh.queue.deinit(gpa);
        sh.visited.deinit(gpa);
    }

    if (options.follow_symlinks) recordRootVisited(&sh);

    // All allocations that can fail happen before the root task is queued so
    // an early error can't leak in-flight tasks.
    const workers = try gpa.alloc(Worker, n_workers);
    defer gpa.free(workers);
    var inited: usize = 0;
    defer for (workers[0..inited]) |*w| w.deinit();
    for (workers, 0..) |*w, i| {
        try w.init(@intCast(i), &sh);
        inited += 1;
    }

    const threads: []std.Thread = if (n_workers > 1)
        try gpa.alloc(std.Thread, n_workers - 1)
    else
        &.{};
    defer if (threads.len > 0) gpa.free(threads);

    // Hand the worker/thread slices to Shared so the calling thread can spawn
    // helpers lazily once it discovers parallel work.
    sh.workers = workers;
    sh.threads = threads;

    // Root task.
    const root_task = try gpa.create(DirTask);
    root_task.* = .{
        .rel = try gpa.dupe(u8, ""),
        .depth = 0,
        .ignore = null,
        .parent = null,
    };
    sh.queue.push(gpa, sh.io, 0, root_task) catch |err| {
        freeTask(&sh, root_task);
        return err;
    };

    // Worker 0 is the calling thread; it spawns the rest on demand (see
    // workerLoop) so shallow trees never create a single helper thread.
    workerLoop(&sh, &workers[0]);
    for (sh.threads[0..sh.spawned]) |t| t.join();

    switch (@as(Failure, @enumFromInt(sh.failure.load(.acquire)))) {
        .none => {},
        .aborted => return error.Aborted,
        .oom => return error.OutOfMemory,
    }
}

/// Streaming parallel walk: the visitor is called for every entry, from
/// multiple threads when `options.threads != 1`. Entry slices are only valid
/// during the callback.
pub fn run(gpa: Allocator, root: []const u8, options: Options, visitor: Visitor) RunError!void {
    const Adapter = struct {
        fn sink(ctx: *anyopaque, worker_id: u32, entry: *const Entry) VisitAction {
            _ = worker_id;
            const v: *const Visitor = @ptrCast(@alignCast(ctx));
            return v.visit(v.context, entry);
        }
    };
    var v = visitor;
    return walkInternal(gpa, root, options, Adapter.sink, @ptrCast(&v), effectiveThreads(&options));
}

// ---------------------------------------------------------------------------
// collect(): one-call materialization (lock-free per-worker accumulation)
// ---------------------------------------------------------------------------

const CHUNK_SIZE = 256 * 1024;

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

/// Owned walk results. Paths are NUL-terminated in storage (entry.path.len
/// excludes the NUL) — handy for C consumers.
pub const Results = struct {
    entries: []Entry,
    chunks: [][]u8,
    gpa: Allocator,

    pub fn deinit(self: *Results) void {
        for (self.chunks) |c| self.gpa.free(c);
        self.gpa.free(self.chunks);
        self.gpa.free(self.entries);
        self.* = undefined;
    }
};

const Collector = struct {
    sinks: []WorkerSink,
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

/// Walks and returns all entries. Faster than run() for "give me everything"
/// consumers: workers accumulate into private buffers with zero locking and
/// results are merged once at the end.
pub fn collect(gpa: Allocator, root: []const u8, options: Options) RunError!Results {
    const n_workers = effectiveThreads(&options);

    var col = Collector{ .sinks = try gpa.alloc(WorkerSink, n_workers) };
    for (col.sinks) |*ws| ws.* = .{ .gpa = gpa };
    defer {
        for (col.sinks) |*ws| ws.deinit();
        gpa.free(col.sinks);
    }

    try walkInternal(gpa, root, options, collectSink, @ptrCast(&col), n_workers);

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
        // Ownership of chunk storage moved to Results.
        ws.chunks.clearRetainingCapacity();
    }

    if (options.sort) {
        std.sort.pdq(Entry, entries, {}, entryLessThan);
    }

    return .{ .entries = entries, .chunks = chunks, .gpa = gpa };
}
