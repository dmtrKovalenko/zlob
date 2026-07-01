const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const queue_mod = @import("queue.zig");
const scan = @import("scan.zig");
const win = @import("scan_windows.zig");
const gitignore_mod = @import("../gitignore.zig");
const compiled_pattern = @import("../compiled_pattern.zig");
const pattern_context = @import("../pattern_context.zig");
const ignore_rules = @import("ignore_rules.zig");

pub const IgnoreRules = ignore_rules.IgnoreRules;

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
const closeFd = types.closeFd;
const closeHandle = types.closeHandle;

const GitIgnore = gitignore_mod.GitIgnore;
const CompiledPattern = compiled_pattern.CompiledPattern;
const Queue = queue_mod.Queue;
const DirTask = queue_mod.DirTask;

pub const WalkError = types.WalkError;
pub const SinkFn = *const fn (ctx: *anyopaque, worker_id: u32, entry: *const Entry) VisitAction;

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
    /// Offset into the root-relative path where paths relative to this node's
    /// directory start.
    relative_offset: u32,
    refs: std.atomic.Value(u32),

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
    pattern: ?*const CompiledPattern = null,
    /// Literal directory prefix of the pattern, used to prune traversal
    /// outside the pattern's scope ("src/lib" for "src/lib/**/*.c").
    pattern_prefix: []const u8 = &.{},
    /// Synthetic gitignore from `Options.extra_ignore`. Sits at the deepest
    /// position in every chain so its `!negation` rules win over the
    /// project's discovered `.gitignore` files (the same precedence a nested
    /// `.gitignore` would give a deeper directory).
    extra_ignore_root: ?*IgnoreNode = null,
    /// Linux only: the per-entry `statx()` mask, precomputed once from
    /// `options.meta` so the hot scan loop doesn't rebuild it per entry. Other
    /// backends also fetch only the requested attributes, but build that
    /// request elsewhere — macOS bakes it into the per-directory
    /// `BulkScanner` AttrList, Windows into its info-class selection — so no
    /// shared field is needed there.
    statx_mask: if (builtin.os.tag == .linux) linux.STATX else void,
    /// Symlink-cycle bookkeeping, only touched when follow_symlinks is set.
    visited_mutex: std.Io.Mutex = .init,
    visited: std.AutoHashMapUnmanaged(InodeKey, void) = .empty,
    /// Reusable ignore rules. Workers register each parsed `.gitignore`/ `.ignore`
    ignore_rules: *IgnoreRules,
    retain_mutex: std.Io.Mutex = .init,
    /// Lazy worker spawning: helper threads are created only once the walk has
    /// demonstrably parallel work, so shallow trees never pay the spawn cost.
    workers: []Worker = &.{},
    threads: []std.Thread = &.{},
    spawn_started: std.atomic.Value(bool) = .init(false),
    spawned: usize = 0,

    pub fn fail(sh: *SharedWorkerState, f: Failure) void {
        sh.abort_signal.store(true, .release);
        _ = sh.failure.cmpxchgStrong(@intFromEnum(Failure.none), @intFromEnum(f), .acq_rel, .acquire);
    }

    pub fn failureResult(sh: *SharedWorkerState) WalkError!void {
        return switch (@as(Failure, @enumFromInt(sh.failure.load(.acquire)))) {
            .none => {},
            .aborted => error.Aborted,
            .oom => error.OutOfMemory,
            .read_failed => error.ReadFailed,
            .permission_denied => error.PermissionDenied,
            .name_too_long => error.NameTooLong,
        };
    }

    /// Spawn the helper worker threads on first call (idempotent). Called by
    /// the calling thread once it sees enough queued work to justify the cost.
    fn ensureWorkers(sh: *SharedWorkerState) void {
        if (sh.threads.len == 0) return;
        if (sh.spawn_started.swap(true, .acq_rel)) return;

        for (sh.threads, 1..) |*t, i| {
            t.* = std.Thread.spawn(.{}, workerLoop, .{ sh, &sh.workers[i] }) catch break;
            sh.spawned += 1;
        }

        // A worker may have parked between its empty-queue check and now; wake
        // freshly spawned threads so none miss the work that triggered spawn.
        sh.queue.wakeAll(sh.io);
    }

    fn visitedBefore(sh: *SharedWorkerState, key: InodeKey) bool {
        sh.visited_mutex.lockUncancelable(sh.io);
        defer sh.visited_mutex.unlock(sh.io);
        const gop = sh.visited.getOrPut(sh.allocator, key) catch return true;
        return gop.found_existing;
    }
};

pub const Scratch = struct {
    name_off: u32,
    name_len: u32,
    kind: EntryKind,
    meta: Metadata,
};

pub const Worker = struct {
    id: u32,
    sh: *SharedWorkerState,
    /// Full-path assembly buffer; [0..root_prefix_len) holds "root/".
    path_buf: [MAX_PATH + 1]u8 = undefined,
    /// Per-directory name bytes (reset per task, capacity retained).
    names: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Scratch) = .empty,
    saw_gitignore: bool = false,
    saw_ignore: bool = false,
    /// Kernel buffer for getdents64 / getattrlistbulk.
    io_buf: []align(8) u8 = &.{},

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
        @memcpy(w.path_buf[0..sh.root_prefix_len], sh.root_path_with_slash);
    }

    pub fn deinit(w: *Worker) void {
        const allocator = w.sh.allocator;

        w.names.deinit(allocator);
        w.entries.deinit(allocator);
        if (w.io_buf.len > 0) allocator.free(w.io_buf);
    }
};

pub fn freeTask(sh: *SharedWorkerState, t: *DirTask) void {
    if (t.parent) |p| p.release(sh);
    if (t.ignore) |ig| ig.release(sh.allocator);
    sh.allocator.free(t.rel);
    sh.allocator.destroy(t);
}

pub fn workerLoop(state: *SharedWorkerState, worker: *Worker) void {
    // Lazy spawning is driven only by worker 0 (the calling thread): once it
    // has uncovered more than a couple of pending directories there is enough
    // fan-out to amortize the helper-thread cost. Helper workers (id != 0)
    // never run this, and worker 0 stops checking once it has spawned them, so
    // the steady-state loop carries no spawn bookkeeping.
    const spawn_threshold = 2;
    var may_spawn = worker.id == 0;

    while (state.queue.pop(state.io, worker.id)) |task| {
        if (!state.abort_signal.load(.acquire)) {
            processDir(state, worker, task) catch |err| switch (err) {
                error.OutOfMemory => state.fail(.oom),
                error.ReadFailed => state.fail(.read_failed),
                error.PermissionDenied => state.fail(.permission_denied),
                error.NameTooLong => state.fail(.name_too_long),
                error.Aborted => state.fail(.aborted),
            };

            if (may_spawn and state.queue.queued.load(.monotonic) > spawn_threshold) {
                state.ensureWorkers();
                may_spawn = false; // spawned once; never check again
            }
        }
        freeTask(state, task);
        state.queue.taskDone(state.io);
    }
}

fn processDir(sh: *SharedWorkerState, w: *Worker, task: *DirTask) WalkError!void {
    const handle = (try openTaskDir(sh, w, task)) orelse return;
    var handle_consumed = false;
    defer if (!handle_consumed) closeHandle(handle, sh.io);

    w.names.clearRetainingCapacity();
    w.entries.clearRetainingCapacity();
    w.saw_gitignore = false;
    w.saw_ignore = false;
    scan.scanDir(sh, w, handle) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            @branchHint(.cold);
            const prefix = taskPrefixLen(sh, w, task);
            try reportError(sh, w.path_buf[0..prefix -| 1], err);
            return;
        },
    };

    var ignore: ?*IgnoreNode = task.ignore;
    var own_ignore = false;
    if (sh.options.respect_git and (w.saw_gitignore or w.saw_ignore)) {
        @branchHint(.unlikely);
        if (try loadIgnoreNode(sh, handle, task, w.saw_gitignore, w.saw_ignore)) |node| {
            ignore = node;
            own_ignore = true;
            {
                sh.retain_mutex.lockUncancelable(sh.io);
                defer sh.retain_mutex.unlock(sh.io);
                sh.ignore_rules.put(task.rel, node) catch return error.OutOfMemory;
            }
        }
    }
    defer if (own_ignore) ignore.?.release(sh.allocator);

    const prefix_len = taskPrefixLen(sh, w, task);
    const opts = &sh.options;
    const entry_depth: u16 = task.depth +| 1;
    const may_descend = opts.max_depth == 0 or entry_depth < opts.max_depth;
    const want_meta = opts.meta.any();
    var child_ref: ?*HandleRef = null;
    defer if (child_ref) |cr| cr.release(sh);

    for (w.entries.items) |se| {
        const name = w.names.items[se.name_off..][0..se.name_len];
        try processEntry(sh, w, handle, name, se.kind, if (want_meta) se.meta else .{}, ignore, prefix_len, entry_depth, may_descend, &child_ref, &handle_consumed);
    }
}

fn processEntry(
    sh: *SharedWorkerState,
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
    if (sh.abort_signal.load(.monotonic) or name.len == 0) {
        @branchHint(.unlikely);
        return;
    }
    if (!opts.include_hidden and name[0] == '.') return;

    var is_dir = entry_kind == .directory;
    if (opts.respect_git and opts.skip_git_dir and is_dir and
        mem.eql(u8, name, ".git"))
    {
        @branchHint(.unlikely);
        return;
    }

    if (prefix_len + name.len >= MAX_PATH) {
        @branchHint(.cold);
        return;
    }
    @memcpy(w.path_buf[prefix_len..][0..name.len], name);
    w.path_buf[prefix_len + name.len] = 0;
    const full = w.path_buf[0 .. prefix_len + name.len];
    const basename = full[prefix_len..];
    const relative_path = full[sh.root_prefix_len..];

    // extra_ignore + project .gitignore chain in one pass. `extra_ignore` is
    // checked first (deepest) so its `!negation` rules win against the
    // project's discovered .gitignore files — same precedence a nested
    // .gitignore would give a deeper directory.
    if (chainIgnored(cur_ignore, sh.extra_ignore_root, relative_path, basename, is_dir)) return;

    if (!is_dir and opts.follow_symlinks and entry_kind == .sym_link) {
        is_dir = isSymlinkedDir(sh, handle, name);
    } else if (is_dir and opts.follow_symlinks) {
        if (statForSymlink(sh, handle, name, false)) |res| {
            if (sh.visitedBefore(res.key)) return;
        }
    }

    var action: VisitAction = .cont;
    var report = entry_kind != .directory or opts.report_dirs;
    if (report) {
        if (sh.pattern) |cp| report = cp.matches(relative_path, opts.pattern_flags);
    }
    if (report) {
        var entry = Entry{
            .path = full,
            .relative_offset = sh.root_prefix_len,
            .basename = basename,
            .kind = entry_kind,
            .depth = entry_depth,
            .meta = meta,
        };
        action = sh.sink(sh.sink_ctx, w.id, &entry);
        if (action == .stop) {
            @branchHint(.cold);
            sh.abort_signal.store(true, .release);
            return;
        }
    }

    if (is_dir and sh.pattern != null and !dirInPatternScope(sh.pattern_prefix, relative_path))
        return;

    if (is_dir and may_descend and action != .skip_dir) {
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
        const child = try sh.allocator.create(DirTask);
        errdefer sh.allocator.destroy(child);

        cr.retain();
        errdefer cr.release(sh);
        if (cur_ignore) |ig| ig.retain();
        errdefer if (cur_ignore) |ig| ig.release(sh.allocator);

        child.* = .{
            .rel = child_rel,
            .depth = entry_depth,
            .ignore = cur_ignore,
            .parent = cr,
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
            break :blk openChild(sh, p.handle, basenameOf(task.rel));
        }
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

fn openChild(sh: *SharedWorkerState, parent: Handle, name: []const u8) anyerror!Handle {
    if (is_posix_backend) {
        var name_z: [NAME_BUF:0]u8 = undefined;
        if (name.len > NAME_MAX) return error.NameTooLong;
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

fn openRoot(sh: *SharedWorkerState, root: []const u8) anyerror!Handle {
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

/// Deepest-first resolution across nested .gitignore files: the first decisive
/// answer wins, mirroring git. Pruning is exact: once a directory is ignored
/// nothing inside it can be re-included, so it is never descended.
///
/// `extra` is the caller-supplied synthetic .gitignore, layered as the
/// *innermost* layer (checked even before `start`'s deepest node) so its
/// `!negation` rules can un-ignore paths the real chain would otherwise drop.
/// Anchoring is at the walk root: rules see the entry's full root-relative
/// path. Pass `null` to skip.
fn chainIgnored(start: ?*IgnoreNode, extra: ?*IgnoreNode, rel: []const u8, basename: []const u8, is_dir: bool) bool {
    if (extra) |x| {
        // extra_ignore is rooted at the walk root (relative_offset = 0), so
        // we pass the entry's full root-relative path verbatim.
        if (x.gi.checkWithBasename(rel, basename, is_dir)) |verdict| {
            return verdict;
        }
    }
    var node: ?*IgnoreNode = start;
    while (node) |n| : (node = n.parent) {
        if (n.gi.checkWithBasename(rel[n.relative_offset..], basename, is_dir)) |verdict| {
            return verdict;
        }
    }
    return false;
}

fn loadIgnoreNode(
    sh: *SharedWorkerState,
    handle: Handle,
    task: *DirTask,
    have_git: bool,
    have_ignore: bool,
) WalkError!?*IgnoreNode {
    const content = (try readIgnore(sh, handle, have_git, have_ignore)) orelse return null;
    var gi = GitIgnore.parseOwned(sh.allocator, content) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };

    const node = sh.allocator.create(IgnoreNode) catch |err| {
        gi.deinit();
        return err;
    };
    if (task.ignore) |parent| parent.retain();
    node.* = .{
        .parent = task.ignore,
        .gi = gi,
        .relative_offset = @intCast(if (task.rel.len > 0) task.rel.len + 1 else 0),
        .refs = .init(1),
    };
    return node;
}
/// Reads `.gitignore` and/or `.ignore` and returns one owned buffer holding
/// their concatenation (gitignore first, then ignore). The caller's parser
/// takes ownership. `.ignore` is placed last so its patterns win ties
/// (ripgrep convention). Returns null when neither file could be read.
fn readIgnore(sh: *SharedWorkerState, handle: Handle, have_git: bool, have_ignore: bool) WalkError!?[]u8 {
    const git = if (have_git) readSmallFile(sh, handle, ".gitignore") else null;
    const ign = if (have_ignore) readSmallFile(sh, handle, ".ignore") else null;

    // Only one source present: hand its buffer straight to the parser (no copy).
    if (ign == null) return git;
    if (git == null) return ign;

    // Both present: concatenate with a separating newline so the last line of
    // .gitignore and the first line of .ignore don't fuse.
    const g = git.?;
    const i = ign.?;
    defer sh.allocator.free(g);
    defer sh.allocator.free(i);
    const merged = sh.allocator.alloc(u8, g.len + 1 + i.len) catch return error.OutOfMemory;
    @memcpy(merged[0..g.len], g);
    merged[g.len] = '\n';
    @memcpy(merged[g.len + 1 ..], i);
    return merged;
}

const max_gitignore_size = 1024 * 1024;

fn readSmallFile(sh: *SharedWorkerState, handle: Handle, name: [:0]const u8) ?[]u8 {
    if (is_posix_backend) {
        const fd = posix.openatZ(handle, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0) catch return null;
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
        return win.readSmallFileAt(sh.allocator, handle, name, max_gitignore_size);
    } else {
        return handle.readFileAlloc(sh.io, name, sh.allocator, .limited(max_gitignore_size)) catch null;
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

// ---------------------------------------------------------------------------
// Symlinking
// ---------------------------------------------------------------------------

const SymlinkStat = struct { is_dir: bool, key: InodeKey };

/// stat(FOLLOW) on a directory entry; true when it resolves to a directory not yet visited
fn isSymlinkedDir(sh: *SharedWorkerState, handle: Handle, name: []const u8) bool {
    if (statForSymlink(sh, handle, name, true)) |res| {
        if (!res.is_dir) return false;
        return !sh.visitedBefore(res.key);
    }
    return false;
}

pub fn recordRootVisited(sh: *SharedWorkerState) void {
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
            _ = sh.visitedBefore(.{ .dev = dev, .ino = stx.ino });
        } else {
            var st: std.c.Stat = undefined;
            if (std.c.fstatat(types.AT_FDCWD, path_z[0..root.len :0], &st, 0) != 0) return;
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

    return @intFromEnum(e);
}
