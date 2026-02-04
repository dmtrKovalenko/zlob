///! Unified directory walker with platform-specific backends.
///!
///! This module provides a consistent interface for recursive directory walking
///! with optimized backends for different platforms:
///!
///! - Linux: Uses direct getdents64 syscalls for ~10-15% speedup over std.fs
///! - Other: Falls back to std.fs.Dir.walk()
///!
///! The backend is selected at compile time based on the target platform.
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

pub const WalkerConfig = struct {
    /// Buffer size for getdents64 (Linux only)
    getdents_buffer_size: usize = 65536,
    /// Maximum recursion depth
    max_depth: usize = 128,
    /// Skip hidden files/directories (starting with .)
    skip_hidden: bool = false,
};

pub fn WalkerType(comptime backend: Backend) type {
    return switch (backend) {
        .getdents64 => Getdents64Walker,
        .std_fs => StdFsWalker,
    };
}

pub const DefaultWalker = WalkerType(default_backend);

pub fn isOptimizedBackendAvailable() bool {
    return builtin.os.tag == .linux;
}

const Getdents64Walker = struct {
    const is_linux = builtin.os.tag == .linux;
    const linux = if (is_linux) std.os.linux else undefined;
    const posix = std.posix;

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
    };

    pub fn init(allocator: Allocator, start_path: []const u8, config: WalkerConfig) !Getdents64Walker {
        if (!is_linux) {
            @compileError("Getdents64Walker is only available on Linux");
        }

        const buffer = try allocator.alignedAlloc(u8, .@"8", config.getdents_buffer_size);
        errdefer allocator.free(buffer);

        const start_fd = try posix.open(start_path, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true, // Don't leak fd to child processes
        }, 0);

        return Getdents64Walker{
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

    pub fn deinit(self: *Getdents64Walker) void {
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

    pub fn next(self: *Getdents64Walker) !?Entry {
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

                self.getdents_offset = 0;
                self.getdents_len = 0;
                continue;
            }

            self.getdents_len = bytes_read;
            self.getdents_offset = 0;
        }
    }

    fn parseNextEntry(self: *Getdents64Walker) ?Entry {
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

        // Skip . and ..
        if (name.len == 1 and name[0] == '.') return null;
        if (name.len == 2 and name[0] == '.' and name[1] == '.') return null;

        // Skip hidden if configured
        if (self.config.skip_hidden and name.len > 0 and name[0] == '.') return null;

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

        // If it's a directory, open it and push to stack for later processing
        if (kind == .directory and self.dir_stack_len < MAX_STACK and self.current_depth < self.config.max_depth) {
            var name_z: [256]u8 = undefined;
            @memcpy(name_z[0..name.len], name);
            name_z[name.len] = 0;

            if (posix.openat(self.current_fd, name_z[0..name.len :0], .{
                .ACCMODE = .RDONLY,
                .DIRECTORY = true,
                .CLOEXEC = true,
            }, 0)) |subdir_fd| {
                // Push to stack - will be processed after current dir is exhausted
                self.dir_stack[self.dir_stack_len] = .{
                    .fd = subdir_fd,
                    .depth = self.current_depth + 1,
                    .path_len = @intCast(self.path_len), // Save path length for this subdir
                };
                self.dir_stack_len += 1;
            } else |_| {}
        }

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

// ============================================================================
// Standard Library Backend (cross-platform)
// ============================================================================

const StdFsWalker = struct {
    allocator: Allocator,
    config: WalkerConfig,
    dir: std.fs.Dir,
    walker: std.fs.Dir.Walker,
    current_entry: Entry,

    pub fn init(allocator: Allocator, start_path: []const u8, config: WalkerConfig) !StdFsWalker {
        var dir = try std.fs.cwd().openDir(start_path, .{ .iterate = true });
        errdefer dir.close();

        const walker = try dir.walk(allocator);

        return StdFsWalker{
            .allocator = allocator,
            .config = config,
            .dir = dir,
            .walker = walker,
            .current_entry = undefined,
        };
    }

    pub fn deinit(self: *StdFsWalker) void {
        self.walker.deinit();
        self.dir.close();
    }

    pub fn next(self: *StdFsWalker) !?Entry {
        while (try self.walker.next()) |entry| {
            // Skip hidden if configured
            if (self.config.skip_hidden) {
                if (entry.basename.len > 0 and entry.basename[0] == '.') continue;
                // Also skip paths with hidden components
                if (mem.indexOf(u8, entry.path, "/.") != null) continue;
            }

            self.current_entry = .{
                .path = entry.path,
                .basename = entry.basename,
                .kind = EntryKind.fromStd(entry.kind),
            };
            return self.current_entry;
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "walker basic" {
    const allocator = std.testing.allocator;

    var walker = try DefaultWalker.init(allocator, ".", .{ .skip_hidden = true });
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
