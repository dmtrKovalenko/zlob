#include "zlob.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define TEST(name) printf("  [TEST] %s\n", name)
#define PASS() printf("    ✓ PASS\n")
#define FAIL(msg)                                                              \
  do {                                                                         \
    printf("    ✗ FAIL: %s\n", msg);                                           \
    return 1;                                                                  \
  } while (0)

int main(void) {

  // glob() - Filesystem walking
  printf("glob() - Filesystem Walking\n");
  TEST("Match *.zig files in src/");
  {
    glob_t pglob;
    int result = glob("src/*.zig", 0, NULL, &pglob);

    if (result != 0 && result != GLOB_NOMATCH) {
      FAIL("glob() returned error");
    }

    if (result == 0) {
      printf("    Found %zu matches\n", pglob.gl_pathc);

      // Verify results structure
      if (pglob.gl_pathc == 0)
        FAIL("Expected at least one match");
      if (pglob.gl_pathv == NULL)
        FAIL("gl_pathv is NULL");
      if (pglob.gl_pathlen == NULL)
        FAIL("gl_pathlen is NULL");

      // Verify first result
      if (pglob.gl_pathv[0] == NULL)
        FAIL("First path is NULL");
      size_t len = strlen(pglob.gl_pathv[0]);
      if (len != pglob.gl_pathlen[0])
        FAIL("gl_pathlen doesn't match strlen");

      // Verify NULL terminator
      if (pglob.gl_pathv[pglob.gl_pathc] != NULL)
        FAIL("Array not NULL-terminated");

      printf("    Example: %s (len=%zu)\n", pglob.gl_pathv[0],
             pglob.gl_pathlen[0]);
      globfree(&pglob);
      PASS();
    } else {
      printf("    No matches (GLOB_NOMATCH)\n");
      PASS();
    }
  }

  // glob() with recursive pattern
  printf("\nglob() - Recursive Pattern\n");
  TEST("Match **/*.zig files");
  {
    glob_t pglob;
    int result = glob("src/**/*.zig", 0, NULL, &pglob);

    if (result == 0) {
      printf("    Found %zu matches\n", pglob.gl_pathc);
      if (pglob.gl_pathc > 0) {
        printf("    Example: %s\n", pglob.gl_pathv[0]);
      }
      globfree(&pglob);
      PASS();
    } else if (result == GLOB_NOMATCH) {
      printf("    No matches (GLOB_NOMATCH)\n");
      PASS();
    } else {
      FAIL("glob() returned error");
    }
  }

  // glob_match_paths() - Path filtering (no filesystem)
  printf("\nglob_match_paths() - Path Filtering\n");
  TEST("Filter paths with *.c pattern");
  {
    const char *paths[] = {
        "main.c", "utils.c", "test.h", "readme.md", "lib.c",
    };
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    glob_t pglob;
    int result = glob_match_paths("*.c", paths, path_count, 0, &pglob);

    if (result != 0)
      FAIL("glob_match_paths() failed");
    if (pglob.gl_pathc != 3)
      FAIL("Expected 3 matches");
    if (pglob.gl_pathv == NULL)
      FAIL("gl_pathv is NULL");
    if (pglob.gl_pathlen == NULL)
      FAIL("gl_pathlen is NULL");

    printf("    Found %zu matches (expected 3)\n", pglob.gl_pathc);

    // Verify zero-copy: pointers should reference original array
    int found_original = 0;
    for (size_t i = 0; i < pglob.gl_pathc; i++) {
      for (size_t j = 0; j < path_count; j++) {
        if (pglob.gl_pathv[i] == paths[j]) {
          found_original++;
          break;
        }
      }
    }
    if (found_original != 3)
      FAIL("Zero-copy failed: pointers don't reference original memory");

    globfree(&pglob);
    PASS();
  }

  // glob_match_paths() with no matches
  printf("\nglob_match_paths() - No Matches\n");
  TEST("Filter paths with *.xyz pattern (no matches)");
  {
    const char *paths[] = {"main.c", "test.h", "readme.md"};
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    glob_t pglob;
    int result = glob_match_paths("*.xyz", paths, path_count, 0, &pglob);

    if (result != GLOB_NOMATCH)
      FAIL("Expected GLOB_NOMATCH");
    printf("    Correctly returned GLOB_NOMATCH\n");
    PASS();
  }

  // glob_match_paths() with recursive pattern
  printf("\nglob_match_paths() - Recursive Pattern\n");
  TEST("Filter paths with **/*.c pattern");
  {
    const char *paths[] = {
        "src/main.c",
        "src/test/unit.c",
        "lib/utils.c",
        "docs/readme.md",
    };
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    glob_t pglob;
    int result = glob_match_paths("**/*.c", paths, path_count, 0, &pglob);

    if (result != 0)
      FAIL("glob_match_paths() failed");
    if (pglob.gl_pathc != 3)
      FAIL("Expected 3 matches");

    printf("    Found %zu matches (expected 3)\n", pglob.gl_pathc);
    for (size_t i = 0; i < pglob.gl_pathc; i++) {
      printf("      - %s (len=%zu)\n", pglob.gl_pathv[i], pglob.gl_pathlen[i]);
    }

    globfree(&pglob);
    PASS();
  }

  printf("\ngl_pathlen Field\n");
  TEST("Verify gl_pathlen provides O(1) length access");
  {
    const char *paths[] = {"short.c", "medium_name.c", "very_long_filename.c"};
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    glob_t pglob;
    int result = glob_match_paths("*.c", paths, path_count, 0, &pglob);

    if (result != 0)
      FAIL("glob_match_paths() failed");

    // Verify lengths match strlen
    for (size_t i = 0; i < pglob.gl_pathc; i++) {
      size_t actual_len = strlen(pglob.gl_pathv[i]);
      if (pglob.gl_pathlen[i] != actual_len) {
        printf("    Path %zu: gl_pathlen=%zu, strlen=%zu\n", i,
               pglob.gl_pathlen[i], actual_len);
        FAIL("gl_pathlen doesn't match strlen");
      }
    }

    printf("    All lengths correct (avoiding strlen overhead)\n");
    globfree(&pglob);
    PASS();
  }

  TEST("Braced patterns");
  {
    const char *paths[] = {"short.c", "long.c", "other.c"};
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    glob_t pglob;
    int result = glob_match_paths("{short, long}.c", paths, path_count, 0, &pglob);

    if (result != 0)
      FAIL("glob_match_paths() failed");

    if pglob.gl_pathc != 2
      FAIL("Expected 2 matches");

    printf("    All lengths correct (avoiding strlen overhead)\n");
    globfree(&pglob);
    PASS();
  }

  printf("\n=== All Tests Passed! ===\n\n");
  return 0;
}
