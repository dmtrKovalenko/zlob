//! Extended glob (extglob) pattern support
//!
//! Implements bash-style extended globbing patterns:
//! - ?(pattern-list) - Matches zero or one occurrence of the given patterns
//! - *(pattern-list) - Matches zero or more occurrences of the given patterns
//! - +(pattern-list) - Matches one or more occurrences of the given patterns
//! - @(pattern-list) - Matches one of the given patterns
//! - !(pattern-list) - Matches anything except one of the given patterns
//!
//! Pattern-list is a list of patterns separated by '|' (pipe character).
//!
//! Note: Nested extglobs are NOT supported (as per design decision).
//! Note: Standalone !(pattern) at pattern start is NOT supported.
//!       Use *.!(js) style instead.

const std = @import("std");
const mem = std.mem;

/// Type of extended glob pattern
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
/// Returns the type if found, null otherwise.
/// Checks for: ?( *( +( @( !(
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

/// Check if a pattern contains any extglob sequences.
/// Scans for ?( *( +( @( !( patterns.
pub fn containsExtglob(pattern: []const u8) bool {
    if (pattern.len < 2) return false;

    var i: usize = 0;
    while (i + 1 < pattern.len) : (i += 1) {
        if (pattern[i + 1] == '(') {
            switch (pattern[i]) {
                '?', '*', '+', '@', '!' => return true,
                else => {},
            }
        }
    }
    return false;
}

/// Find the matching closing parenthesis for an extglob.
/// Handles nested parentheses correctly.
/// Returns the index of the closing ')' or null if not found.
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
                // Skip escaped character
                if (i + 1 < pattern.len) i += 1;
            },
            else => {},
        }
    }

    return null; // No matching closing paren
}

/// Split the content of an extglob by '|' at the correct nesting level.
/// Returns slices into the original pattern (no allocation).
/// Uses a fixed-size buffer for alternatives (max 32).
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
                // Skip escaped character
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

/// Forward declaration for fnmatch - will be set by zlob.zig
pub var fnmatchFunc: *const fn ([]const u8, []const u8) bool = undefined;

/// Initialize the fnmatch function pointer (called from zlob.zig)
pub fn initFnmatch(func: *const fn ([]const u8, []const u8) bool) void {
    fnmatchFunc = func;
}

/// Match a string against a pattern containing extglob constructs.
/// This is the main entry point for extglob matching.
pub fn fnmatchExtglob(pattern: []const u8, string: []const u8) bool {
    return matchExtglobRecursive(pattern, string, 0, 0);
}

/// Recursive extglob matcher that processes pattern and string positions.
fn matchExtglobRecursive(pattern: []const u8, string: []const u8, pat_start: usize, str_start: usize) bool {
    var pi = pat_start;
    var si = str_start;

    while (pi < pattern.len) {
        // Check for extglob at current position
        if (detectExtglobAt(pattern, pi)) |ext_type| {
            const open_paren = pi + 1;
            const close_paren = findClosingParen(pattern, open_paren) orelse {
                // Malformed extglob - treat as literal
                if (si >= string.len or string[si] != pattern[pi]) return false;
                si += 1;
                pi += 1;
                continue;
            };

            const content = pattern[open_paren + 1 .. close_paren];
            const rest_pattern = pattern[close_paren + 1 ..];

            var alt_buffer: [32][]const u8 = undefined;
            const alternatives = splitAlternatives(content, &alt_buffer);

            return matchExtglobType(ext_type, alternatives, rest_pattern, string, si);
        }

        // Handle regular pattern characters
        const ch = pattern[pi];

        switch (ch) {
            '*' => {
                // Regular star wildcard
                pi += 1;
                // Collapse multiple stars
                while (pi < pattern.len and pattern[pi] == '*') pi += 1;

                if (pi >= pattern.len) return true; // * at end matches everything

                // Try matching * with different lengths
                while (si <= string.len) : (si += 1) {
                    if (matchExtglobRecursive(pattern, string, pi, si)) return true;
                }
                return false;
            },
            '?' => {
                // Regular question mark - match one character
                if (si >= string.len) return false;
                si += 1;
                pi += 1;
            },
            '[' => {
                // Character class - delegate to regular fnmatch for this
                // Find the end of the bracket expression
                var bracket_end = pi + 1;
                if (bracket_end < pattern.len and (pattern[bracket_end] == '!' or pattern[bracket_end] == '^')) {
                    bracket_end += 1;
                }
                if (bracket_end < pattern.len and pattern[bracket_end] == ']') {
                    bracket_end += 1;
                }
                while (bracket_end < pattern.len and pattern[bracket_end] != ']') {
                    bracket_end += 1;
                }
                if (bracket_end < pattern.len) {
                    bracket_end += 1; // Include the ]
                }

                // Use fnmatch to check just this character class against one char
                if (si >= string.len) return false;
                const bracket_pattern = pattern[pi..bracket_end];
                const single_char = string[si .. si + 1];
                if (!fnmatchFunc(bracket_pattern, single_char)) return false;
                si += 1;
                pi = bracket_end;
            },
            '\\' => {
                // Escaped character
                pi += 1;
                if (pi >= pattern.len) return false;
                if (si >= string.len or string[si] != pattern[pi]) return false;
                si += 1;
                pi += 1;
            },
            else => {
                // Literal character
                if (si >= string.len or string[si] != ch) return false;
                si += 1;
                pi += 1;
            },
        }
    }

    // Pattern exhausted - string must also be exhausted
    return si == string.len;
}

/// Match based on extglob type
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
        // Try to match this alternative at str_pos
        // The alternative itself may contain wildcards, so we need to find how much it consumes
        const match_result = tryMatchAlternative(alt, rest_pattern, string, str_pos);
        if (match_result) return true;
    }
    return false;
}

/// ?(a|b) - Match zero or one occurrence of the alternatives
fn matchQuestion(alternatives: []const []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize) bool {
    // Try zero occurrences first (match rest_pattern directly)
    if (matchExtglobRecursive(rest_pattern, string, 0, str_pos)) return true;

    // Try one occurrence of each alternative
    return matchAt(alternatives, rest_pattern, string, str_pos);
}

/// *(a|b) - Match zero or more occurrences of the alternatives
fn matchStar(alternatives: []const []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize) bool {
    // Try zero occurrences first
    if (matchExtglobRecursive(rest_pattern, string, 0, str_pos)) return true;

    // Try one or more occurrences using + logic
    return matchPlus(alternatives, rest_pattern, string, str_pos);
}

/// +(a|b) - Match one or more occurrences of the alternatives
fn matchPlus(alternatives: []const []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize) bool {
    // Must match at least one alternative
    for (alternatives) |alt| {
        // Try different lengths that this alternative might match
        var end_pos = str_pos;
        while (end_pos <= string.len) : (end_pos += 1) {
            const candidate = string[str_pos..end_pos];
            if (fnmatchFunc(alt, candidate)) {
                // This alternative matched str_pos..end_pos
                // Now try: more occurrences OR rest_pattern
                // Try rest_pattern (ends the + repetition)
                if (matchExtglobRecursive(rest_pattern, string, 0, end_pos)) return true;

                // Try more occurrences (continue the + repetition)
                if (end_pos > str_pos) { // Must make progress
                    if (matchPlus(alternatives, rest_pattern, string, end_pos)) return true;
                }
            }
        }
    }
    return false;
}

/// !(a|b) - Match anything except the alternatives
fn matchNot(alternatives: []const []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize) bool {
    // For !(alt1|alt2), we need to find a string segment that:
    // 1. Does NOT match any of the alternatives
    // 2. When combined with rest_pattern, matches the rest of the string

    // Try different ending positions for the negated match
    var end_pos = str_pos;
    while (end_pos <= string.len) : (end_pos += 1) {
        const candidate = string[str_pos..end_pos];

        // Check that candidate does NOT match any alternative
        var matches_any = false;
        for (alternatives) |alt| {
            if (fnmatchFunc(alt, candidate)) {
                matches_any = true;
                break;
            }
        }

        if (!matches_any) {
            // This segment doesn't match any alternative - check if rest works
            if (matchExtglobRecursive(rest_pattern, string, 0, end_pos)) return true;
        }
    }

    return false;
}

/// Try to match an alternative pattern against the string and then match rest_pattern
fn tryMatchAlternative(alt: []const u8, rest_pattern: []const u8, string: []const u8, str_pos: usize) bool {
    // The alternative may contain wildcards, so we try different lengths
    var end_pos = str_pos;
    while (end_pos <= string.len) : (end_pos += 1) {
        const candidate = string[str_pos..end_pos];
        if (fnmatchFunc(alt, candidate)) {
            // Alternative matched - now check rest_pattern matches the remainder
            if (matchExtglobRecursive(rest_pattern, string, 0, end_pos)) return true;
        }
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "detectExtglobAt - basic detection" {
    const testing = std.testing;

    try testing.expectEqual(ExtglobType.question, detectExtglobAt("?(foo)", 0).?);
    try testing.expectEqual(ExtglobType.star, detectExtglobAt("*(foo)", 0).?);
    try testing.expectEqual(ExtglobType.plus, detectExtglobAt("+(foo)", 0).?);
    try testing.expectEqual(ExtglobType.at, detectExtglobAt("@(foo)", 0).?);
    try testing.expectEqual(ExtglobType.not, detectExtglobAt("!(foo)", 0).?);

    // Not extglob
    try testing.expect(detectExtglobAt("foo", 0) == null);
    try testing.expect(detectExtglobAt("?foo", 0) == null);
    try testing.expect(detectExtglobAt("*", 0) == null); // No ( after
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
    try testing.expectEqual(@as(?usize, 9), findClosingParen("(foo(bar))", 0)); // Nested - outer closes at 9
    try testing.expectEqual(@as(?usize, null), findClosingParen("(foo", 0)); // No close
    try testing.expectEqual(@as(?usize, null), findClosingParen("foo)", 0)); // No open at pos
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

    // With nested parens - | inside parens should not split
    const alts4 = splitAlternatives("a(b|c)|d", &buffer);
    try testing.expectEqual(@as(usize, 2), alts4.len);
    try testing.expectEqualStrings("a(b|c)", alts4[0]);
    try testing.expectEqualStrings("d", alts4[1]);
}
