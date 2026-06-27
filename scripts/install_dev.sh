#!/usr/bin/env bash
# Rebuild and reinstall the locally signed Release app to /Applications.
# Uses the same Apple Development identity from Signing.xcconfig so macOS
# keeps Microphone, Accessibility, and Input Monitoring grants across
# fast UI iterations. Do not use this over a notarized production install.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/build/audit-release/Build/Products/Release/SapoWhisper.app"
APP_DST="/Applications/SapoWhisper.app"

cd "$ROOT"
make release

if [[ ! -d "$APP_SRC" ]]; then
  echo "install-dev: expected app bundle at $APP_SRC" >&2
  exit 1
fi

osascript -e 'tell application "SapoWhisper" to quit' 2>/dev/null || true
sleep 1
if pgrep -x SapoWhisper >/dev/null 2>&1; then
  killall SapoWhisper 2>/dev/null || true
  sleep 1
fi

ditto "$APP_SRC" "$APP_DST"
open -a "$APP_DST"

CDHASH="$(codesign -dv "$APP_DST" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
echo "install-dev: installed CDHash=${CDHASH:-unknown} to $APP_DST"
