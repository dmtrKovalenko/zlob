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
 * For FFI check out zlob_slice_t and *_slice versions of functions for a more
 * efficinet strings & seamless length-aware string outputs without `strlen`s.
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
  size_t zlo_pathc;    /* Count of matched paths */
  char **zlo_pathv;    /* Array of matched path strings (NULL-terminated) */
  size_t zlo_offs;     /* Number of NULL entries to reserve at beginning of
                          zlo_pathv */
  size_t *zlo_pathlen; /* Array of path lengths (zlob extension for efficient
                          FFI) */
  int zlo_flags;       /* Internal flags */

  /* ALTDIRFUNC: Custom directory access functions (GNU extension)
   * Set these before calling zlob() with ZLOB_ALTDIRFUNC flag */
  void *(*zlo_opendir)(
      const char *path); /* Returns opaque dir handle, NULL on error */
  zlob_dirent_t *(*zlo_readdir)(
      void *dir);                  /* Returns next entry, NULL when done */
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
#define ZLOB_GITIGNORE (1 << 24) /* Filter results using .gitignore from cwd   \
                                  */
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
 * Find pathnames matching a glob pattern.
 *
 * Caller must zlobfree() `pzlob` after a successful call to release the
 * allocated path strings and pathv array.
 *
 * @return 0 on success, or one of ZLOB_NOSPACE, ZLOB_ABORTED, ZLOB_NOMATCH.
 *
 * Supported patterns:
 *   *              Matches any string, including the null string
 *   ?              Matches any single character
 *   [abc]          Matches one character from the set
 *   [!abc]         Matches one character NOT in the set
 *   [a-z]          Matches one character in the range
 *   **             Matches zero or more path components (recursive)
 *   {a,b,c}        Comma-separated alternatives (with ZLOB_BRACE)
 *   ~ / ~/path     Home directory expansion (with ZLOB_TILDE)
 *   ~user/path     Other user's home directory (with ZLOB_TILDE)
 */
int zlob(const char *restrict pattern, int flags,
         int (*errfunc)(const char *epath, int eerrno), zlob_t *restrict pzlob);

/**
 * Free memory allocated by zlob().
 *
 * Safe to call on an already-freed or zero-initialized zlob_t.
 */
void zlobfree(zlob_t *pzlob);

/**
 * Same as `zlob` but interpreted relative to `base_path`.
 *
 * Matched paths in `pzlob->pathv` are relative to `base_path`. Returns
 * ZLOB_ABORTED if `base_path` is not absolute.
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

/** Same as `zlob_match_paths` but accepts string slices as input. */
int zlob_match_paths_slice(const zlob_slice_t *pattern,
                           const zlob_slice_t *paths, size_t path_count,
                           int flags, zlob_t *pzlob);

/**
 * Filter `paths` with a glob pattern (zero-copy).
 *
 * Result pointers in `pzlob->pathv` point directly into the caller's
 * original `paths` memory — no string copies are made. The caller must
 * keep `paths` alive until zlobfree() is called.
 */
int zlob_match_paths(const char *pattern, const char *const *paths,
                     size_t path_count, int flags, zlob_t *pzlob);

/**
 * Same as `zlob_match_paths` but matches against `paths` relative to
 * `base_path`. A leading "./" in `pattern` is treated as relative to
 * `base_path` (and stripped).
 */
int zlob_match_paths_at(const char *base_path, const char *pattern,
                        const char *const *paths, size_t path_count, int flags,
                        zlob_t *pzlob);

/** Same as `zlob_match_paths_at` but accepts string slices as input. */
int zlob_match_paths_at_slice(const zlob_slice_t *base_path,
                               const zlob_slice_t *pattern,
                               const zlob_slice_t *paths, size_t path_count,
                               int flags, zlob_t *pzlob);

/**
 * Check whether a string contains glob wildcard syntax handled by a set of flags
 */
int zlob_has_wildcards(const char *pattern, int flags);

/** zlob_pattern_t - Preanalyzed glob pattern */
typedef struct zlob_pattern zlob_pattern_t;

/**
 * zlob_indices_t - result of zlob_match_paths_indices*() functions
 * which returns indicies of the matched paths in the original provided array.
 */
typedef struct {
  size_t *indices;
  size_t count;
} zlob_indices_t;

/** Free indices array allocated by zlob_match_paths_indices*(). */
void zlob_indices_free(zlob_indices_t *out);

/**
 * Compile a glob pattern for reuse.
 *
 * @param pattern  Null-terminated glob pattern string. Copied internally —
 *                 the caller may free `pattern` immediately after this call.
 * @param flags    ZLOB_* flags. Structural bits (BRACE/DOUBLESTAR_RECURSIVE/
 *                 EXTGLOB) are baked in.
 *
 * @return         Pointer to a freshly-allocated zlob_pattern_t, or NULL on
 *                 out-of-memory.
 */
zlob_pattern_t *zlob_pattern_compile(const char *pattern, int flags);

/**
 * Compile a glob pattern from a slice.
 *
 * Same as zlob_pattern_compile but accepts a `zlob_slice_t` (ptr + len)
 * instead of a null-terminated string. Useful for FFI from languages like
 * Rust where strings are not null-terminated.
 */
zlob_pattern_t *zlob_pattern_compile_slice(const zlob_slice_t *pattern,
                                           int flags);

/**
 * Free memory allocated by zlob_pattern_compile*().
 *
 * Safe to call with NULL. After calling, the pointer must not be used.
 */
void zlob_pattern_free(zlob_pattern_t *p);

/**
 * Zero-allocation a single path match against a compiled pattern.
 *
 * @param p          Compiled pattern.
 * @param path       Path to test (does NOT need to be null-terminated).
 * @param path_len   Length of `path` in bytes.
 * @param flags      ZLOB_* flags. Must agree with compile-time flags on
 *                   the structural bits (BRACE/DOUBLESTAR_RECURSIVE/EXTGLOB);
 *                   debug builds assert this.
 *
 * @return           1 if the path matches, 0 otherwise.
 */
int zlob_pattern_matches(const zlob_pattern_t *p, const char *path,
                         size_t path_len, int flags);

/**
 * Filter `paths` and return matching indices into the input array.
 *
 * Same matching semantics as zlob_match_paths but returns indices rather
 * than path strings — useful for FFI hot paths that want to avoid
 * string-pointer round trips.
 *
 * Indices are always in input order regardless of ZLOB_NOSORT.
 * ZLOB_NOCHECK is silently ignored.
 *
 * Use zlob_indices_free() to clean up the result.
 *
 * @return 0 on success (with matches), ZLOB_NOMATCH if no matches,
 *         ZLOB_NOSPACE on OOM.
 */
int zlob_match_paths_indices(const char *pattern, const char *const *paths,
                             size_t path_count, int flags, zlob_indices_t *out);

/** Same as `zlob_match_paths_indices` but accepts string slice as an input */
int zlob_match_paths_indices_slice(const zlob_slice_t *pattern,
                                   const zlob_slice_t *paths, size_t path_count,
                                   int flags, zlob_indices_t *out);

/** Same as `zlob_match_paths_indices` but accepts base_path parameter. */
int zlob_match_paths_indices_at(const char *base_path, const char *pattern,
                                const char *const *paths, size_t path_count,
                                int flags, zlob_indices_t *out);

/** Same as `zlob_match_paths_indices_at` but accepts string slices as input. */
int zlob_match_paths_indices_at_slice(const zlob_slice_t *base_path,
                                      const zlob_slice_t *pattern,
                                      const zlob_slice_t *paths,
                                      size_t path_count, int flags,
                                      zlob_indices_t *out);

/** Same as `zlob_match_paths_slice` but reuses a pre-compiled pattern. */
int zlob_pattern_match_paths_slice(const zlob_pattern_t *p,
                                   const zlob_slice_t *paths,
                                   size_t path_count, int flags,
                                   zlob_t *out);

/** Same as `zlob_pattern_match_paths_slice` but accepts base_path parameter. */
int zlob_pattern_match_paths_at_slice(const zlob_pattern_t *p,
                                      const zlob_slice_t *base_path,
                                      const zlob_slice_t *paths,
                                      size_t path_count, int flags,
                                      zlob_t *out);

/** Same as `zlob_pattern_match_paths_slice` but returns matching indices. */
int zlob_pattern_match_paths_indices_slice(const zlob_pattern_t *p,
                                           const zlob_slice_t *paths,
                                           size_t path_count, int flags,
                                           zlob_indices_t *out);

/** Same as `zlob_pattern_match_paths_indices_slice` but accepts base_path parameter. */
int zlob_pattern_match_paths_indices_at_slice(const zlob_pattern_t *p,
                                              const zlob_slice_t *base_path,
                                              const zlob_slice_t *paths,
                                              size_t path_count, int flags,
                                              zlob_indices_t *out);

#ifdef __cplusplus
}
#endif

#endif /* ZLOB_H */
