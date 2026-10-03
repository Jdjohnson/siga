#!/bin/zsh
# Deterministic fault tests for the current MuffleSession.swift against a simulated HAL.
# Nothing here plays, captures or changes audio: HAL calls, both queues and the clock are doubles,
# and the real MuffleDSP.c renders synthetic buffers. MUFFLE_ASAN=1 also builds with AddressSanitizer.
set -euo pipefail
cd "${0:A:h}"
mkdir -p ../.build
target="$(uname -m)-apple-macos14.2"
csan=() swiftsan=()
if [[ "${MUFFLE_ASAN:-0}" == 1 ]]; then csan=(-fsanitize=address); swiftsan=(-sanitize=address); fi
xcrun clang -std=c11 -fblocks -target "$target" -O2 -Wall -Wextra -Werror "${csan[@]}" -c ../../MuffleDSP.c -o ../.build/MuffleDSP-muffle.o
python3 generate.py --out ../.build/muffle.swift
xcrun swiftc -target "$target" -import-objc-header ../../MuffleDSP.h -module-cache-path /private/tmp/siga-swift-cache "${swiftsan[@]}" \
    ../.build/muffle.swift ../.build/MuffleDSP-muffle.o -o ../.build/muffle -framework CoreAudio -framework Foundation
../.build/muffle | tee ../.build/muffle.txt | grep -E '^(FAIL|SUMMARY)'
