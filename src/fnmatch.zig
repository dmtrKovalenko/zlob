//! Unified fnmatch implementation with all optimizations
//!
//! This module provides pattern matching with:
//! - SIMD-accelerated literal prefix matching
//! - Template-based fast paths for common patterns (*.ext, prefix*, etc.)
//! - Bitmap-based bracket expression matching
//! - Optional extglob support (?(), *(), +(), @(), !())
//! - POSIX escape sequence handling

const std = @import("std");
const mem = std.mem;
const pattern_context_mod = @import("pattern_context.zig");
const extglob = @import("extglob.zig");
const suffix_match = @import("suffix_match.zig");

pub const PatternContext = pattern_context_mod.PatternContext;
pub const hasWildcards = pattern_context_mod.hasWildcardsSIMD;

// Extglob initialization state
var extglob_initialized = false;

/// Wrapper for extglob callback - uses default escapes=true
fn matchForExtglob(pattern: []const u8, string: []const u8) bool {
    return matchCore(pattern, string, true);
}

/// Initialize extglob module (lazy, thread-safe via atomic)
inline fn ensureExtglobInit() void {
    if (!@atomicLoad(bool, &extglob_initialized, .acquire)) {
        extglob.initFnmatch(&matchForExtglob);
        @atomicStore(bool, &extglob_initialized, true, .release);
    }
}

/// Options for pattern matching
pub const MatchOptions = struct {
    /// Enable extglob patterns: ?() *() +() @() !()
    extglob: bool = false,
    /// Enable POSIX escape sequences (backslash quotes next char)
    escapes: bool = true,
};

/// Match a string against a pattern with full optimization.
/// This is the main entry point - use this for all pattern matching.
pub inline fn match(pattern: []const u8, string: []const u8, options: MatchOptions) bool {
    // Check for extglob patterns first (if enabled)
    if (options.extglob and extglob.containsExtglob(pattern)) {
        ensureExtglobInit();
        return extglob.fnmatchExtglob(pattern, string);
    }
    return matchCore(pattern, string, options.escapes);
}

/// Match using a pre-computed PatternContext for repeated matching against same pattern.
/// More efficient when matching many strings against the same pattern.
pub inline fn matchWithContext(ctx: *const PatternContext, string: []const u8, options: MatchOptions) bool {
    // Check for extglob patterns first (if enabled)
    if (options.extglob and extglob.containsExtglob(ctx.pattern)) {
        ensureExtglobInit();
        return extglob.fnmatchExtglob(ctx.pattern, string);
    }

    // Early rejection: if we know the required last character and it doesn't match, reject immediately
    if (ctx.required_last_char) |required_last| {
        if (string.len == 0 or string[string.len - 1] != required_last) {
            return false;
        }
    }

    // Try template-based fast path first
    if (ctx.matchTemplate(string)) |result| {
        return result;
    }

    // Fast path: exact match with SIMD for long strings (only if no wildcards)
    if (ctx.pattern.len == string.len and !ctx.has_wildcards) {
        if (ctx.pattern.len >= 32) {
            const Vec32 = @Vector(32, u8);
            var i: usize = 0;
            while (i + 32 <= ctx.pattern.len) : (i += 32) {
                const p_vec: Vec32 = ctx.pattern[i..][0..32].*;
                const s_vec: Vec32 = string[i..][0..32].*;
                const eq = p_vec == s_vec;
                const mask = @as(u32, @bitCast(eq));
                if (mask != 0xFFFFFFFF) return false;
            }
            return mem.eql(u8, ctx.pattern[i..], string[i..]);
        }
        return mem.eql(u8, ctx.pattern, string);
    }

    // Try suffix match optimization
    if (ctx.only_suffix_match) |suffix_matcher| {
        return suffix_matcher.match(string);
    }

    return matchCore(ctx.pattern, string, options.escapes);
}

/// Core matching logic - handles wildcards, brackets, escapes
pub fn matchCore(pattern: []const u8, string: []const u8, enable_escapes: bool) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: usize = 0;
    var star_si: usize = 0;
    var have_star = false;

    while (si < string.len or pi < pattern.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];

            // Handle escape sequences
            if (enable_escapes and pc == '\\' and pi + 1 < pattern.len) {
                pi += 1;
                if (si < string.len and pattern[pi] == string[si]) {
                    pi += 1;
                    si += 1;
                    continue;
                }
                if (have_star) {
                    pi = star_pi;
                    star_si += 1;
                    si = star_si;
                    continue;
                }
                return false;
            }

            switch (pc) {
                '*' => {
                    star_pi = pi + 1;
                    star_si = si;
                    have_star = true;
                    pi += 1;
                    continue;
                },
                '?' => {
                    if (si < string.len) {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                },
                '[' => {
                    if (si < string.len) {
                        if (matchBracket(pattern, pi, string[si])) |new_pi| {
                            pi = new_pi;
                            si += 1;
                            continue;
                        }
                    }
                },
                else => {
                    if (si < string.len and pc == string[si]) {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                },
            }
        }

        // No match at current position
        if (have_star and star_si < string.len) {
            pi = star_pi;
            star_si += 1;
            si = star_si;
            continue;
        }

        return false;
    }

    return true;
}

/// Match a bracket expression, returns new pattern index if matched
fn matchBracket(pattern: []const u8, start: usize, ch: u8) ?usize {
    var pi = start + 1;
    if (pi >= pattern.len) return null;

    var negated = false;
    if (pattern[pi] == '!' or pattern[pi] == '^') {
        negated = true;
        pi += 1;
    }

    // ] as first char is literal
    var first = true;
    var matched = false;

    while (pi < pattern.len) {
        const c = pattern[pi];

        if (c == ']' and !first) {
            return if (matched != negated) pi + 1 else null;
        }

        first = false;

        // Check for range
        if (pi + 2 < pattern.len and pattern[pi + 1] == '-' and pattern[pi + 2] != ']') {
            const range_start = c;
            const range_end = pattern[pi + 2];
            if (range_start <= range_end) {
                if (ch >= range_start and ch <= range_end) {
                    matched = true;
                }
            }
            pi += 3;
        } else {
            if (c == ch) {
                matched = true;
            }
            pi += 1;
        }
    }

    return null;
}

// Tests
test "match - basic patterns" {
    try std.testing.expect(match("*.txt", "file.txt", .{}));
    try std.testing.expect(!match("*.txt", "file.log", .{}));
    try std.testing.expect(match("test?", "test1", .{}));
    try std.testing.expect(!match("test?", "test12", .{}));
}

test "match - bracket expressions" {
    try std.testing.expect(match("[abc]", "a", .{}));
    try std.testing.expect(match("[abc]", "b", .{}));
    try std.testing.expect(!match("[abc]", "d", .{}));
    try std.testing.expect(match("[a-z]", "m", .{}));
    try std.testing.expect(!match("[a-z]", "5", .{}));
}

test "match - escape sequences" {
    try std.testing.expect(match("\\*", "*", .{}));
    try std.testing.expect(!match("\\*", "a", .{}));
    try std.testing.expect(match("\\?", "?", .{}));
}

test "match - empty patterns" {
    try std.testing.expect(match("", "", .{}));
    try std.testing.expect(!match("", "a", .{}));
    try std.testing.expect(match("*", "", .{}));
    try std.testing.expect(match("*", "anything", .{}));
}
