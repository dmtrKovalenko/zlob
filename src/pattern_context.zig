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

    pub inline fn init(pattern: []const u8) PatternContext {
        const has_wildcards = hasWildcardsSIMD(pattern);

        const starts_with_dot = pattern.len > 0 and pattern[0] == '.';
        const is_dot_or_dotdot = mem.eql(u8, pattern, ".") or mem.eql(u8, pattern, "..");
        const simd_batched_suffix_match, const only_suffix_match = if (has_wildcards)
            suffix_match.check_simple_star_sufix(pattern)
        else
            .{ null, null };

        const required_last_char = extractRequiredLastChar(pattern);
        const template_info = detectPatternTemplate(pattern, has_wildcards);

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
            .none => null, // No fast path — most common case, check first
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

/// Detect the pattern template for fast-path matching.
/// Accepts pre-computed has_wildcards to avoid redundant SIMD scan.
fn detectPatternTemplate(pattern: []const u8, has_wildcards: bool) struct { template: PatternTemplate, prefix: []const u8, suffix: []const u8, bracket_bitmap: ?BracketBitmap } {
    // Check for escape sequences once - used by both branches
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

/// SIMD-accelerated lastIndexOf for a single byte. Returns the index of last occurrence.
pub fn lastIndexOfCharSIMD(s: []const u8, needle: u8) ?usize {
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
    const MaskInt = std.meta.Int(.unsigned, vec_len);

    if (s.len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const needle_vec: Vec = @splat(needle);
        // Start from the end, processing vec_len bytes at a time
        var i: usize = s.len;
        while (i >= vec_len) {
            i -= vec_len;
            const chunk: Vec = s[i..][0..vec_len].*;
            const mask = @as(MaskInt, @bitCast(chunk == needle_vec));
            if (mask != 0) {
                // Find highest set bit
                return i + vec_len - 1 - @clz(mask);
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

/// Check if pattern has wildcards or extglob patterns (when extglob is enabled).
/// When check_extglob is true, performs a single SIMD pass checking for all
/// special characters (*, ?, [, and extglob prefix+() simultaneously.
pub fn hasWildcardsOrExtglob(s: []const u8, check_extglob: bool) bool {
    if (!check_extglob) return hasWildcardsSIMD(s);

    // Combined single-pass check for wildcards AND extglob patterns
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (s.len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const star_vec: Vec = @splat('*');
        const question_vec: Vec = @splat('?');
        const bracket_vec: Vec = @splat('[');
        const paren_vec: Vec = @splat('(');

        var i: usize = 0;
        while (i + vec_len <= s.len) : (i += vec_len) {
            const chunk: Vec = s[i..][0..vec_len].*;

            // Check wildcards
            const has_star = chunk == star_vec;
            const has_question = chunk == question_vec;
            const has_bracket = chunk == bracket_vec;
            const wildcard_mask = @as(MaskInt, @bitCast(has_star | has_question | has_bracket));
            if (wildcard_mask != 0) return true;

            // Check for '(' which could be extglob
            const paren_mask = @as(MaskInt, @bitCast(chunk == paren_vec));
            if (paren_mask != 0) {
                // Check if any '(' is preceded by an extglob prefix
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

        // Handle remainder
        for (s[i..], i..) |ch, idx| {
            if (ch == '*' or ch == '?' or ch == '[') return true;
            if (ch == '(' and idx > 0) {
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
        if (ch == '(' and idx > 0) {
            switch (s[idx - 1]) {
                '?', '*', '+', '@', '!' => return true,
                else => {},
            }
        }
    }
    return false;
}
