#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/measure_release_bundle.sh [path/to/SapoWhisper.app]

Measures the app bundle, executable, resource folders, embedded bundles, and
Mach-O architectures for release-size audits.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 64
fi

candidate_paths=(
  "${1:-}"
  "build/Build/Products/Release/SapoWhisper.app"
  "build/audit-after-release/Build/Products/Release/SapoWhisper.app"
  "build/audit-baseline-release/Build/Products/Release/SapoWhisper.app"
)

app_path=""
for candidate in "${candidate_paths[@]}"; do
  [[ -z "$candidate" ]] && continue
  if [[ -d "$candidate" ]]; then
    app_path="$candidate"
    break
  fi
done

if [[ -z "$app_path" ]]; then
  echo "No SapoWhisper.app found. Pass an app bundle path explicitly." >&2
  exit 66
fi

binary_path="$app_path/Contents/MacOS/SapoWhisper"
resources_path="$app_path/Contents/Resources"
frameworks_path="$app_path/Contents/Frameworks"

echo "App: $app_path"
echo

echo "Bundle sizes"
du -sh "$app_path"
[[ -f "$binary_path" ]] && du -sh "$binary_path"
[[ -d "$resources_path" ]] && du -sh "$resources_path"
[[ -d "$frameworks_path" ]] && du -sh "$frameworks_path"
echo

if [[ -f "$binary_path" ]]; then
  echo "Executable architectures"
  lipo -archs "$binary_path"
  echo
fi

if [[ -d "$resources_path" ]]; then
  echo "Embedded resource bundles"
  find "$resources_path" -maxdepth 4 -type d \( -name "*.bundle" -o -name "*.lproj" \) -print | sort | while read -r item; do
    du -sh "$item"
  done
  echo

  echo "Top resources"
  find "$resources_path" -maxdepth 4 -type f -print0 \
    | xargs -0 du -k \
    | sort -nr \
    | head -20 \
    | awk '{ size_kb=$1; $1=""; sub(/^ /, ""); printf "%8.1f MB  %s\n", size_kb / 1024, $0 }'
  echo
fi

if [[ -d "$frameworks_path" ]]; then
  echo "Embedded framework architectures"
  find "$frameworks_path" -maxdepth 3 -type f -perm +111 -print | sort | while read -r item; do
    printf "%s: " "$item"
    lipo -archs "$item" 2>/dev/null || echo "not Mach-O"
  done
fi
