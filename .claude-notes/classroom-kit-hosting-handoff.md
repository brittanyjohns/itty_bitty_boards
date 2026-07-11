# Handoff: host + assemble the AAC Classroom Kit (SHIPPED + LIVE)

**Date:** 2026-07-06 · **Status:** DONE — both PRs merged to main, deployed to prod,
kit minted and hosted live.

## Live result

- **KIT_DOWNLOAD_URL:** `https://drpw8a28ruy1n.cloudfront.net/marketing_assets/classroom-kit.pdf`
  (stable across re-runs; CloudFront in front of the prod S3 bucket). 5 artifacts,
  6 pages. Drop this into the `/classroom` page's `KIT_DOWNLOAD_URL`.
- Backend PR: itty_bitty_boards#457 (merged). Printables PR: speakanyway-printables#156 (merged).
- Mint command (prod): `SPEAKANYWAY_API_BASE_URL=https://670kd.hatchboxapp.com npm run marketing-kit -- --sample-profile=<id>`

## Operational gotchas (learned the hard way — read before re-minting)

- **Reference the sample profile by NUMERIC ID, not slug.** `bin/rails marketing:seed_kit_sample_profile`
  prints the id (was 12 in the shared RDS). The internal profiles API 404s on the
  sample *slug* (`speakanyway-sample`) even though the record is findable by slug
  in a console — an unresolved quirk (possibly a read path). Passing the id works.
  TODO: investigate the slug 404 in `API::Internal::ProfilesController#find_profile!`.
- **Seeding on Hatchbox must use the SERVER's injected env, not a manual `RAILS_ENV=production`.**
  A manual `RAILS_ENV=production bin/rails ...` reads DB config from figaro
  (`config/application.yml`) which can point at a DIFFERENT database than the
  running app (Hatchbox injects the real RDS creds into the process env, not an
  EnvironmentFile). Seed by inheriting the running server's env:
  `PID=$(systemctl --user show -p MainPID --value <app>-server.service); xargs -0 -a /proc/$PID/environ env -- bin/rails <task>`.
- **Staging placeholders paid OpenAI image calls** (`AppEnv.staging?`), so a
  StoryTime board built on staging gets `placeholder.jpeg` tiles. Build the kit
  against **prod** for real StoryTime symbols. The Core Words poster (clones
  `core-84`'s existing curated images) is fine on either.
- Staging + prod share the managed RDS, so seeding once (via either box's app
  env) covers both. `core-84` was already seeded in the shared RDS.
- `from_vocab_set` clones a FRESH board each call (not idempotent per board), so
  repeated `marketing-kit` runs leave duplicate `MKT — Core Words Poster` boards
  (tagged `marketing`/`aac-kit`, admin-owned). Harmless scratch — the hosted kit
  PDF is static and references none of them — but clean up the extras if desired.

---

## (Original handoff — backend SHIPPED; printables side)
**Reference:** `.claude-notes/artifact-generation-services.md`,
`.claude-notes/name-tag-asset-sketch.md`,
`.claude-notes/classroom-kit-poster-generation-handoff.md`,
`.claude-notes/internal-from-vocab-set-handoff.md`,
printables `.claude-notes/marketing-artifact-generator-handoff.md` + `saw-internal-api.md`.

## What this is

The AAC Classroom Kit = a **free marketing lead magnet**: one bundled print-ready
PDF (4–5 artifacts) hosted at a stable public URL that drops into the `/classroom`
page's `KIT_DOWNLOAD_URL`. **Not a sellable product; never published to any
marketplace; no cron/auto-trigger.** Every QR points at bare
`speakanyway.com/classroom?utm_source=aac_kit&utm_medium=print&utm_campaign=classroom_kit&utm_content=<artifact>`.

## Division of labour (decided)

- **Rails backend** = render each artifact + **host** the final PDF (Grover for
  HTML→PDF; S3 `public:true` for stable URLs). It has no PDF-merge lib.
- **printables** (`speakanyway-printables`) = orchestrate + **merge** the
  per-artifact PDFs (`pdf-lib`, already a dep + `test:merge-pdf`) into one kit,
  then upload the combined PDF back to the backend to get the public URL.

## Backend — SHIPPED in this PR

- `MarketingAsset` model + `POST/GET /api/internal/marketing_assets(/:slug)` —
  hosts a PDF at a deterministic S3 key → stable public CDN URL. Idempotent
  (`upsert_pdf!`). This is the `KIT_DOWNLOAD_URL` mechanism.
- `GET /api/internal/marketing_artifacts/name_tag.pdf?qr_target_url=&per_page=` —
  generic name-tag sheet (variant A), `Marketing::NameTagSheet` + ERB.
- `qr_target_url:` on `GenerateSafetyIdCard`/`GenerateDeviceTag`/`BaseAssetGenerator`
  + the internal profiles `PATCH`, so the kit tags' QR → `/classroom`.
- `bin/rails marketing:seed_kit_sample_profile` — the sample safety Profile the
  tags render from.
- `POST /api/internal/boards/from_vocab_set` (already shipped, #455/#456) — the
  Core Words poster source (`core-84`).
- Tests: `spec/models/marketing_asset_spec.rb`,
  `spec/requests/api/internal/marketing_assets_spec.rb`,
  `spec/requests/api/internal/marketing_artifacts_spec.rb`,
  `spec/services/communicators/asset_generator_qr_override_spec.rb`, and a new
  case in `spec/requests/api/internal/profiles_spec.rb`.

## printables — the remaining orchestration (next PR)

New standalone script `src/plugins/aac/scripts/marketing-kit.ts`
(`npm run marketing-kit`), NO orchestrator/publisher/Notion/marketplace. Steps:

1. **Core Words poster** — `createBoardFromVocabSet("core-84", { name: "MKT — Core Words Poster", tags: ["marketing","aac-kit"] })`
   (new client method → `POST /api/internal/boards/from_vocab_set`) →
   `exportBoardPdf(id, { qr_code:true, qr_target_url: .../classroom?...utm_content=core_poster, screen_size:"lg" })`
   (+ optional low-ink `hide_colors:true`).
2. **StoryTime board** — `createBoard({ board_creation_type:"scenario", topic, tags:[...], name:"MKT — StoryTime …" })`
   → `waitForBoardComplete(id, { waitForCellImages:true, postCompleteBufferMs:15000 })`
   → `exportBoardPdf` with `utm_content=story_time`.
3. **Safety + device tags** — ensure the sample profile (rake), then
   `PATCH /api/internal/profiles/:id { qr_target_url: .../classroom?...utm_content=safety_tag|device_tag, profile:{} }`
   → read `assets.safety_id_pdf_url` / `device_tag_pdf_url` from `GET /api/internal/profiles/:id` → fetch the PDFs.
   (Sample profile id/slug printed by the rake — pass via env/arg.)
4. **Name tag** — `GET /api/internal/marketing_artifacts/name_tag.pdf?qr_target_url=.../classroom?...utm_content=name_tag`.
5. **Merge** all artifact PDFs with `pdf-lib` (reuse/extract the merge in
   `src/generator/steps/09-merge-final-pdf.ts`) into `classroom-kit.pdf`; keep
   the individual PDFs in `tmp/marketing-artifacts/classroom-kit/`.
6. **Host** — `POST /api/internal/marketing_assets { slug:"classroom-kit", title, file: classroom-kit.pdf }`
   → print the returned `url`. That is the `KIT_DOWNLOAD_URL`.

Also: add `tags?`/`settings?` to `CreateBoardInput` + `createBoardFromVocabSet` /
`uploadMarketingAsset` client methods in `src/plugins/aac/lib/speakanyway.ts`;
extend `src/plugins/aac/scripts/test-speakanyway.ts` (gate on the API token).

## Env / deploy

- Curated sets must be seeded in the target env (`bin/rails vocab_sets:seed`) or
  `from_vocab_set` 404s. Run `marketing:seed_kit_sample_profile` before a build.
- `CDN_HOST` should be set in prod (CloudFront) for a clean URL; else the raw S3
  public URL is used (S3 is `public:true`). No new ENV var, no migration risk
  beyond the `marketing_assets` table.
- Re-running the whole pipeline is idempotent: same slugs → same URLs, new bytes.

## Git rules (Brittany's)

Feature branch off `origin/main` in a worktree. Never push to `main` or merge —
open the PR and stop. Conventional Commit (`feat:`). One backend PR (this),
one printables PR (next).
