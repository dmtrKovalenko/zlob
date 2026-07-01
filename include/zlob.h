/**
 * zlob.h - High-performance glob pattern matching library
 *
 * A C-compatible interface to the zlob (Z Glob) library: SIMD-accelerated
 * file pattern matching plus a parallel directory walker.
 *
 * Usage:
 *   #include <zlob.h>
 *
 *   zlob_t pzlob;
 *   int result = zlob("*.txt", 0, NULL, &pzlob);
 *   if (result == 0) {
 *       for (size_t i = 0; i < pzlob.zlo_pathc; i++) {
 *           printf("%s (len=%zu)\n", pzlob.zlo_pathv[i], pzlob.zlo_pathlen[i]);
 *       }
 *       zlobfree(&pzlob);
 *   }
 *
 * For FFI, prefer zlob_slice_t and the *_slice function variants: they pass
 * length-aware strings across language boundaries with no copies and no
 * strlen() round-trips.
 */

#ifndef ZLOB_H
#define ZLOB_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

/**
 * zlob_dirent_t - Directory entry for ALTDIRFUNC callbacks
 *
 * Used with readdir when ZLOB_ALTDIRFUNC is set.
 */
typedef struct {
  const char *d_name;   /* Null-terminated entry name */
  unsigned char d_type; /* Entry type: DT_DIR=4, DT_REG=8, DT_LNK=10, DT_UNKNOWN=0 */
} zlob_dirent_t;

/* Directory entry types for zlob_dirent_t.d_type */
#define ZLOB_DT_UNKNOWN 0
#define ZLOB_DT_DIR     4
#define ZLOB_DT_REG     8
#define ZLOB_DT_LNK     10

/**
 * zlob_t - Result structure for glob pattern matching
 *
 * Holds the results of a zlob() call. `zlo_pathlen` is a zlob extension: it
 * gives O(1) access to each path's length, so FFI consumers never need a
 * strlen() pass over the results.
 *
 * ALTDIRFUNC support (GNU extension): when the ZLOB_ALTDIRFUNC flag is set,
 * the zlo_opendir/zlo_readdir/zlo_closedir function pointers are used instead
 * of the standard filesystem calls, allowing globbing over virtual
 * filesystems or custom data sources.
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
  void *(*zlo_opendir)(const char *path);   /* Returns opaque dir handle, NULL on error */
  zlob_dirent_t *(*zlo_readdir)(void *dir); /* Returns next entry, NULL when done */
  void (*zlo_closedir)(void *dir);          /* Closes directory handle */
} zlob_t;

/* POSIX glob flags */
#define ZLOB_ERR                  (1 << 0) /* 0x0001 - Return on read errors */
#define ZLOB_MARK                 (1 << 1) /* 0x0002 - Append a slash to each directory name */
#define ZLOB_NOSORT               (1 << 2) /* 0x0004 - Don't sort the names */
#define ZLOB_DOOFFS               (1 << 3) /* 0x0008 - Insert PZLOB->offs NULLs at beginning */
#define ZLOB_NOCHECK              (1 << 4) /* 0x0010 - If nothing matches, return the pattern */
#define ZLOB_APPEND               (1 << 5) /* 0x0020 - Append to results of a previous call */
#define ZLOB_NOESCAPE             (1 << 6) /* 0x0040 - Backslashes don't quote metacharacters */
#define ZLOB_PERIOD               (1 << 7) /* 0x0080 - Leading `.` can be matched by metachars */
#define ZLOB_MAGCHAR              (1 << 8) /* 0x0100 - Set if any metachars seen (OUTPUT only) */

/* GNU extensions */
#define ZLOB_ALTDIRFUNC           (1 << 9)  /* 0x0200 - Use opendir/readdir/closedir funcs */
#define ZLOB_BRACE                (1 << 10) /* 0x0400 - Expand "{a,b}" to "a" "b" */
#define ZLOB_NOMAGIC              (1 << 11) /* 0x0800 - If no magic chars, return the pattern */
#define ZLOB_TILDE                (1 << 12) /* 0x1000 - Expand ~user and ~ to home dirs */
#define ZLOB_ONLYDIR              (1 << 13) /* 0x2000 - Match only directories */
#define ZLOB_TILDE_CHECK          (1 << 14) /* 0x4000 - Like ZLOB_TILDE but error if no user */

/* ============================================================================
 * zlob extensions (bits 24+)
 * NOTE: Bits 15-23 are reserved for potential future glibc extensions.
 * glibc currently uses bits 0-14. We leave a 9-bit gap to avoid conflicts.
 * ============================================================================
 */
#define ZLOB_GITIGNORE            (1 << 24) /* Filter results using .gitignore from cwd */
#define ZLOB_DOUBLESTAR_RECURSIVE (1 << 25) /* Enable ** recursive directory matching */
#define ZLOB_EXTGLOB              (1 << 26) /* Extended globs: ?(p) *(p) +(p) @(p) !(p) */
/* Descend into symlinked dirs when recursing with **. Default off (matches
 * bash globstar/zsh/walkdir; symlinks still match by name, recursion stops at
 * them). A (dev,ino) visited-set breaks cycles, so each physical dir is walked
 * once — never loops, never double-emits a file. */
#define ZLOB_FOLLOW_SYMLINKS      (1 << 27)

/* Recommended modern defaults for globbing:
 * - BRACE: Brace expansion {a,b,c}
 * - DOUBLESTAR_RECURSIVE: Recursive ** patterns
 * - NOSORT: Skip sorting for performance
 * - TILDE: Home directory expansion ~
 * - TILDE_CHECK: Error if ~user not found
 */
#define ZLOB_RECOMMENDED                                                                           \
  (ZLOB_BRACE | ZLOB_DOUBLESTAR_RECURSIVE | ZLOB_NOSORT | ZLOB_TILDE | ZLOB_TILDE_CHECK)

/* Error codes returned by zlob() */
#define ZLOB_NOSPACE           1 /* Out of memory */
#define ZLOB_ABORTED           2 /* Operation aborted (visitor/errfunc requested stop) */
#define ZLOB_NOMATCH           3 /* No matches found */
#define ZLOB_READ_FAILED       4 /* A directory read failed */
#define ZLOB_PERMISSION_DENIED 5 /* A directory could not be opened/read */
#define ZLOB_NAME_TOO_LONG     6 /* A path component exceeded NAME_MAX */

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
int zlob(const char *restrict pattern, int flags, int (*errfunc)(const char *epath, int eerrno),
         zlob_t *restrict pzlob);

/**
 * Free memory allocated by zlob().
 *
 * Safe to call on an already-freed or zero-initialized zlob_t.
 */
void zlobfree(zlob_t *pzlob);

/**
 * Same as `zlob` but interpreted relative to `base_path`.
 *
 * Matched paths in `pzlob->zlo_pathv` are relative to `base_path`. Returns
 * ZLOB_ABORTED if `base_path` is not absolute.
 */
int zlob_at(const char *base_path, const char *restrict pattern, int flags,
            int (*errfunc)(const char *epath, int eerrno), zlob_t *restrict pzlob);

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
int zlob_match_paths_slice(const zlob_slice_t *pattern, const zlob_slice_t *paths,
                           size_t path_count, int flags, zlob_t *pzlob);

/**
 * Filter `paths` with a glob pattern (zero-copy).
 *
 * Result pointers in `pzlob->zlo_pathv` point directly into the caller's
 * original `paths` memory — no string copies are made. The caller must
 * keep `paths` alive until zlobfree() is called.
 */
int zlob_match_paths(const char *pattern, const char *const *paths, size_t path_count, int flags,
                     zlob_t *pzlob);

/**
 * Same as `zlob_match_paths` but matches against `paths` relative to
 * `base_path`. A leading "./" in `pattern` is treated as relative to
 * `base_path` (and stripped).
 */
int zlob_match_paths_at(const char *base_path, const char *pattern, const char *const *paths,
                        size_t path_count, int flags, zlob_t *pzlob);

/** Same as `zlob_match_paths_at` but accepts string slices as input. */
int zlob_match_paths_at_slice(const zlob_slice_t *base_path, const zlob_slice_t *pattern,
                              const zlob_slice_t *paths, size_t path_count, int flags,
                              zlob_t *pzlob);

/**
 * Check whether a string contains glob wildcard syntax handled by a set of
 * flags
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
zlob_pattern_t *zlob_pattern_compile_slice(const zlob_slice_t *pattern, int flags);

/**
 * Free memory allocated by zlob_pattern_compile*().
 *
 * Safe to call with NULL. After calling, the pointer must not be used.
 */
void zlob_pattern_free(zlob_pattern_t *p);

/**
 * Test a single path against a compiled pattern (zero allocation).
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
int zlob_pattern_matches(const zlob_pattern_t *p, const char *path, size_t path_len, int flags);

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
int zlob_match_paths_indices(const char *pattern, const char *const *paths, size_t path_count,
                             int flags, zlob_indices_t *out);

/** Same as `zlob_match_paths_indices` but accepts string slice as an input */
int zlob_match_paths_indices_slice(const zlob_slice_t *pattern, const zlob_slice_t *paths,
                                   size_t path_count, int flags, zlob_indices_t *out);

/** Same as `zlob_match_paths_indices` but accepts base_path parameter. */
int zlob_match_paths_indices_at(const char *base_path, const char *pattern,
                                const char *const *paths, size_t path_count, int flags,
                                zlob_indices_t *out);

/** Same as `zlob_match_paths_indices_at` but accepts string slices as input. */
int zlob_match_paths_indices_at_slice(const zlob_slice_t *base_path, const zlob_slice_t *pattern,
                                      const zlob_slice_t *paths, size_t path_count, int flags,
                                      zlob_indices_t *out);

/** Same as `zlob_match_paths_slice` but reuses a pre-compiled pattern. */
int zlob_pattern_match_paths_slice(const zlob_pattern_t *p, const zlob_slice_t *paths,
                                   size_t path_count, int flags, zlob_t *out);

/** Same as `zlob_pattern_match_paths_slice` but accepts base_path parameter. */
int zlob_pattern_match_paths_at_slice(const zlob_pattern_t *p, const zlob_slice_t *base_path,
                                      const zlob_slice_t *paths, size_t path_count, int flags,
                                      zlob_t *out);

/** Same as `zlob_pattern_match_paths_slice` but returns matching indices. */
int zlob_pattern_match_paths_indices_slice(const zlob_pattern_t *p, const zlob_slice_t *paths,
                                           size_t path_count, int flags, zlob_indices_t *out);

/** Same as `zlob_pattern_match_paths_indices_slice` but accepts base_path
 * parameter. */
int zlob_pattern_match_paths_indices_at_slice(const zlob_pattern_t *p,
                                              const zlob_slice_t *base_path,
                                              const zlob_slice_t *paths, size_t path_count,
                                              int flags, zlob_indices_t *out);

/* ==========================================================================
 * Parallel recursive file walker (replacement for walkdir / the ignore crate)
 *
 * Directory trees are traversed by a pool of worker threads. Metadata is
 * fetched in bulk where the OS allows it (getattrlistbulk on macOS, statx on
 * Linux) and only the attributes requested in `meta_mask` are paid for.
 * .gitignore handling supports nested files and runs in parallel.
 * ========================================================================== */

/** Metadata attribute bits for zlob_walk_options_t.meta_mask and
 *  zlob_walk_entry_t.meta_valid. */
#define ZLOB_META_SIZE            (1u << 0)
#define ZLOB_META_MTIME           (1u << 1)
#define ZLOB_META_ATIME           (1u << 2)
#define ZLOB_META_CTIME           (1u << 3)
#define ZLOB_META_BTIME           (1u << 4) /* creation time (not on all filesystems) */
#define ZLOB_META_INODE           (1u << 5)
#define ZLOB_META_NLINK           (1u << 6)
#define ZLOB_META_MODE            (1u << 7) /* permission bits (mode & 07777) */
#define ZLOB_META_UID             (1u << 8)
#define ZLOB_META_GID             (1u << 9)
#define ZLOB_META_ALL             0x3FFu /* every attribute above (bits 0-9) */

/* Walk behavior flags (zlob_walk_options_t.flags). All-zero options give a
 * plain walkdir-style traversal: hidden files included, .gitignore not
 * consulted, directories reported. */
#define ZLOB_WALK_GITIGNORE       (1u << 0) /* honor (nested) .gitignore + .ignore; also skips .git */
#define ZLOB_WALK_SKIP_HIDDEN     (1u << 1) /* skip dotfiles and don't descend into dot-dirs */
#define ZLOB_WALK_FOLLOW_SYMLINKS (1u << 2)
#define ZLOB_WALK_NO_REPORT_DIRS  (1u << 3) /* yield only non-directory entries */
#define ZLOB_WALK_SORT            (1u << 4) /* sort zlob_walk_collect() results by path */
#define ZLOB_WALK_ABORT_ON_ERROR  (1u << 5)
#define ZLOB_WALK_KEEP_GIT_DIR    (1u << 6) /* with GITIGNORE: still enter .git dirs */

/** Entry kinds. */
#define ZLOB_WALK_KIND_UNKNOWN    0
#define ZLOB_WALK_KIND_FILE       1
#define ZLOB_WALK_KIND_DIR        2
#define ZLOB_WALK_KIND_SYMLINK    3

/** Error callback: return non-zero to abort the walk. */
typedef int (*zlob_walk_errfunc_t)(const char *epath, int eerrno);

typedef struct zlob_walk_options {
  uint32_t flags;              /* ZLOB_WALK_* bits */
  uint32_t meta_mask;          /* ZLOB_META_* bits to fetch per entry */
  uint16_t threads;            /* worker threads; 0 = one per CPU, 1 = caller thread */
  uint16_t max_depth;          /* 0 = unlimited; 1 = direct children only */
  zlob_walk_errfunc_t errfunc; /* optional, may be NULL */
  /* Optional glob filter (NULL = report everything). Only entries whose
   * root-relative path matches are reported, and directories outside the
   * pattern's literal prefix (e.g. everything but src/ for "src/" followed by
   * a recursive double-star) are pruned from traversal entirely. Matched
   * lock-free on workers. */
  const char *pattern;
  /* ZLOB_* flags used to compile/match `pattern`.
   * 0 = default (ZLOB_BRACE | ZLOB_DOUBLESTAR_RECURSIVE). */
  uint32_t pattern_flags;
  /* Caller-supplied .gitignore document layered into the walker, one rule
   * per line, NUL-terminated. NULL = disabled. Surfaces as the *deepest*
   * node in the gitignore chain, so its `!negation` rules win over project
   * `.gitignore` (e.g. "node_modules\n!**\/README.md" prunes node_modules
   * everywhere except README.md files). Reported via the returned
   * IgnoreRules. */
  const char *extra_ignore;
} zlob_walk_options_t;

typedef struct zlob_walk_entry {
  const char *path;         /* full path (root joined with relative), NUL-terminated */
  size_t path_len;          /* strlen(path) */
  uint32_t relative_offset; /* path + relative_offset = path relative to the walk root */
  uint32_t basename_offset; /* path + basename_offset = entry name */
  uint8_t kind;             /* ZLOB_WALK_KIND_* */
  uint16_t depth;           /* root children have depth 1 */
  uint32_t meta_valid;      /* which ZLOB_META_* fields below are filled */
  uint64_t size;            /* file size in bytes */
  int64_t mtime_ns;         /* modification time, nanoseconds since the epoch */
  int64_t atime_ns;         /* access time, nanoseconds since the epoch */
  int64_t ctime_ns;         /* status-change time, nanoseconds since the epoch */
  int64_t btime_ns;         /* creation (birth) time, nanoseconds since the epoch */
  uint64_t inode;           /* inode number */
  uint32_t nlink;           /* hard-link count */
  uint32_t mode;            /* permission bits only; file type is in `kind` */
  uint32_t uid;             /* owner user id */
  uint32_t gid;             /* owner group id */
} zlob_walk_entry_t;

/** Visitor: return 0 to continue, 1 to skip this directory (not descend),
 *  2 to stop the whole walk.
 *
 *  With threads != 1 the callback is invoked CONCURRENTLY from multiple
 *  worker threads and must be thread-safe. The entry and its strings are
 *  only valid for the duration of the call.
 */
typedef int (*zlob_walk_cb)(const zlob_walk_entry_t *entry, void *ctx);

/**
 * Walking the file tree and calling the callback per every entry
 * respecting the options and metadata settings. Starts from the root path.
 *
 * When finished walking writes the inferred ignore rules ot the out_rules ptr
 */
int zlob_walk(const char *root, const zlob_walk_options_t *options, zlob_walk_cb cb, void *ctx,
              void **out_rules);

/** Free the allocated ignore rules set, NUL is noop */
void zlob_ignore_rules_free(void *rules);

typedef struct zlob_walk_result {
  zlob_walk_entry_t *entries;
  size_t count;
  void *_storage; /* internal — do not touch */
} zlob_walk_result_t;

/** Walks `root` and writes all entries to the memory, this is not streaming
 * -- this endpoint writes all the walk results one time in the very end. */
int zlob_walk_collect(const char *root, const zlob_walk_options_t *options,
                      zlob_walk_result_t *out);

void zlob_walk_result_free(zlob_walk_result_t *result);

/** Borrowed handle to the reusable ignore rules (.gitignore + .ignore, nested)
 *  gathered during the walk. Always available after a successful
 *  zlob_walk_collect() */
void *zlob_walk_result_ignore_rules(const zlob_walk_result_t *result);

/** Returns nonzero when `path` (root-relative) is ignored by the ignore rules
 *  the walker assembled, this includes every discovered `.gitignore`/`.ignore` plus
 *  any patterns passed via `extra_ignore`.
 *
 *  Zero on "not ignored", a NULL `rules` handle, or not-accessible `path`.
 *  Performs `lstat` internally.
 */
int zlob_ignore_rules_match_path(void *rules, const char *path);

#ifdef __cplusplus
}
#endif

#endif /* ZLOB_H */
