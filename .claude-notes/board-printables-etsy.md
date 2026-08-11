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

`Boards::Printables::RenderListingImages` renders two PNGs through the **same**
templates and CSS as the printed wrapper pages
(`layouts/pdf_printable` with `@listing_image` set, which switches on the
`.as-listing-image` square-canvas rules):

- `cover` — literally the product's first page, built from
  `RenderWrappers#cover_assigns` so the QR target can't drift.
- `whats_included` — a slide naming the boards in the set. Text and labels only:
  rasterizing PDF page thumbnails would need poppler/ImageMagick that isn't in
  the deploy image.

Etsy will create a listing with no photos but won't let it go live without one,
so `PublishBoardPrintable` renders them if they're missing. The richer gallery
— lifestyle mockups, scene shots, the about slide — stays in the printables
pipeline's steps 13/14.

Images are written to a **versioned** blob key. CloudFront ignores query
strings, so re-uploading to a stable key leaves the admin looking at the
previous render (same lesson as `Boards::GeneratePreviewAssets`).

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
