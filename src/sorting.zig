///! Path sorting utilities for zlob
///!
///! This module provides optimized sorting functions for glob results.
///! Key optimizations:
///! - SIMD-accelerated string comparison
///! - Pre-computed path lengths to avoid O(n) strlen() per comparison
///! - Cache-friendly indirect sorting with cycle-based rearrangement
const std = @import("std");

/// SIMD-optimized string comparison
/// Uses CPU-optimal vector size for comparing strings in chunks
/// Falls back to byte-by-byte for short strings
pub fn simdStrCmp(a: []const u8, b: []const u8) std.math.Order {
    const min_len = @min(a.len, b.len);

    // Use CPU-optimal vector size
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (min_len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const all_ones: MaskInt = @as(MaskInt, 0) -% 1; // All bits set

        var i: usize = 0;
        while (i + vec_len <= min_len) : (i += vec_len) {
            const a_vec: Vec = a[i..][0..vec_len].*;
            const b_vec: Vec = b[i..][0..vec_len].*;
            const eq = a_vec == b_vec;
            const mask = @as(MaskInt, @bitCast(eq));

            if (mask != all_ones) {
                // Found difference, find first differing byte
                const first_diff = @ctz(~mask);
                const a_byte = a[i + first_diff];
                const b_byte = b[i + first_diff];
                if (a_byte < b_byte) return .lt;
                if (a_byte > b_byte) return .gt;
            }
        }
        // Compare remainder byte-by-byte
        for (a[i..min_len], b[i..min_len]) |a_byte, b_byte| {
            if (a_byte < b_byte) return .lt;
            if (a_byte > b_byte) return .gt;
        }
    } else {
        // Fallback for short strings
        for (a[0..min_len], b[0..min_len]) |a_byte, b_byte| {
            if (a_byte < b_byte) return .lt;
            if (a_byte > b_byte) return .gt;
        }
    }

    // All bytes equal up to min_len, compare lengths
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return .eq;
}

/// Sort context for sorting paths with pre-computed lengths
/// This avoids the O(n) strlen() call per comparison that mem.sliceTo would require
pub const PathSortContext = struct {
    paths: [*][*c]u8,
    lengths: [*]usize,

    /// Compare two paths using their pre-computed lengths
    /// This is significantly faster than mem.sliceTo which scans for null terminators
    pub fn lessThan(ctx: PathSortContext, a_idx: usize, b_idx: usize) bool {
        const a_ptr = ctx.paths[a_idx];
        const b_ptr = ctx.paths[b_idx];
        const a_len = ctx.lengths[a_idx];
        const b_len = ctx.lengths[b_idx];

        // Create slices using known lengths - O(1) instead of O(n) for mem.sliceTo
        const slice_a = @as([*]const u8, @ptrCast(a_ptr))[0..a_len];
        const slice_b = @as([*]const u8, @ptrCast(b_ptr))[0..b_len];

        return simdStrCmp(slice_a, slice_b) == .lt;
    }
};

/// Maximum number of paths that can be sorted with stack-allocated buffers
pub const MAX_STACK_SORT_COUNT = 4096;

/// Sort paths in-place using pre-computed lengths from zlo_pathlen
/// This is much faster than C's qsort with mem.sliceTo because:
/// 1. We use known lengths instead of scanning for null terminators
/// 2. Zig's sort is cache-friendly and doesn't require function pointer indirection
///
/// Note: This function uses stack-allocated buffers and is limited to MAX_STACK_SORT_COUNT paths.
/// For larger counts, use sortPathsWithLengthsAlloc which heap-allocates the buffers.
pub fn sortPathsWithLengths(paths: [*][*c]u8, lengths: [*]usize, count: usize) void {
    if (count <= 1) return;
    if (count > MAX_STACK_SORT_COUNT) return; // Safety check

    // Create index array for indirect sorting
    // We sort indices and then rearrange paths/lengths accordingly
    var indices_buf: [MAX_STACK_SORT_COUNT]usize = undefined;
    const indices = indices_buf[0..count];
    for (indices, 0..) |*idx, i| {
        idx.* = i;
    }

    const ctx = PathSortContext{ .paths = paths, .lengths = lengths };
    std.mem.sort(usize, indices, ctx, PathSortContext.lessThan);

    // Rearrange paths and lengths according to sorted indices using cycle sort
    // This is O(n) with O(1) extra space for the swap temps
    var visited_buf: [MAX_STACK_SORT_COUNT]bool = undefined;
    const visited = visited_buf[0..count];
    @memset(visited, false);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (visited[i] or indices[i] == i) {
            visited[i] = true;
            continue;
        }

        // Follow the cycle
        var j = i;
        const temp_path = paths[i];
        const temp_len = lengths[i];

        while (indices[j] != i) {
            const next = indices[j];
            paths[j] = paths[next];
            lengths[j] = lengths[next];
            visited[j] = true;
            j = next;
        }

        paths[j] = temp_path;
        lengths[j] = temp_len;
        visited[j] = true;
    }
}

/// Sort paths in-place using heap-allocated buffers for large counts
/// Use this when count > MAX_STACK_SORT_COUNT
pub fn sortPathsWithLengthsAlloc(allocator: std.mem.Allocator, paths: [*][*c]u8, lengths: [*]usize, count: usize) !void {
    if (count <= 1) return;

    // For small counts, use stack-allocated version
    if (count <= MAX_STACK_SORT_COUNT) {
        sortPathsWithLengths(paths, lengths, count);
        return;
    }

    // Heap-allocate for large counts
    const indices = try allocator.alloc(usize, count);
    defer allocator.free(indices);

    for (indices, 0..) |*idx, i| {
        idx.* = i;
    }

    const ctx = PathSortContext{ .paths = paths, .lengths = lengths };
    std.mem.sort(usize, indices, ctx, PathSortContext.lessThan);

    // Heap-allocate visited array
    const visited = try allocator.alloc(bool, count);
    defer allocator.free(visited);
    @memset(visited, false);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (visited[i] or indices[i] == i) {
            visited[i] = true;
            continue;
        }

        var j = i;
        const temp_path = paths[i];
        const temp_len = lengths[i];

        while (indices[j] != i) {
            const next = indices[j];
            paths[j] = paths[next];
            lengths[j] = lengths[next];
            visited[j] = true;
            j = next;
        }

        paths[j] = temp_path;
        lengths[j] = temp_len;
        visited[j] = true;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "simdStrCmp - equal strings" {
    try std.testing.expectEqual(std.math.Order.eq, simdStrCmp("hello", "hello"));
    try std.testing.expectEqual(std.math.Order.eq, simdStrCmp("", ""));
    try std.testing.expectEqual(std.math.Order.eq, simdStrCmp("a", "a"));
}

test "simdStrCmp - less than" {
    try std.testing.expectEqual(std.math.Order.lt, simdStrCmp("a", "b"));
    try std.testing.expectEqual(std.math.Order.lt, simdStrCmp("abc", "abd"));
    try std.testing.expectEqual(std.math.Order.lt, simdStrCmp("abc", "abcd"));
    try std.testing.expectEqual(std.math.Order.lt, simdStrCmp("", "a"));
}

test "simdStrCmp - greater than" {
    try std.testing.expectEqual(std.math.Order.gt, simdStrCmp("b", "a"));
    try std.testing.expectEqual(std.math.Order.gt, simdStrCmp("abd", "abc"));
    try std.testing.expectEqual(std.math.Order.gt, simdStrCmp("abcd", "abc"));
    try std.testing.expectEqual(std.math.Order.gt, simdStrCmp("a", ""));
}

test "simdStrCmp - long strings with SIMD" {
    const a = "this is a fairly long string that should use SIMD comparison";
    const b = "this is a fairly long string that should use SIMD comparison";
    const c = "this is a fairly long string that should use SIMD comparisoN"; // different at end

    try std.testing.expectEqual(std.math.Order.eq, simdStrCmp(a, b));
    try std.testing.expectEqual(std.math.Order.gt, simdStrCmp(a, c)); // 'n' > 'N'
}

test "sortPathsWithLengths - basic sorting" {
    var paths: [3][*c]u8 = undefined;
    var lengths: [3]usize = undefined;

    // Create test strings
    var str1: [10:0]u8 = "charlie\x00\x00\x00".*;
    var str2: [10:0]u8 = "alpha\x00\x00\x00\x00\x00".*;
    var str3: [10:0]u8 = "bravo\x00\x00\x00\x00\x00".*;

    paths[0] = &str1;
    paths[1] = &str2;
    paths[2] = &str3;
    lengths[0] = 7; // "charlie"
    lengths[1] = 5; // "alpha"
    lengths[2] = 5; // "bravo"

    sortPathsWithLengths(&paths, &lengths, 3);

    // Should be sorted: alpha, bravo, charlie
    const sorted0 = @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]];
    const sorted1 = @as([*]const u8, @ptrCast(paths[1]))[0..lengths[1]];
    const sorted2 = @as([*]const u8, @ptrCast(paths[2]))[0..lengths[2]];

    try std.testing.expectEqualStrings("alpha", sorted0);
    try std.testing.expectEqualStrings("bravo", sorted1);
    try std.testing.expectEqualStrings("charlie", sorted2);
}

test "sortPathsWithLengths - empty and single element" {
    var paths: [1][*c]u8 = undefined;
    var lengths: [1]usize = undefined;

    // Empty case
    sortPathsWithLengths(&paths, &lengths, 0);

    // Single element case
    var str: [5:0]u8 = "test\x00".*;
    paths[0] = &str;
    lengths[0] = 4;
    sortPathsWithLengths(&paths, &lengths, 1);

    const result = @as([*]const u8, @ptrCast(paths[0]))[0..lengths[0]];
    try std.testing.expectEqualStrings("test", result);
}

test "PathSortContext.lessThan" {
    var paths: [2][*c]u8 = undefined;
    var lengths: [2]usize = undefined;

    var str1: [5:0]u8 = "beta\x00".*;
    var str2: [6:0]u8 = "alpha\x00".*;

    paths[0] = &str1;
    paths[1] = &str2;
    lengths[0] = 4;
    lengths[1] = 5;

    const ctx = PathSortContext{ .paths = &paths, .lengths = &lengths };

    // "beta" > "alpha", so lessThan(0, 1) should be false
    try std.testing.expect(!ctx.lessThan(0, 1));
    // "alpha" < "beta", so lessThan(1, 0) should be true
    try std.testing.expect(ctx.lessThan(1, 0));
}
