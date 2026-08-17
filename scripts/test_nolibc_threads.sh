#!/usr/bin/env bash
#
# bug pin test for bild + verfiy fff#786: SIGSEGV when zlob spawns walker threads inside a
# host process that Zig did not start.
#
# Android is built with link_libc=false (Zig ships no bionic headers), which
# hands std.Thread its raw-clone backend. That backend reads
# std.os.linux.tls.area_desc, a global only ever assigned by Zig's start code,
# so a static lib inside a foreign host (fff's libfff_nvim.so under Neovim)
# spawns from a zeroed descriptor and faults.
set -euo pipefail

TARGET="${1:-native}"
shift || true
RUNNER=("$@")

ZIG="${ZIG:-zig}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

build_args=(-Doptimize=ReleaseFast -Dstatic-only=true -Dskip-bench=true -Dforce-no-libc)
cc_args=()
if [ "$TARGET" != "native" ]; then
  build_args+=("-Dtarget=$TARGET")
  cc_args+=("-target" "$TARGET")
  # Static musl needs no sysroot or dynamic loader under qemu-user.
  case "$TARGET" in *musl*) cc_args+=("-static") ;; esac
fi

echo "=> building libzlob.a without libc (target: $TARGET)"
"$ZIG" build --build-file "$ROOT/build.zig" -p "$OUT" "${build_args[@]}"

# The host links libc; the library does not. That asymmetry is the whole point:
# it is what fff's Rust cdylib loaded by Neovim looks like.
echo "=> building the C host (links libc)"
"$ZIG" cc "${cc_args[@]}" -I "$ROOT/include" \
  "$ROOT/test/test_nolibc_threads.c" "$OUT/lib/libzlob.a" -o "$OUT/host"

echo "=> running"
ZLOB_TEST_TMP="$OUT/tree" "${RUNNER[@]}" "$OUT/host"
