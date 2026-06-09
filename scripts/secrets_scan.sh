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
    exec gitleaks dir . --redact --no-banner --config .gitleaks.toml
    ;;
  *)
    echo "secrets-scan: unknown mode '$mode' (use staged|tree)" >&2
    exit 64
    ;;
esac
