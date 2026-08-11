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
- A download file is capped at 20 MB. Rails refuses an oversized PDF rather
  than failing mid-upload; splitting is still the Node pipeline's job.

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

## Gallery images

`Boards::Printables::RenderListingImages` renders **four** square 2560px slides
through `layouts/listing_image.html.erb` — a marketing canvas of its own, not
the print sheet. `LISTING_IMAGE_ORDER` is the Etsy rank order, and rank 1 is the
search thumbnail:

| Slide | Board-specific? | Ported from (`speakanyway-printables`) |
|---|---|---|
| `hero` | yes — real page thumbnails on a room background | `previews/hero-board.*` |
| `whats_included` | yes — capped thumbnail grid + count | `previews/whats-included.*` |
| `how_it_works` | no | `plugins/aac/.../about-saw.*` (steps half) |
| `about` | no | `plugins/aac/.../about-saw.*` (founder half) |

**Rails is authoritative for listings the Rails admin originates**; the pipeline
is authoritative for the ones its own steps 11/13/14 originate. Same rule, and
the same drift hazard, as `Etsy::CopyRules` above. Deliberate differences: no
mockup-scene compositing (that needs the calibrated scene library and a
homography solve — still steps 13/14), and no per-slug variant machinery, so
Rails renders one fixed look.

Rules that hold across the slides:

- **Board pages are HTML before they are a PDF.** `RenderPageThumbnails`
  screenshots `api/boards/print` + `layouts/pdf` with the same assigns
  `CollectPages` prints from. The old note here said page thumbnails would need
  poppler/ImageMagick, which the deploy image lacks — they don't, and that is
  what unlocked showing real boards in the gallery.
- **Thumbnails are trimmed by measurement, not calculation.** How much of a
  Letter sheet a board fills depends on its shape; a 12x3 grid leaves over half
  the page blank and reads as a broken image. The header renders ~24mm against
  the 30mm `RenderAssetData` reserves, and a tall board is clamped by
  `.board-sizer`'s max-height — both errors run in the direction that slices
  tiles off, so the trim scans up from the bottom for the last non-background
  row instead.
- **Thumbnails render once** and are shared by `hero` and `whats_included`;
  planning (`ContentTilePlan`, capped at `MAX_TILES`) happens first so Grover is
  only paid for tiles that get shown. Budget: `min(boards, 8) + 4` renders.
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
A printable generated before this redesign still has images: the retired
`cover`/`whats_included` pair. Four things stop those reaching a live listing:
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
