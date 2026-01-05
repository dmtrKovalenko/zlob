const std = @import("std");
const glob_impl = @import("c_lib");

const Timer = std.time.Timer;

// Real libc glob
extern "c" fn glob(pattern: [*:0]const u8, flags: c_int, errfunc: ?*const anyopaque, pglob: *glob_impl.glob_t) c_int;
extern "c" fn globfree(pglob: *glob_impl.glob_t) void;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    std.debug.print("=== C-Style Glob vs libc glob() Benchmark ===\n\n", .{});

    const test_cases = [_]struct {
        pattern: [:0]const u8,
        iterations: usize,
    }{
        .{ .pattern = "*.zig", .iterations = 1000 },
        .{ .pattern = "src/*.zig", .iterations = 1000 },
        .{ .pattern = "*/*.zig", .iterations = 500 },
        .{ .pattern = "src/[gmr]*.zig", .iterations = 1000 },
        .{ .pattern = "src/????.zig", .iterations = 1000 },
    };

    for (test_cases) |tc| {
        std.debug.print("Pattern: {s}\n", .{tc.pattern});
        std.debug.print("Iterations: {d}\n", .{tc.iterations});

        // Benchmark libc glob
        {
            var timer = try Timer.start();
            const start = timer.lap();

            var i: usize = 0;
            while (i < tc.iterations) : (i += 1) {
                var pglob: glob_impl.glob_t = undefined;
                const result = glob(tc.pattern.ptr, 0, null, &pglob);
                if (result == 0) {
                    globfree(&pglob);
                }
            }

            const elapsed = timer.read() - start;
            const avg_ns = elapsed / tc.iterations;
            const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;
            std.debug.print("  libc glob: {d:.2}μs per call\n", .{avg_us});
        }

        // Benchmark our C-style glob
        {
            var timer = try Timer.start();
            const start = timer.lap();

            var i: usize = 0;
            while (i < tc.iterations) : (i += 1) {
                var pglob: glob_impl.glob_t = undefined;
                const result = glob_impl.glob_c(allocator, tc.pattern.ptr, 0, null, &pglob);
                if (result == 0) {
                    glob_impl.globfreeZ(allocator, &pglob);
                }
            }

            const elapsed = timer.read() - start;
            const avg_ns = elapsed / tc.iterations;
            const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;
            std.debug.print("  our glob:  {d:.2}μs per call\n", .{avg_us});
        }

        std.debug.print("\n", .{});
    }

    // Correctness check
    std.debug.print("=== Correctness Check ===\n\n", .{});

    const verify_patterns = [_][:0]const u8{
        "src/*.zig",
        "*.md",
        "examples/*.zig",
    };

    for (verify_patterns) |pattern| {
        var libc_pglob: glob_impl.glob_t = undefined;
        var our_pglob: glob_impl.glob_t = undefined;

        const libc_result = glob(pattern.ptr, 0, null, &libc_pglob);
        const our_result = glob_impl.glob_c(allocator, pattern.ptr, 0, null, &our_pglob);

        const libc_count = if (libc_result == 0) libc_pglob.gl_pathc else 0;
        const our_count = if (our_result == 0) our_pglob.gl_pathc else 0;

        if (libc_result == 0) globfree(&libc_pglob);
        if (our_result == 0) glob_impl.globfreeZ(allocator, &our_pglob);

        const match = if (libc_count == our_count) "✓" else "✗";
        std.debug.print("{s} Pattern '{s}': libc={d}, ours={d}\n", .{ match, pattern, libc_count, our_count });
    }

    std.debug.print("\nBenchmark completed!\n", .{});
}
