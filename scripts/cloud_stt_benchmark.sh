#!/usr/bin/env bash
set -euo pipefail

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${ENGINE:?Set ENGINE to deepgram or elevenlabs}"
: "${AUDIO_PATH:?Set AUDIO_PATH, for example TestAssets/LocalAITranscription/technical-en-short.wav}"

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
  python3 - "${VOCABULARY_PATH:-}" "${LANGUAGE:-auto}" <<'PY'
import json
import pathlib
import sys
import urllib.parse

vocabulary_path = pathlib.Path(sys.argv[1]) if sys.argv[1] else None
language = sys.argv[2]
deepgram_language = "multi" if language == "auto" else language
query = [
    ("model", "nova-3"),
    ("language", deepgram_language),
    ("smart_format", "true"),
]

if vocabulary_path:
    data = json.loads(vocabulary_path.read_text())
    for term in data.get("keyterms", []):
        term = term.strip()
        if term:
            query.append(("keyterm", term))
    for original, replacement in sorted(data.get("replacements", {}).items()):
        original = original.strip()
        replacement = replacement.strip()
        if original and replacement:
            query.append(("replace", f"{original}:{replacement}"))

print("https://api.deepgram.com/v1/listen?" + urllib.parse.urlencode(query))
PY
}

make_elevenlabs_keyterms() {
  python3 - "${VOCABULARY_PATH:-}" <<'PY'
import json
import pathlib
import re
import sys

vocabulary_path = pathlib.Path(sys.argv[1]) if sys.argv[1] else None
if not vocabulary_path:
    sys.exit(0)

def unique(values):
    seen = set()
    result = []
    for value in values:
        trimmed = value.strip()
        key = trimmed.casefold()
        if trimmed and key not in seen:
            seen.add(key)
            result.append(trimmed)
    return result

def spoken_form(keyterm):
    separated = re.sub(r"[-_.]+", " ", keyterm)
    if len(separated) <= 1:
        return separated

    result = []
    for index, character in enumerate(separated):
        if index:
            previous = separated[index - 1]
            next_character = separated[index + 1] if index + 1 < len(separated) else ""
            if character.isupper() and (
                previous.islower()
                or previous.isdigit()
                or (previous.isupper() and next_character.islower())
            ):
                result.append(" ")
        result.append(character)
    return re.sub(r" {2,}", " ", "".join(result)).strip()

def spoken_symbol_form(keyterm, symbol_word):
    return re.sub(
        r" {2,}",
        " ",
        keyterm.replace(".", f" {symbol_word} ").replace("-", " ").replace("_", " "),
    ).strip()

def recognition_variants(keyterm):
    spoken_variants = [
        keyterm,
        spoken_form(keyterm),
        spoken_symbol_form(keyterm, "dot"),
        spoken_symbol_form(keyterm, "period"),
    ]

    def add_replacement_variants(needle, replacements):
        nonlocal spoken_variants
        if re.search(re.escape(needle), keyterm, flags=re.IGNORECASE):
            spoken_variants.extend(
                re.sub(re.escape(needle), replacement, keyterm, flags=re.IGNORECASE)
                for replacement in replacements
            )

    add_replacement_variants("Claude", ["Cloud", "Claw", "Clawd", "Clawed", "Claud", "Slough", "Clog"])
    add_replacement_variants("Deepgram", ["Deep gram", "Depgram", "Deppgram"])
    add_replacement_variants("ElevenLabs", ["Eleven Labs", "11labs"])
    add_replacement_variants("Local AI Server", ["localize server"])
    add_replacement_variants(
        "SapoWhisper",
        [
            "Sapo Whisper",
            "Sapo Visper",
            "SAP OVISPER",
            "Sapa Whisper",
            "SAPA Whisper",
            "SAP Awhisper",
            "Zap o Whisper",
            "Zapo Whisper",
            "Sapowisper",
        ],
    )
    lower_keyterm = keyterm.casefold()
    if lower_keyterm == "claude.md":
        spoken_variants.extend(["claud mendy", "claude mendy", "cod md"])
    if lower_keyterm == "agents.md":
        spoken_variants.extend(["agens md", "agents knotsmd", "nats md", "agients md"])
    if lower_keyterm == "app store connect":
        spoken_variants.extend(["AppStore Connect", "AppStore, Connect", "Store Connect"])
    if lower_keyterm == "nova-3":
        spoken_variants.append("Nova three")
    if lower_keyterm == "scribe v2":
        spoken_variants.append("Scribe v two")
    if lower_keyterm == "git" or lower_keyterm.startswith("git "):
        add_replacement_variants("git", ["hit"])
    if lower_keyterm == "push" or " push" in lower_keyterm:
        add_replacement_variants("push", ["pug"])
    if lower_keyterm == "git push":
        spoken_variants.append("hit pug")
    add_replacement_variants("Hetzner", ["Etzner", "Etsner"])
    add_replacement_variants("Jellyfin", ["Jellifin", "Gelifin"])
    add_replacement_variants("PostgreSQL", ["PostgresUL"])
    add_replacement_variants("Cloudflare", ["ClavFlare"])

    return unique(spoken_variants + [re.sub(r"[-_.\s]+", "", variant) for variant in spoken_variants])

data = json.loads(vocabulary_path.read_text())
candidates = [
    term.strip()
    for term in data.get("keyterms", [])
    if term.strip()
]
candidates.extend(
    value.strip()
    for _, value in sorted(data.get("replacements", {}).items())
    if value.strip()
)

expanded = []
for candidate in candidates:
    expanded.append(candidate)
for candidate in candidates:
    expanded.extend(recognition_variants(candidate))

for term in unique(expanded):
    if len(term) <= 50 and len(term.split()) <= 5:
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

python3 - "$response_file" "$elapsed" "$engine" "$model" "$AUDIO_PATH" "${TRANSCRIPT_PATH:-}" "${VOCABULARY_PATH:-}" "${CRITICAL_TERMS_PATH:-}" "${PRINT_TEXT:-0}" <<'PY'
import difflib
import json
import pathlib
import re
import sys

response_path = pathlib.Path(sys.argv[1])
elapsed = float(sys.argv[2])
engine = sys.argv[3]
model = sys.argv[4]
audio = sys.argv[5]
transcript_path = pathlib.Path(sys.argv[6]) if sys.argv[6] else None
vocabulary_path = pathlib.Path(sys.argv[7]) if sys.argv[7] else None
critical_terms_path = pathlib.Path(sys.argv[8]) if sys.argv[8] else None
print_text = sys.argv[9] == "1"
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

def unique(values):
    seen = set()
    result = []
    for value in values:
        trimmed = value.strip()
        key = trimmed.casefold()
        if trimmed and key not in seen:
            seen.add(key)
            result.append(trimmed)
    return result

def spoken_form(keyterm):
    separated = re.sub(r"[-_.]+", " ", keyterm)
    if len(separated) <= 1:
        return separated

    result = []
    for index, character in enumerate(separated):
        if index:
            previous = separated[index - 1]
            next_character = separated[index + 1] if index + 1 < len(separated) else ""
            if character.isupper() and (
                previous.islower()
                or previous.isdigit()
                or (previous.isupper() and next_character.islower())
            ):
                result.append(" ")
        result.append(character)
    return re.sub(r" {2,}", " ", "".join(result)).strip()

def spoken_symbol_form(keyterm, symbol_word):
    return re.sub(
        r" {2,}",
        " ",
        keyterm.replace(".", f" {symbol_word} ").replace("-", " ").replace("_", " "),
    ).strip()

def recognition_variants(keyterm):
    spoken_variants = [
        keyterm,
        spoken_form(keyterm),
        spoken_symbol_form(keyterm, "dot"),
        spoken_symbol_form(keyterm, "period"),
    ]

    def add_replacement_variants(needle, replacements):
        nonlocal spoken_variants
        if re.search(re.escape(needle), keyterm, flags=re.IGNORECASE):
            spoken_variants.extend(
                re.sub(re.escape(needle), replacement, keyterm, flags=re.IGNORECASE)
                for replacement in replacements
            )

    add_replacement_variants("Claude", ["Cloud", "Claw", "Clawd", "Clawed", "Claud", "Slough", "Clog"])
    add_replacement_variants("Deepgram", ["Deep gram", "Depgram", "Deppgram"])
    add_replacement_variants("ElevenLabs", ["Eleven Labs", "11labs"])
    add_replacement_variants("Local AI Server", ["localize server"])
    add_replacement_variants("SapoWhisper", ["Sapo Whisper", "Sapo Visper", "SAP OVISPER", "Sapa Whisper", "SAPA Whisper", "SAP Awhisper", "Zap o Whisper", "Zapo Whisper", "Sapowisper"])
    lower_keyterm = keyterm.casefold()
    if lower_keyterm == "claude.md":
        spoken_variants.extend(["claud mendy", "claude mendy", "cod md"])
    if lower_keyterm == "agents.md":
        spoken_variants.extend(["agens md", "agents knotsmd", "nats md", "agients md"])
    if lower_keyterm == "app store connect":
        spoken_variants.extend(["AppStore Connect", "AppStore, Connect", "Store Connect"])
    if lower_keyterm == "nova-3":
        spoken_variants.append("Nova three")
    if lower_keyterm == "scribe v2":
        spoken_variants.append("Scribe v two")
    if lower_keyterm == "git" or lower_keyterm.startswith("git "):
        add_replacement_variants("git", ["hit"])
    if lower_keyterm == "push" or " push" in lower_keyterm:
        add_replacement_variants("push", ["pug"])
    if lower_keyterm == "git push":
        spoken_variants.append("hit pug")
    add_replacement_variants("Hetzner", ["Etzner", "Etsner"])
    add_replacement_variants("Jellyfin", ["Jellifin", "Gelifin"])
    add_replacement_variants("PostgreSQL", ["PostgresUL"])
    add_replacement_variants("Cloudflare", ["ClavFlare"])

    return unique(spoken_variants + [re.sub(r"[-_.\s]+", "", variant) for variant in spoken_variants])

def alphanumeric_tokens(term):
    return re.findall(r"[A-Za-z0-9]+", term)

def token_pattern(token):
    if len(token) <= 4 and token.isalpha():
        return r"[\s._-]*".join(re.escape(character) for character in token) + r"\.?"
    return re.escape(token)

FLEXIBLE_SEPARATOR = r"(?:[\s._,;:\-]+|\s*(?:dot|period|dash|hyphen|underscore)\s*)+"

def whole_term_pattern(term):
    tokens = alphanumeric_tokens(term)
    if not tokens:
        return r"(?!)"
    prefix_guard = r"(?<!APP )" if term.casefold() == "store connect" else ""
    return r"(?<![A-Za-z0-9])" + prefix_guard + FLEXIBLE_SEPARATOR.join(token_pattern(token) for token in tokens) + r"(?![A-Za-z0-9])"

def replacement_pattern(term):
    if not any(symbol in term for symbol in ".-_"):
        return r"\b" + re.escape(term) + r"\b"

    parts = []
    for character in term:
        if character == ".":
            parts.append(r"(?:\s*(?:\.|dot)?\s*)")
        elif character == "-":
            parts.append(r"(?:\s*(?:-|dash|hyphen)?\s*)")
        elif character == "_":
            parts.append(r"(?:\s*(?:_|underscore)?\s*)")
        else:
            parts.append(re.escape(character))
    return r"(?<![A-Za-z0-9])" + "".join(parts) + r"(?![A-Za-z0-9])"

def load_vocabulary(path):
    if not path:
        return [], {}
    data = json.loads(path.read_text())
    keyterms = [term.strip() for term in data.get("keyterms", []) if term.strip()]
    replacements = {
        key.strip().casefold(): value.strip()
        for key, value in data.get("replacements", {}).items()
        if key.strip() and value.strip()
    }
    return keyterms, replacements

def apply_recognition_corrections(transcript, keyterms, replacements):
    current = transcript
    for original, replacement in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
        current = re.sub(replacement_pattern(original), replacement, current, flags=re.IGNORECASE)

    candidates = keyterms + [value for _, value in sorted(replacements.items())]
    pairs = [
        (variant, canonical)
        for canonical in candidates
        for variant in recognition_variants(canonical)
    ]
    for variant, canonical in sorted(pairs, key=lambda pair: len(pair[0]), reverse=True):
        current = re.sub(whole_term_pattern(variant), canonical, current, flags=re.IGNORECASE)
    return current

def normalized_tokens(value):
    return re.findall(r"[a-z0-9]+", value.casefold())

def global_similarity(reference, candidate):
    reference_tokens = normalized_tokens(reference)
    candidate_tokens = normalized_tokens(candidate)
    if not reference_tokens and not candidate_tokens:
        return 100.0
    return round(difflib.SequenceMatcher(None, reference_tokens, candidate_tokens).ratio() * 100, 2)

def exact_term_count(value, term):
    pattern = r"(?<![A-Za-z0-9])" + re.escape(term) + r"(?![A-Za-z0-9])"
    return len(re.findall(pattern, value))

def load_critical_terms(path, keyterms, reference):
    if path:
        return [
            line.strip()
            for line in path.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
    return [term for term in keyterms if exact_term_count(reference, term) > 0]

def critical_score(reference, candidate, critical_terms):
    expected_total = 0
    found_total = 0
    missing = []
    for term in critical_terms:
        expected = exact_term_count(reference, term)
        if expected == 0:
            continue
        found = exact_term_count(candidate, term)
        expected_total += expected
        found_total += min(found, expected)
        if found < expected:
            missing.append({"term": term, "expected": expected, "found": found})

    if expected_total == 0:
        return None, missing
    return round((found_total / expected_total) * 100, 2), missing

def score(reference, candidate, critical_terms):
    similarity = global_similarity(reference, candidate)
    term_score, missing = critical_score(reference, candidate, critical_terms)
    weighted = similarity if term_score is None else round(similarity * 0.35 + term_score * 0.65, 2)
    return {
        "global_similarity": similarity,
        "critical_term_score": term_score,
        "weighted_score": weighted,
        "missing_critical_terms": missing,
    }

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
