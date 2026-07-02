# Changelog

All notable changes to this project will be documented in this file.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Translation chip while recording** — the recording pill shows a translation chip that toggles the output language between "same as audio" and the last explicit target. The selection is sticky across dictations.
- **Interactive result pill** — the completed overlay shows the full polished text with copy and close buttons, plus a translation chip in the header that re-polishes into the new language without re-pasting. Hovering pauses the auto-dismiss.
- **Crash audio recovery** — recordings orphaned by an abrupt quit become re-transcribable History entries at next launch (repairing the truncated WAV header), and cancelling with Esc now confirms the audio was saved to History.
- **About window** — app identity, copyable version, feature chips, and GitHub links now live in a standalone About window opened from the menu bar, replacing the Info tab in Settings.
- **Vocabulary reaches local STT engines** — WhisperKit and the Local AI Server now receive the user's canonical vocabulary as a Whisper-style initial prompt (glossary of keyterms plus correction targets), so keyterms come out spelled right on the first audio-to-text pass instead of relying only on post-processing. Cloud engines keep their native keyterm biasing.
- **Recent dictation context** — AI polish now sees the user's last few dictations (30-minute window, tightly capped) as disambiguation context, so consecutive short dictations keep their shared topic and terminology instead of losing the thread between recordings.
- **Settings tab transitions** — switching tabs in Settings now cross-fades with a subtle scale instead of flipping instantly.
- **Personal context editor** — Settings → Prompts now edits the personal context block (who you are, which tools you use) that disambiguates technical terms in every polish request.

### Changed

- **Simplified menu bar popover** — the menu now holds the essentials: status header, record/stop, History, Settings, About, and Quit. The pickers, last transcription, auto-paste toggle, and welcome tour left the menu; auto-paste and the tour live in Settings → General, and language switching stays in the overlay chip and Settings.
- **One adaptive polish mode** — the AI mode picker (Clean-up, AI Assistant, Work Message, Translate) and custom prompt profiles were removed. A single benchmarked prompt now deletes filler and duplicated ideas in any language, keeps every instruction, name, and number, respects the user's tone, and shapes the output as the same kind of text the user spoke — no configuration needed. Validated case-by-case against real dictation history on local Qwen 3.5 4B and 9B before shipping.
- **Long dictations are polished in chunks** — transcripts past ~2k characters are split at sentence boundaries and each chunk is polished on its own, so cleaning quality on long rambling dictations matches short ones instead of degrading (small models under-clean or start summarizing on long inputs).
- **AI polish always runs** — the minimum-duration and short-text gates were removed together with their settings; every non-empty dictation is polished when the feature is enabled and configured, so results are consistent instead of silently skipping short recordings.
- **Overlay redesign: dock chip + droplet pill** — the dock chip is now a permanent slim bar hugging the screen edge, and every active state (recording, transcribing, result, errors) is a separate droplet pill that detaches from the chip when it appears and is absorbed back on dismiss, with squash-and-stretch chip feedback. This replaces the old background morph that could show an empty half-grown pill with clipped buttons.
- **Click outside to dismiss** — with a result open, clicking anywhere outside the pill collapses it back into the dock chip; clicking the chip toggles the last transcription open and closed.
- **AI polish prompt rebuilt around the user dictionary** — the polish prompt ranks its rules explicitly (output language, then user dictionary, then rewrite rules) and treats vocabulary as canonical spellings that map mishearings and must never be translated, so terms like product names survive Spanish-to-English dictation intact instead of coming out literally translated. Accepted AI suggestions and saved corrections feed the same dictionary. The translation rule is strict about leaving no source-language words behind, and the post-polish language check also verifies short results.
- **Correction targets survive translation** — the corrected side of automatic corrections now anchors the post-polish fidelity check alongside keyterms, so a translation pass can no longer undo a correction the deterministic pass already applied.
- Tightened `make install-dev` so the local reinstall path builds once, verifies Apple Development signing, and refuses ad-hoc installs that would reset macOS permission grants.

### Fixed

- **Overlay crash during animations** — the recording overlay now lives on a fixed transparent surface instead of a window that tracks content size; resizing the window during SwiftUI transition animations made AppKit throw from inside the display cycle and crash the app as soon as a recording started.
- **Result pill layout** — the chip row renders in a single stable row (the flow layout could place a chip outside the pill background), and the overlay window stays clamped inside the visible screen.
- **Auto-paste toggle in Settings now works** — the paste step used a separate non-persisted flag that only the old menu toggle changed, so the Settings toggle had no effect and the choice reset on every launch. Both now share the persisted setting.
- **AI suggestions no longer propose fragment mappings** — correctly-spelled fragments of a term ("push" → "git push", "Code" → "Claude Code") no longer surface as correction suggestions; accepting one would have rewritten normal prose everywhere. Only genuine mishearings of the full term qualify now.
- **Result pill readability** — the copied-text pill now uses proper line spacing and breathing room between the header and the transcript, so multi-line results no longer read as a cramped block.
- **Result pill no longer clips at the bottom of the screen** — under the overlay's ideal-size layout, the transcript reported one line of height and then drew all its real lines, pushing the chips and the dock chip past the fixed window edge (short dictations looked bottom-stuck and cut off). The pill now measures the text for real: short results hug their exact height (single lines keep the pill slim), and only genuinely long transcripts (~10+ lines) use the fixed scrollable viewport — so the pill never shows a mostly empty scroll area either.
- **Translation no longer fails on longer dictations** — the answered-the-request guard compared per-language request cues between the raw text and the polished text, so a faithful Spanish-to-English translation that turned "genera" into "generates" (matching no English cue) was rejected on every retry and the untranslated text shipped. With an explicit output language the cross-language cue check is skipped; direct answer/refusal detection still applies.
- **Clicking outside the result now closes it reliably** — the outside-click check trusted AppKit hit-testing over the overlay's fixed 640×440 surface, which reported hits on the transparent margin, so only clicks far outside the whole surface collapsed the pill. The collapse now compares against the measured frame of the visible pill and chip, so clicking anywhere else — right next to the pill included — closes it immediately.

## [2.5.1] - 2026-06-27

### Added

- GitHub Actions CI workflow that runs `make ci-check` (lint, secret scan, Debug build, tests).
- `make install-dev` / `scripts/install_dev.sh` for fast local reinstalls of the signed Release build without resetting macOS permissions.

### Fixed

- **Prompts tab dark mode** — AI polish behavior pickers (mode, output language, minimum duration) now use primary label color so their selected values stay readable in dark mode.
- **CI strict concurrency** — mark `PasteManager` paste callbacks as `@MainActor` so GitHub Actions builds pass with complete concurrency checking.

## [2.5.0] - 2026-06-25

### Added

- **Local AI Server (NVIDIA)** — added a LAN batch transcription engine for OpenAI-style STT endpoints, with Base URL/model settings, optional Keychain bearer token support, history filters, onboarding, import/export coverage, public benchmark fixtures, and a reproducible local STT benchmark script.
- **Local AI polish learning** — AI polish can now use a Local Server preset, feed compact accepted-correction memory into the prompt, and save likely speech-to-text correction suggestions for user review before they become automatic corrections.
- **Private history polish replay** — added a terminal-only replay script that can run saved history text or WAVs through the local STT + AI polish stack and report aggregate acceptance/suggestion metrics without printing private transcripts by default.
- **Audio upload quality profiles** — added a Microphone setting for batch recordings: Ultra fast, Medium (default), High, and Ultra original.

### Changed

- **AI polish offline behavior** — hosted polish providers pause while the Mac is offline, so local transcription can still paste raw text without disabling the user's saved AI polish preference. Custom polish endpoints are left to their own reachability.
- **AI polish provider setup** — local OpenAI-compatible polish servers now expose an editable Base URL, keep their API key optional and hidden by default, store model/Base URL/API key separately per provider, and show safer friendlier connection errors without leaking provider response details.
- **AI polish translation prompts** — the translation profile now uses the selected output language instead of a per-prompt "force English" toggle, and the prompts editor exposes the same target-language picker.
- **Batch audio fidelity** — batch recordings now use the selected upload profile, Deepgram preserves Ultra original WAVs, and ElevenLabs realtime replay converts saved WAVs back to 16 kHz Int16 before streaming.

### Fixed

- **AI polish stays non-agentic** — transcript polish now treats dictated assistant requests as inert text, retries obvious answer/refusal drift, and rejects outputs where the model answered, researched, calculated, or refused instead of polishing the transcript.
- **Cancelled dictations stay recoverable** — pressing Esc now saves captured audio as a cancelled History entry instead of discarding it, and successful re-transcription clears the cancelled state.
- **ElevenLabs realtime history replay** — re-transcribing saved audio with ElevenLabs realtime no longer crashes while finalizing the replayed audio buffer.

## [2.4.2] - 2026-06-14

### Fixed

- **Silent audio loss in history** — audio persistence is now serialized, so a concurrent storage-cleanup sweep can no longer delete a freshly recorded WAV before its history row references it.
- **Retry pasted stale or duplicated text** — retrying a dictation no longer reuses the previous recording's audio or pastes the result twice.
- **Deepgram Flux dropped the last words on stop** — the final end-of-turn that arrives right after the stream closes is preserved, so the tail of a Flux dictation is no longer lost.
- **WhisperKit concurrent inference** — the shared local model is guarded against overlapping transcriptions that could corrupt output or crash.
- **AI polish number fidelity** — numbers must now survive as an ordered, duplicate-aware sequence; a swapped, dropped, or altered number makes the guard paste the raw transcript instead.
- **Version display & visuals** — the menu surfaces the actually-shipped version, and disabled-state controls render correctly.

### Changed

- **Faster history at scale** — the history list pages incrementally with a stable sort order, so large histories load and scroll smoothly without duplicating or skipping rows.
- **Internal reliability hardening** — closed two audio-stack data races under Swift strict concurrency `complete`, confined the streaming-capture engine lifecycle to its setup queue, made vocabulary writes atomic, and dropped a per-buffer lock allocation in the recorder hot path. Engine readiness/busy state moved behind a small read-only `TranscriptionEngineSession` abstraction that retires duplicated branching, with new characterization tests. Added a GitHub Actions CI gate (lint, secret scan, build, tests).

### Security

- **Hardened diagnostics** — strengthened secret redaction in unified logs and corrected non-retryable 4xx error classification so client errors are not offered a pointless retry.

## [2.4.1] - 2026-06-13

### Fixed

- **ElevenLabs realtime retry & history replay** — these paths now read the API key from the Keychain instead of UserDefaults (which the launch migration empties), so retrying or re-running a realtime dictation no longer fails as "not configured".
- **Realtime network drop on stop** — when the final commit fails with a network error, transcript segments the server already committed are salvaged and pasted instead of being discarded.
- **History reprocessing no longer sticks the app busy** — retranscribing or re-polishing a history entry is isolated from the live app state and overlay, and a selected-engine-busy guard stops a new recording from colliding with an in-flight run.
- **WhisperKit on-demand reload** — a model finishing load mid-session can no longer reset an active recording, processing, or polishing state.
- **Faithful CJK translations** — the AI-polish fidelity guard lowers its length-ratio floor for dense-script (Chinese, Japanese, Korean) translation targets, so faithful translations are no longer discarded and pasted as raw text (the upper bound is unchanged).
- **AI polish fidelity guard no longer false-rejects punctuation fixes** — correcting a dictation typo inside a capitalized token (e.g. `AGENTS..md` → `AGENTS.md`) is accepted, while dropping the token's actual content still fails; numbers, URLs, emails, and vocabulary stay matched literally.
- **History "Polish with AI"** — the button is disabled when AI polish is turned off (it silently did nothing before), and a discarded polish (fidelity rejection or no configured provider) now shows a clear notice instead of nothing.
- **Global hotkey resilience** — registration falls back to the default combo when a custom or imported combo fails, and the Esc cancel key is re-armed after any mid-session re-registration.
- **Secure Keyboard Entry** — the synthetic Cmd+V paste is skipped while Secure Input is active; the text is left on the clipboard instead of posting keystrokes into a secure field.

### Removed

- Unused AudioEqualizerView.

## [2.4.0] - 2026-06-12

### Added

- **Stable local code signing (developer)** — copy `Signing.xcconfig.example` to the git-ignored `Signing.xcconfig` and set your Apple Development team ID: local builds then keep the macOS permission grants (Microphone, Accessibility, Input Monitoring) across reinstalls instead of re-prompting after every rebuild. Fresh clones still build ad-hoc with zero setup, and the release/notarization pipeline is unchanged.

### Changed

- **Fluid recording overlay** — the pill plays its entrance pop on every activation (not just the first one after launch) and appears at its final size instead of stretching from zero; state changes (Recording → Transcribing → AI polish → Copied) hand off sequentially inside a single morphing capsule, so the outgoing content fades out fast and the incoming one fades in right after instead of both being crushed while the capsule resizes.
- **Voice-reactive level meter** — the recording bars gate room noise to a flat baseline and expand the real speech band: staying silent reads as a flat line, quiet speech moves the bars subtly, and loud speech pins them to the top. The level ripples outward from the center bar with a fast attack and a smooth release instead of scaling all five bars in lockstep.
- Timer digits roll with a numeric transition, and the live "no voice?" hint animates in instead of snapping the pill wider.

### Fixed

- The recording pill no longer shows a faint hard-edged rectangle around it: the overlay window was clipping the capsule's drop shadow, and could clip the pill content itself while shrinking between states.

## [2.3.0] - 2026-06-10

### Added

- **Vocabulary usage metrics** — the Vocabulary tab opens with three tiles computed on-device from the last 200 dictations: saved-term capacity against the active engine's limit, average words per minute, and the most used terms; chips carry per-term usage badges. Pure read of existing history — no new tracking is stored.
- **Free-text polish model** — the AI polish model field accepts any model ID (anything on openrouter.ai/models, e.g. qwen or deepseek) with a curated suggestions menu beside it.
- **Clear all history from Settings** — the storage card in General gains a confirmed clear-all button that removes every entry and its audio, mirroring the History window action.
- **Esc cancels dictation** — while a recording session is active (including paused), pressing Esc discards the audio and hides the overlay instantly: nothing is transcribed or pasted. The key is only captured during an active session and never reaches the frontmost app.
- **Live try-it finish for the welcome flow** — the final step shows the user's actual configured trigger as animated keycaps (tap-tap rhythm for double-modifier triggers) with a "Try it right now" card; firing the shortcut celebrates with a "Perfect!" animation and closes the flow by itself while dictation continues.
- **Developer UI preview mode** — launching a Debug build with `SAPO_UI_PREVIEW=1` skips keychain access, hotkey event-tap registration, and startup permission windows, so ad-hoc rebuilds never re-trigger macOS consent prompts while iterating on UI; `SAPO_UI_PREVIEW_SCREEN=history|welcome|settings` (plus `SAPO_UI_PREVIEW_WELCOME_STEP`) opens that window directly for screenshots. The unit-test host gets the same bypass automatically. Normal user launches are unaffected.
- **Sleep/wake residency** — On system sleep any active dictation stops cleanly: the WAV is preserved and the entry is saved as failed with retry available. On wake the app re-validates the global hotkey, refreshes the audio device caches, and re-runs the input preflight.
- **Hotkey watchdog** — The global hotkey re-enables or re-creates itself if macOS silently kills the event tap, checked on every wake and every 10 minutes.
- **Offline fast-fail** — With no network, cloud engines fail instantly with a clear network error (before the mic even opens) instead of burning the request timeout, and the menu bar shows an offline hint that clears on reconnect. Local WhisperKit dictation is unaffected.
- Per-dictation performance log line (`perf stop→paste totalMs=… stages={tail,finalize,engine,polish,paste,persist}`) plus a daily resident-memory log line, so latency and long-run memory are provable from sanitized logs.
- `make idle-cpu-note` prints the manual idle-CPU (0%) verification procedure.
- Native transcription-language menu with Auto plus 15 common languages shared by the supported providers.
- **OpenAI-compatible AI polish provider** — AI polish now talks to any `chat/completions` endpoint (OpenRouter by default, OpenAI, Groq, or a custom URL such as Ollama). Paste an API key, pick a model (default `openai/gpt-5.4-nano`), press Test, done. The key is stored in the macOS Keychain.
- **Fidelity guard for AI polish** — Polished text is checked against the raw transcript (length ratio + anchor tokens: numbers, URLs, names, vocabulary). If the AI drifts, the raw transcript is pasted instead and the entry is marked `rejected_fidelity`.
- History engine filter now includes ElevenLabs and an "Other engines" bucket for entries created by removed engines.
- **Animated Welcome flow** — A five-step onboarding window (welcome → permissions → choose your engine → optional AI polish → ready) guides first-run setup: WhisperKit downloads a model with a progress ring, Deepgram/ElevenLabs keys validate inline, and the AI polish step is prominently skippable. Re-openable any time from the menu bar ("Welcome tour"); a menu hint appears while the engine is unconfigured.

### Changed

- **Vocabulary tab redesigned** — alphabetical chips with hover-revealed delete and usage badges, live ElevenLabs limit validation while typing a new term, and real empty states for empty lists and fruitless searches.
- **Prompts tab decluttered** — the provider configuration collapses into a one-line summary once it is usable (the keychain is only read when it expands), the behavior pickers became equal-height tiles with a compact "fidelity at max" badge, and the prompt editor shows an unsaved-changes dot, disables Save without changes, and asks before deleting a profile.
- **Info tab simplified** — privacy is listed per engine with icons and the version copies itself on click; the how-it-works list was removed. The hotkey tab centers its content vertically.
- **AI polish output language now translates faithfully** — the output language picker offers the full 15-language catalog, and when the transcript is in another language the target is authoritative: the prompt requires a faithful full translation, and the fidelity guard checks only translation-invariant anchors (numbers, URLs, emails, vocabulary) instead of rejecting the translated text. Picking an explicit target resets the transcription language to auto so the spoken language is detected.
- **Auto-ducking is a smooth fade** — system volume ramps down over ~400 ms starting the instant recording begins (the start beep rides the top of the ramp) and ramps back over ~250 ms, replacing the delayed single-step drop.
- **History window redesigned as a two-pane reading layout** — wider sidebar (search with one-tap clear, real empty states for no history / no results) and a single wide reading pane that replaces the cramped third-column inspector: relative-date header with engine and language chips, a visible action bar (Copy, Polish with AI, re-transcribe, download audio, pin, delete), a stats strip (duration · words · language · AI polish · audio), larger transcript typography, and a scrubbable audio player card. Failed entries show their failure code with a prominent re-transcribe button. The window now opens at 1000×640.
- **Welcome flow polish** — removed the dead band above the progress dots left by the transparent titlebar, and the AI polish step's form now follows its header instead of floating mid-window.
- **Faster stop→paste** — Auto-paste fires the moment macOS confirms the target app is active (150 ms hard fallback) instead of polling; history persistence (audio copy + database insert) moved off the paste path to a background task; the overlay switches to "transcribing" the instant stop is pressed; the WAV finalize runs on the audio queue without blocking the UI.
- **AI polish timeout reduced from 8 s to 5 s**, and the polishing overlay now shows a per-second countdown.
- The audio input preflight now genuinely warms the input route (brief muted engine start), so the first dictation after a device change starts faster; the mic indicator may blink briefly on device changes. The preflight also defers itself while any recording is active.
- Auto-ducking always restores the saved volume after recording; the old "respect user volume" heuristic could leave Bluetooth audio permanently low.
- The menu bar popover re-measures at most once per 150 ms and reuses its content controller across opens.
- **Engine portfolio reduced to three engines** — WhisperKit (local), Deepgram (Nova-3 batch / Flux live), and ElevenLabs (Scribe v2 batch / realtime). Apple Speech, Google Cloud STT (V1 and Chirp), and Gemini Audio were removed, along with the entire Vertex AI / service-account stack. Existing selections migrate automatically (Deepgram key → Deepgram, ElevenLabs key → ElevenLabs, otherwise WhisperKit) and stored Google credentials are purged.
- AI polish default mode is now literal clean-up: remove fillers and self-corrections, fix punctuation, never paraphrase.
- The app no longer requests the Speech Recognition permission; only Microphone and Accessibility are needed.

### Removed

- The personal-context editor and the effective-prompt preview were removed from the Prompts tab to keep it focused on prompt profiles. A previously saved personal context still applies to polish runs.

### Fixed

- Pinning the transcription language to the same language AI polish outputs no longer shows the pinned-language warning; it only appears when the two languages actually diverge.
- The double-tap trigger now starts working the moment Accessibility is granted on a fresh install: the event tap used to be created before the permission existed and stayed dead until the user changed the hotkey or relaunched. The app now polls until the process is trusted and re-registers automatically.
- The global hotkey kept dying after visiting Settings: a focused API-key SecureField leaves macOS Secure Keyboard Entry enabled, which silently starves the hotkey event tap. Settings/history/welcome windows now drop the first responder when they close or resign key, releasing secure input immediately.
- The macOS keychain consent prompt fires at most once per build and only when a key is actually needed: launch and settings "is X configured" checks read non-secret presence hints, saving keys re-creates the item instead of re-prompting on every keystroke, and a denied read can no longer wipe stored keys or make the welcome flow reappear for configured users.
- The welcome flow is strictly for new users now: closing it explicitly marks it as seen, so it never auto-reopens on later launches.
- Removed the dead band below the welcome footer button (the titled + fullSizeContentView window is taller than its content rect, so the fixed-height content floated centered).
- History audio playback now uses one shared player: switching entries or closing the detail pane reliably stops playback, and the progress timer only runs while audio plays.
- Transcription language now acts as provider recognition context only, avoiding hidden AI translation or output-language forcing.
- ElevenLabs Scribe batch and realtime now pass explicit languages as `language_code` hints for the spoken audio without changing the transcript into another language.
- Deepgram Flux Live now keeps the native language picker enabled and sends supported selections as `language_hint`.
- AI polish stays fully disabled unless the user explicitly enables it, including forced/manual polish paths.
- ElevenLabs vocabulary hints now send saved terms first, include auto-correction replacement values as recognition hints, and sanitize hints before cloud requests.

## [2.2.1] - 2026-05-29

### Changed

- Distribution-only patch: the macOS DMG is built with Developer ID signing,
  secure timestamping, notarization, and stapling. No app behavior changed.

## [2.2.0] - 2026-05-23

### Added

- **ElevenLabs Scribe Realtime v2 mode** — Added a low-latency ElevenLabs mode that opens a WebSocket at recording start, streams PCM 16 kHz mono while saving a local WAV backup, buffers committed transcript segments only, and pastes once after stop.
- **ElevenLabs mode selector** — Settings now lets users choose between `ElevenLabs Scribe v2` batch mode and `ElevenLabs Scribe Realtime v2`, with batch kept as the default.
- **Editable AI prompts and personal context** — Settings now has a Prompts tab where users can create per-destination prompts (Codex, Slack, custom) and a personal context block reused by every AI polish run.
- **AI transcript polish** — Added an optional post-processing step that can refine completed transcripts with Gemini 3.1 Flash-Lite on Vertex AI after any transcription engine.
- **AI polish progress state** — The recording overlay and menu bar now distinguish transcription from AI polishing so users can see when local/STT work has finished and Gemini formatting has started.
- **AI polish history metadata** — History now keeps the raw transcript, final transcript, AI status, model, mode, and error metadata, with an action to run AI polish later.
- **AI polish output language** — Added an output language selector so polish can keep the transcript language, force Spanish, or force English.
- **Google Cloud guided setup** — Engine settings now show a clearer step-by-step Google Cloud setup flow with gcloud login detection and JSON import as a secondary credentials path.
- **Unified transcription failure model** — New `TranscriptionFailure` type maps every engine's raw failure (HTTP status, `URLError`, decode error, audio problems) into 13 semantic kinds, each with a localized message, a retryable flag, and a log-only technical detail.
- **Engine HTTP failure diagnostics** — Every transcription engine now logs the real HTTP status and a response-body snippet on failure (`failure=<Engine>/<kind> detail=...`), instead of swallowing 401/403/429 with no log line.
- **Recording pre-flight validation** — `AudioFileValidator` rejects missing, empty, or corrupt recordings with a clear message before they reach an engine.
- **Localized failure strings** — Added `failure.*` keys (ES/EN) for the unified failure messages.

### Changed

- **ElevenLabs realtime paste behavior** — Partial transcripts are never typed into the active input; realtime mode only pastes the final buffered text once recording ends.
- **ElevenLabs vocabulary limits** — Scribe batch now accepts up to 1000 keyterms with the current Scribe v2 limits, while realtime uses the stricter 50-term / 20-character limit. Replacements still run locally after transcription.
- **ElevenLabs realtime failure behavior** — Realtime failures keep the saved WAV in failed history and show manual retry without automatically falling back to batch.
- **Overlay performance** — Removed the `.id(stateCategory)` subtree rebuild so recording → transcribing → polishing transitions no longer recreate the pill on every state change.
- **Settings tab churn** — Tabs stay alive in a single ZStack toggled by opacity; switching segments no longer rebuilds the entire tab subtree.
- **Vocabulary filtering** — Keyterm and replacement filters are cached in `@State` and only recomputed on data or query changes, not on every body redraw.
- **Release logging cleanup** — Removed raw `NSLog`, deactivated runtime JSONL snapshots, and kept signposts Debug-only while preserving sanitized unified logs for failure triage.
- **Public repo hygiene** — Dropped the tracked local agent skill cache and ignored `.agents/`, `.claude/`, and `skills-lock.json`.
- **Logging unification** — Migrated every `print()`/`NSLog()` call to `SapoLog`; only metadata gets `privacy: .public`. Google Cloud STT no longer logs response bodies, and `TranscriptAIResult.mode` is now a single `String?` instead of the previous dual enum/id path.
- **Deepgram settings layout** — Moved AI polish above Vocabulary so the post-processing toggle is easier to find immediately after Deepgram setup.
- **AI prompt formatting** — Mode IA now avoids decorative Markdown emphasis by default, preferring compact plain labels, paragraphs, bullets, and backticks only where they improve readability.
- **AI prompt grounding** — AI polish now treats vocabulary and replacements as recognition context only, avoiding added details that were not present in the raw transcript.
- **Agent notes** — Kept `AGENTS.md` compact, public-safe, and focused on the current release workflow.
- **Honest transcription errors** — Failures now distinguish invalid API key, exhausted credits, rate limit, plan restriction, network loss, request timeout, server error, empty/corrupt audio, and interrupted recording, instead of labeling every `401` as "API key inválida".
- **Adaptive engine timeouts** — Request timeouts for ElevenLabs, Deepgram batch, Google Cloud, and Gemini now scale with the clip length (120–600 s) instead of a fixed value.
- **Overlay retry affordance** — The error pill only offers "Retry" for retryable failures (network, timeout, rate limit, server error, interrupted recording) and its message can span two lines.
- **Per-engine error enums removed** — Replaced `ElevenLabsError`, `DeepgramError`, and `GoogleCloudError` with the shared `TranscriptionFailure`.

### Fixed

- **ElevenLabs quota messaging** — `quota_exceeded` responses that mention API key quota now map to `outOfCredits` instead of the invalid API key/auth message.
- **Vertex model routing** — Moved Gemini 3.1 Flash-Lite calls to the Vertex AI `us` multi-region endpoint so enabled polish does not fall back to the raw transcript because of a regional 404.
- **ElevenLabs long-recording timeouts** — ElevenLabs Scribe used a fixed 30 s request timeout that could abort longer recordings before the API responded; the timeout now scales with the audio length.
- **Sanitized provider errors** — HTTP error snippets now redact token/key-like values, and Google token refresh failures no longer surface raw token endpoint bodies.

## [2.1.3] - 2026-05-08

> Patch focused on long-run performance observability after multi-day menu bar, overlay, settings, and recording slowdowns.

### Added

- **Runtime diagnostics file** — Added a rotating JSONL diagnostics log at `~/Library/Application Support/SapoWhisper/Diagnostics/runtime.jsonl` with uptime, memory, screen layout, frontmost app, and contextual state snapshots.
- **Long-run performance snapshots** — Added unified logging for app launch, activation, screen changes, hotkey presses, recording toggles, overlay show/hide, popover opens/closes, Settings opens, and Settings tab switches.
- **Recording route context** — Recording diagnostics now include state, engine, Deepgram mode, pending start/stop flags, audio/Flux activity, paused state, duration, session identifiers, and selected microphone.
- **Multi-monitor overlay diagnostics** — Overlay positioning logs now include the target screen geometry and final window origin so monitor-specific latency can be correlated later.

### Changed

- **Menu bar refresh behavior** — Hidden popover updates are now skipped and visible updates are coalesced, reducing unnecessary SwiftUI/AppKit layout work during long app sessions.
- **Settings device refresh** — General Settings now refreshes audio devices from a background queue and logs refresh timing, avoiding main-thread work when opening Settings.

## [2.1.2] - 2026-05-06

> Patch focused on keeping Flux Live audio upload work off the main thread while preserving enough telemetry to debug long recordings.

### Added

- **Flux audio sender** — Added a dedicated Flux audio sender that serializes WebSocket audio chunk uploads off the main actor.
- **Flux sender telemetry** — Added sender stats for enqueued, sent, failed, pending chunks, bytes sent, maximum queue depth, maximum send wait time, and send timeouts.
- **Flux stop timing logs** — Added drain and stop timing diagnostics so long recordings can show whether audio upload, stream finalization, or transcription handling is the slow part.

### Fixed

- **Flux Live UI latency** — Audio chunks are no longer uploaded from the main-thread streaming path, reducing UI stalls while recording or stopping long Flux sessions.
- **Flux completion resilience** — Flux stop handling now reports sender completeness and fallback context when the stream cannot finish cleanly.

## [2.1.1] - 2026-05-05

### Changed

- Release builds now target Apple Silicon only (`arm64`), reducing the Release `.app` from 29,624 KB to 20,624 KB (-30.38%) and the main executable from 17,708 KB to 8,712 KB (-50.80%).
- Removed a stray source `Info.plist` that was being copied into `Contents/Resources` while Xcode already generated the real bundle Info.plist.
- Removed the unused legacy `MenuBarIcon` asset set; state-specific menu bar icons remain unchanged.
- Added `scripts/measure_release_bundle.sh` to repeat app size, resource, bundle, and architecture audits; the local arm64 test DMG is 13 MB after `create-dmg` compression.
- Added a lightweight Swift formatting/linting workflow using Xcode's bundled `swift-format`, `make format`, `make lint`, `make ci-check`, and optional Lefthook pre-commit formatting.
- Applied the new Swift formatting baseline across the source tree to keep future diffs focused.
- Improved public repo hygiene by removing the tracked Apple Developer Team ID, documenting local ad-hoc signing, tightening ignored private artifacts, and adding concise contributor/security docs.

## [2.1.0] - 2026-05-01

### Added

- **Deepgram Flux Live mode** — Added a near real-time Deepgram streaming mode using `flux-general-multi` over WebSocket, with live PCM upload while the user is speaking and final text ready almost immediately after stop.
- **Deepgram mode selector** — Settings now lets users choose between Nova-3 batch mode and Flux Live mode.
- **Flux capture pipeline** — Added a dedicated streaming audio capture path that writes the same saved WAV used by history while simultaneously sending ordered LINEAR16 chunks to Deepgram.

### Changed

- **Deepgram language behavior** — Flux Live automatically uses `Auto` language and locks the transcription-language picker until the user switches back to Nova-3.
- **Deepgram history labels** — History entries now distinguish `Deepgram Nova-3` from `Deepgram Flux Live`.
- **Vocabulary handling** — Flux Live sends Deepgram keyterms and applies saved word replacements locally after receiving the final transcript.

## [2.0.1] - 2026-05-01

> Patch release focused on recording overlay responsiveness, hotkey safety, and capture diagnostics after the SapoWhisper 2.0 launch.

### Changed

- **Recording overlay rendering** — Reduced high-frequency redraws by throttling audio meter updates and only refreshing the recording timer when the displayed second changes.
- **Overlay presentation** — Kept the recording overlay visible through fast restart/reopen paths so the UI no longer appears to disappear during recorder recovery.
- **Capture diagnostics** — Added lightweight timing logs for overlay presentation, hotkey handling, input setup, and first audio buffer arrival to make performance issues easier to diagnose.

### Fixed

- **Hotkey safety** — Blocked new recording starts while a transcription is still active, preventing accidental overlapping sessions and stale transcription completions.
- **Input startup resilience** — Avoided unnecessary device refresh work when the selected microphone is already known, reducing startup overhead before recording begins.

## [2.0.0] - 2026-04-28

> Public release for the Deepgram Nova-3 batch engine, transcription history, guided permissions, and long-run audio stability work.

### Added

- **Deepgram Nova-3 batch transcription** — Added Deepgram as a high-accuracy cloud engine with API key setup, custom keyterms, and word replacements.
- **Transcription history** — Added a searchable history window with date grouping, engine filters, favorites, metadata inspection, audio playback, audio download, and re-transcription with any engine.
- **Guided permission onboarding** — Added a Missing Permissions window, live permission status rows, menu bar reminders, and System Settings helper overlays for Microphone, Speech Recognition, and Accessibility.
- **Auto-ducking** — Added optional system volume reduction during recording with smart restore after transcription.
- **Preferred microphone sync** — Added persistent preferred microphone handling that keeps the macOS global input aligned across route changes.
- **Public release metadata** — Added an MIT license file, shared Xcode scheme, and trackable Swift package resolution for reproducible public builds.

### Changed

- **Recording pipeline** — Optimized hotkey-to-recording latency, pre-warmed the overlay, reduced redundant audio engine work, and switched recordings to compact 16 kHz mono int16 WAV files.
- **Deepgram architecture** — Replaced the early streaming experiment with a simpler REST batch flow that uploads the completed recording.
- **Overlay UI** — Redesigned the recording overlay into a compact adaptive pill with pause/resume, terminal states, deterministic equalizer animation, and multi-monitor positioning.
- **Settings UI** — Modernized settings with native grouped forms, improved microphone testing, gain controls, and extracted the oversized engine settings view into smaller components.
- **History storage** — Split the SQLite history manager by setup, queries, actions, and audio file policy while adding cleanup for orphaned or oversized recording storage.
- **Release target** — Aligned the Xcode deployment target with the public requirement of macOS 14.0 or later.

### Fixed

- **Microphone permission detection** — Stabilized packaged-build microphone checks so the app no longer shows stale pending states after macOS already granted access.
- **Audio route changes** — Hardened recording and mic testing across AirPods, speakers, Bluetooth devices, and default input/output transitions.
- **Auto-paste timing** — Switched to adaptive frontmost-app polling to reduce paste misses after transcription.
- **Sound volume edge cases** — Fixed 0% sound volume playing at full volume and improved volume slider behavior.
- **Long-run stability** — Reduced overlay redraw churn, avoided stale recorder setups, trimmed accumulated audio files, and quieted permission polling.

## Microphone Permission Verification — 2026-04-24

> Fixed the last false-pending microphone state seen after installing the DMG while macOS already showed SapoWhisper enabled in System Settings.

### Changed

- **Audio input entitlement is now explicit** — Debug and Release builds include the SapoWhisper entitlements file, including `com.apple.security.device.audio-input`, so packaged builds keep the expected microphone capability.
- **Microphone permission checks now match real audio usage** — Added a dedicated microphone permission helper that combines AVFoundation status, `AVAudioApplication` status, and a guarded audio-input probe after returning from System Settings.
- **Permission refresh is quieter** — Permission windows and settings rows now update only when the granted set changes and no longer rewrite SwiftUI state every 0.5s.

### Fixed

- **Microphone stayed visually pending while enabled in System Settings** — Successful mic-test or recorder audio starts now mark microphone access as granted for the running session, preventing stale TCC reads from keeping the onboarding UI blocked.
- **Permission window could consume CPU while open** — Reduced polling and eliminated redundant state writes during permission refresh.

## Menu Bar Popover Animation — 2026-04-24

> Brought the native PeekOCR-style menu bar popover animation and anchored presentation into SapoWhisper.

### Changed

- **Native menu bar popover** — Replaced the SwiftUI `MenuBarExtra` host with an AppKit `NSStatusItem` + `NSPopover`, giving the top icon the same anchored popover animation used by PeekOCR.
- **Status icon press feedback** — Added a subtle click bounce to the SapoWhisper menu bar icon while preserving state-specific frog icons.
- **Settings and History routing** — Settings and History now open from the AppKit menu bar controller while sharing the same `SapoWhisperViewModel` instance as the popover.

### Fixed

- **Settings switches first render** — Settings windows now activate and redraw their hosted SwiftUI content on first presentation, with Sapo green switch tinting to avoid the initial all-blue toggle paint glitch.
- **Popover layout after rapid clicks** — The menu bar popover now rebuilds its SwiftUI host and debounces transition clicks before opening, preventing stale measurements from leaving a blank area above the content.
- **Popover bottom gap** — Removed the artificial minimum popover height so the window hugs the menu content instead of exposing an empty native background strip.
- **Missing permissions banner first paint** — Missing permissions are now calculated before the popover is built, so the warning is visible on first open instead of appearing only after an extra click.

## Permission Reliability + Long-Run Stability — 2026-04-24

> Stabilized macOS permission detection across relaunches/restarts, improved the missing-permissions onboarding surfaces, and reduced long-running UI/storage pressure.

### Added

- **Launch permission reminder** — SapoWhisper now opens the `Missing Permissions` window shortly after launch when Microphone, Speech Recognition, or Accessibility is missing.
- **Adaptive permission colors** — Permission windows, cards, and System Settings helper overlays now use Light/Dark-aware colors for readable contrast in both appearances.
- **History audio storage guardrails** — Saved recordings are cleaned up after history writes, removing orphan files and keeping storage within the configured cap.

### Changed

- **Stable app signing identity** — Debug and Release builds now use the configured Apple Development team/signing identity with hardened runtime enabled, helping macOS keep TCC permissions attached to the same app identity after restarts.
- **Permission status refresh** — The menu bar reminder refreshes when its window becomes active, so returning from System Settings immediately updates the visible state.
- **Recording overlay rendering** — The overlay was split into smaller pill components with a deterministic mini equalizer, reducing redraw churn during long sessions.
- **History manager structure** — SQLite setup, queries, actions, and audio storage cleanup were split into focused files to keep the manager maintainable.

### Fixed

- **Permissions appeared pending after reboot even when enabled in System Settings** — Stabilized signing and startup refresh behavior so macOS permission state is read consistently.
- **Missing permissions were only obvious after opening Settings** — Users now see the guided permission window on app launch when setup is incomplete.
- **Permission helper overlay was too dark in Light Mode** — Removed the hard dark/translucent treatment and switched to semantic adaptive surfaces.
- **Old saved recordings could accumulate over long runs** — Orphan cleanup and storage trimming now run after inserts and deletes.

## Guided Permission Onboarding + Public Repo Cleanup — 2026-04-19

> Added a PeekOCR-style guided permissions flow for SapoWhisper and cleaned the public-facing docs/UI so the repository is ready to share publicly.

### Added

- **Guided permission onboarding** — New `Missing Permissions` window that keeps all required permissions visible at once, even after some become active.
- **Live permission status updates** — Microphone, Speech Recognition, and Accessibility now refresh automatically when returning from System Settings.
- **Floating assistant overlay** — A contextual overlay opens on top of the exact System Settings privacy panel and explains the next step.
- **Accessibility drag helper** — If SapoWhisper is not listed yet in Accessibility, the overlay provides a draggable app card to drop into the list.
- **Permission banner in the menu bar** — The main popover now warns about missing permissions and links directly into the guided flow.
- **Permission rows in Settings** — General and Hotkey settings now show inline permission status rows with activation actions.

### Changed

- **Recording flow now checks required permissions first** — Starting a recording opens the guided onboarding when a blocking permission is missing instead of failing later in the pipeline.
- **Launch no longer triggers surprise permission prompts** — Permission requests are now driven by explicit onboarding actions.
- **Apple Speech permission state is refreshed on app activation** — The app picks up Speech Recognition changes as soon as the user comes back.
- **Menu bar UI was split into smaller components** — Keeps the codebase within the project size limits while integrating the new permission reminder UI.
- **Permission onboarding UI was polished** — Shorter microphone helper copy, a taller hero card, and a roomier missing-permissions window improve readability during setup.

### Changed

- **README updated for public release** — Added the guided permission flow to the feature/installation docs and removed hardcoded personal repository links.
- **Public-facing copy sanitized** — In-app credits and localized strings were updated to avoid personal attribution in the shared build.
- **Source headers cleaned up** — Removed personal author headers from tracked Swift files.

## Auto-Ducking — 2026-04-11

> Automatically lower system audio volume during recording so background music/videos don't interfere with transcription.

### Added

- **Auto-Ducking** — New feature that reduces system output volume while recording and restores it when done. Configurable in Settings > General > Auto-Ducking.
- **Volume reduction slider** — Adjustable from 10% to 100% reduction (default 80%). At 80%, system volume drops to 20% of its original level during recording.
- **Smart restore** — If the user manually changes volume during recording, the app respects their choice and doesn't override it on restore.
- **Safety net** — Volume is force-restored on app termination to prevent getting stuck at low volume.
- **Core Audio HAL integration** — Uses `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` with per-channel fallback, no AVAudioSession (macOS doesn't support it).
- **Localization** — Full ES/EN support for all Auto-Ducking UI strings.

**Files touched:**

- New: `Core/Managers/AutoDuckingManager.swift`
- Modified: `Constants.swift`, `SapoWhisperViewModel.swift`, `AppDelegate.swift`, `GeneralSettingsTab.swift`, `Localizable.strings` (EN/ES)

---

## Audio Route Resilience + Music Playback Fix — 2026-04-09

> Hardened audio capture against input/output device changes while music is playing. Recording and mic test no longer touch output routing, startup now retries transient Core Audio failures, and the app stays responsive during route transitions.

### Fixed

- **Recording could fail with `-10875` / `outputHWFormat invalid` after switching output devices** — The recorder and mic test were forcing `AVAudioEngine` to initialize an output path during capture, which broke startup when macOS was still reconfiguring speaker/AirPods/MX4 output. Both flows are input-only again.
- **Music playback could cut out when starting a recording** — Removed the "silent output" redirection logic that created a competing output route inside `AVAudioEngine`.
- **Rapid start/cancel/start could leave stale recorder setups behind** — Recorder startup now uses a setup generation token so obsolete starts are cancelled and cleaned up before they can publish state.
- **Device switches could still miss retries even after the async recorder change** — Recovery now retries transient route errors like `-10875`, invalid hardware format, and missing first input buffers within a bounded retry budget.
- **Preferred microphone could drift away from the macOS global input** — After output route changes (AirPods, speakers, Bluetooth headphones), SapoWhisper could still record from the selected mic while System Settings silently switched the native input to another device. The app now reconciles route changes and restores the preferred microphone as the global default input.

### Changed

- **Audio route tracking is now thread-safe** — `AudioDeviceManager` uses protected snapshots for available devices and route transition timestamps instead of reading mutable published state across queues.
- **Settle delay now includes output changes too** — New route-settle logic accounts for default input, default output, and device list transitions.
- **Core Audio listeners moved off the main thread** — Route listeners now run on a dedicated queue and only publish UI-facing state back to main.
- **Mic test monitor is serialized and recorder-aware** — It now restarts through a dedicated control queue, uses the same route settle delay, and suspends automatically while the main recorder is active.
- **Preferred mic selection is now a persistent system-level source of truth** — If the app preference is a specific device, route changes re-apply it globally; if that device disappears, SapoWhisper automatically falls back to `System Default` instead of forcing a stale selection.

### Added

- New diagnostic logs for default output transitions and transient recorder retry attempts.

---

## General Settings UX Redesign + Gain Fix — 2026-04-08

> Modernized the General Settings tab to use native `Form` + `.formStyle(.grouped)`, fixed mic test sample recordings not applying gain, and improved slider layouts.

### Fixed

- **Mic test gain not applied to samples** — "Grabar muestra" was writing raw buffers without gain, so playback sounded identical at any gain level. Now `bufferWithGain()` creates a gain-adjusted copy before writing, matching what `AudioRecorder` sends to transcription engines.
- **Volume at 0% played at max** — `SoundManager` used `volumeDouble > 0 ? ... : 1.0` which treated 0% as "not set" and fell back to 100%. Now uses `object(forKey:)` to distinguish unset from zero.
- **Audio micro-cut when recording starts** — Selecting a non-default mic in SapoWhisper caused a brief audio glitch because the system had to switch devices at recording time. Now syncs the system default input device when the user selects a mic in Settings, keeping the device always active.
- **Sample metadata text barely visible** — Changed from `size: 9` + `.quaternary` to `.caption2` + `.tertiary`.

### Changed

- **Native Form layout** — Replaced custom `SettingsCard` wrappers with `Form` + `.formStyle(.grouped)` for native macOS System Settings appearance. Controls auto-align with labels on the left and controls on the right.
- **Combined language sections** — "Idioma de transcripción" and "Idioma de la App" merged into a single "Idioma" section, reducing vertical scroll.
- **Volume slider** — Uses Slider's native `label`/`minimumValueLabel`/`maximumValueLabel` API for proper Form column integration. Range `5%–100%` with 5% steps. Toggle handles full mute.
- **Gain slider** — Same native Slider API. Range `1–40x`. Removed speaker icons and step tick marks for a cleaner track.
- **Toggle labels simplified** — Descriptions moved to Section footers instead of inline VStacks.
- **LanguageButton** — Updated to `Capsule()` + `strokeBorder` with adaptive background color.
- **AudioLevelMeterView** — Extracted subviews (listeningBadge, errorBanner, gainSlider, sampleRecordingSection). Removed redundant panel background in Form context.

### Added

- Localization keys: `settings.language_header`, `settings.gain` (ES/EN).

---

## Audio Device Switch Fix — 2026-04-08

> Fixed recording failures when switching audio devices (e.g., AirPods → speakers) by querying hardware format directly via Core Audio instead of relying on AVAudioEngine's stale format cache.

### Fixed

- **Recording fails after audio device switch** — After disconnecting/connecting headphones, the first recording attempt would fail with error `-10868` (format mismatch). Root cause: `inputNode.outputFormat(forBus:)` returns a cached format (e.g., 44100 Hz) that doesn't update after `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` changes the device to one with a different sample rate (e.g., 48000 Hz). Fix: query the actual hardware format via Core Audio's `kAudioDevicePropertyStreamFormat` and pass it explicitly to `installTap`.
- **AVAudioConverter created with stale format** — Converter was created upfront from `inputNode.outputFormat` before the first buffer arrived. Now created lazily from `buffer.format`, guaranteeing it matches the actual hardware format.

### Changed

- `bindPreferredInputDevice` now returns the device's actual hardware format (queried via Core Audio).
- `AudioRecorder.startRecording()` compares cached vs hardware format and uses hardware format for the tap when they differ.
- Added `queryDeviceInputFormat(deviceID:)` helper that reads `kAudioDevicePropertyStreamFormat` directly from Core Audio.
- Added diagnostic logging: format override detection, lazy converter creation details.

---

## History Re-transcription & Audio Persistence — 2026-04-07

> Full history rework: re-transcribe with any engine, persistent audio storage, download recordings, and real-time updates.

### Added

- **Re-transcribe from history** — "Re-transcribe with..." button in inspector lets you pick any engine and re-process saved audio.
- **Audio always saved** — Recordings are now persisted for both successful and failed transcriptions, enabling future re-transcription and playback.
- **Download audio** — Export button in the inspector saves the recording to disk via NSSavePanel.
- **Real-time history** — History window auto-refreshes when a new transcription completes while open.
- **Engine filter labels** — Sidebar filter uses full names with colored dots instead of abbreviations (DG/GC/WK/AS).

### Changed

- `DeepgramStreamingTranscriber` renamed to batch-oriented architecture (REST only, no WebSocket).
- Audio player now visible for successful entries (previously only for failed retries).
- Engine selector in re-transcribe proposes the user's current engine first.

### Fixed

- Fixed audio playback showing wrong file after refreshing the history list while an entry was selected.

---

## Performance & Overlay Stability Follow-up — 2026-04-07

> Follow-up optimization pass focused on reducing cloud payload size, lowering memory pressure, and making the floating recording overlay reliable again.

### Changed

- **Recorder now writes 16 kHz / mono / int16 WAV directly** — smaller files, less conversion work for cloud engines, and lower memory pressure during capture.
- **Deepgram upload path uses passthrough for int16 WAV** — skips recompression when the on-disk audio is already compact.
- **Google Cloud reads LINEAR16 in chunks** — avoids loading large float buffers into memory before request encoding.
- **Auto-paste wait is now adaptive** — it polls for the target app to become frontmost instead of sleeping a fixed 100–150ms every time.
- **WhisperKit unloads when leaving the local engine** — releases model memory when the user switches back to a cloud engine.
- **History search/filter moved into SQLite** — added DB tuning (`WAL`, indexes) plus query-side filtering to avoid loading and filtering the full history in memory.
- **Overlay presentation hardened** — fixed race conditions around show/hide reuse, render state is set before presentation, and the panel is positioned using the active screen instead of relying only on `NSScreen.main`.

### Fixed

- Fixed a crash when writing recorded audio after switching the recorder pipeline to int16 by matching `AVAudioFile`'s processing format to the converted buffers.
- Fixed the deprecated Deepgram API key `onChange` handler to the modern macOS 14 closure signature.
- Fixed the main-actor/sendable auto-stop timer warnings in `SapoWhisperViewModel`.
- Fixed an invalid overlay window collection behavior combination that could crash on launch during overlay prewarm.

---

## Performance: Hotkey & Transcription Pipeline — 2026-04-07

> Major latency reduction across the entire hotkey→record→transcribe→paste pipeline. Startup dropped from ~630ms to ~240ms, transcription from ~2.7s to ~1.9s.

### Changed

- **Overlay window pre-warmed on app init** — reused instead of recreated on each hotkey press, cutting overlay show time from ~64ms to ~30ms.
- **AudioLevelMonitor eliminated** — audio level metering now uses the same `AVAudioEngine` tap as the recorder, removing a second engine startup (~150ms saved).
- **Hotkey callback uses `MainActor.assumeIsolated`** — bypasses Swift Concurrency task scheduling for near-zero dispatch latency when already on main thread.
- **Audio recording starts synchronously** after overlay show (no deferred Task gap), reducing overlay→audio from ~356ms to ~30ms.
- **Tail padding (180ms) before stop** — captures final syllables that were previously truncated by immediate engine stop.
- **Sound players pre-cached in `SoundManager`** — all WAV files loaded into memory on init, eliminating ~20-70ms of disk I/O per play.
- **Deepgram audio compressed to int16 WAV** in-memory before upload (~2x smaller payload, no temp file).
- **Removed redundant `punctuate=true`** from Deepgram API — already covered by `smart_format=true`.
- **Dock icon updates skipped in menu-bar-only mode** — `LSUIElement=true` means no dock icon, so skip `NSApp.applicationIconImage` calls entirely.
- **Audio device changes skipped when already active** — `AudioDeviceManager` and `AudioRecorder` now check if the requested device is already the system default.
- **`AVAudioConverter` flush on stop** — drains remaining buffered samples before closing the audio file, preventing truncated endings.
- **History DB migration fixed** — `columnExists()` check before `ALTER TABLE` eliminates the `duplicate column name` warning on every launch.

**Performance results (10.5s recording, Deepgram Nova-3):**

| Metric | Before | After |
|--------|--------|-------|
| hotkey→overlay | ~64ms | ~30ms |
| overlay→audio | ~356ms | ~30ms |
| Total startup | ~630ms | ~240ms |
| Compression | N/A | 1ms (in-memory int16) |
| stop→result | ~2.4s | ~1.8s |
| stop→paste | ~2.5s | ~1.9s |

---

## Deepgram Nova-3 + History Redesign — 2026-04-06

> Deepgram Nova-3 as a batch transcription engine (unified with all other engines) + full transcription history.

### Added

- `DeepgramStreamingTranscriber` with Deepgram Nova-3 REST API for batch transcription.
- `VocabularyManager` for custom keyterms and word replacements (improves recognition of domain-specific words).
- `TranscriptionHistoryManager` with SQLite storage for transcription history.
- History window with custom `HStack` sidebar layout + `NSVisualEffectView` for native macOS look.
- History sidebar with date-grouped sections (Pinned, Today, Yesterday, This Week, This Month, Older).
- Sidebar toggle button with smooth `.easeInOut` animation via `@State` boolean.
- History detail panel with full text, `textSelection(.enabled)`, and inline `AVAudioPlayer` for saved audio.
- History inspector panel with metadata (engine, language, duration, words, audio status) and actions (copy, pin, delete).
- Manual search `TextField` with `.safeAreaInset` and segmented `Picker` for engine filtering.
- Pin/favorite support with `is_favorite` SQLite column and dedicated "Pinned" section.
- Context menu on history entries (copy, pin/unpin, delete).
- `HistoryEntry` model extracted to `Models/HistoryEntry.swift` with `DateGroup` and `EngineFilter` enums.
- `fetchAll()`, `toggleFavorite()`, and `delete()` methods on `TranscriptionHistoryManager`.
- Deepgram engine option in Settings with API key configuration.
- Vocabulary settings card with keyterms and replacement rules.
- Comprehensive Xcode previews for all overlay states and UI components.
- Localized error messages for Deepgram auth failures and audio capture errors.
- 30 new i18n keys for history view (Spanish/English).

### Changed

- **Deepgram switched from WebSocket streaming to REST batch API** — unified flow with all other engines (record → stop → transcribe).
- Removed WebSocket, keep-alive, partial transcript, and streaming overlay state.
- Deepgram now supports pause/resume during recording (same as other engines).
- `TranscriptionEngine.deepgramStreaming` renamed to `.deepgram`.
- `AudioRecorder` simplified: removed streaming buffer callback (`onAudioBuffer`).
- History window resizability changed from `.contentSize` to `.contentMinSize` with default size 800x550.
- Recording overlay redesigned: compact adaptive pill (content-sized, down from fixed 480px).
- Overlay uses `.fixedSize()` — each state wraps tightly around its content.
- All overlay states unified under the same Capsule pill design.
- Max audio gain increased from 3.0x to 10.0x for low-sensitivity microphones.

---

## Google Cloud STT V2 + Chirp 3 — 2026-04-04

> Google Cloud Speech-to-Text integration with dual-mode support: V2 (Chirp 3) via gcloud ADC and V1 (latest_long) via API key.

### Added

- `GoogleCloudTranscriber` with dual-mode: V2 (Chirp 3, best accuracy) and V1 (latest_long, API key fallback).
- `ServiceAccountManager` for Google Cloud ADC credentials — auto-detects `~/.config/gcloud/application_default_credentials.json`.
- `GoogleCloudConstants` with V2 endpoint configuration.
- Service account file import via NSOpenPanel + "Detect" button for gcloud ADC.
- Collapsible API Key section as V1 fallback in Engine settings.
- Step-by-step setup instructions for V2 (gcloud CLI) and V1 (API key) in settings UI.
- Full localization for Google Cloud setup instructions (Spanish/English).
- Google Cloud privacy info in About/Info tab.

### Changed

- Engine description updated: "Chirp 3: maximum accuracy. Requires internet and Google Cloud account."
- App subtitle and description updated to include Google Cloud as third engine.
- Privacy section updated with Google Cloud data handling info.
- float32 audio converted to LINEAR16 for both V1 and V2 Google Cloud APIs.

---

## Recording Overlay Redesign — 2026-03-09

> Complete redesign of the recording overlay as a sleek horizontal pill with pause/resume support.

### Added

- Horizontal pill overlay (440x56px, capsule shape) with `.ultraThinMaterial` background.
- Pause/resume recording with interactive button — audio segments concatenated seamlessly.
- `AudioEqualizerView` component with animated audio level bars.
- `FloatingSapoIcon` component with dynamic frog icon per state.
- `OverlayTimer` component for recording duration display (freezes during pause).
- `TranscribingIndicator` component with animated processing dots.
- Overlay states: recording, paused, transcribing, completed (with text preview), error.
- Auto-dismiss 2 seconds after transcription completion.

### Changed

- Overlay redesigned from 280x280 square to 440x56 horizontal pill at bottom center.
- Overlay positioned 60px from bottom edge, centered horizontally.
- `NSPanel` implementation allows interaction without stealing focus from other apps.
- Hotkey (⌥+Space) always stops the full recording, never pauses.
- Full localization updates for overlay states (Spanish/English).

---

## Sound Feedback System — 2025-12-10

> Custom WAV sound effects for recording states with independent volume control.

### Added

- 4 custom WAV sounds: `start.wav`, `stop.wav`, `success.wav`, `error.wav`.
- Volume control slider (20%–100%), independent of system volume.
- Sound settings card in General tab with toggle, volume slider, and "Test sound" button.
- `SoundManager` with `AVAudioPlayer` and configurable volume via `UserDefaults`.
- System sound fallback when WAV files are not found (Morse, Pop, Glass, Basso).
- Full localization for sound settings (Spanish/English).

### Changed

- DMG assets folder added to `.gitignore`.

---

## MVP Release — 2025-12-10

> First release — voice-to-text for macOS from the menu bar. Press a hotkey, speak, and text is transcribed and pasted.

### Added

- Menu bar app with audio recording and automatic transcription.
- Global hotkey (⌥+Space) to start/stop recording from any app.
- **Apple Speech** engine: online transcription via native Apple framework.
- **WhisperKit** engine: 100% local transcription with 5 downloadable models (tiny, base, small, large v3, large v3 turbo).
- Custom sapo frog icon for app icon and menu bar.
- Dynamic menu bar icons reflecting app state (idle, loading, recording, transcribing).
- Microphone selection with virtual device filtering.
- Real-time microphone level meter with gain control (0.5x–3.0x).
- Full English/Spanish localization with runtime language switching.
- Launch at Login via `SMAppService`.
- Recording overlay window (280x280) with real-time audio visualization.
- Unified settings with 4 tabs: General, Engine, Hotkey, About.
- Reusable settings components: `SettingsCard`, `EngineButton`, `LanguageButton`, `WhisperModelButton`, `HotkeyRecorderView`.
- Auto-paste transcribed text to clipboard and active app.
- Public README with installation and usage guide.
