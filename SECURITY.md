# Security

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

For security-sensitive issues, do not post secrets or private recordings in public issues. Open a minimal report that describes the affected area and share sensitive details only through a private maintainer-approved channel.

## Public Repo Boundary

The public repo should contain source code, app assets, shared Xcode metadata, dependency lockfiles, build scripts, formatting config, and contributor docs. Local maintainer notes and release artwork stay ignored unless they are scrubbed and intentionally published.
