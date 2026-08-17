/* Regression test for the Android/Termux SIGSEGV (fff#786).
 *
 * zlob built with `link_libc = false` (the Android configuration, see
 * build.zig) gets Zig's raw-clone `LinuxThreadImpl` instead of pthreads,
 * because `std.Thread.use_pthreads` is gated on `builtin.link_libc`. That
 * implementation lays out the new thread's TLS from
 * `std.os.linux.tls.area_desc`, a global assigned only by `std/start.zig`.
 *
 * When zlob is a static lib inside a host Zig did not start -- this file, or
 * fff's `libfff_nvim.so` loaded by Neovim -- that start code never runs and
 * `area_desc` stays `undefined`, so the first `std.Thread.spawn` builds the
 * thread area from garbage and faults.
 *
 * The walker spawns helpers lazily (worker.zig: `spawn_threshold = 2`), so the
 * fault needs a directory with MORE THAN TWO subdirectories -- exactly the
 * shape the reporter narrowed it down to. Two subdirectories stay on the
 * calling thread and pass, which is why this test walks both trees.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "zlob.h"

static void make_tree(const char *root, int n_subdirs) {
  char buf[512];
  mkdir(root, 0755);
  for (int i = 0; i < n_subdirs; i++) {
    snprintf(buf, sizeof(buf), "%s/dir%d", root, i);
    mkdir(buf, 0755);
    snprintf(buf, sizeof(buf), "%s/dir%d/file.txt", root, i);
    FILE *f = fopen(buf, "w");
    if (f) {
      fputs("x\n", f);
      fclose(f);
    }
  }
}

static int walk(const char *root, size_t *out_count) {
  zlob_walk_options_t opts;
  memset(&opts, 0, sizeof(opts));
  const char *t = getenv("ZLOB_TEST_THREADS");
  opts.threads = (uint16_t)(t ? atoi(t) : 0); /* 0 = one per CPU, the default fff uses */

  zlob_walk_result_t res;
  memset(&res, 0, sizeof(res));

  int rc = zlob_walk_collect(root, &opts, &res);
  if (rc != 0)
    return rc;
  *out_count = res.count;
  zlob_walk_result_free(&res);
  return 0;
}

int main(void) {
  {
    zlob_walk_options_t probe;
    memset(&probe, 0, sizeof(probe));
    printf("zlob_walk_max_workers = %zu\n", zlob_walk_max_workers(&probe));
  }
  const char *base = getenv("ZLOB_TEST_TMP");
  if (!base)
    base = "/tmp/zlob-nolibc-test";
  mkdir(base, 0755);

  char two[512], three[512];
  snprintf(two, sizeof(two), "%s/two", base);
  snprintf(three, sizeof(three), "%s/three", base);
  make_tree(two, 2);
  make_tree(three, 3);

  /* Below the spawn threshold: single-threaded, must pass. */
  size_t n = 0;
  printf("walking %s (2 subdirs, no helper threads expected)...\n", two);
  fflush(stdout);
  if (walk(two, &n) != 0) {
    fprintf(stderr, "FAIL: walk of 2-subdir tree returned an error\n");
    return 1;
  }
  printf("  ok: %zu entries\n", n);
  fflush(stdout);

  /* Above the spawn threshold: this is where ensureWorkers() runs. */
  printf("walking %s (3 subdirs, triggers std.Thread.spawn)...\n", three);
  fflush(stdout);
  if (walk(three, &n) != 0) {
    fprintf(stderr, "FAIL: walk of 3-subdir tree returned an error\n");
    return 1;
  }
  printf("  ok: %zu entries\n", n);

  if (n != 6) {
    fprintf(stderr, "FAIL: expected 6 entries (3 dirs + 3 files), got %zu\n", n);
    return 1;
  }
  printf("PASS\n");
  return 0;
}
