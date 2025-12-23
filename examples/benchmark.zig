//! Benchmark comparing SIMD vs non-SIMD character search

const std = @import("std");
const simdglob = @import("simdglob");

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

        // Benchmark naive implementation
        {
            const start = std.time.nanoTimestamp();
            var result: ?usize = null;
            var i: usize = 0;
            while (i < ITERATIONS) : (i += 1) {
                result = naiveFind(tc.haystack, tc.needle);
            }
            const end = std.time.nanoTimestamp();
            const elapsed = @as(f64, @floatFromInt(end - start)) / @as(f64, ITERATIONS);

            std.debug.print("  Naive:  {d:.2}ns per search", .{elapsed});
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
                result = simdglob.simdFindChar(tc.haystack, tc.needle);
            }
            const end = std.time.nanoTimestamp();
            const elapsed = @as(f64, @floatFromInt(end - start)) / @as(f64, ITERATIONS);

            std.debug.print("  SIMD:   {d:.2}ns per search", .{elapsed});
            if (result) |pos| {
                std.debug.print(" (found at {})\n", .{pos});
            } else {
                std.debug.print(" (not found)\n", .{});
            }
        }

        // Calculate speedup
        {
            var naive_sum: i128 = 0;
            var simd_sum: i128 = 0;

            // Warmup and accurate measurement
            var iter: usize = 0;
            while (iter < 100) : (iter += 1) {
                const naive_start = std.time.nanoTimestamp();
                _ = naiveFind(tc.haystack, tc.needle);
                const naive_end = std.time.nanoTimestamp();
                naive_sum += naive_end - naive_start;

                const simd_start = std.time.nanoTimestamp();
                _ = simdglob.simdFindChar(tc.haystack, tc.needle);
                const simd_end = std.time.nanoTimestamp();
                simd_sum += simd_end - simd_start;
            }

            const naive_avg = @as(f64, @floatFromInt(naive_sum)) / 100.0;
            const simd_avg = @as(f64, @floatFromInt(simd_sum)) / 100.0;
            const speedup = naive_avg / simd_avg;

            std.debug.print("  Speedup: {d:.2}x\n\n", .{speedup});
        }
    }

    std.debug.print("=== Benchmark Notes ===\n", .{});
    std.debug.print("- SIMD uses 16-byte vectors for parallel comparison\n", .{});
    std.debug.print("- Speedup is most significant for longer strings\n", .{});
    std.debug.print("- Short strings (<16 bytes) may be slower due to overhead\n", .{});
    std.debug.print("- Real-world glob benefits from SIMD during wildcard expansion\n", .{});
}
