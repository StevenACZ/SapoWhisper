#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/swift_format_changed.sh format [file.swift ...]
  scripts/swift_format_changed.sh lint [file.swift ...]

Without explicit files, checks Swift files changed from HEAD, untracked Swift
files, and everything the current branch changed since LINT_BASE_REF (main).
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

base_ref="${LINT_BASE_REF:-main}"

# A fully committed branch has an empty working-tree diff, which would make the
# whole branch invisible to the gate.
branch_swift_files() {
  local base head
  base="$(git merge-base "$base_ref" HEAD 2>/dev/null || true)"
  head="$(git rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$base" && -n "$head" && "$base" != "$head" ]] || return 0
  git diff --name-only --diff-filter=ACMR "$base..$head" -- '*.swift'
}

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
      branch_swift_files
    } | sort -u \
      | { grep -v '^LocalPackages/MLXWhisper/Sources/MLXWhisper/' || true; }
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
