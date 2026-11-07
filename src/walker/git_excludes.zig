//! Git's repository-wide exclude sources, layered under the per-directory
//! `.gitignore` chain wherever the walker meets a `.git` entry:
//!
//!   - `$GIT_DIR/info/exclude`: repo-local rules that are never committed. A
//!     linked worktree (`.git` is a file holding `gitdir: <path>`) shares the
//!     main repository's copy through `<gitdir>/commondir`, resolved the way
//!     git does it; a submodule checkout gets its own under `.git/modules/`.
//!   - `core.excludesFile`: taken from the repository config
//!     (`<commondir>/config`), else the global config (`~/.gitconfig` wins
//!     over `$XDG_CONFIG_HOME/git/config`, `GIT_CONFIG_GLOBAL` replaces both),
//!     defaulting to `$XDG_CONFIG_HOME/git/ignore` (`~/.config/git/ignore`).
//!     An empty value disables it; a relative path is relative to the
//!     worktree root, as git runs from there. The system config and
//!     `[include]` directives are not consulted (the `ignore` crate behaves
//!     the same).
//!
//! Precedence follows gitignore(5), lowest first: `core.excludesFile`,
//! `info/exclude`, the `.gitignore` next to `.git`, then every deeper
//! `.gitignore`. The worker parses the first three into the one `IgnoreNode`
//! of the repository root in that order, so last-match-wins inside the node
//! lets `.gitignore` override the exclude files, while the chain lets deeper
//! files override all of them: a `!negation` anywhere behaves as in git.
//!
//! Nothing here can fail: an unreadable or missing file is simply absent.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// Raw open/read where the walker's own backends use them (Linux, macOS with
/// libc); `std.Io` elsewhere. Kept local so this file stands alone.
const posix_reads = builtin.os.tag == .linux or (builtin.os.tag == .macos and builtin.link_libc);

/// Same cap `.gitignore` reads use.
pub const max_file_size = 1024 * 1024;

/// What the directory listing said about a `.git` entry.
pub const DotGit = enum {
    /// A repository directory: `.git` is the commondir.
    directory,
    /// A `gitdir:` pointer file (linked worktree, submodule).
    file,
    /// Symlink or a listing without a usable kind: stat to find out.
    unknown,

    pub fn fromKind(kind: std.Io.File.Kind) DotGit {
        return switch (kind) {
            .directory => .directory,
            .file => .file,
            else => .unknown,
        };
    }
};

/// Exclude documents of one repository root, owned, ready for
/// `GitIgnore.parseOwnedMulti` in field order (lowest precedence first).
pub const Docs = struct {
    excludes_file: ?[]u8 = null,
    info_exclude: ?[]u8 = null,

    pub fn count(self: Docs) usize {
        return @as(usize, @intFromBool(self.excludes_file != null)) + @intFromBool(self.info_exclude != null);
    }

    pub fn deinit(self: Docs, gpa: Allocator) void {
        if (self.excludes_file) |b| gpa.free(b);
        if (self.info_exclude) |b| gpa.free(b);
    }
};

/// Per-walk, thread-safe. Everything it reads is memoized: a repository's
/// `info/exclude` and `core.excludesFile` setting once per commondir (shared
/// by all its linked worktrees), every excludes file once per path (the
/// global one once per walk however many repositories use it). A cache hit
/// is a map lookup plus copies, so the lock is held briefly. Nothing is read
/// before the first `load`: a tree without a repository never touches the
/// home directory.
pub const Resolver = struct {
    gpa: Allocator,
    io: std.Io,
    want_exclude: bool,
    want_global: bool,
    mutex: std.Io.Mutex = .init,
    /// commondir -> what the repository itself says.
    repos: std.StringHashMapUnmanaged(Repo) = .empty,
    /// excludes file path -> contents; null when missing or rule-free.
    files: std.StringHashMapUnmanaged(?[]u8) = .empty,
    /// The global `core.excludesFile` setting (see `excludesFileSetting`),
    /// already defaulted to `$XDG_CONFIG_HOME/git/ignore`. Valid once
    /// `global_resolved`; tests may preset both.
    global: ?[]u8 = null,
    global_resolved: bool = false,

    const Repo = struct {
        info_exclude: ?[]u8,
        /// `core.excludesFile` from the repository config: null when unset,
        /// "" when disabled.
        excludes_setting: ?[]u8,
    };

    pub fn init(gpa: Allocator, io: std.Io, want_exclude: bool, want_global: bool) Resolver {
        return .{ .gpa = gpa, .io = io, .want_exclude = want_exclude, .want_global = want_global };
    }

    pub fn enabled(r: *const Resolver) bool {
        return r.want_exclude or r.want_global;
    }

    pub fn deinit(r: *Resolver) void {
        const gpa = r.gpa;
        var repos = r.repos.iterator();
        while (repos.next()) |e| {
            gpa.free(e.key_ptr.*);
            if (e.value_ptr.info_exclude) |b| gpa.free(b);
            if (e.value_ptr.excludes_setting) |b| gpa.free(b);
        }
        r.repos.deinit(gpa);
        var files = r.files.iterator();
        while (files.next()) |e| {
            gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |b| gpa.free(b);
        }
        r.files.deinit(gpa);
        if (r.global) |g| gpa.free(g);
        r.* = undefined;
    }

    /// Exclude documents for the repository whose worktree root is `dir`
    /// ("." for the cwd), where `dot_git` describes `dir/.git`. Empty when
    /// `.git` is not a repository.
    pub fn load(r: *Resolver, dir: []const u8, dot_git: DotGit) Docs {
        const gpa = r.gpa;
        const common = resolveCommonDir(gpa, r.io, dir, dot_git) orelse return .{};

        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);

        const gop = r.repos.getOrPut(gpa, common) catch {
            gpa.free(common);
            return .{};
        };
        if (gop.found_existing) {
            gpa.free(common);
        } else {
            gop.value_ptr.* = .{
                .info_exclude = if (r.want_exclude) readDoc(gpa, r.io, &.{ common, "info", "exclude" }) else null,
                .excludes_setting = if (r.want_global) settingFromFile(gpa, r.io, &.{ common, "config" }) else null,
            };
        }
        const repo = gop.value_ptr.*;

        return .{
            .info_exclude = if (repo.info_exclude) |b| gpa.dupe(u8, b) catch null else null,
            .excludes_file = if (r.want_global) r.loadExcludesFile(dir, repo.excludes_setting) else null,
        };
    }

    /// User excludes for a .jj boundary without its own Git config.
    pub fn loadGlobal(r: *Resolver, dir: []const u8) Docs {
        if (!r.want_global) return .{};
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        return .{ .excludes_file = r.loadExcludesFile(dir, null) };
    }

    /// Called with the cache locked. A repository-level value replaces the
    /// global one, even when the named file is missing or the value is empty.
    fn loadExcludesFile(r: *Resolver, dir: []const u8, repo_setting: ?[]const u8) ?[]u8 {
        const path = repo_setting orelse r.globalSetting() orelse return null;
        if (path.len == 0) return null;
        const doc = r.excludesFile(dir, path) orelse return null;
        return r.gpa.dupe(u8, doc) catch null;
    }

    fn globalSetting(r: *Resolver) ?[]const u8 {
        if (!r.global_resolved) {
            r.global = resolveGlobalSetting(r.gpa, r.io);
            r.global_resolved = true;
        }
        return r.global;
    }

    /// Memoized contents of the excludes file `path`, relative to the
    /// worktree root `dir` unless absolute. Borrowed.
    fn excludesFile(r: *Resolver, dir: []const u8, path: []const u8) ?[]const u8 {
        const gpa = r.gpa;
        // The common case, an absolute path, is a lookup without allocating.
        if (std.fs.path.isAbsolute(path)) {
            if (r.files.get(path)) |content| return content;
        }
        const key = std.fs.path.resolve(gpa, &.{ dir, path }) catch return null;
        const gop = r.files.getOrPut(gpa, key) catch {
            gpa.free(key);
            return null;
        };
        if (gop.found_existing) {
            gpa.free(key);
        } else {
            gop.value_ptr.* = readDoc(gpa, r.io, &.{key});
        }
        return gop.value_ptr.*;
    }
};

/// An ignore document at `std.fs.path.resolve(parts)`, or null when it is
/// missing or holds no rules: the `git init` template leaves a comments-only
/// info/exclude in every repository, and parsing it would buy an empty
/// matcher.
fn readDoc(gpa: Allocator, io: std.Io, parts: []const []const u8) ?[]u8 {
    const path = std.fs.path.resolve(gpa, parts) catch return null;
    defer gpa.free(path);
    const content = readFile(gpa, io, path) orelse return null;
    if (hasRules(content)) return content;
    gpa.free(content);
    return null;
}

/// `<gitdir>/commondir` resolved for `dir/.git`: the directory itself when
/// `.git` is a directory, else the target of its `gitdir:` pointer, else that
/// target's `commondir` file (linked worktrees). Owned by the caller; null
/// when `dir/.git` is not a repository.
pub fn resolveCommonDir(gpa: Allocator, io: std.Io, dir: []const u8, dot_git: DotGit) ?[]u8 {
    const dot = std.fs.path.join(gpa, &.{ dir, ".git" }) catch return null;
    var kind = dot_git;
    if (kind == .unknown) {
        const st = std.Io.Dir.cwd().statFile(io, dot, .{}) catch {
            gpa.free(dot);
            return null;
        };
        kind = switch (st.kind) {
            .directory => .directory,
            .file => .file,
            else => {
                gpa.free(dot);
                return null;
            },
        };
    }
    if (kind == .directory) return dot;
    defer gpa.free(dot);

    // `.git` file: "gitdir: <path>", relative to `dir` or absolute.
    const pointer = readFile(gpa, io, dot) orelse return null;
    defer gpa.free(pointer);
    const target = gitdirPointerTarget(pointer) orelse return null;
    const gitdir = std.fs.path.resolve(gpa, &.{ dir, target }) catch return null;

    // A linked worktree's private gitdir names the shared one in `commondir`.
    const commondir_file = std.fs.path.join(gpa, &.{ gitdir, "commondir" }) catch {
        gpa.free(gitdir);
        return null;
    };
    defer gpa.free(commondir_file);
    const commondir_ptr = readFile(gpa, io, commondir_file) orelse return gitdir;
    defer gpa.free(commondir_ptr);
    const common_rel = mem.trim(u8, commondir_ptr, " \t\r\n");
    if (common_rel.len == 0) return gitdir;
    defer gpa.free(gitdir);
    return std.fs.path.resolve(gpa, &.{ gitdir, common_rel }) catch null;
}

/// The path after `gitdir:` in a `.git` file, or null when the file is
/// something else entirely.
pub fn gitdirPointerTarget(content: []const u8) ?[]const u8 {
    const first_line = mem.sliceTo(content, '\n');
    const trimmed = mem.trim(u8, first_line, " \t\r");
    if (!mem.startsWith(u8, trimmed, "gitdir:")) return null;
    const target = mem.trim(u8, trimmed["gitdir:".len..], " \t\r");
    return if (target.len == 0) null else target;
}

/// The global `core.excludesFile` setting: `GIT_CONFIG_GLOBAL`, else
/// `$XDG_CONFIG_HOME/git/config` overridden by `~/.gitconfig`; when neither
/// sets it, the default `$XDG_CONFIG_HOME/git/ignore`. Owned; "" when
/// explicitly disabled, null when the environment gives no location.
pub fn resolveGlobalSetting(gpa: Allocator, io: std.Io) ?[]u8 {
    const home = homeDir(gpa);
    defer if (home) |h| gpa.free(h);
    const xdg: ?[]u8 = getEnvAlloc(gpa, "XDG_CONFIG_HOME") orelse
        if (home) |h| (std.fs.path.join(gpa, &.{ h, ".config" }) catch null) else null;
    defer if (xdg) |x| gpa.free(x);

    var setting: ?[]u8 = null;
    if (getEnvAlloc(gpa, "GIT_CONFIG_GLOBAL")) |explicit| {
        defer gpa.free(explicit);
        setting = settingFromFile(gpa, io, &.{explicit});
    } else {
        // Later files override earlier ones, like git's own read order.
        if (xdg) |x| setting = settingFromFile(gpa, io, &.{ x, "git", "config" });
        if (home) |h| {
            if (settingFromFile(gpa, io, &.{ h, ".gitconfig" })) |s| {
                if (setting) |old| gpa.free(old);
                setting = s;
            }
        }
    }
    if (setting) |s| return s;
    const x = xdg orelse return null;
    return std.fs.path.join(gpa, &.{ x, "git", "ignore" }) catch null;
}

fn settingFromFile(gpa: Allocator, io: std.Io, parts: []const []const u8) ?[]u8 {
    const path = std.fs.path.join(gpa, parts) catch return null;
    defer gpa.free(path);
    const config = readFile(gpa, io, path) orelse return null;
    defer gpa.free(config);
    return excludesFileSetting(gpa, config);
}

/// The last `core.excludesFile` value in a git config document, owned, with
/// quotes and escapes removed and a leading `~/` expanded. null when the key
/// is absent; "" when it is set to nothing (git then reads no excludes file)
/// or names a `~user/` path, which would need a passwd lookup.
pub fn excludesFileSetting(gpa: Allocator, config: []const u8) ?[]u8 {
    const raw = excludesFileValue(config) orelse return null;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    unquoteValue(gpa, &buf, raw) catch return null;
    const v = buf.items;
    if (v.len > 0 and v[0] == '~') {
        if (v.len > 1 and !std.fs.path.isSep(v[1])) return gpa.dupe(u8, "") catch null;
        const home = homeDir(gpa) orelse return gpa.dupe(u8, "") catch null;
        defer gpa.free(home);
        return mem.concat(gpa, u8, &.{ home, v[1..] }) catch null;
    }
    return buf.toOwnedSlice(gpa) catch null;
}

/// Raw (still quoted/escaped) value of the last `excludesfile` key inside a
/// plain `[core]` section.
fn excludesFileValue(config: []const u8) ?[]const u8 {
    var in_core = false;
    var found: ?[]const u8 = null;
    var lines = mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw_line| {
        var line = mem.trim(u8, raw_line, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            const close = mem.indexOfScalar(u8, line, ']') orelse {
                in_core = false;
                continue;
            };
            // `[core "sub"]` is not where excludesFile lives.
            in_core = std.ascii.eqlIgnoreCase(mem.trim(u8, line[1..close], " \t"), "core");
            // A setting may follow the header on the same line.
            line = mem.trimStart(u8, line[close + 1 ..], " \t");
        }
        if (!in_core or line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(mem.trim(u8, line[0..eq], " \t"), "excludesfile")) continue;
        found = mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return found;
}

/// git-config value syntax: optional double quotes, `\\` `\"` `\n` `\t`
/// escapes, and an unquoted `#`/`;` starting a trailing comment.
fn unquoteValue(gpa: Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    var quoted = false;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        switch (c) {
            '"' => quoted = !quoted,
            '\\' => {
                if (i + 1 >= raw.len) break;
                i += 1;
                try out.append(gpa, switch (raw[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'b' => 8,
                    else => |e| e,
                });
            },
            '#', ';' => {
                if (!quoted) break;
                try out.append(gpa, c);
            },
            else => try out.append(gpa, c),
        }
    }
    // Whitespace before a stripped comment is not part of the value.
    while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t')) {
        out.items.len -= 1;
    }
}

/// True when at least one line is neither blank nor a `#` comment.
pub fn hasRules(doc: []const u8) bool {
    var lines = mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] != '#') return true;
    }
    return false;
}

/// Whole file (symlinks followed), or null when missing, unreadable,
/// oversized or empty. Paths are relative to the cwd, like the walk root.
fn readFile(gpa: Allocator, io: std.Io, path: []const u8) ?[]u8 {
    if (posix_reads) {
        const path_z = posix.toPosixPath(path) catch return null;
        // NONBLOCK: a FIFO named by a config must not hang the walk.
        const fd = posix.openatZ(posix.AT.FDCWD, &path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, 0) catch return null;
        defer switch (builtin.os.tag) {
            .linux => _ = std.os.linux.close(fd),
            else => _ = std.c.close(fd),
        };
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        list.ensureTotalCapacity(gpa, 4096) catch return null;
        while (true) {
            if (list.unusedCapacitySlice().len == 0) {
                if (list.items.len >= max_file_size) return null;
                list.ensureUnusedCapacity(gpa, list.items.len) catch return null;
            }
            const n = posix.read(fd, list.unusedCapacitySlice()) catch return null;
            if (n == 0) break;
            list.items.len += n;
        }
        if (list.items.len == 0) return null;
        return list.toOwnedSlice(gpa) catch null;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_size)) catch return null;
    if (bytes.len == 0) {
        gpa.free(bytes);
        return null;
    }
    return bytes;
}

/// `$HOME`, falling back to `%USERPROFILE%` on Windows like git for Windows.
fn homeDir(gpa: Allocator) ?[]u8 {
    if (getEnvAlloc(gpa, "HOME")) |h| return h;
    if (builtin.os.tag == .windows) return getEnvAlloc(gpa, "USERPROFILE");
    return null;
}

/// Owned copy of an environment variable; null when unset, empty, or when
/// the build has no way to read the environment (no libc off Windows).
fn getEnvAlloc(gpa: Allocator, name: [:0]const u8) ?[]u8 {
    if (builtin.link_libc) {
        const ptr = std.c.getenv(name.ptr) orelse return null;
        const value = mem.sliceTo(ptr, 0);
        if (value.len == 0) return null;
        return gpa.dupe(u8, value) catch null;
    }
    if (builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        const value = environ.getAlloc(gpa, name) catch return null;
        if (value.len == 0) {
            gpa.free(value);
            return null;
        }
        return value;
    }
    return null;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "gitdirPointerTarget parses .git files" {
    try testing.expectEqualStrings("/repo/.git/worktrees/wt", gitdirPointerTarget("gitdir: /repo/.git/worktrees/wt\n").?);
    try testing.expectEqualStrings("../.git/modules/sub", gitdirPointerTarget("gitdir:../.git/modules/sub").?);
    try testing.expect(gitdirPointerTarget("ref: refs/heads/main\n") == null);
    try testing.expect(gitdirPointerTarget("gitdir: \n") == null);
    try testing.expect(gitdirPointerTarget("") == null);
}

test "hasRules ignores blank and comment lines" {
    try testing.expect(!hasRules(""));
    try testing.expect(!hasRules("# git ls-files --others --exclude-from=.git/info/exclude\n# Lines that start with '#' are comments.\n\n"));
    try testing.expect(hasRules("# c\n*.log\n"));
    try testing.expect(hasRules("\\#literal\n"));
}

fn expectSetting(expected: ?[]const u8, config: []const u8) !void {
    const got = excludesFileSetting(testing.allocator, config);
    defer if (got) |g| testing.allocator.free(g);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(e, got.?);
    } else try testing.expect(got == null);
}

test "excludesFileSetting: core section only, last wins, git value syntax" {
    try expectSetting("/with space/ignore", "[user]\n\tname = x\n\texcludesfile = /wrong\n" ++
        "[core]\n\tautocrlf = false\n\tExcludesFile = /first # comment\n" ++
        "[CORE]\n\texcludesFile = \"/with space/ignore\" ; trailing\n" ++
        "[core \"sub\"]\n\texcludesfile = /not-core\n");
    try expectSetting(null, "[core]\n\tbare = false\n");
    try expectSetting(null, "");
    try expectSetting("a\\b\"c", "[core]\nexcludesfile = a\\\\b\\\"c\n");
    // a setting on the header line, as git accepts it
    try expectSetting("/inline", "[core] excludesFile = /inline\n");
    try expectSetting(null, "[user] excludesFile = /inline\n");
    // empty disables (git then reads no excludes file at all)
    try expectSetting("", "[core]\n\texcludesFile =\n");
    try expectSetting("", "[core]\n\texcludesFile = \"\"\n");
    // relative paths are kept relative; the resolver anchors them
    try expectSetting(".git/local-ignore", "[core]\nexcludesfile = .git/local-ignore\n");
    // ~user needs a passwd lookup: treated as naming no readable file
    try expectSetting("", "[core]\nexcludesfile = ~bob/ignore\n");
}

test "excludesFileSetting expands a leading ~/" {
    const gpa = testing.allocator;
    const home = homeDir(gpa) orelse return error.SkipZigTest;
    defer gpa.free(home);
    const got = excludesFileSetting(gpa, "[core]\nexcludesfile = ~/.gitignore_global\n").?;
    defer gpa.free(got);
    try testing.expect(mem.startsWith(u8, got, home));
    try testing.expect(mem.endsWith(u8, got, ".gitignore_global"));
}

const Fixture = struct {
    io: std.Io,
    root_buf: [128]u8 = undefined,
    root: []const u8 = &.{},
    path_buf: [512]u8 = undefined,

    fn init(f: *Fixture) !void {
        f.io = std.Io.Threaded.global_single_threaded.io();
        f.root = try std.fmt.bufPrint(&f.root_buf, ".zig-cache/walk-tests/git_excludes_{d}", .{std.Io.Timestamp.now(f.io, .real).toNanoseconds()});
        try std.Io.Dir.cwd().createDirPath(f.io, f.root);
    }

    fn deinit(f: *Fixture) void {
        std.Io.Dir.cwd().deleteTree(f.io, f.root) catch {};
    }

    fn path(f: *Fixture, rel: []const u8) []const u8 {
        return std.fmt.bufPrint(&f.path_buf, "{s}/{s}", .{ f.root, rel }) catch unreachable;
    }

    fn mkdir(f: *Fixture, rel: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(f.io, f.path(rel));
    }

    fn write(f: *Fixture, rel: []const u8, data: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(f.io, .{ .sub_path = f.path(rel), .data = data });
    }
};

fn resolverWithGlobal(io: std.Io, global: ?[]const u8) !Resolver {
    var r = Resolver.init(testing.allocator, io, true, true);
    r.global = if (global) |g| try testing.allocator.dupe(u8, g) else null;
    r.global_resolved = true;
    return r;
}

fn expectDocs(r: *Resolver, f: *Fixture, dir: []const u8, dot_git: DotGit, info: ?[]const u8, excludes: ?[]const u8) !void {
    var dir_buf: [256]u8 = undefined;
    const d = try std.fmt.bufPrint(&dir_buf, "{s}", .{f.path(dir)});
    const docs = r.load(d, dot_git);
    defer docs.deinit(testing.allocator);
    if (info) |e| try testing.expectEqualStrings(e, docs.info_exclude orelse return error.MissingInfoExclude) else try testing.expect(docs.info_exclude == null);
    if (excludes) |e| try testing.expectEqualStrings(e, docs.excludes_file orelse return error.MissingExcludesFile) else try testing.expect(docs.excludes_file == null);
}

test "Resolver: repo config and relative worktree and submodule pointers" {
    var f: Fixture = .{ .io = undefined };
    try f.init();
    defer f.deinit();

    try f.mkdir("main/.git/info");
    try f.mkdir("main/.git/worktrees/wt");
    try f.write("main/.git/info/exclude", "# comment\nexcluded/\n");
    // relative: anchored at each worktree root, as git runs from there
    try f.write("main/.git/config", "[core]\n\texcludesfile = local-ignore\n");
    try f.write("main/local-ignore", "*.main\n");
    try f.write("main/.git/worktrees/wt/commondir", "../..\n");
    try f.mkdir("wt");
    try f.write("wt/.git", "gitdir: ../main/.git/worktrees/wt\n");
    try f.write("wt/local-ignore", "*.wt\n");
    try f.mkdir("main/.git/modules/sub/info");
    try f.write("main/.git/modules/sub/info/exclude", "*.sub\n");
    try f.mkdir("main/sub");
    try f.write("main/sub/.git", "gitdir: ../.git/modules/sub\n");
    try f.mkdir("bogus");
    try f.write("bogus/.git", "hello\n");
    try f.mkdir("plain/.git/info");
    try f.write("plain/.git/info/exclude", "# only the git init template\n");

    var r = try resolverWithGlobal(f.io, "/nonexistent/global-ignore");
    defer r.deinit();
    try expectDocs(&r, &f, "main", .directory, "# comment\nexcluded/\n", "*.main\n");
    // the listing's kind is only a hint; .unknown stats
    try expectDocs(&r, &f, "main", .unknown, "# comment\nexcluded/\n", "*.main\n");
    // shared info/exclude and config, but its own relative excludes file
    try expectDocs(&r, &f, "wt", .file, "# comment\nexcluded/\n", "*.wt\n");
    try expectDocs(&r, &f, "wt", .unknown, "# comment\nexcluded/\n", "*.wt\n");
    try expectDocs(&r, &f, "main/sub", .file, "*.sub\n", null);
    try expectDocs(&r, &f, "bogus", .file, null, null);
    try expectDocs(&r, &f, "missing", .unknown, null, null);
    // comments-only template: no document; no repo setting: global (missing)
    try expectDocs(&r, &f, "plain", .directory, null, null);
}

test "Resolver: global fallback, empty value disables, flags" {
    var f: Fixture = .{ .io = undefined };
    try f.init();
    defer f.deinit();

    try f.mkdir("repo/.git");
    try f.write("global-ignore", "*.global\n");
    // relative like any other setting: anchored at the worktree root
    const global = "../global-ignore";

    {
        // no repo config: the global document applies
        var r = try resolverWithGlobal(f.io, global);
        defer r.deinit();
        try expectDocs(&r, &f, "repo", .directory, null, "*.global\n");
    }
    {
        // a repo value naming a missing file still replaces the global one
        try f.write("repo/.git/config", "[core]\n\texcludesFile = /nonexistent/x\n");
        var r = try resolverWithGlobal(f.io, global);
        defer r.deinit();
        try expectDocs(&r, &f, "repo", .directory, null, null);
    }
    {
        // an empty repo value disables excludes files entirely
        try f.write("repo/.git/config", "[core]\n\texcludesFile =\n");
        var r = try resolverWithGlobal(f.io, global);
        defer r.deinit();
        try expectDocs(&r, &f, "repo", .directory, null, null);
    }
    {
        // an empty global value disables the default location too
        try f.write("repo/.git/config", "[core]\n\tbare = false\n");
        var r = try resolverWithGlobal(f.io, "");
        defer r.deinit();
        try expectDocs(&r, &f, "repo", .directory, null, null);
    }
    {
        try f.mkdir("repo/.git/info");
        try f.write("repo/.git/info/exclude", "*.info\n");
        var r = Resolver.init(testing.allocator, f.io, false, false);
        defer r.deinit();
        try testing.expect(!r.enabled());
        try expectDocs(&r, &f, "repo", .directory, null, null);
        var only_exclude = Resolver.init(testing.allocator, f.io, true, false);
        defer only_exclude.deinit();
        try expectDocs(&only_exclude, &f, "repo", .directory, "*.info\n", null);
    }
}
