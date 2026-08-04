const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const linux = std.os.linux;
const types = @import("types.zig");
const worker = @import("worker.zig");
const GitIgnore = @import("../gitignore.zig").GitIgnore;

const IgnoreNode = worker.IgnoreNode;
const MAX_DIR_CHAIN = 64;

pub const __internal_test_api = if (builtin.is_test) struct {
    pub const max_dir_chain = MAX_DIR_CHAIN;

    pub fn isIgnoredResolved(rules: *const IgnoreRules, normalized: []const u8, basename: []const u8, is_dir: bool) bool {
        return rules.isIgnoredResolved(normalized, basename, is_dir);
    }

    pub fn isIgnoredPathSlow(rules: *const IgnoreRules, normalized: []const u8, basename: []const u8, is_dir: bool) bool {
        return rules.isIgnoredPathSlow(normalized, basename, is_dir);
    }
} else struct {};

pub const IgnoreRules = struct {
    allocator: std.mem.Allocator,
    by_dir: std.StringHashMapUnmanaged(*IgnoreNode) = .empty,
    extra: ?*IgnoreNode = null,
    walk_root: []const u8 = &.{},

    /// Returns `true` if the path needs to be ignored or not accessible
    pub fn isIgnoredPath(self: *const IgnoreRules, path: []const u8) bool {
        var normalized_buffer: [types.MAX_PATH]u8 = undefined;
        const path_slash: []const u8 = if (mem.indexOfScalar(u8, path, '\\')) |_| blk: {
            if (path.len > normalized_buffer.len) return true; // pathologically long -> ignored
            @memcpy(normalized_buffer[0..path.len], path);
            for (normalized_buffer[0..path.len]) |*b| {
                if (b.* == '\\') b.* = '/';
            }
            break :blk normalized_buffer[0..path.len];
        } else path;

        // Strip a leading "./" for user-friendliness (relative form).
        const trimmed = if (path_slash.len >= 2 and path_slash[0] == '.' and path_slash[1] == '/')
            path_slash[2..]
        else
            path_slash;

        // Split into (root-relative form, absolute form for lstat)
        // Absolute inputs start with '/' on Unix; on Windows we detect both
        // `/foo/bar` (still absolute here since our slash-normalize ran) and
        // `C:/foo/bar` drive-prefixed forms.
        var abs_buf: [types.MAX_PATH:0]u8 = undefined;
        var relative: []const u8 = undefined;
        var abs_z: [:0]const u8 = undefined;

        if (std.fs.path.isAbsolute(trimmed)) {
            const stripped = stripRootPrefix(self.walk_root, trimmed) orelse return true;
            relative = stripped;
            if (trimmed.len >= abs_buf.len) return true;
            @memcpy(abs_buf[0..trimmed.len], trimmed);
            abs_buf[trimmed.len] = 0;
            abs_z = abs_buf[0..trimmed.len :0];
        } else {
            // Root-relative query: join walk_root + '/' + rel for lstat.
            relative = trimmed;
            const wr = self.walk_root;
            const need_sep = wr.len > 0 and wr[wr.len - 1] != '/';
            const joined_len = wr.len + @intFromBool(need_sep) + relative.len;
            if (joined_len >= abs_buf.len) return true;
            @memcpy(abs_buf[0..wr.len], wr);
            var off_out: usize = wr.len;
            if (need_sep) {
                abs_buf[off_out] = '/';
                off_out += 1;
            }
            @memcpy(abs_buf[off_out..][0..relative.len], relative);
            off_out += relative.len;
            abs_buf[off_out] = 0;
            abs_z = abs_buf[0..off_out :0];
        }

        // ignore if the path is unreachable
        const is_dir = lstatIsDir(abs_z) orelse return true;

        const basename = if (mem.lastIndexOfScalar(u8, relative, '/')) |p| relative[p + 1 ..] else relative;
        return self.isIgnoredResolved(relative, basename, is_dir);
    }

    fn isIgnoredResolved(
        self: *const IgnoreRules,
        normalized: []const u8,
        basename: []const u8,
        is_dir: bool,
    ) bool {
        // Innermost first: extra rules, nested directories, then the root file.
        var ignore_nodes: [MAX_DIR_CHAIN + 1]GitIgnore.ScopedRules = undefined;
        var count: usize = 0;

        if (self.extra) |node| {
            ignore_nodes[count] = .{ .gi = &node.gi, .offset = 0 };
            count += 1;
        }

        var end: usize = normalized.len;
        while (mem.lastIndexOfScalar(u8, normalized[0..end], '/')) |slash| {
            end = slash;
            if (self.by_dir.get(normalized[0..slash])) |node| {
                // if deeper than we can hold as a stack resolution go to the slow method
                if (count == ignore_nodes.len) return self.isIgnoredPathSlow(normalized, basename, is_dir);
                ignore_nodes[count] = .{ .gi = &node.gi, .offset = node.relative_offset };
                count += 1;
            }
        }

        // The loop does not visit the empty root prefix, so add it separately.
        if (self.by_dir.get("")) |node| {
            if (count == ignore_nodes.len) return self.isIgnoredPathSlow(normalized, basename, is_dir);
            ignore_nodes[count] = .{ .gi = &node.gi, .offset = node.relative_offset };
            count += 1;
        }

        const stack = GitIgnore.Stack{ .docs = ignore_nodes[0..count] };
        return stack.verdictWithAncestors(normalized, basename, is_dir) orelse false;
    }

    /// Slow sequential fallback if the path exceeds 64 segments (which is very rare)
    fn isIgnoredPathSlow(
        self: *const IgnoreRules,
        norm: []const u8,
        basename: []const u8,
        is_dir: bool,
    ) bool {
        var offset: usize = 0;
        while (mem.indexOfScalarPos(u8, norm, offset, '/')) |slash| {
            const ancestor = norm[0..slash];
            if (self.slowVerdict(ancestor, GitIgnore.basenameOf(ancestor), true) == true) return true;
            offset = slash + 1;
        }
        return self.slowVerdict(norm, basename, is_dir) orelse false;
    }

    fn slowVerdict(self: *const IgnoreRules, path: []const u8, basename: []const u8, is_dir: bool) ?bool {
        if (self.extra) |node| {
            if (node.gi.checkInode(path, basename, is_dir)) |answer| return answer;
        }
        var end: usize = path.len;
        while (mem.lastIndexOfScalar(u8, path[0..end], '/')) |slash| {
            end = slash;
            if (self.by_dir.get(path[0..slash])) |node| {
                if (node.gi.checkInode(path[node.relative_offset..], basename, is_dir)) |answer| return answer;
            }
        }
        if (self.by_dir.get("")) |node| {
            if (node.gi.checkInode(path, basename, is_dir)) |answer| return answer;
        }
        return null;
    }

    pub fn put(self: *IgnoreRules, dir_rel: []const u8, node: *IgnoreNode) !void {
        const gop = try self.by_dir.getOrPut(self.allocator, dir_rel);
        if (gop.found_existing) {
            // A directory yields at most one node; replacing would leak a ref.
            return;
        }
        errdefer _ = self.by_dir.remove(dir_rel);
        gop.key_ptr.* = try self.allocator.dupe(u8, dir_rel);
        node.retain();
        gop.value_ptr.* = node;
    }

    pub fn setExtra(self: *IgnoreRules, node: ?*IgnoreNode) void {
        if (self.extra) |old| old.release(self.allocator);
        self.extra = node;
        if (node) |n| n.retain();
    }

    pub fn setWalkRoot(self: *IgnoreRules, root: []const u8) !void {
        if (self.walk_root.len > 0) self.allocator.free(self.walk_root);
        self.walk_root = if (root.len == 0) &.{} else try self.allocator.dupe(u8, root);
    }

    pub fn deinit(self: *IgnoreRules) void {
        if (self.walk_root.len > 0) self.allocator.free(self.walk_root);
        self.walk_root = &.{};
        if (self.extra) |x| x.release(self.allocator);
        self.extra = null;
        var it = self.by_dir.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.*.release(self.allocator);
        }
        self.by_dir.deinit(self.allocator);
    }
};

fn stripRootPrefix(root: []const u8, path: []const u8) ?[]const u8 {
    if (root.len == 0) return path;
    // Normalize any trailing slash on the root for comparison stability.
    const clean_root = if (root[root.len - 1] == '/') root[0 .. root.len - 1] else root;
    if (path.len < clean_root.len) return null;
    if (!mem.eql(u8, path[0..clean_root.len], clean_root)) return null;
    if (path.len == clean_root.len) return &.{}; // exact root
    if (path[clean_root.len] != '/') return null; // "root_foo" ≠ "root/..."

    return path[clean_root.len + 1 ..];
}

fn lstatIsDir(path: [:0]const u8) ?bool {
    if (builtin.os.tag == .linux) {
        var stx: linux.Statx = undefined;
        const rc = linux.statx(
            types.AT_FDCWD,
            path.ptr,
            linux.AT.SYMLINK_NOFOLLOW,
            .{ .TYPE = true },
            &stx,
        );
        if (linux.errno(rc) != .SUCCESS) return null;
        return (@as(u32, stx.mode) & 0o170000) == 0o040000;
    }
    // Windows (and any other no-libc target): use the portable std.Io API
    // instead of std.c.fstatat, which would force a libc dependency.
    if (builtin.os.tag == .windows or !@hasDecl(std.c, "fstatat")) {
        const io = std.Io.Threaded.global_single_threaded.io();
        const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return null;
        return st.kind == .directory;
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(types.AT_FDCWD, path.ptr, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return (@as(u32, @intCast(st.mode)) & 0o170000) == 0o040000;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
