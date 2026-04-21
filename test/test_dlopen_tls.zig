// Regression test for #298 / fff.nvim TLS-block crash on Linux glibc.
//
// Reproducer:
//   A consumer shared library (libdlopen_consumer.so) statically links zlob.
//   A host process `dlopen()`s it after the main program is fully up.
//
// Under the bug, zlob's Zig runtime pulls in a 256 KB `threadlocal var
// signal_stack` from std.Thread.maybeAttachSignalStack. When such a shared
// library is loaded via `dlopen` (late), glibc has to carve TLS out of a
// small per-thread "static TLS" reserve. If that reserve is exhausted the
// load fails with:
//   `cannot allocate memory in static TLS block`
//
// macOS (dyld) and Windows (PE TLS callbacks) don't have the same
// limitation, so this test only runs on Linux glibc. The build system
// gates this test to that target.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const c = @cImport({
    @cInclude("dlfcn.h");
    @cInclude("stdlib.h");
});

test "dlopen consumer shared library does not exhaust static TLS block" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (builtin.abi == .musl) return error.SkipZigTest;

    // The build step sets ZLOB_DLOPEN_CONSUMER to the consumer .so's path.
    // Tests don't receive argv (the test runner owns it for --listen=...),
    // so an env var is the cleanest way to pass the path through.
    const lib_path_c = c.getenv("ZLOB_DLOPEN_CONSUMER") orelse {
        std.debug.print(
            "ZLOB_DLOPEN_CONSUMER not set; the build step should pass the consumer .so path\n",
            .{},
        );
        return error.MissingLibPath;
    };
    const lib_path = std.mem.sliceTo(lib_path_c, 0);

    const handle = c.dlopen(lib_path_c, c.RTLD_NOW | c.RTLD_LOCAL);
    if (handle == null) {
        const err = c.dlerror();
        const msg = if (err) |e| std.mem.sliceTo(e, 0) else "(no dlerror)";
        std.debug.print("dlopen({s}) failed: {s}\n", .{ lib_path, msg });
        return error.DlopenFailed;
    }
    defer _ = c.dlclose(handle);

    // Resolve and call the consumer symbol. This forces the loader to bind
    // the zlob code path that materializes TLS storage. If dlopen returned a
    // handle but TLS is broken, the call (or prior TLS init) would SIGSEGV;
    // reaching here means the library is loadable and callable.
    const sym = c.dlsym(handle, "consume_zlob");
    if (sym == null) {
        const err = c.dlerror();
        const msg = if (err) |e| std.mem.sliceTo(e, 0) else "(no dlerror)";
        std.debug.print("dlsym(consume_zlob) failed: {s}\n", .{msg});
        return error.DlsymFailed;
    }

    const consume_zlob: *const fn () callconv(.c) c_int = @ptrCast(@alignCast(sym));
    // `*.zig` contains a wildcard → expected to return 1.
    try testing.expectEqual(@as(c_int, 1), consume_zlob());
}
