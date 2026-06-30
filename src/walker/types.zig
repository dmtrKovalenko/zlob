//! Shared types for the parallel walker: backend selection, the per-platform
//! directory handle, and the public entry/options structs.

const std = @import("std");
const builtin = @import("builtin");
const darwin = @import("scan_darwin.zig");
const win = @import("scan_windows.zig");

const winos = std.os.windows;
const posix = std.posix;
const linux = std.os.linux;

/// Size of the worker's full-path assembly buffer. This is deliberately
/// generous rather than the kernel `PATH_MAX`: the walker opens each directory
/// with `openat`/NT-relative on the *basename* against the parent handle, so a
/// reported path may legitimately be longer than the OS `PATH_MAX` even though
/// every individual open succeeded. Entries whose assembled path would exceed
/// this are skipped (the buffer can't hold them for reporting).
pub const MAX_PATH = 4096;

/// Longest single path component the OS will accept (`NAME_MAX`), used to size
/// the per-component NUL-terminated buffers passed to `openat`/`fstatat`.
/// Components beyond this are rejected with `error.NameTooLong`.
///
/// Note Windows' 255 is the per-component limit (NTFS/ReFS/exFAT, in UTF-16
/// code units) and is unchanged in Windows 11 — the long-path support added in
/// recent Windows only raised the *total path* limit, which here is bounded by
/// `MAX_PATH` (the reporting buffer), not by a single component.
pub const NAME_MAX: usize = switch (builtin.os.tag) {
    .linux => linux.NAME_MAX,
    .windows => 255,
    else => if (@hasDecl(std.c, "NAME_MAX")) std.c.NAME_MAX else 255,
};

/// Per-component scratch buffer length: `NAME_MAX` plus the trailing NUL.
pub const NAME_BUF = NAME_MAX + 1;

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

pub const AT_FDCWD: posix.fd_t = if (builtin.os.tag == .linux) linux.AT.FDCWD else std.c.AT.FDCWD;

pub inline fn closeFd(fd: posix.fd_t) void {
    if (builtin.os.tag == .linux) {
        _ = linux.close(fd);
    } else {
        _ = std.c.close(fd);
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

/// A reported filesystem entry. Slices are valid only for the duration of the
/// `run` visitor callback; `collect` returns owned copies.
pub const Entry = struct {
    /// Full path: walk root joined with the relative path. NUL-terminated at
    /// `path.len` for zero-cost C interop.
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

/// Entry produced by platform scanners before path assembly/filtering.
/// `name` points into a scanner-owned buffer, valid until the next scan call.
pub const RawEntry = struct {
    name: []const u8,
    kind: EntryKind,
    meta: Metadata,
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

pub const Options = struct {
    /// Worker thread count. 0 = one per CPU (capped). 1 = caller thread only.
    threads: u16 = 0,
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
    meta: MetaMask = .{},
    /// Sort collected results by path (`collect` only).
    sort: bool = false,
    err_callback: ?ErrCallbackFn = null,
    abort_on_error: bool = false,
    /// Io used for queue synchronization and by the std_fs fallback backend.
    /// Defaults to a blocking single-threaded Io safe to share across workers.
    io: ?std.Io = null,
};
