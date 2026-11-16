#!/usr/bin/env bash
# Guest userspace for the x86_64 check (scripts/ci/x86-check.sh), on a Linux
# x86_64 host with gcc, curl, python3 and unsquashfs:
#   out/x86/vmlinuz-virt  Alpine's virt kernel (a bzImage)
#   out/x86/guest.cpio    busybox (Alpine busybox-static) + tests/guest/rootfs
#                         + the virtio drivers Alpine builds as modules
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out/x86
v=3.20
net=https://dl-cdn.alpinelinux.org/alpine/v$v/releases/x86_64/netboot
[ -f out/x86/vmlinuz-virt ] || curl -fsSL --retry 5 -o out/x86/vmlinuz-virt "$net/vmlinuz-virt"
if [ ! -f out/x86/busybox ]; then
  apk=$(curl -fsSL https://dl-cdn.alpinelinux.org/alpine/v$v/main/x86_64/ | grep -o 'busybox-static-[0-9][^"]*\.apk' | head -1)
  curl -fsSL --retry 5 -o out/x86/bb.apk "https://dl-cdn.alpinelinux.org/alpine/v$v/main/x86_64/$apk"
  mkdir -p out/x86/bb && tar -xzf out/x86/bb.apk -C out/x86/bb 2>/dev/null || true
  cp out/x86/bb/bin/busybox.static out/x86/busybox
  rm -rf out/x86/bb out/x86/bb.apk
fi
# The drivers, in load order (tests/guest/rootfs/init loads what it finds).
mods="net/packet/af_packet drivers/input/evdev drivers/char/hw_random/rng-core net/core/failover drivers/net/net_failover drivers/net/virtio_net drivers/block/virtio_blk
  drivers/char/virtio_console drivers/char/hw_random/virtio-rng drivers/virtio/virtio_balloon
  drivers/virtio/virtio_input fs/fscache/fscache fs/netfs/netfs net/9p/9pnet net/9p/9pnet_virtio fs/9p/9p
  net/vmw_vsock/vsock net/vmw_vsock/vmw_vsock_virtio_transport_common
  net/vmw_vsock/vmw_vsock_virtio_transport"
if [ ! -f out/x86/modules/evdev.ko ]; then
  curl -fsSL --retry 5 -o out/x86/modloop "$net/modloop-virt"
  rm -rf out/x86/ml && unsquashfs -q -d out/x86/ml out/x86/modloop >/dev/null
  mkdir -p out/x86/modules
  for m in $mods; do
    f=$(find out/x86/ml -path "*/kernel/$m.ko*" | head -1)
    [ -n "$f" ] || { echo "guest-assets-x86: no $m in the modloop" >&2; continue; }
    case $f in
      *.gz) gunzip -c "$f" > "out/x86/modules/$(basename "$m").ko" ;;
      *.zst) zstd -dqf "$f" -o "out/x86/modules/$(basename "$m").ko" ;;
      *) cp "$f" "out/x86/modules/$(basename "$m").ko" ;;
    esac
  done
  rm -rf out/x86/ml out/x86/modloop
fi
gcc -static -O2 -o out/x86/vsock tests/guest/vsock.c
extra="out/x86/vsock:bin/vsock"
for k in out/x86/modules/*.ko; do extra="$extra $k:lib/modules/$(basename "$k")"; done
python3 scripts/mkinitramfs.py tests/guest/rootfs out/x86/guest.cpio out/x86/busybox:bin/busybox $extra
echo out/x86/vmlinuz-virt out/x86/guest.cpio
