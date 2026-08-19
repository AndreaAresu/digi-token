#!/bin/bash
# Headless smoke test for the popover.
#
# Separate from test.sh on purpose: that suite compiles Core and Digi only and
# must stay free of anything needing a running NSApplication. This one does need
# AppKit, so it lives in its own script and links the UI layer too.
#
# It exists because a nil-trap in the first refresh — before AppKit had called
# loadView — quit the app on the first click of the menu bar icon, and nothing
# in test.sh could have seen it.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/uismoke"
mkdir -p build

# AppDelegate carries @main, which would collide with the smoke test's own.
SOURCES=$(find Sources/DigiTokenBar -name '*.swift' ! -name 'AppDelegate.swift' | sort)

swiftc -swift-version 6 -target arm64-apple-macos14.0 -Onone \
    -parse-as-library \
    -o "$OUT" \
    $SOURCES Tests/UISmoke.swift

exec "$OUT"
