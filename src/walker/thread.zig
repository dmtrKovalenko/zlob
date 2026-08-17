//! Worker-thread spawning that is safe inside a foreign host process.
//!
//! `std.Thread` picks its backend from `builtin.link_libc`
//! (`std/Thread.zig`: `use_pthreads`). Targets we deliberately build without
//! libc -- Android, because Zig ships no bionic headers (see `build.zig`) --
//! therefore get the raw-`clone` `LinuxThreadImpl`. That backend lays the new
//! thread's stack/TLS mapping out from `std.os.linux.tls.area_desc`, a global
//! assigned *only* by `std/start.zig`.
//!
//! zlob is normally a static library inside a host Zig did not start: fff's
//! `libfff_nvim.so` under Neovim, or any C/Rust consumer. There `area_desc`
//! stays zeroed, so `spawn` computes a one-page mapping, places the TLS block
//! inside the untouched `PROT_NONE` guard page and faults in the *calling*
//! thread. That is fff#786: a SIGSEGV on Termux/aarch64 the moment a directory
//! has more than `spawn_threshold` subdirectories. x86_64 does not fault --
//! the same arithmetic makes `spawn` fail cleanly there -- which is why the
//! bug only ever showed up on ARM devices.
//!
//! So on Linux-without-libc we call `pthread_create` directly. The symbol is
//! declared *weak*, so:
//!
//!   - Inside a host that has a libc (bionic under Neovim, glibc under a C
//!     program) it resolves at the final link and we get real threads.
//!   - In a genuinely libc-less program -- the standalone zlob CLI built for
//!     Android -- it resolves to null. There Zig's start code *did* run, so
//!     `area_desc` is populated and `std.Thread` is safe to use; we fall back
//!     to it rather than losing parallelism.
//!   - If neither is available we report `ThreadsUnavailable` and the caller
//!     keeps the walk on its own thread.
//!
//! Covered by `test/test_nolibc_threads.c` (`make test-nolibc-threads`).

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// Only Linux-without-libc can reach the unsafe raw-clone backend. Everywhere
/// else `std.Thread` is either pthread-backed or a safe `UnsupportedImpl`
/// whose `spawn` returns an error instead of faulting.
const needs_weak_pthread = builtin.os.tag == .linux and !builtin.link_libc;

/// `pthread_t` is `unsigned long` on glibc/musl and `long` on bionic, i.e.
/// pointer-sized on every Linux ABI we build for.
const pthread_t = c_ulong;

const StartRoutine = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;

const PthreadCreateFn = *const fn (
    noalias thread: *pthread_t,
    noalias attr: ?*const anyopaque,
    start_routine: StartRoutine,
    noalias arg: ?*anyopaque,
) callconv(.c) c_int;

const PthreadJoinFn = *const fn (thread: pthread_t, res: ?*?*anyopaque) callconv(.c) c_int;

const pthread_create: ?PthreadCreateFn = if (needs_weak_pthread)
    @extern(?PthreadCreateFn, .{ .name = "pthread_create", .linkage = .weak })
else
    null;

const pthread_join: ?PthreadJoinFn = if (needs_weak_pthread)
    @extern(?PthreadJoinFn, .{ .name = "pthread_join", .linkage = .weak })
else
    null;

/// True when `std.Thread`'s raw-clone backend can be trusted, i.e. Zig's start
/// code ran and initialized the TLS descriptor that backend reads. `initStatic`
/// always leaves a non-zero size behind, so zero means "never ran".
inline fn zigStartRan() bool {
    return linux.tls.area_desc.size != 0;
}

pub const SpawnError = error{
    /// The process has no libc to spawn through and Zig's own thread runtime
    /// was never initialized. Not fatal: run single-threaded.
    ThreadsUnavailable,
    SpawnFailed,
};

pub const Thread = struct {
    inner: union(enum) {
        pthread: pthread_t,
        std: std.Thread,
    },

    /// Spawn `f(ctx)` on a new thread. `ctx` must outlive the thread.
    pub fn spawn(comptime f: fn (*anyopaque) void, ctx: *anyopaque) SpawnError!Thread {
        if (needs_weak_pthread) {
            if (pthread_create) |create| {
                const trampoline = struct {
                    fn entry(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
                        f(arg.?);
                        return null;
                    }
                }.entry;

                var handle: pthread_t = 0;
                // Null attrs = the host libc's defaults. The walker keeps its
                // per-worker buffers on the heap (`Worker.io_buf`, `path_buf`
                // live in the workers array) and traverses through an explicit
                // queue rather than recursion, so the default stack is ample.
                if (create(&handle, null, trampoline, ctx) != 0) return error.SpawnFailed;
                return .{ .inner = .{ .pthread = handle } };
            }
            if (!zigStartRan()) return error.ThreadsUnavailable;
        }

        const t = std.Thread.spawn(.{}, f, .{ctx}) catch return error.SpawnFailed;
        return .{ .inner = .{ .std = t } };
    }

    pub fn join(self: Thread) void {
        switch (self.inner) {
            .pthread => |h| _ = pthread_join.?(h, null),
            .std => |t| t.join(),
        }
    }
};
