# Security

## Supported Versions

Only the latest release receives security fixes. There is no auto-update
channel: update by downloading the newest DMG from GitHub Releases and
verifying its published SHA-256.

## Secret Handling

Do not commit:

- API keys
- Google ADC or service account JSON files
- Refresh tokens
- `.env*` files
- Local recordings, except the synthetic public fixtures under `TestAssets/LocalAITranscription/`
- Logs, crash reports, DMGs, archives, or notarization/signing files
- Personal Apple Developer Team IDs or local Xcode user data

The app stores user-provided cloud credentials and optional local-server bearer tokens in the macOS Keychain (one consolidated item); only non-secret presence hints (key names) are mirrored to UserDefaults. Credentials should never appear in source control.

## Reporting

For security-sensitive issues, do not post secrets or private recordings in public issues. Report privately via GitHub Security Advisories ("Report a vulnerability" on the repository's Security tab). If that channel is unavailable, open a minimal public issue that describes only the affected area and wait for a private follow-up.

## Data Handling Model

SapoWhisper is bring-your-own-key: cloud STT and AI-polish requests are sent directly from the app to the provider the user configured, authenticated with the user's own API key (sent in request headers, never in URLs). There is no intermediary backend and no telemetry. Dictation history (transcripts and WAV audio) is stored locally under the user's Library and is protected by FileVault, not by additional app-level encryption; history exports contain raw transcripts.

## Public Repo Boundary

The public repo should contain source code, app assets, shared Xcode metadata, dependency lockfiles, build scripts, formatting config, and contributor docs. Local maintainer notes and release artwork stay ignored unless they are scrubbed and intentionally published.
