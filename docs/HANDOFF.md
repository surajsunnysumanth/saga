# Handoff — 10 Nov 2026

Written because this session's context is full. Read this first in a new chat.

## Where the product is

- **App:** Saga 1.0.3 shipped and live. DMG 13,855,524 B, SHA-256 `569c4cf5…b917`. Release holds the in-DMG `Read me first.txt` (Gatekeeper paths + `xattr` alternative + checksum). Public repo `github.com/surajsunnysumanth/saga`, single squashed commit, author *Saga contributors <surajsunnysumanth@users.noreply.github.com>*, site on `gh-pages`.
- **Update check:** in the app — one request/day to `api.github.com`, Home banner + Settings → Archive → Updates, skip-version, on/off switch. 1.0.3 is the first build that can update itself.
- **Recent app work (all on `swift`, not pushed):** reactions + sticker import into the vault path (`aeb48cf`); Wrapped facts/grammar fixes (`0e0290d`, `d5b611d`, `80e00b6`); hearts/stickers/inside-joke fixes (`9933ff3`, `e558d1f`, `8b65e52`).

## Live data state

- Index: **703,690 messages, 9,805 chats, 58,388 media, 51,596 reactions** (❤️ 18,215, 😂 17,155), **2,341 stickers**.
- Vault segments unchanged except additive; `config/` holds `merges.json` (10 merges), `overrides.csv`, `phone-contacts.json` (699 contacts / 786 numbers), `prune.json`, `profiles.json`.
- Index backup before the reactions import: `vault_index.before-reactions.db` in Application Support.
- Inert leftover segment: `seg-20261110T104843-…-reactionsandstickers.ndjson.gz` (chat/md restatements only) — safe to delete.

## In flight when this was written

One subagent fixing three things (`deleg_70788637`):
1. Moments cards → `MESSAGE (N reacts)` + quoted replies underneath.
2. **Crash** when clicking "see message" from a Wrapped card (suspected stale message id after renumbering; must degrade, not trap).
3. Home module tiles not navigating (Chats tile dead).

Check `git log`/`git status` before assuming it landed; verify its crash test fails on the parent commit.

## Known gaps, honestly

- Media rows with **no recorded path** (~8,596) — importer gap, card `t_cccae789`.
- Compactor's `retained-*.db` omits reaction tables, so reactions on messages surviving only in older archives read low.
- Notarisation undecided — first launch needs *Privacy & Security → Open Anyway*.
- Android: assessment done (`docs/` notes) — verdict is **Saga Pocket** (viewer + media/backup companion), not a full port; full Android is honest only on rooted phones.
- whatsmeow live feed: assessed, verdict = private prototype on a spare SIM only; never the primary number.

## Conventions that keep biting

- Rebuild `build/Saga.app` with `sh scripts/make_app.sh`; `swift build --product SagaApp` does **not** update the bundle.
- GitHub Pages: build takes 1–3 min, then assets can serve from cache for 10 min (`max-age=600`). Verify with `?v=timestamp`, not a bare URL.
- Ship order: bump VERSION → universal DMG → release with `Saga.dmg` + `Saga.sha256` → delete previous release → snapshot to `main` (noreply) → `site` subtree to `gh-pages`.
- Never commit: vault data, keys, real names/numbers. Demo fixtures only.
- Person keys are last-ten digits or `lid:<id>`; merges live in `config/merges.json` and are re-applied on every rebuild.
