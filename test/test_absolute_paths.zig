// Cross-platform absolute-path globbing tests.
//
// These tests run zlob against patterns that are PREFIXED with the absolute
// path of a temporary directory. On POSIX the prefix looks like
// `/var/folders/.../zig-tmp-XXX`; on Windows it looks like
// `C:/Users/.../AppData/Local/Temp/zig-tmp-XXX` (backslashes normalised to
// forward slashes per zlob's documented Windows convention).
//
// The goal is to exercise every glob feature against absolute paths so we
// catch any platform-specific path-construction regression. Every test runs
// on Linux, macOS and Windows in CI.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const zlob = @import("zlob");
const zlob_flags = @import("zlob_flags");

const AbsTestDir = struct {
    tmp: std.testing.TmpDir,
    abs_path: [:0]u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, comptime files: []const []const u8) !AbsTestDir {
        const io = std.Io.Threaded.global_single_threaded.io();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const abs_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(abs_path);

        // Normalise to forward slashes - zlob accepts forward slashes on every
        // platform (README.md:17), and the tests assert against forward-slash
        // literals.
        if (builtin.os.tag == .windows) {
            for (abs_path) |*ch| {
                if (ch.* == '\\') ch.* = '/';
            }
        }

        for (files) |f| {
            if (std.fs.path.dirname(f)) |dir_path| {
                tmp.dir.createDirPath(io, dir_path) catch |err| {
                    if (err != error.PathAlreadyExists) return err;
                };
            }
            const file = try tmp.dir.createFile(io, f, .{});
            file.close(io);
        }

        return .{ .tmp = tmp, .abs_path = abs_path, .allocator = allocator };
    }

    fn deinit(self: *AbsTestDir) void {
        self.allocator.free(self.abs_path);
        self.tmp.cleanup();
    }

    fn buildPattern(self: *const AbsTestDir, allocator: std.mem.Allocator, rel_pattern: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.abs_path, rel_pattern });
    }

    /// Run zlob.match with the absolute pattern and return result paths
    /// stripped of the absolute prefix and normalised to forward slashes.
    fn glob(self: *const AbsTestDir, allocator: std.mem.Allocator, rel_pattern: []const u8, flags: u32) ![][]u8 {
        const io = std.Io.Threaded.global_single_threaded.io();
        const full_pattern = try self.buildPattern(allocator, rel_pattern);
        defer allocator.free(full_pattern);

        var result_opt = try zlob.match(allocator, io, full_pattern, flags);
        if (result_opt) |*r| {
            defer r.deinit();
            const len = r.len();
            var out = try allocator.alloc([]u8, len);
            errdefer {
                for (out[0..]) |p| allocator.free(p);
                allocator.free(out);
            }

            const prefix_len = self.abs_path.len + 1;
            for (0..len) |i| {
                var owned = try allocator.dupe(u8, r.get(i));
                if (builtin.os.tag == .windows) {
                    for (owned) |*ch| {
                        if (ch.* == '\\') ch.* = '/';
                    }
                }
                if (owned.len > prefix_len and std.mem.startsWith(u8, owned, self.abs_path)) {
                    const stripped = try allocator.dupe(u8, owned[prefix_len..]);
                    allocator.free(owned);
                    out[i] = stripped;
                } else {
                    out[i] = owned;
                }
            }
            return out;
        } else {
            return try allocator.alloc([]u8, 0);
        }
    }
};

fn freePaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

fn hasPath(paths: [][]u8, expected: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, expected)) return true;
    }
    return false;
}

// ============================================================================
// Basic wildcards
// ============================================================================

test "abs: *.c suffix wildcard" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "foo.c", "bar.c", "baz.txt", "qux.h" });
    defer td.deinit();

    const paths = try td.glob(allocator, "*.c", 0);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "foo.c"));
    try testing.expect(hasPath(paths, "bar.c"));
}

test "abs: bare star matches all files" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "a.c", "b.c", "c.txt" });
    defer td.deinit();

    const paths = try td.glob(allocator, "*", 0);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 3), paths.len);
}

test "abs: ? single-char wildcard" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "a.c", "ab.c", "abc.c" });
    defer td.deinit();

    const paths = try td.glob(allocator, "?.c", 0);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expect(hasPath(paths, "a.c"));
}

// ============================================================================
// Character classes
// ============================================================================

test "abs: [ab].c character class" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "a.c", "b.c", "c.c", "d.c" });
    defer td.deinit();

    const paths = try td.glob(allocator, "[ab].c", 0);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "a.c"));
    try testing.expect(hasPath(paths, "b.c"));
}

test "abs: [a-z]*.c character range" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "alpha.c", "beta.c", "1.c", "2.c" });
    defer td.deinit();

    const paths = try td.glob(allocator, "[a-z]*.c", 0);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "alpha.c"));
    try testing.expect(hasPath(paths, "beta.c"));
}

test "abs: *.[!h] negated character class" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "main.c", "main.h", "main.cpp", "main.hpp" });
    defer td.deinit();

    const paths = try td.glob(allocator, "*.[!h]", 0);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expect(hasPath(paths, "main.c"));
}

test "abs: *.[ch] character class on extension" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "main.c", "main.h", "main.txt" });
    defer td.deinit();

    const paths = try td.glob(allocator, "*.[ch]", 0);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "main.c"));
    try testing.expect(hasPath(paths, "main.h"));
}

// ============================================================================
// Brace expansion
// ============================================================================

test "abs: {a,b}.c brace alternatives" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "a.c", "b.c", "c.c" });
    defer td.deinit();

    const paths = try td.glob(allocator, "{a,b}.c", zlob_flags.ZLOB_BRACE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "a.c"));
    try testing.expect(hasPath(paths, "b.c"));
}

test "abs: opencode.json{,c} empty brace alternative" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "opencode.json",
        "opencode.jsonc",
        "opencode.json5",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "opencode.json{,c}", zlob_flags.ZLOB_BRACE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "opencode.json"));
    try testing.expect(hasPath(paths, "opencode.jsonc"));
}

test "abs: *.{c,h} brace on extension with wildcard" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "a.c", "b.h", "c.txt" });
    defer td.deinit();

    const paths = try td.glob(allocator, "*.{c,h}", zlob_flags.ZLOB_BRACE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "a.c"));
    try testing.expect(hasPath(paths, "b.h"));
}

// ============================================================================
// Brace expansion as directory component
// ============================================================================

test "abs: {src,lib}/*.c brace as directory" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "src/main.c",
        "src/util.c",
        "lib/lib.c",
        "docs/x.c",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "{src,lib}/*.c", zlob_flags.ZLOB_BRACE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expect(hasPath(paths, "src/main.c"));
    try testing.expect(hasPath(paths, "src/util.c"));
    try testing.expect(hasPath(paths, "lib/lib.c"));
}

test "abs: {a,b}/{x,y}.txt multi brace" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "a/x.txt",
        "a/y.txt",
        "b/x.txt",
        "b/y.txt",
        "c/x.txt",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "{a,b}/{x,y}.txt", zlob_flags.ZLOB_BRACE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 4), paths.len);
    try testing.expect(hasPath(paths, "a/x.txt"));
    try testing.expect(hasPath(paths, "a/y.txt"));
    try testing.expect(hasPath(paths, "b/x.txt"));
    try testing.expect(hasPath(paths, "b/y.txt"));
}

test "abs: {src,lib}/*.{c,h} brace dir + brace file" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "src/main.c",
        "src/main.h",
        "lib/lib.c",
        "lib/lib.h",
        "docs/x.c",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "{src,lib}/*.{c,h}", zlob_flags.ZLOB_BRACE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 4), paths.len);
    try testing.expect(hasPath(paths, "src/main.c"));
    try testing.expect(hasPath(paths, "src/main.h"));
    try testing.expect(hasPath(paths, "lib/lib.c"));
    try testing.expect(hasPath(paths, "lib/lib.h"));
}

// ============================================================================
// Recursive ** patterns
// ============================================================================

test "abs: **/*.c recursive descent" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "a.c",
        "src/b.c",
        "src/util/c.c",
        "docs/readme.txt",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "**/*.c", zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE);
    defer freePaths(allocator, paths);

    // **/*.c matches files at any depth including the abs root.
    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expect(hasPath(paths, "a.c"));
    try testing.expect(hasPath(paths, "src/b.c"));
    try testing.expect(hasPath(paths, "src/util/c.c"));
}

test "abs: **/*.{c,h} recursive + brace ext" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "src/a.c",
        "src/a.h",
        "lib/b.c",
        "lib/b.h",
        "docs/readme.md",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "**/*.{c,h}", zlob_flags.ZLOB_BRACE | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 4), paths.len);
    try testing.expect(hasPath(paths, "src/a.c"));
    try testing.expect(hasPath(paths, "src/a.h"));
    try testing.expect(hasPath(paths, "lib/b.c"));
    try testing.expect(hasPath(paths, "lib/b.h"));
}

test "abs: {src,lib}/**/*.c brace dir + recursive" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "src/a.c",
        "src/sub/b.c",
        "src/sub/deep/c.c",
        "lib/d.c",
        "docs/e.c",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "{src,lib}/**/*.c", zlob_flags.ZLOB_BRACE | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 4), paths.len);
    try testing.expect(hasPath(paths, "src/a.c"));
    try testing.expect(hasPath(paths, "src/sub/b.c"));
    try testing.expect(hasPath(paths, "src/sub/deep/c.c"));
    try testing.expect(hasPath(paths, "lib/d.c"));
}

test "abs: {src,lib}/**/*.{c,h} all-features brace recursive" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "src/a.c",
        "src/a.h",
        "src/sub/b.c",
        "src/sub/b.h",
        "lib/c.c",
        "lib/c.h",
        "docs/d.c",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "{src,lib}/**/*.{c,h}", zlob_flags.ZLOB_BRACE | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 6), paths.len);
    try testing.expect(hasPath(paths, "src/a.c"));
    try testing.expect(hasPath(paths, "src/a.h"));
    try testing.expect(hasPath(paths, "src/sub/b.c"));
    try testing.expect(hasPath(paths, "src/sub/b.h"));
    try testing.expect(hasPath(paths, "lib/c.c"));
    try testing.expect(hasPath(paths, "lib/c.h"));
}

// ============================================================================
// Extglob (bash-style)
// ============================================================================

test "abs: @(foo|bar).c extglob alternation" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "foo.c", "bar.c", "baz.c" });
    defer td.deinit();

    const paths = try td.glob(allocator, "@(foo|bar).c", zlob_flags.ZLOB_EXTGLOB);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "foo.c"));
    try testing.expect(hasPath(paths, "bar.c"));
}

test "abs: !(foo).c extglob negation" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "foo.c", "bar.c", "baz.c" });
    defer td.deinit();

    const paths = try td.glob(allocator, "!(foo).c", zlob_flags.ZLOB_EXTGLOB);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "bar.c"));
    try testing.expect(hasPath(paths, "baz.c"));
}

test "abs: ?(a|b).c extglob optional" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "a.c", "b.c", ".c", "ab.c" });
    defer td.deinit();

    const paths = try td.glob(allocator, "?(a|b).c", zlob_flags.ZLOB_EXTGLOB);
    defer freePaths(allocator, paths);

    // ?(a|b) matches zero or one of a/b. The empty match would produce
    // ".c" but it's a hidden file - excluded without ZLOB_PERIOD.
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "a.c"));
    try testing.expect(hasPath(paths, "b.c"));
}

test "abs: ?(a|b).c extglob optional with PERIOD includes hidden" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "a.c", "b.c", ".c", "ab.c" });
    defer td.deinit();

    const paths = try td.glob(allocator, "?(a|b).c", zlob_flags.ZLOB_EXTGLOB | zlob_flags.ZLOB_PERIOD);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expect(hasPath(paths, "a.c"));
    try testing.expect(hasPath(paths, "b.c"));
    try testing.expect(hasPath(paths, ".c"));
}

test "abs: *(ab).c extglob zero-or-more" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ ".c", "ab.c", "abab.c", "abc.c" });
    defer td.deinit();

    const paths = try td.glob(allocator, "*(ab).c", zlob_flags.ZLOB_EXTGLOB);
    defer freePaths(allocator, paths);

    // Zero-or-more "ab". The empty match would produce ".c" but it's hidden
    // (without ZLOB_PERIOD), so we get only "ab.c" and "abab.c".
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "ab.c"));
    try testing.expect(hasPath(paths, "abab.c"));
}

test "abs: +(ab).c extglob one-or-more" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ ".c", "ab.c", "abab.c", "abc.c" });
    defer td.deinit();

    const paths = try td.glob(allocator, "+(ab).c", zlob_flags.ZLOB_EXTGLOB);
    defer freePaths(allocator, paths);

    // One-or-more "ab" -> "ab.c", "abab.c"
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "ab.c"));
    try testing.expect(hasPath(paths, "abab.c"));
}

test "abs: extglob + brace combined" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "src/main.c",
        "src/main.h",
        "lib/util.c",
        "lib/util.h",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "{src,lib}/*.!(h)", zlob_flags.ZLOB_EXTGLOB | zlob_flags.ZLOB_BRACE);
    defer freePaths(allocator, paths);

    // Should match all .c files (anything not ending in .h)
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "src/main.c"));
    try testing.expect(hasPath(paths, "lib/util.c"));
}

// ============================================================================
// Combinations: every feature together
// ============================================================================

test "abs: brace dir + recursive + brace file + extglob" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "src/main.c",
        "src/main.h",
        "src/main.tmp",
        "src/sub/util.c",
        "src/sub/util.h",
        "lib/lib.c",
        "lib/lib.h",
        "docs/readme.md",
    });
    defer td.deinit();

    // Brace dir + recursive + brace ext
    const paths = try td.glob(allocator, "{src,lib}/**/*.{c,h}", zlob_flags.ZLOB_BRACE | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 6), paths.len);
    try testing.expect(hasPath(paths, "src/main.c"));
    try testing.expect(hasPath(paths, "src/main.h"));
    try testing.expect(hasPath(paths, "src/sub/util.c"));
    try testing.expect(hasPath(paths, "src/sub/util.h"));
    try testing.expect(hasPath(paths, "lib/lib.c"));
    try testing.expect(hasPath(paths, "lib/lib.h"));
}

test "abs: literal dir + wildcard file" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "src/a.c",
        "src/b.c",
        "lib/c.c",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "src/*.c", 0);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "src/a.c"));
    try testing.expect(hasPath(paths, "src/b.c"));
}

test "abs: nested literal dir + wildcard file" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "src/sub/a.c",
        "src/sub/b.c",
        "src/other/c.c",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "src/sub/*.c", 0);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, "src/sub/a.c"));
    try testing.expect(hasPath(paths, "src/sub/b.c"));
}

test "abs: literal path - exact file match" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        "Cargo.toml",
        "Cargo.lock",
    });
    defer td.deinit();

    const paths = try td.glob(allocator, "Cargo.toml", 0);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expect(hasPath(paths, "Cargo.toml"));
}

// ============================================================================
// Hidden files / directories with ZLOB_PERIOD
//
// Without ZLOB_PERIOD, wildcards do NOT match leading-dot names. With
// ZLOB_PERIOD they do. These tests exercise every feature against an absolute
// path prefix where the matched files or one of the directory components is
// a dot-prefixed (hidden) entry.
// ============================================================================

test "abs+period: *.c matches hidden files" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        ".hidden.c",
        "visible.c",
        ".env",
    });
    defer td.deinit();

    const paths_no = try td.glob(allocator, "*.c", 0);
    defer freePaths(allocator, paths_no);
    try testing.expectEqual(@as(usize, 1), paths_no.len);
    try testing.expect(hasPath(paths_no, "visible.c"));

    const paths = try td.glob(allocator, "*.c", zlob_flags.ZLOB_PERIOD);
    defer freePaths(allocator, paths);
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, ".hidden.c"));
    try testing.expect(hasPath(paths, "visible.c"));
}

test "abs+period: explicit dot prefix always matches" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        ".env",
        ".gitignore",
        "README.md",
    });
    defer td.deinit();

    // Pattern starts with literal '.' so the hidden-file gate is implicitly
    // bypassed. zlob also returns the synthetic "." and ".." entries on POSIX
    // when the pattern's first char is '.'.
    const paths = try td.glob(allocator, ".[a-z]*", 0);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, ".env"));
    try testing.expect(hasPath(paths, ".gitignore"));
}

test "abs+period: .opencode/opencode.json{,c} hidden directory + brace empty alt" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        ".opencode/opencode.json",
        ".opencode/opencode.jsonc",
        ".opencode/agents/foo.md",
        "opencode.json",
    });
    defer td.deinit();

    // Directory component starts with literal '.' so PERIOD is not required
    // to traverse into it.
    const paths = try td.glob(allocator, ".opencode/opencode.json{,c}", zlob_flags.ZLOB_BRACE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expect(hasPath(paths, ".opencode/opencode.json"));
    try testing.expect(hasPath(paths, ".opencode/opencode.jsonc"));
}

test "abs+period: **/opencode.json{,c} requires PERIOD to descend into hidden dirs" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        ".opencode/opencode.json",
        ".opencode/opencode.jsonc",
        "packages/cli/opencode.json",
        "packages/web/opencode.jsonc",
    });
    defer td.deinit();

    // Without PERIOD, ** does not descend into '.opencode/'.
    const paths_no = try td.glob(allocator, "**/opencode.json{,c}", zlob_flags.ZLOB_BRACE | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE);
    defer freePaths(allocator, paths_no);
    try testing.expectEqual(@as(usize, 2), paths_no.len);
    try testing.expect(hasPath(paths_no, "packages/cli/opencode.json"));
    try testing.expect(hasPath(paths_no, "packages/web/opencode.jsonc"));

    // With PERIOD, '.opencode/' is included.
    const paths = try td.glob(allocator, "**/opencode.json{,c}", zlob_flags.ZLOB_BRACE | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE | zlob_flags.ZLOB_PERIOD);
    defer freePaths(allocator, paths);
    try testing.expectEqual(@as(usize, 4), paths.len);
    try testing.expect(hasPath(paths, ".opencode/opencode.json"));
    try testing.expect(hasPath(paths, ".opencode/opencode.jsonc"));
    try testing.expect(hasPath(paths, "packages/cli/opencode.json"));
    try testing.expect(hasPath(paths, "packages/web/opencode.jsonc"));
}

test "abs+period: {.a,a,b}.c hidden brace alternative" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        ".a.c",
        "a.c",
        "b.c",
    });
    defer td.deinit();

    // Without PERIOD, even an explicit literal alternative starting with '.'
    // does NOT bypass the iterator's hidden-file gate inside the brace
    // expansion path. PERIOD is required to surface ".a.c".
    const paths_no = try td.glob(allocator, "{.a,a,b}.c", zlob_flags.ZLOB_BRACE);
    defer freePaths(allocator, paths_no);
    try testing.expectEqual(@as(usize, 2), paths_no.len);

    const paths = try td.glob(allocator, "{.a,a,b}.c", zlob_flags.ZLOB_BRACE | zlob_flags.ZLOB_PERIOD);
    defer freePaths(allocator, paths);
    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expect(hasPath(paths, ".a.c"));
    try testing.expect(hasPath(paths, "a.c"));
    try testing.expect(hasPath(paths, "b.c"));
}

test "abs+period: **/*.{c,h} with PERIOD across hidden dirs" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        ".cache/main.c",
        ".cache/main.h",
        "src/util.c",
        "src/util.h",
    });
    defer td.deinit();

    const paths_no = try td.glob(allocator, "**/*.{c,h}", zlob_flags.ZLOB_BRACE | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE);
    defer freePaths(allocator, paths_no);
    try testing.expectEqual(@as(usize, 2), paths_no.len);
    try testing.expect(hasPath(paths_no, "src/util.c"));
    try testing.expect(hasPath(paths_no, "src/util.h"));

    const paths = try td.glob(allocator, "**/*.{c,h}", zlob_flags.ZLOB_BRACE | zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE | zlob_flags.ZLOB_PERIOD);
    defer freePaths(allocator, paths);
    try testing.expectEqual(@as(usize, 4), paths.len);
    try testing.expect(hasPath(paths, ".cache/main.c"));
    try testing.expect(hasPath(paths, ".cache/main.h"));
    try testing.expect(hasPath(paths, "src/util.c"));
    try testing.expect(hasPath(paths, "src/util.h"));
}

test "abs+period: ?(a|b).c extglob optional matches hidden empty case" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ "a.c", "b.c", ".c", "ab.c" });
    defer td.deinit();

    const paths_no = try td.glob(allocator, "?(a|b).c", zlob_flags.ZLOB_EXTGLOB);
    defer freePaths(allocator, paths_no);
    try testing.expectEqual(@as(usize, 2), paths_no.len);

    const paths = try td.glob(allocator, "?(a|b).c", zlob_flags.ZLOB_EXTGLOB | zlob_flags.ZLOB_PERIOD);
    defer freePaths(allocator, paths);
    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expect(hasPath(paths, "a.c"));
    try testing.expect(hasPath(paths, "b.c"));
    try testing.expect(hasPath(paths, ".c"));
}

test "abs+period: *(ab).c extglob zero-or-more matches hidden empty" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{ ".c", "ab.c", "abab.c", "abc.c" });
    defer td.deinit();

    const paths_no = try td.glob(allocator, "*(ab).c", zlob_flags.ZLOB_EXTGLOB);
    defer freePaths(allocator, paths_no);
    try testing.expectEqual(@as(usize, 2), paths_no.len);

    const paths = try td.glob(allocator, "*(ab).c", zlob_flags.ZLOB_EXTGLOB | zlob_flags.ZLOB_PERIOD);
    defer freePaths(allocator, paths);
    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expect(hasPath(paths, ".c"));
    try testing.expect(hasPath(paths, "ab.c"));
    try testing.expect(hasPath(paths, "abab.c"));
}

test "abs+period: {.cache,src}/*.c hidden brace alt as dir" {
    const allocator = testing.allocator;
    var td = try AbsTestDir.init(allocator, &.{
        ".cache/a.c",
        ".cache/b.c",
        "src/c.c",
        "lib/d.c",
    });
    defer td.deinit();

    // Brace alt is a literal dot-prefixed dir name - matches even without PERIOD.
    const paths = try td.glob(allocator, "{.cache,src}/*.c", zlob_flags.ZLOB_BRACE);
    defer freePaths(allocator, paths);

    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expect(hasPath(paths, ".cache/a.c"));
    try testing.expect(hasPath(paths, ".cache/b.c"));
    try testing.expect(hasPath(paths, "src/c.c"));
}
