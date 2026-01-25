//! Flag types for zlob operations.

use bitflags::bitflags;

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
        ///
        /// If set, glob will return `ZlobError::Aborted` when a directory
        /// cannot be read. Otherwise, errors are ignored.
        const ERR = 1 << 0;

        /// Append a slash to each directory name.
        ///
        /// Matched directories will have a trailing `/` appended.
        const MARK = 1 << 1;

        /// Don't sort the names.
        ///
        /// By default, results are sorted alphabetically. This flag disables
        /// sorting for potentially faster results.
        const NOSORT = 1 << 2;

        /// Insert `gl_offs` NULLs at beginning of result array.
        ///
        /// This is mainly for POSIX compatibility and rarely needed.
        const DOOFFS = 1 << 3;

        /// Return the pattern itself if no matches found.
        ///
        /// Instead of returning `Ok(None)`, the pattern string
        /// itself will be returned as the sole result.
        const NOCHECK = 1 << 4;

        /// Append results to a previous zlob call.
        ///
        /// New matches are added to existing results instead of replacing them.
        const APPEND = 1 << 5;

        /// Backslashes don't escape metacharacters.
        ///
        /// Normally, `\*` matches a literal `*`. With this flag, backslashes
        /// are treated as regular characters.
        const NOESCAPE = 1 << 6;

        /// Leading `.` can be matched by wildcards.
        ///
        /// By default, patterns like `*` don't match files starting with `.`.
        /// This flag allows wildcards to match hidden files.
        const PERIOD = 1 << 7;

        /// GNU: Set in gl_flags if any metacharacters were seen (output only).
        ///
        /// This is an output flag, not an input flag.
        const MAGCHAR = 1 << 8;

        /// GNU: Use custom directory functions (gl_opendir, gl_readdir, gl_closedir).
        /// !IMPORTANT! there is no api support for rust crate to set those functions yet.
        const ALTDIRFUNC = 1 << 9;

        /// Expand `{a,b,c}` brace patterns.
        ///
        /// With this flag, `{foo,bar}` expands to match both "foo" and "bar".
        ///
        /// # Example
        ///
        /// ```no_run
        /// use zlob::{zlob, ZlobFlags};
        ///
        /// let result = zlob("src/{lib,main}.rs", ZlobFlags::BRACE).unwrap();
        /// ```
        const BRACE = 1 << 10;

        /// GNU: If no magic characters, return the pattern literally.
        ///
        /// Similar to NOCHECK, but only applies when the pattern contains
        /// no wildcards.
        const NOMAGIC = 1 << 11;

        /// Expand `~` to home directory.
        ///
        /// With this flag:
        /// - `~` expands to the current user's home directory
        /// - `~/path` expands to `$HOME/path`
        /// - `~user/path` expands to that user's home directory
        ///
        /// # Example
        ///
        /// ```no_run
        /// use zlob::{zlob, ZlobFlags};
        ///
        /// let result = zlob("~/.config/*", ZlobFlags::TILDE).unwrap();
        /// ```
        const TILDE = 1 << 12;

        /// Match only directories.
        ///
        /// Regular files are excluded from results.
        const ONLYDIR = 1 << 13;

        /// GNU: Like TILDE, but return error if user is not available.
        ///
        /// If the user in `~user` cannot be found, returns an error instead
        /// of leaving it unexpanded.
        const TILDE_CHECK = 1 << 14;

        // =====================================================================
        // zlob extensions (bits 24+)
        // NOTE: Bits 15-23 are reserved for potential future glibc extensions.
        // glibc currently uses bits 0-14. We leave a 9-bit gap to avoid conflicts.
        // =====================================================================

        /// Filter results using `.gitignore` rules from the current directory.
        ///
        /// Matches are filtered against gitignore patterns, excluding files
        /// that would be ignored by git.
        ///
        /// # Example
        ///
        /// ```no_run
        /// use zlob::{zlob, ZlobFlags};
        ///
        /// // Find all .rs files, excluding those in .gitignore
        /// let result = zlob("**/*.rs", ZlobFlags::GITIGNORE | ZlobFlags::DOUBLESTAR_RECURSIVE).unwrap();
        /// ```
        const GITIGNORE = 1 << 24;

        /// Enable `**` recursive directory matching.
        ///
        /// By default (for glibc compatibility), `**` is treated as `*` (single-level match).
        /// With this flag, `**` matches zero or more directory levels recursively.
        ///
        /// # Example
        ///
        /// ```no_run
        /// use zlob::{zlob, ZlobFlags};
        ///
        /// // Find all .rs files recursively
        /// let result = zlob("**/*.rs", ZlobFlags::DOUBLESTAR_RECURSIVE).unwrap();
        /// ```
        const DOUBLESTAR_RECURSIVE = 1 << 25;

        /// Recommended modern defaults for globbing.
        ///
        /// This flag combination enables the most commonly desired behaviors:
        /// - `BRACE`: Brace expansion `{a,b,c}`
        /// - `DOUBLESTAR_RECURSIVE`: Recursive `**` patterns like `**/*.rs`
        /// - `NOSORT`: Skip sorting for better performance
        /// - `TILDE`: Home directory expansion `~`
        /// - `TILDE_CHECK`: Error if `~user` is not found
        ///
        /// **Use this for typical glob usage** unless you need glibc-compatible behavior.
        ///
        /// # Example
        ///
        /// ```no_run
        /// use zlob::{zlob, ZlobFlags};
        ///
        /// // Recommended way to glob
        /// let result = zlob("**/*.rs", ZlobFlags::RECOMMENDED).unwrap();
        ///
        /// // With additional flags
        /// let result = zlob("**/*.rs", ZlobFlags::RECOMMENDED | ZlobFlags::GITIGNORE).unwrap();
        /// ```
        const RECOMMENDED = Self::BRACE.bits() | Self::DOUBLESTAR_RECURSIVE.bits()
                          | Self::NOSORT.bits() | Self::TILDE.bits() | Self::TILDE_CHECK.bits();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_flag_values() {
        // Verify flag values match the C header
        assert_eq!(ZlobFlags::ERR.bits(), 0x0001);
        assert_eq!(ZlobFlags::MARK.bits(), 0x0002);
        assert_eq!(ZlobFlags::NOSORT.bits(), 0x0004);
        assert_eq!(ZlobFlags::DOOFFS.bits(), 0x0008);
        assert_eq!(ZlobFlags::NOCHECK.bits(), 0x0010);
        assert_eq!(ZlobFlags::APPEND.bits(), 0x0020);
        assert_eq!(ZlobFlags::NOESCAPE.bits(), 0x0040);
        assert_eq!(ZlobFlags::PERIOD.bits(), 0x0080);
        assert_eq!(ZlobFlags::MAGCHAR.bits(), 0x0100);
        assert_eq!(ZlobFlags::ALTDIRFUNC.bits(), 0x0200);
        assert_eq!(ZlobFlags::BRACE.bits(), 0x0400);
        assert_eq!(ZlobFlags::NOMAGIC.bits(), 0x0800);
        assert_eq!(ZlobFlags::TILDE.bits(), 0x1000);
        assert_eq!(ZlobFlags::ONLYDIR.bits(), 0x2000);
        assert_eq!(ZlobFlags::TILDE_CHECK.bits(), 0x4000);
        // zlob extensions (bits 24+)
        assert_eq!(ZlobFlags::GITIGNORE.bits(), 1 << 24);
        assert_eq!(ZlobFlags::DOUBLESTAR_RECURSIVE.bits(), 1 << 25);
    }

    #[test]
    fn test_flag_combinations() {
        let flags = ZlobFlags::BRACE | ZlobFlags::NOSORT;
        assert!(flags.contains(ZlobFlags::BRACE));
        assert!(flags.contains(ZlobFlags::NOSORT));
        assert!(!flags.contains(ZlobFlags::TILDE));
    }

    #[test]
    fn test_default_is_empty() {
        assert_eq!(ZlobFlags::default(), ZlobFlags::empty());
    }

    #[test]
    fn test_recommended_contains_expected_flags() {
        let recommended = ZlobFlags::RECOMMENDED;
        assert!(recommended.contains(ZlobFlags::BRACE));
        assert!(recommended.contains(ZlobFlags::DOUBLESTAR_RECURSIVE));
        assert!(recommended.contains(ZlobFlags::NOSORT));
        assert!(recommended.contains(ZlobFlags::TILDE));
        assert!(recommended.contains(ZlobFlags::TILDE_CHECK));
        // Should NOT contain these
        assert!(!recommended.contains(ZlobFlags::ERR));
        assert!(!recommended.contains(ZlobFlags::MARK));
        assert!(!recommended.contains(ZlobFlags::GITIGNORE));
        assert!(!recommended.contains(ZlobFlags::PERIOD));
    }
}
