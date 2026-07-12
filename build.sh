#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Snack Record.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/funasr_transcribe.py" "$APP/Contents/Resources/funasr_transcribe.py"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Assets/SnackLogo.png" "$APP/Contents/Resources/SnackLogo.png"

clang -fobjc-arc "$ROOT/Sources/main.m" \
  -framework Cocoa \
  -framework AVFoundation \
  -framework ScreenCaptureKit \
  -framework CoreMedia \
  -framework UniformTypeIdentifiers \
  -framework UserNotifications \
  -o "$APP/Contents/MacOS/Snack Record"

codesign --force --deep \
  --options runtime \
  --timestamp=none \
  --entitlements "$ROOT/Entitlements.plist" \
  --sign "$SIGN_IDENTITY" \
  "$APP"

echo "$APP"
