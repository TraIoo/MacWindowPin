#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
source Scripts/toolchain.sh
if [[ "${WINDOWPIN_TESTING:-0}" == 1 ]]; then
  APP_PATH="$PROJECT_DIR/build/置顶测试.app"
  BUILD_PATH="$PROJECT_DIR/build/testing"
  SWIFT_BUILD_FLAGS+=(-D WINDOWPIN_TESTING)
else
  # Build a versioned app without overwriting an older version.
  APP_PATH="$PROJECT_DIR/dist/置顶-0.1.1.app"
  BUILD_PATH="$PROJECT_DIR/build/release-0.1.1"
fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$BUILD_PATH"
xcrun swiftc "${SWIFT_BUILD_FLAGS[@]}" -O -g -whole-module-optimization \
  -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit \
  -framework AVFoundation -framework Carbon Sources/*.swift \
  -o "$BUILD_PATH/WindowPin"
cp "$BUILD_PATH/WindowPin" "$APP_PATH/Contents/MacOS/WindowPin"
xcrun strip -S "$APP_PATH/Contents/MacOS/WindowPin"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
if [[ "${WINDOWPIN_TESTING:-0}" == 1 ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.jc.MacWindowPin.Tests' "$APP_PATH/Contents/Info.plist"
fi
codesign --force --sign "${WINDOWPIN_SIGN_IDENTITY:--}" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
print "Built: $APP_PATH"
