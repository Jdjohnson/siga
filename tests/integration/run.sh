#!/bin/zsh
# Actual controller/session/DSP with simulated HAL; no system audio is used.
set -euo pipefail
cd "${0:A:h}"
mkdir -p ../.build
target="$(uname -m)-apple-macos14.2"
csan=() swiftsan=()
if [[ "${MUFFLE_ASAN:-0}" == 1 ]]; then csan=(-fsanitize=address); swiftsan=(-sanitize=address); fi
xcrun clang -std=c11 -target "$target" -O2 -Wall -Wextra -Werror "${csan[@]}" -c ../../MuffleDSP.c -o ../.build/MuffleDSP-integration.o
python3 generate.py
xcrun swiftc -target "$target" -import-objc-header ../../MuffleDSP.h -module-cache-path /private/tmp/siga-swift-cache "${swiftsan[@]}" \
    ../.build/integration.swift ../.build/MuffleDSP-integration.o -o ../.build/integration -framework CoreAudio -framework Foundation
../.build/integration "${1:-0}" | tee ../.build/integration.txt | grep -E '^(FAIL|PASS)'
