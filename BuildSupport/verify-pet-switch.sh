#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
check_app="$project_root/build/PetSwitchChecks.app"
mkdir -p "$check_app/Contents/MacOS" "$check_app/Contents/Resources"
source_files=(Sources/**/*.swift)
source_files=(${source_files:#Sources/App/main.swift})
cp -R Resources/*.lproj "$check_app/Contents/Resources/"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -parse-as-library \
  -target arm64-apple-macosx15.0 "${source_files[@]}" \
  Verification/PetSwitchChecks.swift -o "$check_app/Contents/MacOS/PetSwitchChecks"
cat > "$check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.kenny.KeyPet.PetSwitchChecks</string>
  <key>CFBundleName</key><string>KeyPet Pet Switch Checks</string>
  <key>CFBundleExecutable</key><string>PetSwitchChecks</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
codesign --force --sign - --options runtime "$check_app" >/dev/null 2>&1
"$check_app/Contents/MacOS/PetSwitchChecks"
