//! Error types for zlob operations.
//!
//! The native library (Zig) has a single error set `ZlobError`
//! (`OutOfMemory`, `Aborted`, `ReadFailed`, `PermissionDenied`,
//! `NameTooLong`). At the C boundary each maps to a distinct return code —
//! `ZLOB_NOSPACE`, `ZLOB_ABORTED`, `ZLOB_READ_FAILED`,
//! `ZLOB_PERMISSION_DENIED`, `ZLOB_NAME_TOO_LONG` (plus `ZLOB_NOMATCH` for "no
//! matches") — which this module maps back to the Rust enum below.

use crate::ffi;
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ZlobError {
    /// Out of memory (`ZLOB_NOSPACE`).
    NoSpace,

    /// Operation aborted by a visitor or the error callback (`ZLOB_ABORTED`).
    Aborted,

    /// A directory listing could not be read (`ZLOB_READ_FAILED`). Only
    /// surfaces from the walker when `abort_on_error` is set.
    ReadFailed,

    /// A directory could not be opened or read due to permissions
    /// (`ZLOB_PERMISSION_DENIED`). Only surfaces from the walker when
    /// `abort_on_error` is set.
    PermissionDenied,

    /// A path component exceeded the platform `NAME_MAX`
    /// (`ZLOB_NAME_TOO_LONG`). Only surfaces from the walker when
    /// `abort_on_error` is set.
    NameTooLong,

    /// An argument could not be passed to the native library, e.g. a path or
    /// pattern containing an interior NUL byte. Originates in this crate, not
    /// from a native return code.
    InvalidInput,
}

impl fmt::Display for ZlobError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ZlobError::NoSpace => write!(f, "out of memory"),
            ZlobError::Aborted => write!(f, "operation aborted"),
            ZlobError::ReadFailed => write!(f, "directory read failed"),
            ZlobError::PermissionDenied => write!(f, "permission denied"),
            ZlobError::NameTooLong => write!(f, "path component too long"),
            ZlobError::InvalidInput => {
                write!(f, "argument contains an interior NUL byte")
            }
        }
    }
}

impl std::error::Error for ZlobError {}

impl ZlobError {
    /// Maps a native return code to a result. `Ok(true)` = success with
    /// matches, `Ok(false)` = `ZLOB_NOMATCH`, `Err(..)` = a failure code.
    pub(crate) fn from_code(code: i32) -> Result<bool, Self> {
        match code {
            0 => Ok(true),
            ffi::ZLOB_NOMATCH => Ok(false),
            ffi::ZLOB_NOSPACE => Err(ZlobError::NoSpace),
            ffi::ZLOB_ABORTED => Err(ZlobError::Aborted),
            ffi::ZLOB_READ_FAILED => Err(ZlobError::ReadFailed),
            ffi::ZLOB_PERMISSION_DENIED => Err(ZlobError::PermissionDenied),
            ffi::ZLOB_NAME_TOO_LONG => Err(ZlobError::NameTooLong),
            // Any unexpected non-zero code: treat as aborted.
            _ => Err(ZlobError::Aborted),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_code_maps_every_native_code() {
        assert_eq!(ZlobError::from_code(0), Ok(true));
        assert_eq!(ZlobError::from_code(ffi::ZLOB_NOMATCH), Ok(false));
        assert_eq!(
            ZlobError::from_code(ffi::ZLOB_NOSPACE),
            Err(ZlobError::NoSpace)
        );
        assert_eq!(
            ZlobError::from_code(ffi::ZLOB_ABORTED),
            Err(ZlobError::Aborted)
        );
        assert_eq!(
            ZlobError::from_code(ffi::ZLOB_READ_FAILED),
            Err(ZlobError::ReadFailed)
        );
        assert_eq!(
            ZlobError::from_code(ffi::ZLOB_PERMISSION_DENIED),
            Err(ZlobError::PermissionDenied)
        );
        assert_eq!(
            ZlobError::from_code(ffi::ZLOB_NAME_TOO_LONG),
            Err(ZlobError::NameTooLong)
        );
        // Unknown codes collapse to Aborted.
        assert_eq!(ZlobError::from_code(9999), Err(ZlobError::Aborted));
    }
}
