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
#   4. the guest suite (tests/guest/rootfs/tests.sh), net, 9p, vsock, port
#      forwarding (--forward), console.
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
  # bulk both ways (a full credit window and more; packets split to the
  # guest's buffers): 4 MiB from a host program, 4 MiB to one
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); c,_=s.accept(); c.sendall(bytes(4194304)); c.close()" "${vs}_7001" & src=$!
  python3 -c "
import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); c,_=s.accept(); n=0
while True:
  b=c.recv(1<<20)
  if not b: break
  n+=len(b)
open(sys.argv[2],'w').write(str(n))" "${vs}_7000" "$(dirname "$vs")/got" & sink=$!
  sleep 1
  out=$(drive 120 "busybox shell" '/bin/bench vrecv 7001; /bin/bench vsend 7000 4194304; echo VS-DONE\n' "VS-DONE" 'poweroff -f\n' -- \
    ./out/bend-vmm --mem 512 --cpus 2 --kernel out/guest/Image --initrd out/guest/guest.cpio --vsock "$vs" --cmdline "console=ttyAMA0 quiet" 2>&1 | tr -d '\r')
  wait $src $sink 2>/dev/null
  grep -aq "^BENCH vsock-download-bytes 4194304 B" <<<"$out" && [ "$(cat "$(dirname "$vs")/got" 2>/dev/null)" = 4194304 ] \
    && grn "ok: vsock bulk both ways (4 MiB each: $(grep -a '^BENCH vsock-download ' <<<"$out" | cut -d' ' -f3) / $(grep -a '^BENCH vsock-upload' <<<"$out" | cut -d' ' -f3) MB/s)" \
    || { red "failed: vsock bulk"; grep -a "^BENCH\|bench:" <<<"$out"; echo "host got $(cat "$(dirname "$vs")/got" 2>/dev/null)"; fail=1; }
  kill $src $sink 2>/dev/null
  # port forwarding (--forward, both forms): a host client reads a guest
  # server's line, then sends 4 MiB to another guest server that counts them
  fport=$((20000 + RANDOM % 20000)); bport=$((fport + 1))
  python3 scripts/forward-test.py $((120 * SLOW)) "$fport" "$bport" 4194304 > "$(dirname "$vs")/fwd.log" 2>&1 & fwd=$!
  out=$(drive 150 "busybox shell" 'echo forward-ok | nc -l -p 8080; echo go | nc -l -p 8081 | wc -c; echo FWD-DONE\n' "FWD-DONE" 'poweroff -f\n' -- \
    ./out/bend-vmm --mem 512 --cpus 2 --kernel out/guest/Image --initrd out/guest/guest.cpio --forward "127.0.0.1:$fport:8080,$bport:8081" --cmdline "console=ttyAMA0 quiet" 2>&1 | tr -d '\r')
  wait $fwd 2>/dev/null
  hlog=$(cat "$(dirname "$vs")/fwd.log" 2>/dev/null)
  grep -q "^HOST-FWD-LINE forward-ok$" <<<"$hlog" && grn "ok: --forward host -> guest (127.0.0.1:$fport -> 8080)" || { red "failed: --forward"; echo "$hlog"; grep -a -v sysreg <<<"$out" | tail -8; fail=1; }
  grep -q "^HOST-FWD-SENT 4194304$" <<<"$hlog" && grep -aqE '^ *4194304 *$' <<<"$out" && grn "ok: --forward bulk (4 MiB host -> guest, every byte counted)" || { red "failed: --forward bulk"; echo "$hlog" | tail -3; grep -a -v sysreg <<<"$out" | tail -8; fail=1; }
  kill $fwd 2>/dev/null
  # a forward whose host port is taken stops the VMM at startup
  # (the forward test above leaves $fport in TIME_WAIT: the busy listener
  # sets SO_REUSEADDR so that it can bind it, and then holds it listening)
  python3 -c "import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', int(sys.argv[1]))); s.listen(1); print('BUSY-UP', flush=True); time.sleep(int(sys.argv[2]))" "$fport" $((40 * SLOW)) > "$(dirname "$vs")/busy.log" 2>&1 & busy=$!
  for _ in $(seq $((50 * SLOW))); do grep -q BUSY-UP "$(dirname "$vs")/busy.log" 2>/dev/null && break; kill -0 $busy 2>/dev/null || break; sleep 0.1; done
  if grep -q BUSY-UP "$(dirname "$vs")/busy.log" 2>/dev/null && kill -0 $busy 2>/dev/null; then
    out=$( (alarm 40 ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --forward "$fport:22" --cmdline "console=ttyAMA0 quiet") 2>&1 < /dev/null)
    kill $busy 2>/dev/null; wait $busy 2>/dev/null
    grep -q "cannot listen on 127.0.0.1:$fport: Address already in use" <<<"$out" && grn "ok: --forward on a taken port is a startup error" || { red "failed: --forward on a taken port"; tail -3 <<<"$out"; fail=1; }
  else
    kill $busy 2>/dev/null; wait $busy 2>/dev/null
    red "failed: --forward on a taken port (the busy listener on 127.0.0.1:$fport did not start)"; cat "$(dirname "$vs")/busy.log" 2>/dev/null; fail=1
  fi
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
  # the NAT's DNS server follows the host's resolver (read at each query)
  echo net | nc -U "$sock" | grep -q '^resolver .*: [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*$' && grn "ok: net shows the resolver" || { red "failed: net shows the resolver"; fail=1; }
  [ "$(echo "snapshot $t/vm.snap" | nc -U "$sock")" = saved ] && grn "ok: snapshot ($(du -h "$t/vm.snap" | cut -f1) on disk)" || { red "failed: snapshot"; fail=1; }
  echo quit | nc -U "$sock" >/dev/null; slp 1
  out=$(drive 40 "restored" 'cat /tmp/m\n' "MARK-42" 'poweroff -f\n' -- ./out/bend-vmm --restore "$t/vm.snap" 2>&1)
  grep -q "^MARK-42" <<<"$(tr -d '\r' <<<"$out")" && grep -q "stopped (0)" <<<"$out" && grn "ok: restore (guest RAM and CPUs continue)" || { red "failed: restore"; grep -a -v sysreg <<<"$out" | tail -15; fail=1; }
  # a snapshot cannot choose host files: a restore that names other ones
  # than the snapshot was taken with is refused
  out=$(./out/bend-vmm --restore "$t/vm.snap" --share "$t" 2>&1 < /dev/null)
  grep -q "taken without --share" <<<"$out" && grn "ok: restore refuses host paths the snapshot was not taken with" || { red "failed: restore path check"; tail -3 <<<"$out"; fail=1; }
  # malformed snapshots (src/vmm/snapfile.bend refuses them) end the VMM
  # with an error, never a crash: a cut header, RAM cut short, 65 vCPUs, a
  # machine word count past 2^26
  head -c 30 "$t/vm.snap" > "$t/bad1.snap"
  head -c 1048576 "$t/vm.snap" > "$t/bad2.snap"
  head -c 65536 "$t/vm.snap" > "$t/bad3.snap"; printf 'A' | dd of="$t/bad3.snap" bs=1 seek=12 conv=notrunc 2>/dev/null
  head -c 65536 "$t/vm.snap" > "$t/bad4.snap"
  nargs=$(od -An -tu4 -j32 -N4 "$t/vm.snap" | tr -d ' ')
  printf '\377\377\377\377' | dd of="$t/bad4.snap" bs=1 seek=$((40 + nargs)) conv=notrunc 2>/dev/null
  ok=1
  for b in 1 2 3 4; do
    out=$(./out/bend-vmm --restore "$t/bad$b.snap" 2>&1 < /dev/null); code=$?
    [ $code = 1 ] && grep -q "cannot read the snapshot (22)" <<<"$out" || { ok=0; echo "bad$b: exit $code: $(tail -1 <<<"$out")"; }
  done
  [ $ok = 1 ] && grn "ok: restore refuses malformed snapshots (cut header, RAM cut short, 65 vCPUs, 2^32 machine words)" || { red "failed: malformed snapshots"; fail=1; }
  # a snapshot of a restored VM (its command line is the restore's: no
  # --mem, no --cpus; the header says), written over the very file its RAM
  # is mapped from (a new file renamed into place), restores again
  ( (slp 30) | ./out/bend-vmm --restore "$t/vm.snap" --control "$t/c.sock" > "$t/c.log" 2>&1 & )
  slp 4
  r=$(echo "snapshot $t/vm.snap" | nc -U "$t/c.sock"); echo quit | nc -U "$t/c.sock" > /dev/null; slp 2
  out=$(drive 40 "restored" 'echo CHAIN-$((6*7)) $(nproc)\n' "CHAIN-42" 'poweroff -f\n' -- ./out/bend-vmm --restore "$t/vm.snap" 2>&1)
  [ "$r" = saved ] && grep -q "^CHAIN-42 2" <<<"$(tr -d '\r' <<<"$out")" && ! ls "$t"/*.bend-vmm-tmp > /dev/null 2>&1 \
    && grn "ok: a restored VM snapshots over its own file, and that restores (2 vCPUs)" || { red "failed: snapshot of a restored VM ($r)"; tail -5 <<<"$out"; fail=1; }
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
  # Where the VMM listens (src/vmm/hostfiles.bend): a file at the path is
  # refused and kept; a running VMM's socket is refused (that VMM keeps
  # answering on it); a dead one (its VMM killed) is replaced. A LAN
  # directory others may enter is refused.
  t=$(mktemp -d); echo keep > "$t/notes"; mkdir -m 755 "$t/lan"
  vm() { ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --cmdline "console=ttyAMA0 quiet" "$@"; }
  o1=$(alarm 20 ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --control "$t/notes" < /dev/null 2>&1 | head -3)
  ( (slp 40) | vm --control "$t/c.sock" > "$t/a.log" 2>&1 & )
  for _ in $(seq $((40 * SLOW))); do [ -S "$t/c.sock" ] && break; sleep 0.5; done
  o2=$(alarm 20 ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --control "$t/c.sock" < /dev/null 2>&1 | head -3)
  s2=$(echo status | nc -U "$t/c.sock" 2>/dev/null | head -1)
  pkill -9 -f -- "--control $t/c.sock"; sleep 1
  ( (slp 40) | vm --control "$t/c.sock" > "$t/b.log" 2>&1 & )
  s3=""; for _ in $(seq $((40 * SLOW))); do s3=$(echo status | nc -U "$t/c.sock" 2>/dev/null | head -1); [ -n "$s3" ] && break; sleep 0.5; done
  echo quit | nc -U "$t/c.sock" >/dev/null 2>&1
  o4=$(alarm 20 ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --lan "$t/lan,ip=10.0.3.11/24" < /dev/null 2>&1 | head -3)
  grep -q "is not a socket" <<<"$o1" && [ "$(cat "$t/notes")" = keep ] && grep -q "a running VMM listens there" <<<"$o2" && [ -n "$s2" ] && [ -n "$s3" ] && grep -q "cannot join the LAN" <<<"$o4" \
    && grn "ok: listening paths: a file is kept, a live socket refused, a dead one replaced; an open LAN directory refused" \
    || { red "failed: listening paths"; printf '%s\n' "file: $o1" "live: $o2 ($s2)" "dead: $s3" "lan: $o4"; fail=1; }
  # a socket path longer than the address holds is refused by Bend, saying so
  long=$(mktemp -d)/$(printf 'x%.0s' $(seq 1 120)).sock
  o5=$(./out/bend-vmm --kernel out/linux/linux --initrd out/linux/initrd.cpio --control "$long" < /dev/null 2>&1)
  grep -q "the path is too long for a socket" <<<"$o5" && grn "ok: a socket path too long for the address is refused, saying so" || { red "failed: long socket path"; tail -2 <<<"$o5"; fail=1; }
  rm -rf "$(dirname "$long")"
  rm -rf "$t"
fi

if [ -f host/main.bend ] && [ "${SKIP_GUEST:-0}" != 1 ]; then
  echo "== 5b. LAN: two VMs on one segment (--lan)"
  # B listens on TCP 6443 and UDP 8472 (VXLAN's port); A takes its address
  # by DHCP from its own VMM, pings B (ARP broadcast, then unicast), sends
  # 16 MiB over TCP and a datagram over UDP. NAT egress (eth0) is unchanged.
  t=$(mktemp -d); lan=$t/lan
  ( (slp 4; printf 'ip link set eth1 up; udhcpc -i eth1 -n -q -t 5 >/dev/null 2>&1; nc -l -p 6443 > /tmp/got & nc -u -l -p 8472 > /tmp/u &\n'; slp 30; printf 'echo B-GOT $(wc -c < /tmp/got) $(cat /tmp/u)\n'; slp 3; printf 'poweroff -f\n'; slp 2) \
    | ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --lan "$lan,ip=10.0.3.12/24" --cmdline "console=ttyAMA0 quiet" > "$t/b.log" 2>&1 & )
  slp 2
  out=$(drive 60 "busybox shell" 'ip link set eth1 up; udhcpc -i eth1 -n -q -t 5 2>&1 | grep -o "lease of [0-9.]*"; sleep 3; ping -c 2 10.0.3.12 | grep -o "2 packets received"; dd if=/dev/zero bs=1M count=16 2>/dev/null | nc -w 2 10.0.3.12 6443; echo vxlan-ok | nc -u -w1 10.0.3.12 8472; echo LAN-DONE\n' "LAN-DONE" 'poweroff -f\n' -- \
    ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --lan "$lan,ip=10.0.3.11/24" --cmdline "console=ttyAMA0 quiet" 2>&1 | tr -d '\r')
  for _ in $(seq $((60 * SLOW))); do grep -aq "stopped" "$t/b.log" 2>/dev/null && break; sleep 1; done
  grep -q "lease of 10.0.3.11" <<<"$out" && grep -q "2 packets received" <<<"$out" && grep -aq "B-GOT 16777216 vxlan-ok" "$t/b.log" && [ -z "$(ls "$lan")" ] \
    && grn "ok: two VMs on a LAN (DHCP from the VMM, ping, 16 MiB TCP, UDP 8472; sockets gone after)" || { red "failed: LAN"; tail -5 <<<"$out"; tr -d '\r' < "$t/b.log" | grep -a "B-GOT\|stopped" | tail -3; ls "$lan"; fail=1; }
  rm -rf "$t"
fi

if [ -f host/main.bend ] && [ "${SKIP_GUEST:-0}" != 1 ]; then
  echo "== 5c. limits on what a guest writes to the host: share quota, console log"
  # a 1 MiB quota with 100 KiB already there: 300 KiB fits, 700 KiB stops
  # at the quota (ENOSPC), and room freed by rm is usable again; the console
  # goes to a log that rotates at 16 KiB, not to stdout
  t=$(mktemp -d); mkdir "$t/sh"; dd if=/dev/zero of="$t/sh/existing" bs=1k count=100 2>/dev/null
  # (the console goes to the log, so the input is timed rather than driven)
  ( (slp 6; printf 'cd /mnt/share; dd if=/dev/zero of=a bs=1k count=300 2>/dev/null; dd if=/dev/zero of=b bs=1k count=700 2>&1 | grep -c "No space left"; rm a; dd if=/dev/zero of=c bs=1k count=200 2>/dev/null && echo C-OK; i=0; while [ $i -lt 400 ]; do echo line-$i-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; i=$((i+1)); done; sleep 1; echo LIM-DONE\n'; slp 10; printf 'poweroff -f\n'; slp 2) \
    | alarm 60 ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --share "$t/sh,quota=1M" --console-log "$t/console.log,max=16K,keep=2" --cmdline "console=ttyAMA0 quiet" > "$t/stdout" 2>&1 )
  out=$(cat "$t/stdout")
  # (wc -c, not stat: GNU stat -f is about the file system)
  b=$(wc -c < "$t/sh/b" | tr -d ' '); c=$(wc -c < "$t/sh/c" | tr -d ' ')
  [ "$b" -lt 716800 ] && [ "$b" -gt 524288 ] && [ "$c" = 204800 ] && [ -f "$t/console.log.1" ] && [ ! -e "$t/console.log.3" ] && ! grep -q "LIM-DONE" <<<"$out" && cat "$t"/console.log* | grep -aq "LIM-DONE" \
    && grn "ok: share quota stops a write at 1 MiB (b: $b bytes) and frees with rm; the console log rotates, keeping 2" || { red "failed: limits (b $b, c $c)"; ls -la "$t"; tail -3 <<<"$out"; fail=1; }
  rm -rf "$t"
fi

if [ -f host/main.bend ] && [ "${SKIP_GUEST:-0}" != 1 ]; then
  echo "== 5d. NAT faults: a slow host reader, a connection reset midway"
  # 16 MiB to a host program that reads 16 KiB every 10 ms: every byte
  # arrives, and the NAT holds the guest back (src/net/flush.bend: blocked
  # past 4 MiB pending) instead of buffering it, so the VMM's memory grows
  # by less than 24 MiB. Then a host program that resets the connection
  # after 1 MiB: the guest's sender gets an error, and the next connection
  # works.
  t=$(mktemp -d); sport=$((20000 + RANDOM % 20000)); dport=$((sport + 1))
  python3 scripts/netfault.py slow "$sport" 16777216 "$t/slow" & slow=$!
  python3 scripts/netfault.py drop "$dport" 1048576 "$t/drop" & drop=$!
  slp 1
  ( peak=0; base=0; while :; do
      p=$(pgrep -f '^./out/bend-vmm .*bendnetfault' | head -1); [ -n "$p" ] || { sleep 0.2; continue; }
      r=$(ps -o rss= -p "$p" 2>/dev/null | tr -d ' '); [ -n "$r" ] || break
      [ -f "$t/slow.start" ] && [ "$base" = 0 ] && base=$r
      [ "$r" -gt "$peak" ] && peak=$r
      echo "$base $peak" > "$t/rss"; sleep 0.2
    done ) & mon=$!
  out=$(drive 150 "busybox shell" "head -c 16777216 /dev/zero | nc 10.0.2.2 $sport; echo SLOW-DONE\n" "SLOW-DONE" "head -c 8388608 /dev/zero | nc 10.0.2.2 $dport; echo DROP-EXIT-\$?\n" "DROP-EXIT" "head -c 1048576 /dev/zero | nc 10.0.2.2 $dport; echo DROP-DONE\n" "DROP-DONE" 'poweroff -f\n' -- \
    ./out/bend-vmm --mem 512 --cpus 2 --kernel out/guest/Image --initrd out/guest/guest.cpio --cmdline "console=ttyAMA0 quiet bendnetfault" 2>&1 | tr -d '\r')
  kill $mon $slow $drop 2>/dev/null; wait $slow $drop 2>/dev/null
  read -r base peak < "$t/rss" 2>/dev/null || { base=0; peak=0; }
  grow=$(( (peak - base) / 1024 ))
  [ "$(cat "$t/slow" 2>/dev/null)" = 16777216 ] && [ "$base" -gt 0 ] && [ "$grow" -lt 24 ] \
    && grn "ok: a slow host reader gets every byte; the VMM grew by $grow MiB (held back, not buffered)" \
    || { red "failed: slow host reader (got $(cat "$t/slow" 2>/dev/null), grew $grow MiB)"; grep -a "SLOW\|nc:" <<<"$out" | tail -3; fail=1; }
  [ "$(cat "$t/drop" 2>/dev/null)" = "dropped 1048576" ] && grep -aq "DROP-EXIT-" <<<"$out" && grep -aq "DROP-DONE" <<<"$out" \
    && grn "ok: a connection reset midway ends the guest's sender; the next connection works" \
    || { red "failed: connection reset ($(cat "$t/drop" 2>/dev/null))"; grep -a "DROP\|nc:" <<<"$out" | tail -3; fail=1; }
  rm -rf "$t"
fi

if [ -f host/main.bend ] && [ "${SKIP_GUEST:-0}" != 1 ]; then
  echo "== 5e. Bend's host choices: the share's open-file slots, UDP flows"
  # 20 files read twice through 16 slots (Bend picks each eviction,
  # src/host/fdcache.bend), a file renamed over one held open (the rename
  # empties the share's slots: the next read sees the new file), and DNS
  # through three guest ports and back to the first (Bend picks the flow,
  # Udp.find)
  t=$(mktemp -d); mkdir "$t/sh"
  for i in $(seq 1 20); do echo "file-$i" > "$t/sh/f$i"; done; echo NEW-CONTENT > "$t/sh/new"
  cmd='cd /mnt/share; ok=0; for r in 1 2; do for i in $(seq 1 20); do [ "$(cat f$i)" = "file-$i" ] && ok=$((ok+1)); done; done; echo FILES-$ok; cat f1 >/dev/null; mv new f1; echo RENAMED-$(cat f1); for p in 1 2 3 1 1; do nslookup example.com >/dev/null 2>&1 && echo DNS-OK; done; echo P9U-DONE\n'
  out=$(drive 120 "busybox shell" "mkdir -p /mnt/share; mount -t 9p -o trans=virtio,version=9p2000.L share /mnt/share; $cmd" "P9U-DONE" 'poweroff -f\n' -- \
    ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --share "$t/sh" --cmdline "console=ttyAMA0 quiet" 2>&1 | tr -d '\r')
  grep -aq "^FILES-40" <<<"$out" && grep -aq "^RENAMED-NEW-CONTENT" <<<"$out" && grn "ok: 20 files through 16 slots read back, a rename drops the old file" || { red "failed: share slots"; grep -a "FILES\|RENAMED\|mount" <<<"$out" | tail -3; fail=1; }
  [ "$(grep -ac '^DNS-OK' <<<"$out")" -ge 4 ] && grn "ok: DNS over the NAT's UDP flows ($(grep -ac '^DNS-OK' <<<"$out") of 5)" || { red "failed: UDP flows (DNS)"; grep -a "DNS\|nslookup" <<<"$out" | tail -3; fail=1; }
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
  out=$(drive 300 "login:" 'root\n' "~# " "$set_var" "login:" 'root\n' "~# " "$get_var" -- \
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
    # crash consistency: the VMM killed (SIGKILL) while the guest writes all
    # over a fresh qcow2 image leaves one qemu-img checks clean (leaks
    # would be allowed, corruption not)
    qemu-img create -q -f qcow2 "$t/crash.qcow2" 64M
    ok=1
    for i in 1 2 3; do
      # a pipe, not < <(...): the CI chroot has no /dev/fd ($! is the VMM)
      # the writes start once the shell is up (boot time varies, on an
      # emulated host most of all); the kill comes 1 + i seconds into them
      (for _ in $(seq $((60 * SLOW))); do grep -aq "busybox shell" "$t/crash.log" 2>/dev/null && break; sleep 0.5; done; echo 'while :; do dd if=/dev/urandom of=/dev/vda bs=64k seek=$((RANDOM % 1000)) count=4 oflag=direct 2>/dev/null; done'; sleep $((30 * SLOW))) \
        | ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk "$t/crash.qcow2" --cmdline "console=ttyAMA0 quiet" > "$t/crash.log" 2>&1 & p=$!
      for _ in $(seq $((60 * SLOW))); do grep -aq "busybox shell" "$t/crash.log" 2>/dev/null && break; sleep 0.5; done
      sleep $(((1 + i) * SLOW)); kill -9 $p; wait $p 2>/dev/null; rm -f "$t/crash.log"
      qemu-img check -q "$t/crash.qcow2"; rc=$?
      [ $rc = 0 ] || [ $rc = 3 ] || ok=0
    done
    # the guest must have written: the image grew past 1 MiB
    [ $ok = 1 ] && [ "$(qemu-img info --output=json "$t/crash.qcow2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["actual-size"])')" -gt 1048576 ] \
      && grn "ok: qcow2 survives SIGKILL mid-write (3 rounds, qemu-img check clean)" || { red "failed: qcow2 after SIGKILL"; qemu-img check "$t/crash.qcow2" | tail -3; fail=1; }
    # a guest cannot turn its raw disk into a qcow2 image (whose backing file
    # could name any host file): a qcow2 header at the start is refused
    dd if=/dev/zero of="$t/plain.raw" bs=1048576 count=4 2>/dev/null
    out=$(drive 60 "busybox shell" "printf 'QFI\\373\\0\\0\\0\\3' > /tmp/h; dd if=/tmp/h of=/dev/vda bs=512 count=1 conv=sync,fsync 2>&1 | tail -1; echo RAW-DONE\n" "RAW-DONE" 'poweroff -f\n' -- \
      ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk "$t/plain.raw" --cmdline "console=ttyAMA0 quiet" 2>&1 | tr -d '\r')
    [ "$(head -c 4 "$t/plain.raw" | od -An -tx1 | tr -d ' ')" = 00000000 ] && grn "ok: a raw disk refuses a qcow2 header" || { red "failed: raw disk took a qcow2 header"; tail -5 <<<"$out"; fail=1; }
    rm -rf "$t"
  fi
fi

if [ -f host/main.bend ] && [ "${SKIP_GUEST:-0}" != 1 ]; then
  echo "== 8b. short disk transfers: every host read or write moves at most 1000 bytes, every third is interrupted (BEND_VMM_SHORT_IO)"
  # src/host/transfer.bend decides what follows a short attempt (Host.disk_go):
  # the guest must still read every byte and write where it asked
  t=$(mktemp -d)
  head -c 8388608 /dev/urandom > "$t/d.img"
  want=$(python3 -c 'import hashlib, sys; print(hashlib.md5(open(sys.argv[1], "rb").read()).hexdigest())' "$t/d.img")
  out=$(BEND_VMM_SHORT_IO=1000 drive 120 "busybox shell" 'md5sum /dev/vda; dd if=/dev/vda of=/dev/vda bs=65536 count=32 seek=64 iflag=direct oflag=direct 2>/dev/null; sync; echo SHORT-DONE\n' "SHORT-DONE" 'poweroff -f\n' -- \
    ./out/bend-vmm --mem 256 --kernel out/guest/Image --initrd out/guest/guest.cpio --disk "$t/d.img" --cmdline "console=ttyAMA0 quiet" 2>&1 | tr -d '\r')
  same=$(python3 -c 'import sys; b=open(sys.argv[1], "rb").read(); print(int(b[:2097152] == b[4194304:6291456]))' "$t/d.img")
  grep -q "^$want  /dev/vda" <<<"$out" && [ "$same" = 1 ] && grn "ok: short and interrupted host transfers: the guest reads every byte and writes where it asked" || { red "failed: short disk transfers (copy $same)"; grep -a "vda\|SHORT\|error" <<<"$out" | tail -5; fail=1; }
  rm -rf "$t"
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
