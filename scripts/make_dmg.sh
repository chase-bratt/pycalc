#!/bin/zsh
# Builds "Python Calculator.app" and packages it into dist/PythonCalculator-<version>.dmg
# with an Applications shortcut for drag-to-install.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Python Calculator"
DIST="dist"
APP="$DIST/$APP_NAME.app"

./scripts/build_app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/PythonCalculator-$VERSION.dmg"

echo "› Staging disk image contents"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "› Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

shasum -a 256 "$DMG"
echo "✓ $DMG"
