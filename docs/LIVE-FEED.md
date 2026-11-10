# Live feed: decision and spike

*9 Nov 2026. Companion to `~/.hermes/cache/scratch/wm/whatsmeow-assessment.md`.*

## Decision

**Build the Go sidecar as a private spike. Do not ship it. Do not pair the primary number — with any flag, any override, any "just this once".**

The transport and the merge rules are now built and verified offline. What is *not* built is a pairing that has ever run: there is no spare SIM on this machine, so no QR has been scanned, no message has arrived over the protocol, and nothing here is evidence that the account survives contact. The gate that refuses to pair anything is the piece with a passing test; that is deliberate.

This is the assessment's "prototype only, behind a flag, never on the main number, not in 1.0" made concrete, and no further.

## What exists

`tools/sagalink/` — a separate Go module, not wired into `Package.swift`, not in CI, arm64 only.

| Piece | What it does |
| --- | --- |
| `protocol.go` | NDJSON over stdio. Four verbs in (`status`, `pair`, `unlink`, `shutdown`), events out (`message`, `edit`, `revoke`, `reaction`, `status`, `pair.qr`, `pair.code`, `paired`, `error`). |
| `pipeline.go` | The merge rules: event-id dedupe, merge-key dedupe, LID→PN canonicalisation, seconds→ms, per-chat watermark, fsynced journal before emit. No whatsmeow import, so it is tested without an account. |
| `gate.go` | `--spare-sim` **and** `SAGA_SPARE_SIM_ATTESTED=1` **and** `--primary-number`, plus a post-pairing check on the number WhatsApp actually returned. Refusal happens before the keychain is touched. |
| `link.go` | whatsmeow wiring: QR or 8-character code, receive-only handlers, media hashing behind `--media`, kill switch. Never sends, never marks read, never sends presence. |
| `internal/session` | Application Support layout, 0700/0600 enforcement, vault-location refusal, AES-256-GCM device sealing, sealed `store.DeviceContainer`. |
| `internal/keychain` | Sealing key in the login keychain, `AccessibleWhenUnlockedThisDeviceOnly` — no iCloud sync, no backup export, deleted with the session. |
| `testdata/fixture.ndjson` | Ten representative events: redelivery, phone-sent, group, LID chat, media, edit, reaction, revoke, and a month-old history line. |

## What was verified today

```
go vet ./... && go test ./...     # all green, 21 tests
go build -o sagalink .
sagalink -app-support $D -replay testdata/fixture.ndjson
  replay: 10 lines emitted=8 duplicate-merge-key=1 replay-behind-watermark=1
sagalink -app-support $D -replay testdata/fixture.ndjson -as-history
  replay: 10 lines emitted=0 duplicate-event=10
stat: Saga/link drwx------, state.json -rw-------, journal/*.ndjson -rw-------
```

- A message re-delivered under a new transport id lands once (`duplicate-merge-key`).
- The same fixture, replayed as a history sync against existing state, emits nothing: re-pairing cannot replay a month.
- A *live* message that arrives out of order is still accepted, flagged `late`.
- Edits, reactions and revokes are annotations (`chat|target|dir#kind`); they never overwrite the base row and never move the watermark.
- The LID chat resolves to the phone-number JID before the key is computed, using `--lid-map` or the live alt-JID lookup.
- Pairing refuses in all three failure modes, including a formatted-vs-unformatted primary number, and writes no session database.

## What is not verified

1. **Pairing.** No QR or code has been scanned. `PairPhone`/`GetQRChannel` are wired, compiled and gated; that is not the same as working.
2. **Real events.** The handler shapes match whatsmeow v0.0.0-20261107160454; no live event has passed through them.
3. **Ban exposure.** The entire reason for the gate. A spare SIM, a spare handset and two weeks of read-only uptime would be the minimum evidence; none of that exists here.
4. **Keychain behaviour from a sandboxed helper.** The container works under `go test`; app-sandbox inheritance for a spawned helper is untested.
5. **History parsing.** `events.HistorySync` is counted (`history-blob`), not parsed. On-demand gap-fill via `BuildHistorySyncRequest` is designed but not wired.
6. **Media.** `--media` downloads and hashes into `link/media/`; only the text path is exercised.

## The contract, if the rest is ever built

- **Custody.** `~/Library/Application Support/Saga/link/` — 0700, every file 0600, device keys sealed with a keychain key. `IsInsideVault` refuses any path under a Drive/CloudStorage folder or a `Whatsapp Vault` directory. Nothing is written to the archive by the sidecar.
- **Single writer.** The sidecar appends to `<link>/journal/<run>.ndjson` and emits the same record on stdout. Saga folds it into the vault; the vault keeps exactly one writer.
- **Merge key.** `chat|message-id|direction`, matching `msgstore.message.key_id` plus chat and direction. Timestamps normalised to ms at the boundary so live and backup rows compare directly.
- **Watermark.** Per chat, highest covered `(ts,id)`. Live traffic ignores it (out-of-order delivery is normal); history/replay traffic behind it is dropped. It is the anchor for any future gap-fill request.
- **Kill switches.** `{"cmd":"unlink"}` logs out the linked device and erases the session; the phone's *Linked devices* screen does the same without the app; `StreamReplaced` means another client took the session and the sidecar exits.

## Before anyone pairs anything

1. A spare SIM with its own WhatsApp account, active for a few weeks, on a spare handset — not the Motorola-if-it-matters, not the S25.
2. A written answer to "if this number is banned, what is lost?" that is not "the archive" — the archive is complete without the feed.
3. Two weeks of `status`/`undecryptable`/`temporary-ban` logging with zero outbound traffic before any merge into a real vault is enabled.
4. The primary number recorded in `--primary-number` on every invocation. The gate cannot check what it was not told.

## Cost to finish, unchanged

10–12 sessions for a prototype that has actually paired, 25–30 for a shippable beta (packaging, notarisation, reconnect, pairing UX, LID edge cases). The 25–30 buys a feature that only covers the window since the last backup, because pre-pairing history is a one-shot blob WhatsApp will not re-send.

## The alternative still looks better

The assessment's closing recommendation stands: make re-import cheap and add one-click "refresh from phone". It closes the same gap — days since the last backup — with no linked-device slot, no fingerprintable `whatsmeow` client, and nothing that can cost someone their number. This spike exists to make that comparison testable, not to change the answer.
