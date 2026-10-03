#!/bin/zsh
# Needs a macOS GUI session; no window is presented and no input is sent.
set -euo pipefail
cd "${0:A:h}"
mkdir -p ../.build
cat ../../Setup.swift ../../Welcome.swift main.swift > ../.build/controls.swift
xcrun swiftc -module-cache-path /private/tmp/siga-swift-cache ../.build/controls.swift -o ../.build/controls -framework AppKit
../.build/controls
