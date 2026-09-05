# Contributing

Thanks for helping improve SapoWhisper.

## Setup

Install Xcode, its Metal Toolchain component, and `gitleaks` (`brew install gitleaks`).
The vendored MLX package needs Metal shaders from Xcode; plain `swift build`
does not produce a working local transcription runtime.

```bash
xcodebuild -downloadComponent MetalToolchain
make tools
make ci-check
```

Open `SapoWhisper.xcodeproj` in Xcode and run the `SapoWhisper` scheme.

## Workflow

```bash
make format
make lint
make script-tests
make test
```

- Keep changes focused and small. Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing subsystem boundaries or lifecycle behavior.
- Do not commit credentials, recordings, DMGs, logs, crash reports, local docs, or signing files. The only committed audio is the reviewed, hash-pinned public fixture set in `TestAssets/LocalAITranscription/` and the four bundled app sounds in `SapoWhisper/Resources/Sounds/` (`start.wav`, `stop.wav`, `success.wav`, and `error.wav`). No user recording is an exception.
- Keep Release output Apple Silicon only unless Intel support is explicitly re-approved.
- Use `make release-check` before release-size or packaging changes.
- `make ci-check` (lint + secret/audio scan + script tests + Debug build + unit tests) is the local PR gate.
- Finish active dictations before running app-hosted tests. Tests and previews use isolated preferences and storage; physical microphone tests require explicit opt-in.
- The History replay script checks aggregate/redacted output; it is not a full live-engine parity gate for the app's recognition prompt, language, or VAD settings.
- `gitleaks` is required: `brew install gitleaks`.
- The project intentionally has no hosted CI; contributors must include the local gate result in the PR.

## Pull Requests

Before opening a PR:

```bash
make ci-check
git diff --check
```

Include:

- What changed.
- How it was verified.
- Any permission, signing, or privacy impact.

## Signing

The tracked project uses local ad-hoc signing for contributor builds. Maintainers
keep Apple Development and Developer ID settings in an untracked `Signing.xcconfig`
and configure notarization outside the public repo. Keep daily-use installations
development-signed; validate distribution artifacts separately.

## Release preparation

Keep pending changes under `Unreleased` in [CHANGELOG.md](CHANGELOG.md). Before
packaging, run `make release-check` and `make secrets-scan`. Release input checks
reject untracked or ignored files inside the synchronized `SapoWhisper/` source
directory so local files cannot silently enter the app bundle.

The eventual release also requires the version/build update, Developer ID signing,
notarized and stapled app and DMG, a ZIP of that app, and a signed Sparkle appcast.
Validate the mounted DMG and extracted ZIP before publication; the README or a
successful development build alone is not evidence that distribution is ready.
