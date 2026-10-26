#!/usr/bin/env bash
# Runs a command in a copy of this repository on a Linux arm64 host with KVM:
# the Lima VM "bend-linux" (scripts/lima/linux-host.yaml), created and
# started on first use. Each run copies the working tree to ~/bend-vmm in the
# guest (keeping its out/, so downloaded guest assets stay). On an M3 or later Mac it nests KVM through
# Virtualization.framework; on M1/M2 it emulates EL2 with QEMU TCG
# (scripts/lima/qemu-el2), which is slow but faithful.
#   scripts/lima/linux-host.sh [command...]   (default: an interactive shell)
#   scripts/lima/linux-host.sh --delete       removes the VM
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
vm=bend-linux
export QEMU_SYSTEM_AARCH64="$repo/scripts/lima/qemu-el2"
if [ "${1:-}" = --delete ]; then limactl delete -f "$vm"; exit; fi
if ! limactl list -q 2>/dev/null | grep -qx "$vm"; then
  if sysctl -n machdep.cpu.brand_string | grep -q 'M[12]'; then
    # QEMU's own UEFI firmware: Lima looks for it next to the wrapper
    fw="$(dirname "$(command -v qemu-system-aarch64)")/../share/qemu/edk2-aarch64-code.fd"
    set_type=".vmType = \"qemu\" | .firmware.images = [{\"location\": \"$fw\", \"arch\": \"aarch64\"}]"
  else
    set_type='.vmType = "vz" | .nestedVirtualization = true'
  fi
  limactl create --tty=false --name "$vm" --set "$set_type" --set '.mounts = []' \
    "$repo/scripts/lima/linux-host.yaml"
fi
limactl list -f '{{.Status}}' "$vm" | grep -q Running || limactl start --tty=false "$vm"
# A fresh copy of the working tree (no mount: a cached 9p mount goes stale);
# builds in the guest never touch the Mac's tree.
tar --no-xattrs -C "$repo" --exclude ./out --exclude ./openvmm --exclude ./.git -cf - . \
  | limactl shell "$vm" -- bash -c 'rm -rf ~/bend-vmm.new && mkdir ~/bend-vmm.new && tar -xf - -C ~/bend-vmm.new 2>/dev/null; mkdir -p ~/bend-vmm/out && rm -rf ~/bend-vmm.keep && mv ~/bend-vmm/out ~/bend-vmm.keep && rm -rf ~/bend-vmm && mv ~/bend-vmm.new ~/bend-vmm && mv ~/bend-vmm.keep ~/bend-vmm/out'
if [ $# = 0 ]; then
  exec limactl shell --workdir "\$HOME/bend-vmm" "$vm"
fi
exec limactl shell "$vm" -- bash -lc "cd ~/bend-vmm && export PATH=\$HOME/.bend/bin:\$PATH && $*"
