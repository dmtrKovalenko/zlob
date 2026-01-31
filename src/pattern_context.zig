const std = @import("std");
const mem = std.mem;
const suffix_match = @import("suffix_match.zig");

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
    simd_batched_suffix_match: ?suffix_match.SimdBatchedSuffixMatch,
    only_suffix_match: ?suffix_match.SuffixMatch,

    pub fn init(pattern: []const u8) PatternContext {
        const has_wildcards = hasWildcardsSIMD(pattern);

        const starts_with_dot = pattern.len > 0 and pattern[0] == '.';
        const is_dot_or_dotdot = mem.eql(u8, pattern, ".") or mem.eql(u8, pattern, "..");
        const simd_batched_suffix_match, const only_suffix_match = if (has_wildcards)
            suffix_match.check_simple_star_sufix(pattern)
        else
            .{ null, null };

        // Extract required last character for early rejection
        const required_last_char = extractRequiredLastChar(pattern);

        // Detect pattern template and pre-compile bracket if applicable
        const template_info = detectPatternTemplate(pattern);

        return PatternContext{
            .pattern = pattern,
            .has_wildcards = has_wildcards,
            .simd_batched_suffix_match = simd_batched_suffix_match,
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
        return switch (self.template) {
            .literal => mem.eql(u8, self.pattern, string),
            .star_only => true, // * matches anything
            .star_dot_ext => {
                // *.ext - just check suffix
                if (string.len < self.template_suffix.len) return false;
                return mem.eql(u8, string[string.len - self.template_suffix.len ..], self.template_suffix);
            },
            .prefix_star => {
                // prefix* - just check prefix
                if (string.len < self.template_prefix.len) return false;
                return mem.eql(u8, string[0..self.template_prefix.len], self.template_prefix);
            },
            .prefix_star_ext => {
                // prefix*.ext - check both prefix and suffix
                const min_len = self.template_prefix.len + self.template_suffix.len;
                if (string.len < min_len) return false;
                if (!mem.eql(u8, string[0..self.template_prefix.len], self.template_prefix)) return false;
                return mem.eql(u8, string[string.len - self.template_suffix.len ..], self.template_suffix);
            },
            .bracket_with_affixes => {
                // prefix[charset]suffix - check prefix, suffix, and single char in bracket
                const expected_len = self.template_prefix.len + 1 + self.template_suffix.len;
                if (string.len != expected_len) return false;
                if (!mem.eql(u8, string[0..self.template_prefix.len], self.template_prefix)) return false;
                if (!mem.eql(u8, string[string.len - self.template_suffix.len ..], self.template_suffix)) return false;
                // Check the bracket character
                const bracket_char = string[self.template_prefix.len];
                if (self.bracket_bitmap) |*bm| {
                    return bm.matches(bracket_char);
                }
                return null;
            },
            .none => null, // No fast path
        };
    }
};

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

/// Detect the pattern template for fast-path matching
fn detectPatternTemplate(pattern: []const u8) struct { template: PatternTemplate, prefix: []const u8, suffix: []const u8, bracket_bitmap: ?BracketBitmap } {
    // Check for literal (no wildcards)
    if (!hasWildcardsSIMD(pattern)) {
        return .{ .template = .literal, .prefix = pattern, .suffix = "", .bracket_bitmap = null };
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

            // Set all bits in range
            if (c <= range_end) {
                var ch = c;
                while (ch <= range_end) : (ch += 1) {
                    bitmap.bitmap[ch >> 3] |= @as(u8, 1) << @as(u3, @truncate(ch & 7));
                    if (ch == 255) break;
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
    if (s.len >= 32) {
        const Vec32 = @Vector(32, u8);
        const needle_vec: Vec32 = @splat(needle);
        var i: usize = 0;
        while (i + 32 <= s.len) : (i += 32) {
            const chunk: Vec32 = s[i..][0..32].*;
            const mask = @as(u32, @bitCast(chunk == needle_vec));
            if (mask != 0) return i + @ctz(mask);
        }

        for (s[i..], i..) |c, idx| {
            if (c == needle) return idx;
        }
        return null;
    }
    return mem.indexOfScalar(u8, s, needle);
}

/// SIMD-accelerated lastIndexOf for a single byte. Returns the index of last occurrence.
pub fn lastIndexOfCharSIMD(s: []const u8, needle: u8) ?usize {
    if (s.len >= 32) {
        const Vec32 = @Vector(32, u8);
        const needle_vec: Vec32 = @splat(needle);
        // Start from the end, processing 32 bytes at a time
        var i: usize = s.len;
        while (i >= 32) {
            i -= 32;
            const chunk: Vec32 = s[i..][0..32].*;
            const mask = @as(u32, @bitCast(chunk == needle_vec));
            if (mask != 0) {
                // Find highest set bit (31 - leading zeros)
                return i + 31 - @clz(mask);
            }
        }
        // Handle remainder at start (scan backwards)
        if (i > 0) {
            var j: usize = i;
            while (j > 0) {
                j -= 1;
                if (s[j] == needle) return j;
            }
        }
        return null;
    }
    return mem.lastIndexOfScalar(u8, s, needle);
}

pub fn hasWildcardsSIMD(s: []const u8) bool {
    if (s.len >= 32) {
        const Vec32 = @Vector(32, u8);
        const star_vec: Vec32 = @splat('*');
        const question_vec: Vec32 = @splat('?');
        const bracket_vec: Vec32 = @splat('[');

        var i: usize = 0;
        while (i + 32 <= s.len) : (i += 32) {
            const chunk: Vec32 = s[i..][0..32].*;
            const has_star = chunk == star_vec;
            const has_question = chunk == question_vec;
            const has_bracket = chunk == bracket_vec;
            const combined = has_star | has_question | has_bracket;
            const mask = @as(u32, @bitCast(combined));
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
pub fn containsExtglob(s: []const u8) bool {
    if (s.len < 2) return false;

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

/// Check if pattern has wildcards or extglob patterns (when extglob is enabled)
pub fn hasWildcardsOrExtglob(s: []const u8, check_extglob: bool) bool {
    if (hasWildcardsSIMD(s)) return true;
    if (check_extglob and containsExtglob(s)) return true;
    return false;
}
