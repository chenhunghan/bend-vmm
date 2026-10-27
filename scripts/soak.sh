#!/usr/bin/env bash
# A long run: the busybox guest (2 vCPUs) loops over disk, shared-folder,
# network and memory traffic, checking every byte it reads back
# (tests/guest/rootfs/soak.sh), while the host pauses and resumes it through
# the control socket every minute (SOAK_PAUSE seconds) and samples the VMM's
# memory every 10 s.
#   scripts/soak.sh [MINUTES]         default 10
# Passes when every round checked out, the guest finished, and the VMM's
# resident memory at the end is within 20% of its size after the first
# quarter (a leak grows it round after round). The samples go to
# out/soak/<host>-<time>.tsv (seconds, RSS KiB, rounds), the guest's console
# next to them (.log).
# SKIP_BUILD=1 uses out/bend-vmm as it is; VMM=path runs that binary instead.
set -uo pipefail
cd "$(dirname "$0")/.."
mins=${1:-10}
vmm=${VMM:-./out/bend-vmm}
[ -n "${VMM:-}" ] || [ "${SKIP_BUILD:-0}" = 1 ] || scripts/build.sh host/main.bend out/bend-vmm >/dev/null || exit 1
scripts/guest-assets.sh >/dev/null || exit 1
mkdir -p out/soak
res=out/soak/$(uname -s | tr A-Z a-z)-$(uname -m)-$(date +%Y%m%d-%H%M%S).tsv
t=$(mktemp -d)
trap 'kill $http 2>/dev/null; cp "$t/run.log" "${res%.tsv}.log" 2>/dev/null; rm -rf "$t"' EXIT
dd if=/dev/zero of="$t/disk.img" bs=1048576 count=0 seek=64 2>/dev/null
mkdir "$t/www" "$t/share"
head -c 8388608 /dev/urandom > "$t/www/big"
python3 -c 'import hashlib, sys; print(hashlib.md5(open(sys.argv[1], "rb").read()).hexdigest())' "$t/www/big" > "$t/www/big.md5"
port=$((20000 + RANDOM % 20000))
(cd "$t/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & http=$!
sleep 1
sock=$t/vm.sock
$vmm --mem 512 --cpus 2 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk "$t/disk.img" --share "$t/share" \
  --control "$sock" --cmdline "console=ttyAMA0 quiet bendsoak=$mins benchttp=$port" < /dev/null > "$t/run.log" 2>&1 &
vm=$!
start=$(date +%s); deadline=$((start + mins * 60 + 300)); last_pause=$start; pauses=0
printf 'seconds\trss_kib\trounds\n' > "$res"
while kill -0 $vm 2>/dev/null && [ "$(date +%s)" -lt $deadline ]; do
  sleep 10
  now=$(date +%s)
  rss=$(ps -o rss= -p $vm 2>/dev/null | tr -d ' ')
  rounds=$(grep -c '^SOAK-ITER' "$t/run.log")
  [ -n "$rss" ] && printf '%s\t%s\t%s\n' $((now - start)) "$rss" "$rounds" >> "$res"
  if [ $((now - last_pause)) -ge "${SOAK_PAUSE:-60}" ] && [ -S "$sock" ]; then
    [ "$(echo pause | nc -U "$sock")" = paused ] && sleep 1 && [ "$(echo resume | nc -U "$sock")" = running ] && pauses=$((pauses + 1))
    last_pause=$now
  fi
done
kill $vm 2>/dev/null; wait $vm 2>/dev/null
log=$(tr -d '\r' < "$t/run.log")
rounds=$(grep -c '^SOAK-ITER' <<<"$log")
fails=$(grep -c '^SOAK-FAIL' <<<"$log")
# RSS after the first quarter, and at the end
n=$(($(wc -l < "$res") - 1))
q=$(awk -v n="$n" 'NR == int(n / 4) + 2 { print $2 }' "$res")
e=$(tail -1 "$res" | cut -f2)
growth=$(awk -v q="${q:-0}" -v e="${e:-0}" 'BEGIN { if (q > 0) printf "%.1f", (e - q) * 100 / q; else print "nan" }')
echo "soak: $mins min, $rounds rounds, $fails failures, $pauses pause/resume cycles, RSS ${q:-?} -> ${e:-?} KiB ($growth%)"
echo "samples: $res"
ok=1
grep -q '^SOAK-DONE' <<<"$log" || { echo "soak: the guest did not finish"; tail -20 <<<"$log"; ok=0; }
[ "$fails" = 0 ] || { grep '^SOAK-FAIL' <<<"$log" | head; ok=0; }
[ "$rounds" -gt 0 ] || ok=0
awk -v g="$growth" 'BEGIN { exit !(g == "nan" || g + 0 > 20) }' && { echo "soak: memory grew more than 20%"; ok=0; }
[ $ok = 1 ] && echo "SOAK OK" || { echo "SOAK FAILED"; exit 1; }
