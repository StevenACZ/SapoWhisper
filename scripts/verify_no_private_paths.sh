#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:?usage: verify_no_private_paths.sh <file-or-directory>}"
if LC_ALL=C grep -a -E -r -q '(/Users/|/var/folders/)' "$TARGET"; then
  echo "private-path-check: artifact contains a private build path" >&2
  exit 65
fi

printf 'private-path-check: passed\n'
