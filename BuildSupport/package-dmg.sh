#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app_path="$PWD/build/DerivedData/Build/Products/Release/KeyPet.app"
codesign --verify --deep --strict "$app_path"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
mkdir -p build dist
working_path=$(mktemp -d "$PWD/build/dmg-packaging.XXXXXX")
staging_path="$working_path/contents"
mount_path="$working_path/mount"
mkdir -p "$staging_path" "$mount_path"
ditto "$app_path" "$staging_path/KeyPet.app"
ln -s /Applications "$staging_path/Applications"

# Finder stores the installation window layout on the writable image.
writable_image="$working_path/KeyPet-writable.dmg"
hdiutil create -volname KeyPet -srcfolder "$staging_path" -fs HFS+ -format UDRW "$writable_image"
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then
        hdiutil detach "$mount_path" >/dev/null || true
    fi
}
trap cleanup EXIT
hdiutil attach "$writable_image" -mountpoint "$mount_path" -nobrowse
mounted=true
osascript - "$mount_path" <<'APPLESCRIPT'
on run arguments
    set volumeFolder to POSIX file (item 1 of arguments) as alias
    tell application "Finder"
        set volumeFolder to folder (volumeFolder as text)
        open volumeFolder
        tell container window of volumeFolder
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set bounds to {200, 150, 840, 510}
        end tell
        set viewOptions to icon view options of container window of volumeFolder
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 14
        set background color of viewOptions to {65535, 65535, 65535}
        set position of item "KeyPet.app" of volumeFolder to {170, 150}
        set position of item "Applications" of volumeFolder to {470, 150}
        update volumeFolder without registering applications
        delay 2
        close container window of volumeFolder
    end tell
end run
APPLESCRIPT
sync
hdiutil detach "$mount_path"
mounted=false

prepared_dmg="$working_path/KeyPet.dmg"
hdiutil convert "$writable_image" -format UDZO -o "$prepared_dmg"
codesign --force --sign - "$prepared_dmg"
codesign --verify --strict "$prepared_dmg"
hdiutil verify "$prepared_dmg"

dmg_path="$PWD/dist/KeyPet-$version-arm64.dmg"
if [ -e "$dmg_path" ]; then
    mkdir -p build/replaced-distributions
    backup_path=$(mktemp -d "$PWD/build/replaced-distributions/media.XXXXXX")
    cp "$dmg_path" "$backup_path/"
    if [ -e "$PWD/dist/SHA256SUMS" ]; then
        cp "$PWD/dist/SHA256SUMS" "$backup_path/"
    fi
fi
mv "$prepared_dmg" "$dmg_path"
cd dist
shasum -a 256 ./*.dmg > SHA256SUMS
