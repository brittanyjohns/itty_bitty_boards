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
| `include_share_alike` | boolean | `false` | Only meaningful with `commercial_safe=true`. |

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
| `include_share_alike` | boolean | `false` | Same semantics as GET. |

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
  "license": {
    "type": "CC BY",
    "author_name": "Sergio Palao",
    "author_url": "https://...",
    "copyright_notice_url": "https://..."
  },
  "commercial_safe": true,
  "attribution_required": true,
  "share_alike": false
}
```

- `src` — `Doc#tile_url`, the 288px WebP tile. For previews/thumbnails.
- `original_url` — `Doc#display_url`, the full-resolution original on the CDN.
  **This is what printables download.**
- `width`/`height`/`content_type` — from the eager-loaded blob metadata, so the
  layout code can reject too-small images before building a sheet. Null when the
  blob has no metadata; callers must handle null rather than assume dimensions.
- `license` — the `Doc#license` jsonb verbatim, or null. **Note the key is
  `type`, not `license`.**
- `commercial_safe` / `attribution_required` / `share_alike` — computed flags
  (below), always present regardless of request filters, so the caller can make
  its own call and build a credits page.

### Licensing

**This section is grounded in the actual library, not assumption.** Figures
below are the output of `rake images:license_audit` (dev DB, 2026-07-22,
10,101 docs) — regenerate rather than trusting them as they age.

By resolved license type (this is post-resolution, so it includes the
`OpenSymbol`-sourced docs whose license lives on the symbol row):

| License type | Count | Sellable |
|---|---|---|
| *(no license)* | 5,657 | no — unknown provenance |
| `cc by-nc-sa` | 2,464 | **no — non-commercial** |
| `cc by-sa` | 1,046 | share-alike — opt-in only |
| `cc by` | 400 | yes, **attribution required** |
| `cc by-nc` | 224 | **no — non-commercial** |
| `private` | 152 | no |
| `public domain` | 58 | yes, no obligation |
| `cc by 3.0` | 52 | yes, **attribution required** |
| `cc by-sa 3.0` | 47 | share-alike — opt-in only |
| `gpl` | 1 | no |

By `source_type`: `ObfImport` 5,349 · `OpenAI` 3,116 · `GoogleSearch` 809 ·
`OpenSymbol` 657 · *(none)* 170.

Resulting totals:

| | Count | Share |
|---|---|---|
| **commercial-safe** | **3,626** | **35.9%** |
| attribution-required | 4,233 | 41.9% |
| share-alike | 3,557 | 35.2% |

Commercial-safe decomposes exactly as `OpenAI` 3,116 + `cc by` 400 +
`public domain` 58 + `cc by 3.0` 52. **Roughly two-thirds of the library
cannot go into a product that is sold**, and of what remains, 452 images
carry an attribution obligation.

Facts that constrain the implementation:

- **`Doc#license` is the only populated license field.** `Image#license` has
  **zero** populated rows — never read it.
- **The jsonb key is `type`**, e.g.
  `{"type": "CC BY-NC-SA", "author_name": "Sergio Palao", "author_url": ...,
  "copyright_notice_url": ...}`.
- **`Doc#license` is populated only on `ObfImport` docs.** `OpenSymbol`-sourced
  docs carry license data on the `OpenSymbol` row instead, reached via
  `Doc#matching_open_symbols` (`OpenSymbol.where(search_string: doc.raw)`).
- **`protected_symbol` is `false` on all 1,467 `OpenSymbol` rows.** It is checked
  as belt-and-braces but carries no real signal today — do not rely on it.
- **ARASAAC (author "Sergio Palao", 2,218 docs) is CC BY-NC-SA.** It is the
  single largest licensed source and it is *not* sellable. Free lead magnets
  (the Classroom Kit) are fine; paid products are not.
- **`src` is null until the tile variant is warm.** `Doc#tile_url` performs
  *synchronous* variant materialization, so a 50-result search on cold
  variants would run 50 inline image transcodes. `Images::LabelSearch` guards
  on `Doc#tile_variant_processed?` and returns `src: null` when cold, never
  falling back to the original (a caller must be able to tell "no thumbnail"
  from "here is a thumbnail"). `original_url` is always present.
  `Doc#display_url` enqueues `PreprocessDocTileVariantJob` per cold doc — an
  accepted, self-healing side effect, documented rather than suppressed.

#### The three flags

Computed per doc by `Images::CommercialLicense`:

- **`commercial_safe`** — may this appear in a product we *sell*?
- **`attribution_required`** — must the product visibly credit the author?
- **`share_alike`** — does the license carry a copyleft/SA obligation?

`commercial_safe` is true when either:

1. `source_type == "OpenAI"` — we generated it, it's ours; or
2. the resolved license type matches the commercial allowlist: `public domain`,
   `CC0`, or a `CC BY` variant **without** `NC` and **without** `SA`
   (case-insensitive, tolerant of version suffixes like `3.0`).

It is false when any of:

- the license type contains `NC` / `non-commercial` / `noncommercial`
- the license type is `private`
- the license is blank, missing, or unrecognized
- `source_type` is `GoogleSearch` or nil (scraped/unknown provenance)
- the originating `OpenSymbol` is flagged `protected_symbol`

**The predicate fails closed:** anything unrecognized is unsafe. A false
negative costs one missing picture; a false positive costs a license violation
in a product being sold.

`attribution_required` is true for any `CC BY*` variant (including NC and SA
forms — the obligation exists regardless of whether we can sell it).
`share_alike` is true for any `*-SA` variant.

#### Share-alike is opt-in

`CC BY-SA` (953 docs) is **excluded from `commercial_safe` by default.**
Share-alike is plausibly viral onto the derivative work, which conflicts with
selling a closed-license printable. This is a legal judgement call, not a
settled fact, so the code takes the conservative position and offers an
override: `include_share_alike=true` flips SA licenses to commercial-safe for
callers who have decided a given product can carry the obligation.

#### Request filters

`commercial_safe=true` filters results to safe images only. It is **not** the
default — internal/preview work legitimately wants the whole library, and a
filtered default would silently hide images during exploration. The printables
sellable-product path opts in explicitly.

`include_share_alike=true` is only meaningful alongside `commercial_safe=true`;
it is ignored otherwise (unfiltered requests already return everything).

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
- `commercial_safe=true` filters; omitted does not
- `include_share_alike=true` admits SA images that are otherwise filtered out

Plus a unit spec for `Images::CommercialLicense` driven by the **real license
strings measured in the library**, not invented ones:

| Input | `commercial_safe` | `attribution_required` | `share_alike` |
|---|---|---|---|
| `source_type: "OpenAI"`, no license | true | false | false |
| `{"type": "public domain"}` | true | false | false |
| `{"type": "CC BY"}` / `"CC By"` / `"CC By 3.0"` | true | true | false |
| `{"type": "CC BY-SA"}` / `"CC By-SA 3.0"` | false | true | true |
| `{"type": "CC BY-SA"}` + `include_share_alike` | true | true | true |
| `{"type": "CC BY-NC-SA"}` | false | true | true |
| `{"type": "CC BY-NC"}` | false | true | false |
| `{"type": "private"}` | false | false | false |
| `source_type: "GoogleSearch"`, no license | false | false | false |
| license nil / `{}` / unrecognized type | false | false | false |
| `source_type: "OpenSymbol"` → license via `matching_open_symbols` | per symbol | per symbol | per symbol |

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

## Licensing audit rake task

`lib/tasks/image_licenses.rake` → `rake images:license_audit`

Prints the library-wide breakdown (the table in § Licensing) on demand:
count by resolved license type, by `source_type`, and totals for
commercial-safe / attribution-required / share-alike. Runnable against
production so the numbers can be refreshed as the library grows — the
2026-07-22 figures will drift.

Read-only. No writes, no S3 access.

## Open questions

None.
