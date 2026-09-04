#!/usr/bin/env bash
# Rebuild and reinstall the locally signed Release app to /Applications.
# Uses the same Apple Development identity from Signing.xcconfig so macOS
# keeps Microphone, Accessibility, and Input Monitoring grants across
# fast UI iterations. Do not use this over a notarized production install.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/build/audit-release/Build/Products/Release/SapoWhisper.app"
APP_DST="/Applications/SapoWhisper.app"
INSTALL_TMP="$(mktemp -d "${TMPDIR%/}/sapowhisper-install.XXXXXX")"
APP_BACKUP="$INSTALL_TMP/SapoWhisper.previous.app"
INSTALL_STARTED=0

cleanup() {
  local status=$?
  if [[ $status -ne 0 && $INSTALL_STARTED -eq 1 ]]; then
    if [[ -e "$APP_DST" ]]; then
      mv "$APP_DST" "$INSTALL_TMP/SapoWhisper.failed.app"
    fi
    if [[ -d "$APP_BACKUP" ]]; then
      mv "$APP_BACKUP" "$APP_DST"
    fi
  fi
  rm -rf "$INSTALL_TMP"
  exit "$status"
}
trap cleanup EXIT

cd "$ROOT"
make release

if [[ ! -d "$APP_SRC" ]]; then
  echo "install-dev: expected app bundle at $APP_SRC" >&2
  exit 1
fi

SIGNING_DETAILS="$(codesign -dvvv "$APP_SRC" 2>&1 || true)"
if ! grep -q "Authority=Apple Development" <<<"$SIGNING_DETAILS"; then
  echo "install-dev: Release app is not signed with Apple Development." >&2
  echo "install-dev: copy Signing.xcconfig.example to Signing.xcconfig and set DEVELOPMENT_TEAM." >&2
  exit 65
fi
if ! grep -q "^TeamIdentifier=" <<<"$SIGNING_DETAILS"; then
  echo "install-dev: Release app has no TeamIdentifier; refusing to replace a TCC-granted install." >&2
  exit 65
fi

osascript -e 'tell application "SapoWhisper" to quit' 2>/dev/null || true
sleep 1
if pgrep -x SapoWhisper >/dev/null 2>&1; then
  killall SapoWhisper 2>/dev/null || true
  sleep 1
fi

if [[ -d "$APP_DST" ]]; then
  mv "$APP_DST" "$APP_BACKUP"
fi
INSTALL_STARTED=1
ditto "$APP_SRC" "$APP_DST"
codesign --verify --deep --strict "$APP_DST"
open "$APP_DST"

CDHASH="$(codesign -dvvv "$APP_DST" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
echo "install-dev: installed CDHash=${CDHASH:-unknown} to $APP_DST"
