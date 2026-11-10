# Changelog

## 1.0.5 — 2026-11-10

- **You can see how many people reacted, under each message.** A reaction used to be counted in Wrapped and nowhere else. Now the emoji sit on the bubble's bottom edge the way they do in WhatsApp — 😂 3, ❤️ 1, in whatever order people tapped them — and pointing at one, or clicking it, shows who reacted. Two taps each from the same person still count once.
- **Switching chats no longer leaves you in the last chat's Heartbeat.** Open a conversation from the chat list and it starts on Messages. Before, it kept whichever tab you last looked at, so a new chat could open on another chat's year in review and look empty.
- **A jump from Wrapped offers a way back.** When a moment sends you to the message it is talking about, a thin bar under the header says **Back to where you were** and returns you to the story, the message and the tab you left. If the message is gone from the archive, the chat still opens at that date rather than a blank pane.

## 1.0.4 — 2026-11-10

- **Update from phone now brings the reactions with it.** Reactions and stickers used to arrive only on a first import; a pull from the phone wrote the messages and silently skipped what people did to them, so an archive updated that way reported nothing. The import path the *Update from phone* button uses now carries both. On the owner's archive that was 51,596 reactions and 2,341 stickers that were already on the phone and missing from Saga.
- **Hearts are counted separately from laughs.** One "reactions" number added 💚 to 😂 and told you nothing; a message that got a heart looks nothing like one that got a laugh. Hearts now have their own count and their own card, and neither is added to the other. 👍 stays out of both.
- **Stickers have a number.** They were being filed as photos. Now they are their own kind, identified by the file itself, so one sticker sent 41 times is one sticker used 41 times rather than 41 pictures.
- **A moment shows what it collected.** Wrapped's notable messages now print the message with its count — `the thing you said  (6 reacts)` — the emoji breakdown under it, and the replies that quoted it, indented and attributed. A moment used to be a floating sentence taken on trust.
- **Wrapped's numbers are honest now.** A group comparison counted messages where it claimed groups; "days you turned up" counted any day anyone wrote; "the most hilarious moments" meant the loudest, not the funniest; one stat mixed your voice with a real name; reply times were capped at six hours and spans were off by one day. The rates, the plurals and the comparisons are measured against the data now, and a claim the numbers cannot support is no longer printed.
- **Inside jokes are checked before they are printed.** The extractor could offer an @mention, a phone number or a participant's own name as the joke. Those are rejected; what is left is a phrase people actually repeated.
- **The tiles on Home go somewhere.** Each module is a control now — press it and it opens the thing it counts. A number that does nothing when clicked reads as decoration.
- **"See it in the chat" is safe.** A moment's jump resolves the message before trusting it: if it is no longer in the archive, you get the conversation and a plain sentence saying so, not an empty screen.

## 1.0.3 — 2026-11-10

- **Live pulls work on a Mac where Saga installed its own copy of adb.** Setup has always been able to download Google's platform-tools for you, and importing a backup used that copy — but the phone status check only looked in Homebrew's folders, so on a Mac without Homebrew it reported the phone as absent and photos never came off the device. It now looks at the copy it installed first. If your phone pill said *Disconnected* while the cable was in, this is that fix.
- **Saga tells you when there's a new version.** Once a day, on launch, it asks GitHub for the latest release — one request, nothing about you or your archive sent — and puts a one-line note on Home when there's something newer, with a link to the download. Dismiss it and it stays quiet for that version. Settings → Archive → Updates has *Check now*, a *Skip this version* and a switch to turn the whole thing off.
- **This is the last release you install by hand.** Update checking can only live in a build that already has it, so 1.0.3 is the one copy to install yourself; from here the app can point you at the next one.

## 1.0.2 — 2026-11-09

- **Voice notes have their own shelf.** The Gallery now has a Voice notes tab, in a list rather than a grid because a voice note has no picture. Each row says who sent it and which chat it came from — in a group, "who" without "where" tells you nothing — with the date, the duration and one player for the whole list, so starting a second note stops the first. A note that exists only in your cloud backup says *Not on this Mac — connect your phone* instead of spinning.
- **Media inside a chat is the Gallery, narrowed to that conversation.** Open any chat and its Media tab now carries the same tabs, cards and playback as the Gallery, scoped to the two of you. The Gallery's chat filter is a search field you type into instead of a dropdown of every conversation; with nothing typed it shows all of them.
- **Find inside the conversation.** ⌘F opens a find bar under the chat's header with a count of matches and next/previous; every hit is highlighted in what is on screen, and a hit further back jumps to its place. Searching everything is ⇧⌘F, which is what the top-bar field has always done.
- **One Ask.** Ask is a single button in the top bar (⌘K) that opens the panel; the chat's own Ask tab is gone, so there is one door instead of two with different scopes. The chat header is Messages · Media · Heartbeat.
- **Readability and spacing pass.** The text on screen was measured, and where it fell short of 4.5:1 it was darkened or lightened: the Ask button went from 1.68:1 to 7.48:1, secondary text from 3.76 to 5.72, timestamps on your own messages from 3.61 to 4.78, and sheet buttons now use the app's own accent. Message bubbles size to their text instead of a fixed width, timestamps sit inside the bubble, and the top bar collapses gracefully down to a 900-wide window.
- **Wrapped describes a partial year honestly.** If your archive covers part of a year, the page says how many days it actually covers instead of implying the missing months were quiet.
- **The reply sheet is a list you can act on.** *Might need your reply* defaults to the last six months, newest first, with Dismiss and Undo per row, and says how many older questions the window left out.
- **One home for the archive tools.** Settings now owns import, backups, media folders and clean-up, and the Go menu mirrors the places without competing with them. One word for one chat's story: **Heartbeat**.
- **Small local models work.** The local AI path parses more loosely, so a 3B model on Ollama (qwen2.5:3b, verified) can answer without perfect JSON.

## 1.0.1 — 2026-11-09

- **“Might need your reply” starts at today, not 2017.** The list is limited to a recency window (default six months; adjustable to 1, 3, 6, 12 or 24), ordered newest question first, and the sheet states the rule on screen — including how many older unanswered questions the window left out. A chat that has been quiet longer than the window is treated as history, not as a reply you still owe.
- **Merging contacts works.** Nine sheets were stacked on single views, and macOS presents only one per chain — so several windows (Merge contacts, Clean up spam, On this day, Fold in, Media sources, Unlock) could silently fail to appear. Each sheet now has exactly one presentation host.
- **Name a chat you recognise.** People gained *Chats without a name*: every unresolved chat split by kind (person, business, newsletter, group), searchable and paged, with *Name…*, *Not a person*, and *Merge into…* to fold an obsolete number into someone already in your contacts.
- **The phone's address book is a name source.** `config/phone-contacts.json`, with precedence saved contact > WhatsApp profile name > number. Measured on a real archive: 735 of 786 numbers matched; the rest are unsaved strangers or LID chats with no number to join on.
- **Timing alone no longer merges two people.** A DM-handoff signal can never pair two chats saved under different real names.
- **Placeholder labels are not evidence.** "(unnamed group)", masked numbers and letter-free names can no longer produce merge suggestions.
- **A merge must be provably saved.** Writes are re-read and surfaced as an error instead of failing silently.

## 1.0.0 — 2026-11-08

First public release. Your WhatsApp history, on your Mac.

- Decrypt an Android (crypt15) or iPhone backup, and merge older copies into one archive.
- Chats, people, search, a year in Wrapped, and a Gallery of every photo, video and link.
- Optional passphrase encryption with a recovery kit; local-only AI that cites its sources.
- A phone pill that tells you when a cable is attached, and can pull a backup or a single photo.
- Imports are fingerprinted, so a different phone or number is kept as its own source instead of being merged by accident.

Not yet: notarised builds, a live iPhone pull, MTP (macOS has none), and media consolidation — cloud fill, phone cleanup and a wireless inbox are designed in docs/MEDIA-CONSOLIDATION.md, not built.

## 0.2.0 — unreleased

Pre-public preview. Everything below is in this build; nothing has shipped as a signed download yet.

**Archive**

- Vault of append-only segments, with a rebuildable SQLite index. Older backups merge into the same timeline, and messages deleted on the phone are flagged rather than dropped.
- Optional vault encryption: passphrase plus an independent recovery code, printable recovery kit, and an unencrypted index you can rebuild.
- Media resolved on demand from local folders, a NAS or Google Drive, with a thumbnail cache and no bulk downloads.
- Reversible per-chat cleanup: media, repeats, link-only posts, whole chats.
- Contact merging with reasons, carrying cleanup rules and saved summaries across merged numbers.

**Reading**

- Search with jump-to-message, People, group and per-person Wrapped, a year Wrapped rewritten as a story, On This Day, and a music and video timeline with in-place players.
- Find inside the open conversation (⌘F) with a match count and next/previous; the top-bar search (⇧⌘F) always means every chat.
- Import from Android `crypt15` over USB or a file, and from an existing iPhone backup folder.

**AI, all local**

- Catch me up, Ask (one panel: it asks the chat you are reading, and the scope chip widens it to every conversation), per-chat topics, and "who needs your reply".
- Apple Intelligence on macOS 26, or Ollama and LM Studio. Every answer cites the messages it used.

**Tools**

- `saga` CLI, and a read-only MCP server for Claude Code and other clients.
- `saga demo` builds a 20,600-message synthetic archive for testing and screenshots.

## 0.1.0

First working build: decrypt, import, index, browse and search a single Android backup, with an early SwiftUI shell.
