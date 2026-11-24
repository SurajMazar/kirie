#!/bin/bash
# Builds dist/Kirie.app from the Swift package. Works with only the Command Line Tools installed.
#
#   Scripts/build-app.sh                 release build, ad-hoc signed
#   CONFIG=debug Scripts/build-app.sh    faster debug build
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh   signed for notarisation
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="dist/Kirie.app"

swift build -c "$CONFIG" --product KirieApp
swift build -c "$CONFIG" --product kirie
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/KirieApp" "$APP/Contents/MacOS/Kirie"
# The CLI ships inside the app; it lives in Helpers because "kirie" and "Kirie" would collide
# in MacOS/ on a case-insensitive disk.
cp "$BIN/kirie" "$APP/Contents/Helpers/kirie"

# Icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
"$BIN/kirie" icon "$ICONSET/base.png" --compact >/dev/null
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Kirie</string>
  <key>CFBundleDisplayName</key><string>Kirie</string>
  <key>CFBundleIdentifier</key><string>app.kirie.Kirie</string>
  <key>CFBundleExecutable</key><string>Kirie</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSSpeechRecognitionUsageDescription</key><string>Kirie transcribes your clips on this Mac to create captions. Audio never leaves your computer.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Kirie Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSTypeIsPackage</key><true/>
      <key>LSItemContentTypes</key><array><string>app.kirie.project</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.kirie.project</string>
      <key>UTTypeDescription</key><string>Kirie Project</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.composite-content</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>kirie</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signing lets the app run locally. For distribution, sign with a Developer ID and notarise
# (see Docs/UserGuide/Building.md).
IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP/Contents/Helpers/kirie"
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/kirie"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($CONFIG, version $VERSION build $BUILD)"
