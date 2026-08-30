#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing value for --root" >&2
        exit 64
      fi
      REPOSITORY_ROOT="$(cd "$1" && pwd -P)"
      ;;
    --app)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing value for --app" >&2
        exit 64
      fi
      APP_PATH="$1"
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 64
      ;;
  esac
  shift
done

PROJECT_FILE="$REPOSITORY_ROOT/SapoWhisper.xcodeproj/project.pbxproj"
SOURCE_DIRECTORY="SapoWhisper"

GIT_ROOT="$(git -C "$REPOSITORY_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$GIT_ROOT" || "$(cd "$GIT_ROOT" && pwd -P)" != "$REPOSITORY_ROOT" ]]; then
  echo "Release root is not a Git repository root: $REPOSITORY_ROOT" >&2
  exit 66
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Project file not found: $PROJECT_FILE" >&2
  exit 66
fi

read_unique_setting() {
  local key="$1"
  local values
  local count

  values="$(sed -nE "s/^[[:space:]]*$key = ([^;]+);[[:space:]]*$/\1/p" "$PROJECT_FILE" | LC_ALL=C sort -u)"
  count="$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  if [[ "$count" != "1" ]]; then
    echo "Expected one unique $key in $PROJECT_FILE, found $count." >&2
    if [[ -n "$values" ]]; then
      printf '%s\n' "$values" >&2
    fi
    exit 65
  fi
  printf '%s' "$values"
}

PROJECT_VERSION="$(read_unique_setting MARKETING_VERSION)"
PROJECT_BUILD="$(read_unique_setting CURRENT_PROJECT_VERSION)"

if [[ ! "$PROJECT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid MARKETING_VERSION: $PROJECT_VERSION" >&2
  exit 65
fi
if [[ ! "$PROJECT_BUILD" =~ ^[0-9]+$ ]]; then
  echo "Invalid CURRENT_PROJECT_VERSION: $PROJECT_BUILD" >&2
  exit 65
fi

EXTRA_PATHS=()
while IFS= read -r -d '' extra_path; do
  EXTRA_PATHS+=("$extra_path")
done < <(
  git -C "$REPOSITORY_ROOT" ls-files --others --exclude-standard -z -- "$SOURCE_DIRECTORY"
  git -C "$REPOSITORY_ROOT" ls-files --others --ignored --exclude-standard -z -- "$SOURCE_DIRECTORY"
)

if [[ ${#EXTRA_PATHS[@]} -ne 0 ]]; then
  echo "Release source contains untracked or ignored files under $SOURCE_DIRECTORY/:" >&2
  printf '  %s\n' "${EXTRA_PATHS[@]}" >&2
  echo "Track or remove every file before packaging." >&2
  exit 65
fi

if [[ -n "$APP_PATH" ]]; then
  INFO_PLIST="$APP_PATH/Contents/Info.plist"
  if [[ ! -f "$INFO_PLIST" ]]; then
    echo "App Info.plist not found: $INFO_PLIST" >&2
    exit 66
  fi

  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
  APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
  if [[ "$APP_VERSION" != "$PROJECT_VERSION" || "$APP_BUILD" != "$PROJECT_BUILD" ]]; then
    echo "App identity does not match the current project." >&2
    echo "Project: $PROJECT_VERSION ($PROJECT_BUILD)" >&2
    echo "App: $APP_VERSION ($APP_BUILD)" >&2
    exit 65
  fi
fi

printf '%s\t%s\n' "$PROJECT_VERSION" "$PROJECT_BUILD"
