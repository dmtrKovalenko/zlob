//! Example usage of the simdglob library

const std = @import("std");
const simdglob = @import("simdglob");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== SIMD Glob Examples ===\n\n", .{});

    // Example 1: Simple wildcard matching
    std.debug.print("Example 1: Find all .zig files in src/\n", .{});
    {
        var result = simdglob.match(allocator, "src/*.zig", 0) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            return;
        };
        defer result.deinit();

        std.debug.print("Found {} files:\n", .{result.match_count});
        for (result.paths) |path| {
            std.debug.print("  - {s}\n", .{path});
        }
    }

    std.debug.print("\n", .{});

    // Example 2: Using character classes
    std.debug.print("Example 2: Find files starting with specific letters\n", .{});
    {
        var result = simdglob.match(allocator, "src/[mgr]*.zig", 0) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            return;
        };
        defer result.deinit();

        std.debug.print("Found {} files:\n", .{result.match_count});
        for (result.paths) |path| {
            std.debug.print("  - {s}\n", .{path});
        }
    }

    std.debug.print("\n", .{});

    // Example 3: SIMD character search demonstration
    std.debug.print("Example 3: SIMD character search\n", .{});
    {
        const haystack = "The quick brown fox jumps over the lazy dog";
        const needle = 'q';

        const start = std.time.nanoTimestamp();
        const result = simdglob.simdFindChar(haystack, needle);
        const end = std.time.nanoTimestamp();

        if (result) |pos| {
            std.debug.print("Found '{c}' at position {}\n", .{ needle, pos });
            std.debug.print("Time: {}ns\n", .{end - start});
        } else {
            std.debug.print("Character not found\n", .{});
        }
    }

    std.debug.print("\n", .{});

    // Example 4: Mark directories with trailing slash
    std.debug.print("Example 4: List everything in current directory (with markers)\n", .{});
    {
        var result = simdglob.match(allocator, "*", simdglob.GLOB_MARK) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            return;
        };
        defer result.deinit();

        std.debug.print("Found {} items:\n", .{result.match_count});
        for (result.paths) |path| {
            std.debug.print("  - {s}\n", .{path});
        }
    }

    std.debug.print("\n=== All examples complete ===\n", .{});
}
