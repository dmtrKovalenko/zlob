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

impl std::fmt::Debug for ZlobMatch<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ZlobMatch")
            .field("len", &self.len())
            .field("paths", &self.as_strs())
            .finish()
    }
}

impl<'a> ZlobMatch<'a> {
    /// Returns the number of matched paths.
    #[inline]
    pub fn len(&self) -> usize {
        self.inner.zlo_pathc
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
            let ptr = *self.inner.zlo_pathv.add(index) as *const u8;
            let len = *self.inner.zlo_pathlen.add(index);
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
/// ## Returns
///
/// * `Ok(Some(ZlobMatch))` - Contains references to the paths that matched
/// * `Ok(None)` - No paths matched the pattern
/// * `Err(ZlobError)` - An error occurred (out of memory, etc.)
///
/// ## Example
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

/// Match paths against a glob pattern relative to a base directory, without filesystem access (zero-copy).
///
/// This is the "at" variant of [`zlob_match_paths`] for use when input paths are absolute
/// but the pattern is relative to a known base directory. The `base_path` may or may not
/// end with a trailing `/` — the offset is computed automatically.
///
/// If the pattern starts with `./`, it is interpreted as relative to `base_path`
/// (the prefix is stripped).
///
/// **Zero-copy**: Same as `zlob_match_paths` — no allocation or copying of path strings.
///
/// ## Arguments
///
/// * `base_path` - The base directory that the paths are rooted under
/// * `pattern` - The glob pattern to match against (relative to `base_path`)
/// * `paths` - A slice of absolute paths to filter
/// * `flags` - Flags controlling the matching behavior
///
/// ## Returns
///
/// * `Ok(Some(ZlobMatch))` - Contains references to the paths that matched
/// * `Ok(None)` - No paths matched the pattern
/// * `Err(ZlobError)` - An error occurred (out of memory, etc.)
///
/// ## Example
///
/// ```
/// use zlob::{zlob_match_paths_at, ZlobFlags};
///
/// let paths = [
///     "/home/user/project/src/lib.rs",
///     "/home/user/project/src/main.rs",
///     "/home/user/project/README.md",
/// ];
///
/// if let Some(matches) = zlob_match_paths_at("/home/user/project", "**/*.rs", &paths, ZlobFlags::empty())? {
///     assert_eq!(matches.len(), 2);
///     // Results contain the original full paths
///     assert_eq!(&matches[0], "/home/user/project/src/lib.rs");
/// }
/// # Ok::<(), zlob::ZlobError>(())
/// ```
pub fn zlob_match_paths_at<'a>(
    base_path: &str,
    pattern: &str,
    paths: &'a [&str],
    flags: ZlobFlags,
) -> Result<Option<ZlobMatch<'a>>, ZlobError> {
    // SAFETY: zlob_slice_t and &str have identical memory layout.
    let base_slice: &ffi::zlob_slice_t = unsafe { std::mem::transmute(&base_path) };
    let pattern_slice: &ffi::zlob_slice_t = unsafe { std::mem::transmute(&pattern) };
    let path_slices: &[ffi::zlob_slice_t] = unsafe { std::mem::transmute(paths) };

    let mut inner = ffi::zlob_t::default();

    let result = unsafe {
        ffi::zlob_match_paths_at_slice(
            base_slice,
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
        Ok(false) => Ok(None),
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

    #[test]
    fn test_match_paths_extglob_negation() {
        // Test !(pattern) - matches anything except the pattern
        let paths = ["app.js", "app.ts", "app.css", "app.html"];
        let matches = zlob_match_paths("app.!(js|ts)", &paths, ZlobFlags::EXTGLOB)
            .unwrap()
            .unwrap();

        assert_eq!(matches.len(), 2);
        let results: Vec<&str> = matches.iter().collect();
        assert!(results.contains(&"app.css"));
        assert!(results.contains(&"app.html"));
        // Should NOT contain js or ts
        assert!(!results.contains(&"app.js"));
        assert!(!results.contains(&"app.ts"));
    }

    #[test]
    fn test_match_paths_extglob_exactly_one() {
        // Test @(pattern) - matches exactly one of the alternatives
        let paths = ["foo.txt", "bar.txt", "baz.txt", "qux.txt"];
        let matches = zlob_match_paths("@(foo|bar).txt", &paths, ZlobFlags::EXTGLOB)
            .unwrap()
            .unwrap();

        assert_eq!(matches.len(), 2);
        let results: Vec<&str> = matches.iter().collect();
        assert!(results.contains(&"foo.txt"));
        assert!(results.contains(&"bar.txt"));
        assert!(!results.contains(&"baz.txt"));
    }

    #[test]
    fn test_match_paths_at_200_random_rs_paths() {
        let base_path = "/workspace/my-project";

        let dirs = [
            "src",
            "src/core",
            "src/utils",
            "src/models",
            "src/handlers",
            "src/services",
            "src/middleware",
            "src/config",
            "src/db",
            "src/api",
            "tests",
            "tests/integration",
            "tests/unit",
            "benches",
            "examples",
            "lib",
            "lib/helpers",
            "lib/macros",
            "tools",
            "tools/codegen",
        ];

        let rs_names = [
            "main",
            "lib",
            "mod",
            "config",
            "utils",
            "helpers",
            "errors",
            "types",
            "schema",
            "handler",
            "service",
            "middleware",
            "router",
            "client",
            "server",
            "auth",
            "db",
            "cache",
            "logger",
            "parser",
        ];
        let non_rs_names = [
            "README.md",
            "Cargo.toml",
            "Cargo.lock",
            ".gitignore",
            "LICENSE",
            "config.toml",
            "setup.py",
            "index.js",
            "style.css",
            "data.json",
        ];

        let mut all_paths_owned: Vec<String> = Vec::with_capacity(200);

        // Generate 160 .rs files across various directories
        let mut count = 0;
        for (i, dir) in dirs.iter().enumerate() {
            for (j, name) in rs_names.iter().enumerate() {
                if count >= 160 {
                    break;
                }
                // Add some variety with numbered suffixes
                let suffix = if (i + j) % 3 == 0 {
                    format!("_{}", (i * 7 + j) % 100)
                } else {
                    String::new()
                };
                all_paths_owned.push(format!("{}/{}/{}{}.rs", base_path, dir, name, suffix));
                count += 1;
            }
            if count >= 160 {
                break;
            }
        }

        // Fill remaining slots with non-.rs files to reach 200
        while all_paths_owned.len() < 200 {
            let idx = all_paths_owned.len() - 160;
            let dir = dirs[idx % dirs.len()];
            let name = non_rs_names[idx % non_rs_names.len()];
            all_paths_owned.push(format!("{}/{}/{}", base_path, dir, name));
        }

        assert_eq!(all_paths_owned.len(), 200);

        let all_paths: Vec<&str> = all_paths_owned.iter().map(|s| s.as_str()).collect();
        let expected_rs_count = all_paths.iter().filter(|p| p.ends_with(".rs")).count();
        assert!(expected_rs_count == 160,);

        let matches = zlob_match_paths_at(base_path, "**/*.rs", &all_paths, ZlobFlags::empty())
            .unwrap()
            .unwrap();

        assert_eq!(
            matches.len(),
            expected_rs_count,
            "Expected {} .rs matches, got {}",
            expected_rs_count,
            matches.len()
        );

        // Verify every matched path ends with .rs and starts with base_path
        for path in &matches {
            assert!(
                path.ends_with(".rs"),
                "Matched path should end with .rs: {}",
                path
            );
            assert!(
                path.starts_with(base_path),
                "Matched path should start with base_path: {}",
                path
            );
        }

        let non_rs_in_results = matches.iter().filter(|p| !p.ends_with(".rs")).count();
        assert_eq!(non_rs_in_results, 0, "Should not match non-.rs files");

        let matches_dot =
            zlob_match_paths_at(base_path, "./**/*.rs", &all_paths, ZlobFlags::empty())
                .unwrap()
                .unwrap();

        assert_eq!(
            matches.len(),
            matches_dot.len(),
            "./ prefix should give same results"
        );

        let no_match = zlob_match_paths_at(
            base_path,
            "nonexistent_dir/*.rs",
            &all_paths,
            ZlobFlags::empty(),
        )
        .unwrap();
        assert!(
            no_match.is_none(),
            "Non-existent dir pattern should return no matches"
        );

        let first_rs = all_paths.iter().find(|p| p.ends_with(".rs")).unwrap();
        let rel_first = &first_rs[base_path.len() + 1..];
        let literal_match =
            zlob_match_paths_at(base_path, rel_first, &all_paths, ZlobFlags::empty())
                .unwrap()
                .unwrap();
        assert_eq!(
            literal_match.len(),
            1,
            "Literal pattern should match exactly one path"
        );
        assert_eq!(&literal_match[0], *first_rs);
    }
}
