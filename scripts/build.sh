#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
cache_dir="$(mktemp -d)"
trap 'rm -rf "$cache_dir"' EXIT
app="$PWD/build.noindex/Zoom Audio Recorder.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
for arch in arm64 x86_64; do
  CLANG_MODULE_CACHE_PATH="$cache_dir" SWIFT_MODULECACHE_PATH="$cache_dir" \
    xcrun swiftc -target "$arch-apple-macos15.0" -O -parse-as-library Sources/*.swift \
    -o "$cache_dir/zoom-audio-$arch"
done
xcrun lipo -create "$cache_dir/zoom-audio-arm64" "$cache_dir/zoom-audio-x86_64" \
  -output "$app/Contents/MacOS/zoom-audio"
appiconset="$cache_dir/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$appiconset"
cp Resources/AppIconContents.json "$appiconset/Contents.json"
for size in 16 32 128 256 512; do
  file=$(printf 'icon_%sx%s.png' "$size" "$size")
  sips -s format png -z "$size" "$size" Resources/AppIcon.png \
    --out "$appiconset/$file" >/dev/null
  double=$((size * 2))
  file=$(printf 'icon_%sx%s@2x.png' "$size" "$size")
  sips -s format png -z "$double" "$double" Resources/AppIcon.png \
    --out "$appiconset/$file" >/dev/null
done
if ! xcrun actool --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist "$cache_dir/asset.plist" \
  "$cache_dir/Assets.xcassets" >"$cache_dir/actool.log" 2>&1; then
  cat "$cache_dir/actool.log"
  exit 1
fi
zsh scripts/sign.sh "$app"
echo "Готово: $app"
