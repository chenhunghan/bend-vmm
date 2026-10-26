#!/usr/bin/env bash
# Builds a host program (default host/main.bend) into a native macOS binary
# and signs it with the Hypervisor.framework entitlement.
#   scripts/build-mac.sh [host/<prog>.bend] [out/<name>]
# Command Line Tools clang 17 cannot link against the macOS 27 SDK (its tapi
# rejects arm64e.x1 stubs), so when the default SDK fails this retries with
# the newest installed SDK that links.
set -euo pipefail
cd "$(dirname "$0")/.."
src=${1:-host/main.bend}
out=${2:-out/$(basename "$src" .bend)}
mkdir -p "$(dirname "$out")"

build() { bend "$src" -o "$out" > "$out.log" 2>&1; }
if ! build; then
  ok=0
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX2[0-9].*.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX1[5-9]*.sdk 2>/dev/null | sort -rV); do
    if SDKROOT=$sdk build; then ok=1; break; fi
  done
  if [ $ok = 0 ]; then cat "$out.log" >&2; exit 1; fi
fi
codesign -s - --entitlements host/hv.entitlements -f "$out" 2>/dev/null
rm -f "$out.log"
echo "$out"
