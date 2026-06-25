#!/bin/bash
# Secret scanning gate (gitleaks). Usage: secrets_scan.sh [staged|tree]
#   staged  scan staged changes only (pre-commit hook)
#   tree    scan the working tree (default; used by `make secrets-scan`)
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "secrets-scan: gitleaks is not installed. Install it with: brew install gitleaks" >&2
  exit 69
fi

mode="${1:-tree}"
case "$mode" in
  staged)
    exec gitleaks git --pre-commit --staged --redact --no-banner --config .gitleaks.toml
    ;;
  tree)
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sapowhisper-gitleaks.XXXXXX")"
    cleanup() {
      rm -rf "$tmp_dir"
    }
    trap cleanup EXIT

    git ls-files -z --cached --others --exclude-standard |
      while IFS= read -r -d '' file; do
        mkdir -p "$tmp_dir/$(dirname "$file")"
        cp -p "$file" "$tmp_dir/$file"
      done

    gitleaks dir "$tmp_dir" --redact --no-banner --config .gitleaks.toml
    ;;
  *)
    echo "secrets-scan: unknown mode '$mode' (use staged|tree)" >&2
    exit 64
    ;;
esac
