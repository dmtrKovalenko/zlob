//! ZLOB_MATCH_BASENAME: a pattern with no separator matches entry names at
//! any depth. Covers the in-memory matcher (every compiled shape, at-mode,
//! indices, compiled patterns), the filesystem glob, and the walker.

const std = @import("std");
const testing = std.testing;
const zlob = @import("zlob");
const zlob_flags = @import("zlob_flags");
const walk = zlob.walk;

const ZlobFlags = zlob_flags.ZlobFlags;
const BASENAME = zlob_flags.ZLOB_MATCH_BASENAME;
const BRACE = zlob_flags.ZLOB_BRACE;
const NOCHECK = zlob_flags.ZLOB_NOCHECK;
const PERIOD = zlob_flags.ZLOB_PERIOD;
const EXTGLOB = zlob_flags.ZLOB_EXTGLOB;
const RECURSIVE = zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE;

fn expectMatches(pattern: []const u8, flags: u32, paths: []const []const u8, expected: []const []const u8) !void {
    var result = try zlob.matchPaths(testing.allocator, pattern, paths, flags);
    defer result.deinit();
    const got = try result.toSlice(testing.allocator);
    defer testing.allocator.free(got);
    testing.expectEqual(expected.len, got.len) catch |err| {
        std.debug.print("pattern {s}: got {d} matches:\n", .{ pattern, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return err;
    };
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

const nix_paths = [_][]const u8{
    "hash-glibc/lib/libc.so.6",
    "libc.so.1",
    "nix/store/abc-musl/lib/libc.so",
    "lib/libm.so.6",
    "libc.so.6.bak/notes.txt",
};

test "basename: fff#901 — libc.so* matches at any depth, anchored without the flag" {
    // Without the flag the pattern is anchored at the root and `*` crosses
    // `/`, so the only nested hit is the one whose *root* component starts
    // with the literal.
    try expectMatches("libc.so*", 0, &nix_paths, &.{ "libc.so.1", "libc.so.6.bak/notes.txt" });
    try expectMatches("libc.so*", BASENAME, &nix_paths, &.{
        "hash-glibc/lib/libc.so.6",
        "libc.so.1",
        "nix/store/abc-musl/lib/libc.so",
    });
    // Same answer as the explicit recursive spelling.
    try expectMatches("**/libc.so*", RECURSIVE, &nix_paths, &.{
        "hash-glibc/lib/libc.so.6",
        "libc.so.1",
        "nix/store/abc-musl/lib/libc.so",
    });
}

test "basename: literal matches the whole last component only" {
    const paths = [_][]const u8{
        "README.md",
        "docs/api/README.md",
        "docs/README.md.bak",
        "docs/xREADME.md",
        "README.md/weird",
        "a/b/c/d/e/f/g/README.md",
    };
    try expectMatches("README.md", 0, &paths, &.{"README.md"});
    try expectMatches("README.md", BASENAME, &paths, &.{
        "README.md",
        "a/b/c/d/e/f/g/README.md",
        "docs/api/README.md",
    });
    // Directory entries are plain components too.
    try expectMatches("docs", BASENAME, &paths, &.{});
    try expectMatches("weird", BASENAME, &paths, &.{"README.md/weird"});
}

test "basename: every template shape — prefix*, prefix*.ext, [set], ?, star-only" {
    const paths = [_][]const u8{
        "src/main.c",
        "src/deep/main_test.c",
        "main.c",
        "src/mainframe.rs",
        "x/test1.zig",
        "x/test12.zig",
        "y/tesla.zig",
        "docs/d.md",
    };
    try expectMatches("main*", BASENAME, &paths, &.{ "main.c", "src/deep/main_test.c", "src/main.c", "src/mainframe.rs" });
    try expectMatches("main*.c", BASENAME, &paths, &.{ "main.c", "src/deep/main_test.c", "src/main.c" });
    try expectMatches("test[0-9].zig", BASENAME, &paths, &.{"x/test1.zig"});
    try expectMatches("test?.zig", BASENAME, &paths, &.{"x/test1.zig"});
    try expectMatches("?.md", BASENAME, &paths, &.{"docs/d.md"});
    try expectMatches("*", BASENAME, &paths, &.{
        "docs/d.md",
        "main.c",
        "src/deep/main_test.c",
        "src/main.c",
        "src/mainframe.rs",
        "x/test1.zig",
        "x/test12.zig",
        "y/tesla.zig",
    });
}

test "basename: wildcards never cross a separator" {
    const paths = [_][]const u8{ "a/foo/b.txt", "a/foo.txt", "foo", "foo/x" };
    // Without the flag `*` crosses `/` so the directory component matches too.
    try expectMatches("*foo*", 0, &paths, &.{ "a/foo.txt", "a/foo/b.txt", "foo", "foo/x" });
    try expectMatches("*foo*", BASENAME, &paths, &.{ "a/foo.txt", "foo" });
    try expectMatches("a*", BASENAME, &paths, &.{});
    try expectMatches("?", BASENAME, &paths, &.{"foo/x"});
}

test "basename: *.ext shapes keep their fast paths and the same answers" {
    const paths = [_][]const u8{ "a.c", "src/b.c", "src/deep/.c", "a.cc", "x.html", "deep/y.html" };
    try expectMatches("*.c", BASENAME, &paths, &.{ "a.c", "src/b.c", "src/deep/.c" });
    try expectMatches("*.c", 0, &paths, &.{ "a.c", "src/b.c", "src/deep/.c" });
    try expectMatches("*.html", BASENAME, &paths, &.{ "deep/y.html", "x.html" });
}

test "basename: anything containing a separator stays anchored" {
    const paths = [_][]const u8{ "src/main.rs", "crates/a/src/main.rs", "main.rs", "/abs/main.rs" };
    try expectMatches("src/main.rs", BASENAME, &paths, &.{"src/main.rs"});
    try expectMatches("./main.rs", BASENAME, &paths, &.{"main.rs"});
    try expectMatches("/abs/*", BASENAME, &paths, &.{"/abs/main.rs"});
    try expectMatches("**/main.rs", BASENAME | RECURSIVE, &paths, &.{ "/abs/main.rs", "crates/a/src/main.rs", "main.rs", "src/main.rs" });
    try expectMatches("main.rs", BASENAME, &paths, &.{ "/abs/main.rs", "crates/a/src/main.rs", "main.rs", "src/main.rs" });
}

test "basename: brace alternatives are each a component matcher" {
    const paths = [_][]const u8{
        "src/lib.rs",
        "src/deep/mod.rs",
        "build/out.o",
        "Cargo.toml",
        "x/Cargo.toml",
        "x/Cargo.lock",
        "a.h",
        "inc/b.hpp",
    };
    try expectMatches("{lib,mod}.rs", BASENAME | BRACE, &paths, &.{ "src/deep/mod.rs", "src/lib.rs" });
    try expectMatches("Cargo.{toml,lock}", BASENAME | BRACE, &paths, &.{ "Cargo.toml", "x/Cargo.lock", "x/Cargo.toml" });
    // multi-suffix fast path (all `*.ext`) is already a basename test.
    try expectMatches("*.{h,hpp}", BASENAME | BRACE, &paths, &.{ "a.h", "inc/b.hpp" });
    // Single-alternative brace collapses to the non-brace compile.
    try expectMatches("{lib}.rs", BASENAME | BRACE, &paths, &.{"src/lib.rs"});
    // A separator inside the braces anchors the whole pattern (and the
    // anchored `*` keeps crossing `/`, as without the flag).
    try expectMatches("{src,x}/*.rs", BASENAME | BRACE, &paths, &.{ "src/deep/mod.rs", "src/lib.rs" });
}

test "basename: extglob alternatives work on the component" {
    const paths = [_][]const u8{ "src/app.js", "src/app.ts", "lib/app.css", "app.ts" };
    try expectMatches("app.@(js|ts)", BASENAME | EXTGLOB, &paths, &.{ "app.ts", "src/app.js", "src/app.ts" });
    try expectMatches("app.!(js|ts)", BASENAME | EXTGLOB, &paths, &.{"lib/app.css"});
}

test "basename: escapes are honoured on the component" {
    const paths = [_][]const u8{ "a/x*y", "a/xzy", "x*y" };
    try expectMatches("x\\*y", BASENAME, &paths, &.{ "a/x*y", "x*y" });
    try expectMatches("x\\*y", BASENAME | zlob_flags.ZLOB_NOESCAPE, &paths, &.{});
}

test "basename: at-mode strips the base and never matches through the base name" {
    const paths = [_][]const u8{
        "/home/u/proj/README.md",
        "/home/u/proj/docs/README.md",
        "/home/u/proj",
        "/home/u/proj/x",
    };
    var result = try zlob.matchPathsAt(testing.allocator, "/home/u/proj", "README.md", &paths, BASENAME);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.len());
    try testing.expectEqualStrings("/home/u/proj/README.md", result.get(0));
    try testing.expectEqualStrings("/home/u/proj/docs/README.md", result.get(1));

    // `proj` is the base's own name: the empty relative path must not match it.
    var none = try zlob.matchPathsAt(testing.allocator, "/home/u/proj/", "proj", &paths, BASENAME);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.len());

    var star = try zlob.matchPathsAt(testing.allocator, "/home/u/proj", "*", &paths, BASENAME);
    defer star.deinit();
    try testing.expectEqual(@as(usize, 3), star.len());
}

test "basename: indices API and compiled patterns agree with matchPaths" {
    const paths = [_][]const u8{ "src/lib.rs", "src/deep/mod.rs", "lib.rs", "x/lib.rsx", "xlib.rs" };
    const flags = ZlobFlags{ .match_basename = true, .brace = true };

    const idx = try zlob.matchPathIndices(testing.allocator, "lib.rs", &paths, flags);
    defer testing.allocator.free(idx);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, idx);

    var compiled = try zlob.compilePattern(testing.allocator, "lib.rs", flags);
    defer compiled.deinit();
    try testing.expectEqual(zlob.CompiledPatternKind.basename_literal, std.meta.activeTag(compiled.body));
    try testing.expect(compiled.matches("src/lib.rs", flags));
    try testing.expect(compiled.matches("lib.rs", flags));
    try testing.expect(!compiled.matches("x/lib.rsx", flags));
    try testing.expect(!compiled.matches("xlib.rs", flags));
    // Runtime-length empty slice: a comptime "" would be folded through every
    // switch arm, including ones that index `path[len - 1]`.
    var zero: usize = 0;
    _ = &zero;
    var empty_buf: [1]u8 = undefined;
    try testing.expect(!compiled.matches(empty_buf[0..zero], flags));

    var general = try zlob.compilePattern(testing.allocator, "lib*", flags);
    defer general.deinit();
    try testing.expectEqual(zlob.CompiledPatternKind.basename_general, std.meta.activeTag(general.body));
    try testing.expect(general.matches("src/lib.rs", flags));
    try testing.expect(!general.matches("src/lib/x", flags));
    try testing.expect(!general.matches("src/lib/", flags));

    var brace = try zlob.compilePattern(testing.allocator, "{lib,mod}.rs", flags);
    defer brace.deinit();
    try testing.expectEqual(zlob.CompiledPatternKind.basename_brace, std.meta.activeTag(brace.body));
    const cidx = try zlob.matchPathIndicesCompiled(testing.allocator, &brace, &paths, flags);
    defer testing.allocator.free(cidx);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, cidx);

    // Shapes that are already basename tests keep their original kind.
    var suffix = try zlob.compilePattern(testing.allocator, "*.rs", flags);
    defer suffix.deinit();
    try testing.expectEqual(zlob.CompiledPatternKind.single_suffix_fast, std.meta.activeTag(suffix.body));
    // Anchored patterns are untouched by the flag.
    var anchored = try zlob.compilePattern(testing.allocator, "src/lib.rs", flags);
    defer anchored.deinit();
    try testing.expectEqual(zlob.CompiledPatternKind.literal, std.meta.activeTag(anchored.body));
}

test "basename: NOCHECK returns the pattern as written, empty pattern stays literal" {
    const paths = [_][]const u8{ "a/b", "c" };
    try expectMatches("nope*", BASENAME | NOCHECK, &paths, &.{"nope*"});
    try expectMatches("", BASENAME, &paths, &.{});
    try expectMatches("", BASENAME, &[_][]const u8{""}, &.{""});
}

test "basename: deep paths beyond the component buffer still match" {
    // 200 components: deeper than MAX_PATH_COMPONENTS, which makes the `**`
    // DP path give up. The basename matcher never splits, so it must still hit.
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    for (0..200) |_| {
        @memcpy(buf[len..][0..2], "d/");
        len += 2;
    }
    @memcpy(buf[len..][0..6], "leaf.c");
    len += 6;
    const paths = [_][]const u8{buf[0..len]};
    try expectMatches("leaf*", BASENAME, &paths, &.{buf[0..len]});
    try expectMatches("leaf.c", BASENAME, &paths, &.{buf[0..len]});
}

// ---------------------------------------------------------------------------
// Filesystem glob
// ---------------------------------------------------------------------------

const FsTree = struct {
    io: std.Io,
    tmp: std.testing.TmpDir,
    abs: [:0]u8,

    fn init(files: []const []const u8) !FsTree {
        const io = std.Io.Threaded.global_single_threaded.io();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for (files) |file| {
            if (std.fs.path.dirname(file)) |dir_path| {
                tmp.dir.createDirPath(io, dir_path) catch |err| {
                    if (err != error.PathAlreadyExists) return err;
                };
            }
            const f = try tmp.dir.createFile(io, file, .{});
            f.close(io);
        }
        const abs = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
        return .{ .io = io, .tmp = tmp, .abs = abs };
    }

    fn deinit(self: *FsTree) void {
        testing.allocator.free(self.abs);
        self.tmp.cleanup();
    }

    /// Glob relative to the tree root; results come back base-relative and sorted.
    fn globSorted(self: *FsTree, pattern: []const u8, flags: u32) ![][]const u8 {
        const sorted_flags = ZlobFlags.fromU32(flags).without(.{ .nosort = true });
        var res = try zlob.matchAt(testing.allocator, self.io, self.abs, pattern, sorted_flags) orelse
            return try testing.allocator.alloc([]const u8, 0);
        defer res.deinit();
        const out = try testing.allocator.alloc([]const u8, res.len());
        errdefer testing.allocator.free(out);
        for (out, 0..) |*o, i| o.* = try testing.allocator.dupe(u8, res.get(i));
        return out;
    }

    fn free(got: [][]const u8) void {
        for (got) |g| testing.allocator.free(g);
        testing.allocator.free(got);
    }

    fn expectGlob(self: *FsTree, pattern: []const u8, flags: u32, expected: []const []const u8) !void {
        const got = try self.globSorted(pattern, flags);
        defer free(got);
        testing.expectEqual(expected.len, got.len) catch |err| {
            std.debug.print("fs pattern {s}: got {d} matches:\n", .{ pattern, got.len });
            for (got) |g| std.debug.print("  {s}\n", .{g});
            return err;
        };
        for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
    }
};

test "basename fs: slash-less pattern walks the whole tree, anchored otherwise" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var t = try FsTree.init(&.{
        "libc.so.1",
        "hash-glibc/lib/libc.so.6",
        "nix/store/abc-musl/lib/libc.so",
        "lib/libm.so.6",
        "README.md",
        "docs/api/README.md",
        ".hidden/README.md",
        "src/.README.md",
    });
    defer t.deinit();

    try t.expectGlob("libc.so*", 0, &.{"libc.so.1"});
    try t.expectGlob("libc.so*", BASENAME, &.{ "hash-glibc/lib/libc.so.6", "libc.so.1", "nix/store/abc-musl/lib/libc.so" });
    try t.expectGlob("README.md", BASENAME, &.{ "README.md", "docs/api/README.md" });
    try t.expectGlob("README.md", BASENAME | PERIOD, &.{ ".hidden/README.md", "README.md", "docs/api/README.md" });
    try t.expectGlob(".README.md", BASENAME, &.{"src/.README.md"});
    try t.expectGlob("*.md", BASENAME | BRACE, &.{ "README.md", "docs/api/README.md" });
    try t.expectGlob("lib*.so*", BASENAME | BRACE, &.{ "hash-glibc/lib/libc.so.6", "lib/libm.so.6", "libc.so.1", "nix/store/abc-musl/lib/libc.so" });
    try t.expectGlob("lib{c,m}.so*", BASENAME | BRACE, &.{ "hash-glibc/lib/libc.so.6", "lib/libm.so.6", "libc.so.1", "nix/store/abc-musl/lib/libc.so" });
    // Directory entries: the recursive filesystem walk reports only
    // non-directories for the final component unless it ends with `/`
    // (pre-existing `**/x` behaviour; the flag inherits it exactly). A
    // trailing `/` is a separator, so that pattern stays anchored.
    try t.expectGlob("li*", BASENAME, &.{ "hash-glibc/lib/libc.so.6", "lib/libm.so.6", "libc.so.1", "nix/store/abc-musl/lib/libc.so" });
    try t.expectGlob("**/li*", RECURSIVE, &.{ "hash-glibc/lib/libc.so.6", "lib/libm.so.6", "libc.so.1", "nix/store/abc-musl/lib/libc.so" });
    try t.expectGlob("lib", BASENAME, &.{});
    try t.expectGlob("lib/", BASENAME, &.{"lib"});
    // Separators anchor, including `./`.
    try t.expectGlob("./README.md", BASENAME, &.{"README.md"});
    try t.expectGlob("docs/*/README.md", BASENAME, &.{"docs/api/README.md"});
    // Works without DOUBLESTAR_RECURSIVE: the rewrite forces recursion on.
    try t.expectGlob("libm.so.6", BASENAME, &.{"lib/libm.so.6"});
}

test "basename fs: NOCHECK/NOMAGIC report the caller's pattern, not the rewritten one" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var t = try FsTree.init(&.{"a/b.txt"});
    defer t.deinit();

    try t.expectGlob("missing*", BASENAME | NOCHECK, &.{"missing*"});
    try t.expectGlob("missing.txt", BASENAME | zlob_flags.ZLOB_NOMAGIC, &.{"missing.txt"});
    try t.expectGlob("b.txt", BASENAME | NOCHECK, &.{"a/b.txt"});
}

test "basename fs: MAGCHAR output flag reflects the user's pattern" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var t = try FsTree.init(&.{"a/b.txt"});
    defer t.deinit();

    const zlob_core = @import("zlob_core");
    var pzlob: zlob_core.zlob_t = undefined;
    pzlob.zlo_flags = 0;
    const pattern_z = try testing.allocator.dupeZ(u8, "b.txt");
    defer testing.allocator.free(pattern_z);
    _ = try zlob_core.globAt(testing.allocator, t.io, t.abs, pattern_z.ptr, @bitCast(@as(u32, BASENAME)), null, &pzlob);
    defer zlob_core.globfreeInternal(testing.allocator, &pzlob);
    try testing.expectEqual(@as(usize, 1), pzlob.zlo_pathc);
    try testing.expect(pzlob.zlo_flags & zlob_flags.ZLOB_MAGCHAR == 0);
}

// ---------------------------------------------------------------------------
// Walker
// ---------------------------------------------------------------------------

test "basename walker: pattern filter honours match_basename in pattern_flags" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var t = try FsTree.init(&.{
        "src/a.rs",
        "src/deep/mod.rs",
        "lib/mod.rs",
        "mod.rs",
        "docs/d.md",
    });
    defer t.deinit();

    var results = try walk.collect(testing.allocator, t.abs, .{
        .threads = 1,
        .sort = true,
        .pattern = "mod.rs",
        .pattern_flags = .{ .brace = true, .doublestar_recursive = true, .match_basename = true },
    });
    defer results.deinit();
    try testing.expectEqual(@as(usize, 3), results.entries.len);
    try testing.expectEqualStrings("lib/mod.rs", results.entries[0].relativePath());
    try testing.expectEqualStrings("mod.rs", results.entries[1].relativePath());
    try testing.expectEqualStrings("src/deep/mod.rs", results.entries[2].relativePath());

    var anchored = try walk.collect(testing.allocator, t.abs, .{
        .threads = 1,
        .sort = true,
        .pattern = "mod.rs",
    });
    defer anchored.deinit();
    try testing.expectEqual(@as(usize, 1), anchored.entries.len);
    try testing.expectEqualStrings("mod.rs", anchored.entries[0].relativePath());
}
