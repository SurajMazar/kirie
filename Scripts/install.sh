#!/bin/bash
# Builds Kirie and installs it into /Applications (or the folder given as the first argument).
# Usage: Scripts/install.sh [install folder]
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-/Applications}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

Scripts/build-app.sh

if pgrep -f "$DEST/Kirie.app/Contents/MacOS/Kirie" >/dev/null; then
  echo "Kirie is running from $DEST. Quit it first, then run this again." >&2
  exit 1
fi

rm -rf "$DEST/Kirie.app"
ditto dist/Kirie.app "$DEST/Kirie.app"
codesign --verify --strict "$DEST/Kirie.app"

# Two copies share one bundle identifier. Make the installed one own .kirie projects.
"$LSREGISTER" -u "$PWD/dist/Kirie.app" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST/Kirie.app"
echo "Installed $DEST/Kirie.app"
