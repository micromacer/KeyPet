#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
check_app="$project_root/build/RhythmChecks.app"
mkdir -p "$check_app/Contents/MacOS"
source_files=(Sources/Core/PetContracts.swift Sources/Input/PetKeyMapping.swift
  Sources/Input/PetInputStateMachine.swift Sources/Input/RhythmDetector.swift
  Sources/Input/SystemAudioMonitor.swift Sources/App/PreferencesStore.swift)
check_flags=()
if [[ " $* " == *" --app "* || " $* " == *" --performance "* ]]; then
  source_files=(Sources/**/*.swift)
  source_files=(${source_files:#Sources/App/main.swift})
  check_flags=(-D APP_CHECKS)
  mkdir -p "$check_app/Contents/Resources"
  cp -R Resources/*.lproj "$check_app/Contents/Resources/"
fi
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -parse-as-library \
  -target arm64-apple-macosx15.0 "${check_flags[@]}" "${source_files[@]}" \
  Verification/RhythmChecks.swift -o "$check_app/Contents/MacOS/RhythmChecks"
cat > "$check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.kenny.KeyPet.RhythmChecks</string>
  <key>CFBundleName</key><string>KeyPet Rhythm Checks</string>
  <key>CFBundleExecutable</key><string>RhythmChecks</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSAudioCaptureUsageDescription</key><string>Verify KeyPet system-audio rhythm detection locally. Audio is not saved or uploaded.</string>
</dict></plist>
PLIST
codesign --force --sign - --options runtime "$check_app" >/dev/null 2>&1
"$check_app/Contents/MacOS/RhythmChecks" "$@"
