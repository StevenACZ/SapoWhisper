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
import ipaddress
import json
import mimetypes
import pathlib
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from stt_benchmark_vocabulary import apply_recognition_corrections, load_vocabulary, recognition_variants  # noqa: E402


DEFAULT_APP_SUPPORT = pathlib.Path.home() / "Library/Application Support/SapoWhisper"
DEFAULT_DB = DEFAULT_APP_SUPPORT / "history.db"
DEFAULT_VOCABULARY = DEFAULT_APP_SUPPORT / "vocabulary.json"
DEFAULT_POLISH_BASE_URL = "http://localhost:8081/v1"
DEFAULT_STT_BASE_URL = "http://localhost:8000"
DEFAULT_STT_MODEL = "rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo"

KNOWN_CORRECTIONS = [
    ("deep commit", "git commit"),
    ("deep comment", "git commit"),
    ("deep comet", "git commit"),
    ("dip comment", "git commit"),
    ("deep push", "git push"),
    ("dip push", "git push"),
    ("kit push", "git push"),
    ("cloud md", "CLAUDE.md"),
    ("cloud dot md", "CLAUDE.md"),
    ("claude dot md", "CLAUDE.md"),
    ("clauco", "Claude Code"),
    ("cloud code", "Claude Code"),
    ("claud code", "Claude Code"),
    ("ditgram", "Deepgram"),
    ("ali test", "REST API"),
    ("restapi", "REST API"),
    ("pool request", "pull request"),
    ("local ya server", "Local AI Server"),
    ("localia server", "Local AI Server"),
]

DEFAULT_CORRECTION_TARGETS = [
    "AI polish",
    "AGENTS.md",
    "API REST",
    "CLAUDE.md",
    "Claude Code",
    "Deepgram",
    "Local AI Server",
    "REST API",
    "git commit",
    "git push",
    "pull request",
]


class ReplayInputError(Exception):
    """An input failure with a private detail that is opt-in to display."""

    def __init__(self, public_message: str, private_detail: str):
        super().__init__(public_message)
        self.public_message = public_message
        self.private_detail = private_detail


def is_loopback_host(hostname: str) -> bool:
    normalized = hostname.casefold()
    if normalized in {"localhost", "127.0.0.1", "::1"}:
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


def validate_provider_url(value: str, field_name: str) -> urllib.parse.SplitResult:
    public_message = "Provider URL must use http(s) without credentials, query, or fragment."
    if not value or any(character.isspace() or ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise ReplayInputError(public_message, f"{field_name} contains whitespace or control characters")

    try:
        parsed = urllib.parse.urlsplit(value)
        hostname = parsed.hostname
        parsed.port
    except ValueError as error:
        raise ReplayInputError(public_message, f"{field_name} is malformed: {error}") from error

    if (
        parsed.scheme.casefold() not in {"http", "https"}
        or not parsed.netloc
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or "?" in value
        or "#" in value
    ):
        raise ReplayInputError(public_message, f"{field_name} is not a permitted provider URL")
    return parsed


def validate_replay_transport(args: argparse.Namespace) -> None:
    polish_url = validate_provider_url(args.polish_base_url, "polish-base-url")
    stt_url = validate_provider_url(args.stt_base_url, "stt-base-url")
    remote_urls = [polish_url] if not is_loopback_host(polish_url.hostname) else []
    if args.retranscribe_audio:
        if not is_loopback_host(stt_url.hostname):
            remote_urls.append(stt_url)
    if any(url.scheme.casefold() != "https" for url in remote_urls):
        raise ReplayInputError(
            "Remote private data requires HTTPS.",
            "a non-loopback replay endpoint used plaintext HTTP",
        )
    if remote_urls and not args.allow_remote_private_data:
        raise ReplayInputError(
            "Remote private data requires --allow-remote-private-data.",
            "a non-loopback replay endpoint was selected without explicit private-data authorization",
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=pathlib.Path, default=DEFAULT_DB)
    parser.add_argument("--vocabulary", type=pathlib.Path, default=DEFAULT_VOCABULARY)
    parser.add_argument("--limit", type=int, default=25)
    parser.add_argument("--min-chars", type=int, default=40)
    parser.add_argument("--engine-contains", default="")
    parser.add_argument("--since", default="", help="Inclusive ISO timestamp lower bound, e.g. 2026-06-20T00:00:00Z")
    parser.add_argument("--until", default="", help="Exclusive ISO timestamp upper bound, e.g. 2026-06-21T00:00:00Z")
    parser.add_argument("--polish-base-url", default=DEFAULT_POLISH_BASE_URL)
    parser.add_argument("--polish-model", required=True, help="Model identifier; required to avoid an implicit model choice")
    parser.add_argument("--stt-base-url", default=DEFAULT_STT_BASE_URL)
    parser.add_argument("--stt-model", default=DEFAULT_STT_MODEL)
    parser.add_argument("--timeout", type=float, default=35)
    parser.add_argument("--retranscribe-audio", action="store_true")
    parser.add_argument(
        "--allow-remote-private-data",
        action="store_true",
        help="authorize sending local transcript/audio data to a non-loopback endpoint",
    )
    parser.add_argument("--print-samples", action="store_true")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def fetch_rows(
    db_path: pathlib.Path,
    limit: int,
    min_chars: int,
    engine_contains: str,
    since: str,
    until: str,
) -> list[sqlite3.Row]:
    if not db_path.exists():
        raise ReplayInputError("Unable to read local replay inputs.", f"History DB not found: {db_path}")

    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    filters = ["status = 'completed'", "length(COALESCE(raw_transcription, transcription)) >= ?"]
    values: list[object] = [min_chars]
    if engine_contains:
        filters.append("engine LIKE ?")
        values.append(f"%{engine_contains}%")
    if since:
        filters.append("timestamp >= ?")
        values.append(since)
    if until:
        filters.append("timestamp < ?")
        values.append(until)
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
    validate_provider_url(url, "provider URL")
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
    timeout: float,
) -> str:
    validate_provider_url(base_url, "polish-base-url")
    base = base_url.rstrip("/")
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
Accepted corrections are provided only through replacement hints below.
Never create or recommend vocabulary/keyterms. Never inject a term when the transcript does not clearly point to it.
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
    validate_provider_url(base_url, "stt-base-url")
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


def url_email_tokens(text: str) -> list[str]:
    return re.findall(r"\b[\w.+-]+@[\w.-]+\.\w+\b|https?://\S+|\bwww\.\S+", text)


def contains_folded(text: str, term: str) -> bool:
    return normalize(term) in normalize(text)


def normalize(text: str) -> str:
    return re.sub(r"[\s._,-]+", " ", text.casefold()).strip()


def record_correction_suggestions(
    memory: collections.Counter,
    raw: str,
    corrected: str,
    polished: str,
    keyterms: list[str],
    replacements: dict[str, str],
) -> None:
    for source, target in KNOWN_CORRECTIONS:
        if contains_folded(raw, source) and contains_folded(polished, target):
            memory[(source, target)] += 1
        elif contains_folded(corrected, target) and contains_folded(polished, target):
            memory[(source, target)] += 0

    existing_sources = {normalize(source) for source in replacements}
    targets = unique(keyterms + list(replacements.values()) + DEFAULT_CORRECTION_TARGETS)
    for target in targets:
        if not is_safe_correction_target(target):
            continue
        if contains_folded(raw, target):
            continue
        if not (contains_folded(corrected, target) or contains_folded(polished, target)):
            continue
        for variant in recognition_variants(target):
            source_key = normalize(variant)
            if len(source_key) < 4 or source_key == normalize(target) or source_key in existing_sources:
                continue
            if contains_folded(raw, variant):
                memory[(variant, target)] += 1
                break


def is_safe_correction_target(value: str) -> bool:
    alnum_count = sum(character.isalnum() for character in value)
    if alnum_count < 3:
        return False
    tokens = re.findall(r"[^\W_]+", value)
    if len(tokens) > 1:
        return True
    if any(character in ".-_" or character.isdigit() for character in value):
        return True
    if any(character.isupper() for character in value):
        return True
    return len(value) >= 8


def unique(values: list[str]) -> list[str]:
    seen = set()
    result = []
    for value in values:
        key = normalize(value)
        if not key or key in seen:
            continue
        seen.add(key)
        result.append(value)
    return result


def relative_audio_path(value: str | None) -> pathlib.Path | None:
    if not value:
        return None
    path = pathlib.Path(value)
    if path.is_absolute():
        return path
    return DEFAULT_APP_SUPPORT / path


def main() -> int:
    args = parse_args()
    try:
        validate_replay_transport(args)
        keyterms, replacements = load_vocabulary(args.vocabulary if args.vocabulary.exists() else None)
        rows = fetch_rows(args.db, args.limit, args.min_chars, args.engine_contains, args.since, args.until)
    except ReplayInputError as error:
        print(
            f"Error: {error.private_detail if args.print_samples else error.public_message}",
            file=sys.stderr,
        )
        return 1
    except Exception as error:
        private_detail = f"Could not load replay inputs (vocabulary={args.vocabulary}, db={args.db}): {error}"
        print(
            f"Error: {private_detail if args.print_samples else 'Unable to read local replay inputs.'}",
            file=sys.stderr,
        )
        return 1
    correction_suggestions = collections.Counter()
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
                args.timeout,
            )
        except Exception as error:
            metrics["provider_errors"] += 1
            if args.print_samples:
                samples.append({"id": row["id"], "error": str(error)})
            continue
        latencies.append(time.monotonic() - started)

        accepted, reasons = evaluate_guard(corrected, polished, keyterms)
        if accepted:
            metrics["accepted"] += 1
            record_correction_suggestions(correction_suggestions, raw, corrected, polished, keyterms, replacements)
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

    suggestions = [
        {"from": source, "to": target, "count": count}
        for (source, target), count in correction_suggestions.most_common(20)
        if count > 0
    ]
    result = {
        "history_source": "local",
        "rows_requested": args.limit,
        "metrics": dict(metrics),
        "avg_polish_seconds": round(sum(latencies) / len(latencies), 3) if latencies else None,
        "suggestion_pair_count": len(suggestions),
        "suggestion_occurrence_count": sum(item["count"] for item in suggestions),
    }
    if args.print_samples:
        result["history_db"] = str(args.db)
        result["suggestions"] = suggestions
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
        print(
            "Correction candidates:",
            f"{result['suggestion_pair_count']} pair(s), {result['suggestion_occurrence_count']} occurrence(s)",
        )
        if args.print_samples:
            print(
                "Private suggestions:",
                "; ".join(f"{item['from']} -> {item['to']} x{item['count']}" for item in suggestions) or "none",
            )
    return 0 if metrics["provider_errors"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
