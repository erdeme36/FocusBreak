#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="FocusBreak"
APP_VERSION="${FOCUSBREAK_VERSION:-1.0.6}"
BUILD_NUMBER="${FOCUSBREAK_BUILD:-6}"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$(mktemp -d "$ROOT_DIR/dist/.iconset.XXXXXX")"

cleanup() {
  rm -rf "$ICONSET_DIR"
}

trap cleanup EXIT

cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
swift build \
  --cache-path "$ROOT_DIR/.build/cache" \
  --config-path "$ROOT_DIR/.build/config" \
  --security-path "$ROOT_DIR/.build/security" \
  -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
if [ -d "$ROOT_DIR/Resources" ]; then
  cp -R "$ROOT_DIR/Resources/." "$RESOURCES_DIR/"
fi

if [ -f "$ICON_SOURCE" ] && command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  mkdir -p "$ICONSET_DIR/AppIcon.iconset"
  sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/AppIcon.iconset/icon_512x512.png" >/dev/null
  cp "$ICON_SOURCE" "$ICONSET_DIR/AppIcon.iconset/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET_DIR/AppIcon.iconset" -o "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>FocusBreak</string>
  <key>CFBundleIdentifier</key>
  <string>com.focusbreak.app</string>
  <key>CFBundleName</key>
  <string>FocusBreak</string>
  <key>CFBundleDisplayName</key>
  <string>FocusBreak</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 FocusBreak. All rights reserved.</string>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
  xattr -cr "$APP_DIR" || true
  find "$APP_DIR" -exec xattr -c {} \; 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
  xattr -d "com.apple.fileprovider.fpfs#P" "$APP_DIR" 2>/dev/null || true
  find "$APP_DIR" -name "._*" -delete
  codesign --force --deep --sign - "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

echo "Created $APP_DIR"
