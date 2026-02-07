const std = @import("std");
const zlob = @import("zlob");
const suffix_match = zlob.suffix_match;
const PatternContext = zlob.PatternContext;

/// Benchmark comparing different multi-suffix matching approaches:
/// 1. Original loop-based approach (iterate each PatternContext)
/// 2. Unified masked u32 approach (single SIMD pass)
const ITERATIONS = 1_000_000;
const WARMUP_ITERATIONS = 10_000;

// Test data: filenames to match against
const test_filenames = [_][]const u8{
    "main.c",
    "main.h",
    "parser.rs",
    "lexer.zig",
    "config.json",
    "styles.css",
    "index.html",
    "app.tsx",
    "utils.ts",
    "helpers.js",
    "readme.md",
    "Makefile",
    "build.gradle",
    "package.json",
    "test_runner.py",
    "database.sql",
    "shader.glsl",
    "model.obj",
    "texture.png",
    "audio.wav",
};

// Test patterns (suffixes)
const test_patterns_mixed = [_][]const u8{ "*.c", "*.h", "*.rs", "*.zig" }; // Mixed lengths: 2, 2, 3, 4 bytes
const test_patterns_same = [_][]const u8{ "*.zig", "*.txt", "*.css", "*.sql" }; // Same length: 4 bytes each
const test_patterns_many = [_][]const u8{
    "*.c",
    "*.h",
    "*.rs",
    "*.js",
    "*.ts",
    "*.py",
    "*.go",
    "*.md",
    "*.zig",
    "*.css",
    "*.sql",
    "*.txt",
};

fn createContexts(comptime patterns: []const []const u8) [patterns.len]PatternContext {
    var contexts: [patterns.len]PatternContext = undefined;
    inline for (patterns, 0..) |p, i| {
        contexts[i] = PatternContext.init(p);
    }
    return contexts;
}

/// Original approach: loop over each context
fn matchOriginal(name: []const u8, contexts: []const PatternContext) bool {
    for (contexts) |*ctx| {
        if (ctx.single_suffix_matcher) |*batched| {
            if (batched.matchSuffix(name)) return true;
        }
    }
    return false;
}

/// New unified approach
fn matchUnified(name: []const u8, matcher: *const suffix_match.UnifiedMultiSuffix) bool {
    return matcher.matchAny(name);
}

fn runBenchmark(
    comptime name: []const u8,
    comptime patterns: []const []const u8,
) void {
    const contexts = createContexts(patterns);
    const unified = suffix_match.UnifiedMultiSuffix.init(&contexts);

    var matches_original: usize = 0;
    var matches_unified: usize = 0;

    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        for (test_filenames) |filename| {
            if (matchOriginal(filename, &contexts)) matches_original += 1;
            if (matchUnified(filename, &unified)) matches_unified += 1;
        }
    }
    matches_original = 0;
    matches_unified = 0;

    // Benchmark original approach
    const start1 = std.time.nanoTimestamp();
    for (0..ITERATIONS) |_| {
        for (test_filenames) |filename| {
            if (matchOriginal(filename, &contexts)) matches_original += 1;
        }
    }
    const end1 = std.time.nanoTimestamp();
    const original_ns: u64 = @intCast(end1 - start1);

    // Benchmark unified approach
    const start2 = std.time.nanoTimestamp();
    for (0..ITERATIONS) |_| {
        for (test_filenames) |filename| {
            if (matchUnified(filename, &unified)) matches_unified += 1;
        }
    }
    const end2 = std.time.nanoTimestamp();
    const unified_ns: u64 = @intCast(end2 - start2);

    const total_ops = ITERATIONS * test_filenames.len;
    const original_ns_per_op = @as(f64, @floatFromInt(original_ns)) / @as(f64, @floatFromInt(total_ops));
    const unified_ns_per_op = @as(f64, @floatFromInt(unified_ns)) / @as(f64, @floatFromInt(total_ops));
    const speedup = original_ns_per_op / unified_ns_per_op;

    std.debug.print("\n{s} ({d} patterns):\n", .{ name, patterns.len });
    std.debug.print("  Original: {d:.2} ns/op ({d} matches)\n", .{ original_ns_per_op, matches_original });
    std.debug.print("  Unified:  {d:.2} ns/op ({d} matches)\n", .{ unified_ns_per_op, matches_unified });
    std.debug.print("  Speedup:  {d:.2}x\n", .{speedup});

    // Verify correctness
    if (matches_original != matches_unified) {
        std.debug.print("  WARNING: Match count mismatch!\n", .{});
    }
}

pub fn main() !void {
    std.debug.print("Multi-suffix matching benchmark\n", .{});
    std.debug.print("================================\n", .{});
    std.debug.print("Testing {d} filenames, {d} iterations\n", .{ test_filenames.len, ITERATIONS });

    runBenchmark("Mixed lengths (2,2,3,4 bytes)", &test_patterns_mixed);
    runBenchmark("Same length (4 bytes each)", &test_patterns_same);
    runBenchmark("Many patterns (12 suffixes)", &test_patterns_many);

    std.debug.print("\nDone.\n", .{});
}
