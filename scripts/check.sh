#!/usr/bin/env bash
# The verification gate for the pure VMM (everything under src/). It runs on
# Linux and macOS, in CI and in agent sandboxes. It checks, in order:
#
#   1. Typing: `bend PROOF.bend` either proves everything or fails only on
#      open TODOs (unproven laws, unwritten bodies). Any other error fails.
#   2. Ratchet: every module with a marker laws/done/<module> proves completely
#      on its own (`bend proofs/<module>.bend` prints ALL PROOFS CHECK). A PR
#      adds the marker when it closes the module's last TODO; it never leaves.
#   3. Tests: every tests/<name>.bend runs (in parallel) and prints only PASS
#      lines. A test whose imports still hold TODOs is PENDING, which is an
#      error once its module (same name) is done.
#
# Usage: scripts/check.sh [--strict]   (--strict: no TODO may remain anywhere)
set -uo pipefail
cd "$(dirname "$0")/.."

strict=0
[ "${1:-}" = "--strict" ] && strict=1
fail=0
red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }

# A bend run that only reports open TODOs.
only_todos() { grep -q '^Error: [0-9]* TODOs\? found\.' <<<"$1" && ! grep -q '^- expected\|^- message' <<<"$1"; }
is_done() { [ -f "laws/done/$1" ]; }

echo "== 1. typing (bend PROOF.bend)"
out=$(bend PROOF.bend 2>&1)
if grep -q '^ALL PROOFS CHECK' <<<"$out"; then
  grn "ALL PROOFS CHECK"
elif only_todos "$out"; then
  todos=$(sed -n 's/^Error: \([0-9]*\) TODOs\{0,1\} found\./\1/p' <<<"$out")
  echo "open TODOs: $todos"
  if [ $strict = 1 ]; then red "strict: TODOs remain"; fail=1; fi
else
  red "PROOF.bend does not type-check:"; echo "$out"; fail=1
fi

echo "== 2. ratchet (laws/done/)"
for f in laws/done/*; do
  m=$(basename "$f")
  [ "$m" = README ] && continue
  out=$(bend "proofs/$m.bend" 2>&1)
  if grep -q '^ALL PROOFS CHECK' <<<"$out"; then grn "done: $m"; else red "regressed: $m"; echo "$out" | head -20; fail=1; fi
done

echo "== 3. tests"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tests=$(ls tests/*.bend | grep -v '^tests/t\.bend$')
# Each test runs in its own process; bend's checker is single-file, so this is
# the cheapest parallelism we have.
printf '%s\n' $tests | xargs -P "${JOBS:-8}" -I{} sh -c 'bend "{}" > "'"$tmp"'/$(basename "{}" .bend).out" 2>&1'
for t in $tests; do
  name=$(basename "$t" .bend)
  out=$(cat "$tmp/$name.out")
  if only_todos "$out" && ! grep -q '^PASS\|^FAIL' <<<"$out"; then
    if is_done "$name" || [ $strict = 1 ]; then red "PENDING but required: $t"; fail=1; else echo "pending: $t"; fi
  elif grep -q '^FAIL' <<<"$out" || ! grep -q '^PASS' <<<"$out"; then
    red "failed: $t"; echo "$out" | grep -v '^PASS' | head -20; fail=1
  else
    grn "ok: $t ($(grep -c '^PASS' <<<"$out") passed)"
  fi
done

if [ $fail = 0 ]; then grn "CHECK OK"; else red "CHECK FAILED"; fi
exit $fail
