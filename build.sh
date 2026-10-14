#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
DESTINATION="${1:-$SOURCE_DIR/dist}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/display-output-switch.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$DESTINATION" "$BUILD_DIR/module-cache"
for ARCH in arm64 x86_64; do
    xcrun clang -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min=13.0 -O2 -Wall -Wextra \
        -c "$SOURCE_DIR/Sources/DisplayBridge.c" -o "$BUILD_DIR/bridge-$ARCH.o"
    xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macosx13.0" -sdk "$SDK" \
        -module-cache-path "$BUILD_DIR/module-cache" \
        -import-objc-header "$SOURCE_DIR/Sources/DisplayBridge.h" \
        "$SOURCE_DIR/Sources/Localization.swift" "$SOURCE_DIR/Sources/DisplayModel.swift" "$SOURCE_DIR/Sources/LoginItems.swift" "$SOURCE_DIR/Sources/MenuApp.swift" "$SOURCE_DIR/Sources/main.swift" \
        "$BUILD_DIR/bridge-$ARCH.o" -framework AppKit -framework CoreGraphics -framework ColorSync -framework ServiceManagement \
        -o "$BUILD_DIR/DisplayOutputSwitch-$ARCH"
done
APP="$DESTINATION/MonitorOnOff.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun lipo -create "$BUILD_DIR/DisplayOutputSwitch-arm64" "$BUILD_DIR/DisplayOutputSwitch-x86_64" \
    -output "$APP/Contents/MacOS/MonitorOnOff"
cp "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$SOURCE_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [[ -f "$SOURCE_DIR/LICENSE" ]]; then cp "$SOURCE_DIR/LICENSE" "$APP/Contents/Resources/LICENSE"; fi
for LOCALIZATION in en zh-Hans zh-Hant ko ja; do
    mkdir -p "$APP/Contents/Resources/$LOCALIZATION.lproj"
    cp "$SOURCE_DIR/Resources/$LOCALIZATION.lproj/Localizable.strings" "$APP/Contents/Resources/$LOCALIZATION.lproj/Localizable.strings"
done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '构建完成：%s\n' "$APP"
