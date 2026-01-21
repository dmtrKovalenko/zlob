//! Benchmark comparing SIMD vs non-SIMD character search

const std = @import("std");
const zlob = @import("zlob");

const ITERATIONS = 1_000_000;

fn naiveFind(haystack: []const u8, needle: u8) ?usize {
    for (haystack, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}

pub fn main() !void {
    std.debug.print("=== SIMD vs Naive Character Search Benchmark ===\n\n", .{});

    const test_cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        needle: u8,
    }{
        .{
            .name = "Short string (8 bytes)",
            .haystack = "abcdefgh",
            .needle = 'h',
        },
        .{
            .name = "Medium string (32 bytes)",
            .haystack = "the_quick_brown_fox_jumps_over",
            .needle = 'o',
        },
        .{
            .name = "Long string (128 bytes)",
            .haystack = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
            .needle = 'z',
        },
        .{
            .name = "Very long string (512 bytes)",
            .haystack = "a" ** 511 ++ "z",
            .needle = 'z',
        },
    };

    for (test_cases) |tc| {
        std.debug.print("{s}:\n", .{tc.name});
        std.debug.print("  Haystack length: {} bytes\n", .{tc.haystack.len});

        var naive_elapsed: f64 = undefined;
        var simd_elapsed: f64 = undefined;

        // Benchmark naive implementation
        {
            const start = std.time.nanoTimestamp();
            var result: ?usize = null;
            var i: usize = 0;
            while (i < ITERATIONS) : (i += 1) {
                result = naiveFind(tc.haystack, tc.needle);
                std.mem.doNotOptimizeAway(&result); // Prevent optimization
            }
            const end = std.time.nanoTimestamp();
            naive_elapsed = @as(f64, @floatFromInt(end - start)) / @as(f64, ITERATIONS);

            std.debug.print("  Native:  {d:.2}ns per search", .{naive_elapsed});
            if (result) |pos| {
                std.debug.print(" (found at {})\n", .{pos});
            } else {
                std.debug.print(" (not found)\n", .{});
            }
        }

        // Benchmark SIMD implementation
        {
            const start = std.time.nanoTimestamp();
            var result: ?usize = null;
            var i: usize = 0;
            while (i < ITERATIONS) : (i += 1) {
                result = zlob.simdFindChar(tc.haystack, tc.needle);
                std.mem.doNotOptimizeAway(&result); // Prevent optimization
            }
            const end = std.time.nanoTimestamp();
            simd_elapsed = @as(f64, @floatFromInt(end - start)) / @as(f64, ITERATIONS);

            std.debug.print("  SIMD:   {d:.2}ns per search", .{simd_elapsed});
            if (result) |pos| {
                std.debug.print(" (found at {})\n", .{pos});
            } else {
                std.debug.print(" (not found)\n", .{});
            }
        }

        // Calculate speedup from the SAME measurements
        const speedup = naive_elapsed / simd_elapsed;
        std.debug.print("  Speedup: {d:.2}x\n\n", .{speedup});
    }

    std.debug.print("=== Benchmark Notes ===\n", .{});
    std.debug.print("- SIMD uses 16-byte vectors for parallel comparison\n", .{});
    std.debug.print("- Speedup is most significant for longer strings\n", .{});
    std.debug.print("- Short strings (<16 bytes) may be slower due to overhead\n", .{});
    std.debug.print("- Real-world glob benefits from SIMD during wildcard expansion\n", .{});
}
