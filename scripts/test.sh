#!/bin/bash
# Runs the headless checks in Tests/SelfTest.swift against Core, Digi and the
# real logs on this machine. The UI layer is deliberately excluded — it needs a
# running NSApplication, and nothing worth asserting lives there.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/selftest"
mkdir -p build

SOURCES=$(find Sources/DigiTokenBar/Core Sources/DigiTokenBar/Digi -name '*.swift' | sort)

swiftc -swift-version 6 -target arm64-apple-macos14.0 -Onone \
    -parse-as-library \
    -o "$OUT" \
    $SOURCES Tests/SelfTest.swift

exec "$OUT"
