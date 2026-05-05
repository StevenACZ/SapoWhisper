#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/swift_format_changed.sh format [file.swift ...]
  scripts/swift_format_changed.sh lint [file.swift ...]

Without explicit files, checks Swift files changed from HEAD plus untracked Swift files.
USAGE
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 64
fi

mode="$1"
shift

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

config=".swift-format"

if [[ ! -f "$config" ]]; then
  echo "Missing $config" >&2
  exit 66
fi

if ! xcrun --find swift-format >/dev/null 2>&1; then
  echo "swift-format not found. Install/use Xcode's command line tools." >&2
  exit 69
fi

files=()

if [[ $# -gt 0 ]]; then
  for file in "$@"; do
    [[ "$file" == *.swift && -f "$file" ]] && files+=("$file")
  done
else
  while IFS= read -r file; do
    [[ -n "$file" && -f "$file" ]] && files+=("$file")
  done < <(
    {
      git diff --name-only --diff-filter=ACMR -- '*.swift'
      git diff --cached --name-only --diff-filter=ACMR -- '*.swift'
      git ls-files --others --exclude-standard -- '*.swift'
    } | sort -u
  )
fi

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "swift-format: no changed Swift files"
  exit 0
fi

case "$mode" in
  format)
    xcrun swift-format format --in-place --configuration "$config" "${files[@]}"
    ;;
  lint)
    xcrun swift-format lint --strict --configuration "$config" "${files[@]}"
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
