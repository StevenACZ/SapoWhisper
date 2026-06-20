#!/usr/bin/env python3
"""Replay local SapoWhisper history through the local AI polish endpoint.

Default output is aggregate metrics only: no transcript text, no polished text,
and no local history rows are modified. Use --print-samples only for private
debugging on your own machine.
"""

from __future__ import annotations

import argparse
import collections
import contextlib
import json
import mimetypes
import pathlib
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
import uuid

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from stt_benchmark_vocabulary import apply_recognition_corrections, load_vocabulary  # noqa: E402


DEFAULT_APP_SUPPORT = pathlib.Path.home() / "Library/Application Support/SapoWhisper"
DEFAULT_DB = DEFAULT_APP_SUPPORT / "history.db"
DEFAULT_VOCABULARY = DEFAULT_APP_SUPPORT / "vocabulary.json"
DEFAULT_POLISH_BASE_URL = "http://localhost:8081/v1"
DEFAULT_POLISH_MODEL = "qwen3.6-35b-a3b"
DEFAULT_STT_BASE_URL = "http://localhost:8000"
DEFAULT_STT_MODEL = "rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo"

KNOWN_CORRECTIONS = [
    ("deep commit", "git commit"),
    ("deep comment", "git commit"),
    ("deep comet", "git commit"),
    ("dip comment", "git commit"),
    ("deep push", "git push"),
    ("dip push", "git push"),
    ("cloud md", "CLAUDE.md"),
    ("cloud dot md", "CLAUDE.md"),
    ("claude dot md", "CLAUDE.md"),
    ("cloud code", "Claude Code"),
    ("claud code", "Claude Code"),
    ("ali test", "REST API"),
    ("restapi", "REST API"),
    ("pool request", "pull request"),
    ("local ya server", "Local AI Server"),
    ("localia server", "Local AI Server"),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=pathlib.Path, default=DEFAULT_DB)
    parser.add_argument("--vocabulary", type=pathlib.Path, default=DEFAULT_VOCABULARY)
    parser.add_argument("--limit", type=int, default=25)
    parser.add_argument("--min-chars", type=int, default=40)
    parser.add_argument("--engine-contains", default="")
    parser.add_argument("--polish-base-url", default=DEFAULT_POLISH_BASE_URL)
    parser.add_argument("--polish-model", default=DEFAULT_POLISH_MODEL)
    parser.add_argument("--stt-base-url", default=DEFAULT_STT_BASE_URL)
    parser.add_argument("--stt-model", default=DEFAULT_STT_MODEL)
    parser.add_argument("--timeout", type=float, default=35)
    parser.add_argument("--retranscribe-audio", action="store_true")
    parser.add_argument("--print-samples", action="store_true")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def fetch_rows(db_path: pathlib.Path, limit: int, min_chars: int, engine_contains: str) -> list[sqlite3.Row]:
    if not db_path.exists():
        raise SystemExit(f"History DB not found: {db_path}")

    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    filters = ["status = 'completed'", "length(COALESCE(raw_transcription, transcription)) >= ?"]
    values: list[object] = [min_chars]
    if engine_contains:
        filters.append("engine LIKE ?")
        values.append(f"%{engine_contains}%")
    values.append(limit)

    rows = con.execute(
        f"""
        SELECT id, timestamp, engine, duration_seconds, transcription,
               COALESCE(raw_transcription, transcription) AS raw_transcription,
               audio_path, ai_status
        FROM transcriptions
        WHERE {" AND ".join(filters)}
        ORDER BY timestamp DESC, id DESC
        LIMIT ?
        """,
        values,
    ).fetchall()
    return list(reversed(rows))


def post_json(url: str, payload: dict, timeout: float) -> dict:
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def polish_text(
    base_url: str,
    model: str,
    text: str,
    keyterms: list[str],
    replacements: dict[str, str],
    memory: dict[str, collections.Counter],
    timeout: float,
) -> str:
    base = base_url.rstrip("/")
    top_terms = ", ".join(term for term, _ in memory["terms"].most_common(14)) or "none"
    suggestions = "; ".join(f'"{src}" -> "{dst}"' for (src, dst), _ in memory["suggestions"].most_common(10))
    suggestions = suggestions or "none"
    replacement_lines = "; ".join(f'"{src}" -> "{dst}"' for src, dst in sorted(replacements.items())) or "none"
    keyterm_lines = ", ".join(keyterms[:80]) or "none"

    system = f"""
You polish speech-to-text output. Return ONLY the polished text.

Core rules:
- Preserve the user's intent, details, constraints, language, numbers, URLs, emails, commands, filenames, and product names.
- Remove fillers and obvious self-corrections. Improve punctuation and paragraph structure.
- Fix speech-to-text mistakes only when context makes the intended wording clear.
- Do not invent facts, answers, or conclusions.

<local_learning_memory>
Top terms: {top_terms}
Candidate corrections: {suggestions}
For candidate corrections, the right side is canonical. Replace the left side only when the same domain is clear.
</local_learning_memory>

<vocabulary_hints>
{keyterm_lines}
</vocabulary_hints>

<replacement_hints>
{replacement_lines}
</replacement_hints>
""".strip()

    payload = {
        "model": model,
        "temperature": 0.1,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": text},
        ],
    }
    body = post_json(f"{base}/chat/completions", payload, timeout)
    return clean_polish(body["choices"][0]["message"]["content"], text)


def transcribe_audio(base_url: str, model: str, audio_path: pathlib.Path, timeout: float) -> str:
    base = base_url.rstrip("/")
    endpoint = f"{base}/v1/audio/transcriptions" if not base.endswith("/v1") else f"{base}/audio/transcriptions"
    boundary = f"----SapoWhisperReplay{uuid.uuid4().hex}"
    audio_type = mimetypes.guess_type(audio_path.name)[0] or "audio/wav"
    parts = [
        form_field(boundary, "model", model),
        form_field(boundary, "response_format", "json"),
        file_field(boundary, "file", audio_path, audio_type),
        f"--{boundary}--\r\n".encode("utf-8"),
    ]
    request = urllib.request.Request(
        endpoint,
        data=b"".join(parts),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload.get("text", "").strip()


def form_field(boundary: str, name: str, value: str) -> bytes:
    return (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
        f"{value}\r\n"
    ).encode("utf-8")


def file_field(boundary: str, name: str, path: pathlib.Path, content_type: str) -> bytes:
    header = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{name}"; filename="{path.name}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n"
    ).encode("utf-8")
    return header + path.read_bytes() + b"\r\n"


def clean_polish(value: str, raw_text: str) -> str:
    text = value.strip()
    if text.startswith("```") and text.endswith("```"):
        text = "\n".join(text.splitlines()[1:-1]).strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in {'"', "'"}:
        text = text[1:-1].strip()
    return text or raw_text.strip()


def evaluate_guard(raw: str, polished: str, keyterms: list[str]) -> tuple[bool, list[str]]:
    reasons = []
    raw_len = max(1, len(raw.strip()))
    ratio = len(polished.strip()) / raw_len
    if ratio < 0.45 or ratio > 2.2:
        reasons.append(f"length_ratio={ratio:.2f}")

    raw_numbers = number_tokens(raw)
    polished_numbers = number_tokens(polished)
    if not is_subsequence(raw_numbers, polished_numbers):
        reasons.append("numbers_changed")

    for anchor in url_email_tokens(raw):
        if anchor not in polished:
            reasons.append("url_or_email_missing")
            break

    for term in keyterms:
        if len(term) < 3:
            continue
        if contains_folded(raw, term) and not contains_folded(polished, term):
            reasons.append("vocabulary_missing")
            break

    return not reasons, reasons


def number_tokens(text: str) -> list[str]:
    return re.findall(r"(?<![A-Za-z0-9@/.-])\d+(?:[.,:]\d+)*(?![A-Za-z0-9@/.-])", text)


def url_email_tokens(text: str) -> list[str]:
    return re.findall(r"\b[\w.+-]+@[\w.-]+\.\w+\b|https?://\S+|\b[\w.-]+\.\w{2,}\b", text)


def is_subsequence(expected: list[str], actual: list[str]) -> bool:
    index = 0
    for token in actual:
        if index < len(expected) and token == expected[index]:
            index += 1
    return index == len(expected)


def contains_folded(text: str, term: str) -> bool:
    return normalize(term) in normalize(text)


def normalize(text: str) -> str:
    return re.sub(r"[\s._,-]+", " ", text.casefold()).strip()


def record_memory(memory: dict[str, collections.Counter], raw: str, corrected: str, polished: str) -> None:
    for term in extract_terms(polished):
        memory["terms"][term] += 1
    for source, target in KNOWN_CORRECTIONS:
        if contains_folded(raw, source) and contains_folded(polished, target):
            memory["suggestions"][(source, target)] += 1
        elif contains_folded(corrected, target) and contains_folded(polished, target):
            memory["suggestions"][(source, target)] += 0


def extract_terms(text: str) -> list[str]:
    patterns = [
        r"\b[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+\b",
        r"(?<![A-Za-z0-9])\.[A-Za-z0-9_-]+\b",
        r"\b[A-Z]{2,}(?:\s+[A-Z]{2,})?\b",
        r"\b(?:git|npm|pnpm|swift|xcodebuild|make|curl|docker|kubectl|ssh)\s+[A-Za-z0-9_./:-]+",
    ]
    raw_terms = []
    for pattern in patterns:
        raw_terms.extend(re.findall(pattern, text))
    richer_keys = {
        token.casefold()
        for term in raw_terms
        if any(symbol in term for symbol in ".-/")
        for token in re.findall(r"[A-Za-z0-9]+", term)
    }
    allowed_acronyms = {
        "api",
        "api rest",
        "ci",
        "cli",
        "http",
        "https",
        "json",
        "llm",
        "pr",
        "rest api",
        "sql",
        "stt",
        "tts",
        "url",
        "uuid",
        "vps",
    }
    standalone_extension_noise = {
        ".css",
        ".csv",
        ".html",
        ".js",
        ".json",
        ".jsx",
        ".md",
        ".mp3",
        ".mp4",
        ".py",
        ".sql",
        ".swift",
        ".ts",
        ".tsx",
        ".txt",
        ".wav",
        ".yaml",
        ".yml",
    }
    command_follower_noise = {
        "a",
        "al",
        "con",
        "de",
        "del",
        "el",
        "en",
        "es",
        "la",
        "las",
        "lo",
        "los",
        "para",
        "por",
        "que",
        "sin",
        "un",
        "una",
        "y",
    }
    seen = set()
    terms = []
    for match in raw_terms:
        key = normalize(match)
        if not key or key in {"ai", "ia", "ok"}:
            continue
        if match.casefold() in standalone_extension_noise:
            continue
        parts = key.split(maxsplit=1)
        if (
            len(parts) == 2
            and parts[0] in {"git", "npm", "pnpm", "swift", "xcodebuild", "make", "curl", "docker", "kubectl", "ssh"}
            and parts[1] in command_follower_noise
        ):
            continue
        if re.fullmatch(r"\d+(?:[.:-]\d+)+", match):
            continue
        if match.isupper() and len(match) > 3 and key in richer_keys:
            continue
        if match.isupper() and not any(symbol in match for symbol in ".-/") and key not in allowed_acronyms:
            continue
        if key not in seen:
            seen.add(key)
            terms.append(match)
    return terms[:24]


def relative_audio_path(value: str | None) -> pathlib.Path | None:
    if not value:
        return None
    path = pathlib.Path(value)
    if path.is_absolute():
        return path
    return DEFAULT_APP_SUPPORT / path


def main() -> int:
    args = parse_args()
    keyterms, replacements = load_vocabulary(args.vocabulary if args.vocabulary.exists() else None)
    rows = fetch_rows(args.db, args.limit, args.min_chars, args.engine_contains)
    memory = {"terms": collections.Counter(), "suggestions": collections.Counter()}
    metrics = collections.Counter()
    latencies: list[float] = []
    samples = []

    for row in rows:
        metrics["rows_seen"] += 1
        raw = row["raw_transcription"] or row["transcription"]
        source = "history_text"
        if args.retranscribe_audio:
            audio_path = relative_audio_path(row["audio_path"])
            if audio_path and audio_path.exists():
                with contextlib.suppress(Exception):
                    raw = transcribe_audio(args.stt_base_url, args.stt_model, audio_path, args.timeout)
                    source = "audio_retranscribed"
                    metrics["audio_retranscribed"] += 1
            if source != "audio_retranscribed":
                metrics["audio_missing_or_failed"] += 1

        corrected = apply_recognition_corrections(raw, keyterms, replacements)
        started = time.monotonic()
        try:
            polished = polish_text(
                args.polish_base_url,
                args.polish_model,
                corrected,
                keyterms,
                replacements,
                memory,
                args.timeout,
            )
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, KeyError, json.JSONDecodeError) as error:
            metrics["provider_errors"] += 1
            if args.print_samples:
                samples.append({"id": row["id"], "error": str(error)})
            continue
        latencies.append(time.monotonic() - started)

        accepted, reasons = evaluate_guard(corrected, polished, keyterms)
        if accepted:
            metrics["accepted"] += 1
            record_memory(memory, raw, corrected, polished)
        else:
            metrics["guard_rejected"] += 1
            for reason in reasons:
                metrics[f"reject_{reason}"] += 1

        if polished != corrected:
            metrics["changed"] += 1
        metrics[f"source_{source}"] += 1

        if args.print_samples:
            samples.append(
                {
                    "id": row["id"],
                    "source": source,
                    "accepted": accepted,
                    "reasons": reasons,
                    "raw_preview": raw[:240],
                    "polished_preview": polished[:240],
                }
            )

    result = {
        "history_db": str(args.db),
        "rows_requested": args.limit,
        "metrics": dict(metrics),
        "avg_polish_seconds": round(sum(latencies) / len(latencies), 3) if latencies else None,
        "top_terms": memory["terms"].most_common(15),
        "suggestions": [
            {"from": source, "to": target, "count": count}
            for (source, target), count in memory["suggestions"].most_common(20)
            if count > 0
        ],
    }
    if args.print_samples:
        result["samples"] = samples

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"Rows processed: {metrics['rows_seen']}")
        print(f"Accepted polish: {metrics['accepted']}")
        print(f"Guard rejected: {metrics['guard_rejected']}")
        print(f"Changed text: {metrics['changed']}")
        print(f"Provider errors: {metrics['provider_errors']}")
        if args.retranscribe_audio:
            print(f"Audio retranscribed: {metrics['audio_retranscribed']}")
            print(f"Audio missing/failed: {metrics['audio_missing_or_failed']}")
        print(f"Average polish seconds: {result['avg_polish_seconds']}")
        print("Top learned terms:", ", ".join(term for term, _ in result["top_terms"]) or "none")
        print(
            "Suggestions:",
            "; ".join(f"{item['from']} -> {item['to']} x{item['count']}" for item in result["suggestions"]) or "none",
        )
    return 0 if metrics["provider_errors"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
