#!/bin/zsh
# Default: an ad-hoc signed Siga.app for local use.
# Release: set SIGA_IDENTITY to a "Developer ID Application: …" identity and SIGA_NOTARY to a
# notarytool keychain profile to also sign, notarize, and create the drag-to-Applications DMG.
set -eu
cd "${0:A:h}"
rm -rf Siga.app Siga.zip Siga.dmg   # every build starts from nothing, so no stale file survives
mkdir -p Siga.app/Contents/MacOS Siga.app/Contents/Resources
cp assets/MenuIcon.pdf assets/AppIcon.icns assets/Wordmark.png Siga.app/Contents/Resources/
xcrun swiftc -target arm64-apple-macos14.2 -Osize -whole-module-optimization -Xfrontend -disable-reflection-metadata -Xlinker -objc_stubs_small -module-cache-path /private/tmp/siga-swift-cache main.swift Setup.swift Welcome.swift -o Siga.app/Contents/MacOS/Siga -framework AppKit -framework CoreAudio -framework ServiceManagement
cat > Siga.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Siga</string>
<key>CFBundleIdentifier</key><string>io.mostlyserious.siga</string>
<key>CFBundleName</key><string>Sigá</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>18</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>© 2026 Mostly Serious</string>
</dict></plist>
PLIST
xcrun strip -STx Siga.app/Contents/MacOS/Siga
# The size budget is part of the product. Nothing prints Swift values by reflection, so that metadata is left out.
check_size() {
    (( $(stat -f %z Siga.app/Contents/MacOS/Siga) <= 200000 )) || { echo "Siga is over its 200 KB budget" >&2; exit 1; }
}
check_size
if [[ -z "${SIGA_IDENTITY:-}" ]]; then
    codesign --force --sign - Siga.app
    check_size
    exit 0
fi
: "${SIGA_NOTARY:?set SIGA_NOTARY to a notarytool keychain profile}"   # checked before anything is signed
# Reserve 11 KB for the complete CMS signature (currently about 9 KB), rather than
# codesign's larger default padding. A larger future chain fails signing; never truncate it.
codesign --force --signature-size 11000 --timestamp --options runtime --sign "$SIGA_IDENTITY" Siga.app
check_size
trap 'rm -f Siga.zip' ERR   # a failed notarization, staple, or assessment leaves no half-finished archive behind
ditto -c -k --keepParent Siga.app Siga.zip
xcrun notarytool submit Siga.zip --keychain-profile "$SIGA_NOTARY" --wait
xcrun stapler staple Siga.app
ditto -c -k --keepParent Siga.app Siga.zip
spctl -a -vv Siga.app
# The ZIP above submits the app for its own stapled ticket. The public download is the DMG.
./package-dmg.sh Siga.app Siga.dmg
