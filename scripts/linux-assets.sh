#!/usr/bin/env bash
# Fetches the arm64 kernel for the Linux boot test and builds its initramfs:
#   out/linux/linux       Debian bookworm netboot kernel (uncompressed Image)
#   out/linux/initrd.cpio /dev/console + tests/guest/init.S as /init
# Needs clang and Homebrew's lld (brew install lld).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out/linux
url=https://deb.debian.org/debian/dists/bookworm/main/installer-arm64/current/images/netboot/debian-installer/arm64/linux
known=84b9c190bb4589c4a9527e3191fec051f9f115e88f0a3e8afae96ba0dfb4dfef
if [ ! -f out/linux/linux ]; then curl -fsSL -o out/linux/linux "$url"; fi
got=$(shasum -a 256 out/linux/linux | cut -d' ' -f1)
[ "$got" = "$known" ] || echo "linux-assets: note: kernel sha256 $got differs from the one last tested ($known)" >&2
lld=$(command -v ld.lld || ls /opt/homebrew/opt/lld*/bin/ld.lld 2>/dev/null | tail -1)
clang -target aarch64-linux-gnu -c tests/guest/init.S -o out/linux/init.o
"$lld" -static -e _start out/linux/init.o -o out/linux/init
python3 scripts/initramfs.py out/linux/init out/linux/initrd.cpio
rm -f out/linux/init.o
echo out/linux/linux out/linux/initrd.cpio
