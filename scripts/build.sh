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
# Bend's `-o <bin>` links libX11 for its window runtime, so the binary would
# not start on a headless server. Build the C, load Xlib at run time
# (scripts/x11-lazy.sh), and compile it as `bend -o` does, without -lX11.
bend "$src" -o "$out.c" > "$out.log" 2>&1 || { cat "$out.log" >&2; exit 1; }
scripts/x11-lazy.sh "$out.c"
${CC:-clang} -std=c11 -O3 "$out.c" -lpthread -lm -ldl -o "$out" > "$out.log" 2>&1 || { cat "$out.log" >&2; exit 1; }
rm -f "$out.log" "$out.c"
echo "$out"
