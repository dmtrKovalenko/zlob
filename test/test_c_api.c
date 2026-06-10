#include "zlob.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <sys/stat.h>

static int zlob_test_count_cb(const zlob_walk_entry_t *e, void *ctx) {
  (void)e;
  size_t *n = (size_t *)ctx;
  (*n)++;
  return 0;
}

#define TEST(name) printf("  [TEST] %s\n", name)
#define PASS() printf("    ✓ PASS\n")
#define FAIL(msg)                                                              \
  do {                                                                         \
    printf("    ✗ FAIL: %s\n", msg);                                           \
    return 1;                                                                  \
  } while (0)

int main(void) {

  // zlob() - Filesystem walking
  printf("zlob() - Filesystem Walking\n");
  TEST("Match *.zig files in src/");
  {
    zlob_t pzlob;
    int result = zlob("src/*.zig", 0, NULL, &pzlob);

    if (result != 0 && result != ZLOB_NOMATCH) {
      FAIL("zlob() returned error");
    }

    if (result == 0) {
      printf("    Found %zu matches\n", pzlob.zlo_pathc);

      // Verify results structure
      if (pzlob.zlo_pathc == 0)
        FAIL("Expected at least one match");
      if (pzlob.zlo_pathv == NULL)
        FAIL("pathv is NULL");
      if (pzlob.zlo_pathlen == NULL)
        FAIL("pathlen is NULL");

      // Verify first result
      if (pzlob.zlo_pathv[0] == NULL)
        FAIL("First path is NULL");
      size_t len = strlen(pzlob.zlo_pathv[0]);
      if (len != pzlob.zlo_pathlen[0])
        FAIL("pathlen doesn't match strlen");

      // Verify NULL terminator
      if (pzlob.zlo_pathv[pzlob.zlo_pathc] != NULL)
        FAIL("Array not NULL-terminated");

      printf("    Example: %s (len=%zu)\n", pzlob.zlo_pathv[0],
             pzlob.zlo_pathlen[0]);
      zlobfree(&pzlob);
      PASS();
    } else {
      printf("    No matches (ZLOB_NOMATCH)\n");
      PASS();
    }
  }

  // zlob() with recursive pattern
  printf("\nglob() - Recursive Pattern\n");
  TEST("Match **/*.zig files");
  {
    zlob_t pzlob;
    int result = zlob("src/**/*.zig", 0, NULL, &pzlob);

    if (result == 0) {
      printf("    Found %zu matches\n", pzlob.zlo_pathc);
      if (pzlob.zlo_pathc > 0) {
        printf("    Example: %s\n", pzlob.zlo_pathv[0]);
      }
      zlobfree(&pzlob);
      PASS();
    } else if (result == ZLOB_NOMATCH) {
      printf("    No matches (ZLOB_NOMATCH)\n");
      PASS();
    } else {
      FAIL("zlob() returned error");
    }
  }

  printf("\nzlob_at() - Filesystem Walking Relative to Base Directory\n");
  TEST("Match relative patterns from absolute base path");
  {
    char src_base[4096];
    char repo_root[4096];

    if (realpath("src", src_base) == NULL)
      FAIL("realpath(src) failed");
    if (realpath(".", repo_root) == NULL)
      FAIL("realpath(.) failed");

    zlob_t pzlob;
    int result = zlob_at(src_base, "*.zig", 0, NULL, &pzlob);

    if (result != 0)
      FAIL("zlob_at() failed for *.zig");
    if (pzlob.zlo_pathc == 0)
      FAIL("Expected at least one match for *.zig");

    int found_walker = 0;
    int found_flags = 0;
    for (size_t i = 0; i < pzlob.zlo_pathc; i++) {
      if (strcmp(pzlob.zlo_pathv[i], "walker.zig") == 0)
        found_walker = 1;
      if (strcmp(pzlob.zlo_pathv[i], "flags.zig") == 0)
        found_flags = 1;
    }
    if (!found_walker || !found_flags)
      FAIL("Expected relative matches walker.zig and flags.zig");

    zlobfree(&pzlob);

    result = zlob_at(repo_root, "src/*.zig", 0, NULL, &pzlob);
    if (result != 0)
      FAIL("zlob_at() failed for src/*.zig");

    found_walker = 0;
    found_flags = 0;
    for (size_t i = 0; i < pzlob.zlo_pathc; i++) {
      if (strcmp(pzlob.zlo_pathv[i], "src/walker.zig") == 0)
        found_walker = 1;
      if (strcmp(pzlob.zlo_pathv[i], "src/flags.zig") == 0)
        found_flags = 1;
    }
    if (!found_walker || !found_flags)
      FAIL("Expected relative matches src/walker.zig and src/flags.zig");

    zlobfree(&pzlob);
    PASS();
  }

  // zlob_match_paths() - Path filtering (no filesystem)
  printf("\nzlob_match_paths() - Path Filtering\n");
  TEST("Filter paths with *.c pattern");
  {
    const char *paths[] = {
        "src/main.c", "src/utils.c", "src/tests/test.h",
        "readme.md",  "src/lib.c",
    };
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    int result = zlob_match_paths("**/*.c", paths, path_count, ZLOB_RECOMMENDED, &pzlob);

    if (result != 0)
      FAIL("zlob_match_paths() failed");
    if (pzlob.zlo_pathc != 3)
      FAIL("Expected 3 matches");
    if (pzlob.zlo_pathv == NULL)
      FAIL("pathv is NULL");
    if (pzlob.zlo_pathlen == NULL)
      FAIL("pathlen is NULL");

    printf("    Found %zu matches (expected 3)\n", pzlob.zlo_pathc);

    // Verify zero-copy: pointers should reference original array
    int found_original = 0;
    for (size_t i = 0; i < pzlob.zlo_pathc; i++) {
      for (size_t j = 0; j < path_count; j++) {
        if (pzlob.zlo_pathv[i] == paths[j]) {
          found_original++;
          break;
        }
      }
    }
    if (found_original != 3)
      FAIL("Zero-copy failed: pointers don't reference original memory");

    zlobfree(&pzlob);
    PASS();
  }

  // zlob_match_paths() with no matches
  printf("\nzlob_match_paths() - No Matches\n");
  TEST("Filter paths with *.xyz pattern (no matches)");
  {
    const char *paths[] = {"main.c", "test.h", "readme.md"};
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    int result = zlob_match_paths("*.xyz", paths, path_count, 0, &pzlob);

    if (result != ZLOB_NOMATCH)
      FAIL("Expected ZLOB_NOMATCH");
    printf("    Correctly returned ZLOB_NOMATCH\n");
    PASS();
  }

  // zlob_match_paths() with recursive pattern
  printf("\nzlob_match_paths() - Recursive Pattern\n");
  TEST("Filter paths with **/*.c pattern");
  {
    const char *paths[] = {
        "src/main.c",
        "src/test/unit.c",
        "lib/utils.c",
        "docs/readme.md",
    };
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    int result = zlob_match_paths("**/*.c", paths, path_count, 0, &pzlob);

    if (result != 0)
      FAIL("zlob_match_paths() failed");
    if (pzlob.zlo_pathc != 3)
      FAIL("Expected 3 matches");

    printf("    Found %zu matches (expected 3)\n", pzlob.zlo_pathc);
    for (size_t i = 0; i < pzlob.zlo_pathc; i++) {
      printf("      - %s (len=%zu)\n", pzlob.zlo_pathv[i],
             pzlob.zlo_pathlen[i]);
    }

    zlobfree(&pzlob);
    PASS();
  }

  printf("\npathlen Field\n");
  TEST("Verify pathlen provides O(1) length access");
  {
    const char *paths[] = {"short.c", "medium_name.c", "very_long_filename.c"};
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    int result = zlob_match_paths("*.c", paths, path_count, 0, &pzlob);

    if (result != 0)
      FAIL("zlob_match_paths() failed");

    // Verify lengths match strlen
    for (size_t i = 0; i < pzlob.zlo_pathc; i++) {
      size_t actual_len = strlen(pzlob.zlo_pathv[i]);
      if (pzlob.zlo_pathlen[i] != actual_len) {
        printf("    Path %zu: pathlen=%zu, strlen=%zu\n", i,
               pzlob.zlo_pathlen[i], actual_len);
        FAIL("pathlen doesn't match strlen");
      }
    }

    printf("    All lengths correct (avoiding strlen overhead)\n");
    zlobfree(&pzlob);
    PASS();
  }

  TEST("Braced patterns");
  {
    const char *paths[] = {"short.c", "long.c", "other.c"};
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    // Note: no space after comma in brace pattern
    int result = zlob_match_paths("{short,long}.c", paths, path_count,
                                  ZLOB_BRACE, &pzlob);

    if (result != 0)
      FAIL("zlob_match_paths() failed");

    if (pzlob.zlo_pathc != 2)
      FAIL("Expected 2 matches");

    printf("    All lengths correct (avoiding strlen overhead)\n");
    zlobfree(&pzlob);
    PASS();
  }

  // zlob_match_paths_at() - Path filtering with base directory
  printf("\nzlob_match_paths_at() - Path Filtering with Base Directory\n");
  TEST("Filter absolute paths relative to base directory");
  {
    const char *paths[] = {
        "/home/user/project/src/main.c",
        "/home/user/project/src/test/unit.c",
        "/home/user/project/lib/utils.c",
        "/home/user/project/docs/readme.md",
    };
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    int result = zlob_match_paths_at("/home/user/project", "**/*.c", paths,
                                     path_count, 0, &pzlob);

    if (result != 0)
      FAIL("zlob_match_paths_at() failed");
    if (pzlob.zlo_pathc != 3)
      FAIL("Expected 3 matches");
    if (pzlob.zlo_pathv == NULL)
      FAIL("pathv is NULL");
    if (pzlob.zlo_pathlen == NULL)
      FAIL("pathlen is NULL");

    printf("    Found %zu matches (expected 3)\n", pzlob.zlo_pathc);

    // Verify zero-copy: result pointers should reference original array
    int found_original = 0;
    for (size_t i = 0; i < pzlob.zlo_pathc; i++) {
      for (size_t j = 0; j < path_count; j++) {
        if (pzlob.zlo_pathv[i] == paths[j]) {
          found_original++;
          break;
        }
      }
    }
    if (found_original != 3)
      FAIL("Zero-copy failed: pointers don't reference original memory");

    // Verify pathlen matches strlen for all results
    for (size_t i = 0; i < pzlob.zlo_pathc; i++) {
      if (pzlob.zlo_pathlen[i] != strlen(pzlob.zlo_pathv[i]))
        FAIL("pathlen doesn't match strlen");
    }

    zlobfree(&pzlob);
    PASS();
  }

  TEST("zlob_match_paths_at with ./ prefix pattern");
  {
    const char *paths[] = {
        "/home/user/project/src/main.c",
        "/home/user/project/lib/utils.c",
    };
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    int result = zlob_match_paths_at("/home/user/project", "./**/*.c", paths,
                                     path_count, 0, &pzlob);

    if (result != 0)
      FAIL("zlob_match_paths_at() with ./ prefix failed");
    if (pzlob.zlo_pathc != 2)
      FAIL("Expected 2 matches");

    printf("    Found %zu matches (expected 2)\n", pzlob.zlo_pathc);
    zlobfree(&pzlob);
    PASS();
  }

  TEST("zlob_match_paths_at with no matches");
  {
    const char *paths[] = {
        "/home/user/project/src/main.c",
        "/home/user/project/lib/utils.c",
    };
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    int result = zlob_match_paths_at("/home/user/project", "**/*.zig", paths,
                                     path_count, ZLOB_RECOMMENDED, &pzlob);

    if (result != ZLOB_NOMATCH)
      FAIL("Expected ZLOB_NOMATCH");
    printf("    Correctly returned ZLOB_NOMATCH\n");
    PASS();
  }

  // zlob_walk() / zlob_walk_collect() - Parallel file walker
  printf("zlob_walk() - Parallel File Walker\n");

  char walk_root[] = "/tmp/zlob_walk_capi_XXXXXX";
  if (mkdtemp(walk_root) == NULL)
    FAIL("mkdtemp failed");

  {
    char path[512];
    FILE *f;

    snprintf(path, sizeof(path), "%s/sub", walk_root);
    mkdir(path, 0755);

    snprintf(path, sizeof(path), "%s/.gitignore", walk_root);
    f = fopen(path, "w");
    fputs("*.log\n", f);
    fclose(f);

    snprintf(path, sizeof(path), "%s/hello.txt", walk_root);
    f = fopen(path, "w");
    fputs("hello", f); /* 5 bytes */
    fclose(f);

    snprintf(path, sizeof(path), "%s/noise.log", walk_root);
    f = fopen(path, "w");
    fclose(f);

    snprintf(path, sizeof(path), "%s/sub/inner.txt", walk_root);
    f = fopen(path, "w");
    fclose(f);
  }

  TEST("zlob_walk_collect with gitignore + size metadata");
  {
    zlob_walk_options_t opts = {0};
    opts.flags = ZLOB_WALK_GITIGNORE | ZLOB_WALK_SORT;
    opts.meta_mask = ZLOB_META_SIZE;
    opts.threads = 1;

    zlob_walk_result_t res;
    int rc = zlob_walk_collect(walk_root, &opts, &res);
    if (rc != 0)
      FAIL("zlob_walk_collect failed");

    /* .gitignore + hello.txt + sub + sub/inner.txt (noise.log ignored) */
    if (res.count != 4) {
      printf("    got %zu entries\n", res.count);
      FAIL("Expected 4 entries");
    }

    int found_hello = 0, found_log = 0;
    for (size_t i = 0; i < res.count; i++) {
      const zlob_walk_entry_t *e = &res.entries[i];
      if (e->path[e->path_len] != '\0')
        FAIL("Entry path not NUL-terminated");
      const char *base = e->path + e->basename_off;
      if (strcmp(base, "hello.txt") == 0) {
        found_hello = 1;
        if (!(e->meta_valid & ZLOB_META_SIZE))
          FAIL("hello.txt size not valid");
        if (e->size != 5)
          FAIL("hello.txt size != 5");
        if (e->kind != ZLOB_WALK_KIND_FILE)
          FAIL("hello.txt not a file");
        if (e->depth != 1)
          FAIL("hello.txt depth != 1");
      }
      if (strcmp(base, "noise.log") == 0)
        found_log = 1;
    }
    if (!found_hello)
      FAIL("hello.txt not found");
    if (found_log)
      FAIL("noise.log should be gitignored");

    zlob_walk_result_free(&res);
    if (res.entries != NULL || res.count != 0)
      FAIL("result not cleared after free");
    PASS();
  }

  TEST("zlob_walk streaming callback");
  {
    zlob_walk_options_t opts = {0};
    opts.threads = 1;

    size_t seen = 0;
    int rc = zlob_walk(walk_root, &opts, zlob_test_count_cb, &seen);
    if (rc != 0)
      FAIL("zlob_walk failed");
    /* no gitignore flag: .gitignore, hello.txt, noise.log, sub, sub/inner.txt */
    if (seen != 5) {
      printf("    got %zu entries\n", seen);
      FAIL("Expected 5 entries");
    }
    PASS();
  }

  /* best-effort cleanup */
  {
    char cmd[600];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", walk_root);
    if (system(cmd) != 0) { /* ignore */
    }
  }

  return 0;
}
