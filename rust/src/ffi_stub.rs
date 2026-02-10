// Stub FFI bindings for docs.rs builds where bindgen cannot run.
// This file provides the minimal type definitions needed for documentation
// generation without the actual native library.

use core::ffi::{c_char, c_int, c_uchar};

pub const ZLOB_ERR: c_int = 1 << 0;
pub const ZLOB_MARK: c_int = 1 << 1;
pub const ZLOB_NOSORT: c_int = 1 << 2;
pub const ZLOB_DOOFFS: c_int = 1 << 3;
pub const ZLOB_NOCHECK: c_int = 1 << 4;
pub const ZLOB_APPEND: c_int = 1 << 5;
pub const ZLOB_NOESCAPE: c_int = 1 << 6;
pub const ZLOB_PERIOD: c_int = 1 << 7;
pub const ZLOB_MAGCHAR: c_int = 1 << 8;
pub const ZLOB_ALTDIRFUNC: c_int = 1 << 9;
pub const ZLOB_BRACE: c_int = 1 << 10;
pub const ZLOB_NOMAGIC: c_int = 1 << 11;
pub const ZLOB_TILDE: c_int = 1 << 12;
pub const ZLOB_ONLYDIR: c_int = 1 << 13;
pub const ZLOB_TILDE_CHECK: c_int = 1 << 14;
pub const ZLOB_GITIGNORE: c_int = 1 << 24;
pub const ZLOB_DOUBLESTAR_RECURSIVE: c_int = 1 << 25;
pub const ZLOB_EXTGLOB: c_int = 1 << 26;

pub const ZLOB_RECOMMENDED: c_int =
    ZLOB_BRACE | ZLOB_DOUBLESTAR_RECURSIVE | ZLOB_NOSORT | ZLOB_TILDE | ZLOB_TILDE_CHECK;

pub const ZLOB_NOSPACE: c_int = 1;
pub const ZLOB_ABORTED: c_int = 2;
pub const ZLOB_NOMATCH: c_int = 3;

pub const ZLOB_DT_UNKNOWN: c_uchar = 0;
pub const ZLOB_DT_DIR: c_uchar = 4;
pub const ZLOB_DT_REG: c_uchar = 8;
pub const ZLOB_DT_LNK: c_uchar = 10;

#[repr(C)]
pub struct zlob_dirent_t {
    pub d_name: *const c_char,
    pub d_type: c_uchar,
}

#[repr(C)]
pub struct zlob_slice_t {
    pub ptr: *const c_uchar,
    pub len: usize,
}

#[repr(C)]
pub struct zlob_t {
    pub zlo_pathc: usize,
    pub zlo_pathv: *mut *mut c_char,
    pub zlo_offs: usize,
    pub zlo_pathlen: *mut usize,
    pub zlo_flags: c_int,
    pub zlo_opendir: Option<unsafe extern "C" fn(path: *const c_char) -> *mut core::ffi::c_void>,
    pub zlo_readdir:
        Option<unsafe extern "C" fn(dir: *mut core::ffi::c_void) -> *mut zlob_dirent_t>,
    pub zlo_closedir: Option<unsafe extern "C" fn(dir: *mut core::ffi::c_void)>,
}

// Stub functions - these will never be called during doc builds
extern "C" {
    pub fn zlob(
        pattern: *const c_char,
        flags: c_int,
        errfunc: Option<unsafe extern "C" fn(epath: *const c_char, eerrno: c_int) -> c_int>,
        pzlob: *mut zlob_t,
    ) -> c_int;

    pub fn zlobfree(pzlob: *mut zlob_t);

    pub fn zlob_at(
        base_path: *const c_char,
        pattern: *const c_char,
        flags: c_int,
        errfunc: Option<unsafe extern "C" fn(epath: *const c_char, eerrno: c_int) -> c_int>,
        pzlob: *mut zlob_t,
    ) -> c_int;

    pub fn zlob_match_paths_slice(
        pattern: *const zlob_slice_t,
        paths: *const zlob_slice_t,
        path_count: usize,
        flags: c_int,
        pzlob: *mut zlob_t,
    ) -> c_int;

    pub fn zlob_match_paths(
        pattern: *const c_char,
        paths: *const *const c_char,
        path_count: usize,
        flags: c_int,
        pzlob: *mut zlob_t,
    ) -> c_int;

    pub fn zlob_match_paths_at(
        base_path: *const c_char,
        pattern: *const c_char,
        paths: *const *const c_char,
        path_count: usize,
        flags: c_int,
        pzlob: *mut zlob_t,
    ) -> c_int;

    pub fn zlob_match_paths_at_slice(
        base_path: *const zlob_slice_t,
        pattern: *const zlob_slice_t,
        paths: *const zlob_slice_t,
        path_count: usize,
        flags: c_int,
        pzlob: *mut zlob_t,
    ) -> c_int;

    pub fn zlob_has_wildcards(pattern: *const c_char, flags: c_int) -> c_int;
}
