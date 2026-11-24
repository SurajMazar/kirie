#!/bin/bash
# Forced-termination test: kill -9 the CLI while it is saving, many times, and check the project
# always reopens in a complete, valid state. Usage: Scripts/crash-recovery-test.sh [rounds]
set -uo pipefail
cd "$(dirname "$0")/.."
KIRIE="${KIRIE:-.build/debug/kirie}"
ROUNDS="${1:-25}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROJECT="$WORK/Crash.kirie"

"$KIRIE" new "$PROJECT" --name "Crash test" --compact >/dev/null || { echo "could not create project"; exit 1; }

failures=0
for round in $(seq 1 "$ROUNDS"); do
  # Hammer the project with saves in the background…
  (
    i=0
    while true; do
      i=$((i + 1))
      "$KIRIE" apply "$PROJECT" --command "{\"renameProject\":{\"name\":\"Round $round edit $i\"}}" --compact >/dev/null 2>&1
    done
  ) &
  writer=$!
  # …and kill everything at an arbitrary moment.
  sleep "0.$(( (RANDOM % 6) + 1 ))"
  pkill -9 -P "$writer" 2>/dev/null
  kill -9 "$writer" 2>/dev/null
  wait "$writer" 2>/dev/null

  if ! "$KIRIE" validate "$PROJECT" --compact >/dev/null 2>&1; then
    echo "round $round: project did not validate after forced termination"
    failures=$((failures + 1))
  fi
done

name="$("$KIRIE" info "$PROJECT" --compact | sed -n 's/.*"name":"\([^"]*\)".*"path".*/\1/p' | head -1)"
if [ "$failures" -eq 0 ]; then
  echo "ok: $ROUNDS forced terminations, project always reopened valid (last saved name: ${name:-unknown})"
else
  echo "FAILED: $failures of $ROUNDS rounds left an invalid project"
  exit 1
fi
