//! Owned wrapper for `zlob_indices_t` returned by the C ABI.
//!
//! Holds the raw pointer + count from zlob and exposes `as_slice` / `to_iter`
//! without copying. The C-side buffer is freed on drop.

use crate::error::ZlobError;
use crate::ffi;
use std::slice;

/// Zero-copy indicies storage owned by zlob, freed automatically on drop.
pub struct ZlobIndicies {
    inner: ffi::zlob_indices_t,
}

impl std::fmt::Debug for ZlobIndicies {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ZlobIndicies")
            .field("len", &self.len())
            .field("indices", &self.as_slice())
            .finish()
    }
}

impl Drop for ZlobIndicies {
    fn drop(&mut self) {
        // SAFETY: `inner` came from a zlob entry point and is freed exactly
        // once here. `zlob_indices_free` is a no-op on a zeroed struct, so
        // the no-match / error-after-zeroed paths are also fine.
        unsafe { ffi::zlob_indices_free(&mut self.inner) };
    }
}

impl ZlobIndicies {
    pub(crate) fn from_ffi(code: i32, out: ffi::zlob_indices_t) -> Result<Self, ZlobError> {
        let me = ZlobIndicies { inner: out };
        match ZlobError::from_code(code) {
            Ok(_) => Ok(me),
            Err(err) => Err(err),
        }
    }

    /// Number of matched indices.
    #[inline]
    pub fn len(&self) -> usize {
        self.inner.count
    }

    /// `true` if no indices matched.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.inner.count == 0
    }

    /// Borrow the indices as a slice, no copy.
    #[inline]
    pub fn as_slice(&self) -> &[usize] {
        if self.inner.count == 0 || self.inner.indices.is_null() {
            &[]
        } else {
            // SAFETY: zlob guarantees `indices` points to `count` valid usizes
            // when count > 0, and the buffer lives until `zlob_indices_free`
            unsafe { slice::from_raw_parts(self.inner.indices, self.inner.count) }
        }
    }

    /// Iterate the indices by value. Equivalent to `self.as_slice().iter().copied()`.
    #[inline]
    pub fn to_iter(&self) -> std::iter::Copied<slice::Iter<'_, usize>> {
        self.as_slice().iter().copied()
    }
}

// SAFETY: ZlobIndicies owns its buffer and exposes only &self accessors.
unsafe impl Send for ZlobIndicies {}
// SAFETY: All accessors take &self; the buffer is read-only after construction.
unsafe impl Sync for ZlobIndicies {}
