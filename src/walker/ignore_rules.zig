const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const linux = std.os.linux;
const types = @import("types.zig");
const worker = @import("worker.zig");
const GitIgnore = @import("../gitignore.zig").GitIgnore;
const git_excludes = @import("git_excludes.zig");

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
    parents: ?*IgnoreNode = null,
    /// Prefix of the walk root when matching rules inherited from its
    /// ancestors, including the final slash.
    scope_prefix: []const u8 = &.{},
    root_ignored: bool = false,
    compat: bool = false,
    compat_global: ?GitIgnore = null,
    compat_cwd: ?[:0]const u8 = null,

    pub fn loadCompatGlobal(self: *IgnoreRules, io: std.Io) error{OutOfMemory}!void {
        const doc = git_excludes.loadCompatGlobal(self.allocator, io) orelse return;
        defer self.allocator.free(doc);
        const cwd = std.process.currentPathAlloc(io, self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        errdefer self.allocator.free(cwd);
        self.compat_global = try GitIgnore.parseWithSyntax(self.allocator, doc, .ignore_compat);
        self.compat_cwd = cwd;
    }

    pub fn compatVerdict(
        self: *const IgnoreRules,
        start: ?*IgnoreNode,
        scoped: []const u8,
        full: []const u8,
        basename: []const u8,
        is_dir: bool,
    ) ?bool {
        var node = start;
        const use_global = if (node) |n| n.in_git_context else false;
        var git_in_scope = true;
        var git_match: ?bool = null;
        while (node) |n| : (node = n.parent) {
            switch (n.source) {
                .dot_ignore => if (n.gi.checkInode(scoped[n.relative_offset..], basename, is_dir)) |answer| return answer,
                .git => {
                    if (git_in_scope and git_match == null) {
                        git_match = n.gi.checkInode(scoped[n.relative_offset..], basename, is_dir);
                    }
                    git_in_scope = git_in_scope and !n.git_boundary;
                },
            }
        }
        if (git_match != null) return git_match;
        if (use_global) {
            if (self.compat_global) |*global| {
                var path = full;
                if (mem.startsWith(u8, path, "./")) path = path[2..];
                const cwd = self.compat_cwd.?;
                if (mem.startsWith(u8, path, cwd) and
                    (path.len == cwd.len or std.fs.path.isSep(path[cwd.len]) or std.fs.path.isSep(cwd[cwd.len - 1])))
                {
                    path = path[cwd.len..];
                    if (path.len > 0 and std.fs.path.isSep(path[0])) path = path[1..];
                }
                return global.checkInode(path, basename, is_dir);
            }
        }
        return null;
    }

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
        return if (self.compat)
            self.isIgnoredPathCompat(relative, abs_z, basename, is_dir)
        else
            self.isIgnoredResolved(relative, basename, is_dir);
    }

    fn isIgnoredPathCompat(
        self: *const IgnoreRules,
        relative: []const u8,
        full: []const u8,
        basename: []const u8,
        is_dir: bool,
    ) bool {
        if (relative.len == 0) return false;
        if (relative.len >= types.MAX_PATH) return true;
        var buffer: [2 * types.MAX_PATH]u8 = undefined;
        const scoped = self.scopedPath(&buffer, relative);
        const full_offset = full.len - relative.len;
        var start: ?*IgnoreNode = self.by_dir.get("") orelse self.parents;
        var end: usize = 0;
        while (mem.indexOfScalarPos(u8, relative, end, '/')) |slash| {
            const prefix = relative[0..slash];
            const dir_name = relative[end..slash];
            if (self.extra) |extra| {
                if (extra.gi.checkInode(prefix, dir_name, true)) |answer| {
                    if (answer) return true;
                    start = self.by_dir.get(prefix) orelse start;
                    end = slash + 1;
                    continue;
                }
            }
            if (self.compatVerdict(start, scoped[0 .. self.scope_prefix.len + slash], full[0 .. full_offset + slash], dir_name, true) == true) return true;
            start = self.by_dir.get(prefix) orelse start;
            end = slash + 1;
        }
        if (self.extra) |extra| {
            if (extra.gi.checkInode(relative, basename, is_dir)) |answer| return answer;
        }
        return self.compatVerdict(start, scoped, full, basename, is_dir) orelse false;
    }

    fn isIgnoredResolved(
        self: *const IgnoreRules,
        normalized: []const u8,
        basename: []const u8,
        is_dir: bool,
    ) bool {
        if (self.root_ignored) return true;

        // Innermost first: extra rules, local directories, then inherited rules.
        var ignore_nodes: [MAX_DIR_CHAIN + 1]GitIgnore.ScopedRules = undefined;
        var count: usize = 0;

        if (self.extra) |node| {
            ignore_nodes[count] = .{ .gi = &node.gi, .offset = self.scope_prefix.len };
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

        var parent = self.parents;
        while (parent) |node| : (parent = node.parent) {
            if (count == ignore_nodes.len) return self.isIgnoredPathSlow(normalized, basename, is_dir);
            ignore_nodes[count] = .{ .gi = &node.gi, .offset = node.relative_offset };
            count += 1;
        }

        var buffer: [2 * types.MAX_PATH]u8 = undefined;
        const path = self.scopedPath(&buffer, normalized);
        const stack = GitIgnore.Stack{ .docs = ignore_nodes[0..count] };
        return stack.verdictWithAncestors(path, basename, is_dir) orelse false;
    }

    /// Slow sequential fallback if the path exceeds 64 segments (which is very rare)
    fn isIgnoredPathSlow(
        self: *const IgnoreRules,
        norm: []const u8,
        basename: []const u8,
        is_dir: bool,
    ) bool {
        if (self.root_ignored) return true;
        var buffer: [2 * types.MAX_PATH]u8 = undefined;
        const path = self.scopedPath(&buffer, norm);
        var offset = self.scope_prefix.len;
        // Discovery already checked the walk root and the ancestors above it.
        while (mem.indexOfScalarPos(u8, path, offset, '/')) |slash| {
            const ancestor = path[0..slash];
            if (self.slowVerdict(ancestor, GitIgnore.basenameOf(ancestor), true) == true) return true;
            offset = slash + 1;
        }
        return self.slowVerdict(path, basename, is_dir) orelse false;
    }

    fn scopedPath(self: *const IgnoreRules, buffer: *[2 * types.MAX_PATH]u8, path: []const u8) []const u8 {
        if (self.scope_prefix.len == 0) return path;
        const end = self.scope_prefix.len + path.len;
        @memcpy(buffer[0..self.scope_prefix.len], self.scope_prefix);
        @memcpy(buffer[self.scope_prefix.len..end], path);
        return buffer[0..end];
    }

    fn slowVerdict(self: *const IgnoreRules, scoped: []const u8, basename: []const u8, is_dir: bool) ?bool {
        const path = scoped[self.scope_prefix.len..];
        if (self.extra) |node| {
            if (node.gi.checkInode(path, basename, is_dir)) |answer| return answer;
        }
        var end: usize = path.len;
        while (mem.lastIndexOfScalar(u8, path[0..end], '/')) |slash| {
            end = slash;
            if (self.by_dir.get(path[0..slash])) |node| {
                if (node.gi.checkInode(scoped[node.relative_offset..], basename, is_dir)) |answer| return answer;
            }
        }
        if (self.by_dir.get("")) |node| {
            if (node.gi.checkInode(path, basename, is_dir)) |answer| return answer;
        }
        return worker.chainVerdict(self.parents, scoped, basename, is_dir);
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
        if (self.parents) |node| node.release(self.allocator);
        self.parents = null;
        if (self.scope_prefix.len > 0) self.allocator.free(self.scope_prefix);
        self.scope_prefix = &.{};
        if (self.compat_global) |*global| global.deinit();
        self.compat_global = null;
        if (self.compat_cwd) |cwd| self.allocator.free(cwd);
        self.compat_cwd = null;
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
