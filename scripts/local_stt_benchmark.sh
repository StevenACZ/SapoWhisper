#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${BASE_URL:?Set BASE_URL, for example http://YOUR_SERVER_IP:8000}"
: "${MODEL_ID:?Set MODEL_ID, for example rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo}"
: "${AUDIO_PATH:?Set AUDIO_PATH, for example TestAssets/LocalAITranscription/longform/sample-1m.wav}"

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
curl_error="$(mktemp)"
curl_config=""

cleanup() {
  rm -f "$response_file" "$curl_error"
  if [[ -n "$curl_config" ]]; then
    rm -f "$curl_config"
  fi
}
trap cleanup EXIT

curl_args=(
  --silent
  --show-error
  --fail-with-body
  --output "$response_file"
  --write-out "%{time_total}"
  --request POST "$endpoint"
  --form "model=${MODEL_ID}"
  --form "response_format=json"
)

if [[ -n "${LANGUAGE:-}" && "${LANGUAGE}" != "auto" ]]; then
  curl_args+=(--form "language=${LANGUAGE}")
fi

curl_args+=(--form "file=@${AUDIO_PATH};type=audio/wav;filename=recording.wav")

if [[ -n "${API_KEY:-}" ]]; then
  curl_config="$(mktemp)"
  chmod 600 "$curl_config"
  printf 'header = "Authorization: Bearer %s"\n' "$API_KEY" >"$curl_config"
  curl_args=(--config "$curl_config" "${curl_args[@]}")
fi

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

python3 - "$script_dir" "$response_file" "$elapsed" "$MODEL_ID" "$AUDIO_PATH" "${TRANSCRIPT_PATH:-}" "${VOCABULARY_PATH:-}" "${CRITICAL_TERMS_PATH:-}" "${PRINT_TEXT:-0}" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from stt_benchmark_vocabulary import apply_recognition_corrections, load_critical_terms, load_vocabulary, score

response_path = pathlib.Path(sys.argv[2])
elapsed = float(sys.argv[3])
model = sys.argv[4]
audio = sys.argv[5]
transcript_path = pathlib.Path(sys.argv[6]) if sys.argv[6] else None
vocabulary_path = pathlib.Path(sys.argv[7]) if sys.argv[7] else None
critical_terms_path = pathlib.Path(sys.argv[8]) if sys.argv[8] else None
print_text = sys.argv[9] == "1"
body = response_path.read_text(errors="replace")

try:
    payload = json.loads(body)
    text = payload.get("text", "")
except Exception:
    text = body

keyterms, replacements = load_vocabulary(vocabulary_path)
corrected_text = apply_recognition_corrections(text, keyterms, replacements) if keyterms or replacements else text

result = {
    "audio": audio,
    "model": model,
    "elapsed_seconds": round(elapsed, 3),
    "text_characters": len(text.strip()),
    "text_preview": text.strip()[:180],
}

if transcript_path:
    reference = transcript_path.read_text(errors="replace")
    critical_terms = load_critical_terms(critical_terms_path, keyterms, reference)
    result["scores"] = {
        "raw": score(reference, text, critical_terms),
        "corrected": score(reference, corrected_text, critical_terms),
    }
    result["critical_terms"] = critical_terms
    result["correction_changed"] = corrected_text != text

if print_text:
    result["raw_text"] = text.strip()
    if corrected_text != text:
        result["corrected_text"] = corrected_text.strip()

print(json.dumps(result, ensure_ascii=False))
PY
