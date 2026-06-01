const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const glob = @import("zlob.zig");
const suffix_match = @import("suffix_match.zig");
const brace_optimizer = @import("brace_optimizer.zig");
const utils = @import("utils.zig");

const hasWildcardsBasic = glob.hasWildcardsBasic;
const indexOfCharSIMD = glob.indexOfCharSIMD;
const lastIndexOfCharSIMD = glob.lastIndexOfCharSIMD;
const lastIndexOfAnyTwoSIMD = glob.lastIndexOfAnyTwoSIMD;
const isPathSep = glob.isPathSep;
const containsExtglob = glob.containsExtglob;
const fnmatch_mod = glob.fnmatch;
const PatternContext = glob.PatternContext;
const ZlobFlags = glob.ZlobFlags;
const ZlobResults = glob.ZlobResults;

const builtin = @import("builtin");
const path_sep_is_windows = builtin.os.tag == .windows;

/// Strip a single leading `./` from a pattern (matching is already relative
/// to either cwd or the caller's `base_path`).
inline fn stripDotSlash(raw_pattern: []const u8) []const u8 {
    if (raw_pattern.len >= 2 and raw_pattern[0] == '.' and raw_pattern[1] == '/') {
        return raw_pattern[2..];
    }
    return raw_pattern;
}

pub const PatternSegments = struct {
    segments: [][]const u8,
    /// Pre-computed contexts to avoid redundant hasWildcardsBasic calls.
    contexts: []PatternContext,
    allocator: Allocator,

    has_doublestar: bool,
    /// Original pattern string this was split from. Borrowed.
    original_pattern: []const u8,
    /// Pre-computed context for the fast no-doublestar path.
    pattern_context: PatternContext,

    pub fn deinit(self: *PatternSegments) void {
        self.allocator.free(self.segments);
        self.allocator.free(self.contexts);
    }
};

pub fn splitPatternByDoublestar(allocator: Allocator, pattern: []const u8, flags: ZlobFlags) !PatternSegments {
    if (!flags.doublestar_recursive or mem.indexOf(u8, pattern, "**") == null) {
        var segments = try allocator.alloc([]const u8, 1);
        segments[0] = pattern;

        var contexts = try allocator.alloc(PatternContext, 1);
        contexts[0] = PatternContext.init(pattern);

        return PatternSegments{
            .segments = segments,
            .contexts = contexts,
            .allocator = allocator,
            .has_doublestar = false,
            .original_pattern = pattern,
            .pattern_context = contexts[0],
        };
    }

    var segment_count: usize = 0;
    var iter = mem.splitScalar(u8, pattern, '/');
    while (iter.next()) |_| {
        segment_count += 1;
    }

    var segments = try allocator.alloc([]const u8, segment_count);
    errdefer allocator.free(segments);

    var contexts = try allocator.alloc(PatternContext, segment_count);
    errdefer allocator.free(contexts);

    var idx: usize = 0;
    iter = mem.splitScalar(u8, pattern, '/');
    while (iter.next()) |segment| {
        if (segment.len > 0) {
            segments[idx] = segment;
            contexts[idx] = PatternContext.init(segment);
            idx += 1;
        } else if (idx == 0 and pattern.len > 0 and pattern[0] == '/') {
            segments[idx] = "";
            contexts[idx] = PatternContext.init("");
            idx += 1;
        }
    }

    if (idx < segment_count) {
        segments = try allocator.realloc(segments, idx);
        contexts = try allocator.realloc(contexts, idx);
    }

    return PatternSegments{
        .segments = segments,
        .contexts = contexts,
        .allocator = allocator,
        .has_doublestar = true,
        .original_pattern = pattern,
        .pattern_context = PatternContext.init(pattern),
    };
}

/// Get the basename (filename) from a normalized path.
pub inline fn getBasenameNormalized(path: []const u8) []const u8 {
    // Comptime dispatch: on POSIX a single-needle SIMD scan is enough;
    // on Windows we need a two-needle scan to also catch '\\'.
    const last_sep = if (comptime path_sep_is_windows)
        lastIndexOfAnyTwoSIMD(path, '/', '\\')
    else
        lastIndexOfCharSIMD(path, '/');
    if (last_sep) |pos| return path[pos + 1 ..];
    return path;
}

/// Maximum number of path components the in-memory matcher can split a path
/// into. Bumped from 64 to 128 to absorb deep monorepo trees; sized to fit the
/// matchPathSegments DP row (`MAX_PATH_COMPONENTS + 1`).
pub const MAX_PATH_COMPONENTS: usize = 128;

/// Split `path` into components on `/` (and `\\` on Windows) using the
/// caller's buffer. Returns null when `path` would produce more components
/// than `buffer` can hold — callers must treat that as a no-match rather than
/// silently operating on a truncated component slice (a partial split would
/// drop trailing components and produce false negatives on doublestar
/// patterns).
pub fn splitPathComponentsNormalized(path: []const u8, buffer: [][]const u8) ?[][]const u8 {
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (path.len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const slash_vec: Vec = @splat('/');
        const back_vec: Vec = @splat('\\');
        var idx: usize = 0;
        var start: usize = 0;
        var i: usize = 0;

        while (i + vec_len <= path.len) : (i += vec_len) {
            const chunk: Vec = path[i..][0..vec_len].*;
            const slash_mask = @as(MaskInt, @bitCast(chunk == slash_vec));
            var mask = if (path_sep_is_windows)
                slash_mask | @as(MaskInt, @bitCast(chunk == back_vec))
            else
                slash_mask;
            while (mask != 0) {
                const offset = @ctz(mask);
                const pos = i + offset;
                if (pos > start) {
                    if (idx >= buffer.len) return null;
                    buffer[idx] = path[start..pos];
                    idx += 1;
                }
                start = pos + 1;
                mask &= mask - 1;
            }
        }

        while (i < path.len) : (i += 1) {
            if (isPathSep(path[i])) {
                if (i > start) {
                    if (idx >= buffer.len) return null;
                    buffer[idx] = path[start..i];
                    idx += 1;
                }
                start = i + 1;
            }
        }

        if (start < path.len) {
            if (idx >= buffer.len) return null;
            buffer[idx] = path[start..];
            idx += 1;
        }

        return buffer[0..idx];
    }

    // Fallback for short paths.
    var idx: usize = 0;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (isPathSep(path[i])) {
            if (i > seg_start) {
                if (idx >= buffer.len) return null;
                buffer[idx] = path[seg_start..i];
                idx += 1;
            }
            seg_start = i + 1;
        }
    }
    if (seg_start < path.len) {
        if (idx >= buffer.len) return null;
        buffer[idx] = path[seg_start..];
        idx += 1;
    }
    return buffer[0..idx];
}

fn shouldSkipHidden(path_component: []const u8, pattern: []const u8, flags: ZlobFlags) bool {
    if (path_component.len == 0 or path_component[0] != '.') {
        return false;
    }

    if (mem.eql(u8, path_component, ".") or mem.eql(u8, path_component, "..")) {
        return true;
    }

    if (flags.period) {
        return false;
    }

    if (pattern.len > 0 and pattern[0] == '.') {
        return false;
    }

    return true;
}

inline fn matchSegment(pat_seg: []const u8, path_comp: []const u8, ctx: *const PatternContext, enable_extglob: bool) bool {
    if (enable_extglob and containsExtglob(pat_seg)) {
        return fnmatch_mod.fnmatch(pat_seg, path_comp, .{ .extglob = true });
    }
    return fnmatch_mod.fnmatchWithContext(ctx, path_comp, .{});
}

/// Iterative segment matching using a single-row DP approach.
/// Avoids deep recursion on `**` patterns.
fn matchPathSegments(
    path_components: [][]const u8,
    pattern_segments: [][]const u8,
    pattern_contexts: []PatternContext,
    initial_segment_idx: usize,
    initial_path_idx: usize,
    flags: ZlobFlags,
) bool {
    const pat_len = pattern_segments.len - initial_segment_idx;
    const path_len = path_components.len - initial_path_idx;
    const enable_extglob = flags.extglob;

    if (pat_len == 0) return path_len == 0;

    var dp_storage: [MAX_PATH_COMPONENTS + 1]bool = undefined;
    const dp = dp_storage[0 .. path_len + 1];
    @memset(dp, false);
    dp[0] = true;

    var seg_i: usize = 0;
    while (seg_i < pat_len) : (seg_i += 1) {
        const pat_seg = pattern_segments[initial_segment_idx + seg_i];
        const is_doublestar = pat_seg.len == 2 and pat_seg[0] == '*' and pat_seg[1] == '*';

        if (is_doublestar) {
            var saw_true = false;
            var j: usize = 0;
            while (j <= path_len) : (j += 1) {
                if (dp[j]) {
                    saw_true = true;
                }
                if (saw_true) {
                    if (j > 0) {
                        const comp_idx = initial_path_idx + j - 1;
                        if (comp_idx < path_components.len) {
                            if (shouldSkipHidden(path_components[comp_idx], "", flags)) {
                                saw_true = false;
                            }
                        }
                    }
                    dp[j] = saw_true;
                } else {
                    dp[j] = false;
                }
            }
        } else {
            var j: usize = path_len;
            while (j > 0) : (j -= 1) {
                const path_comp_idx = initial_path_idx + j - 1;
                const path_comp = path_components[path_comp_idx];

                if (dp[j - 1]) {
                    if (shouldSkipHidden(path_comp, pat_seg, flags)) {
                        dp[j] = false;
                    } else if (matchSegment(pat_seg, path_comp, &pattern_contexts[initial_segment_idx + seg_i], enable_extglob)) {
                        dp[j] = true;
                    } else {
                        dp[j] = false;
                    }
                } else {
                    dp[j] = false;
                }
            }
            dp[0] = false;
        }
    }

    return dp[path_len];
}

/// Match a single path against pre-segmented pattern. Allocation-free,
/// branch-free path: this function genuinely cannot fail (no I/O, no
/// allocation), so it returns `bool` directly — callers don't need `try`.
pub fn matchSinglePath(
    pattern_segments: *const PatternSegments,
    path: []const u8,
    flags: ZlobFlags,
) bool {
    const enable_extglob = flags.extglob;
    const enable_escapes = !flags.noescape;

    if (!pattern_segments.has_doublestar) {
        if (enable_extglob and containsExtglob(pattern_segments.original_pattern)) {
            return fnmatch_mod.fnmatch(pattern_segments.original_pattern, path, .{ .extglob = true, .pathname = flags.pathname });
        }
        return fnmatch_mod.fnmatch(pattern_segments.original_pattern, path, .{ .noescape = !enable_escapes, .pathname = flags.pathname });
    }

    var component_buffer: [MAX_PATH_COMPONENTS][]const u8 = undefined;
    const path_components = splitPathComponentsNormalized(path, &component_buffer) orelse return false;
    const pattern_is_absolute = pattern_segments.segments.len > 0 and pattern_segments.segments[0].len == 0;
    const path_is_absolute = path.len > 0 and path[0] == '/';

    if (pattern_is_absolute and !path_is_absolute) {
        return false;
    }

    const pattern_start: usize = if (pattern_is_absolute) 1 else 0;
    const path_start: usize = 0;

    return matchPathSegments(
        path_components,
        pattern_segments.segments[pattern_start..],
        pattern_segments.contexts[pattern_start..],
        0,
        path_start,
        flags,
    );
}

/// For a pattern's last component, return the literal suffix after a leading `*`
/// (e.g. ".c" for "*.c"). Returns null if the suffix can't be reduced to a
/// plain string (more wildcards, extglob, doublestar, empty, etc).
pub fn extractSuffixFromPattern(pattern: []const u8) struct { suffix: ?[]const u8 } {
    const last_slash = lastIndexOfCharSIMD(pattern, '/');
    const last_component = if (last_slash) |pos| pattern[pos + 1 ..] else pattern;

    if (last_component.len < 2) return .{ .suffix = null };
    if (last_component[0] != '*') return .{ .suffix = null };
    if (last_component.len >= 2 and last_component[1] == '*') return .{ .suffix = null };

    const after_star = last_component[1..];
    if (hasWildcardsBasic(after_star)) return .{ .suffix = null };
    if (containsExtglob(after_star)) return .{ .suffix = null };
    if (after_star.len == 0) return .{ .suffix = null };

    return .{ .suffix = after_star };
}

const MultiSuffixMatcherResult = struct {
    matcher: suffix_match.UnifiedMultiSuffix,
    all_simple_suffixes: bool,
};

/// Try to build a unified multi-suffix matcher from expanded patterns.
/// Returns a matcher iff ALL patterns are `*.ext` with ext.len ∈ [1, 4].
fn tryBuildMultiSuffixMatcher(expanded_patterns: []const []const u8) MultiSuffixMatcherResult {
    var result = MultiSuffixMatcherResult{
        .matcher = suffix_match.UnifiedMultiSuffix{},
        .all_simple_suffixes = true,
    };

    for (expanded_patterns) |pattern| {
        if (pattern.len < 2 or pattern[0] != '*') {
            result.all_simple_suffixes = false;
            return result;
        }

        const suffix = pattern[1..];
        if (hasWildcardsBasic(suffix) or mem.indexOfScalar(u8, suffix, '/') != null) {
            result.all_simple_suffixes = false;
            return result;
        }

        if (suffix.len < 1 or suffix.len > 4) {
            result.all_simple_suffixes = false;
            return result;
        }

        if (result.matcher.count < suffix_match.UnifiedMultiSuffix.MAX_SUFFIXES) {
            result.matcher.suffixes[result.matcher.count] = suffix_match.MaskedSuffix.init(suffix);
            result.matcher.count += 1;
            if (suffix.len < result.matcher.min_suffix_len) {
                result.matcher.min_suffix_len = @intCast(suffix.len);
            }
        } else {
            result.all_simple_suffixes = false;
            return result;
        }
    }

    if (result.matcher.min_suffix_len == 255) {
        result.matcher.min_suffix_len = 1;
    }

    return result;
}

const RecursiveSuffixMatcherResult = struct {
    matcher: suffix_match.UnifiedMultiSuffix,
    all_recursive_suffix: bool,
};

/// Try to build a unified multi-suffix matcher for `**/*.ext` style alternatives.
fn tryBuildRecursiveSuffixMatcher(expanded_patterns: []const []const u8) RecursiveSuffixMatcherResult {
    var result = RecursiveSuffixMatcherResult{
        .matcher = suffix_match.UnifiedMultiSuffix{},
        .all_recursive_suffix = true,
    };

    for (expanded_patterns) |pattern| {
        var suffix_pattern = pattern;
        if (mem.startsWith(u8, pattern, "**/")) {
            suffix_pattern = pattern[3..];
        }

        if (suffix_pattern.len < 2 or suffix_pattern[0] != '*') {
            result.all_recursive_suffix = false;
            return result;
        }

        const suffix = suffix_pattern[1..];
        if (hasWildcardsBasic(suffix) or mem.indexOfScalar(u8, suffix, '/') != null) {
            result.all_recursive_suffix = false;
            return result;
        }

        if (suffix.len < 1 or suffix.len > 4) {
            result.all_recursive_suffix = false;
            return result;
        }

        if (result.matcher.count < suffix_match.UnifiedMultiSuffix.MAX_SUFFIXES) {
            result.matcher.suffixes[result.matcher.count] = suffix_match.MaskedSuffix.init(suffix);
            result.matcher.count += 1;
            if (suffix.len < result.matcher.min_suffix_len) {
                result.matcher.min_suffix_len = @intCast(suffix.len);
            }
        } else {
            result.all_recursive_suffix = false;
            return result;
        }
    }

    if (result.matcher.min_suffix_len == 255) {
        result.matcher.min_suffix_len = 1;
    }

    return result;
}

/// Discriminator for `CompiledPattern.body`. One distinct entry per dispatch
/// shape so `matches()` is a single jump-table switch.
pub const CompiledPatternKind = enum(u8) {
    /// No wildcards — exact-match against a normalized literal.
    literal,
    /// Brace-expanded; all alternatives are `*.ext` with ext.len ∈ [1, 4].
    multi_suffix,
    /// Brace-expanded; all alternatives are `**/*.ext` (or plain `*.ext`)
    /// with ext.len ∈ [1, 4].
    recursive_multi_suffix,
    /// Brace-expanded; alternatives are general patterns (no shared shape).
    brace_general,
    /// Single pattern of form `*.ext` with 1–4 byte extension (SIMD path).
    single_suffix_fast,
    /// Single pattern of form `*.ext` with 5+ byte extension.
    single_suffix_generic,
    /// General pattern, no suffix prefilter available.
    general_no_prefilter,
    /// General pattern with 1–4 byte suffix prefilter (SIMD path).
    general_prefilter_fast,
    /// General pattern with 5+ byte suffix prefilter.
    general_prefilter_generic,
};

pub const CompiledPattern = struct {
    allocator: Allocator,
    flags: ZlobFlags,

    /// Owned copy of the post-`./`-strip pattern. All borrowed slices below
    /// (suffix prefilter, generic SuffixMatch.suffix, segments) point into here.
    pattern_storage: []const u8,

    body: Body,

    pub const Body = union(CompiledPatternKind) {
        /// Sub-slice of `pattern_storage` with consecutive `/` collapsed
        /// in-place during compile. NOT separately allocated.
        literal: []const u8,
        multi_suffix: suffix_match.UnifiedMultiSuffix,
        recursive_multi_suffix: suffix_match.UnifiedMultiSuffix,
        brace_general: BraceGeneral,
        single_suffix_fast: suffix_match.SingleSuffixMatcher,
        single_suffix_generic: suffix_match.SuffixMatch,
        general_no_prefilter: PatternSegments,
        general_prefilter_fast: GeneralPrefilterFast,
        general_prefilter_generic: GeneralPrefilterGeneric,
    };

    pub const BraceGeneral = struct {
        /// Owned slices, each allocated via `allocator.dupe` inside `expandBraces`.
        expanded: [][]u8,
        /// One PatternSegments per expanded[i]; slices borrow into expanded[i].
        segments: []PatternSegments,
    };

    pub const GeneralPrefilterFast = struct {
        prefilter: suffix_match.SingleSuffixMatcher,
        segments: PatternSegments,
    };

    pub const GeneralPrefilterGeneric = struct {
        prefilter: suffix_match.SuffixMatch,
        segments: PatternSegments,
    };

    /// Compile a glob pattern into a reusable matcher.
    /// Prepares as much information about the pattern as possible out of the processing loop
    pub fn compile(allocator: Allocator, raw_pattern: []const u8, flags: ZlobFlags) !CompiledPattern {
        return compileImpl(allocator, raw_pattern, flags);
    }

    fn tryCompileOnStack(
        raw_pattern: []const u8,
        flags: ZlobFlags,
        literal_buf: []u8,
    ) ?CompiledPattern {
        // Brace patterns always go through the heap path (expansion may
        // produce multiple alternatives or rewrite storage in place).
        if (flags.brace) return null;

        var stripped = stripDotSlash(raw_pattern);

        // Windows: rewrite `\\` → `/` so all subsequent analysis sees a
        // canonical POSIX-form pattern. Lazy copy; POSIX comptime-elides.
        if (comptime path_sep_is_windows) {
            if (std.mem.indexOfScalar(u8, stripped, '\\') != null) {
                if (stripped.len > literal_buf.len) return null;
                @memcpy(literal_buf[0..stripped.len], stripped);
                for (literal_buf[0..stripped.len]) |*c| {
                    if (c.* == '\\') c.* = '/';
                }
                stripped = literal_buf[0..stripped.len];
            }
        }

        const has_extglob = flags.extglob and containsExtglob(stripped);

        // Literal fast path: no wildcards, no extglob, fits in the stack buffer.
        if (!hasWildcardsBasic(stripped) and !has_extglob and raw_pattern.len < 4096) {
            if (stripped.len > literal_buf.len) return null;
            const normalized = utils.normalizeSlashes(stripped, literal_buf);

            return CompiledPattern{
                .allocator = undefined,
                .flags = flags,
                .pattern_storage = normalized,
                .body = .{ .literal = normalized },
            };
        }

        // Simple suffix fast path like `*.ext` with 1–4 byte extension, no separators.
        const suffix_info = extractSuffixFromPattern(stripped);
        if (suffix_info.suffix) |suffix| {
            if (indexOfCharSIMD(stripped, '/') == null and
                suffix.len >= 1 and suffix.len <= 4)
            {
                return CompiledPattern{
                    .allocator = undefined,
                    .flags = flags,
                    .pattern_storage = stripped,
                    .body = .{ .single_suffix_fast = suffix_match.SingleSuffixMatcher.init(suffix) },
                };
            }
        }

        return null;
    }

    /// Free all memory owned by this CompiledPattern.
    pub fn deinit(self: *CompiledPattern) void {
        switch (self.body) {
            // literal points into pattern_storage — no separate free.
            .literal => {},
            .multi_suffix, .recursive_multi_suffix => {},
            .brace_general => |*bg| {
                for (bg.segments) |*ps| ps.deinit();
                self.allocator.free(bg.segments);
                for (bg.expanded) |e| self.allocator.free(e);
                self.allocator.free(bg.expanded);
            },
            .single_suffix_fast, .single_suffix_generic => {},
            .general_no_prefilter => |*ps| ps.deinit(),
            .general_prefilter_fast => |*g| g.segments.deinit(),
            .general_prefilter_generic => |*g| g.segments.deinit(),
        }
        self.allocator.free(self.pattern_storage);
        self.* = undefined;
    }

    /// Match a single path against this compiled pattern
    pub inline fn matches(self: *const CompiledPattern, path: []const u8, runtime_flags: ZlobFlags) bool {
        std.debug.assert(self.flags.brace == runtime_flags.brace);
        std.debug.assert(self.flags.doublestar_recursive == runtime_flags.doublestar_recursive);
        std.debug.assert(self.flags.extglob == runtime_flags.extglob);

        // Transient scratch for Windows path normalisation. POSIX comptime-elides.
        var path_scratch: [MAX_PATTERN_LEN]u8 = undefined;
        _ = &path_scratch;

        switch (self.body) {
            .literal => |normalized| {
                const norm = utils.normalizePathSeparators(path, &path_scratch);
                return mem.eql(u8, norm, normalized);
            },

            .single_suffix_fast => |*m| return m.matchSuffix(path),
            .single_suffix_generic => |*m| return m.match(path),
            .multi_suffix => |*ms| return ms.matchAny(getBasenameNormalized(path)),
            .recursive_multi_suffix => |*ms| return ms.matchAny(getBasenameNormalized(path)),

            .brace_general => |*bg| {
                // brace + nocheck have already been "consumed" by compile;
                // strip them before delegating to per-segment matching.
                const inner_flags = runtime_flags.without(.{ .brace = true, .nocheck = true });
                const norm = utils.normalizePathSeparators(path, &path_scratch);
                for (bg.segments) |*ps| {
                    if (matchSinglePath(ps, norm, inner_flags)) return true;
                }
                return false;
            },

            .general_no_prefilter => |*ps| {
                const norm = utils.normalizePathSeparators(path, &path_scratch);
                return matchSinglePath(ps, norm, runtime_flags);
            },

            .general_prefilter_fast => |*g| {
                if (!g.prefilter.matchSuffix(path)) return false;
                const norm = utils.normalizePathSeparators(path, &path_scratch);
                return matchSinglePath(&g.segments, norm, runtime_flags);
            },

            .general_prefilter_generic => |*g| {
                if (!g.prefilter.match(path)) return false;
                const norm = utils.normalizePathSeparators(path, &path_scratch);
                return matchSinglePath(&g.segments, norm, runtime_flags);
            },
        }
    }
};

/// Replace `old_storage` with the sole element of `expanded` (a brace
/// expansion that produced exactly one alternative). Frees `old_storage` and
/// the now-empty wrapper array, then empties `expanded` so the caller's
/// errdefer over it becomes a no-op (its memory now lives in the returned
/// storage, owned by the caller's `pattern_storage` errdefer). Returns the
/// transferred storage.
fn transferSingleAlternative(
    allocator: Allocator,
    old_storage: []u8,
    expanded: *[][]const u8,
) []u8 {
    const elem = expanded.*[0];
    const ptr: [*]u8 = @ptrCast(@constCast(elem.ptr));
    const new_storage = ptr[0..elem.len];
    allocator.free(old_storage);
    allocator.free(expanded.*);
    expanded.* = &.{};
    return new_storage;
}

fn compileImpl(allocator: Allocator, raw_pattern: []const u8, flags: ZlobFlags) !CompiledPattern {
    // Strip leading "./" — paths are relative to cwd / base by default.
    const stripped = if (raw_pattern.len >= 2 and raw_pattern[0] == '.' and raw_pattern[1] == '/')
        raw_pattern[2..]
    else
        raw_pattern;

    // Single owned clean copy that all internal slices may borrow from.
    var pattern_storage = try allocator.dupe(u8, stripped);
    errdefer allocator.free(pattern_storage);

    // On Windows, normalise `\\` → `/` in the pattern so all subsequent
    // analysis (segmentation, suffix detection, brace expansion, fnmatch)
    // sees a canonical POSIX-form pattern. POSIX builds comptime-elide
    // this loop entirely.
    if (comptime path_sep_is_windows) {
        for (pattern_storage) |*c| {
            if (c.* == '\\') c.* = '/';
        }
    }

    if (flags.brace) {
        // expandBraces returns []const []const u8 but each element is allocated
        // via allocator.dupe — i.e. each slice is logically []u8 (mutable-owned).
        var expanded_const = try brace_optimizer.expandBraces(allocator, pattern_storage);
        errdefer {
            for (expanded_const) |e| allocator.free(e);
            allocator.free(expanded_const);
        }

        // Single brace-stripped alternative (e.g. "test.{txt}" -> "test.txt"):
        // transfer its storage into pattern_storage and fall through to the
        // non-brace compile.
        if (expanded_const.len == 1) {
            pattern_storage = transferSingleAlternative(allocator, pattern_storage, &expanded_const);
            return compileNonBrace(allocator, pattern_storage, flags);
        }

        // Cast to mutable-owned slice form for storage.
        const expanded: [][]u8 = blk: {
            const ptr: [*][]u8 = @ptrCast(expanded_const.ptr);
            break :blk ptr[0..expanded_const.len];
        };

        // Try multi-suffix fast path: all alternatives are *.ext with ext.len ∈ [1, 4].
        const ms_result = tryBuildMultiSuffixMatcher(expanded);
        if (ms_result.all_simple_suffixes and ms_result.matcher.count > 0) {
            for (expanded) |e| allocator.free(e);
            allocator.free(expanded);
            return CompiledPattern{
                .allocator = allocator,
                .flags = flags,
                .pattern_storage = pattern_storage,
                .body = .{ .multi_suffix = ms_result.matcher },
            };
        }

        // Try recursive multi-suffix: all alternatives are **/*.ext or *.ext.
        // Gated on ZLOB_DOUBLESTAR_RECURSIVE: when unset, `**` is a literal
        // `*` and this fast path (which assumes recursion) must not trigger.
        if (flags.doublestar_recursive) {
            const rms_result = tryBuildRecursiveSuffixMatcher(expanded);
            if (rms_result.all_recursive_suffix and rms_result.matcher.count > 0) {
                for (expanded) |e| allocator.free(e);
                allocator.free(expanded);
                return CompiledPattern{
                    .allocator = allocator,
                    .flags = flags,
                    .pattern_storage = pattern_storage,
                    .body = .{ .recursive_multi_suffix = rms_result.matcher },
                };
            }
        }

        // Brace general: build PatternSegments for each alternative.
        var segments_list = try allocator.alloc(PatternSegments, expanded.len);
        var built: usize = 0;
        errdefer {
            for (segments_list[0..built]) |*ps| ps.deinit();
            allocator.free(segments_list);
        }
        for (expanded, 0..) |exp, i| {
            segments_list[i] = try splitPatternByDoublestar(allocator, exp, flags);
            built = i + 1;
        }

        return CompiledPattern{
            .allocator = allocator,
            .flags = flags,
            .pattern_storage = pattern_storage,
            .body = .{ .brace_general = .{
                .expanded = expanded,
                .segments = segments_list,
            } },
        };
    }

    return compileNonBrace(allocator, pattern_storage, flags);
}

fn compileNonBrace(allocator: Allocator, pattern_storage: []u8, flags: ZlobFlags) !CompiledPattern {
    const has_extglob = flags.extglob and containsExtglob(pattern_storage);

    // Literal fast path — no wildcards, no extglob.
    if (!hasWildcardsBasic(pattern_storage) and !has_extglob) {
        // Normalize in-place: collapse consecutive '/' into one. The result
        // is always <= len, so we can write back into pattern_storage and
        // store the literal as a sub-slice without a second allocation.
        const literal = utils.normalizeSlashes(pattern_storage, pattern_storage);
        return CompiledPattern{
            .allocator = allocator,
            .flags = flags,
            .pattern_storage = pattern_storage,
            .body = .{ .literal = literal },
        };
    }

    // Suffix detection (used both for single_suffix shapes and for prefilter).
    const suffix_info = extractSuffixFromPattern(pattern_storage);

    // Single simple-suffix-only: one segment, has suffix, no slash, isn't "**".
    // We can detect this WITHOUT calling splitPatternByDoublestar — saves an
    // allocation + free pair on the very common `*.ext` hot path.
    // `extractSuffixFromPattern` already returns null for "**" and any pattern
    // whose last component isn't a `*<suffix>` shape.
    const is_simple_suffix_only = suffix_info.suffix != null and
        indexOfCharSIMD(pattern_storage, '/') == null;

    if (is_simple_suffix_only) {
        const suffix = suffix_info.suffix.?;
        if (suffix.len <= 4) {
            return CompiledPattern{
                .allocator = allocator,
                .flags = flags,
                .pattern_storage = pattern_storage,
                .body = .{ .single_suffix_fast = suffix_match.SingleSuffixMatcher.init(suffix) },
            };
        }
        return CompiledPattern{
            .allocator = allocator,
            .flags = flags,
            .pattern_storage = pattern_storage,
            .body = .{ .single_suffix_generic = suffix_match.SuffixMatch.new(suffix) },
        };
    }

    // from here on we need pattern segments.
    var segments = try splitPatternByDoublestar(allocator, pattern_storage, flags);
    errdefer segments.deinit();

    // General with optional suffix prefilter.
    if (suffix_info.suffix) |suffix| {
        if (suffix.len <= 4) {
            return CompiledPattern{
                .allocator = allocator,
                .flags = flags,
                .pattern_storage = pattern_storage,
                .body = .{ .general_prefilter_fast = .{
                    .prefilter = suffix_match.SingleSuffixMatcher.init(suffix),
                    .segments = segments,
                } },
            };
        }
        return CompiledPattern{
            .allocator = allocator,
            .flags = flags,
            .pattern_storage = pattern_storage,
            .body = .{ .general_prefilter_generic = .{
                .prefilter = suffix_match.SuffixMatch.new(suffix),
                .segments = segments,
            } },
        };
    }

    return CompiledPattern{
        .allocator = allocator,
        .flags = flags,
        .pattern_storage = pattern_storage,
        .body = .{ .general_no_prefilter = segments },
    };
}

/// Convenience: heap-compile a glob pattern. Equivalent to
/// `CompiledPattern.compile`. Caller owns the result and must call
/// `deinit()`.
pub fn compilePattern(allocator: Allocator, pattern: []const u8, flags: ZlobFlags) !CompiledPattern {
    return CompiledPattern.compile(allocator, pattern, flags);
}

/// There are 2 collector types available for matchers that is determined at compile time
pub const CollectorKind = enum {
    /// manages an owned list of paths (for glibc and clis)
    slices,
    /// manages an index of original paths (mainly for fff)
    indices,
};

/// Output list type for a given collect kind.
pub fn ListOf(comptime kind: CollectorKind) type {
    return switch (kind) {
        .slices => std.array_list.AlignedManaged([]const u8, null),
        .indices => std.array_list.AlignedManaged(usize, null),
    };
}

/// Single inline push site — `kind` is comptime so the unused branch is
/// fully eliminated by the optimiser.
inline fn collectPush(
    comptime kind: CollectorKind,
    list: *ListOf(kind),
    idx: usize,
    path: []const u8,
) !void {
    switch (kind) {
        .slices => try list.append(path),
        .indices => try list.append(idx),
    }
}

/// Basename suffix-match loop shared by the `multi_suffix` and
/// `recursive_multi_suffix` arms. Pulled out of the dispatch switch so each
/// arm monomorphises against a concrete `*const UnifiedMultiSuffix` — inside
/// the switch the merged prong forced a per-iteration union-field select that
/// blocked hoisting of the matcher fields out of the hot loop.
inline fn runMultiSuffix(
    comptime collector: CollectorKind,
    comptime at: bool,
    ms: *const suffix_match.UnifiedMultiSuffix,
    paths: []const []const u8,
    path_offset: usize,
    out: *ListOf(collector),
    base_index: usize,
) !void {
    for (paths, 0..) |path, i| {
        if (comptime at) {
            if (path.len < path_offset) continue;
        }
        if (ms.matchAny(getBasenameNormalized(path))) {
            try collectPush(collector, out, base_index + i, path);
        }
    }
}

/// Sort matched path slices lexicographically in place (the default,
/// non-NOSORT ordering used by every batch entry point).
pub fn sortPathSlices(paths: [][]const u8) void {
    mem.sort([]const u8, paths, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
}

/// Compute the per-path offset for a base directory. Mirrors the logic used
/// by `matchPathsAt` so external callers can reuse it without re-deriving.
pub fn computePathOffset(base_path: []const u8) usize {
    if (base_path.len == 0) return 0;
    if (base_path[base_path.len - 1] == '/') return base_path.len;
    return base_path.len + 1;
}

const MAX_PATTERN_LEN: usize = 4096; // worst case for the stack-compile literal buffer

/// Iterate `paths` and push matches into `out` (typed by comptime `collector`).
/// The `at` comptime flag elides the per-path `path_offset` check. `base_index`
/// is added to every emitted index (for chunked callers; ignored by the slice
/// collector — non-chunked callers pass `0`).
pub fn matchPathsCompiledImpl(
    comptime collector: CollectorKind,
    comptime at: bool, // if false ignores path offset
    compiled: *const CompiledPattern,
    paths: []const []const u8,
    path_offset: usize,
    flags: ZlobFlags,
    out: *ListOf(collector),
    base_index: usize,
) !void {
    if (std.debug.runtime_safety) {
        std.debug.assert(compiled.flags.brace == flags.brace);
        std.debug.assert(compiled.flags.doublestar_recursive == flags.doublestar_recursive);
        std.debug.assert(compiled.flags.extglob == flags.extglob);
        if (comptime !at) std.debug.assert(path_offset == 0);
    }

    // Transient scratch for Windows path normalisation; matched slices pushed
    // to `out` are always the caller's original `path`. POSIX comptime-elides.
    var path_scratch: [MAX_PATTERN_LEN]u8 = undefined;
    _ = &path_scratch;

    switch (compiled.body) {
        .literal => |normalized| {
            for (paths, 0..) |path, i| {
                if (comptime at) {
                    if (path.len < path_offset) continue;
                }
                const rel_path = if (comptime at) path[path_offset..] else path;
                const norm_rel = utils.normalizePathSeparators(rel_path, &path_scratch);

                if (mem.eql(u8, norm_rel, normalized)) {
                    try collectPush(collector, out, base_index + i, path);
                }
            }
        },

        .multi_suffix => |*ms| try runMultiSuffix(collector, at, ms, paths, path_offset, out, base_index),
        .recursive_multi_suffix => |*ms| try runMultiSuffix(collector, at, ms, paths, path_offset, out, base_index),

        .brace_general => |*bg| {
            const inner_flags = flags.without(.{ .brace = true, .nocheck = true });
            for (paths, 0..) |path, i| {
                if (comptime at) {
                    if (path.len < path_offset) continue;
                }
                const rel_path = if (comptime at) path[path_offset..] else path;
                const norm_rel = utils.normalizePathSeparators(rel_path, &path_scratch);
                for (bg.segments) |*ps| {
                    if (matchSinglePath(ps, norm_rel, inner_flags)) {
                        try collectPush(collector, out, base_index + i, path);
                        break;
                    }
                }
            }
        },

        .single_suffix_fast => |*m| {
            try suffix_match.SingleSuffixMatcher.matchPathsBatchedCollect(
                m,
                paths,
                if (comptime at) path_offset else 0,
                collector == .indices,
                comptime at,
                out,
                base_index,
            );
        },

        .single_suffix_generic => |*m| {
            for (paths, 0..) |path, i| {
                if (comptime at) {
                    if (path.len < path_offset) continue;
                }
                if (m.match(path)) {
                    try collectPush(collector, out, base_index + i, path);
                }
            }
        },

        .general_no_prefilter => |*ps| {
            for (paths, 0..) |path, i| {
                if (comptime at) {
                    if (path.len < path_offset) continue;
                }
                const rel_path = if (comptime at) path[path_offset..] else path;
                const norm_rel = utils.normalizePathSeparators(rel_path, &path_scratch);
                if (matchSinglePath(ps, norm_rel, flags)) {
                    try collectPush(collector, out, base_index + i, path);
                }
            }
        },

        .general_prefilter_fast => |*g| {
            for (paths, 0..) |path, i| {
                if (comptime at) {
                    if (path.len < path_offset) continue;
                }
                if (!g.prefilter.matchSuffix(path)) continue;
                const rel_path = if (comptime at) path[path_offset..] else path;
                const norm_rel = utils.normalizePathSeparators(rel_path, &path_scratch);
                if (matchSinglePath(&g.segments, norm_rel, flags)) {
                    try collectPush(collector, out, base_index + i, path);
                }
            }
        },

        .general_prefilter_generic => |*g| {
            for (paths, 0..) |path, i| {
                if (comptime at) {
                    if (path.len < path_offset) continue;
                }
                if (!g.prefilter.match(path)) continue;
                const rel_path = if (comptime at) path[path_offset..] else path;
                const norm_rel = utils.normalizePathSeparators(rel_path, &path_scratch);
                if (matchSinglePath(&g.segments, norm_rel, flags)) {
                    try collectPush(collector, out, base_index + i, path);
                }
            }
        },
    }
}

/// Run the generic batch matcher into a slice-collecting array, then wrap
/// the result in a `ZlobResults`. Honors `nocheck` (synthesizes pattern on
/// no-match) and `nosort` (sort results by string unless set).
fn matchPathsImplWithCollector(
    allocator: Allocator,
    compiled: *const CompiledPattern,
    paths: []const []const u8,
    path_offset: usize,
    flags: ZlobFlags,
) !ZlobResults {
    if (paths.len == 0) {
        if (flags.nocheck) {
            var result_paths = try allocator.alloc([]const u8, 1);
            result_paths[0] = try allocator.dupe(u8, compiled.pattern_storage);
            return ZlobResults{
                .source = .{ .paths = .{ .items = result_paths, .owns_strings = true } },
                .allocator = allocator,
            };
        }
        const empty: [][]const u8 = &[_][]const u8{};
        return ZlobResults{
            .source = .{ .paths = .{ .items = empty, .owns_strings = false } },
            .allocator = allocator,
        };
    }

    var matches = std.array_list.AlignedManaged([]const u8, null).initCapacity(allocator, paths.len) catch
        std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer matches.deinit();

    if (path_offset == 0) {
        try matchPathsCompiledImpl(.slices, false, compiled, paths, 0, flags, &matches, 0);
    } else {
        try matchPathsCompiledImpl(.slices, true, compiled, paths, path_offset, flags, &matches, 0);
    }

    if (matches.items.len == 0 and flags.nocheck) {
        var result_paths = try allocator.alloc([]const u8, 1);
        result_paths[0] = try allocator.dupe(u8, compiled.pattern_storage);
        return ZlobResults{
            .source = .{ .paths = .{ .items = result_paths, .owns_strings = true } },
            .allocator = allocator,
        };
    }

    if (matches.items.len == 0) {
        const empty: [][]const u8 = &[_][]const u8{};
        return ZlobResults{
            .source = .{ .paths = .{ .items = empty, .owns_strings = false } },
            .allocator = allocator,
        };
    }

    const result_paths = try matches.toOwnedSlice();

    if (!flags.nosort) sortPathSlices(result_paths);

    return ZlobResults{
        .source = .{ .paths = .{ .items = result_paths, .owns_strings = false } },
        .allocator = allocator,
    };
}

/// Run the generic batch matcher into an index-collecting array, then return
/// it as an owned `[]usize`. Always input order; NOSORT/NOCHECK are ignored.
fn matchPathIndicesCompiledImpl(
    allocator: Allocator,
    compiled: *const CompiledPattern,
    paths: []const []const u8,
    path_offset: usize,
    flags: ZlobFlags,
) ![]usize {
    if (paths.len == 0) {
        return allocator.alloc(usize, 0);
    }

    var indices = std.array_list.AlignedManaged(usize, null).initCapacity(allocator, paths.len) catch
        std.array_list.AlignedManaged(usize, null).init(allocator);
    defer indices.deinit();

    if (path_offset == 0) {
        try matchPathsCompiledImpl(.indices, false, compiled, paths, 0, flags, &indices, 0);
    } else {
        try matchPathsCompiledImpl(.indices, true, compiled, paths, path_offset, flags, &indices, 0);
    }

    return indices.toOwnedSlice();
}

// ============================================================================
// One-shot batch entry points.
//
// Compile + match in one call. Internally try the allocation-free
// `tryCompileOnStack` first; fall back to heap `compile` for any pattern
// shape that needs owned storage. Public users get the optimization
// transparently — no need to manage stack buffers manually.
// ============================================================================

/// Match glob pattern against array of paths.
pub fn matchPaths(
    allocator: Allocator,
    raw_pattern: []const u8,
    paths: []const []const u8,
    flags: ZlobFlags,
) !ZlobResults {
    var literal_buf: [MAX_PATTERN_LEN]u8 = undefined;
    if (CompiledPattern.tryCompileOnStack(raw_pattern, flags, &literal_buf)) |stack_compiled| {
        return matchPathsImplWithCollector(allocator, &stack_compiled, paths, 0, flags);
    }
    var compiled = try CompiledPattern.compile(allocator, raw_pattern, flags);
    defer compiled.deinit();
    return matchPathsImplWithCollector(allocator, &compiled, paths, 0, flags);
}

/// Match glob pattern against an array of paths relative to `base_path`.
pub fn matchPathsAt(
    allocator: Allocator,
    base_path: []const u8,
    raw_pattern: []const u8,
    paths: []const []const u8,
    flags: ZlobFlags,
) !ZlobResults {
    const path_offset = computePathOffset(base_path);
    var literal_buf: [MAX_PATTERN_LEN]u8 = undefined;
    if (CompiledPattern.tryCompileOnStack(raw_pattern, flags, &literal_buf)) |stack_compiled| {
        return matchPathsImplWithCollector(allocator, &stack_compiled, paths, path_offset, flags);
    }
    var compiled = try CompiledPattern.compile(allocator, raw_pattern, flags);
    defer compiled.deinit();
    return matchPathsImplWithCollector(allocator, &compiled, paths, path_offset, flags);
}

/// Match against an array of paths using a pre-compiled pattern.
/// Safety: callers must keep `paths` alive longer than the returned
/// `ZlobResults`.
pub fn matchPathsCompiled(
    allocator: Allocator,
    compiled: *const CompiledPattern,
    paths: []const []const u8,
    flags: ZlobFlags,
) !ZlobResults {
    return matchPathsImplWithCollector(allocator, compiled, paths, 0, flags);
}

/// Match against an array of paths at a base path using a pre-compiled pattern.
pub fn matchPathsAtCompiled(
    allocator: Allocator,
    base_path: []const u8,
    compiled: *const CompiledPattern,
    paths: []const []const u8,
    flags: ZlobFlags,
) !ZlobResults {
    const path_offset = computePathOffset(base_path);
    return matchPathsImplWithCollector(allocator, compiled, paths, path_offset, flags);
}

/// Match a glob pattern against an array of paths and return the indices of
/// matching paths (into the input slice), in input order.
///
/// `ZLOB_NOSORT` and `ZLOB_NOCHECK` are ignored — indices are always in input
/// order.
pub fn matchPathIndices(
    allocator: Allocator,
    raw_pattern: []const u8,
    paths: []const []const u8,
    flags: ZlobFlags,
) ![]usize {
    var literal_buf: [MAX_PATTERN_LEN]u8 = undefined;
    if (CompiledPattern.tryCompileOnStack(raw_pattern, flags, &literal_buf)) |stack_compiled| {
        return matchPathIndicesCompiledImpl(allocator, &stack_compiled, paths, 0, flags);
    }
    var compiled = try CompiledPattern.compile(allocator, raw_pattern, flags);
    defer compiled.deinit();
    return matchPathIndicesCompiledImpl(allocator, &compiled, paths, 0, flags);
}

/// Same as `matchPathIndices`, performs matching at a certain base path.
pub fn matchPathIndicesAt(
    allocator: Allocator,
    base_path: []const u8,
    raw_pattern: []const u8,
    paths: []const []const u8,
    flags: ZlobFlags,
) ![]usize {
    var literal_buf: [MAX_PATTERN_LEN]u8 = undefined;
    const path_offset = computePathOffset(base_path);
    if (CompiledPattern.tryCompileOnStack(raw_pattern, flags, &literal_buf)) |stack_compiled| {
        return matchPathIndicesCompiledImpl(allocator, &stack_compiled, paths, path_offset, flags);
    }
    var compiled = try CompiledPattern.compile(allocator, raw_pattern, flags);
    defer compiled.deinit();
    return matchPathIndicesCompiledImpl(allocator, &compiled, paths, path_offset, flags);
}

/// Same as `matchPathIndices` but uses a precompiled pattern.
pub fn matchPathIndicesCompiled(
    allocator: Allocator,
    compiled: *const CompiledPattern,
    paths: []const []const u8,
    flags: ZlobFlags,
) ![]usize {
    return matchPathIndicesCompiledImpl(allocator, compiled, paths, 0, flags);
}

/// Same as `matchPathIndicesAt` but uses a precompiled pattern.
pub fn matchPathIndicesAtCompiled(
    allocator: Allocator,
    base_path: []const u8,
    compiled: *const CompiledPattern,
    paths: []const []const u8,
    flags: ZlobFlags,
) ![]usize {
    const path_offset = computePathOffset(base_path);
    return matchPathIndicesCompiledImpl(allocator, compiled, paths, path_offset, flags);
}
