#!/bin/zsh
# Builds "Python Calculator.app" into ./dist (and optionally installs to /Applications with --install).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Python Calculator"
BUNDLE_ID="app.pycalc.PythonCalculator"
VERSION="1.0.0"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# The macOS 27 SDK's SwiftUI macros ship only with full Xcode; the 26 SDK builds with Command Line Tools.
if [[ -z "${SDKROOT:-}" ]]; then
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk; do
    [[ -d $candidate ]] && export SDKROOT=$candidate && break
  done
fi

echo "› Building release binary"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/PyCalc"

echo "› Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PyCalc"
cp Resources/kernel.py "$APP/Contents/Resources/kernel.py"

echo "› Rendering icon"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make_icon.swift "$ICONSET/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>PyCalc</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSRequiresAquaSystemAppearance</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc signature with the hardened runtime (blocks DYLD_* library injection).
# For distribution, sign with a Developer ID (--sign "Developer ID Application: …" --timestamp) and notarize.
echo "› Signing (ad hoc, hardened runtime)"
codesign --force --options runtime --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "› Installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  echo "✓ /Applications/$APP_NAME.app"
else
  echo "✓ $APP"
fi
