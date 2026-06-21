# SapoWhisper Agent Notes

Compact operating notes for coding agents. Keep this file public-safe, short, and free of credentials or private runtime data.

## Product

- macOS menu bar speech-to-text app.
- Main flow: press `Option + Space`, speak, stop, then paste with clipboard + `Cmd+V`.
- `Esc` cancels an active dictation without transcribing or pasting, but preserves captured audio as a cancelled History entry; pending-start cancels still create no row. The key is a transient Carbon hotkey registered only while a session is active.
- Minimum macOS: 14.0.
- Release target: Apple Silicon only (`arm64`, M1 and newer).
- Main target: `SapoWhisper` in `SapoWhisper.xcodeproj`.
- Dependencies resolve through Xcode SwiftPM and `WhisperKit`.

## Architecture

- `SapoWhisperViewModel`: recording, transcription, AI polish, history, overlay, retry, and paste orchestration.
- `TranscriptionPipeline`: shared transcribe→polish→paste→persist control flow for the three stop paths (session-staleness gates, silence rule); the ViewModel implements `TranscriptionPipelineHost` for every side effect.
- Strict concurrency is `complete` on both the app and test targets; audio-stack classes are `nonisolated` with documented queue/lock synchronization (e.g. `AudioLevelMonitor.sampleFile`/`sampleWriteActive` under `sampleStateLock`, `AudioRecorder.lastInputBufferTime` and `StreamingAudioCapture.lastInputBufferTime` under `captureStateLock` — each written inside `registerInputBuffer`, read via `currentLastInputBufferTime()`, reset via `resetLastInputBufferTime()`; never write them bare off the tap thread). Keep new code warning-free instead of widening `nonisolated(unsafe)`.
- `AudioRecorder`: batch WAV capture uses `AudioUploadQuality` (default `medium`: 24 kHz mono int16); streaming engines keep fixed 16 kHz mono int16 for WebSocket compatibility.
- `StreamingAudioCapture*`: shared streaming capture that writes local WAV history and emits ordered PCM chunks.
- Engines: WhisperKit (local), Deepgram Nova-3 batch, Deepgram Flux Live, ElevenLabs Scribe v2 batch, ElevenLabs Scribe Realtime v2. Apple Speech, Google Cloud STT, and Gemini Audio were removed; old history rows from them stay readable.
- Local AI Server (NVIDIA) is a LAN batch STT engine using OpenAI-style endpoints. Default Speaches model suggestion is `rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo`; Base URL is user-provided and API key is optional in Keychain.
- Public local-STT fixtures live in `TestAssets/LocalAITranscription/`: longform clips under `longform/` and scored technical clips under `technical/en`/`technical/es` with `technical/vocabulary.json`. Use `scripts/local_stt_benchmark.sh`; use `scripts/ai_polish_history_replay.py` for private local-history polish replay (aggregate metrics by default, no transcript output).
- History: SQLite via `TranscriptionHistoryManager*`; audio retention via `HistoryAudioStorage`. The list pages incrementally by `offset` (append, never re-fetch every loaded page) and the query tie-breaks `ORDER BY timestamp DESC, id DESC` so paging cannot duplicate/skip rows; saved audio files use UUID names. Audio persistence (copy WAV → insert row → orphan/size sweep) is serialized through `TranscriptionHistoryManager.persistenceLock` (recursive) so a concurrent sweep cannot delete a freshly copied WAV before its row references it; persist via the atomic `persistEntry`, never a separate `saveAudioFile`+`save`, and keep `deleteOrphanedAudioFiles` matching by file name (not full path). Cancelled captures persist failed rows with `*/user_cancelled`; successful re-transcription must clear `failure_code`.
- Vocabulary tab metrics (words per minute, term usage) are computed read-only from recent history rows off the main actor (`VocabularyUsageCalculator`); do not add tracking columns or history schema changes for them.
- Permissions: `PermissionService` plus guided permission windows and overlays (Microphone + Accessibility only).
- Secrets: one consolidated Keychain item (`KeychainStore`) plus UserDefaults presence hints. Gate "is X configured" checks on `KeychainStore.hasValue` (never `string(for:)`) so launch/settings paths cannot trigger the macOS consent prompt; writes re-create the item (delete+add) so the running build owns it.
- Auto-ducking (`AutoDuckingManager`) fades system volume in a smooth ramp starting the instant recording begins (~400 ms down, ~250 ms up); do not reintroduce delayed or single-step volume drops.
- Welcome flow is first-run only: explicit Close marks it seen, and the final step closes itself when recording starts. Keycaps render the user's actual trigger (combo or double-tap).
- AI polish: optional OpenAI-compatible provider after any engine (`OpenAICompatiblePolisher`; OpenRouter default, Local Server preset for LAN `chat/completions`, editable Base URL, key optional/hidden when local). Provider model/Base URL/API key settings are scoped per endpoint; never let OpenRouter/OpenAI/Groq/local/custom values bleed into another endpoint. Local `AIPolishMemoryManager` stores only reviewable correction suggestions in app support; it must never learn, recommend, or auto-add vocabulary/keyterms. Accepted AI suggestions become normal automatic corrections, and only accepted corrections may feed future polish context. The hard-token guard is retry-only: it may ask the model to regenerate up to 3 total attempts when URLs, emails, vocabulary, or identifier-like tokens drift, but it must not fall back to raw solely for ratio, numbers, wording, or hard-token retry exhaustion; keep `polishing` visually distinct.
- The Prompts tab settings UI only edits prompt profiles; the personal-context editor and effective-prompt preview were removed, but a saved personal context still feeds `TranscriptPolishPromptBuilder`.
- AI polish output language (same-as-input or an explicit target from the 15-language catalog) is authoritative and may translate the transcript; pass `translationExpected` to the hard-token guard so only clear literal anchors (URLs, emails, vocabulary) are checked during translation. Engines never translate; selecting an explicit target resets the transcription language to auto so the spoken language is detected.
- Transcription language is recognition context, not translation or output forcing; only the AI polish output language may translate.
- Hard-token guard anchors are intentionally narrow: URLs, emails, vocabulary terms, and identifier-like capitalized tokens (`AGENTS..md`, `API`, `REST`, `SapoWhisper`). Identifier anchors are matched punctuation-insensitively via a ≥3-alphanumeric key, so a polish that fixes a dictation typo (`AGENTS..md` → `AGENTS.md`) is not a false retry signal while dropping the word's content (→ `AGENTS`) still is. Numbers, ratio, generic capitalization, and normal rewording must not reject or raw-fallback an AI polish.
- The history "Polish with AI" button is disabled when `aiPolishEnabled` is off; the manual polish runs with `force`, so duration/length skips never apply, and a missing provider surfaces a neutral notice (`history.ai_polish_*_notice`), never the "action failed" error alert.

## Deferred structural refactor (owner-gated, do not big-bang)

The ViewModel (~2000 lines) concentrates orchestration deliberately. The next reduction is planned but must be done slice-by-slice WITH the owner validating each step — it sits on the critical record→transcribe→paste path (staleness gates, retry, history reprocess) and has no direct tests:
1. First add characterization tests around the `TranscriptionPipelineHost`/VM seams (start/stop/retry/history/staleness, per engine). (Partial: the read-only engine-state surface — readiness/busy/`canRecord` — is pinned by `TranscriptionEngineSessionTests`; the stop/retry/history seams still lack direct tests.)
2. DONE — the `TranscriptionEngineSession` protocol (readiness/busy) now backs read-only engine state. The three duplicated `switch currentEngine` sites (`isEngineReady`, `isSelectedEngineBusy`, `canRecord`) derive from one `engineSessions(for:)` mapping; each transcriber declares its own `isReady`/`isBusy`. The dispatch `switch` in `transcribeAudio` and the Combine binding filters stay out of scope (not read-only state).
3. Extract stop-path / history / AI-polish coordinators behind protocols, one at a time.
4. Last: factor the two streaming transcribers' shared WebSocket scaffolding into small task-lifecycle helpers only, preserving each provider's distinct committed-segment salvage / batch-fallback semantics.

## ElevenLabs

- Batch mode (`scribe_v2_batch`) is the default ElevenLabs mode.
- Realtime mode (`scribe_v2_realtime`) streams PCM 16 kHz mono over WebSocket.
- Realtime must buffer committed transcript segments only; partial transcripts are telemetry/state, never live-typed.
- Stop flow sends a final commit, waits briefly for committed text, then pastes once.
- A late send failure (`failedMessages` / `.network`) must not discard segments the server already committed: only surface `.network` when nothing was captured, otherwise salvage the committed text via `waitForFinalTranscript`.
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
- Windows hosting SecureFields must drop the first responder on close/resign-key (`SecureInputReleasingWindowDelegate`); stuck Secure Keyboard Entry starves the hotkey event tap.
- Map engine failures to `TranscriptionFailure`; do not reintroduce per-engine error enums. Non-transient 4xx (400/404/405/413/415/422) map to the non-retryable `.clientError`; recording permission denial maps to `.notConfigured` — never offer Retry for an error a retry cannot fix.
- Keep AI polish non-blocking: if the AI provider fails or is not configured, paste/save the raw transcript and record AI metadata.
- Never run AI polish when `aiPolishEnabled` is false, including manual, retry, history, or language-selection paths.
- Keep AI prompts conservative: no invented details, preserve technical terms, and treat vocabulary as recognition context.
- Do not use transcription-language selection to translate text or force a final output language.
- For Deepgram Flux, send `language_hint` only for supported Flux languages; unsupported selections should fall back to auto-detect.
- Deepgram keyterm prompting uses the `keyterm` (singular) query param for Nova-3, including `language=multi`; do not rename it to `keyterms`.
- The history retranscribe/re-polish path must not drive the live `appState` or overlay (`historyReprocessingDepth` suppresses the dictation sinks); the hotkey start gate also checks the selected engine is busy (`isSelectedEngineBusy`), so a re-run neither sticks the app busy nor lets a new recording collide with it.
- The WhisperKit `$isModelLoaded` sink may only leave the `.noModel` state; an on-demand reload finishing mid-session must never reset `.recording`/`.processing`/`.polishing`.
- Hotkey registration falls back to the default combo when `RegisterEventHotKey` fails (e.g. a bad imported combo); re-arm Esc after any mid-session re-registration.
- Skip the synthetic `Cmd+V` when `IsSecureEventInputEnabled()` and leave the text on the clipboard; never post keystrokes into Secure Keyboard Entry.
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
- `make test` runs the `SapoWhisperTests` unit bundle (pure logic: hard-token guard, failure mapping incl. `from()`, VocabularyManager replacements/keyterms, engine migration, settings import); `make ci-check` = lint + Debug build + tests, and `.github/workflows/ci.yml` runs it on every push to `main` and PR (ad-hoc signed — no developer identity needed).
- Run `git diff --check` before staging or reporting a docs/code patch done.
- UI screenshots without consent prompts: launch a Debug build with `SAPO_UI_PREVIEW=1` and optional `SAPO_UI_PREVIEW_SCREEN=history|welcome|settings` + `SAPO_UI_PREVIEW_WELCOME_STEP=<0-4>`. Preview launches and the unit-test host skip keychain reads, hotkey event-tap registration, and startup permission windows (`UIPreviewMode`); normal user launches are unaffected.

## Local Testing Loop

Owner-approved default: when asked to continue work, build and replace the
installed app immediately — silently, with no confirmation prompts and no DMG
(DMGs are release-only). TCC grants (Microphone, Accessibility, Input
Monitoring) survive reinstalls ONLY when the build signs with the stable
local identity: the git-ignored `Signing.xcconfig` (copy from
`Signing.xcconfig.example`, included via the committed
`SigningDefaults.xcconfig`) sets `CODE_SIGN_IDENTITY = Apple Development`
plus the team ID. Without it the build falls back to ad-hoc signing, whose
code-signing hash changes every build, and macOS re-prompts all permissions
after each reinstall. Before installing, confirm the built app shows
`TeamIdentifier` set (`codesign -dv <app>`), not `Signature=adhoc`.

```bash
xcodebuild -project SapoWhisper.xcodeproj -scheme SapoWhisper \
  -configuration Debug -derivedDataPath build/agent build
osascript -e 'tell application "SapoWhisper" to quit' 2>/dev/null; sleep 1
rm -rf /Applications/SapoWhisper.app
cp -R build/agent/Build/Products/Debug/SapoWhisper.app /Applications/
open /Applications/SapoWhisper.app
```

The owner tests by hand; the agent ALWAYS keeps a live log watch running for
the whole session and reacts in two ways, both expected: start fixing the
moment an error appears in the stream, or have the evidence already captured
when the owner reports one.

```bash
/usr/bin/log stream --style compact --predicate 'subsystem == "oli.SapoWhisper"'
```

`log` is a zsh builtin — call `/usr/bin/log`. Crash reports land in
`~/Library/Logs/DiagnosticReports/SapoWhisper-*.ips`.

## Packaging

- Read `DMG/README.md` before creating a DMG.
- For local production-like testing, keep app name `SapoWhisper.app`, bundle id `oli.SapoWhisper`, and Release `arm64`.
- Use the repo Release build from `make release-check`.
- Put local test DMGs in `~/Downloads`.
- Verify DMGs with `hdiutil verify`, mount readonly, check `Info.plist`, `codesign --verify --deep --strict`, `codesign -dv`, and `file`.
- Local test builds are usually `adhoc` + hardened runtime; do not imply notarization unless verified.
