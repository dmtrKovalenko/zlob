const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const worker = @import("worker.zig");
const dirent = @import("dirent");

const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;
const EntryKind = types.EntryKind;
const Metadata = types.Metadata;
const MetaMask = types.MetaMask;
const SharedWorkerState = worker.SharedWorkerState;
const Worker = worker.Worker;
const WalkError = types.WalkError;

pub const supported = builtin.os.tag == .linux;
pub const StatxMask = if (supported) linux.STATX else void;

const DT_UNKNOWN: u8 = 0;
const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;
const DT_LNK: u8 = 10;
const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;
const S_IFLNK: u32 = 0o120000;

pub fn scanDir(sh: *SharedWorkerState, w: *Worker, fd: posix.fd_t) WalkError!void {
    if (comptime !supported) unreachable;
    const want_stat = sh.options.meta.any();
    const only_inode = sh.options.meta.toInt() == (MetaMask{ .inode = true }).toInt();

    while (true) {
        // Short by 8 so the word-at-a-time name scan below stays in bounds.
        const rc = linux.getdents64(fd, w.io_buf.ptr, w.io_buf.len - 8);
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
        while (off + dirent.NAME_OFFSET <= len) {
            const base = off;
            const d_ino = mem.readInt(u64, w.io_buf[base + dirent.INO_OFFSET ..][0..8], .little);
            const reclen = mem.readInt(u16, w.io_buf[base + dirent.RECLEN_OFFSET ..][0..2], .little);
            const d_type = w.io_buf[base + dirent.TYPE_OFFSET];
            // Guard against malformed (FUSE) records: a zero reclen would loop
            // forever, a short one inverts the name area below, and an
            // oversized one reads past what the kernel wrote.
            if (reclen < dirent.NAME_OFFSET or base + reclen > len) {
                @branchHint(.unlikely);
                return error.ReadFailed;
            }
            off += reclen;

            const name_ptr: [*:0]const u8 = @ptrCast(w.io_buf.ptr + base + dirent.NAME_OFFSET);
            // The name is NUL-terminated within the record; scan a word at a
            // time. Vectorized scans do not amortize at these lengths.
            const name_area = w.io_buf[base + dirent.NAME_OFFSET .. base + reclen];

            const name_len = dirent.nameLen(name_area.ptr, name_area.len);
            // name byte that doesn't contain NUL byte technically impossible but who knows what to expect from kernel
            if (name_area.len != 0 and name_len == name_area.len) {
                @branchHint(.unlikely);
                return error.ReadFailed;
            }

            const name = name_area[0..name_len];
            if (name.len == 0) continue;
            if (name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) continue;

            var kind: EntryKind = switch (d_type) {
                DT_REG => .file,
                DT_DIR => .directory,
                DT_LNK => .sym_link,
                else => .unknown,
            };

            var meta = Metadata{};
            if (want_stat or d_type == DT_UNKNOWN) {
                if (only_inode and d_type != DT_UNKNOWN) {
                    meta.inode = d_ino;
                    meta.valid.inode = true;
                } else {
                    var stx: linux.Statx = undefined;
                    var mask = sh.statx_mask;
                    if (d_type == DT_UNKNOWN) mask.TYPE = true;
                    const src = linux.statx(fd, name_ptr, linux.AT.SYMLINK_NOFOLLOW, mask, &stx);
                    if (linux.errno(src) == .SUCCESS) {
                        fillMeta(&meta, &stx, sh.options.meta);
                        if (d_type == DT_UNKNOWN and stx.mask.TYPE) {
                            kind = switch (@as(u32, stx.mode) & S_IFMT) {
                                S_IFDIR => .directory,
                                S_IFREG => .file,
                                S_IFLNK => .sym_link,
                                else => .unknown,
                            };
                        }
                    }
                }
            }

            try worker.appendScratch(sh, w, .{ .name = name, .kind = kind, .meta = meta });
        }
    }
}

/// Translate the caller's requested fields into a statx mask, so each entry's
/// statx only asks the kernel for what will actually be read.
pub fn statxMask(want: MetaMask) StatxMask {
    if (comptime !supported) return {};
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

fn fillMeta(meta: *Metadata, stx: *const linux.Statx, want: MetaMask) void {
    if (comptime !supported) unreachable;
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
