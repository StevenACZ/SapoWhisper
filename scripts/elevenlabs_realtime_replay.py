import argparse
import json
import os
import pathlib
import sys
import threading
import time
import urllib.parse
import wave

from stt_benchmark_vocabulary import (
    ELEVENLABS_REALTIME_SAMPLE_RATE,
    elevenlabs_realtime_chunk_messages,
    elevenlabs_realtime_keyterms,
    elevenlabs_realtime_query,
    initial_prompt_text,
    load_vocabulary_settings,
)

ERROR_TYPES = {
    "auth_error",
    "quota_exceeded",
    "rate_limited",
    "commit_throttled",
    "queue_overflow",
    "resource_exhausted",
    "session_time_limit_exceeded",
    "chunk_size_exceeded",
    "input_error",
    "transcriber_error",
    "unaccepted_terms",
    "error",
}
CHUNK_SECONDS = 0.2
FINAL_COMMIT_TIMEOUT_SECONDS = 15.0
COMMIT_QUIET_SECONDS = 2.0


def fail(message):
    print(f"realtime_error={message}", file=sys.stderr)
    raise SystemExit(1)


def read_pcm16_mono(path):
    with wave.open(str(path), "rb") as reader:
        if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (1, 2, ELEVENLABS_REALTIME_SAMPLE_RATE):
            fail("audio_not_pcm16_mono_16khz")
        return reader.readframes(reader.getnframes())


class Receiver(threading.Thread):
    def __init__(self, connection):
        super().__init__(daemon=True)
        self.connection = connection
        self.condition = threading.Condition()
        self.segments = []
        self.commit_times = []
        self.error_type = None
        self.closed = False

    def run(self):
        try:
            for raw in self.connection:
                try:
                    payload = json.loads(raw)
                except ValueError:
                    continue
                kind = payload.get("message_type") or payload.get("type") or ""
                with self.condition:
                    if kind in {"committed_transcript", "committed_transcript_with_timestamps"}:
                        text = (payload.get("text") or "").strip()
                        if text and (not self.segments or self.segments[-1] != text):
                            self.segments.append(text)
                            self.commit_times.append(time.monotonic())
                    elif kind in ERROR_TYPES:
                        self.error_type = kind
                    self.condition.notify_all()
        except Exception:
            pass
        with self.condition:
            self.closed = True
            self.condition.notify_all()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--vocabulary", default="")
    parser.add_argument("--language-code", default="")
    parser.add_argument("--no-verbatim", default="1")
    parser.add_argument("--previous-text", default="1")
    parser.add_argument("--pace", default="0")
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()

    api_key = os.environ.get("ELEVENLABS_API_KEY", "")
    if not api_key:
        fail("missing_api_key")

    from websockets.sync.client import connect

    keyterms, replacements, include_replacement_values = load_vocabulary_settings(arguments.vocabulary or None)
    query = elevenlabs_realtime_query(
        arguments.language_code or None,
        elevenlabs_realtime_keyterms(keyterms, replacements, include_replacement_values),
        no_verbatim=arguments.no_verbatim != "0",
    )
    previous_text = initial_prompt_text(keyterms, replacements, include_replacement_values) if arguments.previous_text != "0" else ""
    messages = elevenlabs_realtime_chunk_messages(read_pcm16_mono(arguments.audio), previous_text)
    url = "wss://api.elevenlabs.io/v1/speech-to-text/realtime?" + urllib.parse.urlencode(query)

    started_at = time.monotonic()
    try:
        connection = connect(url, additional_headers={"xi-api-key": api_key}, open_timeout=15)
    except Exception as error:
        status_code = getattr(getattr(error, "response", None), "status_code", None)
        fail(f"connect_failed:{type(error).__name__}" + (f":{status_code}" if status_code else ""))

    with connection:
        receiver = Receiver(connection)
        receiver.start()
        committed_before_final = 0
        last_sent_at = started_at
        for index, message in enumerate(messages):
            if arguments.pace == "1":
                delay = started_at + index * CHUNK_SECONDS - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
            if message["commit"]:
                with receiver.condition:
                    committed_before_final = len(receiver.segments)
            try:
                connection.send(json.dumps(message))
            except Exception as error:
                fail(f"send_failed:{type(error).__name__}")
            last_sent_at = time.monotonic()

        deadline = last_sent_at + FINAL_COMMIT_TIMEOUT_SECONDS
        with receiver.condition:
            while receiver.error_type is None and not receiver.closed:
                now = time.monotonic()
                if len(receiver.segments) > committed_before_final:
                    wait_until = min(deadline, receiver.commit_times[-1] + COMMIT_QUIET_SECONDS)
                else:
                    wait_until = deadline
                if now >= wait_until:
                    break
                receiver.condition.wait(timeout=wait_until - now)
            segments = list(receiver.segments)
            commit_times = list(receiver.commit_times)
            error_type = receiver.error_type

    if error_type:
        fail(error_type)

    final_commit_seconds = None
    if len(segments) > committed_before_final:
        final_commit_seconds = round(commit_times[-1] - last_sent_at, 3)
    pathlib.Path(arguments.output).write_text(
        json.dumps(
            {
                "text": " ".join(segments).strip(),
                "final_commit_seconds": final_commit_seconds,
                "chunks_sent": len(messages),
            }
        )
    )
    finished_at = commit_times[-1] if commit_times else time.monotonic()
    print(f"{finished_at - started_at:.3f}", end="")


if __name__ == "__main__":
    main()
