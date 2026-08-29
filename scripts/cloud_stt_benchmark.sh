#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${ENGINE:?Set ENGINE to deepgram or elevenlabs}"
: "${AUDIO_PATH:?Set AUDIO_PATH, for example TestAssets/LocalAITranscription/technical/en/short.wav}"

if [[ ! -f "$AUDIO_PATH" ]]; then
  echo "Audio file not found: $AUDIO_PATH" >&2
  exit 2
fi

if [[ -z "${VOCABULARY_PATH:-}" && "${ALLOW_EMPTY_VOCABULARY:-0}" != "1" ]]; then
  echo "Set VOCABULARY_PATH for production parity or ALLOW_EMPTY_VOCABULARY=1 for an explicit control" >&2
  exit 2
fi
if [[ -n "${VOCABULARY_PATH:-}" && ! -f "$VOCABULARY_PATH" ]]; then
  echo "Vocabulary file not found: $VOCABULARY_PATH" >&2
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
import pathlib
import sys
import urllib.parse

sys.path.insert(0, sys.argv[1])
from stt_benchmark_vocabulary import (
    load_vocabulary_settings,
    mechanically_stable_replacements,
    sanitized_recognition_hint,
    unique,
)

vocabulary_path = pathlib.Path(sys.argv[2]) if sys.argv[2] else None
language = sys.argv[3]
deepgram_language = "multi" if language == "auto" else language
query = [
    ("model", "nova-3"),
    ("language", deepgram_language),
    ("smart_format", "true"),
]

if vocabulary_path:
    keyterms, replacements, include_replacement_values = load_vocabulary_settings(vocabulary_path)
    candidates = list(keyterms)
    if include_replacement_values:
        candidates.extend(value for _, value in sorted(replacements.items()))
    total_words = 0
    for term in unique(sanitized_recognition_hint(value) for value in candidates):
        words = max(1, len(term.split()))
        if len(term) > 100 or total_words + words > 80:
            continue
        query.append(("keyterm", term))
        total_words += words
        if sum(name == "keyterm" for name, _ in query) == 1000:
            break
    for original, replacement in sorted(mechanically_stable_replacements(replacements).items()):
        query.append(("replace", f"{original}:{replacement}"))

print("https://api.deepgram.com/v1/listen?" + urllib.parse.urlencode(query))
PY
}

make_elevenlabs_keyterms() {
  python3 - "$script_dir" "${VOCABULARY_PATH:-}" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from stt_benchmark_vocabulary import load_vocabulary_settings, sanitized_recognition_hint, unique

vocabulary_path = sys.argv[2]
if not vocabulary_path:
    sys.exit(0)

keyterms, replacements, include_replacement_values = load_vocabulary_settings(vocabulary_path)
candidates = list(keyterms)
if include_replacement_values:
    candidates.extend(value for _, value in sorted(replacements.items()))
valid = [
    term
    for term in unique(sanitized_recognition_hint(value) for value in candidates)
    if term and len(term) <= 50 and len(term.split()) <= 5
]
for term in valid[:1000]:
    print(term)
PY
}

case "$engine" in
  deepgram)
    : "${DEEPGRAM_API_KEY:?Set DEEPGRAM_API_KEY}"
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
    : "${ELEVENLABS_API_KEY:?Set ELEVENLABS_API_KEY}"
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

    elevenlabs_keyterms="$(make_elevenlabs_keyterms)"
    while IFS= read -r keyterm; do
      [[ -n "$keyterm" ]] || continue
      curl_args+=(--form-string "keyterms=${keyterm}")
    done <<<"$elevenlabs_keyterms"

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
  printf 'Cloud STT request failed curl_status=%s stderr_bytes=%s response_bytes=%s\n' \
    "$curl_status" "$(wc -c <"$curl_error" | tr -d ' ')" "$(wc -c <"$response_file" | tr -d ' ')" >&2
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
    "audio_bytes": pathlib.Path(audio).stat().st_size,
    "model": model,
    "elapsed_seconds": round(elapsed, 3),
    "text_characters": len(text.strip()),
}

if transcript_path:
    reference = transcript_path.read_text(errors="replace")
    critical_terms = load_critical_terms(critical_terms_path, keyterms, reference)
    raw_score = score(reference, text, critical_terms)
    corrected_score = score(reference, corrected_text, critical_terms)
    private_score_keys = {
        "missing_critical_terms",
        "unexpected_critical_terms",
        "invalid_fixture_terms",
        "missing_digit_runs",
        "unexpected_digit_runs",
    }
    result["scores"] = {
        "raw": {key: value for key, value in raw_score.items() if key not in private_score_keys},
        "corrected": {key: value for key, value in corrected_score.items() if key not in private_score_keys},
    }
    result["critical_term_count"] = len(critical_terms)
    result["missing_critical_term_counts"] = {
        "raw": len(raw_score["missing_critical_terms"]),
        "corrected": len(corrected_score["missing_critical_terms"]),
    }
    result["missing_digit_run_counts"] = {
        "raw": len(raw_score["missing_digit_runs"]),
        "corrected": len(corrected_score["missing_digit_runs"]),
    }
    result["unexpected_digit_run_counts"] = {
        "raw": len(raw_score["unexpected_digit_runs"]),
        "corrected": len(corrected_score["unexpected_digit_runs"]),
    }
    result["correction_changed"] = corrected_text != text

if print_text:
    result["audio"] = audio
    result["raw_text"] = text.strip()
    if corrected_text != text:
        result["corrected_text"] = corrected_text.strip()
    if transcript_path:
        result["critical_terms"] = critical_terms
        for key in private_score_keys:
            result["scores"]["raw"][key] = raw_score[key]
            result["scores"]["corrected"][key] = corrected_score[key]

print(json.dumps(result, ensure_ascii=False))
PY
