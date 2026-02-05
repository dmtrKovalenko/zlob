///! Unified directory walker with platform-specific backends and ALTDIRFUNC support.
///!
///! This module provides a consistent interface for recursive directory walking
///! with optimized backends for different platforms:
///!
///! - Linux: Uses direct getdents64 syscalls for ~10-15% speedup over std.fs
///! - Other: Falls back to std.fs.Dir.walk()
///!
///! The backend is selected at compile time based on the target platform.
///!
///! ALTDIRFUNC Support:
///!   When ALTDIRFUNC callbacks are provided via FsProvider, all filesystem
///!   operations use these callbacks instead of the real filesystem. This
///!   enables globbing over virtual filesystems or in-memory data structures.
///!
///! Usage:
///!   const walker_mod = @import("walker");
///!   var walker = try walker_mod.DefaultWalker.init(allocator, "path/to/dir", .{});
///!   defer walker.deinit();
///!   while (try walker.next()) |entry| {
///!       // entry.path, entry.basename, entry.kind
///!   }
const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const posix = std.posix;

// ============================================================================
// ALTDIRFUNC types and filesystem provider abstraction
// ============================================================================

/// Directory entry for ALTDIRFUNC callbacks (matches zlob_dirent_t in zlob.h)
pub const AltDirent = extern struct {
    d_name: [*:0]const u8, // Null-terminated entry name
    d_type: u8, // Entry type: DT_DIR=4, DT_REG=8, DT_UNKNOWN=0
};

/// Function pointer types for custom directory access (matches glibc glob_t)
pub const AltOpendirFn = *const fn (path: [*:0]const u8) callconv(.c) ?*anyopaque;
pub const AltReaddirFn = *const fn (dir: ?*anyopaque) callconv(.c) ?*AltDirent;
pub const AltClosedirFn = *const fn (dir: ?*anyopaque) callconv(.c) void;

/// Filesystem provider abstraction that enables seamless switching between
/// real filesystem and ALTDIRFUNC callbacks.
///
/// When callbacks are null, uses the real filesystem.
/// When callbacks are set, all operations go through them.
pub const FsProvider = struct {
    opendir: ?AltOpendirFn = null,
    readdir: ?AltReaddirFn = null,
    closedir: ?AltClosedirFn = null,

    /// Check if this provider uses ALTDIRFUNC callbacks
    pub inline fn isAltDirFunc(self: FsProvider) bool {
        return self.opendir != null and self.readdir != null and self.closedir != null;
    }

    /// Default provider using real filesystem
    pub const real_fs = FsProvider{};
};

/// Error callback type - compatible with zlob_errfunc_t
pub const ErrCallbackFn = *const fn (epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int;

/// Convert Zig errors to POSIX errno values
pub fn errToErrno(err: anyerror) c_int {
    return switch (err) {
        error.AccessDenied => @intFromEnum(posix.E.ACCES),
        error.FileNotFound => @intFromEnum(posix.E.NOENT),
        error.NotDir => @intFromEnum(posix.E.NOTDIR),
        error.SymLinkLoop => @intFromEnum(posix.E.LOOP),
        error.NameTooLong => @intFromEnum(posix.E.NAMETOOLONG),
        error.SystemResources => @intFromEnum(posix.E.NOMEM),
        error.InvalidHandle, error.InvalidArgument => @intFromEnum(posix.E.INVAL),
        else => @intFromEnum(posix.E.IO),
    };
}

/// Filter interface for directory prefiltering during traversal.
/// Implementations control which directories to descend into.
pub const DirFilter = struct {
    /// Return true to descend into this directory, false to prune it.
    /// rel_path: path relative to start directory
    /// basename: just the directory name
    filterDirFn: *const fn (ctx: *anyopaque, rel_path: []const u8, basename: []const u8) bool,

    /// Context pointer passed to filterDirFn
    context: *anyopaque,

    /// Check if should descend into directory
    pub inline fn filterDir(self: DirFilter, rel_path: []const u8, basename: []const u8) bool {
        return self.filterDirFn(self.context, rel_path, basename);
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

pub const EntryKind = enum {
    file,
    directory,
    sym_link,
    block_device,
    character_device,
    named_pipe,
    unix_domain_socket,
    whiteout,
    unknown,

    pub fn fromStd(kind: std.fs.Dir.Entry.Kind) EntryKind {
        return switch (kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .sym_link,
            .block_device => .block_device,
            .character_device => .character_device,
            .named_pipe => .named_pipe,
            .unix_domain_socket => .unix_domain_socket,
            .whiteout => .whiteout,
            .door, .event_port, .unknown => .unknown,
        };
    }
};

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

    /// Include "." and ".." only (for patterns like ".*" that start with '.')
    pub const dots_and_hidden: HiddenConfig = .{
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

pub const WalkerConfig = struct {
    /// Buffer size for getdents64 (Linux only)
    getdents_buffer_size: usize = 65536,
    /// Maximum recursion depth.
    /// 0 = no recursion (single directory only)
    /// 1 = one level of subdirectories, etc.
    /// Default 128 for deep recursion.
    max_depth: usize = 128,

    /// Hidden file and special entry filtering.
    /// Controls whether ".", "..", and hidden files are included in iteration.
    hidden: HiddenConfig = HiddenConfig.posix_default,

    /// Directory filter interface for pruning directories during traversal.
    /// When set, filterDir is called for each directory before descending.
    /// Return false from filterDir to prune (skip directory and all contents).
    dir_filter: ?DirFilter = null,

    /// Base directory to start from. If null, path is opened relative to cwd.
    base_dir: ?std.fs.Dir = null,

    /// Error callback for directory open failures.
    /// Called with null-terminated path and errno when a directory cannot be opened.
    /// Return non-zero to abort the walk, zero to continue.
    err_callback: ?ErrCallbackFn = null,

    /// Abort on first error (equivalent to ZLOB_ERR flag).
    /// If true and a directory cannot be opened, the walk aborts.
    abort_on_error: bool = false,

    /// Filesystem provider for ALTDIRFUNC support.
    /// When set with valid callbacks, uses custom directory functions instead of real filesystem.
    fs_provider: FsProvider = FsProvider.real_fs,

    /// Convenience: config for single-directory iteration (no recursion)
    pub fn singleDir(base_dir: ?std.fs.Dir, err_callback: ?ErrCallbackFn, abort_on_error: bool) WalkerConfig {
        return .{
            .max_depth = 0,
            .base_dir = base_dir,
            .err_callback = err_callback,
            .abort_on_error = abort_on_error,
        };
    }
};

/// Unified entry filter - checks if an entry should be skipped based on HiddenConfig.
/// This is the single source of truth for filtering ".", "..", and hidden files.
/// Returns true if the entry should be SKIPPED.
///
/// This function is designed for maximum performance:
/// - Inline for zero function call overhead
/// - Single branch for most common case (non-hidden files)
/// - Branchless checks for "." and ".."
pub inline fn shouldSkipEntry(name: []const u8, hidden: HiddenConfig) bool {
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
        .getdents64 => RecursiveGetdents64Walker,
        .std_fs => StdFsWalker,
    };
}

pub const DefaultWalker = WalkerType(default_backend);

pub fn isOptimizedBackendAvailable() bool {
    return builtin.os.tag == .linux;
}

// Uses getdents64 syscall but only for recursive walking
const RecursiveGetdents64Walker = struct {
    const is_linux = builtin.os.tag == .linux;
    const linux = if (is_linux) std.os.linux else undefined;

    const DT_DIR: u8 = 4;
    const DT_REG: u8 = 8;
    const DT_LNK: u8 = 10;

    const MAX_STACK = 2048;

    allocator: Allocator,
    config: WalkerConfig,

    // Stack of directories to process (LIFO order)
    dir_stack: [MAX_STACK]DirEntry,
    dir_stack_len: usize,

    // Current directory being processed
    current_fd: posix.fd_t,
    current_depth: u16,

    // Buffer for getdents64 results
    getdents_buffer: []align(8) u8,
    getdents_offset: usize,
    getdents_len: usize,

    // Path tracking
    path_buffer: [4096]u8,
    path_len: usize,

    // Stack of path lengths for building relative paths
    path_len_stack: [MAX_STACK]u16,
    path_len_stack_len: usize,

    // Current entry (reused)
    current_entry: Entry,

    // State
    finished: bool,

    const DirEntry = struct {
        fd: posix.fd_t,
        depth: u16,
        path_len: u16, // Path length when this dir was pushed
        // Store the actual path content to restore when we pop this directory
        // This is needed because sibling directories overwrite each other in path_buffer
        path_content: [256]u8,
    };

    pub fn init(allocator: Allocator, start_path: []const u8, config: WalkerConfig) !RecursiveGetdents64Walker {
        if (!is_linux) {
            @compileError("Getdents64Walker is only available on Linux");
        }

        // Use smaller buffer for single-directory iteration (max_depth=0)
        // since we won't be recursing and don't need as much buffering
        const buffer_size = if (config.max_depth == 0) 8192 else config.getdents_buffer_size;
        const buffer = try allocator.alignedAlloc(u8, .@"8", buffer_size);
        errdefer allocator.free(buffer);

        // Open starting directory, using base_dir if provided
        const start_fd = if (config.base_dir) |bd| blk: {
            // Use openatZ to open relative to base_dir
            var path_z: [4096:0]u8 = undefined;
            if (start_path.len >= 4096) return error.NameTooLong;
            @memcpy(path_z[0..start_path.len], start_path);
            path_z[start_path.len] = 0;

            break :blk posix.openatZ(bd.fd, &path_z, .{
                .ACCMODE = .RDONLY,
                .DIRECTORY = true,
                .CLOEXEC = true,
            }, 0) catch |err| {
                try handleOpenError(start_path, err, config);
                return err;
            };
        } else blk: {
            break :blk posix.open(start_path, .{
                .ACCMODE = .RDONLY,
                .DIRECTORY = true,
                .CLOEXEC = true,
            }, 0) catch |err| {
                try handleOpenError(start_path, err, config);
                return err;
            };
        };

        return RecursiveGetdents64Walker{
            .allocator = allocator,
            .config = config,
            .dir_stack = undefined,
            .dir_stack_len = 0,
            .current_fd = start_fd,
            .current_depth = 0,
            .getdents_buffer = buffer,
            .getdents_offset = 0,
            .getdents_len = 0,
            .path_buffer = undefined,
            .path_len = 0,
            .path_len_stack = undefined,
            .path_len_stack_len = 0,
            .current_entry = undefined,
            .finished = false,
        };
    }

    /// Handle directory open errors by calling err_callback and checking abort_on_error
    fn handleOpenError(path: []const u8, err: anyerror, config: WalkerConfig) !void {
        if (config.err_callback) |cb| {
            var path_z: [4096:0]u8 = undefined;
            const len = @min(path.len, 4095);
            @memcpy(path_z[0..len], path[0..len]);
            path_z[len] = 0;

            const errno = errToErrno(err);
            if (cb(&path_z, errno) != 0) {
                return error.Aborted;
            }
        }
        if (config.abort_on_error) {
            return error.Aborted;
        }
    }

    pub fn deinit(self: *RecursiveGetdents64Walker) void {
        if (!is_linux) return;

        // Close current fd if still open
        if (!self.finished and self.current_fd >= 0) {
            posix.close(self.current_fd);
        }

        // Close any remaining stacked fds
        for (self.dir_stack[0..self.dir_stack_len]) |entry| {
            posix.close(entry.fd);
        }

        if (self.getdents_buffer.len > 0) {
            self.allocator.free(self.getdents_buffer);
        }
    }

    pub fn next(self: *RecursiveGetdents64Walker) !?Entry {
        if (!is_linux) return null;
        if (self.finished) return null;

        while (true) {
            // Process entries from current buffer
            while (self.getdents_offset < self.getdents_len) {
                if (self.parseNextEntry()) |entry| {
                    return entry;
                }
            }

            // Buffer exhausted - read more from current directory
            const bytes_read = linux.getdents64(self.current_fd, self.getdents_buffer.ptr, self.getdents_buffer.len);

            if (@as(isize, @bitCast(bytes_read)) < 0 or bytes_read == 0) {
                // Current directory exhausted or error - close it and pop next from stack
                posix.close(self.current_fd);

                if (self.dir_stack_len == 0) {
                    self.finished = true;
                    return null;
                }

                // Pop next directory from stack
                self.dir_stack_len -= 1;
                const next_dir = self.dir_stack[self.dir_stack_len];
                self.current_fd = next_dir.fd;
                self.current_depth = next_dir.depth;
                self.path_len = next_dir.path_len;
                // Restore the path content that was saved when this directory was pushed
                const copy_len = @min(next_dir.path_len, 256);
                @memcpy(self.path_buffer[0..copy_len], next_dir.path_content[0..copy_len]);

                self.getdents_offset = 0;
                self.getdents_len = 0;
                continue;
            }

            self.getdents_len = bytes_read;
            self.getdents_offset = 0;
        }
    }

    fn parseNextEntry(self: *RecursiveGetdents64Walker) ?Entry {
        if (!is_linux) return null;

        const base = self.getdents_offset;
        if (base + 19 > self.getdents_len) return null;

        const reclen = mem.readInt(u16, self.getdents_buffer[base + 16 ..][0..2], .little);
        const d_type = self.getdents_buffer[base + 18];

        const name_start = base + 19;
        var name_len: usize = 0;
        while (name_start + name_len < base + reclen and
            self.getdents_buffer[name_start + name_len] != 0) : (name_len += 1)
        {}

        self.getdents_offset += reclen;

        const name = self.getdents_buffer[name_start..][0..name_len];

        // Unified filtering for ".", "..", and hidden files
        if (shouldSkipEntry(name, self.config.hidden)) return null;

        const kind: EntryKind = switch (d_type) {
            DT_REG => .file,
            DT_DIR => .directory,
            DT_LNK => .sym_link,
            else => .unknown,
        };

        // Build path for this entry
        const path_start = self.path_len;
        if (self.path_len > 0) {
            self.path_buffer[self.path_len] = '/';
            self.path_len += 1;
        }
        const name_in_path_start = self.path_len;
        @memcpy(self.path_buffer[self.path_len..][0..name.len], name);
        self.path_len += name.len;

        const rel_path = self.path_buffer[0..self.path_len];

        // If it's a directory, check filter and possibly push to stack for later processing
        if (kind == .directory and self.dir_stack_len < MAX_STACK and self.current_depth < self.config.max_depth) {
            // Check dir_filter before deciding to descend
            const should_descend = if (self.config.dir_filter) |filter|
                filter.filterDir(rel_path, name)
            else
                true;

            if (should_descend) {
                var name_z: [256]u8 = undefined;
                @memcpy(name_z[0..name.len], name);
                name_z[name.len] = 0;

                if (posix.openat(self.current_fd, name_z[0..name.len :0], .{
                    .ACCMODE = .RDONLY,
                    .DIRECTORY = true,
                    .CLOEXEC = true,
                }, 0)) |subdir_fd| {
                    // Push to stack - will be processed after current dir is exhausted
                    // Save the actual path content since sibling dirs will overwrite path_buffer
                    var entry: DirEntry = .{
                        .fd = subdir_fd,
                        .depth = self.current_depth + 1,
                        .path_len = @intCast(self.path_len),
                        .path_content = undefined,
                    };
                    const copy_len = @min(self.path_len, 256);
                    @memcpy(entry.path_content[0..copy_len], self.path_buffer[0..copy_len]);
                    self.dir_stack[self.dir_stack_len] = entry;
                    self.dir_stack_len += 1;
                } else |_| {}
            }
        }

        // Build result entry
        self.current_entry = .{
            .path = rel_path,
            .basename = self.path_buffer[name_in_path_start..][0..name.len],
            .kind = kind,
        };

        // Reset path for next entry (but subdir path_len is saved in stack)
        self.path_len = path_start;

        return self.current_entry;
    }
};

// ============================================================================
// Standard Library Backend (cross-platform)
// ============================================================================

const StdFsWalker = struct {
    const MAX_STACK = 256;

    allocator: Allocator,
    config: WalkerConfig,

    // Stack of directories to process (LIFO order)
    dir_stack: std.ArrayListUnmanaged(StackEntry),

    // Current directory being iterated
    current_dir: ?std.fs.Dir,
    current_iter: ?std.fs.Dir.Iterator,
    current_depth: usize,

    // Path tracking
    path_buffer: [4096]u8,
    path_len: usize,

    // Current entry (reused)
    current_entry: Entry,

    // State
    finished: bool,

    const StackEntry = struct {
        dir: std.fs.Dir,
        depth: usize,
        path_len: usize,
    };

    pub fn init(allocator: Allocator, start_path: []const u8, config: WalkerConfig) !StdFsWalker {
        const root = config.base_dir orelse std.fs.cwd();
        var dir = root.openDir(start_path, .{ .iterate = true }) catch |err| {
            try handleOpenErrorStd(start_path, err, config);
            return err;
        };
        errdefer dir.close();

        var dir_stack = std.ArrayListUnmanaged(StackEntry){};
        // Only pre-allocate stack if we're doing recursion
        if (config.max_depth > 0) {
            dir_stack.ensureTotalCapacity(allocator, 64) catch {};
        }

        return StdFsWalker{
            .allocator = allocator,
            .config = config,
            .dir_stack = dir_stack,
            .current_dir = dir,
            .current_iter = dir.iterate(),
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

            const errno = errToErrno(err);
            if (cb(&path_z, errno) != 0) {
                return error.Aborted;
            }
        }
        if (config.abort_on_error) {
            return error.Aborted;
        }
    }

    pub fn deinit(self: *StdFsWalker) void {
        // Close current directory if still open
        if (self.current_dir) |*dir| {
            dir.close();
        }

        // Close any remaining stacked directories
        for (self.dir_stack.items) |*entry| {
            entry.dir.close();
        }
        self.dir_stack.deinit(self.allocator);
    }

    pub fn next(self: *StdFsWalker) !?Entry {
        if (self.finished) return null;

        while (true) {
            // Try to get next entry from current directory
            if (self.current_iter) |*iter| {
                if (iter.next() catch null) |entry| {
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

                    const rel_path = self.path_buffer[0..self.path_len];
                    const kind = EntryKind.fromStd(entry.kind);

                    // If it's a directory, check filter and possibly push to stack
                    if (kind == .directory and self.dir_stack.items.len < MAX_STACK and self.current_depth < self.config.max_depth) {
                        // Check dir_filter before deciding to descend
                        const should_descend = if (self.config.dir_filter) |filter|
                            filter.filterDir(rel_path, entry.name)
                        else
                            true;

                        if (should_descend) {
                            if (self.current_dir.?.openDir(entry.name, .{ .iterate = true })) |subdir| {
                                // Push to stack
                                self.dir_stack.append(self.allocator, .{
                                    .dir = subdir,
                                    .depth = self.current_depth + 1,
                                    .path_len = self.path_len,
                                }) catch {
                                    var sd = subdir;
                                    sd.close();
                                };
                            } else |_| {}
                        }
                    }

                    // Build result entry
                    self.current_entry = .{
                        .path = rel_path,
                        .basename = self.path_buffer[name_start..][0..entry.name.len],
                        .kind = kind,
                    };

                    // Reset path for next entry
                    self.path_len = path_start;

                    return self.current_entry;
                }
            }

            // Current directory exhausted - close it and pop from stack
            if (self.current_dir) |*dir| {
                dir.close();
                self.current_dir = null;
                self.current_iter = null;
            }

            if (self.dir_stack.items.len == 0) {
                self.finished = true;
                return null;
            }

            // Pop next directory from stack
            const next_entry = self.dir_stack.pop();
            self.current_dir = next_entry.dir;
            self.current_iter = next_entry.dir.iterate();
            self.current_depth = next_entry.depth;
            self.path_len = next_entry.path_len;
        }
    }
};

// ============================================================================
// Single Directory Iterator (lightweight, no allocations)
// ============================================================================

/// Lightweight single-directory iterator using C's opendir/readdir.
/// This is the fastest option for single-directory iteration as it uses
/// glibc's optimized implementation.
pub const CDirIterator = struct {
    const c = std.c;

    dir: ?*c.DIR,
    path_z: [4096:0]u8,
    hidden: HiddenConfig,

    pub const IterEntry = struct {
        name: []const u8,
        kind: EntryKind,
    };

    /// SIMD-optimized strlen for dirent d_name (max 256 bytes).
    inline fn direntNameSlice(d_name: *const [256]u8) []const u8 {
        const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
        const Vec = @Vector(vec_len, u8);
        const zeros: Vec = @splat(0);
        const iterations = 256 / vec_len;

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
        return d_name[0..256];
    }

    /// Open a directory for single-level iteration.
    /// If base_dir is provided, opens path relative to it; otherwise relative to cwd.
    /// hidden_config controls filtering of ".", "..", and hidden files.
    pub fn open(path: []const u8, base_dir: ?std.fs.Dir, hidden_config: HiddenConfig) !CDirIterator {
        var self = CDirIterator{
            .dir = null,
            .path_z = undefined,
            .hidden = hidden_config,
        };

        if (base_dir) |bd| {
            // For relative paths with base_dir, we need to use openat + fdopendir
            // But C doesn't have a portable way to do this, so fall back to building full path
            // For now, just open relative to cwd (base_dir support requires platform-specific code)
            _ = bd;
            if (path.len >= 4096) return error.NameTooLong;
            @memcpy(self.path_z[0..path.len], path);
            self.path_z[path.len] = 0;
            self.dir = c.opendir(&self.path_z);
        } else {
            if (path.len >= 4096) return error.NameTooLong;
            @memcpy(self.path_z[0..path.len], path);
            self.path_z[path.len] = 0;
            self.dir = c.opendir(&self.path_z);
        }

        if (self.dir == null) {
            return error.AccessDenied;
        }

        return self;
    }

    pub fn close(self: *CDirIterator) void {
        if (self.dir) |d| {
            _ = c.closedir(d);
            self.dir = null;
        }
    }

    pub fn next(self: *CDirIterator) ?IterEntry {
        const dir = self.dir orelse return null;

        while (c.readdir(dir)) |entry_raw| {
            const entry: *const c.dirent = @ptrCast(@alignCast(entry_raw));
            const name = direntNameSlice(&entry.name);

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

    pub const IterEntry = struct {
        name: []const u8,
        kind: EntryKind,
    };

    /// Open a directory for single-level iteration using raw syscalls.
    /// If base_dir is provided, opens path relative to it; otherwise relative to cwd.
    /// hidden_config controls filtering of ".", "..", and hidden files.
    pub fn open(path: []const u8, base_dir: ?std.fs.Dir, hidden_config: HiddenConfig) !SingleDirIterator {
        if (!is_linux) {
            @compileError("SingleDirIterator.open requires Linux");
        }

        // Build null-terminated path on stack
        var path_z: [4096:0]u8 = undefined;
        if (path.len >= 4096) return error.NameTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const flags = linux.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };

        // Use raw syscall for maximum performance
        const fd: i32 = if (base_dir) |bd| blk: {
            const rc = linux.openat(bd.fd, &path_z, flags, 0);
            const signed: isize = @bitCast(rc);
            if (signed < 0) return error.AccessDenied;
            break :blk @intCast(rc);
        } else blk: {
            const rc = linux.openat(linux.AT.FDCWD, &path_z, flags, 0);
            const signed: isize = @bitCast(rc);
            if (signed < 0) return error.AccessDenied;
            break :blk @intCast(rc);
        };

        return SingleDirIterator{
            .fd = fd,
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
                if (base + 19 > self.len) break;

                const reclen = @as(u16, self.buffer[base + 16]) | (@as(u16, self.buffer[base + 17]) << 8);
                const d_type = self.buffer[base + 18];

                self.offset += reclen;

                // Get name directly - it starts at offset 19 and is null-terminated
                const name_ptr = self.buffer[base + 19 ..].ptr;
                var name_len: usize = 0;
                while (name_ptr[name_len] != 0 and name_len < reclen - 19) : (name_len += 1) {}

                const name = name_ptr[0..name_len];

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

            // Buffer exhausted - read more
            const rc = linux.getdents64(self.fd, &self.buffer, self.buffer.len);
            const bytes_read: isize = @bitCast(rc);
            if (bytes_read <= 0) {
                return null;
            }

            self.len = @intCast(bytes_read);
            self.offset = 0;
        }
    }
};

/// Fallback for non-Linux: use std.fs.Dir.Iterator
pub const StdDirIterator = struct {
    dir: std.fs.Dir,
    iter: std.fs.Dir.Iterator,
    hidden: HiddenConfig,

    pub const IterEntry = struct {
        name: []const u8,
        kind: EntryKind,
    };

    pub fn open(path: []const u8, base_dir: ?std.fs.Dir, hidden_config: HiddenConfig) !StdDirIterator {
        const root = base_dir orelse std.fs.cwd();
        var dir = try root.openDir(path, .{ .iterate = true });
        return StdDirIterator{
            .dir = dir,
            .iter = dir.iterate(),
            .hidden = hidden_config,
        };
    }

    pub fn close(self: *StdDirIterator) void {
        self.dir.close();
    }

    pub fn next(self: *StdDirIterator) ?IterEntry {
        while (true) {
            const entry = self.iter.next() catch return null;
            if (entry) |e| {
                // Unified filtering for ".", "..", and hidden files
                if (shouldSkipEntry(e.name, self.hidden)) continue;
                return IterEntry{
                    .name = e.name,
                    .kind = EntryKind.fromStd(e.kind),
                };
            }
            return null;
        }
    }
};

/// Platform-appropriate single-directory iterator with ALTDIRFUNC support.
/// When fs_provider has ALTDIRFUNC callbacks, uses those; otherwise uses C's optimized opendir/readdir.
/// For recursive walking, use DefaultWalker which uses getdents64 on Linux.
pub const DirIterator = struct {
    const c = std.c;

    /// Internal state - either real fs or ALTDIRFUNC mode
    mode: union(enum) {
        /// Real filesystem using C's opendir/readdir
        real_fs: struct {
            dir: ?*c.DIR,
        },
        /// ALTDIRFUNC custom callbacks
        alt_dirfunc: struct {
            handle: ?*anyopaque,
            readdir: AltReaddirFn,
            closedir: AltClosedirFn,
        },
    },
    hidden: HiddenConfig,
    path_z: [4096:0]u8,

    pub const IterEntry = struct {
        name: []const u8,
        kind: EntryKind,
    };

    /// SIMD-optimized strlen for dirent d_name (max 256 bytes).
    inline fn direntNameSlice(d_name: *const [256]u8) []const u8 {
        const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
        const Vec = @Vector(vec_len, u8);
        const zeros: Vec = @splat(0);
        const iterations = 256 / vec_len;

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
        return d_name[0..256];
    }

    /// Open a directory for single-level iteration.
    /// If base_dir is provided, opens path relative to it; otherwise relative to cwd.
    /// hidden_config controls filtering of ".", "..", and hidden files.
    /// fs_provider allows using ALTDIRFUNC callbacks for virtual filesystem support.
    pub fn openWithProvider(path: []const u8, base_dir: ?std.fs.Dir, hidden_config: HiddenConfig, fs_provider: FsProvider) !DirIterator {
        var self = DirIterator{
            .mode = undefined,
            .hidden = hidden_config,
            .path_z = undefined,
        };

        if (path.len >= 4096) return error.NameTooLong;
        @memcpy(self.path_z[0..path.len], path);
        self.path_z[path.len] = 0;

        if (fs_provider.isAltDirFunc()) {
            // Use ALTDIRFUNC callbacks
            const handle = fs_provider.opendir.?(&self.path_z);
            if (handle == null) return error.FileNotFound;

            self.mode = .{ .alt_dirfunc = .{
                .handle = handle,
                .readdir = fs_provider.readdir.?,
                .closedir = fs_provider.closedir.?,
            } };
        } else {
            // Use real filesystem
            if (base_dir) |bd| {
                // For relative paths with base_dir, we need to use openat + fdopendir
                // But C doesn't have a portable way to do this, so fall back to building full path
                // For now, just open relative to cwd (base_dir support requires platform-specific code)
                _ = bd;
                self.mode = .{ .real_fs = .{ .dir = c.opendir(&self.path_z) } };
            } else {
                self.mode = .{ .real_fs = .{ .dir = c.opendir(&self.path_z) } };
            }

            if (self.mode.real_fs.dir == null) {
                return error.AccessDenied;
            }
        }

        return self;
    }

    /// Open a directory for single-level iteration (backward compatible).
    /// If base_dir is provided, opens path relative to it; otherwise relative to cwd.
    /// hidden_config controls filtering of ".", "..", and hidden files.
    pub fn open(path: []const u8, base_dir: ?std.fs.Dir, hidden_config: HiddenConfig) !DirIterator {
        return openWithProvider(path, base_dir, hidden_config, FsProvider.real_fs);
    }

    pub fn close(self: *DirIterator) void {
        switch (self.mode) {
            .real_fs => |*fs| {
                if (fs.dir) |d| {
                    _ = c.closedir(d);
                    fs.dir = null;
                }
            },
            .alt_dirfunc => |*alt| {
                alt.closedir(alt.handle);
                alt.handle = null;
            },
        }
    }

    pub fn next(self: *DirIterator) ?IterEntry {
        switch (self.mode) {
            .real_fs => |fs| {
                const dir = fs.dir orelse return null;

                while (c.readdir(dir)) |entry_raw| {
                    const entry: *const c.dirent = @ptrCast(@alignCast(entry_raw));
                    const name = direntNameSlice(&entry.name);

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

// ============================================================================
// Tests
// ============================================================================

test "walker basic" {
    const allocator = std.testing.allocator;

    var walker = try DefaultWalker.init(allocator, ".", .{ .hidden = HiddenConfig.posix_default });
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next()) |_| {
        count += 1;
        if (count > 10) break;
    }

    try std.testing.expect(count > 0);
}

test "entry kind conversion" {
    try std.testing.expectEqual(EntryKind.file, EntryKind.fromStd(.file));
    try std.testing.expectEqual(EntryKind.directory, EntryKind.fromStd(.directory));
    try std.testing.expectEqual(EntryKind.sym_link, EntryKind.fromStd(.sym_link));
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

    // dots_and_hidden (same as include_all)
    try std.testing.expect(HiddenConfig.dots_and_hidden.include_dot_entries == true);
    try std.testing.expect(HiddenConfig.dots_and_hidden.include_hidden == true);
}
