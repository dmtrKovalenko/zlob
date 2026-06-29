const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const worker = @import("worker.zig");
const IgnoreNode = worker.IgnoreNode;

pub const IgnoreRules = struct {
    gpa: Allocator,
    /// Directory root-relative path ("" = root) -> the node defined there.
    /// Keys are owned. Each node holds one ref on behalf of this map.
    by_dir: std.StringHashMapUnmanaged(*IgnoreNode) = .empty,

    /// Records the node parsed for `dir_rel` (an owned copy of the key is
    /// made). Takes one ref on `node`. Called by the walker under its own
    /// lock when retain mode is on.
    pub fn put(self: *IgnoreRules, dir_rel: []const u8, node: *IgnoreNode) !void {
        const gop = try self.by_dir.getOrPut(self.gpa, dir_rel);
        if (gop.found_existing) {
            // A directory yields at most one node; replacing would leak a ref.
            return;
        }
        errdefer _ = self.by_dir.remove(dir_rel);
        gop.key_ptr.* = try self.gpa.dupe(u8, dir_rel);
        node.retain();
        gop.value_ptr.* = node;
    }

    /// Retruns `true` if the path has to be ignored, no syscalls
    pub fn isIgnored(self: *const IgnoreRules, path: []const u8, is_dir: bool) bool {
        const norm = if (path.len > 2 and path[0] == '.' and path[1] == '/') path[2..] else path;
        const basename = if (mem.lastIndexOfScalar(u8, norm, '/')) |p| norm[p + 1 ..] else norm;

        // Visit ancestor directories deepest-first: for "a/b/c.txt" that is
        // "a/b", then "a", then "" (root). The first directory with a node
        // resolves the whole chain (the node links to its ancestors).
        var dir: []const u8 = if (mem.lastIndexOfScalar(u8, norm, '/')) |p| norm[0..p] else "";
        while (true) {
            if (self.by_dir.get(dir)) |node| {
                return chainIgnored(node, norm, basename, is_dir);
            }
            if (dir.len == 0) return false;
            dir = if (mem.lastIndexOfScalar(u8, dir, '/')) |p| dir[0..p] else "";
        }
    }

    /// Checks a verified existing path wether it needs to be gitignored
    pub fn isIgnoredPath(self: *const IgnoreRules, path: []const u8) bool {
        if (path.len > 0 and path[path.len - 1] == '/') {
            return self.isIgnored(path[0 .. path.len - 1], true);
        }
        return self.isIgnored(path, false);
    }

    /// Like `isIgnored` but determines directory-ness by stat'ing `path` on
    /// disk (lstat: symlinks are not followed)
    pub fn isIgnoredUntrusted(self: *const IgnoreRules, path: []const u8) bool {
        const clean = if (path.len > 0 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
        return self.isIgnored(clean, statIsDir(clean));
    }

    pub fn deinit(self: *IgnoreRules) void {
        var it = self.by_dir.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.*.release(self.gpa);
        }
        self.by_dir.deinit(self.gpa);
    }
};

/// lstat `path` and report whether it is a directory. False on any error or on
/// platforms without a C lstat (the std_fs fallback never reaches here from a
/// retained walk, but keep it total).
fn statIsDir(path: []const u8) bool {
    if (!@hasDecl(std.c, "lstat")) return false;
    if (path.len == 0 or path.len >= 4096) return false;

    var buf: [4096:0]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: std.c.Stat = undefined;
    if (std.c.lstat(buf[0..path.len :0], &st) != 0) return false;
    return (@as(u32, @intCast(st.mode)) & 0o170000) == 0o040000;
}

/// Deepest-first resolution across the node's ancestor chain (same rule the
/// walker uses): the first file with a decisive verdict wins.
fn chainIgnored(start: *IgnoreNode, rel: []const u8, basename: []const u8, is_dir: bool) bool {
    var node: ?*IgnoreNode = start;
    while (node) |n| : (node = n.parent) {
        if (n.gi.checkWithBasename(rel[n.rel_off..], basename, is_dir)) |verdict| {
            return verdict;
        }
    }
    return false;
}
