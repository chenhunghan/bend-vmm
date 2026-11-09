#!/usr/bin/env bash
# Makes this Linux arm64 machine with KVM a GitHub Actions runner for
# bend-vmm's host-linux-kvm job (.github/workflows/ci.yml), so CI boots its
# guests on real KVM in minutes instead of an hour of emulated EL2. Any
# arm64 Linux with /dev/kvm will do: a bare-metal cloud server (AWS
# *g.metal, Hetzner's Ampere servers), an Ampere workstation, or
# scripts/lima/linux-host.yaml on an M3 or later Mac (vmType vz, nested
# virtualization). Then set the repository variable KVM_RUNNER to "true".
#   scripts/ci/kvm-runner.sh [OWNER/REPO]   (default: this checkout's origin)
# Registers with a token from `gh api` (gh logged in with admin rights on
# the repository) or from $RUNNER_TOKEN. Run as the user the runner runs as
# (not root); it installs the toolchain with sudo, Bend as CI pins it, and
# the runner as a service under ~/actions-runner.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "$(uname -s)-$(uname -m)" = Linux-aarch64 ] || { echo "kvm-runner: needs Linux on arm64"; exit 2; }
[ -e /dev/kvm ] || { echo "kvm-runner: no /dev/kvm on this machine"; exit 2; }
repo=${1:-$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}

echo "== toolchain"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y clang lld libx11-dev zstd qemu-utils python3 curl git perl netcat-openbsd
# this user may open /dev/kvm (the kvm group), from the next login on
sudo usermod -aG kvm "$USER"
sudo chmod 666 /dev/kvm

echo "== Bend, as CI pins it"
bv=$(awk '/BEND_VERSION:/ {print $2; exit}' .github/workflows/ci.yml)
bs=$(awk '/BEND_SHA_LINUX_ARM64:/ {print $2; exit}' .github/workflows/ci.yml)
if ! "$HOME/.bend/bin/bend" 2>&1 | grep -q "^Bend $bv:"; then
  n=bend-$bv-linux-arm64.tar.gz; t=$(mktemp -d)
  curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-all-errors --retry-delay 10 -o "$t/$n" "https://github.com/bendlang/bend/releases/download/v$bv/$n"
  echo "$bs  $t/$n" | sha256sum -c -
  tar -xzf "$t/$n" -C "$t"
  mkdir -p "$HOME/.bend/bin"; rm -rf "$HOME/.bend/bend2" "$HOME/.bend/guide"
  mv "$t/bend/bend2" "$t/bend/guide" "$HOME/.bend/"; mv "$t/bend/bin/bend" "$HOME/.bend/bin/bend"; rm -rf "$t"
fi

echo "== the runner"
token=${RUNNER_TOKEN:-$(gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token)}
ver=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')
mkdir -p "$HOME/actions-runner" && cd "$HOME/actions-runner"
[ -x ./config.sh ] || curl -fsSL "https://github.com/actions/runner/releases/download/v$ver/actions-runner-linux-arm64-$ver.tar.gz" | tar -xz
./config.sh --unattended --url "https://github.com/$repo" --token "$token" --labels kvm --name "$(hostname)-kvm" --replace
sudo ./svc.sh install "$USER" && sudo ./svc.sh start
echo "kvm-runner: registered for $repo; now set the repository variable KVM_RUNNER=true"
