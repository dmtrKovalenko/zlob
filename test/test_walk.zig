//! End-to-end tests for the parallel file walker (zlob.walk).
//! Trees are created under the cwd-relative .zig-cache so the tests run on
//! every platform, exercising the native backend (getdents64 on Linux,
//! getattrlistbulk on macOS, NtQueryDirectoryFile on Windows).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const zlob = @import("zlob");
const walk = zlob.walk;

const TestTree = struct {
    io: std.Io,
    root_buf: [256]u8 = undefined,
    root: []const u8 = &.{},

    fn init(self: *TestTree, comptime tag: []const u8) !void {
        self.io = std.Io.Threaded.global_single_threaded.io();
        self.root = try std.fmt.bufPrint(&self.root_buf, ".zig-cache/walk-tests/{s}_{d}", .{
            tag,
            std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
        });
        try std.Io.Dir.cwd().createDirPath(self.io, self.root);
    }

    fn deinit(self: *TestTree) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
    }

    fn mkdir(self: *TestTree, rel: []const u8) !void {
        var buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.root, rel });
        try std.Io.Dir.cwd().createDir(self.io, p, .default_dir);
    }

    fn write(self: *TestTree, rel: []const u8, content: []const u8) !void {
        var buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.root, rel });
        var f = try std.Io.Dir.cwd().createFile(self.io, p, .{});
        defer f.close(self.io);
        try f.writeStreamingAll(self.io, content);
    }
};

fn findEntry(results: *const walk.Results, rel: []const u8) ?*const walk.Entry {
    for (results.entries) |*e| {
        if (std.mem.eql(u8, e.relPath(), rel)) return e;
    }
    return null;
}

test "walk basic tree: paths, kinds, depths, NUL termination" {
    var t: TestTree = .{ .io = undefined };
    try t.init("basic");
    defer t.deinit();

    try t.mkdir("src");
    try t.mkdir("src/sub");
    try t.write("a.txt", "aaa");
    try t.write("src/b.txt", "b");
    try t.write("src/sub/c.txt", "cc");

    var results = try walk.collect(testing.allocator, t.root, .{ .threads = 1, .sort = true });
    defer results.deinit();

    try testing.expectEqual(@as(usize, 5), results.entries.len);

    const a = findEntry(&results, "a.txt").?;
    try testing.expectEqual(walk.EntryKind.file, a.kind);
    try testing.expectEqual(@as(u16, 1), a.depth);
    try testing.expectEqualStrings("a.txt", a.basename);
    // NUL-terminated storage for zero-cost C interop
    try testing.expectEqual(@as(u8, 0), a.path.ptr[a.path.len]);
    // Full path = root + '/' + rel
    try testing.expect(std.mem.startsWith(u8, a.path, t.root));

    const src = findEntry(&results, "src").?;
    try testing.expectEqual(walk.EntryKind.directory, src.kind);

    const c = findEntry(&results, "src/sub/c.txt").?;
    try testing.expectEqual(@as(u16, 3), c.depth);
}

test "walk nested gitignore: deeper file overrides parent" {
    var t: TestTree = .{ .io = undefined };
    try t.init("gitignore");
    defer t.deinit();

    try t.mkdir("build");
    try t.mkdir("sub");
    try t.mkdir("sub/temp");
    try t.mkdir(".git");
    try t.write(".gitignore", "*.log\nbuild/\n");
    try t.write("build/artifact.o", "");
    try t.write("root.log", "");
    try t.write("keep.txt", "");
    try t.write("sub/.gitignore", "!important.log\ntemp/\n");
    try t.write("sub/important.log", "");
    try t.write("sub/other.log", "");
    try t.write("sub/temp/scratch.txt", "");
    try t.write(".git/config", "");

    var results = try walk.collect(testing.allocator, t.root, .{ .threads = 1, .sort = true });
    defer results.deinit();

    // Ignored by root .gitignore
    try testing.expect(findEntry(&results, "build") == null);
    try testing.expect(findEntry(&results, "build/artifact.o") == null);
    try testing.expect(findEntry(&results, "root.log") == null);
    // .git skipped by default
    try testing.expect(findEntry(&results, ".git") == null);
    try testing.expect(findEntry(&results, ".git/config") == null);
    // Deeper negation wins over parent "*.log"
    try testing.expect(findEntry(&results, "sub/important.log") != null);
    // Parent pattern still applies where not negated
    try testing.expect(findEntry(&results, "sub/other.log") == null);
    // Deeper dir-only pattern prunes
    try testing.expect(findEntry(&results, "sub/temp") == null);
    try testing.expect(findEntry(&results, "sub/temp/scratch.txt") == null);
    // Kept files (.gitignore files themselves are reported: they're not ignored)
    try testing.expect(findEntry(&results, "keep.txt") != null);
    try testing.expect(findEntry(&results, "sub") != null);

    // Same walk with gitignore disabled sees everything.
    var all = try walk.collect(testing.allocator, t.root, .{ .threads = 1, .respect_gitignore = false });
    defer all.deinit();
    try testing.expect(all.entries.len > results.entries.len);
    var found_git = false;
    for (all.entries) |*e| {
        if (std.mem.eql(u8, e.relPath(), ".git/config")) found_git = true;
    }
    try testing.expect(found_git);
}

test "walk include_hidden=false skips hidden files and dirs" {
    var t: TestTree = .{ .io = undefined };
    try t.init("hidden");
    defer t.deinit();

    try t.mkdir(".cache");
    try t.write(".cache/data", "");
    try t.write(".env", "");
    try t.write("visible.txt", "");

    var results = try walk.collect(testing.allocator, t.root, .{
        .threads = 1,
        .include_hidden = false,
        .respect_gitignore = false,
    });
    defer results.deinit();

    try testing.expectEqual(@as(usize, 1), results.entries.len);
    try testing.expectEqualStrings("visible.txt", results.entries[0].basename);
}

test "walk max_depth limits traversal" {
    var t: TestTree = .{ .io = undefined };
    try t.init("depth");
    defer t.deinit();

    try t.mkdir("d1");
    try t.mkdir("d1/d2");
    try t.write("top.txt", "");
    try t.write("d1/mid.txt", "");
    try t.write("d1/d2/deep.txt", "");

    var results = try walk.collect(testing.allocator, t.root, .{ .threads = 1, .max_depth = 1 });
    defer results.deinit();
    try testing.expectEqual(@as(usize, 2), results.entries.len); // top.txt + d1

    var results2 = try walk.collect(testing.allocator, t.root, .{ .threads = 1, .max_depth = 2 });
    defer results2.deinit();
    try testing.expectEqual(@as(usize, 4), results2.entries.len); // + d1/mid.txt + d1/d2
}

test "walk metadata: size/mtime/inode/mode" {
    var t: TestTree = .{ .io = undefined };
    try t.init("meta");
    defer t.deinit();

    try t.write("five.bin", "12345");

    var results = try walk.collect(testing.allocator, t.root, .{
        .threads = 1,
        .meta = .{ .size = true, .mtime = true, .inode = true, .mode = true },
    });
    defer results.deinit();

    try testing.expectEqual(@as(usize, 1), results.entries.len);
    const e = &results.entries[0];
    try testing.expect(e.meta.valid.size);
    try testing.expectEqual(@as(u64, 5), e.meta.size);
    try testing.expect(e.meta.valid.mtime);
    try testing.expect(e.meta.mtime_ns > 0);
    try testing.expect(e.meta.valid.inode);
    try testing.expect(e.meta.inode != 0);
    if (e.meta.valid.mode) {
        try testing.expect(e.meta.mode & 0o400 != 0); // owner-readable
    }
}

test "walk visitor: skip_dir prunes, stop halts" {
    var t: TestTree = .{ .io = undefined };
    try t.init("visitor");
    defer t.deinit();

    try t.mkdir("skipme");
    try t.write("skipme/inner.txt", "");
    try t.write("a.txt", "");
    try t.write("b.txt", "");

    const Ctx = struct {
        count: usize = 0,
        saw_inner: bool = false,

        fn visit(ctx_ptr: ?*anyopaque, entry: *const walk.Entry) walk.VisitAction {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
            self.count += 1;
            if (std.mem.eql(u8, entry.basename, "inner.txt")) self.saw_inner = true;
            if (std.mem.eql(u8, entry.basename, "skipme")) return .skip_dir;
            return .cont;
        }
    };

    var ctx = Ctx{};
    try walk.run(testing.allocator, t.root, .{ .threads = 1 }, .{
        .context = @ptrCast(&ctx),
        .visit = Ctx.visit,
    });
    try testing.expectEqual(@as(usize, 3), ctx.count); // a.txt, b.txt, skipme
    try testing.expect(!ctx.saw_inner);

    const StopCtx = struct {
        count: usize = 0,
        fn visit(ctx_ptr: ?*anyopaque, entry: *const walk.Entry) walk.VisitAction {
            _ = entry;
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
            self.count += 1;
            return .stop;
        }
    };
    var stop_ctx = StopCtx{};
    try walk.run(testing.allocator, t.root, .{ .threads = 1 }, .{
        .context = @ptrCast(&stop_ctx),
        .visit = StopCtx.visit,
    });
    try testing.expectEqual(@as(usize, 1), stop_ctx.count);
}

test "walk parallel matches serial results" {
    var t: TestTree = .{ .io = undefined };
    try t.init("parallel");
    defer t.deinit();

    // Wide-ish tree to actually exercise multiple workers.
    var name_buf: [64]u8 = undefined;
    for (0..8) |i| {
        const d = try std.fmt.bufPrint(&name_buf, "dir{d}", .{i});
        try t.mkdir(d);
        for (0..16) |j| {
            const f = try std.fmt.bufPrint(&name_buf, "dir{d}/file{d}.txt", .{ i, j });
            try t.write(f, "x");
        }
        const sub = try std.fmt.bufPrint(&name_buf, "dir{d}/nested", .{i});
        try t.mkdir(sub);
        const nf = try std.fmt.bufPrint(&name_buf, "dir{d}/nested/n.txt", .{i});
        try t.write(nf, "y");
    }
    try t.write(".gitignore", "*.skip\n");
    try t.write("dir0/x.skip", "");

    // Thread-safe allocator required for parallel walks.
    const gpa = std.heap.smp_allocator;

    var serial = try walk.collect(gpa, t.root, .{ .threads = 1, .sort = true });
    defer serial.deinit();
    var parallel = try walk.collect(gpa, t.root, .{ .threads = 4, .sort = true });
    defer parallel.deinit();

    try testing.expectEqual(serial.entries.len, parallel.entries.len);
    for (serial.entries, parallel.entries) |*s, *p| {
        try testing.expectEqualStrings(s.path, p.path);
        try testing.expectEqual(s.kind, p.kind);
        try testing.expectEqual(s.depth, p.depth);
    }
    // 8 dirs + 8 nested dirs + 128 files + 8 nested files + .gitignore - x.skip(ignored)
    try testing.expectEqual(@as(usize, 8 + 8 + 128 + 8 + 1), serial.entries.len);
}

test "walk empty root and missing root" {
    var t: TestTree = .{ .io = undefined };
    try t.init("empty");
    defer t.deinit();

    var results = try walk.collect(testing.allocator, t.root, .{ .threads = 1 });
    defer results.deinit();
    try testing.expectEqual(@as(usize, 0), results.entries.len);

    // Missing root: errors are reported via callback; without abort_on_error
    // the walk completes with zero entries.
    var missing = try walk.collect(testing.allocator, "zlob-walk-definitely-missing-xyz", .{ .threads = 1 });
    defer missing.deinit();
    try testing.expectEqual(@as(usize, 0), missing.entries.len);

    // With abort_on_error it aborts.
    try testing.expectError(error.Aborted, walk.collect(testing.allocator, "zlob-walk-definitely-missing-xyz", .{
        .threads = 1,
        .abort_on_error = true,
    }));
}

test "walk glob pattern: filters entries and prunes out-of-scope dirs" {
    var t: TestTree = .{ .io = undefined };
    try t.init("glob");
    defer t.deinit();

    try t.mkdir("src");
    try t.mkdir("src/deep");
    try t.mkdir("lib");
    try t.mkdir("docs");
    try t.write("src/a.rs", "");
    try t.write("src/b.txt", "");
    try t.write("src/deep/e.rs", "");
    try t.write("lib/c.rs", "");
    try t.write("docs/d.md", "");
    try t.write("top.rs", "");

    // Recursive extension filter across the whole tree.
    {
        var results = try walk.collect(testing.allocator, t.root, .{
            .threads = 1,
            .sort = true,
            .pattern = "**/*.rs",
        });
        defer results.deinit();
        try testing.expectEqual(@as(usize, 4), results.entries.len);
        try testing.expectEqualStrings("lib/c.rs", results.entries[0].relPath());
        try testing.expectEqualStrings("src/a.rs", results.entries[1].relPath());
        try testing.expectEqualStrings("src/deep/e.rs", results.entries[2].relPath());
        try testing.expectEqualStrings("top.rs", results.entries[3].relPath());
    }

    // Anchored pattern: only the src/ subtree is reported ("src/**" also
    // matches "src" itself — ** spans zero components, like bash globstar).
    {
        var results = try walk.collect(testing.allocator, t.root, .{
            .threads = 1,
            .sort = true,
            .pattern = "src/**",
        });
        defer results.deinit();
        for (results.entries) |*e| {
            try testing.expect(std.mem.startsWith(u8, e.relPath(), "src"));
        }
        try testing.expectEqual(@as(usize, 5), results.entries.len); // src, a.rs, b.txt, deep, deep/e.rs
    }

    // Brace pattern.
    {
        var results = try walk.collect(testing.allocator, t.root, .{
            .threads = 1,
            .pattern = "**/*.{md,txt}",
        });
        defer results.deinit();
        try testing.expectEqual(@as(usize, 2), results.entries.len);
    }
}

test "walk follow_symlinks: descends links, breaks cycles, never re-walks root" {
    // The ntdll backend doesn't implement symlink following (documented).
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var t: TestTree = .{ .io = undefined };
    try t.init("symlinks");
    defer t.deinit();

    // The walk root is t.root/tree; outside/ is a sibling, only reachable
    // through the symlink.
    try t.mkdir("tree");
    try t.mkdir("outside");
    try t.write("tree/a.txt", "a");
    try t.write("outside/o.txt", "o");

    var lbuf: [512]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    // tree/link -> ../outside : descended under follow mode.
    try cwd.symLink(t.io, "../outside", try std.fmt.bufPrint(&lbuf, "{s}/tree/link", .{t.root}), .{});
    // tree/back -> . : resolves to the walk root itself; must not re-walk.
    try cwd.symLink(t.io, ".", try std.fmt.bufPrint(&lbuf, "{s}/tree/back", .{t.root}), .{});
    // outside/self -> ../outside : a cycle; the walk must terminate.
    try cwd.symLink(t.io, "../outside", try std.fmt.bufPrint(&lbuf, "{s}/outside/self", .{t.root}), .{});

    var root_buf: [512]u8 = undefined;
    const walk_root = try std.fmt.bufPrint(&root_buf, "{s}/tree", .{t.root});

    // Without follow: links are reported but never descended.
    {
        var results = try walk.collect(testing.allocator, walk_root, .{ .threads = 1, .sort = true });
        defer results.deinit();
        try testing.expectEqual(@as(usize, 3), results.entries.len); // a.txt, back, link
        try testing.expectEqual(walk.EntryKind.sym_link, findEntry(&results, "link").?.kind);
        try testing.expect(findEntry(&results, "link/o.txt") == null);
    }

    // With follow: link/ is descended, the self-cycle is broken, and the
    // back-to-root link does not duplicate root entries.
    {
        var results = try walk.collect(testing.allocator, walk_root, .{
            .threads = 1,
            .sort = true,
            .follow_symlinks = true,
        });
        defer results.deinit();

        try testing.expect(findEntry(&results, "link/o.txt") != null);
        // outside/ was already visited via link, so the cycle link is
        // reported but not descended.
        try testing.expect(findEntry(&results, "link/self") != null);
        try testing.expect(findEntry(&results, "link/self/o.txt") == null);

        var a_count: usize = 0;
        for (results.entries) |*e| {
            // Nothing may be reported through the root-cycling link.
            try testing.expect(!std.mem.startsWith(u8, e.relPath(), "back/"));
            if (std.mem.eql(u8, e.relPath(), "a.txt")) a_count += 1;
        }
        try testing.expectEqual(@as(usize, 1), a_count);
        // a.txt, back, link, link/o.txt, link/self
        try testing.expectEqual(@as(usize, 5), results.entries.len);
    }
}

test "walk error callback: receives path and errno, nonzero return aborts" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no POSIX chmod
    var t: TestTree = .{ .io = undefined };
    try t.init("errfunc");
    defer t.deinit();

    try t.mkdir("ok");
    try t.mkdir("locked");
    try t.write("ok/file.txt", "x");
    try t.write("locked/hidden.txt", "y");

    var path_buf: [512:0]u8 = undefined;
    const locked_path = try std.fmt.bufPrintZ(&path_buf, "{s}/locked", .{t.root});
    if (std.c.chmod(locked_path.ptr, 0) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(locked_path.ptr, 0o755);
    // Root opens mode-000 dirs anyway; the test needs a real EACCES.
    if (std.c.getuid() == 0) return error.SkipZigTest;

    const Cb = struct {
        var calls: usize = 0;
        var saw_locked: bool = false;
        var last_errno: c_int = 0;
        fn record(epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int {
            calls += 1;
            last_errno = eerrno;
            if (std.mem.endsWith(u8, std.mem.sliceTo(epath, 0), "/locked")) saw_locked = true;
            return 0;
        }
        fn abort(epath: [*:0]const u8, eerrno: c_int) callconv(.c) c_int {
            _ = epath;
            _ = eerrno;
            return 1;
        }
    };

    // Ignoring the error: the rest of the tree is still walked, the locked
    // dir itself is reported (it came from the parent's listing) but its
    // contents are not.
    {
        var results = try walk.collect(testing.allocator, t.root, .{
            .threads = 1,
            .sort = true,
            .err_callback = Cb.record,
        });
        defer results.deinit();
        try testing.expectEqual(@as(usize, 1), Cb.calls);
        try testing.expect(Cb.saw_locked);
        try testing.expectEqual(@intFromEnum(std.c.E.ACCES), Cb.last_errno);
        try testing.expectEqual(@as(usize, 3), results.entries.len); // locked, ok, ok/file.txt
        try testing.expect(findEntry(&results, "locked/hidden.txt") == null);
    }

    // A nonzero callback return aborts the walk.
    try testing.expectError(error.Aborted, walk.collect(testing.allocator, t.root, .{
        .threads = 1,
        .err_callback = Cb.abort,
    }));
}

test "walk glob pattern prunes: out-of-scope unreadable dir is never opened" {
    // Pruning proof: an unreadable directory outside the pattern's literal
    // prefix would fail the walk with abort_on_error — unless it was pruned
    // before ever being opened.
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no POSIX chmod
    var t: TestTree = .{ .io = undefined };
    try t.init("glob_prune");
    defer t.deinit();

    try t.mkdir("src");
    try t.mkdir("locked");
    try t.write("src/a.rs", "");
    try t.write("locked/secret.rs", "");

    var path_buf: [512:0]u8 = undefined;
    const locked_path = try std.fmt.bufPrintZ(&path_buf, "{s}/locked", .{t.root});
    if (std.c.chmod(locked_path.ptr, 0) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(locked_path.ptr, 0o755);
    // Root can open mode-000 dirs anyway — the pruning proof needs EACCES.
    if (std.c.getuid() == 0) return error.SkipZigTest;

    // Without a pattern the unreadable dir aborts the walk...
    try testing.expectError(error.Aborted, walk.collect(testing.allocator, t.root, .{
        .threads = 1,
        .abort_on_error = true,
    }));

    // ...with a scoped pattern it is pruned before being opened.
    var results = try walk.collect(testing.allocator, t.root, .{
        .threads = 1,
        .abort_on_error = true,
        .pattern = "src/**/*.rs",
    });
    defer results.deinit();
    try testing.expectEqual(@as(usize, 1), results.entries.len);
    try testing.expectEqualStrings("src/a.rs", results.entries[0].relPath());
}
