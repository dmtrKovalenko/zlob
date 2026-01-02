//! SIMD-optimized suffix matching for glob patterns
//!
//! This module provides platform-adaptive vectorized suffix matching for
//! simple *.ext patterns, automatically selecting optimal vector sizes
//! based on the CPU architecture (SSE/AVX2/AVX-512).

const std = @import("std");
const c = std.c;
const mem = std.mem;
const glob = @import("glob.zig");
const assert = std.debug.assert;

const PatternContext = glob.PatternContext;
const ResultsList = glob.ResultsList;
const dirent = glob.dirent;
const buildFullPath = glob.buildFullPath;
const maybeAppendSlash = glob.maybeAppendSlash;
const shouldSkipFile = glob.shouldSkipFile;

// Platform-optimal SIMD vector sizes (compile-time determined)
// On SSE/NEON: typically 8 x u16 (16 bytes) or 4 x u32 (16 bytes)
// On AVX-512: can be 32 x u16 (64 bytes) or 16 x u32 (64 bytes)
pub const OptimalVecSize16 = std.simd.suggestVectorLength(u16) orelse 8;
pub const OptimalVecSize32 = std.simd.suggestVectorLength(u32) orelse 4;

// Compile-time info about SIMD configuration
comptime {
    @setEvalBranchQuota(2000);
    _ = std.fmt.comptimePrint(
        "SIMD suffix match config: u16 batch={d} ({d} bytes), u32 batch={d} ({d} bytes)",
        .{ OptimalVecSize16, OptimalVecSize16 * 2, OptimalVecSize32, OptimalVecSize32 * 4 },
    );
}

/// Returns the platform-optimal SIMD batch sizes selected at compile time
pub fn getSimdConfig() struct { u16_batch_size: usize, u32_batch_size: usize } {
    return .{
        .u16_batch_size = OptimalVecSize16,
        .u32_batch_size = OptimalVecSize32,
    };
}

pub fn check_simple_star_sufix(pattern: []const u8) struct { ?SimdBatchedSuffixMatch, ?SuffixMatch } {
    if (pattern.len < 2 or pattern[0] != '*') return .{ null, null };

    const suffix = pattern[1..];
    if (glob.hasWildcardsSIMD(suffix)) return .{ null, null };

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
                const xor = (actualSuffix[0] ^ patternSuffix[0]) | (actualSuffix[actualSuffix.len - 1] ^ patternSuffix[actualSuffix.len - 1]) | (actualSuffix[actualSuffix.len / 2] ^ patternSuffix[actualSuffix.len / 2]);
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

/// Comptime-specialized suffix matching - no runtime branching
/// Each function is monomorphized for a specific suffix length
inline fn matchSuffixLen1(name: []const u8, suffix_byte: u8) bool {
    if (name.len < 1) return false;
    return name[name.len - 1] == suffix_byte;
}

inline fn matchSuffixLen2(name: []const u8, suffix_u16: u16) bool {
    if (name.len < 2) return false;
    const tail_ptr = name.ptr + name.len - 2;
    const tail: u16 = @as(*align(1) const u16, @ptrCast(tail_ptr)).*;
    return tail == suffix_u16;
}

inline fn matchSuffixLen3(name: []const u8, suffix_u16: u16, suffix_byte: u8) bool {
    if (name.len < 3) return false;
    const tail_ptr = name.ptr + name.len - 3;
    const tail_u16: u16 = @as(*align(1) const u16, @ptrCast(tail_ptr)).*;
    return tail_u16 == suffix_u16 and tail_ptr[2] == suffix_byte;
}

inline fn matchSuffixLen4(name: []const u8, suffix_u32: u32) bool {
    if (name.len < 4) return false;
    const tail_ptr = name.ptr + name.len - 4;
    const tail: u32 = @as(*align(1) const u32, @ptrCast(tail_ptr)).*;
    return tail == suffix_u32;
}

/// Direct integer comparison approach for suffix matching (1-4 bytes)
/// Uses unaligned loads and direct equality comparison
inline fn matchSuffixDirect(name: []const u8, suffix: []const u8, suffix_u16: u16, suffix_u32: u32) bool {
    if (name.len < suffix.len) return false;

    return switch (suffix.len) {
        1 => name[name.len - 1] == suffix[0],
        2 => blk: {
            const tail_ptr = name.ptr + name.len - 2;
            const tail: u16 = @as(*align(1) const u16, @ptrCast(tail_ptr)).*;
            break :blk tail == suffix_u16;
        },
        3 => blk: {
            const tail_ptr = name.ptr + name.len - 3;
            const tail_u16: u16 = @as(*align(1) const u16, @ptrCast(tail_ptr)).*;
            break :blk tail_u16 == suffix_u16 and tail_ptr[2] == suffix[2];
        },
        4 => blk: {
            const tail_ptr = name.ptr + name.len - 4;
            const tail: u32 = @as(*align(1) const u32, @ptrCast(tail_ptr)).*;
            break :blk tail == suffix_u32;
        },
        else => unreachable,
    };
}

/// XOR-based comparison approach for suffix matching (1-4 bytes)
/// Uses XOR operations to detect differences
inline fn matchSuffixXor(name: []const u8, suffix: []const u8) bool {
    if (name.len < suffix.len) return false;

    const a = name[name.len - suffix.len ..];
    const b = suffix;

    if (a.len < 4) {
        // For lengths 1-3: check first, last, and middle bytes
        const x = (a[0] ^ b[0]) | (a[a.len - 1] ^ b[a.len - 1]) | (a[a.len / 2] ^ b[a.len / 2]);
        return x == 0;
    } else {
        // For length 4: use overlapping u32 reads with XOR
        var x: u32 = 0;
        for ([_]usize{ 0, a.len - 4, (a.len / 8) * 4, a.len - 4 - ((a.len / 8) * 4) }) |n| {
            x |= @as(u32, @bitCast(a[n..][0..4].*)) ^ @as(u32, @bitCast(b[n..][0..4].*));
        }
        return x == 0;
    }
}

pub const SimdBatchedSuffixMatch = struct {
    simple_ext: []const u8, // The extension for *.ext patterns
    suffix_u32: u32, // Pre-computed u32 representation for SIMD
    simple_ext_len: u8, // Length of the extension

    suffix_u16: u16, // Pre-computed u16 for 2-byte suffixes (e.g., ".c")
    suffix_byte: u8, // Third byte for 3-byte suffixes

    /// Initialize SIMD context for a *.ext pattern
    /// Returns a context with pre-computed vectors and masks for fast suffix matching
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
        // Use comptime-specialized suffix matching - no runtime branching
        for (paths) |path| {
            const is_match = switch (self.simple_ext_len) {
                1 => matchSuffixLen1(path, @truncate(self.suffix_u32)),
                2 => matchSuffixLen2(path, self.suffix_u16),
                3 => matchSuffixLen3(path, self.suffix_u16, self.suffix_byte),
                4 => matchSuffixLen4(path, self.suffix_u32),
                else => unreachable,
            };
            if (is_match) {
                try matches.append(path);
            }
        }
    }
};

// Generic SIMD vectorized batch processing with compile-time batch size
fn simdBatchProcessGeneric(
    comptime BatchSize: usize,
    comptime matchFn: fn ([BatchSize][]const u8, *const SimdBatchedSuffixMatch) callconv(.@"inline") @Vector(BatchSize, bool),
    allocator: std.mem.Allocator,
    dir: *c.DIR,
    suffix_ctx: *const SimdBatchedSuffixMatch,
    pattern_ctx: *const PatternContext,
    dirname: []const u8,
    use_dirname: bool,
    flags: c_int,
    directories_only: bool,
    names: *ResultsList,
) !void {
    var batch_names: [BatchSize][]const u8 = undefined;
    var batch_entries: [BatchSize]*const dirent = undefined;
    var batch_count: usize = 0;

    while (c.readdir(dir)) |entry_raw| {
        const entry: *const dirent = @ptrCast(@alignCast(entry_raw));
        const name = mem.sliceTo(&entry.name, 0);
        if (shouldSkipFile(name, pattern_ctx, flags)) continue;

        batch_names[batch_count] = name;
        batch_entries[batch_count] = entry;
        batch_count += 1;

        if (batch_count == BatchSize) {
            const match_vec = matchFn(batch_names, suffix_ctx);
            if (@reduce(.Or, match_vec)) {
                for (0..BatchSize) |i| {
                    if (match_vec[i]) {
                        if (directories_only) {
                            const entry_dtype = batch_entries[i].type;
                            if (entry_dtype != glob.DT_DIR and entry_dtype != glob.DT_UNKNOWN) continue;
                        }

                        const name_to_add = batch_names[i];
                        const path_buf_slice = buildFullPath(allocator, dirname, name_to_add, use_dirname) catch return error.OutOfMemory;
                        var path: [*c]u8 = @ptrCast(path_buf_slice.ptr);
                        const path_len = path_buf_slice.len;

                        var is_dir = batch_entries[i].type == glob.DT_DIR;
                        if (batch_entries[i].type == glob.DT_UNKNOWN) {
                            var stat_buf: std.c.Stat = undefined;
                            if (std.c.stat(path, &stat_buf) == 0) {
                                is_dir = std.c.S.ISDIR(stat_buf.mode);
                            } else {
                                allocator.free(path_buf_slice);
                                continue;
                            }
                        }

                        if (directories_only and !is_dir) {
                            allocator.free(path_buf_slice);
                            continue;
                        }

                        if (maybeAppendSlash(allocator, path, path_len, is_dir, flags) catch {
                            allocator.free(path_buf_slice);
                            return error.OutOfMemory;
                        }) |new_path| {
                            path = new_path;
                        }

                        names.append(path) catch return error.OutOfMemory;
                    }
                }
            }
            batch_count = 0;
        }
    }

    // Process remaining batch items
    if (batch_count > 0) {
        // Initialize unused entries to empty slices to avoid undefined behavior
        for (batch_count..BatchSize) |i| {
            batch_names[i] = "";
        }
        const match_vec = matchFn(batch_names, suffix_ctx);
        if (@reduce(.Or, match_vec)) {
            for (0..batch_count) |i| {
                if (match_vec[i]) {
                    if (directories_only) {
                        const entry_dtype = batch_entries[i].type;
                        if (entry_dtype != glob.DT_DIR and entry_dtype != glob.DT_UNKNOWN) continue;
                    }

                    const name_to_add = batch_names[i];
                    const path_buf_slice = buildFullPath(allocator, dirname, name_to_add, use_dirname) catch return error.OutOfMemory;
                    var path: [*c]u8 = @ptrCast(path_buf_slice.ptr);
                    const path_len = path_buf_slice.len;

                    var is_dir = batch_entries[i].type == glob.DT_DIR;
                    if (batch_entries[i].type == glob.DT_UNKNOWN) {
                        var stat_buf: std.c.Stat = undefined;
                        if (std.c.stat(path, &stat_buf) == 0) {
                            is_dir = std.c.S.ISDIR(stat_buf.mode);
                        } else {
                            allocator.free(path_buf_slice);
                            continue;
                        }
                    }

                    if (directories_only and !is_dir) {
                        allocator.free(path_buf_slice);
                        continue;
                    }

                    if (maybeAppendSlash(allocator, path, path_len, is_dir, flags) catch {
                        allocator.free(path_buf_slice);
                        return error.OutOfMemory;
                    }) |new_path| {
                        path = new_path;
                    }

                    names.append(path) catch return error.OutOfMemory;
                }
            }
        }
    }
}

/// Generic SIMD batch processing for path arrays with compile-time batch size
fn matchPathsBatchGeneric(
    comptime BatchSize: usize,
    comptime matchFn: fn ([BatchSize][]const u8, *const SimdBatchedSuffixMatch) callconv(.@"inline") @Vector(BatchSize, bool),
    paths: []const []const u8,
    suffix_ctx: *const SimdBatchedSuffixMatch,
    matches: *std.array_list.AlignedManaged([]const u8, null),
) !void {
    var batch_paths: [BatchSize][]const u8 = undefined;
    var batch_indices: [BatchSize]usize = undefined;
    var batch_count: usize = 0;
    var path_idx: usize = 0;

    while (path_idx < paths.len) {
        batch_paths[batch_count] = paths[path_idx];
        batch_indices[batch_count] = path_idx;
        batch_count += 1;
        path_idx += 1;

        if (batch_count == BatchSize) {
            const match_vec = matchFn(batch_paths, suffix_ctx);
            if (@reduce(.Or, match_vec)) {
                for (0..BatchSize) |i| {
                    if (match_vec[i]) {
                        try matches.append(paths[batch_indices[i]]);
                    }
                }
            }
            batch_count = 0;
        }
    }

    if (batch_count > 0) {
        for (batch_count..BatchSize) |i| {
            batch_paths[i] = "";
        }

        const match_vec = matchFn(batch_paths, suffix_ctx);
        if (@reduce(.Or, match_vec)) {
            for (0..batch_count) |i| {
                if (match_vec[i]) {
                    try matches.append(paths[batch_indices[i]]);
                }
            }
        }
    }
}
