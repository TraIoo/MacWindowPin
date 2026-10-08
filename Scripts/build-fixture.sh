#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
source Scripts/toolchain.sh
mkdir -p build/WindowPinFixture.app/Contents/MacOS
xcrun swiftc "${SWIFT_BUILD_FLAGS[@]}" \
  -framework AppKit Tests/Fixture.swift -o build/WindowPinFixture.app/Contents/MacOS/Fixture
cat > build/WindowPinFixture.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundleIdentifier</key><string>local.jc.WindowPinFixture</string>
<key>CFBundleName</key><string>置顶验收窗口</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - build/WindowPinFixture.app
mkdir -p build/WindowPinFocusFixture.app/Contents/MacOS
cp build/WindowPinFixture.app/Contents/MacOS/Fixture build/WindowPinFocusFixture.app/Contents/MacOS/Fixture
cp build/WindowPinFixture.app/Contents/Info.plist build/WindowPinFocusFixture.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.jc.WindowPinFocusFixture' build/WindowPinFocusFixture.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Set :CFBundleName 置顶焦点验收' build/WindowPinFocusFixture.app/Contents/Info.plist
codesign --force --sign - build/WindowPinFocusFixture.app
