//! Parallel walker benchmark shaped like fff's indexing scan:
//! `walk.run` with .gitignore handling and bulk size+mtime metadata, a
//! thread-safe visitor that touches every entry's path and metadata.
//!
//!   bench_walk <root> [--threads N] [--iters N] [--warmup N] [--no-meta]
//!              [--no-git] [--collect] [--quiet]
//!
//! Prints one line per iteration plus min/median, and a checksum (entry
//! counts, total size, path bytes) so two builds can be compared for
//! identical output. For A/B runs build this file against both trees and
//! alternate the binaries (see scripts/bench_walk_ab.sh).
const std = @import("std");
const zlob = @import("zlob");
const walk = zlob.walk;

pub const std_options: std.Options = .{
    .signal_stack_size = null,
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};

const Shard = struct {
    files: u64 = 0,
    dirs: u64 = 0,
    other: u64 = 0,
    size: u64 = 0,
    mtime_xor: u64 = 0,
    path_bytes: u64 = 0,
    path_hash: u64 = 0,
    _pad: [72]u8 = undefined,
};

const Ctx = struct {
    shards: []align(128) Shard,
};

fn visit(context: ?*anyopaque, entry: *const walk.Entry) walk.VisitAction {
    const ctx: *Ctx = @ptrCast(@alignCast(context.?));
    const s = &ctx.shards[entry.worker_id];
    switch (entry.kind) {
        .file => s.files += 1,
        .directory => s.dirs += 1,
        else => s.other += 1,
    }
    const rel = entry.relativePath();
    s.path_bytes += rel.len;
    // Order-independent content checksum: touches every path byte like a
    // consumer copying the path out would.
    s.path_hash +%= std.hash.Wyhash.hash(0, rel);
    if (entry.meta) |m| {
        if (entry.kind == .file) {
            s.size +%= m.size;
            s.mtime_xor ^= @bitCast(m.mtime_ns);
        }
    }
    return .cont;
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();

    var root: ?[]const u8 = null;
    var threads: u16 = 0;
    var iters: usize = 10;
    var warmup: usize = 1;
    var meta: walk.MetaMask = .{ .size = true, .mtime = true };
    var respect_git = true;
    var do_collect = false;
    var quiet = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--threads")) {
            threads = try std.fmt.parseInt(u16, args.next().?, 10);
        } else if (std.mem.eql(u8, a, "--iters")) {
            iters = try std.fmt.parseInt(usize, args.next().?, 10);
        } else if (std.mem.eql(u8, a, "--warmup")) {
            warmup = try std.fmt.parseInt(usize, args.next().?, 10);
        } else if (std.mem.eql(u8, a, "--no-meta")) {
            meta = .{};
        } else if (std.mem.eql(u8, a, "--no-git")) {
            respect_git = false;
        } else if (std.mem.eql(u8, a, "--collect")) {
            do_collect = true;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else {
            root = a;
        }
    }
    const root_path = root orelse {
        std.debug.print("usage: bench_walk <root> [--threads N] [--iters N] [--warmup N] [--no-meta] [--no-git] [--collect] [--quiet]\n", .{});
        return error.MissingRoot;
    };

    const opts: walk.Options = .{
        .threads = threads,
        .meta = meta,
        .respect_git = respect_git,
    };
    const n_workers = walk.effectiveThreads(&opts);
    const shards = try gpa.alignedAlloc(Shard, .fromByteUnits(128), n_workers);
    defer gpa.free(shards);
    var ctx = Ctx{ .shards = shards };

    const times = try gpa.alloc(u64, iters);
    defer gpa.free(times);

    var total: Shard = .{};
    var i: usize = 0;
    while (i < warmup + iters) : (i += 1) {
        for (shards) |*s| s.* = .{};
        const t0 = nowNs();
        if (do_collect) {
            var res = try walk.collect(gpa, root_path, opts);
            for (res.entries) |*e| _ = visit(&ctx, e);
            res.deinit();
        } else {
            const rules = try walk.run(gpa, root_path, opts, .{ .context = &ctx, .visit = visit });
            rules.deinit();
            gpa.destroy(rules);
        }
        const dt = nowNs() - t0;
        total = .{};
        for (shards) |*s| {
            total.files += s.files;
            total.dirs += s.dirs;
            total.other += s.other;
            total.size +%= s.size;
            total.mtime_xor ^= s.mtime_xor;
            total.path_bytes += s.path_bytes;
            total.path_hash +%= s.path_hash;
        }
        if (i >= warmup) {
            times[i - warmup] = dt;
            if (!quiet) std.debug.print("  iter {d:>2}: {d:>9.3} ms\n", .{ i - warmup, @as(f64, @floatFromInt(dt)) / 1e6 });
        }
    }

    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    const min = times[0];
    const med = times[times.len / 2];
    var sum: u64 = 0;
    for (times) |t| sum += t;
    std.debug.print(
        "workers={d} files={d} dirs={d} other={d} size={d} path_bytes={d} hash={x} mtime={x}\n",
        .{ n_workers, total.files, total.dirs, total.other, total.size, total.path_bytes, total.path_hash, total.mtime_xor },
    );
    std.debug.print("min={d:.3}ms median={d:.3}ms mean={d:.3}ms\n", .{
        @as(f64, @floatFromInt(min)) / 1e6,
        @as(f64, @floatFromInt(med)) / 1e6,
        @as(f64, @floatFromInt(sum / times.len)) / 1e6,
    });
}
