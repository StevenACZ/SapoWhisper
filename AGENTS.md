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
- `AudioRecorder`: batch 16 kHz mono int16 WAV capture.
- `StreamingAudioCapture*`: shared streaming capture that writes local WAV history and emits ordered PCM chunks.
- Engines: Apple Speech, WhisperKit, Google Cloud STT, Deepgram Nova-3, Deepgram Flux Live, Gemini Audio, ElevenLabs Scribe v2 batch, ElevenLabs Scribe Realtime v2.
- History: SQLite via `TranscriptionHistoryManager*`; audio retention via `HistoryAudioStorage`.
- Permissions: `PermissionService` plus guided permission windows and overlays.
- AI polish: optional Vertex AI Gemini 3.1 Flash-Lite after any engine; keep `polishing` visually distinct from recording/transcribing.

## ElevenLabs

- Batch mode (`scribe_v2_batch`) is the default ElevenLabs mode.
- Realtime mode (`scribe_v2_realtime`) streams PCM 16 kHz mono over WebSocket.
- Realtime must buffer committed transcript segments only; partial transcripts are telemetry/state, never live-typed.
- Stop flow sends a final commit, waits briefly for committed text, then pastes once.
- Always keep the local WAV backup for realtime and failed sessions.
- Realtime failure is manual retry only; do not auto-fallback to batch.
- Retry uses the currently selected ElevenLabs mode.
- Keyterms: batch allows up to 1000 terms, max 50 chars and 5 words each; realtime allows up to 50 terms, max 20 chars each.
- Replacements remain local post-processing for both modes.

## Diagnostics

- Prefer `SapoLog` categories: `Overlay`, `Hotkey`, `Recording`, `AudioRoute`, `Flux`, `AI`, `Gemini`, `Lifecycle`, `MenuBar`, `Settings`, `Performance`.
- Unified logs use subsystem `oli.SapoWhisper`.
- Runtime JSONL snapshots are not active in release code; use sanitized unified logs for triage before code changes.
- Transcription failures should log `failure=<Engine>/<kind>` with HTTP status/body snippet in `detail=`.
- Never log raw transcripts, prompts, API keys, OAuth tokens, service-account JSON, or Gemini responses.
- Prefer `chars=`, `bytes=`, `requestID=`, `sessionID=`, and timing summaries.

## Guardrails

- Do not remove engines, history, permission onboarding, auto-paste, auto-ducking, saved WAV history, or retry UI.
- Keep streaming paths resilient to device route churn.
- Map engine failures to `TranscriptionFailure`; do not reintroduce per-engine error enums.
- Keep AI polish non-blocking: if Gemini fails, paste/save the raw transcript and record AI metadata.
- Keep AI prompts conservative: no invented details, preserve technical terms, and treat vocabulary as recognition context.
- Keep Release artifacts `arm64` unless Intel support is explicitly re-approved.
- Do not force-add ignored local docs, agent caches, or packaging assets (`docs/`, `.agents/`, `DMG/`) without explicit approval.
- Ask before `git add`, `git commit`, `git push`, PR creation, merge, rebase, reset, or destructive git operations.

## Verification

```bash
make format
make lint
make ci-check
make release-check
```

- `make format` and `make lint` only inspect changed Swift files by default.
- The `SapoWhisper` scheme has no configured test action; use `make ci-check` as the current local gate.
- Run `git diff --check` before staging or reporting a docs/code patch done.

## Packaging

- Read `DMG/README.md` before creating a DMG.
- For local production-like testing, keep app name `SapoWhisper.app`, bundle id `oli.SapoWhisper`, and Release `arm64`.
- Use the repo Release build from `make release-check`.
- Put local test DMGs in `~/Downloads`.
- Verify DMGs with `hdiutil verify`, mount readonly, check `Info.plist`, `codesign --verify --deep --strict`, `codesign -dv`, and `file`.
- Local test builds are usually `adhoc` + hardened runtime; do not imply notarization unless verified.
