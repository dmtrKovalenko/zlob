const std = @import("std");
const c_lib = @import("c_lib");
const zlob_t = c_lib.zlob_t;

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    // Heavy workload for perf profiling
    const iterations = 10000;

    std.debug.print("Running {d} iterations on big-repo...\n", .{iterations});

    // Change to big repo
    try std.process.setCurrentPath(io, "/home/neogoose/dev/fff.nvim/big-repo");

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var pzlob: zlob_t = undefined;
        // Use a pattern that matches many files
        const result = c_lib.zlob("drivers/*.c", 0, null, &pzlob);
        if (result == 0) {
            c_lib.zlobfree(&pzlob);
        }
    }

    std.debug.print("Completed {d} iterations\n", .{iterations});
}
