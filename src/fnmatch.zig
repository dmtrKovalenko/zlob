//! Unified pattern matching with SIMD optimizations and extglob support
//!
//! This module is the SINGLE source of truth for all fnmatch-style pattern matching.
//! All matching in zlob routes through here. Key design:
//!
//! - Iterative star-tracking for `*` wildcards (O(1) stack, zero recursion)
//! - SIMD-accelerated character search and exact matching
//! - Bitmap-based bracket expression matching with POSIX character classes
//! - Template-based fast paths via PatternContext (*.ext, prefix*, etc.)
//! - Extended glob support: ?() *() +() @() !()
//! - POSIX escape sequence handling

const std = @import("std");
const mem = std.mem;
const pattern_context_mod = @import("pattern_context.zig");
const suffix_match = @import("suffix_match.zig");
const flags_mod = @import("zlob_flags");

pub const ZlobFlags = flags_mod.ZlobFlags;
pub const PatternContext = pattern_context_mod.PatternContext;
pub const hasWildcardsWithFlags = pattern_context_mod.hasWildcards;
pub const hasWildcardsBasic = pattern_context_mod.hasWildcardsBasic;
pub const containsExtglob = pattern_context_mod.containsExtglob;

/// Check if a pattern contains any glob special characters.
/// Detects all glob syntax: basic wildcards (*, ?, [), braces ({), and extglob patterns.
pub fn hasWildcards(s: []const u8) bool {
    return pattern_context_mod.hasWildcards(s, .{ .brace = true, .extglob = true });
}

/// Match a string against a pattern with flags.
pub inline fn fnmatch(pattern: []const u8, string: []const u8, flags: ZlobFlags) bool {
    if (flags.extglob and containsExtglob(pattern)) {
        return matchExtglob(pattern, string);
    }
    return fnmatchCore(pattern, string, !flags.noescape);
}

/// Match using a pre-computed PatternContext for repeated matching against the same pattern.
/// Applies all fast-path optimizations (template, suffix, SIMD exact) before falling back
/// to the full iterative matcher.
pub inline fn fnmatchWithContext(ctx: *const PatternContext, string: []const u8, flags: ZlobFlags) bool {
    if (flags.extglob and containsExtglob(ctx.pattern)) {
        return matchExtglob(ctx.pattern, string);
    }

    if (ctx.required_last_char) |required_last| {
        if (string.len == 0 or string[string.len - 1] != required_last) {
            return false;
        }
    }

    // this is mostly useful for character classes for posix support pretty cheap for any other checks
    if (ctx.matchTemplate(string)) |result| {
        return result;
    }

    if (ctx.pattern.len == string.len and !ctx.has_wildcards) {
        return simdEqual(ctx.pattern, string);
    }

    if (ctx.only_suffix_match) |suffix_matcher| {
        return suffix_matcher.match(string);
    }

    return fnmatchCore(ctx.pattern, string, !flags.noescape);
}

fn fnmatchCore(pattern: []const u8, string: []const u8, enable_escapes: bool) bool {
    var pi: usize = 0;
    var si: usize = 0;

    // Fast path: scan literal prefix before first wildcard or escape.
    // This avoids per-character switch overhead for the common case of
    // patterns like "src/foo/bar*.zig" where most chars are literal.
    while (pi < pattern.len) {
        const p = pattern[pi];
        if (p == '*' or p == '?' or p == '[') break;
        if (enable_escapes and p == '\\') break;
        if (si >= string.len or string[si] != p) return false;
        pi += 1;
        si += 1;
    }

    // If pattern exhausted after literal prefix, check if string also exhausted
    if (pi >= pattern.len) return si == string.len;

    // Saved positions for star backtracking (only one star needs to be active
    // at a time — a new star supersedes the previous one)
    var star_pi: usize = 0;
    var star_si: usize = 0;
    var have_star = false;

    while (si < string.len or pi < pattern.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];

            // Handle POSIX escape sequences
            if (enable_escapes and pc == '\\') {
                if (pi + 1 < pattern.len) {
                    pi += 1; // skip backslash, look at escaped char
                    if (si < string.len and pattern[pi] == string[si]) {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                } else {
                    // Trailing backslash — match literal backslash
                    if (si < string.len and string[si] == '\\') {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                }
                // Fall through to star backtrack
                if (have_star and star_si < string.len) {
                    pi = star_pi;
                    star_si += 1;
                    si = star_si;
                    continue;
                }
                return false;
            }

            switch (pc) {
                '*' => {
                    // Skip consecutive stars (** treated same as * here)
                    pi += 1;
                    while (pi < pattern.len and pattern[pi] == '*') pi += 1;

                    // If star is at end of pattern, it matches everything
                    if (pi >= pattern.len) return true;

                    // SIMD optimization: if the next pattern char after * is a literal,
                    // use simdFindChar to jump directly to candidate positions in the
                    // string instead of advancing one char at a time on each backtrack.
                    const next_pc = pattern[pi];
                    const next_is_literal = next_pc != '*' and next_pc != '?' and next_pc != '[' and
                        !(enable_escapes and next_pc == '\\');
                    if (next_is_literal) {
                        // Find next occurrence of the literal char starting from si
                        if (simdFindChar(string[si..], next_pc)) |offset| {
                            star_pi = pi;
                            star_si = si + offset; // will be incremented on backtrack
                            si = si + offset;
                            have_star = true;
                        } else {
                            // Literal char not found anywhere — no match possible
                            return false;
                        }
                    } else {
                        // Save position for backtracking
                        star_pi = pi;
                        star_si = si;
                        have_star = true;
                    }
                    continue;
                },
                '?' => {
                    if (si < string.len) {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                    // else fall through to star backtrack
                },
                '[' => {
                    if (si < string.len) {
                        const result = matchBracketBitmap(pattern, pi, string[si]);
                        if (result.matched) {
                            pi = result.new_pi;
                            si += 1;
                            continue;
                        }
                    }
                    // else fall through to star backtrack
                },
                else => {
                    if (si < string.len and pc == string[si]) {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                    // else fall through to star backtrack
                },
            }
        }

        // Mismatch — try to backtrack to last star
        if (have_star and star_si < string.len) {
            star_si += 1;
            // SIMD-accelerated backtrack: if the char after * is a literal,
            // jump to its next occurrence instead of trying every position
            if (star_pi < pattern.len) {
                const next_pc = pattern[star_pi];
                const next_is_literal = next_pc != '*' and next_pc != '?' and next_pc != '[' and
                    !(enable_escapes and next_pc == '\\');
                if (next_is_literal) {
                    if (simdFindChar(string[star_si..], next_pc)) |offset| {
                        star_si += offset;
                    } else {
                        return false;
                    }
                }
            }
            pi = star_pi;
            si = star_si;
            continue;
        }

        return false;
    }

    return true;
}

// ============================================================================
// SIMD utilities
// ============================================================================

/// SIMD-accelerated character search. Returns index of first occurrence of needle.
pub fn simdFindChar(haystack: []const u8, needle: u8) ?usize {
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

    if (haystack.len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const needle_vec: Vec = @splat(needle);

        var i: usize = 0;
        while (i + vec_len <= haystack.len) : (i += vec_len) {
            const chunk: Vec = haystack[i..][0..vec_len].*;
            const matches = chunk == needle_vec;
            const mask = @as(MaskInt, @bitCast(matches));
            if (mask != 0) {
                return i + @ctz(mask);
            }
        }
        for (haystack[i..], i..) |ch, idx| {
            if (ch == needle) return idx;
        }
        return null;
    }
    // Fallback for short strings
    for (haystack, 0..) |ch, idx| {
        if (ch == needle) return idx;
    }
    return null;
}

/// SIMD-accelerated equality check for two equal-length byte slices.
fn simdEqual(a: []const u8, b: []const u8) bool {
    std.debug.assert(a.len == b.len);
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
    if (a.len >= vec_len) {
        const Vec = @Vector(vec_len, u8);
        const MaskInt = std.meta.Int(.unsigned, vec_len);
        const all_ones: MaskInt = @as(MaskInt, 0) -% 1;
        var i: usize = 0;
        while (i + vec_len <= a.len) : (i += vec_len) {
            const av: Vec = a[i..][0..vec_len].*;
            const bv: Vec = b[i..][0..vec_len].*;
            if (@as(MaskInt, @bitCast(av == bv)) != all_ones) return false;
        }
        return mem.eql(u8, a[i..], b[i..]);
    }
    return mem.eql(u8, a, b);
}

// ============================================================================
// Bracket expression matching (bitmap-based)
// ============================================================================

/// Match a bracket expression starting at pattern[bracket_pos] (the '[').
/// Returns whether the character matched and the pattern index after the closing ']'.
/// Handles negation (! and ^), ranges (a-z), and POSIX classes ([[:alpha:]]).
inline fn matchBracketBitmap(pattern: []const u8, bracket_pos: usize, ch: u8) struct { matched: bool, new_pi: usize } {
    var pi = bracket_pos + 1; // skip '['
    if (pi >= pattern.len) return .{ .matched = false, .new_pi = pi };

    var negate = false;
    if (pattern[pi] == '!' or pattern[pi] == '^') {
        negate = true;
        pi += 1;
    }

    const bracket_start = pi;

    // Build a 256-bit bitmap for the character set
    var bitmap: [32]u8 = [_]u8{0} ** 32;

    while (pi < pattern.len) {
        const set_c = pattern[pi];

        // First character is always part of set (even if it's ']')
        if (set_c == ']' and pi > bracket_start) break;

        // Check for POSIX character class [[:class:]]
        if (set_c == '[' and pi + 2 < pattern.len and pattern[pi + 1] == ':') {
            const class_result = parsePosixCharClass(pattern, pi);
            if (class_result.valid) {
                addPosixClassToBitmap(&bitmap, class_result.class_type);
                pi = class_result.end_pi;
                continue;
            }
        }

        pi += 1;

        if (pi + 1 < pattern.len and pattern[pi] == '-' and pattern[pi + 1] != ']') {
            // Range like [a-z]
            pi += 1;
            const range_end = pattern[pi];
            pi += 1;
            if (set_c <= range_end) {
                var range_c = set_c;
                while (range_c <= range_end) : (range_c += 1) {
                    bitmap[range_c >> 3] |= @as(u8, 1) << @as(u3, @truncate(range_c & 7));
                    if (range_c == 255) break;
                }
            }
        } else {
            // Single character
            bitmap[set_c >> 3] |= @as(u8, 1) << @as(u3, @truncate(set_c & 7));
        }
    }

    // Skip the closing ']'
    if (pi < pattern.len and pattern[pi] == ']') pi += 1;

    // Branchless bitmap lookup
    var matched = (bitmap[ch >> 3] & (@as(u8, 1) << @as(u3, @truncate(ch & 7)))) != 0;
    if (negate) matched = !matched;

    return .{ .matched = matched, .new_pi = pi };
}

const PosixCharClass = enum {
    alpha,
    digit,
    alnum,
    space,
    blank,
    lower,
    upper,
    punct,
    xdigit,
    cntrl,
    graph,
    print,
    invalid,
};

fn parsePosixCharClass(pattern: []const u8, start_pi: usize) struct { valid: bool, class_type: PosixCharClass, end_pi: usize } {
    if (start_pi + 2 >= pattern.len) return .{ .valid = false, .class_type = .invalid, .end_pi = start_pi };
    if (pattern[start_pi] != '[' or pattern[start_pi + 1] != ':') {
        return .{ .valid = false, .class_type = .invalid, .end_pi = start_pi };
    }

    var pi = start_pi + 2;
    const class_start = pi;

    while (pi + 1 < pattern.len) {
        if (pattern[pi] == ':' and pattern[pi + 1] == ']') {
            const class_name = pattern[class_start..pi];
            const class_type = getPosixClassType(class_name);
            if (class_type != .invalid) {
                return .{ .valid = true, .class_type = class_type, .end_pi = pi + 2 };
            }
            return .{ .valid = false, .class_type = .invalid, .end_pi = start_pi };
        }
        pi += 1;
    }

    return .{ .valid = false, .class_type = .invalid, .end_pi = start_pi };
}

fn getPosixClassType(name: []const u8) PosixCharClass {
    if (mem.eql(u8, name, "alpha")) return .alpha;
    if (mem.eql(u8, name, "digit")) return .digit;
    if (mem.eql(u8, name, "alnum")) return .alnum;
    if (mem.eql(u8, name, "space")) return .space;
    if (mem.eql(u8, name, "blank")) return .blank;
    if (mem.eql(u8, name, "lower")) return .lower;
    if (mem.eql(u8, name, "upper")) return .upper;
    if (mem.eql(u8, name, "punct")) return .punct;
    if (mem.eql(u8, name, "xdigit")) return .xdigit;
    if (mem.eql(u8, name, "cntrl")) return .cntrl;
    if (mem.eql(u8, name, "graph")) return .graph;
    if (mem.eql(u8, name, "print")) return .print;
    return .invalid;
}

fn addPosixClassToBitmap(bitmap: *[32]u8, class_type: PosixCharClass) void {
    switch (class_type) {
        .alpha => {
            addRangeToBitmap(bitmap, 'A', 'Z');
            addRangeToBitmap(bitmap, 'a', 'z');
        },
        .digit => {
            addRangeToBitmap(bitmap, '0', '9');
        },
        .alnum => {
            addRangeToBitmap(bitmap, 'A', 'Z');
            addRangeToBitmap(bitmap, 'a', 'z');
            addRangeToBitmap(bitmap, '0', '9');
        },
        .space => {
            const space_chars = [_]u8{ ' ', '\t', '\n', '\r', 0x0C, 0x0B };
            for (space_chars) |sc| {
                bitmap[sc >> 3] |= @as(u8, 1) << @as(u3, @truncate(sc & 7));
            }
        },
        .blank => {
            bitmap[' ' >> 3] |= @as(u8, 1) << @as(u3, @truncate(' ' & 7));
            bitmap['\t' >> 3] |= @as(u8, 1) << @as(u3, @truncate('\t' & 7));
        },
        .lower => {
            addRangeToBitmap(bitmap, 'a', 'z');
        },
        .upper => {
            addRangeToBitmap(bitmap, 'A', 'Z');
        },
        .punct => {
            const punct_chars = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";
            for (punct_chars) |pc| {
                bitmap[pc >> 3] |= @as(u8, 1) << @as(u3, @truncate(pc & 7));
            }
        },
        .xdigit => {
            addRangeToBitmap(bitmap, '0', '9');
            addRangeToBitmap(bitmap, 'A', 'F');
            addRangeToBitmap(bitmap, 'a', 'f');
        },
        .cntrl => {
            addRangeToBitmap(bitmap, 0x00, 0x1F);
            bitmap[0x7F >> 3] |= @as(u8, 1) << @as(u3, @truncate(0x7F & 7));
        },
        .graph => {
            addRangeToBitmap(bitmap, 0x21, 0x7E);
        },
        .print => {
            addRangeToBitmap(bitmap, 0x20, 0x7E);
        },
        .invalid => {},
    }
}

inline fn addRangeToBitmap(bitmap: *[32]u8, start: u8, end: u8) void {
    var ch: u8 = start;
    while (ch <= end) : (ch += 1) {
        bitmap[ch >> 3] |= @as(u8, 1) << @as(u3, @truncate(ch & 7));
        if (ch == 255) break;
    }
}

// Extended glob from bash (extglob)
//
// Implements bash-style extended globbing patterns:
// - ?(pattern-list) - zero or one occurrence
// - *(pattern-list) - zero or more occurrences
// - +(pattern-list) - one or more occurrences
// - @(pattern-list) - exactly one of the patterns
// - !(pattern-list) - anything except the patterns
//
// Pattern-list is '|'-separated. Nested extglobs are NOT supported.
// Standalone !(pattern) at pattern start is NOT supported; use *.!(js) instead.

pub const ExtglobType = enum {
    /// ?(pattern-list) - zero or one occurrence
    question,
    /// *(pattern-list) - zero or more occurrences
    star,
    /// +(pattern-list) - one or more occurrences
    plus,
    /// @(pattern-list) - exactly one of the patterns
    at,
    /// !(pattern-list) - anything except the patterns
    not,
};

/// Detect if an extglob starts at the given position.
pub fn detectExtglobAt(pattern: []const u8, pos: usize) ?ExtglobType {
    if (pos >= pattern.len) return null;
    if (pos + 1 >= pattern.len) return null;
    if (pattern[pos + 1] != '(') return null;

    return switch (pattern[pos]) {
        '?' => .question,
        '*' => .star,
        '+' => .plus,
        '@' => .at,
        '!' => .not,
        else => null,
    };
}

/// Find the matching closing parenthesis for an extglob.
/// Handles nested parentheses correctly.
pub fn findClosingParen(pattern: []const u8, open_pos: usize) ?usize {
    if (open_pos >= pattern.len or pattern[open_pos] != '(') return null;

    var depth: usize = 1;
    var i = open_pos + 1;

    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            '\\' => {
                if (i + 1 < pattern.len) i += 1;
            },
            else => {},
        }
    }

    return null;
}

// alternatives are not using the same code as braces because extglob
// is very complicated and allows absolute mixing of thos thus it's hard to keep
// the code shared (the extglob support was mostly written by llm)
pub fn splitAlternatives(content: []const u8, buffer: *[32][]const u8) [][]const u8 {
    var count: usize = 0;
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;

    while (i < content.len) : (i += 1) {
        switch (content[i]) {
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            '|' => {
                if (depth == 0) {
                    if (count < 32) {
                        buffer[count] = content[start..i];
                        count += 1;
                    }
                    start = i + 1;
                }
            },
            '\\' => {
                if (i + 1 < content.len) i += 1;
            },
            else => {},
        }
    }

    // Add the last alternative
    if (count < 32) {
        buffer[count] = content[start..];
        count += 1;
    }

    return buffer[0..count];
}

/// Match a string against a pattern containing extglob constructs.
pub fn matchExtglob(pattern: []const u8, string: []const u8) bool {
    return matchExtglobImpl(pattern, string, 0, 0);
}

fn matchExtglobImpl(pattern: []const u8, string: []const u8, pat_start: usize, str_start: usize) bool {
    var pi = pat_start;
    var si = str_start;

    // Saved positions for star backtracking
    var star_pi: usize = 0;
    var star_si: usize = 0;
    var have_star = false;

    while (si < string.len or pi < pattern.len) {
        if (pi < pattern.len) {
            // Check for extglob at current position
            if (detectExtglobAt(pattern, pi)) |ext_type| {
                const open_paren = pi + 1;
                const close_paren = findClosingParen(pattern, open_paren) orelse {
                    // Malformed extglob — treat prefix char as literal
                    if (si < string.len and string[si] == pattern[pi]) {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                    if (have_star and star_si < string.len) {
                        pi = star_pi;
                        star_si += 1;
                        si = star_si;
                        continue;
                    }
                    return false;
                };

                const content = pattern[open_paren + 1 .. close_paren];
                const rest_pattern = pattern[close_paren + 1 ..];

                var alt_buffer: [32][]const u8 = undefined;
                const alternatives = splitAlternatives(content, &alt_buffer);

                // Try matching the extglob construct.
                // If it succeeds, we're done (rest_pattern handles the tail).
                // If it fails and we have a saved star, backtrack.
                if (matchExtglobType(ext_type, alternatives, rest_pattern, string, si)) {
                    return true;
                }

                // Extglob didn't match — try star backtrack
                if (have_star and star_si < string.len) {
                    pi = star_pi;
                    star_si += 1;
                    si = star_si;
                    continue;
                }
                return false;
            }

            const ch = pattern[pi];

            switch (ch) {
                '*' => {
                    pi += 1;
                    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
                    star_pi = pi;
                    star_si = si;
                    have_star = true;
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
                        const result = matchBracketBitmap(pattern, pi, string[si]);
                        if (result.matched) {
                            pi = result.new_pi;
                            si += 1;
                            continue;
                        }
                    }
                },
                '\\' => {
                    if (pi + 1 < pattern.len) {
                        pi += 1;
                        if (si < string.len and pattern[pi] == string[si]) {
                            pi += 1;
                            si += 1;
                            continue;
                        }
                    }
                    // Fall through to star backtrack
                    if (have_star and star_si < string.len) {
                        pi = star_pi;
                        star_si += 1;
                        si = star_si;
                        continue;
                    }
                    return false;
                },
                else => {
                    if (si < string.len and ch == string[si]) {
                        pi += 1;
                        si += 1;
                        continue;
                    }
                },
            }
        }

        // Mismatch — try to backtrack to last star
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

fn matchExtglobType(
    ext_type: ExtglobType,
    alternatives: []const []const u8,
    rest_pattern: []const u8,
    string: []const u8,
    str_pos: usize,
) bool {
    return switch (ext_type) {
        .at => matchAt(alternatives, rest_pattern, string, str_pos),
        .question => matchQuestion(alternatives, rest_pattern, string, str_pos),
        .star => matchStar(alternatives, rest_pattern, string, str_pos),
        .plus => matchPlus(alternatives, rest_pattern, string, str_pos),
        .not => matchNot(alternatives, rest_pattern, string, str_pos),
    };
}

/// @(a|b) - Match exactly one of the alternatives
fn matchAt(alternatives: []const []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize) bool {
    for (alternatives) |alt| {
        if (tryMatchAlternative(alt, rest_pattern, string, str_pos)) return true;
    }
    return false;
}

/// ?(a|b) - Match zero or one occurrence
fn matchQuestion(alternatives: []const []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize) bool {
    // Zero occurrences
    if (matchExtglobImpl(rest_pattern, string, 0, str_pos)) return true;
    // One occurrence
    return matchAt(alternatives, rest_pattern, string, str_pos);
}

/// *(a|b) - Match zero or more occurrences
fn matchStar(alternatives: []const []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize) bool {
    // Zero occurrences
    if (matchExtglobImpl(rest_pattern, string, 0, str_pos)) return true;
    // One or more
    return matchPlus(alternatives, rest_pattern, string, str_pos);
}

/// +(a|b) - Match one or more occurrences
fn matchPlus(alternatives: []const []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize) bool {
    // Use a visited bitset to avoid exponential re-exploration of the same string positions.
    // Supports strings up to 1024 chars; beyond that falls back to unguarded recursion.
    var visited: [1024 / 8]u8 = [_]u8{0} ** (1024 / 8);
    return matchPlusInner(alternatives, rest_pattern, string, str_pos, &visited);
}

fn matchPlusInner(alternatives: []const []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize, visited: *[1024 / 8]u8) bool {
    // Memoization: if we've already tried this str_pos and it failed, skip it
    if (str_pos < 1024) {
        const byte_idx = str_pos >> 3;
        const bit_mask = @as(u8, 1) << @as(u3, @truncate(str_pos & 7));
        if (visited[byte_idx] & bit_mask != 0) return false;
        visited[byte_idx] |= bit_mask;
    }

    for (alternatives) |alt| {
        var end_pos = str_pos;
        while (end_pos <= string.len) : (end_pos += 1) {
            const candidate = string[str_pos..end_pos];
            if (fnmatchCore(alt, candidate, true)) {
                if (matchExtglobImpl(rest_pattern, string, 0, end_pos)) return true;
                if (end_pos > str_pos) {
                    if (matchPlusInner(alternatives, rest_pattern, string, end_pos, visited)) return true;
                }
            }
        }
    }
    return false;
}

/// !(a|b) - Match anything except the alternatives
fn matchNot(alternatives: []const []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize) bool {
    var end_pos = str_pos;
    while (end_pos <= string.len) : (end_pos += 1) {
        const candidate = string[str_pos..end_pos];

        var matches_any = false;
        for (alternatives) |alt| {
            if (fnmatchCore(alt, candidate, true)) {
                matches_any = true;
                break;
            }
        }

        if (!matches_any) {
            if (matchExtglobImpl(rest_pattern, string, 0, end_pos)) return true;
        }
    }

    return false;
}

fn tryMatchAlternative(alt: []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize) bool {
    var end_pos = str_pos;
    while (end_pos <= string.len) : (end_pos += 1) {
        const candidate = string[str_pos..end_pos];
        if (fnmatchCore(alt, candidate, true)) {
            if (matchExtglobImpl(rest_pattern, string, 0, end_pos)) return true;
        }
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "fnmatch - basic patterns" {
    try std.testing.expect(fnmatch("*.txt", "file.txt", .{}));
    try std.testing.expect(!fnmatch("*.txt", "file.log", .{}));
    try std.testing.expect(fnmatch("test?", "test1", .{}));
    try std.testing.expect(!fnmatch("test?", "test12", .{}));
}

test "fnmatch - bracket expressions" {
    try std.testing.expect(fnmatch("[abc]", "a", .{}));
    try std.testing.expect(fnmatch("[abc]", "b", .{}));
    try std.testing.expect(!fnmatch("[abc]", "d", .{}));
    try std.testing.expect(fnmatch("[a-z]", "m", .{}));
    try std.testing.expect(!fnmatch("[a-z]", "5", .{}));
}

test "fnmatch - escape sequences" {
    try std.testing.expect(fnmatch("\\*", "*", .{}));
    try std.testing.expect(!fnmatch("\\*", "a", .{}));
    try std.testing.expect(fnmatch("\\?", "?", .{}));
}

test "fnmatch - empty patterns" {
    try std.testing.expect(fnmatch("", "", .{}));
    try std.testing.expect(!fnmatch("", "a", .{}));
    try std.testing.expect(fnmatch("*", "", .{}));
    try std.testing.expect(fnmatch("*", "anything", .{}));
}

test "fnmatchCore - iterative star does not overflow stack" {
    try std.testing.expect(fnmatchCore("*.rs", "hello.rs", true));
    try std.testing.expect(!fnmatchCore("*.rs", "hello.txt", true));
    try std.testing.expect(fnmatchCore("a*b*c*d", "aXbYcZd", true));
    try std.testing.expect(!fnmatchCore("a*b*c*d", "aXbYcZ", true));
}

test "detectExtglobAt - basic detection" {
    const testing = std.testing;

    try testing.expectEqual(ExtglobType.question, detectExtglobAt("?(foo)", 0).?);
    try testing.expectEqual(ExtglobType.star, detectExtglobAt("*(foo)", 0).?);
    try testing.expectEqual(ExtglobType.plus, detectExtglobAt("+(foo)", 0).?);
    try testing.expectEqual(ExtglobType.at, detectExtglobAt("@(foo)", 0).?);
    try testing.expectEqual(ExtglobType.not, detectExtglobAt("!(foo)", 0).?);

    try testing.expect(detectExtglobAt("foo", 0) == null);
    try testing.expect(detectExtglobAt("?foo", 0) == null);
    try testing.expect(detectExtglobAt("*", 0) == null);
    try testing.expect(detectExtglobAt("", 0) == null);
}

test "containsExtglob - detection" {
    const testing = std.testing;

    try testing.expect(containsExtglob("?(foo)"));
    try testing.expect(containsExtglob("*.!(js)"));
    try testing.expect(containsExtglob("foo@(bar|baz)"));
    try testing.expect(containsExtglob("+(a)"));

    try testing.expect(!containsExtglob("foo"));
    try testing.expect(!containsExtglob("*.txt"));
    try testing.expect(!containsExtglob("?"));
    try testing.expect(!containsExtglob("*"));
    try testing.expect(!containsExtglob(""));
}

test "findClosingParen - basic" {
    const testing = std.testing;

    try testing.expectEqual(@as(?usize, 4), findClosingParen("(foo)", 0));
    try testing.expectEqual(@as(?usize, 8), findClosingParen("(foo|bar)", 0));
    try testing.expectEqual(@as(?usize, 9), findClosingParen("(foo(bar))", 0));
    try testing.expectEqual(@as(?usize, null), findClosingParen("(foo", 0));
    try testing.expectEqual(@as(?usize, null), findClosingParen("foo)", 0));
}

test "splitAlternatives - basic" {
    const testing = std.testing;

    var buffer: [32][]const u8 = undefined;

    const alts1 = splitAlternatives("foo|bar|baz", &buffer);
    try testing.expectEqual(@as(usize, 3), alts1.len);
    try testing.expectEqualStrings("foo", alts1[0]);
    try testing.expectEqualStrings("bar", alts1[1]);
    try testing.expectEqualStrings("baz", alts1[2]);

    const alts2 = splitAlternatives("single", &buffer);
    try testing.expectEqual(@as(usize, 1), alts2.len);
    try testing.expectEqualStrings("single", alts2[0]);

    const alts3 = splitAlternatives("", &buffer);
    try testing.expectEqual(@as(usize, 1), alts3.len);
    try testing.expectEqualStrings("", alts3[0]);

    const alts4 = splitAlternatives("a(b|c)|d", &buffer);
    try testing.expectEqual(@as(usize, 2), alts4.len);
    try testing.expectEqualStrings("a(b|c)", alts4[0]);
    try testing.expectEqualStrings("d", alts4[1]);
}
