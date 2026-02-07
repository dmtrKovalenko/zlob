const std = @import("std");
const zlob = @import("zlob");
const build_options = @import("build_options");
const posix = std.posix;
const fs = std.fs;
const Io = std.Io;

const version = build_options.version;

const Options = struct {
    pattern: ?[]const u8 = null,
    path: ?[]const u8 = null,
    show_all: bool = false,
    mark_dirs: bool = false,
    sorted: bool = false,
    no_escape: bool = false,
    no_brace: bool = false,
    no_gitignore: bool = false,
    hidden: bool = false,
    dirs_only: bool = false,
    show_help: bool = false,
    show_version: bool = false,
    limit: usize = 100,
};

const BufferedWriter = struct {
    file_writer: fs.File.Writer,

    fn init(handle: posix.fd_t, buf: []u8) BufferedWriter {
        const file = fs.File{ .handle = handle };
        return .{ .file_writer = file.writer(buf) };
    }

    fn writer(self: *BufferedWriter) *Io.Writer {
        return &self.file_writer.interface;
    }

    fn flush(self: *BufferedWriter) void {
        self.file_writer.interface.flush() catch {};
    }
};

fn printVersion(w: *Io.Writer) void {
    w.print("zlob {s}\n", .{version}) catch {};
}

fn printHelp(w: *Io.Writer, program_name: []const u8) void {
    w.print(
        \\{s} - A fast SIMD-accelerated glob pattern matcher
        \\
        \\USAGE:
        \\    {s} [OPTIONS] <PATTERN> [PATH]
        \\
        \\ARGS:
        \\    <PATTERN>    Glob pattern to match (e.g., '**/*.zig', 'src/*.c')
        \\    [PATH]       Directory to search (default: current directory)
        \\
        \\OPTIONS:
        \\    -a, --all            Show all results (default: first 100)
        \\    -n, --limit <NUM>    Limit results to NUM entries (default: 100)
        \\    -H, --hidden         Include hidden files (match files starting with '.')
        \\    -d, --dirs-only      Only match directories
        \\    -m, --mark           Append '/' to directory names
        \\    -E, --no-escape      Treat backslash as literal character
        \\    -s, --sorted         Sort results alphabetically (default: unsorted)
        \\    -B, --no-brace       Disable brace expansion (default: enabled)
        \\    -G, --no-gitignore   Don't respect .gitignore rules (default: enabled)
        \\    -h, --help           Print help information
        \\    -V, --version        Print version information
        \\
        \\PATTERN SYNTAX:
        \\    *            Match any sequence of characters (except '/')
        \\    **           Match any sequence including '/' (recursive)
        \\    ?            Match any single character
        \\    [abc]        Match any character in the set
        \\    [a-z]        Match any character in the range
        \\    [!abc]       Match any character NOT in the set
        \\    {{a,b,c}}      Match any of the comma-separated patterns
        \\
        \\EXAMPLES:
        \\    {s} '**/*.zig'              Find all .zig files recursively
        \\    {s} '*.txt' /path/to/dir    Find .txt files in specified directory
        \\    {s} -G '**/*.ts'            Find .ts files, ignoring .gitignore
        \\    {s} -a '**/*'               List all files (no limit)
        \\    {s} -n 50 '**/*.c'          Show first 50 .c files
        \\    {s} 'src/*.{{c,h}}'           Find .c and .h files in src/
        \\
    , .{ program_name, program_name, program_name, program_name, program_name, program_name, program_name, program_name }) catch {};
}

fn parseArgs(allocator: std.mem.Allocator, stderr: *Io.Writer) !Options {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var opts = Options{};
    const program_name = args.next() orelse "zlob";
    _ = program_name;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                opts.show_help = true;
            } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
                opts.show_version = true;
            } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
                opts.show_all = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--limit")) {
                const limit_str = args.next() orelse {
                    return error.MissingArgument;
                };
                opts.limit = std.fmt.parseInt(usize, limit_str, 10) catch {
                    return error.InvalidNumber;
                };
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--mark")) {
                opts.mark_dirs = true;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sorted")) {
                opts.sorted = true;
            } else if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--no-escape")) {
                opts.no_escape = true;
            } else if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--no-brace")) {
                opts.no_brace = true;
            } else if (std.mem.eql(u8, arg, "-G") or std.mem.eql(u8, arg, "--no-gitignore")) {
                opts.no_gitignore = true;
            } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--hidden")) {
                opts.hidden = true;
            } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--dirs-only")) {
                opts.dirs_only = true;
            } else {
                stderr.print("error: unknown option '{s}'\n", .{arg}) catch {};
                stderr.print("For more information, try '--help'\n", .{}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            }
        } else {
            // Positional argument
            if (opts.pattern == null) {
                opts.pattern = arg;
            } else if (opts.path == null) {
                opts.path = arg;
            } else {
                stderr.print("error: unexpected argument '{s}'\n", .{arg}) catch {};
                stderr.print("For more information, try '--help'\n", .{}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            }
        }
    }

    return opts;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // Buffered writers for stdout and stderr
    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = BufferedWriter.init(posix.STDOUT_FILENO, &stdout_buf);
    var stderr_writer = BufferedWriter.init(posix.STDERR_FILENO, &stderr_buf);
    const stdout = stdout_writer.writer();
    const stderr = stderr_writer.writer();

    const opts = parseArgs(allocator, stderr) catch |err| {
        switch (err) {
            error.MissingArgument => stderr.print("error: option requires an argument\n", .{}) catch {},
            error.InvalidNumber => stderr.print("error: invalid number for --limit\n", .{}) catch {},
        }
        stderr_writer.flush();
        std.process.exit(1);
    };

    if (opts.show_version) {
        printVersion(stdout);
        stdout_writer.flush();
        return;
    }

    if (opts.show_help) {
        printHelp(stdout, "zlob");
        stdout_writer.flush();
        return;
    }

    const pattern = opts.pattern orelse {
        printHelp(stderr, "zlob");
        stderr_writer.flush();
        std.process.exit(1);
    };

    var full_pattern: []const u8 = undefined;
    if (opts.path) |path| {
        // Combine path and pattern
        const trimmed_path = std.mem.trimRight(u8, path, "/");
        full_pattern = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_path, pattern });
    } else {
        full_pattern = pattern;
    }

    // Start with recommended settings, then apply CLI options
    var flags = zlob.ZlobFlags.recommended();
    flags.nosort = !opts.sorted;
    flags.brace = !opts.no_brace;
    flags.gitignore = !opts.no_gitignore;
    flags.mark = opts.mark_dirs;
    flags.noescape = opts.no_escape;
    flags.period = opts.hidden;
    flags.onlydir = opts.dirs_only;
    flags.nomagic = false; // always enable magic, since we require a pattern argument
    _ = &flags; // suppress unused warning if match accepts anytype

    var match_result = zlob.match(allocator, full_pattern, flags) catch |err| {
        stderr.print("error: glob failed: {}\n", .{err}) catch {};
        stderr_writer.flush();
        std.process.exit(1);
    };

    if (match_result) |*result| {
        defer result.deinit();

        const total = result.len();
        const display_limit = if (opts.show_all) total else @min(opts.limit, total);

        var displayed: usize = 0;
        var it = result.iterator();
        while (it.next()) |path| {
            if (displayed >= display_limit) break;
            stdout.print("{s}\n", .{path}) catch {};
            displayed += 1;
        }

        stdout_writer.flush();

        if (!opts.show_all and total > opts.limit) {
            stderr.print("\n... and {d} more ({d} total). Use -a to show all.\n", .{ total - opts.limit, total }) catch {};
            stderr_writer.flush();
        }
    } else {
        std.process.exit(1);
    }
}
