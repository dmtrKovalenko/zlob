//! # zlob
//!
//! High-performance glob pattern matching with SIMD optimizations.
//!
//! zlob is a Rust binding to the zlob library, which provides:
//! - POSIX-compatible glob pattern matching
//! - SIMD-optimized pattern matching for high performance
//! - Support for brace expansion (`{a,b,c}`)
//! - Tilde expansion (`~`, `~user`)
//! - `.gitignore` filtering
//! - Zero-copy path matching API
//!
//! For most use cases, use [`ZlobFlags::RECOMMENDED`]:
//!
//! ```no_run
//! use zlob::{zlob, ZlobFlags};
//!
//! // RECOMMENDED enables: brace expansion, recursive **, tilde expansion, no sorting
//! if let Some(result) = zlob("**/*.rs", ZlobFlags::RECOMMENDED)? {
//!     for path in &result {
//!         println!("{}", path);
//!     }
//! }
//! # Ok::<(), zlob::ZlobError>(())
//! ```
//!
//! ## Basic Usage
//!
//! ```no_run
//! use zlob::{zlob, ZlobFlags};
//!
//! if let Some(result) = zlob("**/*.rs", ZlobFlags::RECOMMENDED)? {
//!     for path in &result {
//!         println!("{}", path);
//!     }
//! }
//!
//! // Use brace expansion
//! if let Some(result) = zlob("src/{lib,main}.rs", ZlobFlags::BRACE)? {
//!     // Index access
//!     if !result.is_empty() {
//!         println!("First match: {}", &result[0]);
//!     }
//!
//!     // Convert to Vec<String>
//!     let paths: Vec<String> = result.to_strings();
//! }
//! # Ok::<(), zlob::ZlobError>(())
//! ```
//!
//! ## Path Matching (No Filesystem Access)
//!
//! For filtering a list of paths without filesystem access, use `zlob_match_paths`:
//!
//! ```
//! use zlob::{zlob_match_paths, ZlobFlags};
//!
//! let paths = ["src/lib.rs", "src/main.rs", "README.md"];
//! if let Some(matches) = zlob_match_paths("*.rs", &paths, ZlobFlags::empty())? {
//!     assert_eq!(matches.len(), 2);
//!     for path in &matches {
//!         println!("{}", path);
//!     }
//! }
//! # Ok::<(), zlob::ZlobError>(())
//! ```
//!
//! This is a zero-copy operation - the results reference the original input strings.
//!
//! ## Flags
//!
//! For most use cases, use [`ZlobFlags::RECOMMENDED`]:
//!
//! ```no_run
//! use zlob::{zlob, ZlobFlags};
//!
//! let result = zlob("**/*.rs", ZlobFlags::RECOMMENDED)?;
//!
//! // Add more flags as needed
//! let result = zlob("**/*.rs", ZlobFlags::RECOMMENDED | ZlobFlags::GITIGNORE)?;
//! # Ok::<(), zlob::ZlobError>(())
//! ```
//!
//! Control matching behavior with individual `ZlobFlags`:
//!
//! ```
//! use zlob::ZlobFlags;
//!
//! // Combine flags with bitwise OR
//! let flags = ZlobFlags::BRACE | ZlobFlags::DOUBLESTAR_RECURSIVE | ZlobFlags::PERIOD;
//!
//! // Common flags:
//! // - RECOMMENDED: Best defaults for typical usage (see above)
//! // - BRACE: Enable {a,b,c} expansion
//! // - DOUBLESTAR_RECURSIVE: Enable ** recursive directory matching
//! // - TILDE: Enable ~ home directory expansion
//! // - NOSORT: Don't sort results (faster)
//! // - PERIOD: Allow wildcards to match leading dots
//! // - GITIGNORE: Filter results with .gitignore rules
//! // - ONLYDIR: Match only directories
//! ```
//!
//! ## Supported Patterns
//!
//! We support all the varieties of glob pattern supported by rust's `glob` crate, posix `glob(3)`,
//! glibc `glob()` implementation and many more.
//!
//! Here are some of the most common patterns:
//!
//! | Pattern | Description |
//! |---------|-------------|
//! | `*` | Matches any string (including empty) |
//! | `?` | Matches any single character |
//! | `[abc]` | Matches one character from the set |
//! | `[!abc]` | Matches one character NOT in the set |
//! | `[a-z]` | Matches one character in the range |
//! | `**` | Matches zero or more path components (requires `DOUBLESTAR_RECURSIVE` or `RECOMMENDED`) |
//! | `{a,b}` | Matches alternatives (requires `BRACE` or `RECOMMENDED`) |
//! | `~` | Home directory (requires `TILDE` or `RECOMMENDED`) |
//! | `~user` | User's home directory (requires `TILDE` or `RECOMMENDED`) |
//!
//! **Note:** By default (for glibc compatibility), `**` is treated as `*`, and braces are not
//! supported
//! Use `ZlobFlags::DOUBLESTAR_RECURSIVE` or `ZlobFlags::RECOMMENDED` for recursive matching.
//!
//! ## Error Handling
//!
//! Operations return `Result<Option<_>, ZlobError>`:
//! - `Ok(Some(result))` - matches found
//! - `Ok(None)` - no matches (not an error)
//! - `Err(ZlobError)` - actual error (out of memory, aborted, etc.)
//!
//! ```no_run
//! use zlob::{zlob, ZlobFlags, ZlobError};
//!
//! match zlob("**/*.rs", ZlobFlags::RECOMMENDED) {
//!     Ok(Some(result)) => println!("Found {} files", result.len()),
//!     Ok(None) => println!("No files matched"),
//!     Err(ZlobError::Aborted) => println!("Operation aborted"),
//!     Err(ZlobError::NoSpace) => println!("Out of memory"),
//! }
//! ```

mod error;
mod flags;
mod match_paths;
mod zlob;

// Raw FFI bindings generated from include/zlob.h by bindgen
#[allow(non_upper_case_globals)]
#[allow(non_camel_case_types)]
#[allow(non_snake_case)]
#[allow(dead_code)]
#[allow(clippy::all)]
mod ffi {
    include!(concat!(env!("OUT_DIR"), "/zlob_bindings.rs"));

    impl Default for zlob_t {
        fn default() -> Self {
            Self {
                zlo_pathc: 0,
                zlo_pathv: std::ptr::null_mut(),
                zlo_offs: 0,
                zlo_pathlen: std::ptr::null_mut(),
                zlo_flags: 0,
                zlo_opendir: None,
                zlo_readdir: None,
                zlo_closedir: None,
            }
        }
    }

    // Safety: zlob_t is safe to send across threads
    unsafe impl Send for zlob_t {}
}

pub use error::*;
pub use flags::*;
pub use match_paths::*;
pub use zlob::*;
