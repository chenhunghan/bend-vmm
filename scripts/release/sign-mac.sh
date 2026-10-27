#!/usr/bin/env bash
# Signs a macOS bend-vmm with the Developer ID in MACOS_SIGN_P12 (hardened
# runtime, the Hypervisor.framework entitlement, a secure timestamp) and
# notarizes it with the App Store Connect API key in APPLE_API_KEY (see
# .github/workflows/release.yml). Without those secrets it signs ad hoc, which
# a release tag refuses.
#   scripts/release/sign-mac.sh <binary>
set -euo pipefail
cd "$(dirname "$0")/../.."
bin=$1
if [ -z "${MACOS_SIGN_P12:-}" ] || [ -z "${APPLE_API_KEY:-}" ]; then
  case "${GITHUB_REF:-}" in
    refs/tags/v*) echo "sign-mac: a release needs MACOS_SIGN_P12 and APPLE_API_KEY" >&2; exit 1 ;;
  esac
  echo "sign-mac: no signing secrets: ad-hoc signature, not notarized"
  codesign -s - --force --entitlements host/hv.entitlements "$bin"
  exit 0
fi
work=$(mktemp -d)
trap 'security delete-keychain "$work/sign.keychain-db" 2>/dev/null || true; rm -rf "$work"' EXIT
# A throwaway keychain holding only the Developer ID.
pass=$(openssl rand -hex 16)
security create-keychain -p "$pass" "$work/sign.keychain-db"
security set-keychain-settings -lut 3600 "$work/sign.keychain-db"
security unlock-keychain -p "$pass" "$work/sign.keychain-db"
echo "$MACOS_SIGN_P12" | base64 --decode > "$work/id.p12"
security import "$work/id.p12" -k "$work/sign.keychain-db" -P "$MACOS_SIGN_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$pass" "$work/sign.keychain-db" >/dev/null
security list-keychains -d user -s "$work/sign.keychain-db" $(security list-keychains -d user | tr -d '"')
id=$(security find-identity -v -p codesigning "$work/sign.keychain-db" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
[ -n "$id" ] || { echo "sign-mac: no Developer ID Application identity in MACOS_SIGN_P12" >&2; exit 1; }
codesign --force --options runtime --timestamp --entitlements host/hv.entitlements -s "$id" "$bin"
codesign --verify --strict --verbose=2 "$bin"
# notarytool takes a zip; a bare binary cannot be stapled, so Gatekeeper
# looks the ticket up online.
echo "$APPLE_API_KEY" | base64 --decode > "$work/key.p8"
ditto -c -k --keepParent "$bin" "$work/bend-vmm.zip"
xcrun notarytool submit "$work/bend-vmm.zip" --key "$work/key.p8" --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID" --wait --timeout 30m --output-format json | tee "$work/notary.json"
grep -q '"status" *: *"Accepted"' "$work/notary.json" || { echo "sign-mac: notarization was not accepted" >&2; exit 1; }
echo "sign-mac: signed by $id and notarized"
