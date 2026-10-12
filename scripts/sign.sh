#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app="$1"
# A Developer ID in the keychain signs builds that can be notarized; without one, a
# private local identity keeps macOS permissions across rebuilds.
identity="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}"
if [[ -n "$identity" ]]; then
  codesign --force --timestamp --sign "$identity" --options runtime \
    --entitlements Resources/Entitlements.plist "$app"
else
  keychain=$(python3 scripts/prepare_local_signing.py)
  codesign --force --sign 'Zoom Audio Recorder Local Code Signing' --keychain "$keychain" \
    --options runtime --entitlements Resources/Entitlements.plist "$app"
fi
codesign --verify --strict "$app"
