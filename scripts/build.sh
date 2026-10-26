#!/usr/bin/env bash
# Builds a host program (default host/main.bend) for this host: macOS on
# Apple Silicon (scripts/build-mac.sh: Hypervisor.framework, signed) or
# Linux on arm64 (KVM; needs clang).
#   scripts/build.sh [host/<prog>.bend] [out/<name>]
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -s)" in
  Darwin) exec scripts/build-mac.sh "$@" ;;
esac
src=${1:-host/main.bend}
out=${2:-out/$(basename "$src" .bend)}
mkdir -p "$(dirname "$out")"
bend "$src" -o "$out" > "$out.log" 2>&1 || { cat "$out.log" >&2; exit 1; }
rm -f "$out.log"
echo "$out"
