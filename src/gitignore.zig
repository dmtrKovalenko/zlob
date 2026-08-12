const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const glob = @import("zlob.zig");
const path_matcher = @import("path_matcher.zig");
const compiled_pattern = @import("compiled_pattern.zig");

/// A single gitignore pattern with pre-computed metadata
pub const Pattern = struct {
    /// Full pattern slice
    text: []const u8,
    /// Pattern is negated (starts with !)
    negated: bool,
    /// Pattern only matches directories (ends with /)
    dir_only: bool,
    /// Pattern is anchored (contains / other than trailing)
    anchored: bool,
    /// Pattern contains ** for recursive matching
    has_double_star: bool,
    /// Pattern has no wildcards (can use literal matching)
    is_literal: bool,
    /// Pattern text contains / (requires full path matching if not anchored)
    has_slash: bool,
    /// Required last byte of matching strings (null if not statically known).
    /// Used for cheap rejection of wildcard patterns before fnmatch.
    required_last_char: ?u8,
    /// For simple suffix patterns like *.rs
    suffix: ?[]const u8,
    /// Pre-computed suffix length for fast comparison
    suffix_len: u8,
    /// Pre-computed u32 of suffix for SIMD-style matching (suffixes <= 4 bytes)
    suffix_u32: u32,
    /// Index in original pattern list (for negation ordering)
    index: u16,
    /// Pre-split components for anchored or recursive wildcard matching.
    /// Empty for basename-only wildcard patterns.
    segments: [][]const u8 = &.{},
};

/// String hash map for O(1) literal lookups
const StringHashMap = std.StringHashMap(PatternMatch);

/// Compact per-wildcard-pattern reject data, kept in a side array parallel to
/// `wildcard_patterns`. The hot loop in `checkWithBasename` walks only these
/// 2-byte gates (one cache line covers 32 patterns) and touches the full
/// ~100-byte `Pattern` struct only when a gate passes — for typical entries
/// every pattern is rejected right here.
pub const WildcardGate = packed struct(u16) {
    /// Required last char (valid when `has_rc`).
    rc: u8,
    has_rc: bool,
    /// `rc` is checked against the basename; otherwise against the full path.
    rc_on_basename: bool,
    /// Full-path `rc` check is sound (pattern has no `**`, or isn't dir_only).
    rc_on_path: bool,
    /// dir_only basename pattern: skip entirely for non-directories.
    skip_for_file: bool,
    _pad: u4 = 0,

    fn init(p: *const Pattern) WildcardGate {
        const basename_only = !p.anchored and !p.has_slash;
        return .{
            .rc = p.required_last_char orelse 0,
            .has_rc = p.required_last_char != null,
            .rc_on_basename = basename_only,
            .rc_on_path = !p.has_double_star or !p.dir_only,
            .skip_for_file = p.dir_only and basename_only,
        };
    }

    /// True when the pattern cannot match this entry — mirrors the inline
    /// reject checks previously duplicated in both checkWithBasename loops.
    inline fn rejects(g: WildcardGate, path_last: i16, basename_last: i16, is_dir: bool) bool {
        if (g.skip_for_file and !is_dir) return true;
        if (g.has_rc) {
            if (g.rc_on_basename) {
                if (basename_last != g.rc) return true;
            } else if (g.rc_on_path) {
                if (path_last != g.rc) return true;
            }
        }
        return false;
    }
};

/// 256-bit presence filter keyed by a string's last byte.
pub const LastByteFilter = struct {
    bits: [4]u64 = .{ 0, 0, 0, 0 },

    inline fn add(self: *LastByteFilter, key: []const u8) void {
        const b = key[key.len - 1];
        self.bits[b >> 6] |= @as(u64, 1) << @as(u6, @truncate(b));
    }

    inline fn mayContain(self: *const LastByteFilter, key: []const u8) bool {
        if (key.len == 0) return false;
        const b = key[key.len - 1];
        return (self.bits[b >> 6] >> @as(u6, @truncate(b))) & 1 != 0;
    }

    fn fromMap(map: *const StringHashMap) LastByteFilter {
        var f = LastByteFilter{};
        var it = map.keyIterator();
        while (it.next()) |key| f.add(key.*);
        return f;
    }
};

const PatternMatch = struct {
    negated: bool,
    dir_only: bool,
    index: u16,
};

/// Gitignore pattern set with optimized matching
pub const GitIgnore = struct {
    allocator: Allocator,
    /// Owned source buffers backing every pattern slice.
    sources: [][]const u8,
    /// All patterns for full matching
    patterns: []Pattern,
    /// Wildcard patterns only (excludes literals)
    wildcard_patterns: []Pattern,
    /// Reject gates parallel to `wildcard_patterns` (see WildcardGate).
    wildcard_gates: []WildcardGate,
    /// Literal directory patterns for O(1) lookup (e.g., "target", "node_modules")
    literal_dirs: StringHashMap,
    /// Literal file patterns for O(1) lookup
    literal_files: StringHashMap,
    /// Anchored literal paths for O(1) exact lookup
    anchored_literal_paths: StringHashMap,
    /// Anchored literal directory patterns that also match descendants
    anchored_literal_dirs: []Pattern,
    /// Simple suffix patterns like "*.rs", "*~", "*.vcxproj.filters"
    suffix_patterns: []Pattern,
    /// 256-bit filters over the *last byte* of the keys in each literal hash
    /// map. A hash lookup only runs when the candidate string's last byte has
    /// its bit set — for the common non-matching entry this replaces a wyhash
    /// of the basename (or the full path for anchored patterns) with one
    /// bit test. All-zero when the map is empty.
    literal_dirs_last: LastByteFilter,
    literal_files_last: LastByteFilter,
    anchored_paths_last: LastByteFilter,
    /// Inclusive start offset in suffix_patterns for each suffix last byte.
    suffix_bucket_start: [256]u32,
    /// Exclusive end offset in suffix_patterns for each suffix last byte.
    suffix_bucket_end: [256]u32,
    /// Whether any negation pattern exists (enables early termination)
    has_negations: bool,
    /// Index of first negation pattern (for early termination)
    first_negation_index: u16,
    /// True when no patterns were parsed (empty/comment-only .gitignore)
    is_empty: bool,
    /// True when wildcard matching needs the caller's path pre-split. The field
    /// name is retained for source compatibility.
    has_double_star_wildcards: bool,
    /// Cache for directory decisions: path -> should_skip
    dir_cache: std.StringHashMap(bool),

    const Self = @This();

    /// Load and parse .gitignore from current working directory
    /// Returns null if no .gitignore file exists
    pub fn loadFromCwd(allocator: Allocator, io: std.Io) !?Self {
        const cwd = std.Io.Dir.cwd();
        const content = cwd.readFileAlloc(io, ".gitignore", allocator, .limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return null;
            if (err == error.StreamTooLong) return null;
            return err;
        };
        errdefer allocator.free(content);
        const sources = try allocator.alloc([]const u8, 1);
        sources[0] = content;
        return try parseOwnedMulti(allocator, sources);
    }

    /// Load and parse `.gitignore` from a specific directory.
    /// Returns null when the file does not exist or exceeds the size limit.
    pub fn loadFromDir(allocator: Allocator, io: std.Io, dir_path: []const u8) !?Self {
        var path_buf: [4096]u8 = undefined;
        const gitignore_path = if (dir_path.len > 0 and !mem.eql(u8, dir_path, "."))
            std.fmt.bufPrint(&path_buf, "{s}/.gitignore", .{dir_path}) catch return null
        else
            ".gitignore";

        const cwd = std.Io.Dir.cwd();
        const content = cwd.readFileAlloc(io, gitignore_path, allocator, .limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound or err == error.StreamTooLong) return null;
            return err;
        };
        errdefer allocator.free(content);
        const sources = try allocator.alloc([]const u8, 1);
        sources[0] = content;
        return try parseOwnedMulti(allocator, sources);
    }

    /// Check if a pattern text contains any glob wildcards (SIMD-accelerated)
    fn hasWildcards(text: []const u8) bool {
        return glob.hasWildcardsBasic(text);
    }

    fn countPathComponents(path: []const u8) usize {
        var count: usize = 0;
        var in_component = false;
        for (path) |byte| {
            if (glob.isPathSep(byte)) {
                in_component = false;
            } else if (!in_component) {
                count += 1;
                in_component = true;
            }
        }
        return count;
    }

    fn unescapeLiteralInPlace(text: []const u8) []const u8 {
        const buf = @constCast(text);
        // Two cursors over the same buffer: `read` scans the original bytes,
        // `write` trails behind it emitting the kept ones. `write <= read`
        // always, which is what makes overwriting in place safe.
        var write: usize = 0;
        var read: usize = 0;
        while (read < buf.len) : (read += 1) {
            // On a backslash, skip it and take the byte it escapes verbatim.
            if (buf[read] == '\\' and read + 1 < buf.len) read += 1;
            buf[write] = buf[read];
            write += 1;
        }
        return buf[0..write];
    }

    /// folds runs of doublestar segments in place: `a/**/**/b` -> `a/**/b`
    fn collapseDoubleStarRuns(text: []const u8) []const u8 {
        const buf = @constCast(text);
        // Same two-cursor compaction as `unescapeLiteralInPlace`, but a segment
        // at a time: `read` walks to the next `/`, `write` trails behind
        // emitting the segments we keep.
        var write: usize = 0;
        var read: usize = 0;
        var prev_was_doublestar = false;
        var wrote_any = false;
        while (true) {
            const seg_end = mem.indexOfScalarPos(u8, buf, read, '/') orelse buf.len;
            const segment = buf[read..seg_end];
            const is_doublestar = segment.len >= 2 and mem.allEqual(u8, segment, '*');
            if (!(is_doublestar and prev_was_doublestar)) {
                // Emit the separator *before* each segment but the first. Using
                // `wrote_any` rather than `write > 0` matters for a leading
                // empty segment (from an anchoring `/`): it emits no bytes but
                // must still be followed by its slash, or `/a**` would collapse
                // to `a**` and silently lose its anchoring.
                if (wrote_any) {
                    buf[write] = '/';
                    write += 1;
                }
                mem.copyForwards(u8, buf[write..][0..segment.len], segment);
                write += segment.len;
                prev_was_doublestar = is_doublestar;
                wrote_any = true;
            }
            if (seg_end == buf.len) break;
            read = seg_end + 1;
        }
        return buf[0..write];
    }

    /// should be only called during parsing cause expensive
    fn extractSuffix(text: []const u8) ?[]const u8 {
        // Must start with * and have no other wildcards
        if (text.len < 2 or text[0] != '*') return null;
        // Check it's not **
        if (text.len >= 2 and text[1] == '*') return null;
        const rest = text[1..];
        // Rest must have no wildcards
        if (hasWildcards(rest)) return null;
        // An escaped byte is a literal one (`*\.log` matches `a.log`), but the
        // suffix is compared raw, so a backslash here would be matched
        // literally. Just ignore it and fallback to fnmatch
        if (mem.indexOfScalar(u8, rest, '\\') != null) return null;
        return rest;
    }

    /// Parse gitignore content from a borrowed string. The bytes are duped
    /// internally; the caller retains ownership of `content`.
    pub fn parse(allocator: Allocator, content: []const u8) !Self {
        const owned = try allocator.dupe(u8, content);
        errdefer allocator.free(owned);
        const sources = try allocator.alloc([]const u8, 1);
        sources[0] = owned;
        errdefer allocator.free(sources);
        return try parseOwnedMulti(allocator, sources);
    }

    /// Parse multiple gitignore documents in one pass and take ownership of
    /// every input buffer plus the outer slice. Sources are consumed in the
    /// given order, so patterns from later files get higher indices and win
    /// ties (`.ignore` after `.gitignore` like ripgrep does)
    pub fn parseOwnedMulti(allocator: Allocator, sources: [][]const u8) !Self {
        errdefer {
            for (sources) |src| allocator.free(src);
            allocator.free(sources);
        }
        const PatternList = std.array_list.AlignedManaged(Pattern, null);

        var patterns_list = PatternList.init(allocator);
        defer patterns_list.deinit();
        var wildcard_list = PatternList.init(allocator);
        defer wildcard_list.deinit();
        var literal_dirs = StringHashMap.init(allocator);
        errdefer literal_dirs.deinit();
        var literal_files = StringHashMap.init(allocator);
        errdefer literal_files.deinit();
        var anchored_literal_paths = StringHashMap.init(allocator);
        errdefer anchored_literal_paths.deinit();
        var anchored_literal_dir_list = PatternList.init(allocator);
        defer anchored_literal_dir_list.deinit();
        var suffix_list = PatternList.init(allocator);
        defer suffix_list.deinit();

        var has_negations = false;
        var first_negation_index: u16 = std.math.maxInt(u16);
        var index: u16 = 0;

        for (sources) |content| {
            var line_iter = mem.splitScalar(u8, content, '\n');
            while (line_iter.next()) |raw_line| {
                const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                    raw_line[0 .. raw_line.len - 1]
                else
                    raw_line;
                const pattern = parseLine(line, index) orelse continue;

                try patterns_list.append(pattern);

                if (pattern.negated) {
                    has_negations = true;
                    if (index < first_negation_index) first_negation_index = index;
                }

                if (pattern.is_literal and pattern.anchored) {
                    const match = PatternMatch{
                        .negated = pattern.negated,
                        .dir_only = pattern.dir_only,
                        .index = index,
                    };
                    if (pattern.dir_only) {
                        try anchored_literal_dir_list.append(pattern);
                    } else {
                        try anchored_literal_paths.put(pattern.text, match);
                    }
                } else if (pattern.is_literal and !pattern.anchored) {
                    const match = PatternMatch{
                        .negated = pattern.negated,
                        .dir_only = pattern.dir_only,
                        .index = index,
                    };
                    if (pattern.dir_only) {
                        try literal_dirs.put(pattern.text, match);
                    } else {
                        try literal_files.put(pattern.text, match);
                    }
                } else if (pattern.suffix != null) {
                    try suffix_list.append(pattern);
                } else {
                    try wildcard_list.append(pattern);
                }

                index += 1;
            }
        }

        const patterns = try patterns_list.toOwnedSlice();
        errdefer allocator.free(patterns);
        const wildcard_patterns = try wildcard_list.toOwnedSlice();
        errdefer allocator.free(wildcard_patterns);
        const anchored_literal_dirs = try anchored_literal_dir_list.toOwnedSlice();
        errdefer allocator.free(anchored_literal_dirs);
        const suffix_patterns = try suffix_list.toOwnedSlice();
        errdefer allocator.free(suffix_patterns);

        std.sort.block(Pattern, suffix_patterns, {}, struct {
            fn lessThan(_: void, a: Pattern, b: Pattern) bool {
                const a_last = a.suffix.?[a.suffix.?.len - 1];
                const b_last = b.suffix.?[b.suffix.?.len - 1];
                if (a_last != b_last) return a_last < b_last;
                return a.suffix_len < b.suffix_len;
            }
        }.lessThan);
        var suffix_bucket_start = [_]u32{std.math.maxInt(u32)} ** 256;
        var suffix_bucket_end = [_]u32{0} ** 256;
        for (suffix_patterns, 0..) |pattern, i| {
            const last = pattern.suffix.?[pattern.suffix.?.len - 1];
            if (suffix_bucket_start[last] == std.math.maxInt(u32)) {
                suffix_bucket_start[last] = @intCast(i);
            }
            suffix_bucket_end[last] = @intCast(i + 1);
        }

        errdefer for (wildcard_patterns) |p| {
            if (p.segments.len > 0) allocator.free(p.segments);
        };
        for (wildcard_patterns) |*p| {
            if (!p.anchored and !p.has_double_star) continue;
            const component_count = countPathComponents(p.text);
            const owned = try allocator.alloc([]const u8, component_count);
            const segments = compiled_pattern.splitPathComponentsNormalized(p.text, owned) orelse unreachable;
            std.debug.assert(segments.len == owned.len);
            p.segments = owned;
        }

        // Whether any pattern needs the caller's path pre-split.
        const wildcard_gates = try allocator.alloc(WildcardGate, wildcard_patterns.len);
        errdefer allocator.free(wildcard_gates);
        for (wildcard_patterns, wildcard_gates) |*p, *g| g.* = WildcardGate.init(p);

        var has_ds_wildcards = false;
        for (wildcard_patterns) |p| {
            if (p.segments.len > 0) {
                has_ds_wildcards = true;
                break;
            }
        }

        return Self{
            .patterns = patterns,
            .wildcard_patterns = wildcard_patterns,
            .wildcard_gates = wildcard_gates,
            .literal_dirs_last = LastByteFilter.fromMap(&literal_dirs),
            .literal_files_last = LastByteFilter.fromMap(&literal_files),
            .anchored_paths_last = LastByteFilter.fromMap(&anchored_literal_paths),
            .literal_dirs = literal_dirs,
            .literal_files = literal_files,
            .anchored_literal_paths = anchored_literal_paths,
            .anchored_literal_dirs = anchored_literal_dirs,
            .suffix_patterns = suffix_patterns,
            .suffix_bucket_start = suffix_bucket_start,
            .suffix_bucket_end = suffix_bucket_end,
            .has_negations = has_negations,
            .first_negation_index = first_negation_index,
            .is_empty = patterns.len == 0,
            .has_double_star_wildcards = has_ds_wildcards,
            .allocator = allocator,
            .sources = sources,
            .dir_cache = std.StringHashMap(bool).init(allocator),
        };
    }

    /// Extract the required last character from a pattern for early rejection.
    /// Returns null if the last character cannot be determined (ends with *, ?, or ]).
    fn extractRequiredLastChar(pattern: []const u8) ?u8 {
        if (pattern.len == 0) return null;
        var i: usize = pattern.len;
        while (i > 0) {
            i -= 1;
            const c = pattern[i];
            if (c == '*' or c == '?' or c == ']') return null;
            return c;
        }
        return null;
    }

    /// Parse a single line - returns pattern with text as slice into line
    fn parseLine(line: []const u8, index: u16) ?Pattern {
        var text = line;

        if (text.len == 0 or text[0] == '#') {
            return null;
        }

        // Trim trailing unescaped spaces
        while (text.len > 0 and text[text.len - 1] == ' ') {
            if (text.len >= 2 and text[text.len - 2] == '\\') break;
            text = text[0 .. text.len - 1];
        }

        if (text.len == 0) return null;

        var negated = false;
        if (text[0] == '!') {
            negated = true;
            text = text[1..];
            if (text.len == 0) return null;
        }

        var dir_only = false;
        if (text[text.len - 1] == '/') {
            dir_only = true;
            text = text[0 .. text.len - 1];
            if (text.len == 0) return null;
        }

        // `**/**` is equivalent to `**`, so fold runs down to one before any
        // other field is derived from `text`. This keeps absurdly repetitive
        // patterns inside the segment budget and saves matchSegmentsSimple a
        // recursion per redundant doublestar.
        if (mem.indexOf(u8, text, "**") != null) {
            text = collapseDoubleStarRuns(text);
        }

        var anchored = false;
        if (text[0] == '/') {
            anchored = true;
            text = text[1..];
        } else {
            for (text) |ch| {
                if (ch == '/') {
                    anchored = true;
                    break;
                }
            }
        }

        const is_literal = !hasWildcards(text);
        // Literal patterns are compared byte-for-byte (hash lookups, memcmp),
        if (is_literal and mem.indexOfScalar(u8, text, '\\') != null) {
            text = unescapeLiteralInPlace(text);
            if (text.len == 0) return null;
        }

        const suffix = if (!anchored) extractSuffix(text) else null;
        const has_slash = glob.indexOfCharSIMD(text, '/') != null;

        // Pre-compute suffix values for fast matching
        var suffix_len: u8 = 0;
        var suffix_u32: u32 = 0;
        if (suffix) |s| {
            suffix_len = @intCast(s.len);
            if (s.len <= 4) {
                @memcpy(@as([*]u8, @ptrCast(&suffix_u32))[0..s.len], s);
            }
        }

        return Pattern{
            .text = text,
            .negated = negated,
            .dir_only = dir_only,
            .anchored = anchored,
            .has_double_star = mem.indexOf(u8, text, "**") != null,
            .is_literal = is_literal,
            .has_slash = has_slash,
            .required_last_char = extractRequiredLastChar(text),
            .suffix = suffix,
            .suffix_len = suffix_len,
            .suffix_u32 = suffix_u32,
            .index = index,
        };
    }

    /// Check if a path should be ignored - optimized version
    pub fn isIgnored(self: *const Self, path: []const u8, is_dir: bool) bool {
        return self.check(path, is_dir) orelse false;
    }

    /// Return the standalone document's verdict for `path`, including ignored
    /// ancestor directories. Null means no pattern matched.
    pub fn check(self: *const Self, path: []const u8, is_dir: bool) ?bool {
        // Fast path: skip ./ prefix if present (common case: no prefix)
        const normalized_path = if (path.len > 2 and path[0] == '.' and path[1] == '/') path[2..] else path;
        // A stack of exactly this document: a standalone `GitIgnore` then gets
        // the same precedence and subtree rules as a walker's nested chain.
        const docs = [_]ScopedRules{.{ .gi = self, .offset = 0 }};
        const stack = Stack{ .docs = &docs };
        return stack.verdictWithAncestors(normalized_path, basenameOf(normalized_path), is_dir);
    }

    /// Match specific inode path to a pattern
    pub fn checkInode(self: *const Self, normalized_path: []const u8, basename: []const u8, is_dir: bool) ?bool {
        // Pre-split path segments once for ** wildcard patterns. Reused across
        // all patterns in the loop below avoids N redundant path splits per
        // entry. The 2 KB stack buffer is only touched when ** patterns exist.
        var path_seg_buf: [compiled_pattern.MAX_PATH_COMPONENTS][]const u8 = undefined;
        const path_segs: ?[][]const u8 = if (self.has_double_star_wildcards)
            compiled_pattern.splitPathComponentsNormalized(normalized_path, &path_seg_buf)
        else
            null;

        // Fast path: if no negations exist, we can use optimized lookups
        if (!self.has_negations) {
            if (is_dir and self.literal_dirs_last.mayContain(basename)) {
                if (self.literal_dirs.get(basename)) |_| {
                    return true;
                }
            }

            if (self.literal_files_last.mayContain(basename)) {
                if (self.literal_files.get(basename)) |match| {
                    if (!match.dir_only or is_dir) {
                        return true;
                    }
                }
            }

            if (self.matchAnySuffix(basename, is_dir)) return true;

            if (self.anchored_paths_last.mayContain(normalized_path)) {
                if (self.anchored_literal_paths.get(normalized_path)) |_| {
                    return true;
                }
            }

            for (self.anchored_literal_dirs) |pattern| {
                if (matchAnchoredLiteralDir(&pattern, normalized_path, is_dir)) return true;
            }

            // Check wildcard patterns - these require actual pattern matching.
            // The parallel `wildcard_gates` array carries all the cheap reject
            // data (dir_only skip + required-last-char), so the typical
            // non-matching entry never loads the wide Pattern structs at all.
            const path_last: i16 = if (normalized_path.len > 0) normalized_path[normalized_path.len - 1] else -1;
            const base_last: i16 = if (basename.len > 0) basename[basename.len - 1] else -1;
            for (self.wildcard_gates, 0..) |gate, i| {
                if (gate.rejects(path_last, base_last, is_dir)) continue;
                if (matchPatternFast(&self.wildcard_patterns[i], normalized_path, basename, path_segs, is_dir)) {
                    return true;
                }
            }

            return null;
        }

        // Negation path: find the latest matching candidate. We still honor
        // pattern order, but avoid scanning literal/suffix patterns that
        // cannot match this basename.
        var ignored: ?bool = null;
        var best_index: u16 = 0;

        if (is_dir and self.literal_dirs_last.mayContain(basename)) {
            if (self.literal_dirs.get(basename)) |match| {
                recordMatch(&best_index, &ignored, match.index, match.negated);
            }
        }

        if (self.literal_files_last.mayContain(basename)) {
            if (self.literal_files.get(basename)) |match| {
                if (!match.dir_only or is_dir) {
                    recordMatch(&best_index, &ignored, match.index, match.negated);
                }
            }
        }

        self.recordSuffixMatches(basename, is_dir, &best_index, &ignored);

        if (self.anchored_paths_last.mayContain(normalized_path)) {
            if (self.anchored_literal_paths.get(normalized_path)) |match| {
                recordMatch(&best_index, &ignored, match.index, match.negated);
            }
        }

        for (self.anchored_literal_dirs) |pattern| {
            if (matchAnchoredLiteralDir(&pattern, normalized_path, is_dir)) {
                recordMatch(&best_index, &ignored, pattern.index, pattern.negated);
            }
        }

        const path_last: i16 = if (normalized_path.len > 0) normalized_path[normalized_path.len - 1] else -1;
        const base_last: i16 = if (basename.len > 0) basename[basename.len - 1] else -1;
        for (self.wildcard_gates, 0..) |gate, i| {
            if (gate.rejects(path_last, base_last, is_dir)) continue;
            const pattern = &self.wildcard_patterns[i];
            if (matchPatternFast(pattern, normalized_path, basename, path_segs, is_dir)) {
                recordMatch(&best_index, &ignored, pattern.index, pattern.negated);
            }
        }

        return ignored;
    }

    /// Compatibility alias for callers using the previous public name.
    pub fn checkWithBasename(self: *const Self, normalized_path: []const u8, basename: []const u8, is_dir: bool) ?bool {
        return self.checkInode(normalized_path, basename, is_dir);
    }

    inline fn recordMatch(best_index: *u16, ignored: *?bool, index: u16, negated: bool) void {
        if (ignored.* == null or index >= best_index.*) {
            best_index.* = index;
            ignored.* = !negated;
        }
    }

    /// An anchored literal dir-only pattern matches the directory itself.
    /// Subtree propagation is resolved by the caller (`check`, or the walker's
    /// structural pruning), never per-pattern.
    inline fn matchAnchoredLiteralDir(pattern: *const Pattern, path: []const u8, is_dir: bool) bool {
        return is_dir and mem.eql(u8, pattern.text, path);
    }

    inline fn tailPackedU32(basename: []const u8, suffix_len: u8) u32 {
        var value: u32 = 0;
        const start = basename.len - suffix_len;
        @memcpy(@as([*]u8, @ptrCast(&value))[0..suffix_len], basename[start..][0..suffix_len]);
        return value;
    }

    inline fn canSimdSuffixGroup(patterns: []const Pattern, index: usize) bool {
        if (index + 4 > patterns.len) return false;
        const len = patterns[index].suffix_len;
        return len > 0 and len <= 4 and
            patterns[index + 1].suffix_len == len and
            patterns[index + 2].suffix_len == len and
            patterns[index + 3].suffix_len == len;
    }

    inline fn matchSuffixGroup4(patterns: []const Pattern, basename: []const u8, is_dir: bool) @Vector(4, bool) {
        const len = patterns[0].suffix_len;
        if (basename.len < len) return @splat(false);
        const tail: @Vector(4, u32) = @splat(tailPackedU32(basename, len));
        const suffixes: @Vector(4, u32) = .{
            patterns[0].suffix_u32,
            patterns[1].suffix_u32,
            patterns[2].suffix_u32,
            patterns[3].suffix_u32,
        };
        const dir_ok: @Vector(4, bool) = .{
            !patterns[0].dir_only or is_dir,
            !patterns[1].dir_only or is_dir,
            !patterns[2].dir_only or is_dir,
            !patterns[3].dir_only or is_dir,
        };
        return (tail == suffixes) & dir_ok;
    }

    inline fn matchAnySuffix(self: *const Self, basename: []const u8, is_dir: bool) bool {
        if (basename.len == 0) return false;
        const bucket_key = basename[basename.len - 1];
        const start = self.suffix_bucket_start[bucket_key];
        if (start == std.math.maxInt(u32)) return false;
        const patterns = self.suffix_patterns[start..self.suffix_bucket_end[bucket_key]];
        var i: usize = 0;
        while (i < patterns.len) {
            if (canSimdSuffixGroup(patterns, i)) {
                if (@reduce(.Or, matchSuffixGroup4(patterns[i..][0..4], basename, is_dir))) return true;
                i += 4;
                continue;
            }
            const pattern = patterns[i];
            if ((!pattern.dir_only or is_dir) and matchSuffixFast(&pattern, basename)) return true;
            i += 1;
        }
        return false;
    }

    inline fn recordSuffixMatches(self: *const Self, basename: []const u8, is_dir: bool, best_index: *u16, ignored: *?bool) void {
        if (basename.len == 0) return;
        const bucket_key = basename[basename.len - 1];
        const start = self.suffix_bucket_start[bucket_key];
        if (start == std.math.maxInt(u32)) return;
        const patterns = self.suffix_patterns[start..self.suffix_bucket_end[bucket_key]];
        var i: usize = 0;
        while (i < patterns.len) {
            if (canSimdSuffixGroup(patterns, i)) {
                const matches = matchSuffixGroup4(patterns[i..][0..4], basename, is_dir);
                if (matches[0]) recordMatch(best_index, ignored, patterns[i].index, patterns[i].negated);
                if (matches[1]) recordMatch(best_index, ignored, patterns[i + 1].index, patterns[i + 1].negated);
                if (matches[2]) recordMatch(best_index, ignored, patterns[i + 2].index, patterns[i + 2].negated);
                if (matches[3]) recordMatch(best_index, ignored, patterns[i + 3].index, patterns[i + 3].negated);
                i += 4;
                continue;
            }
            const pattern = patterns[i];
            if ((!pattern.dir_only or is_dir) and matchSuffixFast(&pattern, basename)) {
                recordMatch(best_index, ignored, pattern.index, pattern.negated);
            }
            i += 1;
        }
    }

    inline fn matchSuffixFast(pattern: *const Pattern, basename: []const u8) bool {
        if (basename.len < pattern.suffix_len) return false;
        const suffix_len = pattern.suffix_len;
        return switch (suffix_len) {
            1 => basename[basename.len - 1] == @as(u8, @truncate(pattern.suffix_u32)),
            2 => blk: {
                const tail_ptr = basename.ptr + basename.len - 2;
                const tail: u16 = @as(*align(1) const u16, @ptrCast(tail_ptr)).*;
                break :blk tail == @as(u16, @truncate(pattern.suffix_u32));
            },
            3 => blk: {
                const tail_ptr = basename.ptr + basename.len - 3;
                const tail_u16: u16 = @as(*align(1) const u16, @ptrCast(tail_ptr)).*;
                const suffix_u16: u16 = @truncate(pattern.suffix_u32);
                break :blk tail_u16 == suffix_u16 and tail_ptr[2] == pattern.suffix.?[2];
            },
            4 => blk: {
                const tail_ptr = basename.ptr + basename.len - 4;
                const tail: u32 = @as(*align(1) const u32, @ptrCast(tail_ptr)).*;
                break :blk tail == pattern.suffix_u32;
            },
            else => mem.endsWith(u8, basename, pattern.suffix.?),
        };
    }

    inline fn matchPatternFast(pattern: *const Pattern, path: []const u8, basename: []const u8, path_segments: ?[][]const u8, is_dir: bool) bool {
        std.debug.assert(!pattern.is_literal);
        std.debug.assert(pattern.anchored or !pattern.has_slash);

        const text = pattern.text;

        // Anchored patterns match against the full path.
        if (pattern.anchored) {
            // Directory ancestry is resolved by the caller.
            if (pattern.dir_only and !is_dir) return false;
            if (path_segments) |ps| {
                return path_matcher.matchGlobSimplePresplitWithPath(pattern.segments, ps);
            } else {
                return path_matcher.matchGlobSimplePresplit(pattern.segments, path);
            }
        }

        // Non-anchored patterns carry no `/`, so they match the basename.
        // Simple suffix patterns (`*.o`, `*.rs`) use the pre-computed u32 tail.
        if (pattern.suffix_len > 0) {
            return matchSuffixFast(pattern, basename);
        }
        return glob.fnmatch.fnmatch(text, basename, .{});
    }

    /// Whether a directory can be skipped without traversing it.
    pub fn shouldSkipDirectory(self: *Self, dir_path: []const u8) bool {
        const normalized_path = if (dir_path.len > 2 and dir_path[0] == '.' and dir_path[1] == '/') dir_path[2..] else dir_path;

        if (self.dir_cache.get(normalized_path)) |cached| {
            return cached;
        }

        const basename = basenameOf(normalized_path);
        const skip = self.checkInode(normalized_path, basename, true) orelse false;
        self.cacheResult(normalized_path, skip);
        return skip;
    }

    /// Cache a directory skip result - duplicates the key since it may be from a stack buffer
    fn cacheResult(self: *Self, path: []const u8, should_skip: bool) void {
        // Duplicate the key since it may point to a temporary stack buffer
        const key_copy = self.allocator.dupe(u8, path) catch return;
        self.dir_cache.put(key_copy, should_skip) catch {
            self.allocator.free(key_copy);
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.suffix_patterns);

        // Free duplicated keys in dir_cache
        var cache_iter = self.dir_cache.keyIterator();
        while (cache_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.dir_cache.deinit();

        self.literal_dirs.deinit();
        self.literal_files.deinit();
        self.anchored_literal_paths.deinit();

        // Free pre-split pattern segments (only wildcard_patterns has them).
        for (self.wildcard_patterns) |p| {
            if (p.segments.len > 0) self.allocator.free(p.segments);
        }

        self.allocator.free(self.patterns);
        self.allocator.free(self.wildcard_patterns);
        self.allocator.free(self.wildcard_gates);
        self.allocator.free(self.anchored_literal_dirs);
        for (self.sources) |src| self.allocator.free(src);
        self.allocator.free(self.sources);
    }

    pub const ScopedRules = struct {
        gi: *const Self,
        offset: usize,
    };

    pub inline fn basenameOf(path: []const u8) []const u8 {
        return if (mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
    }

    /// Ignore documents that may affect a path, ordered innermost first.
    pub const Stack = struct {
        docs: []const ScopedRules,

        /// Return the first matching document's verdict.
        pub fn verdict(self: Stack, path: []const u8, basename: []const u8, is_dir: bool) ?bool {
            for (self.docs) |doc| {
                // A document only has scope over `path` when its directory is an
                // ancestor-or-equal of it, i.e. its offset fits inside the path.
                if (doc.offset > path.len) continue;
                if (doc.gi.checkInode(path[doc.offset..], basename, is_dir)) |answer| return answer;
            }
            return null;
        }

        /// Resolve ignored ancestors before evaluating the path itself.
        pub fn verdictWithAncestors(self: Stack, path: []const u8, basename: []const u8, is_dir: bool) ?bool {
            var offset: usize = 0;
            while (mem.indexOfScalarPos(u8, path, offset, '/')) |slash| {
                const ancestor = path[0..slash];
                if (self.verdict(ancestor, basenameOf(ancestor), true) == true) return true;
                offset = slash + 1;
            }
            return self.verdict(path, basename, is_dir);
        }
    };
};

test "parse empty content" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator, "");
    defer gi.deinit();
    try std.testing.expectEqual(@as(usize, 0), gi.patterns.len);
}

test "parse comments and blank lines" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\# This is a comment
        \\
        \\# Another comment
        \\
    );
    defer gi.deinit();
    try std.testing.expectEqual(@as(usize, 0), gi.patterns.len);
}

test "parse simple patterns" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\*.log
        \\build/
        \\!important.log
    );
    defer gi.deinit();

    try std.testing.expectEqual(@as(usize, 3), gi.patterns.len);
    try std.testing.expectEqualStrings("*.log", gi.patterns[0].text);
    try std.testing.expect(!gi.patterns[0].negated);
    try std.testing.expectEqualStrings("build", gi.patterns[1].text);
    try std.testing.expect(gi.patterns[1].dir_only);
    try std.testing.expectEqualStrings("important.log", gi.patterns[2].text);
    try std.testing.expect(gi.patterns[2].negated);
}

test "parse anchored patterns" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\/root.txt
        \\src/temp
    );
    defer gi.deinit();

    try std.testing.expectEqual(@as(usize, 2), gi.patterns.len);
    try std.testing.expectEqualStrings("root.txt", gi.patterns[0].text);
    try std.testing.expect(gi.patterns[0].anchored);
    try std.testing.expectEqualStrings("src/temp", gi.patterns[1].text);
    try std.testing.expect(gi.patterns[1].anchored);
}

test "isIgnored basic patterns" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\*.log
        \\build/
    );
    defer gi.deinit();

    try std.testing.expect(gi.isIgnored("test.log", false));
    try std.testing.expect(gi.isIgnored("src/debug.log", false));
    try std.testing.expect(!gi.isIgnored("test.txt", false));
    try std.testing.expect(gi.isIgnored("build", true));
    try std.testing.expect(!gi.isIgnored("build", false));
}

test "isIgnored with negation" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\*.log
        \\!important.log
    );
    defer gi.deinit();

    try std.testing.expect(gi.isIgnored("test.log", false));
    try std.testing.expect(!gi.isIgnored("important.log", false));
}

test "isIgnored double star" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\**/logs
        \\src/**/*.o
    );
    defer gi.deinit();

    try std.testing.expect(gi.isIgnored("logs", true));
    try std.testing.expect(gi.isIgnored("app/logs", true));
    try std.testing.expect(gi.isIgnored("src/main.o", false));
    try std.testing.expect(gi.isIgnored("src/lib/util.o", false));
    try std.testing.expect(!gi.isIgnored("other/main.o", false));
}

test "shouldSkipDirectory" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\node_modules/
        \\build/
        \\!build/keep/
    );
    defer gi.deinit();

    try std.testing.expect(gi.shouldSkipDirectory("node_modules"));
    // Exact, not conservative: `!build/keep/` cannot re-include anything once
    // `build/` has excluded the parent, so the subtree is unreachable.
    try std.testing.expect(gi.shouldSkipDirectory("build"));
}

test "literal pattern optimization" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\target/
        \\node_modules/
        \\.git/
    );
    defer gi.deinit();

    // These should use O(1) hash lookup
    try std.testing.expect(gi.isIgnored("target", true));
    try std.testing.expect(gi.isIgnored("node_modules", true));
    try std.testing.expect(gi.isIgnored(".git", true));
    try std.testing.expect(gi.isIgnored("foo/target", true));
    try std.testing.expect(!gi.isIgnored("target", false)); // dir_only
}

test "suffix pattern optimization" {
    const allocator = std.testing.allocator;
    var gi = try GitIgnore.parse(allocator,
        \\*.rs
        \\*.log
    );
    defer gi.deinit();

    try std.testing.expect(gi.isIgnored("main.rs", false));
    try std.testing.expect(gi.isIgnored("src/lib.rs", false));
    try std.testing.expect(gi.isIgnored("debug.log", false));
    try std.testing.expect(!gi.isIgnored("main.txt", false));
}
