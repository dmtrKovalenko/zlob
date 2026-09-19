const std = @import("std");
const builtin = @import("builtin");
const dirent64 = @import("dirent");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// POSIX errno values used for cross-platform error reporting through the
/// `ErrCallbackFn` interface. Values are the standard POSIX integers and
/// match `std.posix.E` on POSIX targets.
const errno = struct {
    const ACCES: c_int = 13;
    const NOENT: c_int = 2;
    const NOTDIR: c_int = 20;
    const LOOP: c_int = 40;
    const NAMETOOLONG: c_int = 36;
    const NOMEM: c_int = 12;
    const MFILE: c_int = 24;
    const NFILE: c_int = 23;
    const INVAL: c_int = 22;
    const IO: c_int = 5;
};

pub const ErrCallbackFn = *const fn (epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int;

pub const DirFilter = struct {
    /// Return true to descend into this directory, false to prune it.
    /// relative_path: path relative to start directory
    /// basename: just the directory name
    filterDirFn: *const fn (ctx: *anyopaque, relative_path: []const u8, basename: []const u8) bool,

    /// Context pointer passed to filterDirFn
    context: *anyopaque,

    /// Check if should descend into directory
    pub inline fn filterDir(self: DirFilter, relative_path: []const u8, basename: []const u8) bool {
        return self.filterDirFn(self.context, relative_path, basename);
    }
};

pub const Backend = enum {
    getdents64,
    std_fs,
};

pub const default_backend: Backend = switch (builtin.os.tag) {
    .linux => .getdents64,
    else => .std_fs,
};

pub const EntryKind = std.Io.File.Kind;

pub const Entry = struct {
    /// Path relative to the starting directory
    path: []const u8,
    /// Just the filename component
    basename: []const u8,
    /// Entry type
    kind: EntryKind,
};

/// Configuration for filtering hidden files and special entries.
/// This is designed to implement POSIX glob semantics efficiently at the walker level.
pub const HiddenConfig = struct {
    /// Include "." and ".." entries in iteration.
    /// POSIX: patterns starting with '.' should match these (e.g., ".*" matches "." and "..")
    /// Default: false (skip them like most iterators do)
    include_dot_entries: bool = false,

    /// Include hidden files (files starting with '.', excluding "." and "..").
    /// POSIX: hidden files only match if pattern starts with '.' OR GLOB_PERIOD is set.
    /// Default: false (skip hidden files)
    include_hidden: bool = false,

    /// POSIX default: skip "." and ".." and hidden files
    pub const posix_default: HiddenConfig = .{
        .include_dot_entries = false,
        .include_hidden = false,
    };

    /// Include all entries (for ZLOB_PERIOD flag or patterns starting with '.')
    pub const include_all: HiddenConfig = .{
        .include_dot_entries = true,
        .include_hidden = true,
    };

    /// Include hidden files but not "." and ".." (for ZLOB_PERIOD without dot pattern)
    pub const hidden_only: HiddenConfig = .{
        .include_dot_entries = false,
        .include_hidden = true,
    };

    /// Compute HiddenConfig from pattern characteristics and flags.
    /// This implements POSIX glob semantics:
    /// - ".*" should match ".", "..", and hidden files
    /// - "*" should NOT match ".", "..", or hidden files (unless PERIOD flag)
    /// - ".foo" should match ".foo" (literal) and hidden files starting with ".foo"
    pub fn fromPatternAndFlags(pattern_starts_with_dot: bool, is_dot_or_dotdot: bool, period_flag: bool) HiddenConfig {
        // If ZLOB_PERIOD is set, allow all hidden files
        if (period_flag) {
            return HiddenConfig.hidden_only;
        }

        // If pattern is exactly "." or "..", include dot entries
        if (is_dot_or_dotdot) {
            return .{
                .include_dot_entries = true,
                .include_hidden = false,
            };
        }

        // If pattern starts with '.', include dot entries and hidden files
        // POSIX: ".*" matches ".", "..", and hidden files
        if (pattern_starts_with_dot) {
            return HiddenConfig.include_all;
        }

        // Default: skip ".", "..", and hidden files
        return HiddenConfig.posix_default;
    }
};

pub const TrustShortGetdents = enum(u8) { auto, never };

/// Per-glob-call memo of the short-read verdict, shared by every
/// DirIterator the call opens. The first opened directory (the walk's start
/// directory) is probed; later ones reuse the answer, but only while they
/// stay on the start directory's device: the non-recursive glob paths open
/// wildcard-matched components by path with a plain openat, which follows
/// symlinks, so a matched link into another filesystem (FUSE, NFS, ...)
/// must not inherit the verdict.
pub const TrustCache = struct {
    state: enum(u8) { unknown, yes, no } = .unknown,
    /// st_dev of the probed start directory; valid when `state == .yes`.
    dev: u64 = 0,
};

pub const WalkerConfig = struct {
    /// Buffer size for getdents64 (Linux only). 64 KiB holds all but the
    /// largest directories in one call, which with `trust_short_getdents`
    /// makes them single-syscall.
    getdents_buffer_size: usize = 65536,

    /// Linux: treat a short getdents64 return as EOF when the start
    /// directory's filesystem fills greedily (see dirent.trustShortReaddir),
    /// saving the confirming call per directory.
    trust_short_getdents: TrustShortGetdents = .auto,

    // left for convenience should not be used for getdents64
    max_depth: usize = 128,

    /// Hidden file and special entry filtering.
    /// Controls whether ".", "..", and hidden files are included in iteration.
    hidden: HiddenConfig = HiddenConfig.posix_default,

    /// Directory filter interface for pruning directories during traversal.
    /// When set, filterDir is called for each directory before descending.
    /// Return false from filterDir to prune (skip directory and all contents).
    dir_filter: ?DirFilter = null,

    /// Base directory to start from. If null, path is opened relative to cwd.
    base_dir: ?std.Io.Dir = null,

    /// Error callback for directory open failures.
    /// Called with null-terminated path and errno when a directory cannot be opened.
    /// Return non-zero to abort the walk, zero to continue.
    err_callback: ?ErrCallbackFn = null,

    /// Abort on first error (equivalent to ZLOB_ERR flag).
    /// If true and a directory cannot be opened, the walk aborts.
    abort_on_error: bool = false,

    /// Follow directory symlinks during recursion.
    follow_symlinks: bool = false,

    /// Filesystem provider for ALTDIRFUNC support.
    /// When set with valid callbacks, uses custom directory functions instead of real filesystem.
    fs: AltFs = AltFs.real_fs,

    /// Emit entries in strcmp order of their relative paths (getdents64
    /// backend only; see `supports_sorted`). Each directory is drained and
    /// its entries sorted before any is emitted; a subdirectory's contents are
    /// emitted at the position of `name ++ "/"` among its siblings, which is
    /// exactly where a global byte-wise sort of the full paths would put them.
    /// Costs one small L1-resident sort per directory instead of one global
    /// sort over every result.
    sorted: bool = false,

    /// With `sorted`: directory entries are keyed `name ++ "/"` instead of
    /// `name`, matching the paths a ZLOB_MARK caller will build from them.
    sort_marks_dirs: bool = false,
};

/// Identifies a filesystem object across remounts within a single walk.
/// Used to break symlink cycles when follow_symlinks is enabled.
pub const InodeKey = struct { dev: u64, ino: u64 };

const has_libc_for_stat = builtin.link_libc and (builtin.os.tag == .macos or
    builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or
    builtin.os.tag == .openbsd or builtin.os.tag == .dragonfly or
    builtin.os.tag == .linux);

// File-mode masks (POSIX) for stat.mode dir-check.
const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;

inline fn keyFromCStat(st: std.c.Stat) InodeKey {
    return .{
        .dev = @bitCast(@as(i64, @intCast(st.dev))),
        .ino = @intCast(st.ino),
    };
}

inline fn isDirMode(mode: anytype) bool {
    return (@as(u32, @intCast(mode)) & S_IFMT) == S_IFDIR;
}

// On Linux, std 0.16 dropped the `Stat`/`fstat`/`fstatat` wrappers; `statx`
// is the only raw stat syscall left. We only need (dev, ino) and the file
// type, so request just TYPE | INO.
const linux_statx_mask = if (builtin.os.tag == .linux)
    std.os.linux.STATX{ .TYPE = true, .INO = true }
else
    undefined;

inline fn keyFromStatx(stx: std.os.linux.Statx) InodeKey {
    // Recombine the split major/minor into a single device identifier. Any
    // injective combination works — this is only ever compared for equality
    // within one walk to break cycles.
    const dev = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor);
    return .{ .dev = dev, .ino = stx.ino };
}

/// Best-effort fstat on an open dir fd to obtain (dev, ino). Returns null
/// when libc is unavailable on the target or the stat call fails.
fn statFd(fd: std.posix.fd_t) ?InodeKey {
    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, linux_statx_mask, &stx);
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
        return keyFromStatx(stx);
    }
    if (!has_libc_for_stat) return null;
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return null;
    return keyFromCStat(st);
}

/// Resolved symlink target via stat(FOLLOW).
const ResolvedSym = struct { is_dir: bool, key: InodeKey };

/// Best-effort stat(FOLLOW) on a symlink. Used as a pre-flight before
/// openat() so we can skip non-dir targets and detected cycles without
/// paying for the open+close round-trip.
fn statAtFollow(dir_fd: std.posix.fd_t, name_z: [*:0]const u8) ?ResolvedSym {
    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        // flags = 0 → follow symlinks (no AT.SYMLINK_NOFOLLOW).
        const rc = std.os.linux.statx(dir_fd, name_z, 0, linux_statx_mask, &stx);
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
        return .{ .is_dir = isDirMode(stx.mode), .key = keyFromStatx(stx) };
    }

    if (!has_libc_for_stat) return null;
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(dir_fd, name_z, &st, 0) != 0) return null;
    return .{ .is_dir = isDirMode(st.mode), .key = keyFromCStat(st) };
}

/// Kind of a dirent whose d_type is DT_UNKNOWN, from one lstat. Unknown
/// stays unknown when the stat fails.
fn statKindNoFollow(dir_fd: std.posix.fd_t, name_z: [:0]const u8) EntryKind {
    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(dir_fd, name_z.ptr, std.os.linux.AT.SYMLINK_NOFOLLOW, std.os.linux.STATX{ .TYPE = true }, &stx);
        if (std.os.linux.errno(rc) != .SUCCESS) return .unknown;
        return switch (stx.mode & std.os.linux.S.IFMT) {
            std.os.linux.S.IFDIR => .directory,
            std.os.linux.S.IFLNK => .sym_link,
            else => .file,
        };
    }
    return .unknown;
}

/// Length of the NUL-terminated name in a dirent record. Shared with the
/// parallel walker's scanner; see `walker/dirent.zig` for the SWAR scan and its
/// 8-byte over-read contract.
const direntNameLen = dirent64.nameLen;

inline fn shouldSkipEntry(name: []const u8, hidden: HiddenConfig) bool {
    if (name.len == 0) return true;

    const first_byte = name[0];
    if (first_byte != '.') return false; // Fast path: non-hidden files always pass

    // Entry starts with '.' - check if it's "." or ".."
    const is_dot = name.len == 1;
    const is_dotdot = name.len == 2 and name[1] == '.';

    if (is_dot or is_dotdot) {
        // "." and ".." entries
        return !hidden.include_dot_entries;
    }

    // Other hidden files (e.g., ".gitignore", ".hidden")
    return !hidden.include_hidden;
}

pub fn WalkerType(comptime backend: Backend) type {
    return switch (backend) {
        .getdents64 => if (builtin.os.tag == .linux)
            RecursiveGetdents64Walker
        else
            @compileError("getdents64 backend is Linux-only"),
        .std_fs => StdFsWalker,
    };
}

pub const DefaultWalker = WalkerType(default_backend);

pub fn isOptimizedBackendAvailable() bool {
    return builtin.os.tag == .linux;
}

/// Linux only: directory opens ask for O_NOATIME so getdents64 never dirties
/// directory inodes. On relatime mounts the first walk after 24h otherwise
/// rewrites every directory's atime inline in getdents64 (btrfs: transaction
/// join + delayed inode update, ~2-3us per directory) and queues a metadata
/// writeback per directory. O_NOATIME is refused with EPERM when the caller
/// neither owns the directory nor has CAP_FOWNER, and EPERM is the only way a
/// read-only directory open can fail *because of* the flag, so the first
/// refusal retries once without it and clears `ok` for the rest of the
/// process (SingleDirIterator has no walk scope to hang the probe on): a
/// foreign tree costs one extra open, not one per directory.
/// Inode number of every btrfs subvolume root as seen from inside it (its
/// entry in the parent listing carries the subvolume id instead). See
/// `RecursiveGetdents64Walker.confirmFreshDir`.
const BTRFS_FIRST_FREE_OBJECTID: u64 = 256;

const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };
const RESOLVE_NO_XDEV: u64 = 0x01;
const RESOLVE_NO_SYMLINKS: u64 = 0x04;

/// openat2(RESOLVE_NO_XDEV): like openat, but fails with EXDEV instead of
/// crossing a mount point, so a child keyed by its parent's device number is
/// known to still be on that device when the open succeeds.
fn rawOpenat2NoXdev(dirfd: std.posix.fd_t, name_z: [*:0]const u8, flags: std.posix.O) usize {
    if (comptime builtin.os.tag != .linux) unreachable;
    var how: OpenHow = .{ .flags = @as(u32, @bitCast(flags)), .mode = 0, .resolve = RESOLVE_NO_XDEV };
    return std.os.linux.syscall4(.openat2, @bitCast(@as(isize, dirfd)), @intFromPtr(name_z), @intFromPtr(&how), @sizeOf(OpenHow));
}

const Openat2Result = union(enum) { opened: std.posix.fd_t, xdev, unavailable, other };

const noatime = if (builtin.os.tag != .linux) struct {} else struct {
    const linux = std.os.linux;
    const posix = std.posix;

    var ok: std.atomic.Value(bool) = .init(true);

    /// `openat2NoXdev` under the same O_NOATIME policy. EPERM is ambiguous
    /// here: O_NOATIME refused on a foreign directory, or openat2 itself
    /// filtered by seccomp. With the flag set, a first EPERM retries once
    /// without it; only an EPERM without the flag (or ENOSYS) reports
    /// openat2 as unavailable.
    fn openat2NoXdev(dir_fd: posix.fd_t, path_z: [*:0]const u8, base_flags: posix.O) Openat2Result {
        var flags = base_flags;
        var want = ok.load(.monotonic);
        flags.NOATIME = want;
        while (true) {
            const rc = rawOpenat2NoXdev(dir_fd, path_z, flags);
            switch (linux.errno(rc)) {
                .SUCCESS => return .{ .opened = @intCast(rc) },
                .XDEV => return .xdev,
                .NOSYS => return .unavailable,
                .PERM => {
                    if (!want) return .unavailable;
                    ok.store(false, .monotonic);
                    want = false;
                    flags.NOATIME = false;
                },
                else => return .other,
            }
        }
    }

    /// Set once openat2 is seen to be unusable (ENOSYS, seccomp EPERM, ...):
    /// callers then go straight to `openat`.
    var no_openat2 = std.atomic.Value(bool).init(false);

    /// Raw `openat2(RESOLVE_NO_SYMLINKS)` with the same O_NOATIME policy as
    /// `openat`. Returns the syscall result (success or an ordinary open
    /// error, mapped by the caller exactly as `openat`'s would be), or null
    /// when the caller must fall back to a plain `openat`: a symlink in the
    /// path (ELOOP), or openat2 unusable on this system.
    fn openat2NoSymlinks(dir_fd: i32, path_z: [*:0]const u8, base_flags: linux.O) ?usize {
        if (no_openat2.load(.monotonic)) return null;
        var flags = base_flags;
        var want = ok.load(.monotonic);
        flags.NOATIME = want;
        while (true) {
            var how: OpenHow = .{ .flags = @as(u32, @bitCast(flags)), .mode = 0, .resolve = RESOLVE_NO_SYMLINKS };
            const rc = linux.syscall4(.openat2, @bitCast(@as(isize, dir_fd)), @intFromPtr(path_z), @intFromPtr(&how), @sizeOf(OpenHow));
            switch (linux.errno(rc)) {
                .LOOP => return null,
                .NOSYS, .INVAL, .@"2BIG" => {
                    no_openat2.store(true, .monotonic);
                    return null;
                },
                .PERM => {
                    // O_NOATIME refused, or openat2 filtered by seccomp:
                    // retry without the flag once, then give up on openat2.
                    if (!want) {
                        no_openat2.store(true, .monotonic);
                        return null;
                    }
                    ok.store(false, .monotonic);
                    want = false;
                    flags.NOATIME = false;
                },
                else => return rc,
            }
        }
    }

    /// Raw `openat` returning the syscall result, so callers keep their own
    /// errno mapping.
    fn openat(dir_fd: i32, path_z: [*:0]const u8, base_flags: linux.O) usize {
        var flags = base_flags;
        const want = ok.load(.monotonic);
        flags.NOATIME = want;
        const rc = linux.openat(dir_fd, path_z, flags, 0);
        if (want and linux.errno(rc) == .PERM) {
            ok.store(false, .monotonic);
            flags.NOATIME = false;
            return linux.openat(dir_fd, path_z, flags, 0);
        }
        return rc;
    }

    fn openatZ(dir_fd: posix.fd_t, path_z: [*:0]const u8, base_flags: posix.O) posix.OpenError!posix.fd_t {
        var flags = base_flags;
        const want = ok.load(.monotonic);
        flags.NOATIME = want;
        return posix.openatZ(dir_fd, path_z, flags, 0) catch |err| {
            if (!want or err != error.PermissionDenied) return err;
            ok.store(false, .monotonic);
            flags.NOATIME = false;
            return posix.openatZ(dir_fd, path_z, flags, 0);
        };
    }
};

// Uses getdents64 syscall but only for recursive walking.
// Linux-only: the entire body assumes `std.posix` / `std.os.linux` are available.
const RecursiveGetdents64Walker = if (builtin.os.tag != .linux) struct {} else struct {
    const posix = std.posix;
    const linux = std.os.linux;

    const DT_DIR: u8 = 4;
    const DT_REG: u8 = 8;
    const DT_LNK: u8 = 10;

    allocator: Allocator,
    config: WalkerConfig,

    // Stack of directories to process (LIFO order) — dynamically grown on heap.
    // Initial capacity 64, which covers most real-world directory trees without
    // reallocation. Grows as needed for pathological cases (huge flat dirs).
    dir_stack: std.ArrayList(DirEntry),

    // Saved paths of the directories on dir_stack, since siblings overwrite
    // path_buffer before we pop. dir_stack is strict LIFO, so the popped entry
    // always owns this buffer's tail and releasing it is a shrink.
    path_stack: std.ArrayList(u8),

    // Cycle-detection set for follow_symlinks. Populated lazily — only when
    // a symlink-to-dir is descended into. Empty (and free) when follow_symlinks
    // is disabled.
    visited: std.AutoHashMapUnmanaged(InodeKey, void),

    // Current directory being processed
    current_fd: posix.fd_t,
    current_depth: u16,
    // follow_symlinks cycle key of the current directory: `current_dev` is
    // inherited down the tree from the start dir's fstat (re-derived by one
    // statx when a mount point or btrfs subvolume is crossed), `current_ino`
    // is the parent listing's d_ino. Children are keyed as
    // (current_dev, d_ino) straight from the listing, so real directories
    // need no stat at all.
    current_dev: u64,
    current_ino: u64,
    // True until the first getdents64 batch of the current directory has been
    // read; that batch's "." record confirms the inherited key.
    fresh: bool,
    // The open could not guarantee it stayed on `current_dev` (mount
    // crossing, or no openat2): confirmFreshDir must fstat.
    current_verify: bool,
    // Set once openat2 fails with ENOSYS (pre-5.6 kernel, seccomp).
    openat2_unavailable: bool,

    // Buffer for getdents64 results
    getdents_buffer: []align(8) u8,
    getdents_offset: usize,
    getdents_len: usize,

    // Path tracking
    path_buffer: [4096]u8,
    path_len: usize,

    // Current entry (reused)
    current_entry: Entry,

    // State
    finished: bool,

    // A short getdents64 return proves EOF (greedy-fill filesystem under the
    // start dir), so the confirming call is skipped: `current_eof` marks the
    // buffer being drained as the directory's last.
    trust_short: bool,
    current_eof: bool,
    // Device of the start dir; a followed symlink onto another device drops
    // `trust_short` (that filesystem was never examined).
    root_dev: u64,

    // Sorted mode (config.sorted): per-level buffered listings. Levels are
    // strict LIFO, so each level's items and dirent bytes are a tail of these
    // arenas and popping a level is a shrink. Empty (and free) otherwise.
    // `sorted_dirents` receives raw getdents64 output (records are 8-byte
    // multiples, so record starts stay 8-aligned); items point at the
    // NUL-terminated names inside those records, so nothing is copied.
    sorted_items: std.ArrayList(SortedItem),
    sorted_dirents: std.ArrayListAligned(u8, .@"8"),
    levels: std.ArrayList(SortedLevel),

    pub const supports_sorted = true;

    const DirEntry = struct {
        fd: posix.fd_t,
        depth: u16,
        // Where this dir's path lives in path_stack.
        path_len: u16,
        path_off: u32,
        // Cycle key, see `current_dev` / `current_ino` / `current_verify`.
        dev: u64,
        ino: u64,
        verify_key: bool,
    };

    /// One buffered entry of a sorted listing. A directory (or, under
    /// follow_symlinks, a symlink) contributes two items: the entry itself,
    /// keyed `name`, and a descend marker keyed `name ++ "/"`. Names are the
    /// NUL-terminated d_name of the record in `sorted_dirents`, so the marker
    /// can openat them directly.
    const SortedItem = struct {
        /// First 8 bytes of the sort key (`name`, or `name ++ "/"` when
        /// `slash`), big-endian and zero-padded, so a single integer compare
        /// decides almost every sibling comparison. Equal prefixes fall back
        /// to the full byte-wise rule in sortedLess.
        key: u64,
        name_off: u32,
        name_len: u16,
        kind: EntryKind,
        /// Sort key is `name ++ "/"`: descend markers, and directory
        /// entries themselves when `sort_marks_dirs` is set.
        slash: bool,
        descend: bool,
    };

    const SortedLevel = struct {
        fd: posix.fd_t,
        depth: u16,
        /// path_len of the parent listing, restored when this level pops.
        parent_path_len: u16,
        items_off: u32,
        items_end: u32,
        cursor: u32,
        dirents_off: u32,
    };

    /// Bytes [i, i+8) of the virtual sort key `name ++ ("/" if slash)`, as a
    /// big-endian word, zero-padded past the key's end. Reads 8 raw bytes at
    /// `name + i` whenever i < name_len, which stays inside the dirent
    /// over-read contract shared with direntNameLen (the record holds the
    /// NUL and the chunk keeps 8 spare bytes).
    inline fn sortedKeyAt(name: [*]const u8, name_len: usize, slash: bool, i: usize) u64 {
        if (i >= name_len) {
            @branchHint(.unlikely);
            return if (slash and i == name_len) @as(u64, '/') << 56 else 0;
        }
        const raw = mem.readInt(u64, name[i..][0..8], .big);
        const remaining = name_len - i;
        if (remaining >= 8) return raw;
        const shift: u6 = @intCast(8 * (8 - remaining));
        const kept = raw & (~@as(u64, 0) << shift);
        if (!slash) return kept;
        return kept | (@as(u64, '/') << (shift - 8));
    }

    /// Byte-wise order of the items' keys (`name` or `name ++ "/"`), compared
    /// a word at a time, with an entry sorting before the descend marker of
    /// the same name so a directory is emitted before its contents.
    inline fn sortedLess(dirents: []const u8, a: SortedItem, b: SortedItem) bool {
        if (a.key != b.key) return a.key < b.key;
        const ap = dirents.ptr + a.name_off;
        const bp = dirents.ptr + b.name_off;
        const max_len: usize = @max(a.name_len, b.name_len);
        var i: usize = 8;
        while (i <= max_len) : (i += 8) {
            const ka = sortedKeyAt(ap, a.name_len, a.slash, i);
            const kb = sortedKeyAt(bp, b.name_len, b.slash, i);
            if (ka != kb) return ka < kb;
        }
        // Identical keys: same name, same slash. Entry before its contents.
        return !a.descend and b.descend;
    }

    /// Non-inline entry point for std.sort.pdq (large listings only).
    fn sortedLessFn(dirents: []const u8, a: SortedItem, b: SortedItem) bool {
        return sortedLess(dirents, a, b);
    }

    /// Hole-shifting insertion sort for the common small listing.
    fn insertionSortItems(items: []SortedItem, dirents: []const u8) void {
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            const x = items[i];
            var j = i;
            while (j > 0 and sortedLess(dirents, x, items[j - 1])) : (j -= 1) {
                items[j] = items[j - 1];
            }
            items[j] = x;
        }
    }

    pub fn init(allocator: Allocator, io: Io, start_path: []const u8, config: WalkerConfig) !RecursiveGetdents64Walker {
        _ = io; // Linux getdents64 backend uses raw syscalls; accepted for API parity with StdFsWalker.

        // Use smaller buffer for single-directory iteration (max_depth=0)
        // since we won't be recursing and don't need as much buffering.
        // Floored so the 8 bytes reserved for direntNameLen stay meaningful.
        const buffer_size = @max(if (config.max_depth == 0) 8192 else config.getdents_buffer_size, 512);
        const buffer = try allocator.alignedAlloc(u8, .@"8", buffer_size);
        errdefer allocator.free(buffer);

        const dir_stack = std.ArrayList(DirEntry).initCapacity(allocator, 16) catch
            std.ArrayList(DirEntry).empty;

        var path_z: [4096:0]u8 = undefined;
        if (start_path.len >= 4096) return error.NameTooLong;
        @memcpy(path_z[0..start_path.len], start_path);
        path_z[start_path.len] = 0;

        const dir_fd = if (config.base_dir) |bd| bd.handle else posix.AT.FDCWD;
        const start_fd = noatime.openatZ(dir_fd, &path_z, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }) catch |err| {
            try handleOpenError(start_path, err, config);
            return err;
        };

        var visited: std.AutoHashMapUnmanaged(InodeKey, void) = .empty;
        var root_key: InodeKey = .{ .dev = 0, .ino = 0 };
        if (config.follow_symlinks) {
            visited.ensureTotalCapacity(allocator, 256) catch {};
            // Seed with the start dir so a symlink pointing back to it is rejected.
            if (statFd(start_fd)) |key| {
                root_key = key;
                visited.put(allocator, key, {}) catch {};
            }
        }

        const trust_short = config.trust_short_getdents == .auto and dirent64.trustShortReaddir(start_fd);

        return RecursiveGetdents64Walker{
            .trust_short = trust_short,
            .current_eof = false,
            .root_dev = root_key.dev,
            .allocator = allocator,
            .config = config,
            .dir_stack = dir_stack,
            .path_stack = std.ArrayList(u8).empty,
            .visited = visited,
            .current_fd = start_fd,
            .current_depth = 0,
            .current_dev = root_key.dev,
            .current_ino = root_key.ino,
            .fresh = false,
            .current_verify = false,
            .openat2_unavailable = false,
            .getdents_buffer = buffer,
            .getdents_offset = 0,
            .getdents_len = 0,
            .path_buffer = undefined,
            .path_len = 0,
            .current_entry = undefined,
            .finished = false,
            .sorted_items = std.ArrayList(SortedItem).empty,
            .sorted_dirents = std.ArrayListAligned(u8, .@"8").empty,
            .levels = std.ArrayList(SortedLevel).empty,
        };
    }

    /// Handle directory open errors by calling err_callback and checking abort_on_error
    fn handleOpenError(path: []const u8, err: anyerror, config: WalkerConfig) !void {
        if (config.err_callback) |cb| {
            var path_z: [4096:0]u8 = undefined;
            const len = @min(path.len, 4095);
            @memcpy(path_z[0..len], path[0..len]);
            path_z[len] = 0;

            const err_code = zigErrorToPosix(err);
            if (cb(&path_z, err_code) != 0) {
                return error.Aborted;
            }
        }
        if (config.abort_on_error) {
            return error.Aborted;
        }
    }

    pub fn deinit(self: *RecursiveGetdents64Walker) void {
        // Close current fd if still open
        if (!self.finished and self.current_fd >= 0) {
            _ = linux.close(self.current_fd);
        }

        // Close any remaining stacked fds
        for (self.dir_stack.items) |entry| {
            _ = linux.close(entry.fd);
        }
        for (self.levels.items) |lvl| {
            _ = linux.close(lvl.fd);
        }

        self.dir_stack.deinit(self.allocator);
        self.path_stack.deinit(self.allocator);
        self.visited.deinit(self.allocator);
        self.sorted_items.deinit(self.allocator);
        self.sorted_dirents.deinit(self.allocator);
        self.levels.deinit(self.allocator);

        if (self.getdents_buffer.len > 0) {
            self.allocator.free(self.getdents_buffer);
        }
    }

    pub fn next(self: *RecursiveGetdents64Walker) !?Entry {
        if (self.finished) return null;
        if (self.config.sorted) return self.nextSorted();

        while (true) {
            // Process entries from current buffer
            while (self.getdents_offset < self.getdents_len) {
                if (self.parseNextEntry()) |entry| {
                    return entry;
                }
            }
            if (!self.refill()) return null;
        }
    }

    /// Drive the whole walk through `sink` without materialising an `Entry`
    /// per file. Non-directory entries are first offered by basename only,
    /// `sink.wantFile(name, kind)`, straight from the getdents buffer; only
    /// on a match is `sink.emitFile(dir_rel, name)` called, with the parent
    /// directory's path relative to the start dir (no trailing '/', empty at
    /// the root). Directories are descended into exactly as in `next()` but
    /// never reported. Errors from emitFile abort the walk.
    pub fn walkInto(self: *RecursiveGetdents64Walker, sink: anytype) !void {
        if (self.finished) return;
        if (self.config.sorted) return self.walkIntoSorted(sink);
        // Loop invariants, hoisted so the per-entry path reads no config.
        const hidden = self.config.hidden;
        const follow = self.config.follow_symlinks;

        while (true) {
            while (self.getdents_offset < self.getdents_len) {
                const raw = self.parseRaw() orelse continue;
                if (shouldSkipEntry(raw.name, hidden)) continue;

                var kind: EntryKind = switch (raw.d_type) {
                    DT_REG => .file,
                    DT_DIR => .directory,
                    DT_LNK => .sym_link,
                    else => .unknown,
                };

                if (kind == .directory or kind == .unknown or (follow and kind == .sym_link)) {
                    // Only descend candidates get their path assembled.
                    const path_start = self.path_len;
                    self.appendNameToPath(raw.name);
                    kind = self.maybeDescend(raw.name, kind, raw.d_ino);
                    self.path_len = path_start;
                    if (kind == .directory) continue;
                }

                if (!sink.wantFile(raw.name, kind)) continue;
                try sink.emitFile(self.path_buffer[0..self.path_len], raw.name);
            }
            if (!self.refill()) return;
        }
    }

    /// Read the next batch of dirents for the current directory, popping the
    /// next stacked directory when it is exhausted. Returns false once the
    /// walk is over.
    fn refill(self: *RecursiveGetdents64Walker) bool {
        while (true) {
            // buffer free - read more from current directory.
            // Short by 8: see direntNameLen. When the previous read already
            // proved EOF, skip the call that would only return 0.
            const cap = self.getdents_buffer.len - 8;
            const bytes_read: usize = if (self.current_eof)
                0
            else
                linux.getdents64(self.current_fd, self.getdents_buffer.ptr, cap);
            self.current_eof = false;

            if (@as(isize, @bitCast(bytes_read)) < 0 or bytes_read == 0) {
                // Current directory exhausted or error - close it and pop next from stack
                if (!self.popNextDir()) return false;
                continue;
            }

            self.getdents_len = bytes_read;
            self.getdents_offset = 0;

            if (self.fresh) {
                self.fresh = false;
                if (self.config.follow_symlinks and !self.confirmFreshDir()) {
                    // Already visited under its real (dev, ino): drop it unread.
                    if (!self.popNextDir()) return false;
                    continue;
                }
            }
            if (self.trust_short and dirent64.shortReadIsEof(bytes_read, cap)) self.current_eof = true;
            return true;
        }
    }

    /// Closes the current directory and makes the top of dir_stack current.
    /// Returns false (and marks the walk finished) when the stack is empty.
    fn popNextDir(self: *RecursiveGetdents64Walker) bool {
        _ = linux.close(self.current_fd);

        const next_dir = self.dir_stack.pop() orelse {
            self.finished = true;
            return false;
        };
        self.current_fd = next_dir.fd;
        self.current_depth = next_dir.depth;
        self.current_dev = next_dir.dev;
        self.current_ino = next_dir.ino;
        self.current_verify = next_dir.verify_key;
        self.fresh = true;
        self.path_len = next_dir.path_len;
        // Restore this dir's saved path, then release its bytes.
        @memcpy(
            self.path_buffer[0..next_dir.path_len],
            self.path_stack.items[next_dir.path_off..][0..next_dir.path_len],
        );
        self.path_stack.shrinkRetainingCapacity(next_dir.path_off);

        self.getdents_offset = 0;
        self.getdents_len = 0;
        return true;
    }

    /// follow_symlinks: the current directory was keyed by its parent's device
    /// and the parent listing's d_ino. Its own first record, ".", reports the
    /// inode as this directory's filesystem sees it; when the two agree the key
    /// is exact. They disagree across a btrfs subvolume boundary (listing:
    /// subvolume id, ".": 256) and a mount point (listing: covered inode; the
    /// EXDEV open path also sets `verify_key`), so those pay one fstat to
    /// learn the real (dev, ino). The directory's own key is already in
    /// `visited`, so only a *different* real key can mean it was visited
    /// before; then this returns false.
    fn confirmFreshDir(self: *RecursiveGetdents64Walker) bool {
        const buf = self.getdents_buffer[0..self.getdents_len];
        var dot_ino: u64 = 0;
        if (buf.len >= dirent64.NAME_OFFSET + 2) {
            const reclen = mem.readInt(u16, buf[dirent64.RECLEN_OFFSET..][0..2], .little);
            if (reclen >= dirent64.NAME_OFFSET + 2 and reclen <= buf.len and
                buf[dirent64.NAME_OFFSET] == '.' and buf[dirent64.NAME_OFFSET + 1] == 0)
            {
                dot_ino = mem.readInt(u64, buf[dirent64.INO_OFFSET..][0..8], .little);
            }
        }
        if (!self.current_verify and dot_ino != 0 and dot_ino == self.current_ino and dot_ino != BTRFS_FIRST_FREE_OBJECTID) {
            @branchHint(.likely);
            return true;
        }
        const key = statFd(self.current_fd) orelse return true;
        if (key.dev == self.current_dev and key.ino == self.current_ino) return true;
        // Off the start dir's device: that filesystem was never checked by
        // the short-read gate, so stop trusting short reads from here on.
        // This batch was read before the check, but its trust decision is
        // taken below, after this point.
        if (key.dev != self.root_dev) self.trust_short = false;
        const gop = self.visited.getOrPut(self.allocator, key) catch return true;
        if (gop.found_existing) return false;
        self.current_dev = key.dev;
        self.current_ino = key.ino;
        return true;
    }

    /// Sorted mode: emit the next entry in strcmp order of relative paths.
    /// The root listing is drained lazily on the first call; `current_fd`
    /// hands its fd over to level 0 and is -1 from then on.
    fn nextSorted(self: *RecursiveGetdents64Walker) !?Entry {
        try self.drainRootSorted(null);

        while (true) {
            const item = self.popSortedItem() orelse return null;
            const name_z = self.sortedName(item);
            const name: []const u8 = name_z;

            // Build path for this entry
            const path_start = self.path_len;
            if (self.path_len + 1 + name.len > self.path_buffer.len) {
                @branchHint(.unlikely);
                continue;
            }
            self.appendNameToPath(name);
            const name_in_path_start = self.path_len - name.len;
            const relative_path = self.path_buffer[0..self.path_len];

            if (!item.descend) {
                self.current_entry = .{
                    .path = relative_path,
                    .basename = self.path_buffer[name_in_path_start..][0..name.len],
                    .kind = item.kind,
                };
                // Reset path for next entry; the slices stay valid until then.
                self.path_len = path_start;
                return self.current_entry;
            }

            // Descend marker: the pushed level keeps path_len extended with
            // its own name until it pops.
            if (!self.descendSorted(item.parent_fd, name_z, item.kind, relative_path, item.depth, @intCast(path_start), null)) {
                self.path_len = path_start;
            }
        }
    }

    /// Sorted counterpart of `walkInto`: same sink contract, entries emitted
    /// in strcmp order of their relative paths. `sink.wantFile` runs inside
    /// `drainDir` on the raw dirent name, so rejected entries are never
    /// sorted, let alone given a path. Directories only contribute their
    /// descend marker (they are never reported), which keeps the per-level
    /// sort to the matching files plus the subdirectories.
    pub fn walkIntoSorted(self: *RecursiveGetdents64Walker, sink: anytype) !void {
        if (self.finished) return;
        try self.drainRootSorted(sink);

        while (true) {
            const item = self.popSortedItem() orelse return;
            const name_z = self.sortedName(item);

            if (!item.descend) {
                try sink.emitFile(self.path_buffer[0..self.path_len], name_z);
                continue;
            }

            const path_start = self.path_len;
            if (self.path_len + 1 + name_z.len > self.path_buffer.len) {
                @branchHint(.unlikely);
                continue;
            }
            self.appendNameToPath(name_z);
            if (!self.descendSorted(item.parent_fd, name_z, item.kind, self.path_buffer[0..self.path_len], item.depth, @intCast(path_start), sink)) {
                self.path_len = path_start;
            }
        }
    }

    /// Sorted mode: drain the start dir into level 0 on the first call.
    /// `current_fd` hands its fd over to that level and is -1 from then on.
    fn drainRootSorted(self: *RecursiveGetdents64Walker, sink: anytype) !void {
        if (self.current_fd < 0) return;
        const root_fd = self.current_fd;
        self.current_fd = -1;
        self.drainDir(root_fd, 0, sink) catch |err| {
            _ = linux.close(root_fd);
            self.finished = true;
            return err;
        };
        self.levels.append(self.allocator, .{
            .fd = root_fd,
            .depth = 0,
            .parent_path_len = 0,
            .items_off = 0,
            .items_end = @intCast(self.sorted_items.items.len),
            .cursor = 0,
            .dirents_off = 0,
        }) catch |err| {
            _ = linux.close(root_fd);
            self.finished = true;
            return err;
        };
    }

    /// The next buffered item of the innermost level, with the level's fd and
    /// depth (levels are popped, closed and their arena tail released on the
    /// way). Null, and `finished`, once every level is exhausted.
    inline fn popSortedItem(self: *RecursiveGetdents64Walker) ?struct { name_off: u32, name_len: u16, kind: EntryKind, descend: bool, parent_fd: posix.fd_t, depth: u16 } {
        while (true) {
            const n_levels = self.levels.items.len;
            if (n_levels == 0) {
                self.finished = true;
                return null;
            }
            const lvl = &self.levels.items[n_levels - 1];
            if (lvl.cursor >= lvl.items_end) {
                _ = linux.close(lvl.fd);
                self.sorted_items.shrinkRetainingCapacity(lvl.items_off);
                self.sorted_dirents.shrinkRetainingCapacity(lvl.dirents_off);
                self.path_len = lvl.parent_path_len;
                self.levels.items.len = n_levels - 1;
                continue;
            }
            const item = self.sorted_items.items[lvl.cursor];
            lvl.cursor += 1;
            // `lvl` may be invalidated by a push after this; copy what we need.
            return .{
                .name_off = item.name_off,
                .name_len = item.name_len,
                .kind = item.kind,
                .descend = item.descend,
                .parent_fd = lvl.fd,
                .depth = lvl.depth,
            };
        }
    }

    inline fn sortedName(self: *const RecursiveGetdents64Walker, item: anytype) [:0]const u8 {
        return self.sorted_dirents.items[item.name_off..][0..item.name_len :0];
    }

    /// Sorted mode: filter, open, drain and push `name_z` as a new level.
    /// Returns false (and pushes nothing) when the directory is pruned,
    /// unopenable, a follow-mode cycle, or out of memory, mirroring the
    /// silent skips of the unsorted path.
    fn descendSorted(
        self: *RecursiveGetdents64Walker,
        parent_fd: posix.fd_t,
        name_z: [:0]const u8,
        kind: EntryKind,
        relative_path: []const u8,
        depth: u16,
        parent_path_len: u16,
        sink: anytype,
    ) bool {
        if (self.config.dir_filter) |filter| {
            if (!filter.filterDir(relative_path, name_z)) return false;
        }

        // Symlink pre-flight, as in maybeDescend.
        if (kind == .sym_link) {
            const res = statAtFollow(parent_fd, name_z) orelse return false;
            if (!res.is_dir) return false;
            if (res.key.dev != self.root_dev) self.trust_short = false;
            const gop = self.visited.getOrPut(self.allocator, res.key) catch return false;
            if (gop.found_existing) return false;
        }

        const subdir_fd = noatime.openatZ(parent_fd, name_z.ptr, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }) catch return false;

        if (self.config.follow_symlinks and kind == .directory) {
            if (statFd(subdir_fd)) |key| {
                // Off the start dir's device (mount point under a followed
                // link): that filesystem was never checked by the short-read
                // gate, as in maybeDescend/confirmFreshDir.
                if (key.dev != self.root_dev) self.trust_short = false;
                if (self.visited.getOrPut(self.allocator, key)) |gop| {
                    if (gop.found_existing) {
                        _ = linux.close(subdir_fd);
                        return false;
                    }
                } else |_| {}
            }
        }

        const items_off = self.sorted_items.items.len;
        const dirents_off = self.sorted_dirents.items.len;
        const ok = blk: {
            self.levels.ensureUnusedCapacity(self.allocator, 1) catch break :blk false;
            self.drainDir(subdir_fd, depth + 1, sink) catch break :blk false;
            break :blk true;
        };
        if (!ok) {
            self.sorted_items.shrinkRetainingCapacity(items_off);
            self.sorted_dirents.shrinkRetainingCapacity(dirents_off);
            _ = linux.close(subdir_fd);
            return false;
        }
        self.levels.appendAssumeCapacity(.{
            .fd = subdir_fd,
            .depth = depth + 1,
            .parent_path_len = parent_path_len,
            .items_off = @intCast(items_off),
            .items_end = @intCast(self.sorted_items.items.len),
            .cursor = @intCast(items_off),
            .dirents_off = @intCast(dirents_off),
        });
        return true;
    }

    /// Sorted mode: read every entry of `fd` (a directory at `depth`) into
    /// the arenas, then sort the new items. getdents64 writes straight into
    /// `sorted_dirents`, one chunk of `getdents_buffer_size` at a time, and
    /// the items index the names in place. Same record validation and hidden
    /// filtering as parseNextEntry. On error the caller unwinds the arenas;
    /// nothing here closes `fd`.
    ///
    /// `sink` is `null` for `nextSorted` (every entry is buffered) or a
    /// `walkInto` sink: then non-directories are offered to `sink.wantFile`
    /// first and directories contribute only their descend marker.
    fn drainDir(self: *RecursiveGetdents64Walker, fd: posix.fd_t, depth: u16, sink: anytype) !void {
        const lazy = @TypeOf(sink) != @TypeOf(null);
        const items_off = self.sorted_items.items.len;
        const may_have_descend = depth < self.config.max_depth;
        const follow = self.config.follow_symlinks;
        const mark = self.config.sort_marks_dirs;
        const chunk = self.getdents_buffer.len;
        const cap = chunk - 8;

        while (true) {
            // Reserve a full chunk but hand the kernel 8 bytes less: the
            // spare tail backs the over-reads of direntNameLen and sortedKey.
            try self.sorted_dirents.ensureUnusedCapacity(self.allocator, chunk);
            const base = self.sorted_dirents.items.len;
            const dst = self.sorted_dirents.items.ptr + base;
            const bytes_read = linux.getdents64(fd, dst, cap);
            if (@as(isize, @bitCast(bytes_read)) < 0 or bytes_read == 0) break;
            self.sorted_dirents.items.len = base + bytes_read;
            const buf = self.sorted_dirents.items;
            const end = base + bytes_read;

            var off = base;
            while (off + dirent64.NAME_OFFSET <= end) {
                const reclen = mem.readInt(u16, buf[off + dirent64.RECLEN_OFFSET ..][0..2], .little);
                const d_type = buf[off + dirent64.TYPE_OFFSET];
                if (reclen < dirent64.NAME_OFFSET or off + reclen > end) {
                    @branchHint(.unlikely);
                    break;
                }
                const name_start = off + dirent64.NAME_OFFSET;
                const name_area = buf[name_start .. off + reclen];
                off += reclen;

                const name_len = direntNameLen(name_area.ptr, name_area.len);
                if (name_len == name_area.len) {
                    @branchHint(.unlikely);
                    continue;
                }
                const name = name_area[0..name_len];
                if (shouldSkipEntry(name, self.config.hidden)) continue;

                var kind: EntryKind = switch (d_type) {
                    DT_REG => .file,
                    DT_DIR => .directory,
                    DT_LNK => .sym_link,
                    else => .unknown,
                };
                // DT_UNKNOWN (XFS ftype=0, FUSE, ...): the unsorted walk
                // probes with openat(O_DIRECTORY) when it reaches the entry;
                // here the kind decides the sort key and the descend marker
                // up front, so classify with one lstat. Never taken on
                // filesystems that report d_type.
                if (kind == .unknown and may_have_descend) {
                    @branchHint(.unlikely);
                    kind = statKindNoFollow(fd, name_area[0..name_len :0]);
                }
                const is_dir = kind == .directory;
                const may_descend = may_have_descend and (is_dir or (follow and kind == .sym_link));
                const entry_slash = is_dir and mark;

                const want_entry = if (lazy) !is_dir and sink.wantFile(name, kind) else true;
                if (!want_entry and !may_descend) continue;

                try self.sorted_items.ensureUnusedCapacity(self.allocator, 2);
                if (want_entry) {
                    self.sorted_items.appendAssumeCapacity(.{
                        .key = sortedKeyAt(name_area.ptr, name_len, entry_slash, 0),
                        .name_off = @intCast(name_start),
                        .name_len = @intCast(name_len),
                        .kind = kind,
                        .slash = entry_slash,
                        .descend = false,
                    });
                }
                if (may_descend) {
                    self.sorted_items.appendAssumeCapacity(.{
                        .key = sortedKeyAt(name_area.ptr, name_len, true, 0),
                        .name_off = @intCast(name_start),
                        .name_len = @intCast(name_len),
                        .kind = kind,
                        .slash = true,
                        .descend = true,
                    });
                }
            }

            // A short read proves EOF on a trusted filesystem: skip the
            // confirming call that would only return 0.
            if (self.trust_short and dirent64.shortReadIsEof(bytes_read, cap)) break;
        }

        const new_items = self.sorted_items.items[items_off..];
        const dirents: []const u8 = self.sorted_dirents.items;
        if (new_items.len <= 32) {
            insertionSortItems(new_items, dirents);
        } else {
            std.sort.pdq(SortedItem, new_items, dirents, sortedLessFn);
        }
    }

    /// A dirent header parsed straight out of the getdents buffer.
    const RawEntry = struct {
        /// Borrowed from the getdents buffer. The terminator was verified, so
        /// the name can be handed to openat/fstatat without copying it out.
        name: [:0]const u8,
        d_type: u8,
        d_ino: u64,
    };

    /// Parse the dirent at getdents_offset and advance past it. Returns null
    /// for a malformed record, after consuming the rest of the buffer.
    inline fn parseRaw(self: *RecursiveGetdents64Walker) ?RawEntry {
        const base = self.getdents_offset;
        // Too few bytes left for a dirent header. Consume the remainder: the
        // caller loops until the offset reaches the length.
        if (base + dirent64.NAME_OFFSET > self.getdents_len) {
            @branchHint(.unlikely);
            self.getdents_offset = self.getdents_len;
            return null;
        }

        const reclen = mem.readInt(u16, self.getdents_buffer[base + dirent64.RECLEN_OFFSET ..][0..2], .little);
        const d_type = self.getdents_buffer[base + dirent64.TYPE_OFFSET];
        const d_ino = mem.readInt(u64, self.getdents_buffer[base + dirent64.INO_OFFSET ..][0..8], .little);

        // Guard against malformed (FUSE) records: a zero reclen would spin
        // forever, and a short one underflows the name area below.
        if (reclen < dirent64.NAME_OFFSET or base + reclen > self.getdents_len) {
            @branchHint(.unlikely);
            self.getdents_offset = self.getdents_len;
            return null;
        }
        self.getdents_offset += reclen;

        const name_start = base + dirent64.NAME_OFFSET;
        const name_area = self.getdents_buffer[name_start .. base + reclen];
        const name_len = direntNameLen(name_area.ptr, name_area.len);
        // unrealistic path if kernel is broken and path doesn't have NUL
        if (name_len == name_area.len) {
            @branchHint(.unlikely);
            return null;
        }
        return .{ .name = name_area[0..name_len :0], .d_type = d_type, .d_ino = d_ino };
    }

    /// Append "/name" (or "name" at the root) to path_buffer.
    inline fn appendNameToPath(self: *RecursiveGetdents64Walker, name: []const u8) void {
        if (self.path_len > 0) {
            self.path_buffer[self.path_len] = '/';
            self.path_len += 1;
        }
        @memcpy(self.path_buffer[self.path_len..][0..name.len], name);
        self.path_len += name.len;
    }

    /// Decide whether to descend into this entry and, if so, open it and push
    /// it on the stack. Expects path_buffer[0..path_len] to hold the entry's
    /// relative path. Returns the resolved kind: a DT_UNKNOWN entry whose
    /// probe open succeeded comes back as .directory.
    /// - .directory: always considered (subject to dir_filter)
    /// - .sym_link: only when follow_symlinks is set, and only after we
    ///   confirm via fstatat that it resolves to a directory.
    /// - .unknown: DT_UNKNOWN (XFS ftype=0, FUSE, some NFS/overlay/9p).
    ///   Probe with openat(O_DIRECTORY) directly: a file answers ENOTDIR,
    ///   cheaper than a statx pre-flight, and a directory is then already
    ///   open. Never taken on filesystems that report d_type.
    fn maybeDescend(self: *RecursiveGetdents64Walker, name_z: [:0]const u8, kind_in: EntryKind, d_ino: u64) EntryKind {
        var kind = kind_in;
        const may_descend = kind == .directory or kind == .unknown or
            (self.config.follow_symlinks and kind == .sym_link);
        if (!may_descend or self.current_depth >= self.config.max_depth) return kind;

        const relative_path = self.path_buffer[0..self.path_len];

        // Check dir_filter before deciding to descend
        const should_descend = if (self.config.dir_filter) |filter|
            filter.filterDir(relative_path, name_z)
        else
            true;
        if (!should_descend) return kind;

        // Cycle key the child carries under follow mode. A real directory
        // is keyed by the listing's d_ino under the current device (exact
        // within one filesystem; a mount or btrfs-subvolume crossing is
        // re-keyed by confirmFreshDir), so it costs no stat. Symlinks
        // pre-flight fstatat(FOLLOW) to confirm dir + cycle BEFORE openat,
        // skipping the wasted open+close for non-dir targets and cycles --
        // big win on symlink-heavy trees (node_modules, bazel-out). A
        // DT_UNKNOWN entry is keyed only once its probe open shows it is a
        // directory (below), since a symlink's d_ino is not its target's.
        const follow = self.config.follow_symlinks;
        var child_key: InodeKey = .{ .dev = self.current_dev, .ino = d_ino };
        const skip_descend: bool = blk: {
            if (!follow) break :blk false;
            if (kind == .sym_link) {
                const res = statAtFollow(self.current_fd, name_z) orelse break :blk true;
                if (!res.is_dir) break :blk true;
                // Off the start dir's device: that filesystem was never
                // checked, so stop trusting short reads from here on.
                if (res.key.dev != self.root_dev) self.trust_short = false;
                child_key = res.key;
            } else if (kind != .directory) break :blk false;
            const gop = self.visited.getOrPut(self.allocator, child_key) catch break :blk true;
            break :blk gop.found_existing;
        };
        if (skip_descend) return kind;

        // An .unknown entry may be a symlink; without follow mode
        // NOFOLLOW makes such a probe fail (ELOOP) instead of
        // descending through it.
        const open_flags: posix.O = .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
            .NOFOLLOW = kind == .unknown and !follow,
        };
        var opened: ?posix.fd_t = null;
        var verify_key = false;
        if (follow and kind == .directory) {
            if (!self.openat2_unavailable) {
                // RESOLVE_NO_XDEV: a mount-point crossing fails with EXDEV
                // and falls through to a plain open whose key
                // confirmFreshDir must then re-derive.
                switch (noatime.openat2NoXdev(self.current_fd, name_z.ptr, open_flags)) {
                    .opened => |fd| opened = fd,
                    .xdev => verify_key = true,
                    .unavailable => {
                        self.openat2_unavailable = true;
                        verify_key = true;
                    },
                    .other => {}, // let openat report the error
                }
            } else {
                verify_key = true;
            }
        }
        // openatZ, not openat: the slice overload would re-copy
        // and rescan the name via toPosixPath.
        const subdir_fd = opened orelse (noatime.openatZ(self.current_fd, name_z.ptr, open_flags) catch return kind);
        // The probe succeeded: an .unknown entry is a directory.
        if (kind == .unknown) {
            kind = .directory;
            // Real-directory cycle bookkeeping for the DT_UNKNOWN case
            // (a d_type-less filesystem: the probe's real key is exact).
            if (follow) {
                verify_key = true;
                if (statFd(subdir_fd)) |key| {
                    child_key = key;
                    verify_key = false;
                    if (self.visited.getOrPut(self.allocator, key)) |gop| {
                        if (gop.found_existing) {
                            _ = linux.close(subdir_fd);
                            return kind;
                        }
                    } else |_| {}
                }
            }
        }

        // Push to stack - processed after current dir is exhausted.
        // Save path content; sibling dirs overwrite path_buffer.
        const path_off = self.path_stack.items.len;
        if (self.path_stack.appendSlice(self.allocator, relative_path)) {
            self.dir_stack.append(self.allocator, .{
                .fd = subdir_fd,
                .depth = self.current_depth + 1,
                .path_len = @intCast(self.path_len),
                .path_off = @intCast(path_off),
                .dev = child_key.dev,
                .ino = child_key.ino,
                .verify_key = verify_key,
            }) catch {
                self.path_stack.shrinkRetainingCapacity(path_off);
                _ = linux.close(subdir_fd);
            };
        } else |_| {
            _ = linux.close(subdir_fd);
        }
        return kind;
    }

    fn parseNextEntry(self: *RecursiveGetdents64Walker) ?Entry {
        const raw = self.parseRaw() orelse return null;
        const name = raw.name;

        // Unified filtering for ".", "..", and hidden files
        if (shouldSkipEntry(name, self.config.hidden)) return null;

        var kind: EntryKind = switch (raw.d_type) {
            DT_REG => .file,
            DT_DIR => .directory,
            DT_LNK => .sym_link,
            else => .unknown,
        };

        // Build path for this entry
        const path_start = self.path_len;
        self.appendNameToPath(name);
        const name_in_path_start = self.path_len - name.len;

        kind = self.maybeDescend(name, kind, raw.d_ino);

        // Build result entry
        self.current_entry = .{
            .path = self.path_buffer[0..self.path_len],
            .basename = self.path_buffer[name_in_path_start..][0..name.len],
            .kind = kind,
        };

        // Reset path for next entry (but subdir path_len is saved in stack)
        self.path_len = path_start;

        return self.current_entry;
    }
};

const StdFsWalker = struct {
    /// `WalkerConfig.sorted` is ignored here; callers sort globally instead.
    pub const supports_sorted = false;

    allocator: Allocator,
    io: Io,
    config: WalkerConfig,

    // Stack of directories to process (LIFO order)
    dir_stack: std.ArrayList(StackEntry),

    // Saved paths of the directories on dir_stack, as in the getdents64 backend.
    path_stack: std.ArrayList(u8),

    // (dev, ino) bookkeeping for follow_symlinks cycle detection.
    // Empty when follow_symlinks is disabled.
    visited: std.AutoHashMapUnmanaged(InodeKey, void),

    // Current directory being iterated
    current_dir: ?std.Io.Dir,
    // Directory reader backed by a 4 KB buffer (reused across directories).
    // Using Reader directly avoids std.Io.Dir.Iterator's fixed 2 KB buffer,
    // which causes extra getdirentries/getdents syscalls in dirs with many
    // entries (e.g. the Linux kernel tree).
    reader: std.Io.Dir.Reader,
    reader_buffer: [4096]u8 align(@alignOf(usize)),
    // Batched entry cache: fetching multiple entries per vtable call
    // amortises the Io.dirRead indirection over many directory entries.
    entry_batch: [32]std.Io.Dir.Entry,
    batch_index: usize,
    batch_len: usize,
    current_depth: usize,

    // Path tracking
    path_buffer: [4096]u8,
    path_len: usize,

    // Current entry (reused)
    current_entry: Entry,

    // State
    finished: bool,

    const StackEntry = struct {
        dir: std.Io.Dir,
        depth: usize,
        // Where this dir's path lives in path_stack.
        path_len: u32,
        path_off: u32,
    };

    pub fn init(allocator: Allocator, io: Io, start_path: []const u8, config: WalkerConfig) !StdFsWalker {
        const root = config.base_dir orelse std.Io.Dir.cwd();
        var dir = root.openDir(io, start_path, .{ .iterate = true }) catch |err| {
            try handleOpenErrorStd(start_path, err, config);
            return err;
        };
        errdefer dir.close(io);

        var dir_stack = std.ArrayList(StackEntry).empty;
        // Only pre-allocate stack if we're doing recursion
        if (config.max_depth > 0) {
            dir_stack.ensureTotalCapacity(allocator, 64) catch {};
        }

        var visited: std.AutoHashMapUnmanaged(InodeKey, void) = .empty;
        if (config.follow_symlinks) {
            visited.ensureTotalCapacity(allocator, 256) catch {};
            if (statFd(dir.handle)) |key| {
                visited.put(allocator, key, {}) catch {};
            }
        }

        return StdFsWalker{
            .allocator = allocator,
            .io = io,
            .config = config,
            .dir_stack = dir_stack,
            .path_stack = std.ArrayList(u8).empty,
            .visited = visited,
            .current_dir = dir,
            .reader = .{
                .dir = dir,
                .state = .reset,
                .index = 0,
                .end = 0,
                .buffer = &[_]u8{},
            },
            .reader_buffer = undefined,
            .entry_batch = undefined,
            .batch_index = 0,
            .batch_len = 0,
            .current_depth = 0,
            .path_buffer = undefined,
            .path_len = 0,
            .current_entry = undefined,
            .finished = false,
        };
    }

    /// Handle directory open errors by calling err_callback and checking abort_on_error
    fn handleOpenErrorStd(path: []const u8, err: anyerror, config: WalkerConfig) !void {
        if (config.err_callback) |cb| {
            var path_z: [4096:0]u8 = undefined;
            const len = @min(path.len, 4095);
            @memcpy(path_z[0..len], path[0..len]);
            path_z[len] = 0;

            const err_code = zigErrorToPosix(err);
            if (cb(&path_z, err_code) != 0) {
                return error.Aborted;
            }
        }
        if (config.abort_on_error) {
            return error.Aborted;
        }
    }

    pub fn deinit(self: *StdFsWalker) void {
        const io = self.io;
        // Close current directory if still open
        if (self.current_dir) |*dir| {
            dir.close(io);
        }

        // Close any remaining stacked directories
        for (self.dir_stack.items) |*entry| {
            entry.dir.close(io);
        }
        self.dir_stack.deinit(self.allocator);
        self.path_stack.deinit(self.allocator);
        self.visited.deinit(self.allocator);
    }

    /// Portable counterpart of the getdents backend's walkInto: same sink
    /// contract, driven by next(). Errors from next() end the walk, matching
    /// the `next() catch null` loops this replaces.
    pub fn walkInto(self: *StdFsWalker, sink: anytype) !void {
        while (self.next() catch null) |entry| {
            if (entry.kind == .directory) continue;
            if (!sink.wantFile(entry.basename, entry.kind)) continue;
            const dir_rel = if (entry.path.len > entry.basename.len)
                entry.path[0 .. entry.path.len - entry.basename.len - 1]
            else
                entry.path[0..0];
            try sink.emitFile(dir_rel, entry.basename);
        }
    }

    pub fn next(self: *StdFsWalker) !?Entry {
        if (self.finished) return null;
        const io = self.io;

        while (true) {
            // Drain the cached batch first.
            if (self.current_dir != null and self.batch_index < self.batch_len) {
                const entry = self.entry_batch[self.batch_index];
                self.batch_index += 1;

                // Unified filtering for ".", "..", and hidden files
                if (shouldSkipEntry(entry.name, self.config.hidden)) continue;

                // Build path for this entry
                const path_start = self.path_len;
                if (self.path_len > 0) {
                    self.path_buffer[self.path_len] = '/';
                    self.path_len += 1;
                }
                const name_start = self.path_len;
                if (self.path_len + entry.name.len > 4095) continue; // Path too long
                @memcpy(self.path_buffer[self.path_len..][0..entry.name.len], entry.name);
                self.path_len += entry.name.len;

                const relative_path = self.path_buffer[0..self.path_len];
                var kind = entry.kind;

                // .unknown: probe with openDir like the getdents backend does.
                const may_descend = kind == .directory or kind == .unknown or
                    (self.config.follow_symlinks and kind == .sym_link);

                if (may_descend and self.current_depth < self.config.max_depth) {
                    // Check dir_filter before deciding to descend
                    const should_descend = if (self.config.dir_filter) |filter|
                        filter.filterDir(relative_path, entry.name)
                    else
                        true;

                    // For symlink entries under follow mode: pre-flight
                    // fstatat(FOLLOW) to confirm dir + cycle BEFORE openDir.
                    // Skips wasted open+close for non-dir targets and cycles.
                    var skip_descend = false;
                    if (should_descend and kind == .sym_link and entry.name.len < 256) {
                        var name_z: [256]u8 = undefined;
                        @memcpy(name_z[0..entry.name.len], entry.name);
                        name_z[entry.name.len] = 0;
                        const name_zp: [*:0]const u8 = @ptrCast(&name_z);
                        if (statAtFollow(self.current_dir.?.handle, name_zp)) |res| {
                            if (!res.is_dir) {
                                skip_descend = true;
                            } else {
                                if (self.visited.getOrPut(self.allocator, res.key)) |gop| {
                                    if (gop.found_existing) skip_descend = true;
                                } else |_| skip_descend = true;
                            }
                        } else {
                            skip_descend = true;
                        }
                    } else if (should_descend and kind == .sym_link) {
                        // Name too long for stack buffer — bail safely.
                        skip_descend = true;
                    }

                    if (should_descend and !skip_descend) {
                        if (self.current_dir.?.openDir(io, entry.name, .{
                            .iterate = true,
                            .follow_symlinks = !(kind == .unknown and !self.config.follow_symlinks),
                        })) |subdir| {
                            var sub = subdir;
                            if (kind == .unknown) kind = .directory;
                            // Real-directory cycle bookkeeping under follow mode.
                            // Symlinks already recorded via pre-flight above.
                            var cycle = false;
                            if (self.config.follow_symlinks and kind == .directory) {
                                if (statFd(sub.handle)) |key| {
                                    if (self.visited.getOrPut(self.allocator, key)) |gop| {
                                        if (gop.found_existing) cycle = true;
                                    } else |_| {}
                                }
                            }
                            if (cycle) {
                                sub.close(io);
                            } else {
                                const path_off = self.path_stack.items.len;
                                if (self.path_stack.appendSlice(self.allocator, self.path_buffer[0..self.path_len])) {
                                    self.dir_stack.append(self.allocator, .{
                                        .dir = sub,
                                        .depth = self.current_depth + 1,
                                        .path_len = @intCast(self.path_len),
                                        .path_off = @intCast(path_off),
                                    }) catch {
                                        self.path_stack.shrinkRetainingCapacity(path_off);
                                        sub.close(io);
                                    };
                                } else |_| {
                                    sub.close(io);
                                }
                            }
                        } else |_| {}
                    }
                }

                // Build result entry
                self.current_entry = .{
                    .path = relative_path,
                    .basename = self.path_buffer[name_start..][0..entry.name.len],
                    .kind = kind,
                };

                // Reset path for next entry
                self.path_len = path_start;

                return self.current_entry;
            }

            // Batch empty — refill via Reader.read. Reader.Entry.name slices
            // reference self.reader_buffer, so they stay valid until the next
            // refill. We batch up to entry_batch.len entries per vtable call,
            // amortising the Io.dirRead indirection.
            if (self.current_dir != null) {
                self.reader.buffer = &self.reader_buffer;
                const n = self.reader.read(io, &self.entry_batch) catch 0;
                self.batch_index = 0;
                self.batch_len = n;
                if (n > 0) continue;
            }

            // Current directory exhausted - close it and pop from stack
            if (self.current_dir) |*dir| {
                dir.close(io);
                self.current_dir = null;
            }

            if (self.dir_stack.items.len == 0) {
                self.finished = true;
                return null;
            }

            // Pop next directory from stack
            const next_entry = self.dir_stack.pop() orelse {
                self.finished = true;
                return null;
            };
            self.current_dir = next_entry.dir;
            // Re-initialize the reader for the new directory (reuses buffer).
            self.reader = .{
                .dir = next_entry.dir,
                .state = .reset,
                .index = 0,
                .end = 0,
                .buffer = &[_]u8{},
            };
            // Invalidate any cached entries from the previous directory.
            self.batch_index = 0;
            self.batch_len = 0;
            self.current_depth = next_entry.depth;
            // Restore this dir's saved path, then release its bytes.
            @memcpy(
                self.path_buffer[0..next_entry.path_len],
                self.path_stack.items[next_entry.path_off..][0..next_entry.path_len],
            );
            self.path_len = next_entry.path_len;
            self.path_stack.shrinkRetainingCapacity(next_entry.path_off);
        }
    }
};

/// Lightweight single-directory iterator using getdents64 on Linux.
/// Uses raw syscalls for maximum performance - no Zig or libc overhead.
/// Uses a stack buffer instead of heap allocation.
pub const SingleDirIterator = struct {
    const is_linux = builtin.os.tag == .linux;
    const linux = if (is_linux) std.os.linux else undefined;

    const DT_DIR: u8 = 4;
    const DT_REG: u8 = 8;
    const DT_LNK: u8 = 10;

    fd: i32,
    buffer: [8192]u8 align(8),
    offset: usize,
    len: usize,
    hidden: HiddenConfig,
    /// Short getdents64 returns prove EOF on this filesystem (see
    /// dirent.trustShortReaddir); `eof` marks the buffer being drained as the
    /// directory's last, so the confirming call is skipped.
    trust_short: bool = false,
    eof: bool = false,

    pub const IterEntry = struct {
        name: []const u8,
        kind: EntryKind,
    };

    pub const OpenedDir = struct {
        fd: i32,
        /// The path may have been resolved through a symlink (it was, or
        /// openat2 could not rule it out); false only when
        /// `openDirFdChecked` was asked to and could prove otherwise.
        maybe_symlinked: bool,
    };

    /// Open a directory for single-level iteration using raw syscalls.
    /// If base_dir is provided, opens path relative to it; otherwise relative to cwd.
    /// Open just the directory fd, so callers embedding this iterator can
    /// construct it in place rather than moving it out of an error union.
    pub fn openDirFd(path: []const u8, base_dir: ?std.Io.Dir) !i32 {
        return (try openDirFdChecked(path, base_dir, false)).fd;
    }

    /// `openDirFd` that, when `rule_out_symlinks` is set, first tries
    /// openat2(RESOLVE_NO_SYMLINKS): a success proves the directory was
    /// reached without following any link, i.e. it lies below the base
    /// directory's tree. Only a path with a symlink pays a second open.
    pub fn openDirFdChecked(path: []const u8, base_dir: ?std.Io.Dir, rule_out_symlinks: bool) !OpenedDir {
        if (!is_linux) {
            @compileError("SingleDirIterator.openDirFd requires Linux");
        }

        // Build null-terminated path on stack
        var path_z: [4096:0]u8 = undefined;
        if (path.len >= 4096) return error.NameTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const flags = linux.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };

        // Use raw syscall for maximum performance
        const dir_fd = if (base_dir) |bd| bd.handle else linux.AT.FDCWD;
        var maybe_symlinked = true;
        const rc = blk: {
            if (rule_out_symlinks) {
                if (noatime.openat2NoSymlinks(dir_fd, &path_z, flags)) |rc2| {
                    maybe_symlinked = false;
                    break :blk rc2;
                }
            }
            break :blk noatime.openat(dir_fd, &path_z, flags);
        };
        // Map onto the same error set std.Io.Dir.openDir produces so
        // openHandled reports an accurate errno through ErrCallbackFn.
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .fd = @intCast(rc), .maybe_symlinked = maybe_symlinked },
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .ACCES => error.AccessDenied,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            .NOMEM => error.SystemResources,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .BADF => error.InvalidHandle,
            .INVAL => error.InvalidArgument,
            else => error.AccessDenied,
        };
    }

    pub fn open(path: []const u8, base_dir: ?std.Io.Dir, hidden_config: HiddenConfig) !SingleDirIterator {
        return SingleDirIterator{
            .fd = try openDirFd(path, base_dir),
            .buffer = undefined,
            .offset = 0,
            .len = 0,
            .hidden = hidden_config,
        };
    }

    pub fn close(self: *SingleDirIterator) void {
        if (!is_linux) return;
        _ = linux.close(self.fd);
    }

    pub fn next(self: *SingleDirIterator) ?IterEntry {
        if (!is_linux) return null;

        while (true) {
            // Try to get next entry from buffer
            while (self.offset < self.len) {
                const base = self.offset;
                if (base + dirent64.NAME_OFFSET > self.len) break;

                const reclen = mem.readInt(u16, self.buffer[base + dirent64.RECLEN_OFFSET ..][0..2], .little);
                const d_type = self.buffer[base + dirent64.TYPE_OFFSET];

                // Guard against malformed (FUSE) records: a zero reclen would
                // spin forever, a short one underflows the name area below.
                if (reclen < dirent64.NAME_OFFSET or base + reclen > self.len) {
                    @branchHint(.unlikely);
                    self.offset = self.len;
                    break;
                }
                self.offset += reclen;

                // The name follows the header, NUL-terminated in the record.
                const name_area = self.buffer[base + dirent64.NAME_OFFSET .. base + reclen];
                const name = name_area[0..direntNameLen(name_area.ptr, name_area.len)];

                // Unified filtering for ".", "..", and hidden files
                if (shouldSkipEntry(name, self.hidden)) continue;

                const kind: EntryKind = switch (d_type) {
                    DT_REG => .file,
                    DT_DIR => .directory,
                    DT_LNK => .sym_link,
                    else => .unknown,
                };

                return IterEntry{ .name = name, .kind = kind };
            }

            // Buffer exhausted - read more. Short by 8: see direntNameLen.
            // A previous short read already proved EOF: skip the 0-return call.
            if (self.eof) return null;
            const cap = self.buffer.len - 8;
            const rc = linux.getdents64(self.fd, &self.buffer, cap);
            const bytes_read: isize = @bitCast(rc);
            if (bytes_read <= 0) {
                return null;
            }

            self.len = @intCast(bytes_read);
            self.offset = 0;
            self.eof = self.trust_short and dirent64.shortReadIsEof(self.len, cap);
        }
    }
};

pub const DirIterator = struct {
    // std.c is only available on POSIX systems
    const has_libc = builtin.os.tag != .windows and builtin.link_libc;
    const c = if (has_libc) std.c else struct {
        // Stubs for non-libc platforms
        pub const DIR = opaque {};
        pub const dirent = extern struct {
            name: [256]u8,
            type: u8,
        };
        pub const DT = struct {
            pub const REG: u8 = 8;
            pub const DIR: u8 = 4;
            pub const LNK: u8 = 10;
        };
        pub fn opendir(_: anytype) ?*DIR {
            return null;
        }
        pub fn readdir(_: anytype) ?*anyopaque {
            return null;
        }
        pub fn closedir(_: anytype) c_int {
            return 0;
        }
    };

    const is_linux = builtin.os.tag == .linux;
    // Empty payload off Linux, where this variant is never constructed.
    const GetdentsIter = if (is_linux) SingleDirIterator else struct {};

    io: Io,
    /// Internal state - getdents64 (Linux), C readdir (other POSIX),
    /// std.Io (Windows/no-libc fallback), or ALTDIRFUNC callbacks.
    mode: union(enum) {
        /// Raw getdents64 syscalls (Linux only). Avoids opendir's per-directory
        /// buffer malloc and the per-entry readdir call.
        getdents: GetdentsIter,
        /// Real filesystem using C's opendir/readdir (POSIX only)
        real_fs: struct {
            dir: ?*c.DIR,
        },
        /// Zig std.Io based iteration (Windows and fallback)
        std_fs: struct {
            dir: std.Io.Dir,
            iter: std.Io.Dir.Iterator,
        },
        /// ALTDIRFUNC custom callbacks
        alt_dirfunc: struct {
            handle: ?*anyopaque,
            readdir: AltReaddirFn,
            closedir: AltClosedirFn,
        },
    },
    hidden: HiddenConfig,

    pub const IterEntry = struct {
        name: []const u8,
        kind: EntryKind,
    };

    /// Platform-specific d_name buffer size:
    /// - Linux: 256 bytes
    /// - macOS (64-bit inodes): 1024 bytes (__DARWIN_MAXPATHLEN)
    /// - FreeBSD: 256 bytes (255 + sentinel)
    /// - NetBSD: 512 bytes (511 + sentinel)
    /// - Windows: 256 bytes (not used, but defined for consistency)
    const DIRENT_NAME_LEN: usize = switch (builtin.os.tag) {
        .macos => 1024,
        .netbsd => 512,
        else => 256,
    };

    /// BSD-derived systems (macOS, FreeBSD, NetBSD, OpenBSD) embed the actual
    /// name length in the dirent `namlen` field, so we can return the slice in
    /// O(1). On glibc Linux the field is absent, so fall back to a SIMD scan
    /// for the terminating NUL.
    const has_namlen = has_libc and @hasField(c.dirent, "namlen");

    /// Extract the name slice from a dirent entry. Uses `namlen` when present
    /// (BSD-family) to skip the trailing-NUL scan entirely — avoids scanning
    /// a fresh 1024-byte buffer on every macOS readdir().
    inline fn direntNameFromEntry(entry: *const c.dirent) []const u8 {
        if (has_namlen) {
            const namlen: usize = @intCast(entry.namlen);
            return entry.name[0..namlen];
        }
        return direntNameSlice(@ptrCast(&entry.name));
    }

    /// SIMD-optimized strlen for dirent d_name. Only used on platforms whose
    /// dirent struct does NOT carry an explicit `namlen`.
    inline fn direntNameSlice(d_name: *const [DIRENT_NAME_LEN]u8) []const u8 {
        const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
        const Vec = @Vector(vec_len, u8);
        const zeros: Vec = @splat(0);
        const iterations = DIRENT_NAME_LEN / vec_len;

        inline for (0..iterations) |iter| {
            const i = iter * vec_len;
            const chunk: Vec = d_name[i..][0..vec_len].*;
            const eq = chunk == zeros;
            const MaskInt = std.meta.Int(.unsigned, vec_len);
            const mask = @as(MaskInt, @bitCast(eq));
            if (mask != 0) {
                return d_name[0 .. i + @ctz(mask)];
            }
        }
        return d_name[0..DIRENT_NAME_LEN];
    }

    /// Open a directory for single-level iteration.
    /// If base_dir is provided, opens path relative to it; otherwise relative to cwd.
    /// hidden_config controls filtering of ".", "..", and hidden files.
    /// fs allows using ALTDIRFUNC callbacks for virtual filesystem support.
    /// Open a directory for iteration, constructing the iterator in place.
    /// `out` is only initialized on success. Constructing in place matters:
    /// the getdents mode embeds an 8 KiB buffer, and returning it by value
    /// through an error union makes the compiler copy that buffer per open.
    pub fn openWithProviderInto(out: *DirIterator, io: Io, path: []const u8, base_dir: ?std.Io.Dir, hidden_config: HiddenConfig, fs: AltFs) !void {
        if (path.len >= 4096) return error.NameTooLong;

        if (fs.isAltDirFunc()) {
            // Use ALTDIRFUNC callbacks
            var path_z: [4096:0]u8 = undefined;
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;

            const handle = fs.opendir.?(&path_z);
            if (handle == null) return error.FileNotFound;

            out.* = .{
                .io = io,
                .mode = .{ .alt_dirfunc = .{
                    .handle = handle,
                    .readdir = fs.readdir.?,
                    .closedir = fs.closedir.?,
                } },
                .hidden = hidden_config,
            };
            return;
        }

        // Linux: raw getdents64, no libc required. Handles base_dir natively
        // via openat. `.buffer = undefined` keeps the 8 KiB scratch area
        // untouched here.
        if (is_linux) {
            // The first directory a glob call opens is its start directory;
            // its verdict covers every directory opened below it that is on
            // the same device (see TrustCache). A later open that provably
            // followed no symlink stayed inside the start directory's tree,
            // where the probe already vouched for every mount, so only a
            // symlinked path pays the fstat. Once the verdict is `no`
            // nothing more is paid here.
            const rule_out_symlinks = if (fs.trust) |tc| tc.state == .yes else false;
            const opened = try SingleDirIterator.openDirFdChecked(path, base_dir, rule_out_symlinks);
            const fd = opened.fd;
            var trust_short = false;
            if (fs.trust) |tc| {
                switch (tc.state) {
                    .unknown => {
                        tc.state = .no;
                        if (dirent64.trustShortReaddir(fd)) {
                            if (statFd(fd)) |key| {
                                tc.state = .yes;
                                tc.dev = key.dev;
                                trust_short = true;
                            }
                        }
                    },
                    .yes => {
                        trust_short = !opened.maybe_symlinked or
                            if (statFd(fd)) |key| key.dev == tc.dev else false;
                    },
                    .no => {},
                }
            }
            out.* = .{
                .io = io,
                .mode = .{ .getdents = .{
                    .fd = fd,
                    .buffer = undefined,
                    .offset = 0,
                    .len = 0,
                    .hidden = hidden_config,
                    .trust_short = trust_short,
                    .eof = false,
                } },
                .hidden = hidden_config,
            };
            return;
        }

        // When base_dir is set (need relative opens) or on Windows or when libc
        // is not available, use std.Io
        if (base_dir != null or builtin.os.tag == .windows or !has_libc) {
            const root = base_dir orelse std.Io.Dir.cwd();
            var dir = try root.openDir(io, path, .{ .iterate = true });
            out.* = .{
                .io = io,
                .mode = .{ .std_fs = .{
                    .dir = dir,
                    .iter = dir.iterate(),
                } },
                .hidden = hidden_config,
            };
            return;
        }

        // Real filesystem: use C's optimized opendir/readdir
        var path_z: [4096:0]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const dir = c.opendir(&path_z);
        if (dir == null) {
            return error.AccessDenied;
        }

        out.* = .{
            .io = io,
            .mode = .{ .real_fs = .{ .dir = dir } },
            .hidden = hidden_config,
        };
    }

    /// By-value variant of openWithProviderInto. Prefer the Into form in hot
    /// paths: this one copies the iterator, getdents buffer included.
    pub fn openWithProvider(io: Io, path: []const u8, base_dir: ?std.Io.Dir, hidden_config: HiddenConfig, fs: AltFs) !DirIterator {
        var it: DirIterator = undefined;
        try openWithProviderInto(&it, io, path, base_dir, hidden_config, fs);
        return it;
    }

    /// Open a directory for single-level iteration (backward compatible).
    /// If base_dir is provided, opens path relative to it; otherwise relative to cwd.
    /// hidden_config controls filtering of ".", "..", and hidden files.
    pub fn open(io: Io, path: []const u8, base_dir: ?std.Io.Dir, hidden_config: HiddenConfig) !DirIterator {
        return openWithProvider(io, path, base_dir, hidden_config, AltFs.real_fs);
    }

    /// Configuration for error handling when opening a directory fails.
    pub const OpenErrorConfig = struct {
        err_callback: ?ErrCallbackFn = null,
        abort_on_error: bool = false,
        /// Path to report to err_callback instead of the opened one, for
        /// fd-relative opens that should still report a full path.
        report_path: ?[]const u8 = null,
        /// Treat ENOTDIR as "skip" without reporting it. Used when the caller
        /// probes a DT_UNKNOWN entry by opening it, the same way glibc's
        /// glob_in_dir ignores ENOTDIR from opendir.
        ignore_not_dir: bool = false,
    };

    /// This directory as an openat() base for its children, when the platform
    /// exposes a real fd. Saves the kernel re-resolving the path prefix.
    pub fn relativeBase(self: *const DirIterator) ?std.Io.Dir {
        if (comptime is_linux) {
            return switch (self.mode) {
                .getdents => |*g| .{ .handle = g.fd },
                else => null,
            };
        }
        return null;
    }

    /// Open a directory with error callback handling.
    /// On failure, invokes err_callback (if set) and returns null instead of an error.
    /// Returns error.Aborted only when the callback requests abort or abort_on_error is set.
    /// Open a directory with error callback handling, constructing the
    /// iterator in place (see openWithProviderInto). Returns true when `out`
    /// was initialized, false when the directory should be skipped, and
    /// error.Aborted when the callback or abort_on_error demands it.
    pub fn openHandledInto(
        out: *DirIterator,
        io: Io,
        path: []const u8,
        base_dir: ?std.Io.Dir,
        hidden_config: HiddenConfig,
        fs: AltFs,
        err_config: OpenErrorConfig,
    ) error{Aborted}!bool {
        openWithProviderInto(out, io, path, base_dir, hidden_config, fs) catch |err| {
            if (err == error.NotDir and err_config.ignore_not_dir) return false;
            if (err_config.err_callback) |cb| {
                const report = err_config.report_path orelse path;
                var path_z: [4096:0]u8 = undefined;
                const len = @min(report.len, 4095);
                @memcpy(path_z[0..len], report[0..len]);
                path_z[len] = 0;
                if (cb(&path_z, zigErrorToPosix(err)) != 0) {
                    return error.Aborted;
                }
            }
            if (err_config.abort_on_error) return error.Aborted;
            return false;
        };
        return true;
    }

    /// By-value variant of openHandledInto, kept for API compatibility.
    pub fn openHandled(
        io: Io,
        path: []const u8,
        base_dir: ?std.Io.Dir,
        hidden_config: HiddenConfig,
        fs: AltFs,
        err_config: OpenErrorConfig,
    ) error{Aborted}!?DirIterator {
        var it: DirIterator = undefined;
        if (!try openHandledInto(&it, io, path, base_dir, hidden_config, fs, err_config)) return null;
        return it;
    }

    pub fn close(self: *DirIterator) void {
        switch (self.mode) {
            .getdents => |*g| {
                if (comptime is_linux) g.close();
            },
            .real_fs => |*fs_mode| {
                if (has_libc) {
                    if (fs_mode.dir) |d| {
                        _ = c.closedir(d);
                        fs_mode.dir = null;
                    }
                }
            },
            .std_fs => |*std_mode| {
                std_mode.dir.close(self.io);
            },
            .alt_dirfunc => |*alt| {
                alt.closedir(alt.handle);
                alt.handle = null;
            },
        }
    }

    pub fn next(self: *DirIterator) ?IterEntry {
        switch (self.mode) {
            .getdents => |*g| {
                if (comptime is_linux) {
                    // SingleDirIterator applies the same hidden-config
                    // filtering, and its names stay valid until the next
                    // next() call, matching readdir's contract.
                    if (g.next()) |entry| {
                        return IterEntry{ .name = entry.name, .kind = entry.kind };
                    }
                }
                return null;
            },
            .real_fs => |fs_mode| {
                if (!has_libc) return null;

                const dir = fs_mode.dir orelse return null;

                while (c.readdir(dir)) |entry_raw| {
                    const entry: *const c.dirent = @ptrCast(@alignCast(entry_raw));
                    // Uses the dirent's own name-length field on BSD-family
                    // systems (macOS/FreeBSD/NetBSD/OpenBSD) to skip a 1024-byte
                    // SIMD NUL scan per entry.
                    const name = direntNameFromEntry(entry);

                    // Unified filtering for ".", "..", and hidden files
                    if (shouldSkipEntry(name, self.hidden)) continue;

                    const kind: EntryKind = switch (entry.type) {
                        c.DT.REG => .file,
                        c.DT.DIR => .directory,
                        c.DT.LNK => .sym_link,
                        else => .unknown,
                    };

                    return IterEntry{ .name = name, .kind = kind };
                }

                return null;
            },
            .std_fs => |*std_mode| {
                while (std_mode.iter.next(self.io) catch null) |entry| {
                    // Unified filtering for ".", "..", and hidden files
                    if (shouldSkipEntry(entry.name, self.hidden)) continue;

                    return IterEntry{
                        .name = entry.name,
                        .kind = entry.kind,
                    };
                }
                return null;
            },
            .alt_dirfunc => |alt| {
                while (alt.readdir(alt.handle)) |dirent| {
                    const name = mem.sliceTo(dirent.d_name, 0);

                    // Unified filtering for ".", "..", and hidden files
                    if (shouldSkipEntry(name, self.hidden)) continue;

                    const kind: EntryKind = switch (dirent.d_type) {
                        4 => .directory, // DT_DIR
                        8 => .file, // DT_REG
                        10 => .sym_link, // DT_LNK
                        else => .unknown,
                    };

                    return IterEntry{ .name = name, .kind = kind };
                }

                return null;
            },
        }
    }
};

fn zigErrorToPosix(err: anyerror) c_int {
    return switch (err) {
        error.AccessDenied => errno.ACCES,
        error.FileNotFound => errno.NOENT,
        error.NotDir => errno.NOTDIR,
        error.SymLinkLoop => errno.LOOP,
        error.NameTooLong => errno.NAMETOOLONG,
        error.SystemResources => errno.NOMEM,
        error.ProcessFdQuotaExceeded => errno.MFILE,
        error.SystemFdQuotaExceeded => errno.NFILE,
        error.InvalidHandle, error.InvalidArgument => errno.INVAL,
        else => errno.IO,
    };
}

pub const AltDirent = extern struct {
    d_name: [*:0]const u8, // Null-terminated entry name
    d_type: u8, // Entry type: DT_DIR=4, DT_REG=8, DT_UNKNOWN=0
};

pub const AltOpendirFn = *const fn (path: [*:0]const u8) callconv(.c) ?*anyopaque;
pub const AltReaddirFn = *const fn (dir: ?*anyopaque) callconv(.c) ?*AltDirent;
pub const AltClosedirFn = *const fn (dir: ?*anyopaque) callconv(.c) void;

pub const AltFs = struct {
    opendir: ?AltOpendirFn = null,
    readdir: ?AltReaddirFn = null,
    closedir: ?AltClosedirFn = null,
    /// Linux: when set, DirIterators opened through this provider share the
    /// short-read verdict (probed on the first directory opened). Null keeps
    /// the EOF-confirming getdents64 call.
    trust: ?*TrustCache = null,

    /// Check if this provider uses ALTDIRFUNC callbacks
    pub inline fn isAltDirFunc(self: AltFs) bool {
        return self.opendir != null and self.readdir != null and self.closedir != null;
    }

    /// Default provider using real filesystem
    pub const real_fs = AltFs{};
};

test "walker basic" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var walker = try DefaultWalker.init(allocator, io, ".", .{ .hidden = HiddenConfig.posix_default });
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next()) |_| {
        count += 1;
        if (count > 10) break;
    }

    try std.testing.expect(count > 0);
}

// direntNameLen lives in walker/dirent.zig, which is a module root and so
// cannot host its own tests. They run from here instead.
//
// The bodies sit behind a comptime branch, not `error.SkipZigTest`: dirent.zig
// refuses to compile off Linux, and a skipped test body would still be
// semantically analyzed. Only the taken branch of a comptime-known `if` is.
test "direntNameLen finds the terminator across word boundaries" {
    if (comptime builtin.os.tag == .linux) {
        // Names are laid out as the kernel writes them: NUL-terminated, then
        // padded to the record length.
        var area: [64]u8 = undefined;
        for ([_]usize{ 0, 1, 7, 8, 9, 15, 16, 31 }) |name_len| {
            @memset(&area, 'a');
            area[name_len] = 0;
            @memset(area[name_len + 1 ..], 0);
            try std.testing.expectEqual(name_len, direntNameLen(&area, area.len));
        }
    }
}

test "direntNameLen clamps when the area has no terminator" {
    if (comptime builtin.os.tag == .linux) {
        // A malformed record without a NUL must report the area length rather
        // than running past it.
        var area: [24]u8 = @splat('a');
        try std.testing.expectEqual(area.len, direntNameLen(&area, area.len));

        // Unterminated area whose length is not a multiple of the word size:
        // the final word read spans past area_len, so the result must clamp.
        var padded: [32]u8 = @splat('a');
        @memset(padded[21..], 0);
        try std.testing.expectEqual(@as(usize, 21), direntNameLen(&padded, 21));
        try std.testing.expectEqual(@as(usize, 13), direntNameLen(&padded, 13));
    }
}

test "direntNameLen does not mistake high bytes for a terminator" {
    if (comptime builtin.os.tag == .linux) {
        // Bytes >= 0x80 (UTF-8 continuations) already have the high bit set,
        // which is what the `& ~word` step exists to reject.
        var area: [32]u8 = @splat(0xC3);
        @memset(area[9..], 0);
        try std.testing.expectEqual(@as(usize, 9), direntNameLen(&area, area.len));
    }
}

test "EntryKind is std.Io.File.Kind" {
    // EntryKind is a direct alias — verify the variants we rely on exist
    try std.testing.expectEqual(EntryKind.file, std.Io.File.Kind.file);
    try std.testing.expectEqual(EntryKind.directory, std.Io.File.Kind.directory);
    try std.testing.expectEqual(EntryKind.sym_link, std.Io.File.Kind.sym_link);
}

// ============================================================================
// POSIX Compliance Tests for Hidden Files and Dot Entries
// ============================================================================

test "shouldSkipEntry - POSIX default skips dot and dotdot" {
    const config = HiddenConfig.posix_default;

    // "." and ".." should be skipped by default
    try std.testing.expect(shouldSkipEntry(".", config) == true);
    try std.testing.expect(shouldSkipEntry("..", config) == true);

    // Regular hidden files should be skipped
    try std.testing.expect(shouldSkipEntry(".gitignore", config) == true);
    try std.testing.expect(shouldSkipEntry(".hidden", config) == true);

    // Non-hidden files should NOT be skipped
    try std.testing.expect(shouldSkipEntry("file.txt", config) == false);
    try std.testing.expect(shouldSkipEntry("README.md", config) == false);
}

test "shouldSkipEntry - include_all allows everything" {
    const config = HiddenConfig.include_all;

    // "." and ".." should be included
    try std.testing.expect(shouldSkipEntry(".", config) == false);
    try std.testing.expect(shouldSkipEntry("..", config) == false);

    // Hidden files should be included
    try std.testing.expect(shouldSkipEntry(".gitignore", config) == false);
    try std.testing.expect(shouldSkipEntry(".hidden", config) == false);

    // Non-hidden files should be included
    try std.testing.expect(shouldSkipEntry("file.txt", config) == false);
}

test "shouldSkipEntry - hidden_only skips dot/dotdot but allows hidden files" {
    const config = HiddenConfig.hidden_only;

    // "." and ".." should be skipped
    try std.testing.expect(shouldSkipEntry(".", config) == true);
    try std.testing.expect(shouldSkipEntry("..", config) == true);

    // Hidden files should be included (for ZLOB_PERIOD flag)
    try std.testing.expect(shouldSkipEntry(".gitignore", config) == false);
    try std.testing.expect(shouldSkipEntry(".hidden", config) == false);

    // Non-hidden files should be included
    try std.testing.expect(shouldSkipEntry("file.txt", config) == false);
}

test "shouldSkipEntry - empty name always skipped" {
    const config = HiddenConfig.include_all;
    try std.testing.expect(shouldSkipEntry("", config) == true);
}

test "HiddenConfig.fromPatternAndFlags - POSIX glob semantics" {
    // Pattern "*" - should skip hidden files and dot entries
    {
        const config = HiddenConfig.fromPatternAndFlags(false, false, false);
        try std.testing.expect(config.include_dot_entries == false);
        try std.testing.expect(config.include_hidden == false);
    }

    // Pattern ".*" (starts with dot) - should include dot entries and hidden files
    // POSIX: ".*" matches ".", "..", and hidden files
    {
        const config = HiddenConfig.fromPatternAndFlags(true, false, false);
        try std.testing.expect(config.include_dot_entries == true);
        try std.testing.expect(config.include_hidden == true);
    }

    // Pattern "." or ".." (is dot or dotdot) - should include dot entries only
    {
        const config = HiddenConfig.fromPatternAndFlags(true, true, false);
        try std.testing.expect(config.include_dot_entries == true);
        try std.testing.expect(config.include_hidden == false);
    }

    // Pattern "*" with ZLOB_PERIOD flag - should include hidden but not dot entries
    {
        const config = HiddenConfig.fromPatternAndFlags(false, false, true);
        try std.testing.expect(config.include_dot_entries == false);
        try std.testing.expect(config.include_hidden == true);
    }

    // Pattern ".*" with ZLOB_PERIOD flag - PERIOD takes precedence for hidden
    {
        const config = HiddenConfig.fromPatternAndFlags(true, false, true);
        try std.testing.expect(config.include_dot_entries == false);
        try std.testing.expect(config.include_hidden == true);
    }
}

test "HiddenConfig presets match expected values" {
    // posix_default
    try std.testing.expect(HiddenConfig.posix_default.include_dot_entries == false);
    try std.testing.expect(HiddenConfig.posix_default.include_hidden == false);

    // include_all
    try std.testing.expect(HiddenConfig.include_all.include_dot_entries == true);
    try std.testing.expect(HiddenConfig.include_all.include_hidden == true);

    // hidden_only
    try std.testing.expect(HiddenConfig.hidden_only.include_dot_entries == false);
    try std.testing.expect(HiddenConfig.hidden_only.include_hidden == true);
}
