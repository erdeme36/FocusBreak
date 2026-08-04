#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="FocusBreak"
VOLUME_NAME="FocusBreak Installer"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/dist/$APP_NAME-Installer.dmg"
LEGACY_DMG_PATH="$ROOT_DIR/dist/$APP_NAME.dmg"
TEMP_DMG="$ROOT_DIR/dist/.${APP_NAME}.installer.temp.dmg"
ICON_SOURCE="$APP_DIR/Contents/Resources/AppIcon.icns"
ICON_REZ_SOURCE="$(mktemp "$ROOT_DIR/dist/.${APP_NAME}.icon.XXXXXX")"
ICON_TEMP_COPY="$(mktemp "$ROOT_DIR/dist/.${APP_NAME}.iconcopy.XXXXXX.icns")"
MOUNT_POINT=""

cleanup() {
  rm -f "$TEMP_DMG"
  rm -f "$ICON_REZ_SOURCE"
  rm -f "$ICON_TEMP_COPY"
}

trap cleanup EXIT

"$ROOT_DIR/scripts/package_app.sh"

rm -f "$DMG_PATH"
rm -f "$LEGACY_DMG_PATH"
rm -f "$TEMP_DMG"

hdiutil create \
  -size 90m \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -ov \
  -type UDIF \
  "$TEMP_DMG"

ATTACH_OUTPUT="$(hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen 2>&1)"
MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/"))}' | tail -n 1)"

if [ -z "$MOUNT_POINT" ]; then
  echo "$ATTACH_OUTPUT"
  echo "Failed to determine mounted volume path for $TEMP_DMG" >&2
  exit 1
fi

ditto "$APP_DIR" "$MOUNT_POINT/$APP_NAME.app"
ln -s /Applications "$MOUNT_POINT/Applications"
xattr -cr "$MOUNT_POINT/$APP_NAME.app" || true
chflags -R nohidden "$MOUNT_POINT/$APP_NAME.app" || true
chflags nohidden "$MOUNT_POINT/Applications" || true

sync

if [ -f "$ICON_SOURCE" ]; then
  cp "$ICON_SOURCE" "$MOUNT_POINT/.VolumeIcon.icns"
  chflags hidden "$MOUNT_POINT/.VolumeIcon.icns" || true
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT_POINT" || true
  fi
fi

if command -v osascript >/dev/null 2>&1; then
  osascript <<APPLESCRIPT || true
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 720, 420}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set text size of theViewOptions to 14
    set position of item "$APP_NAME.app" of container window to {170, 170}
    set position of item "Applications" of container window to {430, 170}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
fi

hdiutil detach "$MOUNT_POINT"

hdiutil convert "$TEMP_DMG" \
  -ov \
  -format UDZO \
  -o "$DMG_PATH"

if [ -f "$ICON_SOURCE" ] && command -v Rez >/dev/null 2>&1 && command -v DeRez >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  cp "$ICON_SOURCE" "$ICON_TEMP_COPY"
  sips -i "$ICON_TEMP_COPY" >/dev/null
  DeRez -only icns "$ICON_TEMP_COPY" > "$ICON_REZ_SOURCE"
  Rez -append "$ICON_REZ_SOURCE" -o "$DMG_PATH"
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$DMG_PATH" || true
  fi
fi

ditto "$DMG_PATH" "$LEGACY_DMG_PATH"
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$LEGACY_DMG_PATH" || true
fi

echo "Created $DMG_PATH"
echo "Created $LEGACY_DMG_PATH"
