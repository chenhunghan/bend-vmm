#!/usr/bin/env bash
# Assembles a bare-metal arm64 payload (tests/guest/<name>.S) into a flat
# binary (out/guest/<name>.bin) with clang and llvm-objcopy.
set -euo pipefail
cd "$(dirname "$0")/.."
name=$1
objcopy=$(command -v llvm-objcopy || true)
# Homebrew's llvm (or a versioned llvm@N) is keg-only: not on PATH.
for c in /opt/homebrew/opt/llvm/bin/llvm-objcopy /opt/homebrew/opt/llvm@*/bin/llvm-objcopy; do
  [ -n "$objcopy" ] || { [ -x "$c" ] && objcopy=$c; }
done
[ -n "$objcopy" ] || objcopy=$(command -v objcopy)
mkdir -p out/guest
clang -target aarch64-none-elf -c "tests/guest/$name.S" -o "out/guest/$name.o"
"$objcopy" -O binary "out/guest/$name.o" "out/guest/$name.bin"
rm -f "out/guest/$name.o"
echo "out/guest/$name.bin"
