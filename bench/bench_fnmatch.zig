//! Benchmark for fnmatch pattern matching
//!
//! Tests throughput for:
//! - Core pattern matching (*.ext, prefix*, wildcards)
//! - Bracket expressions (simple, ranges, POSIX classes)
//! - Extended glob patterns (@(), ?(), *(), +(), !())
//! - PatternContext template fast paths

const std = @import("std");
const zlob = @import("zlob");
const fnmatch = zlob.fnmatch;
const PatternContext = fnmatch.PatternContext;
const ZlobFlags = fnmatch.ZlobFlags;

const ITERATIONS = 1_000_000;
const WARMUP = 100;

fn benchmark(comptime label: []const u8, comptime func: anytype) void {
    // Warmup
    for (0..WARMUP) |_| {
        std.mem.doNotOptimizeAway(func());
    }

    const start = std.time.nanoTimestamp();
    for (0..ITERATIONS) |_| {
        std.mem.doNotOptimizeAway(func());
    }
    const end = std.time.nanoTimestamp();

    const elapsed_ns: f64 = @floatFromInt(end - start);
    const per_op = elapsed_ns / @as(f64, ITERATIONS);
    const ops_per_sec = @as(f64, ITERATIONS) / (elapsed_ns / 1_000_000_000.0);
    std.debug.print("  {s:<45} {d:>8.1}ns/op  {d:>10.0} ops/s\n", .{ label, per_op, ops_per_sec });
}

pub fn main() !void {
    std.debug.print("=== fnmatch Benchmark ===\n\n", .{});

    // ---------------------------------------------------------------
    std.debug.print("--- Core patterns (matchCore) ---\n", .{});

    benchmark("*.txt vs file.txt (match)", struct {
        fn f() bool {
            return fnmatch.match("*.txt", "file.txt", .{});
        }
    }.f);

    benchmark("*.txt vs file.log (no match)", struct {
        fn f() bool {
            return fnmatch.match("*.txt", "file.log", .{});
        }
    }.f);

    benchmark("test_*.zig vs test_foo.zig", struct {
        fn f() bool {
            return fnmatch.match("test_*.zig", "test_foo.zig", .{});
        }
    }.f);

    benchmark("a*b*c*d vs aXXXbYYYcZZZd", struct {
        fn f() bool {
            return fnmatch.match("a*b*c*d", "aXXXbYYYcZZZd", .{});
        }
    }.f);

    benchmark("??? vs abc", struct {
        fn f() bool {
            return fnmatch.match("???", "abc", .{});
        }
    }.f);

    benchmark("exact_match vs exact_match (literal)", struct {
        fn f() bool {
            return fnmatch.match("exact_match.txt", "exact_match.txt", .{});
        }
    }.f);

    // ---------------------------------------------------------------
    std.debug.print("\n--- Bracket expressions ---\n", .{});

    benchmark("[abc] vs a", struct {
        fn f() bool {
            return fnmatch.match("[abc]", "a", .{});
        }
    }.f);

    benchmark("[a-z] vs m", struct {
        fn f() bool {
            return fnmatch.match("[a-z]", "m", .{});
        }
    }.f);

    benchmark("[a-zA-Z0-9] vs X", struct {
        fn f() bool {
            return fnmatch.match("[a-zA-Z0-9]", "X", .{});
        }
    }.f);

    benchmark("[!0-9] vs a (negated)", struct {
        fn f() bool {
            return fnmatch.match("[!0-9]", "a", .{});
        }
    }.f);

    benchmark("file[[:digit:]].txt vs file5.txt (POSIX)", struct {
        fn f() bool {
            return fnmatch.match("file[[:digit:]].txt", "file5.txt", .{});
        }
    }.f);

    benchmark("[[:alpha:]][[:digit:]] vs a5 (POSIX combo)", struct {
        fn f() bool {
            return fnmatch.match("[[:alpha:]][[:digit:]]", "a5", .{});
        }
    }.f);

    // ---------------------------------------------------------------
    std.debug.print("\n--- Extglob patterns ---\n", .{});

    benchmark("@(foo|bar) vs foo", struct {
        fn f() bool {
            return fnmatch.match("@(foo|bar)", "foo", .{ .extglob = true });
        }
    }.f);

    benchmark("*.@(js|ts) vs app.ts", struct {
        fn f() bool {
            return fnmatch.match("*.@(js|ts)", "app.ts", .{ .extglob = true });
        }
    }.f);

    benchmark("*.!(js) vs file.txt", struct {
        fn f() bool {
            return fnmatch.match("*.!(js)", "file.txt", .{ .extglob = true });
        }
    }.f);

    benchmark("a+(X)b vs aXXXb", struct {
        fn f() bool {
            return fnmatch.match("a+(X)b", "aXXXb", .{ .extglob = true });
        }
    }.f);

    benchmark("a*(X)b vs ab (zero match)", struct {
        fn f() bool {
            return fnmatch.match("a*(X)b", "ab", .{ .extglob = true });
        }
    }.f);

    benchmark("?(prefix_)main.c vs main.c", struct {
        fn f() bool {
            return fnmatch.match("?(prefix_)main.c", "main.c", .{ .extglob = true });
        }
    }.f);

    benchmark("@(src|lib)/*.@(c|h) vs src/main.c", struct {
        fn f() bool {
            return fnmatch.match("@(src|lib)/*.@(c|h)", "src/main.c", .{ .extglob = true });
        }
    }.f);

    // ---------------------------------------------------------------
    std.debug.print("\n--- PatternContext fast paths ---\n", .{});

    benchmark("PatternCtx *.zig vs main.zig (template)", struct {
        const ctx = PatternContext.init("*.zig");
        fn f() bool {
            return fnmatch.matchWithContext(&ctx, "main.zig", .{});
        }
    }.f);

    benchmark("PatternCtx test_* vs test_foo (template)", struct {
        const ctx = PatternContext.init("test_*");
        fn f() bool {
            return fnmatch.matchWithContext(&ctx, "test_foo", .{});
        }
    }.f);

    benchmark("PatternCtx exact.txt vs exact.txt (literal)", struct {
        const ctx = PatternContext.init("exact.txt");
        fn f() bool {
            return fnmatch.matchWithContext(&ctx, "exact.txt", .{});
        }
    }.f);

    benchmark("PatternCtx file[0-9].txt vs file5.txt", struct {
        const ctx = PatternContext.init("file[0-9].txt");
        fn f() bool {
            return fnmatch.matchWithContext(&ctx, "file5.txt", .{});
        }
    }.f);

    // ---------------------------------------------------------------
    std.debug.print("\n--- SIMD character search ---\n", .{});

    benchmark("simdFindChar 8 bytes (needle at end)", struct {
        fn f() ?usize {
            return fnmatch.simdFindChar("abcdefgh", 'h');
        }
    }.f);

    benchmark("simdFindChar 44 bytes (needle='o')", struct {
        fn f() ?usize {
            return fnmatch.simdFindChar("the_quick_brown_fox_jumps_over_the_lazy_dog", 'o');
        }
    }.f);

    benchmark("simdFindChar 512 bytes (needle at end)", struct {
        fn f() ?usize {
            return fnmatch.simdFindChar("a" ** 511 ++ "z", 'z');
        }
    }.f);

    std.debug.print("\n=== Done ===\n", .{});
}
