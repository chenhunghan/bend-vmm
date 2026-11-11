#!/usr/bin/env bash
# Paired A/B benchmark of two bend-vmm builds (C_TO_BEND.md, stage 0).
#   scripts/bench/ab.sh [-n PAIRS] [-m METRICS] [--margin M=V ...] A B
# A and B are built binaries or git revisions (a revision is checked out in
# a worktree and built once into out/c-to-bend/bin/<sha>). METRICS is a
# comma list (default exit):
#   exit   200000 UART stores (spam.bin) less an empty payload, per store
#   boot   the tiny Linux (out/linux) from launch to BEND-VMM-BOOT-OK
#   guest  the busybox guest's benchmarks (tests/guest/rootfs/bench.sh):
#          mmio-exit, disk, NAT, 9p; one run gives every metric
# PAIRS (default 30) pairs run interleaved, each in a random AB or BA order,
# after one warmup run of each. Every observation is kept in
# out/c-to-bend/ab-<time>/obs.tsv; scripts/bench/stats.py prints the paired
# report (report.txt) and decides: exit 1 when a metric is slower. A
# missing value, a timeout or a guest failure stops the run with status 2:
# a broken run never reads as a comparison. Each pair waits for an idle
# host (1-minute load under AB_MAXLOAD, default 4).
set -uo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
pairs=30; metrics=exit; margins=()
while [ $# -gt 2 ]; do
  case $1 in
    -n) pairs=$2; shift 2 ;;
    -m) metrics=$2; shift 2 ;;
    --margin) margins+=(--margin "$2"); shift 2 ;;
    *) echo "ab.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
[ $# = 2 ] || { sed -n '2,18p' "$0"; exit 2; }
mkdir -p out/c-to-bend/bin
die() { echo "ab.sh: $*" >&2; exit 2; }

# a binary path, or a revision built into out/c-to-bend/bin/<sha>
resolve() {
  if [ -f "$1" ] && [ -x "$1" ]; then (cd "$(dirname "$1")" && echo "$PWD/$(basename "$1")"); return; fi
  local sha; sha=$(git rev-parse --verify -q "$1^{commit}") || die "$1 is neither a binary nor a revision"
  local bin=$root/out/c-to-bend/bin/$sha
  if [ ! -x "$bin" ]; then
    local wt=$root/out/c-to-bend/src-$sha
    git worktree add -q --detach "$wt" "$sha" >&2 || die "worktree for $1"
    (cd "$wt" && scripts/build.sh host/main.bend "$bin" >&2) || { git worktree remove --force "$wt"; die "build of $1"; }
    git worktree remove --force "$wt"
  fi
  echo "$bin"
}
A=$(resolve "$1") || exit 2
B=$(resolve "$2") || exit 2
run=out/c-to-bend/ab-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
obs=$run/obs.tsv
printf 'pair\torder\tmetric\tunit\tA\tB\n' > "$obs"
{
  echo "A $1 -> $A ($(shasum -a 256 "$A" | cut -c1-16))"
  echo "B $2 -> $B ($(shasum -a 256 "$B" | cut -c1-16))"
  echo "source $(git rev-parse HEAD)"
  echo "bend $(bend version 2>/dev/null | head -1)"
  echo "clang $(clang --version 2>/dev/null | head -1)"
  echo "host $(uname -srm) $(sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 'model name' /proc/cpuinfo 2>/dev/null)"
  echo "metrics $metrics pairs $pairs date $(date -u +%FT%TZ)"
} > "$run/meta.txt"
cat "$run/meta.txt"

clock=scripts/bench/clock.py
need() { [ -f "$1" ] || { "${@:2}" >/dev/null || die "cannot make $1"; }; }
case ",$metrics," in *,exit,*) need out/guest/hello.bin scripts/guest.sh hello; need out/guest/spam.bin scripts/guest.sh spam ;; esac
case ",$metrics," in *,boot,*) scripts/linux-assets.sh >/dev/null || die "linux assets" ;; esac

t=$(mktemp -d)
http=; sink=; source=
cleanup() { [ -n "$http" ] && kill $http $sink $source 2>/dev/null; rm -rf "$t"; }
trap cleanup EXIT
case ",$metrics," in *,guest,*)
  scripts/guest-assets.sh >/dev/null || die "guest assets"
  head -c 268435456 /dev/urandom > "$t/disk.img"
  mkdir "$t/www" "$t/share"
  head -c 268435456 /dev/urandom > "$t/www/big"; echo 268435456 > "$t/www/size"
  ln "$t/www/big" "$t/share/big"; cp "$t/www/size" "$t/share/size"
  port=$((20000 + RANDOM % 20000))
  (cd "$t/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & http=$!
  python3 scripts/bench/sink.py $((port + 1)) 268435456 & sink=$!
  python3 scripts/bench/source.py $((port + 2)) 268435456 & source=$!
  sleep 1 ;;
esac

# one observation of every metric for binary $1: "metric unit value" lines
observe() {
  local bin=$1 o t0 t1
  case ",$metrics," in *,exit,*)
    t0=$(python3 $clock 60 x "$bin" --payload out/guest/hello.bin | awk '/^TOTAL/{print $2}')
    t1=$(python3 $clock 60 x "$bin" --payload out/guest/spam.bin | awk '/^TOTAL/{print $2}')
    [ -n "$t0" ] && [ -n "$t1" ] || die "exit: no result from $bin"
    awk -v a="$t0" -v b="$t1" 'BEGIN { printf "exit us %.4f\n", (b - a) * 1e6 / 200000 }' ;;
  esac
  case ",$metrics," in *,boot,*)
    o=$(python3 $clock 60 BEND-VMM-BOOT-OK "$bin" --kernel out/linux/linux --initrd out/linux/initrd.cpio | awk '/^AT /{print $3}')
    [ -n "$o" ] || die "boot: no marker from $bin"
    echo "boot ms $(awk -v s="$o" 'BEGIN { printf "%.1f", s * 1000 }')" ;;
  esac
  case ",$metrics," in *,guest,*)
    "$bin" --mem 1024 --cpus 2 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk "$t/disk.img" --share "$t/share" \
      --cmdline "console=ttyAMA0 quiet bendbench benchttp=$port" > "$t/run.log" 2>&1 &
    local vm=$! n=0
    while kill -0 $vm 2>/dev/null && ! grep -q BENCH-DONE "$t/run.log"; do
      sleep 0.5; n=$((n + 1)); [ $n -lt 600 ] || { kill $vm; die "guest: timeout on $bin"; }
    done
    wait $vm 2>/dev/null
    grep -q BENCH-DONE "$t/run.log" || { tail -20 "$t/run.log" >&2; die "guest: the benchmarks did not finish on $bin"; }
    tr -d '\r' < "$t/run.log" | awk '/^BENCH [a-z0-9]/ && $2 != "guest-init" && $4 != "B" && $4 != "errno" { print $2, $4, $3 }' ;;
  esac
}

pair() { # pair number, order: append both observations, joined by metric
  local i=$1 ord=$2 x y
  if [ "$ord" = AB ]; then x=$(observe "$A") || exit 2; y=$(observe "$B") || exit 2
  else y=$(observe "$B") || exit 2; x=$(observe "$A") || exit 2; fi
  join <(sort <<<"$x") <(sort <<<"$y") | awk -v i="$i" -v o="$ord" '$2 == $4 { printf "%s\t%s\t%s\t%s\t%s\t%s\n", i, o, $1, $2, $3, $5 }' >> "$obs"
  [ "$(awk -F'\t' -v i="$i" '$1 == i' "$obs" | wc -l)" -eq "$(wc -l <<<"$x")" ] || die "pair $i: A and B gave different metrics"
}

# an idle host: wait until the 1-minute load is under AB_MAXLOAD (default 4)
load() { sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || cut -d' ' -f1 /proc/loadavg; }
idle() { local w=0; until awk -v l="$(load)" -v m="${AB_MAXLOAD:-4}" 'BEGIN { exit !(l < m) }'; do
  [ $w = 0 ] && echo "ab.sh: waiting for load $(load) < ${AB_MAXLOAD:-4}" >&2; w=1; sleep 20; done; }
idle
observe "$A" >/dev/null || exit 2; observe "$B" >/dev/null || exit 2   # warmup
for i in $(seq "$pairs"); do
  idle
  if [ $((RANDOM % 2)) = 0 ]; then pair "$i" AB; else pair "$i" BA; fi || exit 2
  printf '\rpair %d/%d' "$i" "$pairs" >&2
done
echo >&2
python3 scripts/bench/stats.py "$obs" "${margins[@]}" | tee "$run/report.txt"
status=${PIPESTATUS[0]}
echo "observations: $obs"
exit "$status"
