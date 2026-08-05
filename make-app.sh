#!/bin/zsh
# Build ModelUsage.app et installe dans ~/Applications
set -e
cd "$(dirname "$0")"

swift build -c release

APP=~/Applications/ModelUsage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/ModelUsage "$APP/Contents/MacOS/ModelUsage"
mkdir -p "$APP/Contents/Resources"
cp Fonts/NetwaNeo-*.ttf "$APP/Contents/Resources/" 2>/dev/null || true  # polices optionnelles (non redistribuées)
cp Assets/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ModelUsage</string>
    <key>CFBundleIdentifier</key><string>fr.blizor.modelusage</string>
    <key>CFBundleName</key><string>ModelUsage</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

# Identité STABLE (Apple Development) : la permission Accessibilité survit aux
# rebuilds. La signature ad-hoc (-) changeait à chaque build → TCC l'invalidait
# en silence (toggle ON mais AXIsProcessTrusted false).
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Installé : $APP"
open "$APP"
