use crate::error::ZlobError;
use crate::ffi;
use crate::flags::ZlobFlags;
use std::ffi::CString;
use std::ops::Index;
use std::slice;

/// Result of a `zlob()` call.
///
/// This type automatically frees the allocated memory when dropped.
/// It provides zero-copy access to matched paths via the `gl_pathlen` array.
///
/// # Example
///
/// ```no_run
/// use zlob::{zlob, ZlobFlags};
///
/// if let Some(result) = zlob("**/*.rs", ZlobFlags::empty())? {
///     // Iterate over paths
///     for path in &result {
///         println!("{}", path);
///     }
///
///     // Index access
///     if !result.is_empty() {
///         println!("First: {}", &result[0]);
///     }
///
///     // Convert to Vec
///     let paths: Vec<String> = result.to_strings();
/// }
/// # Ok::<(), zlob::ZlobError>(())
/// ```
pub struct Zlob {
    inner: ffi::zlob_t,
}

impl Zlob {
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

    /// Returns the path at the given index, or `None` if out of bounds.
    ///
    /// This is a zero-copy operation that uses `gl_pathlen` to create
    /// a string slice without calling `strlen()`.
    #[inline]
    pub fn get(&self, index: usize) -> Option<&str> {
        if index >= self.len() {
            return None;
        }
        unsafe {
            let ptr = *self.inner.gl_pathv.add(index) as *const u8;
            let len = *self.inner.gl_pathlen.add(index);
            let bytes = slice::from_raw_parts(ptr, len);
            // SAFETY: zlob guarantees UTF-8 valid paths (they come from the filesystem)
            Some(std::str::from_utf8_unchecked(bytes))
        }
    }

    /// Returns an iterator over the matched paths.
    #[inline]
    pub fn iter(&self) -> ZlobIter<'_> {
        ZlobIter {
            zlob: self,
            front: 0,
            back: self.len(),
        }
    }

    /// Returns all paths as a vector of string slices.
    ///
    /// This is a zero-copy operation - the strings reference the internal buffer.
    pub fn as_strs(&self) -> Vec<&str> {
        self.iter().collect()
    }

    /// Converts to a vector of owned strings.
    ///
    /// This copies all path data into new `String` allocations.
    pub fn to_strings(&self) -> Vec<String> {
        self.iter().map(|s| s.to_string()).collect()
    }

    /// Returns raw pointers to path data for advanced zero-copy access.
    ///
    /// # Safety
    ///
    /// The returned slices are valid only while this `Zlob` instance exists.
    /// Do not use them after the `Zlob` is dropped.
    ///
    /// # Returns
    ///
    /// A tuple of `(pathv, pathlen)` where:
    /// - `pathv[i]` is a pointer to the i-th path (null-terminated)
    /// - `pathlen[i]` is the length of the i-th path (excluding null terminator)
    pub unsafe fn raw_parts(&self) -> (&[*mut i8], &[usize]) {
        let pathv = slice::from_raw_parts(self.inner.gl_pathv, self.len());
        let pathlen = slice::from_raw_parts(self.inner.gl_pathlen, self.len());
        (pathv, pathlen)
    }
}

impl Drop for Zlob {
    fn drop(&mut self) {
        unsafe {
            ffi::zlobfree(&mut self.inner);
        }
    }
}

impl Index<usize> for Zlob {
    type Output = str;

    /// Returns the path at the given index.
    ///
    /// # Panics
    ///
    /// Panics if `index >= self.len()`.
    fn index(&self, index: usize) -> &Self::Output {
        self.get(index).expect("index out of bounds")
    }
}

impl<'a> IntoIterator for &'a Zlob {
    type Item = &'a str;
    type IntoIter = ZlobIter<'a>;

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

// SAFETY: Zlob owns its data and can be sent between threads
unsafe impl Send for Zlob {}
// SAFETY: Zlob's methods only take &self and don't mutate shared state
unsafe impl Sync for Zlob {}

/// Iterator over `Zlob` results.
///
/// This iterator yields `&str` references to each matched path.
/// It implements `ExactSizeIterator` and `DoubleEndedIterator`.
pub struct ZlobIter<'a> {
    zlob: &'a Zlob,
    front: usize,
    back: usize,
}

impl<'a> Iterator for ZlobIter<'a> {
    type Item = &'a str;

    fn next(&mut self) -> Option<Self::Item> {
        if self.front >= self.back {
            return None;
        }
        let item = self.zlob.get(self.front)?;
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

impl ExactSizeIterator for ZlobIter<'_> {
    fn len(&self) -> usize {
        self.back - self.front
    }
}

impl DoubleEndedIterator for ZlobIter<'_> {
    fn next_back(&mut self) -> Option<Self::Item> {
        if self.front >= self.back {
            return None;
        }
        self.back -= 1;
        self.zlob.get(self.back)
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

impl std::iter::FusedIterator for ZlobIter<'_> {}

/// Perform glob pattern matching on the filesystem.
///
/// This function finds all files matching the given glob pattern.
///
/// # Arguments
///
/// * `pattern` - The glob pattern to match (e.g., `"**/*.rs"`, `"src/{lib,main}.rs"`)
/// * `flags` - Flags controlling the matching behavior
///
/// # Returns
///
/// * `Ok(Some(Zlob))` - Matches were found
/// * `Ok(None)` - No matches found (pattern is valid but no files match)
/// * `Err(ZlobError)` - An error occurred (out of memory, read error, etc.)
///
/// # Example
///
/// ```no_run
/// use zlob::{zlob, ZlobFlags};
///
/// // Find all Rust files recursively
/// if let Some(result) = zlob("**/*.rs", ZlobFlags::empty())? {
///     for path in &result {
///         println!("{}", path);
///     }
/// } else {
///     println!("No matches found");
/// }
///
/// // Use brace expansion
/// let result = zlob("src/{lib,main}.rs", ZlobFlags::BRACE)?;
///
/// // Filter with .gitignore
/// let result = zlob("**/*", ZlobFlags::GITIGNORE)?;
/// # Ok::<(), zlob::ZlobError>(())
/// ```
///
/// # Supported Patterns
///
/// | Pattern | Description |
/// |---------|-------------|
/// | `*` | Matches any string (including empty) |
/// | `?` | Matches any single character |
/// | `[abc]` | Matches one character from the set |
/// | `[!abc]` | Matches one character NOT in the set |
/// | `[a-z]` | Matches one character in the range |
/// | `**` | Matches zero or more path components (recursive) |
/// | `{a,b}` | Matches alternatives (requires `BRACE` flag) |
/// | `~` | Home directory (requires `TILDE` flag) |
pub fn zlob(pattern: &str, flags: ZlobFlags) -> Result<Option<Zlob>, ZlobError> {
    let pattern_c = CString::new(pattern).map_err(|_| ZlobError::Aborted)?;
    let mut inner = ffi::zlob_t::default();

    let result = unsafe { ffi::zlob(pattern_c.as_ptr(), flags.bits(), None, &mut inner) };

    match ZlobError::from_code(result) {
        Ok(true) => Ok(Some(Zlob { inner })),
        Ok(false) => Ok(None), // No matches
        Err(err) => Err(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_zlob_basic() {
        // this relies on the cwd being rust/ folder itself
        let result = zlob("Cargo.toml", ZlobFlags::empty());
        assert!(result.is_ok());
        let result = result.unwrap();
        assert!(result.is_some());
        let result = result.unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(&result[0], "Cargo.toml");
    }

    #[test]
    fn test_zlob_no_match() {
        let result = zlob("nonexistent_file_12345.xyz", ZlobFlags::empty());
        assert!(result.is_ok());
        assert!(result.unwrap().is_none());
    }

    #[test]
    fn test_zlob_iterator() {
        let result = zlob("*.toml", ZlobFlags::empty()).unwrap().unwrap();
        let paths: Vec<&str> = result.iter().collect();
        assert!(paths.contains(&"Cargo.toml"));
    }

    #[test]
    fn test_zlob_double_ended_iterator() {
        let result = zlob("*.toml", ZlobFlags::empty()).unwrap().unwrap();
        if result.len() > 0 {
            let mut iter = result.iter();
            let first = iter.next();
            let last = iter.next_back();
            assert!(first.is_some());
            // last might be None if there's only one element
            if result.len() > 1 {
                assert!(last.is_some());
                assert_ne!(first, last);
            }
        }
    }

    #[test]
    fn test_zlob_exact_size_iterator() {
        let result = zlob("*.toml", ZlobFlags::empty()).unwrap().unwrap();
        let iter = result.iter();
        assert_eq!(iter.len(), result.len());
    }

    #[test]
    fn test_zlob_brace_expansion() {
        // both individual and brace combination work correctly
        let result = zlob("*.toml", ZlobFlags::empty()).unwrap().unwrap();
        assert!(result.len() >= 1);

        let result = zlob("*.lock", ZlobFlags::empty()).unwrap().unwrap();
        assert!(result.len() >= 1);

        let result = zlob("*.{toml,lock}", ZlobFlags::empty()).unwrap();
        assert!(result.is_none());

        let result = zlob("*.{toml,lock}", ZlobFlags::BRACE).unwrap().unwrap();
        assert!(matches!(result.len(), 2));
    }

    #[test]
    fn test_recursive_globbing() {
        // based on the rust/ folder contents
        let result = zlob("**/*.{rs,toml}", ZlobFlags::BRACE).unwrap().unwrap();

        for path in &result {
            println!("{}", path);
        }

        assert_eq!(result.len(), 8);
    }
}
