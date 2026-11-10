#!/bin/bash
# Build build/Saga.app (ad-hoc signed; fine for local use. Distribution needs a Developer ID + notarization).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(<VERSION)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be major.minor.patch' >&2; exit 2; }
universal=0
if [[ "${1:-}" == "--universal" ]]; then universal=1; fi
if [[ $universal == 1 ]]; then
  swift build -c release --arch arm64 --arch x86_64 --product SagaApp
  swift build -c release --arch arm64 --arch x86_64 --product saga-mcp
  products=.build/out/Products/Release
else
  swift build -c release --product SagaApp
  swift build -c release --product saga-mcp
  products=.build/release
fi
APP=build/Saga.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$products/SagaApp" "$APP/Contents/MacOS/Saga"
cp "$products/saga-mcp" "$APP/Contents/MacOS/saga-mcp"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Saga</string>
  <key>CFBundleDisplayName</key><string>Saga</string>
  <key>CFBundleIdentifier</key><string>app.saga.mac</string>
  <key>CFBundleExecutable</key><string>Saga</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
  <key>CFBundleVersion</key><string>BUILD_PLACEHOLDER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSContactsUsageDescription</key><string>Saga uses your contacts only to show real names instead of phone numbers. Nothing leaves this Mac.</string>
</dict></plist>
P
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/MacOS/saga-mcp"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/Saga"
echo "built $APP  (open build/Saga.app)"
