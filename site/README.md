# Saga website

A framework-free static site: plain HTML, one CSS file, one small JS file (print and the embedded sample's focus ring). No build step, trackers, cookies, external fonts or third-party scripts. Every internal URL is relative, so the same files work under a project path (`<user>.github.io/<repo>/`), a custom domain, or `file://`-style local serving.

## Preview and check locally

```sh
python3 -m http.server -d site 8000          # open http://localhost:8000
sh scripts/check_site.sh                     # links, fragments, metadata, image weight, demo offline audit
python3 -m unittest discover -s scripts/tests -p test_site.py
```

There is nothing to build. `site/` is the deployable directory.

## Pages

| File | Contents |
| --- | --- |
| `index.html` | Hero and download, a 2×2 of what the archive does, the privacy band |
| `features.html` | One repeating pattern: eight alternating screenshot rows — the per-chat story row carries the embedded live Wrapped sample — and a plain list of text-only features |
| `privacy.html` | Plain-language mirror of `PRIVACY.md`: what stays local, what can reach the network, one table row per case |
| `faq.html` | Requirements, keys, iPhone status, encryption, deleted messages, sharing, under a staged four-step path drawn in the setup wizard's visual language |
| `get-started.html` | Download and Gatekeeper step, requirements, Android import, source build, demo archive, troubleshooting |
| `404.html` | Not-found page |
| `demo/index.html` | The live per-person Wrapped sample (see `site/demo/README.md`) |

Every page carries exactly one `<link rel="canonical">`, one set of `og:*` tags and one set of `twitter:*` tags, all with that page's own title — shared links must never preview another page.

Supporting files: `assets/site.css`, `assets/site.js`, `assets/favicon.png`, `assets/apple-touch-icon.png`, `favicon.ico`, `assets/images/social.jpg` (Open Graph artwork, 1200×630), `assets/images/*.webp`, `robots.txt`.

`screenshots/` holds an earlier QA record of the pre-redesign pages (390/768/1440). No page references it and it is not part of the design; it is kept only as history.

## Design tokens

`assets/site.css` is the single stylesheet and the single source of truth for the visual language. Its first block declares, in order: the colour primitives from `docs/DESIGN.md`, semantic colour aliases (`--color-bg`, `--color-surface`, `--color-ink`, `--color-accent`, the one dark `--color-band-*` set), the type scale (`--text-*`, `--leading-*`, `--tracking-*`, `--weight-*`), the 4px spacing scale (`--space-1`…`--space-11`), layout rhythm (`--content-max` 1120px, `--gutter`, `--section-space`, `--card-padding`, `--measure-*`), radii, elevation, borders and motion. Component rules consume only those tokens; page markup carries no colour or size literals apart from the `theme-color` meta tags (the attribute requires a literal colour).

Dark theme follows the system preference and overrides only the palette variables; content rules never branch on theme. There is no theme switch and no stored preference. Add a new value as a token first, then use it — do not introduce a literal in a component rule.

The layout vocabulary is deliberately small: a hero (centred on the homepage, left-aligned on inner pages), one card style, one screenshot style (a bare rounded image with its own shadow, no browser chrome), alternating feature rows, a plain description list, and a two-column FAQ. The hand-drawn underline appears once, on the homepage.

## Where the visuals come from

Every screenshot comes from the synthetic demo vault built by `saga demo` — no real conversation, name or phone identifier is in any image. `gallery.webp` is the one capture made from real photographs: the demo was built with `saga demo --photos fixtures/demo-photos`, so its image attachments are thirteen Unsplash photographs instead of the drawn scenes. Those source files live in `fixtures/demo-photos/` and are deliberately **not** part of `site/`: they exist only to reproduce the capture, and the page never loads them. Only the resulting WebP ships.

The photographs are used under the [Unsplash License](https://unsplash.com/license) — free for commercial use, no attribution required, and no model releases granted. They are illustrative: the people in them are not the demo's fictional friends, and a group photo of friends at a distance or from behind is chosen for exactly that reason. Each picture is linked to its Unsplash photo page below, where the photographer is credited; no API key or API call was used and nothing is hotlinked. The one other deliberate exception is `music.webp`: it shows the covers and titles that the demo archive's public Spotify, YouTube and Apple Music links resolve to, so the Music tab looks like the product. That album artwork is the property of its respective rights holders and appears only inside that screenshot; the page itself loads nothing from a streaming service. Screenshots are WebP at the harness's native 2× (2400×1588, the hero 2800×1200), at most 500 KB each (`scripts/check_site.py` enforces the limit), and the footer says once that they use invented data.

| File | Source |
| --- | --- |
| `assets/images/hero.webp` | Home capture at 2800×1200 (cropped at the gap below the module row, displayed 1400×600) |
| `assets/images/chat.webp` | same run, conversation view, showing the reaction chips |
| `assets/images/search.webp` | search results from the demo index |
| `assets/images/people.webp` | a fictional person's page |
| `assets/images/gallery.webp` | the gallery grid, Images tab, from `saga demo --photos fixtures/demo-photos` |
| `assets/images/music.webp` | the same grid on the Music tab, with each link's cover, title and artist |
| `assets/images/voice-notes.webp` | the Gallery's Voice notes tab: one row per note with its sender, chat, date and duration |
| `assets/images/settings.webp` | archive settings: where the vault lives, add backups |
| `assets/images/wrapped.webp` | global Wrapped for the demo year |
| `assets/social-card.png` | composed locally from the app icon, the home headline and the hero capture |
| `assets/favicon.png`, `favicon.ico`, `assets/apple-touch-icon.png` | derivatives of `Resources/AppIcon.png` |

Every screenshot on the site is captured in the app's dark theme, so the page has one consistent look; never mix a light capture in. The snapshot harness renders at 2× — a 1200×794 window writes a 2400×1588 PNG — and that is the file that ships. Pages declare the CSS size (`width="1200" height="794"`, the hero `1400×600`) and the browser scales the 2× image down, so on the Retina display most visitors use, the text inside a screenshot is native rather than interpolated. Never downscale a capture before encoding; crop only, at native pixels. To refresh them: regenerate the demo vault with `saga demo --out <new-folder>`, run the app's snapshot mode (`build/Saga.app/Contents/MacOS/Saga --demo <new-folder> --snapshot <shots> --dark --width 1200 --height 794`), then `cwebp -q 86 <png> -o site/assets/images/<name>.webp`. Encode at the capture's own size. If a file lands over ~450 KB, drop the quality to `-q 80` before touching the pixels — the thirteen-photo Gallery grid is the one that needs it. The three Gallery captures pick their tab with `SAGA_GALLERY_KIND=Images` (or `Music`, or `Voice notes`) together with `--place gallery`; the Music tab resolves covers over the network, so run that capture twice and keep the second. Encode with `cwebp` rather than an image library: ImageMagick's WebP writer has produced files Chromium lists as complete but never paints.

The Gallery capture adds the photo folder. Its PNG is already 2400×1588 and `features.html` declares 1200×794, so it is encoded as captured — no `sips` step.

```sh
.build/release/saga demo --out /tmp/saga-gallery --photos fixtures/demo-photos
SAGA_GALLERY_KIND=Images build/Saga.app/Contents/MacOS/Saga \
  --demo /tmp/saga-gallery --snapshot /tmp/gallery-shots --dark \
  --place gallery --width 1200 --height 794
cwebp -q 80 /tmp/gallery-shots/1-dashboard.png -o site/assets/images/gallery.webp
```

The hero is the one crop: capture a 1400-wide window taller than the frame, then cut the PNG at the gap below the module row (row 1185 of this layout) and extend that single flat gap row to the declared 2800×1200 — never resize it. Cutting at 1200 instead clips the *1 might need your reply* banner that now follows the modules, so the crop stops in the gap and repeats one background row; the gap is flat, so the join is invisible.

```sh
build/Saga.app/Contents/MacOS/Saga --demo /tmp/saga-demo --snapshot /tmp/hero-shots \
  --dark --place home --width 1400 --height 662
magick /tmp/hero-shots/1-dashboard.png -crop 2800x1185+0+0 +repage /tmp/hero-crop.png
magick /tmp/hero-crop.png \( +clone -crop 2800x1+0+1184 +repage -resize 2800x15! \) \
  -append /tmp/hero.png
cwebp -q 86 /tmp/hero.png -o site/assets/images/hero.webp
```

The chat capture opens the trip group (`--open 8` on the current demo) because its last page carries several reactions, so the chips are part of the picture: `--width 1200 --height 794 --dark --open 8` → `2-chat.png` → `cwebp -q 86`.

Photographs in `fixtures/demo-photos/`, all from Unsplash:

| File | Subject | Unsplash photo page |
| --- | --- | --- |
| `01-group-walk-away.webp` | friends walking away, backs turned | <https://unsplash.com/photos/two-women-and-a-girl-walking-away-from-camera-pqGsD518PRk> |
| `02-group-autumn-path.webp` | two friends on an autumn path, from behind | <https://unsplash.com/photos/two-friends-walking-on-a-path-in-autumn-park-goav65V51AI> |
| `03-group-beach-sunset.webp` | friends silhouetted on a beach at sunset | <https://unsplash.com/photos/friends-watch-the-sunset-over-the-ocean-yQgd8dowDHc> |
| `04-group-hiking-trail.webp` | a group hiking up a trail, distant | <https://unsplash.com/photos/a-group-of-people-hiking-up-a-trail-EC9LVviyzrI> |
| `05-food-biryani.webp` | biryani with egg and cucumber | <https://unsplash.com/photos/a-plate-of-biryani-with-meat-egg-and-cucumber-cLJa_074rcA> |
| `06-food-cafe-table.webp` | coffee and pastries on a wooden table | <https://unsplash.com/photos/a-wooden-table-topped-with-pastries-and-drinks-g5Bj7qR9PCI> |
| `07-food-pastries.webp` | a tray of pastries and a coffee | <https://unsplash.com/photos/a-tray-of-pastries-and-a-cup-of-coffee-on-a-table-pSsOCQEPhbM> |
| `08-pet-dog-grass.webp` | golden retriever resting in foliage | <https://unsplash.com/photos/golden-retriever-dog-resting-in-green-foliage-yzUtFphQf0Q> |
| `09-pet-cat-window.webp` | black cat on a window sill | <https://unsplash.com/photos/a-black-cat-sitting-on-a-window-sill-1oc4NGn1230> |
| `10-pet-dog-beach.webp` | dog running on a beach | <https://unsplash.com/photos/a-dog-is-running-on-the-beach-near-the-water-oEeLZsTdr_k> |
| `11-landscape-mountain-lake.webp` | mountain lake at sunset | <https://unsplash.com/photos/mountain-lake-reflecting-dramatic-sunset-clouds-and-peaks-3j0G9Nu8bYY> |
| `12-landscape-coast.webp` | waves on a sandy coast | <https://unsplash.com/photos/aerial-beach-seashore-waves-dU7C6BgWp0s> |
| `13-landscape-tea-terraces.webp` | tea terraces on rolling hills | <https://unsplash.com/photos/lush-green-tea-terraces-on-rolling-hills-GAfHWK-gSg0> |

The demo numbers these in Gallery order (newest first) and cycles through them, so the first screenful shows every category — group, food, pet, landscape — without repeating a picture. `saga demo` with no `--photos` still draws its abstract scenes; the flag is only for reproducing this capture.

The live sample sits in the `features.html` story row (`#duo-wrapped`, anchored as `#live-demo`) and is framed as a phone rather than a bare iframe: the screen keeps a 9 : 19.5 aspect ratio, the frame width is `min(390px, 100%, 80svh × 9 / 19.5)` so it shrinks on short desktops and narrow phones instead of clipping, and the real `demo/index.html` document scrolls inside it. Bezel, speaker slot, inner glass edge and the ambient shadow are gradients and shadows over the `var(--device-*)` tokens. Nothing about the frame needs JavaScript.

## Verified (on this machine, before hand-off)

- `python3 scripts/check_site.py` / `sh scripts/check_site.sh` — 7 HTML pages; links and fragments resolve; every page has `lang`, title, description, one `h1`, one canonical and one og/twitter set; images have alt text and dimensions at their CSS size while the file is 2×; assets under 500 KB; no passive external requests; the demo page has no absolute URLs, scripts, images or provider hooks.
- `python3 -m unittest discover -s scripts/tests -p test_site.py` — 12 tests pass.
- Every page rendered through Chromium at 390 and 1440 px in light and dark: `scrollWidth == viewport width` (no horizontal scroll) on all six pages, every image decodes, no clipped text.
- Screenshots at 2× on a `deviceScaleFactor` 2 render: the hero (2800×1200 in a 1120 CSS px slot) and a Gallery tile (2400×1588 in 528 CSS px) both read as native pixels, not interpolation.
- Keyboard: the skip link is first and lands on `<main tabindex="-1">`; nav order is Features · Privacy · FAQ · GitHub · Download plus the footer links; the embedded sample takes focus and shows its ring on the screen edge.
- Colour: the palette is unchanged from the audited token block (lowest measured pair 4.9:1 for links on paper).

## Hosting

**GitHub Pages** is the recommendation: `.github/workflows/pages.yml` is `workflow_dispatch` only, and it runs the unit tests and `scripts/check_site.sh` before uploading `site/`. To use it: Settings → Pages → Source "GitHub Actions", then run "Static site (manual publication)". Cloudflare Pages works equally well: build command none, output directory `site`.

No build step, no absolute paths and no server-side includes, so project-path hosting (`/<repo>/`) works unchanged. `404.html` and `robots.txt` are picked up by both hosts; `demo/` is a real folder with `index.html` and is `noindex`.
