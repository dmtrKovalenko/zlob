const std = @import("std");
const glob = @import("glob");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    std.debug.print("=== Testing new glob features ===\n\n", .{});

    // Test 1: Brace expansion
    std.debug.print("Test 1: Brace expansion {{src,examples}}/*.zig\n", .{});
    var pglob: glob.glob_t = undefined;
    var result = glob.glob(allocator, "{src,examples}/*.zig", glob.GLOB_BRACE, null, &pglob);
    if (result == 0) {
        std.debug.print("  SUCCESS: Matches: {d}\n", .{pglob.gl_pathc});
        var i: usize = 0;
        while (i < pglob.gl_pathc and i < 10) : (i += 1) {
            const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
            std.debug.print("    {s}\n", .{path});
        }
        glob.globfree(allocator, &pglob);
    } else {
        std.debug.print("  FAILED with code: {d}\n", .{result});
    }

    // Test 2: Nested braces
    std.debug.print("\nTest 2: Nested braces src/*.{{zig,c}}\n", .{});
    result = glob.glob(allocator, "src/*.{zig,c}", glob.GLOB_BRACE, null, &pglob);
    if (result == 0) {
        std.debug.print("  SUCCESS: Matches: {d}\n", .{pglob.gl_pathc});
        var i: usize = 0;
        while (i < pglob.gl_pathc and i < 10) : (i += 1) {
            const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
            std.debug.print("    {s}\n", .{path});
        }
        glob.globfree(allocator, &pglob);
    } else {
        std.debug.print("  FAILED with code: {d}\n", .{result});
    }

    // Test 3: Recursive glob **/*.zig
    std.debug.print("\nTest 3: Recursive glob **/*.zig\n", .{});
    result = glob.glob(allocator, "**/*.zig", 0, null, &pglob);
    if (result == 0) {
        std.debug.print("  SUCCESS: Matches: {d}\n", .{pglob.gl_pathc});
        var i: usize = 0;
        while (i < pglob.gl_pathc and i < 15) : (i += 1) {
            const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
            std.debug.print("    {s}\n", .{path});
        }
        if (pglob.gl_pathc > 15) {
            std.debug.print("    ... and {d} more files\n", .{pglob.gl_pathc - 15});
        }
        glob.globfree(allocator, &pglob);
    } else {
        std.debug.print("  FAILED with code: {d}\n", .{result});
    }

    // Test 4: Recursive with specific dir
    std.debug.print("\nTest 4: Recursive in subdirectory src/**/*.zig\n", .{});
    result = glob.glob(allocator, "src/**/*.zig", 0, null, &pglob);
    if (result == 0) {
        std.debug.print("  SUCCESS: Matches: {d}\n", .{pglob.gl_pathc});
        var i: usize = 0;
        while (i < pglob.gl_pathc and i < 10) : (i += 1) {
            const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
            std.debug.print("    {s}\n", .{path});
        }
        glob.globfree(allocator, &pglob);
    } else {
        std.debug.print("  FAILED with code: {d}\n", .{result});
    }

    // Test 5: Combined - brace + recursive
    std.debug.print("\nTest 5: Combined brace + recursive {{src,examples}}/**/*.zig\n", .{});
    result = glob.glob(allocator, "{src,examples}/**/*.zig", glob.GLOB_BRACE, null, &pglob);
    if (result == 0) {
        std.debug.print("  SUCCESS: Matches: {d}\n", .{pglob.gl_pathc});
        var i: usize = 0;
        while (i < pglob.gl_pathc and i < 15) : (i += 1) {
            const path = std.mem.sliceTo(pglob.gl_pathv[i], 0);
            std.debug.print("    {s}\n", .{path});
        }
        glob.globfree(allocator, &pglob);
    } else {
        std.debug.print("  FAILED with code: {d}\n", .{result});
    }

    std.debug.print("\nAll tests completed!\n", .{});
}
