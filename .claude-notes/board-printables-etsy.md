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
  writer. `Etsy::PublishBoardPrintableListing` sets it there explicitly even though
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
| `trim_ready` | full colour | **one thin address line, top-right** |

A single board is ONE file holding all three pages; a subboard tree is three
files (`<slug>.color.pdf`, `.low-ink.pdf`, `.trim-ready.pdf`), each fully
wrapped with its own cover, how-to-use, license and credits so any one of them
stands alone. The trim-ready file reuses the **colour** cover — it is a colour
print, only its board pages differ — and gets its own how-to-use page, because
that page is the only thing that tells a reader where the QR went.

**The permanence note lives on the credits and how-to-use pages, never on the
cover.** A buyer's QR points at a board that may later change or move, so both
pages tell them to make a free account and save their own copy — the credits
page beside the QR itself, and how-to-use as step 6. Two placements are ruled
out: the **cover**, which is the first thing a buyer sees on opening the product
(a "may not stay online" line has no business being the first page of something
just paid for — and when this was written the cover was also rendered as the
gallery's first image, so it *was* the Etsy search thumbnail); and the
**license page**, where the surrounding anti-redistribution
terms make it read as a restriction on the buyer rather than a nudge. Word it as
a next action, not a disclaimer — "isn't guaranteed forever" on a product page
reads as a warning about what was just paid for. `credits` renders once and
`MergePdf` binds the same bytes into all three files, and the how-to-use line
sits outside step 1's `@variant` branch, so both are variant-independent by
construction. None of this touches `api/boards/print.html.erb` or
`layouts/pdf.html.erb`, which are shared with real users' PDF downloads.

**Campaign tags go on the SCREEN QRs only.** `Boards::Printables::Qr` builds
two URLs for the same board: `target_url_for` (bare `/pb/<slug>`) for anything
printed, and `listing_target_url_for(board, content:)` for the gallery images
and the listing video, which adds
`utm_source=etsy&utm_medium=listing&utm_campaign=board_printable&utm_content=<surface>`.
The split is a scannability constraint, not a taste one: the bare URL is a
version-6 (41-module) code at the renderer's ECC — already ~0.5mm per module at
the printed page's 0.8in header, the phone-camera detection floor that made the
classroom-kit tags unscannable in 2026-07 — and tagging it pushes it to version
12 (65 modules, 0.31mm), i.e. a code that does not resolve off paper. Screen
QRs pay nothing for the extra characters, and they render at
`Qr::SCREEN_ECC` (`:m`) rather than print's `:h` so the tagged URL stays a
49-module code with ~5px per module in the frame's 244px slot, which survives
Etsy's video re-encode. **Never route a printed QR through
`listing_target_url_for`** — that includes the page thumbnails inside the
gallery slides, which must keep encoding exactly what the downloaded page does
(`RenderPageThumbnails`). Guarded by
`spec/services/boards/printables/qr_spec.rb`.

**`hide_header: true` is not the way to build the trim-ready page.** The QR
lives *inside* the header block in `api/boards/print.html.erb`, so hiding the
header takes the code with it — and the free audio companion is the single
claim the whole listing leans on. `Boards::RenderAssetData` therefore carries a
three-state `header_mode` (`full` / `url_only` / `none`), never a second boolean
that can contradict `hide_header`:

- `url_only` reserves a 6mm band (`#header_band_height_mm`) instead of 30-34mm
  and prints ONE thin line of type — the board's address, no code. The band is
  **reserved, not overlaid**: a width-limited board spans the full sheet, so
  floating text would land on tiles.
- **The trim-ready page carries no QR, deliberately.** "Trim-ready" is a size
  claim, and the 0.6in code cost 20mm of sheet — ~15% of the board's printed
  area on a height-limited landscape page — for a code that is ~0.37mm per
  module at that size, at or under the phone-camera floor that made the
  classroom-kit tags unscannable (`.claude-notes/marketing-assets.md`). It was
  paying a size penalty for a scan that half-works. The scannable code still
  ships on the colour and low-ink pages, and on the trim-ready file's own
  cover and credits pages; the how-to-use page says where it went.
- Because that page renders no code, `RenderAssetData` skips the 480px QR
  encode for it entirely while still resolving `qr_target_url` for the printed
  line.
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

**They are out of sync right now, by design.** The Ruby side moved first on the
boilerplate-copy fix (Aug 2026); `speakanyway-printables` still carries the old
rules and needs the matching change — see that repo's
`.claude-notes/etsy-listing-copy-fix-handoff.md`. What differs until it lands:
the product phrase is `"communication board"` here and `"vocabulary board"`
there; `assemble_tags` runs `topic` second here (capped at
`CopyRules::TOPIC_TAG_MAX`) and fourth there; the description's opening
sentence is per-product here and a frozen constant there; and the two SEO rules
below (no single-word tags, head-term-first titles) exist only here.

**A tag is a PHRASE — `normalize_tag` refuses a single word.** Analysis of all
21 live listings on 2026-08-20 (views normalized by `original_creation_timestamp`,
since the API's `created` resets on renewal) found five of every listing's
thirteen slots going to `aac`, `printable`, `slp`, `classroom` and
`nonspeaking`. A one-word tag competes with the entire marketplace and does not
rank; the listings earning views were found by phrases. The rule lives in
`CopyRules.normalize_tag`, NOT in the pools, deliberately: a future pool edit
cannot put the slots back, and the same rule reaches `Etsy::Client#normalize_tags`
— so a one-word tag typed into the admin listing form is dropped on save too.
That silent drop is intended; the advisory panel names it.

Two consequences worth knowing. A one-word segment of a `topic` now yields
nothing at all (`topic_tags("core words / feelings")` → `["core words"]`), since
there is no legal tag to make from it. And the pools trade brand voice for
search: tags say `nonverbal child`, description prose keeps `nonspeaking`. Etsy
tags are a search index, not a brand surface — that split is approved, not an
inconsistency to fix.

**The head term always leads the title; the board name is always the
qualifier.** `ListingCopy#title` used to open on the board's own name, on the
reasoning that buyers search "core words board" rather than "SpeakAnyWay". That
holds only when the board name is itself a search term. Every zero-view listing
in the same analysis was a niche noun — "Recess", "Haircut", "Potty" — placed in
front of the phrase buyers actually type, so the title opened on a word nobody
searches. There is no conditional: the product phrase leads, always.

The single exception is folding, not reordering — a board whose name already
contains a product word ("Core Words Board") folds INTO the head as
`"AAC Core Words Board"` rather than being repeated after
`"AAC Communication Board Printable"`. The widest-first candidate ladder and its
guaranteed-fitting last rung are unchanged and still load-bearing:
`pick_fitting_title` truncates mid-word when every rung overflows, which is how
a listing shipped titled `"… Printable for Speech The (Digital Download)"`. The
last rung is now a fixed phrase rather than the board name, because the folded
head can itself be arbitrarily long.

**`Etsy::CopyAdvisories` renders beside the overlap warning and is equally
advisory.** Three checks — fewer than 13 tags, any single-word tag still stored
from before the rule, and no "AAC" in the title's first 40 characters. Never a
gate: each has legitimate exceptions only an admin can judge, and a listing that
can't be published is worse than one published with twelve tags.

Seven listings were hand-rewritten to this shape on 2026-08-20 and are live. Do
NOT run `regenerate_listing_copy!` against them — it merges generated copy over
the stored hash, overwriting hand-tuned title, summary, description and tags:
`4554491916 4557544635 4556388009 4554121725 4554595592 4559346650 4556507027`.

**The tag pools describe the product LAST unless something stops them.** The
generic pools — always-on, product-type, audience, top-up — can fill all 13 of
Etsy's slots on their own, and when `topic` was consulted after them that is
exactly what happened: nine printables published Aug 11–15 2026 shipped
byte-identical 13-tag sets, none of which named the product. Etsy caps how many
of one shop's results appear per query, so they competed with each other rather
than reaching buyers. Two things hold the fix in place, and both must stay:
`topic` ranks straight after `always_on`, and it has a source even when nobody
typed one (`ListingCopy#topic_source` mines the sub-board names). The
`Etsy::TagOverlap` warning on the printable's admin page is the backstop — it is
advisory on purpose, since three sizes of one product genuinely share tags.

**A topic has to yield at least `TagOverlap::MIN_TOPIC_TAGS` (4) tags to clear
that warning, and the number is arithmetic, not taste.** Every pool but `topic`
is shared boilerplate, and whatever slots the topic leaves empty are filled from
the same ORDERED `top_up` list — so a short topic collides twice over. Two
listings differing only in topic share `TAG_MAX - t` tags for `t` topic tags
each, which puts a three-phrase topic at exactly the 10 the warning fires on.
`MIN_TOPIC_TAGS` is derived from `TAG_MAX` and `HIGH_OVERLAP` rather than
written down, because the admin hint quotes it — moving either constant must not
leave the form telling an admin a stale number.

**`topic` is editable after creation.** The listing form writes the column, and
`BoardPrintable#regenerate_listing_copy!` behind a confirmed POST re-runs
`ListingCopy` over it. It has to be: `ListingCopy` is deterministic and reads
`topic` only when it runs, so a listing generated before anyone typed one keeps
the boilerplate tags forever otherwise. Three rules hold it together — saving
the topic deliberately does NOT rewrite the copy (the copy is hand-edited before
publishing, so rebuilding it is a separate action with its own confirm);
regenerating KEEPS `price_cents`, which isn't topic-derived at all (the
generator emits a constant, so it would silently reset a chosen price); and it
merges over the stored hash rather than replacing it, so a key the generator
doesn't emit survives. It is local — a published printable's live listing is
unchanged until the copy is pushed with the printables CLI.

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

`Boards::Printables::RenderListingImages` renders **ten** square 2560px slides
through `layouts/listing_image.html.erb` — a marketing canvas of its own, not
the print sheet. `LISTING_IMAGE_ORDER` is the Etsy rank order, and rank 1 is the
search thumbnail.

| Rank | Slide | Board-specific? | Ported from (`speakanyway-printables`) |
|---|---|---|---|
| 1 | `on_paper` | yes — the printed page warped onto a photographed room | step 14 (`kind: "paper"` scenes) |
| 2 | `hero` | yes — real page thumbnails fanned on a room background, with the bundle sticker | `previews/hero-board.*` |
| 3 | `on_a_device` | yes — the root board, in the app's chrome, warped onto a photographed tablet | step 14 + `previews/content-mock-app.*` |
| 4 | `flip_book` | yes — the root page opening two subpages, each with its back marker | — |
| 5 | `whats_included` | yes — capped thumbnail grid of the colour pages, with a low-ink page inset | `previews/whats-included.*` |
| 6 | `on_paper_alt` | yes — a second room, a second page | step 14 |
| 7 | `assemble` | no — print, trim, hole-punch & ring, scan | — |
| 8 | `on_a_device_alt` | yes — a second tablet, a page that isn't the front one | step 14 |
| 9 | `page_index` | yes — every board named, in tree order | — |
| 10 | `about` | no | `plugins/aac/.../about-saw.*` (founder half) |

### Ten is Etsy's cap, so the gallery is full

This list used to be nine, leaving a slot free for something hand-made uploaded
in the seller UI. That slot is deliberately spent on the second paper mockup.
**Anything added from here has to displace something**, and the two things
displaced so far are worth recording because both were removed for the same
reason — a buyer flicking through was shown the same slide twice:

- `how_it_works` — a four-step strip that shared three of its four inline-SVG
  icons (print / cut / scan-to-hear) with `assemble`.
- `whats_included_low_ink` — the identical thumbnail grid rendered a second time
  with `hide_colors`. The claim it existed to prove ("there's a low-ink version")
  is now **one** pale page inset into the colour slide, which costs one Grover
  render instead of up to eight.

Both survive as constants on `BoardPrintable` beside `IMAGE_COVER`, purely so
the strings stay searchable. Nothing matches on them: `purge_legacy_listing_images!`,
`listing_images_view` and `listing_images_current?` all test "not in
`LISTING_IMAGE_ORDER`", so a variant retired later is caught with no code change.

The listing VIDEO is a separate slot and does not count against the ten.

### Rank 1 is a photograph, not board art

In the shop's 2026-06-08 audit the listings led by a photograph of the product in
a real room rated "Strong" and the ones led by flat board art rated "OK/Weak" —
which is why the pipeline puts a mockup at rank 1 and why Rails now does too.
Mockups and content slides alternate the whole way down for the same reason:
four consecutive renders of the same boards read as one product photographed four
times. `render_listing_images_spec.rb` asserts no two mockups are adjacent rather
than pinning the literal order, so the ranks can be retuned without rewriting it.

### No slide may be conditional on board count

`listing_images_current?` requires EVERY variant in `LISTING_IMAGE_ORDER`, so a
slide skipped for a single-board printable would leave that printable
permanently stale, permanently badged in the admin, and re-rendering its whole
gallery on every publish. Where a slide means something different for one board,
its **copy** varies (`Printables::SlideCopy`) and the variant is still rendered:
`flip_book` becomes "one page — and the QR turns it into a talking board",
`page_index` becomes "what's on this board", and the `_alt` mockups fall back to
the root page rather than disappearing.

Adding to that constant makes every existing printable stale. That is the point:
it is what surfaces the admin badge and forces a re-render before publishing.

### The flip-book angle

The three slides added in Aug 2026 (`flip_book`, `assemble`, `page_index`) all
serve one claim: **a printable is a bundle of LINKED pages**. Folder tiles open
sub-pages and every sub-page carries a way back — `Boards::BackTileStamper`
guarantees it, every page carries its own QR, and none of it was said anywhere a
buyer looks. `flip_book` stays in the gallery's first half, ahead of every slide
that merely describes a product the buyer has already decided to look at,
because it is the one claim no competing AAC printable can make.

**Rails is authoritative for listings the Rails admin originates**; the pipeline
is authoritative for the ones its own steps 11/13/14 originate. Same rule, and
the same drift hazard, as `Etsy::CopyRules` above.

### The mockups

Four of the ten slides are photoreal composites, and all four render the same
template (`listing/mockup.html.erb`) through the same maths. A composite is an
AI-generated photograph containing a **blank white placeholder**, with a real
render warped onto that placeholder's four hand-clicked corners. Nothing is fed
to an image model at render time and nothing is composited pixel-wise: the warp
is a CSS `matrix3d` and the screenshot is the same Grover call every other slide
makes.

The scene library is vendored from `speakanyway-printables`
(`src/plugins/aac/templates/assets/mockup-scenes/`), which is where the photos
were generated and where the quads were clicked out in that repo's
`calibrate-mockup-scene.html`. Rails carries the eight `category: "board"`
scenes — four `kind: "tablet"` and six `kind: "paper"` — and none of the eleven
that stage products this app doesn't make (ID cards, device tags, stickers,
tattoos).

`Boards::Printables::MockupScene` is the geometry (cover placement, the
letterbox rectangle, the homography); `TabletScene` and `PaperScene` are only the
lists. `Boards::Printables::Homography` is a straight port of that repo's
`homography.ts` (Gaussian elimination, then the 3x3 embedded column-major into a
CSS `matrix3d`). Unlike the copy rules, this one is fixed maths — a divergence
here is a bug, not a decision.

**The quads are copied, not re-measured.** Re-deriving them by eye puts the
render a few pixels off the glass, or off the paper. The two Canva-exported
tablet scenes are the exception and were fitted here — by WARPING A BLOCK ONTO
THE PHOTO AND LOOKING, never by drawing the quad flat on it. The warp composes
the quad with the slide's cover-placement transform, so an error invisible on the
flat photo is 20–40px of someone else's wallpaper showing along an edge once the
board is on the glass. Both fitted quads land at 4:3, which is the check that the
numbers are right — that is a real iPad screen.

**Both tablet quads sit a few pixels proud of the glass on purpose.** Each
photo's screen already shows something, and a flush quad leaves a sliver of it
visible, which reads as a rendering fault; bleeding onto the bezel reads as the
screen's edge.

**Each pair stages a different scene, and where it can, a different page.**
`StablePick.top` returns a ranked slice rather than just the winner, so the two
picks are deterministic and distinct — rendezvous hashing ranks as well as
maximises, so appending a scene still moves the minimum rather than reshuffling
what already resolved. The salts (`"tablet"`, `"paper"`, and the separate ones
for `BrandAssets::SCENES` and `Palette::PALETTES`) must stay independent:
hashing the same key twice would pair scene 1 with palette 1 forever and collapse
the rotation. **The slug is the load-bearing thing** — renaming one re-skins the
boards that had picked it; reordering the list does nothing.

**Paper scenes are filtered by ORIENTATION before anything is picked.** A
homography maps *any* rectangle onto the quad, so a landscape page handed to the
portrait clipboard does not fail — it silently stretches, which a buyer reads as
a distorted product. The landscape pool is four and the portrait pool is two, and
`PaperScene::MIN_POOL` is asserted against both so deleting a scene can't quietly
leave a pool too small for two distinct picks. The pools are disjoint, which is
what lets a mixed-orientation set take its second pick from the other pool
without either knowing what the first one took. `paper_scene_spec.rb` also checks
each quad's own aspect agrees with the orientation it declares — a scene filed
under the wrong one is a filter that lies.

**The artwork element fills the whole quad in white, and the render is
letterboxed inside it.** On a tablet that white is the shell's own background; on
paper it is doing real work, because the placeholder in the photo *is* a blank
white sheet — so a letterbox bar reads as that sheet's own margin rather than as
a gap where the mockup shows through. That is what lets a 1.97-aspect quad like
`kid-table-crayons` carry a 1.29-aspect Letter page without either stretching it
or exposing the placeholder.

**What sits on the glass is the app; what sits on the paper is the printed page.**
`Boards::Printables::RenderDeviceScreen` wraps the board in SpeakAnyWay's own
chrome — board name, nav, empty speech bar, play/clear/download — and *that*
screenshot is what the tablets warp. A bare printed page there reads as a
photograph of a printout taped to a tablet, and carries nothing saying the thing
on screen talks; the print header would put a scan-me band and a second QR on the
glass. The paper slides want the exact opposite and take the **header-shown**
thumbnail the hero already rendered, because their whole claim is that the sheet
itself carries the code. That also keeps the QR honest for free: those thumbnails
encode the bare `/pb/<slug>` the printed page does, never the UTM-tagged listing
URL. Never route a paper mockup through `listing_target_url_for`.

Two constraints on the shell:

- **It is sized from the scene**, at a constant total area
  (`RenderDeviceScreen::SHELL_AREA`). The homography stretches the artwork onto
  the quad whatever shape it is, so a shell at another aspect arrives visibly
  squashed. It used to be a fixed 1100x720 (~1.528) — the mean of the only two
  scenes that existed — and the photographed scenes added since are 4:3, so a
  fixed shell was one scene away from being wrong for most of the library.
- **The board image is the header-less thumbnail** the what's-included grid
  already rendered, so the slide costs one extra Grover render, not two. A board
  too tall for the shell is top-anchored and clipped — that's what a real screen
  with more board below the fold looks like — and a short wide one is centred.

**Everything inside `.mockup-stage` lays out in the scene's own pixels**, and the
stage as a whole is scaled and offset to cover the slide. `object-fit: cover` on
the photo would move it without telling anything where the corners went, which is
why `MockupScene#cover_placement` computes the placement itself.

**That placement centres the QUAD, not the photo.** Every scene is a landscape
photo and the slide is square, so cover throws away a quarter of the width — and
no placeholder is centred in its own frame. Centring the scene sliced the left
edge off the fridge sheet and ran the desk tablet off the right, both of which
read as a rendering fault rather than as a crop. The offsets are then clamped so
the photo still reaches both edges, and a quad too wide to fit even centred
(`kid-table-crayons`) is cropped evenly on both sides, which reads as a
deliberate close-up. The scene specs assert the evenness rather than the
offsets, so a scene added later is checked by the same rule.

**The mockup slides carry their audio badge in the FOOTER**, not under the title
banner where every other slide puts it. On these four the artwork is the whole
slide and its top edge moves with the scene, so the badge landed across the
printed page's own header — the single thing a paper slide exists to show — and
across the app's board title on the angled tablet. The footer strip is a solid
band, so nothing placed there can be obscured whatever the scene does.

The only thing that differs by kind is the finish: `.mockup-art.kind-tablet` gets
a faint diagonal glare so the board reads as a lit display, and
`.mockup-art.kind-paper` gets the pipeline's own drop-shadow value so the sheet
reads as an object sitting on something. On paper the glare reads as a crease.

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
- **The hero and the paper mockups keep the page header; the grids and the
  tablets don't.** The printed QR lives inside that header
  (`api/boards/print.html.erb`), and both those slides claim that the sheet
  itself carries the code. On a grid tile at a sixth the size the header is just
  the slide's own title band again, so `hide_header: true` gives the board the
  whole tile; on the tablet it would be the tell that the screen is really a
  photographed printout.
- **The root board sits in the MIDDLE of the hero fan, not first.**
  `.hero-stage.fan` draws the middle card in front and unrotated, so the middle
  slot — not the first — is what a buyer sees in the Etsy search grid. Board ids
  arrive in tree order, which put the root in the rotated back card and promoted
  whichever subboard came second: a keyboard page, or a sparse fringe page.
  `RenderListingImages#hero_tiles` moves the root into the centre slot after the
  failed renders are dropped, so a subboard that failed to render can't shift it
  back off centre.
- **Thumbnails are trimmed by measurement, not calculation.** How much of a
  Letter sheet a board fills depends on its shape; a 12x3 grid leaves over half
  the page blank and reads as a broken image. The header renders ~24mm against
  the 30mm `RenderAssetData` reserves, and a tall board is clamped by
  `.board-sizer`'s max-height — both errors run in the direction that slices
  tiles off, so the trim scans up from the bottom for the last non-background
  row instead.
- **Each page variant renders once.** Planning (`ContentTilePlan`, capped at
  `MAX_TILES`) happens first so Grover is only paid for tiles that get shown,
  and the passes are memoized: colour-with-header for the hero and both paper
  mockups, colour without a header for the grid and both tablets, and ONE page
  in low-ink for the what's-included inset. Budget:
  `min(boards, 3) + min(boards, 8) + 1` page renders plus ten slides and two
  device screens — which is fewer than the nine-slide gallery cost, because the
  low-ink pass shrank from a whole second grid to a single page. Still tens of
  seconds for an eight-board set, which is why this is a Sidekiq job and never a
  request thread. A further pass means a slide is re-rendering pixels it already
  had — every mockup deliberately reuses a thumbnail some other slide paid for.

Etsy will create a listing with no photos but won't let it go live without one,
so `PublishBoardPrintable` renders them when they aren't current.

**`listing_images?` is not a strong enough guard — use `listing_images_current?`.**
A printable generated before a gallery change still has images — the retired
`cover`/`whats_included` pair, or any earlier gallery from before a slide was
added. `LISTING_IMAGE_ORDER` is the whole definition of "current", so adding a
variant to it is what makes every older printable stale. Four things stop a
stale image reaching a live listing:
`listing_images_view` filters to known variants, `purge_legacy_listing_images!`
removes them after a successful re-render, the publish guard checks currency,
and the admin card shows a staleness badge. Bulk refresh:
`rake printables:refresh_listing_images`.

Images are written to a **versioned** blob key. CloudFront ignores query
strings, so re-uploading to a stable key leaves the admin looking at the
previous render (same lesson as `Boards::GeneratePreviewAssets`). The same rule
applies to the PDFs — see below.

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

What it deliberately does NOT touch: `listing_copy`, the listing rows, and the
gallery images. Clearing reviewed copy, or the pointer to a live Etsy draft,
would be a worse surprise than stale marketing images — which the existing
**Regenerate** button on the listing-images card re-renders. The redirect notice
says so.

**Every re-run writes the PDFs to a fresh versioned key**
(`board_printables/<id>/<hex>/<filename>`), for exactly the reason the listing
images do: production serves these as `CDN_HOST + blob.key` and CloudFront
caches by path, so re-uploading the regenerated document onto the deterministic
key made **Regenerate a no-op from the outside** — the admin kept downloading
the pre-edit PDF. The version sits in the key PATH, not the filename: the
filename is the product's download name on a marketplace, and a buyer should not
receive `core-words-9f2a.pdf`.

Because the key moves every run, `BoardPrintable#purge_stale_pdfs!` — which
`Generate` calls with the keys it just wrote — is now the only thing that
removes the superseded document, not just the odd orphan from a renamed board or
a grown tree. It runs **after** the new files are attached, same rule as the
listing images, so a failed re-render leaves the previous downloads in place
rather than emptying the record.

`DELETE /admin/board_printables/:id` destroys the record; Active Storage purges
its PDFs and images with it. It cannot touch Etsy — this app implements no
listing update or delete call — so the confirm dialog names the surviving draft
id when one exists (`Admin::BoardPrintablesHelper#board_printable_delete_confirm`).
The dialog also says how many boards will stop being protected, because this
record is what freezes them (below).

## Listed boards are protected

Once a printable has reached Etsy — any listing row of its own, current or
superseded — every board it was rendered from is frozen: **deleting, unpublishing and renaming are refused; structural tile edits
need an explicit confirm.** `Boards::MarketplaceProtection` is the single
authority; `Board#marketplace_protected?` delegates to it.

**Protection covers the whole printed tree, not the printable's root board.**
The scope matches `board_printables.board_ids` (a jsonb array of integers, GIN
indexed, matched with `@>`) unioned with `board_id`. Every interior page of a
set carries its own QR pointing at its own `/pb/<slug>`, so deleting page 4 of a
twelve-page set breaks the product exactly as badly as deleting the root. The
`board_id` half of the union is belt-and-braces for a printable that failed
before `Generate` wrote `board_ids`. Note the ids are **integers** — a string in
that array silently matches nothing and every interior page quietly loses its
protection.

**Why "ever reached Etsy" and not a listing state.** The obvious design is a
`draft / active / ended` column so an ended listing releases its boards. It
models the wrong fact. What protection defends is a printed sheet with a QR on
it, and ending an Etsy listing doesn't recall a laminated board off a fridge.
The column would also be hand-maintained against a shop this app cannot read,
and its one drift mode is the unsafe one: you end a listing, forget to flip the
column, and the boards unprotect while the paper is still live. Release is
therefore an explicit act — `BoardPrintable#waive_protection!`, stamped with who
and when — not an inferred state. Equally, protection does **not** key on the
printable merely existing: generating one to look at it is the normal way to use
the admin, and locking a board every time would make the feature something to
avoid.

**Hard blocks vs confirm.** Deleting, unpublishing and renaming are refused
outright — no request param clears them, only the waiver. Structural tile edits
(layout, columns, adding/removing tiles, colors, tile art) return
`board_marketplace_edit_confirmation_required` once and proceed on
`confirm_marketplace_edit=true`. That param is deliberately not `confirm`, which
`#update` already means "yes, cascade the publish" by — one click must not
authorize the other thing. Reads, PDF exports and audio are never gated.

Both refusals are **409**, alongside the existing `board_in_use` and
`publish_cascade_confirmation_required`. Protection is checked **before**
`Boards::UsageCheck`: `board_in_use` is confirmable and this is not, so
answering with the confirmable one first would teach the client to retry into a
wall. Cascades (`delete_subboards=true`, a builder `BoardGroup`, an unpublish
cascade) are pre-checked and refused **whole** — skipping the protected member
would delete its parent and leave it behind with a folder tile pointing at
nothing, which is the corruption this exists to prevent. `Boards::PublishCascade`
needs its own pre-check because `#apply!` writes with `update_all`, which skips
callbacks entirely.

The model guard (`Board#block_marketplace_protected_destroy`, `prepend: true`)
**raises** rather than `throw :abort`, because the cascades that can reach a
protected board ignore a false return — `BoardGroup` uses `destroy_all`,
`Admin::BoardBuildsController` uses `reverse_each(&:destroy)`. Aborting there
would destroy the group and leave the protected board orphaned, which is worse
than the deletion. `prepend: true` matters too: without it every `dependent:
:destroy` cascade runs and is rolled back to reach the same refusal.
`Board#destroy_despite_marketplace_protection!` is a console/rake hatch and is
never wired to a request param.

`Board#rename_slug!` — the deliberate-rename hatch behind the internal API's
`force_slug` and the `boards:rename_slug` rake task — raises on a protected
board unless `allow_marketplace_protected_change` is also set. It is exactly the
hatch that would silently 404 printed paper. `freeze_published_slug` still
**reverts** rather than raising on the ordinary path, because the frontend
re-derives the slug from the name on every rename; don't convert it.

## Storage layout

`BoardPrintable#files` holds all three kinds of blob, separated by blob metadata
`kind` (`pdf` / `image` / `video`) rather than by separate attachments — the
PNGs arrived long after the PDFs and re-homing the existing ones would have
churned every stored key. **A blob with no `kind` is a PDF** (that's every blob
written before this existed).

**`pdf_files` is an ALLOWLIST (`KIND_DOWNLOADABLE`) and must stay one.** It used
to select by exclusion (`kind != KIND_IMAGE`), which was correct only while "not
an image" and "is a PDF" meant the same thing. The moment a third kind existed
the video read as a PDF everywhere the partition is used: `files_view` would
hand it to a buyer, `upload_files` would send it to Etsy as `application/pdf`
against the five-file cap, and — silently, which is the one that matters —
`purge_stale_pdfs!` would DELETE it on every "Regenerate", since `Generate`
passes only the keys of the PDFs it just wrote.

`files_view` is PDFs only, on purpose: the admin download buttons and the
`/api/board_printables/:id/download_url` contract both read it, and neither
should start handing out marketing art. `listing_images_view` is the images, in
Etsy rank order; `listing_video_view` is separate again.

## The listing video

`Boards::Printables::RenderListingVideo` builds a **flip-through**: an intro
card, one frame per printed page in tree order (root first, capped at
`MAX_PAGE_FRAMES = 8` to match `ContentTilePlan::MAX_TILES`), then a QR outro
showing the same board open in the app. Frames are Grover-rendered 1080-square
cards — the page thumbnails are already data URIs, and every brand element is
already CSS in the shared layout, so an ffmpeg filter graph would be rebuilding
both.

Etsy's rules: 5–15 seconds, ≤100 MB, ≥500px (1080×1080 recommended), **one
video per listing**, and **Etsy strips the audio** — so the clip carries
everything visually and nothing here encodes an audio stream. Scope `listings_w`
covers `POST /shops/:shop_id/listings/:id/videos`, and this app's grant already
holds it.

Three rails:

- **Duration is a pure function** (`.plan_seconds`), specced across every board
  count the admin allows, and the encoded file's real duration is measured again
  before it is attached. Etsy rejects an out-of-spec video at ACTIVATION time in
  the seller UI, a long way from anything that explains why.
- **Do NOT use the ffmpeg concat demuxer.** It is the obvious tool and its
  timing does not survive contact with still images: measured against ffmpeg
  8.1, frames of 1s/2s/4s produced a 5s clip, and the widely-repeated "repeat
  the last file" workaround produced 11s. `VideoTranscoder.encode_still_sequence`
  uses one looped input per frame plus a concat FILTER, which reproduces the
  plan to within a frame. `spec/services/video_transcoder_encode_spec.rb` runs
  ffmpeg for real because no stubbed spec can catch a wrong duration.
- **Publishing never renders it.** The gallery is auto-rendered at publish
  because Etsy won't let a listing with zero photos go live; there is no
  equivalent rule for video, and ten Grover renders plus an ffmpeg encode inside
  a `retry: 0` job is a way to wedge a publish half-done in a real shop. Render
  from the admin first, or the draft goes up without one. A failed video upload
  records itself on `etsy_error` and does **not** fail the publish.

Staleness lives in blob metadata (`spec_version` + `board_count`), so there is
no migration; bump `BoardPrintable::VIDEO_SPEC_VERSION` to force a fleet-wide
re-render. A hand-uploaded clip (`VIDEO_MANUAL`, the admin's "Upload instead"
field) is never stale — nothing could re-render it.

### Sending a video to a listing that already exists

Publishing carries the video with it, so a listing created before its video was
rendered can never get one from the publish path again. `POST push_video` on
that listing's row (`Etsy::PushListingVideo`) is the way in, and it is **not** a hole in the
drafts-only rule: adding a video to a listing that has none is an additive POST,
the same class of call as `upload_image` and `upload_file`, which have always run
against listings. No state, no title, no tags, and still no call anywhere that
activates a listing or deletes anything from one.

The gallery deliberately does **not** get the same treatment. Replacing photos
means deleting the ones already on the listing, and a DELETE against a live
listing is exactly what the drafts-only invariant keeps out — that path stays in
`speakanyway-printables` (below).

**The hazard is Etsy's one-video-per-listing rule, and the guard is local
memory.** This app cannot read a listing back — `Etsy::Client` implements no list
or delete counterpart for videos on purpose — so it can't discover a video that
is already there, and a second POST has no outcome it could verify.
`board_printable_listings.video_pushed_at` is the only thing that makes the
second push refusable. It is **per row** because Etsy's rule is per listing: the
same clip going to a printable's standalone AND its bundle is correct, and the
old printable-wide stamp refused the second. Three rails hold it:

- **The publish path stamps it too.** A draft born with a video would otherwise
  be offered another one by the admin control.
- **A failed upload does not stamp it.** Writing it on failure would lock a
  listing out of ever getting its video.
- **Nothing clears it.** A replacement is a *different row* whose stamp is nil
  by construction, and the superseded row keeps the true record of what its own
  draft received.

Once a video has gone, replacing it needs Etsy's `video_id` form field — an
update call this app does not have — so the control retires itself and names the
seller UI instead.

## Backfilling listings made before the current gallery and video

Two admin rake tasks, for the population of listings that went up before a slide
or the video slot existed:

- `rake printables:render_listing_videos` — enqueues a flip-through for every
  complete printable whose `listing_video_current?` is false, which covers both
  "has none" and "has one from a different version of this printable". A
  hand-uploaded clip reports current and is skipped: nothing could re-render it.
  `PUBLISHED_ONLY=1` narrows to printables that have a listing row which reached
  Etsy. It
  aborts rather than enqueueing when ffmpeg is missing, because the job checks
  too and would return immediately — which looks exactly like the task having
  worked.
- `rake 'printables:export_listing[<id>]'` — writes one folder **per attached
  listing** (`<out>/<printable_id>/<etsy_listing_id>/`), holding that listing's
  gallery images (in `LISTING_IMAGE_ORDER`, which is what decides Etsy's ranks)
  plus a `listing.json` of its resolved copy, for `npm run etsy -- update
  <listingId> ./listing.json --replace-images` in `speakanyway-printables`.
  Read-only; with no id it exports every attached listing.

**The export is how a LIVE listing's tags and photos get fixed**, and the split
is deliberate: that repo already owns and tests delete-then-reupload, and
importing it here would mean adding the delete call this app pointedly lacks.

Two keys are absent from the generated config, and adding either is a behaviour
change rather than a convenience: **`state`**, because writing `"active"` there
would be this app activating a listing; and **`files`**, so `--replace-files`
can't be pointed at an export that never intended it — replacing downloads
deletes the buyer's files first, and a backfill of marketing assets has no
business touching them. A printable whose gallery isn't current is refused
outright rather than warned about: `--replace-images` deletes before it uploads,
so a partial gallery would take ten good images off and put five back.

## Several listings per printable

A printable carries **`board_printable_listings`** rows — one per Etsy listing.
A standalone listing and a bundle listing can sell the same rendered document
with different copy, a different gallery selection, a different subset of the
PDFs and their own clip. Before this table the listing WAS four scalar columns
on `board_printables`, so a printable could hold one listing at a time.

The row is three things at once, and each one matters:

**A publish token.** The admin allocates a row (`state: "pending"`) before
anything touches Etsy. `Admin::BoardPrintableListingsController#publish` then
compare-and-sets it:

```ruby
BoardPrintableListing
  .where(id: listing.id, state: %w[pending failed], etsy_listing_id: nil)
  .update_all(state: "publishing", claimed_at: Time.current, ...)
```

`update_all` returns the affected row count and Postgres orders it under the row
lock, so a double-click has exactly one winner and only the winner enqueues.
The claim lives in the **request thread** on purpose: Sidekiq guarantees no
ordering, so two enqueued jobs could both read `pending` before either wrote.
The job re-checks `state == "publishing"` — that gates the WORK, where the claim
gates the ENQUEUE, and both are needed for different races. Neither closes the
non-transactional window between `create_listing` returning and the id landing
in Postgres; only `retry: 0` does, and it stays.

**A record of a draft in a real shop.** `Etsy::PublishBoardPrintableListing`
persists `etsy_listing_id` the INSTANT Etsy hands it back — before the price,
the images, the files or the video. The old code wrote it only after every
upload succeeded, so an exception in `upload_images` left a real draft in a real
shop with nothing pointing at it. A half-uploaded draft is now
`#assets_incomplete?` (`published_at` set, `assets_uploaded_at` nil) and says so
on its card. That state is deliberately **not** retryable from the admin: a
re-run would upload against a draft that already has some of them.

**Permanent.** Detaching calls `#supersede!`, which sets `superseded_at` and
**keeps** the listing id. The app implements no delete call, so the row is the
only record of which draft an operator has to go and remove — the old
`#relist!` NULLed it and left the draft unfindable. A row that reached Etsy is
therefore never deletable from the admin; only a `pending` or `failed` one is.
"Replace" is the one-click version of what "Detach & relist" used to be:
supersede, then create a fresh row carrying the same purpose, label and
overrides.

Replacing a **gallery** still needs a new listing, for the original reason —
this app creates listings and implements no call that updates one, so photos
cannot be swapped in place. A **video** remains the exception, because adding
one is additive rather than an update.

### Two published-states, and they must not be collapsed

| Predicate | Reads | Means | Cleared by detaching? |
|---|---|---|---|
| `BoardPrintableListing#attached?` | `etsy_listing_id` && no `superseded_at` | that row has a draft right now | **yes** |
| `BoardPrintableListing#reached_etsy?` | `etsy_listing_id` **OR** `published_at` | that row made a draft at some point | never |
| `BoardPrintable#etsy_ever_published?` | the watermark, the legacy id, **OR** any row that reached Etsy | this printable was sold at least once | never |

`etsy_published_at` survives as a **write-once watermark** and is never moved by
a later listing. It is not a fact about a listing; it is "these boards have been
printed and sold", which is what protection defends. Keeping it makes the
protection predicate strictly wider than the one it replaced, so a backfill that
missed a row cannot unfreeze printed paper.

### Marketplace protection reads every listing, ever

`Boards::MarketplaceProtection::PROTECTING_SQL` is the watermark, OR the legacy
scalar id, OR an `EXISTS` over listing rows that reached Etsy. Four deliberate
omissions, each commented in the file:

- **no `superseded_at` filter** — a detached listing still protects; replacing a
  draft doesn't un-print paper;
- **no `state` filter** — a `pending` or `failed` row has neither an id nor a
  `published_at`, so allocating a listing you never publish locks nothing;
- **the watermark half stays**, so this can only over-protect;
- **no new index** — `[board_printable_id, state]`'s prefix serves the subquery.

`PROTECTING_SQL` and `BoardPrintable#etsy_ever_published?` ask the same question
of many rows and one row, and must not diverge. Everything protection-facing —
the waiver, the delete confirm, the release confirm, the protection block in
`_etsy` — sits outside the attached/detached branch, since a printable with no
live listing still freezes its boards and would otherwise lose the control that
releases them.

The API payload keeps `etsy_listing_id` / `etsy_listing_url` per printable (the
frontend's `MarketplacePrintable` contract) reporting the **primary** listing,
and adds an `etsy_listings` array beside them.

### Per-listing assets are allowlists

Every partition is an **allowlist over the printable's shared set**, empty
meaning "all of them" — never an exclusion. Same rule `pdf_files` holds, and for
the same reason: selecting by "not the thing I don't want" was correct only
while there were two kinds of blob.

| Column | Over | Note |
|---|---|---|
| `listing_copy` | the printable's `listing_copy` | overrides only; blanks dropped so a cleared field falls back rather than publishing an empty title |
| `image_variants` | `LISTING_IMAGE_ORDER` | rank 1 is Etsy's search thumbnail, so order is fixed regardless of selection |
| `pdf_variants` | `BoardPrintable#pdf_files` | **intersected**, never a fresh selection over `files` — that is what keeps a gallery image or the video out of a buyer's download. Variants, not ActiveStorage keys: a key is versioned per run, so a key allowlist empties itself on the first Regenerate |

Blobs rendered for one listing are stamped `listing_id` in metadata; a blob with
no `listing_id` is the shared set every listing inherits. The purges in
`#attach_image!` / `#attach_video!` are scoped the same way — they used to match
on variant alone, which would have meant rendering one listing's hero deleted
the shared one.

`RenderListingImages` builds every slide from the **boards and the topic**,
never from `listing_copy`, so two listings with the same topic render identical
images. `topic_override` is therefore the only lever that makes a per-listing
gallery mean anything, and a listing carrying one is treated as **stale** until
it has slides of its own — otherwise it would inherit the shared gallery and the
override would silently do nothing.

`etsy.video_pushed_at` moved onto the row because **Etsy's one-video rule is per
listing**: the same clip going to a printable's standalone AND its bundle is
correct, and the old printable-wide stamp refused the second. The row-scoped
stamp still refuses a second POST at the same listing, which is the thing this
app genuinely cannot verify.

`Etsy::TagOverlap` compares sibling listings on the same printable as well as
other printables — two listings for one product share every tag but the topic
ones by construction, and Etsy caps how many of one shop's results appear per
query, so a bundle can bury its own standalone.

## Publishing is never retried

`PublishBoardPrintableListingJob` is `retry: 0`. A retry after a partial success
creates a **second draft in a real shop**, and nothing downstream would notice.
A failure records itself on `board_printable_listings.error`, shows on the
listing's card, and waits for a human — a half-built draft is easy to delete, a
duplicate is easy to miss. For the same reason, a listing row that already has
an `etsy_listing_id` refuses to publish again. The claim makes this *look* safe
to retry; it is not.

A row wedged in `publishing` (a worker killed between the claim and any write)
is **not** auto-recovered — a timeout-based reset is a duplicate-draft
generator, and this app cannot read a listing back to find out what happened.
The card shows `claimed_at`, and
`rake 'printables:reset_stuck_listing[<row_id>]'` refuses unless
`CONFIRMED_SHOP_CHECKED=1`.

`rake printables:listings` is the read-only inventory to reconcile against the
shop.

## Teachers Pay Teachers

TPT has **no seller API**. `Printables::MarketplaceCopy#tpt_fields` lays the copy
out field by field in the order TPT's upload form asks for it, each with a
copy-to-clipboard button. Note TPT's title cap is 100, not Etsy's 140, and the
`(Digital Download)` suffix is stripped — it reads as spam there.

The subject / grade / resource-type values are defaults picked from TPT's fixed
taxonomy, not rules. Standards is deliberately left blank: AAC vocabulary boards
don't map cleanly to CCSS and a guess is worse than an omission.
