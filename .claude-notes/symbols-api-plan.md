# SpeakAnyWay Symbols API — Design & Build Plan

_Last updated: 2026-05-23_

## Decisions locked in

- **Phased rollout.** Build the internal catalog + skin tones first; design the
  schema so a public, OpenSymbols-style API can layer on later without rework.
- **Skin tones via AI re-render.** Reuse the existing OpenAI image-edit pipeline
  (`ImageEditService`) to regenerate skinnable symbols in 5 tones, with a human
  QA gate before anything is published.

## How OpenSymbols works (the parts we're copying)

It's a search + attribution layer over many symbol *repositories* (ARASAAC,
Mulberry, Twemoji, …), each with its own license. Each API result returns:
`symbol_key, name, locale, license, license_url, author, author_url, source_url,
repo_key, hc (high-contrast), extension, image_url, skins`.

Skin tones are **not** stored as separate rows. When `skins: true`, the image
URL contains a swappable token — either `variant-SKINTONE` (`pic.variant-dark.png`)
or an emoji `-SKINHEX` code (`1f467-1f3fd.svg`). Five tones: light `1f3fb`,
medium-light `1f3fc`, medium `1f3fd`, medium-dark `1f3fe`, dark `1f3ff`.
Access = shared secret → short-lived token. `401 token_expired`, `429 throttled`.

## What we already have

- **`Image`** — the logical concept/word (label, locale, part_of_speech, audio).
  Equivalent to their `name`.
- **`Doc`** — one visual rendering of a concept; polymorphic `documentable`,
  holds the S3 attachment + a 288px webp `tile_url` variant
  (`TILE_VARIANT_TRANSFORMATIONS`), plus `license` (jsonb), `source_type`,
  `original_image_url`. This is where a *variant* naturally lives.
- **`OpenSymbol`** — our cache of *their* symbols (consumer side). Already has
  `symbol_key, repo_key, license, author, hc, extension`.
- **`BoardImage`** — placement of an image on a board.
- **Storage** — S3 (`amazon`, public) + optional CloudFront via `CDN_HOST`;
  variants via libvips → webp.

We already *consume* OpenSymbols. This project flips us to the *producer* side.

## The four real gaps

1. No skin-tone / variant concept anywhere.
2. S3 keys are random ActiveStorage hashes — not organized by repo/symbol/variant,
   so the URL-swap trick that makes skins cheap isn't possible yet.
3. License/attribution is loose freeform jsonb — not safe to expose publicly.
4. No public contract (token, rate limit, docs, stable schema).

## Where it lives

Build **inside the existing Rails app**, under a dedicated `/api/v2/symbols`
namespace, as a clean bounded module. Reuses Image/Doc/S3/variant pipeline,
Sidekiq, and auth. Do **not** spin up a separate service yet — premature.
Keep controllers/serializers self-contained so it *could* be extracted later.

## Data model

Add producer-side tables, decoupled from messy user-generated `Image`s
(which are private, experimental, and inconsistent):

**`symbols`** (canonical concept)
- `symbol_key` (unique, stable, e.g. `cat-1-2fcbe1a4`)
- `name`, `label`, `locale`, `part_of_speech`
- `repo_key` / source identifier
- license fields: `license`, `license_url`, `author`, `author_url`, `source_url`
- `search_string`, `tags`
- `safe` (bool), `hc` (high-contrast bool)
- `skinnable` (bool — does it depict a person/body part?)
- `status` (active / disabled)
- provenance: `origin` (own_ai / open_source / imported) — drives licensing
- `base_variant_id` (the default/no-tone image)

**`symbol_variants`**
- `belongs_to :symbol`
- `variant_type` (enum: base, skin_tone, high_contrast, color)
- `skin_tone` (enum: light / medium_light / medium / medium_dark / dark; store hex)
- image storage — own `Doc` (polymorphic already supports it) **or**
  `has_one_attached :image`; reuse `TILE_VARIANT_TRANSFORMATIONS`
- `generation_source` (ai / manual / passthrough)
- `status` (pending / approved / rejected) — QA gate
- `checksum`, timestamps

Map fields 1:1 to the OpenSymbols response so the public API can mirror their
schema — our own consumer code already speaks it, and any OpenSymbols-compatible
client will work against ours. Expose `skins: true` and variant URLs using the
same `variant-SKINTONE` naming convention.

## S3 / storage organization

Move the *public catalog* off random ActiveStorage keys to a predictable layout:

```
symbols/{repo_key}/{symbol_key}/base.webp
symbols/{repo_key}/{symbol_key}/variant-light.webp
symbols/{repo_key}/{symbol_key}/variant-medium-dark.webp
```

Recommended approach: keep ActiveStorage as the internal working store, and add
a **publish step** (Sidekiq job) that copies *approved* variants into a clean
catalog prefix (or dedicated bucket) with deterministic keys, fronted by
CloudFront (`CDN_HOST` already wired). This decouples messy internal storage
from clean, swappable public URLs — and the deterministic keys are exactly what
makes the OpenSymbols-style skin-tone URL swap work.

## Skin-tone AI re-render pipeline

- New `GenerateSkinToneVariantsJob(symbol_id)`.
- For each of 5 tones, call `ImageEditService` with a tone-specific prompt
  ("…rendered with {medium-dark} skin tone, everything else identical, no text,
  transparent background…").
- **Gate on `skinnable`.** First run an AI classifier ("does this symbol depict
  a person / body part?") so we don't burn credits re-rendering a coffee cup.
- Each result → `symbol_variant` (status `pending`) → **admin QA queue** →
  approve/reject → publish to catalog. AI tone edits drift; human review is
  non-negotiable for a published catalog.
- Cost guardrails: admin-only batch, idempotency, dedupe. **Staging already
  skips paid OpenAI image calls** (per backend CLAUDE.md) — build & test the
  whole pipeline there for free, returns `placeholder.jpeg`.

## Public API surface (Phase 2 — design now, build later)

Mirror OpenSymbols v2 for drop-in interop:

- `POST /api/v2/symbols/token` — shared secret → short-lived JWT.
- `GET /api/v2/symbols?q=&locale=&safe=&repo:=&hc:=` — returns array matching
  their result schema + `skins`.
- Serializer fields: `symbol_key, name, locale, license, license_url, author,
  author_url, repo_key, hc, extension, image_url, skins, details_url`.
- Rate limiting via rack-attack → `429 { throttled: true }`; expired token →
  `401 { token_expired: true }`.
- Only expose symbols with complete, redistributable licenses.

## ⚠️ Licensing caution (read this before re-rendering anything)

You **cannot** relicense a symbol derived from a CC BY-NC-SA / NC source by
AI-re-rendering it — derivatives inherit the source license. So the publicly
redistributable catalog must be limited to:

1. **Your own original AI-generated symbols** (you own/set the license), and
2. **Genuinely open sources** (CC BY / CC0).

Track `origin` + license per symbol. AI-re-rendering an ARASAAC (NC) image into
5 skin tones and serving it from a public API would be a real legal problem.
This is the thing that bites in two weeks if we skip it now.

## Phasing

- **Phase 0 — schema + organization (internal only).** Add `symbols` +
  `symbol_variants`; backfill from admin-owned `Image`/`Doc` rows; stand up the
  catalog S3 prefix + deterministic keys + CloudFront publish job.
- **Phase 1 — skin tones.** `skinnable` classifier, `GenerateSkinToneVariantsJob`,
  admin QA queue, frontend skin-tone picker reading variants.
- **Phase 2 — public API.** Token endpoint, OpenSymbols-compatible search,
  rate limiting, license gating, docs page, shared-secret issuance.

## Open questions for next session

- Default license for your own original symbols? (CC BY? Your own terms?)
- One catalog bucket, or a prefix in the existing bucket?
- Which core word set to seed skin tones with first?
- Reuse `Doc` for variant storage, or give `symbol_variants` its own attachment?
