#!/usr/bin/env bash
# x86_64 guests on this host's KVM (Linux x86_64, /dev/kvm): Alpine's virt
# kernel with the guest suite of tests/guest/rootfs (scripts/guest-assets-x86.sh),
# as scripts/check-host.sh runs it on arm64:
#   1. the guest suite: CPUs, virtio-blk (and a read-only disk), virtio-rng,
#      timers and interrupts, the CMOS clock, hvc0
#   2. devices: the NAT (DHCP, ping, HTTP to the host, DNS), 9p, vsock both
#      ways, --forward
#   3. lifecycle: SIGTERM and the control socket's powerdown press the
#      power button; status json; the guest's own poweroff ends the VMM
# Needs a built VMM (out/bend-vmm, or out/main), gcc, curl, python3, nc,
# unsquashfs.
set -uo pipefail
cd "$(dirname "$0")/../.."
[ -w /dev/kvm ] || { echo "x86-check: needs /dev/kvm"; exit 2; }
vmm=out/bend-vmm; [ -x $vmm ] || vmm=out/main
fail=0
red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
alarm() { local t=$1; shift; timeout "$t" "$@"; }
drive() { local t=$1; shift; python3 scripts/drive.py "$t" "$@"; }
scripts/guest-assets-x86.sh >/dev/null || { red "guest assets failed"; exit 1; }
k=out/x86/vmlinuz-virt; rd=out/x86/guest.cpio; con="console=ttyS0"

echo "== 0. what the guest sees"
out=$(drive 90 "busybox shell" 'cat /proc/interrupts; dmesg | grep -i -E "virtio|LNRO|irq|eth0|rng" | tail -40; ip link; echo DIAG-DONE\n' "DIAG-DONE" 'poweroff -f\n' -- \
  $vmm --mem 512 --kernel $k --initrd $rd --cmdline "$con" 2>&1 | tr -d '\r')
grep -a -v '^\[' <<<"$out" | tail -60

echo "== 1. the guest suite"
dd if=/dev/zero of=out/x86/disk.img bs=1048576 count=8 2>/dev/null
printf 'BEND-DISK-SECTOR0' | dd of=out/x86/disk.img conv=notrunc 2>/dev/null
cp out/x86/disk.img out/x86/disk2.img
out=$( (alarm 180 $vmm --mem 1024 --cpus 2 --kernel $k --initrd $rd --disk out/x86/disk.img,out/x86/disk2.img:ro --cmdline "$con bendtest bendcpus=2") 2>&1 < /dev/null)
if grep -q GUEST-TESTS-DONE <<<"$out" && ! grep -q "GUEST-TEST FAIL" <<<"$out"; then
  grn "ok: guest tests ($(grep -c 'GUEST-TEST PASS' <<<"$out") passed, $(grep -c 'GUEST-TEST SKIP' <<<"$out") skipped)"
  grep -a "GUEST-TEST SKIP" <<<"$out"
else
  red "failed: guest tests"; grep -a "GUEST\|Kernel panic\|bend-vmm" <<<"$out" | tail -30; fail=1
fi
grep -q "stopped (0)" <<<"$out" && grn "ok: the guest's poweroff ends the VMM (ACPI S5)" || { red "failed: poweroff"; tail -5 <<<"$out"; fail=1; }

echo "== 2. devices"
www=$(mktemp -d); share=$(mktemp -d)
echo BEND-HTTP-OK > "$www/hello.txt"; echo BEND-9P-OK > "$share/hello.txt"
port=$((20000 + RANDOM % 20000))
(cd "$www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & http=$!
sleep 1
out=$( (alarm 120 $vmm --mem 1024 --cpus 2 --kernel $k --initrd $rd --share "$share" --cmdline "$con bendtest benchttp=$port benchdns bendshare quiet") 2>&1 < /dev/null)
kill $http 2>/dev/null
for t in rtc hvc0-write net-dhcp net-ping-gateway net-http net-dns p9-mount p9-read p9-write p9-mkdir; do
  if grep -q "GUEST-TEST PASS $t" <<<"$out"; then grn "ok: guest $t"; else red "failed: guest $t"; grep -a "GUEST-TEST.* $t" <<<"$out"; fail=1; fi
done
grep -q HVC0-MARKER-OK <<<"$out" && grn "ok: hvc0 output reaches the host" || { red "failed: hvc0 output"; fail=1; }
[ "$(cat "$share/guest.txt" 2>/dev/null)" = from-guest ] && grn "ok: 9p write reaches the host" || { red "failed: 9p write on the host"; fail=1; }
rm -rf "$www" "$share"
vs=$(mktemp -d)/vs.sock
out=$( (alarm 120 python3 scripts/vsock-test.py "$vs" $vmm --mem 512 --kernel $k --initrd $rd --vsock "$vs" --cmdline "$con bendtest bendvsock quiet") 2>&1 )
grep -q "GUEST-TEST PASS vsock-client" <<<"$out" && grn "ok: vsock guest -> host" || { red "failed: vsock guest -> host"; grep -a -i vsock <<<"$out" | tail -5; fail=1; }
grep -q "GUEST-TEST PASS vsock-server" <<<"$out" && grep -q HOST-VSOCK-OK <<<"$out" && grn "ok: vsock host -> guest" || { red "failed: vsock host -> guest"; grep -a -i vsock <<<"$out" | tail -5; fail=1; }
fport=$((20000 + RANDOM % 20000))
(sleep 20; exec 3<>/dev/tcp/127.0.0.1/$fport && cat <&3 > "$(dirname "$vs")/fwd.out") &
out=$(drive 90 "busybox shell" 'echo forward-ok | nc -l -p 8080; echo FWD-DONE\n' "FWD-DONE" 'poweroff -f\n' -- \
  $vmm --mem 512 --kernel $k --initrd $rd --forward "127.0.0.1:$fport:8080" --cmdline "$con quiet" 2>&1 | tr -d '\r')
grep -q forward-ok "$(dirname "$vs")/fwd.out" 2>/dev/null && grn "ok: --forward host -> guest" || { red "failed: --forward"; tail -5 <<<"$out"; fail=1; }
rm -rf "$(dirname "$vs")"

echo "== 3. lifecycle"
t=$(mktemp -d)
for how in sigterm powerdown; do
  $vmm --mem 256 --kernel $k --initrd $rd --control "$t/p.sock" --cmdline "$con quiet" < /dev/null > "$t/p.log" 2>&1 & p=$!
  sleep 6
  if [ $how = sigterm ]; then kill -TERM $p; else
    s=$(echo "status json" | nc -U "$t/p.sock"); echo "status json: $s"
    [ "$(echo powerdown | nc -U "$t/p.sock")" = "powering down" ] || echo "no reply" >> "$t/p.log"
  fi
  for i in $(seq 16); do kill -0 $p 2>/dev/null || break; sleep 0.5; done
  kill -9 $p 2>/dev/null; wait $p; code=$?
  [ $code = 0 ] && grep -q "GUEST: power button" "$t/p.log" && grn "ok: $how powers the guest off (its power button)" || { red "failed: $how (exit $code)"; tail -5 "$t/p.log"; fail=1; }
done
o=$(alarm 20 $vmm --mem 256 --kernel $k --initrd $rd --control "$t/s.sock" --cmdline "$con quiet" < /dev/null 2>&1 & sleep 5; echo "snapshot $t/x.snap" | nc -U "$t/s.sock"; echo quit | nc -U "$t/s.sock" >/dev/null)
grep -q "error 95" <<<"$o" && grn "ok: snapshots are refused on x86_64 (not yet)" || { red "failed: snapshot refusal"; tail -3 <<<"$o"; fail=1; }
rm -rf "$t"

if [ $fail = 0 ]; then grn "X86-CHECK OK"; else red "X86-CHECK FAILED"; fi
exit $fail
