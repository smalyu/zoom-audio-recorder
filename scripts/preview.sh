#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
destination="${1:-$PWD/build.noindex/previews}"
mkdir -p "$destination" build.noindex/previews/cache
build_arch=$(uname -m)
xcrun swiftc -D PREVIEW -target "$build_arch-apple-macos15.0" -parse-as-library \
  -module-cache-path "$PWD/build.noindex/previews/cache" Sources/*.swift \
  -o build.noindex/previews/recorder-preview
for appearance in light dark; do
  for state in idle nozoom permissions preparing recording muted unknown reconnecting warnings \
    saving saved closed fallback kept failed recovered recovering safety unrecovered damaged longfolder; do
    build.noindex/previews/recorder-preview "$destination/$state-$appearance.png" "$state" "--$appearance"
  done
done
echo "Снимки интерфейса: $destination"
