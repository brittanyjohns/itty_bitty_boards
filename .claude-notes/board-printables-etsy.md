# Board printables → marketplaces

How a `BoardPrintable` becomes a sellable product from the admin dashboard:
Etsy over the API, Teachers Pay Teachers as paste-ready copy.

Entry point: `/admin/board_printables/:id`
(`app/views/admin/board_printables/show.html.erb` and its `_listing_form`,
`_listing_images`, `_etsy`, `_copy_blocks` partials).

## Drafts only — never activate a listing

**Rails creates Etsy drafts and nothing else.** `Etsy::Client#create_listing`
hardcodes `state: "draft"`, and the client implements no activate/update-state
call at all. The absence is the guarantee: there is no argument, param, or flag
anywhere in the app that can put a listing live. Going live stays a deliberate
click in the Etsy seller UI, after a human has checked the category, the photos,
and the return policy.

This mirrors the policy already enforced in `speakanyway-printables`
(`scripts/etsy-listing.ts` → `assertStateAllowed`). If a future change needs to
activate a listing, that is a decision to make explicitly, not a parameter to
add.

It also decides where the admin's "Edit draft on Etsy" link points.
`Admin::BoardPrintablesHelper#etsy_listing_url_for` builds the **seller's**
listing editor (`/your/shops/me/listing-editor/edit/:id#media`), not
`etsy.com/listing/:id` — a draft has no public page, so the public URL Etsy's
API hands back (and which is still stored on `etsy_listing_url`) is a dead end
until someone activates the listing, which is the click the link exists to lead
up to. `#media` opens on the photos section, which is what an admin checks first.

## The token-rotation hazard (read before touching auth)

Etsy's OAuth refresh token is **single-use and rotates on every exchange** — the
token you exchange is dead afterwards, and the response carries its replacement.

Two consequences:

1. **The refresh token cannot live in ENV.** A value pinned in Hatchbox is dead
   after the first exchange. It lives in `oauth_credentials` (provider `etsy`)
   because the database is the only writable store this app has.
2. **Rails and `speakanyway-printables` must never share a grant.** That repo
   holds its own refresh token in its `.env` and rotates it; if Rails exchanged
   the same token the two would invalidate each other and both would start
   throwing intermittent 403s that look like nothing in particular.

So Rails uses a **separate authorization of the same Etsy app**. To seed it:

```bash
cd ../speakanyway-printables
npx tsx scripts/bootstrap-etsy-oauth.ts   # mint a NEW, independent grant
```

then, in this repo:

```bash
rake 'etsy:seed_refresh_token[<the-refresh-token-it-printed>]'
rake etsy:status                          # confirms config without printing secrets
```

Do **not** paste the token currently in the printables repo's `.env`.

`Etsy::Client#access_token` refreshes under a row lock (`with_lock`) so two
Sidekiq workers can't exchange the same single-use token concurrently — the
loser 403s *and* its rotation clobbers the winner's, killing the chain.

Tokens are stored in plaintext: ActiveRecord encryption is not configured in
this app. `OauthCredential#inspect` redacts them so they can't leak into a log
line or a console transcript. Revisit if AR encryption is ever turned on.

## Etsy API quirks worth keeping

Ported from `speakanyway-printables/src/publishers/marketplaces/etsy-ops.ts`.
Each of these was a live failure, not a theory:

- `x-api-key` must be `"keystring:shared_secret"`. The bare keystring 401s
  (Etsy's 2026-02-09 enforcement).
- Tags go as **one** comma-separated `tags` value. Repeated params are not
  merged — Etsy keeps only the last and silently drops the rest.
- More than one `&` in a title is a 400. `Etsy::CopyRules.enforce_title_rules`
  keeps the first and turns later ones into "and".
- Price does not stick through the listing create/PATCH payload. The inventory
  endpoint (`GET` + `PUT /listings/:id/inventory`, a full replace) is the only
  writer. `Etsy::PublishBoardPrintable` sets it there explicitly even though
  create also carried it.
- **`taxonomy_id` is not validated by Etsy.** An unknown id returns 200 and the
  listing is filed under an arbitrary category — invisible in the response and
  fatal to discoverability. `assert_known_taxonomy!` checks it against
  `/seller-taxonomy/nodes`. Default is `2078` (Digital Prints). Do **not** copy
  `6816` out of the printables repo's example config or its
  `docs/etsy-cli-for-agents.md` — both are stale, and 6816 is the id that filed
  every listing under nail-art dotting tools.
- A download file is capped at 20 MB, and a listing at **five** of them
  (`Client::MAX_DOWNLOAD_FILES`). Rails refuses an oversized or over-count
  upload up front rather than failing mid-upload after the draft already
  exists; splitting an oversized PDF is still the Node pipeline's job. A board
  printable ships three files, so the count guard is there for the fourth
  variant nobody remembers to count.

## What's in the download — three PDFs, not two

Every printable ships each board three times
(`BoardPrintable::DOWNLOAD_VARIANTS`, in this order):

| Variant | Ink | Header |
|---|---|---|
| `color` | full colour | full band — logo, board title, scan-me line, QR |
| `low_ink` | white tile backgrounds | full band |
| `trim_ready` | full colour | **QR alone, top-right** |

A single board is ONE file holding all three pages; a subboard tree is three
files (`<slug>.color.pdf`, `.low-ink.pdf`, `.trim-ready.pdf`), each fully
wrapped with its own cover, how-to-use, license and credits so any one of them
stands alone. The trim-ready file reuses the **colour** cover — it is a colour
print, only its board pages differ — and gets its own how-to-use page, because
that page is the only thing that tells a reader where the QR went.

**`hide_header: true` is not the way to build the trim-ready page.** The QR
lives *inside* the header block in `api/boards/print.html.erb`, so hiding the
header takes the code with it — and the free audio companion is the single
claim the whole listing leans on. `Boards::RenderAssetData` therefore carries a
three-state `header_mode` (`full` / `qr_only` / `none`), never a second boolean
that can contradict `hide_header`:

- `qr_only` reserves a 20mm band (`#header_band_height_mm`) instead of 30-34mm
  and prints a 0.6in QR in the corner. The band is **reserved, not overlaid**:
  a width-limited board spans the full sheet, so a floating QR would land on
  tiles.
- `hide_header:` still works for the callers that only ever wanted
  all-or-nothing (board previews, the print endpoints, the gallery's grid
  thumbnails) and maps onto `full`/`none`. `header_mode:` wins when both are
  given.

`Printables::IncludedItems.headline` is the buyer-facing count and is shared by
the listing description and the what's-included slide — changing the variant
set means changing it in that one place, and both follow.

## Listing copy lives in two languages

`Etsy::CopyRules` + `Etsy::ListingCopy` are a Ruby port of
`speakanyway-printables/src/generator/listing-copy.ts` and the keyword pools in
`src/plugins/aac/index.ts`. Deterministic, template-driven, no LLM — so a
listing reads the same whichever system produced it.

They **can drift**. The Ruby side is authoritative for listings originated in
Rails; the TypeScript side for listings originated by the Node pipeline. If you
change a rule (a cap, a tag pool, a title template), change both or accept that
the two now differ on purpose and say so.

One deliberate difference: the Ruby description is **plain text**. Etsy renders
no markup, and TPT takes a plain-text paste cleanly, so skipping the
markdown→text conversion means what an admin reads in the textarea is exactly
what a buyer sees.

Generated copy is only a default. It is written into
`board_printables.listing_copy` and edited by hand before publishing;
`BoardPrintable#listing_copy_or_default` is what previews it before anything is
saved.

**Copy quotes `board_page_count`, never `page_count`.** The record's
`page_count` is the true length of the merged PDFs, and every file is wrapped in
a cover, a how-to-use page, a license and a credits page — so it sold a
one-board printable, whose three board pages *are* the product, as a "7-page
board PDF". `BoardPrintable#board_page_count` derives the honest number
(`boards × DOWNLOAD_VARIANTS`) rather than storing it, so printables generated
before it existed report correctly with no re-render. Both readers of
`Printables::IncludedItems` — the Etsy description and the what's-included
slide's "In your download" panel — must pass the same one, or the text and the
gallery image quote different numbers to the same buyer. `page_count` stays the
merged total: it is what the admin lists and what TPT's "Number of pages" field
asks for.

## Gallery images

`Boards::Printables::RenderListingImages` renders **six** square 2560px slides
through `layouts/listing_image.html.erb` — a marketing canvas of its own, not
the print sheet. `LISTING_IMAGE_ORDER` is the Etsy rank order, and rank 1 is the
search thumbnail:

| Slide | Board-specific? | Ported from (`speakanyway-printables`) |
|---|---|---|
| `hero` | yes — real page thumbnails on a room background | `previews/hero-board.*` |
| `on_a_device` | yes — the root board, in the app's chrome, warped onto a photographed tablet | step 14 + `previews/content-mock-app.*` |
| `whats_included` | yes — capped thumbnail grid of the colour pages | `previews/whats-included.*` |
| `whats_included_low_ink` | yes — the same grid rendered `hide_colors` | — |
| `how_it_works` | no | `plugins/aac/.../about-saw.*` (steps half) |
| `about` | no | `plugins/aac/.../about-saw.*` (founder half) |

**Rails is authoritative for listings the Rails admin originates**; the pipeline
is authoritative for the ones its own steps 11/13/14 originate. Same rule, and
the same drift hazard, as `Etsy::CopyRules` above.

### The horizontal safe zone — square is not what every view shows

Etsy does **not** letterbox a square photo. The listing page frames it 4:5 and
cover-crops, taking **10% off each side**, and the seller-side "Adjust
thumbnail" dialog crops again for the search grid. So the canvas stays square —
that is the search grid's shape and the one all six slides share — and the
layout keeps everything that carries meaning inside `--safe-x` (160px of the
1280px canvas, 12.5%, against the 10% Etsy takes).

Only **content** moves in: the title banner, the headline, the audio badge, the
footer bullets, the QR, the site mark, the logo corner. Backgrounds and band
fills still bleed to the edge — a cropped colour band reads as intentional; a
beheaded board name does not. Any new side inset written as a literal px value
reintroduces the bug, which is why `render_listing_images_spec.rb` asserts each
of those rules reads the token rather than a number.

At the old flat 56px inset this cost every live listing the first letter of its
board name and better than half its QR code.

### The tablet mockup

`on_a_device` is a narrow port of that repo's step 14. Rails does **not** have
its scene library or its calibration tool, and doesn't need them: two of its
nineteen scenes are `kind: "tablet"` board stagings, and those two photos plus
their hand-clicked screen corners are vendored into
`Boards::Printables::TabletScene`. The other seventeen stage products this app
doesn't make (ID cards, device tags, stickers, tattoos) or warp a printed sheet
onto furniture — that compositing is still that repo's job.

**What sits on the glass is the app, not a sheet of paper.**
`Boards::Printables::RenderDeviceScreen` wraps the board in SpeakAnyWay's own
chrome — board name, nav, empty speech bar, play/clear/download — and *that*
screenshot is what gets warped. A bare printed page there reads as a photograph
of a printout taped to a tablet, and carries nothing saying the thing on screen
talks; the print header would put a scan-me band and a second QR on the glass.
Ported from that repo's `renderContentAppPage`, chrome and all, so a listing
from either source shows one app. Two constraints:

- **The shell is 1100x720 (~1.528)**, the mean of the two tablet quad aspects
  in `TabletScene::SCENES`. The homography stretches the artwork onto the quad
  whatever shape it is, so a shell at another aspect arrives visibly squashed.
- **The board image is the header-less thumbnail** the what's-included grid
  already rendered, so the slide costs one extra Grover render, not two. A
  board too tall for the shell is top-anchored and clipped — that's what a real
  screen with more board below the fold looks like — and a short wide one is
  centred.

Three things hold the warp together:

- **The quads are copied, not re-measured.** They are the corners someone
  clicked in that repo's `calibrate-mockup-scene.html`, in the scene JPG's own
  pixel space. Re-deriving them by eye puts the board a few pixels off the glass.
- **Everything inside `.mockup-stage` lays out in those same scene pixels**, and
  the stage as a whole is scaled and offset to cover the slide. `object-fit:
  cover` on the photo would move it without telling anything where the corners
  went, which is why `TabletScene#cover_placement` computes the placement itself.
- **The board is letterboxed into a rectangle of the quad's own proportions
  before it is warped.** A homography maps *any* rectangle onto the quad, so
  handing it a portrait board doesn't fail — it silently stretches the board on
  the glass, which reads as a distorted product.

`Boards::Printables::Homography` is a straight port of that repo's
`homography.ts` (Gaussian elimination, then the 3x3 embedded column-major into a
CSS `matrix3d`). Unlike the copy rules, this one is fixed maths — a divergence
here is a bug, not a decision.

Rules that hold across the slides:

- **The colour rotates per listing, and it rotates deterministically.**
  `Boards::Printables::Palette` hashes the board to one of five palettes and
  writes four tokens (`--accent`, `--accent-soft`, `--band`, `--surface`) over
  the layout's defaults; nothing else in the stylesheet may hardcode a brand
  hex. Same hazard as `SCENES`: reordering `PALETTES` re-skins every existing
  listing, and a random pick would re-skin a live one on every regeneration.
  The salt differs from the scene pick on purpose — hashing the same key twice
  would pair scene 1 with palette 1 forever and collapse 4 x 5 looks back to 4.
  What a palette may **not** touch: the navy title banner, the white paper
  cards, the black ribbon, the navy-on-white QR. Those carry the contrast.
- **A page card is sized by an explicit `aspect-ratio`, never a percentage
  height.** `RenderPageThumbnails` reports the trimmed PNG's real dimensions and
  the templates write them inline. The card used to be `height: auto` on the
  image plus `max-height: 100%`, and that percentage resolves against a card
  whose own height is indefinite — per CSS it is ignored, so the image rendered
  full height and `overflow: hidden` silently sliced the bottom off every board
  page. For the same reason the grid declares `grid-template-rows` explicitly:
  an auto row gives the card nothing definite to measure against.
- **Bands that can't fill the slide use `margin: auto 0`.** `.tile-grid` and
  `.steps-strip` are capped flex items; without the auto margins the leftover
  height piles up below them as a dead band instead of centring them.

- **Board pages are HTML before they are a PDF.** `RenderPageThumbnails`
  screenshots `api/boards/print` + `layouts/pdf` with the same assigns
  `CollectPages` prints from. The old note here said page thumbnails would need
  poppler/ImageMagick, which the deploy image lacks — they don't, and that is
  what unlocked showing real boards in the gallery.
- **The hero keeps the page header; the grids and the tablet don't.** The
  printed QR lives inside that header (`api/boards/print.html.erb`), and the
  hero's claim is that the sheet itself carries the code. On a grid tile at a
  sixth the size the header is just the slide's own title band again, so
  `hide_header: true` gives the board the whole tile; on the tablet it is the
  tell that the screen is really a photographed printout.
- **Thumbnails are trimmed by measurement, not calculation.** How much of a
  Letter sheet a board fills depends on its shape; a 12x3 grid leaves over half
  the page blank and reads as a broken image. The header renders ~24mm against
  the 30mm `RenderAssetData` reserves, and a tall board is clamped by
  `.board-sizer`'s max-height — both errors run in the direction that slices
  tiles off, so the trim scans up from the bottom for the last non-background
  row instead.
- **Each page variant renders once.** Planning (`ContentTilePlan`, capped at
  `MAX_TILES`) happens first so Grover is only paid for tiles that get shown,
  and the three passes are memoized: colour-with-header for the hero, colour and
  low-ink without a header for the two grids. Budget:
  `min(boards, 3) + min(boards, 8) * 2 + 6` — up to 25 renders (~40s) for an
  eight-board set, which is why this is a Sidekiq job and never a request
  thread. A fourth pass means a slide is re-rendering pixels it already had —
  `on_a_device` deliberately reuses the root board's header-hidden grid
  thumbnail rather than rendering its own.
- **No emoji, no decorative glyphs.** The render box's Chrome has no guaranteed
  colour-emoji font. Step icons are inline SVG and list bullets are CSS-drawn
  shapes; the source templates use emoji and would have shipped tofu boxes.
- **Chrome is hermetic, board art is not.** Fonts, logo, founder photo, room
  scenes and QR are all base64 (`BrandAssets`, `Fonts`). Board symbol art inside
  a thumbnail loads from the CDN, exactly as it does when the product PDF is
  printed — the one documented exception, and why the hermeticity spec asserts
  on slide HTML only.
- **The room scene is picked by hashing the board.** A listing is already live
  by the time anyone regenerates it; a random pick would re-skin it each time.
  Reordering `BrandAssets::SCENES` re-skins every existing listing.

Etsy will create a listing with no photos but won't let it go live without one,
so `PublishBoardPrintable` renders them when they aren't current.

**`listing_images?` is not a strong enough guard — use `listing_images_current?`.**
A printable generated before a gallery change still has images — the retired
`cover`/`whats_included` pair, or a four-slide gallery from before the low-ink
split. `LISTING_IMAGE_ORDER` is the whole definition of "current", so adding a
variant to it is what makes every older printable stale. Four things stop a
stale image reaching a live listing:
`listing_images_view` filters to known variants, `purge_legacy_listing_images!`
removes them after a successful re-render, the publish guard checks currency,
and the admin card shows a staleness badge. Bulk refresh:
`rake printables:refresh_listing_images`.

Images are written to a **versioned** blob key. CloudFront ignores query
strings, so re-uploading to a stable key leaves the admin looking at the
previous render (same lesson as `Boards::GeneratePreviewAssets`).

**Grover reads `device_scale_factor` only inside `viewport`.** A top-level one
is accepted and silently ignored — that shipped every listing image at 816px
instead of 2040 until it was caught. `width:`/`height:` are PDF-only keys, and
`to_png`/`to_jpeg` set the screenshot type themselves. Specs pin the nested
option because the failure is invisible: the render still succeeds, just small.

## Regenerating and deleting a printable

`POST /admin/board_printables/:id/regenerate` re-runs `GenerateBoardPrintableJob`
on the **same record** so it picks up board edits — `Boards::Printables::Generate`
re-walks the tree and rewrites `board_ids`, so a sub-board added since the first
run is included. It resets `status` to `pending` and clears `error_message`, and
is refused while the record is already `pending`/`generating`.

What it deliberately does NOT touch: `listing_copy`, `etsy_listing_id`, and the
gallery images. Clearing reviewed copy, or the pointer to a live Etsy draft,
would be a worse surprise than stale marketing images — which the existing
**Regenerate** button on the listing-images card re-renders. The redirect notice
says so.

A re-run can produce different filenames (the name carries the board slug) or a
different variant set (one `full` file becomes a `color`/`low_ink` pair once the
tree grows past one board), so `Generate` calls
`BoardPrintable#purge_stale_pdfs!` with the keys it just wrote. That runs
**after** the new files are attached — same rule as the listing images — so a
failed re-render leaves the previous downloads in place rather than emptying the
record.

`DELETE /admin/board_printables/:id` destroys the record; Active Storage purges
its PDFs and images with it. It cannot touch Etsy — this app implements no
listing update or delete call — so the confirm dialog names the surviving draft
id when one exists (`Admin::BoardPrintablesHelper#board_printable_delete_confirm`).

## Storage layout

`BoardPrintable#files` holds both kinds of blob, separated by blob metadata
`kind` (`pdf` / `image`) rather than a second attachment — the PNGs arrived long
after the PDFs and re-homing the existing ones would have churned every stored
key. **A blob with no `kind` is a PDF** (that's every blob written before this
existed).

`files_view` is PDFs only, on purpose: the admin download buttons and the
`/api/board_printables/:id/download_url` contract both read it, and neither
should start handing out marketing art. `listing_images_view` is the images, in
Etsy rank order.

## Publishing is never retried

`PublishBoardPrintableToEtsyJob` is `retry: 0`. A retry after a partial success
creates a **second draft in a real shop**, and nothing downstream would notice.
A failure records itself on `board_printables.etsy_error`, shows on the page,
and waits for a human — a half-built draft is easy to delete, a duplicate is
easy to miss. For the same reason, a printable that already has an
`etsy_listing_id` refuses to publish again.

## Teachers Pay Teachers

TPT has **no seller API**. `Printables::MarketplaceCopy#tpt_fields` lays the copy
out field by field in the order TPT's upload form asks for it, each with a
copy-to-clipboard button. Note TPT's title cap is 100, not Etsy's 140, and the
`(Digital Download)` suffix is stripped — it reads as spam there.

The subject / grade / resource-type values are defaults picked from TPT's fixed
taxonomy, not rules. Standards is deliberately left blank: AAC vocabulary boards
don't map cleanly to CCSS and a guess is worse than an omission.
