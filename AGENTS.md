# SapoWhisper Agent Notes

Compact public-safe operating notes for coding agents. Keep this file free of
credentials, personal paths, private transcripts, private audio, local server
addresses, and machine-specific workflow details.

## Product

- macOS menu bar speech-to-text app.
- Main flow: press `Option + Space`, speak, stop, then paste with clipboard + `Cmd+V`.
- `Esc` cancels an active dictation without transcribing or pasting, but preserves captured audio as a cancelled History entry; pending-start cancels create no row.
- Minimum macOS: 14.0.
- Release target: Apple Silicon only (`arm64`, M1 and newer).
- Main target: `SapoWhisper` in `SapoWhisper.xcodeproj`.
- Dependencies resolve through Xcode SwiftPM and `WhisperKit`.

## Architecture

- `SapoWhisperViewModel`: recording, transcription, AI polish, history, overlay, retry, and paste orchestration.
- `TranscriptionPipeline`: shared transcribe -> polish -> paste -> persist control flow for stop paths; the ViewModel implements `TranscriptionPipelineHost`.
- Strict concurrency is `complete` on app and test targets. Keep new code warning-free instead of widening unsafe isolation.
- Engines: WhisperKit local, Deepgram Nova-3 batch, Deepgram Flux Live, ElevenLabs Scribe batch/realtime, and Local AI Server batch STT through OpenAI-style endpoints.
- Audio capture: batch WAV capture uses `AudioUploadQuality`; streaming engines keep fixed 16 kHz mono int16 for WebSocket compatibility.
- History persists through SQLite and local audio storage. Use atomic history persistence helpers; do not split audio save and row save.
- Vocabulary metrics are read-only from recent history rows; do not add tracking columns for them.
- Credentials live in Keychain with UserDefaults presence hints. Gate configuration checks on `KeychainStore.hasValue`, not by reading credential values.

## AI Polish

- AI polish is optional and must never block dictation: provider failure, timeout, missing configuration, or empty output keeps the transcript usable.
- Never run AI polish when `aiPolishEnabled` is false, including manual, retry, history, or language-selection paths.
- There is exactly ONE polish mode: a single adaptive prompt (no mode picker, no prompt profiles, no duration gates). It deletes filler and duplicated ideas, keeps every instruction/name/number, respects tone, and never converts prose into invented lists. Do not reintroduce per-mode prompts or skip gates — silent gates read as "the AI didn't work".
- The prompt is dictionary-first: keyterms plus correction targets are canonical spellings that map mishearings, are never translated, and are never injected into text that does not mention them. Benchmark prompt changes case-by-case against real dictation history on a small local model (4B-class) before shipping; never tune by feel.
- Long transcripts are polished in sentence-boundary chunks (`TranscriptPostProcessor.splitIntoChunks`): past ~2k characters small models under-clean or summarize, and chunking restores medium-length quality. Keep the chunk seams on sentence boundaries.
- Local STT engines (WhisperKit, Local AI Server) receive the vocabulary as a Whisper-style initial prompt via `VocabularyManager.initialPromptText()` — canonical forms only, never misheard variants.
- Output language belongs to AI polish only; transcription language is recognition context, not translation.
- The instruction-response guard's cross-language cue check must stay disabled when an explicit output language is set (`translationExpected`): faithful translations legitimately lose source-language cue words, and rejecting them ships the untranslated text.
- The output-language picker (Settings + overlay translation chip) is the sole source of truth for translation targets. Do not reintroduce per-prompt force-English state.
- The hard-token guard is retry-only. It may ask the model to regenerate up to 3 total attempts when URLs, emails, vocabulary, or identifier-like tokens drift. Ratio, numbers, generic capitalization, and normal rewording must not raw-fallback an AI polish.
- `AIPolishMemoryManager` stores only reviewable correction suggestions; accepted corrections merge into the replacements dictionary for future polish requests.

## Private Local Workflows

- Repo-local personal skills belong in ignored `skills/`.
- Local `.agents/skills` and `.claude/skills` may symlink to `../skills` so Codex and Claude Code share the same local skill source.
- Keep private testing workflows, history DB/audio replay, concrete local server URLs, and machine-specific install/debug notes in ignored local skills, not in this public file.
- Do not force-add ignored local docs, agent caches, packaging assets, `.agents/`, `.claude/`, or `skills/` without explicit approval.

## Diagnostics

- Prefer `SapoLog` categories: `Overlay`, `Hotkey`, `Recording`, `AudioRoute`, `Flux`, `AI`, `Lifecycle`, `MenuBar`, `Settings`, `Performance`.
- Unified logs use subsystem `oli.SapoWhisper`.
- Never log raw transcripts, prompts, API keys, AI provider responses, or private retry instructions.
- Prefer metadata such as `chars=`, `bytes=`, `requestID=`, `sessionID=`, and timing summaries.
- Map engine failures to `TranscriptionFailure`; do not reintroduce per-engine error enums.

## Guardrails

- The recording overlay window is a fixed-size transparent surface (`RecordingOverlayWindow.surfaceSize`); never resize it from content size. Content-driven window resizing during SwiftUI transition animations makes `NSHostingView` mutate the window frame inside the AppKit display cycle, which throws and crashes the app. Keep `hostingView.sizingOptions = []`, anchor content with alignment, and let transparent pixels pass clicks through.
- Under that surface's ideal-size layout, multi-line `Text` needs a concrete width (`.frame(width:)` from real measurement), never `maxWidth:` — a max-width frame reports one line of height and the text overflows the pill and the window edge. Outside-click collapse compares against the measured content frame published by the overlay view, not `NSHostingView.hitTest` (the transparent margin reports hits).
- An explicit AI polish output language must always run the polish step: the duration/length skip gates only apply to same-as-input (`TranscriptPostProcessor.skipGatesApply`). Skipping would silently ship the untranslated transcript.
- Do not remove the WhisperKit/Deepgram/ElevenLabs/Local AI Server engine set, history, permission onboarding, auto-paste, auto-ducking, saved WAV history, or retry UI.
- Keep streaming paths resilient to device route changes.
- Skip synthetic `Cmd+V` when Secure Keyboard Entry is active; leave text on the clipboard.
- The history retranscribe/re-polish path must not drive live `appState` or overlay.
- Hotkey registration should fall back to the default combo when registration fails, and re-arm `Esc` after mid-session re-registration.
- Keep Release artifacts `arm64` unless Intel support is explicitly re-approved.
- Ask before `git add`, `git commit`, `git push`, PR creation, merge, rebase, reset, or destructive git operations.

## Verification

```bash
make format
make lint
make test
make ci-check
make release-check
```

- `make format` and `make lint` inspect changed Swift files by default.
- `make test` runs the `SapoWhisperTests` unit bundle.
- `make ci-check` runs lint, Debug build, and tests.
- Run `git diff --check` before staging or reporting a patch done.
- For public changes, scan the diff for credentials, private paths, local addresses, raw transcripts, and private workflow details before commit/push.

## Packaging

- Read `DMG/README.md` before creating a DMG.
- For release-like local testing, keep app name `SapoWhisper.app`, bundle id `oli.SapoWhisper`, and Release `arm64`.
- Use the repo Release build from `make release-check`.
- Verify DMGs with `hdiutil verify`, readonly mount checks, `Info.plist`, code signing, and binary architecture checks.
