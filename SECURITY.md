# Security

## Secret Handling

Do not commit:

- API keys
- Google ADC or service account JSON files
- Refresh tokens
- `.env*` files
- Local recordings
- Logs, crash reports, DMGs, archives, or notarization/signing files
- Personal Apple Developer Team IDs or local Xcode user data

The app stores user-provided cloud credentials locally on the user's Mac. They should never appear in source control.

## Reporting

For security-sensitive issues, do not post secrets or private recordings in public issues. Open a minimal report that describes the affected area and share sensitive details only through a private maintainer-approved channel.

## Public Repo Boundary

The public repo should contain source code, app assets, shared Xcode metadata, dependency lockfiles, build scripts, formatting config, and contributor docs. Local maintainer notes and release artwork stay ignored unless they are scrubbed and intentionally published.
