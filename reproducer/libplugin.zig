// "Broken" plugin — exports one C function, internally uses std.Thread.spawn
// which forces std.Thread.maybeAttachSignalStack into the compilation.
// That function declares a `threadlocal var signal_stack: [262144]u8`
// under the default std_options.signal_stack_size (256 KB).
//
// The resulting `libplugin_broken.so` has a TLS program header of ~256 KB.
// When a host `dlopen`s it after its own TLS layout is frozen, glibc fails
// with `cannot allocate memory in static TLS block`.
const std = @import("std");

fn worker() void {}

export fn plugin_run() c_int {
    // Touching std.Thread.spawn is enough to pull maybeAttachSignalStack
    // into the binary and instantiate the fat threadlocal.
    const t = std.Thread.spawn(.{}, worker, .{}) catch return 1;
    t.join();
    return 0;
}
