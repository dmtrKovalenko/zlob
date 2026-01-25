//! ZLOB flag constants and types
//!
//! This module contains all glob flag definitions used across the zlob library.
//! Flags are compatible with POSIX glob() and GNU extensions.

const std = @import("std");

// ============================================================================
// Standard POSIX glob flags (matching glibc values exactly)
// ============================================================================
pub const ZLOB_ERR = 1 << 0; // 0x0001 - Return on read errors
pub const ZLOB_MARK = 1 << 1; // 0x0002 - Append a slash to each name
pub const ZLOB_NOSORT = 1 << 2; // 0x0004 - Don't sort the names
pub const ZLOB_DOOFFS = 1 << 3; // 0x0008 - Insert PZLOB->gl_offs NULLs
pub const ZLOB_NOCHECK = 1 << 4; // 0x0010 - If nothing matches, return the pattern
pub const ZLOB_APPEND = 1 << 5; // 0x0020 - Append to results of a previous call
pub const ZLOB_NOESCAPE = 1 << 6; // 0x0040 - Backslashes don't quote metacharacters
pub const ZLOB_PERIOD = 1 << 7; // 0x0080 - Leading `.` can be matched by metachars

// ============================================================================
// GNU extensions
// ============================================================================
pub const ZLOB_MAGCHAR = 1 << 8; // 0x0100 - Set in gl_flags if any metachars seen
pub const ZLOB_ALTDIRFUNC = 1 << 9; // 0x0200 - Use gl_opendir et al functions
pub const ZLOB_BRACE = 1 << 10; // 0x0400 - Expand "{a,b}" to "a" "b"
pub const ZLOB_NOMAGIC = 1 << 11; // 0x0800 - If no magic chars, return the pattern
pub const ZLOB_TILDE = 1 << 12; // 0x1000 - Expand ~user and ~ to home directories
pub const ZLOB_ONLYDIR = 1 << 13; // 0x2000 - Match only directories
pub const ZLOB_TILDE_CHECK = 1 << 14; // 0x4000 - Like ZLOB_TILDE but return error if user name not available

// ============================================================================
// zlob extensions (bits 24+)
// NOTE: Bits 15-23 are reserved for potential future glibc extensions.
// glibc currently uses bits 0-14. We leave a 9-bit gap to avoid conflicts
// if glibc adds more flags in future versions.
// ============================================================================
pub const ZLOB_GITIGNORE = 1 << 24; // Filter results using .gitignore from cwd
pub const ZLOB_DOUBLESTAR_RECURSIVE = 1 << 25; // Enable ** recursive directory matching

/// Recommended modern defaults for globbing
///
/// enables:
/// - Brace expansion `something.{c,h}`
/// - Recursive `**` matching patterns like `./**/*.c`
/// - Tilde expansion `~` and `~user`
/// - Tilde user check (error if user not found)
///
/// And disables sorting of results for better performance becuase 99% of time order is not imprtant
pub const ZLOB_RECOMMENDED = ZLOB_BRACE | ZLOB_DOUBLESTAR_RECURSIVE | ZLOB_NOSORT | ZLOB_TILDE | ZLOB_TILDE_CHECK;

// ============================================================================
// Internal flags
// ============================================================================
pub const ZLOB_FLAGS_SHARED_STRINGS: c_int = 0;
pub const ZLOB_FLAGS_OWNS_STRINGS: c_int = 1 << 0;

// ============================================================================
// Error codes
// ============================================================================
pub const ZLOB_NOSPACE = 1;
pub const ZLOB_ABORTED = 2;
pub const ZLOB_NOMATCH = 3;

pub const ZlobFlags = packed struct(u32) {
    // Standard POSIX glob flags (bits 0-7)
    err: bool = false,
    mark: bool = false,
    nosort: bool = false,
    dooffs: bool = false,
    nocheck: bool = false,
    append: bool = false,
    noescape: bool = false,
    period: bool = false,

    // GNU extensions (bits 8-14)
    magchar: bool = false,
    altdirfunc: bool = false,
    brace: bool = false,
    nomagic: bool = false,
    tilde: bool = false,
    onlydir: bool = false,
    tilde_check: bool = false,

    // Reserved for future glibc extensions (bits 15-23)
    // glibc currently uses bits 0-14. We reserve 9 bits to avoid
    // conflicts if glibc adds more flags in future versions.
    _reserved_for_glibc: u9 = 0,

    // zlob extensions (bits 24+)
    gitignore: bool = false,
    doublestar_recursive: bool = false,

    // fill the rest of 32 bites
    _padding: u6 = 0,

    pub fn recommended() ZlobFlags {
        return ZlobFlags{
            .brace = true,
            .doublestar_recursive = true,
            .nosort = true,
            .tilde = true,
            .tilde_check = true,
        };
    }

    pub fn toInt(self: ZlobFlags) c_int {
        return @bitCast(self);
    }

    pub fn fromInt(flags: c_int) ZlobFlags {
        return @bitCast(flags);
    }

    pub fn fromU32(flags: u32) ZlobFlags {
        return @bitCast(flags);
    }

    pub fn toU32(self: ZlobFlags) u32 {
        return @bitCast(self);
    }

    pub fn with(self: ZlobFlags, other: ZlobFlags) ZlobFlags {
        return fromU32(self.toU32() | other.toU32());
    }

    pub fn without(self: ZlobFlags, other: ZlobFlags) ZlobFlags {
        return fromU32(self.toU32() & ~other.toU32());
    }

    comptime {
        std.debug.assert(@sizeOf(ZlobFlags) == @sizeOf(u32));
        std.debug.assert(@bitSizeOf(ZlobFlags) == @bitSizeOf(u32));

        std.debug.assert((ZlobFlags{ .err = true }).toU32() == ZLOB_ERR);
        std.debug.assert((ZlobFlags{ .mark = true }).toU32() == ZLOB_MARK);
        std.debug.assert((ZlobFlags{ .nosort = true }).toU32() == ZLOB_NOSORT);
        std.debug.assert((ZlobFlags{ .dooffs = true }).toU32() == ZLOB_DOOFFS);
        std.debug.assert((ZlobFlags{ .nocheck = true }).toU32() == ZLOB_NOCHECK);
        std.debug.assert((ZlobFlags{ .append = true }).toU32() == ZLOB_APPEND);
        std.debug.assert((ZlobFlags{ .noescape = true }).toU32() == ZLOB_NOESCAPE);
        std.debug.assert((ZlobFlags{ .period = true }).toU32() == ZLOB_PERIOD);
        std.debug.assert((ZlobFlags{ .magchar = true }).toU32() == ZLOB_MAGCHAR);
        std.debug.assert((ZlobFlags{ .altdirfunc = true }).toU32() == ZLOB_ALTDIRFUNC);
        std.debug.assert((ZlobFlags{ .brace = true }).toU32() == ZLOB_BRACE);
        std.debug.assert((ZlobFlags{ .nomagic = true }).toU32() == ZLOB_NOMAGIC);
        std.debug.assert((ZlobFlags{ .tilde = true }).toU32() == ZLOB_TILDE);
        std.debug.assert((ZlobFlags{ .onlydir = true }).toU32() == ZLOB_ONLYDIR);
        std.debug.assert((ZlobFlags{ .tilde_check = true }).toU32() == ZLOB_TILDE_CHECK);
        std.debug.assert((ZlobFlags{ .gitignore = true }).toU32() == ZLOB_GITIGNORE);
        std.debug.assert((ZlobFlags{ .doublestar_recursive = true }).toU32() == ZLOB_DOUBLESTAR_RECURSIVE);
    }
};

pub const GlobError = error{
    OutOfMemory,
    Aborted,
};

test "ZlobFlags bit positions match integer constants" {
    const testing = std.testing;

    const f_err = ZlobFlags{ .err = true };
    const f_mark = ZlobFlags{ .mark = true };
    const f_nosort = ZlobFlags{ .nosort = true };
    const f_dooffs = ZlobFlags{ .dooffs = true };
    const f_nocheck = ZlobFlags{ .nocheck = true };
    const f_append = ZlobFlags{ .append = true };
    const f_noescape = ZlobFlags{ .noescape = true };
    const f_period = ZlobFlags{ .period = true };
    const f_magchar = ZlobFlags{ .magchar = true };
    const f_altdirfunc = ZlobFlags{ .altdirfunc = true };
    const f_brace = ZlobFlags{ .brace = true };
    const f_nomagic = ZlobFlags{ .nomagic = true };
    const f_tilde = ZlobFlags{ .tilde = true };
    const f_onlydir = ZlobFlags{ .onlydir = true };
    const f_tilde_check = ZlobFlags{ .tilde_check = true };
    const f_gitignore = ZlobFlags{ .gitignore = true };
    const f_doublestar_recursive = ZlobFlags{ .doublestar_recursive = true };

    try testing.expectEqual(@as(u32, ZLOB_ERR), f_err.toU32());
    try testing.expectEqual(@as(u32, ZLOB_MARK), f_mark.toU32());
    try testing.expectEqual(@as(u32, ZLOB_NOSORT), f_nosort.toU32());
    try testing.expectEqual(@as(u32, ZLOB_DOOFFS), f_dooffs.toU32());
    try testing.expectEqual(@as(u32, ZLOB_NOCHECK), f_nocheck.toU32());
    try testing.expectEqual(@as(u32, ZLOB_APPEND), f_append.toU32());
    try testing.expectEqual(@as(u32, ZLOB_NOESCAPE), f_noescape.toU32());
    try testing.expectEqual(@as(u32, ZLOB_PERIOD), f_period.toU32());
    try testing.expectEqual(@as(u32, ZLOB_MAGCHAR), f_magchar.toU32());
    try testing.expectEqual(@as(u32, ZLOB_ALTDIRFUNC), f_altdirfunc.toU32());
    try testing.expectEqual(@as(u32, ZLOB_BRACE), f_brace.toU32());
    try testing.expectEqual(@as(u32, ZLOB_NOMAGIC), f_nomagic.toU32());
    try testing.expectEqual(@as(u32, ZLOB_TILDE), f_tilde.toU32());
    try testing.expectEqual(@as(u32, ZLOB_ONLYDIR), f_onlydir.toU32());
    try testing.expectEqual(@as(u32, ZLOB_TILDE_CHECK), f_tilde_check.toU32());
    try testing.expectEqual(@as(u32, ZLOB_GITIGNORE), f_gitignore.toU32());
    try testing.expectEqual(@as(u32, ZLOB_DOUBLESTAR_RECURSIVE), f_doublestar_recursive.toU32());
}

test "ZlobFlags roundtrip conversion" {
    const testing = std.testing;

    const combined: u32 = ZLOB_MARK | ZLOB_NOSORT | ZLOB_BRACE | ZLOB_GITIGNORE;
    const flags = ZlobFlags.fromU32(combined);

    try testing.expect(flags.mark);
    try testing.expect(flags.nosort);
    try testing.expect(flags.brace);
    try testing.expect(flags.gitignore);
    try testing.expect(!flags.err);
    try testing.expect(!flags.period);

    try testing.expectEqual(combined, flags.toU32());

    const combined_cint: c_int = @bitCast(combined);
    try testing.expectEqual(combined_cint, flags.toInt());

    const from_cint = ZlobFlags.fromInt(flags.toInt());
    try testing.expectEqual(combined, from_cint.toU32());
}

test "ZLOB_RECOMMENDED contains expected flags" {
    const testing = std.testing;

    const flags = ZlobFlags.fromU32(ZLOB_RECOMMENDED);

    try testing.expect(flags.brace);
    try testing.expect(flags.doublestar_recursive);
    try testing.expect(flags.nosort);
    try testing.expect(flags.tilde);
    try testing.expect(flags.tilde_check);

    try testing.expect(!flags.err);
    try testing.expect(!flags.mark);
    try testing.expect(!flags.gitignore);
}
