#!/bin/bash
# Simulator build for CI with a watchdog: if the compiler hangs, print which file each stuck
# swift-frontend is compiling plus a stack sample, then fail instead of running into the job timeout.
set -uo pipefail
LOG="${RUNNER_TEMP:-/tmp}/xcodebuild.log"
LIMIT_SECONDS="${BUILD_WATCHDOG_SECONDS:-480}"

xcodebuild build -project ios/Peaker.xcodeproj -scheme Peaker -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "${RUNNER_TEMP:-/tmp}/dd" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_BATCH_MODE=NO \
  OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -warn-long-expression-type-checking=200 -Xfrontend -warn-long-function-bodies=300' \
  > "$LOG" 2>&1 &
build=$!

elapsed=0
while kill -0 "$build" 2>/dev/null && [ "$elapsed" -lt "$LIMIT_SECONDS" ]; do
  sleep 5
  elapsed=$((elapsed + 5))
done

if kill -0 "$build" 2>/dev/null; then
  echo "::error::Build still running after ${LIMIT_SECONDS}s. Stuck compiler processes:"
  for p in $(pgrep -f swift-frontend); do
    echo "===== pid $p, running for $(ps -o etime= -p "$p")"
    ps -o command= -p "$p" | tr ' ' '\n' | grep -A1 -- '-primary-file' | grep -v -- '-primary-file' | sed 's/^/primary file: /'
    sudo sample "$p" 2 -mayDie 2>/dev/null | grep -E "swift::|llvm::" | sed 's/^[ +!:|]*//' | awk '!seen[$0]++' | head -40
  done
  kill "$build" 2>/dev/null
  pkill -f swift-frontend 2>/dev/null
  wait "$build" 2>/dev/null
  xcbeautify --renderer github-actions < "$LOG" || tail -100 "$LOG"
  exit 1
fi

wait "$build"
status=$?
xcbeautify --renderer github-actions < "$LOG" || tail -200 "$LOG"
exit $status
