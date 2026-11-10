# Media consolidation

How Saga should reconcile the same photo across a phone, a cloud archive, an emailed export
and a WhatsApp Web cache that never wrote a file — and what it would cost to build.

Status: blueprint, not built. Written after the media audit on the real vault (58,378 indexed
media rows, 83% found, 10,300 missing, of which a large share were never downloaded to the
phone at all).

---

## 1. The problem, stated precisely

A media row in the archive knows only what WhatsApp recorded: a path on the phone
(`Media/WhatsApp Images/IMG-….jpg`), a size, sometimes a hash. Whether the bytes exist is a
property of the *places we can look*, not of the archive. Today those places are an ordered
list of folders plus one drive root, matched by filename and size, with an ADB fallback for
single files.

That works until it doesn't:

- The same file exists in three places and we cannot say which.
- A file was never downloaded on the phone, so no amount of ADB will find it.
- Two locations disagree (different bytes, same name) and the newest wins by luck.
- The owner cannot tell "missing" from "not downloaded here" from "duplicate".

## 2. What "consolidated" means

One ledger row per media item, saying where the bytes are, which copy is canonical, and what
still needs fetching. Three verbs, in order:

1. **Reconcile** — scan every location, match rows to files, record provenance.
2. **Fill** — fetch what is missing from the best available source (phone, export, cloud).
3. **Sync** — copy the phone's unique files up to the cloud archive, and (rarely) the other way.

Never destructive. Nothing is deleted or renamed in a location Saga does not own.

## 3. Data model

```sql
-- one row per physical file we have ever seen
CREATE TABLE media_location (
  id TEXT PRIMARY KEY,            -- stable uuid, not a path
  label TEXT NOT NULL,            -- "Vintage archive"
  kind TEXT NOT NULL,             -- local | cloud | network | phone
  root TEXT NOT NULL,             -- current path; may move
  last_scan INTEGER
);

CREATE TABLE media_file (
  msg_id INTEGER NOT NULL,        -- media.msg_id
  location_id TEXT NOT NULL,
  rel_path TEXT NOT NULL,
  bytes INTEGER,
  sha256 TEXT,                    -- computed lazily, cached
  state TEXT NOT NULL,            -- present | gone | ambiguous | phone_only | stub
  checked_at INTEGER,
  PRIMARY KEY (msg_id, location_id)
);

CREATE TABLE media_scan (         -- an audit trail, not a cache
  id INTEGER PRIMARY KEY,
  started INTEGER, finished INTEGER,
  scanned INTEGER, matched INTEGER, missing INTEGER, ambiguous INTEGER,
  notes TEXT
);
```

`sha256` is the identity that survives renaming, re-export and re-compression. It is computed
on demand (first time a file is opened, or during an explicit deep scan), never on launch:
hashing 54k files is minutes of I/O.

## 4. Matching pipeline

For each media row, in order, stopping at the first hit:

1. **Exact relative path** in any location (the phone's own layout). Cheap, exact.
2. **Basename + size** anywhere in the locations. This is what runs today.
3. **Basename + size within ±2%** — catches re-encodes that keep the name. Flagged as
   `approximate`, never silent.
4. **SHA-256 match on a known file** — when the same bytes were already hashed elsewhere.
5. **Perceptual hash (pHash) for images** — only in an explicit "deep scan", because it is
   O(n) work and produces judgement calls. Result is a *suggestion*, never an automatic match.

Anything that hits more than one file with different hashes is `ambiguous` and surfaced, not
resolved by heuristic. Ambiguity is data, not a bug.

## 5. Where the bytes come from

| Source | Read | Bulk | Notes |
|---|---|---|---|
| Phone over ADB | per-file `exec-out cat` | `adb pull` of a subtree | Only route on macOS; newest media lives here |
| Cloud folder (Drive/iCloud) | mounted path, downloads on first read | same | Placeholders; a read costs bandwidth and seconds |
| Local export (chat export, AirDrop) | ordinary files | ordinary files | The rescue path for Web-only media |
| WhatsApp Desktop / Web cache | — | — | Not a source. Encrypted LevelDB blobs, no filenames |
| rclone remote | `rclone copy --files-from` | resumable | Needs a configured remote; scriptable, verifiable |

**Fill order** is a property of the item, not a global setting: prefer a local copy, then the
phone, then the cloud. A missing file whose chat is newer than the last phone backup is
`phone_only_expected` — the UI says "waiting for the next backup" instead of "missing".

## 6. Sync, both directions

**Phone → cloud (the useful one).** Find media that exists on the phone but in no cloud
location, then copy it into the archive folder.

- Dry run first: a list with counts and bytes, grouped by conversation and year.
- Execute with 4 concurrent transfers, resumable per file, `sha256` verified after write.
- Journal in `vault/logs/media-sync-<timestamp>.json` so an interrupted run can be resumed
  and audited.
- Two transports: **folder** (write into the mounted cloud folder; no auth, works with any
  provider that syncs) and **rclone** (`rclone copy --files-from`, better for large batches,
  already configured on the owner's Mac).
- Never *move*: the phone copy stays. The cloud gets a second copy, which is what "backup"
  means.

**Cloud → phone** is deliberately not offered as a button. Pushing files back into a phone's
WhatsApp media tree does not make WhatsApp show them, and it risks filling the device. The
honest version is an export: copy to a folder and tell the owner how to import it manually.

## 7. Interface

**Settings → Media** becomes a small page rather than one row:

- Locations, in priority order, with kind badges (built).
- A coverage bar per location, and the combined total (built).
- **Reconcile** (scan + match, with a progress line and a last-run timestamp).
- **Fill gaps** — count, then a sheet: by conversation, by year, with the source that would
  be tried. Buttons per group, because a 10k-file fill is a decision, not a default.
- **Sync to cloud** — same shape, dry run first.
- A ledger view: filter by state, see the conflicting paths for an ambiguous row.

**Chat surface.** A thin strip above the composer when a conversation has missing media:
"38 photos not on this Mac · Try phone · Show". Dismissible, remembered per chat.

**Gallery.** Each tile carries its provenance in the corner (`Phone`, `Cloud`, `Local`) and
stubs get a distinct treatment with a download affordance rather than an empty square.

## 8. What this costs

Rough, for one experienced pair of hands working with the existing code:

| Phase | Scope | Effort | Risk |
|---|---|---|---|
| P0 | Ledger tables, write-through on resolve, per-location provenance, missing sheet (mostly built) | 1–2 days | low |
| P1 | Phone inventory (`find` once, not per-file probes), gap-fill queue from the phone, resumable copy | 3–5 days | medium: ADB throughput, device lock |
| P2 | Cloud fill with a download budget, stub detection, cache policy | 3–5 days | medium: bandwidth, placeholders |
| P3 | Phone → cloud sync, dry run, journal, rclone and folder transports, hash verify | 5–8 days | high: destructive if wrong; must be dry-run first |
| P4 | Deep scan: sha256 sweep, pHash suggestions, duplicate review | 4–6 days | medium: false positives |
| P5 | Chat strip, gallery provenance, ledger UI polish | 3–4 days | low |

Total: roughly **3–4 weeks** of focused work for the whole thing, or **about a week** for
P0+P1, which is the 80% that changes the experience: your recent chats start showing their
photos, and the missing number becomes explainable.

## 9. Risks, and how the design answers them

- **Cloud bills.** A "fill everything" button on a 10k-file set is a large download. Every
  fill is scoped, counted, and previewed with bytes; there is no implicit download.
- **Silent wrong matches.** Size-and-name matching can pair two different files. States are
  explicit (`present`, `approximate`, `ambiguous`), and the UI never claims certainty it
  doesn't have.
- **Half-copied files.** Every write goes to `.partial` and is renamed after checksum; the
  journal records intent before transfer.
- **Reorganising the owner's folders.** Saga writes only into folders it owns (the archive's
  media store) or into a cloud folder the owner explicitly nominated. It never renames or
  deletes anything elsewhere.
- **Hashing cost.** Lazy by default; the deep scan is opt-in and reports progress.
- **Phone leaves the cable.** Every phone-dependent action is resumable and idempotent; a
  disconnect is a pause, not a failure.

## 10. Decisions the owner needs to make

1. **Managed store or in place?** Either Saga keeps a canonical copy of every file it has
   (simple, uses disk, one source of truth) or it only records where the best copy lives
   (no duplication, fragile when a folder moves). Recommendation: record by default, with an
   explicit "collect into the archive" action.
2. **Cloud transport:** the mounted Drive folder (no auth, depends on the Drive app running)
   or rclone (scriptable, verifiable, needs a remote). Recommendation: folder as the default,
   rclone offered for bulk.
3. **Does "sync" ever delete?** Recommendation: never. Missing files are flagged, not removed.

## 11. First slice worth building

P0 + the phone half of P1, because it is measurable on the real vault:

- Add `media_file` + `media_location`, write a row whenever a resolve succeeds.
- One phone inventory pass (`find … -printf '%f %s'`), stored as a location of kind `phone`.
- Gap-fill queue for one conversation at a time, with counts and a progress line.
- Success measure: the 10,300 missing drops by whatever the phone actually holds, and every
  remaining item has a stated reason (`not_on_phone`, `cloud_stub`, `never_downloaded`).

---

## 12. Wireless mode (folder sync on the phone)

Decisions taken: **mounted Drive folder is the default cloud transport, rclone for bulk**, and
the wizard should set this up for someone who has never opened Terminal.

### 12.1 The insight

Any Android folder-sync app (DriveSync / Autosync for Google Drive, FolderSync, Syncthing)
can mirror *any* folder the phone can read, including WhatsApp's own:

```
/sdcard/Android/media/com.whatsapp/WhatsApp/Databases   ->  Drive/<archive>/Databases
/sdcard/Android/media/com.whatsapp/WhatsApp/Media       ->  Drive/<archive>/Media
```

WhatsApp writes `msgstore*.crypt15` into the first; the media tree is the second. If both are
mirrored, Saga needs no cable at all: it watches a Drive folder for a newer backup, decrypts
with the key already in the keychain, merges by uid, and resolves media from the same folder.

That makes the whole pipeline wireless: phone → Drive → Saga, with the phone as the producer
and the Mac as the reader. The 64-digit key never leaves the Mac, and the crypt15 stays
encrypted in Drive, so the cloud holds ciphertext plus plaintext media — the same trade the
owner already made with the manual backup.

### 12.2 What DriveSync needs

- A **folder pair per tree**, not one giant pair: Databases separate from Media, so backup
  uploads are small and media can be paused independently.
- **Filters** so only `msgstore*.crypt15` (and optionally `wa.db.crypt15`) upload, not every
  historical backup. Autosync supports include/exclude patterns.
- **Upload only** (phone → Drive). Two-way sync invites Drive deletions to propagate onto the
  phone, which is the one failure mode worth designing out.
- **Retain last N** on the remote, or the Databases folder grows by ~176 MB per backup.
- **Wi-Fi only + charging**, because backups land around 4 am and a mobile-data upload of
  176 MB is a surprise nobody wants.
- **All Files Access** (Android 11+) — the app needs it to read WhatsApp's directory.

### 12.3 What Saga has to add

1. **A wireless source**: a Drive folder designated as the archive's inbox. On launch (and
   every N minutes while open) look for the newest `msgstore*.crypt15`; if its name/mtime is
   new, decrypt → fingerprint → ingest → rebuild. Show it as a row: "Wireless backup · last
   received 04:12".
2. **Partial-file guard**: a sync client can copy a file mid-write. Validate the crypt15
   header and reject anything modified in the last two minutes; retry next tick.
3. **Retention helper**: list backups in the inbox, offer "keep the newest 3" (never deletes
   without an explicit click, and only inside the inbox folder).
4. **Key check**: the first wireless import needs the key. If it is missing, the wizard asks
   for the 64 digits again rather than failing with a decrypt error.
5. **Wizard path**: "Set it up wirelessly" as a first-class route beside ADB — three screens:
   install the sync app, add these two folder pairs (with copyable paths), then point Saga at
   the Drive folder. Each screen is one job, with an "I'm stuck" panel, matching the existing
   wizard language.

### 12.4 Assessment

- **Feasibility: high.** No new protocol, no WhatsApp internals: a file appears in a folder
  and we already know how to decrypt and merge it. The pieces exist — `Crypt15`, `ingest`,
  profiles, and the mounted-folder resolver.
- **Effort:** wireless ingest + retention + wizard route ≈ **4–6 days**. Media over the same
  path is free once the folder is a registered location (already built).
- **Risks:** (a) a truncated upload — mitigated by the age check and header validation;
  (b) the owner stops plugging in and silently stops getting backups — mitigated by a
  freshness row that says when the last one arrived and a nudge after 3 days;
  (c) cost, if Media is mirrored wholesale — mitigated by paused media pairs and the download
  budget in §9.
- **What it does not solve:** media viewed only in WhatsApp Web still never reaches the
  phone, so no sync app can carry it. That remains an export-on-demand case (§5).

### 12.5 Recommended order with the rest

Wireless ingest belongs **before** the cloud fill work, because it changes where new media
comes from: once the phone mirrors Media to Drive, most "missing" rows resolve without any
ADB or download logic at all. Concretely: P0 ledger → wireless ingest (12.3 1–4) → wizard
route → phone gap-fill for the pre-DriveSync history → cloud fill.

---

## 13. Freeing phone space, safely

The archive makes this possible in a way WhatsApp's own storage screen cannot: a file may be
deleted from the phone only when it provably exists somewhere else. That provability is the
whole feature.

### 13.1 The rule

A phone file is **safe to remove** only when all four hold:

1. It is older than the newest `msgstore*.crypt15` that has been decrypted, fingerprinted and
   ingested into the vault — so the message referencing it is archived.
2. A copy exists in at least one cloud location and its **SHA-256 matches** the phone's file.
3. That cloud location is not a stub (`state = present`, not `stub`), i.e. the bytes are real
   on the remote, not merely a placeholder.
4. It is older than the owner's "keep on phone" window (default 30 days), so recent media
   stays available offline in WhatsApp itself.

Anything failing a test is listed as *not* removable, with the failing reason. No exceptions,
no "probably fine" bucket.

### 13.2 Interface

Settings → Phone → **Free up space**:

```
Would free 4.2 GB · 3,840 files
  Photos      2.9 GB   2,610     all verified in Vintage archive
  Video       1.1 GB     402     all verified
  Voice notes 180 MB     718     verified
  Documents    40 MB     110     38 not verified — kept
Keep media from the last [30] days on the phone
[ Preview list ]   [ Remove 3,840 files ]
```

- **Preview first, always.** Grouped by kind and by conversation, with the reason for every
  exclusion visible.
- Deletion is **per group**, never global.
- A **journal** records every path deleted, its hash, the cloud copy's path and the timestamp,
  so the action is auditable and reversible.
- **Restore** reads the journal and copies files back over ADB — the undo, made possible
  because the bytes were never ours to lose.

### 13.3 Mechanics

- Delete with `adb shell rm` in batches of ~50, verifying each batch's exit status; a lost
  cable pauses the run.
- Never touch `Databases/` from the cleanup path — it is the backup itself. A separate action
  can trim *older* crypt15 files in the **cloud inbox** (§12.3, keep newest N), which saves
  cloud space, not phone space.
- WhatsApp may re-download media when a message is opened again (its own auto-download
  setting decides). That is fine and expected: the message survives, the file comes back if
  the owner wants it. Cleanup is about space, not content.
- Do **not** delete from `WhatsApp Voice Notes` unless the voice note is also archived as a
  media row and verified — voice notes are the most commonly missed category.

### 13.4 Why not use WhatsApp's own "Manage storage"?

It deletes messages along with media, per chat, with no verification that anything was
archived first, and no record of what was removed. It is the right tool for someone who does
not care about the history; Saga's cleanup is for someone who does.

### 13.5 Effort

- Reporting only ("what could be freed", with reasons): **2 days** — the ledger from §3
  supplies nearly all of it.
- Verified deletion with journal and batching: **3–4 days**.
- Restore from journal: **2 days**.
- Risk: **high if unverified, low as designed.** The four-condition gate and preview are what
  make it safe; without them this feature should not ship at all.

### 13.6 Sequencing against the rest

After wireless ingest (§12), because the archive's freshness check depends on knowing which
backup is the latest ingested one. Concretely:

`P0 ledger` → `wireless inbox` → `wizard route` → `free up space (report)` →
`free up space (verified delete + restore)` → `phone gap-fill` → `cloud fill`.

Reporting lands early because it is the trust-building step: seeing "4.2 GB is provably
backed up" is what makes the delete button reasonable later.
