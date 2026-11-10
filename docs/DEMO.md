# Synthetic demo vault

`saga demo` builds a rich, fully fictional archive so screenshots, the website, the live Wrapped page and testers never need real data. It is offline and deterministic: no phone, contacts, preferences, existing vault or network is read. Names are natural-sounding but invented, IDs are prefixed `demo-`, and `vault.json` records `"synthetic": true`.

Nothing in the fixture is copied from a real conversation, not even partially redacted text. Only the *shape* of an archive is borrowed — three years, a handful of groups, one loud group, a quiet stretch — and every line, date, name and attachment is generated.

## Generate

```
swift build
.build/debug/saga demo --out ~/saga-assets/demo-v2
```

`--out` must not exist (existing files are never replaced; output is published by atomic rename, so a failure leaves nothing behind). Output:

```
<out>/vault/                 open-format archive (vault.json has "synthetic": true; one segment seg-demo-v2.ndjson.gz)
<out>/vault_index.db         disposable index (rebuild: saga vault index --vault <out>/vault --out <db>)
<out>/media/                 generated attachments (drawn scenes by default; see --photos below)
<out>/README.txt             marks the folder as synthetic
```

Generation takes a couple of seconds, well under the 10 s budget; the command prints the `--chat` ids it created.

### Real photographs (`--photos`)

`saga demo --photos <folder>` swaps the drawn gallery scenes for an ordinary folder of image files (jpg, png, heic, webp, tiff). Each picture is centre-cropped square, downscaled to 640×640 and re-encoded as JPEG. Files are read in filename order, then numbered in Gallery order (newest first) and cycled, so a screenful of the Gallery shows a camera roll instead of repeating one picture. Two runs with the same folder produce the same archive. A missing or empty folder is an error, and the drawn scenes remain the default when the flag is absent.

The website's Gallery capture uses `fixtures/demo-photos/` — thirteen Unsplash photographs of groups (from behind or at a distance), food, pets and landscapes. They are demo input only, are **not** copied into `site/`, and are credited in `site/README.md`.

## What is in it (fixture v2)

| | |
| --- | --- |
| Messages | 20,600 across 1,095 days, 1 Nov 2023 – 31 Oct 2026 (fixed dates) |
| Chats | 15 chat records → **14 conversations**: 4 one-to-one and 10 groups |
| People | 22 fictional people, every one of them named |
| Volume | one group ("Sunday Football XI") carries 29% of everything |
| Shape | quiet year (2024, ~19% of a normal year), quiet month (June 2026), a 3-week silence in the main chat, a 6-week daily streak, five surge days |
| Music and video | 137 shared link messages (70 distinct URLs) across Spotify, YouTube and Apple Music — all real public pages, checked once when they were added to `DemoLinks.swift`; nothing is fetched at generation time |
| Attachments | 408 rows with generated files: JPEG gradients, three-frame H.264 clips, WAV voice notes, one-page PDFs. No photographs. |
| Wrapped features | laughter (hundreds of laugh messages, 543 quoted replies), inside-joke phrases unique to one chat ("blue kettle", "sambar index", "auto anna"), per-person emoji clusters, a signature emoji pair, a night-owl message, long messages, busiest day, quietest year |
| Edge cases | 19 deleted-on-the-phone (`gone`) entries, one merged identity (Nikhil Rao on two numbers, folded into one conversation), one security-code notice (type 7, hidden from Wrapped and On This Day), and one direct chat (Priya Menon) that ends on an incoming unanswered question so "Might need your reply" has demo evidence |

Text mixes casual English and Indian-English WhatsApp register — short lines, filler, food, cricket, family, work, office lunch orders — and is searchable (`biryani`, `kettle`, `trek`).

Media are written as generated placeholders into `<out>/media/`, and `vault/config/media-sources.json` records that folder as the vault's media source, so the app resolves thumbnails exactly as it does for a real media folder. The path is absolute: regenerate the demo after moving the folder.

## Browse in the app (isolated)

```
.build/debug/SagaApp --demo ~/saga-assets/demo-v2
# screenshots (never touches real data):
.build/debug/SagaApp --demo ~/saga-assets/demo-v2 --snapshot ~/saga-shots [--dark | --light] \
    [--query kettle] [--open 15] [--otd-date 11-28] [--states] [--ai] [--reduce-motion] [--wrapped]
```

With `--demo <folder>` the app's support, cache and vault paths all point at that folder; it skips restoring the real library, legacy migration and phone hints, and does not write `indexPath`/`vaultPath` preferences. If the folder is missing or not a generated demo, the app exits with an error rather than falling back to real data. `--snapshot` without `--demo` is refused (exit 2), so a capture can never show the real library.

## CLI against the demo

```
saga duo --index ~/saga-assets/demo-v2/vault_index.db --chat <dm chat id> --out wrapped.html
saga onthisday --index ~/saga-assets/demo-v2/vault_index.db --date 11-28
saga export --index ~/saga-assets/demo-v2/vault_index.db --chat <id> --out chat.html [.txt]
```

Chat ids are assigned by sorted JID, so they are stable between runs but are best taken from the ids `saga demo` prints. In fixture v2: `1` Aravind Pillai, `2` Book Club (mostly snacks), `3` College Gang 2016, `4` Cousins' Chaos, `5` Flat 4B, `6` Sunday Football XI, `7` Terrace Gardeners, `8` Kerala Trip Crew, `9` Meera Nair, `10` Nikhil Rao (both numbers merged; the old-number chat has no id of its own), `12` Office Lunch Crew, `13` Priya Menon, `14` Weekend Trekkers, `15` Wedding Prep — Aditi & Rohan.

The Wrapped HTML from `saga duo` (and the HTML from `saga export`) is one self-contained file: no external requests, CDNs, fonts, images or embeds, so it renders offline and can be committed as a website asset. Verify with `grep -E 'src=|https?://' wrapped.html` (nothing). When the index belongs to a demo folder, `saga duo` defaults `--me` to "You" (an explicit `--me` still wins), so artifacts never embed your Mac account name; against a real archive it still defaults to the account name.

## For integrators (website, launch cards, screenshots)

- Generate once into a durable, gitignored path, e.g. `saga demo --out ~/saga-assets/demo-v2`, and reuse it; registers do not depend on the clock.
- Demo folder contract: `<out>/vault/` (archive, `vault.json` has `"synthetic": true`), `<out>/media/` (generated attachments, referenced from the vault config), `<out>/vault_index.db` (disposable index), `<out>/README.txt` (provenance).
- App screenshots: `Saga.app/Contents/MacOS/Saga --demo <out> --snapshot <shots> [--dark | --light] [--width 900 --height 820] [--open <chat id>] [--query kettle] [--otd-date 11-28] [--states] [--reduce-motion]` → `1-dashboard.png`, `2-chat.png`, `3-search.png`, `4-person.png`, `5-wrapped.png`, `6-onthisday.png`, and with `--states` also `6-chats-empty` … `12-media-empty` (the illustrated empty and error surfaces). `--open` picks the conversation the chat capture shows (default: the busiest group); `--otd-date MM-DD` picks the day On This Day opens on. `--dark`/`--light` force the appearance for the capture (otherwise the system appearance is used); `--width`/`--height` set the window's content size, so the responsive layout can be checked at the narrow (900) and wide (1440) ends of its range; `--reduce-motion` renders with Reduce Motion treated as on, without changing the machine's accessibility settings. Demo mode never reads or writes the real library, caches or preferences.
- Add `--ai` to capture the on-device AI surfaces: `16-ask.png` (the Ask panel with meaning search in its default-off state), `17-topics.png` (the Topics sheet for the Priya Menon chat, loaded without generating) and `18-reply.png` ("Might need your reply" after its deterministic scan, populated from the demo's planted question). These are debug captures from the synthetic archive only.
- Add `--wrapped` to also render the native Wrapped stories offscreen at full length (`13-wrapped-duo.png` for the busiest one-to-one chat, `14-wrapped-group.png` for the busiest group, `15-wrapped-year.png` plus `15-wrapped-year.pdf` for the selected year, rendered through the same export path as the Export menu); `--wrapped-chat <id>` captures another conversation and `--wrapped-titles` resolves song and video titles so the soundtrack cards show real titles and artwork (`StoryArtwork` preloads the thumbnails, because offscreen rendering does not wait for `AsyncImage`). Offscreen rendering cannot rasterise AppKit-backed buttons, so the story's own export buttons are omitted from these captures; the live window and the sheet always show them.
- Duo/per-person card: `saga duo --index <out>/vault_index.db --chat 9 --out duo-meera.html` (also `--chat 1`, `--chat 10`, `--chat 13`). Group Wrapped lives in the app and exports from its toolbar; there is no `saga group` CLI.
- Nothing in the demo reads the device, network, contacts or existing vault; it is safe to run on a clean machine and in CI.
- Verified consumers in this repository: the README screenshots (`site/assets/images/`), `site/demo/index.html` (built with `scripts/build_demo_page.py` from a `saga duo` export) and the website features section. Regenerate them from a fresh demo run rather than hand-editing.
- The vault is stable for text: the same seed produces the same messages, timestamps, IDs and links. Two things still vary: the placeholder media files are produced by the system image and video encoders (same pixels, and the size recorded in the index always matches the file on disk, but bytes can differ between macOS versions), and Wrapped day/hour counts use the local calendar while the fixture is generated on a fixed IST clock — a machine in another time zone can show a different busiest hour. Compare regenerated artifacts by content, not by diff.

## Tests

`DemoVaultTests`:
- `testDemoLaunchRequiresExplicitSyntheticFixtureAndNeverFallsBack` — nil when `--demo` absent; throws when just flag, with `--snapshot`, or with a non-demo folder; succeeds when given a generated demo folder.
- `testDemoIndexIsRecognizedSoArtifactsNeverEmbedTheMacAccountName` — a demo index is detected (so `saga duo` substitutes "You" for the Mac account name); a random path is not.
- `testDemoBuildsRichBrowsableRebuildableSyntheticArchive` — 20,600 messages / 15 chat records / 14 conversations / 10 groups / 22 named people; a group with ~29% of traffic; a three-year span with a quiet year and quiet month; Spotify, YouTube and Apple Music links (each one must classify and stay unchanged); ~408 media rows whose files resolve and decode (JPEG via ImageIO, MP4 non-empty); quoted replies, gone rows and the security-code notice; one merged conversation with two member numbers and no leftover person key; FTS hits; rebuild from the vault matches.
- `testDemoIsDeterministicAcrossRuns` — two generations produce identical message rows (uid, chat, time, direction, text).
- `testDemoWrappedIsPopulatedFromTheFixture` — Duo Wrapped on the main chat has > 2,000 messages, a streak, a real gap, laughs, funny moments, "blue kettle" as the leading inside joke, an emoji pair, a soundtrack with landed tracks, a quiet year and a night-owl message; Group Wrapped on the biggest group has contributors, moments and tracks; the year Wrapped covers 14 conversations over ten partial months with laughs, a soundtrack, media and named people; On This Day finds several years for 28 November.

`AIFeatureIntegrationTests` (`AIFeatureIntegrationTests.swift`) also checks the demo data end to end: the Priya Menon chat produces a reply candidate whose uid resolves; its last 30 days are readable for topics; and the archive has more than 10,000 messages eligible for the semantic index.
