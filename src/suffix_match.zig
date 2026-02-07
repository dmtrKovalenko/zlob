const std = @import("std");
const mem = std.mem;
const glob = @import("zlob.zig");

const PatternContext = glob.PatternContext;

/// Check if pattern is a simple *.suffix pattern and return precompiled matchers.
/// Returns (SingleSuffixMatcher for 1-4 byte suffixes, SuffixMatch for any length suffix).
pub fn check_simple_star_sufix(pattern: []const u8) struct { ?SingleSuffixMatcher, ?SuffixMatch } {
    if (pattern.len < 2 or pattern[0] != '*') return .{ null, null };

    const suffix = pattern[1..];
    if (glob.hasWildcardsBasic(suffix)) return .{ null, null };

    const suffix_matcher = SuffixMatch{ .suffix = suffix, .suffix_len = @intCast(suffix.len) };

    // SingleSuffixMatcher works for suffixes up to 4 bytes (fits in u32)
    if (suffix.len >= 1 and suffix.len <= 4) {
        return .{ SingleSuffixMatcher.init(suffix), suffix_matcher };
    } else {
        return .{ null, suffix_matcher };
    }
}

pub const SuffixMatch = struct {
    suffix: []const u8,
    suffix_len: u16,

    pub fn new(suffix: []const u8) SuffixMatch {
        return SuffixMatch{
            .suffix = suffix,
            .suffix_len = @intCast(suffix.len),
        };
    }

    pub fn match(self: SuffixMatch, string: []const u8) bool {
        if (string.len < self.suffix.len) return false;

        const patternSuffix = self.suffix;
        const actualSuffix = string[string.len - self.suffix.len ..];

        if (actualSuffix.len <= 16) {
            @branchHint(.likely);
            if (actualSuffix.len < 4) {
                const xor =
                    (actualSuffix[0] ^ patternSuffix[0]) | (actualSuffix[actualSuffix.len - 1] ^ patternSuffix[actualSuffix.len - 1]) | (actualSuffix[actualSuffix.len / 2] ^ patternSuffix[actualSuffix.len / 2]);

                return xor == 0;
            }
            var x: u32 = 0;
            for ([_]usize{ 0, actualSuffix.len - 4, (actualSuffix.len / 8) * 4, actualSuffix.len - 4 - ((actualSuffix.len / 8) * 4) }) |n| {
                x |= @as(u32, @bitCast(actualSuffix[n..][0..4].*)) ^ @as(u32, @bitCast(patternSuffix[n..][0..4].*));
            }
            return x == 0;
        }

        // use chunks of the vector based sized
        const Chunk = if (std.simd.suggestVectorLength(u8)) |vec_size|
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
            if (n <= Chunk.size and actualSuffix.len <= n) {
                const V = @Vector(n / 2, u8);
                var x = @as(V, actualSuffix[0 .. n / 2].*) ^ @as(V, patternSuffix[0 .. n / 2].*);
                x |= @as(V, actualSuffix[actualSuffix.len - n / 2 ..][0 .. n / 2].*) ^ @as(V, patternSuffix[actualSuffix.len - n / 2 ..][0 .. n / 2].*);
                const zero: V = @splat(0);
                return !@reduce(.Or, x != zero);
            }
        }

        for (0..(actualSuffix.len - 1) / Chunk.size) |i| {
            const a_chunk: Chunk.Chunk = @bitCast(actualSuffix[i * Chunk.size ..][0..Chunk.size].*);
            const b_chunk: Chunk.Chunk = @bitCast(patternSuffix[i * Chunk.size ..][0..Chunk.size].*);
            if (Chunk.isNotEqual(a_chunk, b_chunk)) return false;
        }

        const last_a_chunk: Chunk.Chunk = @bitCast(actualSuffix[actualSuffix.len - Chunk.size ..][0..Chunk.size].*);
        const last_b_chunk: Chunk.Chunk = @bitCast(patternSuffix[actualSuffix.len - Chunk.size ..][0..Chunk.size].*);
        return !Chunk.isNotEqual(last_a_chunk, last_b_chunk);
    }
};

pub const MaskedSuffix = struct {
    value: u32, // Suffix bytes shifted to high positions of u32
    mask: u32, // 0xFF for care positions (high bytes for short suffixes)

    /// Create a masked suffix from a byte slice (1-4 bytes)
    pub fn init(suffix: []const u8) MaskedSuffix {
        std.debug.assert(suffix.len >= 1 and suffix.len <= 4);

        // Shift suffix bytes to align with the end of the u32
        const shift: u5 = @intCast((4 - suffix.len) * 8);

        var raw_value: u32 = 0;
        @memcpy(@as([*]u8, @ptrCast(&raw_value))[0..suffix.len], suffix);

        const value: u32 = raw_value << shift;
        const base_mask: u32 = switch (suffix.len) {
            1 => 0x000000FF,
            2 => 0x0000FFFF,
            3 => 0x00FFFFFF,
            4 => 0xFFFFFFFF,
            else => unreachable,
        };
        const mask: u32 = base_mask << shift;

        return MaskedSuffix{ .value = value, .mask = mask };
    }

    /// Create a masked suffix from a precomputed u32 value and length.
    /// The raw_value should have suffix bytes in the LOW positions (as stored in SingleSuffixMatcher).
    pub fn initFromU32(raw_value: u32, len: u8) MaskedSuffix {
        std.debug.assert(len >= 1 and len <= 4);

        const shift: u5 = @intCast((4 - len) * 8);
        const base_mask: u32 = switch (len) {
            1 => 0x000000FF,
            2 => 0x0000FFFF,
            3 => 0x00FFFFFF,
            4 => 0xFFFFFFFF,
            else => unreachable,
        };

        return MaskedSuffix{
            .value = raw_value << shift,
            .mask = base_mask << shift,
        };
    }

    /// Check if this suffix matches the end of the given name
    pub inline fn matches(self: MaskedSuffix, name: []const u8) bool {
        if (name.len < 4) {
            // For short names, use byte-by-byte comparison based on suffix length
            const suffix_len = @popCount(self.mask) / 8;
            if (name.len < suffix_len) return false;

            const tail_ptr = name.ptr + name.len - suffix_len;
            var tail_value: u32 = 0;
            @memcpy(@as([*]u8, @ptrCast(&tail_value))[0..suffix_len], tail_ptr[0..suffix_len]);
            // For short names, the value is still in low position, need to shift
            const shift: u5 = @intCast((4 - suffix_len) * 8);
            return (tail_value << shift) == self.value;
        }

        const tail_ptr = name.ptr + name.len - 4;
        const tail: u32 = @as(*align(1) const u32, @ptrCast(tail_ptr)).*;
        return (tail & self.mask) == self.value;
    }
};

/// Unified multi-suffix matcher using masked u32 comparisons.
/// All suffixes (1-4 bytes) are stored in a single array and matched in one SIMD pass.
pub const UnifiedMultiSuffix = struct {
    /// Maximum number of suffixes we can handle
    pub const MAX_SUFFIXES = 32;

    /// Array of masked suffixes for SIMD matching
    suffixes: [MAX_SUFFIXES]MaskedSuffix = undefined,
    count: u8 = 0,
    min_suffix_len: u8 = 255,

    /// Track if all patterns are simple suffixes (enables fast path without fallback)
    all_simple_suffixes: bool = true,

    pub fn init(contexts: []const @import("pattern_context.zig").PatternContext) UnifiedMultiSuffix {
        var self = UnifiedMultiSuffix{};

        for (contexts) |ctx| {
            if (ctx.single_suffix_matcher) |matcher| {
                if (self.count < MAX_SUFFIXES) {
                    const len = matcher.simple_ext_len;
                    if (len < self.min_suffix_len) self.min_suffix_len = len;

                    self.suffixes[self.count] = MaskedSuffix.initFromU32(matcher.suffix_u32, len);
                    self.count += 1;
                } else {
                    self.all_simple_suffixes = false;
                }
            } else {
                // Has complex patterns that need fallback
                self.all_simple_suffixes = false;
            }
        }

        if (self.min_suffix_len == 255) self.min_suffix_len = 1;
        return self;
    }

    /// Check if this matcher has any suffixes to match
    pub inline fn hasAnySuffixes(self: *const UnifiedMultiSuffix) bool {
        return self.count > 0;
    }

    /// Match a name against all suffixes using unified SIMD comparison.
    /// This checks ALL suffixes (regardless of length) in a single pass.
    pub inline fn matchAny(self: *const UnifiedMultiSuffix, name: []const u8) bool {
        if (self.count == 0) return false;
        if (name.len < self.min_suffix_len) return false;

        // For names >= 4 bytes, use fast SIMD path
        if (name.len >= 4) {
            return self.matchAnySIMD(name);
        }

        // For short names, use scalar fallback
        return self.matchAnyScalar(name);
    }

    /// SIMD-accelerated matching for names >= 4 bytes
    inline fn matchAnySIMD(self: *const UnifiedMultiSuffix, name: []const u8) bool {
        const tail_ptr = name.ptr + name.len - 4;
        const tail: u32 = @as(*align(1) const u32, @ptrCast(tail_ptr)).*;

        const vec_len = comptime std.simd.suggestVectorLength(u32) orelse 4;
        const Vec = @Vector(vec_len, u32);
        const tail_vec: Vec = @splat(tail);

        var i: usize = 0;

        // Process vec_len suffixes at a time
        while (i + vec_len <= self.count) : (i += vec_len) {
            // Load masks and values
            var masks: Vec = undefined;
            var values: Vec = undefined;

            inline for (0..vec_len) |j| {
                masks[j] = self.suffixes[i + j].mask;
                values[j] = self.suffixes[i + j].value;
            }

            // Apply mask and compare: (tail & mask) == value
            const masked = tail_vec & masks;
            const matches = masked == values;

            if (@reduce(.Or, matches)) return true;
        }

        // Handle remainder with scalar loop
        while (i < self.count) : (i += 1) {
            const s = self.suffixes[i];
            if ((tail & s.mask) == s.value) return true;
        }

        return false;
    }

    /// Scalar fallback for names < 4 bytes
    inline fn matchAnyScalar(self: *const UnifiedMultiSuffix, name: []const u8) bool {
        for (self.suffixes[0..self.count]) |s| {
            if (s.matches(name)) return true;
        }
        return false;
    }
};

/// Precompiled multi-suffix context for matching multiple suffixes at once.
/// This is now an alias to UnifiedMultiSuffix which uses the masked u32 approach
/// for SIMD-parallel matching of all suffix lengths in a single pass.
pub const PrecompiledMultiSuffix = UnifiedMultiSuffix;

/// Fast single-suffix matcher for patterns like *.ext (1-4 byte suffixes).
/// Pre-computes u32/u16 representations for efficient suffix comparison.
pub const SingleSuffixMatcher = struct {
    simple_ext: []const u8, // The extension for *.ext patterns
    suffix_u32: u32, // Pre-computed u32 representation
    simple_ext_len: u8, // Length of the extension

    suffix_u16: u16,
    suffix_byte: u8,

    pub fn init(ext: []const u8) SingleSuffixMatcher {
        std.debug.assert(ext.len > 0 and ext.len <= 4);

        var ext_u32: u32 = 0;
        const ext_len: u8 = @intCast(ext.len);
        @memcpy(@as([*]u8, @ptrCast(&ext_u32))[0..ext.len], ext);

        // Pre-compute suffix values for comptime-specialized matching
        const suffix_u16: u16 = @truncate(ext_u32);
        const suffix_byte: u8 = if (ext_len >= 3) ext[2] else 0;

        return SingleSuffixMatcher{
            .simple_ext = ext,
            .simple_ext_len = ext_len,
            .suffix_u32 = ext_u32,
            .suffix_u16 = suffix_u16,
            .suffix_byte = suffix_byte,
        };
    }

    pub inline fn matchSuffix(self: *const SingleSuffixMatcher, name: []const u8) bool {
        const suffix = self.simple_ext;
        if (name.len < self.simple_ext_len) return false;

        return switch (self.simple_ext_len) {
            1 => name[name.len - 1] == suffix[0],
            2 => blk: {
                const tail_ptr = name.ptr + name.len - 2;
                const tail: u16 = @as(*align(1) const u16, @ptrCast(tail_ptr)).*;
                break :blk tail == self.suffix_u16;
            },
            3 => blk: {
                const tail_ptr = name.ptr + name.len - 3;
                const tail_u16: u16 = @as(*align(1) const u16, @ptrCast(tail_ptr)).*;
                break :blk tail_u16 == self.suffix_u16 and tail_ptr[2] == suffix[2];
            },
            4 => blk: {
                const tail_ptr = name.ptr + name.len - 4;
                const tail: u32 = @as(*align(1) const u32, @ptrCast(tail_ptr)).*;
                break :blk tail == self.suffix_u32;
            },
            else => unreachable,
        };
    }

    // used for match paths and allows a way better pipelineing of memory/branching instruction on x86
    pub fn matchPathsBatched(
        self: *const SingleSuffixMatcher,
        paths: []const []const u8,
        matches: *std.array_list.AlignedManaged([]const u8, null),
    ) !void {
        const len = paths.len;
        var i: usize = 0;

        // Process 4 paths at a time for better instruction pipelining
        while (i + 4 <= len) : (i += 4) {
            const m0 = self.matchSuffix(paths[i]);
            const m1 = self.matchSuffix(paths[i + 1]);
            const m2 = self.matchSuffix(paths[i + 2]);
            const m3 = self.matchSuffix(paths[i + 3]);

            // Batch appends to reduce branch mispredictions
            if (m0) try matches.append(paths[i]);
            if (m1) try matches.append(paths[i + 1]);
            if (m2) try matches.append(paths[i + 2]);
            if (m3) try matches.append(paths[i + 3]);
        }

        // Handle remainder
        while (i < len) : (i += 1) {
            if (self.matchSuffix(paths[i])) {
                try matches.append(paths[i]);
            }
        }
    }
};
