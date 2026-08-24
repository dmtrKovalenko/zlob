//! Platform directory scanners. `scanDir` dispatches at comptime to exactly
//! one backend (dead backends are never analyzed). Each scanner reads a whole
//! directory into the worker's scratch arena, fetching metadata only when the
//! caller requested it.
//!
//! - Linux: raw getdents64 into a 64 KiB buffer; statx only when needed
//!   (inode comes free from the dirent).
//! - macOS: getattrlistbulk when metadata is requested (one syscall returns
//!   names AND attributes); otherwise the leaner getdirentries64 path.
//! - Windows: NtQueryDirectoryFile batches carry sizes, all four timestamps
//!   and the file id, so metadata is free (see scan_windows.zig).
//! - Fallback: std.Io.Dir + per-entry statFile.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const worker = @import("worker.zig");

const linux = @import("scan_linux.zig");
const darwin = @import("scan_darwin.zig");
const winows = @import("scan_windows.zig");

const posix = std.posix;
const backend = types.backend;
const is_posix_backend = types.is_posix_backend;
const Handle = types.Handle;
const EntryKind = types.EntryKind;
const Metadata = types.Metadata;
const MetaMask = types.MetaMask;
const SharedWorkerState = worker.SharedWorkerState;
const Worker = worker.Worker;
const closeFd = types.closeFd;
const WalkError = types.WalkError;
const NAME_MAX = types.NAME_MAX;
const NAME_BUF = types.NAME_BUF_Z_LENGTH;

pub fn scanDir(sh: *SharedWorkerState, w: *Worker, handle: Handle) WalkError!void {
    if (backend == .linux_getdents) {
        return linux.scanDir(sh, w, handle);
    } else if (backend == .darwin_bulk) {
        return scanDarwin(sh, w, handle);
    } else if (backend == .windows_ntdll) {
        return scanWindows(sh, w, handle);
    } else {
        return scanStdFs(sh, w, handle);
    }
}

// ---------------------------------------------------------------------------
// macOS: getattrlistbulk (with metadata) / getdirentries64 (without)
// ---------------------------------------------------------------------------

fn scanDarwin(sh: *SharedWorkerState, w: *Worker, fd: posix.fd_t) WalkError!void {
    if (comptime !darwin.supported) unreachable;
    // if we don't need meta use getdirentries64 backend
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
        try worker.appendScratch(sh, w, entry);
    }
}

fn scanDarwinNoMeta(sh: *SharedWorkerState, w: *Worker, fd: posix.fd_t) WalkError!void {
    if (comptime !darwin.supported) unreachable;
    var it = darwin.DirEntries.init(fd, w.io_buf);
    while (it.next() catch return error.ReadFailed) |entry| {
        var kind = entry.kind;
        // Only filesystems that withhold d_type force a stat; misreading a
        // directory as a file would silently drop a whole subtree.
        if (kind == .unknown) {
            kind = statKind(fd, entry.name) orelse .unknown;
        }
        try worker.appendScratchNoMeta(sh, w, entry.name, kind);
    }
}

/// readdir+fstatat fallback for filesystems without getattrlistbulk support.
fn scanPosixFallback(sh: *SharedWorkerState, w: *Worker, fd: posix.fd_t) WalkError!void {
    if (comptime !(is_posix_backend and builtin.os.tag != .linux)) unreachable;
    // fdopendir takes ownership of the fd; iterate on a dup so the caller's fd
    // stays valid for openat() of children.
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
            var name_z: [NAME_BUF:0]u8 = undefined;
            if (name.len <= NAME_MAX) {
                @memcpy(name_z[0..name.len], name);
                name_z[name.len] = 0;
                var st: std.c.Stat = undefined;
                if (std.c.fstatat(fd, name_z[0..name.len :0], &st, std.c.AT.SYMLINK_NOFOLLOW) == 0) {
                    fillMetaFromCStat(&meta, &st, sh.options.meta);
                    if (kind == .unknown) kind = modeToKind(@intCast(st.mode));
                }
            }
        }
        try worker.appendScratch(sh, w, .{ .name = name, .kind = kind, .meta = meta });
    }
}

/// fstatat just to recover the kind of a DT_UNKNOWN entry.
fn statKind(fd: posix.fd_t, name: []const u8) ?EntryKind {
    if (name.len > NAME_MAX) return null;
    var name_z: [NAME_BUF:0]u8 = undefined;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(fd, name_z[0..name.len :0], &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return modeToKind(@intCast(st.mode));
}

fn modeToKind(mode: u32) EntryKind {
    return switch (mode & 0o170000) {
        0o040000 => .directory,
        0o100000 => .file,
        0o120000 => .sym_link,
        else => .unknown,
    };
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

// ---------------------------------------------------------------------------
// Windows: NtQueryDirectoryFile
// ---------------------------------------------------------------------------

fn scanWindows(sh: *SharedWorkerState, w: *Worker, handle: std.os.windows.HANDLE) WalkError!void {
    if (comptime !winows.supported) unreachable;
    var scanner = winows.Scanner.init(handle, w.io_buf, sh.options.meta);
    while (true) {
        const raw = scanner.next() catch |err| switch (err) {
            error.PermissionDenied => return error.PermissionDenied,
            error.ReadFailed => return error.ReadFailed,
        };
        const entry = raw orelse return;
        try worker.appendScratch(sh, w, entry);
    }
}

// ---------------------------------------------------------------------------
// Portable fallback: std.Io.Dir
// ---------------------------------------------------------------------------

fn scanStdFs(sh: *SharedWorkerState, w: *Worker, handle: Handle) WalkError!void {
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
            try worker.appendScratch(sh, w, .{ .name = name, .kind = entry.kind, .meta = meta });
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
