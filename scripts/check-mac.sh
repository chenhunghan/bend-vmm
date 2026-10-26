#!/usr/bin/env bash
# The real-guest check on macOS: scripts/check-host.sh (which also runs on a
# Linux KVM host).
exec "$(dirname "$0")/check-host.sh" "$@"
