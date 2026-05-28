use crate::error::ZlobError;
use crate::ffi;
use crate::flags::ZlobFlags;
use crate::indicies::ZlobIndicies;
use crate::match_paths::ZlobMatch;
use std::ffi::c_char;
use std::ptr::NonNull;

/// A compiled glob pattern. Reusable for any number of path matches.
/// Captures all the information about pattern at compile time, gaurantees 0 allocation during matching
///
/// # Example: chunked batching
///
/// ```
/// use zlob::{ZlobPattern, ZlobFlags};
/// let paths_owned: Vec<String> = (0..2000)
///      .map(|i| format!("path/{}/file.rs", i))
///      .collect();
///
/// let paths: Vec<_> = paths_owned.iter().map(|s| s.as_str()).collect();
/// let pattern = ZlobPattern::compile("**/*.rs", ZlobFlags::empty())?;
/// let mut total = 0;
///
/// // for max performance & SIMD utilization it is recomended to supply results in batches
/// for chunk in paths.chunks(512) {
///     let hits = pattern.match_indices(chunk, ZlobFlags::empty())?;
///     total += hits.len();
/// }
///
/// // though it is still pretty fast to match the paths sequentially
/// let hits: Vec<_> = paths.iter().filter(|p| pattern.matches(p, ZlobFlags::empty())).collect();
/// # assert_eq!(total, 2000);
/// # Ok::<(), zlob::ZlobError>(())
/// ```
pub struct ZlobPattern {
    inner: NonNull<ffi::zlob_pattern_t>,
    /// Flags this pattern was compiled under. Stored so [`Self::matches_default`]
    /// can pass the same flags without forcing the caller to remember them.
    flags: ZlobFlags,
}

impl ZlobPattern {
    /// Compile a glob pattern. The pattern string is copied internally; the
    /// caller may drop it immediately after this call returns.
    pub fn compile(pattern: &str, flags: ZlobFlags) -> Result<Self, ZlobError> {
        // SAFETY: `zlob_pattern_compile_slice` accepts a non-null-terminated
        // (ptr, len) slice. zlob_slice_t and &str have identical layout — same
        // transmute trick used elsewhere in the crate.
        let slice: &ffi::zlob_slice_t = unsafe { std::mem::transmute(&pattern) };
        let raw = unsafe { ffi::zlob_pattern_compile_slice(slice, flags.bits()) };
        match NonNull::new(raw) {
            Some(p) => Ok(ZlobPattern { inner: p, flags }),
            None => Err(ZlobError::NoSpace),
        }
    }

    /// The flags this pattern was compiled under.
    #[inline]
    pub fn flags(&self) -> ZlobFlags {
        self.flags
    }

    /// Match a single path against this compiled pattern. Allocation-free.
    ///
    /// Use this in any caller-driven loop, iterator, or chunked pipeline.
    ///
    /// `flags` must agree with the compile-time flags on the structural bits
    /// (BRACE / DOUBLESTAR_RECURSIVE / EXTGLOB); debug builds assert this.
    /// Behavioral bits (PERIOD / NOESCAPE / etc.) may be flipped per call.
    #[inline]
    pub fn matches(&self, path: &str, flags: ZlobFlags) -> bool {
        unsafe {
            ffi::zlob_pattern_matches(
                self.inner.as_ptr(),
                path.as_ptr() as *const c_char,
                path.len(),
                flags.bits(),
            ) != 0
        }
    }

    /// Match a single path using the same flags this pattern was compiled
    /// under. Equivalent to `matches(path, self.flags())`.
    #[inline]
    pub fn matches_default(&self, path: &str) -> bool {
        self.matches(path, self.flags)
    }

    /// Batch match: return references to paths that match.
    ///
    /// The returned `ZlobMatch` borrows path slices from the input — the
    /// caller must keep `paths` alive until the result is dropped.
    pub fn match_paths<'a>(
        &self,
        paths: &'a [&str],
        flags: ZlobFlags,
    ) -> Result<Option<ZlobMatch<'a>>, ZlobError> {
        let path_slices: &[ffi::zlob_slice_t] = unsafe { std::mem::transmute(paths) };
        let mut inner = ffi::zlob_t::default();

        let result = unsafe {
            ffi::zlob_pattern_match_paths_slice(
                self.inner.as_ptr(),
                path_slices.as_ptr(),
                path_slices.len(),
                flags.bits(),
                &mut inner,
            )
        };

        match ZlobError::from_code(result) {
            Ok(true) => Ok(Some(unsafe { ZlobMatch::from_raw(inner) })),
            Ok(false) => Ok(None),
            Err(err) => Err(err),
        }
    }

    /// At-flow variant of [`Self::match_paths`].
    pub fn match_paths_at<'a>(
        &self,
        base_path: &str,
        paths: &'a [&str],
        flags: ZlobFlags,
    ) -> Result<Option<ZlobMatch<'a>>, ZlobError> {
        let base_slice: &ffi::zlob_slice_t = unsafe { std::mem::transmute(&base_path) };
        let path_slices: &[ffi::zlob_slice_t] = unsafe { std::mem::transmute(paths) };
        let mut inner = ffi::zlob_t::default();

        let result = unsafe {
            ffi::zlob_pattern_match_paths_at_slice(
                self.inner.as_ptr(),
                base_slice,
                path_slices.as_ptr(),
                path_slices.len(),
                flags.bits(),
                &mut inner,
            )
        };

        match ZlobError::from_code(result) {
            Ok(true) => Ok(Some(unsafe { ZlobMatch::from_raw(inner) })),
            Ok(false) => Ok(None),
            Err(err) => Err(err),
        }
    }

    /// Batch match: return the indices into `paths` of all matching paths,
    /// in input order. Borrows the C-allocated buffer directly — no copy.
    ///
    /// Returns an empty [`ZlobIndicies`] for the no-match case (no `Option`
    /// wrapper — empty is the natural representation for callers that iterate).
    pub fn match_indices(
        &self,
        paths: &[&str],
        flags: ZlobFlags,
    ) -> Result<ZlobIndicies, ZlobError> {
        let path_slices: &[ffi::zlob_slice_t] = unsafe { std::mem::transmute(paths) };
        let mut out = ffi::zlob_indices_t {
            indices: std::ptr::null_mut(),
            count: 0,
        };

        let code = unsafe {
            ffi::zlob_pattern_match_paths_indices_slice(
                self.inner.as_ptr(),
                path_slices.as_ptr(),
                path_slices.len(),
                flags.bits(),
                &mut out,
            )
        };

        ZlobIndicies::from_ffi(code, out)
    }

    /// At-flow variant of [`Self::match_indices`].
    pub fn match_indices_at(
        &self,
        base_path: &str,
        paths: &[&str],
        flags: ZlobFlags,
    ) -> Result<ZlobIndicies, ZlobError> {
        let base_slice: &ffi::zlob_slice_t = unsafe { std::mem::transmute(&base_path) };
        let path_slices: &[ffi::zlob_slice_t] = unsafe { std::mem::transmute(paths) };
        let mut out = ffi::zlob_indices_t {
            indices: std::ptr::null_mut(),
            count: 0,
        };

        let code = unsafe {
            ffi::zlob_pattern_match_paths_indices_at_slice(
                self.inner.as_ptr(),
                base_slice,
                path_slices.as_ptr(),
                path_slices.len(),
                flags.bits(),
                &mut out,
            )
        };

        ZlobIndicies::from_ffi(code, out)
    }
}

impl std::fmt::Debug for ZlobPattern {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ZlobPattern")
            .field("flags", &self.flags)
            .finish()
    }
}

impl Drop for ZlobPattern {
    fn drop(&mut self) {
        unsafe { ffi::zlob_pattern_free(self.inner.as_ptr()) };
    }
}

// SAFETY: ZlobPattern is read-only after compile and owns its memory.
unsafe impl Send for ZlobPattern {}
// SAFETY: matches() / match_*() take &self and the underlying CompiledPattern
// is read-only (the only write happens during compile / drop).
unsafe impl Sync for ZlobPattern {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{zlob_match_paths_indices, zlob_match_paths_indices_at};

    fn assert_send<T: Send>() {}
    fn assert_sync<T: Sync>() {}

    #[test]
    fn pattern_is_send_and_sync() {
        assert_send::<ZlobPattern>();
        assert_sync::<ZlobPattern>();
    }

    #[test]
    fn compile_literal() {
        let p = ZlobPattern::compile("src/main.rs", ZlobFlags::empty()).unwrap();
        assert!(p.matches("src/main.rs", ZlobFlags::empty()));
        assert!(!p.matches("src/lib.rs", ZlobFlags::empty()));
    }

    #[test]
    fn compile_simple_suffix() {
        let p = ZlobPattern::compile("*.rs", ZlobFlags::empty()).unwrap();
        assert!(p.matches("foo.rs", ZlobFlags::empty()));
        assert!(p.matches("a/b/c.rs", ZlobFlags::empty()));
        assert!(!p.matches("foo.txt", ZlobFlags::empty()));
    }

    #[test]
    fn compile_brace_multi_suffix() {
        let p = ZlobPattern::compile("*.{c,h}", ZlobFlags::BRACE).unwrap();
        assert!(p.matches("foo.c", ZlobFlags::BRACE));
        assert!(p.matches("foo.h", ZlobFlags::BRACE));
        assert!(!p.matches("foo.txt", ZlobFlags::BRACE));
    }

    #[test]
    fn compile_general_doublestar() {
        let p = ZlobPattern::compile("src/**/*.rs", ZlobFlags::DOUBLESTAR_RECURSIVE).unwrap();
        let f = ZlobFlags::DOUBLESTAR_RECURSIVE;
        assert!(p.matches("src/foo.rs", f));
        assert!(p.matches("src/sub/dir/bar.rs", f));
        assert!(!p.matches("test/foo.rs", f));
    }

    #[test]
    fn matches_default_uses_compile_flags() {
        let p = ZlobPattern::compile("*.{c,h}", ZlobFlags::BRACE).unwrap();
        assert!(p.matches_default("foo.c"));
        assert!(!p.matches_default("foo.txt"));
    }

    #[test]
    fn match_paths_basic() {
        let paths = ["foo.rs", "bar.txt", "baz.rs"];
        let p = ZlobPattern::compile("*.rs", ZlobFlags::empty()).unwrap();
        let result = p.match_paths(&paths, ZlobFlags::empty()).unwrap().unwrap();
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn match_indices_basic() {
        let paths = ["foo.rs", "bar.txt", "baz.rs", "qux.md"];
        let p = ZlobPattern::compile("*.rs", ZlobFlags::empty()).unwrap();
        let hits = p.match_indices(&paths, ZlobFlags::empty()).unwrap();
        assert_eq!(hits.as_slice(), &[0, 2]);
    }

    #[test]
    fn match_indices_no_match_is_empty_vec() {
        let paths = ["foo.txt", "bar.md"];
        let p = ZlobPattern::compile("*.rs", ZlobFlags::empty()).unwrap();
        let hits = p.match_indices(&paths, ZlobFlags::empty()).unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn match_indices_input_order_preserved() {
        // NOSORT is implicitly the only behavior — input order regardless.
        let paths = ["z.rs", "a.rs", "m.rs"];
        let p = ZlobPattern::compile("*.rs", ZlobFlags::empty()).unwrap();
        let hits = p.match_indices(&paths, ZlobFlags::empty()).unwrap();
        assert_eq!(hits.as_slice(), &[0, 1, 2]);
    }

    #[test]
    fn match_indices_at() {
        let paths = ["/proj/src/lib.rs", "/proj/src/main.rs", "/proj/README.md"];
        let p = ZlobPattern::compile("src/*.rs", ZlobFlags::empty()).unwrap();
        let hits = p
            .match_indices_at("/proj", &paths, ZlobFlags::empty())
            .unwrap();
        assert_eq!(hits.as_slice(), &[0, 1]);
    }

    #[test]
    fn pattern_reused_across_chunks() {
        let p = ZlobPattern::compile("*.rs", ZlobFlags::empty()).unwrap();
        let chunk1 = ["a.rs", "b.txt"];
        let chunk2 = ["c.rs", "d.rs", "e.md"];
        let h1 = p.match_indices(&chunk1, ZlobFlags::empty()).unwrap();
        let h2 = p.match_indices(&chunk2, ZlobFlags::empty()).unwrap();
        assert_eq!(h1.as_slice(), &[0]);
        assert_eq!(h2.as_slice(), &[0, 1]);
    }

    #[test]
    fn free_fn_match_paths_indices() {
        let paths = ["a.rs", "b.txt", "c.rs"];
        let hits = zlob_match_paths_indices("*.rs", &paths, ZlobFlags::empty()).unwrap();
        assert_eq!(hits.as_slice(), &[0, 2]);
    }

    #[test]
    fn free_fn_match_paths_indices_at() {
        let paths = ["/proj/src/lib.rs", "/proj/src/main.rs", "/proj/README.md"];
        let hits =
            zlob_match_paths_indices_at("/proj", "src/*.rs", &paths, ZlobFlags::empty()).unwrap();
        assert_eq!(hits.as_slice(), &[0, 1]);
    }

    #[test]
    fn drop_does_not_double_free() {
        // Compile + drop in a tight loop to surface any double-free regressions.
        for _ in 0..100 {
            let p = ZlobPattern::compile("**/*.rs", ZlobFlags::DOUBLESTAR_RECURSIVE).unwrap();
            assert!(p.matches("a/b/c.rs", ZlobFlags::DOUBLESTAR_RECURSIVE));
        }
    }

    #[test]
    fn flags_returns_compile_flags() {
        let p = ZlobPattern::compile("*.{c,h}", ZlobFlags::BRACE).unwrap();
        assert_eq!(p.flags(), ZlobFlags::BRACE);
    }

    #[test]
    fn match_paths_at_basic() {
        let paths = ["/proj/src/lib.rs", "/proj/src/main.rs", "/proj/README.md"];
        let p = ZlobPattern::compile("src/*.rs", ZlobFlags::empty()).unwrap();
        let result = p
            .match_paths_at("/proj", &paths, ZlobFlags::empty())
            .unwrap()
            .unwrap();
        assert_eq!(result.len(), 2);
        let strs = result.as_strs();
        assert!(strs.contains(&"/proj/src/lib.rs"));
        assert!(strs.contains(&"/proj/src/main.rs"));
    }

    #[test]
    fn match_paths_at_no_match_is_none() {
        let paths = ["/proj/README.md"];
        let p = ZlobPattern::compile("src/*.rs", ZlobFlags::empty()).unwrap();
        let result = p
            .match_paths_at("/proj", &paths, ZlobFlags::empty())
            .unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn match_paths_no_match_is_none() {
        let paths = ["foo.txt", "bar.md"];
        let p = ZlobPattern::compile("*.rs", ZlobFlags::empty()).unwrap();
        assert!(p.match_paths(&paths, ZlobFlags::empty()).unwrap().is_none());
    }

    #[test]
    fn match_indices_at_no_match_is_empty() {
        let paths = ["/proj/README.md"];
        let p = ZlobPattern::compile("src/*.rs", ZlobFlags::empty()).unwrap();
        let hits = p
            .match_indices_at("/proj", &paths, ZlobFlags::empty())
            .unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn matches_per_call_period_flag() {
        // Behavioral flag (PERIOD) flipped per call without recompiling. Uses a
        // doublestar pattern so the per-component hidden-file logic engages.
        let f = ZlobFlags::DOUBLESTAR_RECURSIVE;
        let p = ZlobPattern::compile("dir/**", f).unwrap();
        assert!(!p.matches("dir/.hidden", f));
        assert!(p.matches("dir/.hidden", f | ZlobFlags::PERIOD));
    }
}
