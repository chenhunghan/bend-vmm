#!/usr/bin/env bash
# Packs a built bend-vmm with the README into
# out/release/bend-vmm-<version>-<platform>.tar.gz.
#   scripts/release/package.sh <binary> <platform>
set -euo pipefail
cd "$(dirname "$0")/../.."
bin=$1 platform=$2
v=$("$bin" --version | cut -d' ' -f2)
name=bend-vmm-$v-$platform
rm -rf "out/release/$name" && mkdir -p "out/release/$name"
cp "$bin" "out/release/$name/bend-vmm"
cp README.md "out/release/$name/"
tar -czf "out/release/$name.tar.gz" -C out/release "$name"
rm -rf "out/release/$name"
echo "out/release/$name.tar.gz"
