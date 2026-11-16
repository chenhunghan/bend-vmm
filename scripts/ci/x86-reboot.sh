#!/usr/bin/env bash
# Debug: reboots an x86_64 guest 10 times; where one hangs, pauses it (a
# kick) so the trace says where its vCPU was.
set -uo pipefail
cd "$(dirname "$0")/../.."
scripts/build.sh host/main.bend out/bend-vmm >/dev/null || exit 1
scripts/guest-assets-x86.sh >/dev/null || exit 1
for i in $(seq 10); do
  rm -f /tmp/rb.sock
  ( (sleep 6; printf 'reboot -f\n'; sleep 20; printf 'poweroff -f\n'; sleep 2) | BEND_VMM_TRACE=1 timeout 60 ./out/bend-vmm --mem 1024 --kernel out/x86/vmlinuz-virt --initrd out/x86/guest.cpio --control /tmp/rb.sock > /tmp/rb.log 2>&1 & )
  sleep 24
  for k in 1 2 3; do echo pause | nc -U /tmp/rb.sock >/dev/null 2>&1; sleep 0.5; echo resume | nc -U /tmp/rb.sock >/dev/null 2>&1; sleep 0.5; done
  sleep 6
  echo "round $i: ups $(grep -c 'GUEST: up' /tmp/rb.log), stopped0 $(grep -c 'stopped (0)' /tmp/rb.log)"
  grep -a -o -E 'machine restart|bend-vmm: [a-z ()0-9]*|\[trace\] (io (in|out) port=[0-9a-f]+ size=[0-9]|kvm exit [0-9]+|kvm_run.*)' /tmp/rb.log | grep -v 'port=3f[89abcdef]\|port=7[01] ' | awk '/machine restart/{p=1} p' | uniq -c | head -12
done
