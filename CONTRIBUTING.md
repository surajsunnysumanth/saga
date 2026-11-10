# Contributing to Saga

Saga is a Mac-first WhatsApp archive app. Contributions should make it easier to keep, search and understand your own history without exposing anyone's conversations.

## Build and test

Use macOS 14 or later and a Swift 6 toolchain. Apple Intelligence features additionally need a compatible Mac, macOS 26 or later, and an available on-device model; they are not required for the core build.

```sh
swift build -c release
swift test
scripts/make_app.sh
```

The last command creates an ad-hoc-signed local app at `build/Saga.app`; it is not proof of Developer ID signing or notarisation. See [RELEASE.md](docs/RELEASE.md) for distribution requirements.

## Where changes belong

- `Sources/SagaCore`: archive readers, vault/index, search, analytics and model integration; no SwiftUI.
- `Sources/SagaApp`: the native app and first-run experience.
- `Sources/saga`: command-line entry point.
- `Sources/saga-mcp`: the local MCP entry point.
- `Tests/SagaCoreTests`: tests with made-up data.

The Python UI in the project's history is a frozen reference, not a second product to extend. The public tree ships the Swift app; see [ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Before proposing a change

Describe the problem, expected result, scope and how you will test it. For changes to vault formats, schemas, privacy boundaries or dependencies, agree on the design with maintainers first. Do not add a third-party dependency without that agreement. A feature brief is a proposal, not evidence that a feature has shipped.

Keep changes small and preserve unrelated work. Add regression tests for behaviour changes. Run the build, tests and app packaging command above, then report their actual results, along with anything you could not exercise. UI changes should include an app launch and visual check using synthetic data only. Do not launch a screenshot run against an existing personal library.

## Data and privacy rules

- Never attach personal backups, databases, keys, contact cards, logs containing conversations, or real screenshots to a patch, issue or discussion.
- Use fictional names, messages and identifiers in fixtures. Prefer a minimal synthetic database over a redacted personal one.
- Never log message text, contact identifiers or key material. Bug reports should use counts and error categories.
- Source backups are read-only. Preserve append-only vault segments and make user rules reversible.
- Treat the index as a rebuildable cache; persist durable settings in the vault configuration. Use message UIDs rather than rebuild-dependent row IDs for durable references.
- Explain network access before enabling it. Read [PRIVACY.md](PRIVACY.md), including the preview opt-in default and the MCP boundary.
- Report security issues privately; see [SECURITY.md](SECURITY.md). Do not use a public issue to provide an exploit involving private data.

## Pull request checklist

- [ ] The change has a clear purpose and does not include unrelated work.
- [ ] Behaviour changes have synthetic regression tests.
- [ ] Build, tests and local app packaging results are included.
- [ ] User-facing behaviour and privacy changes are documented.
- [ ] No real data, credentials, machine-specific paths or generated personal exports are included, including in commit history.
- [ ] UI evidence comes only from an isolated synthetic demo library.
- [ ] Known limitations and untested cases are stated plainly.

Follow the [code of conduct](CODE_OF_CONDUCT.md). Licensing is under the existing [MIT License](LICENSE); do not contribute material you do not have permission to share.
