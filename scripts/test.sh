#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build.noindex/tests/cache
build_arch=$(uname -m)
xcrun swiftc -target "$build_arch-apple-macos15.0" -parse-as-library \
  -module-cache-path "$PWD/build.noindex/tests/cache" Sources/zoom-audio.swift Tests/AudioTests.swift Tests/MuteTests.swift \
  -o build.noindex/tests/audio-tests
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
build.noindex/tests/audio-tests "$test_dir"
