# Saga design direction

Owner references: **yetanotherbrowser.com** (editorial confidence), **odoo.com** (warm, human, chunky cards and friendly illustration), **CleanMyMac / macpaw.com** (glossy material, generous space, playful premium).

The goal is not "clean SaaS". It is a personal archive that feels like a well-made object: warm, confident, a little playful, never busy.

## Brand in one line
Warm paper, sharp black type, one electric accent, real product screens (never mockups of fake UI), and small hand-drawn marks that stop it feeling corporate.

## Tokens (use these exact values)
WhatsApp's own palette, so the product feels like the app the data came from. No invented brand colours.

```
--teal       #075E54   WhatsApp dark header / dark section background
--teal-deep  #054C44   hover, pressed
--green      #25D366   the accent: primary buttons, links, active state, one hero element per page
--green-soft #DCF8C6   the outgoing-bubble green: highlights, tags, chart fills
--green-ink  #128C7E   green text on light backgrounds (better contrast than #25D366)
--ink        #0B141A   WhatsApp's text black: headings, body
--ink-soft   #54656F   secondary text
--line       #E9EDEF   hairlines (WhatsApp's divider grey)
--paper      #F7F8F6   page background, a green-tinted off-white
--surface    #FFFFFF   cards
--chatbg     #EFEAE2   WhatsApp's chat wallpaper beige (conversation backgrounds)
--radius     20px cards, 14px inputs, 999px buttons
--shadow     0 1px 2px rgba(11,20,26,.05), 0 12px 32px rgba(11,20,26,.07)
```

Use green as the only accent; teal for one dark section per page (privacy) and for the site header/footer. Bubbles, tags and charts may use `--green-soft`.

Type: system stack only (`-apple-system, "SF Pro Text", Inter, system-ui`). Display 56–72px, tracking `-0.02em`, weight 650. Body 17px/1.6. Eyebrow labels 12px, uppercase, letter-spacing .12em, `--ink-soft`. Mono (`ui-monospace`) only for file paths and CLI.

Never: more than one accent per section; gradients behind text; stock photos; drop shadows on text; icon sets from three different families.

## Site
Rhythm: full-bleed warm section → one centred 1120px column → generous vertical padding (96–128px). Alternate `--paper` and `--sand`; one dark section maximum per page (the privacy promise).

- Hero: big black headline with a hand-drawn accent (SVG squiggle or arrow, 2px stroke, `--violet`), one-line subhead, pill primary button, then a **browser-frame card** (three dots, hairline border, 20px radius) containing a real screenshot. Screen, not illustration.
- Sections: eyebrow → headline → short paragraph → 3-up cards with a gradient squircle icon (SF Symbol in `--violet`→`--rose` gradient), title, one sentence. Odoo-style chunkiness: 24px internal padding, 1px hairline, hover lifts 2px.
- Feature rows: alternating screenshot left / copy right; each has a small "you can" bullet list of three concrete things.
- Wrapped demo: framed as a phone-sized story (390×844) with the real HTML scroller inside; a "open it full screen" link.
- Microcopy: plain, warm, specific. No "empower", "seamless", "revolutionise".
- Footer: paper background, the privacy line, licence, disclaimer.

## App (SwiftUI) — CleanMyMac-inspired, still native
- **Home:** replaces the current dashboard with four large module tiles (Chats, People, Wrapped, Music & video), each a 20px-radius card with a gradient squircle icon, a big number, and a one-line status ("703,378 messages · updated 2 days ago"). Hover: lift + hairline accent.
- **Hero card:** one wide card at the top for the current task ("Update from phone", "Your library is 3 days behind") with a single prominent pill button and a soft painted background (`--violet` at 8% over `--surface`).
- **Sidebar:** keep native, but add a thin gradient rule under the header and a small "Local only" mint badge.
- **Chat list:** hairline-separated rows, avatar 34px with a soft gradient ring for groups, name 15px/600, preview 13px `--ink-soft`, right-aligned time in `--ink-soft`; unread dot `--violet`.
- **Conversation:** keep bubbles but soften (18px radius, mine `--violet` at 100%, theirs `--surface` with hairline), 12px meta, and day dividers as small centred pills on `--sand`.
- **Wrapped / duo:** already illustration-like; keep the story feel, adopt the same accent pair and paper background so app and site look like one product.
- **Motion:** 180–240ms springs on hover/open; honour Reduce Motion.
- **Empty and error states:** line-art illustration + one sentence + one button. No raw error strings.


## Information architecture (agreed 8 Nov)

One navigation, three levels, and a word that means one thing.

| Level | Holds | Test |
|---|---|---|
| **Top bar** | The five **places**, always visible: Home · Chats · Gallery · Insights · Settings | Can I go there and stay? |
| **Sidebar** | The **list belonging to the place** — chats under Chats, years under Insights, nothing on Home | Does it change when I pick a different place? |
| **Content header** | **Modes of the thing you opened** — Messages · Media · Heartbeat | Does it only make sense inside this chat? |

The sidebar is a list, never a navigation. That is what stops the one-way door: leaving a chat can never strand you, because the places are not in the column you just replaced.

### Vocabulary (binding)

| Word | Means | Never means |
|---|---|---|
| **Wrapped** | The year, under **Insights** | A single chat |
| **Heartbeat** | One chat or group's own story — who carries it, reply times, jokes, the songs traded | The year |
| **Insights** | The place: Wrapped by year, plus personal stats (most-used words, emoji, late nights, streaks) | Per-chat analysis |
| **Gallery** | Every image, video, music, link and document shared across the archive, tabbed by kind | What one chat shared |
| **Media** | What *this chat* shared (tab inside a chat) | The global gallery |
| **Search** | Finding what exists: messages, people, chats, media | Answering questions |
| **Ask** | Answering, with citations, and optionally taking you somewhere | Finding text |
| **Filter** | Narrowing a list | Searching messages |

### Search and Ask are two different instruments

- **Search (⇧⌘F)** is deterministic and archive-wide. A field in the top bar; results are a full screen grouped by kind — Messages · People · Chats · Media — each row jumping to the thing itself. No model, no waiting, works with AI off.
- **Find (⌘F)** is the same instrument at the level of the window: inside a conversation it searches that chat and steps between matches. ⌘F with no chat open puts the cursor in the archive search. One key, two levels — a chat is never mistaken for the archive.
- **Ask (⌘K)** is the expanding pill at the right of the top bar, and it is the only Ask. It opens the inspector on the conversation you are reading and says so with a scope chip (`Only in Priya ×`); removing the chip widens it to every conversation. It answers with citations, and each citation is a door. It has three shapes, and the UI should announce which one it used:
  1. **Take me there** — "Priya Menon", "2025 Wrapped", "music with Meera" → navigates.
  2. **Answer** — "when did we first talk about the kettle" → a short grounded answer with links to the messages behind it.
  3. **Run a view** — "who hasn't replied", "my late nights" → opens the matching view already filtered.
- With no model on the machine, Ask degrades to Search and says so in one line. Nothing else in the app depends on it.

### Settings

A full-screen place inside the app (⌘, goes there), not a separate window. Archive, People and chats, Home and Privacy are its panes, and every housekeeping tool lives in one of them as well as on the surface that needs it; the Go menu only mirrors what is visible.

## Constraints
- No external fonts, scripts, trackers or CDN assets, on the site or in the app.
- Contrast: body ≥ 4.5:1, large text ≥ 3:1. Accent is never the only signal.
- Every screenshot must come from `saga demo` with fictional, natural-sounding names (no "(demo)" suffixes anywhere in the data).
- Ship in this order: site hero + features, app home + chat list, then the rest.

## Definition of done
A page or screen is done when it matches the tokens above, works at 390 / 768 / 1440 (site) and 900–1600 (app), passes the accessibility checks, and contains no placeholder or "(demo)" text.
