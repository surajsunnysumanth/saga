# Design audit: every surface, with real captures

**Date:** 9 November 2026 · **Branch:** `swift` · **Baseline:** `c6df75b` · **Application code changed:** none.
**Method:** built a fresh synthetic vault (`saga demo --out ~/saga-assets/audit-demo-1 --photos fixtures/demo-photos`), rebuilt `build/Saga.app` with `scripts/make_app.sh`, and captured the app in dark mode at 1440×900 and 900×700 with the snapshot harness. Every surface was read with an image model at 1440, with the 900 variant checked for reflow, clipping and target size; nothing is judged from code alone. Code references are given for every structural claim. Ask and a few AppKit-backed controls do not rasterise offscreen; that limitation is called out where it matters (`docs/WORKER-BRIEF.md:51`).
**Evidence:** 23 PNGs under `~/saga-audit-shots2/` (not committed; listed in the appendix). The pre-existing `docs/screenshots/audit/` JPEGs cover a subset (Home, chat, search, reply, Gallery, Insights) and were used as a cross-check.

The visual language is not the problem. The dark green field, glass panels, one teal/green accent, large hero numbers and editorial copy are coherent and distinctive. The problems are geometry at the minimum width, a reading surface that does not size to its content, navigation instantiated twice, and housekeeping surfaces that still behave like developer tools. This audit is a repair list for that language, not a proposal to replace it.

One process finding matters before any design conclusion: **the first `build/Saga.app` on disk was stale.** It showed only `Archive` and `Privacy` in Settings and an older reply sheet. After `scripts/make_app.sh`, Settings showed all four panes and the current reply rules. If the owner still sees “all time, oldest first” or tools that exist only in the Go menu, the first thing to check is that the running bundle was rebuilt. `docs/CONTACTS-STATE.md` warns about exactly this.

---

## The short version

1. **The top bar breaks at 900.** The centred five-place capsule (~350pt) and the trailing phone/search/Ask cluster (~430pt) overlap by **~171pt**; “Insights” and “Settings” are painted under the search field, and the Ask button is clipped. This is the worst defect in the app because it affects every screen at a supported width.
2. **Every message bubble is 560pt wide.** Measured from the capture: a one-word incoming message (“true”) is a **560×63pt** bubble at 1440, and a **508×63pt** bubble at 900 (the 528pt column minus the 20pt spacer). The timestamp gets its own line inside the bubble. The reading surface is therefore both too wide and too tall for almost every message.
3. **⌘F is a false promise.** The search pill prints `⌘F`, but no `.keyboardShortcut("f")` exists in `Sources/SagaApp`. There is no find-in-chat field. The only way to scope a search is to run a global search and then tick “Only <chat>” on the results page.
4. **Ask is two products with one name.** A global pill (⌘K) and a fourth chat mode both say “Ask”, open different chrome, and the global one can silently stay scoped to the current chat from a previous toggle. The chat header also pays 68pt for the duplicate mode.
5. **The reply feature’s ordering bug is fixed in source, but its placement and row are not.** `ReplyResponsibility` defaults to 6 months and sorts newest first (`ReplyResponsibility.swift:99,134-136`). What remains is a Go-menu/Settings-only entry, a row that repeats the date and “quiet for N days”, an “Open chat” button that actually jumps to a message, and no way to dismiss a handled question.
6. **People has no home.** The top bar has no People; the Chats sidebar has no switch to it. People is reachable only from Go > People (⌘2) or the Home “People” tile, and while you are there the top bar still highlights **Chats**.
7. **The tools are in Settings now, but still duplicated in Go.** Current code puts Merge contacts, Chats without a name, Clean up spam and Might need your reply under Settings > People & chats. The Go menu still repeats all of them, plus Ask, Music & video, On this day and place navigation. The failure is duplication and discoverability, not absence.
8. **Copy and vocabulary drift.** “Wrapped for you two”, “Group Wrapped”, “Group Wrapped: …” and the Go item “Wrapped” (which opens Insights) all break the binding distinction between Wrapped (the year) and Heartbeat (one chat). Heartbeat then prints the chat name three times.
9. **Contrast is broken in exactly the places that carry action or metadata.** The dark Ask pill is **1.68:1**; `textTertiary` is **3.76:1** on cards and **4.0:1** on the page; outgoing timestamps are **3.61:1** at 12pt.
10. **Primary actions in sheets fall back to macOS system blue.** `PruneView` and `MergeView` use `.borderedProminent` without the app tint, so the most consequential buttons (“Hide selected (10)”, “Merge”) do not use the app’s accent.

---

## Screen by screen

### Global chrome: the top bar

**Capture:** `1440-chats/2-chat.png`, `900-chats/2-chat.png`, `900-home/1-dashboard.png`, `900-heartbeat/2-chat.png`.

At 1440 the bar works: places are optically centred, the phone status, 216pt search pill and 89pt Ask pill sit on the right, and there is ~99pt of air between the groups. At 900 it fails.

`Chrome.swift:146-175` is a `ZStack` with two independent layers: a centred `HStack` of five place chips and a trailing `HStack` containing `PhonePill`, `SearchPill` and `AskPill`, with no width negotiation. The place capsule is ~350pt wide and sits at x≈275–625. The trailing cluster is ~430pt wide and starts at x≈454. **They overlap by ~171pt.** The capture shows “Insights” and “Settings” underneath the search field; the Ask pill is clipped at the right edge in the 900 Heartbeat capture. The comment in the code says the places stay “optically centred no matter how wide the right-hand cluster gets” — the overlap is the intended consequence of that rule, not an accident.

The phone status is also semantically wrong. `PhoneStatus.absent` returns the bare string **“Disconnected”** (`PhoneLink.swift:10-16`), drawn in a capsule with a grey dot, no chevron, and `menuIndicator(.hidden)` (`Chrome.swift:240-247`). It reads as network/server state, contradicts the Home hero’s “Up to date”, and has no visible object (“disconnected from what?”). It is a menu that offers “Pull a new backup…” and “Copy photos…”, but looks like static status.

The Ask pill is the least legible control in the chrome. Its label is `Accent.text` (#3FD2A0) on `Accent.tint` (#DCF8C6) at 55% over the dark field, which composites to ≈#7F947B: **1.68:1** (`Chrome.swift:300-306`). It looks disabled, which is the opposite of what a global entry point needs.

The search pill prints `⌘F` at 10.5pt (`Chrome.swift:272`). No `keyboardShortcut("f")` is registered anywhere in `Sources/SagaApp`; the only ⌘-letter commands are in `SagaApp.swift:36-52` (0/1/2/3, K, ⇧D). The hint is therefore false.

**Fix direction:** one row, not two layers. Put the place capsule leading (or keep it centred but give the trailing cluster layout priority and a real minimum gap), hide/collapse the phone pill when no phone is connected, collapse the search to a 32pt icon below ~1100pt, and give Ask a solid, readable fill. At 900 the acceptance is: five places and three controls fully visible with ≥8pt between groups.

### Home

**Capture:** `1440-home/1-dashboard.png`, `900-home/1-dashboard.png`.

This is the strongest screen. “Your archive” → 20,600 messages → four modules → Recent conversations + On this day → two Insight panels is a clear editorial hierarchy. The hero card is the only place with a large number and a single primary action; the four module tiles are consistent in size and icon placement. At 900 the four tiles remain four across (cramped but not clipped), and the hero reflows without losing its button.

Specific issues:

- **Two statuses disagree.** The chrome says “Disconnected”; the hero says “Up to date”. They are unrelated facts read as one.
- **The Ask pill is pale and low-contrast** (1.68:1) while “Update from phone” is the only solid teal action. The global Ask is therefore hard to find, not too prominent.
- **The “Wrapped” tile shows “2026” where the other tiles show a count.** It is a date in a numeric slot; “14 Chats”, “22 People”, “99 Music & video” establish the pattern. A year is defensible, but the one-line caption (“Your year in messages and hours”) is the only place the value is explained.
- **“99 Music & video” counts links, while Gallery reports Links 99, Music 63 and Video 57 separately.** One number is doing duty for two nouns (`HomeView.swift:338-354`, `Places.swift:257`).
- **Recent conversations stops at four rows with no “View all”.** The card has visual room and no exit; the chat list is one click away in the chrome, so this is minor, but the card reads unfinished at 1440.
- **The bottom band is unbalanced at 1440.** Recent conversations is shorter than On this day; the empty space under the fourth row is visible. Not a defect on its own, but the card could carry a “View all” footer or one more row.

At 900 the page scrolls; nothing is horizontally clipped. The top-bar collision is the only hard failure.

### Chats list

**Capture:** `1440-chats/1-dashboard.png`, `900-chats/1-dashboard.png`.

The list itself is good: 296pt fixed column, 34pt avatars, 15pt/600 names, 13pt previews, right-aligned 11pt times, hairline separators, 6pt vertical padding. “14 chats · Most recent” is useful. The three kind chips (All chats / Direct / Groups), the “Filter chats” field and the sort menu are each defensible.

The problems are semantic and hierarchical:

- **Every row has a green dot.** `isFresh` marks a chat if its latest message is within 24 hours of the newest message in the library (`MainViews.swift:237-240`). The demo’s entire archive ends on 31 Oct 2026, so all 14 rows are “fresh”; in a real archive the same rule will mark a large block. The dot reads as unread/online, but the archive has no read state. It is decoration pretending to be data.
- **The selected row is marked twice.** `List` paints a selection band and `ChatRowView` paints its own rounded selection fill (`MainViews.swift:112-121,249-284`). The capture shows a grey band plus a green-tinted row. One selection treatment is enough.
- **“Filter chats” and “Search messages” look like the same instrument.** The sidebar field filters the list; the top field searches every message. The words “Filter” and “Search” are correct, but the two fields are 20pt apart vertically and visually similar. At 900 the top search also collides with the place capsule, so the distinction is lost.
- **There is no Chats | People switch.** This is where People should live (see below), not in a Go menu.
- **“Most recent” is stated in the status line and set in the sort menu.** It is not wrong, but it is a duplicate label above a list that is visibly sorted.

### Conversation — Messages

**Capture:** `1440-chats/2-chat.png`, `900-chats/2-chat.png`.

The header is the clunky part. It contains avatar + title + “900 messages · since Nov 2023”, a fixed **272pt** four-segment control (Messages / Media / Heartbeat / Ask), and an ellipsis menu. At 900 the chat pane is ~568pt wide; after 32pt header padding, a 30pt avatar, 12pt spacing, 272pt picker, 12pt spacing and a 14pt ellipsis, the title block gets ~196pt. “College Gang 2016” needs ~222pt at 25pt bold, so it renders as “College Ga…” and the subtitle as “900 messages · since Nov 2…”. Removing the Ask mode would free 68pt and the title would fit; that is a measurable reason to fix complaint #3 first.

The bubbles are the bigger defect. `Bubble` applies `.frame(maxWidth: 560, alignment: .leading)` to the whole VStack and puts the timestamp in a child with `.frame(maxWidth: .infinity, alignment: .trailing)` (`MainViews.swift:490-519`). In the capture, a connected-component measurement of an incoming bubble gives **1120×126px at 2× = 560×63pt** for the message “true”. At 1440 the bubble is 560pt wide — about half the 1,068pt message column — for four letters. At 900 the 528pt column leaves ~508pt for the bubble; it is effectively full width. Every one-line message also pays a second 12pt line for the timestamp plus 2pt spacing. This is the main reason the chat feels long and airy in the wrong way.

Other issues in the stream:

- **No find.** The only field on screen is the global one in the top bar. There is no magnifier in the conversation header.
- **The system notice is drawn as a person’s bubble.** “Security code with Priya Menon changed. Tap to learn more.” appears as a normal incoming bubble with no sender, and “Tap” is a phone verb. It should be a centred 11pt system line in the day-divider style, with “Click”.
- **The day divider is very quiet.** 12pt secondary text on a #182229 pill with 16pt outer vertical padding; it works, but the weekday makes it longer than it needs to be (“Wednesday, 28 October 2026”).
- **The ellipsis menu carries too much.** “Show” filter, “Jump to a date…”, “Clean up spam…”, “What this chat talked about…”, and Export all live behind one icon. Find should not join that pile; it deserves a visible field.

### Conversation — Media

**Capture:** `1440-media/2-chat.png`, `900-media/2-chat.png`.

The reuse of the Gallery browser inside the chat is the right architecture: same tabs, same cards, same year/sort controls. Two problems:

- **Every card repeats the chat name.** `MediaCard.footer` always renders `item.chatName` plus month/year (`Places.swift:723-735`). Inside “College Gang 2016”, the caption reads “College Gang 2… Aug 2026” on every card; the name is the only part that truncates, and the date loses the day. The reader already knows which chat they are in.
- **At 900 the mode header truncates the chat title** for the same 272pt reason as Messages. The media tabs themselves are in a horizontal scroll view in a chat (`Places.swift:158`), so they survive the narrow width; the header does not.

The large empty area under a 6-item grid is honest, not a defect: a chat with six photos should not stretch them. The caption strategy is the defect.

### Conversation — Heartbeat

**Capture:** `1440-heartbeat/2-chat.png`, `900-heartbeat/2-chat.png`.

Heartbeat repeats identity three times before any data:

1. chat header: **College Gang 2016**;
2. sub-header: **Group Wrapped: College Gang 2016**;
3. hero: eyebrow **GROUP WRAPPED**, title **College Gang 2016**.

Then “WHO TALKS” repeats the group’s numbers. At 900 the chat title is “College Ga…”, “Sandeep Kulka…” is truncated in the bar list, and the Ask button is clipped by the top-bar collision. The hero number (900) and the “Who talks” bars are strong; the duplicate labels are the problem.

This is also a vocabulary failure. DESIGN.md defines **Wrapped** as the year under Insights and **Heartbeat** as one chat/group’s own story. The sub-header (`GroupWrappedView.swift:66`), the eyebrow (`WrappedStory.swift:788`), the export filenames and “Wrapped for you two” (`PeopleViews.swift:159`) all use “Wrapped” for the per-chat/person product. The mode tab says Heartbeat; the content says Group Wrapped. Pick one word and enforce it.

### Gallery

**Capture:** `1440-gallery/1-dashboard.png`, `900-gallery/1-dashboard.png`.

The grid is coherent and the kind counts are the best part of the screen: **Images 311 · Video 57 · Voice notes 27 · Music 63 · Links 99 · Documents 13**. The filter row (All conversations / All years / Newest first) is clear, and the item count on the right is useful.

Issues:

- **Density vs caption legibility.** `adaptive(minimum: 160, maximum: 210)` gives **8 columns at 1440** (`Places.swift:366-368`). At 160–210pt, a 10.5pt caption cannot hold a chat name and a date: the first row alone shows “Sunday Footb…” twice and “Wedding Prep…”, and the pattern continues down the grid (“Kerala Trip Cr…”, “Weekend Trek…”, “Book Club (m…”). The grid is fine for photos; the caption is doing too much. Either widen the cards to 200–240 (6 columns) or move the chat name to a second line and let the date be the first.
- **At 900 the kind tabs are over-constrained.** The Gallery header is a single `HStack` of title + subtitle + spacer + six fixed-size tabs (`Places.swift:163-173`); unlike the in-chat header, it has no horizontal `ScrollView`. At 900 the last tab (“Documents 13”) sits at the edge and is the first thing to clip. The chat Media header already solves this with a scroll view; Gallery should use the same rule.
- **The total is stated twice.** “Images 311” in the tab row and “311 items” in the filter row 40pt below. One is enough.
- **Dates are tertiary 10.5pt** at 3.76:1 on the card; at this size the date is information, not decoration.

### Insights / Wrapped

**Capture:** `1440-insights/1-dashboard.png`, `900-insights/1-dashboard.png`.

This is the second-strongest screen: a 260pt year sidebar, a green hero with a very large year number, one chart, and editorial copy. The hierarchy is clear, the chart is real, and the “On this Mac only” badge is a good use of the privacy language.

Issues:

- **A partial year makes a false claim.** The 2026 hero says “You turned up on 304 days. The other 61, you were missed.” The archive ends 31 October 2026; the other 61 days are November and December, which have not happened (`WrappedCopy.swift:325-331`). The same partial-year arithmetic produces “January to October: 10 of the twelve months have messages.” The year count is honest; the sentence around it is not. Use the covered span (1 Jan–31 Oct, or first message–last message) and say “304 of the 304 days in this archive” for a partial year.
- **“Titles” is unexplained.** A toggle at the top right changes whether song titles are fetched; the label is a noun with no object. “Big titles” or “Fetch song titles” with a help string would be clearer.
- **Year counts 2023 and 2024 are both 1,853** in the demo; that is fixture data, not a design issue, but it makes the sidebar look copied.
- **The chart’s axis labels are 10pt tertiary** and the footnote is the smallest text on the screen. At 900 the chart scrolls out of the viewport; that is acceptable for a long page, but the first screen should end at a natural break rather than mid-chart.
- **The page is called Insights in the chrome, Wrapped in the sidebar and hero.** That is the intended hierarchy (Insights is the place, Wrapped is the year), but the page never says “Insights” after the top bar. A subhead “Insights · Wrapped” would connect them.

### People

**Capture:** `1440-chats/4-person.png`, `900-chats/4-person.png` (the harness opens the first person after search), and `settings-people.png` for the tool entry.

People is a real screen with a clear spine: 296pt list, search + sort, 22 people, then a person detail with four numbered cards, three actions, a year chart and “Where else you talk”. It is also the clearest information-architecture failure:

- **People is not in the top bar.** `Place` has Home, Chats, Gallery, Insights, Settings (`Chrome.swift:6-23`). People is `section = .people` inside Chats (`SagaApp.swift:39,86`). The only visible entries are Go > People (⌘2), the Home People tile, and the two rows at the top of the People sidebar. While you are on People, the top bar highlights **Chats** (`AppModel.place` returns `.chats` for a non-wrapped section). A first-time user cannot get here from the chrome.
- **Three equal actions.** “Merge with another number…”, “Open conversation (2,200 messages)” and “Wrapped for you two” are in one row with no visual primary. “Open conversation” is the action people want; merge and Heartbeat are secondary. Put one primary and move the other two to a menu or a quieter row.
- **“Wrapped for you two”** is the wrong noun for a per-person story (see vocabulary above).
- **The sidebar repeats Settings.** “Merge contacts” and “Chats without a name” sit above the list. They are useful contextually, but they are also the first two rows of Settings > People & chats. One of the two placements should be a link, not a duplicate control.
- **At 900 the detail chart and list scroll**; nothing clips horizontally except the top bar. The four stat cards still fit.

### Settings — Archive

**Capture:** `1440-settings/1-dashboard.png`, `900-settings/1-dashboard.png`.

The place is a 760pt column with a 460pt four-tab segmented control, then three glass groups. The groups are sensible: Where the archive lives, Backups, Media. The copy is unusually good: “The archive is a folder of plain files…”, “Adding an older backup merges it into the same archive…”. The 900 capture fits all four tab labels; the content scrolls.

Issues:

- **The media row leaks the owner’s real path in demo mode.** The capture shows a `/Users/…/CloudStorage/GoogleDrive-<account>/…` path and real file counts. That is a data leak in a synthetic run, not a design choice; it also produces a 60+ character monospace line that truncates. In demo, resolve only under `demoRoot` or show “Not checked in demo”.
- **“Found 408 of 408 indexed photos, videos and documents (100%)”** is a status report inside a card that otherwise contains editable actions. It reads as a setting. Put it under a “Media health” disclosure or a small status row with a “Show missing…” link.
- **Every detail is monospaced.** `SettingRow` renders the detail line with `.system(.caption, design: .monospaced)` (`SettingsView.swift:80-85`). DESIGN.md reserves mono for file paths and CLI. “Numbers that are one person, with the evidence” and “Quiet questions, found without a model” are prose set as code; it makes the whole pane feel like a diagnostic tool.
- **The tab label “People & chats” hides the tools.** The owner looking for Merge contacts has to know that “People & chats” is the housekeeping tab. Rename it or split it (see complaint #4).

### Settings — People & chats, Home, Privacy

**Captures:** `settings-people.png`, `settings-home.png`, `settings-privacy.png` (live window at 1268×1030, because the snapshot harness only opens the Archive tab; the pane is width-capped at 760 so the reading width is the same).

The current code does what complaint #4 asked for: `PeopleSettingsPane` contains Merge contacts, Chats without a name, Clean up spam and Might need your reply (`SettingsView.swift:217-248`); `HomeSettingsPane` contains On this day (`:250-270`); `PrivacySettingsPane` contains protection, encryption, what leaves the Mac and the MCP command (`:273-344`). The problem is that these are still one tab away, labelled by audience rather than task, and the Go menu still repeats them.

The Privacy pane is well written and well grouped: Protection → Turn on encryption → What leaves this Mac → Other apps. Two issues: “Copy Claude Code connect command” is an integration, not a privacy fact, and there is **no AI pane** at all. Model choice and the semantic index live only inside the Ask inspector; DESIGN.md says Settings should have an AI pane. The MCP command and AI settings belong together under “Privacy & AI” or “AI & other apps”.

The Home tab contains a single toggle (“Show ‘On this day’ on Home”) and an “Open today’s page…” row. It is a whole tab for one setting, and the tab is named after a place, which makes “Settings > Home” read like a destination rather than a category.

The duplicate Settings scene is a structural bug: `Settings { SettingsView() }` is declared at `SagaApp.swift:63` while Settings is also a place in the main window. Pressing ⌘, opens a second window with a second copy of the same view instead of navigating the place. Delete the scene and route ⌘, to `model.go(to: .settings)`.

### Sheets

**Reply — `1440-ai/18-reply.png`.**

The current sheet is 780×640 (min 660×600), with a header, controls, rule note, list, footer. It answers the owner’s original complaint in code: default window **6 months**, choices 1/3/6/12/24, sort by question date **descending**. The sheet also says “newest first” twice: in the subtitle and in the rule note.

Residual problems:

- **Row copy repeats itself.** “31 Oct 2026 · quiet for 8 days” says the same fact twice, in two formats. The question is the least prominent line (rowName 15, rowMeta 11, rowPreview 13; the question uses rowPreview and is limited to two lines).
- **“Open chat” is the wrong promise.** `replies.open` calls `app.jump(toMessage:in:)` and dismisses (`ReplyResponsibilityView.swift:76-83,280-283`); the button should say “Show in chat” or “Open message”, not “Open chat”.
- **No handled state.** A question that has been answered on the phone can never leave the list until the archive is updated; the list only shrinks when the data changes. “Dismiss” (local, reversible) is needed for trust.
- **No grouping and no count.** One row floats in a 600pt-tall sheet. “1 question · quiet at least 3 days” and “This week / Earlier” would make the list legible at a glance.
- **Placement.** It is only in Go > Might need your reply and Settings > People & chats. A to-do belongs on Home when the count is non-zero, and/or as a “Waiting on you” filter in Chats.

**Merge contacts — `merge.png`.**

The sheet is 620×680, fixed (`MergeView.swift:102`). The three sections are right: manual two-person merge, suggested pairs with evidence, your merges. With no suggestions in the demo, “Suggested: possibly the same person” is followed by “None found.” and the sheet is mostly empty. The manual fields are two side-by-side pickers (“Keep this person” / “Merge this one into them”); the flow is understandable but the sheet does not collapse to its content.

“Unmerge” is a destructive action styled as an ordinary bordered button (`MergeView.swift:239-245`). It needs a destructive role and a confirmation that names the merges being split.

**Clean up spam — `prune.png`.**

This is the most dangerous screen in the app. `PruneModel.load` pre-selects **every** suggestion (`chosen = Set(suggestions.map(\.jid))`, `PruneView.swift:28`), so the primary button reads **“Hide selected (10)”** before the user has looked at a single row. The list says “Hiding repeats · about 2,302 of 6,000 messages · you wrote 956”; “repeats” is never defined. The primary button is inline after the list, while “Close” is in a separate footer; the sheet is 640×640 and the list scrolls. The checkboxes and prominent button use the system accent (blue), not the app’s teal.

**On this day — `1440-otd/6-onthisday.png`, `900-otd/6-onthisday.png`.**

The sheet has the richest structure in the app: date navigation, a year histogram, a “LAST YEAR” card, first/last message, the biggest-laugh exchange, people chips and media. At 900 the controls all fit, but the people chips overflow horizontally and the last chip is cut (“E.”), with no visible scroll indicator. The date picker is set to **28/11/2026** while the archive ends 31 October 2026, so 2026 is a dash in the histogram; the picker has no range (`OnThisDayView.swift:104-126`). Clamp it to the archive’s first–last message; a future date should be impossible.

**Chats without a name — `1440-unnamed/4-unnamed.png`.**

The sheet is well structured: title, “0 unnamed”, search field, kind tabs, empty state, footer, Done. But the demo has **zero** unnamed chats, so the capture is the empty state “Every chat has a name” and the row/naming design cannot be judged. For a feature whose value is naming 8,000 strangers, the demo fixture should include three unnamed numbers/groups so the sheet can be photographed with real rows. This is a fixture gap, not evidence that the screen is broken.

**Ask — `1440-ai/16-ask.png`, `900-ai/16-ask.png`.**

Judge Ask by code and placement, not by the missing pixels. The inspector’s material does not rasterise offscreen (`docs/WORKER-BRIEF.md:51`), so the composer and segmented controls are absent from the captures; the visible “Also match meaning” block is only the part that draws itself. The structural findings are code-verified:

- `ChatMode` includes `.ai = "Ask"` (`SagaApp.swift:79-85`), so the chat header has a fourth mode; the inline `AIPanelView(showsClose:false)` then has its own `Catch me up / Ask` segmented control (`AIViews.swift:407-411`). That is two layers of Ask chrome inside one pane.
- The global `openAsk` sets `thisChatOnly = model.selected != nil && thisChatOnly` (`AIViews.swift:163-166`). If the checkbox was left on in a previous chat, the global Ask silently stays scoped to the currently selected chat. The global pill has no visible scope indicator.
- The Ask button is disabled when no model is selected (`AIViews.swift:493`), but DESIGN.md says Ask should degrade to Search and say so in one line. The spec and the implementation disagree.

---

## Cross-cutting findings

**Contrast (WCAG relative luminance, dark theme).**

| Pair | Ratio | Verdict |
|---|---|---|
| Ask label #3FD2A0 on 55% green-soft fill ≈#7F947B | **1.68:1** | fail; looks disabled |
| `textTertiary` #667781 on card #111B21 | **3.76:1** | fail at 10–11pt |
| `textTertiary` #667781 on page #0B141A | **4.0:1** | fail at 10–11pt |
| Outgoing timestamp: #E9EDEF at 62% over #005C4B → #90B6B1 | **3.61:1** | fail at 12pt |
| Secondary #8696A0 on card #111B21 | 5.72:1 | pass |
| Primary #E9EDEF on card #111B21 | 14.82:1 | pass |

`textTertiary` is used for Gallery dates, Home recent times, counts and placeholders — information, not decoration. Raise it to #8696A0 (5.72:1 on card, 6.1:1 on page). Raise outgoing timestamps to `onMine` at 0.78 or move them onto the bubble edge. The Ask fill needs a solid dark surface (#12352A or teal #075E54 with white).

**One accent, many primaries.** The selected place chip is teal; the Ask pill is green-tinted; the hero button is teal; sheet primary buttons are system blue; “Merge” and “Scan” are system blue. DESIGN.md says one accent per section. Decide that the app’s primary button is teal with white, and set it once in the theme (or a button style), not per view.

**Type.** The system stack is right. Two drifts: prose details in monospace (`SettingsView.swift:82`), and 10–10.5pt metadata used for real information (Gallery dates, Settings section eyebrows, chart axes). DESIGN.md says mono only for paths/CLI; it says body 17px on the site but the app uses 13px body, which is fine for a dense Mac app — the problem is not the 13px body, it is 10px information.

**Sheets.** Reply, Merge, Prune, On This Day and Unnamed do not share a header: Reply has a 20pt symbol + 25pt title + Local-only badge; Merge has a 20pt symbol + title2; Prune has the same; Unnamed has a title and a count; On This Day has an eyebrow + large date. Unify: 20pt symbol, 20pt semibold title, 12pt secondary subtitle, Local-only badge where relevant, Close trailing, 24pt gutter. The sheets also use stock macOS controls (rounded text fields, default checkboxes, system-blue prominent buttons) while the main window uses glass; that is the source of the “developer tool” feeling in Merge and Prune.

**Vocabulary.** The binding table in DESIGN.md is good and the UI breaks it in four places: “Wrapped for you two”, “Group Wrapped”, “Group Wrapped: …”, and Go > “Wrapped” (which opens Insights). “Heartbeat” should be the only word for the per-chat story; “Wrapped” only for the year. Add a string-lint test for `Wrapped` outside the year views.

**Copy accuracy.** The Wrapped partial-year claim (“the other 61, you were missed”) is the one place where copy is not just inconsistent but false. It costs more trust than any spacing issue. Fix the data span before polishing anything in Wrapped.

**Privacy language.** “Local only”, “On this Mac only”, “everything stays on this Mac”, “searchable offline”, “Nothing is sent anywhere” and “Nothing leaves this Mac” all appear. Pick one badge (“Local only”) and one sentence (“Nothing leaves this Mac.”); keep the specific caveats about old backups, which are different claims.

**Empty states.** They are a strength: the search empty/error states, the Wrapped empty state, the unnamed empty state and the chat empty state all have an illustration, one sentence and one action. Keep this pattern when adding find, reply dismissal and People.

**What to protect.** The exact, limited claims (“A chat is listed only when its latest archived message is their question…”, “An old backup can't show what you've answered since”, “Messages missing from the newer phone copy stay, flagged as deleted”) are the app’s voice. Do not cut them to win density. The Wrapped false claim is what happens when the same voice is allowed to claim more than the data supports.

---

## The ten fixes that would most improve the app

Ranked by impact on daily use, not by effort.

1. **Fix the top bar at ≤1100pt.** One row: place capsule leading (or centred with layout priority), trailing phone/search/Ask cluster after a flexible spacer. Below 1100: hide the phone pill when absent, collapse search to a 32pt icon, remove the shortcut hints from the collapsed state. Acceptance: at 900 all five places and all three controls are fully visible with ≥8pt between groups; no word is painted under another control.
2. **Make bubbles fit their text and lose the second line.** The bubble container is always 560pt wide; at 900 it is ~508pt, effectively the full column. Let the text determine width up to 560, put the timestamp inline at the end of the last line (or overlay it at bottom-trailing with reserved trailing padding), and keep the sender name only on the first bubble of a run. Acceptance: “true” is a ~100–140pt bubble, not 560pt; a one-line message is ~32–36pt tall, not 63pt.
3. **Add find in the conversation and make ⌘F real.** A 220pt find bar that slides under the chat header, placeholder “Find in College Gang 2016”, count “3 of 17”, ⌘G/⇧⌘G next/previous, Esc closes, Return next. The global field becomes “Search all chats” with ⇧⌘F. ⌘F with no chat open focuses the global field. Delete the global “Only <chat>” checkbox once the local field exists.
4. **Remove Ask as a chat mode; make one scope-aware Ask panel.** Chat header becomes Messages · Media · Heartbeat (272→204pt, which fixes the 900 title truncation). The pill and ⌘K open the same panel. When opened inside a chat, show a removable scope chip “In College Gang 2016 ×” and placeholder “Ask about College Gang 2016…”; elsewhere “All chats” and “Ask your archive…”. Add “Ask this chat…” (⌘⇧K) to the chat’s More menu as a second entry to the same panel, not a second surface. Move “Also match meaning” and “Build index” below the question field, under a “Search settings” disclosure. Degrade to Search with one line when no model exists, as DESIGN.md promises.
5. **Rework Might need your reply.** Default window **90 days** (choices 30/90/365, never all time); quiet threshold 3 days in a small menu, not a Stepper; newest question first, grouped “This week / This month / Earlier”. Row: name + “asked 9 days ago” on line 1, the question on line 2 in primary text, trailing “Show in chat” (jumps to the message) and “Dismiss” (local handled state). Add a Home card “3 might need a reply” when count > 0 and a “Waiting on you” filter in Chats. Remove “newest first” from the subtitle; keep the rule note and the two caveats.
6. **Give People a home in Chats, not the Go menu.** Add a two-segment switch at the top of the Chats sidebar, above All/Direct/Groups: **Chats | People**. Go > People (⌘2) selects the People segment. The top bar then never lies about where you are. Reduce the People detail to one primary “Open conversation”, with Merge and Heartbeat in a secondary menu.
7. **Finish Settings and delete the Go duplication.** Keep four panes, rename them for tasks: **Archive** (folder, backups, sources, media, media health); **People & cleanup** (Contacts: Merge, Chats without a name; Cleanup: Clean up spam, active rules, Hidden chats); **Home** (On this day, Home cards, “Waiting on you” visibility); **Privacy & AI** (encryption, what leaves, AI model, semantic index, MCP/other apps). Route ⌘, to the place and delete the duplicate Settings scene. Remove from Go every tool that now has a home; Go should only mirror places, or be deleted. Put live counts on the four housekeeping rows. Fix the monospace prose.
8. **Make Clean up spam safe and make the sheets share the app’s language.** No preselection (`Hide 0 chats` until rows are ticked); define “repeats” in one line (“forwards and messages sent more than three times”); let a row expand to show three examples; one fixed footer with the primary action on the left and Close on the right; teal checkboxes and buttons, not system blue. Merge: destructive role + confirmation for Unmerge, and let the sheet height follow content instead of 680pt of empty. Unify sheet headers.
9. **Fix contrast and accent hygiene.** Ask fill solid and readable; `textTertiary` to #8696A0; outgoing timestamps to ≥4.5:1; one teal button style for primary actions. Acceptance: no informational text below 4.5:1, and no primary button is system blue.
10. **Do a vocabulary and copy-accuracy pass.** Heartbeat everywhere for a chat/person story; Wrapped only for the year; delete “Group Wrapped: …” and the third chat-name repeat; in-chat Media captions show date (and sender for groups), not the chat name; say “You” for the owner; change “Tap” to “Click”; and fix the partial-year Wrapped claim (“304 of the 304 days in this archive” / “a message in all 10 months”) before shipping any Wrapped copy.

Also, below the top ten: Gallery cards at 200–240pt (6 columns) or two-line captions; Gallery kind tabs get a horizontal scroll at ≤1100; On This Day clamps its date range; clean up the duplicated “311 items”; and make the green dots in the chat list mean something or remove them.

---

## The owner’s five complaints, one by one

### 1. “Might need your reply” — all time, oldest first

**Status:** the ordering/window bug is **not in the current source**. `ReplyResponsibility.defaultWindowMonths = 6` (`Sources/SagaCore/ReplyResponsibility.swift:99`), the choices are 1/3/6/12/24 months (`:103`), and `candidates` sorts by `questionDate` descending, tie-broken by UID (`:134-137`). The sheet says “newest first” in the subtitle and in the rule note. If the owner is still seeing 2017 first, they are almost certainly running a stale `build/Saga.app`; rebuild the bundle, not just the product.

**Why it still feels clunky:**

- The entry point is buried in Go and Settings; it is not on Home or in Chats.
- The row says “31 Oct 2026 · quiet for 8 days”, which is the same fact twice; the question is the smallest line on the card.
- “Open chat” actually jumps to the message and closes the sheet; the label sets the wrong expectation.
- There is no “handled” state, so the list never reflects what the owner has done on the phone.
- With one row, the 600pt sheet is mostly empty and the list has no grouping or count.

**Proposal:**

- **Window:** default **last 90 days**; menu of **30 days / 90 days / 1 year**; never “all time”. If older questions exist, show one line “12 older questions outside this window” and a “Show older” disclosure, so the cutoff is explicit rather than silent.
- **Order:** newest question first, grouped under **“This week”**, **“This month”**, **“Earlier”**. No oldest-first.
- **Row:** **Priya Menon** · *asked 9 days ago* on line one; the question as the primary 13pt line, quoted; trailing **“Show in chat”** (jumps to and highlights the message) and **“Dismiss”** (local handled state, undoable). Drop the absolute date from the row; show it on hover or in the detail. The words “quiet for 8 days” can become “no reply since 31 Oct” if the date is useful, but not both.
- **Placement:** a Home tile/card “3 might need a reply” shown only when the count is above zero; a “Waiting on you” filter in Chats; keep the sheet itself reachable from both. Remove it from Go.
- **Copy:** keep “Might need your reply” (it is the owner’s phrase and it is honest), but add the count and window: “3 questions · last 90 days”. Keep the two caveats verbatim.

### 2. Chat window clunkiness and no find

**Status:** open. There is no find field in the conversation; the only field is the global one. `⌘F` is printed on that field but unbound. The per-chat capability exists only as an “Only <chat>” checkbox on the **results** page after a global search (`MainViews.swift:548-550`).

**Proposal:**

- **Placement:** a find bar that slides down **directly under the conversation header**, full content width, 44pt tall, with a magnifier, the field and a close button. This is Safari’s model and it does not add a third chrome row permanently. The chat header already has an ellipsis at the trailing edge; put the find toggle to its left (magnifier icon), so the header reads title · find · more.
- **Shortcut:** **⌘F** with a chat open opens/focuses the find bar. **⌘G / ⇧⌘G** next/previous; **Return / ⇧Return** also next/previous; **Esc** closes and restores the previous scroll position. When no chat is open, ⌘F focuses the global field.
- **Scope and count:** placeholder **“Find in College Gang 2016”**; count **“3 of 17”** across the whole chat, not only the loaded 200 messages; selecting a match jumps to the message and uses the existing gold highlight ring. The field is a find, not a list filter: it should not hide the rest of the conversation.
- **Global search:** relabel the top pill **“Search all chats”** and change its hint to **⌘⇧F**; keep the full-screen grouped results. The “Only <chat>” checkbox can disappear once the local find exists, because the scope is now selected by where you are.
- **Header:** removing Ask (see #3) gives the title back 68pt, so “College Gang 2016” and “900 messages · since Nov 2023” fit at 900.

### 3. Global Ask vs per-chat Ask

**Status:** open by design. `ChatMode` includes `.ai = "Ask"` (`SagaApp.swift:79-85`); the inline panel has its own `Catch me up / Ask` segmented control (`AIViews.swift:407-411`). The global pill and the chat tab are two doors with the same name, different chrome and a hidden scope: `openAsk` preserves `thisChatOnly` from the previous chat if a chat is selected (`AIViews.swift:163-166`).

**Proposal: one surface, two labelled scopes — not two products.**

- **Keep one entry point and one panel:** the top-bar **Ask** pill (⌘K) opens the right-hand inspector. Delete the fourth chat mode; the chat header becomes **Messages · Media · Heartbeat** (204pt, which also fixes the 900 truncation).
- **Make scope explicit at the top of the panel:** a chip under the question field: **“All chats ▾”** or **“In College Gang 2016 ×”**. Opening Ask from inside a chat preselects that chat and the placeholder reads **“Ask about College Gang 2016…”**; opening it from Home/Gallery/Insights reads **“Ask your archive…”**. The chip is always visible; there is no hidden `thisChatOnly` state.
- **Add a second labelled entry, same panel:** **“Ask this chat…”** in the conversation’s More menu, shortcut **⌘⇧K**, opens the same inspector with the scope chip preset. If the product wants a visible header affordance, a small sparkle+magnifier button next to find is enough; do not add a fourth mode.
- **Wording:** “Ask” for the global instrument, “Ask this chat” for the scoped action. Do not label both “Ask”. If the team insists on two distinct surfaces, then they must be named **“Ask everything”** and **“Ask this chat”** and must share the same result renderer; two same-named tools is the current confusion.
- **Panel order:** question field → scope chip → Ask button → model picker → results. Put “Also match meaning” and “Build index” under a **Search settings** disclosure below the field; they are setup, not the first thing a person sees. When no model is available, degrade to Search and say “No local model — showing keyword search” instead of disabling Ask, as DESIGN.md line 88 promises.

### 4. Merge, spam and the Go menu

**Status:** **the current build already puts them in Settings.** `PeopleSettingsPane` has Merge contacts, Chats without a name, Clean up spam and Might need your reply (`SettingsView.swift:217-248`). The screenshot `settings-people.png` shows the tab. The owner’s complaint is still valid in two ways: the items are **also** in Go, and the tab is named “People & chats” rather than “People & cleanup”, so the tools are not where a person looks first.

**Exact grouping:**

| Setting pane | Contains |
|---|---|
| **Archive** | Archive folder (Change…), Backups (Add old backups, Back the phone up again, Import from iPhone), Sources, Media folders, Media health (Found/Missing) |
| **People & cleanup** | **Contacts:** Merge contacts…, Chats without a name…, merge history (“Your merges”) · **Cleanup:** Clean up spam…, active cleanup rules with Restore, Hidden chats |
| **Home** | Show “On this day” on Home, Open today’s page…, Home card visibility (including “Waiting on you”), default start place |
| **Privacy & AI** | Protection/encryption, What leaves this Mac, AI model + semantic index, Other apps (MCP / Claude Code) |

- **Remove from Go:** Merge contacts, Clean up spam, Might need your reply, Chats without a name, On this day, Show/hide On this day, Ask, Music & video, Copy Claude Code. Those all have a visible home: Settings, the Home card, the Ask pill, and the Gallery Music tab.
- **Keep Go only for places, or delete it.** If kept, it should be: Home ⌘0, Chats ⌘1, People ⌘2, Gallery ⌘3, Insights ⌘4, Settings ⌘5, with the same place names. “Overview” and “Wrapped” are not place names; they should go.
- **Name the place.** “People & chats” reads like a section, not a task. “People & cleanup” says what it holds. The four housekeeping rows should carry live counts: “3 suggestions”, “12 unnamed”, “4 cleanup rules”, “1 question waiting”.
- **Remove the duplicate Settings scene** (`SagaApp.swift:63`); ⌘, should navigate the place, not open a second window.

Every current Go item and its new home:

| Go item | New home |
|---|---|
| Chats ⌘1 | Top bar **Chats** (place) |
| People ⌘2 | **Chats / People** switch in the sidebar |
| Wrapped ⌘3 | Top bar **Insights** → Wrapped |
| Might need your reply… | Home card “Waiting on you” + Chats filter |
| Chats without a name… | Settings → People & cleanup → Contacts |
| On this day… | Home “On this day” card |
| Show/hide “On this day” on Home | Settings → Home |
| Overview ⌘0 | Top bar **Home** |
| Ask your archive… ⌘K | Top bar **Ask** pill |
| Music & video from every chat… | Gallery → Music tab |
| Merge contacts… | Settings → People & cleanup → Contacts |
| Clean up spam… | Settings → People & cleanup → Cleanup |
| Copy Claude Code connect command | Settings → Privacy & AI → Other apps |

After that table, the Go menu has no unique item. Delete it, or leave it as a redundant place switcher with correct names; either is consistent.

### 5. Overall audit

The ten fixes above are the answer. The pattern is: the app has a strong visual language and a good archive model, but its chrome and reading surface were tuned for a 1240pt window and a chat that is read like a feed. At 900 the chrome breaks; at any width the bubbles are too wide and too tall; the navigation has a hidden People section; and the tools have two homes (Settings and Go). Fix the geometry and the vocabulary, and the existing design will feel intentional again.

---

## Where I disagree with the second opinion

The Opus critique below is kept verbatim. I checked its claims against the captures and source; these are the places I do not follow it.

- **“The Ask panel is a rendering failure — pure black, top bar and header gone.”** The full 1440 capture still has the top bar and chat header; only the inspector’s AppKit material and composer are missing. `docs/WORKER-BRIEF.md:51` says the inspector material never captures and views with no background come back transparent. This is a capture limitation, not proof that the shipped panel is black. The real Ask problem is the duplicate entry point and hidden scope, which is code-verified.
- **“Gallery with 8 columns is fine; leave it.”** The column count is fine for photos, but the 10.5pt caption is not: most names are ellipsized (three in the first row alone), and at 900 the Gallery kind tabs have no scroll view (unlike the in-chat Media header). Widening to 200–240 or using two caption lines is the fix, not fewer columns for their own sake.
- **“A 6-item Media grid leaving the bottom half empty is honest.”** Agreed; I do not count it as a defect. The redundant chat-name caption is the defect.
- **“Refresh does nothing useful on static data.”** It rescans the archive and is the correct recovery after a library rebuild; it is only redundant because the sheet also scans on appearance. Keep it as a secondary action, not the primary.
- **“On This Day picks its date with a numeric field and stepper.”** It is a compact `DatePicker`, not a numeric field; the real issues are the unclamped future date and the crowded control row.
- **“Ask and Update from phone are equally prominent.”** No: the Ask fill is 1.68:1 and looks disabled. Opus’s later section agrees it is too weak; the first claim overstates competition.
- **“Every row has a green dot”** is a demo-data artifact (all chats end on 31 Oct) but the underlying `isFresh` rule still paints a large block in a real archive; the semantic objection stands.
- **“People is not a place; it is a section inside Chats.”** Correct, and that is exactly why the fix is a Chats | People switch, not a sixth top-bar chip.

---

## Second opinion (Opus, verbatim)

The prompt included the 22 captures, the five complaints, my preliminary findings, and the DESIGN.md rules. Opus saw the images; its output is unchanged.

```text
# Saga design critique (second opinion)

I looked at all 22 screenshots.

## 1. Where I agree, disagree, and what you missed

**I agree with these, and some are worse than you said:**
- **Top bar at 900px.** Worse than overlap. "Disconnected" is printed on top of "Insights" and "Settings", and the search icon sits inside the place capsule. It's unreadable, and it happens on every place.
- **⌘F does nothing, and there's no find inside a chat.** Confirmed.
- **"Wrapped" used for per-chat and per-person stories.** Confirmed. Heartbeat shows the chat name three times and calls itself "Group Wrapped".
- **People has no home.** Confirmed. It's reachable only from Go or the Home tile.
- **Clean up spam selects all 10 groups for you.** Agree, and it's the most dangerous screen in the app.

**I think these are wrong or overstated:**
- **"Ask and Update from phone are equally prominent."** No. The Ask pill is pale sage with pale teal text and looks *disabled* in every capture. In Gallery it nearly disappears. The problem is that it's too weak, not that it competes.
- **Ask capture: "the input isn't visible at the top."** That understates it. The panel is a rendering failure, not a layout-order issue: a pure-black inspector, unstyled controls, and a blank white pill (presumably "Build index", white text on white). Also, the top bar and the conversation header are gone from the window. Treat it as broken.
- **Gallery with 8 columns and truncated captions.** Fine for a photo grid. Leave it.
- **A 6-item Media grid leaving the bottom half empty.** That's just honest. Not a defect.
- **"Found 408 of 408" looks editable.** Minor. The real issue is that this Settings page is six launchers and paths in monospace.
- **The real Google Drive path in demo mode.** It's a data leak in the demo, not a design issue. Fix it, but rank it low.

**What you missed:**
- **Message bubbles don't size to their text.** In `chat-messages-1440`, the one-word message "true" sits in a bubble about 390pt wide, the same width as every other bubble. This is the single biggest readability and density defect in the core screen.
- **Every row in the Chats sidebar has a green dot.** In an archive, the dot means nothing, but it reads as "unread" or "online". All the group avatars are also the same outline icon.
- **System events look like messages from a person.** "Security code with Priya Menon changed. Tap to learn more." is drawn as an incoming bubble, and "Tap" is the wrong word on a Mac.
- **Heartbeat says "Suraj writes the most" and lists "Suraj" first.** That's the owner, so it should say "You". On this day shows "You" with an "M" avatar.
- **The cleanup sheets drop the app's look.** Clean up spam uses system-blue checkboxes and a system-blue button. Merge uses light system text fields. Clean up spam also has two footers: the primary button sits inline after the list, and Close sits bottom-right.
- **"Home" is both a place and a Settings tab.** The Settings tab holds a single toggle.
- **Settings descriptions are in monospace.** "Numbers that are one person, with the evidence" is ordinary text set like code.
- **Insights copy doesn't make sense.** "The other 61, you were missed." and "304 days in a row was the best run. 212 of them were sent between midnight and 5 am." Days aren't sent.
- **On this day picks its date with a numeric field and stepper** ("28/11/2026"), the clunkiest control in the app.
- **The reply sheet says "newest first" twice:** once in the subtitle, once in the info banner. The "Local only" badge repeats the footer. The Refresh button does nothing useful on static data.
- **"Copy Claude Code connect command" sits under Privacy.** It's an integration, not a privacy setting.

## 2. Top ten fixes, in impact order

1. **Fix the top bar.** Move Settings out of the place capsule to a gear icon on the right, next to Ask. Below about 1100pt, collapse the places to icon + label-on-hover, and shrink the search pill to an icon button. Remove "Disconnected". Show phone status only inside the Update from phone flow, as "Phone not connected".
2. **Make bubbles fit their text.** Maximum width 62% of the reading column, capped near 560pt. Group by sender, and show the sender name only on the first bubble of a run.
3. **Add find inside a chat** (details in §3, complaint 2).
4. **One Ask, not two.** Remove Ask from the conversation's mode control, leaving Messages · Media · Heartbeat. ⌘K opens a right-hand Ask panel styled like the rest of the app, with the question field pinned at the top and a removable scope chip under it. Fix the panel's rendering.
5. **Rework "Might need your reply"** (details in §3, complaint 1).
6. **Restructure Settings, and give People a home in Chats** (details in §3, complaint 4).
7. **Make Clean up spam safe.**
   - Nothing selected by default.
   - Each row expands to show three sample "repeats" so the user can see what will be hidden.
   - Use the app's teal checkboxes.
   - One fixed footer: "Hide 0 groups' repeats" (disabled) on the left of Close.
   - Define "repeats" in the header: "Forwards and messages sent more than three times."
8. **Fix contrast.** Ask pill: solid accent fill with dark text. Raise `textTertiary` to at least 4.5:1, and outgoing timestamps to at least 0.75 opacity.
9. **Clean up the Chats sidebar and the message stream.**
   - Remove the green dots.
   - Give each group a colour from its name and its first letter, instead of the shared outline icon.
   - Show system events as centred captions in the date-pill style, with "Tap" changed to "Click".
   - Say "You" wherever the owner appears.
10. **Remove repeats.**
    - Heartbeat: drop the "Group Wrapped: …" sub-header and change the eyebrow to "HEARTBEAT", with the chat name shown once, in the hero.
    - In-chat Media: drop the chat name from each card and show the date only, as "Aug 2026".
    - People detail: rename "Wrapped for you two" to "Heartbeat".

## 3. The owner's five complaints

**1. Might need your reply.**
- **Window:** default to the last 90 days. Offer 30 days, 90 days and 1 year, and never "all time".
- **Quiet threshold:** fix it at 2 days and remove the stepper.
- **Order:** newest question first, grouped under "This week" and "Earlier".
- **Placement:** a Home tile, "3 might need a reply", shown only when the count is above zero. Also a "Waiting on you" filter in the Chats sidebar.
- **Each row:** **Priya Menon** · *asked 9 days ago (31 Oct)*, then the quoted question on the next line. On the right: "Show in chat", which jumps to that message and highlights it, and "Dismiss", which marks it handled on this Mac.
- **Empty state:** "Nothing waiting from the last 90 days."

**2. Find in chat.**
- With a chat open, ⌘F slides a find bar down under the conversation header, Safari-style. Placeholder: "Find in College Gang 2016".
- It shows "3 of 17", with ⌘G and ⇧⌘G for next and previous, and Esc closes it.
- At the right end, a link: "Search all chats ⇧⌘F".
- The top pill always means all chats: label it "Search all chats" and show ⇧⌘F.

**3. Ask.** One entry point that takes its scope from where you are. The pill and ⌘K open the same panel. Inside a chat, the scope chip reads "In College Gang 2016 ✕" and the placeholder reads "Ask about College Gang 2016…". Anywhere else, the chip reads "All chats". Two entry points only make sense when they do different things, and here they don't.

**4. Settings.** Use four tabs:
- **Archive:** folder, backups, media folders, Update from phone.
- **People:** Merge contacts, Name unknown chats.
- **Cleanup:** spam suggestions plus the active hide rules listed inline, each with "Remove rule".
- **Privacy & AI:** encryption, what leaves the Mac, connected apps.

Move the On this day toggle to a "Hide from Home" item on the card's context menu, mirrored as a row under Archive. "Might need your reply", "Music & video" and "On this day" are things to look at, not settings, so take them out of Settings: they go to Home, the Gallery Music tab, and Home respectively.

People becomes a two-way switch at the top of the Chats sidebar, "Chats | People", above the All / Direct / Groups filter. After that, Go only *repeats* what's elsewhere.

**5. Overall audit.** The problems above come in three groups: layout at narrow widths, how the core reading screen looks, and where things are placed. The visual language itself is fine.

## 4. Where DESIGN.md causes the problem

- **"Ask is a content mode."** Change the rule. Modes should be different views of the same thing, and Messages, Media and Heartbeat are. Ask is a tool that works across everything and takes its scope from where you are. New rule: *tools (Find, Ask) take the open thing as their scope and never become a mode.*
- **"Five places in the top bar, Settings among them."** Change the rule. This is what causes the 900px collision, and it leaves People with no home. Make it four places (Home, Chats, Gallery, Insights), with Settings behind a gear and ⌘,. People becomes a list inside Chats.
- **"Settings is a full-screen place."** Change it, or at least cap it. A full window for four short tabs gives you launcher pages that are 70% empty. Make it a standard Settings window, or a centred 640pt panel.
- **The Wrapped/Heartbeat vocabulary and ⌘F vs ⌘K.** These rules are right; the implementation breaks them. Add one line to the doc: *⌘F is find in the current context; ⇧⌘F searches everything.*
- **Glass panels.** The doc needs a rule for sheets and inspectors. Today they fall back to the stock macOS controls, which is where the blue checkboxes, light text fields and black Ask panel come from.
```

---

## Appendix — evidence, captures, and limits

**Captures (2× PNG unless noted; dark theme).**

| Surface | 1440×900 | 900×700 |
|---|---|---|
| Home | `1440-home/1-dashboard.png` | `900-home/1-dashboard.png` |
| Chats list | `1440-chats/1-dashboard.png` | `900-chats/1-dashboard.png` |
| Conversation, Messages | `1440-chats/2-chat.png` | `900-chats/2-chat.png` |
| Conversation, Media | `1440-media/2-chat.png` | `900-media/2-chat.png` |
| Conversation, Heartbeat | `1440-heartbeat/2-chat.png` | `900-heartbeat/2-chat.png` |
| Gallery | `1440-gallery/1-dashboard.png` | `900-gallery/1-dashboard.png` |
| Insights / Wrapped | `1440-insights/1-dashboard.png` | `900-insights/1-dashboard.png` |
| Settings, Archive | `1440-settings/1-dashboard.png` | `900-settings/1-dashboard.png` |
| Settings, People & chats / Home / Privacy | `settings-people.png`, `settings-home.png`, `settings-privacy.png` (live 1268×1030; panes capped at 760) | same, content width unchanged |
| Reply sheet | `1440-ai/18-reply.png` | hosted at 780×640 |
| Ask inspector | `1440-ai/16-ask.png` | `900-ai/16-ask.png` (composer not rasterised) |
| Merge contacts | `merge.png` (620×680) | same |
| Clean up spam | `prune.png` (640×640) | same |
| On this day | `1440-otd/6-onthisday.png` | `900-otd/6-onthisday.png` |
| Chats without a name | `1440-unnamed/4-unnamed.png` | same |

All paths are under `~/saga-audit-shots2/` except the two sheet captures (`merge.png`, `prune.png`) and the three live Settings captures (`settings-people.png`, `settings-home.png`, `settings-privacy.png`), which were under `/tmp/` and are also listed above. Nothing in `docs/screenshots/audit/` was modified.

**Reproduce:**

```sh
saga demo --out ~/saga-assets/audit-demo-1 --photos fixtures/demo-photos
sh scripts/make_app.sh
APP=build/Saga.app/Contents/MacOS/Saga
$APP --snapshot /tmp/shots/1440-chats --demo ~/saga-assets/audit-demo-1 --dark --place chats --width 1440 --height 900
$APP --snapshot /tmp/shots/1440-media --demo ~/saga-assets/audit-demo-1 --dark --chat-mode media --width 1440 --height 900
$APP --snapshot /tmp/shots/1440-heartbeat --demo ~/saga-assets/audit-demo-1 --dark --chat-mode Heartbeat --width 1440 --height 900
$APP --snapshot /tmp/shots/1440-ask --demo ~/saga-assets/audit-demo-1 --dark --ai --width 1440 --height 900
$APP --snapshot /tmp/shots/1440-otd --demo ~/saga-assets/audit-demo-1 --dark --otd-date 11-28 --width 1440 --height 900
```

**Limits.**

- The snapshot harness does not rasterise AppKit-backed controls or the inspector material (`docs/WORKER-BRIEF.md:51`). The Ask composer and some segmented controls are absent from captures although present in code. This audit judges Ask on code and placement, not on missing pixels.
- `--snapshot` only opens the Settings **Archive** tab. People & chats, Home and Privacy were captured live at 1268×1030; the pane is width-capped at 760, so the reading measure is the same.
- The demo has **zero** unnamed chats and **zero** merge suggestions. Those two sheets were judged on structure and empty states, not populated rows.
- No VoiceOver session was run. Focus/accessibility notes are code-level only.
- The demo fixture ends 31 Oct 2026. Dates in Wrapped and On This Day reflect that fixed date; they are not evidence of a clock bug.
- The real Google Drive path visible in the Settings capture is deliberately not reproduced in this document. It is a demo isolation bug, not a design feature.
