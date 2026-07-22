# Internal API — search endpoints (images + boards)

**Date:** 2026-07-22
**Status:** Design approved in conversation; spec pending review
**Motivation:** Build printable products from existing SpeakAnyWay content. The
printables pipeline needs to look up images by word, find admin boards by tag or
name, and download print-quality bytes directly from S3/CloudFront.

## Problem

The internal API (`/api/internal/`) can create, generate and fetch content
**by id**, but has no way to *find* anything. The printables repo has no path
from "I need a picture of an apple" or "which boards are tagged `printable`?" to
a usable result.

This spec adds two search surfaces:

- **Image search by label** — the primary need (§ Image search)
- **Board search by tag / name / description** — admin-owned boards, published
  and unpublished (§ Board search)

They share auth, scoping philosophy (admin-owned content only) and pagination
conventions, but are otherwise independent.

### Constraints specific to images

Two constraints shape the image design:

1. **The URL the app normally hands out is not print-grade.** `Doc#tile_url`
   returns the tile variant — `resize_to_limit: [288, 288]`, WebP, quality 65
   (`ApplicationRecord::TILE_VARIANT_TRANSFORMATIONS`). Fine on screen, bad in
   print. `Doc#display_url` returns the untouched original blob key.
2. **The library mixes licensed third-party artwork with our own.**
   `Doc#source_type` is `"OpenSymbol"` (OpenSymbols — spans public domain,
   CC BY, CC BY-SA, and protected/proprietary sets) or `"OpenAI"` (generated,
   ours). Printables are *sold*. Shipping a protected symbol in a paid product
   is a licensing problem. The OBF importer already gates on this
   (`image_license_required`, HTTP 400); this endpoint takes the same posture.

## Non-goals

- No proxy/streaming download endpoint. Production S3 is `public: true` with
  `CDN_HOST` set, so blob URLs are permanent and unsigned — the client fetches
  from CloudFront directly. Streaming bytes through Rails would add cost and
  latency for zero benefit.
- No presigned URLs, for the same reason.
- No new image *generation* paths. Search only.
- No changes to the public/user-facing image or board APIs.
- No board *content* in search results — board search returns metadata only.
  Fetching a board's tiles stays `GET /api/internal/boards/:id`.

## Image search

All endpoints in this spec mount under the existing `namespace :internal`,
inheriting `API::Internal::ApplicationController` (bearer `INTERNAL_API_KEY`,
`current_user` is always `User::DEFAULT_ADMIN_ID`).

### `GET /api/internal/images/search`

Single-label lookup.

| Param | Type | Default | Notes |
|---|---|---|---|
| `q` | string | *required* | The label to search for. Blank → 422. |
| `match` | `exact` \| `prefix` | `exact` | See matching below. |
| `limit` | integer | `10` | Clamped to 1..50. |
| `commercial_safe` | boolean | `false` | See licensing below. |

Response `200`: `{ "query": "apple", "results": [ <image>, ... ] }`

The response carries no top-level `match`; each result reports its own (see
Matching), since an exact-mode request that falls back returns prefix hits.

### `POST /api/internal/images/search`

Bulk lookup — one round trip for a whole sheet.

```json
{ "labels": ["apple", "dog", "run"], "limit_per_label": 3, "commercial_safe": true }
```

| Param | Type | Default | Notes |
|---|---|---|---|
| `labels` | string[] | *required* | Empty/missing → 422. Max **100**; over → 422. |
| `limit_per_label` | integer | `3` | Clamped to 1..25. |
| `match` | `exact` \| `prefix` | `exact` | Same semantics as GET. |
| `commercial_safe` | boolean | `false` | Same semantics as GET. |

Response `200`:

```json
{
  "results": {
    "apple": [ <image>, ... ],
    "dog":   [ <image> ],
    "run":   []
  }
}
```

Every requested label appears as a key, **including ones with no match** (empty
array). Callers must be able to detect gaps without diffing against their
request. Keys are the caller's labels verbatim, not the normalized form.

### Matching

`match=exact` (default): try `Image.search_by_exact_label`. If that returns
nothing, fall back to `Image.search_by_label` (prefix tsearch). The response's
`match` field on each result records which one actually hit (`"exact"` or
`"prefix"`) so the caller can tell a precise hit from a fuzzy one.

`match=prefix`: skip straight to `search_by_label`.

Rationale: for a printable you usually know the word and want *that* picture,
but labels are stored inconsistently enough that a hard exact-only match would
produce spurious empty results.

### Scope

All queries run against:

```ruby
Image.default_public.searchable.with_artifacts
```

- `default_public` — `is_private` false/nil, `user_id` in `[nil, DEFAULT_ADMIN_ID]`
- `searchable` — excludes `SampleVoice`
- `with_artifacts` — eager-loads `docs → image_attachment → blob`, so building
  URLs and reading dimensions costs no extra queries

No user-owned or private images are ever reachable through this endpoint. This
is not configurable; a `scope=all` override was considered and rejected — the
endpoint feeds a sellable product and the safe scope should not be bypassable.

**Images with no attached doc are excluded from results.** A printable can't use
them, so returning them with a null URL is noise.

### Result shape

```json
{
  "id": 123,
  "label": "apple",
  "match": "exact",
  "src": "https://cdn.../variants/xyz",
  "original_url": "https://cdn.../abc123",
  "content_type": "image/png",
  "width": 1024,
  "height": 1024,
  "source_type": "OpenAI",
  "license": { "license": "public domain", "license_url": "..." },
  "commercial_safe": true
}
```

- `src` — `Doc#tile_url`, the 288px WebP tile. For previews/thumbnails.
- `original_url` — `Doc#display_url`, the full-resolution original on the CDN.
  **This is what printables download.**
- `width`/`height`/`content_type` — from the eager-loaded blob metadata, so the
  layout code can reject too-small images before building a sheet. Null when the
  blob has no metadata; callers must handle null rather than assume dimensions.
- `license` — the `Doc#license` jsonb, or null.
- `commercial_safe` — the computed boolean (below), always present regardless of
  whether the request filtered on it, so callers can make their own call.

### Licensing — `commercial_safe`

A single predicate, computed per doc, used both as a returned field and as an
optional filter.

An image is **commercial-safe** when either:

1. `source_type == "OpenAI"` — we generated it; it's ours; or
2. its license is in an explicit allowlist of commercially-usable licenses:
   public domain, CC0, CC BY, CC BY-SA (matched case-insensitively against the
   license string).

It is **not** commercial-safe when any of:

- the originating OpenSymbol is flagged `protected_symbol`
- the license string is blank, missing, or unrecognized
- the license mentions non-commercial (`nc`, `non-commercial`, `noncommercial`)

**The predicate fails closed:** anything unrecognized is treated as unsafe. For
a product being sold, a false negative costs one missing picture; a false
positive costs a license violation.

`commercial_safe=true` on a request filters results to safe images only. It is
**not** the default — internal/preview work legitimately wants the whole library,
and defaulting to a filtered library would silently hide images during
exploration. The printables sellable-product path opts in explicitly.

This lives in a `Images::CommercialLicense` service object (single public method
`safe?(doc)`, plus the allowlist constant) rather than inline in the controller,
so the OBF importer or a future product path can reuse the same rule instead of
reimplementing it.

## Board search

Find admin-owned boards by tag, name, or description — published **and**
unpublished. Feeds printable production ("which boards are tagged `printable`?")
and general internal tooling.

### `GET /api/internal/boards/search`

| Param | Type | Default | Notes |
|---|---|---|---|
| `q` | string | — | Matches `name` (prefix tsearch) **OR** `description` (ILIKE contains) |
| `tags` | string | — | Comma-separated; each normalized via `Board.normalize_tag_value` |
| `tag_match` | `all` \| `any` | `all` | `with_all_tags` / `with_any_tags` |
| `published` | boolean | *(unset — both)* | `true` or `false` to filter |
| `limit` | integer | `25` | Clamped to 1..100 |
| `page` | integer | `1` | Kaminari |

Every param is independently optional. No params returns the full admin board
list, paginated — a legitimate "show me everything" call.

Response `200`:

```json
{
  "results": [ <board>, ... ],
  "page": 1,
  "total_pages": 3,
  "total_count": 61
}
```

### `GET /api/internal/boards/tags`

Tag discovery — you cannot filter by tag without knowing which tags exist.

Accepts `published` (same semantics as search). Response `200`:

```json
{ "tags": [ { "tag": "printable", "count": 12 }, { "tag": "marketing", "count": 4 } ] }
```

Ordered by count descending, then tag ascending. Implemented with the same
`unnest(tags)` approach as the existing `Board.public_boards_tags`, generalized
to the admin scope (which includes unpublished boards).

### Scope

```ruby
Board.where(user_id: User::DEFAULT_ADMIN_ID).main_boards.not_builder_child
```

- `main_boards` — already means `non_menus` **and** `sub_board` false/nil, so
  menus and sub-boards are excluded without new scopes
- `not_builder_child` — excludes Board Builder sub-boards, consistent with how
  `countable_board_count` treats a built tree as one board

The result is "top-level boards a human would recognize" — what you'd actually
turn into a printable. Admin-owned scratch boards created via the internal API
(`predefined: false`) **are** included, since that's where marketing/kit boards
live.

`predefined: true`-only was considered and rejected: it would exclude the
marketing and kit boards this endpoint most needs to find.

### Matching

`q` matches when **either** condition holds:

- `Board.search_by_name` (pg_search prefix tsearch on `name`)
- `description ILIKE '%q%'`

These are deliberately different match styles: name gets prefix matching
("anim" finds "Animals"), description only substring. Because the two aren't
comparably ranked, results are ordered by **`updated_at desc`**, not by
relevance — an honest ordering rather than a fake combined rank.

`description` is **not** added to the `search_by_name` pg_search scope. That
scope is used elsewhere in the app and widening it would silently change
existing results.

Tag filtering ANDs with `q` when both are present.

### Result shape

A lean, purpose-built payload — **not** `Board#api_view` or `#list_api_view`,
both of which pull `pdf_url`, `word_list` and communicator data and would N+1
badly across a page of results.

```json
{
  "id": 5394,
  "slug": "core-words",
  "name": "Core Words",
  "description": "Starter core vocabulary board",
  "tags": ["printable", "core"],
  "published": true,
  "predefined": false,
  "board_type": "static",
  "image_count": 60,
  "preview_image_url": "https://cdn.../preview.webp",
  "created_at": "2026-05-01T12:00:00Z",
  "updated_at": "2026-07-01T09:30:00Z"
}
```

- `image_count` — the `board_images_count` counter cache, so it's free
- `preview_image_url` — eager-loaded via `with_artifacts`
  (`preview_image_attachment` / `_blob`), null when no preview is attached

**Unpublished boards are returned by default.** A caller building a sellable
product is responsible for passing `published=true`; the endpoint will not
assume it. Documented explicitly in the README, since a draft board silently
becoming a product is the same class of mistake as using `src` where
`original_url` was meant.

## Implementation notes

- New controller actions on `API::Internal::ImagesController`: `search`
  (GET) and `bulk_search` (POST), routed on the existing `images` collection
  block in `config/routes.rb`.
- Search/serialization logic goes in a query object
  (`Images::LabelSearch`) rather than the controller — the controller stays
  thin, and the bulk action is then a loop over the same object.
- Bulk executes per-label queries in a single pass; with the 100-label cap and
  `with_artifacts` eager loading this is acceptable. If it becomes a
  bottleneck, the fix is one grouped query — noted, not built (YAGNI).
- New actions on `API::Internal::BoardsController`: `search` and `tags`, routed
  on the existing `boards` collection block. Query logic in a
  `Boards::AdminSearch` query object, mirroring `Images::LabelSearch`.
- The lean board payload is a private serializer method on the controller (or a
  small `Boards::SearchResultSerializer`), deliberately **not** a new
  `Board#*_api_view` — the model already carries five view methods and does not
  need a sixth.
- `q` combines a pg_search relation with an ILIKE condition. Implement as two
  `id` subqueries UNIONed, or `where(id: name_matches).or(where(id: desc_matches))`
  — pg_search relations don't compose cleanly with `.or`, so resolve to ids
  first rather than fighting the gem.

## Testing

### Image search

`spec/requests/api/internal/images_search_spec.rb`, following the existing
`spec/requests/api/internal/images_spec.rb` pattern (`admin_user` created at
`User::DEFAULT_ADMIN_ID`, stubbed `INTERNAL_API_KEY`, Disk-backed Active
Storage — no real S3).

Cases:

- 401 without a valid bearer token (both verbs)
- 422 on blank `q`, on empty/missing `labels`, on >100 labels
- exact match wins over prefix; `match` field reports which hit
- prefix fallback fires when exact returns nothing
- `match=prefix` skips the exact attempt
- private images and non-admin-owned images are excluded
- images with no attached doc are excluded
- `limit` / `limit_per_label` clamping
- bulk returns a key for every requested label, including empty results
- `commercial_safe` computation: OpenAI → true; allowlisted license → true;
  protected symbol → false; blank license → false; non-commercial → false
- `commercial_safe=true` filters; omitted does not

Plus a unit spec for `Images::CommercialLicense` covering the allowlist and the
fail-closed default.

### Board search

`spec/requests/api/internal/boards_search_spec.rb`, same harness. Cases:

- 401 without a valid bearer token (both endpoints)
- no params returns the full admin scope, paginated
- `q` matches on name (prefix: "anim" finds "Animals")
- `q` matches on description substring
- `q` matches neither → empty results, not an error
- non-admin-owned boards excluded
- menus, sub-boards and builder children excluded
- `published=true` / `published=false` filter; omitted returns **both**
  (explicitly asserts an unpublished board appears)
- `tags=a,b` defaults to ALL (a board with only `a` is excluded)
- `tag_match=any` returns the board with only `a`
- tag values are normalized (`?tags=Printable` matches stored `printable`)
- `tags` ANDs with `q`
- `limit` clamping and pagination metadata correctness
- `/boards/tags` returns counts, respects `published`, and includes tags that
  appear only on unpublished boards

## Documentation

- **`README.md`** — add all four endpoints to the existing `## Internal API`
  section, matching its curl-example style. Also add an **endpoint index** at
  the top of that section (currently the reader has to scroll ~400 lines to
  learn what exists). Two things get called out explicitly because they are the
  most likely consumer mistakes:
  - `src` vs `original_url` on image results (tile vs print-resolution)
  - board search returning **unpublished boards by default**
- **`.claude-notes/internal-api.md`** — new spoke (`git add -f`; the directory
  is gitignored) covering the internal API surface, the auth model, the
  public-bucket/CDN download path, and the licensing rule. The surface is
  currently documented piecemeal inside `marketing-assets.md`, and more
  endpoints are planned.
- **`CLAUDE.md`** — one row in the subsystem map pointing at the new spoke.
- **`CHANGELOG.md`** — user-facing entry.

## Open questions

None.
