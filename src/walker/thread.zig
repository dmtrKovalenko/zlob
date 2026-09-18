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

/// `pthread_attr_t` is 56 bytes on glibc x86_64, 64 on musl x86_64, 24 on
/// bionic (32-bit) / 56 on bionic 64-bit. 64 bytes of 16-byte-aligned storage
/// covers every Linux libc we can be linked against.
const PthreadAttr = extern struct { opaque_bytes: [64]u8 align(16) };

const PthreadAttrInitFn = *const fn (attr: *PthreadAttr) callconv(.c) c_int;
const PthreadAttrDestroyFn = *const fn (attr: *PthreadAttr) callconv(.c) c_int;
const PthreadAttrSetStackSizeFn = *const fn (attr: *PthreadAttr, size: usize) callconv(.c) c_int;

const pthread_attr_init: ?PthreadAttrInitFn = if (needs_weak_pthread)
    @extern(?PthreadAttrInitFn, .{ .name = "pthread_attr_init", .linkage = .weak })
else
    null;

const pthread_attr_destroy: ?PthreadAttrDestroyFn = if (needs_weak_pthread)
    @extern(?PthreadAttrDestroyFn, .{ .name = "pthread_attr_destroy", .linkage = .weak })
else
    null;

const pthread_attr_setstacksize: ?PthreadAttrSetStackSizeFn = if (needs_weak_pthread)
    @extern(?PthreadAttrSetStackSizeFn, .{ .name = "pthread_attr_setstacksize", .linkage = .weak })
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

/// Default helper-thread stack size: 1 MiB.
///
/// `std.Thread`'s default is 16 MiB, and glibc keeps at most 40 MiB
/// (`glibc.pthread.stack_cache_size`) of exited threads' stacks around for
/// reuse. Fifteen 16 MiB stacks blow through that cache, so every walk pays
/// for 13-15 fresh `mmap(MAP_STACK)` + `mprotect` guard + first-touch faults,
/// and `munmap` (TLB shootdowns under `mmap_lock`) at join -- about 2/3 of a
/// small walk's page faults. Fifteen 1 MiB stacks (15 MiB) fit in the cache
/// and are reused across walks with no mmap traffic at all.
///
/// The walker itself is non-recursive and keeps its big buffers off-stack
/// (`Worker.io_buf`, `Worker.path_buf` live in the workers array), so the
/// only stack consumer of note is the caller's visitor/sink callback. Rust
/// defaults threads to 2 MiB and bionic to 1 MiB, so 1 MiB is a familiar
/// floor; `Options.thread_stack_size` raises it when a callback needs more.
///
/// Do not go much lower: glibc rejects sizes that cannot also hold the
/// static TLS block plus the guard page (256 KiB fails with EINVAL on a
/// typical desktop glibc), and `std.Thread.spawn` maps EINVAL to
/// `unreachable`, which in ReleaseFast silently degrades to a single-threaded
/// walk. `spawn` below additionally falls back to `FALLBACK_STACK_SIZE` when
/// the requested size is refused, so an unusual libc cannot cost parallelism.
pub const DEFAULT_STACK_SIZE: usize = 1 << 20;

/// Second attempt when the libc refuses `stack_size`; matches the
/// `std.Thread` default so behaviour is at worst what it was before.
pub const FALLBACK_STACK_SIZE: usize = 16 << 20;

/// Anything below this is refused by glibc (static TLS + guard) and would
/// only silently serialize the walk, so clamp rather than try.
const MIN_STACK_SIZE: usize = 512 << 10;

pub const Thread = struct {
    inner: union(enum) {
        pthread: pthread_t,
        std: std.Thread,
    },

    /// Spawn `f(ctx)` on a new thread with a `stack_size`-byte stack (0 =
    /// `DEFAULT_STACK_SIZE`). `ctx` must outlive the thread. If the libc
    /// refuses the requested size the spawn is retried once with
    /// `FALLBACK_STACK_SIZE`.
    pub fn spawn(comptime f: fn (*anyopaque) void, ctx: *anyopaque, stack_size: usize) SpawnError!Thread {
        const requested = @max(if (stack_size == 0) DEFAULT_STACK_SIZE else stack_size, MIN_STACK_SIZE);
        return spawnSized(f, ctx, requested) catch |err| switch (err) {
            error.SpawnFailed => if (requested < FALLBACK_STACK_SIZE)
                spawnSized(f, ctx, FALLBACK_STACK_SIZE)
            else
                err,
            else => err,
        };
    }

    fn spawnSized(comptime f: fn (*anyopaque) void, ctx: *anyopaque, stack_size: usize) SpawnError!Thread {
        if (needs_weak_pthread) {
            if (pthread_create) |create| {
                const trampoline = struct {
                    fn entry(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
                        f(arg.?);
                        return null;
                    }
                }.entry;

                // Build a pthread_attr carrying the stack size. If the attr
                // functions did not resolve (a libc exporting pthread_create
                // but not the attr API is not something we expect, but the
                // symbols are weak) fall back to the host libc's defaults.
                var attr: PthreadAttr = undefined;
                var attr_ptr: ?*const anyopaque = null;
                const have_attr = pthread_attr_init != null and
                    pthread_attr_setstacksize != null and
                    pthread_attr_destroy != null;
                if (have_attr and pthread_attr_init.?(&attr) == 0) {
                    if (pthread_attr_setstacksize.?(&attr, stack_size) == 0) {
                        attr_ptr = @ptrCast(&attr);
                    }
                }
                defer {
                    if (have_attr and attr_ptr != null) _ = pthread_attr_destroy.?(&attr);
                }
                if (attr_ptr == null and stack_size != FALLBACK_STACK_SIZE) return error.SpawnFailed;

                var handle: pthread_t = 0;
                if (create(&handle, attr_ptr, trampoline, ctx) != 0) return error.SpawnFailed;
                return .{ .inner = .{ .pthread = handle } };
            }
            if (!zigStartRan()) return error.ThreadsUnavailable;
        }

        const t = std.Thread.spawn(.{ .stack_size = stack_size }, f, .{ctx}) catch return error.SpawnFailed;
        return .{ .inner = .{ .std = t } };
    }

    pub fn join(self: Thread) void {
        switch (self.inner) {
            .pthread => |h| _ = pthread_join.?(h, null),
            .std => |t| t.join(),
        }
    }
};
