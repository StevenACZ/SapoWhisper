# Architecture

Read this document before changing capture, transcription, history, polish, or window lifecycle behavior. Operational gates and privacy rules remain in [AGENTS.md](AGENTS.md); benchmark methodology and dated evidence remain in [BENCHMARKS.md](BENCHMARKS.md).

## Ownership and boundaries

| Owner | Responsibility |
| --- | --- |
| `SapoWhisperViewModel` | Coordinates the active dictation and connects engine, history, overlay, and paste services. |
| `AudioCaptureEngine` / `CaptureStartSupervisor` | Capture and bounded startup recovery across all engines. |
| `StreamingDictationSession` | Common live-engine lifecycle contract. |
| `TranscriptionPipeline` / `DictationHistoryPersister` | Processing orchestration and durable recording handoff. |
| `TranscriptionHistoryManager` / `HistoryAudioStorage` | SQLite records, polish versions, and local audio ownership. |
| `TranscriptPostProcessor` / `OpenAICompatiblePolisher` | Polish policy, chunking, provider requests, and output validation. |
| `OverlayWindowManager` | Overlay presentation and window lifecycle. |
| `WelcomeView` / `WelcomeAIPolishStep` | Onboarding navigation and isolated polish-provider setup state; `WelcomeComponents` contains the shared step title. |

These are source-file boundaries within the app target, not separate frameworks. Keep shared policy in its existing owner instead of duplicating it in views or provider adapters.

## Lifecycle and concurrency

The app uses Swift 6 with MainActor default isolation and complete strict concurrency. The XCTest target also uses Swift 6, with explicit actor annotations rather than a target-wide actor default, which conflicts with inherited XCTest initializers in the current toolchain.

- `DictationOperationCoordinator` owns each post-stop task and its cancellation. Its observable active context remains occupied until the task actually drains, preventing a late finalizer from closing a newer session.
- `StreamingCapturePreparation` seals capture and persists a pending History row before network finalization. The original WAV remains available for provider fallback until completion; the History copy is retained afterward.
- `TranscriptionPipeline` awaits final persistence before publishing the copied result. Opening History immediately therefore targets the completed row.
- `HistoryEntryStatus` defines processing states used by both UI and SQL deletion/recovery guards. Recognized text is saved before AI polish; interruption leaves the text and audio recoverable.
- `AudioInputPreflightManager` owns scheduling on MainActor and performs bounded hardware work off-main. `AudioInputActivityGate` makes microphone acquisition cancellable and bounded even when a preflight is stuck.
- `AudioConverterInputSource` owns converter feed state under a lock across capture, file merge and local-model decoding.
- `FileMultipartBody` prepares Local AI Server uploads off-main with bounded file reads and private temporary-file ownership. `TransientRequestRetry` shares one retry policy across in-memory and file upload requests. The original recording stays owned by History.
- `AppPreferences.defaults` preserves the normal preferences store and gives tests/previews an isolated process suite. `AppRuntimePaths` similarly isolates their file storage. Test startup skips migrations, cleanup, updates, companion control and unsolicited audio effects.

## Capture, engines, and persistence

- `SapoWhisperViewModel`: recording, transcription, AI polish, history, overlay, retry, and paste orchestration.
- `TranscriptionPipeline`: shared transcribe -> polish -> persist -> paste control flow for stop paths; the ViewModel implements `TranscriptionPipelineHost`.
- Strict concurrency is `complete` on app and test targets. Keep new code warning-free instead of widening unsafe isolation.
- Engines: MLX Whisper local (default; vendored `LocalPackages/MLXWhisper`), Deepgram Nova-3 batch, Deepgram Flux Live, ElevenLabs Scribe batch/realtime, and Local AI Server batch STT through OpenAI-style endpoints. WhisperKit was removed deliberately (2026-07-06; MLX runs the same weights ~6x faster) — do not reintroduce it, and keep `EnginePortfolioMigration` mapping stored `whisper` selections to `mlx_whisper` and purging the CoreML caches.
- MLX accepts only windows that reach the decoder end token. An output-limit window retries once without glossary bias, then splits into contiguous halves at most twice, with one second minimum per half; unresolved limits remain recoverable failures eligible for backup. Batch and streamed generation share this owner, and streamed deltas contain only accepted windows. A per-recording decoder limit must not mark the engine unreachable for later dictations.
- The recording meter uses a small AppKit layer renderer; live audio updates animate only bar transforms and opacity. Its connecting timer and audio subscription stop when detached, and Reduce Motion disables interpolation.
- `LocalPackages/MLXWhisper` is vendored from mlx-audio-swift (MIT, pinned commit in its Package.swift header) trimmed to the Whisper model. Local additions: initial-prompt (`<|startofprev|>`) vocabulary support, real auto language detection, a downloader with progress, quantized-checkpoint loading (4-bit), a Task-cancellation hook in the decode loop, and HF snapshots pinned to commit shas (bump revisions in `MLXWhisperModel.revision` + `WhisperModelDownloader.tokenizerRepo`); sync upstream fixes manually and keep the pin comment current. Its sources are exempt from repo swift-format lint. Building anything that links mlx-swift needs the Xcode Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`) and `-skipPackagePluginValidation` on headless xcodebuild (already in the Makefile); plain `swift build` produces a binary without Metal shaders that dies at MLX init — bench with the package's `mlxwhisper-cli` built via xcodebuild instead (XCTest-host numbers are not representative for the GPU path).
- Audio capture: one class, `AudioCaptureEngine`, serves every engine. `CaptureStartSupervisor` owns startup retries for all modes; the first attempt cannot consume its recovery window, and each retry waits once. `.batch` records a WAV at `AudioUploadQuality`, except whisper-family targets (MLX Whisper, Local AI Server) on the STT-oriented qualities (ultra-fast, medium), which capture 16 kHz directly — whisper decodes at 16 kHz and a higher-rate capture only adds a second resample. `.streaming` keeps fixed 16 kHz mono int16 for WebSocket compatibility and emits PCM chunks (batch is streaming with a nil chunk handler). Do not reintroduce per-path capture classes.
- Companion control accepts toggles and state queries only through a same-user Unix socket that validates the peer audit token and code signature; payload-free `.began`/`.ended` distributed notifications are hints that companions verify through that socket. A remote request opens `MiradorMicrophone_UID` explicitly and temporarily suspends preferred-default reconciliation without changing the saved microphone selection.
- Streaming engines (Flux, ElevenLabs realtime) are driven through `StreamingDictationSession` plus one shared start/stop/pause/abort/binding path in the ViewModel (`StreamingEngineContext`). Do not add per-engine copies of that flow.
- Observation: `MLXWhisperTranscriber` and the vocabulary/AI-memory/prompt-context managers are `@Observable` — views read them directly; do not reintroduce `@Published` mirrors in the ViewModel. High-frequency tickers (recording duration) stay OFF ObservableObject state: publish through a subject and subscribe locally in the one view that renders them.
- History persists through SQLite and local audio storage. Use atomic history persistence helpers; do not split audio save and row save.
- After capture seals, batch and streaming dictations persist audio + a "transcribing" History row BEFORE final processing (`DictationHistoryPersister.persistPending` → pipeline target `.finalizePending`); success fills the row, failure marks it failed, and a launch sweep (`recoverInterruptedTranscriptions`) resolves rows orphaned by a crash. Streaming recognition itself runs during capture. Never move persistence back to after finalization — that reopens the audio-loss window this exists to close.
- Engine selection runs on `TranscriptionEngineVariant` (engine + mode: MLX, Local AI Server, Nova-3, Flux Live, Scribe, Scribe Realtime), not on the brand — a live mode is a different runtime path, and the backup is chosen and executed at that granularity. `EngineFailoverPolicy` owns the "which engine runs" decision as pure values; keep it there and tested, never re-derived at call sites.
- The optional backup engine (Settings → Engine) covers three points, not one: it STARTS the dictation when the primary is unusable, offline, or in `EngineReachabilityLog` (a live backup then dictates natively); it rescues a failed batch transcription; and it rescues a failed live one from the preserved WAV. Provider failures, including rejected requests/models, missing configuration, authentication, quota, rate limits and decoder limits, are eligible for one configured backup. Cancelled, interrupted, empty or invalid captures are excluded. Unknown failures are rescuable only after capture; startup requires a classified provider failure. Only `network`, `timedOut`, and `serverError` mark an engine temporarily unreachable. History records the engine that actually transcribed, and a live backup rescuing an already-captured take runs its provider's file model (`fileTranscriptionVariant`) — replaying a finished file through a live socket is slower and strictly less accurate. Explicit engine choices (history retranscribe menu) never fall back.
- `TranscriptionAttemptContext` scopes backup preference to the current primary operation. A usable configured backup skips primary HTTP/network backoffs and same-provider streaming rescue after confirmed errors. Unconfirmed realtime partials must not hide a failure. Without a usable backup, provider recovery remains unchanged. Overlay backup notices name the actual variant and survive processing/copy confirmation, then clear for the next dictation.
- The backup must be a DIFFERENT engine, never a sibling mode of the primary. Readiness and reachability are provider-wide — one key, one host, one `EngineReachabilityLog` entry — so a sibling is unavailable exactly when the primary is and can never rescue anything: `decision` only hands over when the primary is worse off than the backup, which two equal availabilities make impossible. Offering one in the picker promises a rescue that cannot run. The live→file direction within one provider is already covered inside the streaming transcribers (`transcribeFullCaptureFallback`).
- A Local AI Server dictation probes `/health` in the background WHILE the user speaks (`startReachabilityProbe`), so a dead server is already known at stop time and skipped outright instead of paying the preflight; one success clears the entry and the primary takes the next take. Never move that probe into the stop path — costing the user nothing is the entire point.
- Local AI Server availability and Settings status share ViewModel ownership. Configuration changes and successful connection tests invalidate stale cooldowns for the next take without changing an active capture. Revision-scoped observations prevent old checks from overwriting newer configuration or transcription outcomes; a transport response alone never claims transcription success.
- Provider adapters return raw recognition text. `TranscriptPostProcessor` applies saved recognition corrections once before the optional AI-polish gate; provider-side replacements must not cascade into a second local pass.
- Automatic History cleanup removes only unprotected completed rows. Failed and processing recordings, pinned entries and unexpired retention extensions survive both age and size policies; size cleanup also preserves the newest capture by timestamp, not insertion ID. The audio cap is soft when only protected recordings remain, with a visible storage warning.
- History schema v5 stores `retention_until` separately from the original capture timestamp. An explicit continuation accepts a saved failed take for the session, so the offer TTL cannot expire during recording or a pause. Continuation uses the selected provider's file mode to transcribe the combined audio while preserving the normal engine preference.
- Settings transfer exports portable preferences and explicit unset-key metadata without secrets or microphone identity. Imports validate before changes, write a private pre-import backup, persist file sections before preferences and attempt file rollback on errors. This is recoverable multi-file work, not a crash-atomic transaction; old documents without presence metadata preserve omitted fields.
- Vocabulary metrics are read-only from recent history rows; do not add tracking columns for them.
- Speech-mishearing brand tables and spoken-form helpers live in `SpeechConfusionCatalog`, shared by `VocabularyManager` and `AIPolishMemoryManager`. Add new mishearing variants there — do not re-add per-manager copies (they drift).
- MLX model snapshots live under the app's own `Application Support/SapoWhisper/MLXModels/` (one folder per tier, `WhisperModelDownloader.modelDirectory`); a model counts as downloaded only when weights + config + tokenizer are all present and non-empty.
- Selection- and session-driven MLX loads must have a bounded lifecycle: cancel pending selection loads before engine/model changes, and unload any model that finishes loading or transcribing after MLX is no longer selected. Keep rapid other → MLX → other and switch-away-during-use regressions tested.
- Credentials live in Keychain with UserDefaults presence hints. Gate configuration checks on `KeychainStore.hasValue`, not by reading credential values.

## AI Polish

- AI polish is optional and must never block dictation: provider failure, timeout, missing configuration, or empty output keeps the transcript usable.
- Never run AI polish when `aiPolishEnabled` is false, including manual, retry, history, or language-selection paths.
- There are exactly TWO polish modes (`PolishMode`): Normal, a single adaptive prompt that deletes filler and duplicated ideas, keeps every instruction/name/number, respects tone, and never converts prose into invented lists; and Compact (2026-07-05), which extracts requirements and rewrites the whole transcript in ONE call as the shortest faithful text (own timeout curve — never the per-chunk Normal budget). No prompt profiles, no SILENT skip gates ("the AI didn't work"); the one sanctioned gate is the user-chosen `PolishMinimumDuration` (default Always), enforced for live dictations only — manual History re-polish always runs.
- The prompt is dictionary-first: keyterms plus correction targets are canonical spellings that map mishearings, are never translated, and are never injected into text that does not mention them. Benchmark prompt changes against the frozen four-route contract in `BENCHMARKS.md`; publish aggregate evidence only and never tune by feel.
- Filler deletion is two-tier by evidence, not by vibe: pure fillers are always-delete, but dual-use words ("la verdad", "equis", "tal", "y ya") are contextual and often carry meaning ("la verdad es que…", "equis cosas"). Do not move dual-use words back into the always-delete list without a bench run proving it.
- Reasoning effort is a single global setting (`PolishReasoningEffort`, default Off) sent with every polish request — OpenRouter gets `reasoning: {effort, exclude}`, everyone else `reasoning_effort`. Off exists because reasoning models otherwise think away the output token cap and the polish arrives truncated (Mercury 2, 2026-07-05). Explicit levels add `reasoningTokenHeadroom` to the cap; a provider that rejects the parameter gets one retry without it. Do not add per-endpoint or per-model reasoning knobs.
- On endpoints that support structured outputs (OpenAI, OpenRouter) the polish uses a strict JSON schema with a leading `filler_scan` field — forcing the model to enumerate fillers before writing `polished` measurably cuts leftovers on long chunks. Groq/local/custom keep the plain-text contract, and a rejected structured request falls back to plain automatically. Never log or persist `filler_scan`.
- Long transcripts are polished in sentence-boundary chunks (`TranscriptPostProcessor.splitIntoChunks`): past ~2k characters small models under-clean or summarize, and chunking restores medium-length quality. Keep the chunk seams on sentence boundaries. Chunks 2+ receive the RAW tail of their predecessor as continuity context (raw, not polished, so hosted chunks keep running in parallel).
- Recognition hints and deterministic corrections are separate: excluding
  replacement targets from engine hints must never change post-transcription
  correction eligibility. Local STT prompts contain canonical forms only.
- Output language belongs to AI polish only; transcription language is recognition context, not translation.
- The instruction-response guard rejects ONLY assistant-response markers the model INTRODUCED (openers, first-person completion reports, "as requested" framing, sign-offs, refusals/apologies, and a reply-shaped answer to a dictated question) — owner decision 2026-08-29; cue preservation, negation flips, anchors, math answers and drift are gone from it, and content-loss checks live only as retry-only hints in `PolishFidelityGuard` and `PolishContentDiffGuard`.
- The output-language picker (Settings + overlay translation chip) is the sole source of truth for translation targets. Do not reintroduce per-prompt force-English state.
- The hard-token guard is retry-only. It may ask the model to regenerate up to 3 total attempts when URLs, emails, vocabulary, or identifier-like tokens drift. Ratio, numbers, generic capitalization, and normal rewording must not raw-fallback an AI polish. Numbers are deliberately NOT hard anchors: STT mangles spoken numbers with random separators ("0,63.40.64") and the polish must be free to repair them — number fidelity belongs to the prompt and the chunker (which never splits inside a number).
- `PolishContentDiffGuard` is the lenient complement, also retry-only: it flags digit RUNS that vanish entirely (re-punctuation and stutter absorption pass) and raw sentences whose distinctive words are almost all missing from the output (a dropped passage). It shares the same retry budget and must never raw-fallback an otherwise good polish.
- History keeps a polish trail: every APPLIED polish also inserts into `polish_versions` (schema v4; centralized in the manager's save/update paths — never insert from callers), raw text stays in `raw_transcription`, and deletes sweep orphaned versions. The history "Polish with AI" menu re-polishes with any endpoint/model recorded by `PolishProviderConfiguration.recordRecentModel` (called only when a polish APPLIES — never while typing in Settings, which fires per keystroke).
- `AIPolishMemoryManager` stores only reviewable correction suggestions; accepted corrections merge into the replacements dictionary for future polish requests.

## Guardrails

- Transient overlay dismissal belongs to the current presentation; every state change cancels its timer. Closed menu popovers release their SwiftUI content and subscriptions.
- Processing cancellation controls and Escape share the same eligibility predicate. A cancelled overlay re-polish retains task ownership until it drains and cannot update the clipboard or History afterward.
- Every captured or merged WAV keeps its process-owned recovery marker until durable History ownership or deliberate deletion. Never remove source takes or their History row before the merged pending row exists. A live owner's file must remain untouched regardless of modification age.
- Disk-write failures stop the active session and surface a storage error; stop paths reject incomplete capture diagnostics before transcription. Do not replace this with logging alone.
- Continue-previous offers rebuild from recent recoverable History rows on every launch and retain the original capture timestamp. Completed, deleted, expired or audio-missing rows must not reappear.
- Overlay chrome supplies its own contrast floor and semantic foreground hierarchy. Appearance and accessibility drive updates; do not poll or capture the desktop to recolor text.
- The recording overlay window is a fixed-size transparent surface (`RecordingOverlayWindow.surfaceSize`); never resize it from content size. Content-driven window resizing during SwiftUI transition animations makes `NSHostingView` mutate the window frame inside the AppKit display cycle, which throws and crashes the app. Keep `hostingView.sizingOptions = []`, anchor content with alignment, and let transparent pixels pass clicks through.
- EVERY manually sized `NSHostingView`/`NSHostingController` window (settings, history, about, permissions, welcome) must set `sizingOptions = []`. The default options let the hosting view drive window min/max from inside AppKit's update-constraints pass; when the SwiftUI graph invalidates mid-pass, macOS 26 throws in `_postWindowNeedsUpdateConstraints` — a hard crash on dictation start and app launch (2026-07-05). New hosting windows must follow this or size via `preferredContentSize` popover flow.
- Under that surface's ideal-size layout, multi-line `Text` needs a concrete width (`.frame(width:)` from real measurement), never `maxWidth:` — a max-width frame reports one line of height and the text overflows the pill and the window edge. Outside-click collapse compares against the measured content frame published by the overlay view, not `NSHostingView.hitTest` (the transparent margin reports hits).
- A closed window must not keep a live `NSHostingController`: the settings/history/about controllers are released on `windowWillClose` (`SecureInputReleasingWindowDelegate.onWillClose`) because a retained graph keeps animating forever — one Settings open left the app at ~40% CPU with RSS climbing until relaunch (2026-08-14). The settings tabs stay mounted at opacity 0 by design, so every continuous (trigger-less) animator inside a tab must pin its phases on `\.settingsTabIsSelected`.
- Continuously animated pill subviews (equalizer bars, meters) must animate transforms (`scaleEffect`), not layout (`frame` sizes), and isolate their rendering with native `CALayer` content or `.drawingGroup()`. Otherwise SwiftUI flattens them into the pill's shared drawing layer and every animation frame re-renders that layer on the CPU — text glyphs included, whose CoreGraphics bitmap buffers accumulate ~1 MB/s of resident memory per recording session (reachable, so `leaks` reports zero).
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
- Keep the two lifecycle notification names, authenticated socket contract, and
  Mirador microphone UID stable; Mirador depends on them.
- Treat an explicit microphone UID as exclusive: restore it silently after route
  changes and never warm/restart it while healthy. If absent, wait without a
  fallback; only system-default mode follows the current input.
- Route asserting AVAudioEngine calls through `AudioEngineGuard`; materialize,
  bind and read formats on the disposable deadline queue, quarantining the same
  route epoch on a HAL hang. Teardown only through `teardownAndRetire`; release
  retired engines after route quiescence and retry exceptions after route settle.
- Never use a zero-length read as the EOF signal on `AVAudioFile` — reading at
  exact EOF throws; gate reads on `framePosition < length`.
- Whisper-family engines hallucinate on silent/short takes ("Thank you.",
  repetition loops, glossary echo — covered by public regression tests).
  Two layers stop this and both must stay: the Local AI Server request always
  sends `vad_filter=true` (kills silence hallucinations AND trailing-silence
  repetition loops), and every batch engine result passes through
  `WhisperHallucinationFilter` (punctuation debris, loop collapse, vocabulary
  echo → the no-speech flow). Keep the vocabulary in `prompt`: hotwords-only
  requests measurably lose punctuation/casing in regression fixtures.
- Local AI Server transcriptions preflight `GET /health` (3 s timeout) before uploading: any HTTP response — including 404 on servers without that endpoint — counts as alive; only transport failures throw. Do not remove it — without the preflight a powered-off server hangs the dictation for the full scaled request timeout (2–10 min).
- Skip synthetic `Cmd+V` when Secure Keyboard Entry is active; leave text on the clipboard.
- The history retranscribe/re-polish path must not drive live `appState` or overlay.
- Hotkey registration should fall back to the default combo when registration fails, and re-arm `Esc` after mid-session re-registration.
- Keep Release artifacts `arm64` unless Intel support is explicitly re-approved.
