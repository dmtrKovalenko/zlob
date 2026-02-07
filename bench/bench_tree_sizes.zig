const std = @import("std");
const c_lib = @import("c_lib");
const zlob_flags = @import("zlob_flags");
const posix = std.posix;
const Timer = std.time.Timer;

// libc glob types and functions
extern "c" fn glob(pattern: [*:0]const u8, flags: c_int, errfunc: ?*const anyopaque, pglob: *LibcGlobT) c_int;
extern "c" fn globfree(pglob: *LibcGlobT) void;

const LibcGlobT = extern struct {
    pathc: usize,
    pathv: [*c][*c]u8,
    offs: usize,
};

// --- Tree creation helpers ---

fn createFile(dir: std.fs.Dir, path: []const u8) void {
    // Create parent directories if needed
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    const f = dir.createFile(path, .{}) catch return;
    f.close();
}

fn createDir(dir: std.fs.Dir, path: []const u8) void {
    dir.makePath(path) catch {};
}

const TreeConfig = struct {
    name: []const u8,
    dirs: []const []const u8,
    files: []const []const u8,
};

// Small tree: 10 files in 3 dirs (typical single-module project)
const small_tree = TreeConfig{
    .name = "small",
    .dirs = &.{ "src", "test", "docs" },
    .files = &.{
        "src/main.zig",
        "src/utils.zig",
        "src/lib.zig",
        "test/test_main.zig",
        "test/test_utils.zig",
        "docs/readme.md",
        "build.zig",
        "build.zig.zon",
        "LICENSE",
        "README.md",
    },
};

// Medium tree: ~100 files in ~20 dirs (typical mid-size project)
const medium_dirs = [_][]const u8{
    "src",
    "src/core",
    "src/core/utils",
    "src/net",
    "src/net/http",
    "src/net/tcp",
    "src/io",
    "src/io/fs",
    "src/io/mem",
    "test",
    "test/core",
    "test/net",
    "test/io",
    "docs",
    "docs/api",
    "docs/guides",
    "examples",
    "examples/basic",
    "examples/advanced",
    "bench",
};

fn generateMediumFiles() [100][]const u8 {
    const exts = [_][]const u8{ ".zig", ".zig", ".zig", ".md", ".txt", ".json" };
    const prefixes = [_][]const u8{
        "src/core/main",               "src/core/types",          "src/core/error",
        "src/core/log",                "src/core/config",         "src/core/utils/string",
        "src/core/utils/math",         "src/core/utils/hash",     "src/core/utils/mem",
        "src/core/utils/sort",         "src/net/server",          "src/net/client",
        "src/net/socket",              "src/net/dns",             "src/net/tls",
        "src/net/http/request",        "src/net/http/response",   "src/net/http/headers",
        "src/net/http/router",         "src/net/http/handler",    "src/net/tcp/listener",
        "src/net/tcp/stream",          "src/net/tcp/pool",        "src/net/tcp/buffer",
        "src/net/tcp/timeout",         "src/io/reader",           "src/io/writer",
        "src/io/buffered",             "src/io/stream",           "src/io/poll",
        "src/io/fs/file",              "src/io/fs/dir",           "src/io/fs/path",
        "src/io/fs/watch",             "src/io/fs/lock",          "src/io/mem/alloc",
        "src/io/mem/pool",             "src/io/mem/arena",        "src/io/mem/slab",
        "src/io/mem/gc",               "test/core/test_main",     "test/core/test_types",
        "test/core/test_error",        "test/core/test_log",      "test/core/test_config",
        "test/core/test_string",       "test/core/test_math",     "test/core/test_hash",
        "test/core/test_mem",          "test/core/test_sort",     "test/net/test_server",
        "test/net/test_client",        "test/net/test_socket",    "test/net/test_dns",
        "test/net/test_tls",           "test/net/test_request",   "test/net/test_response",
        "test/net/test_headers",       "test/net/test_router",    "test/net/test_handler",
        "test/net/test_listener",      "test/net/test_stream",    "test/io/test_reader",
        "test/io/test_writer",         "test/io/test_buffered",   "test/io/test_stream",
        "test/io/test_poll",           "test/io/test_file",       "test/io/test_dir",
        "test/io/test_path",           "test/io/test_watch",      "test/io/test_lock",
        "test/io/test_alloc",          "test/io/test_pool",       "test/io/test_arena",
        "test/io/test_slab",           "test/io/test_gc",         "docs/readme",
        "docs/api/core",               "docs/api/net",            "docs/api/io",
        "docs/guides/getting_started", "docs/guides/tutorial",    "docs/guides/advanced",
        "examples/basic/hello",        "examples/basic/echo",     "examples/basic/cat",
        "examples/basic/ls",           "examples/basic/grep",     "examples/advanced/server",
        "examples/advanced/client",    "examples/advanced/proxy", "examples/advanced/pool",
        "examples/advanced/bench",     "bench/bench_core",        "bench/bench_net",
        "bench/bench_io",              "bench/bench_mem",         "bench/bench_fs",
        "build",                       "build.zig",               "LICENSE",
        "README",                      "CHANGELOG",
    };
    var result: [100][]const u8 = undefined;
    for (0..100) |i| {
        const prefix = prefixes[i % prefixes.len];
        const ext = exts[i % exts.len];
        result[i] = prefix ++ ext;
    }
    return result;
}

const medium_files_array = generateMediumFiles();

const medium_tree = TreeConfig{
    .name = "medium",
    .dirs = &medium_dirs,
    .files = &medium_files_array,
};

fn buildTree(base: std.fs.Dir, config: TreeConfig) void {
    for (config.dirs) |d| {
        createDir(base, d);
    }
    for (config.files) |f| {
        createFile(base, f);
    }
}

/// Build a large tree programmatically: ~5000 files across ~200 dirs
fn buildLargeTree(base: std.fs.Dir) void {
    const top_dirs = [_][]const u8{
        "src", "lib", "test", "docs", "bench", "tools", "scripts", "config", "data", "assets",
    };
    const sub_dirs = [_][]const u8{
        "core", "utils", "net", "io",  "fs", "mem",   "log",   "config", "http", "tcp",
        "udp",  "tls",   "dns", "rpc", "db", "cache", "queue", "pool",   "auth", "crypto",
    };
    const exts = [_][]const u8{ ".zig", ".c", ".h", ".md", ".json", ".txt", ".yaml", ".toml" };
    const names = [_][]const u8{
        "main",    "types",  "error",  "log",    "config",  "utils", "string",
        "math",    "hash",   "mem",    "sort",   "search",  "parse", "format",
        "server",  "client", "socket", "stream", "buffer",  "pool",  "queue",
        "handler", "router", "filter", "cache",  "index",   "store", "driver",
        "test",    "bench",  "init",   "close",  "read",    "write", "flush",
        "connect", "listen", "accept", "send",   "recv",    "alloc", "free",
        "create",  "delete", "update", "query",  "execute", "build", "check",
    };

    // Create directory structure
    for (top_dirs) |top| {
        createDir(base, top);
        for (sub_dirs) |sub| {
            var buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ top, sub }) catch continue;
            createDir(base, path);
        }
    }

    // Create ~5000 files
    var count: usize = 0;
    for (top_dirs) |top| {
        for (sub_dirs) |sub| {
            for (names) |name| {
                const ext = exts[count % exts.len];
                var buf: [512]u8 = undefined;
                const path = std.fmt.bufPrint(&buf, "{s}/{s}/{s}{s}", .{ top, sub, name, ext }) catch continue;
                createFile(base, path);
                count += 1;
            }
        }
    }
}

// --- Benchmarking ---

const BenchResult = struct {
    libc_ns: u64,
    zlob_ns: u64,
    libc_count: usize,
    zlob_count: usize,
};

fn benchmarkPattern(pattern_z: [*:0]const u8, iterations: usize) !BenchResult {
    // Warmup: 3 rounds to populate OS caches and stabilize
    for (0..3) |_| {
        var g: LibcGlobT = undefined;
        if (glob(pattern_z, 0, null, &g) == 0) globfree(&g);
        var z: c_lib.zlob_t = undefined;
        if (c_lib.zlob(pattern_z, 0, null, &z) == 0) c_lib.zlobfree(&z);
    }

    // Count matches
    var libc_count: usize = 0;
    {
        var g: LibcGlobT = undefined;
        if (glob(pattern_z, 0, null, &g) == 0) {
            libc_count = g.pathc;
            globfree(&g);
        }
    }
    var zlob_count: usize = 0;
    {
        var z: c_lib.zlob_t = undefined;
        if (c_lib.zlob(pattern_z, 0, null, &z) == 0) {
            zlob_count = z.zlo_pathc;
            c_lib.zlobfree(&z);
        }
    }

    // Benchmark libc
    var libc_timer = try Timer.start();
    for (0..iterations) |_| {
        var g: LibcGlobT = undefined;
        if (glob(pattern_z, 0, null, &g) == 0) globfree(&g);
    }
    const libc_ns = libc_timer.read();

    // Benchmark zlob
    var zlob_timer = try Timer.start();
    for (0..iterations) |_| {
        var z: c_lib.zlob_t = undefined;
        if (c_lib.zlob(pattern_z, 0, null, &z) == 0) c_lib.zlobfree(&z);
    }
    const zlob_ns = zlob_timer.read();

    return .{
        .libc_ns = libc_ns,
        .zlob_ns = zlob_ns,
        .libc_count = libc_count,
        .zlob_count = zlob_count,
    };
}

/// Benchmark zlob-only with custom flags (for recursive ** patterns that libc doesn't support)
fn benchmarkZlobOnly(pattern_z: [*:0]const u8, flags: c_int, iterations: usize) !BenchResult {
    // Warmup
    for (0..3) |_| {
        var z: c_lib.zlob_t = undefined;
        if (c_lib.zlob(pattern_z, flags, null, &z) == 0) c_lib.zlobfree(&z);
    }

    // Count matches
    var zlob_count: usize = 0;
    {
        var z: c_lib.zlob_t = undefined;
        if (c_lib.zlob(pattern_z, flags, null, &z) == 0) {
            zlob_count = z.zlo_pathc;
            c_lib.zlobfree(&z);
        }
    }

    // Benchmark zlob
    var zlob_timer = try Timer.start();
    for (0..iterations) |_| {
        var z: c_lib.zlob_t = undefined;
        if (c_lib.zlob(pattern_z, flags, null, &z) == 0) c_lib.zlobfree(&z);
    }
    const zlob_ns = zlob_timer.read();

    return .{
        .libc_ns = 0,
        .zlob_ns = zlob_ns,
        .libc_count = 0,
        .zlob_count = zlob_count,
    };
}

fn printResult(label: []const u8, pattern: []const u8, r: BenchResult, iterations: usize) void {
    const libc_us = @as(f64, @floatFromInt(r.libc_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0;
    const zlob_us = @as(f64, @floatFromInt(r.zlob_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0;
    const ratio = if (r.zlob_ns > 0) @as(f64, @floatFromInt(r.libc_ns)) / @as(f64, @floatFromInt(r.zlob_ns)) else 0.0;

    const marker = if (ratio >= 1.0) "+" else "-";

    std.debug.print("  {s:<30} {s:<20} matches={d:<5} libc={d:>8.1}us  zlob={d:>8.1}us  {s}{d:.2}x\n", .{
        label,
        pattern,
        r.libc_count,
        libc_us,
        zlob_us,
        marker,
        if (ratio >= 1.0) ratio else 1.0 / ratio,
    });

    if (r.libc_count != r.zlob_count and r.libc_count != 0) {
        std.debug.print("    WARNING: match count mismatch! libc={d} zlob={d}\n", .{ r.libc_count, r.zlob_count });
    }
}

fn printZlobOnly(label: []const u8, pattern: []const u8, r: BenchResult, iterations: usize) void {
    const zlob_us = @as(f64, @floatFromInt(r.zlob_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0;
    std.debug.print("  {s:<30} {s:<20} matches={d:<5}                    zlob={d:>8.1}us\n", .{
        label,
        pattern,
        r.zlob_count,
        zlob_us,
    });
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    _ = allocator;

    // Create temp directory for all test trees
    var tmp_buf: [256]u8 = undefined;
    const pid = std.os.linux.getpid();
    const tmp_base = std.fmt.bufPrint(&tmp_buf, "/tmp/zlob_bench_{d}", .{pid}) catch unreachable;

    var tmp_base_z: [256:0]u8 = undefined;
    @memcpy(tmp_base_z[0..tmp_base.len], tmp_base);
    tmp_base_z[tmp_base.len] = 0;

    // Create base and subtree directories
    const cwd = std.fs.cwd();
    cwd.makePath(tmp_base) catch |e| {
        std.debug.print("Error creating temp dir: {}\n", .{e});
        return;
    };

    var base_dir = cwd.openDir(tmp_base, .{}) catch |e| {
        std.debug.print("Error opening temp dir: {}\n", .{e});
        return;
    };
    defer base_dir.close();

    // Cleanup on exit
    defer {
        cwd.deleteTree(tmp_base) catch {};
    }

    std.debug.print("\n", .{});
    std.debug.print("=== zlob vs libc: Tree Size Scaling Benchmark ===\n", .{});
    std.debug.print("NOTE: Compile with -Doptimize=ReleaseFast for meaningful results\n\n", .{});

    // --- Small tree ---
    std.debug.print("--- Small tree (10 files, 3 dirs) ---\n", .{});
    {
        base_dir.makePath("small") catch {};
        var small_dir = base_dir.openDir("small", .{}) catch return;
        defer small_dir.close();
        buildTree(small_dir, small_tree);

        var path_buf: [512:0]u8 = undefined;
        const prefix = std.fmt.bufPrint(&path_buf, "{s}/small/", .{tmp_base}) catch unreachable;

        posix.chdir(prefix) catch return;

        const small_iters: usize = 10000;
        const patterns = [_][]const u8{ "*.zig", "src/*.zig", "*", "*.md" };
        for (patterns) |pat| {
            var pat_z: [64:0]u8 = undefined;
            @memcpy(pat_z[0..pat.len], pat);
            pat_z[pat.len] = 0;
            const r = try benchmarkPattern(&pat_z, small_iters);
            printResult("small", pat, r, small_iters);
        }
    }

    // --- Medium tree ---
    std.debug.print("\n--- Medium tree (100 files, 20 dirs) ---\n", .{});
    {
        base_dir.makePath("medium") catch {};
        var medium_dir = base_dir.openDir("medium", .{}) catch return;
        defer medium_dir.close();
        buildTree(medium_dir, medium_tree);

        var path_buf: [512:0]u8 = undefined;
        const prefix = std.fmt.bufPrint(&path_buf, "{s}/medium/", .{tmp_base}) catch unreachable;

        posix.chdir(prefix) catch return;

        const medium_iters: usize = 5000;
        const patterns = [_][]const u8{ "*.zig", "src/*.zig", "src/core/*.zig", "test/*/*.zig", "*" };
        for (patterns) |pat| {
            var pat_z: [64:0]u8 = undefined;
            @memcpy(pat_z[0..pat.len], pat);
            pat_z[pat.len] = 0;
            const r = try benchmarkPattern(&pat_z, medium_iters);
            printResult("medium", pat, r, medium_iters);
        }
    }

    // --- Large tree ---
    std.debug.print("\n--- Large tree (~5000 files, ~200 dirs) ---\n", .{});
    {
        base_dir.makePath("large") catch {};
        var large_dir = base_dir.openDir("large", .{}) catch return;
        defer large_dir.close();
        buildLargeTree(large_dir);

        var path_buf: [512:0]u8 = undefined;
        const prefix = std.fmt.bufPrint(&path_buf, "{s}/large/", .{tmp_base}) catch unreachable;

        posix.chdir(prefix) catch return;

        const large_iters: usize = 1000;
        const patterns = [_][]const u8{ "src/core/*.zig", "src/*/*.zig", "*.zig", "src/core/*.c", "*" };
        for (patterns) |pat| {
            var pat_z: [64:0]u8 = undefined;
            @memcpy(pat_z[0..pat.len], pat);
            pat_z[pat.len] = 0;
            const r = try benchmarkPattern(&pat_z, large_iters);
            printResult("large", pat, r, large_iters);
        }
    }

    // --- Recursive patterns (zlob-only, libc doesn't support **) ---
    std.debug.print("\n--- Recursive patterns (zlob only, ** not supported by libc) ---\n", .{});
    {
        const ds_flag: c_int = zlob_flags.ZLOB_DOUBLESTAR_RECURSIVE;

        // Test on small tree
        {
            var path_buf: [512:0]u8 = undefined;
            const prefix = std.fmt.bufPrint(&path_buf, "{s}/small/", .{tmp_base}) catch unreachable;
            posix.chdir(prefix) catch return;

            const iters: usize = 10000;
            const rec_patterns = [_][]const u8{ "**/*.zig", "**/*", "**/*.md" };
            for (rec_patterns) |pat| {
                var pat_z: [64:0]u8 = undefined;
                @memcpy(pat_z[0..pat.len], pat);
                pat_z[pat.len] = 0;
                const r = try benchmarkZlobOnly(&pat_z, ds_flag, iters);
                printZlobOnly("small-recursive", pat, r, iters);
            }
        }

        // Test on medium tree
        {
            var path_buf: [512:0]u8 = undefined;
            const prefix = std.fmt.bufPrint(&path_buf, "{s}/medium/", .{tmp_base}) catch unreachable;
            posix.chdir(prefix) catch return;

            const iters: usize = 5000;
            const rec_patterns = [_][]const u8{ "**/*.zig", "**/*", "**/*.md" };
            for (rec_patterns) |pat| {
                var pat_z: [64:0]u8 = undefined;
                @memcpy(pat_z[0..pat.len], pat);
                pat_z[pat.len] = 0;
                const r = try benchmarkZlobOnly(&pat_z, ds_flag, iters);
                printZlobOnly("medium-recursive", pat, r, iters);
            }
        }

        // Test on large tree
        {
            var path_buf: [512:0]u8 = undefined;
            const prefix = std.fmt.bufPrint(&path_buf, "{s}/large/", .{tmp_base}) catch unreachable;
            posix.chdir(prefix) catch return;

            const iters: usize = 200;
            const rec_patterns = [_][]const u8{ "**/*.zig", "**/*.c", "**/*" };
            for (rec_patterns) |pat| {
                var pat_z: [64:0]u8 = undefined;
                @memcpy(pat_z[0..pat.len], pat);
                pat_z[pat.len] = 0;
                const r = try benchmarkZlobOnly(&pat_z, ds_flag, iters);
                printZlobOnly("large-recursive", pat, r, iters);
            }
        }
    }

    std.debug.print("\n+ = zlob faster, - = libc faster\n", .{});
    std.debug.print("Benchmark complete.\n\n", .{});
}
