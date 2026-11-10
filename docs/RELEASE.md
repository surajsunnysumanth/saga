# Release preparation

Saga 0.2.0 is a **prepared preview**, not a published release. Do not tag, push, upload to Apple, or publish merely by following the local checks below. The release task authorizes local preparation only.

## Local rehearsal (no account required)

From the repository root on macOS with Swift 6:

```bash
swift build -c release
swift test
python3 scripts/test_release.py
scripts/make_icons.sh       # only when regenerating artwork
scripts/make_app.sh
scripts/release.sh --dry-run
```

`--dry-run` performs a real local app build, ad-hoc signing, DMG creation and verification. It never submits to Apple or publishes. Output is `build/release/dry-run/Saga-<VERSION>-<host-architecture>.dmg` and a `.sha256` sidecar. This DMG is **not for distribution**. Its image contains only `Saga.app`, `LICENSE.txt` and an Applications shortcut; no vault or repository copy. Rehearsal replaces only generated build artifacts, not user data.

`VERSION` is the sole app/DMG version source (currently 0.2.0); increment it and add a CHANGELOG entry for each release. Both plist version fields use this numeric three-part version. Current builds target the host architecture; test/package separately for arm64 and x86_64 before claiming both. The app bundle includes `saga-mcp`, not the separate `saga` CLI; CLI examples run the source-built tool.

## Signing and notarization (requires separate authorization)

Needs an Apple Developer account, a **Developer ID Application** certificate with private key in the login Keychain, and Xcode's `codesign`, `notarytool`, and `stapler`. Do not put passwords or certificates in the repo or `.env` files. Create a notarytool Keychain profile interactively using your own account/team and an app-specific password (or the Apple-supported API key flow). No account is supplied by this repository.

```bash
# Interactive prompts; do not append credentials to this command or commit them.
xcrun notarytool store-credentials saga-notary
# These values identify Keychain entries; they are not passwords.
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Organization (TEAMID)'
export NOTARY_KEYCHAIN_PROFILE='saga-notary'
# ONLY after authorization to upload the generated app/DMG to Apple:
scripts/release.sh --notarize
```

This signs the nested MCP executable before the app with hardened runtime and secure timestamps, verifies the signature, submits a temporary app ZIP, waits, staples/validates the app ticket and checks Gatekeeper. It then creates/signs the DMG, submits it, staples/validates it and checks the container policy. Failed commands stop packaging. ZIP and staging data are removed on exit. Logs may contain signing-team metadata: review/redact before sharing. No Git tag, remote push, GitHub release or deployment is performed. Output is `build/release/notarize/` with checksum. Do not distribute a failed or partially processed artifact; use only an all-successful run.

If notarization fails, retrieve the notarytool submission log using the submission ID and Keychain profile. Resolve the reported issue; do not add broad entitlements or disable validation. No extra entitlements are currently requested; Contacts, local model loading, USB helpers and child-process execution still need signed-build testing.

Maintainer references: Apple's “Customizing the notarization workflow” and “Notarizing macOS software before distribution” in Developer Documentation. Consult the installed `xcrun notarytool help` for credential options.

## Synthetic screenshots and design gate

Never run `Saga --snapshot` against the normal app-support directory for public assets. It renders the currently loaded library, which can include private text, names and search snippets.

1. Build `saga` and run `saga demo --out build/demo` into a new/disposable directory.
2. Use the isolated GUI invocation in [DEMO.md](DEMO.md). Confirm both support/index and vault paths point only to demo output; no real-vault preference, Keychain access, contacts import or USB action is allowed.
3. Run the isolated app's `--snapshot <output-directory>` (and `--dark` for the second pass), using a query present in the synthetic corpus.
4. Inspect dashboard, chat, search, person and Wrapped captures in light/dark. Check sidebar spacing, typography, green accent matching the generated icon, selection contrast, window resizing and clipping.
5. Review every image for private information; the reviewed WebP copies live in `site/assets/images/` (used by both the README and the website), so there is one checked-in copy per capture. Add README images with “synthetic demo” captions and verify relative links. Do not commit raw vault/index files. A GIF is optional; static screenshots satisfy the brief.

**Verified at integration (captures at `4d0d737`, contract re-checked at `c7fd819` on branch `swift`):** `saga demo --out <new-dir>` produced 720 messages / 4 chats / 3 named people; the isolated app rendered all five captures in light and dark; the real app-support folder was not modified. Dashboard, chat, search, person and Wrapped were inspected in both appearances (no clipping or contrast failures; fictional names only), and the README/website images were checked against a capture from the fixture then in use. The fixture has since been rebuilt: it is now 20,600 messages across 14 conversations and three years, with generated placeholder media, real public music links, a merged identity and deleted-on-the-phone rows, and the checked-in captures were regenerated from it (fixture v2, see [DEMO.md](DEMO.md)). Group Wrapped remains in-app only (no HTML exporter); feature screens that need link metadata, prune rules or an AI run are still not produced by the fixture. The refined 1024px PNG and multi-resolution ICNS are generated by `scripts/make_icons.sh`; they use the app's existing green palette.

## Clean-user / VM first-run checklist

A new macOS user or fresh VM is preferred; creating users/VMs requires operator permission and is **not performed by the release script**. A demo-isolated process on an existing account is useful but does not prove clean-user permissions or Gatekeeper behavior. Record OS, architecture, artifact version/checksum and pass/fail; do not record private content.

- [ ] Fresh account has no Saga support folder, preferences, saved key or tools.
- [ ] Downloaded notarized DMG passes Gatekeeper while quarantined; mounts; Applications drag-copy works; eject and launch installed copy.
- [ ] Icon, version and minimum OS are correct; no missing bundled resources or helper.
- [ ] First launch shows setup, not another account's library; cancellation is safe.
- [ ] Synthetic demo opens; search, navigation and Wrapped work; quit/relaunch retains only demo state.
- [ ] Contacts permission denied and allowed paths both have useful next steps (use synthetic contacts).
- [ ] No-phone/unauthorized-phone and missing-ADB paths explain recovery; downloading tools is user-requested.
- [ ] Existing backup import handles missing/wrong keys and insufficient disk space without modifying source files (synthetic fixtures only).
- [ ] Local AI absent/disabled still allows browsing; optional network features remain off until requested.
- [ ] MCP helper launches; notarized build can execute required local helpers.
- [ ] Remove only test-account Saga data when finished; never delete a real archive.

**Not yet verified:** fresh-user/VM first run, cross-architecture builds, real Developer ID signing, Apple notarization and quarantined-download Gatekeeper checks. They require an authorized account/environment. The dry run cannot certify them.

## Repository/privacy gate

MIT license is in `LICENSE` and is copied into the DMG. Third-party services/tools have their own licenses; none are bundled by the release script. Review screenshots, exports and new fixtures manually. `.gitignore` is a guardrail, not a data-loss prevention system: renamed files or `git add -f` can bypass it.

Before staging, scan tracked and nonignored files for the maintainer's name, known phone numbers, home/Drive paths and credentials. Report only counts/paths, not matched content. Use `git grep -l` rather than printing matching lines. Exclude only demonstrably synthetic fixtures when reviewing numeric matches (timestamps/JIDs/hash constants also match broad digit searches). Check `git diff --cached --stat` and staged file names for accidental data. Historical commits are not rewritten by this task; separately audit history before making a previously private repository public.

Examples of extensions/folders excluded: databases and sidecars, crypt backups, keys, contacts, NDJSON segments, vault/archive/media folders, certificates, environment files, build outputs and local verification directories. Never assume every private file has a recognized suffix.

## Acceptance status for this implementation lane

- README: current features, install, privacy, FAQ, troubleshooting; screenshots are synthetic demo captures.
- Icon: refined artwork and reproducible multi-size generation; visual inspection required after generation.
- Packaging: explicit local dry run vs authorized notarization, version 0.2.0, CHANGELOG and MIT license.
- Hygiene: expanded ignores; personal cloud-path/device details removed from published docs.
- Verified at integration: demo CLI output contract, isolated app launch, public demo screenshots and light/dark snapshot review.
- Environment-blocked: clean-user/VM and signed/notarized distribution checks above. No release is published.
