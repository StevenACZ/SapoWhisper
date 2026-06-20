#!/usr/bin/env bash
set -euo pipefail

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${ENGINE:?Set ENGINE to deepgram or elevenlabs}"
: "${AUDIO_PATH:?Set AUDIO_PATH, for example TestAssets/LocalAITranscription/technical/en/short.wav}"

if [[ ! -f "$AUDIO_PATH" ]]; then
  echo "Audio file not found: $AUDIO_PATH" >&2
  exit 2
fi

engine="$(printf '%s' "$ENGINE" | tr '[:upper:]' '[:lower:]')"
response_file="$(mktemp)"
curl_config="$(mktemp)"
curl_error="$(mktemp)"
trap 'rm -f "$response_file" "$curl_config" "$curl_error"' EXIT
chmod 600 "$curl_config"

make_deepgram_endpoint() {
  python3 - "$script_dir" "${VOCABULARY_PATH:-}" "${LANGUAGE:-auto}" <<'PY'
import json
import pathlib
import sys
import urllib.parse

sys.path.insert(0, sys.argv[1])
from stt_benchmark_vocabulary import load_vocabulary, recognition_payload_terms

vocabulary_path = pathlib.Path(sys.argv[2]) if sys.argv[2] else None
language = sys.argv[3]
deepgram_language = "multi" if language == "auto" else language
query = [
    ("model", "nova-3"),
    ("language", deepgram_language),
    ("smart_format", "true"),
]

if vocabulary_path:
    keyterms, replacements = load_vocabulary(vocabulary_path)
    for term in recognition_payload_terms(keyterms, replacements, max_count=1000, max_length=100, max_total_words=80):
        query.append(("keyterm", term))
    data = json.loads(vocabulary_path.read_text())
    for original, replacement in sorted(data.get("replacements", {}).items()):
        original = original.strip()
        replacement = replacement.strip()
        if original and replacement:
            query.append(("replace", f"{original}:{replacement}"))

print("https://api.deepgram.com/v1/listen?" + urllib.parse.urlencode(query))
PY
}

make_elevenlabs_keyterms() {
  python3 - "$script_dir" "${VOCABULARY_PATH:-}" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from stt_benchmark_vocabulary import load_vocabulary, recognition_payload_terms

vocabulary_path = sys.argv[2]
if not vocabulary_path:
    sys.exit(0)

keyterms, replacements = load_vocabulary(vocabulary_path)
for term in recognition_payload_terms(keyterms, replacements, max_count=1000, max_length=50, max_words=5):
    print(term)
PY
}

case "$engine" in
  deepgram)
    : "${DEEPGRAM_API_KEY:?Set DEEPGRAM_API_KEY in .env}"
    endpoint="$(make_deepgram_endpoint)"
    printf 'header = "Authorization: Token %s"\n' "$DEEPGRAM_API_KEY" >"$curl_config"
    curl_args=(
      --config "$curl_config"
      --silent
      --show-error
      --fail-with-body
      --output "$response_file"
      --write-out "%{time_total}"
      --request POST "$endpoint"
      --header "Content-Type: audio/wav"
      --data-binary "@${AUDIO_PATH}"
    )
    model="nova-3"
    ;;
  elevenlabs)
    : "${ELEVENLABS_API_KEY:?Set ELEVENLABS_API_KEY in .env}"
    printf 'header = "xi-api-key: %s"\n' "$ELEVENLABS_API_KEY" >"$curl_config"
    curl_args=(
      --config "$curl_config"
      --silent
      --show-error
      --fail-with-body
      --output "$response_file"
      --write-out "%{time_total}"
      --request POST "https://api.elevenlabs.io/v1/speech-to-text"
      --form "model_id=scribe_v2"
      --form "tag_audio_events=false"
      --form "timestamps_granularity=none"
    )

    case "${LANGUAGE:-auto}" in
      en) curl_args+=(--form "language_code=eng") ;;
      es) curl_args+=(--form "language_code=spa") ;;
      auto|"") ;;
      *) echo "Unsupported ElevenLabs benchmark LANGUAGE=${LANGUAGE}; use auto, en, or es" >&2; exit 2 ;;
    esac

    while IFS= read -r keyterm; do
      [[ -n "$keyterm" ]] || continue
      curl_args+=(--form-string "keyterms=${keyterm}")
    done < <(make_elevenlabs_keyterms)

    curl_args+=(--form "file=@${AUDIO_PATH};type=audio/wav")
    model="scribe_v2"
    ;;
  *)
    echo "Unsupported ENGINE=$ENGINE; use deepgram or elevenlabs" >&2
    exit 2
    ;;
esac

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

python3 - "$script_dir" "$response_file" "$elapsed" "$engine" "$model" "$AUDIO_PATH" "${TRANSCRIPT_PATH:-}" "${VOCABULARY_PATH:-}" "${CRITICAL_TERMS_PATH:-}" "${PRINT_TEXT:-0}" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from stt_benchmark_vocabulary import apply_recognition_corrections, load_critical_terms, load_vocabulary, score

response_path = pathlib.Path(sys.argv[2])
elapsed = float(sys.argv[3])
engine = sys.argv[4]
model = sys.argv[5]
audio = sys.argv[6]
transcript_path = pathlib.Path(sys.argv[7]) if sys.argv[7] else None
vocabulary_path = pathlib.Path(sys.argv[8]) if sys.argv[8] else None
critical_terms_path = pathlib.Path(sys.argv[9]) if sys.argv[9] else None
print_text = sys.argv[10] == "1"
body = response_path.read_text(errors="replace")

try:
    payload = json.loads(body)
except Exception:
    payload = {}

if engine == "deepgram":
    try:
        text = payload["results"]["channels"][0]["alternatives"][0].get("transcript", "")
    except Exception:
        text = body
else:
    text = payload.get("text", body if isinstance(body, str) else "")

keyterms, replacements = load_vocabulary(vocabulary_path)
corrected_text = apply_recognition_corrections(text, keyterms, replacements) if keyterms or replacements else text

result = {
    "engine": engine,
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
