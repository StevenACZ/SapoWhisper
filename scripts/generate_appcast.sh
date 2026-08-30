#!/usr/bin/env bash
# Build the Sparkle update artifacts for a release: a ZIP of the (already
# notarized) app plus an appcast.xml whose enclosure is EdDSA-signed with the
# private key stored in the login Keychain (created once via generate_keys).
#
# Upload BOTH files as assets of the GitHub release. The app resolves the feed
# through the stable URL:
#   https://github.com/StevenACZ/SapoWhisper/releases/latest/download/appcast.xml
set -euo pipefail

cd "$(dirname "$0")/.."

APP_PATH="${APP_PATH:-build/notarized-release/Build/Products/Release/SapoWhisper.app}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Downloads}"
REPO_URL="https://github.com/StevenACZ/SapoWhisper"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  echo "Run 'make notarized-dmg' first, or set APP_PATH." >&2
  exit 65
fi

SPARKLE_BIN="$(ls -d build/*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_BIN" ]]; then
  echo "Sparkle tools not found under build/*/SourcePackages." >&2
  echo "Build the project once so SwiftPM downloads the Sparkle artifact." >&2
  exit 69
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"

ZIP_NAME="SapoWhisper-$VERSION.zip"
ZIP_PATH="$OUTPUT_DIR/$ZIP_NAME"
APPCAST_PATH="$OUTPUT_DIR/appcast.xml"

VALIDATION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sapowhisper-appcast.XXXXXX")"
cleanup() {
  rm -rf "$VALIDATION_DIR"
}
trap cleanup EXIT

echo "==> Verifying stapled app"
scripts/verify_release_app.sh "$APP_PATH" "Developer ID Application"
xcrun stapler validate "$APP_PATH"

echo "==> Zipping $APP_PATH -> $ZIP_PATH"
rm -f "$ZIP_PATH"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_PATH" "$ZIP_PATH"

ZIP_ENTRIES="$VALIDATION_DIR/zip-entries.txt"
unzip -Z1 "$ZIP_PATH" >"$ZIP_ENTRIES"
if LC_ALL=C grep -E -q '(^|/)\._' "$ZIP_ENTRIES"; then
  echo "Sparkle archive contains AppleDouble sidecar entries." >&2
  exit 65
fi

echo "==> Verifying archived app"
ditto -x -k "$ZIP_PATH" "$VALIDATION_DIR"
ARCHIVED_APP="$VALIDATION_DIR/$(basename "$APP_PATH")"
scripts/verify_release_app.sh "$ARCHIVED_APP" "Developer ID Application"
xcrun stapler validate "$ARCHIVED_APP"

echo "==> Signing update (EdDSA key from the login Keychain)"
SIGNATURE_ATTRS="$("$SPARKLE_BIN/sign_update" "$ZIP_PATH")"
# sign_update prints: sparkle:edSignature="..." length="..."

PUB_DATE="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"

echo "==> Writing $APPCAST_PATH"
cat >"$APPCAST_PATH" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SapoWhisper</title>
    <item>
      <title>$VERSION</title>
      <link>$REPO_URL/releases/tag/v$VERSION</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure
        url="$REPO_URL/releases/download/v$VERSION/$ZIP_NAME"
        type="application/octet-stream"
        $SIGNATURE_ATTRS />
    </item>
  </channel>
</rss>
APPCAST

echo "==> Done"
echo "    $ZIP_PATH"
echo "    $APPCAST_PATH"
echo "Upload both as assets of the v$VERSION GitHub release."
