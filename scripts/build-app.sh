#!/usr/bin/env bash
# Builds "build/Fast Share.app" from the Swift package; no Xcode project needed.
# Usage: scripts/build-app.sh [--install]   (--install copies the app to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

app_name="Fast Share"
build_dir="build"
app="$build_dir/$app_name.app"
iconset="$build_dir/AppIcon.iconset"
icns="$build_dir/AppIcon.icns"

swift build -c release --product FastShare
bin_dir="$(swift build -c release --show-bin-path)"

if [[ ! -f "$icns" || scripts/make-icon.swift -nt "$icns" ]]; then
  rm -rf "$iconset"
  swift scripts/make-icon.swift "$iconset"
  iconutil --convert icns --output "$icns" "$iconset"
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/FastShare" "$app/Contents/MacOS/FastShare"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$icns" "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app" # ad-hoc signature, enough to run on this Mac
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e "if application \"$app_name\" is running then tell application \"$app_name\" to quit"
  rm -rf "/Applications/$app_name.app"
  ditto "$app" "/Applications/$app_name.app"
  echo "Installed /Applications/$app_name.app"
fi
