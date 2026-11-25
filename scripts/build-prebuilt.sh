#!/usr/bin/env bash
#
# Cross-compile the static library for every target the Rust crate supports
# and record the checksums the crate's build.rs verifies downloads against.
#
#   scripts/build-prebuilt.sh [--target <rust-triple>]... [out-dir]
#
# Writes <out-dir>/libzlob-<rust-triple>.a (default dist/prebuilt) and
# rust/prebuilt.sha256. Zig cross-compiles every target from any host, so one
# machine produces the whole set. The build flags match what rust/build.rs
# passes to `zig build`, so a prebuilt library is the same code a user with
# Zig installed compiles.
set -euo pipefail

ZIG="${ZIG:-zig}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/prebuilt"
ONLY=()

while [ $# -gt 0 ]; do
  case "$1" in
    --target) ONLY+=("$2"); shift 2 ;;
    *) OUT="$1"; shift ;;
  esac
done

cd "$ROOT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# rust_target_to_zig() in rust/build.rs is the one list of supported targets.
PAIRS="$(sed -n 's/^ *"\([a-z0-9_-]*\)" => "\([a-z0-9_.-]*\)",$/\1 \2/p' rust/build.rs)"
[ -n "$PAIRS" ] || { echo "no targets found in rust/build.rs" >&2; exit 1; }

VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' rust/Cargo.toml | head -n1)"
SUMS="$WORK/prebuilt.sha256"
echo "# zlob $VERSION" > "$SUMS"

# Targets rust/build.rs lists but Zig cannot build yet. Users on these still
# need Zig, and get its error. loongarch64 glibc: translate-c fails on
# bits/types.h with Zig 0.17.1.
KNOWN_BROKEN=" loongarch64-unknown-linux-gnu "

built=0
while read -r rust_target zig_target; do
  if [[ "$KNOWN_BROKEN" == *" $rust_target "* ]]; then
    echo "==> $rust_target skipped (known not to build)"
    continue
  fi
  if [ ${#ONLY[@]} -gt 0 ] && [[ ! " ${ONLY[*]} " == *" $rust_target "* ]]; then
    continue
  fi
  echo "==> $rust_target ($zig_target)"
  prefix="$WORK/$rust_target"
  "$ZIG" build -Dtarget="$zig_target" -Doptimize=ReleaseFast \
    -Dskip-bench=true -Dstatic-only=true -p "$prefix"

  lib="$prefix/lib/libzlob.a"
  [ -f "$lib" ] || lib="$prefix/lib/zlob.lib" # MSVC name, same archive format
  asset="libzlob-$rust_target.a"
  case "$rust_target" in
    *apple*)
      # Apple's linker wants 8-byte aligned members; Zig may write 4-byte BSD ones.
      "$ZIG" ar --format=darwin qLcs "$OUT/$asset.tmp" "$lib"
      mv "$OUT/$asset.tmp" "$OUT/$asset"
      ;;
    *) cp "$lib" "$OUT/$asset" ;;
  esac
  echo "$(sha256 "$OUT/$asset")  $asset" >> "$SUMS"
  built=$((built + 1))
done <<< "$PAIRS"

[ "$built" -gt 0 ] || { echo "no target matched: ${ONLY[*]}" >&2; exit 1; }

# A partial run (--target) must not replace the full release list.
if [ ${#ONLY[@]} -eq 0 ]; then
  cp "$SUMS" rust/prebuilt.sha256
  echo "Wrote rust/prebuilt.sha256 for $built targets"
else
  cp "$SUMS" "$OUT/prebuilt.sha256"
  echo "Wrote $OUT/prebuilt.sha256 for $built targets"
fi
