#!/usr/bin/env bash
# Level 4 of the verification ladder (docs/DESIGN.md): builds the host layer
# and runs real guests on this host's hypervisor: Hypervisor.framework on
# macOS (Apple Silicon), KVM on Linux (arm64, /dev/kvm).
# CHECK_SLOW=N stretches every timeout and pause N times (an emulated host,
# such as scripts/lima/linux-host.sh on an M1/M2 Mac); SKIP_NATIVE=1 skips
# the native test build; SKIP_BUILD=1 uses the binaries already in out/
# (bend-vmm, smoke, the guest payloads), as scripts/ci/emulated-kvm.sh does.
#   1. smoke: a bare-metal payload prints through UART traps and powers off
#      through PSCI, driven by host/smoke.bend (host effects only).
#   2. (when host/main.bend exists) the same payloads on the full machine.
#   3. Linux (scripts/linux-assets.sh) boots to its init marker and powers off.
#   4. the guest suite (tests/guest/rootfs/tests.sh), net, 9p, vsock, console.
#   5. lifecycle: pause, resume, snapshot, restore; SIGTERM and powerdown
#      press the guest's power button.
#   6. display: screendump, and the virtio keyboard and tablet driven through
#      the control socket's type and pointer commands.
#   7. UEFI: edk2 firmware boots Alpine's ISO (GRUB, Linux); an EFI variable
#      written by Linux survives a reboot in the --vars file.
#   8. qcow2 (with qemu-img): a qcow2 over a raw backing file, a compressed
#      image and a fresh one read and written by the guest; qemu-img checks
#      them and reads back what the guest wrote; a second bend-vmm cannot
#      open an image one writes, two overlays share a backing file.
#   9. (macOS) a disk image on a full host volume: guest writes fail (IOERR)
#      instead of being lost.
set -uo pipefail
cd "$(dirname "$0")/.."
host=$(uname -s)-$(uname -m)
case "$host" in
  Darwin-arm64) ;;
  Linux-aarch64) [ -w /dev/kvm ] || { echo "check-host: needs /dev/kvm"; exit 2; } ;;
  *) echo "check-host: needs macOS on Apple Silicon or Linux on arm64 with KVM"; exit 2 ;;
esac
SLOW=${CHECK_SLOW:-1}
# sleep and alarm, stretched by CHECK_SLOW
slp() { sleep $(( $1 * SLOW )); }
alarm() { local t=$1; shift; perl -e 'alarm shift; exec @ARGV' $(( t * SLOW )) "$@"; }
fail=0
# Build artifacts go when the check ends (scripts/clean.sh keeps downloaded assets).
trap 'scripts/clean.sh' EXIT
red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }

# drive <timeout-s> [<pattern> <text>]... -- <cmd...>: types each text once
# its pattern shows (scripts/drive.py), the timeout stretched by CHECK_SLOW.
drive() { local t=$1; shift; python3 scripts/drive.py $(( t * SLOW )) "$@"; }

# expect <name> <timeout-s> <pattern> <cmd...>: runs cmd, requires pattern in its output.
expect() {
  name=$1 secs=$2 pat=$3; shift 3
  out=$( (alarm "$secs" "$@") 2>&1 )
  if grep -q -- "$pat" <<<"$out"; then grn "ok: $name"; else red "failed: $name"; echo "$out" | tail -20; fail=1; fi
}

if [ "${SKIP_NATIVE:-0}" != 1 ]; then
  echo "== native tests"
  scripts/check-native.sh 2 | tail -1 | grep -q "CHECK-NATIVE OK" || { red "native tests failed (scripts/check-native.sh)"; fail=1; }
fi

echo "== build"
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  for g in tests/guest/*.S; do scripts/guest.sh "$(basename "$g" .S)" >/dev/null || fail=1; done
  scripts/build.sh host/smoke.bend out/smoke >/dev/null || { red "smoke build failed"; exit 1; }
fi

echo "== 1. host smoke"
expect "smoke prints" 20 "hello from the guest" ./out/smoke out/guest/hello.bin
expect "smoke powers off" 20 "smoke: done 1" ./out/smoke out/guest/hello.bin

if [ -f host/main.bend ]; then
  echo "== 2. machine"
  [ "${SKIP_BUILD:-0}" = 1 ] || scripts/build.sh host/main.bend out/bend-vmm >/dev/null || { red "bend-vmm build failed"; exit 1; }
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
  dd if=/dev/zero of=out/guest/disk.img bs=1048576 count=8 2>/dev/null
  printf 'BEND-DISK-SECTOR0' | dd of=out/guest/disk.img conv=notrunc 2>/dev/null
  cp out/guest/disk.img out/guest/disk2.img
  out=$( (alarm 180 ./out/bend-vmm --mem 1024 --cpus 2 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk out/guest/disk.img,out/guest/disk2.img:ro --cmdline "console=ttyAMA0 bendtest bendcpus=2") 2>&1 )
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
  slp 1
  out=$( (alarm 120 ./out/bend-vmm --mem 1024 --cpus 2 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --share "$share" --cmdline "console=ttyAMA0 bendtest benchttp=$port benchdns bendshare quiet") 2>&1 )
  kill $http 2>/dev/null
  for t in rtc hvc0-write net-dhcp net-ping-gateway net-http net-dns p9-mount p9-read p9-write p9-mkdir; do
    if grep -q "GUEST-TEST PASS $t" <<<"$out"; then grn "ok: guest $t"; else red "failed: guest $t"; fail=1; fi
  done
  grep -q HVC0-MARKER-OK <<<"$out" && grn "ok: hvc0 output reaches the host" || { red "failed: hvc0 output"; fail=1; }
  [ "$(cat "$share/guest.txt" 2>/dev/null)" = from-guest ] && grn "ok: 9p write reaches the host" || { red "failed: 9p write on the host"; fail=1; }
  rm -rf "$www" "$share"
  vs=$(mktemp -d)/v.sock
  out=$( (alarm 120 python3 scripts/vsock-test.py "$vs" ./out/bend-vmm --mem 512 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --vsock "$vs" --cmdline "console=ttyAMA0 bendtest bendvsock quiet") 2>&1 )
  grep -q "GUEST-TEST PASS vsock-client" <<<"$out" && grn "ok: vsock guest -> host (Unix socket ${vs##*/}_1234)" || { red "failed: vsock guest -> host"; fail=1; }
  grep -q "GUEST-TEST PASS vsock-server" <<<"$out" && grep -q HOST-VSOCK-OK <<<"$out" && grn "ok: vsock host -> guest (CONNECT 5000)" || { red "failed: vsock host -> guest"; grep -a -i vsock <<<"$out" | tail -5; fail=1; }
  rm -rf "$(dirname "$vs")"
  out=$( (alarm 120 ./out/bend-vmm --mem 4096 --cpus 8 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --disk out/guest/disk.img --cmdline "console=ttyAMA0 bendtest bendcpus=8 quiet") 2>&1 )
  if grep -q GUEST-TESTS-DONE <<<"$out" && ! grep -q "GUEST-TEST FAIL" <<<"$out"; then grn "ok: 8 cpus, 4 GiB (RAM past 4 GiB)"; else red "failed: 8 cpus, 4 GiB"; grep -a GUEST <<<"$out" | tail; fail=1; fi
  out=$(drive 60 "busybox shell" 'echo hi-$((40+2))\n' "hi-42" 'poweroff -f\n' -- ./out/bend-vmm --mem 1024 --kernel out/guest/Image --initrd out/guest/guest.cpio 2>&1)
  if grep -q "^hi-42" <<<"$out"; then grn "ok: console input"; else red "failed: console input"; tail -5 <<<"$out"; fail=1; fi
  out=$(drive 90 "busybox shell" 'reboot -f\n' "busybox shell" 'poweroff -f\n' -- ./out/bend-vmm --mem 1024 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio 2>&1)
  if [ "$(grep -c 'GUEST: up' <<<"$out")" = 2 ] && grep -q "stopped (0)" <<<"$out"; then grn "ok: reboot (gzip kernel)"; else red "failed: reboot"; grep -a -v sysreg <<<"$out" | tail -15; fail=1; fi
fi

if [ -f host/main.bend ] && [ "${SKIP_GUEST:-0}" != 1 ]; then
  echo "== 5. lifecycle: pause, resume, snapshot, restore"
  t=$(mktemp -d); sock=$t/vm.sock
  ( (slp 8; printf 'echo MARK-$((6*7)) > /tmp/m\n'; slp 40) | ./out/bend-vmm --mem 512 --cpus 2 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --control "$sock" --cmdline "console=ttyAMA0 quiet" > "$t/run.log" 2>&1 & )
  slp 12
  [ "$(echo pause | nc -U "$sock")" = paused ] && [ "$(echo status | nc -U "$sock")" = paused ] && grn "ok: pause" || { red "failed: pause"; fail=1; }
  [ "$(echo resume | nc -U "$sock")" = running ] && grn "ok: resume" || { red "failed: resume"; fail=1; }
  [ "$(echo "snapshot $t/vm.snap" | nc -U "$sock")" = saved ] && grn "ok: snapshot ($(du -h "$t/vm.snap" | cut -f1) on disk)" || { red "failed: snapshot"; fail=1; }
  echo quit | nc -U "$sock" >/dev/null; slp 1
  out=$(drive 40 "restored" 'cat /tmp/m\n' "MARK-42" 'poweroff -f\n' -- ./out/bend-vmm --restore "$t/vm.snap" 2>&1)
  grep -q "^MARK-42" <<<"$(tr -d '\r' <<<"$out")" && grep -q "stopped (0)" <<<"$out" && grn "ok: restore (guest RAM and CPUs continue)" || { red "failed: restore"; grep -a -v sysreg <<<"$out" | tail -15; fail=1; }
  # a snapshot cannot choose host files: a restore that names other ones
  # than the snapshot was taken with is refused
  out=$(./out/bend-vmm --restore "$t/vm.snap" --share "$t" 2>&1 < /dev/null)
  grep -q "taken without --share" <<<"$out" && grn "ok: restore refuses host paths the snapshot was not taken with" || { red "failed: restore path check"; tail -3 <<<"$out"; fail=1; }
  # SIGTERM, and the control socket's powerdown, press the guest's power
  # button (the virtio keyboard's KEY_POWER): the guest powers off
  for how in sigterm powerdown; do
    ./out/bend-vmm --mem 256 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --control "$t/p.sock" --cmdline "console=ttyAMA0 quiet" < /dev/null > "$t/p.log" 2>&1 & p=$!
    slp 6
    if [ $how = sigterm ]; then kill -TERM $p; else [ "$(echo powerdown | nc -U "$t/p.sock")" = "powering down" ] || echo "no reply" >> "$t/p.log"; fi
    for i in $(seq $((16 * SLOW))); do kill -0 $p 2>/dev/null || break; sleep 0.5; done
    kill -9 $p 2>/dev/null; wait $p; code=$?
    [ $code = 0 ] && grep -q "GUEST: power button" "$t/p.log" && grn "ok: $how powers the guest off (its power button)" || { red "failed: $how (exit $code)"; tail -5 "$t/p.log"; fail=1; }
  done
  rm -rf "$t"
fi

if [ -f host/main.bend ] && [ "${SKIP_GUEST:-0}" != 1 ]; then
  echo "== 6. display: framebuffer, virtio keyboard and tablet"
  t=$(mktemp -d); sock=$t/vm.sock
  ( (slp 40) | alarm 40 ./out/bend-vmm --mem 512 --cpus 2 --kernel out/guest/vmlinuz --initrd out/guest/guest.cpio --control "$sock" --display 640x480,headless --cmdline "console=ttyAMA0 quiet" > "$t/run.log" 2>&1 & )
  slp 7
  # typed on tty1 (the framebuffer console) through the virtio keyboard
  printf '%s\n' 'type echo KEYS-$((6*7)) > /dev/ttyAMA0\n' | nc -U "$sock" >/dev/null; slp 1
  printf '%s\n' 'type dd if=/dev/input/event1 bs=24 count=3 2>/dev/null | hexdump -C > /dev/ttyAMA0 &\n' | nc -U "$sock" >/dev/null; slp 1
  [ "$(printf 'pointer 12345 32767\n' | nc -U "$sock")" = moved ] || { red "failed: pointer command"; fail=1; }
  slp 1
  [ "$(echo "screendump $t/s.ppm" | nc -U "$sock")" = saved ] && [ "$(head -c 15 "$t/s.ppm" | tr '\n' ' ')" = "P6 640 480 255 " ] && grn "ok: screendump (640x480)" || { red "failed: screendump"; fail=1; }
  echo quit | nc -U "$sock" >/dev/null; slp 1
  log=$(tr -d '\r' < "$t/run.log")
  grep -q "KEYS-42" <<<"$log" && grn "ok: virtio keyboard (typed into the framebuffer console)" || { red "failed: virtio keyboard"; tail -5 <<<"$log"; fail=1; }
  grep -q "03 00 00 00 39 30 00 00" <<<"$log" && grep -q "03 00 01 00 ff 7f 00 00" <<<"$log" && grn "ok: virtio tablet (ABS_X 12345, ABS_Y 32767)" || { red "failed: virtio tablet"; tail -5 <<<"$log"; fail=1; }
  rm -rf "$t"
fi

if [ -f host/main.bend ] && [ "${SKIP_GUEST:-0}" != 1 ]; then
  echo "== 7. UEFI: firmware, an ISO, EFI variables"
  scripts/uefi-assets.sh >/dev/null
  t=$(mktemp -d); cp out/uefi/vars.fd "$t/vars.fd"
  efivar=/sys/firmware/efi/efivars/BendTest-12345678-1234-1234-1234-123456789abc
  # drive.py turns \\ into \ and \n into Enter: the guest's printf gets \007.
  set_var='printf "\\007\\000\\000\\000bend-ok" > '"$efivar"'; echo SET-$((6*7)); reboot\n'
  get_var='tail -c 7 '"$efivar"'; echo; echo AFTER-REBOOT; poweroff\n'
  out=$(drive 200 "login:" 'root\n' "~# " "$set_var" "login:" 'root\n' "~# " "$get_var" -- \
    ./out/bend-vmm --firmware out/uefi/code.fd --vars "$t/vars.fd" --mem 1024 --cpus 2 --disk out/uefi/alpine.iso:ro 2>&1 | tr -d '\r')
  grep -q "Welcome to Alpine" <<<"$out" && grn "ok: UEFI boots the Alpine ISO (edk2, GRUB, Linux $(grep -ao 'Linux [0-9][^ ]*' <<<"$out" | head -1 | cut -d' ' -f2))" || { red "failed: UEFI boot"; tail -5 <<<"$out"; fail=1; }
  grep -q "SET-42" <<<"$out" && [ "$(grep -c 'Welcome to Alpine Linux' <<<"$out")" = 2 ] && grn "ok: UEFI reboot" || { red "failed: UEFI reboot"; grep -a -v sysreg <<<"$out" | tail -15; fail=1; }
  grep -B1 "AFTER-REBOOT" <<<"$out" | grep -q "^bend-ok" && grep -q "bend-ok" "$t/vars.fd" && grn "ok: EFI variable persists (flash, --vars)" || { red "failed: EFI variable"; grep -a -B2 AFTER-REBOOT <<<"$out"; fail=1; }
  grep -q "reboot: Power down" <<<"$out" && grn "ok: UEFI power off" || { red "failed: UEFI power off"; fail=1; }
  rm -rf "$t"
fi

if [ -f host/main.bend ] && [ "${SKIP_GUEST:-0}" != 1 ]; then
  echo "== 8. qcow2: a raw backing file, compressed clusters, writes"
  if ! command -v qemu-img >/dev/null; then
    echo "skipped: no qemu-img (it makes the images and checks what the guest wrote)"
  else
    t=$(mktemp -d)
    head -c 33554432 /dev/urandom > "$t/base.raw"
    want=$(python3 -c 'import hashlib, sys; print(hashlib.md5(open(sys.argv[1], "rb").read()).hexdigest())' "$t/base.raw")
    qemu-img create -q -f qcow2 -b base.raw -F raw "$t/over.qcow2" 32M
    qemu-img convert -q -c -O qcow2 "$t/base.raw" "$t/comp.qcow2"
    qemu-img create -q -f qcow2 "$t/fresh.qcow2" 32M
    writes='dd if=/dev/urandom of=/dev/vda bs=4096 seek=3 count=5 conv=fsync 2>/dev/null; dd if=/dev/urandom of=/dev/vda bs=1M seek=7 count=3 conv=fsync 2>/dev/null; dd if=/dev/urandom of=/dev/vdb bs=512 seek=999 count=1 conv=fsync 2>/dev/null; dd if=/dev/urandom of=/dev/vdc bs=65536 seek=100 count=40 conv=fsync 2>/dev/null'
    out=$(drive 120 "busybox shell" 'md5sum /dev/vda /dev/vdb; echo READ-DONE\n' "READ-DONE" "$writes; sync; echo 3 > /proc/sys/vm/drop_caches; md5sum /dev/vda /dev/vdb /dev/vdc; echo WRITE-DONE\n" "WRITE-DONE" 'poweroff -f\n' -- \
      ./out/bend-vmm --mem 512 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk "$t/over.qcow2,$t/comp.qcow2,$t/fresh.qcow2" --cmdline "console=ttyAMA0 quiet" 2>&1 | tr -d '\r')
    sums=$(grep -E '^[0-9a-f]{32}  /dev/vd[abc]$' <<<"$out")
    [ "$(head -2 <<<"$sums" | grep -c "^$want ")" = 2 ] && grn "ok: qcow2 reads (a raw backing file; compressed clusters)" || { red "failed: qcow2 reads"; grep -a -v sysreg <<<"$out" | tail -8; fail=1; }
    after=$(tail -3 <<<"$sums")
    ok=1
    for d in a b c; do
      f=$(case $d in a) echo over ;; b) echo comp ;; c) echo fresh ;; esac)
      qemu-img check -q "$t/$f.qcow2" || ok=0
      qemu-img convert -O raw "$t/$f.qcow2" "$t/$f.raw"
      got=$(python3 -c 'import hashlib, sys; print(hashlib.md5(open(sys.argv[1], "rb").read()).hexdigest())' "$t/$f.raw")
      grep -q "^$got  /dev/vd$d" <<<"$after" || ok=0
    done
    [ "$(python3 -c 'import hashlib, sys; print(hashlib.md5(open(sys.argv[1], "rb").read()).hexdigest())' "$t/base.raw")" = "$want" ] || ok=0
    [ $ok = 1 ] && grn "ok: qcow2 writes (qemu-img check passes, qemu-img reads what the guest wrote, the backing file is unchanged)" || { red "failed: qcow2 writes"; echo "$after"; fail=1; }
    # locks: a second bend-vmm cannot open an image one writes, while two
    # overlays share their backing file
    qemu-img create -q -f qcow2 -b base.raw -F raw "$t/two.qcow2" 32M
    vm() { exec ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk "$1" --cmdline "console=ttyAMA0 quiet" < /dev/null 2>&1; }
    vm "$t/over.qcow2" > /dev/null & a=$!
    vm "$t/two.qcow2" > /dev/null & b=$!
    sleep $((3 * SLOW))
    again=$(vm "$t/over.qcow2")
    kill -0 $a 2>/dev/null && kill -0 $b 2>/dev/null && grep -q "in use by another process" <<<"$again" \
      && grn "ok: image locks (a second writer is refused; overlays share a backing file)" || { red "failed: image locks"; echo "$again" | tail -3; fail=1; }
    kill $a $b 2>/dev/null; wait $a $b 2>/dev/null
    # a guest cannot turn its raw disk into a qcow2 image (whose backing file
    # could name any host file): a qcow2 header at the start is refused
    dd if=/dev/zero of="$t/plain.raw" bs=1048576 count=4 2>/dev/null
    out=$(drive 60 "busybox shell" "printf 'QFI\\373\\0\\0\\0\\3' > /tmp/h; dd if=/tmp/h of=/dev/vda bs=512 count=1 conv=sync,fsync 2>&1 | tail -1; echo RAW-DONE\n" "RAW-DONE" 'poweroff -f\n' -- \
      ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk "$t/plain.raw" --cmdline "console=ttyAMA0 quiet" 2>&1 | tr -d '\r')
    [ "$(head -c 4 "$t/plain.raw" | od -An -tx1 | tr -d ' ')" = 00000000 ] && grn "ok: a raw disk refuses a qcow2 header" || { red "failed: raw disk took a qcow2 header"; tail -5 <<<"$out"; fail=1; }
    rm -rf "$t"
  fi
fi

if [ -f host/main.bend ] && [ "${SKIP_GUEST:-0}" != 1 ] && command -v hdiutil >/dev/null; then
  echo "== 9. a full host disk: the guest sees I/O errors, not lost writes"
  t=$(mktemp -d)
  if hdiutil create -quiet -size 3m -fs APFS -volname bendfull "$t/full.dmg" && hdiutil attach -quiet -mountpoint "$t/mnt" "$t/full.dmg"; then
    dd if=/dev/zero of="$t/mnt/d.img" bs=1048576 count=0 seek=64 2>/dev/null
    out=$(drive 90 "busybox shell" 'dd if=/dev/urandom of=/dev/vda bs=1M count=8 oflag=direct; echo FULL-DONE\n' "FULL-DONE" 'poweroff -f\n' -- \
      ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk "$t/mnt/d.img" --cmdline "console=ttyAMA0 quiet" 2>&1 | tr -d '\r')
    grep -aq "dd: error writing '/dev/vda': I/O error" <<<"$out" && grn "ok: writes past a full host disk fail in the guest (IOERR)" || { red "failed: full host disk"; grep -a "records\|error" <<<"$out" | tail -3; fail=1; }
    hdiutil detach -quiet "$t/mnt"
  else
    echo "skipped: cannot make a small volume"
  fi
  rm -rf "$t"
fi

if [ $fail = 0 ]; then grn "CHECK-MAC OK"; else red "CHECK-MAC FAILED"; fi
exit $fail
