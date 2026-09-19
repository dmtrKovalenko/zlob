const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("dirent64 records are a Linux getdents64 concept; " ++
            "this module must not be referenced on other targets");
    }
}

pub const INO_OFFSET = 0;
pub const RECLEN_OFFSET = 16;
pub const TYPE_OFFSET = 18;
pub const NAME_OFFSET = 19;

comptime {
    const d64 = std.os.linux.dirent64;
    std.debug.assert(@offsetOf(d64, "ino") == INO_OFFSET);
    std.debug.assert(@offsetOf(d64, "reclen") == RECLEN_OFFSET);
    std.debug.assert(@offsetOf(d64, "type") == TYPE_OFFSET);
    std.debug.assert(@offsetOf(d64, "name") == NAME_OFFSET);
}

/// Length of the NUL-terminated name in a dirent record, scanned a word at a
/// time. Returns area_len if no NUL is present.
/// (yes it's a better faster SWAR implmeented `strnlen`)
pub inline fn nameLen(area_ptr: [*]const u8, area_len: usize) usize {
    const lo: u64 = 0x0101010101010101;
    const hi: u64 = 0x8080808080808080;
    var k: usize = 0;
    while (k < area_len) : (k += 8) {
        const w = mem.readInt(u64, area_ptr[k..][0..8], .little);
        const zero_mask = (w -% lo) & ~w & hi;
        if (zero_mask != 0) {
            return @min(k + (@ctz(zero_mask) >> 3), area_len);
        }
    }
    return area_len;
}

// ---------------------------------------------------------------------------
// Short-read-is-EOF detection
// ---------------------------------------------------------------------------
//
// Every directory normally costs two getdents64 calls: one that returns the
// records and one that returns 0 to confirm EOF. The in-tree local
// filesystems (ext2/3/4, btrfs, xfs, tmpfs, f2fs) fill the buffer greedily:
// their readdir stops early only when `dir_emit` fails for lack of space.
// So when a call leaves at least one maximal record's worth of room unused,
// the directory is exhausted and the confirming call can be skipped.
//
// That is not true of FUSE, network and stacked filesystems, which may return
// short batches before EOF. The verdict is therefore gated on the walk root:
// its own filesystem must be whitelisted (fstatfs magic) and no mount of any
// other type may lie below the root's canonical path (/proc/self/mountinfo,
// re-read whenever the kernel reports a mount-table change, so a mount that
// appeared since the last walk -- autofs, sshfs, a container bind -- is
// seen). Escaping the root through `..` or a followed
// symlink is not covered by the mount check; the walkers additionally drop
// trust when a followed symlink crosses a device boundary.

const linux = std.os.linux;

/// Largest getdents64 record: 19-byte header + 255-byte name + NUL, rounded
/// up to 8 bytes.
pub const MAX_RECLEN: usize = 280;

/// True when a getdents64 call that returned `n` bytes into a buffer of
/// `cap` bytes proves EOF on a greedy-fill filesystem: a further record of any
/// size would have fit.
pub inline fn shortReadIsEof(n: usize, cap: usize) bool {
    return n + MAX_RECLEN <= cap;
}

/// fstatfs `f_type` magics of filesystems whose readdir fills greedily.
pub fn fsMagicIsGreedy(magic: u64) bool {
    return switch (magic) {
        0xEF53, // ext2/ext3/ext4
        0x9123683E, // btrfs
        0x58465342, // xfs
        0x01021994, // tmpfs
        0xF2F52010, // f2fs
        => true,
        else => false,
    };
}

/// mountinfo filesystem-type names of the same set.
pub fn fsNameIsGreedy(name: []const u8) bool {
    const greedy = [_][]const u8{ "ext4", "ext3", "ext2", "btrfs", "xfs", "tmpfs", "f2fs" };
    for (greedy) |g| if (mem.eql(u8, name, g)) return true;
    return false;
}

/// Decide whether short getdents64 reads below the open directory `fd` may be
/// taken as EOF. One fstatfs, a mount-table freshness check (fstat + poll,
/// see currentMountTable), plus one readlink of /proc/self/fd/N when the
/// mount table contains non-greedy mounts. Returns false on any doubt.
pub fn trustShortReaddir(fd: linux.fd_t) bool {
    if (envDisabled()) return false;

    var sfs: [256]u8 align(8) = undefined;
    const rc = linux.syscall2(.fstatfs, @as(usize, @bitCast(@as(isize, fd))), @intFromPtr(&sfs));
    if (linux.errno(rc) != .SUCCESS) return false;
    // f_type is the first word of struct statfs (a C long; the magic fits in
    // its low 32 bits on every ABI).
    const f_type = mem.readInt(u64, sfs[0..8], .little) & 0xFFFF_FFFF;
    if (!fsMagicIsGreedy(f_type)) return false;

    mount_lock.lock();
    defer mount_lock.unlock();
    const table = currentMountTable() orelse return false;
    if (table.bad.len == 0) return true;

    // Some mount below the root would be a problem; find the root's canonical
    // path and check whether any of them actually lies under it.
    var link_buf: [32]u8 = undefined;
    const link = std.fmt.bufPrintZ(&link_buf, "/proc/self/fd/{d}", .{fd}) catch return false;
    var path_buf: [4096]u8 = undefined;
    const rl = linux.readlink(link.ptr, &path_buf, path_buf.len);
    const rlen: isize = @bitCast(rl);
    if (rlen <= 0 or rlen >= path_buf.len) return false;
    const path = path_buf[0..@intCast(rlen)];
    if (path[0] != '/') return false; // "(unreachable)" / "(deleted)" forms
    return !table.badMountBelow(path);
}

const MountTable = struct {
    /// /proc/self/mountinfo exactly as last read.
    raw: []u8,
    /// Copy of `raw` that `parseMountInfo` unescaped in place; `bad` slices
    /// into it.
    work: []u8,
    /// Mount points of every mount whose filesystem type is not greedy,
    /// unescaped, as they appear in /proc/self/mountinfo.
    bad: []const []const u8,

    fn badMountBelow(t: *const MountTable, root: []const u8) bool {
        return anyMountBelow(t.bad, root);
    }

    fn deinit(t: *MountTable, gpa: std.mem.Allocator) void {
        gpa.free(t.bad);
        gpa.free(t.work);
        gpa.free(t.raw);
    }
};

/// True when any of `mounts` equals `root` or lies under it.
pub fn anyMountBelow(mounts: []const []const u8, root: []const u8) bool {
    for (mounts) |mp| {
        if (isUnder(mp, root)) return true;
    }
    return false;
}

/// `path` equals `root` or lies under it (component-wise).
fn isUnder(path: []const u8, root: []const u8) bool {
    if (mem.eql(u8, root, "/")) return true;
    if (!mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == '/';
}

/// Minimal run-once guard (std.once is not exported in 0.16): the first
/// caller runs `f`, concurrent callers spin until it has finished. Init is
/// a few microseconds, so spinning is cheaper than a futex here.
fn Once(comptime f: fn () void) type {
    return struct {
        state: std.atomic.Value(u8) = .init(0), // 0 idle, 1 running, 2 done

        fn call(self: *@This()) void {
            if (self.state.load(.acquire) == 2) return;
            if (self.state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
                f();
                self.state.store(2, .release);
                return;
            }
            while (self.state.load(.acquire) != 2) std.atomic.spinLoopHint();
        }
    };
}

/// Spinlock guarding `mount_table` (std.Io.Mutex needs an Io this module
/// does not have). Held for a freshness check (about a microsecond) and,
/// only when the mount table changed, a mountinfo read and parse; probes
/// are one per walk root.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

var mount_lock: SpinLock = .{};
var mount_table: ?MountTable = null;

/// The mount table as of right now. Caller holds `mount_lock`. Null when
/// /proc/self/mountinfo cannot be read: with no table there is no proof, so
/// the caller distrusts.
///
/// Change detection uses the kernel's own notification: a long-lived
/// mountinfo fd reports POLLPRI|POLLERR once per mount-table change of its
/// namespace (`mounts_poll`). The unchanged case is one fstat (the fd is
/// still ours: a caller that closes every fd behind the library's back would
/// otherwise let a recycled number pass as unchanged) plus one poll with
/// zero timeout, no allocation; any event re-reads and reparses the file.
/// The fd is bound to the mount namespace it was opened in, so a probe that
/// finds the process in a different namespace (unshare/setns since the last
/// one) reopens it.
fn currentMountTable() ?*const MountTable {
    const gpa = std.heap.page_allocator;
    if (mount_table != null and mountinfoUnchanged()) return &mount_table.?;
    mount_table_reloads += 1;

    if (mount_table) |*t| {
        t.deinit(gpa);
        mount_table = null;
    }
    if (!openMountinfo()) return null;

    var scratch: [16 * 1024]u8 = undefined;
    const content = readProcFd(gpa, mount_fd, &scratch) orelse return null;
    const raw = if (content.heap) content.bytes else gpa.dupe(u8, content.bytes) catch return null;
    const work = gpa.dupe(u8, raw) catch {
        gpa.free(raw);
        return null;
    };
    const bad = parseMountInfo(gpa, work) catch {
        gpa.free(work);
        gpa.free(raw);
        return null;
    };
    mount_table = .{ .raw = raw, .work = work, .bad = bad };
    return &mount_table.?;
}

var mount_fd: linux.fd_t = -1;
var mount_fd_dev: u64 = 0;
var mount_fd_ino: u64 = 0;
/// nsfs inode of the mount namespace `mount_fd` was opened in.
var mount_fd_ns: u64 = 0;
/// Times the table was (re)read; exposed for tests and diagnostics.
pub var mount_table_reloads: usize = 0;

/// Identity (nsfs inode) of the caller's current mount namespace, 0 when it
/// cannot be determined.
fn currentMountNs() u64 {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, "/proc/self/ns/mnt", 0, .{ .INO = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return 0;
    return stx.ino;
}

fn statFdKey(fd: linux.fd_t, dev: *u64, ino: *u64) bool {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return false;
    dev.* = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor);
    ino.* = stx.ino;
    return true;
}

/// Make `mount_fd` a fresh /proc/self/mountinfo descriptor positioned at 0,
/// recording its identity. A previous fd that is still ours is reused
/// (rewound); one that is not (closed and recycled by the caller) is left
/// alone and replaced.
fn openMountinfo() bool {
    if (mount_fd >= 0) {
        if (mountFdIsOurs()) {
            if (mountFdCurrent()) {
                const off = linux.lseek(mount_fd, 0, linux.SEEK.SET);
                if (linux.errno(off) == .SUCCESS) return true;
            }
            _ = linux.close(mount_fd);
        }
        mount_fd = -1;
    }
    const rc = linux.openat(linux.AT.FDCWD, "/proc/self/mountinfo", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc);
    if (!statFdKey(fd, &mount_fd_dev, &mount_fd_ino)) {
        _ = linux.close(fd);
        return false;
    }
    mount_fd = fd;
    mount_fd_ns = currentMountNs();
    return true;
}

fn mountFdIsOurs() bool {
    var dev: u64 = 0;
    var ino: u64 = 0;
    if (!statFdKey(mount_fd, &dev, &ino)) return false;
    return dev == mount_fd_dev and ino == mount_fd_ino;
}

/// The fd still describes the namespace the caller is in.
fn mountFdCurrent() bool {
    const ns = currentMountNs();
    return ns != 0 and ns == mount_fd_ns;
}

/// True when the mount table has not changed since `mount_fd` was last read
/// (or last polled). False on any doubt.
fn mountinfoUnchanged() bool {
    if (mount_fd < 0 or !mountFdIsOurs() or !mountFdCurrent()) return false;
    var pfd = [1]linux.pollfd{.{ .fd = mount_fd, .events = linux.POLL.PRI, .revents = 0 }};
    const rc = linux.poll(&pfd, 1, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    // POLLIN is always set on this file; only PRI/ERR announce a change.
    return rc == 0 or (pfd[0].revents & (linux.POLL.PRI | linux.POLL.ERR)) == 0;
}

const ProcFile = struct {
    bytes: []u8,
    /// `bytes` is heap-allocated (did not fit the caller's scratch buffer)
    /// and must be freed by the caller.
    heap: bool,
};

/// Whole content of an open procfs file from its current position. Lands in
/// `scratch` when it fits, else in an exactly sized heap buffer. Null on any
/// failure.
fn readProcFd(gpa: std.mem.Allocator, fd: linux.fd_t, scratch: []u8) ?ProcFile {
    var buf: []u8 = scratch;
    var heap = false;
    var len: usize = 0;
    while (true) {
        if (len == buf.len) {
            if (heap) {
                buf = gpa.realloc(buf, buf.len * 2) catch {
                    gpa.free(buf);
                    return null;
                };
            } else {
                const grown = gpa.alloc(u8, buf.len * 2) catch return null;
                @memcpy(grown[0..len], buf[0..len]);
                buf = grown;
                heap = true;
            }
        }
        const r = linux.read(fd, buf.ptr + len, buf.len - len);
        const n: isize = @bitCast(r);
        if (n < 0) {
            if (linux.errno(r) == .INTR) continue;
            if (heap) gpa.free(buf);
            return null;
        }
        if (n == 0) break;
        len += @intCast(n);
    }
    if (!heap) return .{ .bytes = buf[0..len], .heap = false };
    // Exact size, so the slice can be freed as a whole.
    const exact = gpa.realloc(buf, len) catch {
        gpa.free(buf);
        return null;
    };
    return .{ .bytes = exact, .heap = true };
}

/// Collect the (unescaped, in place) mount points of non-greedy mounts.
/// Line format: `id parent maj:min root mountpoint opts [optional...] - fstype source superopts`.
pub fn parseMountInfo(gpa: std.mem.Allocator, content: []u8) ![]const []const u8 {
    var bad: std.ArrayList([]const u8) = .empty;
    errdefer bad.deinit(gpa);

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_const| {
        if (line_const.len == 0) continue;
        // Fields are space-separated; embedded spaces are escaped as \040.
        var fields = mem.splitScalar(u8, line_const, ' ');
        var mountpoint: ?[]const u8 = null;
        var fstype: ?[]const u8 = null;
        var idx: usize = 0;
        var past_sep = false;
        while (fields.next()) |f| : (idx += 1) {
            if (idx == 4) mountpoint = f;
            if (past_sep) {
                fstype = f;
                break;
            }
            if (idx >= 6 and f.len == 1 and f[0] == '-') past_sep = true;
        }
        const mp = mountpoint orelse continue;
        const ft = fstype orelse continue;
        if (fsNameIsGreedy(ft)) continue;
        // Unescape in place: `content` is mutable and shrinking is safe.
        const mp_mut: []u8 = @constCast(mp);
        try bad.append(gpa, unescapeOctal(mp_mut));
    }
    return bad.toOwnedSlice(gpa);
}

fn unescapeOctal(s: []u8) []u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 3 < s.len and isOct(s[i + 1]) and isOct(s[i + 2]) and isOct(s[i + 3])) {
            s[out] = ((s[i + 1] - '0') << 6) | ((s[i + 2] - '0') << 3) | (s[i + 3] - '0');
            i += 4;
        } else {
            s[out] = s[i];
            i += 1;
        }
        out += 1;
    }
    return s[0..out];
}

inline fn isOct(c: u8) bool {
    return c >= '0' and c <= '7';
}

var env_disabled_cached: bool = false;
var env_once: Once(loadEnv) = .{};

fn loadEnv() void {
    // ZLOB_TRUST_SHORT_GETDENTS=0 turns the optimization off for the process.
    // Only reachable with libc: without it a library has no environ.
    if (builtin.link_libc) {
        if (std.c.getenv("ZLOB_TRUST_SHORT_GETDENTS")) |v| {
            env_disabled_cached = v[0] == '0' and v[1] == 0;
        }
    }
}

fn envDisabled() bool {
    env_once.call();
    return env_disabled_cached;
}

// Unit tests live in test/test_walk.zig: tests in a non-root module are not
// collected by `zig build test`.
