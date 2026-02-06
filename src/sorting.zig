///! Path sorting utilities for zlob
///!
///! Provides POSIX-compliant sorting of glob results.
///! Per POSIX, when GLOB_NOSORT is not set, pathnames shall be sorted as if
///! by a call to strcoll(). In the C/POSIX locale this is equivalent to strcmp()
///! (byte-by-byte unsigned comparison), which is what we implement here.
const std = @import("std");

fn simdStrCmp(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (min_len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const all_ones: MaskInt = @as(MaskInt, 0) -% 1;

        var i: usize = 0;
        while (i + vec_len <= min_len) : (i += vec_len) {
            const a_vec: Vec = a[i..][0..vec_len].*;
            const b_vec: Vec = b[i..][0..vec_len].*;
            const eq = a_vec == b_vec;
            const mask = @as(MaskInt, @bitCast(eq));

            if (mask != all_ones) {
                const first_diff = @ctz(~mask);
                const a_byte = a[i + first_diff];
                const b_byte = b[i + first_diff];
                if (a_byte < b_byte) return .lt;
                return .gt;
            }
        }
        for (a[i..min_len], b[i..min_len]) |ab, bb| {
            if (ab < bb) return .lt;
            if (ab > bb) return .gt;
        }
    } else {
        for (a[0..min_len], b[0..min_len]) |ab, bb| {
            if (ab < bb) return .lt;
            if (ab > bb) return .gt;
        }
    }

    return std.math.order(a.len, b.len);
}

/// Sort context for in-place pdqsort of parallel paths + lengths arrays.
/// Implements the swap/lessThan interface expected by std.mem.sortUnstableContext.
const PathSortCtx = struct {
    paths: [*][*c]u8,
    lengths: [*]usize,

    pub fn swap(ctx: PathSortCtx, a: usize, b: usize) void {
        const tmp_path = ctx.paths[a];
        ctx.paths[a] = ctx.paths[b];
        ctx.paths[b] = tmp_path;

        const tmp_len = ctx.lengths[a];
        ctx.lengths[a] = ctx.lengths[b];
        ctx.lengths[b] = tmp_len;
    }

    pub fn lessThan(ctx: PathSortCtx, a: usize, b: usize) bool {
        const slice_a = @as([*]const u8, @ptrCast(ctx.paths[a]))[0..ctx.lengths[a]];
        const slice_b = @as([*]const u8, @ptrCast(ctx.paths[b]))[0..ctx.lengths[b]];
        return simdStrCmp(slice_a, slice_b) == .lt;
    }
};

pub fn sortPaths(paths: [*][*c]u8, lengths: [*]usize, count: usize) void {
    if (count <= 1) return;
    std.mem.sortUnstableContext(0, count, PathSortCtx{
        .paths = paths,
        .lengths = lengths,
    });
}

const testing = std.testing;

test "simdStrCmp - equal strings" {
    try testing.expectEqual(std.math.Order.eq, simdStrCmp("hello", "hello"));
    try testing.expectEqual(std.math.Order.eq, simdStrCmp("", ""));
    try testing.expectEqual(std.math.Order.eq, simdStrCmp("a", "a"));
}

test "simdStrCmp - less than" {
    try testing.expectEqual(std.math.Order.lt, simdStrCmp("a", "b"));
    try testing.expectEqual(std.math.Order.lt, simdStrCmp("abc", "abd"));
    try testing.expectEqual(std.math.Order.lt, simdStrCmp("abc", "abcd"));
    try testing.expectEqual(std.math.Order.lt, simdStrCmp("", "a"));
}

test "simdStrCmp - greater than" {
    try testing.expectEqual(std.math.Order.gt, simdStrCmp("b", "a"));
    try testing.expectEqual(std.math.Order.gt, simdStrCmp("abd", "abc"));
    try testing.expectEqual(std.math.Order.gt, simdStrCmp("abcd", "abc"));
    try testing.expectEqual(std.math.Order.gt, simdStrCmp("a", ""));
}

test "simdStrCmp - long strings with SIMD" {
    const a = "this is a fairly long string that should use SIMD comparison";
    const b = "this is a fairly long string that should use SIMD comparison";
    const c = "this is a fairly long string that should use SIMD comparisoN";

    try testing.expectEqual(std.math.Order.eq, simdStrCmp(a, b));
    try testing.expectEqual(std.math.Order.gt, simdStrCmp(a, c)); // 'n' > 'N'
}

test "sortPaths - basic sorting" {
    var paths: [3][*c]u8 = undefined;
    var lengths: [3]usize = undefined;

    var str1: [10:0]u8 = "charlie\x00\x00\x00".*;
    var str2: [10:0]u8 = "alpha\x00\x00\x00\x00\x00".*;
    var str3: [10:0]u8 = "bravo\x00\x00\x00\x00\x00".*;

    paths[0] = &str1;
    paths[1] = &str2;
    paths[2] = &str3;
    lengths[0] = 7;
    lengths[1] = 5;
    lengths[2] = 5;

    sortPaths(&paths, &lengths, 3);

    const sorted0 = @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]];
    const sorted1 = @as([*]const u8, @ptrCast(paths[1]))[0..lengths[1]];
    const sorted2 = @as([*]const u8, @ptrCast(paths[2]))[0..lengths[2]];

    try testing.expectEqualStrings("alpha", sorted0);
    try testing.expectEqualStrings("bravo", sorted1);
    try testing.expectEqualStrings("charlie", sorted2);
}

test "sortPaths - empty and single element" {
    var paths: [1][*c]u8 = undefined;
    var lengths: [1]usize = undefined;

    // Empty case
    sortPaths(&paths, &lengths, 0);

    // Single element case
    var str: [5:0]u8 = "test\x00".*;
    paths[0] = &str;
    lengths[0] = 4;
    sortPaths(&paths, &lengths, 1);

    const result = @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]];
    try testing.expectEqualStrings("test", result);
}

test "sortPaths - already sorted" {
    var paths: [3][*c]u8 = undefined;
    var lengths: [3]usize = undefined;

    var str1: [6:0]u8 = "alpha\x00".*;
    var str2: [6:0]u8 = "bravo\x00".*;
    var str3: [8:0]u8 = "charlie\x00".*;

    paths[0] = &str1;
    paths[1] = &str2;
    paths[2] = &str3;
    lengths[0] = 5;
    lengths[1] = 5;
    lengths[2] = 7;

    sortPaths(&paths, &lengths, 3);

    try testing.expectEqualStrings("alpha", @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]]);
    try testing.expectEqualStrings("bravo", @as([*]const u8, @ptrCast(paths[1]))[0..lengths[1]]);
    try testing.expectEqualStrings("charlie", @as([*]const u8, @ptrCast(paths[2]))[0..lengths[2]]);
}

test "sortPaths - reverse sorted" {
    var paths: [3][*c]u8 = undefined;
    var lengths: [3]usize = undefined;

    var str1: [8:0]u8 = "charlie\x00".*;
    var str2: [6:0]u8 = "bravo\x00".*;
    var str3: [6:0]u8 = "alpha\x00".*;

    paths[0] = &str1;
    paths[1] = &str2;
    paths[2] = &str3;
    lengths[0] = 7;
    lengths[1] = 5;
    lengths[2] = 5;

    sortPaths(&paths, &lengths, 3);

    try testing.expectEqualStrings("alpha", @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]]);
    try testing.expectEqualStrings("bravo", @as([*]const u8, @ptrCast(paths[1]))[0..lengths[1]]);
    try testing.expectEqualStrings("charlie", @as([*]const u8, @ptrCast(paths[2]))[0..lengths[2]]);
}

test "sortPaths - POSIX byte ordering (paths with slashes)" {
    var paths: [4][*c]u8 = undefined;
    var lengths: [4]usize = undefined;

    var s1: [12:0]u8 = "dir/file.c\x00\x00".*;
    var s2: [14:0]u8 = "dir/subdir/a\x00\x00".*;
    var s3: [10:0]u8 = "dir/aaa.c\x00".*;
    var s4: [8:0]u8 = "abc.txt\x00".*;

    paths[0] = &s1;
    paths[1] = &s2;
    paths[2] = &s3;
    paths[3] = &s4;
    lengths[0] = 10;
    lengths[1] = 12;
    lengths[2] = 9;
    lengths[3] = 7;

    sortPaths(&paths, &lengths, 4);

    try testing.expectEqualStrings("abc.txt", @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]]);
    try testing.expectEqualStrings("dir/aaa.c", @as([*]const u8, @ptrCast(paths[1]))[0..lengths[1]]);
    try testing.expectEqualStrings("dir/file.c", @as([*]const u8, @ptrCast(paths[2]))[0..lengths[2]]);
    try testing.expectEqualStrings("dir/subdir/a", @as([*]const u8, @ptrCast(paths[3]))[0..lengths[3]]);
}

test "sortPaths - duplicate paths" {
    var paths: [4][*c]u8 = undefined;
    var lengths: [4]usize = undefined;

    var s1: [6:0]u8 = "bravo\x00".*;
    var s2: [6:0]u8 = "alpha\x00".*;
    var s3: [6:0]u8 = "bravo\x00".*;
    var s4: [6:0]u8 = "alpha\x00".*;

    paths[0] = &s1;
    paths[1] = &s2;
    paths[2] = &s3;
    paths[3] = &s4;
    lengths[0] = 5;
    lengths[1] = 5;
    lengths[2] = 5;
    lengths[3] = 5;

    sortPaths(&paths, &lengths, 4);

    try testing.expectEqualStrings("alpha", @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]]);
    try testing.expectEqualStrings("alpha", @as([*]const u8, @ptrCast(paths[1]))[0..lengths[1]]);
    try testing.expectEqualStrings("bravo", @as([*]const u8, @ptrCast(paths[2]))[0..lengths[2]]);
    try testing.expectEqualStrings("bravo", @as([*]const u8, @ptrCast(paths[3]))[0..lengths[3]]);
}
