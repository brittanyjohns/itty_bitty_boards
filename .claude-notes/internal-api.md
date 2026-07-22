# Internal API — `/api/internal/`

> Authoritative doc for the internal API surface. Update this (not CLAUDE.md)
> when behavior changes. User-facing usage docs live in `README.md`.

Server-to-server API for trusted callers (the printables pipeline, internal
scripts). Not for the React frontend and never exposed to end users.

## Auth and identity

`API::Internal::ApplicationController` authenticates a bearer token against
`ENV["INTERNAL_API_KEY"]` with `ActiveSupport::SecurityUtils.secure_compare`,
and CSRF is skipped. There is **no per-user auth**: `current_user` is always
`User::DEFAULT_ADMIN_ID`, so every write is attributed to the admin. Any new
endpoint inherits this — do not add per-user scoping to this namespace.

## Downloads go straight to the CDN

Production Active Storage is S3 with `public: true`, and `CDN_HOST` is set, so
blob URLs are permanent and unsigned. Internal callers fetch bytes directly
from CloudFront. **Do not add proxy/streaming download endpoints or presigned
URLs** — they add cost and latency for no benefit.

The trap: `Doc#tile_url` is the 288×288 WebP q65 tile variant
(`ApplicationRecord::TILE_VARIANT_TRANSFORMATIONS`), while `Doc#display_url` is
the untouched original. Anything print-bound must use the original. Image
search returns both, as `src` and `original_url`.

`Doc#tile_url` performs *synchronous* ActiveStorage variant materialization
(download original + libvips transform + upload) on first access — calling it
unconditionally on a page of cold results risks dozens of inline transcodes in
one request. `Images::LabelSearch` guards on `Doc#tile_variant_processed?` and
only returns a tile URL when the variant is already processed; otherwise
`src` is `null` and **never** falls back to the original (a caller must be
able to tell "no thumbnail yet" from "here is a thumbnail"). `original_url`
(`Doc#display_url`) is always present, and if the tile variant is still cold,
reading it enqueues `PreprocessDocTileVariantJob` to warm it in the
background — an accepted, self-healing side effect, not a bug. A repeat
search for the same label will typically come back with `src` populated.

## Licensing — `Images::CommercialLicense`

Single source of truth for "may this image go in something we sell." Public
entry point is `Images::CommercialLicense.for(doc, include_share_alike:)`,
returning a `Result` with `#commercial_safe?`, `#attribution_required?`,
`#share_alike?`, and the raw `#license` hash.

- **`Doc#license` is the only populated license field.** `Image#license` has
  zero rows — never read it. The jsonb key is **`type`**, not `license`.
- `Doc#license` is populated only on `ObfImport` docs. `OpenSymbol`-sourced
  docs carry license data on the `OpenSymbol` row, reached via
  `Doc#matching_open_symbols` (`search_string` has no uniqueness constraint,
  so `CommercialLicense` resolves deterministically — ordered by `id`, and any
  matching symbol flagged `protected_symbol` wins over the rest).
- `OpenSymbol#protected_symbol` is `false` on every row today — it is checked
  defensively but carries no real signal.
- **ARASAAC (author "Sergio Palao") is CC BY-NC-SA and is the single largest
  licensed source.** It cannot go in a paid product. Free lead magnets (the
  Classroom Kit) are fine.

Three flags per image: `commercial_safe`, `attribution_required`,
`share_alike`. The predicate **fails closed** — unrecognized licenses,
scraped `GoogleSearch` docs and unknown/blank `source_type` are all unsafe. CC
BY-SA is excluded from `commercial_safe` by default (share-alike is plausibly
viral onto a sold derivative) and admitted only via `include_share_alike`.

Current library-wide breakdown (`rake images:license_audit`, dev DB,
2026-07-22, 10,101 docs — **regenerate rather than trusting these as they
age**):

| | Count | Share |
|---|---|---|
| commercial-safe | 3,626 | 35.9% |
| attribution-required | 4,233 | 41.9% |
| share-alike | 3,557 | 35.2% |

Only **35.9%** of the library can go in a product that's sold — roughly
**two-thirds cannot**. The single largest non-commercial bucket is `cc by-nc-sa`
at 2,464 docs (ARASAAC, author "Sergio Palao"). Commercial-safe decomposes
exactly as `OpenAI` 3,116 + `cc by` 400 + `public domain` 58 + `cc by 3.0` 52.

## Search endpoints

- `GET|POST /api/internal/images/search` → `Images::LabelSearch`. Exact match
  first, prefix fallback. Scoped to `Image.default_public.searchable.with_artifacts`
  — user and private images are never reachable, and this is not overridable.
  Images with no attached doc are excluded (a printable can't use them, so a
  null-URL result would be noise).
- `GET /api/internal/boards/search` → `Boards::AdminSearch`. Scoped to admin
  boards, excluding menus, sub-boards and Board Builder children. Returns
  **unpublished boards by default**; callers building shippable products must
  pass `published=true`.
- `GET /api/internal/boards/tags` → tag counts for discovery, ordered by count
  descending then tag ascending.

`Boards::AdminSearch.base_scope` deliberately does **not** reuse
`Board.main_boards` (which composes `where.not(board_type: "menu")`). In SQL,
`NULL != 'menu'` evaluates to `NULL`, not `TRUE`, so `where.not` silently
excludes every board with a `NULL` board_type — verified against production
data, 11 admin-owned top-level boards had `board_type: nil` and were invisible
under `main_boards`. `AdminSearch` reimplements the "not a menu, not a
sub-board" filter with `boards.board_type IS DISTINCT FROM 'menu'`, which
treats `NULL` as simply "not equal to `menu`." This fix is intentionally local
to `AdminSearch` — do not swap it back for `Board.main_boards` /
`Board.non_menus`, which are used elsewhere and whose NULL semantics other
callers may depend on.

`q` on board search matches name via pg_search (prefix) OR description via
ILIKE (substring); the two aren't comparably ranked, so results order by
`updated_at desc` rather than a fake combined relevance. Implemented as two id
lookups OR'd together (`where(id: name_ids + desc_ids)`), not `.or` composed
directly on the pg_search relation — pg_search relations don't compose
cleanly with `.or`. **Do not widen `Board.search_by_name` to include
description** — that scope is used elsewhere.

Board search results use a purpose-built lean payload
(`search_result_view` on the controller), deliberately not one of `Board`'s
five `api_view*` methods, which pull `pdf_url` / `word_list` / communicator
data and would N+1 across a page.

## Related

`marketing-assets.md` documents the marketing-asset and artifact endpoints
(stable slugs, kit QR targets) in detail.
