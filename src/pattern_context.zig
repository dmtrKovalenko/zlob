const std = @import("std");
const mem = std.mem;
const suffix_match = @import("suffix_match.zig");

/// Fast pattern context created for every independent pattern block.
/// Pre-computes pattern analysis to avoid redundant work during matching.
pub const PatternContext = struct {
    pattern: []const u8,
    has_wildcards: bool, // Pattern contains wildcards
    starts_with_dot: bool, // Pattern starts with '.'
    is_dot_or_dotdot: bool, // Pattern is exactly "." or ".."

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

        return PatternContext{
            .pattern = pattern,
            .has_wildcards = has_wildcards,
            .simd_batched_suffix_match = simd_batched_suffix_match,
            .only_suffix_match = only_suffix_match,
            .starts_with_dot = starts_with_dot,
            .is_dot_or_dotdot = is_dot_or_dotdot,
        };
    }
};

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
