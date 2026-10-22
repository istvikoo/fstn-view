#!/bin/bash
# Builds "fstn view.app" and a release zip into build/
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/FstnView"
APP="build/fstn view.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FstnView"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: Resources/AppIcon.png (1024×1024) -> AppIcon.icns
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z $SIZE $SIZE Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  sips -z $((SIZE * 2)) $((SIZE * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
codesign --force --sign - "$APP" >/dev/null

ZIP="build/fstn-view-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "App: $(pwd)/$APP"
echo "Zip: $(pwd)/$ZIP"
