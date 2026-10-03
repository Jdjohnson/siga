#!/bin/zsh
# Runs the regression harnesses against the product source in this repository.
# Nothing here plays, records or changes audio. Engine/app calls use doubles;
# the tile accessibility assertion constructs the native controls without opening a window.
set -euo pipefail
cd "$(dirname "$0")"
for name in ducking app; do
    python3 "$name/generate.py" > /dev/null
    xcrun swiftc -module-cache-path /private/tmp/siga-swift-cache ".build/$name.swift" -o ".build/$name"
    ".build/$name" | tee ".build/$name.txt" | grep -E '^(FAIL|SUMMARY|passed)'
done
zsh muffle/run.sh
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror dsp.c ../MuffleDSP.c -framework CoreAudio -o .build/dsp
.build/dsp | tee .build/dsp.txt
