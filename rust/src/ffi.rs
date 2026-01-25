//! Raw FFI bindings to the zlob C library.
//!
//! These are low-level bindings and should not be used directly.
//! Use the safe wrappers in the parent module instead.

use std::ffi::{c_char, c_int, c_void};

/// Result structure for zlob operations.
///
/// This matches the C `zlob_t` structure exactly.
#[repr(C)]
#[allow(non_camel_case_types)]
pub struct zlob_t {
    /// Count of matched paths
    pub gl_pathc: usize,
    /// Array of matched path strings (NULL-terminated)
    pub gl_pathv: *mut *mut c_char,
    /// Number of NULL entries to reserve at beginning of gl_pathv
    pub gl_offs: usize,
    /// Array of path lengths (parallel to gl_pathv, for efficient FFI)
    pub gl_pathlen: *mut usize,
    /// Internal flags
    pub gl_flags: c_int,
    /// Custom opendir function (GNU extension, used with ALTDIRFUNC)
    pub gl_opendir: Option<unsafe extern "C" fn(*const c_char) -> *mut c_void>,
    /// Custom readdir function (GNU extension, used with ALTDIRFUNC)
    pub gl_readdir: Option<unsafe extern "C" fn(*mut c_void) -> *mut zlob_dirent_t>,
    /// Custom closedir function (GNU extension, used with ALTDIRFUNC)
    pub gl_closedir: Option<unsafe extern "C" fn(*mut c_void)>,
}

/// Directory entry for ALTDIRFUNC callbacks.
#[repr(C)]
#[allow(non_camel_case_types)]
pub struct zlob_dirent_t {
    /// Null-terminated entry name
    pub d_name: *const c_char,
    /// Entry type: DT_DIR=4, DT_REG=8, DT_LNK=10, DT_UNKNOWN=0
    pub d_type: u8,
}

/// FFI-compatible slice type - matches Rust's `&str` layout exactly.
///
/// This allows zero-copy conversion between Rust string slices and zlob slices.
#[repr(C)]
#[allow(non_camel_case_types)]
pub struct zlob_slice_t {
    pub ptr: *const u8,
    pub len: usize,
}

// Compile-time assertion that zlob_slice_t matches &str layout
const _: () = {
    assert!(std::mem::size_of::<zlob_slice_t>() == std::mem::size_of::<&str>());
    assert!(std::mem::align_of::<zlob_slice_t>() == std::mem::align_of::<&str>());
};

/// Error callback type for zlob operations.
///
/// Called when a directory read error occurs.
/// Returns non-zero to abort, zero to continue.
#[allow(non_camel_case_types)]
pub type zlob_errfunc_t = unsafe extern "C" fn(*const c_char, c_int) -> c_int;

#[allow(dead_code)]
pub const ZLOB_NOSPACE: c_int = 1;
#[allow(dead_code)]
pub const ZLOB_ABORTED: c_int = 2;
#[allow(dead_code)]
pub const ZLOB_NOMATCH: c_int = 3;

extern "C" {
    #[link_name = "glob"]
    pub fn zlob(
        pattern: *const c_char,
        flags: c_int,
        errfunc: Option<zlob_errfunc_t>,
        pzlob: *mut zlob_t,
    ) -> c_int;

    #[link_name = "glob_at"]
    pub fn zlob_at(
        base_path: *const c_char,
        pattern: *const c_char,
        flags: c_int,
        errfunc: Option<zlob_errfunc_t>,
        pzlob: *mut zlob_t,
    ) -> c_int;

    #[link_name = "globfree"]
    pub fn zlobfree(pzlob: *mut zlob_t);

    pub fn zlob_match_paths_slice(
        pattern: *const zlob_slice_t,
        paths: *const zlob_slice_t,
        path_count: usize,
        flags: c_int,
        pzlob: *mut zlob_t,
    ) -> c_int;
}

impl Default for zlob_t {
    fn default() -> Self {
        Self {
            gl_pathc: 0,
            gl_pathv: std::ptr::null_mut(),
            gl_offs: 0,
            gl_pathlen: std::ptr::null_mut(),
            gl_flags: 0,
            gl_opendir: None,
            gl_readdir: None,
            gl_closedir: None,
        }
    }
}

// Safety: absolutely safe to use across multiple threads
unsafe impl Send for zlob_t {}
