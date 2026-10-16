//! Randomized cross-check for ZLOB_MATCH_BASENAME. Each basename matcher
//! (batch, at-mode, indices, compiled) must give the same answer as the
//! plain matcher run on the last component of the path. The paths are also
//! copied against PROT_NONE guard pages, so a read past either end of a path
//! faults instead of passing silently.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const zlob = @import("zlob");
const zlob_flags = @import("zlob_flags");

const ZlobFlags = zlob_flags.ZlobFlags;

const Token = struct {
    pat: []const u8,
    /// Texts that the token can match. They make matching paths likely; the
    /// oracle still decides the expected answer.
    samples: []const []const u8,
};

const long_name = "x_long_component_name";

const plain_tokens = [_]Token{
    .{ .pat = "a", .samples = &.{"a"} },
    .{ .pat = "lib", .samples = &.{"lib"} },
    .{ .pat = ".", .samples = &.{"."} },
    .{ .pat = ".so", .samples = &.{".so"} },
    .{ .pat = long_name, .samples = &.{long_name} },
    .{ .pat = "*", .samples = &.{ "", "b", "ab.c", "zzzzzzzzzzzzzzzzzzzz" } },
    .{ .pat = "?", .samples = &.{ "a", "." } },
    .{ .pat = "[ab]", .samples = &.{ "a", "b" } },
    .{ .pat = "[!a]", .samples = &.{ "b", "." } },
    .{ .pat = "[a-c]", .samples = &.{"c"} },
    .{ .pat = "\\*", .samples = &.{ "*", "\\x" } },
    .{ .pat = "\\a", .samples = &.{ "a", "\\a" } },
};

const brace_tokens = [_]Token{
    .{ .pat = "{a,lib}", .samples = &.{ "a", "lib" } },
    .{ .pat = "{.so,b*}", .samples = &.{ ".so", "bq" } },
    .{ .pat = "{,a}", .samples = &.{ "", "a" } },
    .{ .pat = "{" ++ long_name ++ ",y}", .samples = &.{ long_name, "y" } },
};

const extglob_tokens = [_]Token{
    .{ .pat = "@(a|lib)", .samples = &.{ "a", "lib" } },
    .{ .pat = "*(a)", .samples = &.{ "", "aa" } },
    .{ .pat = "+(b)", .samples = &.{"b"} },
    .{ .pat = "!(a)", .samples = &.{ "b", "a" } },
};

const dir_names = [_][]const u8{ "a", "src", "lib", ".hidden", "a.b", long_name ++ "_dir", "*" };

fn pick(rng: std.Random, comptime T: type, items: []const T) T {
    return items[rng.uintLessThan(usize, items.len)];
}

/// Pages around each copied path: [PROT_NONE][data][PROT_NONE].
const GuardedArena = struct {
    mem: []align(std.heap.page_size_min) u8,
    page: usize,

    fn init() !GuardedArena {
        const page = std.heap.pageSize();
        const mem = try std.posix.mmap(null, 3 * page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (std.c.mprotect(@ptrCast(mem.ptr), page, .{}) != 0) return error.MprotectFailed;
        if (std.c.mprotect(@ptrCast(@alignCast(mem.ptr + 2 * page)), page, .{}) != 0) return error.MprotectFailed;
        return .{ .mem = mem, .page = page };
    }

    fn deinit(self: GuardedArena) void {
        std.posix.munmap(self.mem);
    }

    /// `s` copied so that its last byte is the last readable byte.
    fn atEnd(self: GuardedArena, s: []const u8) []const u8 {
        const end = 2 * self.page;
        @memcpy(self.mem[end - s.len .. end], s);
        return self.mem[end - s.len .. end];
    }

    /// `s` copied so that its first byte is the first readable byte.
    fn atStart(self: GuardedArena, s: []const u8) []const u8 {
        @memcpy(self.mem[self.page..][0..s.len], s);
        return self.mem[self.page..][0..s.len];
    }
};

fn lastComponent(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

fn checkPattern(
    arena: std.mem.Allocator,
    guard: GuardedArena,
    rng: std.Random,
    pattern: []const u8,
    samples: []const []const u8,
    flags: ZlobFlags,
) !void {
    const gpa = testing.allocator;
    var flags_b = flags;
    flags_b.match_basename = true;
    var flags_b_nosort = flags_b;
    flags_b_nosort.nosort = true;

    // Paths: directory prefixes plus a last component that is either a
    // pattern sample or an arbitrary name.
    var paths: std.ArrayList([]const u8) = .empty;
    for (0..40) |_| {
        var buf: std.ArrayList(u8) = .empty;
        if (rng.uintLessThan(u8, 8) == 0) try buf.append(arena, '/');
        const depth = rng.uintLessThan(usize, 4);
        for (0..depth) |_| {
            try buf.appendSlice(arena, pick(rng, []const u8, &dir_names));
            try buf.append(arena, '/');
        }
        if (rng.uintLessThan(u8, 16) == 0) {
            // trailing separator: empty last component
        } else if (rng.boolean() and samples.len > 0) {
            try buf.appendSlice(arena, pick(rng, []const u8, samples));
        } else {
            try buf.appendSlice(arena, pick(rng, []const u8, &dir_names));
        }
        try paths.append(arena, buf.items);
    }

    // Oracle: the plain matcher on each last component. `.` and `..` stay
    // anchored, so for them it is the plain matcher on the whole path.
    const anchored = std.mem.eql(u8, pattern, ".") or std.mem.eql(u8, pattern, "..");
    var lasts = try arena.alloc([]const u8, paths.items.len);
    for (paths.items, 0..) |p, i| lasts[i] = if (anchored) p else lastComponent(p);
    const want = try zlob.matchPathIndices(gpa, pattern, lasts, flags);
    defer gpa.free(want);

    const got = try zlob.matchPathIndices(gpa, pattern, paths.items, flags_b);
    defer gpa.free(got);
    try expectSameIndices("matchPathIndices", pattern, flags, paths.items, want, got);

    var results = try zlob.matchPaths(gpa, pattern, paths.items, flags_b_nosort);
    defer results.deinit();
    try testing.expectEqual(want.len, results.len());

    // At-mode: the same relative paths under a base directory. (An anchored
    // pattern matches the relative path, which the oracle above is not.)
    if (!anchored) try checkAtMode(gpa, arena, pattern, paths.items, want, flags, flags_b);

    // Compiled single-path API.
    var compiled = try zlob.compilePattern(gpa, pattern, flags_b);
    defer compiled.deinit();
    var w: usize = 0;
    for (paths.items, 0..) |p, i| {
        const expected = w < want.len and want[w] == i;
        if (expected) w += 1;
        if (compiled.matches(p, flags_b) != expected) {
            std.debug.print("compiled.matches mismatch: pattern '{s}' flags {x} path '{s}' want {}\n", .{ pattern, flags.toU32(), p, expected });
            return error.TestUnexpectedResult;
        }
        // Guard pages: no read before or after the path.
        if (p.len <= guard.page) {
            try testing.expectEqual(expected, compiled.matches(guard.atEnd(p), flags_b));
            try testing.expectEqual(expected, compiled.matches(guard.atStart(p), flags_b));
            const one_end = [_][]const u8{guard.atEnd(p)};
            const at_end = try zlob.matchPathIndices(gpa, pattern, &one_end, flags_b);
            defer gpa.free(at_end);
            try testing.expectEqual(@intFromBool(expected), at_end.len);
            const one_start = [_][]const u8{guard.atStart(p)};
            const at_start = try zlob.matchPathIndices(gpa, pattern, &one_start, flags_b);
            defer gpa.free(at_start);
            try testing.expectEqual(@intFromBool(expected), at_start.len);
        }
    }
}

fn checkAtMode(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    pattern: []const u8,
    paths: []const []const u8,
    want: []const usize,
    flags: ZlobFlags,
    flags_b: ZlobFlags,
) !void {
    var at_paths = try arena.alloc([]const u8, paths.len);
    for (paths, 0..) |p, i| {
        const rel = if (p.len > 0 and p[0] == '/') p[1..] else p;
        at_paths[i] = try std.fmt.allocPrint(arena, "/base/{s}", .{rel});
    }
    const got_at = try zlob.matchPathIndicesAt(gpa, "/base", pattern, at_paths, flags_b);
    defer gpa.free(got_at);
    try expectSameIndices("matchPathIndicesAt", pattern, flags, paths, want, got_at);
}

fn expectSameIndices(api: []const u8, pattern: []const u8, flags: ZlobFlags, paths: []const []const u8, want: []const usize, got: []const usize) !void {
    if (std.mem.eql(usize, want, got)) return;
    std.debug.print("{s} mismatch: pattern '{s}' flags {x}\n", .{ api, pattern, flags.toU32() });
    for (paths, 0..) |p, i| {
        const in_want = std.mem.indexOfScalar(usize, want, i) != null;
        const in_got = std.mem.indexOfScalar(usize, got, i) != null;
        if (in_want != in_got) std.debug.print("  '{s}': want {} got {}\n", .{ p, in_want, in_got });
    }
    return error.TestUnexpectedResult;
}

test "basename fuzz: every matcher agrees with the plain matcher on the last component" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const guard = try GuardedArena.init();
    defer guard.deinit();

    const flag_sets = [_]ZlobFlags{
        .{},
        .{ .brace = true },
        .{ .extglob = true },
        .{ .noescape = true },
        .{ .period = true },
        .{ .brace = true, .extglob = true },
    };

    var prng = std.Random.DefaultPrng.init(0x5eed_ba5e);
    const rng = prng.random();

    for (flag_sets) |flags| {
        for (0..400) |_| {
            var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var pat: std.ArrayList(u8) = .empty;
            var samples: std.ArrayList([]const u8) = .empty;
            // Two candidate matches built from the same token choices.
            var s1: std.ArrayList(u8) = .empty;
            var s2: std.ArrayList(u8) = .empty;
            const n_tokens = 1 + rng.uintLessThan(usize, 4);
            for (0..n_tokens) |_| {
                const roll = rng.uintLessThan(u8, 10);
                const tok = if (flags.brace and roll == 0)
                    pick(rng, Token, &brace_tokens)
                else if (flags.extglob and roll == 1)
                    pick(rng, Token, &extglob_tokens)
                else
                    pick(rng, Token, &plain_tokens);
                try pat.appendSlice(arena, tok.pat);
                try s1.appendSlice(arena, pick(rng, []const u8, tok.samples));
                try s2.appendSlice(arena, pick(rng, []const u8, tok.samples));
            }
            try samples.append(arena, s1.items);
            try samples.append(arena, s2.items);
            try checkPattern(arena, guard, rng, pat.items, samples.items, flags);
        }
    }
}
