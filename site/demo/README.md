# Live demo: sample per-person Wrapped

`index.html` is a real per-person Wrapped page produced by Saga from its synthetic demo archive. It is not a mock-up: every number and quote comes from the generated vault and index.

## Provenance

- Generator: `saga demo --out <out>` and `saga duo --index <out>/vault_index.db --chat 2 --out duo.html` (the `saga duo` exporter in `Sources/SagaCore/DuoWrappedHTML.swift`).
- Source page: the untouched export, kept outside the site (`<out>/html/duo-jules.html`; the durable copy used here is `<out>` = a `saga demo` folder with 720 messages, 4 chats, 3 named people).
- Demo data: 60 days from 2026-01-01, two groups and two one-to-one chats, fictional natural-sounding names. `vault.json` in the source folder carries `"synthetic": true`.
- Rebuild the hosted copy with:

  ```sh
  python3 scripts/build_demo_page.py --source <out>/html/duo-jules.html --out site/demo/index.html
  ```

## What the build script changes

The exporter's page is designed to be opened from the Mac app. For hosting it is reduced to a single static document:

- the provider-player hook (`play()`, which would insert Spotify/YouTube/SoundCloud iframes) is removed, so no click can load third-party content;
- the scroll-reveal script is removed, so every section is visible without JavaScript and the page runs with `sandbox="allow-same-origin"` and no scripts;
- `lang="en"`, a description, `noindex`, a favicon reference and a "Fictional demo" band are added.

Nothing else changes: statistics, quotes, layout and CSS are the exporter's output.

## Verified

- `grep -E 'src=|https?://' site/demo/index.html` finds nothing; the page loads no images, fonts, scripts or frames.
- No `<script>` element remains; all nine sections render without JavaScript.
- Lighthouse (mobile): performance 100, accessibility 100, best practices 100, SEO 63 — the SEO score reflects the deliberate `noindex`, not a defect.
- Embedded on `features.html#live-demo` in a titled, sandboxed iframe; the direct link opens the same file.
- Content is fictional throughout; `saga duo` substitutes `You` for the Mac account name when the index belongs to a demo folder, so no local name is embedded.
