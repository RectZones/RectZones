#!/usr/bin/env bash
# Build RectZones and assemble the .app bundle.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/build/RectZones.app"

# Version has exactly one source of truth: the git tag (v1.0.0 -> 1.0.0).
#
# RZ_VERSION overrides it, and that override is not a convenience — a build from
# a source tarball has no git metadata to read, and a tarball is precisely what a
# Homebrew formula consumes. Without it the formula could not stamp the version it
# was asked to build, and its binary would differ from one built at the tag.
#
# Ad-hoc signing folds Info.plist into the code directory, so the version string is
# part of the binary hash: same source + same version => byte-identical binary, and
# a version bump costs users a fresh Accessibility grant. Keep this deterministic.
if [ -n "${RZ_VERSION:-}" ]; then
  VERSION="${RZ_VERSION#v}"
elif VERSION="$(git -C "$DIR" describe --tags --abbrev=0 2>/dev/null)"; then
  VERSION="${VERSION#v}"
else
  # No tag reachable (untagged checkout, or a CI clone fetched without tags).
  # Stamp an obviously-unreleased version rather than guessing at a real one.
  VERSION="0.0.0"
  echo "warning: no git tag found and RZ_VERSION unset; stamping $VERSION" >&2
fi

# CFBundleVersion accepts one to three period-separated integers and nothing else.
# A malformed value yields a subtly broken bundle, so reject it here instead.
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$'; then
  echo "error: version '$VERSION' must be one to three dot-separated integers" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -O2 -fobjc-arc \
  "$DIR/src/main.m" \
  -o "$APP/Contents/MacOS/RectZones" \
  -framework Cocoa -framework ApplicationServices -framework Carbon

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>RectZones</string>
    <key>CFBundleDisplayName</key>       <string>RectZones</string>
    <key>CFBundleIdentifier</key>        <string>app.rectzones.RectZones</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
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
