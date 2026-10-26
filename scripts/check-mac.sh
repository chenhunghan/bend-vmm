#!/usr/bin/env bash
# Level 4 of the verification ladder (docs/DESIGN.md): builds the host layer
# and runs real guests on Hypervisor.framework. macOS on Apple Silicon only.
#   1. smoke: a bare-metal payload prints through UART traps and powers off
#      through PSCI, driven by host/smoke.bend (host effects only).
#   2. (when host/main.bend exists) the same payloads on the full machine.
#   3. Linux (scripts/linux-assets.sh) boots to its init marker and powers off.
set -uo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ] || { echo "check-mac: needs macOS on arm64"; exit 2; }
fail=0
# Build artifacts go when the check ends (scripts/clean.sh keeps downloaded assets).
trap 'scripts/clean.sh' EXIT
red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }

# expect <name> <timeout-s> <pattern> <cmd...>: runs cmd, requires pattern in its output.
expect() {
  name=$1 secs=$2 pat=$3; shift 3
  out=$( (perl -e 'alarm shift; exec @ARGV' "$secs" "$@") 2>&1 )
  if grep -q -- "$pat" <<<"$out"; then grn "ok: $name"; else red "failed: $name"; echo "$out" | tail -20; fail=1; fi
}

echo "== native tests"
scripts/check-native.sh 2 | tail -1 | grep -q "CHECK-NATIVE OK" || { red "native tests failed (scripts/check-native.sh)"; fail=1; }

echo "== build"
for g in tests/guest/*.S; do scripts/guest.sh "$(basename "$g" .S)" >/dev/null || fail=1; done
scripts/build-mac.sh host/smoke.bend out/smoke >/dev/null || { red "smoke build failed"; exit 1; }

echo "== 1. host smoke"
expect "smoke prints" 20 "hello from the guest" ./out/smoke out/guest/hello.bin
expect "smoke powers off" 20 "smoke: done 1" ./out/smoke out/guest/hello.bin

if [ -f host/main.bend ]; then
  echo "== 2. machine"
  scripts/build-mac.sh host/main.bend out/bend-vmm >/dev/null || { red "bend-vmm build failed"; exit 1; }
  expect "machine hello" 20 "hello from the guest" ./out/bend-vmm --payload out/guest/hello.bin
fi

if [ -f host/main.bend ] && [ "${SKIP_LINUX:-0}" != 1 ]; then
  echo "== 3. linux boot"
  scripts/linux-assets.sh >/dev/null || { red "linux assets failed"; exit 1; }
  expect "linux boots to init" 120 "BEND-VMM-BOOT-OK" ./out/bend-vmm --kernel out/linux/linux --initrd out/linux/initrd.cpio
  expect "linux powers off" 120 "stopped (0)" ./out/bend-vmm --kernel out/linux/linux --initrd out/linux/initrd.cpio
  expect "linux smp (4 cpus)" 120 "Brought up 1 node, 4 CPUs" ./out/bend-vmm --cpus 4 --kernel out/linux/linux --initrd out/linux/initrd.cpio
fi

if [ -f host/main.bend ] && [ "${SKIP_GUEST:-0}" != 1 ]; then
  echo "== 4. guest userspace (Ubuntu kernel, busybox)"
  scripts/guest-assets.sh >/dev/null || { red "guest assets failed"; exit 1; }
  dd if=/dev/zero of=out/guest/disk.img bs=1m count=8 2>/dev/null
  printf 'BEND-DISK-SECTOR0' | dd of=out/guest/disk.img conv=notrunc 2>/dev/null
  cp out/guest/disk.img out/guest/disk2.img
  out=$( (perl -e 'alarm 180; exec @ARGV' ./out/bend-vmm --mem 1024 --cpus 2 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk out/guest/disk.img,out/guest/disk2.img:ro --cmdline "console=ttyAMA0 bendtest bendcpus=2") 2>&1 )
  if grep -q GUEST-TESTS-DONE <<<"$out" && ! grep -q "GUEST-TEST FAIL" <<<"$out"; then
    grn "ok: guest tests ($(grep -c 'GUEST-TEST PASS' <<<"$out") passed, $(grep -c 'GUEST-TEST SKIP' <<<"$out") skipped)"
  else
    red "failed: guest tests"; grep -a "GUEST" <<<"$out" | tail -20; fail=1
  fi
  # devices: a host HTTP server and a shared directory for the net and 9p tests
  www=$(mktemp -d); share=$(mktemp -d)
  echo BEND-HTTP-OK > "$www/hello.txt"; echo BEND-9P-OK > "$share/hello.txt"
  port=$((20000 + RANDOM % 20000))
  (cd "$www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & http=$!
  sleep 1
  out=$( (perl -e 'alarm 120; exec @ARGV' ./out/bend-vmm --mem 1024 --cpus 2 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --share "$share" --cmdline "console=ttyAMA0 bendtest benchttp=$port benchdns bendshare quiet") 2>&1 )
  kill $http 2>/dev/null
  for t in rtc hvc0-write net-dhcp net-ping-gateway net-http net-dns p9-mount p9-read p9-write p9-mkdir; do
    if grep -q "GUEST-TEST PASS $t" <<<"$out"; then grn "ok: guest $t"; else red "failed: guest $t"; fail=1; fi
  done
  grep -q HVC0-MARKER-OK <<<"$out" && grn "ok: hvc0 output reaches the host" || { red "failed: hvc0 output"; fail=1; }
  [ "$(cat "$share/guest.txt" 2>/dev/null)" = from-guest ] && grn "ok: 9p write reaches the host" || { red "failed: 9p write on the host"; fail=1; }
  rm -rf "$www" "$share"
  out=$( (perl -e 'alarm 120; exec @ARGV' ./out/bend-vmm --mem 4096 --cpus 8 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --disk out/guest/disk.img --cmdline "console=ttyAMA0 bendtest bendcpus=8 quiet") 2>&1 )
  if grep -q GUEST-TESTS-DONE <<<"$out" && ! grep -q "GUEST-TEST FAIL" <<<"$out"; then grn "ok: 8 cpus, 4 GiB (RAM past 4 GiB)"; else red "failed: 8 cpus, 4 GiB"; grep -a GUEST <<<"$out" | tail; fail=1; fi
  out=$( ( (sleep 20; printf 'echo hi-$((40+2))\n'; sleep 2; printf 'poweroff -f\n'; sleep 5) | perl -e 'alarm 60; exec @ARGV' ./out/bend-vmm --mem 1024 --kernel out/guest/Image --initrd out/guest/guest.cpio) 2>&1 )
  if grep -q "^hi-42" <<<"$out"; then grn "ok: console input"; else red "failed: console input"; tail -5 <<<"$out"; fail=1; fi
  out=$( ( (sleep 20; printf 'reboot -f\n'; sleep 25; printf 'poweroff -f\n'; sleep 5) | perl -e 'alarm 90; exec @ARGV' ./out/bend-vmm --mem 1024 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio) 2>&1 )
  if [ "$(grep -c 'GUEST: up' <<<"$out")" = 2 ] && grep -q "stopped (0)" <<<"$out"; then grn "ok: reboot (gzip kernel)"; else red "failed: reboot"; grep -a -E "GUEST|reset|stopped" <<<"$out"; fail=1; fi
fi

if [ $fail = 0 ]; then grn "CHECK-MAC OK"; else red "CHECK-MAC FAILED"; fi
exit $fail
