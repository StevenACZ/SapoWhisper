#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SapoWhisper"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-build/notarized-release}"
ICON_PATH="${ICON_PATH:-SapoWhisper/Assets.xcassets/AppIcon.appiconset/icon_512x512.png}"
BACKGROUND_PATH="${BACKGROUND_PATH:-DMG/dmg_bg_final.png}"
OUTPUT_DMG="${OUTPUT_DMG:-}"
NOTARY_PROFILE="${SAPOWHISPER_NOTARY_PROFILE:-${NOTARY_PROFILE:-notarytool-dmg}}"
APP_NOTARY_TEMP=""
MOUNT_POINT=""

cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  if [[ -n "$APP_NOTARY_TEMP" && -d "$APP_NOTARY_TEMP" ]]; then
    rm -rf "$APP_NOTARY_TEMP"
  fi
}
trap cleanup EXIT

usage() {
  echo "Usage: $0 [--output <path>]"
  echo
  echo "Environment:"
  echo "  SAPOWHISPER_SIGN_IDENTITY   Developer ID Application identity. Defaults to the first local Developer ID Application identity."
  echo "  SAPOWHISPER_DEVELOPMENT_TEAM Development team. Defaults to the signing certificate OU."
  echo "  SAPOWHISPER_NOTARY_PROFILE  notarytool keychain profile. Defaults to notarytool-dmg."
  echo "  DERIVED_DATA                Xcode DerivedData path. Defaults to build/notarized-release."
  echo "  OUTPUT_DMG                  Output DMG path. Defaults to ~/Downloads/SapoWhisper-<version>.dmg."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing value for --output" >&2
        exit 64
      fi
      OUTPUT_DMG="$1"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

SOURCE_IDENTITY="$(scripts/verify_release_inputs.sh)"

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg is required. Install it with: brew install create-dmg" >&2
  exit 69
fi

SIGN_IDENTITY="${SAPOWHISPER_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  IDENTITIES=()
  while IFS= read -r identity; do
    IDENTITIES+=("$identity")
  done < <(security find-identity -p codesigning -v | awk -F '"' '/Developer ID Application/ { print $2 }')
  if [[ ${#IDENTITIES[@]} -ne 1 ]]; then
    echo "Expected exactly one Developer ID Application identity; set SAPOWHISPER_SIGN_IDENTITY explicitly." >&2
    exit 65
  fi
  SIGN_IDENTITY="${IDENTITIES[0]}"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "No Developer ID Application signing identity found." >&2
  echo "Install the certificate with its private key, or set SAPOWHISPER_SIGN_IDENTITY." >&2
  exit 65
fi

IDENTITY_TEAM_ID="$(security find-certificate -c "$SIGN_IDENTITY" -p \
  | openssl x509 -noout -subject -nameopt RFC2253 \
  | sed -n 's/.*OU=\([^,]*\).*/\1/p' \
  | head -n 1)"
if [[ -z "$IDENTITY_TEAM_ID" ]]; then
  echo "Could not detect a development team from the signing certificate." >&2
  exit 65
fi
TEAM_ID="${SAPOWHISPER_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-$IDENTITY_TEAM_ID}}"
if [[ "$TEAM_ID" != "$IDENTITY_TEAM_ID" ]]; then
  echo "Configured development team does not match the signing certificate." >&2
  exit 65
fi

echo "==> Validating notary profile: $NOTARY_PROFILE"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null

echo "==> Building $APP_NAME ($CONFIGURATION)"
SOURCE_ROOT="$(pwd)"
C_PATH_FLAGS="-fmacro-prefix-map=$SOURCE_ROOT=."
xcodebuild \
  -quiet \
  -project SapoWhisper.xcodeproj \
  -scheme SapoWhisper \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CFLAGS="\$(inherited) $C_PATH_FLAGS" \
  OTHER_CPLUSPLUSFLAGS="\$(inherited) $C_PATH_FLAGS" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  clean build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found: $BUILT_APP" >&2
  exit 66
fi

BUILT_IDENTITY="$(scripts/verify_release_inputs.sh --app "$BUILT_APP")"
if [[ "$BUILT_IDENTITY" != "$SOURCE_IDENTITY" ]]; then
  echo "Project release identity changed during the build." >&2
  echo "Before build: $SOURCE_IDENTITY" >&2
  echo "After build: $BUILT_IDENTITY" >&2
  exit 65
fi
IFS=$'\t' read -r VERSION BUILD <<<"$BUILT_IDENTITY"
if [[ -z "$OUTPUT_DMG" ]]; then
  OUTPUT_DMG="$HOME/Downloads/SapoWhisper-$VERSION.dmg"
fi

SPARKLE_FW="$BUILT_APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  # xcodebuild with manual signing does not deep-re-sign the executables
  # nested inside Sparkle's prebuilt xcframework; Apple notarization rejects
  # their upstream signatures (no Developer ID, no secure timestamp).
  # Re-sign inside-out per Sparkle's distribution guidance, preserving the
  # XPC services' own entitlements, then re-seal the framework and the app.
  echo "==> Re-signing Sparkle nested executables with $SIGN_IDENTITY"
  for NESTED in \
    "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_FW/Versions/B/Updater.app" \
    "$SPARKLE_FW/Versions/B/Autoupdate"; do
    codesign -f -o runtime --timestamp --preserve-metadata=entitlements \
      -s "$SIGN_IDENTITY" "$NESTED"
  done
  codesign -f -o runtime --timestamp -s "$SIGN_IDENTITY" "$SPARKLE_FW"
  codesign -f -o runtime --timestamp --preserve-metadata=entitlements \
    -s "$SIGN_IDENTITY" "$BUILT_APP"
fi

echo "==> Verifying app signature"
scripts/verify_release_app.sh "$BUILT_APP" "Developer ID Application"
SIGNING_DETAILS="$(codesign -dvv "$BUILT_APP" 2>&1)"
if ! grep -q "Authority=Developer ID Application" <<<"$SIGNING_DETAILS"; then
  echo "App is not signed with Developer ID Application." >&2
  echo "$SIGNING_DETAILS" >&2
  exit 65
fi
if ! grep -q "^Timestamp=" <<<"$SIGNING_DETAILS"; then
  echo "App signature is missing a secure timestamp." >&2
  echo "$SIGNING_DETAILS" >&2
  exit 65
fi
if ! grep -q "^Runtime Version=" <<<"$SIGNING_DETAILS"; then
  echo "App signature is missing Hardened Runtime." >&2
  echo "$SIGNING_DETAILS" >&2
  exit 65
fi
ENTITLEMENTS="$(codesign -d --entitlements :- "$BUILT_APP" 2>/dev/null || true)"
if grep -q "get-task-allow" <<<"$ENTITLEMENTS"; then
  echo "App signature contains get-task-allow, which is not valid for Developer ID distribution." >&2
  echo "$ENTITLEMENTS" >&2
  exit 65
fi

APP_NOTARY_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/sapowhisper-app-notary.XXXXXX")"
APP_NOTARY_ARCHIVE="$APP_NOTARY_TEMP/$APP_NAME.zip"
echo "==> Archiving app for notarization"
ditto -c -k --keepParent "$BUILT_APP" "$APP_NOTARY_ARCHIVE"

echo "==> Notarizing app"
xcrun notarytool submit "$APP_NOTARY_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling app"
xcrun stapler staple "$BUILT_APP"
xcrun stapler validate "$BUILT_APP"
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
rm -rf "$APP_NOTARY_TEMP"
APP_NOTARY_TEMP=""

echo "==> Creating $OUTPUT_DMG"
rm -f "$OUTPUT_DMG"
DMG_ARGS=(
  --volname "SapoWhisper"
  --volicon "$ICON_PATH"
  --window-pos 200 120
  --window-size 600 520
  --icon-size 100
  --icon "$APP_NAME.app" 150 310
  --hide-extension "$APP_NAME.app"
  --app-drop-link 450 310
  --no-internet-enable
)
if [[ -f "$BACKGROUND_PATH" ]]; then
  DMG_ARGS=(--background "$BACKGROUND_PATH" "${DMG_ARGS[@]}")
fi
create-dmg "${DMG_ARGS[@]}" "$OUTPUT_DMG" "$BUILT_APP"

echo "==> Signing DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUTPUT_DMG"
codesign --verify --verbose=2 "$OUTPUT_DMG"

echo "==> Verifying DMG"
hdiutil verify "$OUTPUT_DMG"

echo "==> Notarizing DMG"
xcrun notarytool submit "$OUTPUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling DMG"
xcrun stapler staple "$OUTPUT_DMG"
xcrun stapler validate "$OUTPUT_DMG"

echo "==> Gatekeeper DMG assessment"
spctl -a -t open --context context:primary-signature -vv "$OUTPUT_DMG"

MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/sapowhisper-dmg.XXXXXX")"
echo "==> Mounting DMG readonly"
hdiutil attach "$OUTPUT_DMG" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null

MOUNTED_APP="$MOUNT_POINT/$APP_NAME.app"
if [[ ! -d "$MOUNTED_APP" ]]; then
  echo "Mounted app not found: $MOUNTED_APP" >&2
  exit 66
fi
if [[ ! -e "$MOUNT_POINT/Applications" && ! -L "$MOUNT_POINT/Applications" ]]; then
  echo "Applications drop link is missing from the DMG." >&2
  exit 66
fi
MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNTED_APP/Contents/Info.plist")"
MOUNTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MOUNTED_APP/Contents/Info.plist")"
if [[ "$MOUNTED_VERSION" != "$VERSION" || "$MOUNTED_BUILD" != "$BUILD" ]]; then
  echo "Mounted app identity mismatch: expected $VERSION ($BUILD), got $MOUNTED_VERSION ($MOUNTED_BUILD)" >&2
  exit 66
fi
scripts/verify_release_inputs.sh --app "$MOUNTED_APP" >/dev/null

echo "==> Verifying mounted app"
xcrun stapler validate "$MOUNTED_APP"
scripts/verify_release_app.sh "$MOUNTED_APP" "Developer ID Application"
spctl -a -t execute -vv "$MOUNTED_APP"

echo "==> SHA-256"
shasum -a 256 "$OUTPUT_DMG"
