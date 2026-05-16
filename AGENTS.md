# SapoWhisper Agent Notes

Project-local operating notes for coding agents. Keep this compact, operational, and free of credentials or private runtime data.

## Product

- macOS menu bar speech-to-text app.
- Minimum macOS: 14.0.
- Release target: Apple Silicon only (`arm64`, M1 and newer).
- Main target: `SapoWhisper` in `SapoWhisper.xcodeproj`.
- Dependencies are resolved by Xcode through SwiftPM and `WhisperKit`.

## Architecture

- `SapoWhisperViewModel`: recording, transcription, history, overlay, and paste orchestration.
- `AudioRecorder`: batch 16 kHz mono int16 WAV capture.
- `StreamingAudioCapture*`: Flux Live WAV history plus ordered LINEAR16 streaming.
- Engines: Apple Speech, WhisperKit, Google Cloud STT, Deepgram Nova-3, Deepgram Flux Live, Gemini Audio, ElevenLabs Scribe v2.
- Engine failures map to a shared `TranscriptionFailure` (`Core/TranscriptionFailure.swift`): a semantic `Kind` (auth, outOfCredits, rateLimited, timedOut, network, audioEmpty, audioCorrupt, ...), a user-facing localized message, an `isRetryable` flag, and a log-only `technicalDetail`. `AudioFileValidator` rejects missing/empty/corrupt recordings before they reach an engine.
- Transcript post-processing: optional AI polish through Vertex AI Gemini 3.1 Flash-Lite after any engine.
- AI polish has its own `polishing` UI state after transcription; keep it visually distinct from `processing/transcribing`.
- AI polish has an output-language selector; default behavior should preserve the transcript's dominant language unless the user explicitly chooses Spanish, English, or Translate to English.
- History: SQLite via `TranscriptionHistoryManager*`; audio retention via `HistoryAudioStorage`.
- Permissions: `PermissionService` plus guided permission windows/overlays.
- Diagnostics: prefer `SapoLog` categories `Overlay`, `Hotkey`, `Recording`, `AudioRoute`, `Flux`, `AI`, `Gemini`, `Lifecycle`, `MenuBar`, `Settings`, and `Performance`.
- Long-run slowdown investigations should start from unified logs plus
  `~/Library/Application Support/SapoWhisper/Diagnostics/runtime.jsonl`, especially after 3-4 day sessions.

## Diagnostics access

The app logs to Apple's unified logging system under the bundle id (`oli.SapoWhisper`) plus a rotating JSONL file capped at 2 MB.

Tail logs live in another terminal while the app runs:

```bash
log stream --predicate 'subsystem == "oli.SapoWhisper"' --info
```

Inspect the persistent diagnostics file (rotates to `runtime.previous.jsonl`):

```bash
tail -f ~/Library/Application\ Support/SapoWhisper/Diagnostics/runtime.jsonl | jq
```

Three OSSignpost intervals appear under the `Signpost` category for Instruments and `log stream`:

- `hotkey-to-overlay` — time from `show()` start to the overlay being visible.
- `polish` — end-to-end Gemini transcript polish span.
- `transcription` — reserved; not yet wrapped around the engine calls.

Transcription failures log one line tagged `failure=<Engine>/<kind>` with a `detail=` field carrying the HTTP status and a short response-body snippet; grep unified logs for `failure=` to triage engine errors.

Never log raw transcripts, prompts, Gemini responses, API keys, OAuth tokens, or service-account JSON. Prefer `chars=`/`bytes=` summaries over the actual content.

## Guardrails

- Do not remove engines, history, permission onboarding, auto-paste, auto-ducking, or saved WAV history.
- Keep Flux Live resilient to device route churn; inspect logs before changing startup/retry behavior.
- Map every engine failure to `TranscriptionFailure`; do not reintroduce per-engine error enums or collapse distinct HTTP statuses (401 auth vs. 401 out-of-credits vs. 403 plan vs. 429 rate) into a single "invalid API key" message.
- Keep AI polish non-blocking: if Gemini fails, the app must paste/save the raw transcript and record AI metadata.
- Keep AI polish prompts conservative: no invented details, no decorative Markdown emphasis by default, preserve technical terms, and use vocabulary/replacements only as recognition context.
- Do not log raw transcript content, credentials, access tokens, or service-account JSON.
- Keep Release artifacts `arm64` unless Intel support is explicitly re-approved.
- Do not force-add ignored local docs (`docs/`, `DMG/`) without explicit approval.

## Verification

```bash
make format
make lint
make ci-check
make release-check
```

The Makefile uses Xcode's bundled `swift-format`; no separate formatter install is required.
Default format/lint targets only inspect changed Swift files to avoid large legacy formatting diffs.

Manual equivalents:

```bash
xcodebuild -project SapoWhisper.xcodeproj -scheme SapoWhisper \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ./build/audit-debug build

xcodebuild -project SapoWhisper.xcodeproj -scheme SapoWhisper \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath ./build/audit-release clean build

scripts/measure_release_bundle.sh \
  build/audit-release/Build/Products/Release/SapoWhisper.app
```

Current note: the `SapoWhisper` scheme has no configured test action.

## Packaging

Read `DMG/README.md` before creating a DMG. Verify signing/notarization before making public release claims.

### Production-like quick test DMG

When the user wants a build to test locally as the current production app, generate a DMG that preserves the production identity as much as possible:

- Keep the app name `SapoWhisper.app`.
- Keep the bundle identifier `oli.SapoWhisper`.
- Keep the release target `arm64`.
- Use the repo's normal Release build, signed locally by Xcode (`adhoc` + hardened runtime is expected for local testing).
- Ask the user to install it over `/Applications/SapoWhisper.app`; do not tell them to run the app from Downloads or directly from the DMG when permissions matter.
- Note that macOS can still revalidate TCC permissions when the binary changes, especially with ad-hoc signing, but preserving the bundle id/name avoids unnecessary new permission identities.

Recommended flow:

```bash
make release-check

rm -f ~/Downloads/SapoWhisper-<version>-<label>.dmg

create-dmg \
  --volname "SapoWhisper" \
  --volicon "./SapoWhisper/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
  --background "./DMG/dmg_bg_final.png" \
  --window-pos 200 120 \
  --window-size 600 520 \
  --icon-size 100 \
  --icon "SapoWhisper.app" 150 310 \
  --hide-extension "SapoWhisper.app" \
  --app-drop-link 450 310 \
  --no-internet-enable \
  ~/Downloads/SapoWhisper-<version>-<label>.dmg \
  ./build/audit-release/Build/Products/Release/SapoWhisper.app
```

Verify the DMG and the app inside it before reporting it ready:

```bash
hdiutil verify ~/Downloads/SapoWhisper-<version>-<label>.dmg

MOUNT_DIR=$(mktemp -d /tmp/sapowhisper-dmg.XXXXXX)
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" \
  ~/Downloads/SapoWhisper-<version>-<label>.dmg

/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIdentifier' \
  -c 'Print :CFBundleShortVersionString' \
  "$MOUNT_DIR/SapoWhisper.app/Contents/Info.plist"

codesign --verify --deep --strict --verbose=2 "$MOUNT_DIR/SapoWhisper.app"
codesign -dv --verbose=2 "$MOUNT_DIR/SapoWhisper.app" 2>&1 | sed -n '1,30p'
file "$MOUNT_DIR/SapoWhisper.app/Contents/MacOS/SapoWhisper"

hdiutil detach "$MOUNT_DIR"
```

Expected verification for quick local production testing:

- `CFBundleIdentifier`: `oli.SapoWhisper`
- `CFBundleShortVersionString`: current repo version
- `codesign --verify`: valid on disk and satisfies designated requirement
- `Signature`: `adhoc`
- `CodeDirectory` flags include `runtime`
- executable format includes `Mach-O 64-bit executable arm64`
