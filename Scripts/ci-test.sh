#!/bin/bash
# Runs each test target on its own with a watchdog. If a target hangs, prints where the test process
# is stuck and fails, instead of running until the job times out.
# Usage: Scripts/ci-test.sh [seconds per target, default 420]
set -uo pipefail
cd "$(dirname "$0")/.."
LIMIT="${1:-420}"
TARGETS=(ProjectDomainTests PersistenceTests MediaServicesTests ComicStudioTests RenderEngineTests KirieServicesTests)
status=0

Scripts/test.sh --build-only 2>&1 | tail -3 || exit 1

for target in "${TARGETS[@]}"; do
  echo "::group::$target"
  start=$(date +%s)
  # A pseudo-terminal keeps the test output unbuffered, so progress is visible as it happens.
  script -q /dev/null Scripts/test.sh --skip-build --filter "$target" &
  runner=$!
  while kill -0 "$runner" 2>/dev/null; do
    sleep 5
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$LIMIT" ]; then
      echo "::error::$target did not finish within ${LIMIT}s"
      for pid in $(pgrep -f "swiftpm-testing-helper|KiriePackageTests" || true); do
        echo "--- sample of process $pid"
        sample "$pid" 2 -mayDie 2>/dev/null | grep -E "Kirie|ProjectDomain|Persistence|MediaServices|RenderEngine|ComicStudio|AVAsset|VTCompression|CIContext|Task.sleep|semaphore" | head -60
      done
      pkill -9 -f "swiftpm-testing-helper|KiriePackageTests|swift-test" 2>/dev/null
      kill -9 "$runner" 2>/dev/null
      status=1
      break
    fi
  done
  if [ "$status" -eq 0 ]; then
    wait "$runner" || status=1
  fi
  echo "::endgroup::"
  echo "$target finished in $(( $(date +%s) - start ))s (status $status)"
  [ "$status" -ne 0 ] && break
done
exit "$status"
