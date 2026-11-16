#!/usr/bin/env bash
# Boots an x86_64 Linux guest on this host's KVM (Linux x86_64): Alpine's
# virt kernel and a one-file initramfs (tests/guest/x86init.c) that reports
# the CPUs, the virtio devices, the interrupts and the clock, then powers
# off through ACPI. Needs gcc (static), curl, python3 and a built VMM
# (out/main, scripts/build.sh).
#   scripts/ci/x86-boot.sh [extra VMM flags...]
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p out/x86
v=3.20
base=https://dl-cdn.alpinelinux.org/alpine/v$v/releases/x86_64/netboot
[ -f out/x86/vmlinuz-virt ] || curl -fsSL --retry 5 -o out/x86/vmlinuz-virt "$base/vmlinuz-virt"
gcc -static -O2 -o out/x86/init tests/guest/x86init.c
python3 scripts/initramfs.py out/x86/init out/x86/initrd.cpio
log=out/x86/boot.log
set +e
timeout 300 out/main --kernel out/x86/vmlinuz-virt --initrd out/x86/initrd.cpio \
  --cmdline "console=ttyS0 earlyprintk=serial,ttyS0" --mem 512 --cpus 2 "$@" </dev/null >"$log" 2>&1
rc=$?
set -e
cat "$log"
echo "x86-boot: exit $rc"
grep -q 'x86-init: done' "$log" || { echo "x86-boot: FAILED: the guest's init did not finish"; exit 1; }
[ $rc = 0 ] || { echo "x86-boot: FAILED: the VMM did not power off cleanly"; exit 1; }
echo "x86-boot: OK"
