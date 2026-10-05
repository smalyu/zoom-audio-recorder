#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
destination="${1:-$PWD/build/Zoom Audio Recorder.dmg}"
python_bin="${PYTHON_BIN:-python3}"
mkdir -p build/installer/.background build/packaging
if ! PYTHONPATH="$PWD/build/packaging" "$python_bin" -c 'import ds_store, mac_alias' 2>/dev/null; then
  "$python_bin" -m pip install --target "$PWD/build/packaging" ds_store==1.3.2 mac_alias==2.2.3
fi
build_arch=$(uname -m)
xcrun swiftc -target "$build_arch-apple-macos15.0" -module-cache-path "$PWD/build/packaging/cache" \
  scripts/InstallerArtwork.swift -o build/packaging/artwork
build/packaging/artwork "$PWD/build/installer/.background/installer.png"
ditto "build/Zoom Audio Recorder.app" "build/installer/Zoom Audio Recorder.app"
[[ -L build/installer/Applications ]] || ln -s /Applications build/installer/Applications
cp "build/Zoom Audio Recorder.app/Contents/Resources/AppIcon.icns" build/installer/.VolumeIcon.icns
xcrun SetFile -a C build/installer
hdiutil create -ov -size 64m -fs HFS+ -volname 'Zoom Audio Recorder' \
  -srcfolder build/installer -format UDRW build/installer-rw.dmg
mkdir -p build/mount
hdiutil attach -nobrowse -noverify -mountpoint "$PWD/build/mount" build/installer-rw.dmg
trap 'hdiutil detach "$PWD/build/mount" >/dev/null 2>&1 || true' EXIT
PYTHONPATH="$PWD/build/packaging" "$python_bin" scripts/finder_layout.py "$PWD/build/mount"
sync
hdiutil detach "$PWD/build/mount"
trap - EXIT
mkdir -p "${destination:h}"
hdiutil convert -ov build/installer-rw.dmg -format UDZO -imagekey zlib-level=9 -o "$destination"
hdiutil verify "$destination"
echo "Установщик: $destination"
