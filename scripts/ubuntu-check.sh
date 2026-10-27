#!/usr/bin/env bash
# A real distribution on bend-vmm: Ubuntu 24.04's arm64 cloud image (qcow2,
# ~600 MiB, downloaded once into out/ubuntu) boots through UEFI from a qcow2
# overlay with a cloud-init seed disk (NoCloud), 4 vCPUs. cloud-init reports
# on the console: the kernel, the CPUs, systemd's failed units and an HTTPS
# request through the NAT. Then SIGTERM presses the power button and systemd
# must power off cleanly, leaving an overlay qemu-img checks clean.
#   scripts/ubuntu-check.sh           (needs qemu-img; macOS: hdiutil,
#                                      Linux: genisoimage or xorriso)
# SKIP_BUILD=1 uses out/bend-vmm as it is.
set -uo pipefail
cd "$(dirname "$0")/.."
red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
command -v qemu-img >/dev/null || { echo "ubuntu-check: needs qemu-img"; exit 2; }
[ "${SKIP_BUILD:-0}" = 1 ] || scripts/build.sh host/main.bend out/bend-vmm >/dev/null || exit 1
scripts/uefi-assets.sh >/dev/null || exit 1
mkdir -p out/ubuntu
img=out/ubuntu/noble-server-cloudimg-arm64.img
[ -f "$img" ] || curl -fL -o "$img.part" https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img && mv "$img.part" "$img" 2>/dev/null
[ -f "$img" ] || { echo "ubuntu-check: cannot download the image"; exit 1; }
t=$(mktemp -d)
trap 'kill $vm 2>/dev/null; rm -rf "$t"' EXIT
mkdir "$t/seed"
printf 'instance-id: bend-vmm-check\nlocal-hostname: bendcheck\n' > "$t/seed/meta-data"
cat > "$t/seed/user-data" <<'EOF'
#cloud-config
runcmd:
  - [ sh, -c, 'echo "UBUNTU-UP $(uname -r) $(nproc) cpus" > /dev/ttyAMA0' ]
  - [ sh, -c, 'echo "UBUNTU-HTTPS $(curl -s -o /dev/null -w %{http_code} https://cloud-images.ubuntu.com/)" > /dev/ttyAMA0' ]
  - [ sh, -c, 'echo "UBUNTU-FAILED $(systemctl --failed --no-legend | wc -l)" > /dev/ttyAMA0' ]
EOF
case "$(uname -s)" in
  Darwin) hdiutil makehybrid -quiet -o "$t/seed.iso" "$t/seed" -iso -joliet -default-volume-name cidata ;;
  *) (command -v genisoimage >/dev/null && genisoimage -quiet -o "$t/seed.iso" -V cidata -J -r "$t/seed") \
       || xorriso -as mkisofs -quiet -o "$t/seed.iso" -V cidata -J -r "$t/seed" ;;
esac || { echo "ubuntu-check: cannot make the seed ISO"; exit 1; }
qemu-img create -q -f qcow2 -b "$(cd "$(dirname "$img")" && pwd)/$(basename "$img")" -F qcow2 "$t/over.qcow2" 8G
cp out/uefi/vars.fd "$t/vars.fd"
./out/bend-vmm --firmware out/uefi/code.fd --vars "$t/vars.fd" --mem 2048 --cpus 4 --disk "$t/over.qcow2,$t/seed.iso:ro" \
  < /dev/null > "$t/run.log" 2>&1 &
vm=$!
start=$(date +%s)
until grep -aq "UBUNTU-FAILED" "$t/run.log" || ! kill -0 $vm 2>/dev/null || [ $(($(date +%s) - start)) -gt "${UBUNTU_TIMEOUT:-300}" ]; do sleep 1; done
up=$(($(date +%s) - start))
log=$(tr -d '\r' < "$t/run.log")
fail=0
grep -aq "^UBUNTU-UP .* 4 cpus" <<<"$log" && grn "ok: Ubuntu boots ($(grep -a '^UBUNTU-UP' <<<"$log" | cut -d' ' -f2), cloud-init done in ${up}s)" || { red "failed: Ubuntu boot"; grep -av sysreg <<<"$log" | tail -20; fail=1; }
grep -aq "^UBUNTU-HTTPS 200" <<<"$log" && grn "ok: HTTPS through the NAT" || { red "failed: HTTPS from the guest"; grep -a "^UBUNTU-HTTPS" <<<"$log"; fail=1; }
grep -aq "^UBUNTU-FAILED 0" <<<"$log" && grn "ok: no failed systemd units" || { red "failed: systemd units failed"; grep -a "^UBUNTU-FAILED\|FAILED" <<<"$log" | head; fail=1; }
kill -TERM $vm 2>/dev/null
s=$(date +%s)
while kill -0 $vm 2>/dev/null && [ $(($(date +%s) - s)) -lt 30 ]; do sleep 0.5; done
wait $vm; code=$?
[ $code = 0 ] && grep -aq "reboot: Power down" "$t/run.log" && grn "ok: SIGTERM shuts Ubuntu down cleanly ($(($(date +%s) - s))s)" || { red "failed: SIGTERM shutdown (exit $code)"; tail -5 "$t/run.log"; fail=1; }
qemu-img check -q "$t/over.qcow2" && grn "ok: qemu-img check of the overlay" || { red "failed: qemu-img check"; fail=1; }
if [ $fail = 0 ]; then grn "UBUNTU OK"; else red "UBUNTU FAILED"; fi
exit $fail
