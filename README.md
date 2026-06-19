# 🐸 SapoWhisper

SapoWhisper is a small macOS menu bar app for fast speech-to-text.
Press `Option + Space`, speak, press it again, and the transcript is pasted into the app you were using.

## ✨ Highlights

- ⚡ Global hotkey recording with a compact floating overlay.
- 📋 Auto-paste via clipboard + `Cmd+V`; no live typing while you speak.
- 🧠 Local and cloud transcription engines.
- 🗂️ Searchable history with saved audio, replay, download, pinning, and re-transcription.
- 🎙️ Preferred microphone sync, route-change resilience, gain control, and optional auto-ducking.
- 🪄 Optional AI polish through any OpenAI-compatible provider (OpenRouter by default) with a built-in fidelity guard and an optional output language (English/Spanish) that translates faithfully.
- 🔐 Guided setup for Microphone and Accessibility permissions.

## 🎧 Transcription Engines

| Engine | Mode | Best for |
|---|---|---|
| WhisperKit | Local | Private offline transcription. |
| Local AI Server (NVIDIA) | Batch LAN | Offloading transcription to a local NVIDIA GPU server with an OpenAI-style STT endpoint. |
| Deepgram Nova-3 | Batch | High-accuracy cloud transcription. |
| Deepgram Flux Live | Realtime | Low-latency streaming with WAV backup. |
| ElevenLabs Scribe v2 | Batch | Accurate Scribe transcription. |
| ElevenLabs Scribe Realtime v2 | Realtime | Low-latency Scribe with committed-text buffering. |

Cloud and optional local-server credentials are stored locally on the user's Mac. Never commit API keys, exported recordings, logs, DMGs, archives, or signing files.

### Local AI Server Fixtures

`TestAssets/LocalAITranscription/` contains public synthetic WAV fixtures for local STT testing:

- `sample-1m.wav`
- `sample-2m.wav`
- `sample-3m.wav`
- `sample-6m.wav`

Use `scripts/local_stt_benchmark.sh` with any OpenAI-compatible local STT server:

```bash
BASE_URL=http://YOUR_SERVER_IP:8000 \
MODEL_ID=rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo \
AUDIO_PATH=TestAssets/LocalAITranscription/sample-1m.wav \
scripts/local_stt_benchmark.sh
```

## 🧰 Requirements

- macOS 14.0 or later
- Apple Silicon Mac (`arm64`, M1 and newer)
- Xcode with command line tools
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
- `make ci-check`: lint + Debug build + unit tests.
- `make release-check`: lint + Release build + bundle size audit.
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

Current arm64 cleanup baseline:

- `.app`: 29,624 KB -> 20,624 KB (`-30.38%`)
- executable: 17,708 KB -> 8,712 KB (`-50.80%`)
- local compressed test DMG: about 13-14 MB

Local test DMGs are usually ad-hoc signed with hardened runtime. Do not present them as notarized unless notarization was explicitly verified.

## 🧪 Tests

Unit tests live in `SapoWhisperTests` and cover pure logic: the AI polish fidelity guard, failure mapping, engine migration, and settings transfer.

```bash
make test
```

Use `make ci-check` (lint + build + tests) as the main local gate and `make release-check` before packaging.

## 🧼 Public Repo Safety

Tracked and public-safe:

- Source code, app assets, localized strings, sound effects, entitlements, Xcode project metadata, shared scheme, `Package.resolved`, Makefile, scripts, README, changelog, contributing notes, security notes, and license.

Ignored and local/private:

- `CLAUDE.md`, `DMG/`, `docs/`, `.agents/`, `.claude/`, `.codex/`, `skills-lock.json`, `xcuserdata/`, `build/`, logs, crash reports, credentials, `.env*`, exported audio, DMGs, archives, and local signing files.

Before opening a PR:

```bash
make ci-check
git diff --check
```

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

MIT
