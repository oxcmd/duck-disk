#!/usr/bin/env bash
# Builds a release binary (Apple silicon) and assembles "dist/Duck Disk.app".
#
# Usage: scripts/package-app.sh [--dmg]
#
# Signing:
#   - With a "Developer ID Application" certificate in the keychain (or DEVELOPER_ID set to its name),
#     the app is signed with the hardened runtime and a secure timestamp.
#   - Without one, it is signed ad-hoc (runs on this Mac; other Macs show a Gatekeeper warning).
# Notarization (Developer ID only): set NOTARY_PROFILE to a profile saved with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-password>
# and the app (and the disk image with --dmg) is notarized and stapled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
APP="$DIST/Duck Disk.app"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
mkdir -p "$DIST"

echo "→ Compiling Duck Disk $VERSION (release, arm64)…"
swift build -c release --product DuckDisk
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DuckDisk" "$APP/Contents/MacOS/DuckDisk"
cp "$PLIST" "$APP/Contents/Info.plist"

ICON_SOURCES=("$ROOT/scripts/make-icon.swift" "$ROOT/Sources/DuckDisk/DuckArtwork.swift")
NEEDS_ICON=0
[ -f "$DIST/AppIcon.icns" ] || NEEDS_ICON=1
for src in "${ICON_SOURCES[@]}"; do
  [ "$src" -nt "$DIST/AppIcon.icns" ] && NEEDS_ICON=1
done
if [ "$NEEDS_ICON" = 1 ]; then
  echo "→ Rendering icon"
  ICONSET="$DIST/AppIcon.iconset"
  rm -rf "$ICONSET"
  swiftc -O -parse-as-library "${ICON_SOURCES[@]}" -o "$DIST/make-icon"
  "$DIST/make-icon" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$DIST/AppIcon.icns"
  rm -rf "$ICONSET" "$DIST/make-icon"
fi
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${DEVELOPER_ID:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi

if [ -n "$IDENTITY" ]; then
  echo "→ Signing with $IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "→ Signing ad-hoc (no Developer ID certificate found)"
  codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"

notarize() {
  local target="$1"
  if [ -z "$IDENTITY" ] || [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "→ Skipping notarization of $(basename "$target") (needs a Developer ID certificate and NOTARY_PROFILE)"
    return
  fi
  echo "→ Notarizing $(basename "$target")"
  local submission="$target"
  if [ -d "$target" ]; then
    submission="$DIST/notarize-upload.zip"
    ditto -c -k --keepParent "$target" "$submission"
  fi
  xcrun notarytool submit "$submission" --keychain-profile "$NOTARY_PROFILE" --wait
  [ "$submission" != "$target" ] && rm -f "$submission"
  xcrun stapler staple "$target"
}

notarize "$APP"

if [ "${1:-}" = "--dmg" ]; then
  DMG="$DIST/DuckDisk-$VERSION.dmg"
  echo "→ Creating $DMG"
  STAGE="$DIST/dmg-stage"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Duck Disk $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  fi
  notarize "$DMG"
  echo "✓ $DMG"
fi

echo "✓ $APP"
