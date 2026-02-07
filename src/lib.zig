//! SIMD-accelerated glob pattern matching library
//!
//! This library provides high-performance file pattern matching (globbing) using
//! SIMD optimizations for improved performance on pattern matching operations.
//!
//! This is the pure Zig API. For C-compatible API, see c_lib.zig which provides
//! POSIX glob() and globfree() functions and C header (include/zlob.h).

const std = @import("std");
const zlob = @import("zlob");

// Re-export the flags module as a namespace
// Consumers access constants via zlob.flags.ZLOB_MARK, zlob.flags.ZlobFlags, etc.
pub const flags = @import("zlob_flags");

// Re-export modules through zlob_core to avoid module conflicts
pub const fnmatch = zlob.fnmatch;
pub const pattern_context = zlob.pattern_context;
pub const suffix_match = zlob.suffix_match;
pub const PatternContext = zlob.PatternContext;

pub const ZlobResults = zlob.ZlobResults;
pub const ZlobError = zlob.ZlobError;
pub const zlob_t = zlob.zlob_t;
pub const analyzePattern = zlob.analyzePattern;
pub const simdFindChar = zlob.simdFindChar;
pub const hasWildcardsWithFlags = zlob.hasWildcards;
pub const hasWildcardsBasic = zlob.hasWildcardsBasic;
pub const ZlobFlags = zlob.ZlobFlags;

/// Check if a pattern contains any glob special characters.
/// Detects all glob syntax: basic wildcards (*, ?, [), braces ({), and extglob patterns.
/// For fine-grained control, use `hasWildcardsWithFlags(pattern, flags)`.
pub fn hasWildcards(s: []const u8) bool {
    return zlob.hasWildcards(s, .{ .brace = true, .extglob = true });
}

/// Perform file system walking and collect matching results to ZlobResults
///
/// Example with ZlobFlags (recommended):
/// ```zig
/// const flags = zlob.ZlobFlags{ .brace = true, .gitignore = true };
/// if (try zlob.match(allocator, "**/*.zig", flags)) |*result| {
///     defer result.deinit();
///     var it = result.iterator();
///     while (it.next()) |path| {
///         std.debug.print("{s}\n", .{path});
///     }
/// }
/// ```
///
/// You can also pass any integer type build from the ZLOB_* flags if you prefer
/// or even struct literals like .{ .mark = true } for convenience
pub fn match(allocator: std.mem.Allocator, pattern: []const u8, flags_param: anytype) !?ZlobResults {
    const zflags = flagsToZlobFlags(flags_param);

    var pzlob: zlob_t = undefined;
    const opt_result = try zlob.globSlice(allocator, pattern, zflags.toInt(), null, &pzlob);

    if (opt_result) |_| {
        return ZlobResults{
            .source = .{ .zlob = pzlob },
            .allocator = allocator,
        };
    } else {
        if (zflags.nocheck) {
            var paths = try allocator.alloc([]const u8, 1);
            paths[0] = try allocator.dupe(u8, pattern);
            return ZlobResults{
                .source = .{ .paths = .{ .items = paths, .owns_strings = true } },
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
/// Example with ZlobFlags (recommended):
/// ```zig
/// const paths = [_][]const u8{
///     "/users/alice/code/main.c",
///     "/users/alice/code/src/utils.c",
///     "/users/bob/docs/readme.md",
/// };
///
/// var result = try zlob.matchPaths(allocator, "/users/**/code/*.c", &paths, .{});
/// defer result.deinit();
///
/// var it = result.iterator();
/// while (it.next()) |path| {
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
pub fn matchPaths(allocator: std.mem.Allocator, pattern: []const u8, paths: []const []const u8, flags_param: anytype) !ZlobResults {
    const zflags = flagsToZlobFlags(flags_param);
    return zlob.path_matcher.matchPaths(allocator, pattern, paths, zflags);
}

/// Match glob pattern against an array of absolute paths, treating each path as relative
/// to the given base directory.
///
/// This is the "at" variant of `matchPaths` for use when input paths are absolute but the
/// pattern is relative to a known base directory. The `base_path` may or may not end with
/// a trailing `/` — the offset is computed automatically.
///
/// If the pattern starts with `./`, it is interpreted as relative to `base_path` and the
/// prefix is replaced accordingly (i.e. stripped, since matching already operates relative
/// to the base).
///
/// Matched results contain the **original full paths** as submitted by the caller.
///
/// Example:
/// ```zig
/// const paths = [_][]const u8{
///     "/home/user/project/src/main.c",
///     "/home/user/project/src/test/unit.c",
///     "/home/user/project/lib/utils.c",
///     "/home/user/project/docs/readme.md",
/// };
///
/// const result = try zlob.matchPathsAt(allocator, "/home/user/project", "**/*.c", &paths, .{});
/// defer result.deinit();
/// // Use result.get(i) or result.iterator() to access the 3 matching absolute paths
/// ```
///
/// Supported flags: same as `matchPaths`.
pub fn matchPathsAt(allocator: std.mem.Allocator, base_path: []const u8, pattern: []const u8, paths: []const []const u8, flags_param: anytype) !ZlobResults {
    const zflags = flagsToZlobFlags(flags_param);
    return zlob.path_matcher.matchPathsAt(allocator, base_path, pattern, paths, zflags);
}

/// Perform file system walking within a specified base directory and collect matching results.
///
/// This is similar to `match()` but operates relative to the given `base_path` instead of
/// the current working directory. The `base_path` must be an absolute path.
///
/// Example:
/// ```zig
/// // Find all .zig files under /home/user/project
/// if (try zlob.matchAt(allocator, "/home/user/project", "**/*.zig", .{ .brace = true })) |*result| {
///     defer result.deinit();
///     var it = result.iterator();
///     while (it.next()) |path| {
///         std.debug.print("{s}\n", .{path});
///     }
/// }
/// ```
///
/// Returns `error.Aborted` if `base_path` is not an absolute path (doesn't start with '/').
pub fn matchAt(allocator: std.mem.Allocator, base_path: []const u8, pattern: []const u8, flags_param: anytype) !?ZlobResults {
    const zflags = flagsToZlobFlags(flags_param);
    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);

    var pzlob: zlob_t = undefined;
    const opt_result = try zlob.globAt(allocator, base_path, pattern_z.ptr, zflags.toInt(), null, &pzlob);

    if (opt_result) |_| {
        return ZlobResults{
            .source = .{ .zlob = pzlob },
            .allocator = allocator,
        };
    } else {
        if (zflags.nocheck) {
            var paths = try allocator.alloc([]const u8, 1);
            paths[0] = try allocator.dupe(u8, pattern);
            return ZlobResults{
                .source = .{ .paths = .{ .items = paths, .owns_strings = true } },
                .allocator = allocator,
            };
        }
        return null;
    }
}

/// Convert any supported flags type to ZlobFlags.
/// Supports: ZlobFlags, u32, c_int, comptime_int, or struct literals like .{ .mark = true }
fn flagsToZlobFlags(flags_param: anytype) ZlobFlags {
    const T = @TypeOf(flags_param);
    if (T == ZlobFlags) {
        return flags_param;
    } else if (T == u32) {
        return ZlobFlags.fromU32(flags_param);
    } else if (T == c_int) {
        return ZlobFlags.fromInt(flags_param);
    } else if (T == comptime_int) {
        return ZlobFlags.fromU32(@intCast(flags_param));
    } else if (@typeInfo(T) == .@"struct") {
        // Handle anonymous struct literals like .{ .mark = true }
        const gf: ZlobFlags = flags_param;
        return gf;
    } else {
        @compileError("flags must be ZlobFlags, u32, c_int, or a struct literal");
    }
}
