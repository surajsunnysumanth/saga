# Contacts and merging: where this stands

Written after a long session that hit its context limit. Read this first; it is the state, not a plan.

## What the user reports, in their words

- Merge suggestions propose **completely wrong pairs** (e.g. "Shagun Ohri" with `9833052771` + a stranger's `8861111364`).
- Contacts that are **already merged reappear** as suggestions.
- **Saved contacts show as unnamed** in the archive.
- Wants a **toggle** for weak matches, off by default.

## Root causes found so far

1. **The DM-handoff heuristic inferred identity from timing.** It paired a chat that went quiet with one that started later, if they shared a group. That is how a stranger got proposed. Fixed: a suggestion is rejected outright when members carry two different real names (`MergeSuggestions.swift`, in `Builder.add`).
2. **Placeholder names were usable as evidence.** 37 chats are literally "(unnamed group)"; 8,094 entries carry half-masked numbers like `+918****9745`. Fixed: `isUnresolvedLabel` rejects names containing "unnamed"/"unknown", any `*`, or fewer than two letters.
3. **Names were never imported.** Saga used to resolve from (a) WhatsApp's `wa.db` contacts table, which is root-only, (b) an old `contacts.vcf`, (c) manual overrides. The phone's own address book was not a source, which is why 8,094 of 9,747 chats showed numbers. **Fixed:** `PhoneContacts.names(in:)` now feeds `Resolver.resolve` (`Sources/SagaCore/Importer.swift`), wired from `VaultIndexer.build`. Precedence is per-chat override → saved contact → imported vCard/extra contacts → WhatsApp profile name → the number.
   - **Correction, measured 2026-11-08: this source is redundant on this vault.** `config/contacts.json` already held all 786 of the book's numbers (786/786, every name identical) from the earlier vCard import, and it is consulted three lines below the book in `Resolver.resolve`. So the book cannot add a name the archive did not already have. See "Why the saved names did not move the count" below.
4. **Numbers were displayed wrong.** `MergeView.phoneHint` printed the key's last ten digits with a `+` glued on, inventing a country code (`9833052771` → `+9833052771` instead of `+91 98330 52771`). It now only prints when the key is entirely digits.

## Verified, with tests

- `Tests/SagaCoreTests/MergePersistenceTests.swift` — 3 tests pass: a merge survives a fresh read; merging `a+b` then `b+c` folds to one group `a,b,c`; an empty file reads as no merges. **Storage is sound**, so a merge that disappears is an app-layer fault, not a format one.
- `MergeConfig.add` now re-reads after writing and throws `MergeWriteError.notPersisted` rather than silently losing the merge.

## Data pulled from the phone

`~/.hermes/cache/scratch/phone_contacts.json` — 786 unique numbers → name, from
`adb shell content query --uri content://com.android.contacts/data/phones --projection display_name:data1`.

Row count was 838; duplicates were collapsed **only** where all rows for a number agreed on the name.
This file carries names but **not** the address book's grouping: two numbers saved under one contact are
two separate entries here. Re-pull with `contact_id` in the projection to recover the grouping.

## "Changed their number" system messages

Implemented (`MergeReason.changedNumber`, weight 4, `Builder.addNumberChanges`), but **dormant**: the index
has 0 messages matching `%changed their number%`. WhatsApp likely stores the new number in a structured
column rather than in `text`. Do not expect this to fire without reading that column.

## Done, with tests

1. `PhoneContacts` reader in `SagaCore` reads `contact_id → [numbers], name` from
   `<vault>/config/phone-contacts.json`.
2. Saved names are a first-class source in `Resolver.resolve`: **override → saved contact → vCard/extra
   contacts → WhatsApp profile name → number**. A `lid:` chat has no number, so it is never renamed from the
   book (`Tests/SagaCoreTests/SavedContactNameTests.swift`, 5 tests).
3. Two numbers under one saved contact already produce a deterministic merge reason.
4. Number display prints the full international number.

**The names only appear after a library rebuild** — the index is a cache, and `chats.name` is written by
`VaultIndexer.build`.

## Why the saved names did not move the count

Measured on the live index (9,781 chats) and the 786-number book. **There is no key mismatch**: both sides
already reduce with `normalizePhone` (last ten digits), and last-ten is the best rule available.

JID node shapes, one-to-one chats (9,426 rows):

| server | node | count |
|---|---|---|
| `s.whatsapp.net` | 12 digits, `91…` | 7,057 |
| `s.whatsapp.net` | 12 digits, other country code | 137 |
| `s.whatsapp.net` | 11 digits (national form) | 283 |
| `s.whatsapp.net` | 10 or 13 digits | 34 |
| `lid` | 13–15 digits, no phone | 1,685 |
| `newsletter` / `broadcast` / `bot` / `temp` | — | 275 |

Book numbers, 786 total: 610 are 12 digits (593 of them `91…`), 94 are 11, 78 are 10 (no country code),
4 are 13. Both sides mix country-code and national forms, which is exactly why the rule must be last-ten.

| reduction rule (one-to-one `s.whatsapp.net` chats, 7,465) | chats matched |
|---|---|
| full number, no reduction | 613 |
| **last ten digits (what ships)** | **661** |
| last ten after stripping a leading `0` | 661 (+0) |
| last ten after stripping country code `91` | 661 (+0) |
| union of all four rules | 661 (+0) |

- Book coverage: 735 of the 786 saved numbers correspond to a chat — 661 as `s.whatsapp.net` JIDs (12-digit
  `91…` mostly) and 74 as `lid` chats whose segment already carried the phone JID. All 735 resolve, all with
  the book's name. The other 51 numbers have no chat in the archive. **735 is the ceiling; the book reaches it.**
- Why the count still moved by only 35: `chats.resolved` went 1,021 → 1,056. Of the 700 chats whose key is in
  the book in the pre-change index, all 700 were *already* named, with the identical name, from
  `config/contacts.json`. The 36 "new" chats are rows that `config/merges.json` had collapsed before it was
  reset to `{}`; 35 of them picked up a name. Nothing was renamed. The book is a duplicate of `contacts.json`.
- Unresolved split (8,725 chats, none of which the book can name):

| bucket | chats |
|---|---|
| one-to-one phone chat, number not in the address book at all | 6,804 |
| one-to-one `lid` chat — no phone number in the vault to join on | 1,608 |
| newsletter | 270 |
| group that never had a subject | 37 |
| broadcast / temp / bot | 6 |

So the "8,000 unnamed chats" are overwhelmingly **unsaved numbers** (78%), not a join bug. The address book
is 786 numbers; the archive has 7,465 phone chats. A saved-name book cannot name a stranger.

**Where the real ceiling is:** the 1,608 `lid` chats (16% of the archive) are people, not numbers, and the
vault holds no `lid → phone` map for them — only 74 of 1,685 carry one in the segment. Naming those needs
WhatsApp's `jid_map` (root-only) or a lid↔pn hint in the export, not a change to number matching.
Do **not** loosen the key rule: stripping `0`/`91` adds exactly zero matches, and matching a `lid` to the
book would be guessing.

## The Unnamed view: browsing the chats nothing could name

The 8,725 unresolved chats are now a screen, not a number. `People → Chats without a name` (also
`Go → Chats without a name…`) opens a sheet listing every chat with `resolved = 0`, most messages first.

- **Query:** `VaultStore.unnamedChats(matching:kind:excluding:limit:offset:)` returns `UnnamedChat`
  (chat id, JID, group flag, the index's display name, message count, last activity, kind), ordered by
  message count then last activity. `unnamedChatCounts()` and `unnamedChatCount()` feed the filter chips
  and the sidebar row. `LEFT JOIN chat_stats` on purpose: a chat with no messages is still unnamed, and
  an inner join silently dropped 668 of them (270 newsletters became 18).
- **Kinds** come from the JID server, because that is all the index holds for an unnamed chat: `person`
  (`s.whatsapp.net`, `lid`), `business` (`bot`, `broadcast`, `temp`), `newsletter`, `group`. `status@broadcast`
  is the owner's own status feed and is excluded rather than offered as a business.
- **Rows show the number, not the label.** The index often holds a masked half-number (`+919****0001`),
  which cannot be matched to anything; the row prints the full international number from the JID, or
  `lid:…` / `newsletter:…` / `group:…`. `UnnamedChat.isPlaceholder` decides whether the stored label is a
  name at all.
- **Naming** writes `config/overrides.csv` through `NameOverrides.set(_:for:in:)` — the only writer for that
  file. It keeps the header, every other column and every other row (it is a spreadsheet the owner may
  have edited), quotes names containing commas, re-reads through `ContactSources.loadOverrides` and throws
  `notPersisted` rather than reporting a write that did not land. The app then rebuilds the library, which
  is what makes `chats.name` move.
- **Typed names now beat a LID→phone mapping.** `Resolver.resolve` consults overrides on the `lid` branch
  (an override is the owner's own evidence, not a guess), and `VaultIndexer` also checks the raw chat JID
  and the sender's LID, so a name typed for a LID chat that resolves through a phone JID is not ignored.
- **Ignore** is `config/unnamed-ignores.json` (`UnnamedIgnores`), keyed by chat JID. It only filters this
  query: nothing is deleted, no rebuild is needed, and *Restore* brings the rows back.
- **Measured on the live index** (read-only copy): person 8,412 · newsletter 270 · group 37 · business 5,
  plus the excluded status row = 8,725. A 100-row page costs ~11 ms.

Files: `Sources/SagaCore/UnnamedChats.swift`, `Sources/SagaCore/UnnamedIgnores.swift`,
`NameOverrides` in `Sources/SagaCore/Contacts.swift`, `Sources/SagaApp/UnnamedChatsView.swift`.
Tests: `Tests/SagaCoreTests/UnnamedChatsTests.swift` (11 tests, synthetic numbers only).

## Still open

- ~~Rebuild the archive so the 8,094 unnamed chats pick their saved names up~~ — done; the rebuild is
  correct and changes nothing, because the names were already there.
- The 6,804 unsaved numbers and the 1,608 `lid` chats stay unnamed by design.

## Constraints that keep biting

- **Rebuild the app bundle, not just the product.** `swift build --product SagaApp` does not update
  `build/Saga.app`; run `sh scripts/make_app.sh` or the user will keep seeing stale UI.
- `Vault(...)` is created with `try Vault(url:)` in tests; there is no `Vault.open(at:protection:)`.
- `MergeConfig` stores `{"merges":[{"keys":[...],"name":"..."}]}`; `config/merges.json`.
- Person keys are **last ten digits** or `lid:<id>`; they are not full international numbers.
- `SQLiteDB` is not thread-safe — serialise access.
- The vault has `config/contacts.json` (names), `overrides.csv`, `prune.json`, `profiles.json`,
  `merge-suggestion-ignores.json`, `merges.json`.
