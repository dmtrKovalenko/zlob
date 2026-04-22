// Minimal consumer shared library that statically links zlob.
// Mirrors how downstream crates (e.g. fff-nvim's libfff_nvim.so) embed zlob:
// a `.so` that is produced ahead of time and then `dlopen`'d by a host that
// has already finished its own TLS setup (e.g. neovim loading a plugin).
//
// A Zig-native consumer instantiates std itself, so std_options is read
// from *this* file, not from c_lib.zig. Rust/C consumers don't have to do
// anything because they don't compile Zig std — linking libzlob.a (which
// has zlob's fix baked in) is enough. Any Zig-native consumer, though,
// must repeat the override or its own std.Thread will re-introduce the
// 256 KB threadlocal signal_stack that defeats the purpose of the fix.
const std = @import("std");
const c_lib = @import("c_lib");

pub const std_options: std.Options = .{
    .signal_stack_size = null,
};

export fn consume_zlob() c_int {
    return c_lib.zlob_has_wildcards("*.zig", 0);
}
