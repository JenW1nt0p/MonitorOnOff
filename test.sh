#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/display-output-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD_DIR/module-cache"
xcrun clang -isysroot "$SDK" -mmacosx-version-min=13.0 -c "$SOURCE_DIR/Sources/DisplayBridge.c" -o "$BUILD_DIR/bridge.o"
xcrun swiftc -swift-version 5 -sdk "$SDK" -module-cache-path "$BUILD_DIR/module-cache" \
    -import-objc-header "$SOURCE_DIR/Sources/DisplayBridge.h" \
    "$SOURCE_DIR/Sources/Localization.swift" "$SOURCE_DIR/Sources/DisplayConnections.swift" "$SOURCE_DIR/Sources/DisplayModel.swift" "$SOURCE_DIR/Sources/LoginItems.swift" "$SOURCE_DIR/Tests/main.swift" "$BUILD_DIR/bridge.o" \
    -framework AppKit -framework CoreGraphics -framework ColorSync -framework ServiceManagement -framework IOKit -o "$BUILD_DIR/tests"
mkdir -p "$BUILD_DIR/Tests.app/Contents/MacOS" "$BUILD_DIR/Tests.app/Contents/Resources"
cp "$SOURCE_DIR/Info.plist" "$BUILD_DIR/Tests.app/Contents/Info.plist"
mv "$BUILD_DIR/tests" "$BUILD_DIR/Tests.app/Contents/MacOS/MonitorOnOff"
for LOCALIZATION in en zh-Hans zh-Hant ko ja; do
    cp -R "$SOURCE_DIR/Resources/$LOCALIZATION.lproj" "$BUILD_DIR/Tests.app/Contents/Resources/"
done
"$BUILD_DIR/Tests.app/Contents/MacOS/MonitorOnOff" "$BUILD_DIR/state"
