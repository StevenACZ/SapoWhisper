# SapoWhisper Agent Notes

Compact public-safe operating notes for coding agents. Keep this file free of
credentials, personal paths, private transcripts, private audio, local server
addresses, and machine-specific workflow details.

## Product

- macOS menu bar speech-to-text app.
- Main flow: press `Option + Space`, speak, stop, then paste with clipboard + `Cmd+V`.
- `Esc` twice within 2.5 s cancels an active dictation (the first press only arms: the pill heartbeats and shows "Esc again to cancel" — `EscapeCancelGate`) without transcribing or pasting, preserving captured audio as a cancelled History entry; pending-start cancels create no row. The same double press cancels an in-flight batch or streaming transcription and AI polish (the pre-persisted row resolves to cancelled and is offered as continue-previous). Re-transcribing an entry clears its continue-previous offer.
- The overlay dock chip opens an in-pill quick history (recent transcripts, copy, prev/next paging, current-engine re-transcribe, jump to the full History window). It is deliberately minimal — no pin, AI polish, audio download, or duration.
- Minimum macOS: 14.0.
- Release target: Apple Silicon only (`arm64`, M1 and newer).
- Main target: `SapoWhisper` in `SapoWhisper.xcodeproj`.
- Dependencies resolve through Xcode SwiftPM; the local STT engine is the vendored `LocalPackages/MLXWhisper` package.

## Architecture

- Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing the affected subsystem; its ownership and behavioral guardrails are required constraints.
- Keep capture, streaming lifecycle, failover, history persistence, and polish policy in their existing shared owners.
- Preserve the engine set, history, permission onboarding, auto-paste, auto-ducking, saved WAV history, and retry UI.
- App and tests use Swift 6 with complete strict concurrency. App defaults to MainActor; XCTest declares isolation explicitly. Do not widen unsafe isolation to silence diagnostics.
- Route preferences through `AppPreferences.defaults` and file storage through `AppRuntimePaths`. Tests/previews must never share production preferences, history, caches or background startup effects. Keep the hardware opt-in limited to its explicit read-only input selection.
- Preserve the authenticated companion socket, lifecycle notification names, and microphone UID contract.
- History processing must not take ownership of the live dictation state or overlay.
- Benchmark prompt changes against [BENCHMARKS.md](BENCHMARKS.md); preserve dated evidence and its limitations.

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

- Apply the capture, persistence, polish, and window invariants in [ARCHITECTURE.md](ARCHITECTURE.md#guardrails).
- Every captured or merged WAV keeps its recovery marker until durable History ownership or deliberate deletion. Preserve merge sources until the combined pending row exists; recovery must skip live owners regardless of file age.
- Credentials belong in Keychain; configuration checks use `KeychainStore.hasValue`, not credential reads.
- Never show an action that cannot execute in the current state; derive visibility and execution from the same predicate.
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
- `make ci-check` runs lint, secret/audio scans, script tests, a Debug build, and unit tests.
- Run `git diff --check` before staging or reporting a patch done.
- For public changes, scan the diff for credentials, private paths, local addresses, raw transcripts, and private workflow details before commit/push.

## Packaging

- Read the tracked `scripts/package_notarized_dmg.sh` and the `notarized-dmg` target in `Makefile` before packaging; local signing configuration stays outside the public repo.
- For release-like local testing, keep app name `SapoWhisper.app`, bundle id `oli.SapoWhisper`, and Release `arm64`.
- Use the repo Release build from `make release-check`.
- Every distributed container and app needs its own ticket: notarize and staple
  the app before creating the DMG, then notarize/staple the DMG and ZIP that app.
  Validate mounted/extracted apps with `stapler` + strict `codesign`; use `ditto`
  for ZIP extraction, and keep readonly DMG/plist/architecture checks.
