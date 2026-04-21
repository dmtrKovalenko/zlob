# Isolated reproducer for `cannot allocate memory in static TLS block`

Two binaries, zero dependencies on zlob. Reproduces the glibc static-TLS
exhaustion that fff.nvim / zlob 1.3.2 / Zig 0.16 consumers hit on Linux.

## Files

- `host.c`         — C host executable. `dlopen`s a plugin and calls it.
- `libplugin.zig`  — Zig shared library. Uses `std.Thread.spawn`, which
                     pulls in the 256 KB `threadlocal var signal_stack`
                     from `std.Thread.maybeAttachSignalStack`. This is
                     the "broken" version.
- `libplugin_fixed.zig` — Same as above but with
                     `pub const std_options: std.Options =
                         .{ .signal_stack_size = null };`
                     which is the fix.
- `Makefile`       — Builds both plugins and the host, runs the reproduction.

## How to run (Linux glibc)

    cd reproducer
    make
    ./host ./libplugin_broken.so   # should fail: cannot allocate memory in static TLS block
    ./host ./libplugin_fixed.so    # should succeed

The broken .so will have a TLS program header of ~256 KB. Check with:

    readelf -l libplugin_broken.so | grep TLS
    readelf -l libplugin_fixed.so  | grep TLS
