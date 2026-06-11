//! Error types for zlob operations.

use crate::ffi;
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ZlobError {
    /// Out of memory (ZLOB_NOSPACE).
    NoSpace,

    /// Read error or operation aborted (ZLOB_ABORTED).
    Aborted,

    /// An argument could not be passed to the native library, e.g. a path or
    /// pattern containing an interior NUL byte.
    InvalidInput,
}

impl fmt::Display for ZlobError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ZlobError::NoSpace => write!(f, "out of memory"),
            ZlobError::Aborted => write!(f, "operation aborted or read error"),
            ZlobError::InvalidInput => {
                write!(f, "argument contains an interior NUL byte")
            }
        }
    }
}

impl std::error::Error for ZlobError {}

impl ZlobError {
    pub(crate) fn from_code(code: i32) -> Result<bool, Self> {
        match code {
            0 => Ok(true),
            ffi::ZLOB_NOMATCH => Ok(false),
            ffi::ZLOB_NOSPACE => Err(ZlobError::NoSpace),
            ffi::ZLOB_ABORTED => Err(ZlobError::Aborted),
            _ => Err(ZlobError::Aborted),
        }
    }
}
