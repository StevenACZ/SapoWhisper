#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

expected_hash() {
  case "$1" in
    SapoWhisper/Resources/Sounds/error.wav) printf '%s' '9011858c2d6b5c5cce10c939fdacb4d7c4bf39bb8a37431a7aaff22c4f2eb2b5' ;;
    SapoWhisper/Resources/Sounds/start.wav) printf '%s' '2fd2ac8380848d6fe574043d1ded205b387daee481e02ce924b72cc73ff99758' ;;
    SapoWhisper/Resources/Sounds/stop.wav) printf '%s' '0660b8c8b94188466456193d8e4438e8373f4172cc2e42a224260e06fd8544cc' ;;
    SapoWhisper/Resources/Sounds/success.wav) printf '%s' 'a8495ded66e9da4294493996b7009b7466580539f2e3ff0475c2bb6121b7fe23' ;;
    TestAssets/LocalAITranscription/longform/sample-1m.wav) printf '%s' 'c8ae8cf0e3ea1c45ad151eb4c2520b95a3c534d84d49f99035c4df984ad6173b' ;;
    TestAssets/LocalAITranscription/longform/sample-2m.wav) printf '%s' 'd5874330bad8a4484107ad5f4ee224bae797ae07c24de41318411cbe073e358f' ;;
    TestAssets/LocalAITranscription/longform/sample-3m.wav) printf '%s' '7445a2ee171bea0f487a2d763abcb086f463e95f9f908737c732f067c6ec46df' ;;
    TestAssets/LocalAITranscription/longform/sample-6m.wav) printf '%s' '71a9e12739f1778b18895df79d9b5158cfc6ea089ed9a73c50add97ad90a6308' ;;
    TestAssets/LocalAITranscription/technical/en/medium.wav) printf '%s' 'd8c62e9fb4b3817295b348eac3b7cc1568732ff9cffbeebacb42336d9fb3f101' ;;
    TestAssets/LocalAITranscription/technical/en/short.wav) printf '%s' '6efbc980eaf33ad9acff8136ce3a52af161cf4f565371dbac3590f8740dba979' ;;
    TestAssets/LocalAITranscription/technical/es/synthetic-public.wav) printf '%s' '13434dd77f37adf8325bb3754756f26fe46e5b9063baf2d291685133ee365f1a' ;;
    *) return 1 ;;
  esac
}

unexpected=0
audio_count=0
while IFS= read -r -d '' file; do
  [[ -f "$file" ]] || continue
  mime="$(file --brief --mime-type "$file")"
  case "$mime" in
    audio/*) ;;
    *)
      case "$file" in
        *.[Ww][Aa][Vv] | *.[Cc][Aa][Ff] | *.[Aa][Mm][Rr] | *.[Ww][Mm][Aa] | *.[Mm][Pp]3 | *.[Mm]4[Aa] | *.[Ff][Ll][Aa][Cc] | *.[Aa][Ii][Ff] | *.[Aa][Ii][Ff][Ff] | *.[Aa][Aa][Cc] | *.[Oo][Gg][Gg] | *.[Oo][Pp][Uu][Ss]) ;;
        *) continue ;;
      esac
      ;;
  esac

  audio_count=$((audio_count + 1))
  if ! expected="$(expected_hash "$file")"; then
    printf 'public-audio-check: unexpected tracked audio: %s\n' "$file" >&2
    unexpected=1
    continue
  fi

  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'public-audio-check: hash mismatch: %s\n' "$file" >&2
    unexpected=1
  fi

  if [[ "$mime" != "audio/wav" && "$mime" != "audio/x-wav" && "$mime" != "audio/vnd.wave" ]]; then
    printf 'public-audio-check: invalid WAV type: %s (%s)\n' "$file" "$mime" >&2
    unexpected=1
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

if [[ "$audio_count" -ne 11 ]]; then
  printf 'public-audio-check: expected 11 public audio files, found %s\n' "$audio_count" >&2
  unexpected=1
fi
test "$unexpected" -eq 0
printf 'public-audio-check: tracked audio hashes and formats passed\n'
