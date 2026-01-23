//! Path matching without filesystem access.

use crate::error::ZlobError;
use crate::ffi;
use crate::flags::ZlobFlags;
use std::marker::PhantomData;
use std::slice;

/// Result of `zlob_match_paths()` - zero-copy references to input paths.
///
/// This type holds references to the original input paths, not copies.
/// The lifetime `'a` ensures the original paths remain valid while this exists.
///
/// # Example
///
/// ```
/// use zlob::{zlob_match_paths, ZlobFlags};
///
/// let paths = ["foo.rs", "bar.txt", "baz.rs"];
/// if let Some(matches) = zlob_match_paths("*.rs", &paths, ZlobFlags::empty())? {
///     assert_eq!(matches.len(), 2);
///     for path in &matches {
///         println!("{}", path);
///     }
/// }
/// # Ok::<(), zlob::ZlobError>(())
/// ```
pub struct ZlobMatch<'a> {
    inner: ffi::zlob_t,
    _marker: PhantomData<&'a str>,
}

impl<'a> ZlobMatch<'a> {
    /// Returns the number of matched paths.
    #[inline]
    pub fn len(&self) -> usize {
        self.inner.gl_pathc
    }

    /// Returns `true` if no paths matched.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Returns the matched path at the given index, or `None` if out of bounds.
    ///
    /// The returned reference has lifetime `'a`, tied to the original input paths.
    #[inline]
    pub fn get(&self, index: usize) -> Option<&'a str> {
        if index >= self.len() {
            return None;
        }
        unsafe {
            let ptr = *self.inner.gl_pathv.add(index) as *const u8;
            let len = *self.inner.gl_pathlen.add(index);
            let bytes = slice::from_raw_parts(ptr, len);
            // SAFETY: The input was valid UTF-8 (&str), so the output is too
            Some(std::str::from_utf8_unchecked(bytes))
        }
    }

    /// Returns an iterator over the matched paths.
    #[inline]
    pub fn iter(&self) -> ZlobMatchIter<'a, '_> {
        ZlobMatchIter {
            inner: self,
            front: 0,
            back: self.len(),
        }
    }

    /// Returns all matched paths as a vector of string slices.
    pub fn as_strs(&self) -> Vec<&'a str> {
        self.iter().collect()
    }

    /// Converts to a vector of owned strings.
    pub fn to_strings(&self) -> Vec<String> {
        self.iter().map(|s| s.to_string()).collect()
    }
}

impl Drop for ZlobMatch<'_> {
    fn drop(&mut self) {
        unsafe {
            ffi::zlobfree(&mut self.inner);
        }
    }
}

impl<'a> std::ops::Index<usize> for ZlobMatch<'a> {
    type Output = str;

    /// Returns the matched path at the given index.
    ///
    /// # Panics
    ///
    /// Panics if `index >= self.len()`.
    fn index(&self, index: usize) -> &Self::Output {
        self.get(index).expect("index out of bounds")
    }
}

impl<'a, 'b> IntoIterator for &'b ZlobMatch<'a> {
    type Item = &'a str;
    type IntoIter = ZlobMatchIter<'a, 'b>;

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

// SAFETY: ZlobMatch owns its internal data and can be sent between threads
unsafe impl Send for ZlobMatch<'_> {}
// SAFETY: ZlobMatch's methods only take &self and don't mutate shared state
unsafe impl Sync for ZlobMatch<'_> {}

/// Iterator over `ZlobMatch` results.
pub struct ZlobMatchIter<'a, 'b> {
    inner: &'b ZlobMatch<'a>,
    front: usize,
    back: usize,
}

impl<'a, 'b> Iterator for ZlobMatchIter<'a, 'b> {
    type Item = &'a str;

    fn next(&mut self) -> Option<Self::Item> {
        if self.front >= self.back {
            return None;
        }
        let item = self.inner.get(self.front)?;
        self.front += 1;
        Some(item)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let remaining = self.back - self.front;
        (remaining, Some(remaining))
    }

    fn count(self) -> usize {
        self.back - self.front
    }

    fn nth(&mut self, n: usize) -> Option<Self::Item> {
        if n >= self.back - self.front {
            self.front = self.back;
            return None;
        }
        self.front += n;
        self.next()
    }

    fn last(mut self) -> Option<Self::Item> {
        self.next_back()
    }
}

impl ExactSizeIterator for ZlobMatchIter<'_, '_> {
    fn len(&self) -> usize {
        self.back - self.front
    }
}

impl DoubleEndedIterator for ZlobMatchIter<'_, '_> {
    fn next_back(&mut self) -> Option<Self::Item> {
        if self.front >= self.back {
            return None;
        }
        self.back -= 1;
        self.inner.get(self.back)
    }

    fn nth_back(&mut self, n: usize) -> Option<Self::Item> {
        if n >= self.back - self.front {
            self.front = self.back;
            return None;
        }
        self.back -= n;
        self.next_back()
    }
}

impl std::iter::FusedIterator for ZlobMatchIter<'_, '_> {}

/// Match paths against a glob pattern without filesystem access (zero-copy).
///
/// This function filters a slice of paths using a glob pattern. No filesystem
/// access is performed - it purely does pattern matching on the provided strings.
///
/// **Zero-copy**: The pattern and paths are passed directly to zlob without
/// any allocation or copying, thanks to the identical memory layout of
/// Rust's `&str` and zlob's `zlob_slice_t`.
///
/// # Arguments
///
/// * `pattern` - The glob pattern to match against
/// * `paths` - A slice of paths to filter
/// * `flags` - Flags controlling the matching behavior
///
/// # Returns
///
/// * `Ok(Some(ZlobMatch))` - Contains references to the paths that matched
/// * `Ok(None)` - No paths matched the pattern
/// * `Err(ZlobError)` - An error occurred (out of memory, etc.)
///
/// # Example
///
/// ```
/// use zlob::{zlob_match_paths, ZlobFlags};
///
/// let paths = ["src/lib.rs", "src/main.rs", "README.md", "Cargo.toml"];
/// if let Some(matches) = zlob_match_paths("*.rs", &paths, ZlobFlags::empty())? {
///     assert_eq!(matches.len(), 2);
///     assert_eq!(&matches[0], "src/lib.rs");
///     assert_eq!(&matches[1], "src/main.rs");
/// }
/// # Ok::<(), zlob::ZlobError>(())
/// ```
///
/// # Brace Expansion
///
/// ```
/// use zlob::{zlob_match_paths, ZlobFlags};
///
/// let paths = ["foo.rs", "bar.rs", "baz.txt"];
/// if let Some(matches) = zlob_match_paths("{foo,bar}.*", &paths, ZlobFlags::BRACE)? {
///     assert_eq!(matches.len(), 2);
/// }
/// # Ok::<(), zlob::ZlobError>(())
/// ```
pub fn zlob_match_paths<'a>(
    pattern: &str,
    paths: &'a [&str],
    flags: ZlobFlags,
) -> Result<Option<ZlobMatch<'a>>, ZlobError> {
    // SAFETY: zlob_slice_t and &str have identical memory layout:
    // - Both are (ptr: *const u8, len: usize) pairs
    // - Both have the same size and alignment (verified by static assert in ffi.rs)
    // This transmute is zero-cost - no allocation, no copying.
    let pattern_slice: &ffi::zlob_slice_t = unsafe { std::mem::transmute(&pattern) };

    // SAFETY: &[&str] and &[zlob_slice_t] have identical memory layout.
    // Each &str is (ptr, len), each zlob_slice_t is { ptr, len }.
    let path_slices: &[ffi::zlob_slice_t] = unsafe { std::mem::transmute(paths) };

    let mut inner = ffi::zlob_t::default();

    let result = unsafe {
        ffi::zlob_match_paths_slice(
            pattern_slice,
            path_slices.as_ptr(),
            path_slices.len(),
            flags.bits(),
            &mut inner,
        )
    };

    match ZlobError::from_code(result) {
        Ok(true) => Ok(Some(ZlobMatch {
            inner,
            _marker: PhantomData,
        })),
        Ok(false) => Ok(None), // No matches
        Err(err) => Err(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_match_paths_basic() {
        let paths = ["foo.rs", "bar.txt", "baz.rs"];
        let matches = zlob_match_paths("*.rs", &paths, ZlobFlags::empty())
            .unwrap()
            .unwrap();

        assert_eq!(matches.len(), 2);
        let results: Vec<&str> = matches.iter().collect();
        assert!(results.contains(&"foo.rs"));
        assert!(results.contains(&"baz.rs"));
    }

    #[test]
    fn test_match_paths_no_match() {
        let paths = ["foo.rs", "bar.rs"];
        let result = zlob_match_paths("*.txt", &paths, ZlobFlags::empty()).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_match_paths_brace() {
        let paths = ["foo.rs", "bar.rs", "baz.rs"];
        let matches = zlob_match_paths("{foo,bar}.rs", &paths, ZlobFlags::BRACE)
            .unwrap()
            .unwrap();

        assert_eq!(matches.len(), 2);
        let results: Vec<&str> = matches.iter().collect();
        assert!(results.contains(&"foo.rs"));
        assert!(results.contains(&"bar.rs"));
    }

    #[test]
    fn test_match_paths_index() {
        let paths = ["a.rs", "b.rs", "c.rs"];
        let matches = zlob_match_paths("*.rs", &paths, ZlobFlags::empty())
            .unwrap()
            .unwrap();

        assert_eq!(matches.len(), 3);
        // Results should be in order
        assert!(&matches[0].ends_with(".rs"));
    }

    #[test]
    fn test_match_paths_iterator() {
        let paths = ["x.rs", "y.rs", "z.txt"];
        let matches = zlob_match_paths("*.rs", &paths, ZlobFlags::empty())
            .unwrap()
            .unwrap();

        let mut iter = matches.iter();
        assert_eq!(iter.len(), 2);
        assert!(iter.next().is_some());
        assert_eq!(iter.len(), 1);
        assert!(iter.next().is_some());
        assert_eq!(iter.len(), 0);
        assert!(iter.next().is_none());
    }

    #[test]
    fn test_match_paths_double_ended() {
        let paths = ["1.rs", "2.rs", "3.rs"];
        let matches = zlob_match_paths("*.rs", &paths, ZlobFlags::empty())
            .unwrap()
            .unwrap();

        let mut iter = matches.iter();
        let first = iter.next().unwrap();
        let last = iter.next_back().unwrap();
        assert_ne!(first, last);
    }

    #[test]
    fn test_match_paths_empty_input() {
        let paths: [&str; 0] = [];
        let result = zlob_match_paths("*.rs", &paths, ZlobFlags::empty()).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_match_paths_wildcard() {
        let paths = ["src/lib.rs", "src/main.rs", "test/test.rs"];
        let matches = zlob_match_paths("src/*.rs", &paths, ZlobFlags::empty())
            .unwrap()
            .unwrap();

        assert_eq!(matches.len(), 2);
    }

    #[test]
    fn test_match_paths_question_mark() {
        let paths = ["a1.rs", "a2.rs", "ab.rs", "abc.rs"];
        let matches = zlob_match_paths("a?.rs", &paths, ZlobFlags::empty())
            .unwrap()
            .unwrap();

        assert_eq!(matches.len(), 3); // a1.rs, a2.rs, ab.rs
    }

    #[test]
    fn test_match_paths_character_class() {
        let paths = ["a.rs", "b.rs", "c.rs", "d.rs"];
        let matches = zlob_match_paths("[ab].rs", &paths, ZlobFlags::empty())
            .unwrap()
            .unwrap();

        assert_eq!(matches.len(), 2);
        let results: Vec<&str> = matches.iter().collect();
        assert!(results.contains(&"a.rs"));
        assert!(results.contains(&"b.rs"));
    }

    #[test]
    fn test_match_paths_preserves_lifetime() {
        let paths = vec!["foo.rs".to_string(), "bar.txt".to_string()];
        let path_refs: Vec<&str> = paths.iter().map(|s| s.as_str()).collect();

        let matches = zlob_match_paths("*.rs", &path_refs, ZlobFlags::empty())
            .unwrap()
            .unwrap();

        // The matched paths should reference the original strings
        assert_eq!(matches.len(), 1);
        assert_eq!(&matches[0], "foo.rs");
    }
}
