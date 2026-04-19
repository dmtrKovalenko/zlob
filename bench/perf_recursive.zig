const std = @import("std");
const c_lib = @import("c_lib");
const zlob_t = c_lib.zlob_t;

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.process.setCurrentPath(io, "/home/neogoose/dev/fff.nvim/big-repo") catch {};

    const pattern = "drivers/**/*.c";
    const iterations = 100;

    for (0..iterations) |_| {
        var result: zlob_t = undefined;
        const ret = c_lib.zlob(pattern, 0, null, &result);
        if (ret == 0) {
            c_lib.zlobfree(&result);
        }
    }
}
