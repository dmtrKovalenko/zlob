const std = @import("std");
const c_lib = @import("c_lib");
const zlob_t = c_lib.zlob_t;

pub fn main() !void {
    std.process.changeCurDir("/home/neogoose/dev/fff.nvim/big-repo") catch {};

    const patterns = [_][:0]const u8{
        "drivers/*/*.c", // Nested (non-recursive)
        "drivers/**/*.c", // Recursive
    };

    for (patterns) |pattern| {
        std.debug.print("\nPattern: {s}\n", .{pattern});

        var total: u64 = 0;
        var count: usize = 0;
        const iterations = 10;

        for (0..iterations) |_| {
            var timer = try std.time.Timer.start();
            var result: zlob_t = undefined;
            const ret = c_lib.zlob(pattern, 0, null, &result);
            total += timer.read();
            if (ret == 0) {
                count = result.zlo_pathc;
                c_lib.zlobfree(&result);
            }
        }

        std.debug.print("  Average: {d}μs ({d} matches)\n", .{ total / iterations / 1000, count });
    }
}
