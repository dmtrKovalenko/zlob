PREFIX ?= /usr/local
LIBDIR = $(PREFIX)/lib
INCLUDEDIR = $(PREFIX)/include

LIBNAME = libzlob.so

ZIG = zig
CC ?= gcc
CFLAGS = -Wall -Wextra -O2
CARGO ?= cargo
CLANG_FORMAT ?= clang-format

C_FORMAT_FILES = include/zlob.h test/test_c_api.c

# Detect OS for library extension
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    LIBNAME = libzlob.dylib
    LIBEXT = dylib
else ifeq ($(UNAME_S),Linux)
    LIBNAME = libzlob.so
    LIBEXT = so
else
    LIBNAME = zlob.dll
    LIBEXT = dll
endif

.PHONY: all build install uninstall test clean cli install-cli uninstall-cli dev dev-test test-libc format format-check help

all: build

# Build the shared library using zig build
build:
	@echo "Building zlob..."
	$(ZIG) build -Doptimize=ReleaseFast
	@echo ""
	@echo "Build complete:"
	@echo "  Library: zig-out/lib/$(LIBNAME)"
	@echo "  Static:  zig-out/lib/libzlob.a"
	@echo "  CLI:     zig-out/bin/zlob"
	@echo "  Header:  zig-out/include/zlob.h"

build-static:
	@echo "Building zlob static library..."
	$(ZIG) build -Doptimize=ReleaseFast -Dstatic-only=true
	@echo ""
	@echo "Static library built: zig-out/lib/libzlob.a"

# Install library and headers
install: build
	@echo "Installing zlob library to $(PREFIX)..."
	install -d $(LIBDIR)
	install -d $(INCLUDEDIR)
	install -m 644 zig-out/lib/$(LIBNAME) $(LIBDIR)/$(LIBNAME)
	install -m 644 zig-out/include/zlob.h $(INCLUDEDIR)/zlob.h
	@if [ "$(UNAME_S)" = "Linux" ]; then \
		ldconfig 2>/dev/null || true; \
	fi
	@echo "Installation complete!"
	@echo "  Library: $(LIBDIR)/$(LIBNAME)"
	@echo "  Header:  $(INCLUDEDIR)/zlob.h"

# Uninstall
uninstall:
	@echo "Uninstalling zlob library..."
	rm -f $(LIBDIR)/$(LIBNAME)
	rm -f $(INCLUDEDIR)/zlob.h
	@if [ "$(UNAME_S)" = "Linux" ]; then \
		ldconfig 2>/dev/null || true; \
	fi
	@echo "Uninstall complete!"

test: build
	@echo "-> Running Zig tests"
	$(ZIG) build test --summary all
ifneq ($(filter Linux Darwin,$(UNAME_S)),)
	@echo "========================"
	@echo "-> Running C API tests"
	$(CC) $(CFLAGS) -I./zig-out/include -L./zig-out/lib \
		-o test_c_api test/test_c_api.c -lzlob \
		-Wl,-rpath,./zig-out/lib
	./test_c_api
	@rm -f test_c_api
endif
	@echo "========================"
	@echo "-> Running Rust tests"
	cd rust && $(CARGO) test

# Clean build artifacts
clean:
	rm -rf zig-out zig-cache .zig-cache
	rm -f test_c_api test_match_paths main
	cd rust && $(CARGO) clean 2>/dev/null || true
	@echo "Clean complete!"

# Build CLI executable
cli:
	@echo "Building zlob CLI..."
	$(ZIG) build -Doptimize=ReleaseFast
	@echo "CLI built: zig-out/bin/zlob"

# Install CLI executable
install-cli: cli
	@echo "Installing zlob CLI to $(PREFIX)/bin..."
	install -d $(PREFIX)/bin
	install -m 755 zig-out/bin/zlob $(PREFIX)/bin/zlob
	@echo "Installation complete!"
	@echo "  Executable: $(PREFIX)/bin/zlob"

# Uninstall CLI executable
uninstall-cli:
	@echo "Uninstalling zlob CLI..."
	rm -f $(PREFIX)/bin/zlob
	@echo "Uninstall complete!"

# ============================================================================
# Development targets
# ============================================================================

# Build all: Zig library, C library, and Rust bindings
dev: build
	@echo ""
	@echo "Building Rust bindings..."
	cd rust && $(CARGO) build
	@echo ""
	@echo "Development build complete:"
	@echo "  Zig library:  zig-out/lib/$(LIBNAME)"
	@echo "  Zig static:   zig-out/lib/libzlob.a"
	@echo "  Zig CLI:      zig-out/bin/zlob"
	@echo "  Rust target:  rust/target/debug/libzlob.rlib"

# Run all tests: Zig, C, and Rust
dev-test: build
	@echo "========================================"
	@echo "zig tests"
	@echo "========================================"
	$(ZIG) build test
	@echo ""
	@echo "========================================"
	@echo "c api tests"
	@echo "========================================"
	$(CC) $(CFLAGS) -I./zig-out/include -L./zig-out/lib \
		-o test_c_api test/test_c_api.c -lzlob \
		-Wl,-rpath,./zig-out/lib
	./test_c_api
	@rm -f test_c_api
	@echo ""
	@echo "========================================"
	@echo "rust tests "
	@echo "========================================"
	cd rust && $(CARGO) test
	@echo ""
	@echo "========================================"
	@echo "comparing to glibc"
	@echo "========================================"
	./test/test_libc_comparison.sh
	@echo ""
	@echo "========================================"
	@echo "All tests passed!"
	@echo "========================================"

# Run libc comparison tests only
test-libc: build
	@echo "========================================"
	@echo "Running libc comparison tests..."
	@echo "========================================"
	./test/test_libc_comparison.sh

format:
	zig fmt src/ test/ bench/
	$(CLANG_FORMAT) -i $(C_FORMAT_FILES)
	cd rust && cargo fmt --all

format-check:
	zig fmt --check src/ test/ bench/
	$(CLANG_FORMAT) --dry-run --Werror $(C_FORMAT_FILES)
	cd rust && cargo fmt --check

help:
	@echo "zlob - faster and more correct glob library, 100% POSIX compatible"
	@echo ""
	@echo "Targets:"
	@echo "  make              - Build the shared library (release)"
	@echo "  make install      - Install library and headers (may require sudo)"
	@echo "  make test         - Run all tests (Zig + Rust, plus C API on Linux/macOS)"
	@echo "  make test-libc    - Run libc comparison tests (requires TEST_DIR)"
	@echo "  make cli          - Build the CLI executable"
	@echo "  make install-cli  - Install CLI executable (may require sudo)"
	@echo "  make clean        - Remove build artifacts"
	@echo ""
	@echo "Development:"
	@echo "  make dev          - Build all: Zig, C, and Rust"
	@echo "  make dev-test     - Run all tests: Zig, C, Rust, and libc comparison"
	@echo "  make format       - Format Zig and C sources (zig fmt + clang-format)"
	@echo "  make format-check - Verify Zig and C sources are formatted (no changes)"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX        - Installation prefix (default: /usr/local)"
	@echo "  CC            - C compiler (default: gcc)"
	@echo "  CARGO         - Cargo command (default: cargo)"
	@echo "  CLANG_FORMAT  - clang-format command (default: clang-format)"
	@echo "  TEST_DIR      - Directory for libc comparison tests"
	@echo ""
	@echo "Examples:"
	@echo "  make"
	@echo "  make dev-test"
	@echo "  TEST_DIR=/path/to/linux make test-libc"
	@echo "  sudo make install"
	@echo "  make cli && sudo make install-cli"
	@echo "  sudo make PREFIX=/usr install"
