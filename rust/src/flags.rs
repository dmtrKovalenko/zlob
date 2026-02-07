//! Flag types for zlob operations.
//!
//! Flag values are imported from the C header via bindgen (single source of truth).

use bitflags::bitflags;

use crate::ffi;

bitflags! {
    /// Bitflags options for zlob configuration
    ///
    /// # Example
    ///
    /// ```
    /// use zlob::ZlobFlags;
    ///
    /// // Combine flags with bitwise OR
    /// let flags = ZlobFlags::BRACE | ZlobFlags::NOSORT | ZlobFlags::PERIOD;
    /// ```
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
    pub struct ZlobFlags: i32 {
        /// Return on read errors.
        const ERR = ffi::ZLOB_ERR;

        /// Append a slash to each directory name.
        const MARK = ffi::ZLOB_MARK;

        /// Don't sort the names.
        const NOSORT = ffi::ZLOB_NOSORT;

        /// Insert `offs` NULLs at beginning of result array.
        const DOOFFS = ffi::ZLOB_DOOFFS;

        /// Return the pattern itself if no matches found.
        const NOCHECK = ffi::ZLOB_NOCHECK;

        /// Append results to a previous zlob call.
        const APPEND = ffi::ZLOB_APPEND;

        /// Backslashes don't escape metacharacters.
        const NOESCAPE = ffi::ZLOB_NOESCAPE;

        /// Leading `.` can be matched by wildcards.
        const PERIOD = ffi::ZLOB_PERIOD;

        /// GNU: Use custom directory functions.
        const ALTDIRFUNC = ffi::ZLOB_ALTDIRFUNC;

        /// Expand `{a,b,c}` brace patterns.
        ///
        /// # Example
        ///
        /// ```no_run
        /// use zlob::{zlob, ZlobFlags};
        /// let result = zlob("src/{lib,main}.rs", ZlobFlags::BRACE).unwrap();
        /// ```
        const BRACE = ffi::ZLOB_BRACE;

        /// GNU: If no magic characters, return the pattern literally.
        const NOMAGIC = ffi::ZLOB_NOMAGIC;

        /// Expand `~` to home directory.
        ///
        /// # Example
        ///
        /// ```no_run
        /// use zlob::{zlob, ZlobFlags};
        /// let result = zlob("~/.config/*", ZlobFlags::TILDE).unwrap();
        /// ```
        const TILDE = ffi::ZLOB_TILDE;

        /// Match only directories.
        const ONLYDIR = ffi::ZLOB_ONLYDIR;

        /// GNU: Like TILDE, but return error if user is not available.
        const TILDE_CHECK = ffi::ZLOB_TILDE_CHECK;

        // zlob extensions (bits 24+)

        /// Filter results using `.gitignore` rules from the current directory.
        ///
        /// # Example
        ///
        /// ```no_run
        /// use zlob::{zlob, ZlobFlags};
        /// let result = zlob("**/*.rs", ZlobFlags::GITIGNORE | ZlobFlags::DOUBLESTAR_RECURSIVE).unwrap();
        /// ```
        const GITIGNORE = ffi::ZLOB_GITIGNORE;

        /// Enable `**` recursive directory matching.
        ///
        /// # Example
        ///
        /// ```no_run
        /// use zlob::{zlob, ZlobFlags};
        /// let result = zlob("**/*.rs", ZlobFlags::DOUBLESTAR_RECURSIVE).unwrap();
        /// ```
        const DOUBLESTAR_RECURSIVE = ffi::ZLOB_DOUBLESTAR_RECURSIVE;

        /// Enable extended glob patterns (extglob).
        ///
        /// Supports: `?(pat)`, `*(pat)`, `+(pat)`, `@(pat)`, `!(pat)`
        ///
        /// # Example
        ///
        /// ```no_run
        /// use zlob::{zlob, ZlobFlags};
        /// let result = zlob("src/*.!(js|ts)", ZlobFlags::EXTGLOB | ZlobFlags::RECOMMENDED).unwrap();
        /// ```
        const EXTGLOB = ffi::ZLOB_EXTGLOB;

        /// Recommended modern defaults for globbing.
        ///
        /// Enables: BRACE, DOUBLESTAR_RECURSIVE, NOSORT, TILDE, TILDE_CHECK
        ///
        /// # Example
        ///
        /// ```no_run
        /// use zlob::{zlob, ZlobFlags};
        /// let result = zlob("**/*.rs", ZlobFlags::RECOMMENDED).unwrap();
        /// ```
        const RECOMMENDED = ffi::ZLOB_RECOMMENDED;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_flag_values_match_c_header() {
        // Values come from bindgen, so these tests verify the bitflags! macro works correctly
        assert_eq!(ZlobFlags::ERR.bits(), 0x0001);
        assert_eq!(ZlobFlags::MARK.bits(), 0x0002);
        assert_eq!(ZlobFlags::NOSORT.bits(), 0x0004);
        assert_eq!(ZlobFlags::DOOFFS.bits(), 0x0008);
        assert_eq!(ZlobFlags::NOCHECK.bits(), 0x0010);
        assert_eq!(ZlobFlags::APPEND.bits(), 0x0020);
        assert_eq!(ZlobFlags::NOESCAPE.bits(), 0x0040);
        assert_eq!(ZlobFlags::PERIOD.bits(), 0x0080);
        assert_eq!(ZlobFlags::ALTDIRFUNC.bits(), 0x0200);
        assert_eq!(ZlobFlags::BRACE.bits(), 0x0400);
        assert_eq!(ZlobFlags::NOMAGIC.bits(), 0x0800);
        assert_eq!(ZlobFlags::TILDE.bits(), 0x1000);
        assert_eq!(ZlobFlags::ONLYDIR.bits(), 0x2000);
        assert_eq!(ZlobFlags::TILDE_CHECK.bits(), 0x4000);
        assert_eq!(ZlobFlags::GITIGNORE.bits(), 1 << 24);
        assert_eq!(ZlobFlags::DOUBLESTAR_RECURSIVE.bits(), 1 << 25);
        assert_eq!(ZlobFlags::EXTGLOB.bits(), 1 << 26);
    }

    #[test]
    fn test_recommended_contains_expected_flags() {
        let recommended = ZlobFlags::RECOMMENDED;
        assert!(recommended.contains(ZlobFlags::BRACE));
        assert!(recommended.contains(ZlobFlags::DOUBLESTAR_RECURSIVE));
        assert!(recommended.contains(ZlobFlags::NOSORT));
        assert!(recommended.contains(ZlobFlags::TILDE));
        assert!(recommended.contains(ZlobFlags::TILDE_CHECK));
        assert!(!recommended.contains(ZlobFlags::EXTGLOB));
    }
}
