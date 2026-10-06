#!/bin/sh
# Renders docs/screenshot-light.png and docs/screenshot-dark.png from the real app views.
# It compiles the app's sources with scripts/screenshot.swift in place of the @main file,
# into an app with its own bundle ID, so the real app's settings stay untouched.
# With --vm it runs the capture in the test VM (testvm) instead of on this screen.
# Usage: scripts/screenshot.sh [--vm]
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"
NAME=$(sed -n 's/^name: *//p' project.yml)
BUNDLE_ID=$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: *//p' project.yml | head -1).screenshot
MACOS=$(sed -n 's/^ *macOS: *"\(.*\)"$/\1/p' project.yml | head -1)
APP="$ROOT/build/screenshot/$NAME Screenshot.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" docs
find "$NAME" -name '*.swift' ! -exec grep -q '^@main' {} \; -exec \
  swiftc -O -swift-version 6 -parse-as-library -D SCREENSHOT -target "$(uname -m)-apple-macos$MACOS" \
  -o "$APP/Contents/MacOS/Screenshot" scripts/screenshot.swift {} +

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Screenshot</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
if [ "${1:-}" = "--vm" ]; then
  testvm push "$APP" "screenshot/"
  testvm run "rm -rf ~/screenshot/out && mkdir -p ~/screenshot/out && open -W -n \"\$HOME/screenshot/$NAME Screenshot.app\" --args \"\$HOME/screenshot/out\" -AppleLocale en_US -AppleLanguages '(en)'"
  testvm pull "screenshot/out/." docs/
else
  open -n "$APP" --args "$ROOT/docs" -AppleLocale en_US -AppleLanguages '(en)'
  sleep 1
  while pgrep -f "$NAME Screenshot.app/Contents/MacOS" >/dev/null; do sleep 1; done
fi
ls -la docs/screenshot-*.png
