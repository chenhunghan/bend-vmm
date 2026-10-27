#!/usr/bin/env bash
# Benchmarks bend-vmm on this host's hypervisor and prints one line per
# metric; the results also go to out/bench/<host>-<time>.tsv.
#   scripts/bench.sh                  run every benchmark
#   scripts/bench.sh --compare FILE   also show the change from an earlier .tsv
# Metrics:
#   boot-*          wall time from launch: the tiny Linux (out/linux) to its
#                   init marker and to the VMM's exit, the median of 5 runs;
#                   the busybox guest to its userspace (cold, and from a
#                   snapshot on macOS)
#   exit-*          a bare-metal payload's 200000 UART stores, less an empty
#                   payload, per store: one guest exit handled end to end
#   mmio-exit       the same from a Linux process (tests/guest/bench.c)
#   disk-*          virtio-blk: sequential 1 MiB read and write, 4 KiB random
#                   reads (QD1), O_DIRECT on a 256 MiB image (written out)
#   net-*, 9p-*     a 256 MiB download from a host HTTP server through the NAT
#                   and a 256 MiB upload to a host socket, HTTP request
#                   latency, the shared folder's read, write and stat
#   rss-*           the VMM's resident memory after the guest benchmarks
# SKIP_BUILD=1 uses out/bend-vmm as it is.
set -uo pipefail
cd "$(dirname "$0")/.."
compare=""
[ "${1:-}" = --compare ] && compare=$2
host=$(uname -s | tr A-Z a-z)-$(uname -m)
mkdir -p out/bench
res=out/bench/$host-$(date +%Y%m%d-%H%M%S).tsv
: > "$res"
clock=scripts/bench/clock.py
rec() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$res"; printf '%-22s %10s %s\n' "$1" "$2" "$3"; }
median() { sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'; }
ms() { awk -v s="$1" 'BEGIN { printf "%.0f", s * 1000 }'; }

[ "${SKIP_BUILD:-0}" = 1 ] || scripts/build.sh host/main.bend out/bend-vmm >/dev/null || exit 1
scripts/guest.sh hello >/dev/null && scripts/guest.sh spam >/dev/null
scripts/linux-assets.sh >/dev/null && scripts/guest-assets.sh >/dev/null || exit 1
vmm=./out/bend-vmm

# boot
a=(); b=()
for i in 1 2 3 4 5; do
  o=$(python3 $clock 60 "BEND-VMM-BOOT-OK" $vmm --kernel out/linux/linux --initrd out/linux/initrd.cpio)
  a+=("$(awk '/^AT /{print $3}' <<<"$o")"); b+=("$(awk '/^TOTAL/{print $2}' <<<"$o")")
done
rec boot-tiny-init "$(ms "$(printf '%s\n' "${a[@]}" | median)")" ms
rec boot-tiny-exit "$(ms "$(printf '%s\n' "${b[@]}" | median)")" ms
o=$(python3 $clock 60 "GUEST: up" $vmm --mem 512 --kernel out/guest/Image --initrd out/guest/guest.cpio --cmdline "console=ttyAMA0 quiet bendbench")
rec boot-busybox-init "$(ms "$(awk '/^AT /{print $NF}' <<<"$o")")" ms

# exits
t0=$(python3 $clock 60 "x" $vmm --payload out/guest/hello.bin | awk '/^TOTAL/{print $2}')
t1=$(python3 $clock 60 "x" $vmm --payload out/guest/spam.bin | awk '/^TOTAL/{print $2}')
rec exit-uart "$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", (b - a) * 1e6 / 200000 }')" us

# the guest benchmarks
t=$(mktemp -d)
# written out, not sparse: reads move real bytes, not holes
head -c 268435456 /dev/urandom > "$t/disk.img"
mkdir "$t/www" "$t/share"
# 256 MiB: the guest times with /proc/uptime (10 ms), so a transfer takes
# a few tenths of a second at least
head -c 268435456 /dev/urandom > "$t/www/big"; echo 268435456 > "$t/www/size"
ln "$t/www/big" "$t/share/big"; cp "$t/www/size" "$t/share/size"
port=$((20000 + RANDOM % 20000))
(cd "$t/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & http=$!
python3 scripts/bench/sink.py $((port + 1)) 268435456 & sink=$!
sleep 1
$vmm --mem 1024 --cpus 2 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk "$t/disk.img" --share "$t/share" \
  --cmdline "console=ttyAMA0 quiet bendbench benchttp=$port" > "$t/run.log" 2>&1 &
vm=$!
rss=0
while kill -0 $vm 2>/dev/null; do
  r=$(ps -o rss= -p $vm 2>/dev/null | tr -d ' '); [ -n "$r" ] && [ "$r" -gt "$rss" ] && rss=$r
  grep -q BENCH-DONE "$t/run.log" && break
  sleep 0.5
done
wait $vm 2>/dev/null
kill $http $sink 2>/dev/null
tr -d '\r' < "$t/run.log" | awk '/^BENCH [a-z0-9]/ && $2 != "guest-init" { print $2, $3, $4 }' | while read -r n v u; do rec "$n" "$v" "$u"; done
rec rss-peak "$((rss / 1024))" MiB
cp "$t/run.log" out/bench/guest.log
grep -q BENCH-DONE "$t/run.log" || { echo "bench: the guest benchmarks did not finish:"; tail -20 "$t/run.log"; }

# snapshots (macOS)
if [ "$(uname -s)" = Darwin ]; then
  sock=$t/vm.sock
  ( sleep 30 | $vmm --mem 1024 --cpus 2 --kernel out/guest/Image --initrd out/guest/guest.cpio --control "$sock" --cmdline "console=ttyAMA0 quiet" > "$t/snap.log" 2>&1 & )
  sleep 4
  s=$(python3 -c 'import time; print(time.monotonic())')
  r=$(echo "snapshot $t/vm.snap" | nc -U "$sock")
  e=$(python3 -c 'import time; print(time.monotonic())')
  echo quit | nc -U "$sock" >/dev/null; sleep 1
  if [ "$r" = saved ]; then
    rec snapshot-save "$(ms "$(awk -v s="$s" -v e="$e" 'BEGIN { print e - s }')")" ms
    rec snapshot-size "$(( $(du -k "$t/vm.snap" | cut -f1) / 1024 ))" MiB
    o=$(python3 $clock 30 "restored" sh -c "(sleep 1; echo 'poweroff -f') | $vmm --restore $t/vm.snap")
    rec boot-restore "$(ms "$(awk '/^AT /{print $NF}' <<<"$o")")" ms
  fi
fi
rm -rf "$t"

if [ -n "$compare" ]; then
  echo
  echo "change from $compare:"
  awk -F'\t' 'NR == FNR { old[$1] = $2; next } ($1 in old) && old[$1] > 0 {
    printf "%-22s %10s -> %-10s %+6.1f%%\n", $1, old[$1], $2, ($2 - old[$1]) * 100 / old[$1] }' "$compare" "$res"
fi
echo "results: $res"
