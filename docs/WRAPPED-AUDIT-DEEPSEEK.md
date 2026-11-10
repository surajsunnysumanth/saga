# Wrapped / Heartbeat — quality audit (DeepSeek Pro)

Read-only audit of the Wrapped/Heartbeat generator. Nothing in `Sources/` was
changed. Every claim below was produced by running the actual builders
(`YearWrappedBuilder`, `DuoWrappedBuilder`, `GroupWrappedBuilder`) against a
fresh `saga demo` fixture and against a read-only copy of the live index, and
then reading the sentences the views assemble. Demo quotes are verbatim (the
fixture is fictional and public-safe); live-index findings are redacted to
names as `[name]` / `[bot]` and text as `[…]`, per the repo privacy rule.

---

## Verdict

**Not shippable as-is.** The engine is structurally sound — most numbers match
the data, partial years are handled honestly, and the copy mostly reads like a
person wrote it — but two headline sentences are factually wrong in *every*
story: the "ahead of N other groups" figure is the group-*message* count (off by
~100×), and the "longest thing anyone typed" card surfaces forwarded
newsletters on a busy archive. Four more bugs print a wrong number or a
nonsense sentence in narrower cases. Fix the six items in the ranked list, and
the generator is shippable.

---

## The worst five outputs

### 1. "The loudest room was Sunday Football XI — 2,779 messages, ahead of 7,669 other groups."

Year Wrapped **2025**, demo fixture. Verbatim.

The archive's 2025 has **10 groups**. The sentence claims 7,670 of them.

Root cause: `YearWrappedBuilder.build` sets
`groupCount = COALESCE(sum(c.is_group), 0)` — summed across every *message*
row joined to its chat, so it is the number of group **messages** (7,670), not
the number of groups. `WrappedCopy.yearRoom(groups:)` then prints `groups - 1`
as "other groups".

The live index makes it worse: 2025 prints **"ahead of 39,269 other groups"**
(actual: 249 groups), 2026 prints **"ahead of 30,738 other groups"** (actual:
209). The number is wrong in every single year view, by roughly two orders of
magnitude.

### 2. The year's biggest laugh is a two-letter word

Year Wrapped **2025**, demo fixture. The "What made you laugh" card reads:

> The biggest one: Nikhil Rao in Flat 4B, 10 October.

…and the featured message bubble underneath is the text **`in`**, answered by
`😂😂😂😂`.

`YearWrappedBuilder.laughs()` sorts laugh-replies by raw laugh score, takes the
single highest, and returns whatever message it answered with no minimum
content check. Four laughing emoji are worth 4 points, so the archive's
"biggest laugh of the year" is one person typing "in". The same scoring on the
live index picks a moment whose featured text is profanity (`[…] can go fuck a
dead duck […]`), so the "biggest one" can also surface a message nobody would
want framed as their year.

### 3. "Tara Bhat drew 1 laughs from the room."

Group Wrapped **Terrace Gardeners**, demo fixture (a quiet 400-message group).
Verbatim.

`GroupWrappedStory`'s laugh-card subtitle is hardcoded:

```swift
subtitle: w.funniest.first.map { "\($0.name) drew \(WrappedCopy.n($0.laughsEarned)) laughs from the room." }
```

`n(1)` → `"1"`, then `" laughs"` is appended unconditionally. Any group whose
funniest person earned exactly one laugh ships "1 laughs".

### 4. "Your longest message is 0 characters; [bot]'s record is 321."

Duo Heartbeat, live index, a one-sided chat: 7 messages, **0 from you**, 7 from
the other side. Verbatim except the name.

`WrappedCopy.longestMessage(me:them:mine:theirs:)` guards `max(mine,theirs) > 0`
but never handles one side being zero, so `mine == 0` prints "Your longest
message is 0 characters". A person who never sent anything cannot have a
"longest message". (Same chat also shows the deeper problem that this is a
restaurant-booking bot, not a friend — see ranked item 10.)

### 5. "All of it on 4 July 2023."

Duo Heartbeat, live index. Verbatim. The chat's 34 messages run **4–5 July
2023** — two days — but the cover says everything happened on the 4th.

`DuoWrappedBuilder` computes `spanDays = dateComponents(.day, from:
startOfDay(first), to: startOfDay(last))` with **no `+1`**, while
`YearWrapped.spanDays` *does* add one. A two-day chat yields `spanDays == 1`,
which trips `WrappedCopy.span()`'s `span == 1` branch ("All of it on …") and
erases the second day. The off-by-one also understates every long span (the
Meera demo reports "1,095 days" for a 1 Nov 2023 → 31 Oct 2026 span that
is really 1,096).

---

## The data behind the five

| # | Claim printed | What the data says | Root |
|---|---|---|---|
| 1 | "ahead of 7,669 other groups" | 10 groups in 2025 | `sum(c.is_group)` = group messages |
| 2 | biggest laugh = text `in` | reply `😂😂😂😂` answered `in` | no min-content on laugh target |
| 3 | "drew 1 laughs" | `laughsEarned == 1` | hardcoded plural in the view |
| 4 | "Your longest message is 0 characters" | you sent 0 messages | no zero-side guard |
| 5 | "All of it on 4 July 2023" | messages on 4 *and* 5 July | `spanDays` missing `+1` |

---

## Ranked fixes

1. **`groupCount` is group-message count.** In `YearWrappedBuilder.build`,
   replace `COALESCE(sum(c.is_group),0)` with
   `count(DISTINCT CASE WHEN c.is_group=1 THEN m.chat_id END)`. Add a test
   asserting the demo's 10-group year prints "ahead of 9 other groups".

2. **The longest-message fallback defeats its own filter.** `longestMessage`
   picks `rows.first { !isBroadcast && noLinks } ?? rows.first`; when the
   top-12 are all broadcasts/links it falls back to the absolute longest, which
   on the live index is a 7,671- and an 8,805-character event newsletter
   ("Hello and a happy friiidayyyyy. From the archives…", "…Hydroponics
   101…"). Widen to `LIMIT 50`, and return `nil` instead of `?? rows.first`
   when nothing qualifies — the card is already optional.

3. **Give the year's "biggest one" a floor.** In `laughs()`, after sorting the
   best replies, walk the list and return the first whose target message has
   real content (≥ ~12 non-emoji characters), rather than the highest raw
   emoji score. Kills both the `in` moment and the profanity moment.

4. **Pluralise the group laugh subtitle** (`GroupWrappedStory.laughs`). Reuse a
   `WrappedCopy` helper (`laugh(n)` → "1 laugh" / "N laughs") instead of the
   hardcoded `" laughs"`.

5. **Handle the zero side in `longestMessage`.** When `mine == 0 || theirs == 0`,
   describe only the non-zero side (or return a sentence that says the quiet
   side didn't send any), never "0 characters".

6. **Add the `+1` to `DuoWrappedBuilder`'s `spanDays`** to match
   `YearWrapped.spanDays`, and make `span()` treat a two-day span as two days
   rather than "all on one day".

Then, in priority order:

7. **Resolve sender names in the year soundtrack.** `YearMusic.load` uses raw
   `m.sender`, so `linkSenders` and track details on the live index print raw
   phone numbers and LIDs as names (`1750864413`, `1735741577`, a `Phone`-only
   bot) — e.g. "… sent it on 2 Jan 2026 · 4 times in all" attributed to a raw
   number. Join the `people` table the way the `people` list already does.

8. **"On repeat" means "shared twice".** Duo `music()` tags `evs.count > 1` as
   "On repeat", so in a chat where every song was shared twice, everything is
   "on repeat" and the label loses meaning. Use `>= 3` and add a "Sent twice"
   tier (mirror the year view's `role()`).

9. **The emoji "signature pair" can be one emoji twice** — `😂😂 … 136 times`
   is not a meaningful pair. Require `a != b` or drop the pair line.

10. **Don't write a Heartbeat for bots/business chats.** Chats with no resolved
    name (a raw number) and one-sided traffic produce "You & a raw number",
    "Phone broke it", "Your longest message is 0 characters". Gate the duo/group
    Heartbeat on a minimum from-you message count (or flag verified/business
    chats), or these stories read as a joke about a reservation bot.

11. **`pace` uses the wrong denominator for sparse chats.** "In 2026 alone that
    was 1.8 a day" for a 7-message, 247-day chat (`count / activeDays`, not
    `count / spanDays`). Divide by `spanDays`, and fall back to "N messages in
    all" when the result is under 1/day.

12. **`quietestYear` mis-frames a partial first year.** The demo reports "2024
    went quiet — 193 messages in twelve months" when 2023 (170 messages in *two*
    months, an archive start) was the actual low point; the interior-year
    filter excludes the first year and the median comparison flags a year that
    was not a dip. Compare per-day rate, and treat a partial first year as an
    archive start, not a lull.

---

## What is actually good (verified, not assumed)

- **Partial years are handled honestly.** Live 2026: "You turned up on all 313
  days this archive covers", range "January – November 2026". Demo 2023:
  "November to December: a message in all 2 months." The covered-days
  denominator and `isPartial` logic work, and the old "the other 61 days you
  were missed" lie is gone.
- **The `people` list resolves names and rejects numbers** (raw numbers/LIDs are
  filtered by `isNumber`), so "…got the most of your attention" leads with a
  real name. The gap is only in the *soundtrack* sender list (item 7).
- **Balance, reply-race, laughs, and music counts all match the data** — the
  numbers in "Meera Nair sent 55% of them — 1,202 to 998" and "Sam's messages
  drew 72 laughs… 23 went back the other way" check out against the fixtures.
- **Funny-moment selection spreads across years** (demo moments land in 2023,
  2024, 2025, 2026) and drops broadcast/unsubscribe text, and real quoted
  replies are preferred over proximity guesses.
- **System notices never leak** into counts, the longest message, the laugh, or
  the soundtrack (asserted by `YearWrappedTests`).
- **Zero-state guards hold the line.** A chat below 2 messages is refused by the
  views ("Not enough messages in this chat for a Heartbeat"), so the empty
  "sent 0 messages / 0 people" story a content-less channel can produce never
  reaches the user.

## Method

Fresh `saga demo` fixture (`saga demo --out …`, 20,600 messages / 15 chats),
plus a read-only copy of the live index (`vault_index.db`, 703k messages /
9,746 chats, 2017–2026). A throwaway SwiftPM driver in the scratch dir imported
`SagaCore` and printed the exact copy the three story views assemble (the
driver is not part of the repo). Years exercised: 2023 / 2024 / 2025 / 2026 on
the demo, 2017–2026 on the live index; duo/group on the biggest and sparsest
DM, the biggest group, a one-member channel, and single-year chats. No source
files were modified.
