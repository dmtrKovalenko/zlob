//! SIMD-accelerated glob pattern matching library
//!
//! This library provides high-performance file pattern matching (globbing) using
//! SIMD optimizations for improved performance on pattern matching operations.
//!
//! Based on the OpenBSD glob implementation with modern SIMD enhancements.
//!
//! This is the pure Zig API. For C-compatible API, see c_lib.zig which provides
//! POSIX glob() and globfree() functions with a C header (include/zlob.h).

const std = @import("std");

pub const glob = @import("zlob");
pub const GlobResults = glob.GlobResults;
pub const GlobError = glob.GlobError;
pub const zlob_t = glob.zlob_t;
pub const analyzePattern = glob.analyzePattern;
pub const simdFindChar = glob.simdFindChar;
pub const hasWildcardsSIMD = glob.hasWildcardsSIMD;

/// This is a zig wrapper around the bitflags exposed by posix/gnu/zlob
pub const GlobFlags = glob.GlobFlags;

// Legacy integer flag constants (for backward compatibility and C interop)
pub const ZLOB_APPEND = glob.ZLOB_APPEND;
pub const ZLOB_DOOFFS = glob.ZLOB_DOOFFS;
pub const ZLOB_ERR = glob.ZLOB_ERR;
pub const ZLOB_MARK = glob.ZLOB_MARK;
pub const ZLOB_NOCHECK = glob.ZLOB_NOCHECK;
pub const ZLOB_NOSORT = glob.ZLOB_NOSORT;
pub const ZLOB_NOESCAPE = glob.ZLOB_NOESCAPE;
pub const ZLOB_MAGCHAR = glob.ZLOB_MAGCHAR;
pub const ZLOB_NOMAGIC = glob.ZLOB_NOMAGIC;
pub const ZLOB_TILDE = glob.ZLOB_TILDE;
pub const ZLOB_BRACE = glob.ZLOB_BRACE;
pub const ZLOB_PERIOD = glob.ZLOB_PERIOD;
pub const ZLOB_ONLYDIR = glob.ZLOB_ONLYDIR;
pub const ZLOB_TILDE_CHECK = glob.ZLOB_TILDE_CHECK;
pub const ZLOB_GITIGNORE = glob.ZLOB_GITIGNORE;
pub const ZLOB_NOSPACE = glob.ZLOB_NOSPACE;
pub const ZLOB_ABORTED = glob.ZLOB_ABORTED;
pub const ZLOB_NOMATCH = glob.ZLOB_NOMATCH;

/// Flags parameter type - accepts either GlobFlags or u32 for backward compatibility.
pub const FlagsParam = union(enum) {
    flags: GlobFlags,
    int: u32,

    pub fn toGlobFlags(self: FlagsParam) GlobFlags {
        return switch (self) {
            .flags => |f| f,
            .int => |i| GlobFlags.fromU32(i),
        };
    }

    pub fn toU32(self: FlagsParam) u32 {
        return switch (self) {
            .flags => |f| f.toU32(),
            .int => |i| i,
        };
    }
};

/// Perform file system walking and collect matching results to GlobResults
///
/// Example with GlobFlags (recommended):
/// ```zig
/// const flags = zlob.GlobFlags{ .brace = true, .gitignore = true };
/// if (try zlob.match(allocator, "**/*.zig", flags)) |*result| {
///     defer result.deinit();
///     for (result.paths) |path| {
///         std.debug.print("{s}\n", .{path});
///     }
/// }
/// ```
///
/// Example with integer flags (legacy):
/// ```zig
/// if (try zlob.match(allocator, "**/*.zig", zlob.ZLOB_BRACE | zlob.ZLOB_GITIGNORE)) |*result| {
///     defer result.deinit();
///     for (result.paths) |path| {
///         std.debug.print("{s}\n", .{path});
///     }
/// }
/// ```
pub fn match(allocator: std.mem.Allocator, pattern: []const u8, flags: anytype) !?GlobResults {
    const flags_u32 = flagsToU32(flags);

    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);

    var pzlob: zlob_t = undefined;
    const opt_result = try glob.glob(allocator, pattern_z.ptr, @intCast(flags_u32), null, &pzlob);

    if (opt_result) |_| {
        var paths = try allocator.alloc([]const u8, pzlob.gl_pathc);
        errdefer allocator.free(paths);

        var i: usize = 0;
        while (i < pzlob.gl_pathc) : (i += 1) {
            const c_path = pzlob.gl_pathv[i];
            const path_len = pzlob.gl_pathlen[i];
            paths[i] = c_path[0..path_len];
        }

        return GlobResults{
            .paths = paths,
            .match_count = pzlob.gl_pathc,
            .allocator = allocator,
            .pzlob = pzlob,
        };
    } else {
        const gf = GlobFlags.fromU32(flags_u32);
        if (gf.nocheck) {
            var paths = try allocator.alloc([]const u8, 1);
            errdefer allocator.free(paths);
            paths[0] = try allocator.dupe(u8, pattern);
            return GlobResults{
                .paths = paths,
                .match_count = 1,
                .allocator = allocator,
            };
        }
        return null;
    }
}

/// Match glob pattern against array of paths with full ** recursive support
///
/// This function provides in-memory pattern matching against an array of path strings
/// WITHOUT any filesystem I/O. It properly handles recursive ** patterns that match
/// zero or more directory components.
///
/// Pattern examples:
/// - `**/*.c` - All .c files at any depth
/// - `/users/**/code/*.zig` - All .zig files in any 'code' directory under /users
/// - `src/**/test_*.zig` - All test files under src/
///
/// Example with GlobFlags (recommended):
/// ```zig
/// const paths = [_][]const u8{
///     "/users/alice/code/main.c",
///     "/users/alice/code/src/utils.c",
///     "/users/bob/docs/readme.md",
/// };
///
/// const result = try zlob.matchPaths(allocator, "/users/**/code/*.c", &paths, .{});
/// defer result.deinit();
///
/// for (result.paths) |path| {
///     std.debug.print("Match: {s}\n", .{path});
/// }
/// ```
///
/// Supported flags:
/// - .nosort: Don't sort results
/// - .nocheck: Return pattern itself if no matches
/// - .period: Allow wildcards to match hidden files (starting with '.')
/// - .noescape: Treat backslashes as literal characters
///
/// Requirements:
/// - Input paths MUST be normalized (no consecutive slashes like //)
/// - Paths from filesystem operations are typically already normalized
pub fn matchPaths(allocator: std.mem.Allocator, pattern: []const u8, paths: []const []const u8, flags: anytype) !GlobResults {
    return glob.internalMatchPaths(allocator, pattern, paths, flagsToU32(flags));
}

/// Convert any supported flags type to u32.
/// Supports: GlobFlags, u32, comptime_int, or struct literals like .{ .mark = true }
fn flagsToU32(flags: anytype) u32 {
    const T = @TypeOf(flags);
    if (T == GlobFlags) {
        return flags.toU32();
    } else if (T == u32 or T == comptime_int) {
        return @intCast(flags);
    } else if (@typeInfo(T) == .@"struct") {
        // Handle anonymous struct literals like .{ .mark = true }
        const gf: GlobFlags = flags;
        return gf.toU32();
    } else {
        @compileError("flags must be GlobFlags, u32, or a struct literal");
    }
}

test {
    // Import all tests from glob module
    std.testing.refAllDecls(@This());
}

test "GlobFlags conversion" {
    const testing = std.testing;

    // Test basic flag creation
    const flags = GlobFlags{ .mark = true, .nosort = true };
    try testing.expect(flags.mark);
    try testing.expect(flags.nosort);
    try testing.expect(!flags.brace);

    // Test toU32/fromU32 roundtrip
    const as_int = flags.toU32();
    const expected: u32 = ZLOB_MARK | ZLOB_NOSORT;
    try testing.expectEqual(expected, as_int);

    const back = GlobFlags.fromU32(as_int);
    try testing.expect(back.mark);
    try testing.expect(back.nosort);

    // Test with/without
    const with_brace = flags.with(.{ .brace = true });
    try testing.expect(with_brace.mark);
    try testing.expect(with_brace.nosort);
    try testing.expect(with_brace.brace);

    const without_mark = with_brace.without(.{ .mark = true });
    try testing.expect(!without_mark.mark);
    try testing.expect(without_mark.nosort);
    try testing.expect(without_mark.brace);
}

test "flagsToU32 accepts multiple types" {
    const testing = std.testing;

    // GlobFlags
    const mark_flag = GlobFlags{ .mark = true };
    const mark_expected: u32 = ZLOB_MARK;
    try testing.expectEqual(mark_expected, flagsToU32(mark_flag));

    // u32
    try testing.expectEqual(mark_expected, flagsToU32(@as(u32, ZLOB_MARK)));

    // comptime_int
    try testing.expectEqual(@as(u32, 0), flagsToU32(0));

    // Anonymous struct literal
    const mark_brace_expected: u32 = ZLOB_MARK | ZLOB_BRACE;
    try testing.expectEqual(mark_brace_expected, flagsToU32(.{ .mark = true, .brace = true }));
}
