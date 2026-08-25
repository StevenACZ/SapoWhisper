# SapoWhisper Agent Notes

Compact public-safe operating notes for coding agents. Keep this file free of
credentials, personal paths, private transcripts, private audio, local server
addresses, and machine-specific workflow details.

## Product

- macOS menu bar speech-to-text app.
- Main flow: press `Option + Space`, speak, stop, then paste with clipboard + `Cmd+V`.
- `Esc` twice within 2.5 s cancels an active dictation (the first press only arms: the pill heartbeats and shows "Esc again to cancel" — `EscapeCancelGate`) without transcribing or pasting, preserving captured audio as a cancelled History entry; pending-start cancels create no row. The same double press cancels an in-flight batch transcription (the pre-persisted row resolves to cancelled and is offered as continue-previous). Re-transcribing an entry clears its continue-previous offer.
- The overlay dock chip opens an in-pill quick history (recent transcripts, copy, prev/next paging, current-engine re-transcribe, jump to the full History window). It is deliberately minimal — no pin, AI polish, audio download, or duration.
- Minimum macOS: 14.0.
- Release target: Apple Silicon only (`arm64`, M1 and newer).
- Main target: `SapoWhisper` in `SapoWhisper.xcodeproj`.
- Dependencies resolve through Xcode SwiftPM; the local STT engine is the vendored `LocalPackages/MLXWhisper` package.

## Architecture

- `SapoWhisperViewModel`: recording, transcription, AI polish, history, overlay, retry, and paste orchestration.
- `TranscriptionPipeline`: shared transcribe -> polish -> paste -> persist control flow for stop paths; the ViewModel implements `TranscriptionPipelineHost`.
- Strict concurrency is `complete` on app and test targets. Keep new code warning-free instead of widening unsafe isolation.
- Engines: MLX Whisper local (default; vendored `LocalPackages/MLXWhisper`), Deepgram Nova-3 batch, Deepgram Flux Live, ElevenLabs Scribe batch/realtime, and Local AI Server batch STT through OpenAI-style endpoints. WhisperKit was removed deliberately (2026-07-06; MLX runs the same weights ~6x faster) — do not reintroduce it, and keep `EnginePortfolioMigration` mapping stored `whisper` selections to `mlx_whisper` and purging the CoreML caches.
- `LocalPackages/MLXWhisper` is vendored from mlx-audio-swift (MIT, pinned commit in its Package.swift header) trimmed to the Whisper model. Local additions: initial-prompt (`<|startofprev|>`) vocabulary support, real auto language detection, a downloader with progress, quantized-checkpoint loading (4-bit), a Task-cancellation hook in the decode loop, and HF snapshots pinned to commit shas (bump revisions in `MLXWhisperModel.revision` + `WhisperModelDownloader.tokenizerRepo`); sync upstream fixes manually and keep the pin comment current. Its sources are exempt from repo swift-format lint. Building anything that links mlx-swift needs the Xcode Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`) and `-skipPackagePluginValidation` on headless xcodebuild (already in the Makefile); plain `swift build` produces a binary without Metal shaders that dies at MLX init — bench with the package's `mlxwhisper-cli` built via xcodebuild instead (XCTest-host numbers are not representative for the GPU path).
- Audio capture: one class, `AudioCaptureEngine`, serves every engine. `.batch` records a WAV at `AudioUploadQuality`, except whisper-family targets (MLX Whisper, Local AI Server) on the STT-oriented qualities (ultra-fast, medium), which capture 16 kHz directly — whisper decodes at 16 kHz and a higher-rate capture only adds a second resample. `.streaming` keeps fixed 16 kHz mono int16 for WebSocket compatibility and emits PCM chunks (batch is streaming with a nil chunk handler). Do not reintroduce per-path capture classes.
- Companion control uses payload-free distributed notifications: `oli.SapoWhisper.dictation.toggle` requests a toggle, while `.began`/`.ended` publish real recording state. A remote request opens `MiradorMicrophone_UID` explicitly and temporarily suspends preferred-default reconciliation without changing the saved microphone selection.
- Streaming engines (Flux, ElevenLabs realtime) are driven through `StreamingDictationSession` plus one shared start/stop/pause/abort/binding path in the ViewModel (`StreamingEngineContext`). Do not add per-engine copies of that flow.
- Observation: `MLXWhisperTranscriber` and the vocabulary/AI-memory/prompt-context managers are `@Observable` — views read them directly; do not reintroduce `@Published` mirrors in the ViewModel. High-frequency tickers (recording duration) stay OFF ObservableObject state: publish through a subject and subscribe locally in the one view that renders them.
- History persists through SQLite and local audio storage. Use atomic history persistence helpers; do not split audio save and row save.
- Batch dictations persist audio + a "transcribing" History row BEFORE the engine runs (`DictationHistoryPersister.persistPending` → pipeline target `.finalizePending`); success fills the row, failure marks it failed, and a launch sweep (`recoverInterruptedTranscriptions`) resolves rows orphaned by a crash. Never move persistence back to after transcription — that reopens the audio-loss window this exists to close.
- Engine selection runs on `TranscriptionEngineVariant` (engine + mode: MLX, Local AI Server, Nova-3, Flux Live, Scribe, Scribe Realtime), not on the brand — a live mode is a different runtime path, and the backup is chosen and executed at that granularity. `EngineFailoverPolicy` owns the "which engine runs" decision as pure values; keep it there and tested, never re-derived at call sites.
- The optional backup engine (Settings → Engine) covers three points, not one: it STARTS the dictation when the primary is unusable, offline, or in `EngineReachabilityLog` (a live backup then dictates natively); it rescues a failed batch transcription; and it rescues a failed live one from the preserved WAV. Only `network`/`timedOut`/`serverError` are rescued. History records the engine that actually transcribed, and a live backup rescuing an already-captured take runs its provider's file model (`fileTranscriptionVariant`) — replaying a finished file through a live socket is slower and strictly less accurate. Explicit engine choices (history retranscribe menu) never fall back.
- The backup must be a DIFFERENT engine, never a sibling mode of the primary. Readiness and reachability are provider-wide — one key, one host, one `EngineReachabilityLog` entry — so a sibling is unavailable exactly when the primary is and can never rescue anything: `decision` only hands over when the primary is worse off than the backup, which two equal availabilities make impossible. Offering one in the picker promises a rescue that cannot run. The live→file direction within one provider is already covered inside the streaming transcribers (`transcribeFullCaptureFallback`).
- A Local AI Server dictation probes `/health` in the background WHILE the user speaks (`startReachabilityProbe`), so a dead server is already known at stop time and skipped outright instead of paying the preflight; one success clears the entry and the primary takes the next take. Never move that probe into the stop path — costing the user nothing is the entire point.
- Vocabulary metrics are read-only from recent history rows; do not add tracking columns for them.
- Speech-mishearing brand tables and spoken-form helpers live in `SpeechConfusionCatalog`, shared by `VocabularyManager` and `AIPolishMemoryManager`. Add new mishearing variants there — do not re-add per-manager copies (they drift).
- MLX model snapshots live under the app's own `Application Support/SapoWhisper/MLXModels/` (one folder per tier, `WhisperModelDownloader.modelDirectory`); a model counts as downloaded only when weights + config + tokenizer are all present and non-empty.
- Selection- and session-driven MLX loads must have a bounded lifecycle: cancel pending selection loads before engine/model changes, and unload any model that finishes loading or transcribing after MLX is no longer selected. Keep rapid other → MLX → other and switch-away-during-use regressions tested.
- Credentials live in Keychain with UserDefaults presence hints. Gate configuration checks on `KeychainStore.hasValue`, not by reading credential values.

## AI Polish

- AI polish is optional and must never block dictation: provider failure, timeout, missing configuration, or empty output keeps the transcript usable.
- Never run AI polish when `aiPolishEnabled` is false, including manual, retry, history, or language-selection paths.
- There are exactly TWO polish modes (`PolishMode`): Normal, a single adaptive prompt that deletes filler and duplicated ideas, keeps every instruction/name/number, respects tone, and never converts prose into invented lists; and Compact (2026-07-05), which extracts requirements and rewrites the whole transcript in ONE call as the shortest faithful text (own timeout curve — never the per-chunk Normal budget). No prompt profiles, no SILENT skip gates ("the AI didn't work"); the one sanctioned gate is the user-chosen `PolishMinimumDuration` (default Always), enforced for live dictations only — manual History re-polish always runs.
- The prompt is dictionary-first: keyterms plus correction targets are canonical spellings that map mishearings, are never translated, and are never injected into text that does not mention them. Benchmark prompt changes case-by-case against real dictation history on the PRODUCTION model (OpenRouter `gpt-5.4-nano`) before shipping; never tune by feel.
- Filler deletion is two-tier by evidence, not by vibe: pure fillers are always-delete, but dual-use words ("la verdad", "equis", "tal", "y ya") are contextual — real history shows they usually carry meaning ("la verdad es que…", "equis cosas"). Do not move dual-use words back into the always-delete list without a bench run proving it.
- Reasoning effort is a single global setting (`PolishReasoningEffort`, default Off) sent with every polish request — OpenRouter gets `reasoning: {effort, exclude}`, everyone else `reasoning_effort`. Off exists because reasoning models otherwise think away the output token cap and the polish arrives truncated (Mercury 2, 2026-07-05). Explicit levels add `reasoningTokenHeadroom` to the cap; a provider that rejects the parameter gets one retry without it. Do not add per-endpoint or per-model reasoning knobs.
- On endpoints that support structured outputs (OpenAI, OpenRouter) the polish uses a strict JSON schema with a leading `filler_scan` field — forcing the model to enumerate fillers before writing `polished` measurably cuts leftovers on long chunks. Groq/local/custom keep the plain-text contract, and a rejected structured request falls back to plain automatically. Never log or persist `filler_scan`.
- Long transcripts are polished in sentence-boundary chunks (`TranscriptPostProcessor.splitIntoChunks`): past ~2k characters small models under-clean or summarize, and chunking restores medium-length quality. Keep the chunk seams on sentence boundaries. Chunks 2+ receive the RAW tail of their predecessor as continuity context (raw, not polished, so hosted chunks keep running in parallel).
- Recognition hints and deterministic corrections are separate: excluding
  replacement targets from engine hints must never change post-transcription
  correction eligibility. Local STT prompts contain canonical forms only.
- Output language belongs to AI polish only; transcription language is recognition context, not translation.
- The instruction-response guard's cue-preservation check must stay disabled when an explicit output language is set (`translationExpected`) AND in Compact mode (`compactionExpected`): faithful translations lose source-language cue words, and compact rewrites legitimately turn imperative cues into requirement phrasing — both rejected every good output 3/3 and shipped raw. The introduced-phrase drift checks (refusals, math answers, self-reference) stay on in both cases.
- The output-language picker (Settings + overlay translation chip) is the sole source of truth for translation targets. Do not reintroduce per-prompt force-English state.
- The hard-token guard is retry-only. It may ask the model to regenerate up to 3 total attempts when URLs, emails, vocabulary, or identifier-like tokens drift. Ratio, numbers, generic capitalization, and normal rewording must not raw-fallback an AI polish. Numbers are deliberately NOT hard anchors: STT mangles spoken numbers with random separators ("0,63.40.64") and the polish must be free to repair them — number fidelity belongs to the prompt and the chunker (which never splits inside a number).
- `PolishContentDiffGuard` is the lenient complement, also retry-only: it flags digit RUNS that vanish entirely (re-punctuation and stutter absorption pass) and raw sentences whose distinctive words are almost all missing from the output (a dropped passage). It shares the same retry budget and must never raw-fallback an otherwise good polish.
- History keeps a polish trail: every APPLIED polish also inserts into `polish_versions` (schema v4; centralized in the manager's save/update paths — never insert from callers), raw text stays in `raw_transcription`, and deletes sweep orphaned versions. The history "Polish with AI" menu re-polishes with any endpoint/model recorded by `PolishProviderConfiguration.recordRecentModel` (called only when a polish APPLIES — never while typing in Settings, which fires per keystroke).
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
- EVERY manually sized `NSHostingView`/`NSHostingController` window (settings, history, about, permissions, welcome) must set `sizingOptions = []`. The default options let the hosting view drive window min/max from inside AppKit's update-constraints pass; when the SwiftUI graph invalidates mid-pass, macOS 26 throws in `_postWindowNeedsUpdateConstraints` — a hard crash on dictation start and app launch (2026-07-05). New hosting windows must follow this or size via `preferredContentSize` popover flow.
- Under that surface's ideal-size layout, multi-line `Text` needs a concrete width (`.frame(width:)` from real measurement), never `maxWidth:` — a max-width frame reports one line of height and the text overflows the pill and the window edge. Outside-click collapse compares against the measured content frame published by the overlay view, not `NSHostingView.hitTest` (the transparent margin reports hits).
- A closed window must not keep a live `NSHostingController`: the settings/history/about controllers are released on `windowWillClose` (`SecureInputReleasingWindowDelegate.onWillClose`) because a retained graph keeps animating forever — one Settings open left the app at ~40% CPU with RSS climbing until relaunch (2026-08-14). The settings tabs stay mounted at opacity 0 by design, so every continuous (trigger-less) animator inside a tab must pin its phases on `\.settingsTabIsSelected`.
- Continuously animated pill subviews (equalizer bars, meters) must animate transforms (`scaleEffect`), not layout (`frame` sizes), and isolate themselves with `.drawingGroup()`. Otherwise SwiftUI flattens them into the pill's shared drawing layer and every animation frame re-renders that layer on the CPU — text glyphs included, whose CoreGraphics bitmap buffers accumulate ~1 MB/s of resident memory per recording session (reachable, so `leaks` reports zero).
- An explicit AI polish output language must always run the polish step — polish has no skip gates of any kind, and silently skipping would ship the untranslated transcript.
- Do not remove the MLX Whisper/Deepgram/ElevenLabs/Local AI Server engine set, history, permission onboarding, auto-paste, auto-ducking, saved WAV history, or retry UI.
- Keep streaming paths resilient to device route changes.
- Never surface an affordance (chip, hint, armed warning, menu item) whose
  action cannot execute in the CURRENT state: derive its visibility from the
  same predicate the action guards on, never from a coarser state summary.
  This bit twice — the sibling-backup picker offered a rescue `decision`
  could never hand over (v2.14.0), and the first double-Esc build armed
  "Esc again to cancel" during streaming/post-stop windows where the confirm
  was a guaranteed no-op (fixed via `escCancelCanAct` before v2.15.0).
- Never gate live-session UI on "is this the SELECTED engine" — once the backup
  can start a dictation, the running session is not the selected one. Gate on
  the variant driving the dictation (`sessionVariant`). Gating the streaming
  meter and timer on the selection starved `registerSessionAudioLevel`, the only
  path that clears the "connecting <mic>" label, so a backup-driven dictation
  that was recording fine sat on "connecting" at 00:00 until the 6 s timeout.
- Keep the three SapoWhisper distributed notification names and the Mirador
  microphone UID stable; Mirador depends on them as a companion-app contract.
- Treat an explicit saved microphone UID as fail-closed while absent: preflight,
  monitor, capture start/recovery must not touch, announce, or use system default.
  Preserve the UID and restore that same device on lifecycle and route events.
- Route every AVAudioEngine call that can assert (`inputNode`, `installTap`,
  `prepare`/`start`) through `AudioEngineGuard`: AVFAudio throws uncatchable
  Objective-C NSExceptions mid route transition, which killed the app before
  the guard existed. Treat the guarded error as transient and retry.
- Never use a zero-length read as the EOF signal on `AVAudioFile` — reading at
  exact EOF throws; gate reads on `framePosition < length`.
- Whisper-family engines hallucinate on silent/short takes ("Thank you.",
  repetition loops, glossary echo — all reproduced from real history audio).
  Two layers stop this and both must stay: the Local AI Server request always
  sends `vad_filter=true` (kills silence hallucinations AND trailing-silence
  repetition loops), and every batch engine result passes through
  `WhisperHallucinationFilter` (punctuation debris, loop collapse, vocabulary
  echo → the no-speech flow). Keep the vocabulary in `prompt`: hotwords-only
  requests measurably lose punctuation/casing on real dictations.
- Local AI Server transcriptions preflight `GET /health` (3 s timeout) before uploading: any HTTP response — including 404 on servers without that endpoint — counts as alive; only transport failures throw. Do not remove it — without the preflight a powered-off server hangs the dictation for the full scaled request timeout (2–10 min).
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
- A notarized DMG does not transfer its ticket to the separate Sparkle ZIP.
  Before upload, require the app's own staple, extract the ZIP with `ditto`,
  and validate both `stapler` and strict `codesign` on the extracted app.
