#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app_path="$PWD/build/DerivedData/Build/Products/Release/KeyPet.app"
codesign --verify --deep --strict "$app_path"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
mkdir -p build dist
staging_path=$(mktemp -d "$PWD/build/dmg-staging-media.XXXXXX")
ditto "$app_path" "$staging_path/KeyPet.app"
ln -s /Applications "$staging_path/Applications"
cp README.md LICENSE "$staging_path/"

dmg_path="$PWD/dist/KeyPet-$version-arm64.dmg"
if [ -e "$dmg_path" ]; then
    mkdir -p build/replaced-distributions
    backup_path=$(mktemp -d "$PWD/build/replaced-distributions/media.XXXXXX")
    cp "$dmg_path" "$backup_path/"
fi
hdiutil create -volname KeyPet -srcfolder "$staging_path" -format UDZO -ov "$dmg_path"
hdiutil verify "$dmg_path"
cd dist
shasum -a 256 ./*.dmg > SHA256SUMS
