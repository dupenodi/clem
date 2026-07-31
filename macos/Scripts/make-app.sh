#!/bin/zsh
# Build Clem.app from the SPM executable.
set -e
cd "$(dirname "$0")/.."

CONF="${1:-release}"
swift build -c "$CONF"

APP="build/Clem.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONF/Clem" "$APP/Contents/MacOS/Clem"
cp Resources/Clem.icns "$APP/Contents/Resources/Clem.icns"
[ -f Resources/home-bg-default.png ] && cp Resources/home-bg-default.png "$APP/Contents/Resources/home-bg-default.png"
[ -f Resources/clem.png ] && cp Resources/clem.png "$APP/Contents/Resources/clem.png"
[ -f Resources/clem-launch.jpg ] && cp Resources/clem-launch.jpg "$APP/Contents/Resources/clem-launch.jpg"
[ -f Resources/clem2.png ] && cp Resources/clem2.png "$APP/Contents/Resources/clem2.png"
[ -f Resources/clem-nobg.png ] && cp Resources/clem-nobg.png "$APP/Contents/Resources/clem-nobg.png"
if [ -d Resources/Fonts ]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
fi
if [ -d Resources/Characters ]; then
  mkdir -p "$APP/Contents/Resources/Characters"
  cp Resources/Characters/* "$APP/Contents/Resources/Characters/" 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Clem</string>
  <key>CFBundleIdentifier</key><string>app.clem.desktop</string>
  <key>CFBundleName</key><string>Clem</string>
  <key>CFBundleDisplayName</key><string>Clem</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>Clem</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Clem reads the active browser tab URL to give memories context.</string>
  <key>NSCameraUsageDescription</key>
  <string>With Eyes-on-screen enabled, Clem briefly checks the webcam when you go idle to tell whether you're still looking at the screen. Frames are analysed on-device and never stored or sent anywhere.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Sign with a stable identity so TCC permissions (Screen Recording /
# Accessibility) survive rebuilds. Falls back to ad-hoc if none found.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ {print $2; exit}')
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "signed as: ${IDENTITY:-ad-hoc}"

echo "✓ built $APP"

# Install to /Applications (real app: Spotlight, Launchpad, login items).
if [ "${2:-install}" = "install" ]; then
  rm -rf "/Applications/Clem.app"
  cp -R "$APP" "/Applications/Clem.app"
  echo "✓ installed /Applications/Clem.app"
fi
