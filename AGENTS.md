# SapoWhisper Agent Notes

Compact operating notes for coding agents. Keep this file public-safe, short, and free of credentials or private runtime data.

## Product

- macOS menu bar speech-to-text app.
- Main flow: press `Option + Space`, speak, stop, then paste with clipboard + `Cmd+V`.
- Minimum macOS: 14.0.
- Release target: Apple Silicon only (`arm64`, M1 and newer).
- Main target: `SapoWhisper` in `SapoWhisper.xcodeproj`.
- Dependencies resolve through Xcode SwiftPM and `WhisperKit`.

## Architecture

- `SapoWhisperViewModel`: recording, transcription, AI polish, history, overlay, retry, and paste orchestration.
- `TranscriptionPipeline`: shared transcribe→polish→paste→persist control flow for the three stop paths (session-staleness gates, silence rule); the ViewModel implements `TranscriptionPipelineHost` for every side effect.
- Strict concurrency is `complete` on the app target; audio-stack classes are `nonisolated` with documented queue/lock synchronization. Keep new code warning-free instead of widening `nonisolated(unsafe)`.
- `AudioRecorder`: batch 16 kHz mono int16 WAV capture.
- `StreamingAudioCapture*`: shared streaming capture that writes local WAV history and emits ordered PCM chunks.
- Engines: WhisperKit (local), Deepgram Nova-3 batch, Deepgram Flux Live, ElevenLabs Scribe v2 batch, ElevenLabs Scribe Realtime v2. Apple Speech, Google Cloud STT, and Gemini Audio were removed; old history rows from them stay readable.
- History: SQLite via `TranscriptionHistoryManager*`; audio retention via `HistoryAudioStorage`.
- Permissions: `PermissionService` plus guided permission windows and overlays (Microphone + Accessibility only).
- Secrets: one consolidated Keychain item (`KeychainStore`) plus UserDefaults presence hints. Gate "is X configured" checks on `KeychainStore.hasValue` (never `string(for:)`) so launch/settings paths cannot trigger the macOS consent prompt; writes re-create the item (delete+add) so the running build owns it.
- Auto-ducking (`AutoDuckingManager`) fades system volume in a smooth ramp starting the instant recording begins (~400 ms down, ~250 ms up); do not reintroduce delayed or single-step volume drops.
- Welcome flow is first-run only: explicit Close marks it seen, and the final step closes itself when recording starts. Keycaps render the user's actual trigger (combo or double-tap).
- AI polish: optional OpenAI-compatible provider after any engine (`OpenAICompatiblePolisher`; OpenRouter default, model `openai/gpt-5.4-nano`, key in the macOS Keychain). A fidelity guard pastes the raw transcript when the output drifts. Keep `polishing` visually distinct from recording/transcribing.
- AI polish output language (same/Spanish/English) is authoritative and may translate the transcript; pass `translationExpected` to the fidelity guard so only translation-invariant anchors (numbers, URLs, emails, vocabulary) are enforced.
- Transcription language is recognition context, not translation or output forcing; only the AI polish output language may translate.

## ElevenLabs

- Batch mode (`scribe_v2_batch`) is the default ElevenLabs mode.
- Realtime mode (`scribe_v2_realtime`) streams PCM 16 kHz mono over WebSocket.
- Realtime must buffer committed transcript segments only; partial transcripts are telemetry/state, never live-typed.
- Stop flow sends a final commit, waits briefly for committed text, then pastes once.
- Always keep the local WAV backup for realtime and failed sessions.
- Realtime failure is manual retry only; do not auto-fallback to batch.
- Retry uses the currently selected ElevenLabs mode.
- Keyterms: batch allows up to 1000 terms, max 50 chars and 5 words each; realtime allows up to 50 terms, max 20 chars each.
- Language `auto` lets Scribe detect speech language; explicit languages are Scribe `language_code` hints for the spoken audio only.
- Keyterm payloads must prioritize saved vocabulary terms before generated variants, include replacement values as recognition hints, and sanitize hints before cloud requests.
- Replacements remain local post-processing for both modes.

## Diagnostics

- Prefer `SapoLog` categories: `Overlay`, `Hotkey`, `Recording`, `AudioRoute`, `Flux`, `AI`, `Lifecycle`, `MenuBar`, `Settings`, `Performance`.
- Unified logs use subsystem `oli.SapoWhisper`.
- Runtime JSONL snapshots are not active in release code; use sanitized unified logs for triage before code changes.
- Transcription failures should log `failure=<Engine>/<kind>` with HTTP status/body snippet in `detail=`.
- Never log raw transcripts, prompts, API keys, or AI provider responses.
- Prefer `chars=`, `bytes=`, `requestID=`, `sessionID=`, and timing summaries.

## Guardrails

- Do not remove the WhisperKit/Deepgram/ElevenLabs engine set, history, permission onboarding, auto-paste, auto-ducking, saved WAV history, or retry UI.
- Keep streaming paths resilient to device route churn.
- Map engine failures to `TranscriptionFailure`; do not reintroduce per-engine error enums.
- Keep AI polish non-blocking: if the AI provider fails or is not configured, paste/save the raw transcript and record AI metadata.
- Never run AI polish when `aiPolishEnabled` is false, including manual, retry, history, or language-selection paths.
- Keep AI prompts conservative: no invented details, preserve technical terms, and treat vocabulary as recognition context.
- Do not use transcription-language selection to translate text or force a final output language.
- For Deepgram Flux, send `language_hint` only for supported Flux languages; unsupported selections should fall back to auto-detect.
- Keep Release artifacts `arm64` unless Intel support is explicitly re-approved.
- Do not force-add ignored local docs, agent caches, or packaging assets (`docs/`, `.agents/`, `DMG/`) without explicit approval.
- Ask before `git add`, `git commit`, `git push`, PR creation, merge, rebase, reset, or destructive git operations.

## Verification

```bash
make format
make lint
make test
make ci-check
make release-check
```

- `make format` and `make lint` only inspect changed Swift files by default.
- `make test` runs the `SapoWhisperTests` unit bundle (pure logic: fidelity guard, failure mapping, engine migration, settings import); `make ci-check` = lint + Debug build + tests.
- Run `git diff --check` before staging or reporting a docs/code patch done.
- UI screenshots without consent prompts: launch a Debug build with `SAPO_UI_PREVIEW=1` and optional `SAPO_UI_PREVIEW_SCREEN=history|welcome` + `SAPO_UI_PREVIEW_WELCOME_STEP=<0-4>`. Preview launches and the unit-test host skip keychain reads, hotkey event-tap registration, and startup permission windows (`UIPreviewMode`); normal user launches are unaffected.

## Packaging

- Read `DMG/README.md` before creating a DMG.
- For local production-like testing, keep app name `SapoWhisper.app`, bundle id `oli.SapoWhisper`, and Release `arm64`.
- Use the repo Release build from `make release-check`.
- Put local test DMGs in `~/Downloads`.
- Verify DMGs with `hdiutil verify`, mount readonly, check `Info.plist`, `codesign --verify --deep --strict`, `codesign -dv`, and `file`.
- Local test builds are usually `adhoc` + hardened runtime; do not imply notarization unless verified.
