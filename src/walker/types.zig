//! Shared types for the parallel walker: backend selection, the per-platform
//! directory handle, and the public entry/options structs.

const std = @import("std");
const builtin = @import("builtin");
const darwin = @import("scan_darwin.zig");
const win = @import("scan_windows.zig");

const winos = std.os.windows;
const posix = std.posix;
const linux = std.os.linux;

pub const MAX_PATH = switch (builtin.os.tag) {
    .macos => 1024,
    else => 4096, // keep 4096 for windows cause it's unclear if we should use 260 or 32768
};

pub const NAME_MAX: usize = switch (builtin.os.tag) {
    .linux => linux.NAME_MAX,
    .windows, .macos => 255,
    else => if (@hasDecl(std.c, "NAME_MAX")) std.c.NAME_MAX else 255,
};

pub const NAME_BUF_Z_LENGTH = NAME_MAX + 1;

/// zlob's single error set, shared with the glob API (see `flags.zig`). The
/// glob side only yields `OutOfMemory`/`Aborted`; the directory scanners add
/// `ReadFailed`/`PermissionDenied`, normally reported per-directory and
/// swallowed unless `abort_on_error` upgrades them.
pub const WalkError = @import("../zlob.zig").ZlobError;

pub const ZlobFlags = @import("../zlob.zig").ZlobFlags;
pub const EntryKind = std.Io.File.Kind;
pub const ErrCallbackFn = *const fn (epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int;

pub const Backend = enum { linux_getdents, darwin_bulk, windows_ntdll, std_fs };

pub const backend: Backend = if (builtin.os.tag == .linux)
    .linux_getdents
else if (darwin.supported)
    .darwin_bulk
else if (win.supported)
    .windows_ntdll
else
    .std_fs;

pub const is_posix_backend = backend == .linux_getdents or backend == .darwin_bulk;
pub const is_windows_backend = backend == .windows_ntdll;

/// Per-platform open directory handle: a raw fd on POSIX, an NT handle on
/// Windows, a `std.Io.Dir` on the portable fallback.
pub const Handle = if (is_posix_backend)
    posix.fd_t
else if (is_windows_backend)
    winos.HANDLE
else
    std.Io.Dir;

pub const AT_FDCWD: posix.fd_t = switch (builtin.os.tag) {
    .linux => linux.AT.FDCWD,
    .windows => undefined, // POSIX-only; the Windows backend uses NT handles
    else => std.c.AT.FDCWD,
};

pub inline fn closeFd(fd: posix.fd_t) void {
    switch (builtin.os.tag) {
        .linux => _ = linux.close(fd),
        .windows => {}, // POSIX-only; the Windows backend closes NT handles
        else => _ = std.c.close(fd),
    }
}

pub inline fn closeHandle(h: Handle, io: std.Io) void {
    if (is_posix_backend) {
        closeFd(h);
    } else if (is_windows_backend) {
        winos.CloseHandle(h);
    } else {
        var d = h;
        d.close(io);
    }
}

/// Which metadata attributes to fetch per entry. An empty mask means the
/// walker never stats anything; entry kind still comes free from the listing.
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

/// Per-entry metadata. Only fields whose bit is set in `valid` are meaningful;
/// a requested attribute can still be invalid when the filesystem lacks it
/// (e.g. btime on ext3). Semantics are lstat-like: symlinks are never followed.
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

/// A reported filesystem entry. Slices and the `meta` pointer are valid only
/// for the duration of the `run` visitor callback; `collect` returns owned
/// copies (paths in `WalkerResult.chunks`, metadata in `WalkerResult.metas`).
///
/// Kept small on purpose (40 bytes): every reported entry moves through the
/// per-worker sink, the final gather and the optional sort, so the 72-byte
/// `Metadata` lives out of line and is only materialized when requested.
pub const Entry = struct {
    /// Full path: walk root joined with the relative path. NUL-terminated at
    /// `path.len` for zero-cost C interop.
    path: []const u8,
    /// Per-entry metadata, or null when `Options.meta` is empty.
    meta: ?*const Metadata,
    /// Offset into `path` where the root-relative part starts.
    relative_offset: u32,
    /// Offset into `path` where the basename starts (see `basename`).
    basename_offset: u32,
    /// Depth below the root: direct children of the root have depth 1.
    depth: u16,
    /// Index of the current worker id
    worker_id: u16 = 0,
    kind: EntryKind,

    pub inline fn relativePath(self: *const Entry) []const u8 {
        return self.path[self.relative_offset..];
    }

    /// Basename (slice into `path`).
    pub inline fn basename(self: *const Entry) []const u8 {
        return self.path[self.basename_offset..];
    }
};

/// Entry produced by platform scanners before path assembly/filtering.
/// `name` points into a scanner-owned buffer, valid until the next scan call.
pub const RawEntry = struct {
    name: []const u8,
    kind: EntryKind,
    meta: Metadata,
    /// Inode number as reported by the parent's directory listing (Linux
    /// `d_ino`), 0 when unknown. Only consumed under `follow_symlinks`, where
    /// it keys the cycle set without a statx per real directory.
    ino: u64 = 0,
};

pub const VisitAction = enum(c_int) {
    cont = 0,
    /// Don't descend into this directory (no effect on files).
    skip_dir = 1,
    /// Stop the whole walk as soon as possible.
    stop = 2,
};

/// Visitor for `run`
/// When `threads != 1` it is invoked concurrently from multiple worker threads and has to be thread-safe
pub const Visitor = struct {
    context: ?*anyopaque = null,
    visit: *const fn (context: ?*anyopaque, entry: *const Entry) VisitAction,
};

pub const TrustShortGetdents = enum(u8) { auto, never };

pub const Options = struct {
    /// Worker thread count. 0 = one per CPU (capped). 1 = caller thread only.
    threads: u16 = 0,
    /// Stack size in bytes for each helper worker thread. 0 = 1 MiB
    /// (`thread.DEFAULT_STACK_SIZE`). Small stacks let glibc's stack cache
    /// reuse them across walks instead of mmap/munmap-ing 16 MiB per thread
    /// per walk. The walker itself needs very little stack; raise this only
    /// when a `Visitor`/sink callback running on worker threads needs more.
    /// Values below 512 KiB are clamped up (glibc refuses them).
    thread_stack_size: usize = 0,
    /// Maximum entry depth to yield/descend (root children = 1). 0 = unlimited.
    max_depth: u16 = 0,
    /// Descend into symlinked directories (cycles are detected and broken).
    /// Not supported by the Windows ntdll backend.
    follow_symlinks: bool = false,
    /// Report entries whose name starts with '.'. Hidden directories are not
    /// descended into when false.
    include_hidden: bool = true,
    /// Honor .gitignore files (nested ones included). `.ignore` files are
    /// honored too, with their patterns taking precedence over `.gitignore`.
    respect_git: bool = true,
    /// Skip ".git" directories (only when respect_git is set).
    skip_git_dir: bool = true,
    /// Report directory entries (directories are traversed either way).
    report_dirs: bool = true,
    /// Glob filter: only entries whose root-relative path matches are reported
    /// (e.g. "**/*.rs", "src/**", "*.{c,h}"). Traversal is narrowed too:
    /// directories outside the pattern's literal prefix are pruned unopened.
    pattern: ?[]const u8 = null,
    /// Flags for compiling/matching `pattern`. Default: brace + recursive `**`.
    pattern_flags: ZlobFlags = .{ .brace = true, .doublestar_recursive = true },
    /// Extra ignore document layered into the walker, `.gitignore` syntax,
    /// one rule per line. Callers building from Rust use
    /// `WalkBuilder::extra_ignore(&["a", "b"])` which joins for them; direct
    /// Zig callers should pass a buffer like "a\nb\n". Compiled once into a
    /// single GitIgnore matcher and checked *deepest* in the chain so
    /// `!negation` rules override the project's `.gitignore`. Matches
    /// surface via the returned [`crate::walk::IgnoreRules`].
    extra_ignore: ?[]const u8 = null,
    meta: MetaMask = .{},
    /// Sort collected results by path (`collect` only).
    sort: bool = false,
    /// Linux: skip the EOF-confirming getdents64 call per directory when the
    /// root's filesystem is known to fill buffers greedily (ext4, btrfs, xfs,
    /// tmpfs, f2fs) and no other filesystem is mounted below it. `.never`
    /// always issues the extra call. Env `ZLOB_TRUST_SHORT_GETDENTS=0` also
    /// disables it process-wide (libc builds).
    trust_short_getdents: TrustShortGetdents = .auto,
    err_callback: ?ErrCallbackFn = null,
    abort_on_error: bool = false,
    /// Io used for queue synchronization and by the std_fs fallback backend.
    /// Defaults to a blocking single-threaded Io safe to share across workers.
    io: ?std.Io = null,
};
