#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
zsh Scripts/build-fixture.sh
WINDOWPIN_TESTING=1 zsh Scripts/build.sh
RUN_DIR="$(mktemp -d /private/tmp/MacWindowPin-integration.XXXXXX)"
mkdir -p "$RUN_DIR/app2"
open -na "$PROJECT_DIR/build/WindowPinFocusFixture.app" --args "$RUN_DIR/app2"
open -na "$PROJECT_DIR/build/WindowPinFixture.app" --args "$RUN_DIR"
for attempt in {1..30}; do
  [[ -f "$RUN_DIR/fixture-status.json" ]] && break
  sleep 0.1
done
open -na "$PROJECT_DIR/build/置顶测试.app" --args --integration-test "$RUN_DIR"
print "Results: $RUN_DIR/integration-results.log"
print "The fixture contains only disposable test text. Close it after a blocked or failed run."
