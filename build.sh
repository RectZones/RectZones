#!/usr/bin/env bash
# Build RectZones and assemble the .app bundle.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/RectZones.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -O2 -fobjc-arc \
  "$DIR/src/main.m" \
  -o "$APP/Contents/MacOS/RectZones" \
  -framework Cocoa -framework ApplicationServices -framework Carbon

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>RectZones</string>
    <key>CFBundleDisplayName</key>       <string>RectZones</string>
    <key>CFBundleIdentifier</key>        <string>app.rectzones.RectZones</string>
    <key>CFBundleVersion</key>           <string>0.1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleExecutable</key>        <string>RectZones</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
</dict>
</plist>
PLIST

# App icon (generate if missing)
if [ ! -f "$DIR/assets/AppIcon.icns" ]; then
  mkdir -p "$DIR/assets"
  clang -fobjc-arc "$DIR/tools/makeicon.m" -o /tmp/rz-makeicon -framework Cocoa
  /tmp/rz-makeicon "$DIR/assets/AppIcon.iconset"
  iconutil -c icns "$DIR/assets/AppIcon.iconset" -o "$DIR/assets/AppIcon.icns"
fi
cp "$DIR/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: helps the TCC (Accessibility) grant attach to the binary
codesign --force --sign - "$APP"

echo "OK: $APP"
