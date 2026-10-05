#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app="$1"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime \
    --entitlements Resources/Entitlements.plist "$app"
else
  keychain=$(python3 scripts/prepare_local_signing.py)
  codesign --force --sign 'Zoom Audio Recorder Local Code Signing' --keychain "$keychain" \
    --options runtime --entitlements Resources/Entitlements.plist "$app"
fi
codesign --verify --strict "$app"
