const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const linux = std.os.linux;
const types = @import("types.zig");
const worker = @import("worker.zig");
const IgnoreNode = worker.IgnoreNode;
const MAX_PATH = types.MAX_PATH;

const MAX_DIR_CHAIN = 64;

pub const IgnoreRules = struct {
    allocator: std.mem.Allocator,
    by_dir: std.StringHashMapUnmanaged(*IgnoreNode) = .empty,
    extra: ?*IgnoreNode = null,
    walk_root: []const u8 = &.{},

    /// Returns `true` if the path needs to be ignored or not accessible
    pub fn isIgnoredPath(self: *const IgnoreRules, path: []const u8) bool {
        var normlaized_buffer: [MAX_PATH]u8 = undefined;
        const path_slash: []const u8 = if (mem.indexOfScalar(u8, path, '\\')) |_| blk: {
            if (path.len > normlaized_buffer.len) return true; // pathologically long → ignored
            @memcpy(normlaized_buffer[0..path.len], path);
            for (normlaized_buffer[0..path.len]) |*b| {
                if (b.* == '\\') b.* = '/';
            }
            break :blk normlaized_buffer[0..path.len];
        } else path;

        // Strip a leading "./" for user-friendliness (relative form).
        const trimmed = if (path_slash.len >= 2 and path_slash[0] == '.' and path_slash[1] == '/')
            path_slash[2..]
        else
            path_slash;

        // Split into (root-relative form, absolute form for lstat).
        // Absolute inputs start with '/' on Unix; on Windows we detect both
        // `/foo/bar` (still absolute here since our slash-normalize ran) and
        // `C:/foo/bar` drive-prefixed forms.
        var abs_buf: [MAX_PATH:0]u8 = undefined;
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
        // Collect, in one pass, the ordered chain of rule nodes whose scope
        // covers this query — shallowest → deepest:
        //   [0]      = root ruleset (`by_dir[""]`), if any
        //   [1..N]   = the `.gitignore` at each directory prefix of `norm`
        //              that actually has a ruleset, in increasing depth
        // The synthetic `extra` node is handled separately since it always
        // sorts before everything else. Building this once turns the old
        // O(depth²) prefix re-walk (plus a duplicated leaf pass) into O(depth):
        // each hashmap lookup happens exactly once and both phases below reuse
        // the same array.
        var chain: [MAX_DIR_CHAIN]*IgnoreNode = undefined;
        var chain_len: usize = 0;
        var overflow = false;

        if (self.by_dir.get("")) |node| {
            chain[chain_len] = node;
            chain_len += 1;
        }
        {
            var off: usize = 0;
            while (mem.indexOfScalarPos(u8, normalized, off, '/')) |slash| {
                const dir = normalized[0..slash];
                if (self.by_dir.get(dir)) |node| {
                    if (chain_len == chain.len) {
                        overflow = true;
                        break;
                    }
                    chain[chain_len] = node;
                    chain_len += 1;
                }
                off = slash + 1;
            }
        }

        if (overflow) return self.isIgnoredPathSlow(normalized, basename, is_dir);

        // For every *ancestor directory* of the query, would that
        // ancestor itself be ignored? against every ruleset whose scope
        // covers it. If yes, the whole subtree is ignored
        var offset: usize = 0;
        while (mem.indexOfScalarPos(u8, normalized, offset, '/')) |slash| {
            const ancestor = normalized[0..slash];
            const ancestor_basename = if (mem.lastIndexOfScalar(u8, ancestor, '/')) |p|
                ancestor[p + 1 ..]
            else
                ancestor;

            if (self.extra) |x| {
                if (x.gi.checkWithBasename(ancestor, ancestor_basename, true)) |v| {
                    if (v) return true;
                }
            }
            for (chain[0..chain_len]) |node| {
                // A node only has scope over `ancestor` when its directory is
                // an ancestor-or-equal of it, i.e. `relative_offset` fits.
                if (node.relative_offset > ancestor.len) continue;
                if (node.gi.checkWithBasename(
                    ancestor[node.relative_offset..],
                    ancestor_basename,
                    true,
                )) |v| {
                    if (v) return true;
                }
            }
            offset = slash + 1;
        }

        // now we have to check every single node in the chain as git would do it
        if (self.extra) |x| {
            if (x.gi.checkWithBasename(normalized, basename, is_dir)) |verdict| {
                return verdict;
            }
        }
        var i: usize = chain_len;
        while (i > 0) {
            i -= 1;
            const node = chain[i];
            if (node.gi.checkWithBasename(
                normalized[node.relative_offset..],
                basename,
                is_dir,
            )) |verdict| {
                return verdict;
            }
        }
        return false;
    }

    fn isIgnoredPathSlow(
        self: *const IgnoreRules,
        norm: []const u8,
        basename: []const u8,
        is_dir: bool,
    ) bool {
        var off: usize = 0;
        while (mem.indexOfScalarPos(u8, norm, off, '/')) |slash| {
            const ancestor = norm[0..slash];
            const ancestor_basename = if (mem.lastIndexOfScalar(u8, ancestor, '/')) |p|
                ancestor[p + 1 ..]
            else
                ancestor;

            if (self.extra) |x| {
                if (x.gi.checkWithBasename(ancestor, ancestor_basename, true)) |v| {
                    if (v) return true;
                }
            }
            if (self.by_dir.get("")) |node| {
                if (node.gi.checkWithBasename(ancestor, ancestor_basename, true)) |v| {
                    if (v) return true;
                }
            }
            var mid_off: usize = 0;
            while (mem.indexOfScalarPos(u8, ancestor, mid_off, '/')) |mid_slash| {
                const mid_dir = ancestor[0..mid_slash];
                if (self.by_dir.get(mid_dir)) |node| {
                    if (node.gi.checkWithBasename(
                        ancestor[node.relative_offset..],
                        ancestor_basename,
                        true,
                    )) |v| {
                        if (v) return true;
                    }
                }
                mid_off = mid_slash + 1;
            }
            off = slash + 1;
        }

        if (self.extra) |x| {
            if (x.gi.checkWithBasename(norm, basename, is_dir)) |verdict| {
                return verdict;
            }
        }

        // Leaf resolution, deepest -> shallowest. Walk directory prefixes
        // from the deepest slash back toward the root, then the root ruleset.
        var end: usize = norm.len;
        while (mem.lastIndexOfScalar(u8, norm[0..end], '/')) |slash| {
            const dir = norm[0..slash];
            if (self.by_dir.get(dir)) |node| {
                if (node.gi.checkWithBasename(
                    norm[node.relative_offset..],
                    basename,
                    is_dir,
                )) |verdict| {
                    return verdict;
                }
            }
            end = slash;
        }
        if (self.by_dir.get("")) |node| {
            if (node.gi.checkWithBasename(norm, basename, is_dir)) |verdict| {
                return verdict;
            }
        }
        return false;
    }

    pub fn isIgnoredInode(
        self: *const IgnoreRules,
        node: *IgnoreNode,
        rel: []const u8,
        basename: []const u8,
        is_dir: bool,
    ) bool {
        if (self.extra) |x| {
            if (x.gi.checkWithBasename(rel, basename, is_dir)) |verdict| {
                return verdict;
            }
        }
        var cur: ?*IgnoreNode = node;
        while (cur) |n| : (cur = n.parent) {
            if (n.gi.checkWithBasename(rel[n.relative_offset..], basename, is_dir)) |verdict| {
                return verdict;
            }
        }
        return false;
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

const testing = std.testing;
const GitIgnore = @import("../gitignore.zig").GitIgnore;

/// Build an `IgnoreNode` for `dir_rel` (root-relative directory, "" = root)
/// from a `.gitignore`-style document. `relative_offset` is derived the same
/// way the walker does it (worker.zig).
fn testNode(alloc: std.mem.Allocator, dir_rel: []const u8, doc: []const u8) !*IgnoreNode {
    const gi = try GitIgnore.parse(alloc, doc);
    const node = try alloc.create(IgnoreNode);
    node.* = .{
        .parent = null,
        .gi = gi,
        .relative_offset = @intCast(if (dir_rel.len > 0) dir_rel.len + 1 else 0),
        .refs = .init(1),
    };
    return node;
}

fn expectFastEqualsSlow(rules: *const IgnoreRules, norm: []const u8, is_dir: bool) !void {
    const basename = if (mem.lastIndexOfScalar(u8, norm, '/')) |p| norm[p + 1 ..] else norm;
    const fast = rules.isIgnoredResolved(norm, basename, is_dir);
    const slow = rules.isIgnoredPathSlow(norm, basename, is_dir);
    testing.expectEqual(slow, fast) catch |err| {
        std.debug.print("mismatch for '{s}' (is_dir={}): fast={} slow={}\n", .{ norm, is_dir, fast, slow });
        return err;
    };
}

test "isIgnoredResolved: nested rules, ancestor pruning, negation, fast==slow" {
    const alloc = testing.allocator;
    var rules: IgnoreRules = .{ .allocator = alloc };
    defer rules.deinit();

    // root/.gitignore prunes `build/` entirely and ignores *.log everywhere.
    try rules.put("", try testNode(alloc, "", "build/\n*.log\n"));
    // root ref is held by `put`; drop the local creation ref.
    (rules.by_dir.get("").?).release(alloc);

    // src/.gitignore re-includes keep.log (negation) and ignores gen/.
    try rules.put("src", try testNode(alloc, "src", "!keep.log\ngen/\n"));
    (rules.by_dir.get("src").?).release(alloc);

    // Concrete expectations -------------------------------------------------
    // *.log ignored at root scope.
    try testing.expect(rules.isIgnoredResolved("a.log", "a.log", false));
    // build/ pruned: anything beneath it is ignored regardless of depth.
    try testing.expect(rules.isIgnoredResolved("build/x/y.c", "y.c", false));
    // src/keep.log is re-included by the nested negation → NOT ignored.
    try testing.expect(!rules.isIgnoredResolved("src/keep.log", "keep.log", false));
    // src/other.log still hits the root *.log rule.
    try testing.expect(rules.isIgnoredResolved("src/other.log", "other.log", false));
    // src/gen/ pruned by the nested rule.
    try testing.expect(rules.isIgnoredResolved("src/gen/out.o", "out.o", false));
    // A plain source file is not ignored.
    try testing.expect(!rules.isIgnoredResolved("src/main.zig", "main.zig", false));

    // Differential: fast path must equal slow path for a spread of queries,
    // both file and dir forms.
    const cases = [_][]const u8{
        "a.log",               "build",           "build/x",
        "build/x/y.c",         "src",             "src/keep.log",
        "src/other.log",       "src/gen",         "src/gen/out.o",
        "src/main.zig",        "src/nested/deep", "src/nested/deep/f.log",
        "unrelated/thing.txt", "keep.log",        "src/gen/sub/x.log",
    };
    for (cases) |c| {
        try expectFastEqualsSlow(&rules, c, false);
        try expectFastEqualsSlow(&rules, c, true);
    }
}

test "isIgnoredResolved: overflow beyond MAX_DIR_CHAIN falls back and matches" {
    const alloc = testing.allocator;
    var rules: IgnoreRules = .{ .allocator = alloc };
    defer rules.deinit();

    // Create a .gitignore at every directory level well past MAX_DIR_CHAIN so
    // the chain overflows and `isIgnoredPath` defers to the slow scan. Each
    // level ignores `dead` and the deepest ignores `target.txt`.
    var path_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer path_buf.deinit(alloc);
    const levels = MAX_DIR_CHAIN + 5;
    var i: usize = 0;
    while (i < levels) : (i += 1) {
        const dir = path_buf.items;
        const node = try testNode(alloc, dir, "dead\n");
        try rules.put(dir, node);
        node.release(alloc);
        if (path_buf.items.len > 0) try path_buf.append(alloc, '/');
        try path_buf.appendSlice(alloc, "d");
    }

    // A leaf that is `dead` under the deepest dir must still be ignored via the
    // slow fallback, and the fast/slow cores must agree at a shallow depth.
    var leaf: std.ArrayListUnmanaged(u8) = .empty;
    defer leaf.deinit(alloc);
    try leaf.appendSlice(alloc, path_buf.items);
    try leaf.appendSlice(alloc, "/dead");
    try testing.expect(rules.isIgnoredResolved(leaf.items, "dead", false));

    try expectFastEqualsSlow(&rules, "d/d/d/keep", false);
    try expectFastEqualsSlow(&rules, "d/d/d/dead", false);
}
