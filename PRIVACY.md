# Privacy

Saga imports and searches your WhatsApp history on your Mac. There is no Saga-hosted archive or cloud AI provider in the built-in model layer, and no analytics feature is intended. **Local storage does not mean that every feature is offline.** The boundaries below matter before opening a library, enabling a player or connecting an AI client.

This is a source-based description verified against the integrated launch candidate's code, not a completed network-capture audit. A fresh-preferences network capture has not yet been recorded; treat the boundaries below as code-verified, not traffic-verified.

## What is stored locally

- The vault contains append-only compressed message segments, media references and configuration such as names, merges and prune rules. Compression is not encryption.
- The derived SQLite index contains searchable message text, contact identifiers and statistics. AI summaries and link metadata are cached separately in the app support folder.
- The Android backup key saved by the app is held in the macOS Keychain. Input backup/key files and any copies you keep remain your responsibility.
- Optional vault encryption (vault format 2, off by default) seals `segments/*.ndjson.gz` and `config/*.json` with AES-256-GCM. Its data key is wrapped under your passphrase (PBKDF2) and an independent recovery code; macOS Keychain can remember the unlock on this Mac. The derived SQLite index, AI caches (`ai_cache.db`, `semantic_cache.db`) and link-metadata cache in the app support folder remain plaintext. For unencrypted vaults use an encrypted Mac/volume, control access and keep independent backups.

## What can leave the Mac, and when

| Action or feature | Data and destination |
| --- | --- |
| Import, indexing, search, statistics, pruning and merges | Processed locally. Sources remain on your chosen storage. A cloud-mounted source or destination can involve your storage provider as described below. |
| Android setup downloading platform tools | `Adb.downloadTools()` downloads Google's platform-tools archive. Google receives an ordinary download request and network metadata; this request is not an upload of the archive. Connecting a phone also requires explicit device trust/USB debugging. |
| Update check | Once a day on launch, at most every 24 hours, `UpdateChecker` makes one `GET` to `https://api.github.com/repos/surajsunnysumanth/saga/releases/latest` through `URLSession` with no custom headers, no cookies, no query string and no body. GitHub sees the request and ordinary connection metadata (including the IP address it comes from); no archive content, message, contact, identifier or usage data is included. Only `tag_name` and the release/asset links are read from the response. Locally it stores the last-check time, the last version seen and a dismissed version, under `updateLastCheckAt`, `updateLastSeenVersion` and `updateSkippedVersion` in `UserDefaults`. A failed check is silent and is not retried until the next day. Setting `updateChecksEnabled` to `false` (Settings → Archive → Updates) stops the request entirely; the manual "Check now" button is disabled in that state. |
| Built-in AI | Apple Foundation Models runs on device. Ollama is contacted at `127.0.0.1:11434`; LM Studio at `127.0.0.1:1234`. Selected message content, the question and instructions are passed to the selected local model. Model software installation/downloads and any forwarding configured in an external local server have their own privacy implications. |
| Link-title lookups | Spotify, SoundCloud or YouTube oEmbed requests contain the shared media URL. Expanding a `spotify.link` or `on.soundcloud.com` short share link sends one HEAD request to that host and follows its redirect, and the resolved target is cached locally. Those providers see the URL and request metadata, not the surrounding chat transcript from this lookup. Returned titles/artwork URLs are cached locally. Apple Music titles can be derived from the shared URL without a title lookup. |
| Artwork | Loading a remote thumbnail contacts its image host. Requests disclose the image URL and ordinary request metadata. Cached artwork URLs are not themselves cached image bytes. |
| Embedded media players | Opening a player, or enabling automatic players while scrolling, loads third-party web content from the media service and any resources it uses. This can expose media IDs, IP address, request metadata and browser/session state; signing in shares information directly with that provider. It is not covered by an offline promise. |
| Open in service / temporary playlist | Opens the chosen media URL, or a list of YouTube video IDs, in your browser. The provider and browser settings determine subsequent processing. |
| Cloud/NAS/media folders | Saga reads the location you choose. Reading an online-only cloud file can trigger a download. A vault or export placed in a synced folder is uploaded by that sync client according to its settings. Saga does not make a synced destination private. |
| MCP | The stdio server returns matching messages and contact information to the client you connect. The client may forward them to its model provider, including a cloud provider. Connecting it is a separate disclosure decision, even though Saga's server is local and read-only. Block lists are not a substitute for trusting the client; see [MCP limitations](docs/MCP.md). |
| Export, copy and share | Chat exports, Wrapped pages/PDFs, copied content and screenshots may include private messages and names. Saga writes or copies them at your request; sharing them or choosing a synced destination makes them available beyond Saga. |

The title-lookup row describes the request to fetch a title, not sending an already-known title as the input. Do not describe this as "only titles leave the machine"; it is the media URL/identifier that the provider needs.

## Preview and player controls

Title/artwork fetching is **off by default**: `loadLinkPreviews` (Music & video panel) and `wrappedTitles` (Duo and group Wrapped) both default to `false`, and the `saga duo` CLI fetches titles only with an explicit `--titles` flag. Enabling a toggle sends the shared media URL to Spotify, YouTube or SoundCloud as described above; artwork thumbnails load only while the toggle is on. With a toggle off, previously cached titles can still be displayed from the local cache, but those panels make no new title, short-link or artwork request. Opening a player or an external link still contacts its service, and automatic players remain a separate setting.

These defaults were verified in the integrated launch candidate's source (see [DEVELOPMENT.md](docs/DEVELOPMENT.md) for the repository gate). A fresh-preferences profile with network observation has not yet been recorded; until it is, do not claim the app is fully offline with previews off — use a network restriction outside the app if a strictly offline session is required. This section must be updated from verified behaviour, not removed on assumption.

## Practical controls

Keep sensitive archives on storage you trust; protect both the vault and caches. Use built-in local AI rather than a cloud-backed MCP client for local analysis. Review service/player controls before opening external content. Back up durable vault data before migrations. Deleting a rebuildable index does not delete the vault, AI cache, exports, synced copies or other backups, and deleting local files does not promise secure erasure.

See [SECURITY.md](SECURITY.md) for vulnerability reporting and threat boundaries and [the disclaimer](docs/DISCLAIMER) for project scope.
