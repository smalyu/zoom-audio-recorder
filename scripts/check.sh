#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

# Check the app and its preview-only code without creating a bundle or using Keychain.
for check_arch in arm64 x86_64; do
  for check_mode in app preview; do
    check_cache="$PWD/build.noindex/check/$check_arch/$check_mode"
    mkdir -p "$check_cache"
    check_flags=()
    if [[ "$check_mode" == preview ]]; then
      check_flags=(-D PREVIEW)
    fi
    echo "Проверка Swift: $check_arch ($check_mode)"
    xcrun swiftc -target "$check_arch-apple-macos15.0" -parse-as-library -typecheck \
      -module-cache-path "$check_cache" "${check_flags[@]}" Sources/*.swift
  done
done

echo "Запуск тестов"
zsh scripts/test.sh
echo "Все проверки пройдены"
