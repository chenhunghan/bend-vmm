#!/usr/bin/env bash
# Snapshot compatibility between two builds (C_TO_BEND.md, stage 3): a
# snapshot taken by A restores on B and one taken by B restores on A (the
# guest's RAM and CPUs continue), and a save killed midway leaves the last
# good snapshot in place (the VMM writes a temporary file and renames it).
#   scripts/snapcompat.sh A B
# A and B are built binaries or git revisions (built once into
# out/c-to-bend/bin/<sha>, as scripts/bench/ab.sh does). Malformed and cut
# snapshots are check-host's (section 5). Exit status 1 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
root=$PWD
[ $# = 2 ] || { sed -n '2,10p' "$0"; exit 2; }
SLOW=${CHECK_SLOW:-1}
slp() { sleep $(( $1 * SLOW )); }
drive() { local t=$1; shift; python3 scripts/drive.py $(( t * SLOW )) "$@"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
die() { echo "snapcompat: $*" >&2; exit 2; }

resolve() {
  if [ -f "$1" ] && [ -x "$1" ]; then (cd "$(dirname "$1")" && echo "$PWD/$(basename "$1")"); return; fi
  local sha; sha=$(git rev-parse --verify -q "$1^{commit}") || die "$1 is neither a binary nor a revision"
  local bin=$root/out/c-to-bend/bin/$sha
  if [ ! -x "$bin" ]; then
    local wt=$root/out/c-to-bend/src-$sha
    mkdir -p out/c-to-bend/bin
    git worktree add -q --detach "$wt" "$sha" >&2 || die "worktree for $1"
    (cd "$wt" && scripts/build.sh host/main.bend "$bin" >&2) || { git worktree remove --force "$wt"; die "build of $1"; }
    git worktree remove --force "$wt"
  fi
  echo "$bin"
}
A=$(resolve "$1") || exit 2
B=$(resolve "$2") || exit 2
scripts/guest-assets.sh >/dev/null || die "guest assets"
fail=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

# boots on $1 with a control socket, leaves a mark in the guest, snapshots
# into $2; 0 when saved
take() {
  local bin=$1 snap=$2 sock=$t/vm.sock
  rm -f "$sock"
  ( (slp 8; printf 'echo MARK-$((6*7)) > /tmp/m\n'; slp 40) | "$bin" --mem 512 --cpus 2 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --control "$sock" --cmdline "console=ttyAMA0 quiet" > "$t/take.log" 2>&1 & )
  slp 12
  local r; r=$(echo "snapshot $snap" | nc -U "$sock")
  echo quit | nc -U "$sock" >/dev/null; slp 1
  [ "$r" = saved ]
}

# restores $2 on $1: the mark is there and the guest powers off cleanly
restore() {
  local out; out=$(drive 40 "restored" 'cat /tmp/m\n' "MARK-42" 'poweroff -f\n' -- "$1" --restore "$2" 2>&1)
  grep -q "^MARK-42" <<<"$(tr -d '\r' <<<"$out")" && grep -q "stopped (0)" <<<"$out"
}

for dir in "A B" "B A"; do
  set -- $dir
  from=$([ "$1" = A ] && echo "$A" || echo "$B"); to=$([ "$2" = A ] && echo "$A" || echo "$B")
  if take "$from" "$t/$1.snap" && restore "$to" "$t/$1.snap"; then
    grn "ok: a snapshot taken by $1 restores on $2"
  else
    red "failed: a snapshot taken by $1 on $2"; tail -5 "$t/take.log"; fail=1
  fi
done

# a save killed midway: the snapshot file is the last good one
sock=$t/k.sock
take "$B" "$t/keep.snap" || { red "failed: the first snapshot"; fail=1; }
cp "$t/keep.snap" "$t/keep.orig"
( (slp 8; slp 40) | "$B" --mem 1024 --cpus 2 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --control "$sock" --cmdline "console=ttyAMA0 quiet" > "$t/kill.log" 2>&1 & )
slp 12
pid=$(pgrep -f -- "--control $sock" | head -1)
( echo "snapshot $t/keep.snap" | nc -U "$sock" > /dev/null 2>&1 & )
# the save of 1 GiB of RAM takes a while: kill it after it began
sleep 0.05; [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; slp 1
mid=""; [ -e "$t/keep.snap.bend-vmm-tmp" ] && mid=" (killed while writing the temporary file)"
if cmp -s "$t/keep.snap" "$t/keep.orig" && restore "$B" "$t/keep.snap"; then
  grn "ok: a save killed midway leaves the last snapshot whole$mid"
else
  red "failed: a killed save damaged the snapshot"; fail=1
fi

[ $fail = 0 ] && grn "SNAPCOMPAT OK" || red "SNAPCOMPAT FAILED"
exit $fail
