#!/usr/bin/env bash
# Double-sided (A/B) walker benchmark.
#
# Runs two builds of bench/bench_walk.zig against the same trees, alternating
# A and B round by round so cache state, thermal drift and background load hit
# both sides equally. Reports the per-side median of round medians and checks
# that both sides produced the same entry checksum.
#
#   scripts/bench_walk_ab.sh <bench_walk_A> <bench_walk_B> <root>... [-- <bench_walk args>]
#
# Env: ROUNDS (default 5), ITERS per round (default 10).
#
# Build the two sides from the trees you want to compare, e.g.
#   git stash / checkout main && zig build -Doptimize=ReleaseFast && cp zig-out/bin/bench_walk /tmp/walk_base
#   <apply change>            && zig build -Doptimize=ReleaseFast && cp zig-out/bin/bench_walk /tmp/walk_new
#   scripts/bench_walk_ab.sh /tmp/walk_base /tmp/walk_new ~/src/linux -- --threads 8
set -euo pipefail

A=$1
B=$2
shift 2
roots=()
extra=()
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then
    shift
    extra=("$@")
    break
  fi
  roots+=("$1")
  shift
done
ROUNDS=${ROUNDS:-5}
ITERS=${ITERS:-10}

median() { sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'; }

printf '%-34s %10s %10s %8s  %s\n' "tree" "A ms" "B ms" "B vs A" "output"
for root in "${roots[@]}"; do
  a_meds=()
  b_meds=()
  a_sum=""
  b_sum=""
  for _ in $(seq "$ROUNDS"); do
    out=$("$A" "$root" --iters "$ITERS" --quiet ${extra[@]+"${extra[@]}"} 2>&1)
    a_meds+=("$(sed -n 's/.*median=\([0-9.]*\)ms.*/\1/p' <<<"$out")")
    a_sum=$(sed -n 's/^workers=[0-9]* //p' <<<"$out")
    out=$("$B" "$root" --iters "$ITERS" --quiet ${extra[@]+"${extra[@]}"} 2>&1)
    b_meds+=("$(sed -n 's/.*median=\([0-9.]*\)ms.*/\1/p' <<<"$out")")
    b_sum=$(sed -n 's/^workers=[0-9]* //p' <<<"$out")
  done
  am=$(printf '%s\n' "${a_meds[@]}" | median)
  bm=$(printf '%s\n' "${b_meds[@]}" | median)
  delta=$(awk -v a="$am" -v b="$bm" 'BEGIN { printf "%+.1f%%", (b - a) / a * 100 }')
  same="identical"
  [ "$a_sum" = "$b_sum" ] || same="DIFFERENT"
  printf '%-34s %10.2f %10.2f %8s  %s\n' "$(basename "$root")" "$am" "$bm" "$delta" "$same"
done
