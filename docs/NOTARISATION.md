# Signing and notarisation

**Decision, 2026-11-09: notarise.** Ship signed Developer ID builds with a stapled
Apple ticket. Until the account below exists, the download stays ad-hoc signed and
the first-launch instructions stay in the README, the Get started page and the FAQ.

## Why

The people this is for own a WhatsApp backup, not a developer certificate. The
first screen they meet should not be a security warning.

- macOS 15 and later have no right-click bypass. An unverified app stops with
  *Apple could not verify "Saga" is free of malware* and the only way through is
  **System Settings → Privacy & Security → Open Anyway**, inside an hour of the
  blocked launch, with a password. That is a lot to ask before the app has shown
  anything.
- The warning lands hardest on this kind of software. "Apple could not verify it"
  is a bad answer from an app asking to read your message archive, whatever the
  checksum says.
- The cost is fixed and small: the Apple Developer Program is $99 a year at Apple's
  US price (local pricing varies), one account, and the packaging path already
  exists in `scripts/release.sh`.
- Retro-fitting it costs more than doing it first. Notarising after an announced
  launch spends the launch on the caveat instead of the app.

## What the shipped build is now

Measured against the released `Saga.dmg` (1.0.1), not inferred:

| Check | Result |
|---|---|
| `codesign -dv Saga.app` | `Signature=adhoc`, `flags=0x2(adhoc)` |
| `xcrun stapler validate Saga.app` | "does not have a ticket stapled to it" |
| `xcrun syspolicy_check distribution Saga.app` | `Adhoc Signed App` (warning) and `Notary Ticket Missing` (fatal) |
| `security find-identity -v -p codesigning` on the build Mac | 0 valid identities |

The app runs fine locally. The problem is only distribution to someone else's Mac.

## What it needs

1. An Apple Developer Program membership (annual, identity-checked at enrolment).
2. A **Developer ID Application** certificate with its private key in the login
   Keychain. Enrolment publishes the account holder's name as the certificate's
   team name.
3. A `notarytool` Keychain profile, created interactively — never in the repo or a
   `.env` file.
4. Hardened-runtime testing of the parts that reach outside the app: Contacts
   (TCC), the bundled `saga-mcp` helper, ADB child processes and local model
   servers. The release script already signs the nested helper before the app with
   `--options runtime --timestamp`; these paths have not been tested under a real
   signature yet.

Then `DEVELOPER_ID_APPLICATION=… NOTARY_KEYCHAIN_PROFILE=… scripts/release.sh --notarize`
signs, submits, waits, staples and validates the app, then does the same for the
DMG. [RELEASE.md](RELEASE.md) has the full checklist, including the clean-account
Gatekeeper test that proves the result on a machine that is not this one.

## What changes when a notarised DMG ships

One pass, in this order, on the release that carries the ticket:

- `README.md` — the Download paragraph loses the approval steps and says the build
  is signed and notarised; the "What it doesn't do yet" bullet goes away.
- `site/get-started.html` — replace the ad-hoc paragraph with nothing more than
  "drag it to Applications and open it".
- `site/faq.html` — drop the *Why does macOS say it can't verify Saga?* entry.
- `CHANGELOG.md` and the release notes — the Gatekeeper sentence becomes "signed
  and notarised", a better line than the apology.
- `docs/RELEASE.md` — the clean-user checklist is the gate, not a pending item.
- This file — replace the decision with the date the first notarised build went
  out, and keep the checks table as the record of what was wrong before.

Do not describe a build as notarised until `xcrun stapler validate` and a
quarantined download on a clean account both pass.

## If the account is not taken up

Ad-hoc shipping is a legitimate choice for an open-source Mac app. It stays
defensible as long as the instructions are exact — the common failure is telling
someone to open Privacy & Security when they never triggered the block, so no
button is there. That is why the current copy leads with the failed launch, names
the one-hour window and gives the macOS 14 right-click path separately.

Re-open the decision if any of these happen: the app is promoted to an audience
that is not already comfortable with Gatekeeper; a user reports being unable to get
past the warning; or App Store distribution is considered, which requires the same
membership.
