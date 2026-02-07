/**
 * zlob.h - High-performance glob pattern matching library
 *
 * This is a C-compatible interface to the zlob (Z Glob) library,
 * which provides high-performance file pattern matching with SIMD
 * optimizations.
 *
 * Usage:
 *   #include <zlob.h>
 *
 *   zlob_t pzlob;
 *   int result = zlob("*.txt", 0, NULL, &pzlob);
 *   if (result == 0) {
 *       for (size_t i = 0; i < pzlob.pathc; i++) {
 *           printf("%s (len=%zu)\n", pzlob.pathv[i], pzlob.pathlen[i]);
 *       }
 *       zlobfree(&pzlob);
 *   }
 *
 * There is an additional pathlen field provides O(1) access to path
 * lengths, which is useful for FFI with languages like Rust where you can
 * create string slices without calling strlen():
 */

#ifndef ZLOB_H
#define ZLOB_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

/**
 * zlob_dirent_t - Directory entry for ALTDIRFUNC callbacks
 *
 * Used with readdir when ZLOB_ALTDIRFUNC is set.
 */
typedef struct {
  const char *d_name; /* Null-terminated entry name */
  unsigned char
      d_type; /* Entry type: DT_DIR=4, DT_REG=8, DT_LNK=10, DT_UNKNOWN=0 */
} zlob_dirent_t;

/* Directory entry types for zlob_dirent_t.d_type */
#define ZLOB_DT_UNKNOWN 0
#define ZLOB_DT_DIR 4
#define ZLOB_DT_REG 8
#define ZLOB_DT_LNK 10

/**
 * zlob_t - Result structure for glob pattern matching
 *
 * This structure contains the results of a glob() call.
 * The pathlen field is a zlob extension for efficient FFI - it provides
 * O(1) access to path lengths without needing strlen() calls.
 *
 * ALTDIRFUNC Support (GNU extension):
 *   When ZLOB_ALTDIRFUNC flag is set, the opendir, readdir, and
 * closedir function pointers are used instead of the standard filesystem
 * functions. This allows globbing over virtual filesystems or custom data
 * sources.
 */
typedef struct {
  size_t zlo_pathc; /* Count of matched paths */
  char **zlo_pathv; /* Array of matched path strings (NULL-terminated) */
  size_t zlo_offs; /* Number of NULL entries to reserve at beginning of zlo_pathv */
  size_t * zlo_pathlen; /* Array of path lengths (zlob extension for efficient FFI) */
  int zlo_flags;   /* Internal flags */

  /* ALTDIRFUNC: Custom directory access functions (GNU extension)
   * Set these before calling zlob() with ZLOB_ALTDIRFUNC flag */
  void *(*zlo_opendir)(
      const char *path); /* Returns opaque dir handle, NULL on error */
  zlob_dirent_t *(*zlo_readdir)(
      void *dir);                 /* Returns next entry, NULL when done */
  void (*zlo_closedir)(void *dir); /* Closes directory handle */
} zlob_t;

/* POSIX glob flags */
#define ZLOB_ERR (1 << 0) /* 0x0001 - Return on read errors */
#define ZLOB_MARK                                                              \
  (1 << 1)                   /* 0x0002 - Append a slash to each directory name \
                              */
#define ZLOB_NOSORT (1 << 2) /* 0x0004 - Don't sort the names */
#define ZLOB_DOOFFS                                                            \
  (1 << 3) /* 0x0008 - Insert PZLOB->offs NULLs at beginning */
#define ZLOB_NOCHECK                                                           \
  (1 << 4) /* 0x0010 - If nothing matches, return the pattern itself */
#define ZLOB_APPEND                                                            \
  (1 << 5) /* 0x0020 - Append to results of a previous call                    \
            */
#define ZLOB_NOESCAPE                                                          \
  (1 << 6) /* 0x0040 - Backslashes don't quote metacharacters */
#define ZLOB_PERIOD                                                            \
  (1 << 7) /* 0x0080 - Leading `.` can be matched by metachars */
#define ZLOB_MAGCHAR                                                           \
  (1 << 8) /* 0x0100 - Set zlob() if any metachars seen (OUTPUT only) */

/* GNU extensions */
#define ZLOB_ALTDIRFUNC                                                        \
  (1 << 9) /* 0x0200 - Use opendir/readdir/closedir functions */
#define ZLOB_BRACE (1 << 10) /* 0x0400 - Expand "{a,b}" to "a" "b" */
#define ZLOB_NOMAGIC                                                           \
  (1 << 11) /* 0x0800 - If no magic chars, return the pattern */
#define ZLOB_TILDE                                                             \
  (1 << 12) /* 0x1000 - Expand ~user and ~ to home directories */
#define ZLOB_ONLYDIR (1 << 13) /* 0x2000 - Match only directories */
#define ZLOB_TILDE_CHECK                                                       \
  (1 << 14) /* 0x4000 - Like ZLOB_TILDE but return error if user name not      \
               available */

/* ============================================================================
 * zlob extensions (bits 24+)
 * NOTE: Bits 15-23 are reserved for potential future glibc extensions.
 * glibc currently uses bits 0-14. We leave a 9-bit gap to avoid conflicts.
 * ============================================================================
 */
#define ZLOB_GITIGNORE (1 << 24) /* Filter results using .gitignore from cwd */
#define ZLOB_DOUBLESTAR_RECURSIVE                                              \
  (1 << 25) /* Enable ** recursive directory matching */
#define ZLOB_EXTGLOB                                                           \
  (1 << 26) /* Enable extended glob patterns: ?(pat) *(pat) +(pat) @(pat)      \
               !(pat) */

/* Recommended modern defaults for globbing:
 * - BRACE: Brace expansion {a,b,c}
 * - DOUBLESTAR_RECURSIVE: Recursive ** patterns
 * - NOSORT: Skip sorting for performance
 * - TILDE: Home directory expansion ~
 * - TILDE_CHECK: Error if ~user not found
 */
#define ZLOB_RECOMMENDED                                                       \
  (ZLOB_BRACE | ZLOB_DOUBLESTAR_RECURSIVE | ZLOB_NOSORT | ZLOB_TILDE |         \
   ZLOB_TILDE_CHECK)

/* Error codes returned by glob() */
#define ZLOB_NOSPACE 1 /* Out of memory */
#define ZLOB_ABORTED 2 /* Read error or other system error */
#define ZLOB_NOMATCH 3 /* No matches found */

/**
 * zlob - Find pathnames matching a pattern
 *
 * @return 0 on success, or one of ZLOB_NOSPACE, ZLOB_ABORTED, ZLOB_NOMATCH
 *
 * Supported patterns:
 *   *              Matches any string, including the null string
 *   ?              Matches any single character
 *   [abc]          Matches one character from the set
 *   [!abc]         Matches one character NOT in the set
 *   [a-z]          Matches one character in the range
 *   **             Matches zero or more path components (recursive)
 *   {a,b,c}        Matches any of the comma-separated alternatives (with
 * ZLOB_BRACE) ~              Expands to home directory (with ZLOB_TILDE)
 *   ~/path         Expands to $HOME/path (with ZLOB_TILDE)
 *   ~user/path     Expands to user's home directory (with ZLOB_TILDE)
 *
 * Examples:
 *   "*.txt"          All .txt files in current directory
 *   "src/test_*.c"   All test_*.c files in src directory
 *   "file?.txt"      file1.txt, file2.txt, etc.
 *   "{foo,bar}*"     All files starting with foo or bar (with ZLOB_BRACE)
 *   "~/.config"      User's .config directory (with ZLOB_TILDE)
 *
 * Memory Management:
 *   After successful zlob() call, you MUST call zlobfree() to release memory.
 *   The strings in pathv and the pathv array itself are allocated by
 * zlob() and must be freed by zlobfree().
 */
int zlob(const char *restrict pattern, int flags,
         int (*errfunc)(const char *epath, int eerrno), zlob_t *restrict pzlob);

/**
 * zlobfree - Free memory allocated by zlob()
 *
 * @param pzlob  Pointer to zlob_t structure to free
 *
 * This function frees all memory allocated by a previous zlob() call,
 * including the path strings and the pathv array.
 * After calling zlobfree(), the zlob_t structure is reset to initial state.
 *
 * It is safe to call zlobfree() on a zlob_t that has already been freed,
 * or on an uninitialized zlob_t with pathv set to NULL.
 */
void zlobfree(zlob_t *pzlob);

/**
 * zlob_at - Find pathnames matching a pattern relative to a base directory
 *
 * This function is similar to zlob() but operates relative to the specified
 * base_path instead of the current working directory. The matched paths in
 * pzlob->pathv will be relative to base_path.
 *
 * @return 0 on success, or one of ZLOB_NOSPACE, ZLOB_ABORTED, ZLOB_NOMATCH
 *
 * Returns ZLOB_ABORTED if base_path is not an absolute path.
 *
 * Example:
 *   zlob_t pzlob;
 *   int result = zlob_at("/home/user/project", "src/*.c", ZLOB_BRACE, NULL,
 * &pzlob); if (result == 0) { for (size_t i = 0; i < pzlob.pathc; i++) {
 *           // Paths are relative to /home/user/project
 *           printf("%s\n", pzlob.pathv[i]);
 *       }
 *       zlobfree(&pzlob);
 *   }
 */
int zlob_at(const char *base_path, const char *restrict pattern, int flags,
            int (*errfunc)(const char *epath, int eerrno),
            zlob_t *restrict pzlob);


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
 * zlob_match_paths_slice - Filter paths with glob pattern (zero-copy, slice
 * version)
 *
 * This function filters an array of paths using a glob pattern WITHOUT copying
 * the path strings. The result pointers in pzlob->pathv point directly to
 * the caller's original memory.
 *
 * IMPORTANT:
 * - Caller must keep the original paths alive until globfree() is called
 * - Use globfree() to clean up results
 */
int zlob_match_paths_slice(const zlob_slice_t *pattern,
                           const zlob_slice_t *paths, size_t path_count,
                           int flags, zlob_t *pzlob);

/**
 * zlob_match_paths - Filter paths with glob pattern (zero-copy, C string
 * version)
 *
 * This function filters an array of paths using a glob pattern WITHOUT copying
 * the path strings. The result pointers in pzlob->pathv point directly to
 * the caller's original memory.
 *
 * IMPORTANT:
 * - Caller must keep the original paths alive until globfree() is called
 * - Use globfree() to clean up results
 */
int zlob_match_paths(const char *pattern, const char *const *paths,
                     size_t path_count, int flags, zlob_t *pzlob);

/**
 * zlob_match_paths_at - Filter paths with glob pattern relative to a base
 * directory (zero-copy, C string version)
 *
 * @return 0 on success, ZLOB_NOMATCH if no matches, ZLOB_NOSPACE on OOM
 *
 * This function filters an array of absolute paths using a glob pattern
 * relative to a base directory, WITHOUT copying the path strings. The result
 * pointers in pzlob->pathv point directly to the caller's original memory.
 *
 * If the pattern starts with "./", it is treated as relative to base_path
 * (the prefix is stripped).
 *
 * Example:
 *   const char *paths[] = {
 *       "/home/user/project/src/main.c",
 *       "/home/user/project/lib/utils.c",
 *       "/home/user/project/docs/readme.md",
 *   };
 *   zlob_t pzlob;
 *   int result = zlob_match_paths_at("/home/user/project", "src/*.c",
 *       paths, 3, 0, &pzlob);
 *
 * IMPORTANT:
 * - Caller must keep the original paths alive until zlobfree() is called
 * - Use zlobfree() to clean up results
 */
int zlob_match_paths_at(const char *base_path, const char *pattern,
                        const char *const *paths, size_t path_count, int flags,
                        zlob_t *pzlob);

/**
 * zlob_match_paths_at_slice - Filter paths with glob pattern relative to a
 * base directory (zero-copy, slice version)
 *
 * Same as zlob_match_paths_at but using slice types for zero-copy FFI with
 * languages like Rust and Zig.
 *
 * IMPORTANT:
 * - Caller must keep the original paths alive until zlobfree() is called
 * - Use zlobfree() to clean up results
 */
int zlob_match_paths_at_slice(const zlob_slice_t *base_path,
                               const zlob_slice_t *pattern,
                               const zlob_slice_t *paths, size_t path_count,
                               int flags, zlob_t *pzlob);

/**
 * zlob_has_wildcards - Check if a string contains glob pattern syntax
 *
 * Detects glob metacharacters in a single SIMD-accelerated pass:
 * - Basic wildcards: *, ?, [
 * - Brace expansion syntax: { (only if ZLOB_BRACE flag is set)
 * - Extended glob patterns: ?(, *(, +(, @(, !( (only if ZLOB_EXTGLOB flag is set)
 *
 * This is useful for determining whether a string should be treated as a
 * glob pattern or as a literal file path. For example, a file manager could
 * use this to decide whether to call zlob() or just stat() the path directly.
 *
 * Example:
 *   if (zlob_has_wildcards("*.txt", 0)) {
 *       // Use zlob() for pattern matching
 *   } else {
 *       // Treat as literal path
 *   }
 *
 *   // With brace expansion enabled
 *   if (zlob_has_wildcards("{a,b}.txt", ZLOB_BRACE)) {
 *       // Detected brace pattern
 *   }
 */
int zlob_has_wildcards(const char *pattern, int flags);

#ifdef __cplusplus
}
#endif

#endif /* ZLOB_H */
