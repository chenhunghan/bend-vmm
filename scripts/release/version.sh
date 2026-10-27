#!/usr/bin/env bash
# Writes the version bend-vmm --version prints into host/version.bend: the
# tag (v1.2.3 -> 1.2.3) for a release, else dev-<commit>.
#   scripts/release/version.sh <ref name>
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-}" in
  v[0-9]*) v=${1#v} ;;
  *) v="dev-$(git rev-parse --short HEAD)" ;;
esac
perl -pi -e 's/^  "[^"]*"$/  "'"$v"'"/' host/version.bend
grep -q "\"$v\"" host/version.bend
echo "$v"
