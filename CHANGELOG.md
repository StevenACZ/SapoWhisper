# Changelog

All notable changes to this project are documented in this file.

Based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

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

### Documentation

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

### Files

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

### Performance Results (10.5s recording, Deepgram Nova-3)

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
