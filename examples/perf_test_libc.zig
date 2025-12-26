const std = @import("std");
const glob_libc = @import("glob_libc");

pub fn main() !void {
    // Heavy workload for perf profiling
    const iterations = 10000;

    std.debug.print("Running {d} iterations on big-repo...\n", .{iterations});

    // Change to big repo
    try std.process.changeCurDir("/home/neogoose/dev/fff.nvim/big-repo");

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var pglob: glob_libc.glob_t = undefined;
        // Use a pattern that matches many files
        const result = glob_libc.glob("drivers/*.c", 0, null, &pglob);
        if (result == 0) {
            glob_libc.globfree(&pglob);
        }
    }

    std.debug.print("Completed {d} iterations\n", .{iterations});
}
