const std = @import("std");
const c_lib = @import("c_lib");
const zlob_t = c_lib.zlob_t;

pub fn main() !void {
    std.process.changeCurDir("/home/neogoose/dev/fff.nvim/big-repo") catch {};

    const pattern = "drivers/**/*.c";
    const iterations = 5;

    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Running {d} iterations...\n\n", .{iterations});

    var total_time: u64 = 0;
    var total_matches: usize = 0;

    for (0..iterations) |i| {
        var timer = try std.time.Timer.start();

        var result: zlob_t = undefined;
        const ret = c_lib.zlob(pattern, 0, null, &result);

        const elapsed = timer.read();
        total_time += elapsed;

        if (ret == 0) {
            total_matches = result.gl_pathc;
            std.debug.print("  Iteration {d}: {d}μs ({d} matches)\n", .{ i + 1, elapsed / 1000, result.gl_pathc });
            c_lib.zlobfree(&result);
        } else {
            std.debug.print("  Iteration {d}: FAILED\n", .{i + 1});
        }
    }

    std.debug.print("\nAverage: {d}μs ({d} matches)\n", .{ total_time / iterations / 1000, total_matches });
}
