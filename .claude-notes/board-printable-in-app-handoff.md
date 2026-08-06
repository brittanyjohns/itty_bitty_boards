# Handoff: cover-wrapped board printables in-app (backend)

**Date:** 2026-08-06 · **Status:** not started
**Full plan:** `../drafts/board-printable-in-app-plan.md` (this doc is self-contained; the plan adds context)
**Counterpart:** `../itty-bitty-frontend/.claude-notes/board-printable-in-app-handoff.md`
**Issue:** none filed

## What we're building

An admin-only endpoint that generates a **cover-wrapped, multi-page printable
PDF** for a board (optionally the board plus its whole subboard tree) and
persists it via ActiveStorage.

This ports three steps out of the `speakanyway-printables` Node pipeline —
its steps 05 (collect board pages), 08 (render wrapper pages), 09 (merge) —
into Rails. Everything downstream in that pipeline (listing copy, marketing
images, Drive upload, Etsy/Gumroad) stays where it is and is out of scope.

**Target output, single board (6 pages):**

```
cover → how-to-use → board (color) → board (low-ink) → license → credits
```

**Target output, N-board subboard bundle (2N + 8 pages, split into two files):**

```
<slug>.color.pdf    = cover → how-to-use → N color pages   → license → credits
<slug>.low-ink.pdf  = cover → how-to-use → N low-ink pages → license → credits
```

Board pages are ordered breadth-first from the root, root first. The color half
comes before the low-ink half, matching the pipeline.

## Decisions (already made — don't re-litigate)

1. **Add a PDF-merge gem.** There is no Ruby merge library in app code today.
   Per-page Grover renders, merged afterwards — this mirrors the pipeline's
   `pdf-lib` usage exactly, and preserves each page's own orientation for free.
   **Ask Brittany before adding it** (repo rule), and **verify the license is
   compatible with a commercial closed-source product** — HexaPDF is AGPL-3.0
   with a paid commercial option and is the wrong choice for that reason.
   Prefer a permissive pure-Ruby option such as `combine_pdf`; read the gemspec
   rather than trusting this note.
2. **Both single-board and subboard-tree modes are in scope.**
3. **New `BoardPrintable` model**, `has_many_attached :files`. Do **not** reuse
   `board.pdf_file` — that's the existing single-page cached export and it's
   exposed via `Board#api_view`.
4. **`API::Admin::` namespace**, since the frontend admin UI is the caller.
5. Frontend does not add a client-side admin guard; the backend 403 is the
   real gate. Your authorization must therefore actually be correct.

## Current state — what already exists

### The board-page renderer (most of pipeline step 05 is already yours)

`GET /api/internal/boards/:id/export.pdf`
(`app/controllers/api/internal/boards_controller.rb:117-164`, routed at
`config/routes.rb:438`) already renders exactly the board pages the printable
needs. The printables pipeline is just an HTTP client for it — for a color page
it sends:

```
GET /api/internal/boards/<id>/export.pdf
    ?qr_code=true
    &qr_target_url=https%3A%2F%2Fapp.speakanyway.com%2Fpb%2F<id>
    &screen_size=lg&hide_colors=0&hide_header=0
```

and the low-ink page is identical with `hide_colors=1`.

**Do not have Rails HTTP-call its own endpoint.** Go straight to the shared
core, `Boards::RenderAssetData` (`app/services/boards/render_asset_data.rb:4`),
which takes `board:`, `screen_size:`, `hide_colors:`, `hide_header:`,
`include_qr:`, `qr_target_url:` and returns the assigns for
`app/views/api/boards/print.html.erb` + `app/views/layouts/pdf.html.erb`.
`api/internal/boards_controller.rb:117-164` is the reference for wiring assigns
→ `render_to_string` → `Grover.new(html, **opts).to_pdf`.

Two behaviours to know:

- **Orientation is automatic.** `#resolved_landscape`
  (`render_asset_data.rb:68-72`) makes any board with ≥6 tiles landscape. So a
  finished printable legitimately mixes portrait wrappers with landscape board
  pages. The merge gem preserves that; don't try to normalize it.
- **`hide_header=1` also kills the QR**, because the QR lives inside the header
  in `print.html.erb`. There is no header-less-with-QR combination. The
  printable wants `hide_header=0` on every board page, so this doesn't bite —
  just don't "clean up" the header later expecting the QR to survive.

### Grover

`Gemfile:148-149` (`grover`, `rqrcode`); global config at
`config/initializers/grover.rb:3-15` — Letter, `wait_until: "networkidle0"`,
`--no-sandbox`. The configured timeout is enormous, which is exactly why
multi-page generation belongs on Sidekiq and never on a request thread.

### ActiveStorage

Services in `config/storage.yml`: `test` → Disk, `amazon` → S3 with
`public: true`. Production uses `:amazon` (`config/environments/production.rb:54`).
Because the bucket is public, **URLs are `CDN_HOST + key`, not presigned** —
follow `Board#pdf_url` (`app/models/board.rb:351-363`) and
`MarketingAsset#file_url` (`app/models/marketing_asset.rb:53-68`), both of which
return nil rather than raising when nothing is attached.

The canonical attach-a-generated-file pattern is
`MarketingAsset#attach_pdf!` (`app/models/marketing_asset.rb:31-49`) —
deterministic key, purge before re-attach so the unique index on `blobs.key`
doesn't collide.

### Admin auth

`User#admin?` is a **role string**, not a boolean column
(`app/models/user.rb:940-942` → `role == "admin"`).

Copy `API::Admin::ApplicationController`
(`app/controllers/api/admin/application_controller.rb:1-28`): it
`prepend_before_action :authenticate_admin!` and looks the user up by
`authentication_token` **scoped to `role: "admin"`**. Routes live under
`namespace :api { namespace :admin { … } }` at `config/routes.rb:526-566`;
`app/controllers/api/admin/boards_controller.rb:3` is a subclass example.

### Sidekiq

Jobs live in **`app/sidekiq/`** (not `app/jobs/`), plain classes with
`include Sidekiq::Job`, invoked with `.perform_async`. Queues are defined in
`config/sidekiq.yml`. The convention to copy is
`app/sidekiq/generate_board_preview_job.rb`: thin job, delegates to a service
under `app/services/`, service renders **and attaches atomically**, failures
propagate so Sidekiq retries.

### The subboard link

`board_images.predictive_board_id` (`app/models/board_image.rb:23`), with
`Board#predictive_board_images` (`app/models/board.rb:90`). **No Ruby tree walk
exists yet** — the BFS lives only in the pipeline's TypeScript.

## Work items

### 1. `BoardPrintable` model + migration

```ruby
# db/migrate/..._create_board_printables.rb
create_table :board_printables do |t|
  t.references :board, null: false, foreign_key: true   # the ROOT board
  t.references :created_by, foreign_key: { to_table: :users }
  t.string  :status, null: false, default: "pending"    # pending/generating/complete/failed
  t.boolean :include_subboards, null: false, default: false
  t.integer :max_boards, null: false, default: 25
  t.string  :topic
  t.integer :page_count
  t.jsonb   :board_ids, null: false, default: []        # every board in the bundle, BFS order
  t.text    :error_message
  t.timestamps
end
add_index :board_printables, [:board_id, :status]
```

`has_many_attached :files` — one attachment for single-board, two (color +
low-ink) for a bundle. Storage keys scope by record id so re-runs never collide:
`board_printables/#{id}/#{filename}`.

Expose a `#files_view` returning `[{ variant:, filename:, url:, byte_size: }]`
using the `CDN_HOST + key` convention above.

### 2. `Boards::Printables::CollectPages` (pipeline step 05)

Input: root board, `include_subboards`, `max_boards`.
Output: ordered array of `{ pdf_bytes:, page_number:, board_id:, board_name:, variant: }`.

- Resolve the root board.
- If `include_subboards`, BFS from the root over each cell's
  `predictive_board_id`. Dedupe by board id — seed the visited set with the root
  so a child linking back to the root doesn't loop. Skip self-links. **Raise**
  when the unique-board count would exceed `max_boards` (the pipeline throws
  rather than truncating; match that — silently dropping boards would ship an
  incomplete product).
- Render each board twice through `Boards::RenderAssetData` + Grover:
  `hide_colors: false` for the color half, `hide_colors: true` for low-ink.
  Always `hide_header: false`, `screen_size: "lg"`, `include_qr: true`.
- **Each page's QR targets its own board** — `https://app.speakanyway.com/pb/<that board's id>`.
  This matters: a buyer scanning page 5 of a 9-board bundle should land on that
  board, not the root. Only the cover QR points at the root.
- Page order: all color pages (BFS order, root first), then all low-ink pages in
  the same board order.

### 3. `Boards::Printables::RenderWrappers` (pipeline step 08)

Four pages, each its own Grover render, each Letter **portrait**:

| Page | Content | Tokens |
|---|---|---|
| cover | board title, subtitle, logo, QR → **root** board | title, subtitle, logo, qr |
| how-to-use | print/laminate guidance; wording branches on single vs "set of N" | board count |
| license | personal-use terms | — |
| credits | thanks + logo + QR | logo, qr |

Follow the repo's existing rule that a distinct look is a **separate
template/layout pair, never a conditional inside the shared one** — the comment
at `app/controllers/api/internal/boards_controller.rb:136-139` states this for
the marketing skin. So add `app/views/api/board_printables/_cover.html.erb`
etc. plus a `layouts/pdf_printable.html.erb`; do not add branches to
`layouts/pdf.html.erb`.

QR generation uses `rqrcode`, already in the Gemfile;
`app/services/boards/asset_rendering.rb` has the existing helpers. The pipeline
renders its QR navy `#13496f` on cream `#FBF7F1` at 400px — match it so the
in-app output looks like the pipeline's.

**Fonts:** the pipeline's wrappers `@import` Nunito from Google Fonts at render
time. Do not copy that — a network fetch inside PDF generation is a flaky
failure mode. Match however `app/views/layouts/pdf.html.erb` already handles
fonts.

The how-to-use copy is worth lifting near-verbatim from the pipeline
(`speakanyway-printables/src/plugins/aac/product-types/existing-board.ts`,
`buildHowToUseHtml`) so in-app and pipeline products read identically.

### 4. `Boards::Printables::MergePdf` (pipeline step 09)

- **Single board (N=1):** one file — cover, how-to-use, page 1 (color),
  page 2 (low-ink), license, credits.
- **Bundle (N>1):** two files, no combined master. Each variant is fully
  wrapped: cover → how-to-use → that variant's N pages → license → credits.
  The cover and its root QR are duplicated into both, by design.

Filenames key off the root board's slug (falling back to `board-<id>`):
`<slug>.pdf`, or `<slug>.color.pdf` / `<slug>.low-ink.pdf`.

### 5. `Boards::Printables::Generate` + `GenerateBoardPrintableJob`

Orchestrator service calling 2 → 3 → 4, then attaching the results and setting
`status`, `page_count`, `board_ids`. Job in `app/sidekiq/`, thin, delegating.
Set `status: "failed"` with `error_message` on rescue, then re-raise so Sidekiq
retries.

### 6. `API::Admin::BoardPrintablesController`

Subclass `API::Admin::ApplicationController`. Routes under the existing
`namespace :api { namespace :admin { … } }`:

| Verb | Path | Does |
|---|---|---|
| POST | `/api/admin/boards/:board_id/printables` | creates the record, enqueues the job, returns it (202) |
| GET | `/api/admin/board_printables/:id` | status poll |
| GET | `/api/admin/board_printables/:id/download_url` | `{ files: [{ variant, filename, url }] }` |

Accepts `include_subboards`, `max_boards`, `topic`. Returns 422 with a clear
message when the tree exceeds `max_boards`.

## Testing

Request specs go in `spec/requests/api/admin/`. Factories are all in
`spec/factories.rb`: `:admin_user` (`:94`), `:user` (`:88`, role `"user"`),
`:board` (`:113`), `:board_image` (`:136`), `:image` (`:126`).

Copy the Chrome-avoiding stubs from
`spec/requests/api/internal/board_pdf_export_spec.rb`:

```ruby
fake_grover = instance_double(Grover, to_pdf: "%PDF-fake")
allow(Grover).to receive(:new).and_return(fake_grover)
```

Authorization matrix — prove every row:

| Caller | Expect |
|---|---|
| no token | 401 |
| valid token, `role: "user"` | 401 |
| valid token, `role: "admin"` | 200/202 |
| admin, board belonging to another user | 200 (admin is global — assert deliberately so the intent is recorded) |

Behaviour to prove:

- single board → one attachment, 6 pages, correct page order
- `include_subboards` → BFS order with root first, root's own subboard link not
  re-walked, duplicate board ids visited once
- tree over `max_boards` → 422, nothing attached, no partial record left in
  `generating`
- bundle → exactly two attachments, color and low-ink, each fully wrapped
- each board page's QR target is its own board; the cover's is the root
- job failure → `status: "failed"` with `error_message` populated
- re-running for the same board doesn't collide on `blobs.key`

Also add a service spec for the BFS walk specifically — it's the piece most
likely to regress and the cheapest to test in isolation.

Run `bundle exec rspec spec/requests/api/admin spec/services/boards` before
opening the PR.

## Deploy notes

- **One new gem** — get Brittany's explicit OK first.
- **One migration**, `board_printables`. No backfill.
- **No new ENV vars.**
- Ships independently of the frontend; it's an admin-only API with no UI until
  the counterpart PR lands.

## Wrap-up

Follow this repo's CLAUDE.md for git workflow and conventions. Open the PR and
stop — never merge. Commit this doc in the PR so it survives the session.
Update `.claude-notes/artifact-generation-services.md` — it catalogs the
printable engines and this adds a fourth.
