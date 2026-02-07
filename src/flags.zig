//! ZLOB flag constants and types
//!
//! This module contains all glob flag definitions used across the zlob library.
//! Flags are compatible with POSIX glob() and GNU extensions.
//!
//! IMPORTANT: The C header (include/zlob.h) is the single source of truth.
//! All flag values are imported from there via @cImport to avoid duplication.

const std = @import("std");

// ============================================================================
// Import flag constants from the C header (single source of truth)
// ============================================================================
const c = @cImport({
    @cInclude("zlob.h");
});

// Standard POSIX glob flags (bits 0-7)
pub const ZLOB_ERR = c.ZLOB_ERR;
pub const ZLOB_MARK = c.ZLOB_MARK;
pub const ZLOB_NOSORT = c.ZLOB_NOSORT;
pub const ZLOB_DOOFFS = c.ZLOB_DOOFFS;
pub const ZLOB_NOCHECK = c.ZLOB_NOCHECK;
pub const ZLOB_APPEND = c.ZLOB_APPEND;
pub const ZLOB_NOESCAPE = c.ZLOB_NOESCAPE;
pub const ZLOB_PERIOD = c.ZLOB_PERIOD;

// GNU extensions (bits 8-14)
pub const ZLOB_MAGCHAR = c.ZLOB_MAGCHAR;
pub const ZLOB_ALTDIRFUNC = c.ZLOB_ALTDIRFUNC;
pub const ZLOB_BRACE = c.ZLOB_BRACE;
pub const ZLOB_NOMAGIC = c.ZLOB_NOMAGIC;
pub const ZLOB_TILDE = c.ZLOB_TILDE;
pub const ZLOB_ONLYDIR = c.ZLOB_ONLYDIR;
pub const ZLOB_TILDE_CHECK = c.ZLOB_TILDE_CHECK;

// zlob extensions (bits 24+)
pub const ZLOB_GITIGNORE = c.ZLOB_GITIGNORE;
pub const ZLOB_DOUBLESTAR_RECURSIVE = c.ZLOB_DOUBLESTAR_RECURSIVE;
pub const ZLOB_EXTGLOB = c.ZLOB_EXTGLOB;
pub const ZLOB_RECOMMENDED = c.ZLOB_RECOMMENDED;

// Error codes
pub const ZLOB_NOSPACE = c.ZLOB_NOSPACE;
pub const ZLOB_ABORTED = c.ZLOB_ABORTED;
pub const ZLOB_NOMATCH = c.ZLOB_NOMATCH;

// ============================================================================
// Internal flags (not in C header - Zig implementation detail)
// ============================================================================
pub const ZLOB_FLAGS_SHARED_STRINGS: c_int = 0;
pub const ZLOB_FLAGS_OWNS_STRINGS: c_int = 1 << 0;

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
    extglob: bool = false,

    // fill the rest of 32 bits
    _padding: u5 = 0,

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
        std.debug.assert((ZlobFlags{ .extglob = true }).toU32() == ZLOB_EXTGLOB);
    }
};

pub const ZlobError = error{
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
    const f_extglob = ZlobFlags{ .extglob = true };

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
    try testing.expectEqual(@as(u32, ZLOB_EXTGLOB), f_extglob.toU32());
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
