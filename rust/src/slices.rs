//! Adapter for accepting different string-slice types in batch APIs.
//!
//! `AsZlobPaths` is a sealed trait implemented for slice-like inputs of string
//! types. The `&[&str]` impl is zero-copy: it transmutes the whole slice into
//! `&[zlob_slice_t]` because both have the same `(ptr, len)` layout. Other
//! impls (`&[String]`, `&[&String]`, `&[Cow<str>]`, `&[Box<str>]`) build a
//! `Vec<zlob_slice_t>` once per call.

use crate::ffi;
use std::borrow::Cow;

mod sealed {
    pub trait Sealed {}
}

/// Custom Into<_> like trait that allows to reduce allocations if supplying the &[&str]
pub trait AsZlobPaths: sealed::Sealed {
    #[doc(hidden)]
    fn as_zlob_slices(&self) -> Cow<'_, [ffi::zlob_slice_t]>;
}

#[inline]
fn slice_from_str(s: &str) -> ffi::zlob_slice_t {
    ffi::zlob_slice_t {
        ptr: s.as_ptr(),
        len: s.len(),
    }
}

impl sealed::Sealed for [&str] {}
impl AsZlobPaths for [&str] {
    #[inline]
    fn as_zlob_slices(&self) -> Cow<'_, [ffi::zlob_slice_t]> {
        // SAFETY: `&str` and `zlob_slice_t` share the same layout
        // `(ptr: *const u8, len: usize)`. Slice references over them are
        // therefore identical: same length, same element size, same alignment.
        Cow::Borrowed(unsafe { std::mem::transmute::<&[&str], &[ffi::zlob_slice_t]>(self) })
    }
}

impl sealed::Sealed for [String] {}
impl AsZlobPaths for [String] {
    #[inline]
    fn as_zlob_slices(&self) -> Cow<'_, [ffi::zlob_slice_t]> {
        Cow::Owned(self.iter().map(|s| slice_from_str(s.as_str())).collect())
    }
}

impl sealed::Sealed for [&String] {}
impl AsZlobPaths for [&String] {
    #[inline]
    fn as_zlob_slices(&self) -> Cow<'_, [ffi::zlob_slice_t]> {
        Cow::Owned(self.iter().map(|s| slice_from_str(s.as_str())).collect())
    }
}

impl sealed::Sealed for [Box<str>] {}
impl AsZlobPaths for [Box<str>] {
    #[inline]
    fn as_zlob_slices(&self) -> Cow<'_, [ffi::zlob_slice_t]> {
        Cow::Owned(self.iter().map(|s| slice_from_str(s)).collect())
    }
}

impl<'b> sealed::Sealed for [Cow<'b, str>] {}
impl<'b> AsZlobPaths for [Cow<'b, str>] {
    #[inline]
    fn as_zlob_slices(&self) -> Cow<'_, [ffi::zlob_slice_t]> {
        Cow::Owned(self.iter().map(|s| slice_from_str(s.as_ref())).collect())
    }
}

// Blanket impl: any `[T; N]` whose `[T]` slice has the trait inherits it.
// Lets callers pass `&["a", "b", "c"]` directly.
impl<T, const N: usize> sealed::Sealed for [T; N] where [T]: sealed::Sealed {}
impl<T, const N: usize> AsZlobPaths for [T; N]
where
    [T]: AsZlobPaths,
{
    #[inline]
    fn as_zlob_slices(&self) -> Cow<'_, [ffi::zlob_slice_t]> {
        <[T] as AsZlobPaths>::as_zlob_slices(self.as_slice())
    }
}

// Blanket impl: `Vec<T>` inherits whatever `[T]` provides.
impl<T> sealed::Sealed for Vec<T> where [T]: sealed::Sealed {}
impl<T> AsZlobPaths for Vec<T>
where
    [T]: AsZlobPaths,
{
    #[inline]
    fn as_zlob_slices(&self) -> Cow<'_, [ffi::zlob_slice_t]> {
        <[T] as AsZlobPaths>::as_zlob_slices(self.as_slice())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn str_slice_is_borrowed_zero_copy() {
        let v: Vec<&str> = vec!["a", "bb", "ccc"];
        let slices = v.as_slice().as_zlob_slices();
        assert!(matches!(slices, Cow::Borrowed(_)));
        assert_eq!(slices.len(), 3);
        assert_eq!(slices[0].len, 1);
        assert_eq!(slices[1].len, 2);
        assert_eq!(slices[2].len, 3);
    }

    #[test]
    fn string_slice_is_owned_alloc() {
        let v: Vec<String> = vec!["x".into(), "yy".into()];
        let slices = v.as_slice().as_zlob_slices();
        assert!(matches!(slices, Cow::Owned(_)));
        assert_eq!(slices.len(), 2);
        assert_eq!(slices[0].len, 1);
        assert_eq!(slices[1].len, 2);
    }

    #[test]
    fn box_str_slice_works() {
        let v: Vec<Box<str>> = vec!["foo".into(), "bar".into()];
        let slices = v.as_slice().as_zlob_slices();
        assert_eq!(slices.len(), 2);
        assert_eq!(slices[0].len, 3);
    }

    #[test]
    fn cow_slice_works() {
        let v: Vec<Cow<'_, str>> = vec![Cow::Borrowed("ab"), Cow::Owned("cdef".into())];
        let slices = v.as_slice().as_zlob_slices();
        assert_eq!(slices.len(), 2);
        assert_eq!(slices[0].len, 2);
        assert_eq!(slices[1].len, 4);
    }
}
