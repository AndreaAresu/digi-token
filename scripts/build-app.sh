#!/bin/bash
# Builds DigiTokenBar.app straight from swiftc.
#
# We deliberately do not use SwiftPM: on a machine with only the Command Line
# Tools installed, `swift build` can fail because CLT ships
# BuildServerProtocol.framework outside the rpath its own swift-package binary
# searches, and SIP strips the DYLD_ override that would fix it. swiftc itself is
# fine, and this app has no external dependencies, so driving the compiler
# directly is both simpler and more portable.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DigiTokenBar"
VERSION="0.1.0"
BUNDLE_ID="dev.digitoken.digitokenbar"
CONFIG="${1:-release}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

SOURCES=$(find Sources/DigiTokenBar -name '*.swift' | sort)
[ -n "$SOURCES" ] || { echo "no sources found" >&2; exit 1; }

FLAGS=(-parse-as-library -swift-version 6 -target arm64-apple-macos14.0)
if [ "$CONFIG" = "release" ]; then
    FLAGS+=(-O -whole-module-optimization)
else
    FLAGS+=(-Onone -g)
fi

echo "==> compiling ($CONFIG)"
mkdir -p "$BUILD_DIR"
# shellcheck disable=SC2086
swiftc "${FLAGS[@]}" -o "$BUILD_DIR/$APP_NAME" $SOURCES

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Sources/DigiTokenBar/Resources/digidex.bin "$APP/Contents/Resources/"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/"

if [ "$CONFIG" = "release" ]; then
    strip -rSTx "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> signing (ad-hoc)"
codesign --force -s - "$APP" 2>/dev/null || echo "   (codesign skipped)"

echo "done: open $APP"
