#!/usr/bin/env bash
# Assembles a bare-metal arm64 payload (tests/guest/<name>.S) into a flat
# binary (out/guest/<name>.bin) with clang and llvm-objcopy.
set -euo pipefail
cd "$(dirname "$0")/.."
name=$1
objcopy=$(command -v llvm-objcopy || echo /opt/homebrew/opt/llvm/bin/llvm-objcopy)
mkdir -p out/guest
clang -target aarch64-none-elf -c "tests/guest/$name.S" -o "out/guest/$name.o"
"$objcopy" -O binary "out/guest/$name.o" "out/guest/$name.bin"
rm -f "out/guest/$name.o"
echo "out/guest/$name.bin"
