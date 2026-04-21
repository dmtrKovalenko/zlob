# Minimal reproducer for the glibc "cannot allocate memory in static TLS
# block" error that hits Zig 0.16 shared libraries loaded late via dlopen.
#
# This Makefile always cross-compiles to x86_64-linux-gnu via Zig, so you
# can build the artifacts on macOS / whatever and scp them to a Linux box
# to see the failure. (The bug only reproduces on glibc; macOS dyld and
# musl don't have the same static-TLS reserve.)
#
# Usage:
#   make           # builds both plugins + host (cross-compiled to linux)
#   make inspect   # shows TLS program header sizes (runs locally)
#   make run       # runs both scenarios (requires Linux glibc)
#   make clean
#
# Expected outcome on Linux:
#   ./host ./libplugin_broken.so  -> dlopen fails: "cannot allocate memory
#                                     in static TLS block"
#   ./host ./libplugin_fixed.so   -> "plugin_run returned 0"

ZIG    ?= zig
TARGET ?= x86_64-linux-gnu

PLUGIN_BROKEN := libplugin_broken.so
PLUGIN_FIXED  := libplugin_fixed.so
HOST          := host

# Dynamic Zig shared lib linked against glibc. -OReleaseSafe so the
# threadlocal isn't optimized out (it never would be anyway — it's
# per-thread data referenced by sigaltstack).
ZIG_LIB_FLAGS := -dynamic -fPIC -lc -OReleaseSafe -target $(TARGET)

all: $(HOST) $(PLUGIN_BROKEN) $(PLUGIN_FIXED)

$(HOST): host.c
	$(ZIG) cc -target $(TARGET) -Wall -O2 host.c -o $@ -ldl

$(PLUGIN_BROKEN): libplugin.zig
	$(ZIG) build-lib $(ZIG_LIB_FLAGS) -femit-bin=$@ libplugin.zig

$(PLUGIN_FIXED): libplugin_fixed.zig
	$(ZIG) build-lib $(ZIG_LIB_FLAGS) -femit-bin=$@ libplugin_fixed.zig

run: all
	@echo "--- broken plugin (expect failure on Linux glibc) ---"
	-./$(HOST) ./$(PLUGIN_BROKEN)
	@echo
	@echo "--- fixed plugin (expect success) ---"
	./$(HOST) ./$(PLUGIN_FIXED)

# Works on any host — uses llvm-readelf (ships with zig under
# lib/zig/tools/ on newer releases, or via brew install llvm).
inspect: $(PLUGIN_BROKEN) $(PLUGIN_FIXED)
	@echo "--- TLS segment of broken plugin ---"
	@llvm-readelf -l $(PLUGIN_BROKEN) | grep -E 'Type|TLS' || readelf -l $(PLUGIN_BROKEN) | grep TLS
	@echo
	@echo "--- TLS segment of fixed plugin ---"
	@llvm-readelf -l $(PLUGIN_FIXED)  | grep -E 'Type|TLS' || readelf -l $(PLUGIN_FIXED)  | grep TLS

clean:
	rm -f $(HOST) $(PLUGIN_BROKEN) $(PLUGIN_FIXED)

.PHONY: all run inspect clean
