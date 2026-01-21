# Makefile for zlob - POSIX glob library
#
# Targets:
#   make          - Build the shared library
#   make install  - Install library and headers (requires sudo)
#   make test     - Run minimal C API tests
#   make clean    - Remove build artifacts

PREFIX ?= /usr/local
LIBDIR = $(PREFIX)/lib
INCLUDEDIR = $(PREFIX)/include

LIBNAME = libzlob.so
VERSION = 1.0.0

ZIG = zig
ZIG_FLAGS = -O ReleaseFast
CC ?= gcc
CFLAGS = -Wall -Wextra -O2

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

.PHONY: all build install uninstall test clean make-cli install-cli uninstall-cli

all: build

# Build the shared library using zig build
build:
	@echo "Building zlob library..."
	$(ZIG) build -Doptimize=ReleaseFast
	@echo "Library built: zig-out/lib/$(LIBNAME)"

# Install library and headers
install: build
	@echo "Installing zlob library to $(PREFIX)..."
	install -d $(LIBDIR)
	install -d $(INCLUDEDIR)
	install -m 644 zig-out/lib/$(LIBNAME) $(LIBDIR)/$(LIBNAME)
	install -m 644 include/zlob.h $(INCLUDEDIR)/zlob.h
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

# Minimal test of C API
test: build test/test_c_api.c
	$(CC) $(CFLAGS) -I./include -L./zig-out/lib \
		-o test_c_api test/test_c_api.c -lzlob \
		-Wl,-rpath,./zig-out/lib
	@echo ""
	./test_c_api
	@rm -f test_c_api

# Clean build artifacts
clean:
	rm -rf zig-out zig-cache .zig-cache
	rm -f test_c_api test_match_paths main
	@echo "Clean complete!"

# Build CLI executable
cli:
	@echo "Building simdglob CLI..."
	$(ZIG) build -Doptimize=ReleaseFast
	@echo "CLI built: zig-out/bin/simdglob"

# Install CLI executable
install-cli: make-cli
	@echo "Installing simdglob CLI to $(PREFIX)/bin..."
	install -d $(PREFIX)/bin
	install -m 755 zig-out/bin/simdglob $(PREFIX)/bin/simdglob
	@echo "Installation complete!"
	@echo "  Executable: $(PREFIX)/bin/simdglob"

# Uninstall CLI executable
uninstall-cli:
	@echo "Uninstalling simdglob CLI..."
	rm -f $(PREFIX)/bin/simdglob
	@echo "Uninstall complete!"

# Help
help:
	@echo "zlob - faster and more correct glob library, 100% POSIX compatible"
	@echo ""
	@echo "Targets:"
	@echo "  make              - Build the shared library"
	@echo "  make install      - Install library and headers (may require sudo)"
	@echo "  make test         - Run minimal C API tests"
	@echo "  make make-cli     - Build the CLI executable"
	@echo "  make install-cli  - Install CLI executable (may require sudo)"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make help         - Show this help message"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX        - Installation prefix (default: /usr/local)"
	@echo "  CC            - C compiler (default: gcc)"
	@echo ""
	@echo "Examples:"
	@echo "  make"
	@echo "  make test"
	@echo "  sudo make install"
	@echo "  make make-cli && sudo make install-cli"
	@echo "  sudo make PREFIX=/usr install"
