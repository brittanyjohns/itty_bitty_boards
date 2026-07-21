# SpeakAnyWay — Backend

Ruby on Rails 8 app (hybrid: API + HTML views). Deployed on EC2 via Hatchbox.

This file is the always-loaded **hub**: stack, commands, conventions, and
cross-cutting invariants. Deep subsystem documentation lives in
`.claude-notes/*.md` (the **spokes**) — see the subsystem map below and read
the relevant spoke before working in that area. Note: `.claude-notes/` is
gitignored; durable subsystem docs are force-added (`git add -f`), while
one-off handoff/scratch files stay untracked and local.

## Stack

- **Framework:** Rails 8 (`~> 8.0`; `config.load_defaults 8.0`). Upgraded from
  7.1 (EOL) in #56 — see `config/initializers/new_framework_defaults_7_2.rb` /
  `_8_0.rb` for the documented framework-default overrides. Schema annotations
  use `annotaterb` (the Rails 8-compatible successor to the retired `annotate`
  gem).
- **Language:** Ruby
- **Database:** PostgreSQL on **managed AWS RDS** (Multi-AZ, automated backups +
  PITR), migrated off the shared EC2 box in Phase 2a of the scaling roadmap
  (#392). The `production:` block in `config/database.yml` reads **all**
  connection params from ENV — `DATABASE_HOST`, `DATABASE_NAME`,
  `DATABASE_USERNAME`, `ITTY_BITTY_BOARDS_DATABASE_PASSWORD`, `DATABASE_PORT`,
  `DATABASE_SSLMODE` — so the app is repointed by changing Hatchbox ENV, not
  code. **When `DATABASE_HOST` is unset the block falls back to the old on-box
  local-socket defaults** (`itty_bitty_boards_production` / role
  `itty_bitty_boards` / socket), so the config is backward-compatible and the
  rollback is "unset `DATABASE_HOST`". Cutover procedure (dump+restore, downtime
  steps, verify, rollback): `docs/rds-migration-runbook.md`. Staging shares the
  prod EC2 box and continues to point at the same managed DB unless its own
  `DATABASE_*` ENV is set.
- **Auth:** Devise + devise-jwt
- **Authorization:** Pundit
- **Background jobs:** Sidekiq (v7) + Redis
- **Video (tile clips):** `VideoTranscoder` shells out to `ffmpeg`/`ffprobe`
  (no gem). `ProcessTileVideoJob` runs after `upload_video` to enforce the 30s
  cap (trims, doesn't reject) and transcode .mov/HEVC → H.264 mp4, then
  rebroadcasts the board so the editor picks up the swapped URL. **Everything
  is gated on `VideoTranscoder.available?`** — when the binaries are missing
  the controller narrows what it accepts (mp4/webm, 25 MB) and the job leaves
  the original clip attached rather than destroying it. Keep that contract:
  never accept an upload format we can't guarantee we can make web-safe.
  YouTube tiles may also carry optional `start_seconds`/`end_seconds` trim
  points in `data["video"]`, validated by `BoardImage.parse_video_range` and
  written only via `attach_youtube_video` (422 `invalid_video_range`). Details:
  `.claude-notes/video-tile-trim-range.md`.
- **Video demo boards** are built by `VideoBoards::BoardSeeder`, shared by
  `lib/tasks/video_demo.rake` (curated `songs`/`asl` configs) and
  `Admin::VideoBoardsController` (`/admin/video_boards`, a form). Two rails are
  load-bearing: **creating never publishes** (`published: false` on new records
  only, so a re-seed can't un-publish a reviewed board) and **an empty board
  can't be published**. The service only ever takes an already-parsed
  `youtube_id` + range — callers validate with `YoutubeUrlParser.video_id` and
  `BoardImage.parse_video_range` (`{}` = no trim, `nil` = reject) *before* any
  write. Admin-created boards carry `settings["video_seeder"] = true`, which is
  what the admin list/publish/destroy actions scope to.
- **Cache:** `Rails.cache` is a **Redis cache store** in production
  (`config/environments/production.rb`, issue #474) — namespaced `ibb_cache` so
  keys can't collide with Sidekiq / Rack::Attack on the shared Redis, with a
  fail-open `error_handler` (a Redis blip logs + returns nil, never 500s a
  request). `CACHE_REDIS_URL` overrides the instance/db (defaults to
  `REDIS_URL`). Dev = `:memory_store`/`:null_store`, test = `:null_store`
  (stub `Rails.cache` in specs that need it).
- **Payments:** Stripe and RevenueCat (via webhook). Admin revenue metrics
  combine both via `MissionControl::RevenueMetrics` — see
  `.claude-notes/billing-and-plans.md`.
- **File storage:** S3 (Active Storage)
- **Email:** Action Mailer over Gmail SMTP. Both environments authenticate
  against `smtp.gmail.com` when `SMTP_USERNAME`/`SMTP_PASSWORD` are set (a
  Google Workspace account + App Password); production falls back to the
  `smtp-relay.gmail.com` IP-allowlisted relay when no credentials are present.
  `SMTP_ADDRESS` overrides the SMTP host. The `mailgun-ruby` gem is in the
  Gemfile but is not the active delivery transport. Diagnose delivery with
  `bin/rails 'mail:test[you@example.com]'`.
- **TTS/Audio:** AWS Polly
- **AI:** OpenAI API (`ruby-openai`) — board generation, scenario builder,
  image generation
- **Serializers:** jsonapi-serializer gem
- **Hosting:** Hatchbox / EC2
  - Production: `main` branch → `speakanyway.com` (Hatchbox app
    `670kd.hatchboxapp.com`)
  - Staging: `staging` branch → `https://ypk9e.hatchboxapp.com`. **Deploy
    branch, not a development branch** — it mirrors `main`. Promote by
    force-pushing `origin/main` onto `staging` and then running the
    `Deploy staging (manual)` workflow via `workflow_dispatch` (see
    `.github/workflows/staging-deploy.yml`) — pushing to `staging` alone does
    NOT trigger a deploy; the workflow is what fires the Hatchbox deploy.
    (Brittany's `deploy-staging` skill does both steps.) Commits on `staging`
    that aren't on `main` are drift and will be wiped by the next promotion's
    force-push. Staging-specific behavior is gated on
    `ENV["STAGING"] == "true"` — both envs run with `RAILS_ENV=production`.
    Use the `AppEnv.staging?` helper (`app/models/app_env.rb`) in app code.
  - **Staging skips paid OpenAI calls.** When `AppEnv.staging?`,
    `OpenAiClient#create_image` / `#create_image_variation`,
    `ImageVariationService`, and `ImageEditService` return the bundled
    `public/placeholder.jpeg`; `BoardScreenshotVisionService#parse_board`
    returns a placeholder grid. The rest of each pipeline runs normally.

## Frontend

- React/Ionic frontend served separately (not via Rails asset pipeline)
- Communicates with Rails backend via JSON API endpoints
- Some HTML views for auth flows and admin dashboard, but most user-facing UI
  is React
- Local development: Rails server on http://localhost:4000, React dev server
  on http://localhost:8100
- Frontend local repo is `../itty-bitty-frontend`

## Routing

- Routes are mixed: some at root level, some under `/api/`, some under
  `/api/v1/`
- JSON API routes are generally under `namespace :api` (with
  `defaults: { format: :json }`)
- Auth routes (`/api/v1/`) live in `app/controllers/api/v1/`
- Do not assume all routes follow a single convention — check
  `config/routes.rb`

## Code conventions

- Standard Ruby style — no unnecessary metaprogramming
- Fat models, thin controllers
- Use snake_case everywhere (Ruby/Rails standard)

## Common commands

- `bin/dev` — start Rails server in development http://localhost:4000
- `bin/console` — open Rails console
- `bin/rails db:migrate` — run database migrations
- `bin/rails db:seed` — seed the database
- `bundle exec sidekiq` — start Sidekiq worker
- `bundle exec rspec` — run tests
- `bin/rails 'mail:test[you@example.com]'` — diagnose mail delivery: prints
  the resolved ActionMailer config and sends a test email, surfacing the real
  SMTP error

## Reading production logs (CLI)

Hatchbox runs Puma + Sidekiq as **user** systemd services on the deploy
user, so logs are in the user journal (no sudo needed).

- `bin/prod-logs` — tail production Puma (`itty-bitty-boards-server.service`) over SSH
- `bin/prod-logs worker` — tail production Sidekiq (`itty-bitty-boards-sidekiq.service`)
- `bin/prod-logs all` — tail every `itty-bitty-boards-*.service` unit
- `bin/prod-logs <unit-name>` — tail a specific unit (pass-through)
- `bin/staging-logs [web|worker|all]` — same shape for staging
- `bin/prod-disk-audit` — read-only snapshot of disk + journald + nginx +
  app `log/` and `tmp/` sizes. Run any time you suspect disk pressure.

Env overrides: `PROD_HOST`, `PROD_WEB_UNIT`, `PROD_WORKER_UNIT`,
`PROD_ALL_UNIT` (and `STAGING_*` equivalents). `LINES=N` controls the
backlog size (default 200).

## Ops summary (details: `.claude-notes/ops.md`)

- `DiskSpaceAlertJob` emails `ADMIN_EMAIL` on root-disk pressure (hourly,
  Redis-debounced, skipped on staging). BetterStack hits `/up` every 3 min
  (stock `Rails::HealthController`; configured in BetterStack's UI, nothing
  in-repo to tune).
- **AppSignal APM** is active in production/staging only; prod and staging
  report as separate environments split by `APPSIGNAL_APP_ENV` (staging must
  set it), not Rails env. `/up` is excluded from metrics; params/session
  filtering drops secrets.
- **Rack::Attack** throttles only write/auth/AI-generation paths, all
  ENV-tunable; counter store is an explicit Redis `RedisCacheStore` (never
  `Rails.cache`, which is `:null_store` in test), fail-open; disabled in the
  test env by default; 429 responses are generic.

## Cross-cutting invariants

These hold everywhere in the codebase; a change that would violate one needs
an explicit decision, not a drive-by edit.

- **Usage must never break.** SpeakAnyWay is an AAC app: board reads,
  board-load, and audio playback are never throttled, locked, plan-gated, or
  broken by a downgrade. When unsure whether a path is read-critical, leave
  it ungated.
- **HTTP error semantics:** **402** = credit exhaustion only
  (`insufficient_credits`). **429** = true rate limiting only. **403** =
  permission/plan gates (`board_locked`, `pro_required`,
  `communicator_in_fallback`, `myspeak_id_limit_reached`, …). Never leak
  internals in API errors — generic messages only.
- **`User#paid_plan?` is the single paid-tier gate.** It checks both
  `plan_type` and `plan_status`; `basic_trial` and Stripe `trialing` count as
  paid while active. Never read `plan_type` directly for a paid-feature check.
- **`User#countable_board_count` / `at_board_limit?` is the single source of
  truth for board counting.** Builder sub-boards (`builder_child`) are
  excluded so a built tree counts as one; every creation gate routes through
  it.
- **Webhooks are the sole credit-grant authority** (Stripe + RevenueCat).
  Client-called endpoints may reflect plan state but never grant credits. All
  credit movement goes through `CreditService` and the immutable
  `credit_transactions` ledger; grants are idempotent on event id.
- **Downgrades retain, never delete.** Over-limit boards become read-only;
  over-limit communicators enter fallback mode (public MySpeak page stays
  up). No plan change destroys user content.
- **External-service failures fail soft.** Redis blips, PostHog, Mailchimp,
  and geolocation errors are rescued and logged — they can never 500 a
  request or a webhook.
- **Safety-profile emergency info is only served by the gated `safety_view`
  POST** — never on public page-open.
- **Third-party sends are env-gated to production** (Mailchimp journeys,
  PostHog captures; staging excluded via `AppEnv.staging?`) so non-prod can't
  email or track real users.

## Subsystem map (read the spoke before working in the area)

| Spoke | Covers |
|---|---|
| `.claude-notes/billing-and-plans.md` | Stripe + RevenueCat subscription paths, webhooks + idempotency, no-card reverse trial, soft trial, Partner Program (`partner_pro`), email-only (passwordless) signup, plan-switch endpoints + error contract, `paid_plan?` details, MySpeak ID limit, downgrade rules (board read-only lock + `make_editable` cooldown, communicator fallback + `keep_signable`, sandbox→active promotion), Mission Control revenue metrics |
| `.claude-notes/credits.md` | AI credit ledger: `CreditService`, feature costs, `check_credits!` / 402 contract, grant lifecycle + refresh/expiry cron jobs, menu image budget + refunds, free first-fill image generation, credits rake tasks, beta entitlement audit |
| `.claude-notes/marketing-integrations.md` | Mailchimp CRM sync + Customer Journeys (all journey keys + ENV wiring), dual-welcome design, plan-welcome idempotency, PostHog server-side events + `distinct_id` contract |
| `.claude-notes/safety-profiles.md` | MySpeak safety pages: gated emergency-info reveal, view logging + parent alerts + throttling, coarse IP geolocation, random slugs + legacy-slug fallback |
| `.claude-notes/boards-and-teams.md` | Team permissions / owner-pinning, SLP→family hand-off, board assignment deep clone (`AssignmentCloner`), non-destructive board removal, board deletion warn+confirm (409), Board Sets (BoardGroup) CRUD + limits, responsive layouts (sm/md derived from lg), OBF/OBZ import copyright policy, Make a Board From Screenshot |
| `.claude-notes/board-builder.md` | Board Builder wizard end-to-end: starter templates, complexity levels + `StructurePlanner`, Core 60/84 robust vocab sets + seed self-healing, communicator AAC profile, gestalt (GLP) support, all builder rake tasks |
| `.claude-notes/ops.md` | Monitoring/alerting details, AppSignal APM config, full Rack::Attack throttle rules + ENV vars |
| `.claude-notes/marketing-assets.md` | AAC Classroom Kit hosting: `MarketingAsset`, internal endpoints, marketing print style, QR scannability rule (do not re-add long UTMs to tag QRs) |

Related tracked docs: `docs/rds-migration-runbook.md`, `docs/stripe-setup.md`,
`docs/credits-handoff.md`, `.claude-notes/artifact-generation-services.md`,
`.claude-notes/classroom-kit-hosting-handoff.md`,
`.claude-notes/beta-end-founding-rate-handoff.md`. The SLP→parent handoff
permissions matrix lives in
`../speakanyway/marketing/.claude-notes/handoff-workflow.md`.

## Do not

- Do not install new gems without asking first
- Do not modify any deployment or server config files
- Do not log sensitive user data
- Do not expose internal errors in API responses — return generic messages to the client
- Do not hardcode any environment-specific values (use ENV variables)

## Testing

- Prefer FactoryBot.build over create where possible
- Add focused tests for changed behavior
- Avoid destructive S3/ActiveStorage behavior in tests
- New features and bug fixes always get tests (per `~/.claude/CLAUDE.md`).
  Don't backfill tests for _existing_ code unless asked.
- Rails test environment uses `:null_store` for Rails.cache — stub
  `Rails.cache` in specs that depend on caching behavior
- Avoid `travel_to` with past timestamps for Redis keys (TTLs expire
  immediately); use future times or freeze time instead
- After spec changes, run the tests that depend on the changed code to ensure
  no regressions. Use `bin/rspec --only-failures` to rerun only failed specs.
- Services that query `DEFAULT_ADMIN_ID` (`FringeTemplates`, `RobustSets`,
  `VocabSets`) need the admin created with that specific ID in specs —
  `create(:admin_user)` assigns a random ID and the lookups return nil.
  Use: `User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)`

## Documentation rules (this file + the spokes)

- **Verify against the codebase before writing.** Read Gemfile,
  `config/application.rb`, and `routes.rb` first. Do NOT claim "API-only"
  without checking `config.api_only`; no compliance claims (FedRAMP, HIPAA,
  SOC2) unless explicitly evidenced in code; list actual dependencies, not
  assumed ones. If unsure, say "unverified" rather than asserting.
- **Document the invariant, not the fix.** "Tile upserts key on
  `obf_button_id`" belongs in a spoke; the story of the bug that motivated it
  belongs in the PR/issue. Exception: keep a short note when the history
  encodes a trap a future change could reintroduce.
- **Keep this hub lean.** Subsystem detail goes in the matching
  `.claude-notes/` spoke (create one if needed and `git add -f` it — the
  directory is gitignored). A subsystem's presence here is its map row plus,
  at most, a bullet in the invariants list.
- Issue/PR numbers are fine as pointers (`see #384`), not as narrative
  anchors or section titles.

## Bash & Long-Running Commands

When running long bash commands (bundle update, migrations, test suites), use
appropriate timeouts and check completion status explicitly rather than
polling repeatedly.
