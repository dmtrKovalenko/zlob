const std = @import("std");
const simdglob = @import("simdglob");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example 1: Filter files from a database/API result
    std.debug.print("Example 1: Simple wildcard matching\n", .{});
    std.debug.print("=====================================\n", .{});

    const database_files = [_][]const u8{
        "user_data.json",
        "config.yaml",
        "logs.txt",
        "backup.json",
        "settings.json",
        "readme.md",
    };

    // Reusable Glob instance for better performance
    var g = simdglob.Glob.init(allocator, 0);
    defer g.deinit();

    var result1 = try simdglob.matchFiles(allocator, "*.json", &database_files, 0, &g);
    defer result1.deinit();

    std.debug.print("Pattern: *.json\n", .{});
    std.debug.print("Matches: {d}\n", .{result1.match_count});
    for (result1.paths) |path| {
        std.debug.print("  - {s}\n", .{path});
    }
    std.debug.print("\n", .{});

    // Example 2: Filter by character class
    std.debug.print("Example 2: Character class filtering\n", .{});
    std.debug.print("=====================================\n", .{});

    const api_files = [_][]const u8{
        "test1.log",
        "test2.log",
        "test3.log",
        "testa.log",
        "testb.log",
        "prod1.log",
    };

    var result2 = try simdglob.matchFiles(allocator, "test[0-9].log", &api_files, 0, &g);
    defer result2.deinit();

    std.debug.print("Pattern: test[0-9].log\n", .{});
    std.debug.print("Matches: {d}\n", .{result2.match_count});
    for (result2.paths) |path| {
        std.debug.print("  - {s}\n", .{path});
    }
    std.debug.print("\n", .{});

    // Example 3: Path-based filtering
    std.debug.print("Example 3: Path-based filtering\n", .{});
    std.debug.print("================================\n", .{});

    const cached_paths = [_][]const u8{
        "src/main.zig",
        "src/test.zig",
        "src/lib.zig",
        "lib/helper.c",
        "lib/util.c",
        "test/test_main.zig",
    };

    var result3 = try simdglob.matchFiles(allocator, "src/*.zig", &cached_paths, 0, &g);
    defer result3.deinit();

    std.debug.print("Pattern: src/*.zig\n", .{});
    std.debug.print("Matches: {d}\n", .{result3.match_count});
    for (result3.paths) |path| {
        std.debug.print("  - {s}\n", .{path});
    }
    std.debug.print("\n", .{});

    // Example 4: Complex pattern with negation
    std.debug.print("Example 4: Negated character class\n", .{});
    std.debug.print("===================================\n", .{});

    const files = [_][]const u8{
        "file1.txt",
        "file2.txt",
        "file3.txt",
        "fileA.txt",
        "fileB.txt",
    };

    var result4 = try simdglob.matchFiles(allocator, "file[!12].txt", &files, 0, &g);
    defer result4.deinit();

    std.debug.print("Pattern: file[!12].txt\n", .{});
    std.debug.print("Matches: {d}\n", .{result4.match_count});
    for (result4.paths) |path| {
        std.debug.print("  - {s}\n", .{path});
    }

    std.debug.print("\nAll examples completed successfully!\n", .{});
}
