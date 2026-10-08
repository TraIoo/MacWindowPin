#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
source Scripts/toolchain.sh
mkdir -p Verification
xcrun swiftc "${SWIFT_BUILD_FLAGS[@]}" \
  Sources/WindowIdentity.swift Tests/IdentityTests.swift -o build/IdentityTests
build/IdentityTests | tee Verification/identity-tests.log
WINDOWPIN_TESTING=1 zsh Scripts/build.sh
build/置顶测试.app/Contents/MacOS/WindowPin --self-test | tee Verification/self-tests.log
