# Local AI Transcription Fixtures

Public benchmark fixtures for SapoWhisper's `Local AI Server (NVIDIA)` engine.

## Files

- `longform/source-transcript.txt`: source narration text.
- `longform/sample-1m.wav`: first 1 minute of the fixture.
- `longform/sample-2m.wav`: first 2 minutes of the fixture.
- `longform/sample-3m.wav`: first 3 minutes of the fixture.
- `longform/sample-6m.wav`: full 6 minute fixture.
- `technical/vocabulary.json`: public keyterms used for technical vocabulary scoring.
- `technical/en/short.txt` / `technical/en/short.wav`: short English technical dictation fixture.
- `technical/en/medium.txt` / `technical/en/medium.wav`: medium English technical dictation fixture.
- `technical/es/synthetic-public.txt` / `technical/es/synthetic-public.wav`: Spanish technical fixture generated with the macOS Paulina system voice from the tracked authored transcript.

All WAV files are `16 kHz`, mono, `pcm_s16le`, matching SapoWhisper's normal recording format.

## Benchmark

Run the public benchmark script without storing results in the repo. Scripts never load `.env` automatically; export any endpoint or credential explicitly in the current shell.

```bash
BASE_URL=http://YOUR_SERVER_IP:8000 \
MODEL_ID=rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo \
AUDIO_PATH=TestAssets/LocalAITranscription/longform/sample-1m.wav \
ALLOW_EMPTY_VOCABULARY=1 \
scripts/local_stt_benchmark.sh
```

Scored technical fixture:

```bash
BASE_URL=http://YOUR_SERVER_IP:8000 \
MODEL_ID=rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo \
AUDIO_PATH=TestAssets/LocalAITranscription/technical/en/short.wav \
TRANSCRIPT_PATH=TestAssets/LocalAITranscription/technical/en/short.txt \
VOCABULARY_PATH=TestAssets/LocalAITranscription/technical/vocabulary.json \
scripts/local_stt_benchmark.sh
```

When `TRANSCRIPT_PATH` is set, the script reports:

- `word_error_rate` and `word_errors`.
- Pass/fail gates for canonical critical terms and ordered digit runs.
- Aggregate expected/found/missing/unexpected occurrence counts.
- A lexicographic rank that never lets a lower WER compensate for a failed hard gate.

When `VOCABULARY_PATH` is set, the script reports both raw and locally corrected aggregate scores, mirroring SapoWhisper's conservative pre-polish vocabulary correction layer. Exact transcripts, terms, paths, and digit values remain hidden unless `PRINT_TEXT=1` is explicitly set for a private local run.

Cloud batch fixtures can be checked with the same metrics:

```bash
export DEEPGRAM_API_KEY='your-key'
ENGINE=deepgram \
LANGUAGE=en \
AUDIO_PATH=TestAssets/LocalAITranscription/technical/en/short.wav \
TRANSCRIPT_PATH=TestAssets/LocalAITranscription/technical/en/short.txt \
VOCABULARY_PATH=TestAssets/LocalAITranscription/technical/vocabulary.json \
scripts/cloud_stt_benchmark.sh
```

`scripts/cloud_stt_benchmark.sh` reads credentials only from the current process environment and supports `ENGINE=deepgram` for Nova-3 batch or `ENGINE=elevenlabs` for Scribe v2 batch. Its default output contains aggregate metrics only.

Use the longer clips to compare throughput and queue behavior. For fair model comparisons, run one cold request first, then measure several warm requests.

## Synthetic Spanish Fixture

`technical/es/synthetic-public.wav` contains no human voice. It includes controlled filler words and technical terms, while `technical/es/synthetic-public.txt` keeps the expected canonical spelling. The audio gate pins the hash and WAV format of every tracked fixture so replacing an allowlisted filename cannot silently publish another recording.

Speaches requires the model to be installed first. If the benchmark returns a 404 saying the model is not installed, download it once:

```bash
python3 - <<'PY'
from urllib.parse import quote
model = "rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo"
print(f"curl -X POST http://YOUR_SERVER_IP:8000/v1/models/{quote(model, safe='')}")
PY
```
