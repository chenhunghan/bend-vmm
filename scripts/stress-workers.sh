#!/usr/bin/env bash
# Stress of the vCPU worker handoff (C_TO_BEND.md, stage 5, against the
# current C worker: host/hvf.c's hvf_vcpu_run / hvf_thread). A guest with
# every vCPU busy (a spinning loop each, and one printing a heartbeat every
# second) is paused, resumed, asked its status and snapshotted back to back
# through the control socket, ROUNDS times (default 200; a snapshot every
# 20th). Passes when every command got its answer, the heartbeat kept
# coming after the last round (no vCPU stuck parked or lost a wakeup), the
# guest's clock then runs with the host's (timers still fire on time; it
# stops while paused, by design), and the last snapshot restores.
#   scripts/stress-workers.sh [ROUNDS] [CPUS]     (default 200 4)
# VMM=path runs that binary (default out/bend-vmm, built when missing).
set -uo pipefail
cd "$(dirname "$0")/.."
rounds=${1:-200}; cpus=${2:-4}
vmm=${VMM:-./out/bend-vmm}
[ -x "$vmm" ] || scripts/build.sh host/main.bend out/bend-vmm >/dev/null || exit 1
scripts/guest-assets.sh >/dev/null || exit 1
red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
t=$(mktemp -d); sock=$t/vm.sock
trap 'echo quit | nc -U "$sock" >/dev/null 2>&1; [ -f "$t/feeder" ] && kill "$(cat "$t/feeder")" 2>/dev/null; rm -rf "$t"' EXIT
spin='i=0; while [ $i -lt '"$cpus"' ]; do (while :; do :; done) & i=$((i+1)); done'
beat='(while :; do echo BEAT $(cut -d" " -f1 /proc/uptime); sleep 1; done) &'
# the guest's input: the two loops, then nothing until the end (the feeder's
# sleep is killed on exit, and holds none of this script's output open)
( sh -c 'echo $$ > "$1"; sleep 8; printf "%s\n%s\n" "$2" "$3"; exec sleep 3600' sh "$t/feeder" "$spin" "$beat" </dev/null 2>/dev/null | "$vmm" --mem 512 --cpus "$cpus" --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --control "$sock" --cmdline "console=ttyAMA0 quiet" > "$t/run.log" 2>&1 & )
# (the console echoes the typed loop too: wait for a beat line itself)
for _ in $(seq 100); do grep -aq '^BEAT [0-9]' "$t/run.log" 2>/dev/null && break; sleep 0.2; done
grep -aq '^BEAT [0-9]' "$t/run.log" || { red "failed: the guest did not start beating"; tail -5 "$t/run.log"; exit 1; }
t0=$(python3 -c 'import time; print(time.monotonic())')
g0=$(grep -a '^BEAT [0-9]' "$t/run.log" | tail -1 | awk '{print $2}' | tr -d '\r')
bad=0; fail=0
for i in $(seq "$rounds"); do
  [ "$(echo pause | nc -U "$sock")" = paused ] || { bad=$((bad + 1)); echo "round $i: pause"; }
  [ "$(echo status | nc -U "$sock")" = paused ] || { bad=$((bad + 1)); echo "round $i: status"; }
  if [ $((i % 20)) = 0 ]; then
    [ "$(echo "snapshot $t/vm.snap" | nc -U "$sock")" = saved ] || { bad=$((bad + 1)); echo "round $i: snapshot"; }
  fi
  [ "$(echo resume | nc -U "$sock")" = running ] || { bad=$((bad + 1)); echo "round $i: resume"; }
done
n0=$(grep -ac '^BEAT [0-9]' "$t/run.log")
# the guest's clock stops while it is paused: compare it with the host's
# over 6 s of running after the rounds (beats come each second: +-1.5 s)
sleep 1.2; ta=$(python3 -c 'import time; print(time.monotonic())'); ga=$(grep -a '^BEAT [0-9]' "$t/run.log" | tail -1 | awk '{print $2}' | tr -d '\r')
sleep 6
n1=$(grep -ac '^BEAT [0-9]' "$t/run.log")
t1=$(python3 -c 'import time; print(time.monotonic())')
g1=$(grep -a '^BEAT [0-9]' "$t/run.log" | tail -1 | awk '{print $2}' | tr -d '\r')
drift=$(python3 -c "print(abs(($g1 - $ga) - ($t1 - $ta)) < 1.5)" 2>/dev/null)
[ $bad = 0 ] && grn "ok: $rounds rounds of pause, status, resume ($((rounds / 20)) snapshots) on $cpus busy vCPUs: every command answered" || { red "failed: $bad commands unanswered"; fail=1; }
[ "$n1" -gt "$n0" ] && grn "ok: the guest kept running after the rounds (beats $n0 -> $n1)" || { red "failed: no heartbeat after the rounds"; tail -5 "$t/run.log"; fail=1; }
[ "$drift" = True ] && grn "ok: after the rounds the guest's clock runs with the host's ($(python3 -c "print(round($g1 - $ga, 1), 'vs', round($t1 - $ta, 1))") s)" || { red "failed: guest clock after the rounds ($ga -> $g1 over $ta -> $t1)"; fail=1; }
echo quit | nc -U "$sock" >/dev/null 2>&1; sleep 1
out=$(python3 scripts/drive.py 60 "restored" 'echo RESTORED-$((6*7))\n' "RESTORED-42" 'poweroff -f\n' -- "$vmm" --restore "$t/vm.snap" 2>&1)
grep -q "stopped (0)" <<<"$out" && grep -aq "^RESTORED-42" <<<"$(tr -d '\r' <<<"$out")" && grn "ok: the last snapshot restores" || { red "failed: restore of the last snapshot"; tail -5 <<<"$out"; fail=1; }
exit ${fail:-0}
