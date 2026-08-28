#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?usage: verify_release_app.sh <app> [expected-authority]}"
EXPECTED_AUTHORITY="${2:-}"
EXPECTED_TEAM_ID="NXT93S55FY"
BINARY="$APP_PATH/Contents/MacOS/SapoWhisper"

if [[ ! -d "$APP_PATH" || ! -f "$BINARY" ]]; then
  echo "release-app-check: app bundle is incomplete" >&2
  exit 66
fi

codesign --verify --deep --strict "$APP_PATH"
SIGNING_DETAILS="$(codesign -dvvv "$APP_PATH" 2>&1)"
TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNING_DETAILS" | head -1)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
ARCHITECTURES="$(lipo -archs "$BINARY")"
DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP_PATH" 2>&1)"

if [[ "$BUNDLE_ID" != "oli.SapoWhisper" ]]; then
  echo "release-app-check: unexpected bundle identifier" >&2
  exit 65
fi
if [[ "$ARCHITECTURES" != "arm64" ]]; then
  echo "release-app-check: executable must contain only arm64" >&2
  exit 65
fi
if [[ -z "$TEAM_ID" ]]; then
  echo "release-app-check: missing TeamIdentifier" >&2
  exit 65
fi
if [[ "$TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
  echo "release-app-check: TeamIdentifier mismatch" >&2
  exit 65
fi
if [[ -n "$EXPECTED_AUTHORITY" ]] && ! grep -Fq "Authority=$EXPECTED_AUTHORITY" <<<"$SIGNING_DETAILS"; then
  echo "release-app-check: signing authority mismatch" >&2
  exit 65
fi
if ! grep -Fq 'identifier "oli.SapoWhisper"' <<<"$DESIGNATED_REQUIREMENT" ||
  ! grep -Fq 'anchor apple generic' <<<"$DESIGNATED_REQUIREMENT"; then
  echo "release-app-check: designated requirement is not anchored to the app" >&2
  exit 65
fi
if [[ "$EXPECTED_AUTHORITY" == "Developer ID Application" ]] &&
  ! grep -Fq "certificate leaf[subject.OU] = $EXPECTED_TEAM_ID" <<<"$DESIGNATED_REQUIREMENT"; then
  echo "release-app-check: designated requirement has the wrong signing team" >&2
  exit 65
fi
scripts/verify_no_private_paths.sh "$APP_PATH"
FORBIDDEN_PATH="$(find "$APP_PATH" \( -name '.env' -o -name '*.ips' -o -name '*.sqlite' -o -name '*.db' -o -name '.agents' -o -name '.claude' -o -name 'TestAssets' \) -print -quit)"
if [[ -n "$FORBIDDEN_PATH" ]]; then
  echo "release-app-check: private or development artifact found in bundle" >&2
  exit 65
fi

printf 'release-app-check: bundle, team, requirement, architecture, paths, and contents passed\n'
