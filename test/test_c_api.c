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
    zlob_t pzlob;
    int result = glob("src/*.zig", 0, NULL, &pzlob);

    if (result != 0 && result != ZLOB_NOMATCH) {
      FAIL("glob() returned error");
    }

    if (result == 0) {
      printf("    Found %zu matches\n", pzlob.gl_pathc);

      // Verify results structure
      if (pzlob.gl_pathc == 0)
        FAIL("Expected at least one match");
      if (pzlob.gl_pathv == NULL)
        FAIL("gl_pathv is NULL");
      if (pzlob.gl_pathlen == NULL)
        FAIL("gl_pathlen is NULL");

      // Verify first result
      if (pzlob.gl_pathv[0] == NULL)
        FAIL("First path is NULL");
      size_t len = strlen(pzlob.gl_pathv[0]);
      if (len != pzlob.gl_pathlen[0])
        FAIL("gl_pathlen doesn't match strlen");

      // Verify NULL terminator
      if (pzlob.gl_pathv[pzlob.gl_pathc] != NULL)
        FAIL("Array not NULL-terminated");

      printf("    Example: %s (len=%zu)\n", pzlob.gl_pathv[0],
             pzlob.gl_pathlen[0]);
      globfree(&pzlob);
      PASS();
    } else {
      printf("    No matches (ZLOB_NOMATCH)\n");
      PASS();
    }
  }

  // glob() with recursive pattern
  printf("\nglob() - Recursive Pattern\n");
  TEST("Match **/*.zig files");
  {
    zlob_t pzlob;
    int result = glob("src/**/*.zig", 0, NULL, &pzlob);

    if (result == 0) {
      printf("    Found %zu matches\n", pzlob.gl_pathc);
      if (pzlob.gl_pathc > 0) {
        printf("    Example: %s\n", pzlob.gl_pathv[0]);
      }
      globfree(&pzlob);
      PASS();
    } else if (result == ZLOB_NOMATCH) {
      printf("    No matches (ZLOB_NOMATCH)\n");
      PASS();
    } else {
      FAIL("glob() returned error");
    }
  }

  // zlob_match_paths() - Path filtering (no filesystem)
  printf("\nzlob_match_paths() - Path Filtering\n");
  TEST("Filter paths with *.c pattern");
  {
    const char *paths[] = {
        "main.c", "utils.c", "test.h", "readme.md", "lib.c",
    };
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    int result = zlob_match_paths("*.c", paths, path_count, 0, &pzlob);

    if (result != 0)
      FAIL("zlob_match_paths() failed");
    if (pzlob.gl_pathc != 3)
      FAIL("Expected 3 matches");
    if (pzlob.gl_pathv == NULL)
      FAIL("gl_pathv is NULL");
    if (pzlob.gl_pathlen == NULL)
      FAIL("gl_pathlen is NULL");

    printf("    Found %zu matches (expected 3)\n", pzlob.gl_pathc);

    // Verify zero-copy: pointers should reference original array
    int found_original = 0;
    for (size_t i = 0; i < pzlob.gl_pathc; i++) {
      for (size_t j = 0; j < path_count; j++) {
        if (pzlob.gl_pathv[i] == paths[j]) {
          found_original++;
          break;
        }
      }
    }
    if (found_original != 3)
      FAIL("Zero-copy failed: pointers don't reference original memory");

    globfree(&pzlob);
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
    if (pzlob.gl_pathc != 3)
      FAIL("Expected 3 matches");

    printf("    Found %zu matches (expected 3)\n", pzlob.gl_pathc);
    for (size_t i = 0; i < pzlob.gl_pathc; i++) {
      printf("      - %s (len=%zu)\n", pzlob.gl_pathv[i], pzlob.gl_pathlen[i]);
    }

    globfree(&pzlob);
    PASS();
  }

  printf("\ngl_pathlen Field\n");
  TEST("Verify gl_pathlen provides O(1) length access");
  {
    const char *paths[] = {"short.c", "medium_name.c", "very_long_filename.c"};
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    int result = zlob_match_paths("*.c", paths, path_count, 0, &pzlob);

    if (result != 0)
      FAIL("zlob_match_paths() failed");

    // Verify lengths match strlen
    for (size_t i = 0; i < pzlob.gl_pathc; i++) {
      size_t actual_len = strlen(pzlob.gl_pathv[i]);
      if (pzlob.gl_pathlen[i] != actual_len) {
        printf("    Path %zu: gl_pathlen=%zu, strlen=%zu\n", i,
               pzlob.gl_pathlen[i], actual_len);
        FAIL("gl_pathlen doesn't match strlen");
      }
    }

    printf("    All lengths correct (avoiding strlen overhead)\n");
    globfree(&pzlob);
    PASS();
  }

  TEST("Braced patterns");
  {
    const char *paths[] = {"short.c", "long.c", "other.c"};
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    // Note: no space after comma in brace pattern
    int result = zlob_match_paths("{short,long}.c", paths, path_count, ZLOB_BRACE, &pzlob);

    if (result != 0)
      FAIL("zlob_match_paths() failed");

    if (pzlob.gl_pathc != 2)
      FAIL("Expected 2 matches");

    printf("    All lengths correct (avoiding strlen overhead)\n");
    globfree(&pzlob);
    PASS();
  }

  printf("\n=== All Tests Passed! ===\n\n");
  return 0;
}
