# 🐸 SapoWhisper

SapoWhisper is a fast speech-to-text app for Apple Silicon Macs. Press the global shortcut, speak, press it again, and the transcript is pasted into the app you were using.

[Download the latest release](https://github.com/StevenACZ/SapoWhisper/releases/latest)

## What it does

- Records from a configurable global shortcut. The default is `Option + Space`, and a double-modifier shortcut is also available.
- Transcribes locally, through a local NVIDIA server, or with supported cloud providers.
- Supports low-latency realtime dictation with a preserved local-audio fallback.
- Pastes the result automatically and keeps searchable local history with replay and re-transcription.
- Recovers interrupted recordings after a crash or restart.
- Keeps a personal vocabulary for names and technical terms.
- Optionally cleans up or translates transcripts with an OpenAI-compatible AI provider.
- Includes English and Spanish interfaces plus signed one-click updates.

## Install

SapoWhisper requires macOS 14 or later on an Apple Silicon Mac.

1. Download the latest `SapoWhisper-*.dmg` from [Releases](https://github.com/StevenACZ/SapoWhisper/releases/latest).
2. Drag SapoWhisper into Applications.
3. Open it and grant Microphone permission. Grant Accessibility permission for automatic paste; double-modifier shortcuts also require Input Monitoring.
4. Choose a transcription engine and add that provider's credential when required.

Existing users can update from inside the app.

## Transcription engines

| Engine | Mode | Use case |
| --- | --- | --- |
| Whisper MLX | Local | Private offline transcription on the Mac |
| Local AI Server | Local network | Offload transcription to an NVIDIA server |
| Deepgram Nova-3 | Cloud batch | Accurate completed recordings |
| Deepgram Flux | Cloud realtime | Fast live dictation |
| ElevenLabs Scribe | Cloud batch or realtime | Scribe transcription |

Cloud engines and the configured local server receive the audio sent for transcription. Local MLX stays on the Mac. API credentials are stored in the macOS Keychain, and history remains on the Mac under the retention settings you choose.

## AI polish

AI polish is optional. You choose the provider, model, cleanup level, and output language. Settings includes model candidates and a built-in test, while custom model IDs remain supported. If a response fails the app's safety checks, SapoWhisper retries within a bounded budget and preserves the source transcript when needed.

See [BENCHMARKS.md](BENCHMARKS.md) for the public evaluation contract and its evidence limits.

## Build from source

Building requires Xcode and `gitleaks`. Local MLX builds also require the Metal Toolchain; maintainer-style signed reinstalls require a local `Signing.xcconfig`, while normal contributor builds use the tracked local-signing defaults.

```bash
git clone https://github.com/StevenACZ/SapoWhisper.git
cd SapoWhisper
make tools
make ci-check
```

Open `SapoWhisper.xcodeproj` and run the `SapoWhisper` scheme. See [CONTRIBUTING.md](CONTRIBUTING.md) for development details and [SECURITY.md](SECURITY.md) for the security policy.

## License

MIT
