// Ported from rust-lang/glob tests/glob-std.rs
// https://github.com/rust-lang/glob/blob/master/tests/glob-std.rs
//
// Original copyright:
// Copyright 2013-2014 The Rust Project Developers
// Licensed under Apache-2.0 or MIT

const std = @import("std");
const testing = std.testing;
const simdglob = @import("simdglob");
const glob = simdglob.glob;
const fs = std.fs;

const TestDir = struct {
    dir: std.testing.TmpDir,
    path: []const u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !TestDir {
        const tmp = std.testing.tmpDir(.{});
        const path = try tmp.dir.realpathAlloc(allocator, ".");
        return .{
            .dir = tmp,
            .path = path,
            .allocator = allocator,
        };
    }

    fn deinit(self: *TestDir) void {
        self.allocator.free(self.path);
        self.dir.cleanup();
    }

    fn mkFile(self: *TestDir, path: []const u8, is_directory: bool) !void {
        if (is_directory) {
            try self.dir.dir.makePath(path);
        } else {
            // Ensure parent directories exist
            if (fs.path.dirname(path)) |parent| {
                try self.dir.dir.makePath(parent);
            }
            const file = try self.dir.dir.createFile(path, .{});
            file.close();
        }
    }

    fn mkSymlinkFile(self: *TestDir, original: []const u8, link: []const u8) !void {
        _ = self;
        _ = original;
        _ = link;
        // TODO: Implement symlink support when needed
        return error.SkipZigTest;
    }

    fn mkSymlinkDir(self: *TestDir, original: []const u8, link: []const u8) !void {
        _ = self;
        _ = original;
        _ = link;
        // TODO: Implement symlink support when needed
        return error.SkipZigTest;
    }

    fn globVec(self: *TestDir, allocator: std.mem.Allocator, pattern: []const u8) ![][]const u8 {
        // Change to test directory
        const old_cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(old_cwd);
        try std.posix.chdir(self.path);
        defer std.posix.chdir(old_cwd) catch {};

        var g = glob.Glob.init(allocator, 0);
        defer g.deinit();

        // Handle NoMatch by returning empty array (Rust glob behavior)
        var result = g.glob(pattern) catch |err| {
            if (err == error.NoMatch) {
                return try allocator.alloc([]const u8, 0);
            }
            return err;
        };
        defer result.deinit();

        // Copy paths to return (must copy because result will be freed)
        const paths = try allocator.alloc([]const u8, result.paths.len);
        for (result.paths, 0..) |path, i| {
            paths[i] = try allocator.dupe(u8, path);
        }

        return paths;
    }

    fn expectPaths(actual: [][]const u8, expected: []const []const u8) !void {
        if (actual.len != expected.len) {
            std.debug.print("\nExpected {} paths, got {}\n", .{ expected.len, actual.len });
            std.debug.print("Expected:\n", .{});
            for (expected) |path| {
                std.debug.print("  {s}\n", .{path});
            }
            std.debug.print("Actual:\n", .{});
            for (actual) |path| {
                std.debug.print("  {s}\n", .{path});
            }
            return error.TestUnexpectedResult;
        }

        for (expected) |exp_path| {
            var found = false;
            for (actual) |act_path| {
                if (std.mem.eql(u8, exp_path, act_path)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.debug.print("\nExpected path not found: {s}\n", .{exp_path});
                std.debug.print("Actual paths:\n", .{});
                for (actual) |path| {
                    std.debug.print("  {s}\n", .{path});
                }
                return error.TestUnexpectedResult;
            }
        }
    }
};

// Basic literal path tests
test "glob-rust: literal path" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "aaa");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa"});
}

test "glob-rust: literal path with trailing slash" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "aaa/");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa"});
}

test "glob-rust: non-matching literal" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "bbb");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try testing.expect(paths.len == 0);
}

// Wildcard tests
test "glob-rust: single star wildcard" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);
    try td.mkFile("bbb", true);
    try td.mkFile("ccc", true);

    const paths = try td.globVec(testing.allocator, "a*");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa"});
}

test "glob-rust: star in middle" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "a*a");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa"});
}

test "glob-rust: multiple stars" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "*a*a*a*");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa"});
}

// Question mark tests
test "glob-rust: three question marks" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);
    try td.mkFile("bbb", true);
    try td.mkFile("ccc", true);
    try td.mkFile("xyz", true);

    const paths = try td.globVec(testing.allocator, "???/");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{ "aaa", "bbb", "ccc", "xyz" });
}

test "glob-rust: single question mark" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("xyz", true);
    try td.mkFile("xyz/x", false);
    try td.mkFile("xyz/y", false);
    try td.mkFile("xyz/z", false);

    const paths = try td.globVec(testing.allocator, "xyz/?");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{ "xyz/x", "xyz/y", "xyz/z" });
}

test "glob-rust: question mark in filename" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);
    try td.mkFile("aaa/tomato", true);
    try td.mkFile("aaa/tomato/tomato.txt", false);
    try td.mkFile("aaa/tomato/tomoto.txt", false);

    const paths = try td.globVec(testing.allocator, "aaa/tomato/tom?to.txt");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{ "aaa/tomato/tomato.txt", "aaa/tomato/tomoto.txt" });
}

// Nested path tests
test "glob-rust: nested wildcard" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);
    try td.mkFile("aaa/apple", true);
    try td.mkFile("aaa/orange", true);
    try td.mkFile("aaa/tomato", true);

    const paths = try td.globVec(testing.allocator, "aaa/*");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{ "aaa/apple", "aaa/orange", "aaa/tomato" });
}

test "glob-rust: multiple nested wildcards" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);
    try td.mkFile("aaa/tomato", true);
    try td.mkFile("aaa/tomato/tomato.txt", false);
    try td.mkFile("aaa/tomato/tomoto.txt", false);

    const paths = try td.globVec(testing.allocator, "*/*/*.txt");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{ "aaa/tomato/tomato.txt", "aaa/tomato/tomoto.txt" });
}

// Character class tests
test "glob-rust: simple character class" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "aa[a]");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa"});
}

test "glob-rust: character class with multiple options" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "aa[abc]");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa"});
}

test "glob-rust: character class in middle" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "a[bca]a");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa"});
}

test "glob-rust: character class non-matching" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "aa[b]");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try testing.expect(paths.len == 0);
}

// Negated character class tests
test "glob-rust: negated character class" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "aa[!b]");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa"});
}

test "glob-rust: negated character class multiple" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "aa[!bcd]");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa"});
}

test "glob-rust: negated character class non-matching" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "aa[!a]");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try testing.expect(paths.len == 0);
}

// Complex pattern tests
test "glob-rust: complex pattern with all features" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);
    try td.mkFile("aaa/tomato", true);
    try td.mkFile("aaa/tomato/tomato.txt", false);
    try td.mkFile("aaa/tomato/tomoto.txt", false);

    const paths = try td.globVec(testing.allocator, "*/*/t[aob]m?to[.]t[!y]t");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{ "aaa/tomato/tomato.txt", "aaa/tomato/tomoto.txt" });
}

// Relative path tests
test "glob-rust: dot prefix" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "./aaa");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa"});
}

test "glob-rust: dot star" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);
    try td.mkFile("bbb", true);

    const paths1 = try td.globVec(testing.allocator, "./*");
    defer {
        for (paths1) |path| testing.allocator.free(path);
        testing.allocator.free(paths1);
    }

    const paths2 = try td.globVec(testing.allocator, "*");
    defer {
        for (paths2) |path| testing.allocator.free(path);
        testing.allocator.free(paths2);
    }

    try testing.expect(paths1.len == paths2.len);
}

// Special character tests
test "glob-rust: bracket literal" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("bbb", true);
    try td.mkFile("bbb/specials", true);
    try td.mkFile("bbb/specials/[", false);

    const paths = try td.globVec(testing.allocator, "bbb/specials/[[]");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"bbb/specials/["});
}

test "glob-rust: exclamation literal" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("bbb", true);
    try td.mkFile("bbb/specials", true);
    try td.mkFile("bbb/specials/!", false);

    const paths = try td.globVec(testing.allocator, "bbb/specials/!");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"bbb/specials/!"});
}

test "glob-rust: right bracket literal" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("bbb", true);
    try td.mkFile("bbb/specials", true);
    try td.mkFile("bbb/specials/]", false);

    const paths = try td.globVec(testing.allocator, "bbb/specials/[]]");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"bbb/specials/]"});
}

// Empty and edge case tests
test "glob-rust: empty pattern" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);

    const paths = try td.globVec(testing.allocator, "");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try testing.expect(paths.len == 0);
}

test "glob-rust: dot" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    const paths = try td.globVec(testing.allocator, ".");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"."});
}

test "glob-rust: dot dot" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    const paths = try td.globVec(testing.allocator, "..");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{".."});
}

test "glob-rust: trailing slash on file returns nothing" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);
    try td.mkFile("aaa/tomato", true);
    try td.mkFile("aaa/tomato/tomato.txt", false);

    const paths = try td.globVec(testing.allocator, "aaa/tomato/tomato.txt/");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try testing.expect(paths.len == 0);
}

test "glob-rust: nested path" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);
    try td.mkFile("aaa/apple", true);

    const paths = try td.globVec(testing.allocator, "aaa/apple");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try TestDir.expectPaths(paths, &.{"aaa/apple"});
}

test "glob-rust: nested path non-existent" {
    var td = try TestDir.init(testing.allocator);
    defer td.deinit();

    try td.mkFile("aaa", true);
    try td.mkFile("aaa/apple", true);

    const paths = try td.globVec(testing.allocator, "aaa/apple/nope");
    defer {
        for (paths) |path| testing.allocator.free(path);
        testing.allocator.free(paths);
    }

    try testing.expect(paths.len == 0);
}
