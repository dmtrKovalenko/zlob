// "Fixed" plugin — same as libplugin.zig but overrides std_options to
// disable the 256 KB alternative signal stack. With the override,
// std.Thread.maybeAttachSignalStack early-returns at comptime and the
// fat threadlocal is never instantiated.
//
// The resulting `libplugin_fixed.so` has a TLS program header of a few
// bytes (just the small `tls_thread_id` etc.). `dlopen` succeeds.
const std = @import("std");

pub const std_options: std.Options = .{
    .signal_stack_size = null,
};

fn worker() void {}

export fn plugin_run() c_int {
    const t = std.Thread.spawn(.{}, worker, .{}) catch return 1;
    t.join();
    return 0;
}
