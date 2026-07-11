# Marketing assets — AAC Classroom Kit hosting

> Extracted from CLAUDE.md on 2026-07-11 (hub-and-spoke restructure).
> This file is the authoritative doc for this subsystem — update it (not CLAUDE.md)
> when behavior changes. CLAUDE.md keeps only the cross-cutting invariants.

## Marketing assets — AAC Classroom Kit hosting

The AAC Classroom Kit is a **free marketing lead magnet** (a bundled print-ready
PDF for the `/classroom` landing page) — **not** a sellable product and never
published to any marketplace. The backend's job is to *host* the assembled kit
PDF at a stable public URL and to render/source the individual artifacts;
assembly (merging the per-artifact PDFs) happens in the **printables** repo,
which already depends on `pdf-lib`.

- **`MarketingAsset` (`app/models/marketing_asset.rb`) hosts a PDF at a stable
  slug.** `has_one_attached :file` written at a **deterministic** S3 key
  (`marketing_assets/<slug>.pdf`) via purge-then-reupload — the same
  stable-key pattern as `Boards::GeneratePreviewAssets#stable_preview_key`.
  Production S3 is `public: true`, so `#file_url` (CDN_HOST + key, `file.url`
  fallback) is a permanent, unsigned CDN URL that **never changes across
  regenerations**. `MarketingAsset.upsert_pdf!(slug:, bytes:, title:, kind:)` is
  idempotent — re-running the kit build overwrites in place, so the
  `KIT_DOWNLOAD_URL` is safe to hardcode on the frontend.
- **Stable slugs for kit boards (`replace_existing_slug`).** The internal
  boards endpoints (`POST /api/internal/boards`, `POST /api/internal/boards/
  from_vocab_set`) accept an opt-in `replace_existing_slug` boolean: the
  controller destroys the previous board holding the requested slug and gives
  the new board the **exact** slug — scoped so only a board owned by the
  internal admin AND tagged `marketing` is ever destroyed (anything else is
  left alone and the new board gets a suffixed slug, logged). On
  `from_vocab_set` the new-board slug rides **`board_slug`** (`slug` is the
  vocab-set key), claimed only after the clone persists so a failed clone
  never destroys the live QR target. This keeps the printed kit's
  `/pb/<slug>` QR targets stable across regenerations and stops `MKT —`
  scratch boards accumulating. Brief 404 window on the slug while a
  regeneration is in flight — acceptable for a lead magnet.
- **Marketing print style (`style=marketing`) on board PDF export.**
  `GET /api/internal/boards/:id/export.pdf?style=marketing` renders the
  marketing-branded pair `app/views/api/boards/print_marketing.html.erb` +
  `app/views/layouts/pdf_marketing.html.erb` (gradient header band, white QR
  chip, footer CTA; tile rendering identical since AAC colors are meaningful).
  The pair is a deliberate **copy**, not a refactor — the shared
  `print`/`pdf` pair backs real users' exports and stays byte-identical when
  the param is absent (spec-guarded in `board_pdf_export_spec.rb`). Any
  unknown `style` value falls back to the shared pair.
- **Endpoints (behind `INTERNAL_API_KEY`, `namespace :internal`):**
  - `POST /api/internal/marketing_assets` `{ slug, file(multipart PDF), title?, kind? }`
    → upsert + host → `{ slug, title, kind, url }` (`201`). The printables
    marketing-kit script POSTs the merged kit here to get the public URL.
  - `GET /api/internal/marketing_assets/:slug` → `{ ..., url }` or `404`.
  - `GET /api/internal/marketing_artifacts/{name_tag,safety_tag,device_tag}.pdf?qr_target_url=&per_page=`
    → stream the generic classroom sheets (`Marketing::NameTagSheet` /
    `SafetyTagSheet` / `DeviceTagSheet`, Grover HTML→PDF, templates under
    `app/views/marketing/`, shared helpers in `Marketing::SheetRendering`). All
    are fillable, no per-child data, laid N-up on a single **Letter** page with
    cut lines.
- **The kit's safety + device tags are compact, print-and-cut backpack tags.**
  `SafetyTagSheet` (a "Communication ID" tag: photo circle, fillable name,
  "I use a device to communicate", QR) and `DeviceTagSheet` ("This device is my
  voice", QR) render generic, fixed-physical-size tags **2-up on Letter** — not
  the app's detailed Profile safety card. This was a deliberate change: the app's
  `Communicators::GenerateSafetyIdCard` renders a full-page 1200×1800 card that
  **overflowed onto a 2nd page** when exported (taller than A4) and is too big
  for a backpack tag. The kit tags no longer depend on a sample Profile.
  - **The app's Profile-driven safety/device cards are unchanged**, including the
    optional `qr_target_url:` override on `GenerateSafetyIdCard`/`GenerateDeviceTag`
    (still available; just no longer used by the kit). The
    `marketing:seed_kit_sample_profile` rake also remains but is no longer needed
    for the kit.
  - **Known follow-up:** `Communicators::BaseAssetGenerator#generate_pdf_from_html`
    still uses `format: "A4"`, so a real user's downloaded safety-card PDF can
    overflow to 2 pages. Not fixed here (out of scope for the kit change) — a
    separate fix would size the page to the card.
- **Kit QR targets (short, so they actually scan).** Two families:
  - **Board posters** (Core Words, Storytime) → `app.speakanyway.com/pb/<slug>`
    (`mkt-core-words-poster`, `mkt-storytime-board`) — deep-links to the live
    tappable board. These carry no UTM.
  - **Tags** (name / safety / device) → **`speakanyway.com/myspeak`** (bare
    domain per brand rule, **no UTM**). They previously pointed at the
    ~119-char `/classroom?utm_...` URL, which forced a 41-module (version-6) QR;
    at the tags' small printed size that fell at/below the phone-camera scan
    floor and **wouldn't scan** (2026-07-08). The short `/myspeak` URL is a
    ~25-module (version-2) code — roughly double the printed module size — and
    lets `Marketing::SheetRendering#qr_data_url` run ECC **`:m`** (restored from
    the `:l` hack that only existed to cram the long URL in). **Do not re-add a
    long UTM to the tag URLs** — it re-inflates the module count and re-breaks
    scanning (guarded by `spec/services/marketing/qr_scannability_spec.rb`).
  - The kit is assembled by the printables `npm run build-kit` script, which is
    the single source of truth for these per-artifact `qr_target_url`s — the
    backend endpoints just render whatever URL they're handed.
- Reference: `.claude-notes/artifact-generation-services.md` (the reusable
  engines) and `.claude-notes/classroom-kit-hosting-handoff.md` (end-to-end
  pipeline + the printables side + the `KIT_DOWNLOAD_URL` swap).

