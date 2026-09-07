#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP="$ROOT/dist/Jort.app"
readonly OUTPUT_DIR="$ROOT/dist"
readonly VOLUME_NAME="Install Jort"
readonly STAGING_DIR="$OUTPUT_DIR/dmg-staging"
readonly RW_DMG="$OUTPUT_DIR/Jort-rw.dmg"
readonly FINAL_DMG="$OUTPUT_DIR/Jort-0.3.0-macos.dmg"
readonly BACKGROUND_DIR="$STAGING_DIR/.background"
readonly MOUNT_POINT="/Volumes/$VOLUME_NAME"

test -d "$APP" || {
  printf 'Missing application bundle: %s\n' "$APP" >&2
  exit 1
}

rm -rf "$STAGING_DIR" "$RW_DMG" "$FINAL_DMG"
mkdir -p "$BACKGROUND_DIR"

cp -R "$APP" "$STAGING_DIR/Jort.app"
cp "$ROOT/dist/dmg-background.png" "$BACKGROUND_DIR/background.png"
sips --setProperty dpiWidth 72 --setProperty dpiHeight 72 \
  "$BACKGROUND_DIR/background.png" >/dev/null
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  "$RW_DMG"

hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG"
trap 'hdiutil detach "$MOUNT_POINT" -quiet || true' EXIT

osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Install Jort"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 1000, 620}

    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 112
    set background picture of theViewOptions to file ".background:background.png"

    set position of item "Jort.app" of container window to {220, 225}
    set position of item "Applications" of container window to {700, 225}

    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_POINT"
trap - EXIT

hdiutil convert "$RW_DMG" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$FINAL_DMG"

rm -rf "$STAGING_DIR" "$RW_DMG"
printf 'Created %s\n' "$FINAL_DMG"
