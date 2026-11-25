#!/usr/bin/env bash
#
# Cross-compile the static library for every target the Rust crate supports
# into the zlob-prebuilt-* crates, ready for `cargo publish`.
#
#   scripts/build-prebuilt.sh [--target <rust-triple>]...
#
# Writes rust/prebuilt/<os>/lib/<rust-triple>/libzlob.a (zlob.lib for MSVC).
# Zig cross-compiles every target from any host, so one machine produces the
# whole set. Apart from -Dstrip, the build flags match what rust/build.rs
# passes to `zig build`, so a prebuilt library is the same code a user with
# Zig installed compiles.
set -euo pipefail

ZIG="${ZIG:-zig}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONLY=()

while [ $# -gt 0 ]; do
  case "$1" in
    --target) ONLY+=("$2"); shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# rust_target_to_zig() in rust/build.rs is the one list of supported targets.
PAIRS="$(sed -n 's/^ *"\([a-z0-9_-]*\)" => "\([a-z0-9_.-]*\)",$/\1 \2/p' rust/build.rs)"
[ -n "$PAIRS" ] || { echo "no targets found in rust/build.rs" >&2; exit 1; }

# Targets rust/build.rs lists but Zig cannot build yet. Users on these still
# need Zig, and get its error. loongarch64 glibc: translate-c fails on
# bits/types.h with Zig 0.17.1.
KNOWN_BROKEN=" loongarch64-unknown-linux-gnu "

# A full run replaces everything, so a dropped target leaves no stale library.
if [ ${#ONLY[@]} -eq 0 ]; then
  rm -rf rust/prebuilt/*/lib
fi

built=0
while read -r rust_target zig_target; do
  if [ ${#ONLY[@]} -gt 0 ] && [[ ! " ${ONLY[*]} " == *" $rust_target "* ]]; then
    continue
  fi
  if [[ "$KNOWN_BROKEN" == *" $rust_target "* ]]; then
    echo "==> $rust_target skipped (known not to build)"
    continue
  fi
  # Must agree with the [target.'cfg(..)'.dependencies] tables in rust/Cargo.toml.
  case "$rust_target" in
    *android*) os=android ;;
    *linux*) os=linux ;;
    *apple*) os=apple ;;
    *windows*) os=windows ;;
    *freebsd* | *netbsd*) os=bsd ;;
    *) echo "no zlob-prebuilt crate for $rust_target" >&2; exit 1 ;;
  esac

  echo "==> $rust_target ($zig_target) -> zlob-prebuilt-$os"
  prefix="$WORK/$rust_target"
  "$ZIG" build -Dtarget="$zig_target" -Doptimize=ReleaseFast \
    -Dskip-bench=true -Dstatic-only=true -Dstrip=true -p "$prefix"

  dest="rust/prebuilt/$os/lib/$rust_target"
  rm -rf "$dest"
  mkdir -p "$dest"
  # Zig names the archive zlob.lib on every Windows target. rustc looks for
  # zlob.lib on MSVC and libzlob.a everywhere else, MinGW included.
  lib="$prefix/lib/libzlob.a"
  [ -f "$lib" ] || lib="$prefix/lib/zlob.lib"
  case "$rust_target" in
    *apple*)
      # Apple's linker wants 8-byte aligned members; Zig may write 4-byte BSD ones.
      "$ZIG" ar --format=darwin qLcs "$dest/libzlob.a" "$lib"
      ;;
    *msvc*) cp "$lib" "$dest/zlob.lib" ;;
    *) cp "$lib" "$dest/libzlob.a" ;;
  esac
  built=$((built + 1))
done <<< "$PAIRS"

[ "$built" -gt 0 ] || { echo "no target matched: ${ONLY[*]}" >&2; exit 1; }
echo "Built $built targets into rust/prebuilt/*/lib"
