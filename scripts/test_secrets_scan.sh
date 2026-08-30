#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/sapowhisper-secrets-test.XXXXXX")"
cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT

mkdir -p "$fixture_root/scripts"
cp "$repo_root/scripts/secrets_scan.sh" "$fixture_root/scripts/secrets_scan.sh"
cp "$repo_root/.gitleaks.toml" "$fixture_root/.gitleaks.toml"
git -C "$fixture_root" init -q
git -C "$fixture_root" config user.email test@example.invalid
git -C "$fixture_root" config user.name Test
printf '%s\n' 'safe' >"$fixture_root/config.txt"
git -C "$fixture_root" add config.txt
git -C "$fixture_root" commit -qm base

{
  printf '%s%s\n' '-----BEGIN ' 'PRIVATE KEY-----'
  printf '%s\n' 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDfSynthetic'
  printf '%s%s\n' '-----END ' 'PRIVATE KEY-----'
} >"$fixture_root/config.txt"
git -C "$fixture_root" add config.txt
printf '%s\n' 'safe working copy' >"$fixture_root/config.txt"

if (cd "$fixture_root" && bash scripts/secrets_scan.sh tree >/dev/null 2>&1); then
  printf '%s\n' 'secrets-scan test: staged secret was hidden by working tree' >&2
  exit 1
fi

printf '%s\n' 'secrets-scan test: index and working snapshots are independent'
