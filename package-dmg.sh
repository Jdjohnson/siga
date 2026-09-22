#!/bin/zsh
# Package an already signed and stapled app; does not launch or install it.
set -eu
[[ $# -ge 1 && $# -le 2 ]] || { echo 'Usage: package-dmg.sh /path/to/Siga.app [/path/to/Siga.dmg]' >&2; exit 2; }
: "${SIGA_IDENTITY:?set SIGA_IDENTITY to a Developer ID Application identity}"
: "${SIGA_NOTARY:?set SIGA_NOTARY to a notarytool keychain profile}"
siga_packaging="${0:A:h}/packaging"
siga_app="${1:A}"
siga_output="${2:-${0:A:h}/Siga.dmg}"
siga_output="${siga_output:A}"
[[ -d "$siga_app" && ! -e "$siga_output" ]] || { echo 'App must exist and output must be a new file.' >&2; exit 2; }
codesign --verify --deep --strict "$siga_app"
xcrun stapler validate "$siga_app"
(( $(stat -f %z "$siga_app/Contents/MacOS/Siga") <= 200000 )) || { echo 'Siga is over its 200 KB budget' >&2; exit 1; }
siga_tmp=$(mktemp -d /private/tmp/siga-dmg.XXXXXX)
siga_mount=''
siga_cleanup() {
    if [[ -n "$siga_mount" ]]; then hdiutil detach "$siga_mount" >/dev/null 2>&1 || true; fi
    rm -rf "$siga_tmp"
}
trap siga_cleanup EXIT
mkdir "$siga_tmp/root"
ditto "$siga_app" "$siga_tmp/root/Siga.app"
ln -s /Applications "$siga_tmp/root/Applications"
cp "$siga_packaging/finder-layout.dsstore" "$siga_tmp/root/.DS_Store"
cp "$siga_packaging/background.tiff" "$siga_tmp/root/.background.tiff"
cp "$siga_app/Contents/Resources/AppIcon.icns" "$siga_tmp/root/.VolumeIcon.icns"
hdiutil create -srcfolder "$siga_tmp/root" -volname 'Install Sigá' -fs HFS+ -format UDRW "$siga_tmp/layout.dmg"
hdiutil attach -readwrite -nobrowse -plist "$siga_tmp/layout.dmg" > "$siga_tmp/mount.plist"
siga_mount=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:mount-point' "$siga_tmp/mount.plist" 2>/dev/null || true)
# Entity ordering varies by macOS; find the mounted volume rather than assuming a device slice.
if [[ -z "$siga_mount" ]]; then
    siga_mount=$(plutil -extract system-entities xml1 -o - "$siga_tmp/mount.plist" | sed -n '/<key>mount-point<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}')
fi
[[ -d "$siga_mount/Siga.app" && $(readlink "$siga_mount/Applications") == /Applications ]]
SetFile -a C "$siga_mount"
hdiutil detach "$siga_mount"
siga_mount=''
hdiutil convert "$siga_tmp/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$siga_tmp/Siga.dmg"
codesign --force --timestamp --sign "$SIGA_IDENTITY" --identifier io.mostlyserious.siga.disk-image "$siga_tmp/Siga.dmg"
xcrun notarytool submit "$siga_tmp/Siga.dmg" --keychain-profile "$SIGA_NOTARY" --wait
xcrun stapler staple "$siga_tmp/Siga.dmg"
xcrun stapler validate "$siga_tmp/Siga.dmg"
codesign --verify --strict "$siga_tmp/Siga.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$siga_tmp/Siga.dmg"
hdiutil verify "$siga_tmp/Siga.dmg"
mv "$siga_tmp/Siga.dmg" "$siga_output"
shasum -a 256 "$siga_output"
