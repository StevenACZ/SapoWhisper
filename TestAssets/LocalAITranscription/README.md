# Local AI Transcription Fixtures

Public benchmark fixtures for SapoWhisper's `Local AI Server (NVIDIA)` engine.

## Files

- `source-transcript.txt`: source narration text.
- `sample-1m.wav`: first 1 minute of the fixture.
- `sample-2m.wav`: first 2 minutes of the fixture.
- `sample-3m.wav`: first 3 minutes of the fixture.
- `sample-6m.wav`: full 6 minute fixture.

All WAV files are `16 kHz`, mono, `pcm_s16le`, matching SapoWhisper's normal recording format.

## Benchmark

Run the public benchmark script without storing results in the repo:

```bash
BASE_URL=http://YOUR_SERVER_IP:8000 \
MODEL_ID=rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo \
AUDIO_PATH=TestAssets/LocalAITranscription/sample-1m.wav \
scripts/local_stt_benchmark.sh
```

Use the longer clips to compare throughput and queue behavior. For fair model comparisons, run one cold request first, then measure several warm requests.

Speaches requires the model to be installed first. If the benchmark returns a 404 saying the model is not installed, download it once:

```bash
python3 - <<'PY'
from urllib.parse import quote
model = "rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo"
print(f"curl -X POST http://YOUR_SERVER_IP:8000/v1/models/{quote(model, safe='')}")
PY
```
