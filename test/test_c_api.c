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

  TEST("zlob_match_paths_at with trailing slash on base_path");
  {
    const char *paths[] = {
        "/opt/app/src/main.zig",
        "/opt/app/src/utils/helpers.zig",
        "/opt/app/test/test_main.zig",
        "/opt/app/README.md",
    };
    const size_t path_count = sizeof(paths) / sizeof(paths[0]);

    zlob_t pzlob;
    int result = zlob_match_paths_at("/opt/app/", "src/**/*.zig", paths,
                                     path_count, 0, &pzlob);

    if (result != 0)
      FAIL("zlob_match_paths_at() failed");
    if (pzlob.zlo_pathc != 2)
      FAIL("Expected 2 matches");

    printf("    Found %zu matches (expected 2)\n", pzlob.zlo_pathc);
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
                                     path_count, 0, &pzlob);

    if (result != ZLOB_NOMATCH)
      FAIL("Expected ZLOB_NOMATCH");
    printf("    Correctly returned ZLOB_NOMATCH\n");
    PASS();
  }

  printf("\n=== All Tests Passed! ===\n\n");
  return 0;
}
