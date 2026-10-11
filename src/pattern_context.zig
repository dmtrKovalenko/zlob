const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const suffix_match = @import("suffix_match.zig");
const zlob_flags = @import("zlob_flags");

const ZlobFlags = zlob_flags.ZlobFlags;

/// Common pattern templates that can be matched with specialized fast paths
pub const PatternTemplate = enum {
    /// No special template detected
    none,
    /// Pattern is exactly "*" - matches any single component
    star_only,
    /// Pattern is "*.ext" - suffix match only
    star_dot_ext,
    /// Pattern is "prefix*" - prefix match only
    prefix_star,
    /// Pattern is "prefix*.ext" - prefix and suffix match
    prefix_star_ext,
    /// Pattern is a literal with no wildcards
    literal,
    /// Pattern is "prefix[charset]suffix" - bracket pattern with fixed prefix/suffix
    bracket_with_affixes,
};

pub const BracketBitmap = struct {
    bitmap: [32]u8,
    negated: bool,

    pub inline fn matches(self: *const BracketBitmap, ch: u8) bool {
        const bit_set = (self.bitmap[ch >> 3] & (@as(u8, 1) << @as(u3, @truncate(ch & 7)))) != 0;
        return if (self.negated) !bit_set else bit_set;
    }
};

/// Fast pattern context created for every independent pattern block.
/// Pre-computes pattern analysis to avoid redundant work during matching.
pub const PatternContext = struct {
    pattern: []const u8,
    has_wildcards: bool, // Pattern contains wildcards
    starts_with_dot: bool, // Pattern starts with '.'
    is_dot_or_dotdot: bool, // Pattern is exactly "." or ".."

    // Early rejection: required last character (if determinable from pattern)
    // For patterns like "*.zig" -> 'g', "foo" -> 'o', "[abc]" -> null
    required_last_char: ?u8,

    // Pattern template for specialized fast-path matching
    template: PatternTemplate,
    // For star_dot_ext: the extension (including dot)
    // For prefix_star: the prefix
    // For prefix_star_ext: split at star position
    template_prefix: []const u8,
    template_suffix: []const u8,

    // Pre-compiled bracket bitmap for bracket_with_affixes template
    bracket_bitmap: ?BracketBitmap,

    // Prebuilt patterns for various suffix matching optimizations
    single_suffix_matcher: ?suffix_match.SingleSuffixMatcher,
    only_suffix_match: ?suffix_match.SuffixMatch,

    pub inline fn init(pattern: []const u8) PatternContext {
        const has_wildcards = hasWildcardsBasic(pattern);

        const starts_with_dot = pattern.len > 0 and pattern[0] == '.';
        const is_dot_or_dotdot = mem.eql(u8, pattern, ".") or mem.eql(u8, pattern, "..");
        const single_suffix_matcher, const only_suffix_match = if (has_wildcards)
            suffix_match.check_simple_star_sufix(pattern)
        else
            .{ null, null };

        const required_last_char = extractRequiredLastChar(pattern);
        const template_info = detectPatternTemplate(pattern, has_wildcards);

        return PatternContext{
            .pattern = pattern,
            .has_wildcards = has_wildcards,
            .single_suffix_matcher = single_suffix_matcher,
            .only_suffix_match = only_suffix_match,
            .starts_with_dot = starts_with_dot,
            .is_dot_or_dotdot = is_dot_or_dotdot,
            .required_last_char = required_last_char,
            .template = template_info.template,
            .template_prefix = template_info.prefix,
            .template_suffix = template_info.suffix,
            .bracket_bitmap = template_info.bracket_bitmap,
        };
    }

    /// Fast-path matching using detected template
    /// Returns null if no fast path available, otherwise returns match result
    pub inline fn matchTemplate(self: *const PatternContext, string: []const u8) ?bool {
        return self.matchTemplateAs(self.template, string);
    }

    /// `matchTemplate` with the template passed in: hand it a comptime value
    /// (`== self.template`) from a caller that dispatches once outside its
    /// per-path loop and the switch folds away, leaving a loop body with no
    /// dispatch in it. A runtime value gives the ordinary switch. (Not an
    /// `inline else`: that would analyse every prong at every call site and
    /// blow the compiler's inline-expansion budget in callers of
    /// `CompiledPattern.matches`.)
    pub inline fn matchTemplateAs(self: *const PatternContext, template: PatternTemplate, string: []const u8) ?bool {
        return switch (template) {
            .none => null, // No fast path — most common case, check first
            .literal => eqlBytesInline(self.pattern, string),
            .star_only => true, // * matches anything
            .star_dot_ext => {
                // *.ext - just check suffix
                if (string.len < self.template_suffix.len) return false;
                return eqlBytesInline(string[string.len - self.template_suffix.len ..], self.template_suffix);
            },
            .prefix_star => {
                // prefix* - just check prefix
                if (string.len < self.template_prefix.len) return false;
                return eqlBytesInline(string[0..self.template_prefix.len], self.template_prefix);
            },
            .prefix_star_ext => {
                // prefix*.ext - check both prefix and suffix
                const min_len = self.template_prefix.len + self.template_suffix.len;
                if (string.len < min_len) return false;
                if (!eqlBytesInline(string[0..self.template_prefix.len], self.template_prefix)) return false;
                return eqlBytesInline(string[string.len - self.template_suffix.len ..], self.template_suffix);
            },
            .bracket_with_affixes => {
                // prefix[charset]suffix - check prefix, suffix, and single char in bracket
                const expected_len = self.template_prefix.len + 1 + self.template_suffix.len;
                if (string.len != expected_len) return false;
                if (!eqlBytesInline(string[0..self.template_prefix.len], self.template_prefix)) return false;
                if (!eqlBytesInline(string[string.len - self.template_suffix.len ..], self.template_suffix)) return false;
                // Check the bracket character
                const bracket_char = string[self.template_prefix.len];
                if (self.bracket_bitmap) |*bm| {
                    return bm.matches(bracket_char);
                }
                return null;
            },
        };
    }
};

/// Copy of `eqlBytes` from the Zig 0.16.0 standard library, made `inline`.
/// `std.mem.eql(u8, ...)` is a thin wrapper around it:
/// https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/mem.zig#L767-L826
///
/// Use it instead of `std.mem.eql` in per-path loops. Neither `std.mem.eql`
/// nor `eqlBytes` is `inline`, and LLVM keeps `std.mem.eql` as an out-of-line
/// call inside `matchPathsCompiledImpl`, so each prefix or suffix compare of
/// each path is a function call. `@call(.always_inline, std.mem.eql, ...)`
/// does not fix it: it inlines `eql` only, and the call to `eqlBytes` (private
/// to std) stays.
///
/// The body is std's, minus `comptime assert(use_vectors_for_comparison)`.
/// Keep it in sync when the Zig version changes.
pub inline fn eqlBytesInline(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len == 0 or a.ptr == b.ptr) return true;

    if (a.len <= 16) {
        if (a.len < 4) {
            const x = (a[0] ^ b[0]) | (a[a.len - 1] ^ b[a.len - 1]) | (a[a.len / 2] ^ b[a.len / 2]);
            return x == 0;
        }
        var x: u32 = 0;
        for ([_]usize{ 0, a.len - 4, (a.len / 8) * 4, a.len - 4 - ((a.len / 8) * 4) }) |n| {
            x |= @as(u32, @bitCast(a[n..][0..4].*)) ^ @as(u32, @bitCast(b[n..][0..4].*));
        }
        return x == 0;
    }

    // Figure out the fastest way to scan through the input in chunks.
    // Uses vectors when supported and falls back to usize/words when not.
    const Scan = if (std.simd.suggestVectorLength(u8)) |vec_size|
        struct {
            pub const size = vec_size;
            pub const Chunk = @Vector(size, u8);
            pub inline fn isNotEqual(chunk_a: Chunk, chunk_b: Chunk) bool {
                return @reduce(.Or, chunk_a != chunk_b);
            }
        }
    else
        struct {
            pub const size = @sizeOf(usize);
            pub const Chunk = usize;
            pub inline fn isNotEqual(chunk_a: Chunk, chunk_b: Chunk) bool {
                return chunk_a != chunk_b;
            }
        };

    inline for (1..6) |s| {
        const n = 16 << s;
        if (n <= Scan.size and a.len <= n) {
            const V = @Vector(n / 2, u8);
            var x = @as(V, a[0 .. n / 2].*) ^ @as(V, b[0 .. n / 2].*);
            x |= @as(V, a[a.len - n / 2 ..][0 .. n / 2].*) ^ @as(V, b[a.len - n / 2 ..][0 .. n / 2].*);
            const zero: V = @splat(0);
            return !@reduce(.Or, x != zero);
        }
    }
    // Compare inputs in chunks at a time (excluding the last chunk).
    for (0..(a.len - 1) / Scan.size) |i| {
        const a_chunk: Scan.Chunk = @bitCast(a[i * Scan.size ..][0..Scan.size].*);
        const b_chunk: Scan.Chunk = @bitCast(b[i * Scan.size ..][0..Scan.size].*);
        if (Scan.isNotEqual(a_chunk, b_chunk)) return false;
    }

    // Compare the last chunk using an overlapping read (similar to the previous size strategies).
    const last_a_chunk: Scan.Chunk = @bitCast(a[a.len - Scan.size ..][0..Scan.size].*);
    const last_b_chunk: Scan.Chunk = @bitCast(b[a.len - Scan.size ..][0..Scan.size].*);
    return !Scan.isNotEqual(last_a_chunk, last_b_chunk);
}

test "eqlBytesInline agrees with mem.eql for every length and differing position" {
    var a: [70]u8 = undefined;
    var b: [70]u8 = undefined;
    var n: usize = 0;
    while (n <= a.len) : (n += 1) {
        for (0..n) |i| {
            a[i] = @truncate(i *% 31 +% 7);
            b[i] = a[i];
        }
        try std.testing.expect(eqlBytesInline(a[0..n], b[0..n]));
        if (n > 0) try std.testing.expect(!eqlBytesInline(a[0..n], b[0 .. n - 1]));
        for (0..n) |d| {
            b[d] ^= 0x80;
            try std.testing.expectEqual(mem.eql(u8, a[0..n], b[0..n]), eqlBytesInline(a[0..n], b[0..n]));
            try std.testing.expect(!eqlBytesInline(a[0..n], b[0..n]));
            b[d] ^= 0x80;
        }
    }
}

/// Find the closing bracket for a bracket expression, handling ']' as first char being literal
fn findClosingBracket(pattern: []const u8, bracket_start: usize) ?usize {
    var i = bracket_start + 1; // Skip '['

    // Skip negation marker
    if (i < pattern.len and pattern[i] == '!') {
        i += 1;
    }

    // First char after '[' (or '[!') can be ']' as literal
    if (i < pattern.len and pattern[i] == ']') {
        i += 1;
    }

    // Now find the actual closing bracket
    while (i < pattern.len) {
        if (pattern[i] == ']') {
            return i;
        }
        i += 1;
    }

    return null; // No closing bracket found
}

/// Detect the pattern template for fast-path matching.
/// Accepts pre-computed has_wildcards to avoid redundant SIMD scan.
fn detectPatternTemplate(pattern: []const u8, has_wildcards: bool) struct { template: PatternTemplate, prefix: []const u8, suffix: []const u8, bracket_bitmap: ?BracketBitmap } {
    const has_escapes = mem.indexOfScalar(u8, pattern, '\\') != null;

    // Check for literal (no wildcards)
    if (!has_wildcards) {
        // Also check for escape sequences - if present, we can't use literal fast path
        // because the pattern needs escape processing
        if (has_escapes) {
            return .{ .template = .none, .prefix = "", .suffix = "", .bracket_bitmap = null };
        }
        return .{ .template = .literal, .prefix = pattern, .suffix = "", .bracket_bitmap = null };
    }

    // If pattern contains escape sequences, don't use template optimization
    // because templates don't handle POSIX escape processing
    if (has_escapes) {
        return .{ .template = .none, .prefix = "", .suffix = "", .bracket_bitmap = null };
    }

    // Check for single * only
    if (pattern.len == 1 and pattern[0] == '*') {
        return .{ .template = .star_only, .prefix = "", .suffix = "", .bracket_bitmap = null };
    }

    // Count wildcards and find positions
    var star_count: usize = 0;
    var question_count: usize = 0;
    var bracket_count: usize = 0;
    var first_star_pos: ?usize = null;
    var first_bracket_pos: ?usize = null;

    for (pattern, 0..) |c, i| {
        switch (c) {
            '*' => {
                star_count += 1;
                if (first_star_pos == null) first_star_pos = i;
            },
            '?' => question_count += 1,
            '[' => {
                bracket_count += 1;
                if (first_bracket_pos == null) first_bracket_pos = i;
            },
            else => {},
        }
    }

    // Check for single bracket pattern: prefix[charset]suffix
    if (bracket_count == 1 and star_count == 0 and question_count == 0) {
        if (first_bracket_pos) |bracket_start| {
            // Find closing bracket - need to handle ']' as first char being literal
            const close_pos = findClosingBracket(pattern, bracket_start);
            if (close_pos) |bracket_end| {
                const prefix = pattern[0..bracket_start];
                const suffix = pattern[bracket_end + 1 ..];

                // Pre-compile the bracket expression into a bitmap
                const bitmap = compileBracketBitmap(pattern, bracket_start);
                if (bitmap) |bm| {
                    return .{
                        .template = .bracket_with_affixes,
                        .prefix = prefix,
                        .suffix = suffix,
                        .bracket_bitmap = bm,
                    };
                }
            }
        }
    }

    // Only optimize single-star patterns without ? or []
    if (star_count != 1 or question_count > 0 or bracket_count > 0) {
        return .{ .template = .none, .prefix = "", .suffix = "", .bracket_bitmap = null };
    }

    const star_pos = first_star_pos.?;

    // *.ext pattern
    if (star_pos == 0 and pattern.len > 1) {
        return .{ .template = .star_dot_ext, .prefix = "", .suffix = pattern[1..], .bracket_bitmap = null };
    }

    // prefix* pattern
    if (star_pos == pattern.len - 1) {
        return .{ .template = .prefix_star, .prefix = pattern[0..star_pos], .suffix = "", .bracket_bitmap = null };
    }

    // prefix*.ext pattern
    if (star_pos > 0 and star_pos < pattern.len - 1) {
        return .{
            .template = .prefix_star_ext,
            .prefix = pattern[0..star_pos],
            .suffix = pattern[star_pos + 1 ..],
            .bracket_bitmap = null,
        };
    }

    return .{ .template = .none, .prefix = "", .suffix = "", .bracket_bitmap = null };
}

/// Compile a bracket expression into a 256-bit bitmap
fn compileBracketBitmap(pattern: []const u8, bracket_start: usize) ?BracketBitmap {
    var bitmap = BracketBitmap{
        .bitmap = [_]u8{0} ** 32,
        .negated = false,
    };

    var pi = bracket_start + 1; // Skip '['

    // Check for negation
    if (pi < pattern.len and pattern[pi] == '!') {
        bitmap.negated = true;
        pi += 1;
    }

    const expr_start = pi;

    while (pi < pattern.len) {
        const c = pattern[pi];

        // ']' as first char (or after '!') is a literal, not closing bracket
        if (c == ']' and pi > expr_start) break;

        pi += 1;

        // Check for range like a-z
        if (pi + 1 < pattern.len and pattern[pi] == '-' and pattern[pi + 1] != ']') {
            pi += 1;
            const range_end = pattern[pi];
            pi += 1;

            // Set all bits in range with byte-wide masks (at most 32 stores)
            if (c <= range_end) {
                const first_byte: usize = c >> 3;
                const last_byte: usize = range_end >> 3;
                const first_mask = @as(u8, 0xFF) << @as(u3, @truncate(c & 7));
                const last_mask = @as(u8, 0xFF) >> @as(u3, @truncate(7 - (range_end & 7)));
                if (first_byte == last_byte) {
                    bitmap.bitmap[first_byte] |= first_mask & last_mask;
                } else {
                    bitmap.bitmap[first_byte] |= first_mask;
                    var b = first_byte + 1;
                    while (b < last_byte) : (b += 1) {
                        bitmap.bitmap[b] = 0xFF;
                    }
                    bitmap.bitmap[last_byte] |= last_mask;
                }
            }
        } else {
            // Single character
            bitmap.bitmap[c >> 3] |= @as(u8, 1) << @as(u3, @truncate(c & 7));
        }
    }

    return bitmap;
}

/// Extract the required last character from a pattern for early rejection.
/// Returns null if the last character cannot be determined (e.g., ends with *, ?, or []).
fn extractRequiredLastChar(pattern: []const u8) ?u8 {
    if (pattern.len == 0) return null;

    // Scan backwards to find last non-wildcard character
    var i: usize = pattern.len;
    while (i > 0) {
        i -= 1;
        const c = pattern[i];

        // If pattern ends with a wildcard, we can't determine the last char
        if (c == '*' or c == '?') return null;

        // If pattern ends with ']', it's a bracket expression - can't determine
        if (c == ']') return null;

        // Found a literal character - this is the required last char
        // But check if it's escaped (preceded by backslash)
        if (i > 0 and pattern[i - 1] == '\\') {
            // Escaped character - it's a literal, return it
            return c;
        }

        return c;
    }

    return null;
}

pub fn indexOfCharSIMD(s: []const u8, needle: u8) ?usize {
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (s.len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const needle_vec: Vec = @splat(needle);
        var i: usize = 0;
        while (i + vec_len <= s.len) : (i += vec_len) {
            const chunk: Vec = s[i..][0..vec_len].*;
            const mask = @as(MaskInt, @bitCast(chunk == needle_vec));
            if (mask != 0) return i + @ctz(mask);
        }

        for (s[i..], i..) |c, idx| {
            if (c == needle) return idx;
        }
        return null;
    }
    return mem.indexOfScalar(u8, s, needle);
}

const path_sep_is_windows = builtin.os.tag == .windows;

/// True when `ch` is a path separator on the current platform.
///
/// `/` is always treated as a separator. On Windows `\\` is too. The Windows
/// branch is gated comptime so non-Windows builds compile to a single byte
/// compare with no extra branches.
pub inline fn isPathSep(ch: u8) bool {
    return ch == '/' or (path_sep_is_windows and ch == '\\');
}

/// SIMD-accelerated last-occurrence scan that matches either of two bytes
/// in a single reverse pass. Only useful when you genuinely need a two-needle
/// scan (the canonical case is "last path separator on Windows", where both
/// `/` and `\\` are valid).
///
/// On non-Windows targets prefer `lastIndexOfCharSIMD(s, '/')` directly —
/// it does the same work with one fewer compare per chunk.
pub inline fn lastIndexOfAnyTwoSIMD(s: []const u8, a: u8, b: u8) ?usize {
    return lastIndexOfImpl(s, a, b);
}

/// SIMD-accelerated lastIndexOf for a single byte. Returns the index of last
/// occurrence. Inline: as an out-of-line call it returned the `?usize`
/// through the stack, and the reload of that optional's tag was the single
/// hottest instruction of the basename matcher.
pub inline fn lastIndexOfCharSIMD(s: []const u8, needle: u8) ?usize {
    return lastIndexOfImpl(s, needle, null);
}

/// Width of the reverse-scan vector. Deliberately *not*
/// `suggestVectorLength`: that yields 32/64 on AVX2/AVX-512 hosts, and path
/// strings are mostly shorter than that, which used to push nearly every
/// basename lookup onto the scalar byte loop. 16 bytes covers a typical
/// basename in one compare and is native on every SIMD target we build for.
const rev_scan_vec_len: usize = 16;

/// Reverse scan for the last byte equal to `a` (or `b`, when given; `b` is
/// comptime-known null for the single-needle entry point so the extra
/// compare folds away).
///
/// Three regimes, all branch-light:
/// - len >= 16: 16-byte chunks from the end, then ONE overlapping load of
///   `s[0..16]` for the head. Any hit in that overlapping chunk is at a
///   position the chunk loop did not already cover (it found nothing there),
///   so no masking is needed.
/// - 8 <= len < 16: two overlapping 8-byte SWAR windows (tail, then head) by
///   the same argument.
/// - len < 8: scalar.
inline fn lastIndexOfImpl(s: []const u8, a: u8, b: ?u8) ?usize {
    const V = rev_scan_vec_len;
    const Vec = @Vector(V, u8);
    const MaskInt = std.meta.Int(.unsigned, V);

    if (s.len >= V) {
        const a_vec: Vec = @splat(a);
        var i: usize = s.len;
        while (i >= V) {
            i -= V;
            const chunk: Vec = s[i..][0..V].*;
            var mask = @as(MaskInt, @bitCast(chunk == a_vec));
            if (b) |bb| mask |= @as(MaskInt, @bitCast(chunk == @as(Vec, @splat(bb))));
            if (mask != 0) return i + V - 1 - @clz(mask);
        }
        if (i > 0) {
            const chunk: Vec = s[0..V].*;
            var mask = @as(MaskInt, @bitCast(chunk == a_vec));
            if (b) |bb| mask |= @as(MaskInt, @bitCast(chunk == @as(Vec, @splat(bb))));
            if (mask != 0) return V - 1 - @clz(mask);
        }
        return null;
    }

    if (s.len >= 8) {
        const tail = mem.readInt(u64, s[s.len - 8 ..][0..8], .little);
        if (lastByteInWord(tail, a, b)) |k| return s.len - 8 + k;
        const head = mem.readInt(u64, s[0..8], .little);
        if (lastByteInWord(head, a, b)) |k| return k;
        return null;
    }

    var j: usize = s.len;
    while (j > 0) {
        j -= 1;
        if (s[j] == a) return j;
        if (b) |bb| if (s[j] == bb) return j;
    }
    return null;
}

/// Index (0 = lowest-addressed byte of the little-endian word) of the highest
/// byte equal to `a` or `b`, using the exact (no false positive) zero-byte
/// test `~(((x & 0x7f..) + 0x7f..) | x) & 0x80..`.
inline fn lastByteInWord(w: u64, a: u8, b: ?u8) ?usize {
    const lo: u64 = 0x7f7f7f7f7f7f7f7f;
    const hi: u64 = 0x8080808080808080;
    const xa = w ^ (@as(u64, 0x0101010101010101) * a);
    var z = ~(((xa & lo) + lo) | xa) & hi;
    if (b) |bb| {
        const xb = w ^ (@as(u64, 0x0101010101010101) * bb);
        z |= ~(((xb & lo) + lo) | xb) & hi;
    }
    if (z == 0) return null;
    return (63 - @as(usize, @clz(z))) / 8;
}

test "lastIndexOfCharSIMD / lastIndexOfAnyTwoSIMD agree with std for every length and position" {
    // Covers the scalar (<8), SWAR (8..15), single-chunk (16..31) and
    // multi-chunk-with-overlapping-head (>=16, non-multiple) regimes,
    // including needle at index 0, at the end, in the overlap, and absent.
    var buf: [80]u8 = undefined;
    var len: usize = 0;
    while (len <= buf.len) : (len += 1) {
        const s = buf[0..len];
        @memset(s, 'x');
        try std.testing.expectEqual(@as(?usize, null), lastIndexOfCharSIMD(s, '/'));
        try std.testing.expectEqual(@as(?usize, null), lastIndexOfAnyTwoSIMD(s, '/', '\\'));
        var pos: usize = 0;
        while (pos < len) : (pos += 1) {
            @memset(s, 'x');
            s[pos] = '/';
            // a second, earlier needle must not win
            if (pos > 3) s[pos / 2] = '/';
            try std.testing.expectEqual(mem.lastIndexOfScalar(u8, s, '/'), lastIndexOfCharSIMD(s, '/'));
            try std.testing.expectEqual(mem.lastIndexOfScalar(u8, s, '/'), lastIndexOfAnyTwoSIMD(s, '/', '\\'));
            s[pos] = '\\';
            try std.testing.expectEqual(mem.lastIndexOfAny(u8, s, "/\\"), lastIndexOfAnyTwoSIMD(s, '/', '\\'));
            // 0x80-class bytes around the needle exercise the SWAR carry path
            if (pos + 1 < len) s[pos + 1] = 0xff;
            if (pos > 0) s[pos - 1] = 0x80;
            try std.testing.expectEqual(mem.lastIndexOfAny(u8, s, "/\\"), lastIndexOfAnyTwoSIMD(s, '/', '\\'));
            try std.testing.expectEqual(mem.lastIndexOfScalar(u8, s, '/'), lastIndexOfCharSIMD(s, '/'));
        }
    }
}

pub fn firstWildcardPos(pattern: []const u8, flags: ZlobFlags) usize {
    // On Windows backslash is a path separator, not an escape character.
    const enable_escape = !flags.noescape and !path_sep_is_windows;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const ch = pattern[i];
        if (enable_escape and ch == '\\' and i + 1 < pattern.len) break;
        if (ch == '[') break;
        if (ch == '{' and flags.brace) break;
        if (flags.extglob and i + 1 < pattern.len and pattern[i + 1] == '(') {
            switch (ch) {
                '?', '*', '+', '@', '!' => break,
                else => {},
            }
        }
        if (ch == '*' or ch == '?') break;
    }
    return i;
}

/// Internal SIMD-accelerated check for basic glob wildcards (*, ?, [).
/// Used internally where only basic wildcard detection is needed (pattern fragments,
/// suffix checks, etc.) and brace/extglob detection is not applicable.
pub fn hasWildcardsBasic(s: []const u8) bool {
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (s.len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const star_vec: Vec = @splat('*');
        const question_vec: Vec = @splat('?');
        const bracket_vec: Vec = @splat('[');

        var i: usize = 0;
        while (i + vec_len <= s.len) : (i += vec_len) {
            const chunk: Vec = s[i..][0..vec_len].*;
            const has_star = chunk == star_vec;
            const has_question = chunk == question_vec;
            const has_bracket = chunk == bracket_vec;
            const combined = has_star | has_question | has_bracket;
            const mask = @as(MaskInt, @bitCast(combined));
            if (mask != 0) return true;
        }
        for (s[i..]) |ch| {
            if (ch == '*' or ch == '?' or ch == '[') return true;
        }
        return false;
    }
    for (s) |ch| {
        if (ch == '*' or ch == '?' or ch == '[') return true;
    }
    return false;
}

/// Check if pattern contains extglob sequences: ?( *( +( @( !(
/// These are two-character sequences where the second char is '('
/// Uses SIMD to quickly scan for '(' characters, then checks preceding byte.
pub fn containsExtglob(s: []const u8) bool {
    if (s.len < 2) return false;

    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (s.len >= vec_len + 1) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const paren_vec: Vec = @splat('(');

        // Start from index 1 since we need to check s[i-1]
        var i: usize = 1;
        while (i + vec_len <= s.len) : (i += vec_len) {
            const chunk: Vec = s[i..][0..vec_len].*;
            const mask = @as(MaskInt, @bitCast(chunk == paren_vec));
            if (mask != 0) {
                // Found '(' in this chunk - check preceding bytes
                var remaining_mask = mask;
                while (remaining_mask != 0) {
                    const bit_pos = @ctz(remaining_mask);
                    const paren_idx = i + bit_pos;
                    // Check if preceding character is an extglob prefix
                    switch (s[paren_idx - 1]) {
                        '?', '*', '+', '@', '!' => return true,
                        else => {},
                    }
                    // Clear this bit
                    remaining_mask &= remaining_mask - 1;
                }
            }
        }

        // Handle remainder
        while (i < s.len) : (i += 1) {
            if (s[i] == '(') {
                switch (s[i - 1]) {
                    '?', '*', '+', '@', '!' => return true,
                    else => {},
                }
            }
        }
        return false;
    }

    // Fallback for short strings
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i + 1] == '(') {
            switch (s[i]) {
                '?', '*', '+', '@', '!' => return true,
                else => {},
            }
        }
    }
    return false;
}

/// Unified SIMD-accelerated detection of glob special characters in a pattern.
///
/// Checks for the presence of glob metacharacters in a single SIMD pass:
/// - Always checks: `*`, `?`, `[` (basic wildcards)
/// - When `flags.brace` is set: also checks for `{` (brace expansion)
/// - When `flags.extglob` is set: also checks for extglob sequences `?(`, `*(`, `+(`, `@(`, `!(`
///
/// Returns true if the pattern contains any active glob syntax that would require
/// pattern matching rather than literal string comparison.
///
/// This is the public API function for determining whether a string is a glob pattern.
pub fn hasWildcards(s: []const u8, flags: ZlobFlags) bool {
    const check_braces = flags.brace;
    const check_extglob = flags.extglob;

    // Fast path: no extra checks needed, use basic wildcard detection
    if (!check_braces and !check_extglob) return hasWildcardsBasic(s);

    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (s.len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const star_vec: Vec = @splat('*');
        const question_vec: Vec = @splat('?');
        const bracket_vec: Vec = @splat('[');

        var i: usize = 0;
        while (i + vec_len <= s.len) : (i += vec_len) {
            const chunk: Vec = s[i..][0..vec_len].*;

            // Check basic wildcards
            const has_star = chunk == star_vec;
            const has_question = chunk == question_vec;
            const has_bracket = chunk == bracket_vec;
            var combined = has_star | has_question | has_bracket;

            // Check braces if enabled
            if (check_braces) {
                const brace_vec: Vec = @splat('{');
                combined = combined | (chunk == brace_vec);
            }

            const wildcard_mask = @as(MaskInt, @bitCast(combined));
            if (wildcard_mask != 0) return true;

            // Check for extglob patterns: prefix + '('
            if (check_extglob) {
                const paren_vec: Vec = @splat('(');
                const paren_mask = @as(MaskInt, @bitCast(chunk == paren_vec));
                if (paren_mask != 0) {
                    var remaining = paren_mask;
                    while (remaining != 0) {
                        const bit_pos = @ctz(remaining);
                        const paren_idx = i + bit_pos;
                        if (paren_idx > 0) {
                            switch (s[paren_idx - 1]) {
                                '?', '*', '+', '@', '!' => return true,
                                else => {},
                            }
                        }
                        remaining &= remaining - 1;
                    }
                }
            }
        }

        // Handle remainder
        for (s[i..], i..) |ch, idx| {
            if (ch == '*' or ch == '?' or ch == '[') return true;
            if (check_braces and ch == '{') return true;
            if (check_extglob and ch == '(' and idx > 0) {
                switch (s[idx - 1]) {
                    '?', '*', '+', '@', '!' => return true,
                    else => {},
                }
            }
        }
        return false;
    }

    // Fallback for short strings
    for (s, 0..) |ch, idx| {
        if (ch == '*' or ch == '?' or ch == '[') return true;
        if (check_braces and ch == '{') return true;
        if (check_extglob and ch == '(' and idx > 0) {
            switch (s[idx - 1]) {
                '?', '*', '+', '@', '!' => return true,
                else => {},
            }
        }
    }
    return false;
}
