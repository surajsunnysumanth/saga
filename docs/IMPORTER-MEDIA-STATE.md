# Media rows with no path: where they come from

Status: diagnosed and partially fixed. Rebuild on the live archive takes media rows with no
path from **9,193 to 8,926 (−267)**; the remaining 8,926 have no path in any source and no
identical file on this Mac, so no index change can reach them.

## The question

The Gallery can only open a file whose path the archive recorded in `media.file_path`. On the
live index (`~/Library/Application Support/Saga/vault_index.db`) 9,193 of 58,388 media rows
had no path at all, so no resolver change could reach them. The concern was that the importer
was dropping paths for particular message types or media kinds.

## Answer: no rows are dropped — the phone never had the file

Every media message in the newest backup snapshot is present in the index. Comparing
`message_media` in `archive-migrated/msgstore-20261106-025821.db` with the index by
`uid = sha256(chat JID | key_id | from_me)`:

| | rows |
|---|---|
| media rows in that snapshot | 57,590 |
| of those present in the index | 57,590 (100%) |
| with a path | 48,960 |
| **with no path** | **8,630** |
| index rows from other/older segments | 798 |
| index total / pathless total | 58,388 / 9,193 |

The pathless rows are pathless **in the phone's own database**. For that snapshot:

- 8,898 of 8,899 pathless rows carry `file_hash`, `media_key` and `direct_path` — WhatsApp knows
  the file only by hash and by its CDN location.
- 8,804 of 8,837 pathless rows have `transferred = 0`: the file was never downloaded to this
  phone. (95 rows are `transferred = 1` but the file is gone from storage.)
- They match the counts in the March 2026 Python vault index (8,604 of 57,526), so this is not a
  regression in the Swift importer — the same rows were already unresolvable there.

Kind and message type of the 9,193 pathless rows (live index):

| kind | rows | | message type | rows |
|---|---|---|---|---|
| image | 6,933 | | 1 image | 4,939 |
| video | 1,541 | | 25 business/template | 1,109 |
| doc | 587 | | 3 video | 777 |
| audio | 122 | | 9 document | 738 |
| other | 10 | | 57 business/template | 538 |
| | | | 13 gif | 528 |
| | | | 20 sticker | 143 |
| | | | 62, 42/43 view-once, 2 audio | 84 / 78 / 72 |
| | | | 28, 26 | 62 / 54 |

Which segment recorded them:

| segment source | media rows | no path |
|---|---|---|
| `legacy-archive` (full snapshot, 5 Nov) | 57,590 | 8,630 |
| `legacy-retained` (partial) | 692 | 530 |
| `android-crypt15` (7–9 Nov, five imports) | 106 | 33 |

So the bulk is one import of a snapshot in which those files had never been downloaded, plus
the same rows carried forward.

## The two real ingest defects

1. **A path that appears later could never be recorded.** `Vault.ingest` skips a message it
   already holds, and the message record is append-only, so a media row imported before its file
   was downloaded stayed pathless forever — even though a later backup knew the path. 563 of the
   9,193 pathless rows arrived after 6 Nov and are exactly exposed to this.
2. **A file recorded twice, once with a path and once without, kept the empty copy.** A forward
   or a re-save gives the same bytes a second row; only one of them has a `file_path`. Nothing
   used `file_hash` to notice the two rows are the same file. This is 264 rows in the snapshot
   (267 in the index).

## What changed

- `Sources/SagaCore/MediaPathRecovery.swift` — `MediaPathIndex`: hash → known path. Only an equal
  SHA-256 may donate a path; size and filename matches are deliberately rejected because they
  produce paths to the wrong file.
- `Vault.ingest` now (a) fills a pathless row from an identical row in the same snapshot, and
  (b) writes a `{"k":"md","u":uid,"md":{…}}` record for an already-stored message whose file this
  backup has newly downloaded. `IngestResult.pathsUpdated` reports the second case, and the
  segment header records it as `mediaUpdated`.
- `VaultIndexer.build` folds `k:"md"` records into the message they name, then repairs remaining
  pathless rows from an equal hash. `ImportSummary.mediaPathsRecovered` reports the repair.
- `Importer.run` (the direct `msgstore.db → index` path) applies the same in-snapshot rule, for
  the primary source and for `additionalSources`.

Tests: `Tests/SagaCoreTests/MediaPathRecoveryTests.swift` (six cases: sibling repair, the record
written at ingest, a later backup filling a known message, a genuinely absent file staying
pathless, different hashes never matching, direct import parity).

## Proof

Rebuild from the live vault (46 s), then count:

```
saga vault index --vault "~/Library/Application Support/Saga/vault" --out /tmp/idx.db
sqlite3 /tmp/idx.db "select count(*) total, sum(file_path is null or file_path='') nopath from media"
58388|8926          # was 58388|9193
```

Messages, chats, people and total media rows are unchanged; only `file_path` is filled.

## What is left

8,926 rows still have no path. For those the file is absent from the phone's database and from
this Mac's media archive, so a path would be an invention. Two honest routes remain:

- **Hash-match the media archive on disk** (`My Drive/BACKUP/Whatsapp`, 54,381 files / 50 GB).
  Prefilter by `file_length` (1,280 pathless rows have a same-size file) and confirm by SHA-256;
  a 82-row sample verified 26, so the realistic ceiling is a few hundred rows. Reading cloud
  placeholders is slow (≈2 s per file), so it wants a cache and a background pass, not an
  index-build step.
- **Fetch on demand** from the phone (`PhoneLink`) for the newest rows; those are the ones the
  Gallery shows first.
