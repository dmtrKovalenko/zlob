//! Walk benchmark harness for A/B perf work.
//!
//! Usage:
//!   bench_walk <root> <mode> [iters] [threads]     mode: plain | gitignore | meta | serial
//!   bench_walk <root> glob <pattern> [iters]          C-style zlob() glob (single-threaded)
//!   bench_walk <root> walkglob <pattern> [iters] [threads]   parallel walker with Options.pattern
//!   bench_walk sizes                                     print @sizeOf hot structs
//!
//! Prints one machine-parseable line:
//!   RESULT mode=<mode> root=<root> count=<N> best_us=<X> median_us=<Y> threads=<T> iters=<I>
//!
//! Timings are wall-clock per iteration (best and median over `iters`, after one
//! untimed warmup). Numbers from separate invocations are NOT comparable
//! (page cache state); interleave base/new binaries in one loop (see ab.sh).
const std = @import("std");
const zlob = @import("zlob");
const c_lib = @import("c_lib");
const zlob_flags = @import("zlob_flags");
const walk = zlob.walk;

// Mirror src/c_lib.zig: opt out of the default 256 KiB threadlocal signal
// stack (std.Thread's entry wrapper instantiates it per spawned thread and
// glibc memsets the whole TLS block inside pthread_create) and the segfault
// handler. This is a root-module setting; libzlob.a already sets it, but
// every Zig root binary must set it itself or every parallel walk pays
// ~256 KiB of zeroing + 64 page faults + a sigaltstack syscall per thread.
pub const std_options: std.Options = .{
    .signal_stack_size = null,
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};

const Mode = enum { plain, gitignore, meta, serial, glob, walkglob, sizes };

fn usage(prog: []const u8) noreturn {
    std.debug.print(
        \\Usage: {s} <root> <plain|gitignore|meta|serial> [iters=5] [threads=0]
        \\       {s} <root> glob <pattern> [iters=5]
        \\       {s} <root> walkglob <pattern> [iters=5] [threads=0]
        \\       {s} sizes
        \\
    , .{ prog, prog, prog, prog });
    std.process.exit(2);
}

fn parseUsize(s: []const u8, prog: []const u8) usize {
    return std.fmt.parseInt(usize, s, 10) catch usage(prog);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.c_allocator;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_iter.deinit();
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv_list.items) |a| allocator.free(a);
        argv_list.deinit(allocator);
    }
    while (args_iter.next()) |arg| try argv_list.append(allocator, try allocator.dupe(u8, arg));
    const args = argv_list.items;
    const prog = if (args.len > 0) args[0] else "bench_walk";
    if (args.len >= 2 and std.mem.eql(u8, args[1], "sizes")) {
        std.debug.print("sizeof Entry={d} Metadata={d} MetaMask={d} Options={d}\n", .{
            @sizeOf(walk.Entry), @sizeOf(walk.Metadata), @sizeOf(walk.MetaMask), @sizeOf(walk.Options),
        });
        return;
    }
    if (args.len < 3) usage(prog);

    const root = args[1];
    const mode = std.meta.stringToEnum(Mode, args[2]) orelse usage(prog);

    var iters: usize = 5;
    var threads: u16 = 0;
    var pattern: []const u8 = "";
    if (mode == .glob or mode == .walkglob) {
        if (args.len < 4) usage(prog);
        pattern = args[3];
        if (args.len > 4) iters = parseUsize(args[4], prog);
        if (args.len > 5) threads = @intCast(parseUsize(args[5], prog));
    } else {
        if (args.len > 3) iters = parseUsize(args[3], prog);
        if (args.len > 4) threads = @intCast(parseUsize(args[4], prog));
    }
    if (iters == 0) usage(prog);

    const times = try allocator.alloc(u64, iters);
    defer allocator.free(times);

    var count: usize = 0;
    var eff_threads: u32 = 1;

    switch (mode) {
        .glob => {
            try std.process.setCurrentPath(io, root);
            const pat_z = try allocator.dupeZ(u8, pattern);
            defer allocator.free(pat_z);
            // warmup
            count = runGlob(pat_z);
            for (times) |*t| {
                const start = std.Io.Timestamp.now(io, .awake);
                const n = runGlob(pat_z);
                const end = std.Io.Timestamp.now(io, .awake);
                t.* = @intCast(start.durationTo(end).nanoseconds);
                if (n != count) {
                    std.debug.print("count changed between iterations: {d} vs {d}\n", .{ count, n });
                    std.process.exit(3);
                }
            }
        },
        else => {
            var opts: walk.Options = .{
                .threads = threads,
                .respect_git = false,
                .skip_git_dir = false,
                .include_hidden = true,
                .report_dirs = true,
                .meta = .{},
            };
            switch (mode) {
                .plain => {},
                .gitignore => {
                    opts.respect_git = true;
                    opts.skip_git_dir = true;
                },
                .meta => opts.meta = .{ .size = true, .mtime = true },
                .serial => opts.threads = 1,
                .walkglob => {
                    opts.pattern = pattern;
                    opts.report_dirs = false;
                },
                .glob, .sizes => unreachable,
            }
            eff_threads = walk.effectiveThreads(&opts);

            // warmup
            count = try runWalk(allocator, root, opts);
            for (times) |*t| {
                const start = std.Io.Timestamp.now(io, .awake);
                const n = try runWalk(allocator, root, opts);
                const end = std.Io.Timestamp.now(io, .awake);
                t.* = @intCast(start.durationTo(end).nanoseconds);
                if (n != count) {
                    std.debug.print("count changed between iterations: {d} vs {d}\n", .{ count, n });
                    std.process.exit(3);
                }
            }
        },
    }

    std.sort.pdq(u64, times, {}, std.sort.asc(u64));
    const best_us = times[0] / 1000;
    const median_us = if (iters % 2 == 1)
        times[iters / 2] / 1000
    else
        (times[iters / 2 - 1] + times[iters / 2]) / 2000;

    var out_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var w = stdout_file.writer(io, &out_buf);
    if (mode == .glob) {
        try w.interface.print("RESULT mode=glob root={s} pattern={s} count={d} best_us={d} median_us={d} threads=1 iters={d}\n", .{ root, pattern, count, best_us, median_us, iters });
    } else if (mode == .walkglob) {
        try w.interface.print("RESULT mode=walkglob root={s} pattern={s} count={d} best_us={d} median_us={d} threads={d} iters={d}\n", .{ root, pattern, count, best_us, median_us, eff_threads, iters });
    } else {
        try w.interface.print("RESULT mode={s} root={s} count={d} best_us={d} median_us={d} threads={d} iters={d}\n", .{ @tagName(mode), root, count, best_us, median_us, eff_threads, iters });
    }
    try w.interface.flush();
}

fn runWalk(allocator: std.mem.Allocator, root: []const u8, opts: walk.Options) !usize {
    var res = try walk.collect(allocator, root, opts);
    defer res.deinit();
    return res.entries.len;
}

fn runGlob(pattern: [:0]const u8) usize {
    var pzlob: c_lib.zlob_t = undefined;
    const rc = c_lib.zlob(pattern.ptr, zlob_flags.ZLOB_RECOMMENDED, null, &pzlob);
    if (rc != 0) {
        std.debug.print("zlob() failed: rc={d}\n", .{rc});
        std.process.exit(4);
    }
    const n = pzlob.zlo_pathc;
    c_lib.zlobfree(&pzlob);
    return n;
}
