// vibe coded based on the path report from fff which was caused by non-libc target
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const walker = @import("walker");

const seg_len = 60;
const seg = "d" ** seg_len;

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
    const a_dir = prefix ++ "/" ++ "a" ** seg_len;
    const b_dir = prefix ++ "/" ++ "b" ** seg_len;

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
