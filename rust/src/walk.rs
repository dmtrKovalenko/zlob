//! Parallel recursive directory walker — a drop-in replacement for the
//! `walkdir` and `ignore` crates backed by zlob's native walker.
//!
//! Highlights:
//! - Traversal runs on a pool of worker threads (one per CPU by default).
//! - Metadata is fetched in bulk where the OS allows it (`getattrlistbulk`
//!   on macOS, `statx` on Linux) and only requested attributes are paid for.
//! - Nested `.gitignore` files are honored and matched in parallel.
//! - [`WalkBuilder::build`] materializes the whole tree with a single FFI
//!   call (no per-entry callback crossing) — typically much faster than
//!   iterating `walkdir`.
//!
//! ```no_run
//! use zlob::walk::WalkBuilder;
//!
//! // ignore-crate-style defaults: .gitignore respected, hidden skipped.
//! let results = WalkBuilder::new("./src").build().unwrap();
//! for entry in results.iter() {
//!     println!("{}", entry.path().display());
//! }
//!
//! // Streaming + parallel, walkdir-style (no filtering):
//! WalkBuilder::new(".")
//!     .git_ignore(false)
//!     .hidden(false)
//!     .run(|entry| {
//!         println!("{}", entry.path().display());
//!         zlob::walk::WalkState::Continue
//!     })
//!     .unwrap();
//! ```

use crate::error::ZlobError;
use crate::ffi;
use std::ffi::CString;
use std::marker::PhantomData;
use std::os::raw::{c_int, c_void};
use std::path::Path;
use std::sync::Mutex;

// Walk behavior flags (must match include/zlob.h).
const WALK_GITIGNORE: u32 = 1 << 0;
const WALK_SKIP_HIDDEN: u32 = 1 << 1;
const WALK_FOLLOW_SYMLINKS: u32 = 1 << 2;
const WALK_NO_REPORT_DIRS: u32 = 1 << 3;
const WALK_SORT: u32 = 1 << 4;
const WALK_ABORT_ON_ERROR: u32 = 1 << 5;
const WALK_KEEP_GIT_DIR: u32 = 1 << 6;

// Metadata attribute bits (must match include/zlob.h).
const META_SIZE: u32 = 1 << 0;
const META_MTIME: u32 = 1 << 1;
const META_ATIME: u32 = 1 << 2;
const META_CTIME: u32 = 1 << 3;
const META_BTIME: u32 = 1 << 4;
const META_INODE: u32 = 1 << 5;
const META_NLINK: u32 = 1 << 6;
const META_MODE: u32 = 1 << 7;
const META_UID: u32 = 1 << 8;
const META_GID: u32 = 1 << 9;

/// Which metadata attributes the walker should fetch per entry.
///
/// Keep it `default()` (nothing) when you only need names and kinds — the
/// walker then never stats anything. On macOS all requested attributes are
/// fetched in bulk (one syscall per directory batch) via `getattrlistbulk`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WalkMetadata {
    pub size: bool,
    pub modified: bool,
    pub accessed: bool,
    pub changed: bool,
    /// Creation (birth) time — not available on all filesystems.
    pub created: bool,
    pub inode: bool,
    pub nlink: bool,
    /// Permission bits (mode & 0o7777).
    pub mode: bool,
    pub uid: bool,
    pub gid: bool,
}

impl WalkMetadata {
    /// Request every supported attribute.
    pub fn all() -> Self {
        Self {
            size: true,
            modified: true,
            accessed: true,
            changed: true,
            created: true,
            inode: true,
            nlink: true,
            mode: true,
            uid: true,
            gid: true,
        }
    }

    fn to_mask(self) -> u32 {
        let mut m = 0;
        if self.size {
            m |= META_SIZE;
        }
        if self.modified {
            m |= META_MTIME;
        }
        if self.accessed {
            m |= META_ATIME;
        }
        if self.changed {
            m |= META_CTIME;
        }
        if self.created {
            m |= META_BTIME;
        }
        if self.inode {
            m |= META_INODE;
        }
        if self.nlink {
            m |= META_NLINK;
        }
        if self.mode {
            m |= META_MODE;
        }
        if self.uid {
            m |= META_UID;
        }
        if self.gid {
            m |= META_GID;
        }
        m
    }
}

/// Flow control returned by [`WalkBuilder::run`] visitors.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalkState {
    /// Keep walking.
    Continue,
    /// Don't descend into this directory (no effect for files).
    SkipDir,
    /// Stop the whole walk as soon as possible.
    Quit,
}

/// Entry kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalkEntryKind {
    File,
    Dir,
    Symlink,
    Unknown,
}

/// Builder for a parallel directory walk.
///
/// Defaults mirror the `ignore` crate: `.gitignore` files (nested included)
/// are respected, hidden entries are skipped, directories are reported.
/// For raw `walkdir` semantics use `.git_ignore(false).hidden(false)`.
#[derive(Debug, Clone)]
pub struct WalkBuilder {
    /// `Err` when the root contained an interior NUL — surfaced by
    /// [`Self::build`]/[`Self::run`] instead of silently walking elsewhere.
    root: Result<CString, ZlobError>,
    flags: u32,
    meta: WalkMetadata,
    threads: u16,
    max_depth: u16,
    /// `Err` when a pattern contained an interior NUL — surfaced by
    /// [`Self::build`]/[`Self::run`] instead of silently dropping the filter.
    pattern: Result<Option<CString>, ZlobError>,
    pattern_flags: u32,
}

impl WalkBuilder {
    pub fn new(root: impl AsRef<Path>) -> Self {
        let bytes = path_to_bytes(root.as_ref());
        Self {
            root: CString::new(bytes).map_err(|_| ZlobError::InvalidInput),
            flags: WALK_GITIGNORE | WALK_SKIP_HIDDEN,
            meta: WalkMetadata::default(),
            threads: 0,
            max_depth: 0,
            pattern: Ok(None),
            pattern_flags: 0,
        }
    }

    fn set(&mut self, bit: u32, on: bool) -> &mut Self {
        if on {
            self.flags |= bit;
        } else {
            self.flags &= !bit;
        }
        self
    }

    /// Honor `.gitignore` files, including nested ones (default: `true`).
    /// Also skips `.git` directories while enabled.
    pub fn git_ignore(&mut self, yes: bool) -> &mut Self {
        self.set(WALK_GITIGNORE, yes)
    }

    /// Skip hidden (dot) files and directories (default: `true`).
    pub fn hidden(&mut self, skip: bool) -> &mut Self {
        self.set(WALK_SKIP_HIDDEN, skip)
    }

    /// Follow symbolic links to directories (default: `false`).
    /// Cycles are detected and broken.
    pub fn follow_links(&mut self, yes: bool) -> &mut Self {
        self.set(WALK_FOLLOW_SYMLINKS, yes)
    }

    /// Report directory entries themselves (default: `true`).
    pub fn report_dirs(&mut self, yes: bool) -> &mut Self {
        self.set(WALK_NO_REPORT_DIRS, !yes)
    }

    /// Sort [`WalkBuilder::build`] results by path (default: `false`).
    /// Parallel traversal is inherently unordered; sorting happens once at
    /// the end.
    pub fn sort(&mut self, yes: bool) -> &mut Self {
        self.set(WALK_SORT, yes)
    }

    /// Abort the walk on the first directory error (default: `false`,
    /// unreadable directories are skipped).
    pub fn abort_on_error(&mut self, yes: bool) -> &mut Self {
        self.set(WALK_ABORT_ON_ERROR, yes)
    }

    /// Still descend into `.git` directories when gitignore is enabled.
    pub fn keep_git_dir(&mut self, yes: bool) -> &mut Self {
        self.set(WALK_KEEP_GIT_DIR, yes)
    }

    /// Metadata to fetch per entry (default: none).
    pub fn metadata(&mut self, meta: WalkMetadata) -> &mut Self {
        self.meta = meta;
        self
    }

    /// Glob filter: only entries whose root-relative path matches the
    /// pattern are reported (e.g. `**/*.rs`, `src/**`, `*.{c,h}`).
    ///
    /// Traversal itself is narrowed too: directories outside the pattern's
    /// literal prefix (everything but `src/` for `src/**/*.c`) are pruned
    /// without ever being opened. Matching is SIMD-accelerated, compiled
    /// once per walk, and runs lock-free on the worker threads.
    ///
    /// Compiled with brace expansion + recursive `**` by default; use
    /// [`Self::glob_with_flags`] for different pattern semantics.
    pub fn glob(&mut self, pattern: impl AsRef<str>) -> &mut Self {
        self.pattern = CString::new(pattern.as_ref())
            .map(Some)
            .map_err(|_| ZlobError::InvalidInput);
        self.pattern_flags = 0; // library default: BRACE | DOUBLESTAR_RECURSIVE
        self
    }

    /// Like [`Self::glob`] but with explicit [`crate::ZlobFlags`] for the
    /// pattern (e.g. enable `EXTGLOB`, disable `BRACE`).
    pub fn glob_with_flags(
        &mut self,
        pattern: impl AsRef<str>,
        flags: crate::ZlobFlags,
    ) -> &mut Self {
        self.pattern = CString::new(pattern.as_ref())
            .map(Some)
            .map_err(|_| ZlobError::InvalidInput);
        self.pattern_flags = flags.bits() as u32;
        self
    }

    /// Number of worker threads. `0` (default) = one per CPU; `1` = run on the calling thread.
    pub fn threads(&mut self, n: usize) -> &mut Self {
        self.threads = n.min(u16::MAX as usize) as u16;
        self
    }

    /// Maximum depth to descend/yield. Direct children of the root are at
    /// depth 1. `None` (default) = unlimited.
    pub fn max_depth(&mut self, depth: Option<usize>) -> &mut Self {
        self.max_depth = depth.unwrap_or(0).min(u16::MAX as usize) as u16;
        self
    }

    /// Validated root + options. The returned pattern/root pointers borrow
    /// from `self` and stay valid for the duration of the FFI call.
    fn checked_options(&self) -> Result<(&CString, ffi::zlob_walk_options_t), ZlobError> {
        let root = self.root.as_ref().map_err(|e| *e)?;
        let pattern = match self.pattern.as_ref().map_err(|e| *e)? {
            Some(p) => p.as_ptr(),
            None => std::ptr::null(),
        };
        Ok((
            root,
            ffi::zlob_walk_options_t {
                flags: self.flags,
                meta_mask: self.meta.to_mask(),
                threads: self.threads,
                max_depth: self.max_depth,
                errfunc: None,
                pattern,
                pattern_flags: self.pattern_flags,
            },
        ))
    }

    /// Walk the tree and materialize all entries in one call.
    ///
    /// This is the fastest way to consume the walker from Rust: workers
    /// accumulate into lock-free private buffers and the result crosses the
    /// FFI boundary exactly once.
    pub fn build(&self) -> Result<WalkResults, ZlobError> {
        let (root, opts) = self.checked_options()?;
        let mut out = ffi::zlob_walk_result_t {
            entries: std::ptr::null_mut(),
            count: 0,
            _storage: std::ptr::null_mut(),
        };
        let rc = unsafe { ffi::zlob_walk_collect(root.as_ptr(), &opts, &mut out) };
        match rc {
            0 => Ok(WalkResults { raw: out }),
            _ => Err(rc_to_error(rc)),
        }
    }

    /// Stream entries through `visitor`, in parallel.
    ///
    /// The visitor is called concurrently from worker threads (one per CPU by
    /// default), hence the `Sync` bound — mirroring `ignore`'s
    /// `build_parallel`. If you only need a single-threaded walk and want to
    /// pass a non-`Sync` `FnMut` (e.g. one that mutates captured state without
    /// a lock), use [`Self::run_serial`] instead.
    ///
    /// Entry borrows are only valid for the duration of the call.
    ///
    /// A panicking visitor stops the walk; the panic resumes on the calling
    /// thread once the walk has wound down.
    pub fn run<F>(&self, visitor: F) -> Result<(), ZlobError>
    where
        F: Fn(WalkEntry<'_>) -> WalkState + Sync,
    {
        // The parallel contract: honor the builder's thread setting (0 = one
        // per CPU). The visitor is shared by reference across workers.
        self.run_inner(self.threads, &move |e| visitor(e))
    }

    /// Stream entries through `visitor` on the calling thread only.
    ///
    /// This is the single-threaded counterpart to [`Self::run`]: because the
    /// visitor is only ever invoked from the caller's thread, it takes an
    /// `FnMut` with **no `Sync`/`Send` bound**, so it may freely mutate
    /// captured state (e.g. push into a `Vec`, accumulate into a local) without
    /// any synchronization. This mirrors how `walkdir`/`ignore` expose a plain
    /// serial iterator separate from their parallel API.
    ///
    /// The builder's [`Self::threads`] setting is ignored here (the walk always
    /// runs on the calling thread).
    ///
    /// Entry borrows are only valid for the duration of the call. A panicking
    /// visitor stops the walk; the panic resumes on the caller once the walk
    /// has wound down.
    pub fn run_serial<F>(&self, mut visitor: F) -> Result<(), ZlobError>
    where
        F: FnMut(WalkEntry<'_>) -> WalkState,
    {
        // `run_inner` requires a `Fn + Sync` closure (the parallel contract).
        // A serial `FnMut` satisfies neither on its own, so we bridge it:
        //   - interior mutability (`RefCell`) turns the `FnMut` into something
        //     callable through `&self`, i.e. a `Fn`;
        //   - `AssertSync` supplies the `Sync` bound.
        // Both are sound ONLY because `run_inner(1, ...)` forces a
        // single-threaded walk: the closure runs exclusively on the calling
        // thread, so there is never concurrent access to the `RefCell`.
        struct AssertSync<T>(T);
        // SAFETY: only constructed here and only ever driven with `threads = 1`,
        // so the wrapped `RefCell` is touched by a single thread.
        unsafe impl<T> Sync for AssertSync<T> {}

        let cell = AssertSync(std::cell::RefCell::new(&mut visitor));
        // Capture the whole `AssertSync` wrapper (not its inner field) so the
        // closure inherits `AssertSync`'s asserted `Sync`. Disjoint closure
        // captures would otherwise grab `cell.0` directly and lose it.
        let adapter = &cell;
        self.run_inner(1, &move |e| (adapter.0.borrow_mut())(e))
    }

    /// Shared FFI driver for [`Self::run`]/[`Self::run_serial`]. `threads`
    /// overrides the worker count for this walk; `visitor` is invoked per
    /// entry and must outlive the call.
    fn run_inner<F>(&self, threads: u16, visitor: &F) -> Result<(), ZlobError>
    where
        F: Fn(WalkEntry<'_>) -> WalkState + Sync,
    {
        struct VisitCtx<'a, F> {
            visitor: &'a F,
            // First panic payload from any worker; replayed after the FFI
            // call returns (unwinding across the Zig frames is UB).
            panic: Mutex<Option<Box<dyn std::any::Any + Send + 'static>>>,
        }

        unsafe extern "C" fn trampoline<F>(
            entry: *const ffi::zlob_walk_entry_t,
            ctx: *mut c_void,
        ) -> c_int
        where
            F: Fn(WalkEntry<'_>) -> WalkState + Sync,
        {
            let ctx = unsafe { &*(ctx as *const VisitCtx<'_, F>) };
            let entry = WalkEntry {
                raw: unsafe { &*entry },
                _marker: PhantomData,
            };
            match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| (ctx.visitor)(entry))) {
                Ok(WalkState::Continue) => 0,
                Ok(WalkState::SkipDir) => 1,
                Ok(WalkState::Quit) => 2,
                Err(payload) => {
                    let mut slot = ctx.panic.lock().unwrap_or_else(|p| p.into_inner());
                    if slot.is_none() {
                        *slot = Some(payload);
                    }
                    2 // stop the walk; don't unwind into Zig
                }
            }
        }

        let (root, mut opts) = self.checked_options()?;
        opts.threads = threads;
        let ctx = VisitCtx {
            visitor,
            panic: Mutex::new(None),
        };
        let rc = unsafe {
            ffi::zlob_walk(
                root.as_ptr(),
                &opts,
                Some(trampoline::<F>),
                &ctx as *const VisitCtx<'_, F> as *mut c_void,
            )
        };
        if let Some(payload) = ctx.panic.lock().unwrap_or_else(|p| p.into_inner()).take() {
            std::panic::resume_unwind(payload);
        }
        match rc {
            0 => Ok(()),
            _ => Err(rc_to_error(rc)),
        }
    }
}

fn rc_to_error(rc: c_int) -> ZlobError {
    match ZlobError::from_code(rc) {
        Err(e) => e,
        // The walker never returns NOMATCH-style codes; treat anything else
        // unexpected as an abort.
        Ok(_) => ZlobError::Aborted,
    }
}

#[cfg(unix)]
fn path_to_bytes(p: &Path) -> Vec<u8> {
    use std::os::unix::ffi::OsStrExt;
    p.as_os_str().as_bytes().to_vec()
}

#[cfg(not(unix))]
fn path_to_bytes(p: &Path) -> Vec<u8> {
    p.to_string_lossy().into_owned().into_bytes()
}

/// Owned results of [`WalkBuilder::build`]. Holds all paths and metadata in
/// a handful of contiguous allocations.
pub struct WalkResults {
    raw: ffi::zlob_walk_result_t,
}

// The underlying storage is plain heap memory with no thread affinity.
unsafe impl Send for WalkResults {}
unsafe impl Sync for WalkResults {}

impl WalkResults {
    pub fn len(&self) -> usize {
        self.raw.count
    }

    pub fn is_empty(&self) -> bool {
        self.raw.count == 0
    }

    fn raw_entries(&self) -> &[ffi::zlob_walk_entry_t] {
        if self.raw.count == 0 || self.raw.entries.is_null() {
            return &[];
        }
        unsafe { std::slice::from_raw_parts(self.raw.entries, self.raw.count) }
    }

    pub fn get(&self, index: usize) -> Option<WalkEntry<'_>> {
        self.raw_entries().get(index).map(|raw| WalkEntry {
            raw,
            _marker: PhantomData,
        })
    }

    pub fn iter(&self) -> impl ExactSizeIterator<Item = WalkEntry<'_>> {
        self.raw_entries().iter().map(|raw| WalkEntry {
            raw,
            _marker: PhantomData,
        })
    }

    /// Reusable ignore rules (`.gitignore` + `.ignore`, nested) gathered during
    /// the walk, for testing arbitrary paths afterwards. Always `Some` after a
    /// successful [`WalkBuilder::build`] (empty when `.git_ignore(false)` or the
    /// tree had no ignore files). The returned matcher borrows from these
    /// results.
    pub fn ignore_rules(&self) -> Option<IgnoreRules<'_>> {
        let handle = unsafe { ffi::zlob_walk_result_ignore_rules(&self.raw) };
        if handle.is_null() {
            None
        } else {
            Some(IgnoreRules {
                handle,
                _marker: PhantomData,
            })
        }
    }
}

/// A reusable view of the ignore rules a walk discovered, for checking
/// arbitrary paths after the walk has finished. Borrows from the
/// [`WalkResults`] it came from.
///
/// Resolves nested `.gitignore`/`.ignore` rules deepest-first, mirroring git.
#[derive(Clone, Copy)]
pub struct IgnoreRules<'a> {
    handle: *mut c_void,
    _marker: PhantomData<&'a ()>,
}

// The handle points into the walk result's owned, immutable rule storage.
unsafe impl Send for IgnoreRules<'_> {}
unsafe impl Sync for IgnoreRules<'_> {}

impl IgnoreRules<'_> {
    /// Returns whether `path` (relative to the walk root) is ignored.
    /// Use on a trusted paths that you know exists, folders should be indicated witha trailing
    /// forward slash.
    ///
    /// There is [`Self::is_ignored_untrusted`], which stats the path.
    pub fn is_ignored(&self, path: impl AsRef<Path>) -> bool {
        let Ok(cpath) = CString::new(path_to_bytes(path.as_ref())) else {
            return false; // an interior NUL can't match any real path
        };
        unsafe { ffi::zlob_ignore_rules_match_path(self.handle, cpath.as_ptr()) != 0 }
    }

    /// Like [`Self::is_ignored`] but determines directory-ness by stat'ing the
    /// path on disk (symlinks are not followed
    pub fn is_ignored_untrusted(&self, path: impl AsRef<Path>) -> bool {
        let Ok(cpath) = CString::new(path_to_bytes(path.as_ref())) else {
            return false;
        };

        unsafe { ffi::zlob_ignore_rules_match_untrusted(self.handle, cpath.as_ptr()) != 0 }
    }
}

impl Drop for WalkResults {
    fn drop(&mut self) {
        unsafe { ffi::zlob_walk_result_free(&mut self.raw) };
    }
}

impl std::fmt::Debug for WalkResults {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WalkResults")
            .field("count", &self.raw.count)
            .finish()
    }
}

/// A single walked entry. Borrowed from [`WalkResults`] storage or, inside
/// [`WalkBuilder::run`] visitors, from per-worker buffers.
#[derive(Clone, Copy)]
pub struct WalkEntry<'a> {
    raw: &'a ffi::zlob_walk_entry_t,
    _marker: PhantomData<&'a ()>,
}

impl<'a> WalkEntry<'a> {
    #[inline]
    pub fn path_bytes(&self) -> &'a [u8] {
        unsafe { std::slice::from_raw_parts(self.raw.path as *const u8, self.raw.path_len) }
    }

    /// Full path (walk root joined with the relative path).
    #[inline]
    pub fn path(&self) -> &'a Path {
        bytes_to_path(self.path_bytes())
    }

    /// Path relative to the walk root.
    #[inline]
    pub fn rel_path(&self) -> &'a Path {
        bytes_to_path(&self.path_bytes()[self.raw.rel_off as usize..])
    }

    /// The entry's name (final path component).
    #[inline]
    pub fn file_name(&self) -> &'a Path {
        bytes_to_path(&self.path_bytes()[self.raw.basename_off as usize..])
    }

    /// Depth below the root — direct children of the root are at depth 1.
    #[inline]
    pub fn depth(&self) -> usize {
        self.raw.depth as usize
    }

    #[inline]
    pub fn kind(&self) -> WalkEntryKind {
        match self.raw.kind {
            1 => WalkEntryKind::File,
            2 => WalkEntryKind::Dir,
            3 => WalkEntryKind::Symlink,
            _ => WalkEntryKind::Unknown,
        }
    }

    #[inline]
    pub fn is_file(&self) -> bool {
        self.raw.kind == 1
    }

    #[inline]
    pub fn is_dir(&self) -> bool {
        self.raw.kind == 2
    }

    #[inline]
    pub fn is_symlink(&self) -> bool {
        self.raw.kind == 3
    }

    fn meta(&self, bit: u32) -> bool {
        self.raw.meta_valid & bit != 0
    }

    /// File size in bytes (requires `WalkMetadata.size`).
    pub fn size(&self) -> Option<u64> {
        self.meta(META_SIZE).then_some(self.raw.size)
    }

    /// Modification time, nanoseconds since the Unix epoch.
    pub fn modified_ns(&self) -> Option<i64> {
        self.meta(META_MTIME).then_some(self.raw.mtime_ns)
    }

    /// Access time, nanoseconds since the Unix epoch.
    pub fn accessed_ns(&self) -> Option<i64> {
        self.meta(META_ATIME).then_some(self.raw.atime_ns)
    }

    /// Status-change time, nanoseconds since the Unix epoch.
    pub fn changed_ns(&self) -> Option<i64> {
        self.meta(META_CTIME).then_some(self.raw.ctime_ns)
    }

    /// Creation (birth) time, nanoseconds since the Unix epoch.
    pub fn created_ns(&self) -> Option<i64> {
        self.meta(META_BTIME).then_some(self.raw.btime_ns)
    }

    pub fn inode(&self) -> Option<u64> {
        self.meta(META_INODE).then_some(self.raw.inode)
    }

    pub fn nlink(&self) -> Option<u32> {
        self.meta(META_NLINK).then_some(self.raw.nlink)
    }

    /// Permission bits (mode & 0o7777); the file type is in [`Self::kind`].
    pub fn mode(&self) -> Option<u32> {
        self.meta(META_MODE).then_some(self.raw.mode)
    }

    pub fn uid(&self) -> Option<u32> {
        self.meta(META_UID).then_some(self.raw.uid)
    }

    pub fn gid(&self) -> Option<u32> {
        self.meta(META_GID).then_some(self.raw.gid)
    }
}

impl std::fmt::Debug for WalkEntry<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WalkEntry")
            .field("path", &self.path())
            .field("kind", &self.kind())
            .field("depth", &self.depth())
            .finish()
    }
}

#[cfg(unix)]
fn bytes_to_path(b: &[u8]) -> &Path {
    use std::os::unix::ffi::OsStrExt;
    Path::new(std::ffi::OsStr::from_bytes(b))
}

#[cfg(not(unix))]
fn bytes_to_path(b: &[u8]) -> &Path {
    // The native walker produces WTF-8/UTF-8 encoded paths on Windows.
    Path::new(std::str::from_utf8(b).unwrap_or(""))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn make_tree() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir(root.join("src")).unwrap();
        fs::create_dir(root.join("target")).unwrap();
        fs::write(root.join(".gitignore"), "target/\n*.log\n").unwrap();
        fs::write(root.join("Cargo.toml"), "x").unwrap();
        fs::write(root.join("debug.log"), "").unwrap();
        fs::write(root.join("src/main.rs"), "fn main() {}").unwrap();
        fs::write(root.join("target/out.bin"), "bin").unwrap();
        dir
    }

    #[test]
    fn build_respects_gitignore() {
        let dir = make_tree();
        let results = WalkBuilder::new(dir.path())
            .threads(1)
            .sort(true)
            .build()
            .unwrap();

        let names: Vec<String> = results
            .iter()
            .map(|e| e.rel_path().to_string_lossy().into_owned())
            .collect();

        // hidden(.gitignore) skipped, target/ and *.log ignored
        assert_eq!(names, vec!["Cargo.toml", "src", "src/main.rs"]);
    }

    #[test]
    fn build_plain_walkdir_mode() {
        let dir = make_tree();
        let results = WalkBuilder::new(dir.path())
            .git_ignore(false)
            .hidden(false)
            .threads(1)
            .sort(true)
            .build()
            .unwrap();

        let names: Vec<String> = results
            .iter()
            .map(|e| e.rel_path().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            names,
            vec![
                ".gitignore",
                "Cargo.toml",
                "debug.log",
                "src",
                "src/main.rs",
                "target",
                "target/out.bin",
            ]
        );

        let main_rs = results
            .iter()
            .find(|e| e.file_name() == Path::new("main.rs"))
            .unwrap();
        assert!(main_rs.is_file());
        assert_eq!(main_rs.depth(), 2);
        assert!(main_rs.path().ends_with("src/main.rs"));
        // no metadata requested
        assert_eq!(main_rs.size(), None);
    }

    #[test]
    fn metadata_size_and_mtime() {
        let dir = make_tree();
        let results = WalkBuilder::new(dir.path())
            .git_ignore(false)
            .hidden(false)
            .threads(1)
            .metadata(WalkMetadata {
                size: true,
                modified: true,
                inode: true,
                ..Default::default()
            })
            .build()
            .unwrap();

        let main_rs = results
            .iter()
            .find(|e| e.file_name() == Path::new("main.rs"))
            .unwrap();
        assert_eq!(main_rs.size(), Some(12)); // "fn main() {}"
        assert!(main_rs.modified_ns().unwrap() > 0);
        assert!(main_rs.inode().unwrap() != 0);
    }

    #[test]
    fn parallel_run_visits_everything() {
        let dir = make_tree();
        let count = AtomicUsize::new(0);
        WalkBuilder::new(dir.path())
            .git_ignore(false)
            .hidden(false)
            .run(|_entry| {
                count.fetch_add(1, Ordering::Relaxed);
                WalkState::Continue
            })
            .unwrap();
        assert_eq!(count.load(Ordering::Relaxed), 7);
    }

    #[test]
    fn run_serial_accepts_non_sync_fnmut() {
        // The whole point of `run_serial`: no `Sync`/`Send` bound, so a plain
        // `FnMut` that mutates captured state without any synchronization
        // compiles and works. (`Vec`/`Rc` are `!Sync`; capturing them mutably
        // would be rejected by `run`.)
        use std::rc::Rc;
        let dir = make_tree();
        let mut names: Vec<String> = Vec::new();
        let not_sync: Rc<u8> = Rc::new(0); // a !Sync witness held across calls
        WalkBuilder::new(dir.path())
            .git_ignore(false)
            .hidden(false)
            // Even with many threads configured, run_serial ignores it and
            // runs single-threaded, so this borrow is sound.
            .threads(8)
            .run_serial(|entry| {
                let _ = &not_sync;
                names.push(entry.file_name().to_string_lossy().into_owned());
                WalkState::Continue
            })
            .unwrap();
        assert_eq!(names.len(), 7);
    }

    #[test]
    fn run_serial_skip_dir_and_quit() {
        let dir = make_tree();
        let mut count = 0usize;
        WalkBuilder::new(dir.path())
            .git_ignore(false)
            .hidden(false)
            .run_serial(|entry| {
                count += 1;
                if entry.is_dir() {
                    WalkState::SkipDir
                } else {
                    WalkState::Continue
                }
            })
            .unwrap();
        // top level only: .gitignore, Cargo.toml, debug.log, src, target
        assert_eq!(count, 5);
    }

    #[test]
    fn run_skip_dir_and_quit() {
        let dir = make_tree();
        let count = AtomicUsize::new(0);
        WalkBuilder::new(dir.path())
            .git_ignore(false)
            .hidden(false)
            .threads(1)
            .run(|entry| {
                count.fetch_add(1, Ordering::Relaxed);
                if entry.is_dir() {
                    WalkState::SkipDir
                } else {
                    WalkState::Continue
                }
            })
            .unwrap();
        // top level only: .gitignore, Cargo.toml, debug.log, src, target
        assert_eq!(count.load(Ordering::Relaxed), 5);

        let quit_count = AtomicUsize::new(0);
        WalkBuilder::new(dir.path())
            .threads(1)
            .run(|_| {
                quit_count.fetch_add(1, Ordering::Relaxed);
                WalkState::Quit
            })
            .unwrap();
        assert_eq!(quit_count.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn max_depth_limits() {
        let dir = make_tree();
        let results = WalkBuilder::new(dir.path())
            .git_ignore(false)
            .hidden(false)
            .threads(1)
            .max_depth(Some(1))
            .build()
            .unwrap();
        assert_eq!(results.len(), 5);
        assert!(results.iter().all(|e| e.depth() == 1));
    }

    #[test]
    fn interior_nul_is_an_error_not_a_silent_default() {
        // A root with an interior NUL must NOT silently walk the cwd.
        let err = WalkBuilder::new("bad\0root").build().unwrap_err();
        assert_eq!(err, ZlobError::InvalidInput);
        let err = WalkBuilder::new("bad\0root")
            .run(|_| WalkState::Continue)
            .unwrap_err();
        assert_eq!(err, ZlobError::InvalidInput);

        // A pattern with an interior NUL must NOT silently drop the filter.
        let dir = make_tree();
        let err = WalkBuilder::new(dir.path())
            .glob("*.\0rs")
            .build()
            .unwrap_err();
        assert_eq!(err, ZlobError::InvalidInput);
        // A later valid pattern clears the error.
        let ok = WalkBuilder::new(dir.path())
            .glob("*.\0rs")
            .glob("**/*.rs")
            .build();
        assert!(ok.is_ok());
    }

    #[test]
    #[should_panic(expected = "visitor exploded")]
    fn visitor_panic_propagates_to_caller() {
        let dir = make_tree();
        let _ = WalkBuilder::new(dir.path())
            .git_ignore(false)
            .hidden(false)
            .run(|_| panic!("visitor exploded"));
    }

    #[test]
    fn empty_and_missing_roots() {
        let dir = tempfile::tempdir().unwrap();
        let results = WalkBuilder::new(dir.path()).build().unwrap();
        assert!(results.is_empty());

        // Missing roots are reported through the (unset) error callback and
        // produce an empty result unless abort_on_error is set.
        let missing = WalkBuilder::new("/definitely/not/a/real/path/zlob")
            .build()
            .unwrap();
        assert!(missing.is_empty());

        let err = WalkBuilder::new("/definitely/not/a/real/path/zlob")
            .abort_on_error(true)
            .build();
        assert!(err.is_err());
    }

    #[test]
    fn retained_ignore_rules_are_reusable() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir(root.join("src")).unwrap();
        // Root: ignore *.log and build/; .ignore re-includes important.tmp,
        // while .gitignore ignores all *.tmp.
        fs::write(root.join(".gitignore"), "*.log\nbuild/\n*.tmp\n").unwrap();
        fs::write(root.join(".ignore"), "!important.tmp\n").unwrap();
        // Nested rule scoped to src/.
        fs::write(root.join("src/.gitignore"), "*.bak\n").unwrap();
        fs::write(root.join("src/main.rs"), "").unwrap();

        let results = WalkBuilder::new(root).threads(1).build().unwrap();

        let rules = results.ignore_rules().expect("rules always present");

        // Root-level rules (files: no trailing slash).
        assert!(rules.is_ignored("app.log"));
        // build/ is directory-only; the trailing slash marks it a directory.
        assert!(rules.is_ignored("build/"));
        // Without the slash it's treated as a file, so build/ doesn't apply.
        assert!(!rules.is_ignored("build"));
        assert!(rules.is_ignored("scratch.tmp"));
        // .ignore precedence re-includes important.tmp.
        assert!(!rules.is_ignored("important.tmp"));
        // Nested rule only inside src/.
        assert!(rules.is_ignored("src/old.bak"));
        assert!(!rules.is_ignored("old.bak"));
        assert!(!rules.is_ignored("src/main.rs"));

        // The untrusted variant resolves dir-ness by stat'ing the path it is
        // given, then matches that same string against the (root-relative)
        // rules. A path that doesn't exist resolves to "file", so the
        // directory-only `build/` rule does not apply; a *.tmp file rule still
        // does. (We avoid changing the process cwd in tests.)
        assert!(!rules.is_ignored_untrusted("build")); // missing -> file -> build/ skipped
        assert!(rules.is_ignored_untrusted("ghost.tmp")); // missing -> file -> *.tmp applies
    }

    #[test]
    fn ignore_rules_always_available() {
        // Rules are now always returned (no opt-in flag). With git_ignore on,
        // the tree's rules are queryable.
        let dir = make_tree();
        let results = WalkBuilder::new(dir.path()).build().unwrap();
        let rules = results.ignore_rules().expect("rules always present");
        // make_tree() gitignores target/ and *.log.
        assert!(rules.is_ignored("target/"));
        assert!(rules.is_ignored("debug.log"));
        assert!(!rules.is_ignored("Cargo.toml"));
    }

    #[cfg(unix)]
    #[test]
    fn permission_denied_surfaces_with_abort_on_error() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let locked = dir.path().join("locked");
        fs::create_dir(&locked).unwrap();
        fs::write(locked.join("inner.txt"), "x").unwrap();
        // Remove all access so opening/reading the directory fails.
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();

        // Restore permissions on the way out so the tempdir can be cleaned up,
        // regardless of how the assertions go.
        struct Restore<'a>(&'a std::path::Path);
        impl Drop for Restore<'_> {
            fn drop(&mut self) {
                let _ = fs::set_permissions(self.0, fs::Permissions::from_mode(0o755));
            }
        }
        let _restore = Restore(&locked);

        // Skip when running as root, where mode 0o000 is not enforced.
        if std::fs::read_dir(&locked).is_ok() {
            return;
        }

        // Tolerated by default: the unreadable directory is skipped.
        let ok = WalkBuilder::new(dir.path())
            .git_ignore(false)
            .hidden(false)
            .build();
        assert!(ok.is_ok());

        // With abort_on_error the permission error surfaces as its own variant
        // rather than collapsing into Aborted.
        let err = WalkBuilder::new(dir.path())
            .git_ignore(false)
            .hidden(false)
            .threads(1)
            .abort_on_error(true)
            .build()
            .unwrap_err();
        assert_eq!(err, ZlobError::PermissionDenied);
    }
}

#[cfg(test)]
mod glob_tests {
    use super::*;
    use std::fs;

    #[test]
    fn glob_filters_and_prunes() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir(root.join("src")).unwrap();
        fs::create_dir(root.join("docs")).unwrap();
        fs::write(root.join("src/main.rs"), "").unwrap();
        fs::write(root.join("src/lib.rs"), "").unwrap();
        fs::write(root.join("docs/guide.md"), "").unwrap();
        fs::write(root.join("top.rs"), "").unwrap();

        let results = WalkBuilder::new(root)
            .git_ignore(false)
            .hidden(false)
            .threads(1)
            .sort(true)
            .glob("**/*.rs")
            .build()
            .unwrap();

        let names: Vec<String> = results
            .iter()
            .map(|e| e.rel_path().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["src/lib.rs", "src/main.rs", "top.rs"]);

        // Brace pattern through the default flags.
        let braced = WalkBuilder::new(root)
            .git_ignore(false)
            .hidden(false)
            .threads(1)
            .glob("**/*.{md,rs}")
            .build()
            .unwrap();
        assert_eq!(braced.len(), 4);

        // Anchored pattern narrows traversal to the src/ subtree.
        let scoped = WalkBuilder::new(root)
            .git_ignore(false)
            .hidden(false)
            .threads(1)
            .glob("src/**/*.rs")
            .build()
            .unwrap();
        assert_eq!(scoped.len(), 2);
    }

    #[test]
    fn glob_composes_with_gitignore_and_parallel_run() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir(root.join("src")).unwrap();
        fs::create_dir(root.join("target")).unwrap();
        fs::write(root.join(".gitignore"), "target/\n").unwrap();
        fs::write(root.join("src/a.rs"), "").unwrap();
        fs::write(root.join("target/gen.rs"), "").unwrap();

        let count = AtomicUsize::new(0);
        WalkBuilder::new(root)
            .glob("**/*.rs")
            .run(|entry| {
                assert!(entry.path().extension().is_some_and(|e| e == "rs"));
                count.fetch_add(1, Ordering::Relaxed);
                WalkState::Continue
            })
            .unwrap();
        // target/gen.rs is gitignored; only src/a.rs survives both filters.
        assert_eq!(count.load(Ordering::Relaxed), 1);
    }
}
