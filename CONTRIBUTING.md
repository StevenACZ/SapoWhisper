# Contributing

Thanks for helping improve SapoWhisper.

## Setup

```bash
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

- Keep changes focused and small.
- Do not commit credentials, recordings, DMGs, logs, crash reports, local docs, or signing files. The only committed audio exception is the synthetic public fixture set in `TestAssets/LocalAITranscription/`.
- Keep Release output Apple Silicon only unless Intel support is explicitly re-approved.
- Use `make release-check` before release-size or packaging changes.
- `make ci-check` (lint + secret/audio scan + script tests + Debug build + unit tests) is the local PR gate.
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

The tracked project uses local ad-hoc signing for contributor builds. Maintainers configure Apple Development, Developer ID, and notarization outside the public repo when preparing release artifacts.
