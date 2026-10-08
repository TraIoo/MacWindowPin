# Sourced by project scripts. All compatibility files stay under build/.
mkdir -p "$PROJECT_DIR/build/ModuleCacheFixed"
SWIFT_BUILD_FLAGS=(-swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$PROJECT_DIR/build/ModuleCacheFixed")
SWIFT_BIN="$(xcrun --find swiftc)"
SWIFT_INCLUDE="${SWIFT_BIN:h:h}/include/swift"
if [[ -f "$SWIFT_INCLUDE/module.modulemap" && -f "$SWIFT_INCLUDE/bridging.modulemap" ]] && \
   /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_INCLUDE/module.modulemap" && \
   /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_INCLUDE/bridging.modulemap"; then
  python3 - "$PROJECT_DIR/build" "$SWIFT_INCLUDE/module.modulemap" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve()
empty=root/'empty.modulemap'
empty.write_text('// Legacy duplicate hidden only inside compiler VFS. System files unchanged.\n')
(root/'toolchain-overlay.json').write_text(json.dumps({'version':0,'roots':[{
  'type':'file','name':sys.argv[2],'external-contents':str(empty)}]}))
PY
  SWIFT_BUILD_FLAGS+=(-vfsoverlay "$PROJECT_DIR/build/toolchain-overlay.json")
fi
