# Internal API — image search by label

**Date:** 2026-07-22
**Status:** Design approved in conversation; spec pending review
**Motivation:** Build printable products from the existing SpeakAnyWay image
library. The printables pipeline needs to look up images by word, get a
print-quality URL, and download the bytes directly from S3/CloudFront.

## Problem

The internal API (`/api/internal/`) can create and generate images, but has no
way to *find* one. The printables repo currently has no path from "I need a
picture of an apple" to a downloadable file.

Two constraints shape the design:

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
- No changes to the public/user-facing image API.

## Endpoints

Both mount under the existing `namespace :internal`, inheriting
`API::Internal::ApplicationController` (bearer `INTERNAL_API_KEY`,
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

## Matching

`match=exact` (default): try `Image.search_by_exact_label`. If that returns
nothing, fall back to `Image.search_by_label` (prefix tsearch). The response's
`match` field on each result records which one actually hit (`"exact"` or
`"prefix"`) so the caller can tell a precise hit from a fuzzy one.

`match=prefix`: skip straight to `search_by_label`.

Rationale: for a printable you usually know the word and want *that* picture,
but labels are stored inconsistently enough that a hard exact-only match would
produce spurious empty results.

## Scope

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

## Result shape

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

## Licensing — `commercial_safe`

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

## Testing

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

## Documentation

- **`README.md`** — add both endpoints to the existing `## Internal API`
  section, matching its curl-example style. Also add an **endpoint index** at
  the top of that section (currently the reader has to scroll ~400 lines to
  learn what exists), and document the `src` vs `original_url` distinction
  explicitly — it's the single most likely thing for a consumer to get wrong.
- **`.claude-notes/internal-api.md`** — new spoke (`git add -f`; the directory
  is gitignored) covering the internal API surface, the auth model, the
  public-bucket/CDN download path, and the licensing rule. The surface is
  currently documented piecemeal inside `marketing-assets.md`, and more
  endpoints are planned.
- **`CLAUDE.md`** — one row in the subsystem map pointing at the new spoke.
- **`CHANGELOG.md`** — user-facing entry.

## Open questions

None.
