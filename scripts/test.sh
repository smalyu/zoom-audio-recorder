#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build/tests/cache
build_arch=$(uname -m)
xcrun swiftc -target "$build_arch-apple-macos15.0" -parse-as-library \
  -module-cache-path "$PWD/build/tests/cache" Sources/zoom-audio.swift Tests/AudioTests.swift \
  -o build/tests/audio-tests
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
build/tests/audio-tests "$test_dir"
