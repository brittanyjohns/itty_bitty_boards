# Handoff: Dynamic kit landing pages (backend)

**Date:** 2026-08-19 · **Status:** built — see "As built" at the foot of this doc
**Full plan:** `../drafts/kit-landing-pages-plan.md` (this doc is self-contained; the plan adds context)
**Counterpart:** `../itty-bitty-frontend/.claude-notes/kit-landing-pages-handoff.md` (also built and shipped)
**Issue:** none filed
**Related spokes:** `.claude-notes/board-printables-etsy.md`, `.claude-notes/marketing-integrations.md`,
`.claude-notes/classroom-lead-tag-handoff.md`

## Goal

Back a reusable lead-magnet landing page at `app.speakanyway.com/kit/:slug`. Brittany creates and edits
these pages in `/admin`, picks one of her existing `BoardPrintable` records as the download, and the
page goes live with no deploy.

## Decisions (already made — don't re-litigate)

- Config lives in the **database**, not a frontend config file. New `KitPage` model.
- The download is an existing **`BoardPrintable`** plus a chosen PDF variant. Not `MarketingAsset`,
  not a live `/boards/:id/pdf` render.
- URLs are `/kit/:slug`. `/classroom` and `/ctg` are **not** migrated and must keep working exactly
  as they do now — they're printed on QR codes and campaign emails.
- Leads reuse `DownloadLead` with `source = "kit_<slug>"`. No new lead model, no new table for leads.
- The email gate is soft by design (see "Known constraint" below). Don't try to harden it in this PR.

## Current state

**`DownloadLead`** — `app/models/download_lead.rb`, table at `db/schema.rb:510-521`
(`email`, `name`, `board_id`, `source`, `mailchimp_status`, `data` jsonb). Created anonymously via
`POST /api/download_leads` (`app/controllers/api/download_leads_controller.rb:11` skips auth;
`config/routes.rb:188`). Sources in use: `free_download`, `classroom_kit`, `ctg`, `playground_nomination`.
The model header (lines 6-11) documents that new sources should ride the `data` jsonb rather than add columns.

**Mailchimp tagging** — `app/sidekiq/mailchimp_upsert_lead_job.rb:13-21`:

```ruby
SOURCE_TAGS = {
  "classroom_kit" => "ClassroomKitLead",
  "ctg" => "ctg-2026",
  "playground_nomination" => "PlaygroundNomination",
}.freeze # fallback DEFAULT_LEAD_TAG = "BoardDownloadLead"
```

This frozen hash is the only reason a new landing page currently needs a code change. Work item 4 fixes that.

**`BoardPrintable`** — `app/models/board_printable.rb`, table at `db/schema.rb:227-254`.
- `has_many_attached :files` (line 139); blobs are distinguished by **blob metadata**, not separate
  attachments. `metadata["kind"]` ∈ `"pdf"` / `"image"` / `"video"`, with **nil meaning legacy PDF**.
  `KIND_DOWNLOADABLE = [nil, KIND_PDF]` (line 55) is a deliberate allowlist — read the comment there
  before touching selection logic.
- PDF variants: `DOWNLOAD_VARIANTS` (line 33) = `color`, `low_ink`, `trim_ready`; single-board docs use `full`.
- `files_view` (line 268) returns `[{variant, filename, url, byte_size}]` for PDFs only, and its comment
  states both the admin download buttons and `/api/board_printables/:id/download_url` read it. **Reuse it.**
- `status` is a plain string, not an enum: `STATUSES = %w[pending generating complete failed]` (line 12);
  `complete?` at line 145.
- `protects_board?` (line 407) = `etsy_ever_published? && protection_waived_at.nil?`.

**Existing admin** — `Admin::BoardPrintablesController` (`app/controllers/admin/board_printables_controller.rb`,
routes at `config/routes.rb:107-120`). `Admin::ApplicationController:3` sets `layout "admin"` and
requires `authenticate_user!` + `require_admin!`.

**No CMS model exists.** `app/models/page.rb` is `Page < Profile` (MySpeak), not a content page — don't
confuse the two when naming.

### Known constraint — the gate is soft, don't over-build

`config/storage.yml:9-15` configures the `amazon` service with `public: true`, and
`config/environments/production.rb:54` uses it. `has_many_attached :files` names no service, so every
printable file already sits behind a permanent, unsigned `CDN_HOST/board_printables/<id>/<hex>/<file>.pdf`
URL. The hex path segment is the only protection. Requiring an email before revealing the URL is exactly
what `/classroom` does today and is the intended behavior here. Do **not** move printables to
`amazon_private` or add presigned URLs in this PR.

## Work items

### 1. `KitPage` model + migration

```ruby
create_table :kit_pages do |t|
  t.string  :slug, null: false                 # kebab-case, unique index
  t.string  :title, null: false                # h1
  t.string  :eyebrow                           # pill above the h1, e.g. "Free classroom kit"
  t.text    :subhead
  t.jsonb   :content, null: false, default: {} # see shape below
  t.references :board_printable, foreign_key: true   # nullable until a printable is picked
  t.string  :printable_variant, null: false, default: "color"
  t.string  :mailchimp_tag                     # nil => derived default
  t.string  :cta_label
  t.string  :cta_path
  t.boolean :published, null: false, default: false
  t.datetime :etsy_override_at                 # see item 5
  t.references :etsy_override_by, foreign_key: { to_table: :users }
  t.timestamps
end
add_index :kit_pages, :slug, unique: true
```

`content` jsonb shape — keep it small and validated loosely; this is what the frontend renders:

```json
{
  "items": [{ "title": "Core word poster", "description": "..." }],
  "closing": { "heading": "Make it personal", "body": "...", "cta_label": "...", "cta_path": "/sign-up" }
}
```

Model requirements:
- Slug validated against a kebab format — copy `MarketingAsset::SLUG_FORMAT` (`app/models/marketing_asset.rb`).
- `printable_variant` inclusion in `BoardPrintable::DOWNLOAD_VARIANTS + ["full"]`.
- `lead_source` → `"kit_#{slug}"`.
- `resolved_mailchimp_tag` → `mailchimp_tag.presence || "#{slug.camelize}Lead"` (so `at-school` → `AtSchoolLead`).
- `downloadable?` → `board_printable&.complete? && board_printable.files.attached?`.
- `download_files` → `board_printable.files_view.select { _1[:variant] == printable_variant }`,
  falling back to all of `files_view` if that variant isn't present (a printable may only have `full`).
- Scope `published`.

### 2. Public read endpoint

`GET /api/kit_pages/:slug` → `Api::KitPagesController#show`, `skip_before_action :authenticate_token!`.
Look up by slug among `published`; 404 `{ error: "kit_page_not_found" }` otherwise.

Response — **never include a file URL here**:

```json
{
  "slug": "at-school", "title": "...", "eyebrow": "...", "subhead": "...",
  "content": { ... }, "cta_label": "...", "cta_path": "...",
  "downloadable": true
}
```

`downloadable: false` tells the frontend to hide the form rather than render a broken gate.

### 3. Public download endpoint

`POST /api/kit_pages/:slug/download` → `Api::KitPagesController#download`, auth skipped.

Params: `{ email:, name?, data?: {} }` (`data` carries UTM, same as `/classroom`).

Behavior:
1. Find the published page; 404 if missing.
2. 422 `{ error: "not_available" }` unless `downloadable?`.
3. Create a `DownloadLead` with `source: page.lead_source`, `email`, `name`, `data` merged with
   `{ "kit_slug" => page.slug }`. On validation failure return `422 { errors: [...] }` matching the shape
   `Api::DownloadLeadsController` already returns — the frontend surfaces `errors[0]` inline.
4. Return `200 { files: page.download_files }`.

Routes, inside `namespace :api` alongside the other public routes near `config/routes.rb:183-188`:

```ruby
resources :kit_pages, only: [:show], param: :slug do
  member { post :download }
end
```

Watch route ordering — put these with the other `public_*` flat routes, not inside an authenticated block.

### 4. Dynamic Mailchimp tag (the "no deploy per page" piece)

In `app/sidekiq/mailchimp_upsert_lead_job.rb`, keep `SOURCE_TAGS` as the explicit map for the existing
three sources, then add a fallback: when `source` starts with `kit_`, look up
`KitPage.find_by(slug: source.delete_prefix("kit_"))` and use `resolved_mailchimp_tag`; if the page is
gone, fall back to `DEFAULT_LEAD_TAG`. Never raise — a missing page must not fail the job and lose the lead.

Do not add a Customer Journey trigger. Per issue #640 the classroom flow deliberately does not promise
an emailed kit because no journey fires on the tag; the same is true here.

### 5. Admin CRUD — `/admin/kit_pages`

`Admin::KitPagesController` with `index`, `new`, `create`, `edit`, `update`, plus a `publish` /
`unpublish` member. Follow `app/views/admin/video_boards/` for structure — it's the closest plain-CRUD
screen. Conventions in `app/views/layouts/admin.html.erb`: `content_for :page_title`, `admin-card` /
`admin-input` / `admin-hover-row` / `admin-badge` helper classes, `text-t1/t2/t3`, flash rendered by the
layout so controllers just `redirect_to ..., notice:`. Forms use plain `form_tag` +
`text_field_tag`/`text_area_tag` and controllers read flat `params[:foo]` — match that, don't introduce
`form_with`. **Add the nav link** to the hardcoded list in the layout (lines ~113-138); active state is
`request.path.start_with?("/admin/kit_pages")`.

Form fields: slug, title, eyebrow, subhead, content items (a repeatable title/description pair is fine;
a raw JSON textarea is acceptable for v1 if it validates and shows parse errors), printable select,
variant select, mailchimp tag, CTA label/path, published checkbox.

**Printable select rules:**
- Only offer `BoardPrintable.where(status: "complete")` with files attached, labeled with the board name
  and page count.
- If the selected printable's `protects_board?` is true, **block the save** and re-render with an
  `admin-flash-err` explaining that this printable is published on Etsy, plus an explicit
  "Give this away for free anyway" checkbox that, when checked, stamps `etsy_override_at` /
  `etsy_override_by_id`. Two-step on purpose — selling a printable on Etsy and giving it away from a
  landing page should never happen by accidentally picking the wrong dropdown row.
- Show a live "Preview" link to `#{ENV['FRONT_END_URL']}/kit/#{slug}` on the index and edit screens.

## Testing

Run `bundle exec rspec` for the files you touch.

| Case | Expected |
|---|---|
| `GET /api/kit_pages/:slug`, published, no token | 200, no file URL in the body |
| `GET /api/kit_pages/:slug`, unpublished | 404 `kit_page_not_found` |
| `GET /api/kit_pages/:slug`, unknown slug | 404 |
| `POST .../download`, valid email | 200 with `files[]`; a `DownloadLead` exists with `source == "kit_<slug>"` |
| `POST .../download`, blank/invalid email | 422 with `errors[]` |
| `POST .../download`, page has no printable | 422 `not_available` |
| `POST .../download` | enqueues `MailchimpUpsertLeadJob` |
| `MailchimpUpsertLeadJob` with `kit_at-school` | tags `AtSchoolLead` |
| Same, page deleted | tags `BoardDownloadLead`, does not raise |
| Variant selection | only the chosen variant is returned when present; falls back to all PDFs when absent |
| Admin save with an Etsy-published printable, no override | rejected, no record change |
| Same, with override checked | saved, `etsy_override_at` stamped |
| Admin routes without an admin session | redirected / rejected |

Also add a regression spec asserting `POST /api/download_leads` still behaves as before — `/classroom`
and `/ctg` depend on it and must not change.

## Deploy notes

- One migration: `create_kit_pages`. No backfill.
- No new ENV vars. The preview link uses the existing `FRONT_END_URL`.
- Ships safely on its own; nothing user-visible until the frontend PR lands.
- After deploy, create one page in `/admin/kit_pages` so the frontend has something to point at, and
  put its slug in the frontend PR description.

## Wrap-up

Follow this repo's CLAUDE.md for git workflow and conventions. Open the PR and stop — never merge.
Commit this doc in the PR so it survives the session. Add a short entry pointing at it from the
`.claude-notes/` spoke table in CLAUDE.md if the model outlives this feature.

## As built

Shipped as written, with these deliberate deviations — read them before
changing the model or the contract.

- **`downloadable?` is stricter than the sketch.** It requires a real PDF
  (`download_files.any?`), not merely `files.attached?`. A printable carrying
  only listing images or the listing video is "attached" but has nothing a
  visitor can be handed, and rendering the email gate for it means a form that
  can only ever 422. Same reason the admin's printable dropdown filters on
  `pdf_files.any?` rather than on `files.attached?`.
- **`resolved_mailchimp_tag` underscores before camelizing.** `"at-school".camelize`
  is `"At-school"`, which is not a usable tag — the slug's hyphens are converted
  first, so `at-school` → `AtSchoolLead` as specified.
- **Admin route helpers are `*_dashboard_kit_page(s)`**, matching every other
  controller in the `admin` namespace. The PATH is still `/admin/kit_pages`, so
  the nav's `request.path.start_with?` active state is as described.
- **Content is a raw JSON textarea** (the v1 the doc allows). A parse failure
  re-renders the form with what was typed, not with the last saved value.
- **The Etsy override is scoped to the printable it was granted for.** A stamped
  override lets later edits of the same page through, but swapping in a
  *different* protected printable asks again, and moving to an unprotected one
  clears the stamp — a stale grant must not silently authorize the next swap.
- **No `destroy` action.** Unpublish is the way to take a page down; the row is
  the only record of which leads came from where.

## Autofill (`POST /admin/kit_pages/autofill`)

The v1 screen was a raw data-entry form: slug, title, eyebrow, subhead, two CTA
fields, and a JSON blob typed into a monospace textarea. **Autofill the page**
writes all of it from the printable the page gives away.

- `KitPages::CopySuggester` is one OpenAI JSON-mode call returning
  `{eyebrow, title, subhead, items, closing}`, built the same way as
  `Boards::AdminBuilder::MetadataSuggester` (same `GenerationError`, same
  `instance_variable_set(:@model, …)` idiom, same hard clamps on every field).
- **It never feeds `listing_copy["description"]` to the model.** That is Etsy
  checkout prose — "instant download", "no sign-in required" — and reads as a
  sales pitch on a page that is giving the thing away. `summary` and `tags` are
  the clean borrow. A spec asserts the description never reaches the prompt.
- **Blanks only, and it never saves.** Same rule as
  `Admin::BoardBuildsController#suggest_context`: anything typed survives,
  including a hand-written content blob (clear the textarea and autofill again
  to have it rewritten). The action renders; it does not persist.
- The slug is derived from the board name **only into a blank field**, and
  uniquified with a `-2` suffix. Re-deriving a slug that already exists would
  move a live `/kit/<slug>` URL — the same rule boards got in #727.
- `mailchimp_tag` is deliberately left blank: `resolved_mailchimp_tag` already
  derives one, so filling it would freeze a value that currently follows a slug
  correction.
- Routed on **both** the collection and a member, because one form partial
  serves `new` and `edit`; `autofill_path(@kit_page)` picks. The button is a
  `formaction` submit with `formnovalidate` (slug and title are `required`, and
  filling them is the point), and the form carries `data: { turbo: false }` —
  without it Turbo Drive refuses the rendered 200 and the button is a silent
  no-op. A request spec asserts that attribute for exactly that reason.

## Mockup images on the public page

`KitPage#gallery_images` puts the printable's rendered marketplace mockups into
`public_view` as `images: [{variant, url}]`, first one first.

- It is a curated **allowlist**, `KitPage::KIT_IMAGE_ORDER` — hero, on_paper,
  flip_book, whats_included, on_a_device. `about` and `page_index` are Etsy shop
  framing and read wrong on a free page. Narrowing by allowlist rather than by
  exclusion is the same discipline `BoardPrintable#pdf_files` keeps: a new image
  variant has to be opted in before it can reach a visitor.
- It reuses `BoardPrintable#listing_images_view`, which has already dropped
  blobs from retired gallery designs, and drops any entry whose `url` came back
  nil (`url_for_file` returns nil rather than raising).
- **This does not weaken the no-file-URL rule.** That rule is about the
  *product* — the PDF, which is still revealed only by the download endpoint
  after a `DownloadLead` is written. These are marketing renders on the same
  public CDN, and they are what persuades a visitor to enter an email at all.

### Files

- `db/migrate/20260819120000_create_kit_pages.rb`, `app/models/kit_page.rb`
- `app/controllers/api/kit_pages_controller.rb` (public read + download)
- `app/controllers/admin/kit_pages_controller.rb`, `app/views/admin/kit_pages/`
- `app/services/kit_pages/copy_suggester.rb` (autofill), plus
  `spec/services/kit_pages/copy_suggester_spec.rb`
- `app/sidekiq/mailchimp_upsert_lead_job.rb` (the `kit_` tag fallback)
- Specs: `spec/models/kit_page_spec.rb`, `spec/requests/api/kit_pages_spec.rb`,
  `spec/requests/api/download_leads_kit_pages_regression_spec.rb`,
  `spec/requests/admin/kit_pages_spec.rb`, plus additions to
  `spec/sidekiq/mailchimp_upsert_lead_job_spec.rb`

## Uploaded documents (the download that isn't a printable)

A kit page can hand over PDFs uploaded straight onto it, in place of a
`BoardPrintable`. The public contract is untouched — same `files` rows, same
email gate, same "no file URL on the read" — so the frontend needed **no change
at all**.

- **Upload wins outright, for the file AND the pictures.** While any document is
  attached, `#download_files` and `#gallery_images` both ignore
  `board_printable` completely (`#uploaded_download?` is the switch). A printable
  is often still selected — it was, before the upload — and serving one's
  mockups above the other's document is the failure this rules out. Removing
  every document falls back to the printable, unchanged.
- **Two NAMED attachments**, `documents` and `preview_images`, not one bag keyed
  on blob metadata. `BoardPrintable`'s single `files` collection is shared across
  PDFs, gallery images and video, and the `pdf_files` invariant exists precisely
  because that partition was once written as an exclusion. Nothing here needs a
  partition, so it doesn't have one.
- **The label is the button text.** An upload carries an optional admin-typed
  label in blob metadata, published as the row's `variant` — which is the field
  `KitLandingPage` prints on the button (`printableVariantLabel` passes an
  unrecognized string straight through). Blank falls back to the filename
  without its extension. A single-document page shows a plain "Download" and
  never renders it.
- **PDF only**, `KitPage::DOCUMENT_CONTENT_TYPES`, capped at
  `MAX_DOCUMENT_BYTES` / `MAX_DOCUMENTS`. An allowlist, same discipline
  `pdf_files` keeps.
- **Versioned storage keys.** `#versioned_storage_key_for` mirrors
  `BoardPrintable`'s: CloudFront caches by path and ignores query strings, so
  re-uploading over a stable key leaves the CDN serving the previous document.
- **No migration.** Everything above is Active Storage plus blob metadata.

### Preview images

`KitPages::DocumentPreviewRenderer` rasterizes the first
`KitPage::PREVIEW_PAGE_COUNT` pages with **libvips** (`pdfload_buffer`), which is
already the Active Storage variant processor in production and links libpoppler
on the platforms we deploy — so no new gem and no new binary. Not poppler's
`pdftoppm` or ImageMagick directly: `Boards::Printables::RenderPageThumbnails`
records that neither can be relied on in the deploy image.

- Gated on `.available?`, memoized, in the `VideoTranscoder` style. Where libvips
  has no PDF loader the page shows no mockups, the admin Document card **says
  so**, and the download is unaffected — a gallery is marketing, the PDF is the
  product. An empty gallery with no explanation reads as a broken upload.
- `ruby-vips` is required explicitly at the top of the service. It arrives as an
  `image_processing` dependency and is otherwise loaded lazily, so `defined?(Vips)`
  is false until something asks for it — which would make `available?` answer "no"
  on a host that has a loader.
- `RenderKitPreviewsJob` **replaces** the whole set rather than appending: the
  previews picture the current download, so a page left from a removed document
  is worse than none. Enqueued via `ActiveRecord.after_all_transactions_commit`.
- Every failure path returns `[]` and logs.

### Admin

The Document card is its **own** form on `edit`, outside the main one. Forms can't
nest, and "Autofill the page" re-renders the main form — a browser cannot
repopulate a file input across a render, so a file picked there would silently
vanish. Same shape as the listing-video upload on board printables.

The card renders on **both** screens, but only `edit` carries the file input: an
upload needs a saved row (the storage key is scoped by id, and the form posts to
a member route). On `new` it says so — a silent New screen reads as "there is no
way to upload a PDF here", which is exactly the wrong answer.

Routes: `POST upload_document`, `DELETE remove_document` (by blob signed id,
scoped to the page), `POST regenerate_previews`. Upload validation lives in the
controller and reports as a flash — re-rendering the whole edit screen around a
small side form would lose whatever was typed in the main one.

The Etsy give-away guard is untouched: it keys on `board_printable`, and an
uploaded document was never sold.

### Files

- `app/models/concerns/attached_file_urls.rb` — `url_for_file` /
  `download_url_for_file` extracted from `BoardPrintable` so both models share
  one copy of the presign path
- `app/models/kit_page.rb`, `app/services/kit_pages/document_preview_renderer.rb`,
  `app/sidekiq/render_kit_previews_job.rb`
- `app/controllers/admin/kit_pages_controller.rb`,
  `app/views/admin/kit_pages/_documents.html.erb`
- Specs: `spec/services/kit_pages/document_preview_renderer_spec.rb`,
  `spec/sidekiq/render_kit_previews_job_spec.rb`, plus additions to the kit page
  model, admin and API specs. `spec/fixtures/files/sample.pdf` is a real 2-page
  PDF — the renderer's whole job is decoding one, so stub bytes prove nothing.


## Draft preview (`?preview=<token>`)

The admin's Preview link on an **unpublished** page used to open the frontend's
"This page isn't available", because `/kit/:slug` scopes to `published` and being
signed in as an admin changes nothing there — the endpoint is deliberately
anonymous (the frontend sends no auth header, so a 401 could never redirect a
marketing URL to sign-in).

A draft's Preview link now carries a signed token, and it is the ONLY thing that
gets an unpublished page past `KitPage.for_public`.

- **The payload is the SLUG**, via `Rails.application.message_verifier`, so a
  token minted for one page cannot reveal another. It expires after
  `PREVIEW_TOKEN_TTL`; the admin screen mints a fresh one on every render, so a
  short TTL costs nothing.
- **An invalid token is answered exactly like a missing page** — 404
  `kit_page_not_found`. A wrong guess must not become a way to probe for drafts.
- **A preview never writes a lead.** `#download` returns the files and returns
  early, before the `DownloadLead` and the Mailchimp enqueue: an admin checking
  their own draft would otherwise put a fake `kit_<slug>` row in the leads table
  and fire an upsert for themselves, so previewing the page would corrupt the
  numbers the page exists to produce.
- **`preview?` is false for a published page**, token or not. Someone forwarded a
  preview link to a page that has since gone live is an ordinary visitor and must
  still be counted as a lead. For the same reason a live page's admin link stays
  clean — an admin might paste it into a campaign.
- `preview: true` is merged into the response **by the controller**, not
  published by `#public_view`, so a live payload is byte-for-byte what it was.

The frontend reads `?preview=` off the location and forwards it to both calls;
that is the whole of its half.

## Canva templates (the product that isn't a file)

A kit page may hand over **editable Canva designs** as well as, or instead of,
a PDF. The motivating product is the MySpeak ID card: it only works once it
carries one communicator's name, photo and QR, so a flat PDF can't be the
deliverable. The visitor gets their own copy of the design in Canva, and makes
the QR themselves with Canva's built-in **QR Code app**, pasting their
`permanent_url`. No Canva API, no OAuth, no QR generation on our side.

### Shape

`kit_pages.canva_templates` — jsonb, `default: []`, `null: false`. One row per
template:

```json
{ "label": "Lanyard card", "url": "https://www.canva.com/design/…", "description": "Two per page" }
```

**Its own column, not a key under `content`.** `public_view` ships `content`
wholesale (`content: content.presence || {}`), so a link parked there is
published to anonymous visitors. Stripping it back out on the way through is
the same one-column-two-meanings trap `pdf_files` records.

### The gate

The rule is identical to the PDF's, and the two reader names say which is which:

| Reader | Carries | Where |
|---|---|---|
| `template_teasers` | `label`, `description` | `public_view` — marketing, same argument as `gallery_images` |
| `template_links` | + `url` | `#download` only, after the lead |

`downloadable?` keeps its narrow meaning — *a readable PDF exists*. The wider
test is `offers_anything?` (`downloadable? || has_templates?`), which is what
`#download` guards on and what the frontend checks before rendering the email
form. A templates-only page therefore reports `downloadable: false` and still
opens its gate.

The download response always carries **both** keys:

```json
{ "files": [...], "templates": [...] }
```

`files` stays present as `[]` on a templates-only page, so a frontend that
predates this feature renders its existing "nothing to download" dead end
rather than throwing.

Leads are untouched: same `DownloadLead`, same `kit_<slug>` source, same
dynamic Mailchimp tag.

### URL validation

An **allowlist**, like `DOCUMENT_CONTENT_TYPES` and `KIT_IMAGE_ORDER`. `https`
always, and then either shape Canva's Share menu produces:

| Host | Path rule |
|---|---|
| `KitPage::CANVA_DESIGN_HOSTS` — `canva.com`, `www.canva.com` | starts with `/design/` |
| `KitPage::CANVA_SHORT_HOSTS` — `canva.link` | anything past the root (the whole path IS the id) |

Cap of `KitPage::MAX_TEMPLATES` (5). A new Canva URL shape has to be opted in.

A short link is stored **as pasted, never resolved**. It is Canva's own
shortener, a visitor following it lands in the same place, and expanding it
here would make saving the admin form depend on a third-party request that can
hang or fail. The refusal message names both accepted shapes — the first cut
listed only the `/design/` one, so pasting the short link Canva had just handed
out looked like a bug in the form.

Nothing distinguishes a **template** link from a read-only **view** link; both
are well-formed and only Canva knows which is which. The admin hint says to
check in a private window, and that stays a human step rather than a guess
encoded here.

A row missing its `url` is dropped by both readers rather than published as a
dead button — but the *validation* still refuses it, so a half-filled row is
reported to the admin instead of being silently swallowed. Only a wholly blank
row (the spare slot the form always renders) is dropped before validation, in
`Admin::KitPagesController#submitted_canva_templates`.

### Admin form

A repeater posting `canva_templates[][label]` / `[url]` / `[description]`.
Existing rows plus one blank; three blanks on a page with none. A failed save
re-renders what was typed for free, because `assign_and_save` assigns before
saving — the same mechanism `@content_raw` uses.

### The how-to

`content["how_to"]` (`{ "heading": …, "steps": [ … ] }`) is validated loosely,
like `items` and `closing`, and rendered in the success card under the template
buttons. It's where the three-step "copy your MySpeak link → Canva's QR Code
app → print" instruction lives, so it's editable without a deploy.

### Accepted limits

- **A revealed link is a bearer token and can't be revoked.** Same trade the
  unsigned PDF CDN URL already makes; the gate is soft by design.
- **Nothing health-checks a template link.** Delete or unshare the design in
  Canva and the page offers a dead button with no signal. The admin form says
  so; a checker isn't worth building.
- **`KitPages::CopySuggester` is untouched.** It writes copy from a printable
  and cannot invent a template link.
