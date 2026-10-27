#!/usr/bin/env bash
# Runs scripts/check-host.sh on KVM where the machine has no /dev/kvm (a
# GitHub-hosted arm64 runner): QEMU emulates an arm64 CPU with EL2
# (virtualization=on, TCG), the guest kernel (out/guest/Image) boots in it
# with KVM, mounts this host's root read-only over 9p and runs the check in a
# chroot of it, so the host's own toolchain and the binaries built here run
# unchanged. Slow (every guest instruction is emulated), so the check runs
# with CHECK_SLOW (default 5).
#   scripts/ci/emulated-kvm.sh            builds, then checks
# Needs Linux on arm64 with qemu-system-aarch64, clang, lld, zstd and bend.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "$(uname -s)-$(uname -m)" = Linux-aarch64 ] || { echo "emulated-kvm: needs Linux on arm64"; exit 2; }
repo=$(pwd)
mem=${L1_MEM:-8192}
cpus=${L1_CPUS:-$(nproc)}

echo "== build (native)"
scripts/guest-assets.sh >/dev/null
scripts/linux-assets.sh >/dev/null
scripts/uefi-assets.sh >/dev/null
for g in tests/guest/*.S; do scripts/guest.sh "$(basename "$g" .S)" >/dev/null; done
scripts/build.sh host/smoke.bend out/smoke >/dev/null
scripts/build.sh host/main.bend out/bend-vmm >/dev/null

echo "== the emulated KVM host"
l1=out/l1
rm -rf "$l1" && mkdir -p "$l1/root"
cat > "$l1/root/init" <<EOF
#!/bin/busybox sh
/bin/busybox --install -s /bin
mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev
for m in netfs 9pnet 9pnet_virtio 9p; do insmod /lib/modules/\$m.ko; done
mkdir -p /host
mount -t 9p -o trans=virtio,version=9p2000.L,ro,msize=1048576,cache=loose host /host
mount -t tmpfs -o size=$((mem * 3 / 4))m tmp /host/tmp
mount -t tmpfs run /host/run
mkdir -p /host/run/systemd/resolve
echo "nameserver 10.0.2.3" > /host/run/systemd/resolve/stub-resolv.conf
cp /host/run/systemd/resolve/stub-resolv.conf /host/run/resolv.conf
mount --bind /host/run/resolv.conf /host/etc/resolv.conf 2>/dev/null
mount --rbind /dev /host/dev; mount -t proc proc /host/proc; mount -t sysfs sys /host/sys
ip link set lo up; ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0; ip route add default via 10.0.2.2
echo "L1: \$(uname -r), kvm: \$(ls /dev/kvm)"
chroot /host /usr/bin/env -i HOME=/tmp PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  CHECK_SLOW=${CHECK_SLOW:-5} SKIP_NATIVE=1 SKIP_BUILD=1 \
  /bin/bash -c 'cp -a $repo /tmp/w && cd /tmp/w && scripts/check-host.sh'
echo "L1-EXIT \$?"
poweroff -f
EOF
mods=""
for m in netfs 9pnet 9pnet_virtio 9p; do mods="$mods out/guest/modules/$m.ko:lib/modules/$m.ko"; done
python3 scripts/mkinitramfs.py "$l1/root" "$l1/initrd.cpio" out/guest/busybox:bin/busybox $mods

log=$l1/console.log
timeout "${L1_TIMEOUT:-5400}" qemu-system-aarch64 \
  -machine virt,virtualization=on,gic-version=3 -accel tcg,thread=multi,tb-size=1024 \
  -cpu max,pauth-impdef=on -smp "$cpus" -m "$mem" -nographic -no-reboot \
  -kernel out/guest/Image -initrd "$l1/initrd.cpio" -append "console=ttyAMA0 rdinit=/init quiet" \
  -fsdev local,id=root,path=/,security_model=none,readonly=on \
  -device virtio-9p-device,fsdev=root,mount_tag=host \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  < /dev/null 2>&1 | tee "$log" || true
code=$(sed -n 's/^L1-EXIT \([0-9]*\).*/\1/p' "$log" | tail -1)
rm -rf "$l1"
[ "${code:-1}" = 0 ] && echo "EMULATED-KVM OK" || { echo "EMULATED-KVM FAILED (${code:-no exit code})"; exit 1; }
