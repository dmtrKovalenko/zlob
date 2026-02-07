const std = @import("std");
const mem = std.mem;
const glob = @import("zlob.zig");

const PatternContext = glob.PatternContext;

pub fn check_simple_star_sufix(pattern: []const u8) struct { ?SimdBatchedSuffixMatch, ?SuffixMatch } {
    if (pattern.len < 2 or pattern[0] != '*') return .{ null, null };

    const suffix = pattern[1..];
    if (glob.hasWildcardsBasic(suffix)) return .{ null, null };

    const suffix_matcher = SuffixMatch{ .suffix = suffix, .suffix_len = @intCast(suffix.len) };

    // SIMD batching works for suffixes up to 4 bytes (fits in u32)
    if (suffix.len <= 4) {
        return .{ SimdBatchedSuffixMatch.init(suffix), suffix_matcher };
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

pub const SimdBatchedSuffixMatch = struct {
    simple_ext: []const u8, // The extension for *.ext patterns
    suffix_u32: u32, // Pre-computed u32 representation for SIMD
    simple_ext_len: u8, // Length of the extension

    suffix_u16: u16,
    suffix_byte: u8,

    pub fn init(ext: []const u8) SimdBatchedSuffixMatch {
        std.debug.assert(ext.len > 0 and ext.len <= 4);

        var ext_u32: u32 = 0;
        const ext_len: u8 = @intCast(ext.len);
        @memcpy(@as([*]u8, @ptrCast(&ext_u32))[0..ext.len], ext);

        // Pre-compute suffix values for comptime-specialized matching
        const suffix_u16: u16 = @truncate(ext_u32);
        const suffix_byte: u8 = if (ext_len >= 3) ext[2] else 0;

        return SimdBatchedSuffixMatch{
            .simple_ext = ext,
            .simple_ext_len = ext_len,
            .suffix_u32 = ext_u32,
            .suffix_u16 = suffix_u16,
            .suffix_byte = suffix_byte,
        };
    }

    pub inline fn matchSuffix(self: *const SimdBatchedSuffixMatch, name: []const u8) bool {
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

    pub fn matchPathsBatchedSIMD(
        self: *const SimdBatchedSuffixMatch,
        paths: []const []const u8,
        matches: *std.array_list.AlignedManaged([]const u8, null),
    ) !void {
        const len = paths.len;
        var i: usize = 0;

        // Process 4 paths at a time for better instruction pipelining
        // this unrolling how dumb it might be looking actualloy gives a measurable performance increase on x86_64
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
