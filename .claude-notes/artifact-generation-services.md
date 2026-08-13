# Reference: artifact / printable generation services

**Date:** 2026-07-06 · **Type:** durable reference (not a journal)
**Why this exists:** the AAC Classroom Kit initiative needs printable artifacts (posters, name tags, safety/device tags). A lot of the machinery already exists — this note catalogs it so we reuse instead of rebuild. All file paths are in `itty_bitty_boards`.

There are **three reusable engines**. Verified by reading the code 2026-07-06.

## 1. Board content engine (Board Builder + vocab sets) — makes the *board*

Generates curated core-word board content, all OBF-based.

- Controller: `app/controllers/api/v1/board_builder_controller.rb` (routes: `GET board_builder/templates`, `GET board_builder/interest_categories`, `POST board_builder`). Recommended sets: **`core-60`** (small) and **`core-84`** (large). Complexity levels: starter (6×10), standard (6×10), extended (7×12).
- Services in `app/services/boards/`: `starter_blueprints.rb`, `robust_sets.rb`, `glp_templates.rb`, `structure_planner.rb`, `board_tree_builder.rb`, `blueprint_assembler.rb`, `interest_categories.rb`, `interest_words.rb`, `ai_page_generator.rb`, `phrases_page_builder.rb`.
- Vocab-set seeding: `app/services/vocab_sets.rb`. Authored OBF/OBZ source lives in `db/seeds/board_builder_sets/<slug>/` (manifest.json + boards/*.obf).
  - `bin/rails vocab_sets:seed` — seed every authored set; `SLUGS=core-60` to narrow; `DRY_RUN=1` to preview.
  - `bin/rails 'vocab_sets:build[core-60]'` — emit a distributable `.obz` to `tmp/`.

## 2. OBF/OBZ round-trip — import + export

Boards convert to/from Open Board Format both directions.

- Export: `Board#to_obf(user)` → `GET api/boards/:id/download_obf` (`boards_controller#download_obf`, ~line 635). `.obz` zip via `VocabSets#obz_bytes(slug)`.
- Import: `Board.create_from_obf(json, user_id)` (~line 1063) and `Board.from_obf` (upserts by `(user_id, obf_id)`), `app/models/obz_importer.rb`, `app/sidekiq/import_from_obf_job.rb`, `app/services/obz_analyzer.rb`. Routes: `POST import_obf`, `POST analyze_obz`.

## 3. Board → print PDF/PNG — makes the *printable poster*

Renders any board to a print-ready PDF or PNG. **This is the poster generator.**

- Endpoint: `GET api/boards/:id/pdf` (`boards_controller#pdf`, ~line 1113). Params: `bw=1` (black/white low-ink), `qr=0/1` (include QR, default on), `hide_header=1`, `hide_colors=1`, `screen_size` (default `lg`), `preview` (inline vs attachment). Caches the default (color+QR) variant to `board.pdf_file`.
- Service (async/synchronous): `app/services/boards/generate_preview_assets.rb` → `GeneratePreviewAssets.new(board:, ...).call(generate_png:, generate_pdf:)`. Job: `app/sidekiq/generate_board_preview_job.rb`. `Board#generate_previews` (model ~line 230).
- Render pipeline: `Boards::RenderAssetData` (options: `screen_size`, `hide_colors`, `hide_header`, `include_qr`, `qr_target_url`) → template `app/views/api/boards/print.html.erb` + layout `pdf` → **Grover** (headless Chrome) → Letter, auto portrait/landscape. Layout fixed for print by `Boards::BoardPdfLayoutNormalizer`.
- Attachments on Board: `preview_image` (PNG), `pdf_file` (PDF); URLs via `Board#preview_image_url` / `#pdf_url` (CDN-stable keys).
- **A preview render must be bounded; a printable render must not be.** Grover waits on `networkidle0` with an effectively infinite global timeout (`config/initializers/grover.rb`), so a tile picture that *hangs* — an S3 key not written yet, art still coming back from `GenerateImagesJob` — never settles the page and the board ends up with no snapshot at all. `RenderAssetData` takes `image_load_deadline_ms:` (nil by default); the template swaps any tile still unloaded at that deadline for its label placeholder, which cancels the request. Only `GeneratePreviewAssets` passes a value (`IMAGE_LOAD_DEADLINE_MS`), plus a bounded `RENDER_TIMEOUT_MS` so a stalled render fails and retries instead of pinning a Sidekiq thread. Printable PDFs deliberately keep the nil default — they're a paid artifact, and a slow S3 read must not cost them the real symbol. A `<img>` that 404s is a different case and always falls back via `onerror`.
- **A set renders ONE preview — the root. Every other page is thumbnailed from the folder tile that opens it** (`Boards::SubBoardThumbnails`, shared by `BuildBoardSetJob` and `ImportObzJob`). Rendering per page means one headless-Chrome run per sub-board on the shared `:default` queue (concurrency 10), and a real vocabulary set runs to 50-200 pages — one import would stall every other job behind it. The resolved tile image goes to the child's denormalized `display_image_url` COLUMN via `update_column`, so it never re-enqueues a preview. `purge_previews:` is true only for the Board Builder, whose sub-boards are deliberately never rendered; imports leave any later-earned preview in place, since an imported page is an ordinary board.
- **A render records its outcome, and the client polls that — not the URL.**
  `settings["preview_status"]` is one of `queued` / `ok` / `skipped` / `failed`,
  and `settings["preview_generated_at"]` advances on every successful render
  (`Board#record_preview_generated!`, written in the same save as the
  denormalized `preset_display_image_url` so a reader can't see one without the
  other). Both ride on `api_view` and `api_view_with_predictive_images`.
  `POST generate_preview_image` refuses **422** — `preview_not_supported` for a
  `builder_child` page, `board_has_no_tiles` for an empty board — instead of
  enqueuing a job it knows will skip; `Board#preview_generation_blocker` mirrors
  the job's own skip condition, so keep the two in step. `GenerateBoardPreviewJob`
  stamps `skipped` on the builder-child return and `failed` from
  `sidekiq_retries_exhausted`. The point of all of it: the endpoint only
  *enqueues*, so without a recorded outcome a silent skip, an exhausted render,
  and a worker that isn't draining are all indistinguishable from a slow
  success — which is how "Regenerate from tiles" could report success while
  never changing anything, across three separate rounds of fixes to the read
  path. **Do not poll `preview_image_url` for this.** It changes only
  incidentally (it happens to carry the versioned key), and it isn't the field
  the thumbnail renders — `display_image_url` is, and the two agree only while
  `display_image_source == "preview"`.
- **Every path that finishes writing tile art re-enqueues the preview.** The snapshot is taken while art may still be in flight (`GenerateBoardJob` renders right after the tiles exist), so `GenerateImagesJob` re-enqueues `GenerateBoardPreviewJob` on completion — otherwise the all-placeholder snapshot becomes the board's cover permanently. The `.obf`/`.obz` import jobs enqueue it too: nothing else in the import path renders one, and `BoardGroup#preview_image_url` reads through to the root board's attachment.

## 4. Communicator card/tag generators — makes *per-communicator printables*

Already ships the kit's safety + device tags as PNG **and** PDF with an embedded QR to the communicator's public page.

- `app/services/communicators/generate_device_tag.rb` — 1200×700, QR → `profile.public_url`, template `communicators/assets/device_tag.html.erb`. Default copy: "This device is my voice…".
- `app/services/communicators/generate_safety_id_card.rb` — 1200×1800, QR + emergency notes, template `communicators/assets/safety_id_card.html.erb`.
- Base class: `app/services/communicators/base_asset_generator.rb` — **the reusable pattern for any new printable.** Provides: `rendered_html(template:, locals:)` under the `asset_export` layout, `qr_data_url_for(url, size:)` (RQRCode), `logo_base64`, `avatar_data_url`, `generate_png_from_html` / `generate_pdf_from_html` (Grover), `attach_binary`, and signature-based caching (`attached_and_fresh?`).
- Triggered by: `app/jobs/regenerate_safety_cards_job.rb`, `Profile#generate_attachments!`. Served by `app/controllers/api/profiles/assets_controller.rb` and `api/internal/profiles_controller.rb` (`safety_id_png_url`, `safety_id_pdf_url`, `device_tag_png_url`, `device_tag_pdf_url`).

### 4b. Communicator care plan — the per-communicator *document*

Same family as the cards, different page model. `Communicators::GenerateCarePlan`
renders `settings["care"]` (and, in the `:full` variant, the emergency info) to
a flowing multi-page Letter PDF: `CarePlanDocument` (presenter) →
`communicators/assets/care_plan` + `layouts/pdf_care_plan` → Grover. Owner-only
via `POST /api/profiles/:id/care_plan?variant=full|care_only`.

**The distinction to keep straight — and the reason this isn't a fifth card:**

| | `generate_pdf_from_html` | `generate_letter_pdf` |
|---|---|---|
| page | fixed pixel (`width:`/`height:`) | Letter, CSS-paginated |
| for | card art (safety ID, device tag) | documents of unknown length |
| failure if misused | a Letter format clips 1200px art and spills to page 2 (why the fixed size exists — see `asset_pdf_page_size_spec.rb`) | a fixed height **silently discards** everything past page one |

Two more things that only show up in a real render: `@page { margin: 0 }` kills
Chrome's header/footer (it renders in a separate document clipped to the page
margin), and a `break-inside: avoid` around a whole section pushes any section
taller than a page onto the next sheet and leaves a dead half-page. Details:
`.claude-notes/safety-profiles.md`.

## How this maps to the AAC Classroom Kit

| Kit item | Reuse | New work |
|---|---|---|
| Core Words poster | Board Builder core-60/84 → `GET boards/:id/pdf?bw=` | Minimal — pick/seed a board, hit the endpoint |
| MySpeak safety & device tags | `GenerateDeviceTag` / `GenerateSafetyIdCard` — already done | None (per-communicator) |
| AAC name tags | `BaseAssetGenerator` pattern | New ERB template + thin generator subclass |
| StoryTime Companions | `BaseAssetGenerator` pattern | New ERB template + thin generator subclass |

**Key nuance:** engines #3 and #4 render from *live* boards / communicator profiles (real data, QR to public page) — perfect for per-communicator items (name/safety/device tags). Generic, blank, print-at-home classroom assets (a blank Core Words poster) render from a seeded template board or a static template, not a user's data.

**Stack note:** printables = HTML/ERB → **Grover** (headless Chrome) → PDF/PNG, QR via **rqrcode**. To add a new printable, follow `BaseAssetGenerator`; to print a board, use the board `pdf` endpoint.

## 5. Hosting an assembled PDF at a stable public URL — makes the *kit download link* (SHIPPED)

Built for the AAC Classroom Kit (2026-07-06). The assembled kit PDF has no
natural parent record (not a Board, not a Profile), so a small model owns it.

- **`MarketingAsset`** (`app/models/marketing_asset.rb`): `has_one_attached :file`
  written at a **deterministic** S3 key (`marketing_assets/<slug>.pdf`) via
  purge-then-reupload. Prod S3 is `public: true`, so `#file_url` (CDN_HOST + key,
  `file.url` fallback) is a permanent, unsigned CDN URL that never changes across
  regenerations. **The stable key is a trade-off, not a pattern to copy:**
  CloudFront omits the query string from its cache key, so re-uploading to a warm
  key keeps serving the old file until the edge TTL expires — re-publishing needs
  a CloudFront invalidation. Board previews hit this and moved to a
  per-generation key (`GeneratePreviewAssets#versioned_preview_key`).
  `MarketingAsset.upsert_pdf!(slug:, bytes:, title:, kind:)` is idempotent.
- **Endpoints** (behind `INTERNAL_API_KEY`): `POST /api/internal/marketing_assets`
  (multipart `file` + `slug`) → `{ slug, title, kind, url }`;
  `GET /api/internal/marketing_assets/:slug`. The printables merge step POSTs the
  combined PDF here to get the `KIT_DOWNLOAD_URL`.

## 6. Generic (data-less) marketing renders (SHIPPED)

- **Name tag (variant A):** `Marketing::NameTagSheet` (`app/services/marketing/`)
  renders `app/views/marketing/name_tag_sheet.html.erb` N-up on Letter via Grover;
  streamed by `GET /api/internal/marketing_artifacts/name_tag.pdf?qr_target_url=&per_page=`.
  No Profile / no per-child data.
- **QR override on the Profile-driven tags:** `GenerateSafetyIdCard` /
  `GenerateDeviceTag` (and `BaseAssetGenerator`) take an optional `qr_target_url:`
  (folded into the freshness signature). Default unchanged (QR → `profile.public_url`).
  The kit passes the `/classroom` URL. Internal profiles `PATCH` forwards it.
- **Sample profile for the kit's tags:** `bin/rails marketing:seed_kit_sample_profile`
  seeds one admin-owned, generic safety `Profile` ("SpeakAnyWay Sample") so the
  tags render realistic sample data without a real child.

See `.claude-notes/classroom-kit-hosting-handoff.md` for the end-to-end pipeline.

## 7. Cover-wrapped board printables — the *sellable* PDF (SHIPPED)

The in-app port of the `speakanyway-printables` Node pipeline's PDF-producing
core (its steps 05, 08, 09). Engine #3 renders one board page; this wraps a
board — or its whole subboard tree — in cover / how-to-use / license / credits
and merges everything into a finished product PDF. Admin-only.

- **Model:** `BoardPrintable` (`has_many_attached :files`, status
  pending/generating/complete/failed, `board_ids` = the walked tree in BFS
  order). Storage keys are scoped by record id
  (`board_printables/<id>/<filename>`) so a re-run never collides on the unique
  `active_storage_blobs.key` index. `#files_view` returns
  `[{ variant, filename, url, byte_size }]` on the `CDN_HOST + key` convention.
  Deliberately **not** `board.pdf_file` — that's engine #3's cached single-page
  export and it rides in `Board#api_view`.
- **Services** (`app/services/boards/printables/`): `CollectPages` (BFS walk +
  two Grover renders per board), `RenderWrappers` (the four wrapper pages),
  `MergePdf` (combine_pdf), `Generate` (orchestrates + attaches + stamps).
  Job: `app/sidekiq/generate_board_printable_job.rb`.
- **Endpoints:** `POST /api/admin/boards/:board_id/printables` (202),
  `GET /api/admin/board_printables/:id`,
  `GET /api/admin/board_printables/:id/download_url`.
- **Output shape:** single board = **one** file (`<slug>.pdf`, variant `full`,
  6 pages: cover, how-to-use, colour, low-ink, license, credits). Subboard tree
  = **two** files (`<slug>.color.pdf` / `<slug>.low-ink.pdf`, variants `color`
  and `low_ink`), each fully wrapped, `2N + 8` pages total. There is no combined
  master; the cover is duplicated into both so either file stands alone.

Things that will bite a future change:

- **The tree size is checked in the controller, synchronously, before any record
  exists.** An over-cap tree must answer **422**, and a job that raises cannot.
  `CollectPages.walk_board_tree` is a class method for exactly this reason; the
  job re-walks when it renders. Moving the check into the job would leave a
  record stuck in `generating` with nothing attached.
- **The walk raises rather than truncating.** Silently dropping boards ships an
  incomplete product that looks complete. `max_boards` is clamped to
  `MAX_BOARDS_CEILING` (100) — every board is two Chrome renders.
- **Each board page's QR targets its own board**; only the cover's targets the
  root. A buyer scanning page 5 of a 9-board bundle must land on that board.
- **`hide_header: false` on every board page** — the QR lives inside the header
  in `print.html.erb`, so hiding the header also kills the per-page QR. There is
  no header-less-with-QR combination.
- **Wrappers are a separate template/layout pair**
  (`app/views/api/board_printables/*` + `layouts/pdf_printable.html.erb`), never
  a branch inside `layouts/pdf.html.erb` — same rule as `pdf_marketing`.
- **The layout deliberately does not `@import` Nunito** the way the pipeline's
  `base.css` does. A network fetch inside PDF generation is a flaky failure
  mode; it uses the system stack, matching `layouts/pdf.html.erb`. A spec
  asserts the absence of `fonts.googleapis.com`.
- **Merging, not one long HTML print**, is what preserves each page's own
  orientation — portrait wrappers next to landscape board pages (any board with
  ≥6 tiles goes landscape via `RenderAssetData#resolved_landscape`).

**Licensing:** admin-only internal generation is fine, but *selling* the output
is not automatically fine — `Images::CommercialLicense` is the gate, and per
`.claude-notes/internal-api.md` only a minority of the image library is
commercial-safe (ARASAAC, the largest source, is CC BY-NC-SA).

Design + full context: `.claude-notes/board-printable-in-app-handoff.md`.
