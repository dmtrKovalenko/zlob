const std = @import("std");
const glob = @import("glob");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    // Heavy workload for perf profiling
    const iterations = 10000;

    std.debug.print("Running {d} iterations on big-repo...\n", .{iterations});

    // Change to big repo
    try std.process.changeCurDir("/home/neogoose/dev/fff.nvim/big-repo");

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var pglob: glob.glob_t = undefined;
        // Use a pattern that matches many files
        const result = glob.glob(allocator, "drivers/*.c", 0, null, &pglob);
        if (result == 0) {
            glob.globfree(allocator, &pglob);
        }
    }

    std.debug.print("Completed {d} iterations\n", .{iterations});
}
