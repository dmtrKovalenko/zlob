//! macOS bulk directory scanner built on getattrlistbulk(2).
//!
//! One syscall returns a whole batch of directory entries WITH the requested
//! metadata (size, times, ids, mode, ...) — no per-entry stat. The attribute
//! mask is built at runtime from walk.MetaMask so callers only pay for the
//! attributes they ask for.
//!
//! Attributes are returned packed, 4-byte aligned, in the canonical order
//! documented in getattrlist(2): ATTR_CMN_RETURNED_ATTRS first, then
//! ATTR_CMN_ERROR, then the remaining common attributes in ascending bit
//! order, then the dir group (for directories) or file group (for anything
//! else). We do not pass FSOPT_PACK_INVAL_ATTRS: the per-entry returned set
//! is the source of truth for which attributes are present, which also
//! handles filesystems that don't support a given attribute.

const std = @import("std");
const builtin = @import("builtin");
const walk = @import("walk.zig");

pub const supported = builtin.os.tag == .macos and builtin.link_libc;

pub const AttrList = extern struct {
    bitmapcount: u16,
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};

pub const AttributeSet = extern struct {
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
};

const ATTR_BIT_MAP_COUNT: u16 = 5;

// <sys/attr.h> common attribute bits
const ATTR_CMN_NAME: u32 = 0x00000001;
const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
const ATTR_CMN_CRTIME: u32 = 0x00000200;
const ATTR_CMN_MODTIME: u32 = 0x00000400;
const ATTR_CMN_CHGTIME: u32 = 0x00000800;
const ATTR_CMN_ACCTIME: u32 = 0x00001000;
const ATTR_CMN_OWNERID: u32 = 0x00008000;
const ATTR_CMN_GRPID: u32 = 0x00010000;
const ATTR_CMN_ACCESSMASK: u32 = 0x00020000;
const ATTR_CMN_FILEID: u32 = 0x02000000;
const ATTR_CMN_ERROR: u32 = 0x20000000;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;

const ATTR_DIR_LINKCOUNT: u32 = 0x00000001;

const ATTR_FILE_LINKCOUNT: u32 = 0x00000001;
const ATTR_FILE_DATALENGTH: u32 = 0x00000200;

const FSOPT_NOFOLLOW: u64 = 0x00000001;

// <sys/vnode.h> object types
const VREG: u32 = 1;
const VDIR: u32 = 2;
const VLNK: u32 = 5;

const Timespec = extern struct { sec: i64, nsec: i64 };
const AttrRef = extern struct { off: i32, len: u32 };

extern "c" fn getattrlistbulk(
    dirfd: c_int,
    alist: *const AttrList,
    attrbuf: *anyopaque,
    bufsize: usize,
    options: u64,
) c_int;

/// Raw 64-bit-inode directory read. This is the syscall wrapper `readdir`
/// itself dispatches to under 64-bit inodes (the public `getdirentries`
/// deliberately link-errors there). Calling it directly on the directory fd
/// avoids the `dup`/`fstat`/`fstatfs`/`fcntl`/`closedir` overhead that
/// `fdopendir` pays per directory — roughly four extra syscalls each.
extern "c" fn __getdirentries64(fd: c_int, buf: [*]u8, bufsize: usize, basep: *u64) isize;

/// macOS `struct dirent` (64-bit inode): ino(8) seekoff(8) reclen(2)
/// namlen(2) type(1) name[]. The name begins at byte 21 of each record.
pub const DIRENT_TYPE_OFF = 20;
pub const DIRENT_NAME_OFF = 21;

pub const DType = struct {
    pub const UNKNOWN: u8 = 0;
    pub const DIR: u8 = 4;
    pub const REG: u8 = 8;
    pub const LNK: u8 = 10;
};

/// One getdirentries64 batch. `name`s point into `buf` and are valid until
/// the next `refill`.
pub const DirEntries = if (!supported) struct {} else struct {
    fd: c_int,
    buf: []align(8) u8,
    len: usize = 0,
    pos: usize = 0,
    basep: u64 = 0,

    pub const Entry = struct { name: []const u8, kind: walk.EntryKind };

    pub fn init(fd: c_int, buf: []align(8) u8) DirEntries {
        return .{ .fd = fd, .buf = buf };
    }

    pub const Error = error{ReadFailed};

    fn refill(self: *DirEntries) Error!bool {
        while (true) {
            const r = __getdirentries64(self.fd, self.buf.ptr, self.buf.len, &self.basep);
            if (r < 0) {
                if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
                return error.ReadFailed;
            }
            if (r == 0) return false;
            self.len = @intCast(r);
            self.pos = 0;
            return true;
        }
    }

    pub fn next(self: *DirEntries) Error!?Entry {
        while (true) {
            if (self.pos >= self.len) {
                if (!try self.refill()) return null;
            }
            const rec = self.pos;
            if (rec + DIRENT_NAME_OFF > self.len) return error.ReadFailed;
            const reclen = readUnaligned(u16, self.buf, rec + 16);
            const namlen = readUnaligned(u16, self.buf, rec + 18);
            const d_type = self.buf[rec + DIRENT_TYPE_OFF];
            // A zero reclen would spin forever; only a malformed fs yields one.
            if (reclen < DIRENT_NAME_OFF or rec + reclen > self.len) return error.ReadFailed;
            self.pos = rec + reclen;

            const name_start = rec + DIRENT_NAME_OFF;
            if (name_start + namlen > self.len) return error.ReadFailed;
            const name = self.buf[name_start .. name_start + namlen];
            if (name.len == 0) continue;
            if (name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) continue;

            const kind: walk.EntryKind = switch (d_type) {
                DType.REG => .file,
                DType.DIR => .directory,
                DType.LNK => .sym_link,
                else => .unknown,
            };
            return .{ .name = name, .kind = kind };
        }
    }
};

inline fn readUnaligned(comptime T: type, buf: []const u8, pos: usize) T {
    var v: T = undefined;
    @memcpy(@as([*]u8, @ptrCast(&v))[0..@sizeOf(T)], buf[pos..][0..@sizeOf(T)]);
    return v;
}

inline fn tsToNs(ts: Timespec) i64 {
    return ts.sec *% std.time.ns_per_s +% ts.nsec;
}

pub const ScanError = error{
    /// Filesystem does not support getattrlistbulk — caller must fall back
    /// to readdir+fstatat.
    Unsupported,
    PermissionDenied,
    ReadFailed,
};

/// Streaming scanner over one directory fd. Names returned by `next()` point
/// into `buf` and are invalidated by the next kernel refill — callers must
/// copy them out before draining the batch (the walker copies into its
/// per-directory scratch arena).
pub const BulkScanner = if (!supported) struct {} else struct {
    fd: std.c.fd_t,
    buf: []align(8) u8,
    alist: AttrList,
    mask: walk.MetaMask,
    /// Entries remaining in the current batch.
    remaining: u32 = 0,
    pos: usize = 0,
    /// True once any batch was successfully fetched. EINVAL on the *first*
    /// call means "unsupported filesystem"; later it would be a real error.
    primed: bool = false,

    pub fn init(fd: std.c.fd_t, buf: []align(8) u8, mask: walk.MetaMask) BulkScanner {
        // TODO unify the mask so we do not need to recreate it & make the mask
        var common: u32 = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE;
        if (mask.btime) common |= ATTR_CMN_CRTIME;
        if (mask.mtime) common |= ATTR_CMN_MODTIME;
        if (mask.ctime) common |= ATTR_CMN_CHGTIME;
        if (mask.atime) common |= ATTR_CMN_ACCTIME;
        if (mask.uid) common |= ATTR_CMN_OWNERID;
        if (mask.gid) common |= ATTR_CMN_GRPID;
        if (mask.mode) common |= ATTR_CMN_ACCESSMASK;
        if (mask.inode) common |= ATTR_CMN_FILEID;

        var dir: u32 = 0;
        if (mask.nlink) dir |= ATTR_DIR_LINKCOUNT;

        var file: u32 = 0;
        if (mask.nlink) file |= ATTR_FILE_LINKCOUNT;
        if (mask.size) file |= ATTR_FILE_DATALENGTH;

        return .{
            .fd = fd,
            .buf = buf,
            .mask = mask,
            .alist = .{
                .bitmapcount = ATTR_BIT_MAP_COUNT,
                .commonattr = common,
                .dirattr = dir,
                .fileattr = file,
            },
        };
    }

    fn refill(self: *BulkScanner) ScanError!bool {
        while (true) {
            const n = getattrlistbulk(self.fd, &self.alist, self.buf.ptr, self.buf.len, FSOPT_NOFOLLOW);
            if (n < 0) {
                const e = std.c._errno().*;
                switch (@as(std.c.E, @enumFromInt(e))) {
                    .INTR => continue,
                    .INVAL, .OPNOTSUPP => return if (self.primed) error.ReadFailed else error.Unsupported,
                    .ACCES, .PERM => return error.PermissionDenied,
                    else => return error.ReadFailed,
                }
            }
            if (n == 0) return false;
            self.primed = true;
            self.remaining = @intCast(n);
            self.pos = 0;
            return true;
        }
    }

    /// Returns the next entry, or null when the directory is exhausted.
    /// "." and ".." are never returned by getattrlistbulk.
    pub fn next(self: *BulkScanner) ScanError!?walk.RawEntry {
        outer: while (true) {
            if (self.remaining == 0) {
                if (!try self.refill()) return null;
            }

            const rec_start = self.pos;
            if (rec_start + 4 > self.buf.len) return error.ReadFailed;
            const reclen = readUnaligned(u32, self.buf, rec_start);
            if (reclen < 4 or rec_start + reclen > self.buf.len) return error.ReadFailed;
            self.pos = rec_start + reclen;
            self.remaining -= 1;

            var p = rec_start + 4;
            const ret = readUnaligned(AttributeSet, self.buf, p);
            p += @sizeOf(AttributeSet);

            if (ret.commonattr & ATTR_CMN_ERROR != 0) {
                const entry_err = readUnaligned(u32, self.buf, p);
                p += 4;
                // Entry-level error (e.g. dataless file fault): skip it.
                if (entry_err != 0) continue :outer;
            }

            var entry = walk.RawEntry{ .name = &.{}, .kind = .unknown, .meta = .{} };

            if (ret.commonattr & ATTR_CMN_NAME != 0) {
                const ref = readUnaligned(AttrRef, self.buf, p);
                const name_start: usize = if (ref.off >= 0)
                    p + @as(usize, @intCast(ref.off))
                else blk: {
                    const back: usize = @intCast(-ref.off);
                    if (back > p) return error.ReadFailed;
                    break :blk p - back;
                };
                // ref.len includes the trailing NUL.
                if (ref.len == 0 or name_start + ref.len > self.buf.len) return error.ReadFailed;
                entry.name = self.buf[name_start .. name_start + ref.len - 1];
                p += @sizeOf(AttrRef);
            }

            if (ret.commonattr & ATTR_CMN_OBJTYPE != 0) {
                entry.kind = switch (readUnaligned(u32, self.buf, p)) {
                    VREG => .file,
                    VDIR => .directory,
                    VLNK => .sym_link,
                    else => .unknown,
                };
                p += 4;
            }

            if (ret.commonattr & ATTR_CMN_CRTIME != 0) {
                entry.meta.btime_ns = tsToNs(readUnaligned(Timespec, self.buf, p));
                entry.meta.valid.btime = true;
                p += @sizeOf(Timespec);
            }
            if (ret.commonattr & ATTR_CMN_MODTIME != 0) {
                entry.meta.mtime_ns = tsToNs(readUnaligned(Timespec, self.buf, p));
                entry.meta.valid.mtime = true;
                p += @sizeOf(Timespec);
            }
            if (ret.commonattr & ATTR_CMN_CHGTIME != 0) {
                entry.meta.ctime_ns = tsToNs(readUnaligned(Timespec, self.buf, p));
                entry.meta.valid.ctime = true;
                p += @sizeOf(Timespec);
            }
            if (ret.commonattr & ATTR_CMN_ACCTIME != 0) {
                entry.meta.atime_ns = tsToNs(readUnaligned(Timespec, self.buf, p));
                entry.meta.valid.atime = true;
                p += @sizeOf(Timespec);
            }
            if (ret.commonattr & ATTR_CMN_OWNERID != 0) {
                entry.meta.uid = readUnaligned(u32, self.buf, p);
                entry.meta.valid.uid = true;
                p += 4;
            }
            if (ret.commonattr & ATTR_CMN_GRPID != 0) {
                entry.meta.gid = readUnaligned(u32, self.buf, p);
                entry.meta.valid.gid = true;
                p += 4;
            }
            if (ret.commonattr & ATTR_CMN_ACCESSMASK != 0) {
                entry.meta.mode = readUnaligned(u32, self.buf, p) & 0o7777;
                entry.meta.valid.mode = true;
                p += 4;
            }
            if (ret.commonattr & ATTR_CMN_FILEID != 0) {
                entry.meta.inode = readUnaligned(u64, self.buf, p);
                entry.meta.valid.inode = true;
                p += 8;
            }

            if (entry.kind == .directory) {
                if (ret.dirattr & ATTR_DIR_LINKCOUNT != 0) {
                    entry.meta.nlink = readUnaligned(u32, self.buf, p);
                    entry.meta.valid.nlink = true;
                    p += 4;
                }
            } else {
                if (ret.fileattr & ATTR_FILE_LINKCOUNT != 0) {
                    entry.meta.nlink = readUnaligned(u32, self.buf, p);
                    entry.meta.valid.nlink = true;
                    p += 4;
                }
                if (ret.fileattr & ATTR_FILE_DATALENGTH != 0) {
                    entry.meta.size = readUnaligned(u64, self.buf, p);
                    entry.meta.valid.size = true;
                    p += 8;
                }
            }

            if (entry.name.len == 0) continue :outer;
            return entry;
        }
    }
};
