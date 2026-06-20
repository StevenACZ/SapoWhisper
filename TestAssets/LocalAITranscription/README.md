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
- `technical/es/short.txt` / `technical/es/short.wav`: short Spanish technical dictation fixture.
- `technical/es/medium.txt` / `technical/es/medium.wav`: medium Spanish technical dictation fixture.

All WAV files are `16 kHz`, mono, `pcm_s16le`, matching SapoWhisper's normal recording format.

## Benchmark

Run the public benchmark script without storing results in the repo:

```bash
BASE_URL=http://YOUR_SERVER_IP:8000 \
MODEL_ID=rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo \
AUDIO_PATH=TestAssets/LocalAITranscription/longform/sample-1m.wav \
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

- `global_similarity`: word-level transcript similarity.
- `critical_term_score`: exact canonical-form matches for keyterms present in the source transcript.
- `weighted_score`: 35% global similarity plus 65% critical-term score.
- `missing_critical_terms`: canonical terms still missing from the candidate transcript.

When `VOCABULARY_PATH` is set, the script reports both raw and locally corrected scores, mirroring SapoWhisper's conservative pre-polish vocabulary correction layer.

Cloud batch fixtures can be checked with the same metrics:

```bash
ENGINE=deepgram \
LANGUAGE=en \
AUDIO_PATH=TestAssets/LocalAITranscription/technical/en/short.wav \
TRANSCRIPT_PATH=TestAssets/LocalAITranscription/technical/en/short.txt \
VOCABULARY_PATH=TestAssets/LocalAITranscription/technical/vocabulary.json \
scripts/cloud_stt_benchmark.sh
```

`scripts/cloud_stt_benchmark.sh` reads ignored local credentials from `.env` (`DEEPGRAM_API_KEY`, `ELEVENLABS_API_KEY`) and supports `ENGINE=deepgram` for Nova-3 batch or `ENGINE=elevenlabs` for Scribe v2 batch.

Use the longer clips to compare throughput and queue behavior. For fair model comparisons, run one cold request first, then measure several warm requests.

Speaches requires the model to be installed first. If the benchmark returns a 404 saying the model is not installed, download it once:

```bash
python3 - <<'PY'
from urllib.parse import quote
model = "rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo"
print(f"curl -X POST http://YOUR_SERVER_IP:8000/v1/models/{quote(model, safe='')}")
PY
```
