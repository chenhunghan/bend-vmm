#!/usr/bin/env bash
# Removes build artifacts: binaries, native test builds, logs, disk images,
# unpacked packages. Keeps the downloaded guest assets (kernels, modules,
# busybox) so the next check does not fetch them again; --all removes those
# too (out/ entirely).
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" = --all ]; then
  rm -rf out
  exit 0
fi
[ -d out ] || exit 0
rm -rf out/native out/pr out/guest/deb out/guest/extra out/guest/bb
rm -f out/bend-vmm out/smoke out/fs_smoke out/zz* out/*.log out/*.c
rm -f out/guest/*.deb out/guest/*.apk out/guest/*.img out/guest/*.o out/guest/*.bin
rm -f out/linux/*.o
# Directories left empty go too.
find out -type d -empty -delete 2>/dev/null || true
