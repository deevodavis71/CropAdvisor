#!/bin/zsh
# Builds CropAdvisor.app with swiftc directly (works with just the Command Line Tools).
# Usage: ./build_app.sh [debug]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${1:-release}
OPT=(-O -whole-module-optimization)
[[ "$CONFIG" == "debug" ]] && OPT=(-Onone -g)

BUILD=build
APP="$BUILD/CropAdvisor.app"
mkdir -p "$BUILD"

swiftc "${OPT[@]}" -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macosx15.0" \
    -module-name CropAdvisor \
    Sources/CropAdvisor/*.swift \
    -o "$BUILD/CropAdvisor"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/CropAdvisor" "$APP/Contents/MacOS/CropAdvisor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# CI sets these from the release tag and run number; local builds keep the plist's values.
[[ -n "${APP_VERSION:-}" ]] && plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP/Contents/Info.plist"
[[ -n "${APP_BUILD:-}" ]] && plutil -replace CFBundleVersion -string "$APP_BUILD" "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
