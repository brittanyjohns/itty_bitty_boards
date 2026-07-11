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

## 4. Communicator card/tag generators — makes *per-communicator printables*

Already ships the kit's safety + device tags as PNG **and** PDF with an embedded QR to the communicator's public page.

- `app/services/communicators/generate_device_tag.rb` — 1200×700, QR → `profile.public_url`, template `communicators/assets/device_tag.html.erb`. Default copy: "This device is my voice…".
- `app/services/communicators/generate_safety_id_card.rb` — 1200×1800, QR + emergency notes, template `communicators/assets/safety_id_card.html.erb`.
- Base class: `app/services/communicators/base_asset_generator.rb` — **the reusable pattern for any new printable.** Provides: `rendered_html(template:, locals:)` under the `asset_export` layout, `qr_data_url_for(url, size:)` (RQRCode), `logo_base64`, `avatar_data_url`, `generate_png_from_html` / `generate_pdf_from_html` (Grover), `attach_binary`, and signature-based caching (`attached_and_fresh?`).
- Triggered by: `app/jobs/regenerate_safety_cards_job.rb`, `Profile#generate_attachments!`. Served by `app/controllers/api/profiles/assets_controller.rb` and `api/internal/profiles_controller.rb` (`safety_id_png_url`, `safety_id_pdf_url`, `device_tag_png_url`, `device_tag_pdf_url`).

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
  purge-then-reupload — same stable-key trick as `GeneratePreviewAssets#stable_preview_key`.
  Prod S3 is `public: true`, so `#file_url` (CDN_HOST + key, `file.url` fallback)
  is a permanent, unsigned CDN URL that never changes across regenerations.
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
