import json
import pathlib
import re
import unicodedata


BASE_CONFUSIONS = {
    "Claude": ["Cloud", "Claw", "Clawd", "Clawed", "Claud", "Clauco", "Clouco", "Slough", "Clog"],
    "Deepgram": ["Deep gram", "Depgram", "Deppgram", "Ditgram"],
    "ElevenLabs": ["Eleven Labs", "11labs"],
    "Local AI Server": ["localize server", "local ya server", "localia server"],
    "SapoWhisper": [
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
    "Hetzner": ["Etzner", "Etsner", "Edsner", "Hedsner", "Headsnare", "Head snare", "HeadServe", "HeadServer"],
    "Jellyfin": ["Jellifin", "Gelifin", "Jellyfine", "JellyFight", "JellyFy"],
    "PostgreSQL": ["PostgresUL", "Postgres SQL"],
    "Cloudflare": ["ClavFlare", "CloudFair"],
    "WireGuard": ["YFWAR", "YF WAR", "WifeWare"],
}

EXACT_CONFUSIONS = {
    "claude.md": ["claud mendy", "claude mendy", "cod md"],
    ".env": [".em", ".emb", ".m", "dot em", "dot emb", "dot m", "period m", "punto em", "punto emb", "punto m", "punto env"],
    ".gitignore": ["punto git ignore", "punto geek ignore", "punto kid ignore"],
    "agents.md": ["agens md", "agents knotsmd", "legends md", "legends dot md", "legends punto md", "legends.md", "nats md", "agients md", "ages md", "ages punto md", "ages punto m d", "agents punto md", "agents punto m d"],
    "app store connect": ["AppStore Connect", "AppStore, Connect", "Store Connect"],
    "nova-3": ["Nova three", "Nova tres"],
    "scribe v2": ["Scribe v two", "Scribe version 2", "Scribe version dos", "Scribe versión 2", "Scribe versión dos", "Scri Scribe version dos", "Scri Scribe versión dos"],
    "local ai server (nvidia)": ["Local AI Server NVIDIA", "Local AI Server, NVIDIA", "local ya server NVIDIA", "localia server NVIDIA"],
    "ai polish": ["a AI", "a AI polish", "ahí a Polish"],
    "commit": ["comet", "comit", "commet", "HacerunComet"],
    "git commit": ["deep comment", "deep comet", "dip comment", "hago Kimi", "Kit commit", "KitCom", "KitComit", "KitCommit"],
    "kimi v2": ["KimiV2", "Kimi P2", "Kimi P 2", "KimiVersión2", "Kimi version 2", "Kimi version dos", "Kimi versión dos", "Kimi V two", "Kimi V dos"],
    "qbittorrent": ["KubiTorret", "Kubi Torrent", "QubiTorrent", "Qubitorrel", "Cubitorrel", "qBittorrent", "qbittorrent"],
    "vue 3": ["Vue three"],
    "git push": ["deep push", "dip push", "hit pug", "kit push", "KitPush"],
    "testflight": ["TestFly"],
    "sqlite": ["SQ Lite", "UseSqlite"],
    "userdefaults": ["UserDefault", "User Default", "User Defaults"],
    "rest api": ["RESTAPI"],
    "pull request": ["pool request"],
}

CONTEXT_ONLY_CORRECTION_VARIANTS = {"hit", "pug", "comet", "cloud", "claw", "clawed", "clog", "slough"}


def unique(values):
    seen = set()
    result = []
    for value in values:
        trimmed = value.strip()
        key = unicodedata.normalize("NFC", trimmed.lower())
        if trimmed and key not in seen:
            seen.add(key)
            result.append(trimmed)
    return result


def load_vocabulary(path):
    keyterms, replacements, _ = load_vocabulary_settings(path)
    return keyterms, replacements


def load_vocabulary_settings(path):
    if not path:
        return [], {}, True
    data = json.loads(pathlib.Path(path).read_text())
    keyterms = [term.strip() for term in data.get("keyterms", []) if term.strip()]
    replacements = {
        key.strip(): value.strip()
        for key, value in data.get("replacements", {}).items()
        if key.strip() and value.strip()
    }
    return keyterms, replacements, data.get("includeReplacementTargetsInRecognitionHints", True)


def sanitized_recognition_hint(term):
    sanitized = "".join(" " if unicodedata.category(character) in {"Cc", "Cf"} else character for character in term)
    return re.sub(r" {2,}", " ", sanitized).strip()


def swift_character_count(value):
    """Covers common Swift grapheme clusters; stdlib cannot implement every Unicode UAX #29 tailoring."""
    normalized = unicodedata.normalize("NFC", value)
    count = 0
    joined = False
    regional_run = 0
    previous = ""
    for character in normalized:
        codepoint = ord(character)
        category = unicodedata.category(character)
        if previous == "\r" and character == "\n":
            previous = character
            continue
        if character == "\u200d":
            joined = True
            previous = character
            continue
        if category in {"Mn", "Mc", "Me"} or 0xFE00 <= codepoint <= 0xFE0F or 0xE0100 <= codepoint <= 0xE01EF or 0x1F3FB <= codepoint <= 0x1F3FF or 0xE0020 <= codepoint <= 0xE007F:
            if count == 0:
                count = 1
            previous = character
            continue
        if joined:
            joined = False
            previous = character
            continue
        if 0x1F1E6 <= codepoint <= 0x1F1FF:
            if regional_run % 2 == 0:
                count += 1
            regional_run += 1
        else:
            regional_run = 0
            count += 1
        previous = character
    return count


def recognition_candidates(keyterms, replacements, include_replacement_values=True):
    saved_keyterms = [term.strip() for term in keyterms if term.strip()]
    if not include_replacement_values:
        return saved_keyterms
    replacement_values = [value.strip() for _, value in sorted(replacements.items()) if value.strip()]
    return saved_keyterms + replacement_values


def echo_detection_terms(keyterms, replacements, include_replacement_values=True):
    return unique(sanitized_recognition_hint(term) for term in recognition_candidates(keyterms, replacements, include_replacement_values))


def initial_prompt_text(keyterms, replacements, include_replacement_values=True, max_length=700):
    terms = echo_detection_terms(keyterms, replacements, include_replacement_values)
    prefix = "Glossary: "
    body = ""
    for term in terms:
        candidate = term if not body else f"{body}, {term}"
        if swift_character_count(prefix) + swift_character_count(candidate) + 1 > max_length:
            break
        body = candidate
    return f"{prefix}{body}." if body else ""


def spoken_form(keyterm):
    separated = re.sub(r"[-_.]+", " ", keyterm)
    result = []
    for index, character in enumerate(separated):
        if index:
            previous = separated[index - 1]
            next_character = separated[index + 1] if index + 1 < len(separated) else ""
            if character.isupper() and (previous.islower() or previous.isdigit() or (previous.isupper() and next_character.islower())):
                result.append(" ")
        result.append(character)
    return re.sub(r" {2,}", " ", "".join(result)).strip()


def spoken_symbol_form(keyterm, symbol_word):
    return re.sub(r" {2,}", " ", keyterm.replace(".", f" {symbol_word} ").replace("-", " ").replace("_", " ")).strip()


def recognition_variants(keyterm):
    variants = [keyterm, spoken_symbol_form(keyterm, "dot"), spoken_symbol_form(keyterm, "period"), spoken_symbol_form(keyterm, "punto")]
    if not keyterm.startswith("."):
        variants.insert(1, spoken_form(keyterm))
    for needle, replacements in BASE_CONFUSIONS.items():
        if re.search(re.escape(needle), keyterm, flags=re.IGNORECASE):
            variants.extend(re.sub(re.escape(needle), replacement, keyterm, flags=re.IGNORECASE) for replacement in replacements)
    lower = keyterm.casefold()
    variants.extend(EXACT_CONFUSIONS.get(lower, []))
    if lower == "git" or lower.startswith("git "):
        variants.extend(re.sub("git", "hit", keyterm, flags=re.IGNORECASE) for _ in [0])
    if lower == "push" or " push" in lower:
        variants.extend(re.sub("push", "pug", keyterm, flags=re.IGNORECASE) for _ in [0])
    condensed = [] if keyterm.startswith(".") else [re.sub(r"[-_.\s]+", "", variant) for variant in variants]
    return unique(variants + condensed)


def recognition_payload_terms(keyterms, replacements, max_count, max_length, max_words=None, max_total_words=None):
    candidates = keyterms + [value for _, value in sorted(replacements.items())]
    expanded = []
    for candidate in candidates:
        expanded.append(candidate)
    for candidate in candidates:
        expanded.extend(recognition_variants(candidate))
    valid = [
        term for term in unique(expanded)
        if len(term) <= max_length and (max_words is None or len(term.split()) <= max_words)
    ]
    if max_total_words is None:
        return valid[:max_count]
    total_words = 0
    limited = []
    for term in valid:
        words = max(1, len(term.split()))
        if total_words + words > max_total_words:
            continue
        total_words += words
        limited.append(term)
        if len(limited) >= max_count:
            break
    return limited


def token_pattern(token):
    if len(token) <= 4 and token.isalpha():
        return r"[\s._-]*".join(re.escape(character) for character in token)
    return re.escape(token)


FLEXIBLE_SEPARATOR = r"(?:[\s._,;:\-]+|\s*(?:dot|period|punto|dash|hyphen|underscore)\s*)+"


def whole_term_pattern(term):
    tokens = re.findall(r"[^\W_]+", term)
    if not tokens:
        return r"(?!)"
    prefix_guard = r"(?<!APP )" if term.casefold() == "store connect" else ""
    leading_boundary = r"(?<![A-Za-z0-9.])" if term.startswith(".") else r"(?<![A-Za-z0-9])"
    dot_prefix = r"(?:\.|dot|period|punto)\s*" if term.startswith(".") else ""
    return leading_boundary + prefix_guard + dot_prefix + FLEXIBLE_SEPARATOR.join(token_pattern(token) for token in tokens) + r"(?![A-Za-z0-9])"


def replacement_pattern(term):
    if not any(symbol in term for symbol in ".-_"):
        return r"\b" + re.escape(term) + r"\b"
    parts = []
    for character in term:
        if character == ".":
            parts.append(r"(?:\s*(?:\.|dot|period|punto)?\s*)")
        elif character == "-":
            parts.append(r"(?:\s*(?:-|dash|hyphen)?\s*)")
        elif character == "_":
            parts.append(r"(?:\s*(?:_|underscore)?\s*)")
        else:
            parts.append(re.escape(character))
    return r"(?<![A-Za-z0-9])" + "".join(parts) + r"(?![A-Za-z0-9])"


def mechanically_stable_replacements(replacements):
    stable = {}
    for original, replacement in replacements.items():
        corrected = re.sub(replacement_pattern(original), lambda _: replacement, replacement, flags=re.IGNORECASE)
        if corrected == replacement:
            stable[original] = replacement
    return stable


def apply_recognition_corrections(transcript, keyterms, replacements):
    current = transcript
    for original, replacement in sorted(mechanically_stable_replacements(replacements).items(), key=lambda item: len(item[0]), reverse=True):
        current = re.sub(replacement_pattern(original), lambda _: replacement, current, flags=re.IGNORECASE)
    candidates = recognition_candidates(keyterms, replacements)
    available_terms = {term.strip().casefold() for term in candidates if term.strip()}
    if "git" in available_terms and "commit" in available_terms:
        for variant in ["deep comment", "deep comet", "dip comment"]:
            current = re.sub(whole_term_pattern(variant), "git commit", current, flags=re.IGNORECASE)
    if "git" in available_terms and "push" in available_terms:
        for variant in ["deep push", "dip push"]:
            current = re.sub(whole_term_pattern(variant), "git push", current, flags=re.IGNORECASE)
    if "git" in available_terms:
        for variant in ["KitCom", "KitComit", "KitCommit", "Kit Commit"]:
            current = re.sub(whole_term_pattern(variant), "git commit", current, flags=re.IGNORECASE)
        for variant in ["KitPush", "Kit Push"]:
            current = re.sub(whole_term_pattern(variant), "git push", current, flags=re.IGNORECASE)
    canonical_keys = {normalized_recognition_key(term) for term in candidates}
    pairs = [
        (variant, canonical)
        for canonical in candidates
        for variant in recognition_variants(canonical)
        if variant.casefold() not in CONTEXT_ONLY_CORRECTION_VARIANTS
        and (normalized_recognition_key(variant) == normalized_recognition_key(canonical) or normalized_recognition_key(variant) not in canonical_keys)
    ]
    for variant, canonical in sorted(pairs, key=lambda pair: len(pair[0]), reverse=True):
        current = re.sub(whole_term_pattern(variant), lambda _: canonical, current, flags=re.IGNORECASE)
    return current


def normalized_recognition_key(term):
    return " ".join(re.findall(r"[^\W_]+", term)).casefold()


def exact_term_count(value, term):
    normalized_value = unicodedata.normalize("NFC", value)
    normalized_term = unicodedata.normalize("NFC", term)
    return len(re.findall(r"(?<![^\W_])" + re.escape(normalized_term) + r"(?![^\W_])", normalized_value))


def load_critical_terms(path, keyterms, reference):
    if path:
        return [line.strip() for line in pathlib.Path(path).read_text().splitlines() if line.strip() and not line.lstrip().startswith("#")]
    return [term for term in keyterms if exact_term_count(reference, term) > 0]


def word_tokens(value):
    tokens = []
    for token in unicode_word_units(unicodedata.normalize("NFC", value).casefold()):
        if any(is_unsegmented_script_character(character) for character in token):
            tokens.extend(split_unsegmented_token(token))
        else:
            tokens.append(token)
    return tokens


def unicode_word_units(value):
    units = []
    current = ""
    for character in value:
        category = unicodedata.category(character)
        if category.startswith(("L", "N")):
            current += character
        elif category.startswith("M") and current:
            current += character
        else:
            if current:
                units.append(current)
                current = ""
    if current:
        units.append(current)
    return units


def split_unsegmented_token(token):
    parts = []
    buffered = ""
    for character in token:
        category = unicodedata.category(character)
        if category.startswith("M"):
            if buffered:
                buffered += character
            elif parts:
                parts[-1] += character
        elif is_unsegmented_script_character(character):
            if buffered:
                parts.append(buffered)
                buffered = ""
            parts.append(character)
        else:
            buffered += character
    if buffered:
        parts.append(buffered)
    return parts


def is_unsegmented_script_character(character):
    codepoint = ord(character)
    return (
        0x3400 <= codepoint <= 0x4DBF
        or 0x4E00 <= codepoint <= 0x9FFF
        or 0xF900 <= codepoint <= 0xFAFF
        or 0x3040 <= codepoint <= 0x30FF
        or 0x0E00 <= codepoint <= 0x0E7F
        or 0xAC00 <= codepoint <= 0xD7AF
    )


def edit_distance(reference, candidate):
    previous = list(range(len(candidate) + 1))
    for reference_index, reference_token in enumerate(reference, start=1):
        current = [reference_index]
        for candidate_index, candidate_token in enumerate(candidate, start=1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[candidate_index] + 1,
                    previous[candidate_index - 1] + (reference_token != candidate_token),
                )
            )
        previous = current
    return previous[-1]


def digit_runs(value):
    pattern = r"(?<![\w])-?\d+(?:[.,:/-]\d+)*(?![\w])"
    runs = []
    for match in re.finditer(pattern, value):
        token = match.group()
        unsigned = token[1:] if token.startswith("-") else token
        runs.append(
            {
                "digits": "".join(character for character in token if character.isdigit()),
                "has_separator": any(character in ".,:/-" for character in unsigned),
                "is_negative": token.startswith("-"),
            }
        )
    return runs


def missing_digit_runs(reference, candidate, require_source_separator=True):
    available = digit_runs(candidate)
    search_start = 0
    missing = []
    for expected in digit_runs(reference):
        match_index = next(
            (
                index
                for index in range(search_start, len(available))
                if available[index]["digits"] == expected["digits"]
                and available[index]["is_negative"] == expected["is_negative"]
                and (
                    not require_source_separator
                    or not expected["has_separator"]
                    or available[index]["has_separator"]
                )
            ),
            None,
        )
        if match_index is None:
            missing.append(expected)
        else:
            search_start = match_index + 1
    return missing


def score(reference, candidate, critical_terms):
    reference_tokens = word_tokens(reference)
    candidate_tokens = word_tokens(candidate)
    word_errors = edit_distance(reference_tokens, candidate_tokens)
    word_error_rate = 0.0 if not reference_tokens and not candidate_tokens else (100.0 if not reference_tokens else round(word_errors / len(reference_tokens) * 100, 2))
    expected_total = 0
    found_total = 0
    missing = []
    unexpected = []
    invalid_fixture_terms = []
    for term in critical_terms:
        expected = exact_term_count(reference, term)
        found = exact_term_count(candidate, term)
        if not expected:
            invalid_fixture_terms.append({"term": term})
            continue
        expected_total += expected
        found_total += min(found, expected)
        if found < expected:
            missing.append({"term": term, "expected": expected, "found": found})
        if found > expected:
            unexpected.append({"term": term, "expected": expected, "found": found})
    missing_digits = missing_digit_runs(reference, candidate)
    unexpected_digits = missing_digit_runs(candidate, reference, require_source_separator=False)
    critical_missing_occurrences = sum(item["expected"] - item["found"] for item in missing)
    critical_unexpected_occurrences = sum(item["found"] - item["expected"] for item in unexpected)
    critical_fixture_valid = not invalid_fixture_terms
    critical_pass = critical_fixture_valid and critical_missing_occurrences == 0 and critical_unexpected_occurrences == 0
    digits_pass = not missing_digits and not unexpected_digits
    return {
        "hard_gates_pass": critical_pass and digits_pass,
        "critical_terms_fixture_valid": critical_fixture_valid,
        "critical_terms_pass": critical_pass,
        "digit_runs_pass": digits_pass,
        "critical_terms_expected": expected_total,
        "critical_terms_found": found_total,
        "critical_terms_missing_occurrences": critical_missing_occurrences,
        "critical_terms_unexpected_occurrences": critical_unexpected_occurrences,
        "critical_terms_invalid_fixture_count": len(invalid_fixture_terms),
        "digit_runs_expected": len(digit_runs(reference)),
        "digit_runs_missing_occurrences": len(missing_digits),
        "digit_runs_unexpected_occurrences": len(unexpected_digits),
        "word_error_rate": word_error_rate,
        "word_errors": word_errors,
        "reference_word_count": len(reference_tokens),
        "lexicographic_rank": [
            int(not critical_pass),
            int(not digits_pass),
            int(not critical_fixture_valid),
            critical_missing_occurrences,
            critical_unexpected_occurrences,
            len(missing_digits),
            len(unexpected_digits),
            word_error_rate,
        ],
        "missing_critical_terms": missing,
        "unexpected_critical_terms": unexpected,
        "invalid_fixture_terms": invalid_fixture_terms,
        "missing_digit_runs": missing_digits,
        "unexpected_digit_runs": unexpected_digits,
    }
