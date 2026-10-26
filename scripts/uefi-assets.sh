#!/usr/bin/env bash
# Fetches arm64 UEFI firmware for --firmware: edk2's ArmVirtQemu build from
# Ubuntu's qemu-efi-aarch64 package (AAVMF), into out/uefi/:
#   code.fd  the firmware (flash bank 0), without Secure Boot
#   vars.fd  an empty variable store template (copy it per VM for --vars)
# and, for scripts/check-mac.sh, Alpine's arm64 "virt" ISO (alpine.iso), a
# UEFI-bootable image (GRUB, Linux, OpenRC).
set -euo pipefail
cd "$(dirname "$0")/.."
ver=2025.11-3ubuntu7.3
if [ ! -f out/uefi/code.fd ]; then
  mkdir -p out/uefi/deb
  curl -fsSL -o out/uefi/efi.deb "http://ports.ubuntu.com/ubuntu-ports/pool/main/e/edk2/qemu-efi-aarch64_${ver}_all.deb"
  (cd out/uefi/deb && ar x ../efi.deb && tar -xf data.tar.zst ./usr/share/AAVMF/AAVMF_CODE.no-secboot.fd ./usr/share/AAVMF/AAVMF_VARS.fd)
  mv out/uefi/deb/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd out/uefi/code.fd
  mv out/uefi/deb/usr/share/AAVMF/AAVMF_VARS.fd out/uefi/vars.fd
  rm -rf out/uefi/deb out/uefi/efi.deb
fi
alpine=3.24.3
if [ ! -f out/uefi/alpine.iso ]; then
  curl -fsSL -o out/uefi/alpine.iso "https://dl-cdn.alpinelinux.org/alpine/v${alpine%.*}/releases/aarch64/alpine-virt-${alpine}-aarch64.iso"
fi
echo out/uefi/code.fd out/uefi/vars.fd out/uefi/alpine.iso
