use crate::error::ZlobError;
use crate::{ZlobFlags, ffi};
use bitflags::bitflags;
use std::ffi::{CStr, CString};
use std::marker::PhantomData;
use std::os::raw::{c_int, c_void};
use std::path::Path;

type Result<T> = std::result::Result<T, ZlobError>;

bitflags! {
    /// Options for a [`WalkBuilder`]. Combine with `|`.
    ///
    /// ```
    /// use zlob::walk::{WalkBuilder, WalkFlags};
    /// // raw traversal, sorted, directories suppressed
    /// // (run on a thread with a generous stack: rustdoc's default doctest
    /// // main-thread stack is small on Windows)
    /// std::thread::Builder::new().stack_size(8 << 20).spawn(|| {
    ///     let r = WalkBuilder::new("src")
    ///         .unwrap()
    ///         .options(WalkFlags::SORT | WalkFlags::NO_REPORT_DIRS)
    ///         .collect()
    ///         .unwrap();
    ///     let _ = r;
    /// }).unwrap().join().unwrap();
    /// ```
    ///
    /// Bit values must match `ZLOB_WALK_*` in `include/zlob.h`.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub struct WalkFlags: u32 {
        /// Honor nested `.gitignore`/`.ignore` files; also skips `.git` dirs.
        const GITIGNORE       = 1 << 0;
        /// Skip hidden (dot) files and don't descend into dot-directories.
        const SKIP_HIDDEN     = 1 << 1;
        /// Follow symlinked directories (cycles are detected and broken).
        const FOLLOW_SYMLINKS = 1 << 2;
        /// Do **not** report directory entries (they are still traversed).
        const NO_REPORT_DIRS  = 1 << 3;
        /// Sort [`WalkBuilder::collect`] results by path.
        const SORT            = 1 << 4;
        /// Abort on the first directory error (default: skip unreadable dirs).
        const ABORT_ON_ERROR  = 1 << 5;
        /// With [`Self::GITIGNORE`]: still descend into `.git` directories.
        const KEEP_GIT_DIR    = 1 << 6;

        /// `ignore`-crate-style defaults: [`Self::GITIGNORE`] | [`Self::SKIP_HIDDEN`].
        const RECOMMENDED     = Self::GITIGNORE.bits() | Self::SKIP_HIDDEN.bits();
    }
}

bitflags! {
    /// Which metadata attributes the walker should fetch per entry. Combine with `|`.
    ///
    /// ```
    /// use zlob::walk::{WalkBuilder, WalkMetadata};
    /// // (run on a thread with a generous stack: rustdoc's default doctest
    /// // main-thread stack is small on Windows)
    /// std::thread::Builder::new().stack_size(8 << 20).spawn(|| {
    ///     let r = WalkBuilder::new("src")
    ///         .unwrap()
    ///         .metadata(WalkMetadata::SIZE | WalkMetadata::MTIME)
    ///         .collect()
    ///         .unwrap();
    ///     let _ = r;
    /// }).unwrap().join().unwrap();
    /// ```
    ///
    /// Bit values must match `ZLOB_META_*` in `include/zlob.h`.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
    pub struct WalkMetadata: u32 {
        /// File size in bytes.
        const SIZE  = 1 << 0;
        /// Modification time.
        const MTIME = 1 << 1;
        /// Access time.
        const ATIME = 1 << 2;
        /// Status-change time.
        const CTIME = 1 << 3;
        /// Creation (birth) time — not available on all filesystems.
        const BTIME = 1 << 4;
        /// Inode number.
        const INODE = 1 << 5;
        /// Hard-link count.
        const NLINK = 1 << 6;
        /// Permission bits (mode & 0o7777).
        const MODE  = 1 << 7;
        /// Owner user id.
        const UID   = 1 << 8;
        /// Owner group id.
        const GID   = 1 << 9;

        /// Every supported attribute.
        const ALL   = 0x3FF;
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

/// Builder for a parallel directory walk. Settings diefault to [`WalkFlags::RECOMMENDED`]
#[derive(Debug, Clone)]
pub struct WalkBuilder {
    extra_ignore: Option<CString>,
    flags: WalkFlags,
    max_depth: u16,
    meta: WalkMetadata,
    pattern: Option<CString>,
    pattern_flags: i32,
    root: CString,
    threads: u16,
}

impl WalkBuilder {
    pub fn new(root: impl AsRef<Path>) -> Result<Self> {
        let bytes = path_to_bytes(root.as_ref());
        Ok(Self {
            root: CString::new(bytes).map_err(|_| ZlobError::InvalidInput)?,
            flags: WalkFlags::RECOMMENDED,
            meta: WalkMetadata::empty(),
            threads: 0,
            max_depth: 0,
            pattern_flags: 0,
            pattern: None,
            extra_ignore: None,
        })
    }

    /// Set the walk behavior flags, replacing any previously set flags
    /// (default: [`WalkFlags::RECOMMENDED`]).
    ///
    /// # Example
    ///
    /// ```no_run
    /// use zlob::walk::{WalkBuilder, WalkFlags};
    /// // raw traversal (walkdir-style): no gitignore, hidden shown
    /// let r = WalkBuilder::new(".")
    ///     .unwrap()
    ///     .options(WalkFlags::empty())
    ///     .collect()
    ///     .unwrap();
    /// ```
    pub fn options(&mut self, flags: WalkFlags) -> &mut Self {
        self.flags = flags;
        self
    }

    /// Metadata to fetch per entry (default: [`WalkMetadata::empty`]).
    pub fn metadata(&mut self, meta: WalkMetadata) -> &mut Self {
        self.meta = meta;
        self
    }

    /// White-list pattern for the included directories
    pub fn include(&mut self, pattern: impl AsRef<str>) -> Result<&mut Self> {
        self.pattern = Some(CString::new(pattern.as_ref()).map_err(|_| ZlobError::InvalidInput)?);
        self.pattern_flags = ZlobFlags::RECOMMENDED.bits();
        Ok(self)
    }

    /// Override `ZlobFlags::RECOMMENDED` for the included pattern. Always call it after
    /// `WalkBuilder::include`. Make sure that not all the flags make sense in this case,
    /// e.g. there is no reason to set ZlobFlags::GITIGNORE if gitignore is enabled for walker.
    ///
    /// ```no_run
    /// use zlob::{ZlobFlags, walk::WalkBuilder};
    /// # fn main() -> Result<(), zlob::ZlobError> {
    /// let r = WalkBuilder::new(".")?
    ///     .include("src/*.!(c|cpp)")? // pattern using bash extglob syntax
    ///     .include_flags(ZlobFlags::EXTGLOB) // need to enable it
    ///     .collect()?;
    /// # Ok(()) }
    /// ```
    pub fn include_flags(&mut self, flags: ZlobFlags) -> &mut Self {
        self.pattern_flags = flags.bits();
        self
    }

    /// Extra ignore rules layered into the walker, using `.gitignore` syntax.
    /// Those extra ignore rules are going to be surfaced in the output IgnoreRules set.
    ///
    /// ```no_run
    /// use zlob::walk::WalkBuilder;
    /// # fn main() -> Result<(), zlob::ZlobError> {
    /// let _ = WalkBuilder::new(".")?
    ///     .extra_ignore(&["node_modules", "target", ".venv", "!**/README.md"])?
    ///     .collect()?;
    /// # Ok(()) }
    /// ```
    pub fn extra_ignore<S: AsRef<str>>(&mut self, patterns: &[S]) -> Result<&mut Self> {
        let mut joined = String::new();
        for p in patterns {
            joined.push_str(p.as_ref());
            joined.push('\n');
        }

        self.extra_ignore = Some(CString::new(joined).map_err(|_| ZlobError::InvalidInput)?);
        Ok(self)
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

    /// Number of worker threads a [`Self::run`] / [`Self::collect`] with the
    /// current configuration will use (always >= 1). Every entry's
    /// [`WalkEntry::worker_id`] is strictly below this bound, so it is the
    /// exact size for caller-side per-worker shards:
    ///
    /// ```no_run
    /// use zlob::walk::{WalkBuilder, WalkState};
    /// # fn main() -> Result<(), zlob::ZlobError> {
    /// let mut builder = WalkBuilder::new(".")?;
    /// let shards: Vec<std::sync::Mutex<Vec<String>>> =
    ///     (0..builder.max_workers()).map(|_| Default::default()).collect();
    /// builder.run(|entry| {
    ///     // one worker per shard -> the lock is never contended
    ///     shards[entry.worker_id()]
    ///         .lock()
    ///         .unwrap()
    ///         .push(entry.path().display().to_string());
    ///     WalkState::Continue
    /// })?;
    /// # Ok(()) }
    /// ```
    pub fn max_workers(&self) -> usize {
        let Ok((_root, opts)) = self.checked_options() else {
            return 1;
        };
        (unsafe { ffi::zlob_walk_max_workers(&opts) }).max(1)
    }

    /// Validated root + options. The returned pattern/root pointers borrow
    /// from `self` and stay valid for the duration of the FFI call.
    fn checked_options(&self) -> Result<(&CStr, ffi::zlob_walk_options_t)> {
        let root = self.root.as_ref();
        let pattern = match self.pattern.as_ref() {
            Some(p) => p.as_ptr(),
            None => std::ptr::null(),
        };
        let extra_ignore = match self.extra_ignore.as_ref() {
            Some(p) => p.as_ptr(),
            None => std::ptr::null(),
        };

        Ok((
            root,
            ffi::zlob_walk_options_t {
                flags: self.flags.bits(),
                meta_mask: self.meta.bits(),
                threads: self.threads,
                max_depth: self.max_depth,
                errfunc: None,
                pattern,
                pattern_flags: self.pattern_flags as u32,
                extra_ignore,
            },
        ))
    }

    /// Walk the tree and materialize all entries in one call.
    ///
    /// This is the fastest way to consume the walker from Rust: workers
    /// accumulate into private buffers and then return combined results
    pub fn collect(&self) -> Result<WalkResults> {
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

    /// Stream entries through `visitor`, in parallel calling callback for every entry.
    /// Returns assembled Walk
    ///
    /// the callback should neer panic, panicking = UB
    pub fn run<F>(&self, visitor: F) -> Result<WalkerOutcomeRules>
    where
        F: Fn(WalkEntry<'_>) -> WalkState + Sync,
    {
        self.run_inner(self.threads, &move |e| visitor(e))
    }

    /// Stream entries through `visitor` on the calling thread only.
    /// This allows to pass non-Sync cb to the walker for example mutate reference
    ///
    /// Returns a [`WalkRulesHandle`] just like [`Self::run`].
    pub fn run_serial<F>(&self, mut visitor: F) -> Result<WalkerOutcomeRules>
    where
        F: FnMut(WalkEntry<'_>) -> WalkState,
    {
        struct SerialBridge<F> {
            ptr: *mut F,
        }

        unsafe impl<F> Sync for SerialBridge<F> {}

        let bridge = SerialBridge {
            ptr: &mut visitor as *mut F,
        };

        // Capture by shared reference so the closure captures the *whole*
        // SerialBridge (Sync via unsafe impl above)
        let bridge_ref = &bridge;
        self.run_inner(1, &move |e| {
            let f = unsafe { &mut *bridge_ref.ptr };
            f(e)
        })
    }

    fn run_inner<F>(&self, threads: u16, visitor: &F) -> Result<WalkerOutcomeRules>
    where
        F: Fn(WalkEntry<'_>) -> WalkState + Sync,
    {
        unsafe extern "C" fn zlob_callback<F>(
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

            match visitor(entry) {
                WalkState::Continue => 0,
                WalkState::SkipDir => 1,
                WalkState::Quit => 2,
            }
        }

        let (root, mut opts) = self.checked_options()?;
        opts.threads = threads;
        let mut raw_rules: *mut c_void = std::ptr::null_mut();
        let rc = unsafe {
            ffi::zlob_walk(
                root.as_ptr(),
                &opts,
                Some(zlob_callback::<F>),
                visitor as *const F as *mut c_void,
                &mut raw_rules,
            )
        };
        match rc {
            0 => Ok(WalkerOutcomeRules { raw: raw_rules }),
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

/// A reusable set of rules used by the walker to ignore files
#[derive(Clone, Copy)]
pub struct IgnoreRules<'a> {
    handle: *mut c_void,
    _marker: PhantomData<&'a ()>,
}

unsafe impl Send for IgnoreRules<'_> {}
unsafe impl Sync for IgnoreRules<'_> {}

impl IgnoreRules<'_> {
    /// Returns `true` if the provided path is ignored by the collected rule set
    /// Works at a `Path` so both absolute and relative paths are supported.
    ///
    /// Performs `lstat` internally, marks non-accessible/non-existent files as ignored
    ///
    /// `relative_path` has to be relative to the walker's provided base path
    pub fn is_ignored(&self, path: impl AsRef<Path>) -> bool {
        let Ok(cpath) = CString::new(path_to_bytes(path.as_ref())) else {
            return false; // an interior NUL can't match any real path
        };
        unsafe { ffi::zlob_ignore_rules_match_path(self.handle, cpath.as_ptr()) != 0 }
    }
}

/// Owned results of [`WalkBuilder::collect`]. Holds all paths and metadata in
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

    /// Reusable ignore rules (`.gitignore` + `.ignore` + custom rules matcher) gathered during
    /// the walk, for testing arbitrary paths afterwards. Always `Some` after a
    /// successful [`WalkBuilder::collect`] (empty when `GITIGNORE` was off or the
    /// tree had no ignore files).
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

/// The rules that were assembled during a previous walker run
pub struct WalkerOutcomeRules {
    raw: *mut c_void,
}

unsafe impl Send for WalkerOutcomeRules {}
unsafe impl Sync for WalkerOutcomeRules {}

impl WalkerOutcomeRules {
    /// Borrow the rules for querying. `None` when the walk gathered nothing
    /// (e.g. `WalkFlags::GITIGNORE` was off and no `extra_ignore` was set).
    pub fn rules(&self) -> Option<IgnoreRules<'_>> {
        if self.raw.is_null() {
            None
        } else {
            Some(IgnoreRules {
                handle: self.raw,
                _marker: PhantomData,
            })
        }
    }
}

impl Drop for WalkerOutcomeRules {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { ffi::zlob_ignore_rules_free(self.raw) };
            self.raw = std::ptr::null_mut();
        }
    }
}

impl std::fmt::Debug for WalkerOutcomeRules {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WalkRulesHandle").finish_non_exhaustive()
    }
}

/// A single walked entry
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
    pub fn relative_path(&self) -> &'a Path {
        bytes_to_path(&self.path_bytes()[self.raw.relative_offset as usize..])
    }

    /// Raw bytes of the path relative to the walk root.
    #[inline]
    pub fn relative_path_bytes(&self) -> &'a [u8] {
        &self.path_bytes()[self.raw.relative_offset as usize..]
    }

    /// If the item is kind of `WalkEntryKind::File` returns it's filename, otherwise None
    #[inline]
    pub fn basename(&self) -> Option<&'a str> {
        if !self.is_file() {
            return None;
        }

        std::str::from_utf8(&self.path_bytes()[self.raw.basename_offset as usize..]).ok()
    }

    /// Byte offset where the basename begins inside [`Self::relative_path_bytes`].
    #[inline]
    pub fn basename_offset_in_relative(&self) -> u16 {
        (self
            .raw
            .basename_offset
            .saturating_sub(self.raw.relative_offset)) as u16
    }

    /// Depth below the root — direct children of the root are at depth 1.
    #[inline]
    pub fn depth(&self) -> usize {
        self.raw.depth as usize
    }

    #[inline]
    pub fn worker_id(&self) -> usize {
        self.raw.worker_id as usize
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

    fn meta(&self, bit: WalkMetadata) -> bool {
        self.raw.meta_valid & bit.bits() != 0
    }

    /// File size in bytes (requires [`WalkMetadata::SIZE`]).
    pub fn size(&self) -> Option<u64> {
        self.meta(WalkMetadata::SIZE).then_some(self.raw.size)
    }

    /// Modification time, nanoseconds since the Unix epoch.
    pub fn modified_ns(&self) -> Option<i64> {
        self.meta(WalkMetadata::MTIME).then_some(self.raw.mtime_ns)
    }

    /// Access time, nanoseconds since the Unix epoch.
    pub fn accessed_ns(&self) -> Option<i64> {
        self.meta(WalkMetadata::ATIME).then_some(self.raw.atime_ns)
    }

    /// Status-change time, nanoseconds since the Unix epoch.
    pub fn changed_ns(&self) -> Option<i64> {
        self.meta(WalkMetadata::CTIME).then_some(self.raw.ctime_ns)
    }

    /// Creation (birth) time, nanoseconds since the Unix epoch.
    pub fn created_ns(&self) -> Option<i64> {
        self.meta(WalkMetadata::BTIME).then_some(self.raw.btime_ns)
    }

    pub fn inode(&self) -> Option<u64> {
        self.meta(WalkMetadata::INODE).then_some(self.raw.inode)
    }

    pub fn nlink(&self) -> Option<u32> {
        self.meta(WalkMetadata::NLINK).then_some(self.raw.nlink)
    }

    /// Permission bits (mode & 0o7777); the file type is in [`Self::kind`].
    pub fn mode(&self) -> Option<u32> {
        self.meta(WalkMetadata::MODE).then_some(self.raw.mode)
    }

    pub fn uid(&self) -> Option<u32> {
        self.meta(WalkMetadata::UID).then_some(self.raw.uid)
    }

    pub fn gid(&self) -> Option<u32> {
        self.meta(WalkMetadata::GID).then_some(self.raw.gid)
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
            .unwrap()
            .options(WalkFlags::RECOMMENDED | WalkFlags::SORT)
            .threads(1)
            .collect()
            .unwrap();

        let names: Vec<String> = results
            .iter()
            .map(|e| e.relative_path().to_string_lossy().into_owned())
            .collect();

        // hidden(.gitignore) skipped, target/ and *.log ignored
        assert_eq!(names, vec!["Cargo.toml", "src", "src/main.rs"]);
    }

    #[test]
    fn build_plain_walkdir_mode() {
        let dir = make_tree();
        let results = WalkBuilder::new(dir.path())
            .unwrap()
            .options(WalkFlags::SORT)
            .threads(1)
            .collect()
            .unwrap();

        let names: Vec<String> = results
            .iter()
            .map(|e| e.relative_path().to_string_lossy().into_owned())
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
            .find(|e| e.basename() == Some("main.rs"))
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
            .unwrap()
            .options(WalkFlags::empty())
            .threads(1)
            .metadata(WalkMetadata::SIZE | WalkMetadata::MTIME | WalkMetadata::INODE)
            .collect()
            .unwrap();

        let main_rs = results
            .iter()
            .find(|e| e.basename() == Some("main.rs"))
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
            .unwrap()
            .options(WalkFlags::empty())
            .run(|_entry| {
                count.fetch_add(1, Ordering::Relaxed);
                WalkState::Continue
            })
            .unwrap();
        assert_eq!(count.load(Ordering::Relaxed), 7);
    }

    #[test]
    fn run_returns_queryable_rules_handle() {
        // The streaming API now surfaces the retained ignore rules the same
        // way `collect()` does — same walk, same rule set.
        let dir = make_tree();
        let handle = WalkBuilder::new(dir.path())
            .unwrap()
            .run(|_| WalkState::Continue)
            .unwrap();
        let rules = handle.rules().expect("rules always present after a walk");
        // make_tree() creates target/ + debug.log, both gitignored. isIgnoredPath
        // lstats the on-disk paths.
        assert!(rules.is_ignored("target"));
        assert!(rules.is_ignored("debug.log"));
        assert!(!rules.is_ignored("Cargo.toml"));

        // Rules are usable after the walk returns — the handle owns storage
        // that lives until it drops (verified by the borrows above).
        drop(handle);
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
            .unwrap()
            .options(WalkFlags::empty())
            // Even with many threads configured, run_serial ignores it and
            // runs single-threaded, so this borrow is sound.
            .threads(8)
            .run_serial(|entry| {
                let _ = &not_sync;
                // basename() is file-only by design; this test wants the
                // leaf name of every entry (dirs included), so slice out of
                // the relative bytes directly.
                let rel = entry.relative_path_bytes();
                let leaf = &rel[entry.basename_offset_in_relative() as usize..];
                names.push(String::from_utf8_lossy(leaf).into_owned());
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
            .unwrap()
            .options(WalkFlags::empty())
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
            .unwrap()
            .options(WalkFlags::empty())
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
            .unwrap()
            .threads(1)
            .run(|_| {
                quit_count.fetch_add(1, Ordering::Relaxed);
                WalkState::Quit
            })
            .unwrap();
        assert_eq!(quit_count.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn worker_id_shards_without_locks() {
        // worker_id must always be below max_workers(), for both the
        // streaming and the collect paths, so per-worker shard arrays sized
        // by max_workers() can be indexed without bounds checks failing.
        let dir = make_tree();
        let builder = {
            let mut b = WalkBuilder::new(dir.path()).unwrap();
            b.options(WalkFlags::empty());
            b
        };
        let n = builder.max_workers();
        assert!(n >= 1);

        let seen = AtomicUsize::new(0);
        let shards: Vec<std::sync::Mutex<Vec<String>>> =
            (0..n).map(|_| Default::default()).collect();
        builder
            .run(|entry| {
                // panics via index OOB if the bound contract is broken
                shards[entry.worker_id()]
                    .lock()
                    .unwrap()
                    .push(entry.relative_path().to_string_lossy().into_owned());
                seen.fetch_add(1, Ordering::Relaxed);
                WalkState::Continue
            })
            .unwrap();
        assert_eq!(seen.load(Ordering::Relaxed), 7);

        // The sharded union equals the collected set: nothing lost, nothing
        // duplicated when accumulating per worker.
        let mut merged: Vec<String> = shards
            .into_iter()
            .flat_map(|s| s.into_inner().unwrap())
            .collect();
        merged.sort();
        let collected = builder.collect().unwrap();
        let mut expected: Vec<String> = collected
            .iter()
            .map(|e| e.relative_path().to_string_lossy().into_owned())
            .collect();
        expected.sort();
        assert_eq!(merged, expected);

        // collect() carries worker ids too, under the same bound.
        assert!(collected.iter().all(|e| e.worker_id() < n));
    }

    #[test]
    fn worker_id_is_zero_on_single_thread() {
        let dir = make_tree();
        let mut b = WalkBuilder::new(dir.path()).unwrap();
        b.options(WalkFlags::empty()).threads(1);
        assert_eq!(b.max_workers(), 1);
        b.run(|entry| {
            assert_eq!(entry.worker_id(), 0);
            WalkState::Continue
        })
        .unwrap();

        // run_serial always executes on the calling thread only.
        let mut b = WalkBuilder::new(dir.path()).unwrap();
        b.options(WalkFlags::empty()).threads(8);
        b.run_serial(|entry| {
            assert_eq!(entry.worker_id(), 0);
            WalkState::Continue
        })
        .unwrap();
    }

    #[test]
    fn max_workers_respects_explicit_threads() {
        let dir = make_tree();
        let mut b = WalkBuilder::new(dir.path()).unwrap();
        b.threads(3);
        assert_eq!(b.max_workers(), 3);
        b.threads(0);
        let auto = b.max_workers();
        assert!(auto >= 1);
    }

    #[test]
    fn max_depth_limits() {
        let dir = make_tree();
        let results = WalkBuilder::new(dir.path())
            .unwrap()
            .options(WalkFlags::empty())
            .threads(1)
            .max_depth(Some(1))
            .collect()
            .unwrap();
        assert_eq!(results.len(), 5);
        assert!(results.iter().all(|e| e.depth() == 1));
    }

    #[test]
    fn extra_ignore_un_ignores_via_negation() {
        // Project's .gitignore ignores every .rs file. The caller passes a
        // *negation* through extra_ignore to re-include `keep.rs` and the
        // entire `src/important/` subtree. This mirrors how a nested
        // .gitignore would override a shallower one.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir(root.join("src")).unwrap();
        fs::create_dir(root.join("src/important")).unwrap();
        fs::write(root.join(".gitignore"), "*.rs\n").unwrap();
        fs::write(root.join("keep.rs"), "fn k() {}").unwrap();
        fs::write(root.join("drop.rs"), "fn d() {}").unwrap();
        fs::write(root.join("src/main.rs"), "fn m() {}").unwrap();
        fs::write(root.join("src/lib.rs"), "fn l() {}").unwrap();
        fs::write(root.join("src/important/special.rs"), "fn s() {}").unwrap();
        fs::write(root.join("src/important/other.rs"), "fn o() {}").unwrap();

        let results = WalkBuilder::new(root)
            .unwrap()
            .options(WalkFlags::RECOMMENDED | WalkFlags::SORT)
            .threads(1)
            // - "!keep.rs" re-includes a single file at the root.
            // - "!src/important/**" re-includes a whole subtree.
            // - Both win because extra_ignore is checked before the project's
            //   "*.rs" rule (same precedence as a deeper nested .gitignore).
            .extra_ignore(&["!keep.rs", "!src/important/**"])
            .unwrap()
            .collect()
            .unwrap();

        let names: Vec<String> = results
            .iter()
            .map(|e| e.relative_path().to_string_lossy().into_owned())
            .collect();

        // Re-included by extra_ignore (negations win).
        assert!(
            names.contains(&"keep.rs".to_string()),
            "keep.rs should be re-included, got {names:?}"
        );
        assert!(
            names.iter().any(|n| n == "src/important/special.rs"),
            "src/important/special.rs should be re-included, got {names:?}"
        );
        assert!(
            names.iter().any(|n| n == "src/important/other.rs"),
            "src/important/other.rs should be re-included, got {names:?}"
        );

        // Dropped by the project's `*.rs` rule, NOT re-included.
        assert!(
            !names.contains(&"drop.rs".to_string()),
            "drop.rs should remain ignored, got {names:?}"
        );
        assert!(
            !names.iter().any(|n| n == "src/main.rs"),
            "src/main.rs should remain ignored, got {names:?}"
        );
        assert!(
            !names.iter().any(|n| n == "src/lib.rs"),
            "src/lib.rs should remain ignored, got {names:?}"
        );

        // The IgnoreRules surface mirrors what the walk applied — extra
        // patterns are checked there too, so external `is_ignored()` agrees.
        let rules = results.ignore_rules().expect("rules always present");
        assert!(!rules.is_ignored("keep.rs"));
        assert!(rules.is_ignored("drop.rs"));
        assert!(!rules.is_ignored("src/important/special.rs"));
        assert!(rules.is_ignored("src/main.rs"));
    }

    #[test]
    fn extra_ignore_adds_new_rules() {
        // No project .gitignore; extra_ignore alone supplies the ignore list.
        // Confirms many patterns batch into one matcher and surface in the
        // returned IgnoreRules.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir(root.join("node_modules")).unwrap();
        fs::create_dir(root.join("target")).unwrap();
        fs::write(root.join("node_modules/a.js"), "").unwrap();
        fs::write(root.join("target/out.o"), "").unwrap();
        fs::write(root.join("README.md"), "").unwrap();
        fs::write(root.join("main.rs"), "").unwrap();

        let results = WalkBuilder::new(root)
            .unwrap()
            .options(WalkFlags::empty()) // no gitignore-discovery, no hidden-skip
            .threads(1)
            .extra_ignore(&["node_modules", "/target"])
            .unwrap()
            .collect()
            .unwrap();

        let names: Vec<String> = results
            .iter()
            .map(|e| e.relative_path().to_string_lossy().into_owned())
            .collect();

        assert!(
            !names.iter().any(|n| n.starts_with("node_modules")),
            "node_modules subtree should be pruned, got {names:?}"
        );
        assert!(
            !names.iter().any(|n| n.starts_with("target")),
            "target/ subtree should be pruned at root, got {names:?}"
        );
        assert!(names.contains(&"README.md".to_string()));
        assert!(names.contains(&"main.rs".to_string()));

        let rules = results.ignore_rules().expect("rules always present");
        assert!(rules.is_ignored("node_modules/"));
        assert!(rules.is_ignored("target/"));
        assert!(!rules.is_ignored("main.rs"));
    }

    #[test]
    fn interior_nul_is_an_error_not_a_silent_default() {
        // A root with an interior NUL must fail at construction, not
        // silently walk the cwd.
        let err = WalkBuilder::new("bad\0root").unwrap_err();
        assert_eq!(err, ZlobError::InvalidInput);

        // A pattern with an interior NUL fails at `.include(...)` — same
        // shape as the root check, just on a different builder method.
        let dir = make_tree();
        let mut b = WalkBuilder::new(dir.path()).unwrap();
        let err = b.include("*.\0rs").unwrap_err();
        assert_eq!(err, ZlobError::InvalidInput);

        // Retrying with a valid pattern on the same builder works, since
        // the failed call didn't corrupt any state.
        let ok = WalkBuilder::new(dir.path())
            .unwrap()
            .include("**/*.rs")
            .unwrap()
            .collect();
        assert!(ok.is_ok());
    }

    #[test]
    fn empty_and_missing_roots() {
        let dir = tempfile::tempdir().unwrap();
        let results = WalkBuilder::new(dir.path()).unwrap().collect().unwrap();
        assert!(results.is_empty());

        // Missing roots are reported through the (unset) error callback and
        // produce an empty result unless abort_on_error is set.
        let missing = WalkBuilder::new("/definitely/not/a/real/path/zlob")
            .unwrap()
            .collect()
            .unwrap();
        assert!(missing.is_empty());

        let err = WalkBuilder::new("/definitely/not/a/real/path/zlob")
            .unwrap()
            .options(WalkFlags::RECOMMENDED | WalkFlags::ABORT_ON_ERROR)
            .collect();
        assert!(err.is_err());
    }

    #[test]
    fn is_ignored_accepts_windows_style_backslash_paths() {
        // The matcher normalizes '\\' → '/' on the way in so Windows callers
        // (who get native '\\'-separated paths from std::path) get the same
        // answers as Unix callers passing '/'.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::write(root.join(".gitignore"), "target/\n*.log\n").unwrap();
        fs::create_dir_all(root.join("target/foo")).unwrap();
        fs::write(root.join("target/foo/bar.rs"), "").unwrap();
        fs::create_dir_all(root.join("src/deeply/nested")).unwrap();
        fs::write(root.join("src/deeply/nested/scratch.log"), "").unwrap();
        fs::write(root.join("src/main.rs"), "").unwrap();

        let results = WalkBuilder::new(root)
            .unwrap()
            .threads(1)
            .collect()
            .unwrap();
        let rules = results.ignore_rules().expect("rules always present");

        // Same assertions as the ancestor-walk test but with '\\' separators.
        assert!(rules.is_ignored("target\\foo\\bar.rs"));
        assert!(rules.is_ignored("src\\deeply\\nested\\scratch.log"));
        assert!(!rules.is_ignored("src\\main.rs"));
        // Mixed separators — the leading '/' style should still work too.
        assert!(rules.is_ignored("target/foo\\bar.rs"));
    }

    #[test]
    fn is_ignored_walks_ancestors_for_unvisited_subtrees() {
        // The walker never enters `target/` because the root .gitignore prunes
        // it — so the by_dir HashMap has no node for `target/`, only for the
        // walk root. `is_ignored("target/foo/bar.rs")` still has to say yes,
        // by consulting the root's rule as the ancestor of that path.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir(root.join("src")).unwrap();
        fs::create_dir_all(root.join("target/foo")).unwrap();
        fs::create_dir_all(root.join("target/deeply/nested")).unwrap();
        fs::create_dir_all(root.join("src/deeply/nested")).unwrap();
        fs::write(root.join(".gitignore"), "target/\n*.log\n").unwrap();
        fs::write(root.join("src/main.rs"), "").unwrap();
        fs::write(root.join("src/lib.rs"), "").unwrap();
        fs::write(root.join("target/foo/bar.rs"), "").unwrap();
        fs::write(root.join("target/deeply/nested/thing.o"), "").unwrap();
        fs::write(root.join("src/deeply/nested/scratch.log"), "").unwrap();

        let results = WalkBuilder::new(root)
            .unwrap()
            .threads(1)
            .collect()
            .unwrap();
        let rules = results.ignore_rules().expect("rules always present");

        // Files under the pruned `target/` subtree — walker never opened the
        // dir, but the root's `target/` rule still catches every descendant.
        assert!(
            rules.is_ignored("target/foo/bar.rs"),
            "target/ at root should catch descendants even when target/ is pruned"
        );
        assert!(rules.is_ignored("target/deeply/nested/thing.o"));
        // File rule from the same root .gitignore, applied at arbitrary depth.
        assert!(rules.is_ignored("src/deeply/nested/scratch.log"));
        // Sanity: non-ignored path from a visited subtree.
        assert!(!rules.is_ignored("src/main.rs"));
        assert!(!rules.is_ignored("src/lib.rs"));
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
        // Materialize the paths we query so lstat can classify them.
        fs::write(root.join("app.log"), "").unwrap();
        fs::create_dir(root.join("build")).unwrap();
        fs::write(root.join("scratch.tmp"), "").unwrap();
        fs::write(root.join("important.tmp"), "").unwrap();
        fs::write(root.join("src/old.bak"), "").unwrap();
        fs::write(root.join("old.bak"), "").unwrap();

        let results = WalkBuilder::new(root)
            .unwrap()
            .threads(1)
            .collect()
            .unwrap();

        let rules = results.ignore_rules().expect("rules always present");

        // Root-level rules — lstat now supplies directory-ness.
        assert!(rules.is_ignored("app.log"));
        // "build" exists as a directory on disk; the dir-only `build/` rule fires.
        assert!(rules.is_ignored("build"));
        assert!(rules.is_ignored("scratch.tmp"));
        // .ignore precedence re-includes important.tmp.
        assert!(!rules.is_ignored("important.tmp"));
        // Nested rule only inside src/.
        assert!(rules.is_ignored("src/old.bak"));
        // A `*.bak` file at the *root* is not covered by the src/-scoped rule.
        assert!(!rules.is_ignored("old.bak"));
        assert!(!rules.is_ignored("src/main.rs"));

        // Non-existent paths surface as ignored per the new contract.
        assert!(rules.is_ignored("this-does-not-exist"));

        // Absolute-path queries work too, provided they're inside the walk.
        let abs = root.join("app.log");
        assert!(rules.is_ignored(abs.to_str().unwrap()));
        // Absolute path outside the walk → ignored (not part of this walk).
        assert!(rules.is_ignored("/etc/passwd"));
    }

    #[test]
    fn ignore_rules_always_available() {
        // Rules are now always returned (no opt-in flag). With git_ignore on,
        // the tree's rules are queryable.
        let dir = make_tree();
        let root = dir.path();
        let results = WalkBuilder::new(root).unwrap().collect().unwrap();
        let rules = results.ignore_rules().expect("rules always present");
        // make_tree() creates target/ (dir) and debug.log (file), both
        // gitignored. Query the paths as they exist on disk.
        assert!(rules.is_ignored("target"));
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
            .unwrap()
            .options(WalkFlags::empty())
            .collect();
        assert!(ok.is_ok());

        // With abort_on_error the permission error surfaces as its own variant
        // rather than collapsing into Aborted.
        let err = WalkBuilder::new(dir.path())
            .unwrap()
            .options(WalkFlags::ABORT_ON_ERROR)
            .threads(1)
            .collect()
            .unwrap_err();
        assert_eq!(err, ZlobError::PermissionDenied);
    }

    // Guards against drift between the Rust bitflags and the C header. The
    // walk/meta constants come from bindgen (real build only).
    #[cfg(not(docsrs))]
    #[test]
    fn flag_values_match_c_header() {
        assert_eq!(WalkFlags::GITIGNORE.bits(), ffi::ZLOB_WALK_GITIGNORE as u32);
        assert_eq!(
            WalkFlags::SKIP_HIDDEN.bits(),
            ffi::ZLOB_WALK_SKIP_HIDDEN as u32
        );
        assert_eq!(
            WalkFlags::FOLLOW_SYMLINKS.bits(),
            ffi::ZLOB_WALK_FOLLOW_SYMLINKS as u32
        );
        assert_eq!(
            WalkFlags::NO_REPORT_DIRS.bits(),
            ffi::ZLOB_WALK_NO_REPORT_DIRS as u32
        );
        assert_eq!(WalkFlags::SORT.bits(), ffi::ZLOB_WALK_SORT as u32);
        assert_eq!(
            WalkFlags::ABORT_ON_ERROR.bits(),
            ffi::ZLOB_WALK_ABORT_ON_ERROR as u32
        );
        assert_eq!(
            WalkFlags::KEEP_GIT_DIR.bits(),
            ffi::ZLOB_WALK_KEEP_GIT_DIR as u32
        );
        assert_eq!(
            WalkFlags::RECOMMENDED,
            WalkFlags::GITIGNORE | WalkFlags::SKIP_HIDDEN
        );

        assert_eq!(WalkMetadata::SIZE.bits(), ffi::ZLOB_META_SIZE as u32);
        assert_eq!(WalkMetadata::MTIME.bits(), ffi::ZLOB_META_MTIME as u32);
        assert_eq!(WalkMetadata::ATIME.bits(), ffi::ZLOB_META_ATIME as u32);
        assert_eq!(WalkMetadata::CTIME.bits(), ffi::ZLOB_META_CTIME as u32);
        assert_eq!(WalkMetadata::BTIME.bits(), ffi::ZLOB_META_BTIME as u32);
        assert_eq!(WalkMetadata::INODE.bits(), ffi::ZLOB_META_INODE as u32);
        assert_eq!(WalkMetadata::NLINK.bits(), ffi::ZLOB_META_NLINK as u32);
        assert_eq!(WalkMetadata::MODE.bits(), ffi::ZLOB_META_MODE as u32);
        assert_eq!(WalkMetadata::UID.bits(), ffi::ZLOB_META_UID as u32);
        assert_eq!(WalkMetadata::GID.bits(), ffi::ZLOB_META_GID as u32);
        assert_eq!(WalkMetadata::ALL.bits(), ffi::ZLOB_META_ALL as u32);
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
            .unwrap()
            .options(WalkFlags::SORT)
            .threads(1)
            .include("**/*.rs")
            .unwrap()
            .collect()
            .unwrap();

        let names: Vec<String> = results
            .iter()
            .map(|e| e.relative_path().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["src/lib.rs", "src/main.rs", "top.rs"]);

        // Brace pattern through the default flags.
        let braced = WalkBuilder::new(root)
            .unwrap()
            .options(WalkFlags::empty())
            .threads(1)
            .include("**/*.{md,rs}")
            .unwrap()
            .collect()
            .unwrap();
        assert_eq!(braced.len(), 4);

        // Anchored pattern narrows traversal to the src/ subtree.
        let scoped = WalkBuilder::new(root)
            .unwrap()
            .options(WalkFlags::empty())
            .threads(1)
            .include("src/**/*.rs")
            .unwrap()
            .collect()
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
            .unwrap()
            .include("**/*.rs")
            .unwrap()
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
