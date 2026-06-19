#!/usr/bin/env bash
set -euo pipefail

: "${BASE_URL:?Set BASE_URL, for example http://YOUR_SERVER_IP:8000}"
: "${MODEL_ID:?Set MODEL_ID, for example rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo}"
: "${AUDIO_PATH:?Set AUDIO_PATH, for example TestAssets/LocalAITranscription/sample-1m.wav}"

if [[ ! -f "$AUDIO_PATH" ]]; then
  echo "Audio file not found: $AUDIO_PATH" >&2
  exit 2
fi

base="${BASE_URL%/}"
if [[ "$base" == */v1 ]]; then
  endpoint="$base/audio/transcriptions"
else
  endpoint="$base/v1/audio/transcriptions"
fi

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

curl_args=(
  --silent
  --show-error
  --fail-with-body
  --output "$response_file"
  --write-out "%{time_total}"
  --request POST "$endpoint"
  --form "file=@${AUDIO_PATH};type=audio/wav"
  --form "model=${MODEL_ID}"
  --form "response_format=json"
)

if [[ -n "${LANGUAGE:-}" && "${LANGUAGE}" != "auto" ]]; then
  curl_args+=(--form "language=${LANGUAGE}")
fi

if [[ -n "${API_KEY:-}" ]]; then
  curl_args+=(--header "Authorization: Bearer ${API_KEY}")
fi

curl_error="$(mktemp)"
trap 'rm -f "$response_file" "$curl_error"' EXIT

set +e
elapsed="$(curl "${curl_args[@]}" 2>"$curl_error")"
curl_status=$?
set -e

if [[ "$curl_status" -ne 0 ]]; then
  cat "$curl_error" >&2
  if [[ -s "$response_file" ]]; then
    echo >&2
    cat "$response_file" >&2
    echo >&2
  fi
  exit "$curl_status"
fi

python3 - "$response_file" "$elapsed" "$MODEL_ID" "$AUDIO_PATH" <<'PY'
import json
import pathlib
import sys

response_path = pathlib.Path(sys.argv[1])
elapsed = float(sys.argv[2])
model = sys.argv[3]
audio = sys.argv[4]
body = response_path.read_text(errors="replace")

try:
    payload = json.loads(body)
    text = payload.get("text", "")
except Exception:
    text = body

print(json.dumps({
    "audio": audio,
    "model": model,
    "elapsed_seconds": round(elapsed, 3),
    "text_characters": len(text.strip()),
    "text_preview": text.strip()[:180],
}, ensure_ascii=False))
PY
