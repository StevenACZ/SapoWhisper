# 🐸 SapoWhisper

SapoWhisper is a small macOS menu bar app for fast speech-to-text.
Press `Option + Space`, speak, press it again, and the transcript is pasted into the app you were using.

## ✨ Highlights

- ⚡ Global hotkey recording with a compact floating overlay.
- 📋 Auto-paste via clipboard + `Cmd+V`; no live typing while you speak.
- 🧠 Local and cloud transcription engines.
- 🗂️ Searchable history with saved audio, cancelled-recording recovery, replay, download, pinning, and re-transcription.
- 🎙️ Preferred microphone sync, route-change resilience, gain control, and optional auto-ducking.
- 📱 Companion control from Mirador: start or stop SapoWhisper in the iPhone viewer and use the phone as the host microphone without synthetic hotkeys.
- 🎚️ Batch audio upload quality profiles, from ultra-fast compact WAVs to native Float32.
- 🪄 Optional AI polish through any OpenAI-compatible provider (OpenRouter by default) with retry-based fidelity checks and a shared output-language picker for same-language cleanup or a requested target-language translation; source-preserving fallback is path-dependent.
- ✅ Historically tested AI model candidates in Settings, while keeping free-text model IDs for providers that change over time.
- 🔐 Guided setup for Microphone and Accessibility permissions.
- 🔔 One-click in-app updates (Sparkle): a quiet menu notice when a new version ships; installing downloads, verifies the EdDSA signature, and relaunches automatically. The daily check can be turned off in Settings.

## 🎧 Transcription Engines

| Engine | Mode | Best for |
|---|---|---|
| Whisper (Local MLX) | Local | Private offline transcription on Apple Silicon. Large V3 Turbo is the quality default; its 4-bit tier uses less memory, but its quality is not measured in the public scorecard. |
| Local AI Server (NVIDIA) | Batch LAN | Offloading transcription to a local NVIDIA GPU server; faster-whisper Large V3 Turbo is the public-fixture reference. |
| Deepgram Nova-3 | Batch | High-accuracy cloud transcription. |
| Deepgram Flux Live | Realtime | Low-latency streaming with final-tail capture, server-close confirmation, and WAV fallback. |
| ElevenLabs Scribe v2 | Batch | Accurate Scribe transcription. |
| ElevenLabs Scribe Realtime v2 | Realtime | Low-latency Scribe with committed-text buffering. |

Cloud and optional local-server credentials are stored locally on the user's Mac. Never commit API keys, exported recordings, logs, DMGs, archives, or signing files.

Batch engines use the selected microphone upload-quality profile: Ultra fast (16 kHz Int16), Medium by default (24 kHz Int16), High (native rate up to 48 kHz Int16), or Ultra original (native Float32). Realtime engines keep their required 16 kHz Int16 streaming format.

## 🧠 AI Polish Model Guide

The model field always accepts a custom ID. The menu adds tested starting points rather than silently choosing a model:

| Tier | OpenRouter model | Guidance |
|---|---|---|
| Translation candidate | `anthropic/claude-opus-5` | Historical internal screens favored it for translation and difficult rewrites. Long-input qualification is pending, and no reproducible public result manifest is available. |
| Compact candidate | `openai/gpt-5.6-sol` | Preferred candidate for Compact cleanup. Translation and long-input qualification are pending; use the built-in tester before relying on it. |
| Same-language candidate | `qwen/qwen3.8-flash` | Candidate for cleanup when output stays in the spoken language. Translation is not qualified. |
| Fast candidate | `openai/gpt-5.4-nano` | Candidate for quick cleanup. Difficult Compact and translation cases may keep the source text. |
| Experimental candidate | `qwen/qwen3.5-flash-02-23` | Higher fidelity risk; use only for low-stakes same-language cleanup after testing it. |

For Compact cleanup, `openai/gpt-5.6-sol` is the preferred candidate. Translation and long-input qualification remain pending, so run the built-in polish test before enabling it for important dictations.

No small local AI-polish model has qualified yet, so Local Server polish is labeled experimental. This is separate from local speech-to-text: MLX Large V3 Turbo remains the recommended offline transcription model; the 4-bit tier saves resources, but its quality has not been measured here.

See [BENCHMARKS.md](BENCHMARKS.md) for the historical screen scope, known evidence gaps, and promotion gates.

### Local AI Server Fixtures

`TestAssets/LocalAITranscription/` contains the current public fixture set: tracked reference text and previously published, hash-pinned WAV audio. The retired natural-voice Spanish fixture was `technical/es/real-natural.wav` with reference `technical/es/real-natural.txt`; it is not part of the current corpus. The active fixture labels are:

- `longform/sample-1m.wav`
- `longform/sample-2m.wav`
- `longform/sample-3m.wav`
- `longform/sample-6m.wav`
- `technical/en/short.wav` / `technical/en/short.txt`
- `technical/en/medium.wav` / `technical/en/medium.txt`
- `technical/es/synthetic-public.wav` / `technical/es/synthetic-public.txt`

The English and longform WAVs predate the current provenance record, so no synthetic-voice claim is made for them. `technical/es/synthetic-public.wav` was generated with the macOS Paulina system voice from the tracked public text; it contains no human voice or private recording. Exact hashes and formats for these fixtures and the bundled app sounds are enforced by the public-repo gate.

Use `scripts/local_stt_benchmark.sh` with any OpenAI-compatible local STT server:

```bash
BASE_URL=http://YOUR_SERVER_IP:8000 \
MODEL_ID=rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo \
AUDIO_PATH=TestAssets/LocalAITranscription/longform/sample-1m.wav \
ALLOW_EMPTY_VOCABULARY=1 \
scripts/local_stt_benchmark.sh
```

## 🧰 Requirements

- macOS 14.0 or later
- Apple Silicon Mac (`arm64`, M1 and newer)
- Xcode with command line tools
- `gitleaks` (`brew install gitleaks`) for the public-repo safety gate
- Microphone permission
- Accessibility permission for auto-paste

## 🚀 Quick Start

```bash
git clone <repo-url>
cd SapoWhisper
make tools
make ci-check
```

Open `SapoWhisper.xcodeproj` in Xcode and run the `SapoWhisper` scheme.

The tracked project defaults to local signing (`Sign to Run Locally`) so contributors can build without the maintainer's Apple Developer Team ID.

## 🛠️ Developer Workflow

```bash
make format
make lint
make ci-check
```

- `make format`: format changed Swift files with Xcode's bundled `swift-format`.
- `make lint`: lint changed Swift files without editing them.
- `make test`: run the `SapoWhisperTests` unit bundle.
- `make script-tests`: run benchmark contract and redaction tests.
- `make secrets-scan`: scan source plus the exact tracked-audio allowlist (public fixtures and bundled app sounds).
- `make ci-check`: lint + secret/audio scan + script tests + Debug build + unit tests.
- `make release-check`: lint + Release build + size, signature, architecture, content, and private-path checks.
- `make install-dev`: signed Release reinstall to `/Applications` for local UI iteration without resetting macOS permission grants.
- `make format-all` / `make lint-all`: full-repo passes for planned formatting work.

Optional hooks:

```bash
make hooks-install
```

## 📦 Release Builds

Release builds target Apple Silicon only.

```bash
make release-check

scripts/measure_release_bundle.sh \
  build/audit-release/Build/Products/Release/SapoWhisper.app
```

The size script reports the current app, executable, resource, and framework
breakdown; do not reuse historical bundle numbers after dependencies change.

Local test DMGs are usually ad-hoc signed with hardened runtime. Do not present them as notarized unless notarization was explicitly verified.

## 🧪 Tests

Unit tests live in `SapoWhisperTests` and cover the AI polish contracts and model catalog, failure mapping, engine migration, audio upload quality, realtime finalization, replay conversion, and settings transfer. The History replay script is an aggregate/redaction check, not a full live-engine parity test: its transcription request does not reproduce the app's complete recognition prompt, language, or VAD settings.

```bash
make test
```

Use `make ci-check` as the local PR gate and `make release-check` before packaging. This project intentionally has no hosted CI; release verification runs locally on the supported Apple Silicon toolchain.

## 🧼 Public Repo Safety

Tracked and public-safe:

- Source code, app assets, localized strings, hash-pinned public audio fixtures, four bundled app sounds, entitlements, Xcode project metadata, shared scheme, `Package.resolved`, Makefile, scripts, README, benchmark scorecard, changelog, `AGENTS.md`, contributing notes, security notes, and license.

Ignored and local/private:

- `DMG/`, `docs/`, `.agents/`, `.claude/`, `.codex/`, `skills/`, `skills-lock.json`, `scripts/local_polish_model_benchmark.py`, `xcuserdata/`, `build/`, logs, crash reports, credentials, `.env*`, exported audio, DMGs, archives, and local signing files.

Before opening a PR:

```bash
make ci-check
git diff --check
```

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

MIT
