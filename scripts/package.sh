#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
destination="${1:-$PWD/build.noindex/Zoom Audio Recorder.dmg}"
python_bin="${PYTHON_BIN:-python3}"
volume='Zoom Audio Recorder'
mkdir -p build.noindex/installer/.background build.noindex/packaging
if ! PYTHONPATH="$PWD/build.noindex/packaging" "$python_bin" -c 'import ds_store, mac_alias' 2>/dev/null; then
  "$python_bin" -m pip install --target "$PWD/build.noindex/packaging" ds_store==1.3.2 mac_alias==2.2.3
fi
build_arch=$(uname -m)
xcrun swiftc -target "$build_arch-apple-macos15.0" -module-cache-path "$PWD/build.noindex/packaging/cache" \
  scripts/InstallerArtwork.swift -o build.noindex/packaging/artwork
build.noindex/packaging/artwork "$PWD/build.noindex/installer/.background/installer.png"
ditto "build.noindex/Zoom Audio Recorder.app" "build.noindex/installer/Zoom Audio Recorder.app"
[[ -L build.noindex/installer/Applications ]] || ln -s /Applications build.noindex/installer/Applications
cp "build.noindex/Zoom Audio Recorder.app/Contents/Resources/AppIcon.icns" build.noindex/installer/.VolumeIcon.icns
xcrun SetFile -a C build.noindex/installer
hdiutil create -ov -size 64m -fs HFS+ -volname "$volume" \
  -srcfolder build.noindex/installer -format UDRW build.noindex/installer-rw.dmg
mkdir -p build.noindex/mount
hdiutil attach -nobrowse -noverify -mountpoint "$PWD/build.noindex/mount" build.noindex/installer-rw.dmg
trap 'hdiutil detach "$PWD/build.noindex/mount" >/dev/null 2>&1 || true' EXIT
PYTHONPATH="$PWD/build.noindex/packaging" "$python_bin" scripts/finder_layout.py "$PWD/build.noindex/mount" "$volume"
sync
hdiutil detach "$PWD/build.noindex/mount"
trap - EXIT
mkdir -p "${destination:h}"
hdiutil convert -ov build.noindex/installer-rw.dmg -format UDZO -imagekey zlib-level=9 -o "$destination"
hdiutil verify "$destination"
identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)
if [[ -n "$identity" ]]; then
  # Notarized and stapled, the installer and the app open without a trip to Privacy & Security.
  # Credentials: xcrun notarytool store-credentials zoom-audio-recorder --apple-id … --team-id …
  codesign --force --timestamp --sign "$identity" "$destination"
  xcrun notarytool submit "$destination" --keychain-profile zoom-audio-recorder --wait
  xcrun stapler staple "$destination"
  spctl --assess --type open --context context:primary-signature --verbose "$destination"
fi
echo "Установщик: $destination"
