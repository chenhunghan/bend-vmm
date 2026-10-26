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
fi
python3 scripts/mkinitramfs.py tests/guest/rootfs out/guest/guest.cpio out/guest/busybox:bin/busybox
echo out/guest/Image out/guest/guest.cpio
