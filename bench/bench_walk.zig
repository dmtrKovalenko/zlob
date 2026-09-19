//! Walk benchmark harness for A/B perf work.
//!
//! Usage:
//!   bench_walk <root> <mode> [iters] [threads]
//!       mode: plain | gitignore | meta | serial | sort | follow | ccollect | run | crun
//!         plain     walk.collect, no gitignore, hidden + dirs reported
//!         gitignore walk.collect honoring .gitignore (skips .git)
//!         meta      walk.collect with size+mtime metadata (statx per entry)
//!         serial    walk.collect with threads=1
//!         sort      walk.collect with Options.sort (sorted-collect cost)
//!         follow    walk.collect with follow_symlinks (symlink pre-flight cost)
//!         ccollect  C API zlob_walk_collect (C-ABI collect overhead)
//!         run       walk.run streaming visitor (no result allocation)
//!         crun      C API zlob_walk streaming callback
//!   bench_walk <root> glob <pattern> [iters]          C-style zlob() glob (single-threaded)
//!   bench_walk <root> globsort <pattern> [iters]      same without ZLOB_NOSORT (glob sort cost)
//!   bench_walk <root> walkglob <pattern> [iters] [threads]   parallel walker with Options.pattern
//!   bench_walk <root> globpar <pattern> [iters] [threads]    zlob() with ZLOB_PARALLEL (threads: 0=default 4)
//!   bench_walk sizes                                     print @sizeOf hot structs
//!
//! Prints one machine-parseable line:
//!   RESULT mode=<mode> root=<root> count=<N> best_us=<X> median_us=<Y> threads=<T> iters=<I>
//!
//! Timings are wall-clock per iteration (best and median over `iters`, after one
//! untimed warmup). Numbers from separate invocations are NOT comparable
//! because page-cache state differs; interleave base/new binaries in one loop.
const std = @import("std");
const zlob = @import("zlob");
const c_lib = @import("c_lib");
const zlob_flags = @import("zlob_flags");
const walk = zlob.walk;

// Root-module opt-out for per-worker signal-stack setup; see README.md.
pub const std_options: std.Options = .{
    .signal_stack_size = null,
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};

const Mode = enum { plain, gitignore, meta, serial, sort, follow, ccollect, run, crun, glob, globsort, walkglob, globpar };

fn isGlobMode(m: Mode) bool {
    return m == .glob or m == .globsort or m == .globpar;
}

fn usage(prog: []const u8) noreturn {
    std.debug.print(
        \\Usage: {s} <root> <plain|gitignore|meta|serial|sort|follow|ccollect|run|crun> [iters=5] [threads=0]
        \\       {s} <root> glob <pattern> [iters=5]
        \\       {s} <root> globsort <pattern> [iters=5]
        \\       {s} <root> walkglob <pattern> [iters=5] [threads=0]
        \\       {s} <root> globpar <pattern> [iters=5] [threads=0]
        \\       {s} sizes
        \\
    , .{ prog, prog, prog, prog, prog, prog });
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
        std.debug.print("sizeof Entry={d} Metadata={d} MetaMask={d} Options={d} zlob_walk_entry_t={d}\n", .{
            @sizeOf(walk.Entry), @sizeOf(walk.Metadata), @sizeOf(walk.MetaMask), @sizeOf(walk.Options), @sizeOf(c_lib.zlob_walk_entry_t),
        });
        return;
    }
    if (args.len < 3) usage(prog);

    const root = args[1];
    const mode = std.meta.stringToEnum(Mode, args[2]) orelse usage(prog);
    // Read once here: runWalk runs inside the timed loop.
    if (std.c.getenv("ZLOB_BENCH_DUMP")) |p| dump_path = std.mem.sliceTo(p, 0);

    var iters: usize = 5;
    var threads: u16 = 0;
    var pattern: []const u8 = "";
    if (isGlobMode(mode) or mode == .walkglob) {
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
        .glob, .globsort, .globpar => {
            try std.process.setCurrentPath(io, root);
            const pat_z = try allocator.dupeZ(u8, pattern);
            defer allocator.free(pat_z);
            var gflags: c_int = if (mode == .globsort)
                zlob_flags.ZLOB_RECOMMENDED & ~@as(c_int, zlob_flags.ZLOB_NOSORT)
            else
                zlob_flags.ZLOB_RECOMMENDED;
            if (mode == .globpar) {
                gflags |= zlob_flags.ZLOB_PARALLEL;
                if (threads != 0) zlob.setGlobParallelThreads(threads);
                eff_threads = if (threads != 0) threads else 4;
            }
            count = runGlob(pat_z, gflags);
            for (times) |*t| {
                const start = std.Io.Timestamp.now(io, .awake);
                const n = runGlob(pat_z, gflags);
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
                .sort => opts.sort = true,
                .walkglob => {
                    opts.pattern = pattern;
                    opts.report_dirs = false;
                },
                .follow => opts.follow_symlinks = true,
                .ccollect, .run, .crun => {},
                .glob, .globsort, .globpar => unreachable,
            }
            eff_threads = walk.effectiveThreads(&opts);

            const root_z = try allocator.dupeZ(u8, root);
            defer allocator.free(root_z);

            count = try runMode(mode, allocator, root, root_z, opts);
            for (times) |*t| {
                const start = std.Io.Timestamp.now(io, .awake);
                const n = try runMode(mode, allocator, root, root_z, opts);
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
    if (isGlobMode(mode)) {
        try w.interface.print("RESULT mode={s} root={s} pattern={s} count={d} best_us={d} median_us={d} threads={d} iters={d}\n", .{ @tagName(mode), root, pattern, count, best_us, median_us, eff_threads, iters });
    } else if (mode == .walkglob) {
        try w.interface.print("RESULT mode=walkglob root={s} pattern={s} count={d} best_us={d} median_us={d} threads={d} iters={d}\n", .{ root, pattern, count, best_us, median_us, eff_threads, iters });
    } else {
        try w.interface.print("RESULT mode={s} root={s} count={d} best_us={d} median_us={d} threads={d} iters={d}\n", .{ @tagName(mode), root, count, best_us, median_us, eff_threads, iters });
    }
    try w.interface.flush();
}

fn runMode(mode: Mode, allocator: std.mem.Allocator, root: []const u8, root_z: [:0]const u8, opts: walk.Options) !usize {
    return switch (mode) {
        .ccollect => runCCollect(root_z, opts),
        .run => runRun(allocator, root, opts),
        .crun => runCRun(root_z, opts),
        else => runWalk(allocator, root, opts),
    };
}

/// ZLOB_BENCH_DUMP target, resolved once in main (see dumpEntries).
var dump_path: ?[]const u8 = null;

fn runWalk(allocator: std.mem.Allocator, root: []const u8, opts: walk.Options) !usize {
    var res = try walk.collect(allocator, root, opts);
    defer res.deinit();
    if (dump_path) |p| try dumpEntries(allocator, p, &res);
    return res.entries.len;
}

/// ZLOB_BENCH_DUMP=<file>: write every collected root-relative path (sorted,
/// one per line) so two runs can be diffed when their counts disagree.
fn dumpEntries(allocator: std.mem.Allocator, path: []const u8, res: *const walk.WalkerResult) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const paths = try allocator.alloc([]const u8, res.entries.len);
    defer allocator.free(paths);
    for (res.entries, paths) |*e, *p| p.* = e.relativePath();
    std.mem.sort([]const u8, paths, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [1 << 16]u8 = undefined;
    var fw = f.writer(io, &buf);
    for (paths) |p| {
        try fw.interface.writeAll(p);
        try fw.interface.writeByte('\n');
    }
    try fw.interface.flush();
}

/// Mirror the bench's walk.Options onto the C ABI options (bits from include/zlob.h).
fn cOpts(o: walk.Options) c_lib.zlob_walk_options_t {
    var f: u32 = 0;
    if (o.respect_git) f |= 1 << 0; // ZLOB_WALK_GITIGNORE
    if (!o.include_hidden) f |= 1 << 1; // ZLOB_WALK_SKIP_HIDDEN
    if (o.follow_symlinks) f |= 1 << 2; // ZLOB_WALK_FOLLOW_SYMLINKS
    if (!o.report_dirs) f |= 1 << 3; // ZLOB_WALK_NO_REPORT_DIRS
    if (o.sort) f |= 1 << 4; // ZLOB_WALK_SORT
    if (!o.skip_git_dir) f |= 1 << 6; // ZLOB_WALK_KEEP_GIT_DIR
    return .{ .flags = f, .meta_mask = o.meta.toInt(), .threads = o.threads, .max_depth = o.max_depth };
}

fn runCCollect(root_z: [:0]const u8, o: walk.Options) !usize {
    const co = cOpts(o);
    var out: c_lib.zlob_walk_result_t = undefined;
    const rc = c_lib.zlob_walk_collect(root_z.ptr, &co, &out);
    if (rc != 0) {
        std.debug.print("zlob_walk_collect() failed: rc={d}\n", .{rc});
        std.process.exit(4);
    }
    const n = out.count;
    c_lib.zlob_walk_result_free(&out);
    return n;
}

// Per-worker counters on their own cache lines so the streaming modes measure
// the walker, not false sharing in the visitor. effectiveThreads caps at 1024.
const Slot = struct { n: u64 align(64) = 0 };
var slots: [1024]Slot = undefined;

fn resetSlots() void {
    for (&slots) |*s| s.n = 0;
}

fn sumSlots() usize {
    var total: usize = 0;
    for (&slots) |*s| total += s.n;
    return total;
}

fn visitCount(ctx: ?*anyopaque, e: *const walk.Entry) walk.VisitAction {
    _ = ctx;
    slots[e.worker_id].n += 1;
    std.mem.doNotOptimizeAway(e.path.len);
    return .cont;
}

fn runRun(a: std.mem.Allocator, r: []const u8, o: walk.Options) !usize {
    resetSlots();
    const rules = try walk.run(a, r, o, .{ .context = null, .visit = visitCount });
    rules.deinit();
    a.destroy(rules);
    return sumSlots();
}

fn cVisitCount(e: *const c_lib.zlob_walk_entry_t, ctx: ?*anyopaque) callconv(.c) c_int {
    _ = ctx;
    slots[e.worker_id].n += 1;
    std.mem.doNotOptimizeAway(e.path_len);
    return 0;
}

fn runCRun(root_z: [:0]const u8, o: walk.Options) !usize {
    resetSlots();
    const co = cOpts(o);
    var rules: ?*anyopaque = null;
    const rc = c_lib.zlob_walk(root_z.ptr, &co, cVisitCount, null, &rules);
    if (rc != 0) {
        std.debug.print("zlob_walk() failed: rc={d}\n", .{rc});
        std.process.exit(4);
    }
    c_lib.zlob_ignore_rules_free(rules);
    return sumSlots();
}

fn runGlob(pattern: [:0]const u8, flags: c_int) usize {
    var pzlob: c_lib.zlob_t = undefined;
    const rc = c_lib.zlob(pattern.ptr, flags, null, &pzlob);
    if (rc != 0) {
        std.debug.print("zlob() failed: rc={d}\n", .{rc});
        std.process.exit(4);
    }
    const n = pzlob.zlo_pathc;
    c_lib.zlobfree(&pzlob);
    return n;
}
