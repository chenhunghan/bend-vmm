#!/usr/bin/env bash
# Guest userspace for check-mac.sh level 4:
#   out/guest/Image      Ubuntu noble arm64 kernel (virtio-mmio, virtio-blk built in)
#   out/guest/guest.cpio busybox (Alpine busybox-static) + tests/guest/rootfs
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out/guest
if [ ! -f out/guest/Image ]; then
  curl -fsSL -o out/guest/vmlinuz https://cloud-images.ubuntu.com/noble/current/unpacked/noble-server-cloudimg-arm64-vmlinuz-generic
  gunzip -c out/guest/vmlinuz > out/guest/Image
fi
if [ ! -f out/guest/busybox ]; then
  apk=$(curl -fsSL https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64/ | grep -o 'busybox-static-[0-9][^"]*\.apk' | head -1)
  curl -fsSL -o out/guest/bb.apk "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64/$apk"
  mkdir -p out/guest/bb && tar -xzf out/guest/bb.apk -C out/guest/bb 2>/dev/null || true
  cp out/guest/bb/bin/busybox.static out/guest/busybox
  rm -rf out/guest/bb out/guest/bb.apk
fi
# Drivers this kernel builds as modules: virtio-rng, the 9p and vsock stacks,
# virtio-input.
kver=6.8.0-147-generic
if [ ! -f out/guest/modules/9p.ko ] || [ ! -f out/guest/modules/vsock.ko ] || [ ! -f out/guest/modules/virtio_input.ko ]; then
  mkdir -p out/guest/modules out/guest/deb
  curl -fsSL -o out/guest/modules.deb "http://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/linux-modules-${kver%-generic}-generic_${kver%-generic}.147_arm64.deb"
  (cd out/guest/deb && ar x ../modules.deb && tar -xf data.tar ./lib/modules)
  for m in drivers/char/hw_random/virtio-rng fs/netfs/netfs net/9p/9pnet net/9p/9pnet_virtio fs/9p/9p net/vmw_vsock/vsock net/vmw_vsock/vmw_vsock_virtio_transport_common net/vmw_vsock/vmw_vsock_virtio_transport drivers/virtio/virtio_input; do
    zstd -dqf "out/guest/deb/lib/modules/$kver/kernel/$m.ko.zst" -o "out/guest/modules/$(basename $m).ko"
  done
  rm -rf out/guest/deb out/guest/modules.deb
fi
if [ ! -f out/guest/modules/rtc-pl031.ko ]; then
  mkdir -p out/guest/extra
  curl -fsSL -o out/guest/extra.deb "http://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/linux-modules-extra-${kver%-generic}-generic_${kver%-generic}.147_arm64.deb"
  (cd out/guest/extra && ar x ../extra.deb && tar -xf data.tar "./lib/modules/$kver/kernel/drivers/rtc/rtc-pl031.ko.zst")
  zstd -dqf "out/guest/extra/lib/modules/$kver/kernel/drivers/rtc/rtc-pl031.ko.zst" -o out/guest/modules/rtc-pl031.ko
  rm -rf out/guest/extra out/guest/extra.deb
fi
# the guest's vsock test program
lld=$(command -v ld.lld || ls /opt/homebrew/opt/lld*/bin/ld.lld 2>/dev/null | tail -1)
clang -target aarch64-linux-gnu -c tests/guest/vsock.S -o out/guest/vsock.o
"$lld" -static -e _start out/guest/vsock.o -o out/guest/vsock
rm -f out/guest/vsock.o
# the guest's benchmark program
clang -target aarch64-linux-gnu -O2 -ffreestanding -fno-stack-protector -fno-builtin -c tests/guest/bench.c -o out/guest/bench.o
"$lld" -static -e _start out/guest/bench.o -o out/guest/bench
rm -f out/guest/bench.o
mods="out/guest/vsock:bin/vsock out/guest/bench:bin/bench"
for k in out/guest/modules/*.ko; do mods="$mods $k:lib/modules/$(basename "$k")"; done
python3 scripts/mkinitramfs.py tests/guest/rootfs out/guest/guest.cpio out/guest/busybox:bin/busybox $mods
echo out/guest/Image out/guest/guest.cpio
