//! Windows bulk directory scanner built directly on ntdll.
//!
//! NtQueryDirectoryFile returns a whole batch of entries per syscall and —
//! unlike FindFirstFile/readdir-style APIs — each record already carries the
//! interesting metadata (sizes, all four timestamps, attributes, and the
//! 64-bit file id when requested). That makes metadata effectively FREE on
//! Windows: no per-entry stat ever happens.
//!
//! Two information classes are used depending on the requested mask:
//! - FileBothDirectoryInformation when the file id (inode) is not needed
//! - FileIdBothDirectoryInformation when it is
//!
//! Directory handles are opened with NtCreateFile relative to the parent
//! handle (OBJECT_ATTRIBUTES.RootDirectory) — the NT-native openat().

const std = @import("std");
const builtin = @import("builtin");
const walk = @import("types.zig");

pub const supported = builtin.os.tag == .windows;

const w = std.os.windows;

/// FileIdBothDirectoryInformation (class 37) record layout — not in std.
pub const FILE_ID_BOTH_DIR_INFORMATION = extern struct {
    NextEntryOffset: w.ULONG,
    FileIndex: w.ULONG,
    CreationTime: i64,
    LastAccessTime: i64,
    LastWriteTime: i64,
    ChangeTime: i64,
    EndOfFile: i64,
    AllocationSize: i64,
    FileAttributes: w.FILE.ATTRIBUTE,
    FileNameLength: w.ULONG,
    EaSize: w.ULONG,
    ShortNameLength: u8,
    ShortName: [12]w.WCHAR,
    FileId: i64,
    FileName: [1]w.WCHAR,
};

/// Difference between the Windows epoch (1601-01-01) and the Unix epoch
/// (1970-01-01) in 100ns intervals.
const windows_epoch_offset: i64 = 116444736000000000;

// Name-surrogate reparse tags — the only reparse points that behave like
// links (matches what Rust's std considers a symlink). Other tags (cloud
// placeholders, dedup, appexeclinks, ...) are materially regular files/dirs.
const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA0000003;
const IO_REPARSE_TAG_SYMLINK: u32 = 0xA000000C;

inline fn filetimeToUnixNs(ft: i64) i64 {
    return (ft -% windows_epoch_offset) *% 100;
}

pub const ScanError = error{ ReadFailed, PermissionDenied };

pub const Scanner = if (!supported) struct {} else struct {
    handle: w.HANDLE,
    buf: []align(8) u8,
    mask: walk.MetaMask,
    /// Whether to use the Id variant of the information class (file id wanted).
    use_id: bool,
    index: usize = 0,
    end: usize = 0,
    restart: bool = true,
    /// WTF-8 conversion scratch for the current entry name (max NT component
    /// is 255 UTF-16 units -> at most 3 bytes each in WTF-8).
    name_buf: [255 * 3]u8 = undefined,

    pub fn init(handle: w.HANDLE, buf: []align(8) u8, mask: walk.MetaMask) Scanner {
        return .{
            .handle = handle,
            .buf = buf,
            .mask = mask,
            .use_id = mask.inode,
        };
    }

    fn refill(self: *Scanner) ScanError!bool {
        var iosb: w.IO_STATUS_BLOCK = undefined;
        const class: w.FILE.INFORMATION_CLASS = if (self.use_id) .IdBothDirectory else .BothDirectory;
        const rc = w.ntdll.NtQueryDirectoryFile(
            self.handle,
            null,
            null,
            null,
            &iosb,
            self.buf.ptr,
            std.math.lossyCast(w.ULONG, self.buf.len),
            class,
            .FALSE,
            null,
            .fromBool(self.restart),
        );
        self.restart = false;
        switch (rc) {
            .SUCCESS => {},
            .NO_MORE_FILES => return false,
            .ACCESS_DENIED => return error.PermissionDenied,
            else => return error.ReadFailed,
        }
        if (iosb.Information == 0) return false;
        self.index = 0;
        self.end = iosb.Information;
        return true;
    }

    /// Returns the next entry or null when the directory is exhausted.
    /// `RawEntry.name` points into the scanner's scratch buffer and is only
    /// valid until the next call.
    pub fn next(self: *Scanner) ScanError!?walk.RawEntry {
        while (true) {
            if (self.index >= self.end) {
                if (!try self.refill()) return null;
            }
            const entry = if (self.use_id)
                try self.parseOne(FILE_ID_BOTH_DIR_INFORMATION)
            else
                try self.parseOne(w.FILE_BOTH_DIR_INFORMATION);
            if (entry) |e| return e;
        }
    }

    fn parseOne(self: *Scanner, comptime T: type) ScanError!?walk.RawEntry {
        // Bounds-check the record before touching it: the kernel guarantees
        // well-formed batches, but user-mode filesystem drivers (WinFsp
        // et al.) have shipped bugs here and the cost is two compares.
        const rec_start = self.index;
        const name_off = @offsetOf(T, "FileName");
        if (rec_start + name_off > self.end) return error.ReadFailed;
        // The official docs guarantee proper alignment but faulty VM /
        // sandboxing layers have been seen to break it; match std and assume
        // only 2-byte alignment.
        const info: *align(2) T = @ptrCast(@alignCast(&self.buf[rec_start]));
        if (rec_start + name_off + info.FileNameLength > self.end) return error.ReadFailed;
        if (info.NextEntryOffset != 0) {
            self.index = rec_start + info.NextEntryOffset;
        } else {
            self.index = self.end;
        }

        const name_w = @as([*]align(2) u16, @ptrCast(&info.FileName))[0 .. info.FileNameLength / 2];
        if (name_w.len == 0) return null;
        if (std.mem.eql(u16, name_w, &[_]u16{'.'}) or
            std.mem.eql(u16, name_w, &[_]u16{ '.', '.' })) return null;

        const name_len = std.unicode.wtf16LeToWtf8(&self.name_buf, name_w);

        const attrs = info.FileAttributes;
        const kind: walk.EntryKind = if (attrs.REPARSE_POINT) blk: {
            // For directory-enumeration info classes EaSize doubles as the
            // reparse tag when REPARSE_POINT is set (documented for
            // FileBothDirectoryInformation and friends). Only name
            // surrogates are links; placeholders/dedup files keep their
            // real kind.
            const tag: u32 = info.EaSize;
            if (tag == IO_REPARSE_TAG_SYMLINK or tag == IO_REPARSE_TAG_MOUNT_POINT)
                break :blk .sym_link;
            break :blk if (attrs.DIRECTORY) .directory else .file;
        } else if (attrs.DIRECTORY)
            .directory
        else
            .file;

        var meta = walk.Metadata{};
        const mask = self.mask;
        if (mask.size and kind == .file) {
            meta.size = @intCast(@max(info.EndOfFile, 0));
            meta.valid.size = true;
        }
        if (mask.mtime) {
            meta.mtime_ns = filetimeToUnixNs(info.LastWriteTime);
            meta.valid.mtime = true;
        }
        if (mask.atime) {
            meta.atime_ns = filetimeToUnixNs(info.LastAccessTime);
            meta.valid.atime = true;
        }
        if (mask.ctime) {
            meta.ctime_ns = filetimeToUnixNs(info.ChangeTime);
            meta.valid.ctime = true;
        }
        if (mask.btime) {
            meta.btime_ns = filetimeToUnixNs(info.CreationTime);
            meta.valid.btime = true;
        }
        if (mask.inode and @hasField(T, "FileId")) {
            meta.inode = @bitCast(info.FileId);
            meta.valid.inode = true;
        }
        // nlink / mode / uid / gid have no cheap Windows equivalent — their
        // valid bits stay unset.

        return .{
            .name = self.name_buf[0..name_len],
            .kind = kind,
            .meta = meta,
        };
    }
};

/// Opens a child directory by (single-component) name relative to a parent
/// directory handle. Never follows reparse points.
pub fn openChildDir(parent: w.HANDLE, name: []const u8) !w.HANDLE {
    if (!supported) unreachable;
    var name_w: [255]u16 = undefined;
    const name_w_len = std.unicode.wtf8ToWtf16Le(&name_w, name) catch return error.NameTooLong;

    var handle: w.HANDLE = undefined;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const rc = w.ntdll.NtCreateFile(
        &handle,
        .{
            .SPECIFIC = .{ .FILE_DIRECTORY = .{
                .LIST = true,
                .READ_ATTRIBUTES = true,
                .TRAVERSE = true,
            } },
            .STANDARD = .{ .SYNCHRONIZE = true },
        },
        &.{
            .RootDirectory = parent,
            .ObjectName = @constCast(&w.UNICODE_STRING.init(name_w[0..name_w_len])),
        },
        &iosb,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{
            .DIRECTORY_FILE = true,
            .IO = .SYNCHRONOUS_NONALERT,
            .OPEN_FOR_BACKUP_INTENT = true,
            .OPEN_REPARSE_POINT = true,
        },
        null,
        0,
    );
    return switch (rc) {
        .SUCCESS => handle,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .OBJECT_NAME_INVALID => error.BadPathName,
        .NOT_A_DIRECTORY => error.NotDir,
        .ACCESS_DENIED, .SHARING_VIOLATION => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// Reads a (small) file by name relative to an open directory handle.
/// Returns null when it can't be opened/read — callers treat it as absent.
pub fn readSmallFileAt(
    gpa: std.mem.Allocator,
    dir: w.HANDLE,
    name: []const u8,
    max_size: usize,
) ?[]u8 {
    if (!supported) unreachable;
    var name_w: [255]u16 = undefined;
    const name_w_len = std.unicode.wtf8ToWtf16Le(&name_w, name) catch return null;

    var handle: w.HANDLE = undefined;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const rc = w.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .GENERIC = .{ .READ = true },
        },
        &.{
            .RootDirectory = dir,
            .ObjectName = @constCast(&w.UNICODE_STRING.init(name_w[0..name_w_len])),
        },
        &iosb,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{
            .IO = .SYNCHRONOUS_NONALERT,
            .NON_DIRECTORY_FILE = true,
        },
        null,
        0,
    );
    if (rc != .SUCCESS) return null;
    defer w.CloseHandle(handle);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    list.ensureTotalCapacity(gpa, 8192) catch return null;
    while (true) {
        const spare = list.unusedCapacitySlice();
        if (spare.len == 0) {
            if (list.items.len >= max_size) break;
            list.ensureUnusedCapacity(gpa, list.items.len) catch return null;
            continue;
        }
        var read_iosb: w.IO_STATUS_BLOCK = undefined;
        const read_rc = w.ntdll.NtReadFile(
            handle,
            null,
            null,
            null,
            &read_iosb,
            spare.ptr,
            std.math.lossyCast(w.ULONG, spare.len),
            null,
            null,
        );
        switch (read_rc) {
            .SUCCESS => {
                if (read_iosb.Information == 0) break;
                list.items.len += read_iosb.Information;
            },
            .END_OF_FILE => break,
            else => return null,
        }
    }
    return list.toOwnedSlice(gpa) catch null;
}
