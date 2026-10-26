#!/usr/bin/env bash
# Level 3b of the verification ladder: every tests/<name>.bend compiled to a
# native binary and run several times on all CPU threads. `bend file.bend`
# (level 3) runs the JavaScript lane, which is sequential; the native runtime
# runs parallel lets on real threads, and a program must pass on both.
#   scripts/check-native.sh [runs]       (default 3 runs per test)
set -uo pipefail
cd "$(dirname "$0")/.."
runs=${1:-3}
fail=0
red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
mkdir -p out/native
trap 'rm -rf out/native' EXIT
build() {
  if [ "$(uname -s)" = Darwin ]; then scripts/build-mac.sh "$1" "$2" >/dev/null 2>&1; else bend "$1" -o "$2" >/dev/null 2>&1; fi
}
tests=$(ls tests/*.bend | grep -v -E '^tests/(t|zz_.*)\.bend$')
for t in $tests; do
  name=$(basename "$t" .bend)
  # skip tests whose module still has TODOs (they are pending on level 3)
  if ! build "$t" "out/native/$name"; then
    if bend "$t" 2>&1 | grep -q 'TODOs\? found'; then echo "pending: $t"; continue; fi
    red "build failed: $t"; fail=1; continue
  fi
  ok=1
  for i in $(seq 1 "$runs"); do
    out=$("./out/native/$name" 2>&1)
    if grep -q '^FAIL\|frontier drained\|^bend:' <<<"$out" || ! grep -q '^PASS' <<<"$out"; then
      red "failed natively (run $i): $t"; grep -v '^PASS' <<<"$out" | head -5; ok=0; fail=1; break
    fi
  done
  [ $ok = 1 ] && grn "ok native: $t ($(grep -c '^PASS' <<<"$out") passed x$runs)"
done
if [ $fail = 0 ]; then grn "CHECK-NATIVE OK"; else red "CHECK-NATIVE FAILED"; fi
exit $fail
