#!/usr/bin/env bash
# Builds a release binary and assembles "dist/Duck Disk.app" (ad-hoc signed).
# Usage: scripts/package-app.sh [--dmg]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
APP="$DIST/Duck Disk.app"
ICONSET="$DIST/AppIcon.iconset"

echo "→ Compiling (release)…"
swift build -c release --product DuckDisk
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DuckDisk" "$APP/Contents/MacOS/DuckDisk"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [ ! -f "$DIST/AppIcon.icns" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$DIST/AppIcon.icns" ]; then
  echo "→ Rendering icon"
  rm -rf "$ICONSET"
  swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$DIST/AppIcon.icns"
  rm -rf "$ICONSET"
fi
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

if [ "${1:-}" = "--dmg" ]; then
  echo "→ Creating disk image"
  STAGE="$DIST/dmg-stage"
  rm -rf "$STAGE" "$DIST/DuckDisk.dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Duck Disk" -srcfolder "$STAGE" -ov -format UDZO "$DIST/DuckDisk.dmg" >/dev/null
  rm -rf "$STAGE"
  echo "✓ $DIST/DuckDisk.dmg"
fi

echo "✓ $APP"
