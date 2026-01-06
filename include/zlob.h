/**
 * zlob.h - POSIX-compatible glob pattern matching library
 *
 * This is a C-compatible interface to the zlob (Z Glob) library,
 * which provides high-performance file pattern matching with SIMD optimizations.
 *
 * Usage:
 *   #include <zlob.h>
 *
 *   glob_t pglob;
 *   int result = glob("*.txt", 0, NULL, &pglob);
 *   if (result == 0) {
 *       for (size_t i = 0; i < pglob.gl_pathc; i++) {
 *           printf("%s (len=%zu)\n", pglob.gl_pathv[i], pglob.gl_pathlen[i]);
 *       }
 *       globfree(&pglob);
 *   }
 *
 * The gl_pathlen field provides O(1) access to path lengths, which is useful
 * for FFI with languages like Rust where you can create string slices without
 * calling strlen():
 *   // Rust example:
 *   let path_str = std::str::from_utf8_unchecked(
 *       std::slice::from_raw_parts(pglob.gl_pathv[i] as *const u8, pglob.gl_pathlen[i])
 *   );
 */

#ifndef ZLOB_H
#define ZLOB_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

/**
 * glob_t - Result structure for glob pattern matching
 *
 * This structure contains the results of a glob() call.
 * The gl_pathlen field is a zlob extension for efficient FFI - it provides
 * O(1) access to path lengths without needing strlen() calls.
 */
typedef struct {
    size_t gl_pathc;      /* Count of matched paths */
    char **gl_pathv;      /* Array of matched path strings (NULL-terminated) */
    size_t gl_offs;       /* Number of NULL entries to reserve at beginning of gl_pathv */
    size_t *gl_pathlen;   /* Array of path lengths (zlob extension for efficient FFI) */
    int _reserved;        /* Internal use only - do not access */
} glob_t;

/* POSIX glob flags */
#define GLOB_ERR        (1 << 0)  /* 0x0001 - Return on read errors */
#define GLOB_MARK       (1 << 1)  /* 0x0002 - Append a slash to each directory name */
#define GLOB_NOSORT     (1 << 2)  /* 0x0004 - Don't sort the names */
#define GLOB_DOOFFS     (1 << 3)  /* 0x0008 - Insert PGLOB->gl_offs NULLs at beginning */
#define GLOB_NOCHECK    (1 << 4)  /* 0x0010 - If nothing matches, return the pattern itself */
#define GLOB_APPEND     (1 << 5)  /* 0x0020 - Append to results of a previous call */
#define GLOB_NOESCAPE   (1 << 6)  /* 0x0040 - Backslashes don't quote metacharacters */
#define GLOB_PERIOD     (1 << 7)  /* 0x0080 - Leading `.` can be matched by metachars */

/* GNU extensions */
#define GLOB_MAGCHAR    (1 << 8)  /* 0x0100 - Set in gl_flags if any metachars seen (OUTPUT only) */
#define GLOB_ALTDIRFUNC (1 << 9)  /* 0x0200 - Use gl_opendir et al functions (NOT IMPLEMENTED) */
#define GLOB_BRACE      (1 << 10) /* 0x0400 - Expand "{a,b}" to "a" "b" */
#define GLOB_NOMAGIC    (1 << 11) /* 0x0800 - If no magic chars, return the pattern */
#define GLOB_TILDE      (1 << 12) /* 0x1000 - Expand ~user and ~ to home directories */
#define GLOB_ONLYDIR    (1 << 13) /* 0x2000 - Match only directories */
#define GLOB_TILDE_CHECK (1 << 14) /* 0x4000 - Like GLOB_TILDE but return error if user name not available */

/* Error codes returned by glob() */
#define GLOB_NOSPACE    1  /* Out of memory */
#define GLOB_ABORTED    2  /* Read error or other system error */
#define GLOB_NOMATCH    3  /* No matches found */

/**
 * glob - Find pathnames matching a pattern (POSIX-compliant)
 *
 * @param pattern   The glob pattern to match (e.g., "*.txt", "src/test_*.c")
 * @param flags     Bitwise OR of GLOB_* flags
 * @param errfunc   Error callback function: int (*errfunc)(const char *epath, int eerrno)
 *                  Called when a directory read error occurs. If it returns non-zero
 *                  or GLOB_ERR is set, glob() will abort and return GLOB_ABORTED.
 *                  Pass NULL to ignore errors and continue matching.
 * @param pglob     Pointer to glob_t structure to receive results
 *
 * @return 0 on success, or one of GLOB_NOSPACE, GLOB_ABORTED, GLOB_NOMATCH
 *
 * Supported patterns:
 *   *              Matches any string, including the null string
 *   ?              Matches any single character
 *   [abc]          Matches one character from the set
 *   [!abc]         Matches one character NOT in the set
 *   [a-z]          Matches one character in the range
 *   **             Matches zero or more path components (recursive)
 *   {a,b,c}        Matches any of the comma-separated alternatives (with GLOB_BRACE)
 *   ~              Expands to home directory (with GLOB_TILDE)
 *   ~/path         Expands to $HOME/path (with GLOB_TILDE)
 *   ~user/path     Expands to user's home directory (with GLOB_TILDE)
 *
 * Examples:
 *   "*.txt"          All .txt files in current directory
 *   "src/test_*.c"   All test_*.c files in src directory
 *   "file?.txt"      file1.txt, file2.txt, etc.
 *   "{foo,bar}*"     All files starting with foo or bar (with GLOB_BRACE)
 *   "~/.config"      User's .config directory (with GLOB_TILDE)
 *
 * Memory Management:
 *   After successful glob() call, you MUST call globfree() to release memory.
 *   The strings in gl_pathv and the gl_pathv array itself are allocated by glob()
 *   and must be freed by globfree().
 */
int glob(const char *restrict pattern, int flags,
         int (*errfunc)(const char *epath, int eerrno),
         glob_t *restrict pglob);

/**
 * globfree - Free memory allocated by glob()
 *
 * @param pglob  Pointer to glob_t structure to free
 *
 * This function frees all memory allocated by a previous glob() call,
 * including the path strings and the gl_pathv array.
 * After calling globfree(), the glob_t structure is reset to initial state.
 *
 * It is safe to call globfree() on a glob_t that has already been freed,
 * or on an uninitialized glob_t with gl_pathv set to NULL.
 *
 * NOTE: This function automatically detects whether it's freeing results from
 * glob() or glob_match_paths_*() and handles them correctly. You can safely
 * use this for all glob_t structures.
 */
void globfree(glob_t *pglob);

/* ============================================================================
 * Path Matching API (no filesystem access)
 * ============================================================================ */

/**
 * zlob_slice_t - FFI-compatible slice representation
 *
 * This structure matches Rust's &str and Zig's []const u8 memory layout,
 * allowing zero-copy string passing across language boundaries.
 */
typedef struct {
    const unsigned char *ptr;
    size_t len;
} zlob_slice_t;

/**
 * glob_match_paths_slice - Filter paths with glob pattern (zero-copy, slice version)
 *
 * @param pattern       Pointer to zlob_slice_t containing the pattern
 * @param paths         Array of zlob_slice_t (one per path)
 * @param path_count    Number of paths in the array
 * @param flags         Bitwise OR of GLOB_* flags
 * @param pglob         Pointer to glob_t structure to receive results
 * @return 0 on success, GLOB_NOMATCH if no matches, GLOB_NOSPACE on OOM
 *
 * This function filters an array of paths using a glob pattern WITHOUT copying
 * the path strings. The result pointers in pglob->gl_pathv point directly to
 * the caller's original memory.
 *
 * IMPORTANT:
 * - Caller must keep the original paths alive until glob_match_paths_free() is called
 * - Use glob_match_paths_free(), NOT globfree(), to clean up results
 *
 * Rust example:
 *   let paths = vec!["foo.txt", "bar.c", "baz.txt"];
 *   let path_slices: Vec<_> = paths.iter().map(|s| zlob_slice_t {
 *       ptr: s.as_ptr(), len: s.len()
 *   }).collect();
 *   let pattern = zlob_slice_t { ptr: b"*.txt".as_ptr() as *const u8, len: 5 };
 *   let mut pglob: glob_t = unsafe { std::mem::zeroed() };
 *   let result = glob_match_paths_slice(&pattern, path_slices.as_ptr(), paths.len(), 0, &mut pglob);
 *   if result == 0 {
 *       for i in 0..pglob.gl_pathc {
 *           let path = unsafe { std::slice::from_raw_parts(
 *               pglob.gl_pathv.add(i).read() as *const u8, pglob.gl_pathlen.add(i).read()
 *           )};
 *           println!("{}", std::str::from_utf8(path).unwrap());
 *       }
 *       globfree(&mut pglob);
 *   }
 */
int glob_match_paths_slice(
    const zlob_slice_t *pattern,
    const zlob_slice_t *paths,
    size_t path_count,
    int flags,
    glob_t *pglob
);

/**
 * glob_match_paths - Filter paths with glob pattern (zero-copy, C string version)
 *
 * @param pattern       Null-terminated pattern string
 * @param paths         Array of null-terminated path strings
 * @param path_count    Number of paths in the array
 * @param flags         Bitwise OR of GLOB_* flags
 * @param pglob         Pointer to glob_t structure to receive results
 * @return 0 on success, GLOB_NOMATCH if no matches, GLOB_NOSPACE on OOM
 *
 * This function filters an array of paths using a glob pattern WITHOUT copying
 * the path strings. The result pointers in pglob->gl_pathv point directly to
 * the caller's original memory.
 *
 * IMPORTANT:
 * - Caller must keep the original paths alive until glob_match_paths_free() is called
 * - Use glob_match_paths_free(), NOT globfree(), to clean up results
 *
 * C example:
 *   const char *paths[] = {"foo.txt", "bar.c", "baz.txt"};
 *   glob_t pglob;
 *   int result = glob_match_paths("*.txt", paths, 3, 0, &pglob);
 *   if (result == 0) {
 *       for (size_t i = 0; i < pglob.gl_pathc; i++) {
 *           printf("%s (len=%zu)\n", pglob.gl_pathv[i], pglob.gl_pathlen[i]);
 *       }
 *       glob_match_paths_free(&pglob);  // NOT globfree()!
 *   }
 */
int glob_match_paths(
    const char *pattern,
    const char *const *paths,
    size_t path_count,
    int flags,
    glob_t *pglob
);

#ifdef __cplusplus
}
#endif

#endif /* ZLOB_H */
