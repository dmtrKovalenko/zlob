#!/usr/bin/env bash
#
# Reproduce the README benchmark numbers.
#
# Compares the `zlob` crate against the `glob` and `globset` crates over a
# real Linux kernel checkout, with and without symlink following. The kernel
# tree is the README fixture: it contains directory symlinks under
# scripts/dtc/include-prefixes/* that make the FOLLOW_SYMLINKS path meaningful.
#
# Usage:
#   scripts/run-benchmarks.sh [/path/to/linux]
#
# If no path is given, a shallow Linux kernel checkout is cloned into
# /tmp/linux (skipped if it already exists).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL="${1:-/tmp/linux}"
# Drop the kernel-path arg so any remaining args pass through to cargo bench
# (e.g. a criterion benchmark-name filter).
[[ $# -gt 0 ]] && shift

if [[ ! -d "$KERNEL" ]]; then
  echo ">> No kernel tree at $KERNEL — cloning (shallow) ..."
  git clone --depth 1 https://github.com/torvalds/linux.git "$KERNEL"
fi

if [[ ! -f "$KERNEL/Makefile" ]]; then
  echo "!! $KERNEL does not look like a Linux kernel checkout" >&2
  exit 1
fi

echo ">> Benchmark fixture: $KERNEL"
echo ">> $(find "$KERNEL" -type f | wc -l) files, \
$(find "$KERNEL" -type d | wc -l) dirs, \
$(find "$KERNEL" -name '*.c' | wc -l) .c files, \
$(find "$KERNEL" -type l | wc -l) symlinks"

cd "$REPO_ROOT/rust"

# The harness prints a match-count parity table at startup (including the
# zlob+follow unique-file counts) and then benchmarks each pattern. The
# `all_recursive_c` (`**/*.c`) pattern is additionally benchmarked with
# FOLLOW_SYMLINKS as `zlob_follow/...`.
REPO="$KERNEL" cargo bench --bench glob_comparison "$@"
