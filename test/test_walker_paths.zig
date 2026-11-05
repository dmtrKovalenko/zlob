// vibe coded based on the path report from fff which was caused by non-libc target
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const walker = @import("walker");

const seg_len = 60;
const seg: [seg_len]u8 = @splat('d');

const Tree = struct {
    io: std.Io,
    root_buf: [256]u8 = undefined,
    root: []const u8 = &.{},

    fn init(self: *Tree, comptime tag: []const u8) !void {
        self.io = std.Io.Threaded.global_single_threaded.io();
        self.root = try std.fmt.bufPrint(&self.root_buf, ".zig-cache/walker-path-tests/{s}_{d}", .{
            tag,
            std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
        });
        try std.Io.Dir.cwd().createDirPath(self.io, self.root);
    }

    fn deinit(self: *Tree) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
    }

    fn mkdirs(self: *Tree, rel: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.root, rel });
        try std.Io.Dir.cwd().createDirPath(self.io, p);
    }

    fn touch(self: *Tree, rel: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.root, rel });
        var f = try std.Io.Dir.cwd().createFile(self.io, p, .{});
        f.close(self.io);
    }
};

/// Walk `root` and return the path reported for the single entry whose
/// basename is `leaf`, duplicated into `allocator` (Entry.path points into
/// the walker's own reusable buffer).
fn findLeaf(
    comptime be: walker.Backend,
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    leaf: []const u8,
) !?[]u8 {
    var w = try walker.WalkerType(be).init(allocator, io, root, .{ .max_depth = 64 });
    defer w.deinit();
    while (try w.next()) |entry| {
        if (std.mem.eql(u8, entry.basename, leaf)) return try allocator.dupe(u8, entry.path);
    }
    return null;
}

/// Two sibling directories nested deep enough that their paths exceed 256
/// bytes. Because the stack is LIFO, the second one pushed is popped first and
/// overwrites the shared path buffer, so the first one's path has to survive
/// intact rather than keeping a stale tail from its sibling.
fn deepSiblingsCase(comptime be: walker.Backend) !void {
    const allocator = testing.allocator;

    var tree: Tree = .{ .io = undefined };
    try tree.init("deep_siblings");
    defer tree.deinit();

    const prefix = seg ++ "/" ++ seg ++ "/" ++ seg ++ "/" ++ seg;
    const a_dir = prefix ++ "/" ++ @as([seg_len]u8, @splat('a'));
    const b_dir = prefix ++ "/" ++ @as([seg_len]u8, @splat('b'));

    try tree.mkdirs(a_dir);
    try tree.mkdirs(b_dir);
    try tree.touch(a_dir ++ "/a_leaf.txt");
    try tree.touch(b_dir ++ "/b_leaf.txt");

    const a_path = try findLeaf(be, allocator, tree.io, tree.root, "a_leaf.txt") orelse
        return error.LeafNotFound;
    defer allocator.free(a_path);
    const b_path = try findLeaf(be, allocator, tree.io, tree.root, "b_leaf.txt") orelse
        return error.LeafNotFound;
    defer allocator.free(b_path);

    // Well past the 256-byte stash the getdents64 backend used to truncate at.
    try testing.expect(a_path.len > 256);

    try testing.expectEqualStrings(a_dir ++ "/a_leaf.txt", a_path);
    try testing.expectEqualStrings(b_dir ++ "/b_leaf.txt", b_path);
}

/// A chain deeper than any per-entry stash, walked with no siblings to
/// clobber the buffer — guards the plain nesting case.
fn deepChainCase(comptime be: walker.Backend) !void {
    const allocator = testing.allocator;

    var tree: Tree = .{ .io = undefined };
    try tree.init("deep_chain");
    defer tree.deinit();

    const chain = seg ++ "/" ++ seg ++ "/" ++ seg ++ "/" ++ seg ++ "/" ++ seg ++ "/" ++ seg;
    try tree.mkdirs(chain);
    try tree.touch(chain ++ "/leaf.txt");

    const path = try findLeaf(be, allocator, tree.io, tree.root, "leaf.txt") orelse
        return error.LeafNotFound;
    defer allocator.free(path);

    try testing.expect(path.len > 256);
    try testing.expectEqualStrings(chain ++ "/leaf.txt", path);
}

test "std_fs backend: long sibling paths stay intact" {
    try deepSiblingsCase(.std_fs);
}

test "std_fs backend: deep chain path stays intact" {
    try deepChainCase(.std_fs);
}

test "getdents64 backend: long sibling paths stay intact" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try deepSiblingsCase(.getdents64);
}

test "getdents64 backend: deep chain path stays intact" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try deepChainCase(.getdents64);
}

test "walkers skip overlong paths and keep entries that fit" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tree: Tree = .{ .io = undefined };
    try tree.init("overlong_paths");
    defer tree.deinit();

    var dir = try std.Io.Dir.cwd().openDir(tree.io, tree.root, .{});
    defer dir.close(tree.io);
    const segment: [255]u8 = @splat('d');
    for (0..16) |i| {
        const name = if (i == 15) segment[0..254] else segment[0..];
        try dir.createDir(tree.io, name, .default_dir);
        const next = try dir.openDir(tree.io, name, .{});
        dir.close(tree.io);
        dir = next;
    }
    try dir.createDir(tree.io, "too-long", .default_dir);
    try dir.createDir(tree.io, "also-long", .default_dir);
    const file = try dir.createFile(tree.io, "f", .{});
    file.close(tree.io);

    inline for (.{ walker.Backend.getdents64, walker.Backend.std_fs }) |backend| {
        for ([_]bool{ false, true }) |sorted| {
            var w = try walker.WalkerType(backend).init(testing.allocator, tree.io, tree.root, .{ .sorted = sorted });
            defer w.deinit();
            var saw_file = false;
            while (try w.next()) |entry| {
                try testing.expect(entry.path.len <= 4096);
                if (std.mem.eql(u8, entry.basename, "f")) {
                    try testing.expectEqual(@as(usize, 4096), entry.path.len);
                    saw_file = true;
                }
            }
            try testing.expect(saw_file);
        }
    }
}

const DirectorySwap = struct {
    io: std.Io,
    dir: std.Io.Dir,
    swapped: bool = false,
    failure: ?anyerror = null,

    fn swap(self: *DirectorySwap, name: []const u8) !void {
        try self.dir.deleteDir(self.io, name);
        try self.dir.symLink(self.io, "../target", name, .{});
        self.swapped = true;
    }

    fn filter(ctx: *anyopaque, _: []const u8, name: []const u8) bool {
        const self: *DirectorySwap = @ptrCast(@alignCast(ctx));
        self.swap(name) catch |err| {
            self.failure = err;
            return false;
        };
        return true;
    }
};

test "walkers reject a directory replaced by a symlink before open" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tree: Tree = .{ .io = undefined };
    try tree.init("directory_swap");
    defer tree.deinit();
    try tree.mkdirs("scan");
    try tree.mkdirs("target");
    try tree.touch("target/outside.txt");

    var scan_path: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&scan_path, "{s}/scan", .{tree.root});
    var dir = try std.Io.Dir.cwd().openDir(tree.io, path, .{});
    defer dir.close(tree.io);

    inline for (.{ walker.Backend.getdents64, walker.Backend.std_fs }) |backend| {
        for ([_]bool{ false, true }) |sorted| {
            try dir.createDir(tree.io, "child", .default_dir);
            var swap = DirectorySwap{ .io = tree.io, .dir = dir };
            var w = try walker.WalkerType(backend).init(testing.allocator, tree.io, path, .{
                .sorted = sorted,
                .dir_filter = .{ .filterDirFn = DirectorySwap.filter, .context = &swap },
            });
            defer w.deinit();
            while (try w.next()) |entry| {
                try testing.expect(!std.mem.eql(u8, entry.basename, "outside.txt"));
            }
            if (swap.failure) |err| return err;
            try testing.expect(swap.swapped);
            try dir.deleteFile(tree.io, "child");
        }
    }
}

// The two backends are meant to be interchangeable, so a tree with mixed
// name lengths and nesting must produce the exact same set of paths.
test "backends agree on the entry set" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var tree: Tree = .{ .io = undefined };
    try tree.init("backend_parity");
    defer tree.deinit();

    const deep = seg ++ "/" ++ seg ++ "/" ++ seg ++ "/" ++ seg ++ "/" ++ seg;
    try tree.mkdirs(deep);
    try tree.mkdirs("short/nested");
    try tree.touch(deep ++ "/deep.txt");
    try tree.touch("short/nested/file.txt");
    try tree.touch("short/top.txt");

    var sets: [2]std.ArrayList([]u8) = .{ .empty, .empty };
    defer for (&sets) |*s| {
        for (s.items) |p| allocator.free(p);
        s.deinit(allocator);
    };

    inline for (.{ walker.Backend.getdents64, walker.Backend.std_fs }, 0..) |be, i| {
        var w = try walker.WalkerType(be).init(allocator, tree.io, tree.root, .{ .max_depth = 64 });
        defer w.deinit();
        while (try w.next()) |entry| {
            try sets[i].append(allocator, try allocator.dupe(u8, entry.path));
        }
    }

    // Traversal order differs between backends; compare as sorted sets.
    for (&sets) |*s| std.mem.sort([]u8, s.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    try testing.expectEqual(sets[0].items.len, sets[1].items.len);
    for (sets[0].items, sets[1].items) |a, b| try testing.expectEqualStrings(a, b);
}

test "getdents64 backend: follow_symlinks breaks ancestor cycles, walks siblings once" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var tree: Tree = .{ .io = undefined };
    try tree.init("follow_cycles");
    defer tree.deinit();

    // a/b/f.txt, c/c.txt, c/d/d.txt; a/b/{up -> .., root -> ../.., side -> ../../c}
    try tree.mkdirs("a/b");
    try tree.mkdirs("c/d");
    try tree.touch("a/b/f.txt");
    try tree.touch("c/c.txt");
    try tree.touch("c/d/d.txt");
    var lbuf: [4096]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    try cwd.symLink(tree.io, "..", try std.fmt.bufPrint(&lbuf, "{s}/a/b/up", .{tree.root}), .{});
    try cwd.symLink(tree.io, "../..", try std.fmt.bufPrint(&lbuf, "{s}/a/b/root", .{tree.root}), .{});
    try cwd.symLink(tree.io, "../../c", try std.fmt.bufPrint(&lbuf, "{s}/a/b/side", .{tree.root}), .{});
    // a/b/absout -> <absolute path of>/c: an absolute target is followed too
    // (and counts as the one visit of c/ when reached first).
    {
        var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var rel_c: [4096]u8 = undefined;
        const c_rel = try std.fmt.bufPrint(&rel_c, "{s}/c", .{tree.root});
        const c_abs = abs_buf[0..try cwd.realPathFile(tree.io, c_rel, &abs_buf)];
        try cwd.symLink(tree.io, c_abs, try std.fmt.bufPrint(&lbuf, "{s}/a/b/absout", .{tree.root}), .{});
    }

    var w = try walker.WalkerType(.getdents64).init(allocator, tree.io, tree.root, .{
        .max_depth = 64,
        .follow_symlinks = true,
    });
    defer w.deinit();

    var total: usize = 0;
    var f_count: usize = 0;
    var c_leaves: usize = 0;
    var d_leaves: usize = 0;
    var saw_up = false;
    var saw_root = false;
    var saw_side = false;
    while (try w.next()) |entry| {
        total += 1;
        // A runaway cycle would never end; cap it so a regression fails
        // instead of hanging.
        try testing.expect(total < 200);
        const p = entry.path;
        try testing.expect(!std.mem.startsWith(u8, p, "a/b/up/"));
        try testing.expect(!std.mem.startsWith(u8, p, "a/b/root/"));
        if (std.mem.eql(u8, p, "a/b/up")) saw_up = true;
        if (std.mem.eql(u8, p, "a/b/root")) saw_root = true;
        if (std.mem.eql(u8, p, "a/b/side")) saw_side = true;
        if (std.mem.eql(u8, p, "a/b/f.txt")) f_count += 1;
        if (std.mem.endsWith(u8, p, "/c.txt")) c_leaves += 1;
        if (std.mem.endsWith(u8, p, "/d.txt")) d_leaves += 1;
    }
    try testing.expect(saw_up and saw_root and saw_side);
    try testing.expectEqual(@as(usize, 1), f_count);
    // c/ is entered exactly once, via the real dir or the sibling link.
    try testing.expectEqual(@as(usize, 1), c_leaves);
    try testing.expectEqual(@as(usize, 1), d_leaves);
}
