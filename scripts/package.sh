#!/bin/bash
# Packages build/Release/Tovri.app for distribution:
#   dist/Tovri-<version>.zip  (Sparkle updates and Homebrew)
#   dist/Tovri-<version>.dmg  (manual download)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP="$ROOT/build/Release/Tovri.app"
DIST="$ROOT/dist"

[[ -d "$APP" ]] || { echo "error: build the app first (scripts/build.sh)" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
mkdir -p "$DIST"

ZIP="$DIST/Tovri-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the bundle's symlinks and extended attributes intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

DMG="$DIST/Tovri-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Tovri.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/packaging/dmg/Open Me First.txt" "$STAGE/"
rm -f "$DMG"
hdiutil create -quiet -volname "Tovri $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO -ov "$DMG"

(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" | tee SHA256SUMS)
