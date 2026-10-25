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
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
