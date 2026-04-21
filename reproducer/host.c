/*
 * Minimal C host. `dlopen`s a plugin passed on the command line, looks up
 * `plugin_run`, and calls it. No TLS of its own — the point is to let the
 * plugin's TLS segment exercise glibc's static-TLS budget.
 *
 * Usage:
 *   ./host ./libplugin_broken.so     -> expect: cannot allocate memory in static TLS block
 *   ./host ./libplugin_fixed.so      -> expect: plugin_run returned 0
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef int (*plugin_run_fn)(void);

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <path-to-plugin.so>\n", argv[0]);
        return 2;
    }

    dlerror(); /* clear */
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        fprintf(stderr, "dlopen(%s) failed: %s\n", argv[1], dlerror());
        return 1;
    }

    dlerror();
    plugin_run_fn run = (plugin_run_fn)dlsym(handle, "plugin_run");
    const char *err = dlerror();
    if (err) {
        fprintf(stderr, "dlsym(plugin_run) failed: %s\n", err);
        dlclose(handle);
        return 1;
    }

    int rc = run();
    printf("plugin_run returned %d\n", rc);
    dlclose(handle);
    return rc;
}
