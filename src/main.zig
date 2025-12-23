const std = @import("std");
const simdglob = @import("simdglob");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    const pattern = args.next() orelse {
        std.debug.print("Usage: simdglob <pattern> [flags]\n", .{});
        std.debug.print("\nExample patterns:\n", .{});
        std.debug.print("  *.txt          - All .txt files in current directory\n", .{});
        std.debug.print("  **/*.zig       - All .zig files recursively\n", .{});
        std.debug.print("  src/*.zig      - All .zig files in src directory\n", .{});
        std.debug.print("  [abc]*.txt     - Files starting with a, b, or c\n", .{});
        std.debug.print("  file?.txt      - file1.txt, file2.txt, etc.\n", .{});
        std.debug.print("\nFlags:\n", .{});
        std.debug.print("  --mark         - Append / to directories\n", .{});
        std.debug.print("  --nosort       - Don't sort results\n", .{});
        std.debug.print("  --noescape     - Don't treat \\ as escape character\n", .{});
        return;
    };

    // Parse flags
    var flags: u32 = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--mark")) {
            flags |= simdglob.GLOB_MARK;
        } else if (std.mem.eql(u8, arg, "--nosort")) {
            flags |= simdglob.GLOB_NOSORT;
        } else if (std.mem.eql(u8, arg, "--noescape")) {
            flags |= simdglob.GLOB_NOESCAPE;
        } else {
            std.debug.print("Unknown flag: {s}\n", .{arg});
            return;
        }
    }

    // Perform glob matching
    const start = std.time.nanoTimestamp();
    var result = simdglob.match(allocator, pattern, flags) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };
    defer result.deinit();
    const end = std.time.nanoTimestamp();

    // Print results
    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Matches: {d}\n", .{result.match_count});
    std.debug.print("Time: {d:.2}ms\n\n", .{@as(f64, @floatFromInt(end - start)) / 1_000_000.0});

    if (result.match_count == 0) {
        std.debug.print("No matches found.\n", .{});
    } else {
        for (result.paths) |path| {
            std.debug.print("{s}\n", .{path});
        }
    }
}
