# SapoWhisper

SapoWhisper is a macOS menu bar app that turns speech into text from a global shortcut.
Press `Option + Space`, speak, stop, and the transcript is pasted into the frontmost app.

## Requirements

- macOS 14.0 or later
- Apple Silicon Mac (`arm64`, M1 and newer)
- Xcode with command line tools
- Microphone permission
- Accessibility permission for auto-paste

## Features

- Global hotkey recording with a compact floating overlay.
- Auto-paste into the current app.
- Local transcription with WhisperKit.
- Online transcription with Apple Speech, Google Cloud STT, Deepgram Nova-3, and Deepgram Flux Live.
- Searchable transcription history with saved audio, replay, download, pinning, and re-transcription.
- Guided permission setup for Microphone, Speech Recognition, and Accessibility.
- Preferred microphone sync, route-change resilience, and optional auto-ducking while recording.

## Transcription Engines

| Engine | Mode | Notes |
|---|---|---|
| Apple Speech | Online | No app-specific setup. |
| WhisperKit | Local | Private offline transcription; models download in-app. |
| Google Cloud | Online | Supports Chirp 3 via ADC and API-key fallback. |
| Deepgram Nova-3 | Online | High-accuracy batch transcription. |
| Deepgram Flux Live | Online | Near real-time streaming with local WAV history. |

Cloud API keys and Google credentials are stored locally on the user's Mac. Do not commit credentials, exported recordings, logs, DMGs, or local signing files.

## Quick Start

```bash
git clone <repo-url>
cd SapoWhisper
make tools
make ci-check
```

Open `SapoWhisper.xcodeproj` in Xcode and run the `SapoWhisper` scheme.

The tracked project defaults to local ad-hoc signing (`Sign to Run Locally`) so contributors can build without the maintainer's Apple Developer Team ID. Maintainers should configure Developer ID or Apple Development signing locally when creating release artifacts.

## Daily Workflow

```bash
make format
make lint
make build
```

- `make format` formats changed Swift files with Xcode's bundled `swift-format`.
- `make lint` checks changed Swift files without editing them.
- `make ci-check` runs `lint + Debug build`.
- `make release-check` runs `lint + Release build + size check`.
- `make format-all` and `make lint-all` are explicit full-repo passes; use them only for a planned formatting migration.

Optional hooks:

```bash
make hooks-install
```

## Release Size

Release builds target Apple Silicon only. Measure a built app with:

```bash
scripts/measure_release_bundle.sh \
  build/audit-release/Build/Products/Release/SapoWhisper.app
```

Current size baseline after the arm64 release cleanup:

- Release `.app`: 29,624 KB -> 20,624 KB (`-30.38%`)
- Main executable: 17,708 KB -> 8,712 KB (`-50.80%`)
- Local compressed test DMG: 13 MB

## Public Repo Safety

Tracked and expected to be public:

- Source code, assets needed by the app, localized strings, sound effects, entitlements, Xcode project metadata, shared scheme, `Package.resolved`, Makefile, formatting config, scripts, README, changelog, contributing notes, and license.

Ignored and intentionally private/local:

- `AGENTS.md`, `CLAUDE.md`, `DMG/`, `docs/`, `.codex/`, `xcuserdata/`, build products, logs, crash reports, credentials, `.env*`, exported audio, DMGs, archives, and local signing files.

Before opening a PR, run:

```bash
make ci-check
git diff --check
```

## Tests

The `SapoWhisper` scheme currently has no configured test action. Use `make ci-check` as the current local gate.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
