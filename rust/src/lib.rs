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
//! ## Basic Usage
//!
//! ```no_run
//! use zlob::{zlob, ZlobFlags};
//!
//! // Find all Rust files recursively
//! if let Some(result) = zlob("**/*.rs", ZlobFlags::empty())? {
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
//! Control matching behavior with `ZlobFlags`:
//!
//! ```
//! use zlob::ZlobFlags;
//!
//! // Combine flags with bitwise OR
//! let flags = ZlobFlags::BRACE | ZlobFlags::NOSORT | ZlobFlags::PERIOD;
//!
//! // Common flags:
//! // - BRACE: Enable {a,b,c} expansion
//! // - TILDE: Enable ~ home directory expansion
//! // - NOSORT: Don't sort results (faster)
//! // - PERIOD: Allow wildcards to match leading dots
//! // - GITIGNORE: Filter results with .gitignore rules
//! // - ONLYDIR: Match only directories
//! ```
//!
//! ## Supported Patterns
//!
//! | Pattern | Description |
//! |---------|-------------|
//! | `*` | Matches any string (including empty) |
//! | `?` | Matches any single character |
//! | `[abc]` | Matches one character from the set |
//! | `[!abc]` | Matches one character NOT in the set |
//! | `[a-z]` | Matches one character in the range |
//! | `**` | Matches zero or more path components (recursive) |
//! | `{a,b}` | Matches alternatives (requires `BRACE` flag) |
//! | `~` | Home directory (requires `TILDE` flag) |
//! | `~user` | User's home directory (requires `TILDE` flag) |
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
//! match zlob("**/*.rs", ZlobFlags::empty()) {
//!     Ok(Some(result)) => println!("Found {} files", result.len()),
//!     Ok(None) => println!("No files matched"),
//!     Err(ZlobError::Aborted) => println!("Operation aborted"),
//!     Err(ZlobError::NoSpace) => println!("Out of memory"),
//! }
//! ```

mod error;
mod ffi;
mod flags;
mod match_paths;
mod zlob;

pub use error::ZlobError;
pub use flags::ZlobFlags;
pub use match_paths::{zlob_match_paths, ZlobMatch, ZlobMatchIter};
pub use zlob::{zlob, Zlob, ZlobIter};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_public_api() {
        // Test that all public items are accessible
        let _flags = ZlobFlags::BRACE | ZlobFlags::NOSORT;
        let _err = ZlobError::Aborted;
    }
}
