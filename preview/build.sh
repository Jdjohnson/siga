#!/bin/zsh
# Build the same native onboarding UI with an in-memory backend.
set -eu
siga_source="${${1:-${0:A:h:h}}:A}"   # resolved before the cd, so this runs from the repository root too
cd "${0:A:h}"
siga_preview='Sigá Onboarding Preview.app'
mkdir -p "$siga_preview/Contents/MacOS" "$siga_preview/Contents/Resources"
cp "$siga_source/assets/Wordmark.png" "$siga_source/assets/MenuIcon.pdf" "$siga_source/assets/AppIcon.icns" "$siga_preview/Contents/Resources/"
xcrun swiftc -D SIGA_PREVIEW -target arm64-apple-macos14.2 -module-cache-path /private/tmp/siga-preview-swift-cache "$siga_source/Setup.swift" "$siga_source/Welcome.swift" main.swift -o "$siga_preview/Contents/MacOS/SigaPreview" -framework AppKit
cat > "$siga_preview/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SigaPreview</string>
<key>CFBundleIdentifier</key><string>io.mostlyserious.siga.onboarding-preview</string>
<key>CFBundleName</key><string>Sigá Preview</string>
<key>CFBundleDisplayName</key><string>Sigá Preview — Simulated</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>16</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$siga_preview"
