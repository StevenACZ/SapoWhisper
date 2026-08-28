# Security

## Supported Versions

Only the latest release receives security fixes. Updates ship through an
in-app Sparkle channel: the app checks the appcast published on GitHub
Releases once a day and shows a quiet notice; nothing downloads until the
user clicks Install. Update archives are EdDSA-signed and verified against
the public key embedded in the app before installation. Manual installs
remain available — download the newest DMG from GitHub Releases and verify
its published SHA-256.

## Secret Handling

Do not commit:

- API keys
- Google ADC or service account JSON files
- Refresh tokens
- `.env*` files
- Local recordings, except the synthetic public fixtures under `TestAssets/LocalAITranscription/`
- Logs, crash reports, DMGs, archives, or notarization/signing files
- Signing private keys, certificates, provisioning profiles, notarization credentials, or local Xcode user data

The app stores user-provided cloud credentials and optional local-server bearer tokens in the macOS Keychain (one consolidated item); only non-secret presence hints (key names) are mirrored to UserDefaults. Credentials should never appear in source control.

## Reporting

For security-sensitive issues, do not post secrets or private recordings in public issues. Report privately via GitHub Security Advisories ("Report a vulnerability" on the repository's Security tab). If that channel is unavailable, open a minimal public issue that describes only the affected area and wait for a private follow-up.

## Data Handling Model

SapoWhisper is bring-your-own-key: cloud STT and AI-polish requests are sent directly from the app to the provider the user configured, authenticated with the user's own API key (sent in request headers, never in URLs). There is no intermediary backend and no telemetry; the optional daily update check is a single unauthenticated fetch of the Sparkle appcast from GitHub Releases that carries no identifiers or usage data and can be turned off in Settings. Dictation history (transcripts and WAV audio) is stored locally under the user's Library and relies on OS account permissions plus FileVault when enabled; it has no additional app-level encryption, and history exports contain raw transcripts.

## Runtime Hardening

Public builds use Hardened Runtime, Developer ID signing, notarization, stapled
tickets, and EdDSA-signed Sparkle updates. SapoWhisper is not App Sandbox
contained because its global hotkey, Accessibility-assisted paste, and
cross-application workflow require user-granted system permissions outside a
container. It therefore runs with the normal file access of the signed-in user;
install only notarized releases and configure only providers you trust.

Companion apps cannot request microphone capture through distributed
notifications. Remote dictation uses a same-user Unix socket that validates
the Mirador Host audit token, bundle identifier, and Apple signing Team ID
before accepting a command. Lifecycle notifications are unauthenticated,
payload-free hints; companions must confirm recording state through the signed
local socket before acting on them. They contain no transcript, audio, or
device payload.

## Public Repo Boundary

The public repo should contain source code, app assets, shared Xcode metadata, dependency lockfiles, build scripts, formatting config, and contributor docs. Local maintainer notes and release artwork stay ignored unless they are scrubbed and intentionally published.
