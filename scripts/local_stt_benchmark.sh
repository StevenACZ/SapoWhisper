#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${BASE_URL:?Set BASE_URL, for example http://YOUR_SERVER_IP:8000}"
: "${MODEL_ID:?Set MODEL_ID, for example rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo}"
: "${AUDIO_PATH:?Set AUDIO_PATH, for example TestAssets/LocalAITranscription/longform/sample-1m.wav}"

if [[ -z "${VOCABULARY_PATH:-}" && "${ALLOW_EMPTY_VOCABULARY:-0}" != "1" ]]; then
  echo "Set VOCABULARY_PATH or explicitly opt out with ALLOW_EMPTY_VOCABULARY=1." >&2
  exit 2
fi

if [[ -n "${VOCABULARY_PATH:-}" && ! -f "$VOCABULARY_PATH" ]]; then
  echo "Vocabulary file not found: $VOCABULARY_PATH" >&2
  exit 2
fi

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
prompt_file="$(mktemp)"
curl_config=""

cleanup() {
  rm -f "$response_file" "$curl_error" "$prompt_file"
  if [[ -n "$curl_config" ]]; then
    rm -f "$curl_config"
  fi
}
trap cleanup EXIT

python3 - "$script_dir" "${VOCABULARY_PATH:-}" >"$prompt_file" <<'PY'
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from stt_benchmark_vocabulary import initial_prompt_text, load_vocabulary_settings

path = pathlib.Path(sys.argv[2]) if sys.argv[2] else None
keyterms, replacements, include_replacement_targets = load_vocabulary_settings(path)
print(initial_prompt_text(keyterms, replacements, include_replacement_targets), end="")
PY

vocabulary_prompt="$(<"$prompt_file")"

curl_args=(
  --silent
  --show-error
  --fail-with-body
  --output "$response_file"
  --write-out "%{time_total}"
  --request POST "$endpoint"
  --form "model=${MODEL_ID}"
  --form "response_format=json"
  --form "vad_filter=true"
)

if [[ -n "${LANGUAGE:-}" && "${LANGUAGE}" != "auto" ]]; then
  curl_args+=(--form "language=${LANGUAGE}")
fi

if [[ -n "$vocabulary_prompt" ]]; then
  curl_args+=(--form-string "prompt=${vocabulary_prompt}")
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
  if [[ "${PRINT_TEXT:-0}" == "1" ]]; then
    cat "$curl_error" >&2
    if [[ -s "$response_file" ]]; then
      echo >&2
      cat "$response_file" >&2
      echo >&2
    fi
  else
    echo "Transcription request failed (curl status ${curl_status}). Set PRINT_TEXT=1 for private diagnostics." >&2
  fi
  exit "$curl_status"
fi

python3 - "$script_dir" "$response_file" "$elapsed" "$MODEL_ID" "$AUDIO_PATH" "${TRANSCRIPT_PATH:-}" "${VOCABULARY_PATH:-}" "${CRITICAL_TERMS_PATH:-}" "${PRINT_TEXT:-0}" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from stt_benchmark_vocabulary import apply_recognition_corrections, exact_term_count, load_critical_terms, load_vocabulary, score

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
    "model": model,
    "elapsed_seconds": round(elapsed, 3),
    "text_characters": len(text.strip()),
}

if transcript_path:
    reference = transcript_path.read_text(errors="replace")
    critical_terms = load_critical_terms(critical_terms_path, keyterms, reference)
    invalid_critical_term_count = sum(exact_term_count(reference, term) == 0 for term in critical_terms)
    if invalid_critical_term_count:
        raise ValueError(f"{invalid_critical_term_count} configured critical terms are absent from the reference")
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
    result["text_preview"] = text.strip()[:180]
    result["raw_text"] = text.strip()
    if corrected_text != text:
        result["corrected_text"] = corrected_text.strip()
    if transcript_path:
        result["critical_terms"] = critical_terms
        result["scores"]["raw"]["missing_critical_terms"] = raw_score["missing_critical_terms"]
        result["scores"]["corrected"]["missing_critical_terms"] = corrected_score["missing_critical_terms"]
        result["scores"]["raw"]["unexpected_critical_terms"] = raw_score["unexpected_critical_terms"]
        result["scores"]["corrected"]["unexpected_critical_terms"] = corrected_score["unexpected_critical_terms"]
        result["scores"]["raw"]["invalid_fixture_terms"] = raw_score["invalid_fixture_terms"]
        result["scores"]["corrected"]["invalid_fixture_terms"] = corrected_score["invalid_fixture_terms"]
        result["scores"]["raw"]["missing_digit_runs"] = raw_score["missing_digit_runs"]
        result["scores"]["corrected"]["missing_digit_runs"] = corrected_score["missing_digit_runs"]
        result["scores"]["raw"]["unexpected_digit_runs"] = raw_score["unexpected_digit_runs"]
        result["scores"]["corrected"]["unexpected_digit_runs"] = corrected_score["unexpected_digit_runs"]

print(json.dumps(result, ensure_ascii=False))
PY
