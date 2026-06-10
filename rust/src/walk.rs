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
    root: CString,
    flags: u32,
    meta: WalkMetadata,
    threads: u16,
    max_depth: u16,
}

impl WalkBuilder {
    pub fn new(root: impl AsRef<Path>) -> Self {
        let bytes = path_to_bytes(root.as_ref());
        Self {
            root: CString::new(bytes).unwrap_or_default(),
            flags: WALK_GITIGNORE | WALK_SKIP_HIDDEN,
            meta: WalkMetadata::default(),
            threads: 0,
            max_depth: 0,
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

    /// Number of worker threads. `0` (default) = one per CPU; `1` = run on
    /// the calling thread.
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

    fn options(&self) -> ffi::zlob_walk_options_t {
        ffi::zlob_walk_options_t {
            flags: self.flags,
            meta_mask: self.meta.to_mask(),
            threads: self.threads,
            max_depth: self.max_depth,
            errfunc: None,
        }
    }

    /// Walk the tree and materialize all entries in one call.
    ///
    /// This is the fastest way to consume the walker from Rust: workers
    /// accumulate into lock-free private buffers and the result crosses the
    /// FFI boundary exactly once.
    pub fn build(&self) -> Result<WalkResults, ZlobError> {
        let opts = self.options();
        let mut out = ffi::zlob_walk_result_t {
            entries: std::ptr::null_mut(),
            count: 0,
            _storage: std::ptr::null_mut(),
        };
        let rc = unsafe { ffi::zlob_walk_collect(self.root.as_ptr(), &opts, &mut out) };
        match rc {
            0 => Ok(WalkResults { raw: out }),
            _ => Err(rc_to_error(rc)),
        }
    }

    /// Stream entries through `visitor`, in parallel.
    ///
    /// With more than one thread the visitor is called concurrently from
    /// worker threads, hence `Sync`. Entry borrows are only valid for the
    /// duration of the call.
    pub fn run<F>(&self, visitor: F) -> Result<(), ZlobError>
    where
        F: Fn(WalkEntry<'_>) -> WalkState + Sync,
    {
        unsafe extern "C" fn trampoline<F>(
            entry: *const ffi::zlob_walk_entry_t,
            ctx: *mut c_void,
        ) -> c_int
        where
            F: Fn(WalkEntry<'_>) -> WalkState + Sync,
        {
            let visitor = unsafe { &*(ctx as *const F) };
            let entry = WalkEntry {
                raw: unsafe { &*entry },
                _marker: PhantomData,
            };
            match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| visitor(entry))) {
                Ok(WalkState::Continue) => 0,
                Ok(WalkState::SkipDir) => 1,
                Ok(WalkState::Quit) => 2,
                Err(_) => 2, // poison the walk on panic; don't unwind into Zig
            }
        }

        let opts = self.options();
        let rc = unsafe {
            ffi::zlob_walk(
                self.root.as_ptr(),
                &opts,
                Some(trampoline::<F>),
                &visitor as *const F as *mut c_void,
            )
        };
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
}
