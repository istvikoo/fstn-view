#!/bin/bash
# Builds "fstn view.app" and a release zip into build/
set -euo pipefail
cd "$(dirname "$0")"

# Universal: окремо для Apple Silicon і Intel, потім один файл з обома (macOS сама вибирає потрібну частину)
# (Нові версії Swift кладуть обидві збірки в одну папку — тож кожну одразу копіюємо окремо.)
mkdir -p build
BINS=()
for ARCH in arm64 x86_64; do
  swift build -c release --triple "$ARCH-apple-macosx14.0"
  OUT="build/FstnView-$ARCH"
  cp "$(swift build -c release --triple "$ARCH-apple-macosx14.0" --show-bin-path)/FstnView" "$OUT"
  [ "$(lipo -archs "$OUT")" = "$ARCH" ] || { echo "Збірка $ARCH дала $(lipo -archs "$OUT")" >&2; exit 1; }
  BINS+=("$OUT")
done
BIN="build/FstnView-universal"
lipo -create "${BINS[@]}" -output "$BIN"
rm -f "${BINS[@]}"
APP="build/fstn view.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FstnView"
rm -f "$BIN"
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

# DMG для встановлення перетягуванням: програма, ярлик «Програми» і фон зі стрілкою.
# Розкладку вікна (Resources/dmg/DS_Store) один раз налаштовано у Finder і збережено в проєкті,
# тож тут Finder не потрібен — це надійно і на GitHub Actions. (zip лишається для автооновлень.)
DMG="build/fstn-view-$VERSION.dmg"
STAGE="build/dmg-stage"
RW="build/dmg-rw.dmg"
MNT="build/dmg-mount"
rm -rf "$STAGE" "$RW" "$DMG" "$MNT"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/dmg/background.tiff "$STAGE/.background/background.tiff"
cp Resources/dmg/DS_Store "$STAGE/.DS_Store"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
hdiutil create -quiet -volname "fstn view" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
# Іконка самого диска (як у програми)
mkdir -p "$MNT"
hdiutil attach -quiet "$RW" -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MNT"
if command -v SetFile >/dev/null; then SetFile -a C "$MNT"; fi
hdiutil detach -quiet "$MNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$STAGE" "$RW" "$MNT"

echo "App: $(pwd)/$APP"
echo "Zip: $(pwd)/$ZIP"
echo "Dmg: $(pwd)/$DMG"
