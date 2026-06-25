import difflib
import json
import pathlib
import re


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
    "agents.md": ["agens md", "agents knotsmd", "nats md", "agients md", "ages md", "ages punto md", "ages punto m d", "agents punto md", "agents punto m d"],
    "app store connect": ["AppStore Connect", "AppStore, Connect", "Store Connect"],
    "nova-3": ["Nova three", "Nova tres"],
    "scribe v2": ["Scribe v two", "Scribe version 2", "Scribe version dos", "Scribe versión 2", "Scribe versión dos", "Scri Scribe version dos", "Scri Scribe versión dos"],
    "local ai server (nvidia)": ["Local AI Server NVIDIA", "Local AI Server, NVIDIA", "local ya server NVIDIA", "localia server NVIDIA"],
    "ai polish": ["a AI", "a AI polish", "ahí a Polish"],
    "commit": ["comet", "comit", "commet", "HacerunComet"],
    "git commit": ["deep comment", "deep comet", "dip comment", "hago Kimi", "Kit commit"],
    "kimi v2": ["KimiV2", "Kimi P2", "Kimi P 2", "KimiVersión2", "Kimi version 2", "Kimi version dos", "Kimi versión dos", "Kimi V two", "Kimi V dos"],
    "qbittorrent": ["KubiTorret", "Kubi Torrent", "QubiTorrent", "Qubitorrel", "Cubitorrel", "qBittorrent", "qbittorrent"],
    "vue 3": ["Vue three"],
    "git push": ["deep push", "dip push", "hit pug", "kit push"],
    "testflight": ["TestFly"],
    "sqlite": ["SQ Lite", "UseSqlite"],
    "userdefaults": ["UserDefault", "User Default", "User Defaults"],
    "rest api": ["RESTAPI"],
    "pull request": ["pool request"],
}


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


def load_vocabulary(path):
    if not path:
        return [], {}
    data = json.loads(pathlib.Path(path).read_text())
    keyterms = [term.strip() for term in data.get("keyterms", []) if term.strip()]
    replacements = {
        key.strip().casefold(): value.strip()
        for key, value in data.get("replacements", {}).items()
        if key.strip() and value.strip()
    }
    return keyterms, replacements


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
        return r"[\s._-]*".join(re.escape(character) for character in token) + r"\.?"
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


def apply_recognition_corrections(transcript, keyterms, replacements):
    current = transcript
    for original, replacement in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
        current = re.sub(replacement_pattern(original), replacement, current, flags=re.IGNORECASE)
    candidates = keyterms + [value for _, value in sorted(replacements.items())]
    available_terms = {term.strip().casefold() for term in candidates if term.strip()}
    if "git" in available_terms and "commit" in available_terms:
        for variant in ["deep comment", "deep comet", "dip comment"]:
            current = re.sub(whole_term_pattern(variant), "git commit", current, flags=re.IGNORECASE)
    if "git" in available_terms and "push" in available_terms:
        for variant in ["deep push", "dip push"]:
            current = re.sub(whole_term_pattern(variant), "git push", current, flags=re.IGNORECASE)
    pairs = [(variant, canonical) for canonical in candidates for variant in recognition_variants(canonical)]
    for variant, canonical in sorted(pairs, key=lambda pair: len(pair[0]), reverse=True):
        current = re.sub(whole_term_pattern(variant), canonical, current, flags=re.IGNORECASE)
    return current


def exact_term_count(value, term):
    return len(re.findall(r"(?<![A-Za-z0-9])" + re.escape(term) + r"(?![A-Za-z0-9])", value))


def load_critical_terms(path, keyterms, reference):
    if path:
        return [line.strip() for line in pathlib.Path(path).read_text().splitlines() if line.strip() and not line.lstrip().startswith("#")]
    return [term for term in keyterms if exact_term_count(reference, term) > 0]


def score(reference, candidate, critical_terms):
    reference_tokens = re.findall(r"[a-z0-9]+", reference.casefold())
    candidate_tokens = re.findall(r"[a-z0-9]+", candidate.casefold())
    similarity = 100.0 if not reference_tokens and not candidate_tokens else round(difflib.SequenceMatcher(None, reference_tokens, candidate_tokens).ratio() * 100, 2)
    expected_total = 0
    found_total = 0
    missing = []
    for term in critical_terms:
        expected = exact_term_count(reference, term)
        found = exact_term_count(candidate, term)
        if expected:
            expected_total += expected
            found_total += min(found, expected)
            if found < expected:
                missing.append({"term": term, "expected": expected, "found": found})
    term_score = None if expected_total == 0 else round((found_total / expected_total) * 100, 2)
    weighted = similarity if term_score is None else round(similarity * 0.35 + term_score * 0.65, 2)
    return {"global_similarity": similarity, "critical_term_score": term_score, "weighted_score": weighted, "missing_critical_terms": missing}
