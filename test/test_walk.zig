//! End-to-end tests for the walker public api

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const zlob = @import("zlob");
const walk = zlob.walk;
const GitIgnore = @import("zlob_core").GitIgnore;

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

fn findEntry(results: *const walk.WalkerResult, rel: []const u8) ?*const walk.Entry {
    for (results.entries) |*e| {
        if (std.mem.eql(u8, e.relativePath(), rel)) return e;
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
    try testing.expectEqualStrings("a.txt", a.basename());
    // NUL-terminated storage for zero-cost C interop
    try testing.expectEqual(@as(u8, 0), a.path.ptr[a.path.len]);
    // Full path = root + '/' + rel
    try testing.expect(std.mem.startsWith(u8, a.path, t.root));

    const src = findEntry(&results, "src").?;
    try testing.expectEqual(walk.EntryKind.directory, src.kind);

    const c = findEntry(&results, "src/sub/c.txt").?;
    try testing.expectEqual(@as(u16, 3), c.depth);
}

test "walk unicode and invalid-UTF-8 names: byte-exact paths and offsets" {
    var t: TestTree = .{ .io = undefined };
    try t.init("unicode");
    defer t.deinit();

    try t.mkdir("ünïcode");
    try t.mkdir("ünïcode/日本語ディレクトリ");
    try t.write("ünïcode/日本語ディレクトリ/файл-🚀.txt", "x");

    // POSIX filenames are arbitrary bytes; names with invalid UTF-8 (from the
    // fff#799 reproducer) must round-trip byte-exact through the walker.
    // Only Linux filesystems reliably accept them.
    const invalid_dir = "#fq\x1c\xf0\x2a\x038k9\x8b\x0b\x95\x82K";
    const invalid_file = "\x07\xfa\x04yA!\xfa\xd9\xf1zR\xa3s\xa6";
    var expect_total: usize = 3;
    if (builtin.os.tag == .linux) {
        try t.mkdir(invalid_dir);
        try t.write(invalid_dir ++ "/" ++ invalid_file, "");
        expect_total += 2;
    }

    var results = try walk.collect(testing.allocator, t.root, .{ .threads = 1, .sort = true });
    defer results.deinit();
    try testing.expectEqual(expect_total, results.entries.len);

    // Offsets are byte offsets and must hold for every entry regardless of
    // how the name decodes: relative part starts right after "root/", the
    // basename right after the last '/'.
    for (results.entries) |*e| {
        try testing.expect(std.mem.startsWith(u8, e.path, t.root));
        try testing.expectEqual(t.root.len + 1, e.relative_offset);
        try testing.expectEqual(@as(u8, '/'), e.path[e.relative_offset - 1]);
        const last_slash = std.mem.lastIndexOfScalar(u8, e.path, '/').?;
        try testing.expectEqualStrings(e.path[last_slash + 1 ..], e.basename());
    }

    const rocket = findEntry(&results, "ünïcode/日本語ディレクトリ/файл-🚀.txt").?;
    try testing.expectEqualStrings("файл-🚀.txt", rocket.basename());
    try testing.expectEqual(@as(u16, 3), rocket.depth);
    try testing.expectEqual(walk.EntryKind.file, rocket.kind);

    if (builtin.os.tag == .linux) {
        const deep = findEntry(&results, invalid_dir ++ "/" ++ invalid_file).?;
        try testing.expectEqualStrings(invalid_file, deep.basename());
        try testing.expectEqual(walk.EntryKind.file, deep.kind);
        try testing.expectEqual(walk.EntryKind.directory, findEntry(&results, invalid_dir).?.kind);
    }
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
    var all = try walk.collect(testing.allocator, t.root, .{ .threads = 1, .respect_git = false });
    defer all.deinit();
    try testing.expect(all.entries.len > results.entries.len);
    var found_git = false;
    for (all.entries) |*e| {
        if (std.mem.eql(u8, e.relativePath(), ".git/config")) found_git = true;
    }
    try testing.expect(found_git);
}

// Regression: https://github.com/dmtrKovalenko/fff/issues/723
//
// The "ignore everything, then allow back" .gitignore idiom. `!/**/` is a
// dir-only negation that re-includes every directory, which is the only reason
// the walk may descend at all; `!*.*` re-includes extensioned files. If the
// dir-only negation is dropped, every subdirectory stays ignored and gets
// pruned, so the walker reports top-level files only — the reported symptom.
//
// The expected set is exactly what `git add -A -n` stages for this tree, plus
// the directories (git does not track directories, walkers report them). The
// `ignore` crate agrees.
test "walk allowlist gitignore: '*' + '!*.*' + '!/**/' descends into subdirs" {
    var t: TestTree = .{ .io = undefined };
    try t.init("gitignore_allowlist");
    defer t.deinit();

    try t.mkdir("src");
    try t.mkdir("src/deep");
    try t.mkdir("dir.d");
    try t.mkdir("plain");
    try t.mkdir(".git");
    try t.write(".gitignore",
        \\# Ignore all
        \\*
        \\
        \\# Unignore all with extensions
        \\!*.*
        \\
        \\# Unignore all dirs
        \\!/**/
        \\
    );
    try t.write("main.rs", "");
    try t.write("Makefile", "");
    try t.write(".keep", "");
    try t.write("src/lib.rs", "");
    try t.write("src/noext", "");
    try t.write("src/deep/a.txt", "");
    try t.write("dir.d/x.md", "");
    try t.write("dir.d/noext", "");
    try t.write("plain/y.txt", "");
    try t.write(".git/config", "");

    // Serial and parallel must agree; the bug shows up in both.
    for ([_]u16{ 1, 4 }) |threads| {
        var results = try walk.collect(testing.allocator, t.root, .{
            .threads = threads,
            .sort = true,
        });
        defer results.deinit();

        // Directories are re-included by `!/**/`, so the walk descends.
        // `plain/` is the important one: its name has no dot, so *only* the
        // dir-only negation can save it.
        const kept = [_][]const u8{
            ".gitignore", ".keep",       "dir.d", "dir.d/x.md", "main.rs",
            "plain",      "plain/y.txt", "src",   "src/deep",   "src/deep/a.txt",
            "src/lib.rs",
        };
        for (kept) |rel| {
            if (findEntry(&results, rel) == null) {
                std.debug.print("threads={d}: missing entry '{s}'\n", .{ threads, rel });
                return error.TestExpectedEntry;
            }
        }

        // Extensionless files are never re-included by `!*.*`.
        const dropped = [_][]const u8{
            "Makefile", "src/noext", "dir.d/noext", ".git", ".git/config",
        };
        for (dropped) |rel| {
            if (findEntry(&results, rel) != null) {
                std.debug.print("threads={d}: unexpected entry '{s}'\n", .{ threads, rel });
                return error.TestUnexpectedEntry;
            }
        }

        // Nothing else may sneak in.
        try testing.expectEqual(kept.len, results.entries.len);
    }
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
        .respect_git = false,
    });
    defer results.deinit();

    try testing.expectEqual(@as(usize, 1), results.entries.len);
    try testing.expectEqualStrings("visible.txt", results.entries[0].basename());
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
    try testing.expectEqual(@as(usize, 1), results.metas.len);
    const e = &results.entries[0];
    const meta = e.meta.?;
    try testing.expect(meta.valid.size);
    try testing.expectEqual(@as(u64, 5), meta.size);
    try testing.expect(meta.valid.mtime);
    try testing.expect(meta.mtime_ns > 0);
    try testing.expect(meta.valid.inode);
    try testing.expect(meta.inode != 0);
    if (meta.valid.mode) {
        try testing.expect(meta.mode & 0o400 != 0); // owner-readable
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
            if (std.mem.eql(u8, entry.basename(), "inner.txt")) self.saw_inner = true;
            if (std.mem.eql(u8, entry.basename(), "skipme")) return .skip_dir;
            return .cont;
        }
    };

    var ctx = Ctx{};
    {
        const rules = try walk.run(testing.allocator, t.root, .{ .threads = 1 }, .{
            .context = @ptrCast(&ctx),
            .visit = Ctx.visit,
        });
        rules.deinit();
        testing.allocator.destroy(rules);
    }
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
    {
        const rules = try walk.run(testing.allocator, t.root, .{ .threads = 1 }, .{
            .context = @ptrCast(&stop_ctx),
            .visit = StopCtx.visit,
        });
        rules.deinit();
        testing.allocator.destroy(rules);
    }
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

fn fullPathLessThan(_: void, a: walk.Entry, b: walk.Entry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

test "sort: collect order equals a full-path pdq sort of the unsorted collect" {
    var t: TestTree = .{ .io = undefined };
    try t.init("sortorder");
    defer t.deinit();

    // Names chosen so that bytes below and above '/' ('-', '.', '_', digits,
    // upper case), prefix relations ("a" vs "a-b" vs "a/b") and deep nesting
    // all appear; the sort must be plain byte order on the full path.
    const dirs = [_][]const u8{ "a", "a-b", "a.b", "a_b", "A", "a/b", "a/b/c", "a-b/c", "dir0", "dir1", "dir10", "dir2" };
    for (dirs) |d| try t.mkdir(d);
    const files = [_][]const u8{
        "a/b/c/z.txt", "a/b/c.txt", "a/b.txt", "a.txt",  "a-b/c/x", "a-b/x", "a.b/x", "a_b/x", "A/x",
        "dir0/f",      "dir1/f",    "dir10/f", "dir2/f", "z",       "Z",     "0",     "~",     " space",
    };
    for (files) |f| try t.write(f, "x");
    var name_buf: [64]u8 = undefined;
    for (0..300) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "dir{d}/file{d}.c", .{ i % 3, (i * 7919) % 1000 });
        try t.write(name, "x");
    }

    const gpa = std.heap.smp_allocator;
    var unsorted = try walk.collect(gpa, t.root, .{ .threads = 1 });
    defer unsorted.deinit();
    const reference = try gpa.dupe(walk.Entry, unsorted.entries);
    defer gpa.free(reference);
    std.sort.pdq(walk.Entry, reference, {}, fullPathLessThan);

    inline for (.{ 1, 4 }) |threads| {
        var sorted = try walk.collect(gpa, t.root, .{ .threads = threads, .sort = true });
        defer sorted.deinit();
        try testing.expectEqual(reference.len, sorted.entries.len);
        for (reference, sorted.entries) |*r, *s| {
            try testing.expectEqualStrings(r.path, s.path);
            try testing.expectEqualStrings(r.relativePath(), s.relativePath());
        }
    }
}

fn syntheticEntry(gpa: std.mem.Allocator, rng: std.Random, prefix: []const u8) !walk.Entry {
    // Short alphabet with bytes on both sides of '/' so directory boundaries,
    // prefix relations and duplicates all occur often.
    const alphabet = "ab/.-_A";
    const len = rng.uintLessThan(usize, 12);
    const buf = try gpa.allocSentinel(u8, prefix.len + len, 0);
    @memcpy(buf[0..prefix.len], prefix);
    for (buf[prefix.len..]) |*c| c.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
    return .{
        .path = buf,
        .relative_offset = @intCast(prefix.len),
        .basename_offset = @intCast(prefix.len),
        .kind = .file,
        .depth = 1,
        .meta = null,
    };
}

fn checkSortAgainstPdq(gpa: std.mem.Allocator, n: usize, threads: u32, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const prefix = "/tmp/some/root/";

    const reference = try gpa.alloc(walk.Entry, n);
    defer {
        for (reference) |e| gpa.free(e.path.ptr[0 .. e.path.len + 1]);
        gpa.free(reference);
    }
    for (reference) |*e| e.* = try syntheticEntry(gpa, rng, prefix);

    var subject = try gpa.alloc(walk.Entry, n);
    @memcpy(subject, reference);
    const io = std.Io.Threaded.global_single_threaded.io();
    subject = try walk.__internal_test_api.sortEntries(gpa, io, subject, threads);
    defer gpa.free(subject);

    std.sort.pdq(walk.Entry, reference, {}, fullPathLessThan);
    for (reference, subject) |r, s| try testing.expectEqualStrings(r.path, s.path);
}

test "sort: sortEntries matches pdq on full paths (serial, randomized)" {
    try checkSortAgainstPdq(testing.allocator, 0, 1, 1);
    try checkSortAgainstPdq(testing.allocator, 1, 1, 1);
    try checkSortAgainstPdq(testing.allocator, 13, 1, 2);
    try checkSortAgainstPdq(testing.allocator, 5000, 1, 3);
}

test "sort: sortEntries matches pdq on full paths (parallel pool, randomized)" {
    // Large enough that the task pool is exercised with several helpers.
    try checkSortAgainstPdq(std.heap.smp_allocator, 20000, 4, 4);
    try checkSortAgainstPdq(std.heap.smp_allocator, 20000, 16, 5);
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
        try testing.expectEqualStrings("lib/c.rs", results.entries[0].relativePath());
        try testing.expectEqualStrings("src/a.rs", results.entries[1].relativePath());
        try testing.expectEqualStrings("src/deep/e.rs", results.entries[2].relativePath());
        try testing.expectEqualStrings("top.rs", results.entries[3].relativePath());
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
            try testing.expect(std.mem.startsWith(u8, e.relativePath(), "src"));
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

test "walk pattern: wildcards match within one path component" {
    var t: TestTree = .{ .io = undefined };
    try t.init("pattern_components");
    defer t.deinit();

    try t.mkdir("src");
    try t.mkdir("src/net");
    try t.mkdir("src/net/deep");
    try t.mkdir("lib");
    try t.write("top.rs", "");
    try t.write("src/a.rs", "");
    try t.write("src/net/b.rs", "");
    try t.write("src/net/c.c", "");
    try t.write("src/net/deep/d.rs", "");
    try t.write("lib/e.rs", "");

    const Case = struct { pattern: []const u8, want: []const []const u8 };
    const cases = [_]Case{
        // `*` is exactly one component: not src/a.rs, not src/net/deep/d.rs.
        .{ .pattern = "src/*/*.rs", .want = &.{"src/net/b.rs"} },
        // A slash-free pattern only matches at the root.
        .{ .pattern = "*.rs", .want = &.{"top.rs"} },
        .{ .pattern = "*.{rs,c}", .want = &.{"top.rs"} },
        // `?` and bracket classes do not match `/` either.
        .{ .pattern = "src/???/*.[cr]*", .want = &.{ "src/net/b.rs", "src/net/c.c" } },
        // Only `**` spans components.
        .{ .pattern = "src/**/*.rs", .want = &.{ "src/a.rs", "src/net/b.rs", "src/net/deep/d.rs" } },
        .{ .pattern = "**/*.{rs,c}", .want = &.{ "lib/e.rs", "src/a.rs", "src/net/b.rs", "src/net/c.c", "src/net/deep/d.rs", "top.rs" } },
        .{ .pattern = "{**/*.c,*.rs}", .want = &.{ "src/net/c.c", "top.rs" } },
    };
    for (cases) |case| {
        for ([_]u16{ 1, 4 }) |threads| {
            var results = try walk.collect(testing.allocator, t.root, .{
                .threads = threads,
                .sort = true,
                .report_dirs = false,
                .pattern = case.pattern,
            });
            defer results.deinit();
            testing.expectEqual(case.want.len, results.entries.len) catch |err| {
                std.debug.print("pattern {s}: got {d} entries\n", .{ case.pattern, results.entries.len });
                for (results.entries) |*e| std.debug.print("  {s}\n", .{e.relativePath()});
                return err;
            };
            for (case.want, results.entries) |want, *e| {
                try testing.expectEqualStrings(want, e.relativePath());
            }
        }
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
            try testing.expect(!std.mem.startsWith(u8, e.relativePath(), "back/"));
            if (std.mem.eql(u8, e.relativePath(), "a.txt")) a_count += 1;
        }
        try testing.expectEqual(@as(usize, 1), a_count);
        // a.txt, back, link, link/o.txt, link/self
        try testing.expectEqual(@as(usize, 5), results.entries.len);
    }
}

test "walk follow_symlinks: link to ancestor and link into sibling" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var t: TestTree = .{ .io = undefined };
    try t.init("symlinks_ancestor");
    defer t.deinit();

    // tree/
    //   a/b/f.txt
    //   a/b/up   -> ..      (a: an ancestor, already visited)
    //   a/b/root -> ../..   (the walk root itself)
    //   a/b/side -> ../../c (a sibling subtree, visited once either way)
    //   a/b/absout -> <absolute>/outside (outside the walk root; descended)
    //   c/c.txt
    //   c/d/d.txt
    // outside/o.txt (sibling of tree/)
    try t.mkdir("outside");
    try t.write("outside/o.txt", "o");
    try t.mkdir("tree");
    try t.mkdir("tree/a");
    try t.mkdir("tree/a/b");
    try t.mkdir("tree/c");
    try t.mkdir("tree/c/d");
    try t.write("tree/a/b/f.txt", "f");
    try t.write("tree/c/c.txt", "c");
    try t.write("tree/c/d/d.txt", "d");

    var lbuf: [512]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    try cwd.symLink(t.io, "..", try std.fmt.bufPrint(&lbuf, "{s}/tree/a/b/up", .{t.root}), .{});
    try cwd.symLink(t.io, "../..", try std.fmt.bufPrint(&lbuf, "{s}/tree/a/b/root", .{t.root}), .{});
    try cwd.symLink(t.io, "../../c", try std.fmt.bufPrint(&lbuf, "{s}/tree/a/b/side", .{t.root}), .{});
    {
        var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var rel_out: [512]u8 = undefined;
        const outside_rel = try std.fmt.bufPrint(&rel_out, "{s}/outside", .{t.root});
        const outside_abs = abs_buf[0..try cwd.realPathFile(t.io, outside_rel, &abs_buf)];
        try cwd.symLink(t.io, outside_abs, try std.fmt.bufPrint(&lbuf, "{s}/tree/a/b/absout", .{t.root}), .{});
    }

    var root_buf: [512]u8 = undefined;
    const walk_root = try std.fmt.bufPrint(&root_buf, "{s}/tree", .{t.root});

    for ([_]u16{ 1, 4 }) |threads| {
        var results = try walk.collect(testing.allocator, walk_root, .{
            .threads = threads,
            .sort = true,
            .follow_symlinks = true,
        });
        defer results.deinit();

        // The links themselves are reported...
        try testing.expect(findEntry(&results, "a/b/up") != null);
        try testing.expect(findEntry(&results, "a/b/root") != null);
        try testing.expect(findEntry(&results, "a/b/side") != null);
        // An absolute link out of the tree is followed like any other.
        try testing.expect(findEntry(&results, "a/b/absout/o.txt") != null);

        var f_count: usize = 0;
        var c_via_real: usize = 0;
        var c_via_link: usize = 0;
        var d_leaves: usize = 0;
        for (results.entries) |*e| {
            const rel = e.relativePath();
            // ...but ancestors are never re-entered through them.
            try testing.expect(!std.mem.startsWith(u8, rel, "a/b/up/"));
            try testing.expect(!std.mem.startsWith(u8, rel, "a/b/root/"));
            if (std.mem.eql(u8, rel, "a/b/f.txt")) f_count += 1;
            if (std.mem.eql(u8, rel, "c/c.txt")) c_via_real += 1;
            if (std.mem.eql(u8, rel, "a/b/side/c.txt")) c_via_link += 1;
            if (std.mem.endsWith(u8, rel, "/d.txt")) d_leaves += 1;
        }
        try testing.expectEqual(@as(usize, 1), f_count);
        // The sibling subtree is walked exactly once: through whichever of
        // the real directory and the link was reached first.
        try testing.expectEqual(@as(usize, 1), c_via_real + c_via_link);
        try testing.expectEqual(@as(usize, 1), d_leaves);
    }
}

test "walk follow_symlinks: result size is independent of scheduling" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var t: TestTree = .{ .io = undefined };
    try t.init("symlink_farm");
    defer t.deinit();

    // A pnpm-style link farm: links/l<i> -> ../real/d<i>, and every real
    // directory also holds a link back to an ancestor (a cycle). Whichever of
    // the link and the real directory a worker reaches first gets to list the
    // directory; the other must still be reported so the total never depends
    // on the race.
    const n_dirs = 24;
    try t.mkdir("real");
    try t.mkdir("links");
    var buf: [512]u8 = undefined;
    var lbuf: [512]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    for (0..n_dirs) |i| {
        try t.mkdir(try std.fmt.bufPrint(&buf, "real/d{d}", .{i}));
        for (0..3) |j| try t.write(try std.fmt.bufPrint(&buf, "real/d{d}/f{d}.txt", .{ i, j }), "x");
        try cwd.symLink(t.io, "../..", try std.fmt.bufPrint(&lbuf, "{s}/real/d{d}/up", .{ t.root, i }), .{});
        const target = try std.fmt.bufPrint(&buf, "../real/d{d}", .{i});
        try cwd.symLink(t.io, target, try std.fmt.bufPrint(&lbuf, "{s}/links/l{d}", .{ t.root, i }), .{});
    }
    // real, links, n_dirs dirs, 3 files + 1 up link each, n_dirs links.
    const expected: usize = 2 + n_dirs + n_dirs * 4 + n_dirs;

    for (0..6) |_| {
        for ([_]u16{ 1, 8 }) |threads| {
            var results = try walk.collect(testing.allocator, t.root, .{
                .threads = threads,
                .follow_symlinks = true,
            });
            defer results.deinit();
            try testing.expectEqual(expected, results.entries.len);
            // Every file is listed exactly once, by whichever path won.
            var files: usize = 0;
            for (results.entries) |*e| {
                if (e.kind == .file) files += 1;
                try testing.expect(!std.mem.endsWith(u8, e.relativePath(), "/up/real"));
            }
            try testing.expectEqual(@as(usize, n_dirs * 3), files);
        }
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

    // Without a pattern the unreadable dir aborts the walk with the specific
    // permission error...
    try testing.expectError(error.PermissionDenied, walk.collect(testing.allocator, t.root, .{
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
    try testing.expectEqualStrings("src/a.rs", results.entries[0].relativePath());
}

test "walk retains reusable IgnoreRules: nesting, negation, .ignore precedence" {
    var t: TestTree = .{ .io = undefined };
    try t.init("ignore_rules");
    defer t.deinit();

    // Root .gitignore ignores *.log, the build/ dir, and all *.tmp; re-includes
    // keep.log.
    try t.write(".gitignore", "*.log\nbuild/\n!keep.log\n*.tmp\n");
    // Root .ignore is merged after .gitignore so it wins ties: it re-includes
    // important.tmp that .gitignore's *.tmp would otherwise drop.
    try t.write(".ignore", "!important.tmp\n");
    try t.mkdir("src");
    // Nested .gitignore under src/ ignores *.bak only within src/.
    try t.write("src/.gitignore", "*.bak\n");
    try t.mkdir("build");
    try t.write("app.log", "");
    try t.write("keep.log", "");
    try t.write("scratch.tmp", "");
    try t.write("important.tmp", "");
    try t.write("old.bak", "");
    try t.write("src/main.rs", "");
    try t.write("src/old.bak", "");

    var results = try walk.collect(testing.allocator, t.root, .{
        .threads = 1,
    });
    defer results.deinit();

    const rules = results.ignore_rules;

    // Root rules — isIgnoredPath lstat()s the target for dir-ness.
    try testing.expect(rules.isIgnoredPath("app.log"));
    try testing.expect(!rules.isIgnoredPath("keep.log")); // negation
    try testing.expect(rules.isIgnoredPath("build")); // dir-only build/ rule fires via lstat
    try testing.expect(rules.isIgnoredPath("scratch.tmp")); // *.tmp from .gitignore
    try testing.expect(!rules.isIgnoredPath("important.tmp")); // .ignore re-includes

    // Nested rules apply only within src/.
    try testing.expect(rules.isIgnoredPath("src/old.bak"));
    try testing.expect(!rules.isIgnoredPath("old.bak")); // not ignored at root
    try testing.expect(!rules.isIgnoredPath("src/main.rs"));

    // Non-existent paths surface as ignored (unreachable → ignored).
    try testing.expect(rules.isIgnoredPath("src/util/helper.rs"));

    // Absolute-path queries work too, provided they're inside the walk.
    var abs_buf: [512]u8 = undefined;
    const abs_app_log = try std.fmt.bufPrint(&abs_buf, "{s}/app.log", .{t.root});
    try testing.expect(rules.isIgnoredPath(abs_app_log));
    // Absolute path outside the walk → ignored (not part of this walk).
    try testing.expect(rules.isIgnoredPath("/etc/passwd"));
}

fn testNode(alloc: std.mem.Allocator, dir_rel: []const u8, doc: []const u8) !*walk.__internal_test_api.IgnoreNode {
    const gi = try GitIgnore.parse(alloc, doc);
    const node = try alloc.create(walk.__internal_test_api.IgnoreNode);
    node.* = .{
        .parent = null,
        .gi = gi,
        .relative_offset = @intCast(if (dir_rel.len > 0) dir_rel.len + 1 else 0),
        .refs = .init(1),
    };
    return node;
}

fn expectFastEqualsSlow(rules: *const walk.IgnoreRules, norm: []const u8, is_dir: bool) !void {
    const basename = if (std.mem.lastIndexOfScalar(u8, norm, '/')) |p| norm[p + 1 ..] else norm;
    const fast = walk.__internal_test_api.isIgnoredResolved(rules, norm, basename, is_dir);
    const slow = walk.__internal_test_api.isIgnoredPathSlow(rules, norm, basename, is_dir);
    testing.expectEqual(slow, fast) catch |err| {
        std.debug.print("mismatch for '{s}' (is_dir={}): fast={} slow={}\n", .{ norm, is_dir, fast, slow });
        return err;
    };
}

test "isIgnoredResolved: nested rules, ancestor pruning, negation, fast==slow" {
    const alloc = testing.allocator;
    var rules: walk.IgnoreRules = .{ .allocator = alloc };
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
    try testing.expect(walk.__internal_test_api.isIgnoredResolved(&rules, "a.log", "a.log", false));
    // build/ pruned: anything beneath it is ignored regardless of depth.
    try testing.expect(walk.__internal_test_api.isIgnoredResolved(&rules, "build/x/y.c", "y.c", false));
    // src/keep.log is re-included by the nested negation → NOT ignored.
    try testing.expect(!walk.__internal_test_api.isIgnoredResolved(&rules, "src/keep.log", "keep.log", false));
    // src/other.log still hits the root *.log rule.
    try testing.expect(walk.__internal_test_api.isIgnoredResolved(&rules, "src/other.log", "other.log", false));
    // src/gen/ pruned by the nested rule.
    try testing.expect(walk.__internal_test_api.isIgnoredResolved(&rules, "src/gen/out.o", "out.o", false));
    // A plain source file is not ignored.
    try testing.expect(!walk.__internal_test_api.isIgnoredResolved(&rules, "src/main.zig", "main.zig", false));

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

test "isIgnoredResolved: a nested negation re-includes a parent-excluded dir" {
    // Regression: the ancestor phase used to ask "does any ruleset in scope
    // ignore this ancestor?" and return true on the first hit, walking the chain
    // shallowest-first. That let a shallow rule win over a deeper negation, so
    // an ancestor git had re-included still pruned its whole subtree.
    //
    // Ground truth (git 2.x):
    //   $ printf 'build/*\n' > .gitignore
    //   $ printf '!keep\n'   > build/.gitignore
    //   $ git ls-files -o --exclude-standard
    //   .gitignore  build/.gitignore  build/keep/k.txt
    const alloc = testing.allocator;
    var rules: walk.IgnoreRules = .{ .allocator = alloc };
    defer rules.deinit();

    try rules.put("", try testNode(alloc, "", "build/*\n"));
    (rules.by_dir.get("").?).release(alloc);
    try rules.put("build", try testNode(alloc, "build", "!keep\n"));
    (rules.by_dir.get("build").?).release(alloc);

    // `build/keep` is excluded by the root rule but re-included by the deeper
    // one, which has precedence — so neither it nor its contents are ignored.
    try testing.expect(!walk.__internal_test_api.isIgnoredResolved(&rules, "build/keep", "keep", true));
    try testing.expect(!walk.__internal_test_api.isIgnoredResolved(&rules, "build/keep/k.txt", "k.txt", false));
    // A sibling the nested file says nothing about stays excluded.
    try testing.expect(walk.__internal_test_api.isIgnoredResolved(&rules, "build/other", "other", true));
    try testing.expect(walk.__internal_test_api.isIgnoredResolved(&rules, "build/other/x.o", "x.o", false));

    for ([_][]const u8{
        "build",           "build/keep",  "build/keep/k.txt",
        "build/keep/deep", "build/other", "build/other/x.o",
    }) |case| {
        try expectFastEqualsSlow(&rules, case, false);
        try expectFastEqualsSlow(&rules, case, true);
    }
}

// ---------------------------------------------------------------------------
// ZLOB_PARALLEL: recursive ** globs routed through the parallel walker must
// produce exactly the serial result set.
// ---------------------------------------------------------------------------

const c_lib = @import("c_lib");
const zlob_flags = @import("zlob_flags");

fn globPathsSorted(alloc: std.mem.Allocator, pattern: [:0]const u8, flags: c_int) ![][]u8 {
    var g: c_lib.zlob_t = undefined;
    const rc = c_lib.zlob(pattern.ptr, flags, null, &g);
    if (rc == zlob_flags.ZLOB_NOMATCH) return try alloc.alloc([]u8, 0);
    try testing.expectEqual(@as(c_int, 0), rc);
    defer c_lib.zlobfree(&g);
    const out = try alloc.alloc([]u8, g.zlo_pathc);
    for (out, 0..) |*o, i| o.* = try alloc.dupe(u8, std.mem.span(g.zlo_pathv[g.zlo_offs + i]));
    std.sort.pdq([]u8, out, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out;
}

fn expectParallelEqualsSerial(alloc: std.mem.Allocator, pattern: [:0]const u8, base_flags: c_int, threads: u16) !void {
    const serial = try globPathsSorted(alloc, pattern, base_flags);
    defer {
        for (serial) |p| alloc.free(p);
        alloc.free(serial);
    }
    zlob.setGlobParallelThreads(threads);
    defer zlob.setGlobParallelThreads(4);
    const parallel = try globPathsSorted(alloc, pattern, base_flags | zlob_flags.ZLOB_PARALLEL);
    defer {
        for (parallel) |p| alloc.free(p);
        alloc.free(parallel);
    }
    try testing.expectEqual(serial.len, parallel.len);
    for (serial, parallel) |s, p| try testing.expectEqualStrings(s, p);
}

test "ZLOB_PARALLEL recursive glob matches serial result set" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var t: TestTree = .{ .io = undefined };
    try t.init("parglob");
    defer t.deinit();

    try t.mkdir("src");
    try t.mkdir("src/a");
    try t.mkdir("src/a/deep");
    try t.mkdir("src/b");
    try t.mkdir("lib");
    try t.mkdir("lib/foo");
    try t.mkdir(".hidden");
    try t.mkdir("src/.hdir");
    try t.write("root.c", "");
    try t.write("src/main.c", "");
    try t.write("src/main.h", "");
    try t.write("src/a/x.c", "");
    try t.write("src/a/deep/y.c", "");
    try t.write("src/a/deep/z.txt", "");
    try t.write("src/b/w.c", "");
    try t.write("lib/foo/f.c", "");
    try t.write("lib/foo/Makefile", "");
    try t.write(".hidden/h.c", "");
    try t.write("src/.hdir/hh.c", "");
    try t.write("src/.dot.c", "");

    const base: c_int = zlob_flags.ZLOB_BRACE | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE;
    var pat_buf: [512:0]u8 = undefined;
    const patterns = [_][]const u8{
        "**/*.c",       "**/*.{c,h}", "**/foo/*.c", "src/**/*.c", "**/deep/*",
        "**/.*.c",      "**",         "**/",        "src/**",     "lib/**/Makefile",
        "**/nomatch.x", "**/*",
    };
    for ([_]u16{ 1, 4, 16 }) |threads| {
        for (patterns) |p| {
            const pat = try std.fmt.bufPrintZ(&pat_buf, "{s}/{s}", .{ t.root, p });
            try expectParallelEqualsSerial(alloc, pat, base, threads);
            try expectParallelEqualsSerial(alloc, pat, base | zlob_flags.ZLOB_MARK, threads);
            try expectParallelEqualsSerial(alloc, pat, base | zlob_flags.ZLOB_PERIOD, threads);
            try expectParallelEqualsSerial(alloc, pat, base | zlob_flags.ZLOB_ONLYDIR | zlob_flags.ZLOB_MARK, threads);
        }
    }
}

var par_errfunc_calls: usize = 0;
fn countingErrfunc(_: [*:0]const u8, _: c_int) callconv(.c) c_int {
    par_errfunc_calls += 1;
    return 0;
}
fn abortingErrfunc(_: [*:0]const u8, _: c_int) callconv(.c) c_int {
    par_errfunc_calls += 1;
    return 1;
}

test "ZLOB_PARALLEL errfunc is delivered and can abort" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Only meaningful when running unprivileged (root can read a 000 dir).
    if (std.os.linux.getuid() == 0) return error.SkipZigTest;

    var t: TestTree = .{ .io = undefined };
    try t.init("parglob_err");
    defer t.deinit();
    try t.mkdir("ok");
    try t.write("ok/a.c", "");
    try t.mkdir("locked");
    try t.write("locked/b.c", "");
    var buf: [512:0]u8 = undefined;
    const locked = try std.fmt.bufPrintZ(&buf, "{s}/locked", .{t.root});
    try testing.expectEqual(@as(usize, 0), std.os.linux.chmod(locked.ptr, 0));
    defer _ = std.os.linux.chmod(locked.ptr, 0o755);

    var pat_buf: [512:0]u8 = undefined;
    const pat = try std.fmt.bufPrintZ(&pat_buf, "{s}/**/*.c", .{t.root});
    const base: c_int = zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE | zlob_flags.ZLOB_PARALLEL;

    par_errfunc_calls = 0;
    var g: c_lib.zlob_t = undefined;
    var rc = c_lib.zlob(pat.ptr, base, countingErrfunc, &g);
    try testing.expectEqual(@as(c_int, 0), rc);
    try testing.expectEqual(@as(usize, 1), g.zlo_pathc);
    c_lib.zlobfree(&g);
    try testing.expectEqual(@as(usize, 1), par_errfunc_calls);

    par_errfunc_calls = 0;
    rc = c_lib.zlob(pat.ptr, base, abortingErrfunc, &g);
    try testing.expectEqual(zlob_flags.ZLOB_ABORTED, rc);
    try testing.expectEqual(@as(usize, 1), par_errfunc_calls);

    rc = c_lib.zlob(pat.ptr, base | zlob_flags.ZLOB_ERR, null, &g);
    try testing.expectEqual(zlob_flags.ZLOB_ABORTED, rc);
}

test "isIgnoredResolved: overflow beyond the directory-chain limit falls back and matches" {
    const alloc = testing.allocator;
    var rules: walk.IgnoreRules = .{ .allocator = alloc };
    defer rules.deinit();

    // Create a .gitignore at every directory level well past the fixed stack
    // limit. The chain must fall back to the slow scan without changing its
    // verdict; every level ignores `dead`.
    var path_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer path_buf.deinit(alloc);
    const levels = walk.__internal_test_api.max_dir_chain + 5;
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
    try testing.expect(walk.__internal_test_api.isIgnoredResolved(&rules, leaf.items, "dead", false));

    try expectFastEqualsSlow(&rules, "d/d/d/keep", false);
    try expectFastEqualsSlow(&rules, "d/d/d/dead", false);
}

// ---------------------------------------------------------------------------
// Short-read-is-EOF (single getdents64 per directory) correctness
// ---------------------------------------------------------------------------

/// Creates `n` files with pseudo-random name lengths under `dir` (absolute or
/// cwd-relative). Lengths 1..200 so directory listings land on arbitrary
/// getdents64 buffer boundaries.
fn fillRandomNames(io: std.Io, dir: []const u8, n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n * 7919 + 13));
    const rnd = prng.random();
    var name_buf: [256]u8 = undefined;
    var path_buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const len = 1 + rnd.uintLessThan(usize, 200);
        // Unique numeric prefix, then random filler up to the chosen length.
        const head = try std.fmt.bufPrint(&name_buf, "{d}_", .{i});
        var k: usize = head.len;
        while (k < @max(len, head.len)) : (k += 1) name_buf[k] = 'a' + @as(u8, @intCast(rnd.uintLessThan(usize, 26)));
        const name = name_buf[0..k];
        const p = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
        var f = try std.Io.Dir.cwd().createFile(io, p, .{});
        f.close(io);
    }
}

fn countStd(io: std.Io, dir: []const u8) !usize {
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}

fn checkShortEofTree(base: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = testing.allocator;
    const walker = @import("walker");

    var root_buf: [512]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/short_eof_{d}", .{
        base, std.Io.Timestamp.now(io, .real).toMilliseconds(),
    });
    std.Io.Dir.cwd().createDirPath(io, root) catch return error.SkipZigTest;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // Sizes straddle the 8 KiB (DirIterator) and 64 KiB (walkers) buffers,
    // including the empty and single-entry cases.
    const sizes = [_]usize{ 0, 1, 2, 27, 28, 29, 60, 61, 300, 700, 3000 };
    var expected_total: usize = 0;
    var sub_buf: [600]u8 = undefined;
    for (sizes) |n| {
        const sub = try std.fmt.bufPrint(&sub_buf, "{s}/n{d}", .{ root, n });
        try std.Io.Dir.cwd().createDir(io, sub, .default_dir);
        try fillRandomNames(io, sub, n);
        const std_count = try countStd(io, sub);
        try testing.expectEqual(n, std_count);
        expected_total += n + 1; // files + the subdir itself

        // Walker B single-directory iterator (8 KiB buffer, per-call trust cache).
        var tc = walker.TrustCache{};
        var iter: walker.DirIterator = undefined;
        const opened = try walker.DirIterator.openHandledInto(&iter, io, sub, null, .{
            .include_dot_entries = false,
            .include_hidden = true,
        }, .{ .trust = &tc }, .{});
        try testing.expect(opened);
        defer iter.close();
        var it_count: usize = 0;
        while (iter.next()) |_| it_count += 1;
        try testing.expectEqual(n, it_count);
    }

    // Walker A, serial and parallel.
    inline for ([_]u16{ 1, 0 }) |threads| {
        var results = try walk.collect(gpa, root, .{ .threads = threads, .respect_git = false });
        defer results.deinit();
        try testing.expectEqual(expected_total, results.entries.len);
    }
    // Walker A with the optimization off must agree.
    {
        var results = try walk.collect(gpa, root, .{ .threads = 1, .respect_git = false, .trust_short_getdents = .never });
        defer results.deinit();
        try testing.expectEqual(expected_total, results.entries.len);
    }

    // Walker B recursive (64 KiB buffer).
    inline for ([_]walker.TrustShortGetdents{ .auto, .never }) |trust| {
        var w = try walker.DefaultWalker.init(gpa, io, root, .{
            .hidden = .{ .include_dot_entries = false, .include_hidden = true },
            .trust_short_getdents = trust,
        });
        defer w.deinit();
        var count: usize = 0;
        while (try w.next()) |_| count += 1;
        try testing.expectEqual(expected_total, count);
    }
}

// The dirent module's own tests are not collected (non-root module), so its
// short-read gate is unit-tested here.
const dirent = if (builtin.os.tag == .linux) @import("dirent") else struct {};

test "short-read EOF: filesystem whitelist" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try testing.expect(dirent.fsMagicIsGreedy(0xEF53)); // ext4
    try testing.expect(dirent.fsMagicIsGreedy(0x9123683E)); // btrfs
    try testing.expect(dirent.fsMagicIsGreedy(0x01021994)); // tmpfs
    try testing.expect(!dirent.fsMagicIsGreedy(0x65735546)); // FUSE
    try testing.expect(!dirent.fsMagicIsGreedy(0x6969)); // NFS
    try testing.expect(!dirent.fsMagicIsGreedy(0x794C7630)); // overlay
    try testing.expect(!dirent.fsMagicIsGreedy(0xFF534D42)); // cifs
    try testing.expect(dirent.fsNameIsGreedy("xfs"));
    try testing.expect(!dirent.fsNameIsGreedy("fuse.sshfs"));
}

test "short-read EOF: threshold leaves room for one maximal record" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 280), dirent.MAX_RECLEN);
    try testing.expect(dirent.shortReadIsEof(0, 280));
    try testing.expect(dirent.shortReadIsEof(1000, 1280));
    try testing.expect(!dirent.shortReadIsEof(1001, 1280));
}

test "short-read EOF: mountinfo parse keeps only non-greedy mounts, unescaped" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const sample =
        \\72 1 0:33 /root / rw,relatime shared:1 - btrfs /dev/mapper/luks rw,ssd
        \\51 72 0:33 /home /home rw,relatime shared:2 - btrfs /dev/mapper/luks rw
        \\98 51 0:50 / /home/u/my\040mnt rw,nosuid shared:9 - fuse.sshfs u@h:/ rw
        \\99 72 0:51 / /mnt/nfs rw shared:10 - nfs4 h:/export rw
        \\54 72 8:1 / /boot rw,relatime shared:3 - ext4 /dev/sda1 rw
        \\
    ;
    const gpa = testing.allocator;
    const content = try gpa.dupe(u8, sample);
    defer gpa.free(content);
    const bad = try dirent.parseMountInfo(gpa, content);
    defer gpa.free(bad);
    try testing.expectEqual(@as(usize, 2), bad.len);
    try testing.expectEqualStrings("/home/u/my mnt", bad[0]);
    try testing.expectEqualStrings("/mnt/nfs", bad[1]);

    try testing.expect(dirent.anyMountBelow(bad, "/"));
    try testing.expect(dirent.anyMountBelow(bad, "/home"));
    try testing.expect(dirent.anyMountBelow(bad, "/home/u"));
    try testing.expect(dirent.anyMountBelow(bad, "/home/u/my mnt"));
    try testing.expect(!dirent.anyMountBelow(bad, "/home/v"));
    try testing.expect(!dirent.anyMountBelow(bad, "/home/u/my"));
    try testing.expect(!dirent.anyMountBelow(bad, "/boot"));
}

test "short-read EOF: probe rejects a non-whitelisted filesystem (procfs)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    const rc = linux.openat(linux.AT.FDCWD, "/proc/self", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    try testing.expect(!dirent.trustShortReaddir(fd));
}

test "short-read EOF: dense random-name trees match std iteration (cache dir)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try checkShortEofTree(".zig-cache/walk-tests");
}

test "short-read EOF: dense random-name trees match std iteration (tmpfs)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try checkShortEofTree("/dev/shm/zlob-walk-tests");
}

/// st_dev of `path` (symlinks followed), or null when it cannot be stat'ed.
fn devOf(path: []const u8) ?u64 {
    const linux = std.os.linux;
    var path_z: [1024:0]u8 = undefined;
    if (path.len >= path_z.len) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path_z[0..path.len :0], 0, .{ .INO = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor);
}

/// Two-device fixture: a root in the repo's cache dir (its filesystem) holding
/// a symlink `link` to a directory on /dev/shm (tmpfs), plus a same-device
/// subdir `local`. Skips when both land on the same device or /dev/shm is
/// unusable.
const CrossDevTree = struct {
    io: std.Io,
    root_buf: [256]u8 = undefined,
    root: []const u8 = &.{},
    shm_buf: [256]u8 = undefined,
    shm: []const u8 = &.{},

    fn init(self: *CrossDevTree, comptime tag: []const u8, dense: usize) !void {
        self.io = std.Io.Threaded.global_single_threaded.io();
        const cwd = std.Io.Dir.cwd();
        const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        self.root = try std.fmt.bufPrint(&self.root_buf, ".zig-cache/walk-tests/{s}_{d}", .{ tag, now });
        self.shm = try std.fmt.bufPrint(&self.shm_buf, "/dev/shm/zlob-walk-tests/{s}_{d}", .{ tag, now });
        try cwd.createDirPath(self.io, self.root);
        errdefer cwd.deleteTree(self.io, self.root) catch {};
        cwd.createDirPath(self.io, self.shm) catch return error.SkipZigTest;
        errdefer cwd.deleteTree(self.io, self.shm) catch {};

        const root_dev = devOf(self.root) orelse return error.SkipZigTest;
        const shm_dev = devOf(self.shm) orelse return error.SkipZigTest;
        if (root_dev == shm_dev) return error.SkipZigTest;

        var buf: [512]u8 = undefined;
        try cwd.createDir(self.io, try std.fmt.bufPrint(&buf, "{s}/local", .{self.root}), .default_dir);
        try fillRandomNames(self.io, try std.fmt.bufPrint(&buf, "{s}/local", .{self.root}), dense);
        try fillRandomNames(self.io, self.shm, dense);
        // Dense subdirs on the foreign device too, so the walkers list
        // directories there whose batches straddle the short-read threshold.
        for ([_]usize{ 1, 28, 29, 300 }) |n| {
            const sub = try std.fmt.bufPrint(&buf, "{s}/sub{d}", .{ self.shm, n });
            try cwd.createDir(self.io, sub, .default_dir);
            try fillRandomNames(self.io, sub, n);
        }
        // `shm` is already absolute, so the links resolve from anywhere.
        try cwd.symLink(self.io, self.shm, try std.fmt.bufPrint(&buf, "{s}/link", .{self.root}), .{});
        try cwd.symLink(self.io, self.shm, try std.fmt.bufPrint(&buf, "{s}/local/link", .{self.root}), .{});
    }

    fn deinit(self: *CrossDevTree) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        std.Io.Dir.cwd().deleteTree(self.io, self.shm) catch {};
    }
};

test "short-read EOF: DirIterator trust cache stops at a symlink onto another device" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const walker = @import("walker");
    var t: CrossDevTree = .{ .io = undefined };
    try t.init("xdev_iter", 29);
    defer t.deinit();
    const hidden: walker.HiddenConfig = .{ .include_dot_entries = false, .include_hidden = true };

    // Probe on the start directory, as globSingle does.
    var tc = walker.TrustCache{};
    var root_iter: walker.DirIterator = undefined;
    try testing.expect(try walker.DirIterator.openHandledInto(&root_iter, t.io, t.root, null, hidden, .{ .trust = &tc }, .{}));
    defer root_iter.close();
    // The cache dir's filesystem may itself be non-greedy (or have a foreign
    // mount below it); then there is no trust to inherit and nothing to test.
    if (tc.state != .yes) return error.SkipZigTest;
    try testing.expect(root_iter.mode.getdents.trust_short);
    try testing.expectEqual(devOf(t.root).?, tc.dev);

    var buf: [512]u8 = undefined;
    // Same device: the verdict carries over.
    var local_iter: walker.DirIterator = undefined;
    try testing.expect(try walker.DirIterator.openHandledInto(&local_iter, t.io, try std.fmt.bufPrint(&buf, "{s}/local", .{t.root}), null, hidden, .{ .trust = &tc }, .{}));
    defer local_iter.close();
    try testing.expect(local_iter.mode.getdents.trust_short);

    // Through the link onto tmpfs: the verdict must not carry over, and the
    // listing must still be complete.
    var link_iter: walker.DirIterator = undefined;
    try testing.expect(try walker.DirIterator.openHandledInto(&link_iter, t.io, try std.fmt.bufPrint(&buf, "{s}/link", .{t.root}), null, hidden, .{ .trust = &tc }, .{}));
    defer link_iter.close();
    try testing.expect(!link_iter.mode.getdents.trust_short);
    try testing.expectEqual(tc.state, .yes); // siblings on the root device keep it
    var n: usize = 0;
    while (link_iter.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 29 + 4), n);

    // Same through the glob front door: a literal component after a
    // wildcard is opened by path (openat follows the link), so the foreign
    // directory is listed with the start dir's cache in hand; it must still
    // be listed completely.
    var pat_buf: [512:0]u8 = undefined;
    const pat = try std.fmt.bufPrintZ(&pat_buf, "{s}/l*/link/*", .{t.root});
    const alloc = testing.allocator;
    const paths = try globPathsSorted(alloc, pat, 0);
    defer {
        for (paths) |p| alloc.free(p);
        alloc.free(paths);
    }
    try testing.expectEqual(@as(usize, 29 + 4), paths.len);
}

test "short-read EOF: follow_symlinks onto another device lists completely (trust auto == never)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const walker = @import("walker");
    const gpa = testing.allocator;
    var t: CrossDevTree = .{ .io = undefined };
    try t.init("xdev_follow", 300);
    defer t.deinit();

    var expected: usize = 0;
    {
        var results = try walk.collect(gpa, t.root, .{
            .threads = 1,
            .respect_git = false,
            .follow_symlinks = true,
            .trust_short_getdents = .never,
        });
        defer results.deinit();
        expected = results.entries.len;
    }
    // local(1) + 300 + local/link(1, target already visited via root/link or
    // vice versa: the shm tree is listed exactly once) + link(1) + 300 + 4
    // subdirs + 1 + 28 + 29 + 300
    try testing.expectEqual(@as(usize, 3 + 300 + 300 + 4 + 1 + 28 + 29 + 300), expected);

    // Walker A, one worker and the full pool; serial Walker B as well.
    inline for ([_]u16{ 1, 0 }) |threads| {
        var results = try walk.collect(gpa, t.root, .{
            .threads = threads,
            .respect_git = false,
            .follow_symlinks = true,
        });
        defer results.deinit();
        try testing.expectEqual(expected, results.entries.len);
    }
    var w = try walker.DefaultWalker.init(gpa, t.io, t.root, .{
        .hidden = .{ .include_dot_entries = false, .include_hidden = true },
        .follow_symlinks = true,
    });
    defer w.deinit();
    var count: usize = 0;
    while (try w.next()) |_| count += 1;
    try testing.expectEqual(expected, count);
}
