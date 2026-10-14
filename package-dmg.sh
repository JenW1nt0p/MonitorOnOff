#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${1:-$PROJECT_DIR/dist/MonitorOnOff.app}"
DESTINATION="${2:-$PROJECT_DIR/dist}"
if [[ ! -f "$APP_PATH/Contents/Info.plist" ]]; then
    printf 'App not found. Run ./build.sh first or supply an app path.\n' >&2
    exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
mkdir -p "$DESTINATION"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/monitor-on-off-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
codesign --verify --deep --strict "$APP_PATH"
ditto "$APP_PATH" "$STAGING_DIR/MonitorOnOff.app"
ln -s /Applications "$STAGING_DIR/Applications"
if [[ -f "$PROJECT_DIR/LICENSE" ]]; then
    cp "$PROJECT_DIR/LICENSE" "$STAGING_DIR/LICENSE"
    cp "$PROJECT_DIR/LICENSE" "$STAGING_DIR/MonitorOnOff.app/Contents/Resources/LICENSE"
    codesign --force --sign - "$STAGING_DIR/MonitorOnOff.app"
    codesign --verify --deep --strict "$STAGING_DIR/MonitorOnOff.app"
fi
cat > "$STAGING_DIR/Install.txt" <<'NOTES'
MonitorOnOff

Copy MonitorOnOff.app to Applications (or ~/Applications), eject this image,
then launch the installed copy. Do not enable launch at login from this image.
Launch at login is enabled on first launch and can be disabled in the app menu.

This build is ad hoc signed and is not Developer ID signed or notarized.
Review the source before running downloaded software.
Source: https://github.com/JenW1nt0p/MonitorOnOff

将 MonitorOnOff.app 复制到“应用程序”或 ~/Applications，推出此磁盘映像，
再打开已安装的应用。不要从磁盘映像启用登录自启动。
首次启动默认开启登录自启动，可在应用菜单中关闭。
此版本使用临时签名，未使用 Developer ID 签名或 Apple 公证。
NOTES
DMG_PATH="$DESTINATION/MonitorOnOff-$VERSION-universal.dmg"
hdiutil create -volname "MonitorOnOff $VERSION" -srcfolder "$STAGING_DIR" -fs HFS+ -format UDZO -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"
printf 'DMG ready: %s\n' "$DMG_PATH"
