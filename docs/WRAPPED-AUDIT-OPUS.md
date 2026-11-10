# Wrapped / Heartbeat quality audit (Claude Opus)

An independent, read-only audit of what the Wrapped generator actually writes. No source was changed for this audit.

## How it was judged

- **Fixture:** a fresh `saga demo --out …` (fixture v2: 20,600 messages, 4 one-to-one chats, 10 groups, 2023-11-01 to 2026-10-31).
- **Dump:** a throwaway SwiftPM package outside the repo that links `SagaCore` and builds the stories with `YearWrappedBuilder`, `DuoWrappedBuilder` and `GroupWrappedBuilder`. It puts the strings together exactly as `WrappedView.swift` and `WrappedStory.swift` do, so the lines quoted below are what the screen shows. Titles were off, which is the app's default (`@AppStorage("wrappedTitles") = false`).
- **Stories read:** the year Wrapped for 2023–2026; Heartbeats for Aravind, Meera, Nikhil and Priya; group stories for Flat 4B, Sunday Football XI, Terrace Gardeners, Wedding Prep and Book Club.
- **Edge cases:** four fixtures cut down from the demo: a 2-message DM, a DM covering one month only, a group covering one month only, and a year holding one chat with 42 messages. I also ran one Heartbeat with `me = "Suraj"`, which is what the app passes by default (`NSFullUserName()`'s first name).
- **Real archive:** two aggregate SQL counts against the real `vault_index.db` to measure two bugs at scale. Only counts were read, never message text or names.

**What the fixture hides.** Every demo chat spans the same 36 months with the same yearly curve, and laugh replies are attached to random lines. That means the demo cannot show whether the stories differ in *shape* or whether the chosen moment is actually funny. The selection rules can still be judged, and they are judged below.

---

## The five weakest passages (verbatim → rewrite)

### 1. Year Wrapped, "Who you talked to": two false facts in one subtitle

> **Before (2023):** "Sandeep Kulkarni got the most of your attention: 123 messages. 22 people wrote to you in all. The loudest room was Sunday Football XI — 551 messages, ahead of 1,514 other groups."

- **"1,514 other groups" is a bug.** `groupCount` is `sum(c.is_group)` over the *message* join (`YearWrappedBuilder.build`, the `count(DISTINCT m.chat_id), COALESCE(sum(c.is_group),0)` query), so it counts messages sent in groups. The demo has 10 groups. On the real archive the same query gives 45,489 for 2024 against 160 actual groups, so the owner's 2024 story would say "ahead of 45,488 other groups". The only test feeds `yearRoom(groups: 10)` by hand and never checks what the builder produces.
- **"Got the most of your attention" is upside down.** It ranks people by messages *they* sent, mostly in groups. Sandeep is the loudest member of the football group. The person you actually talked to that year is Meera: 170 messages, 85 of them yours.
- **"Wrote to you"** counts everyone who posted in any group you are in.

> **After:** "Meera Nair was the one you actually talked to: 170 messages between you, half of them yours. The loudest room was Sunday Football XI — 551 messages, ahead of 9 other groups, and you sent 91 of them."

### 2. Year Wrapped, "What made you laugh": the moment is one word, and you are not in it

> **Before (2025):** "211 replies came back as a laugh out loud. The biggest one: Nikhil Rao in Flat 4B, 10 October."
> Bubble: **Nikhil Rao:** "in" → **Ritu Sharma:** "😂😂😂😂"

The card is titled *What made you laugh* and shows two other people laughing at the word "in". Here is how the selection works:

- Every laugh reply is scored.
- The score caps at 4, so nearly everything ties.
- Ties go to the most *recent* reply.
- Nothing is required of the message being laughed at: no minimum length, no requirement that you sent it or laughed at it, and the year builder has no URL or laugh-text filter.

2026 makes the same mistake with "can we do monday instead" → "hahahaha 😂". The headline count is also capped. The query reads the newest 6,000 quoted replies *before* scoring, and the real archive has 12,478–15,610 quoted replies in its busiest years, so "N replies came back as a laugh" quietly undercounts by half or more.

> **After (illustrative; the demo's laughs are random):** "You made people laugh 58 times this year, Meera most of all. The line that got the biggest reaction, three people laughing within ten minutes: 'i finally fixed the tap myself after watching two videos and breaking one spanner.'"

The rule behind the rewrite:

- The target needs at least 3 content words and no link, and must not itself be a laugh.
- Rank by distinct laughers, then by reply depth.
- The year card prefers exchanges you are part of.

### 3. Heartbeat and group, "Words that only mean something here": n-gram fragments sold as inside jokes

> **Before (Aravind):** "8 phrases live only in this chat. “i've started walking” leads, 6 times." Tags: *i've started walking, owe you money, new biryani, always start without, biryani place near, next month, closed by next, confirmed for sunday*
>
> **Before (Wedding Prep):** *tent guy, column is everyone's, i'm sitting down, everyone's favourite, it's the lighting, saw it i'm, says it's, tailor says*

This is the headline "voice" feature, and most of its output is fragments:

- Overlapping n-grams of the same phrase each take a slot: "new biryani" and "biryani place near"; "column is everyone's" and "everyone's favourite"; Meera's "discussing the blue" next to "not discussing".
- Function-word shards get through: "saw it i'm", "says it's", "next month", "we're out".
- Nikhil gets "album from track" and "three nikhil".

Meera's list is good ("blue kettle" 34, "leaf conspiracy", "sambar index"), which shows the scorer works when the signal is strong and fills up with junk when it is not. It always fills 8 slots.

> **After (Aravind):** "Nothing here quite counts as an inside joke, but 'the new biryani place' came up on 4 different days."
> **After (Meera):** "'Blue kettle' — 34 times. Then 'leaf conspiracy' (16) and 'sambar index' (15)."

How to get there:

- Merge overlapping n-grams.
- Require at least 3 distinct days, and both people (DM) or at least 2 speakers (group).
- Show 3, not 8.
- Say so honestly, or hide the card, when nothing survives.

### 4. Emoji card: "your signature pair" is someone else's, or the same emoji twice

> **Before (Aravind Heartbeat):** "🏏😤 is your signature pair — 27 times, side by side." The columns underneath: *You* 😂25 💀8 🤣6, *Aravind* 🏏52 😤51.
>
> **Before (4 of the 5 groups read):** "😂😂 is your signature pair — 58 times, side by side." (Flat 4B; Sunday Football reads "136 times", Wedding Prep "27".) The cover glyph is a 78 pt 😂😂.

- In all four Heartbeats the "pair" is the other person's habit, and you used neither emoji.
- In four of five groups the "pair" is one emoji typed twice.
- Groups still get "your".
- `DuoWrappedTests` (lines 221–223) asserts `emojiPair == ("😂","😂")`, so the doubled-emoji pair is pinned as intended behaviour.

> **After (Aravind):** "🏏😤 is Aravind's: 52 cricket bats and 51 huffs. You answer with 😂."
> **After (Flat 4B):** "The flat runs on 😂, 190 of them. 💃 is a distant second with 97."

### 5. "How it started": the same kicker under every first message

> **Before (all four Heartbeats):** "It didn't need to be clever."
> …under "ok new chat, the old one had four hundred messages about a kettle", "dei are you awake, i need yesterday's score", "this is my new number, save it and delete the old one" and "did you finish the book or did the cat sit on it".

`firstKicker` only reacts to greetings, a question mark, an emoji, length or word count. Any ordinary sentence falls through to the same fallback. The first message is the most personal line in the story, and the one sentence written about it is the same for every chat. Meanwhile the data for a real callback is right there: Meera's opener is about a kettle, and "blue kettle" is the chat's top phrase.

> **After (Meera):** "It started with a kettle. 'Blue kettle' came up 34 more times."
> **After (Nikhil):** "A new number on day one, and 800 messages on it since."
> **After (fallback, no callback found):** no kicker at all.

---

## What else the copy gets wrong

### Facts

- **Mixed person.** With the app's real default (`me = "Suraj"`), one story uses both persons:
  - second person: "You two sent 2,200 messages", "You answer in 37 min";
  - third person: "Suraj's messages drew 72 laughs from Meera Nair", "Suraj 13, Meera Nair 26", "Suraj broke it".

  `possessive`/`verb` only treat the literal word "you" as the user.
- **Reply time is capped at 6 hours, and sparse chats get a false claim.** Any gap of 6 hours or more is counted as a conversation start in an `if/else if`, so it is never also a reply. The "typical reply" median therefore never sees a 6–24 h answer. On the one-month fixture it prints "You usually reply in 2 min. Aravind Pillai takes a day or more", although Aravind replied the same day all month.
- **"You turned up on 304 days" counts days *anyone* wrote**, not days you did. "The other 324, you were missed" (the one-chat year) is therefore false as well as cloying.
- **"Nothing else came close" is never checked.** The 2023 longest message is 77 characters and the runner-up is 76. 2024's longest message is the same fixture sentence (76 characters), which is also the longest message in Nikhil's and Priya's Heartbeats.
- **Off-by-one spans.** Duo and group `spanDays` leave out the +1. A 1,096-day chat reads "1,095 days", and a chat with messages on two consecutive days would read "All of it on 2 November".
- **Rates and plurals:**
  - `pace` divides by *active* days but says "a day": 2 messages gives "In 2023 alone that was 1 a day."
  - "Peak month: November 2023, 1 laughs."
  - "You traded 1 songs and videos — You 1, Priya Menon 0." (one song, sent by one person, is not traded)
  - "1 phrases live only in this chat", "1 were the same link", "1 links landed", "Tara Bhat drew 1 laughs", "you also kept 1 videos", "1 days in a row at best", "1 messages on your busiest day".
- **Laughs attributed to the wrong person.** "IT LANDED | … Meera Nair sent it … | ↳ Meera Nair: on repeat since morning": the reaction comes from a later share of the same link, so the card shows the sender reacting to her own song.
- **The group "funniest" is just the loudest.** The ranking uses raw laugh counts, so "Sandeep Kulkarni writes the most — 1,082 messages, and gets the laughs too (136)" only means he posts the most. Per message he is roughly level with you (12.6% against 11.6%).

### Picking the moments

- **Group laugh moments accept laughs as the punchline.** Duo skips targets that are themselves laughs; group does not. Examples:
  - "Nikhil Rao: hahaha shut up 😂 ↳ Ritu Sharma: rofl"
  - "Divya Iyer: hahahahahaha ↳ Rachel Thomas: hahahaha"
  - "Ritu Sharma: one min"
  - "You: ya same"

  Book Club shows two moments on the same day with the same reply.
- **The duo funniest moments** include "You: kind of", "You: theek hai", "You: is it confirmed" and a bare Spotify URL ("You: old favourite https://open.spotify.com/track/…").
- **The night message picks the latest clock time, not the best line.** "Aravind Pillai at 4:53 am … : cool"; "fine fine".
- **No floor on trivia:**
  - "The loudest day was 7 January, with 1."
  - "2 messages on your busiest day"
  - "ON REPEAT … 2 times in all"
  - a music card for 1 link
  - "the longest thing anyone typed" at 72 characters
  - "March 2025 was the loudest month: 33 messages, 100% of the whole thing"
- **The year story never looks at the year.** 2025 has 5.3× the messages of 2024 (9,731 against 1,853), the biggest fact in the archive, and no card mentions it. There is also nothing on:
  - who was new that year;
  - who faded;
  - the first or last message of the year;
  - a chat that started or ended.

  Every year reads "Most of it landed around 9 pm", "N days in a row was the best run" right after "turned up on all N days", and ends "not one of them left this Mac".

### Voice and endings

- **Closings ignore whether the chat is alive.** "2 messages and still going." is printed for a chat whose last message was in November 2023.
- **The year's last line is a privacy claim.** Each year closes on the product's privacy line instead of anything about that year.
- **Untitled track cards.** With titles off (the default), 5 of the 6 year track cards read "Spotify track" or "YouTube video" with a role badge. The soundtrack card is mostly placeholder text.
- **The only voice is in the empty states.** "Very serious correspondence", "just a serious crowd" and "you were missed" read as voice. Everything with data in it is a frame with numbers slotted in.

## Do two chats tell different stories?

Not yet.

**The frame count.** I stripped names, numbers, months, quoted phrases and emoji from the generated sentences. Each Heartbeat has about 13 sentences, 21 distinct frames cover all four, and **7 frames are word-for-word identical in all four**:

- the cover line;
- the kicker;
- the inside-joke line;
- the emoji pair;
- the quiet-year line;
- the loudest-month line;
- the longest-message line.

**Where the rest of the difference comes from.** Mostly which branch fired ("You sent 52%" against "Priya Menon sent 55%").

**What genuinely differs:** the quoted first message, Meera's phrase list and the reply race. The *interpretation* is the same skeleton every time, in the same nine-card order. Card order and card choice never depend on what is remarkable about a particular chat. Possible examples of what a chat could lead with:

- a 25-day silence someone broke;
- a 3:1 imbalance;
- a chat that started last spring.

The demo makes this worse, because every chat shares one timeline. That is a fixture problem, and it is filed below, but the generator has no mechanism to differ even on varied data.

## Sparse and single-year data

| Case | What it printed | Verdict |
|---|---|---|
| 2-message DM | Full nine-card story: "In 2023 alone that was 1 a day", "a while your typical reply", "1 days in a row at best", chart with one bar, "2 messages and still going." | Should not render as a story. Show one honest card below roughly 50 messages. |
| One-month DM | "In 2025 alone that was 1.1 a day" (only 2025 exists), "Aravind Pillai takes a day or more" (false), "😂😂 is your signature pair — 2 times" | Plural, rate and reply bugs all show up |
| One-month group | Holds up mostly. "1 links landed in the chat, from one person. Tara Bhat shared 1 of them." | Plural bug |
| One-chat, 42-message year | "You turned up on 42 days. The other 324, you were missed." "The loudest day was 7 January, with 1." "you also kept 1 videos." | False and trivial |
| Partial current year | Handled well: "Of the 304 days this archive covers…", "January to October" | Good, and the only edge case that was designed for |

---

## Ranked fix list

**P0: wrong facts. Fix before anyone screenshots a story.**

1. **Group count.** Change `groupCount` to `count(DISTINCT CASE WHEN c.is_group=1 THEN m.chat_id END)`, and add a builder-level test with 3 groups that asserts the sentence.
2. **One narrative person.** Pass "You" as the subject to every copy helper. Use the display name only for bubble labels and the cover.
3. **Reply time.** Classify "start" and "reply" independently so 6–24 h answers count, and never print "takes a day or more" unless no reply under 24 h exists.
4. **Year people and days.**
   - "Most of your attention" should rank by two-way DM volume, or messages *you* sent.
   - "Turned up" should use `from_me` days, or be reworded to "the archive has messages on N days".
   - "Wrote to you" should become "were in your chats".
5. **Laugh total.** Count laugh replies in SQL, or score every row with no `LIMIT 6000`, so the headline number is complete.
6. **Superlatives and plurals.**
   - Only say "nothing else came close" when the margin is at least 1.5×.
   - Add the missing `+1` to duo and group `spanDays`.
   - Route every "N noun" through one plural helper.
   - Make `pace` say "per day you talked", or divide by calendar days.
7. **Song reactions.** Credit reactions per share event, so the sender cannot "react" to their own song.

**P1: pick moments that mean something.**

8. **Laugh-moment eligibility, for duo, group and year:**
   - the target has at least 3 content words, is not a laugh and has no URL;
   - rank by distinct laughers, then reply depth, then a non-recency tiebreak;
   - the year card prefers exchanges involving you;
   - dedupe groups by reply and by day.
9. **Emoji.**
   - Reject `a == b` and rewrite `DuoWrappedTests` 221–223 in the same commit.
   - Attribute the pair to a person when 80% or more of it is theirs.
   - Never write "your" in a group.
10. **Inside jokes.** Merge overlapping n-grams, require at least 3 distinct days and more than one speaker, show 3, and hide the card when nothing survives.
11. **Floors that suppress trivia:**
    - busiest day under 5 messages;
    - laugh peak month under 3;
    - "On repeat" for fewer than 3 shares;
    - music card for fewer than 3 links;
    - longest message under 140 characters;
    - Heartbeat below about 50 messages, which gets a single card instead of a story.
12. **The night message.** Choose the longest substantive late message, not the latest timestamp.
13. **Give the year story year-shaped facts:**
    - change against the previous year;
    - new people;
    - people who went quiet;
    - the first message of the year;
    - chats that started.

**P2: voice.**

14. **Callbacks instead of fallbacks.** Link the first message to the top phrase or to the person who carries the chat. Delete "It didn't need to be clever." and show no kicker when no callback exists.
15. **Closings from data.** Say "still going" only if the last message is under 30 days old, otherwise "last message: 12 Nov 2023". Move "not one of them left this Mac" out of the year's closing line, since the lock footer already says it.
16. **Choose the order per chat.** Lead with the most unusual stat (gap, imbalance, streak, a phrase with lift above 50) instead of a fixed nine-card order.
17. **Untitled tracks.** With titles off, use the `link_meta.db` cache or the URL slug. Otherwise write "a Spotify track Meera sent on 15 Nov" instead of a bare "Spotify track".

**Follow-up for the fixture, outside the generator:** give demo chats their own arcs:

- one that starts in mid-2025;
- one that dies in 2024;
- one with a long gap;
- a group that is actually funny on one person's lines.

Also attach laugh replies to lines written to be funny. Until then, the demo cannot show whether stories differ, and screenshots will keep showing "in" → 😂😂😂😂.

## Bottom line

**Hollow now, and not ready to ship as the feature that sells the app.** The plumbing is sound:

- quoted replies are used;
- partial years are handled honestly;
- there is a sensible distinctive-phrase scorer;
- the HTML export shares its copy with the screen.

The output is still a fixed nine-card template with numbers dropped in. It has at least one headline fact that is wildly wrong on the owner's own archive ("ahead of 45,488 other groups"), it switches between "you" and the owner's name in the same story, and its "best moments" are chosen by a tiebreak on recency rather than by anything like meaning. Seven of thirteen sentences are identical across every Heartbeat.

P0 is a day's work and removes the embarrassment. P1 decides whether the stories become worth reading. Without P1, Wrapped is a well-formatted statistics page with a few quips in the empty states. That is shippable as "Insights", but it is not yet a story anyone would share.
