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
  `bin/rails 'mail:test[you@example.com]'`. **No mail ever carries an
  attachment.** Templates render the header logo as `@logo.url`, which
  `ApplicationMailer.email_logo_url` resolves to an absolute URL for
  `public/email-logo.png` on the mailer's own host (override with
  `EMAIL_LOGO_URL`). Inline `cid` attachments are not an option: clients list
  every attachment part — inline ones included — so the logo showed up as a
  downloadable file. Transactional mail is therefore single-part `text/html`,
  so specs must read bodies as `(mail.html_part || mail).body`. **Staging
  delivers no mail:** `StagingMailInterceptor` blocks every send when
  `AppEnv.staging?`, so nothing exercised on staging reaches a real inbox. Set
  `STAGING_MAIL_ALLOWLIST` (comma-separated exact addresses, or `@domain`
  suffixes) to let specific recipients through when testing a template;
  non-matching addresses are stripped from to/cc/bcc. `E2eMailInterceptor` is
  separate and pattern-scoped — it drops `e2e+*@speakanyway.com` in every
  environment. **A send leaves two possible signals and no more:**
  `MailDeliveryObserver` logs `[mail] delivered` (with the Message-ID) once
  the transport accepts a message, and `ApplicationMailer`'s `rescue_from`
  logs `[mail] delivery_failed` and re-raises. Neither can see an
  accepted-then-dropped message — that is only visible in Google Admin >
  Reporting > Email Log Search, keyed on the Message-ID, which is why the
  observer logs it.
- **TTS/Audio:** AWS Polly. Per-tile **custom audio** (a parent's recording)
  follows the same shape as tile video: `upload_audio` validates type/size
  against `BoardImage.accepted_audio_content_types`, attaches, and hands off to
  `ProcessCustomAudioJob`, which normalizes to mp3 via `AudioTranscoder` and
  rebroadcasts the board — everything gated on `AudioTranscoder.available?`, so
  a format we can't convert is refused rather than stored. **webm is not
  playable on iPad Safari, which is where communicators tap tiles**; never
  accept it without a working transcode. `data["using_custom_audio"]` is the
  flag that stops `Board#api_view_with_images` re-resolving a tile to the
  board's voice — set it only via `BoardImage#set_custom_audio!` /
  `#set_voice_audio!`, or a tile ends up pinned out of the board voice with no
  way back. Audio filename lookups (`AudioHelper#find_audio_by_filename`) are
  scoped to the record and its Image on purpose: filenames are
  `<label>_<voice>.mp3` and collide across accounts.
- **AI:** OpenAI API (`ruby-openai`) — board generation, scenario builder,
  image generation. Every text-to-image prompt is composed by
  `Images::PromptBuilder` and **always wraps** user input in the house style
  envelope; transparency and quality are API params, never prose. Details:
  `.claude-notes/image-generation.md`.
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
  `communicator_in_fallback`, …). **409** = state
  conflicts, some confirmable (`board_in_use`,
  `publish_cascade_confirmation_required`,
  `board_marketplace_edit_confirmation_required`) and some not
  (`board_marketplace_protected`, `public_page_exists`) — an unconfirmable conflict is always
  answered FIRST, or the client learns to retry into a wall. Never leak
  internals in API errors — generic messages only.
- **`User#paid_plan?` is the single paid-tier gate.** It checks both
  `plan_type` and `plan_status`; `basic_trial` and Stripe `trialing` count as
  paid while active. Never read `plan_type` directly for a paid-feature check.
  And `pro?` is a statement about LIMITS, not about which features exist: the
  Clinician plan is deliberately outside it (its 2-slot cap is the product),
  so a *feature* gate written as `pro?` silently refuses a clinician the thing
  their plan advertises — lending 403'd `pro_required` for every approved
  clinician, making the lend → claim → recycle workflow impossible end to end.
  A feature gets its own predicate (`User#can_lend?`), published on the
  api_view so the frontend gates on the same answer instead of re-deriving it
  from `pro`; the slot math stays exactly where it was.
- **A clinician application's license number is required only where one EXISTS,
  and the check is `on: :create`.** `LICENSE_REQUIRED_CREDENTIALS` is `slp`/`ot`;
  for `at_specialist` (RESNA ATP is optional, and the apply page recruits them
  in its H1) and `other` the field is optional and `verification_note` — the
  applicant's own words, its own column, never the admin-written `notes` — is
  the alternative. A hard requirement gated nobody: `N/A` filed a real
  application, so the field was a barrier to exactly the legitimate-but-
  unlicensed applicants a human reviewer exists to judge. Placeholders are
  refused where a license is required and DROPPED where it isn't (stored "N/A"
  reads like an answer in the admin queue), and a refusal always names the
  alternative — a rejection that only says no sends the applicant back to
  inventing a value. `on: :create` is load-bearing: applications filed before
  the rule carry no license at all, and `ClinicianApplications::Reviewer` SAVES
  the row to approve or deny it, so a blanket validation would make every
  historical SLP/OT application permanently unapprovable.
- **`settings["signup_method"]` is an allowlist (`User::SIGNUP_METHODS`), and it
  is written from a client param.** An account that arrived through
  `/clinicians/apply` carried `"standard"` — indistinguishable from any other
  web signup — so the one question that measures that page could not be asked.
  Only the signup request knows which form it came from, so the param is the
  fix; `User.sanitize_signup_method` resolves anything unrecognized to the
  caller's own default, because the value is read by analytics and Mailchimp
  segments and an unbounded string there is a segment nobody can enumerate. The
  stamp and the PostHog `signup_method` property must be the SAME resolved
  string — the capture used to hardcode `"standard"`, so the funnel and the
  admin view could disagree about one account. `API::ClinicianApplicationsController`
  carries a deliberately narrow bridge for clients that don't send it yet (first
  application, account under 15 minutes old, method still `"standard"`):
  provenance a later action can rewrite is worth nothing, so widening any of
  those three conditions defeats the point.
- **A board's `parent` is PROVENANCE, not ownership — never reassign it on a
  save.** `user_id` says who owns a board; `parent` says where it came from
  (the `Menu` a menu board was extracted from, the `Image` behind a
  predictive/category board, the `Board` that spawned a subboard, the
  `OpenaiPrompt` behind a generated one). Both update paths used to set
  `parent_type = "User"` unconditionally, which severed that link on the first
  rename — and no other column points back, so it was unrecoverable from the
  row. A menu board silently lost `original_menu_image_url` (the frontend's
  "View Menu" button), `menu_description`, and reported its *owner's* user id
  as `menu_id`. Route every assignment through `Board#sync_user_parent`, which
  re-points only a `"User"` parent (so a hand-off still follows the owner).
  Anything derived from `parent` must key on `parent_type`, never on
  `board_type`. Repair for already-severed rows: `rake menu_boards:relink`.
- **There is ONE creation cap and it is boards.** `User#countable_board_count`
  (own, non-predefined) and `at_board_limit?` are the single source of truth,
  and every creation gate routes through `BoardCreationLimit`. Board Builder
  sets used to be exempt — their boards were excluded from the count and the
  builder gated on a second `board_group_limit` cap instead — which is how a
  user at their board limit could run the wizard, receive a whole tree, and
  still be told "1 of 1 boards": the builder gated on one number while the
  dashboard reported the other, and neither matched `can_create_boards`. Two
  caps for one resource, since a Board Set cannot exist without boards. Board
  Sets are now uncapped and `board_group_limit` is gone. Two corollaries. A
  builder run has to fit ENTIRELY (`Boards::BuilderSetSize.worst_case(level)`,
  reserved up front) because the job cannot stop halfway — which is what makes
  the Board Builder a paid feature by arithmetic rather than by a flag, since
  Free's cap of 1 can never hold a set. And `board_limit` resolves from
  `plan_type` at READ time (`User.plan_limits_for`): it used to be stamped into
  `settings` by the five plan setters, so every user who ever changed plans
  carried a frozen copy and moving a constant reached nobody.
  `settings["board_limit"]` now means one thing only — a deliberate admin
  override, coerced with `.to_i` because the admin JSON path could store a
  String and make `countable_board_count >= board_limit` raise. Cleanup for
  historical stamps: `rake plans:clear_stamped_board_limits` (dry run by
  default). Every limit 422 carries a stable
  `error_code: "board_limit_reached"`; the existing `error` strings are left
  byte-identical, since some are sentences the frontend renders verbatim.
- **The countable set is also the /boards LISTING, and `Board.countable` is the
  one definition of it.** `User#countable_boards` and `BoardsController#index`
  both read that scope, so an empty boards page can never sit next to a "1/1
  boards" refusal again (issue #804). Before this they were different scopes:
  the listing ran `main_boards`, which drops menus, sub-pages, and — because
  `NULL != 'menu'` is NULL in SQL, not TRUE — every board with a NULL
  `board_type`. `board_type` has no column default and `set_board_type` is
  commented out of the callback chain, so NULL is the NORMAL state for anything
  minted outside `boards#create`; those boards counted while being unreachable
  and undeletable. Fixed with `MENU_BOARD_TYPE_SQL` (`IS DISTINCT FROM`) rather
  than a backfill — normalizing `board_type` would run `tmp_board_type`, whose
  `parent_type: "Image"` -> `"predictive"` mapping changes how folder tiles
  render. Admins keep the unfiltered listing (`current_user.admin?` carve-out):
  they are cap-exempt and DEFAULT_ADMIN_ID owns the predefined library.
- **One exemption from the cap: a PUBLISHED menu board is free**
  (`Board.published_menus`, mirrored per-row by `Board#counts_toward_board_limit?`
  and shipped as `counts_toward_limit` in `api_view`). Publishing is what makes a
  board public (`Board#viewable_by?`), so a shared menu is public infrastructure
  and stops being charged. `menus#create` and `#rerun` therefore gate themselves
  INLINE rather than via a blanket `before_action` — the publish intent has to be
  known first, or the one board a capped user is allowed to add would be the one
  board they could never create. Unpublishing re-charges it and may put the user
  over the cap; that is the ordinary over-limit state, not an error.
- **There is ONE communicator-slot answer and it is
  `Permissions::CommunicatorLimits.slots_for`.** A `loaner` occupies the
  lender's slot until a family CLAIMS it, and the slot returns on claim — that
  is what the Clinician plan sells. Two payload fields used to answer "am I out
  of slots" and they were opposites at the same instant:
  `comm_account_limit_reached` summed the paid AND sandbox limits against EVERY
  communicator (matching no gate anywhere) while `paid_comm_account_limit_reached`
  tracked loaner+active, so a clinician at 2/2 with one out on loan read `false`
  in the field the pre-form cap card gated on and 422'd on the create. One
  backend ambiguity, two frontend bugs — one panel printed "2 of 2 slots in use"
  directly above "No slots available". `slots_for` returns
  `{ limit, used, available, on_loan, active, limit_reached }`, is published as
  `communicator_slots`, and **both enforcement gates decide through it**
  (`can_create?`'s self-create branch and `can_claim?`, via
  `refuse_when_out_of_slots`) — agreement between the number shown and the
  answer given is structural, not two copies of the same arithmetic. Both raw
  flags now read out of it and stay in the payload only for the frontend that
  ships today; gate anything new on `communicator_slots`. The limit is
  `slot_limit_for` (`communicator_slot_limit` override ?? `paid_communicator_limit`,
  plus Pro add-on slots) — never `settings["paid_communicator_limit"]` read
  directly, which is how `accounts_included` showed an overridden account one
  number while the gate refused it on another. Sandbox communicators have their
  own quota and never occupy a slot.
- **`ChildAccount#is_demo` says SANDBOX, not "test data"; the test/internal
  predicate is `User#demo_user?`.** `is_demo` is a legacy alias for `sandbox?`,
  and `Permissions::CommunicatorLimits.self_create_status` forces every Free
  user's self-create to sandbox (their one full slot is claim/hand-off only) —
  so a genuine Free parent's communicator reads `is_demo: true`, correctly. An
  analytics or marketing filter keyed there would drop exactly the cohort those
  exclusions exist to protect. The real one lives on the USER (`demo_user?` /
  `User.demo_accounts` — email pattern + the `internal_account` flag), and is
  already what the Mailchimp `DEMO_USER` merge field, the journey gate, and
  Mission Control's `without_demo` read; keep the scope and the predicate in
  agreement. Pinned by `spec/models/child_account_demo_flag_spec.rb`.
- **`can_edit` on a communicator payload is one question — "can this VIEWER
  curate boards here" — and `ChildAccount#curatable_by?` is the only answer.**
  It was answered twice and differently: `index_api_view` asked whether the
  *owner* was an admin, so `GET /api/child_accounts` reported `can_edit: false`
  on a parent's own communicator while `GET /api/child_accounts/:id` reported
  `true`, and `ViewChildAccountScreen` gates most of its affordances on that
  field. `User#can_add_boards_to_account?` (the controller's curate
  `before_action`) delegates to the same predicate, so the gate and the flag are
  one piece of code rather than two copies. `index_api_view` therefore takes a
  `viewing_user` — pass it; with none, `can_edit` is false rather than a guess
  about somebody else's rights. Distinct from `can_edit_communicator`
  (`editable_by?` — the communicator object itself), which is narrower.
- **Every outbound message leaves a row in `mail_deliveries`, and a SUPPRESSED
  send is not a missing one.** `MailDeliveryObserver` records `delivered` (with
  the Message-ID a Google Workspace Email Log Search takes) and `suppressed`;
  `ApplicationMailer`'s `rescue_from` records `failed` and re-raises.
  `/admin/mail_deliveries` is the surface, badged in the admin nav, because a
  failure only an SSH session can see does not answer the person who has to
  trust "we'll email you as soon as it's approved". The third state is the one
  the log lines could not express: staging blocks EVERY message, so
  "suppressed" and "never attempted" were indistinguishable. **Every writer is
  fail-soft** — a raise in the observer fires AFTER a successful hand-off, so it
  would turn a delivered message into a Sidekiq retry and send it twice.
  Envelope only, never a body. `MAIL_DELIVERY_LOG=false` disables recording;
  `PruneMailDeliveriesJob` enforces `MAIL_DELIVERY_RETENTION_DAYS` (90) so the
  table stays a log rather than an archive.
- **A board is `complete` when its WORDS exist; `images_ready?` is when it can
  be DRAWN.** `GenerateBoardJob` sets `status: "complete"` immediately after
  enqueuing per-tile art, so a client gating a "board ready" screen on status
  opens a board whose tiles are still text. `Board#images_ready?` /
  `#tiles_awaiting_art_count` are the second question and the one a ready screen
  should gate on. Three things it gets right that `has_generating_images?` does
  not: **`pending` is the board_images column DEFAULT**, held by nearly every
  tile that never went through art generation, so it is NOT an in-progress
  status (`TILE_ART_IN_PROGRESS_STATUSES` is `generating`/`processing`); a
  **BLANK** `display_image_url` is READY, not waiting, because it is the "this
  tile has no picture" marker the client already draws; and only VISIBLE tiles
  count, since a viewer never waits on a tile they can't see. It is deliberately
  absent from `Board#api_view`, which serializes board LISTS and would pay a
  query per board.
- **Webhooks are the sole credit-grant authority** (Stripe + RevenueCat).
  Client-called endpoints may reflect plan state but never grant credits. All
  credit movement goes through `CreditService` and the immutable
  `credit_transactions` ledger; grants are idempotent on event id.
- **"Hide tiles" and "Hide pictures" are different questions, and neither is a
  data flag you should invent.** `board_images.hidden` ("Hide tiles") drops the
  tile from the board entirely — `visible_board_images` excludes it, so it
  never reaches the Speak view. A **blank** `display_image_url` ("Hide
  pictures") keeps the tile speaking and only stops its picture being drawn.
  Conflating them is easy because the bulk param for `hidden` is still called
  `hide_images` — read the param names carefully: `hide_images` → `hidden`,
  `hide_pictures` → blank `display_image_url`.
- **`display_image_url` has three states — `nil`, `""`, and a url — and `""` is
  load-bearing.** Every resolver chains with a bare `||`
  (`board_image.display_image_url || image.display_image_url(user) ||
  image.src_url`), and `""` is truthy in Ruby, so a blank stops the chain and
  means "this tile has no picture", while `nil` falls through to the shared
  Image's art. Never "tidy" a blank to nil, and never wrap the chain in
  `.presence` — that erased the marker and printed an apple on a Core Safety
  colour tile (#683). `BoardImage#picture_hidden?` and `#unhide_picture!` are
  where that distinction is written down; use them rather than comparing to
  `""` by hand. Because it is the *same* marker the renderers already honour,
  "Hide pictures" works in PDF exports, board covers, and printables without
  any of them knowing the feature exists — which is exactly why it must not
  become a second `data[...]` flag.
- **`BoardImage#set_defaults` SEEDS a picture, it never overwrites one — a
  non-nil `display_image_url` is the pin, and a copy has to look like its
  source.** The `before_create` cannot tell an authored URL from a defaulted
  snapshot, and every clone/assign path is `board_image.dup` → re-point
  `image_id` → `save`, so an unconditional assignment there silently replaced
  every text-tile render with the shared Image's library symbol while
  `data["text_image"]` still claimed a render (it had already been carved out
  for `""`, one authored state of three). `if display_image_url.nil?`, and the
  same rule one column over for `font_size`. A caller that WANTS the library
  default back writes `nil` first (`#unhide_picture!`). Two corollaries: the
  text-tile `doc_id` does NOT travel with a clone (`BoardImage#cloned_tile_data`
  strips it — the Doc hangs off the SOURCE tile's `Image`, and
  `unchanged_render?` only asks whether that Doc exists, never whose it is); and
  a create path that pre-sets `display_image_url` is now believed, which is why
  `Board.from_obf` must hand each tile its OWN button's picture — its
  first-picture-wins variable is the BOARD's cover and was being passed to every
  tile, giving a picture-less button the previous button's art.
- **A tile's picture belongs to the board's OWNER, and `Images::TileArtFanout`
  is the only thing allowed to write it from a shared `Image`.** `images` and
  `docs` are shared library rows — one "apple" `Image` is on thousands of boards
  across unrelated accounts — while `board_images.display_image_url` is per-tile
  user content. `Image#update_board_images_display_image` used to sweep EVERY
  tile of an Image on any `src_url` change with no ownership check at all, so an
  admin picking different library art repainted every user's existing board. A
  fan-out may now touch a tile only when its board is owned by the **acting
  user** or by `DEFAULT_ADMIN_ID` (**no actor ⇒ admin boards only** — never a
  guess), the tile has no picture of its own (`nil`, or still equal to the URL
  being replaced), and the tile is not `picture_hidden?`. `force:` means "all of
  MY boards, including my own pins" and relaxes the pin check *only*;
  `repair_dead:` is the sole mode that may cross ownership, because a URL that
  no longer resolves is broken for its owner too. Set `Image#fanout_actor_id`
  before writing `src_url` so the cascade knows whose boards are in scope. A
  library change may improve what a board's *empty* tiles fall back to; it may
  never repaint a tile someone chose — users pull improved art per board via
  `PUT /api/boards/:id/update_to_default_docs`. No "pinned" column: a non-nil
  `display_image_url` **is** the pin.
- **`docs.current` is the LIBRARY DEFAULT and is admin/owner-write-only; a
  user's own pick is a `UserDoc` row.** `current` is one global boolean on a
  shared row, but every path wrote it per-user-intent — so a regular user
  marking a picture current, or merely generating art on a public admin `Image`,
  flipped the fallback everyone else resolves through `Image#display_doc`.
  `Image#set_library_default_doc!(doc, actor:)` is the single writer and no-ops
  unless `actor.can_edit?(image)`. Nothing is lost for the user: `display_doc`
  reads `UserDoc` **before** `docs.current`, so their pick already wins for them
  — it just stops becoming everyone else's. `BoardImage#set_defaults` snapshots
  `image.src_url` at create, which is how a library change legitimately reaches
  *future* boards, so `src_url` must still move when the default does.
- **Merging library images is a REVIEWED PLAN, never a one-shot command, and the
  scan half writes nothing.** `images` has no soft-delete, so a merge is
  unrecoverable except through the `image_merges` ledger.
  `Images::DuplicateScanner` is a pure read that produces a `planned`
  `ImageMergeBatch`; `ImageMergeJob` (one group, one transaction) applies it and
  **re-asserts scope at execution time** — a row that became a user's, went
  private, or was relabelled between scan and run is skipped, never merged on
  stale evidence. Grouping is (label, language, `part_of_speech`) and all three
  are load-bearing: `Images::PromptBuilder` disambiguates homographs by POS, so
  `can` the verb and `can` the noun are different pictures by design. A merge
  must carry across what `image.destroy!` would otherwise take with it —
  `predictive_boards` are `dependent: :destroy` (**real boards**), `user_docs`
  are keyed by `image_id` as well as `doc_id` (a user's saved pick detaches
  silently), and docs must move through `Doc.unscoped` because the default scope
  hides soft-deleted rows from BOTH the read and the cascade. Tiles keep their
  own `display_image_url` byte-for-byte, `""` included; only `image_id` moves.
  Details: `.claude-notes/library-image-dedupe.md`.
- **`API::Admin::ApplicationController` descends from the TOP-LEVEL
  `ApplicationController`, so `current_user` there is Devise's session helper
  and is `nil` for a token request.** Use `current_admin`. The failure is silent
  and awful: every `actor:` becomes "no actor", which fails
  `can_edit?` gates and un-scopes `Images::TileArtFanout`.
- **`ColorHelper::PARTS_OF_SPEECH` is the ONLY part-of-speech vocabulary, and a
  prompt must interpolate it rather than restate it.** It is what
  `ImageHelper#background_color_for` switches on, and that switch ends in `else
  "gray"` — so an unrecognised value does not fail, it silently miscolours a
  tile. `AiBoardFormatter` listed its own set in prose ("interjection",
  "phrase", "other") and omitted `social`, `question` and `important_function`,
  so the AI layout path could never produce a red, pink or purple tile: the
  Modified Fitzgerald Key categories an AAC board leans on hardest. Interpolate
  the constant (`Drafting.part_of_speech_rules` is the pattern) and validate the
  answer against it before it reaches a colour resolver; `nil` means "no POS
  learned" and every caller already skips it, which is the safe way to drop a
  bad value. Classification is by communicative FUNCTION, not grammar — "more"
  and "yes" are `social`, "no" and "stop" are `important_function`. And a POS
  the model guessed belongs to the TILE (`board_images.data`), never written
  back to the shared `images` row: same cross-account contamination rule the
  tile-art fan-out follows, one column over.
- **A menu board is not an AAC board: its tiles are WHITE and it looks up no
  part of speech.** A tile on a menu board is a dish, so the Modified
  Fitzgerald colour says nothing and the generated food photo carries the
  tile. The rule belongs to the BOARD, not the shared `Image` — `images` are
  library rows, so `BoardImage#resolved_background_color` (keyed on
  `Board#is_a_menu?`) resolves white without repainting the library, and a
  reused library row keeps its own colour everywhere else. Every colour
  writer goes through it (`set_colors`, `set_background_color!`,
  `set_defaults`, the AI format pass) — including `tile_colors:repair`, which
  would otherwise repaint a menu board from its category, since white is in
  `PRESET_HEX` and so passes the `authored?` test. On the Image side,
  `image_type: "menu"` rows resolve white and take no category:
  `ensure_defaults` assigns `bg_color` in the SAME write as `part_of_speech`,
  because the `after_save :update_background_color` guard skips only when the
  colour moved alongside the category. And every image a menu board creates
  is a menu image — the over-budget words too, which used to fall to
  `Image.create(label: word)` and fire a synchronous `AacWordCategorizer`
  OpenAI call per unmatched dish name inside the user-facing generation path,
  while dropping restaurant names into the shared public library. `Image#menu?`
  is the single predicate and is case-insensitive: `Menu.set_image_types`
  writes `"Menu"`.

- **`images.label` is a lowercase matching key; `display_label` is the text.**
  `Image#set_label` downcases and strips `label` on every write and captures
  the authored casing into `display_label`. Never look an image up with
  `find_by(label:)` — use the `Image.by_label` scope (or
  `Boards::ImageResolver` when resolving a *tile*, which adds art-preference).
  A case-sensitive lookup misses the curated symbol and the calling site then
  creates a blank duplicate. `board_images.label` is **not** normalized by any
  callback: it is lowercase when `set_labels` derives it from the image, but
  builders that write it directly (`NavRowSync`, `PhrasesPageBuilder`) keep
  their own casing — read `display_label` for tile text either way.
- **Tile casing defaults to lowercase, and only a capital PAST the first letter
  counts as deliberate.** `Labels::CaseNormalizer` is the single authority, and
  `Image#set_label` is the single place authored casing becomes display text —
  fold there, never at the ~20 call sites that build an `Image` from a raw
  label. A plain leading capital ("Fun", "Giraffe") carries no intent and is
  folded down; "iPad", "TV", "McDonald's", "HELP" and the standalone pronoun
  "I" are preserved. Judged **per word**, so one styled word can't exempt a
  whole label. Treating any capital as deliberate is what made the lowercase
  default a no-op on exactly the input it exists to fix.
- **An ENGLISH `language_settings` entry is not a translation.** `set_labels`
  reads `images.language_settings[lang]["display_label"]` BEFORE the column and
  takes a real (non-English) translation verbatim as authored text. The "en"
  entry is not authored — `Image#translate_to` writes it for whatever language
  it was asked for — so it is case-normalized like any other default. Taking it
  verbatim let Title Case ("You", "All Done") skip `Labels::CaseNormalizer`
  entirely, and because backfills fold the `display_label` COLUMN, the capital
  survived every fold and was re-inherited by each new board built from that
  image. Anything that folds casing has to reach the jsonb too
  (`lib/tasks/tile_label_casing.rake`), and a clean column is no evidence the
  jsonb is clean.
- **A category tile's label is authored, not defaulted.** Folder tiles keep
  their capital ("Food", "Play") — an AAC board leans on it to separate a page
  you open from a word you speak. The OBF importer pins the authored button
  label and `Boards::BoardTreeBuilder` pins the blueprint's folder label; both
  bypass the lowercase default by design. `predictive_board_id` alone does NOT
  identify a folder (predictive/dynamic word tiles carry it too), so never use
  it to infer that a tile's casing was intentional. `BoardImage#door_tile?` is
  the test: the `mute_name`/nav flags, or a pointer at a board that isn't
  `board_type: "predictive"`. `#authored_tile_text?` widens that to every tile
  whose text isn't a word — doors plus keyboard keys ("A", "Space"), which
  carry a `data["tile_type"]`.
- **An imported board set is ONE board in a listing: its root.** The interior
  pages are sub-boards. That rule used to be a blanket `where(obf_id: nil)` on
  `Board.searchable` / `Board.admin_owned_boards`, which hid the root too — an
  import was unreachable from anywhere but the BoardGroup it arrived in, while
  the user's own index (no such filter) listed all thirty pages. The scopes now
  read `Board.without_imported_pages` (`obf_id IS NULL OR NOT sub_board`), and
  `Boards::ImportedSetClassifier` is what makes `sub_board` true enough to carry
  it: import links tiles with `update_columns` and only after every board
  exists, so `check_is_sub_board` never sees the finished graph. The root is
  PINNED (`settings["main_board"]`, alongside `builder_root`) because every page
  carries a way home — without the pin the next unrelated save demotes it.
  Run the classifier after `Boards::BackTileStamper`; the walk it falls back to
  skips back tiles, and an unflagged way home walks straight out of the set.
  Board Builder seed material (robust-set roots, fringe templates) stays out of
  the public catalogue by name — `Board.not_builder_seed` — not as a side effect
  of the OBF filter. Details: `.claude-notes/boards-and-teams.md`.
- **`data["back_tile"]` is the navigation-DIRECTION signal; `mute_name` is not.**
  Folder links run both ways in practice — every page in a set carries a way
  home stored as an ordinary folder tile — so a walk over `predictive_board_id`
  cannot tell a descent from a way back on its own. `BoardImage#back_tile?`
  (`back_tile` / `nav_tile` / `override_frozen`) is what any structural walk
  must consult; `Boards::BackTileStamper` sets it from `Boards::SetDepths`, so
  nothing depends on a creation path having flagged it. `mute_name` is
  deliberately excluded: `BuildBoardSetJob` mutes EVERY folder tile in a builder
  set, so keying direction off it would stop a builder root cascading its own
  pages. Following an unflagged back tile is what made deleting a page inside an
  imported set offer to delete that set's home board.
- **A nav region holds WORDS as well as folders, and only the folders are
  chrome.** A built set's bottom strip is `this | People | … | More | that` —
  the determiners at its ends are vocabulary that happens to sit in the nav row,
  reproduced on every page for the same motor-planning reason the folders are.
  `Boards::NavRowSync` treated every region cell as a folder, so on each child
  it relocated the authored `this` into the content area as a colliding occupant
  and created a SECOND one at the nav cell — carrying `mute_name`, which is what
  makes `BoardImage#door_tile?` true, so the tile in the strip was a silent door
  and the speaking one had wandered. A word cell is ADOPTED by label and stays a
  plain word tile, flagged `data["nav_word"]` rather than `data["nav_tile"]`:
  same ownership and idempotency, none of the door/back semantics. Never widen
  `nav_tile` to cover a word — `door_tile?` and `back_tile_data?` both key on it.
- **A CLONED tile's text is defaulted, not authored.** It carries whatever the
  source board happened to store, so it gets the same casing rule as any other
  defaulted tile — `BoardImage#cloned_display_label_from` folds it, and only
  `authored_tile_text?` tiles keep their casing. Copying `display_label` verbatim (which both clone
  paths used to do, one line after `set_labels` had folded it) makes every seed
  board's casing permanent in every board built from it: that is what kept the
  Board Builder emitting Title Case after the creation paths were fixed.
- **Copying a board copies its SET, and whether a link survives is a question
  about the set — never one `clone_with_images` may answer.** Every clone path
  goes through `Boards::SetCloner`, which walks the linked sub-boards
  (`Boards::PredictiveLinkSet.collect`), clones them, and only then translates
  each `predictive_board_id` through `rewire!`. `clone_with_images` therefore
  copies every pointer VERBATIM: it sees one board, and which of that board's
  links can be kept depends on which other boards the same operation copied.
  Nulling one in the tile loop cuts the link before the rewire can translate
  it, which is why `flatten_foreign_links:` was removed — two mechanisms for
  one outcome, and the ownership test it used got a self-link wrong (a tile
  aiming at its own board is IN the set and now maps to the root clone).
  `rewire!`'s `out_of_set:` policy is the whole decision: `:keep` for
  assignments (a link past the depth cap works exactly as it did before deep
  cloning), `:null` for builder sets, `:flatten` for anything a USER owns — a
  copied tile must never point into the source owner's live account, which
  breaks the moment they unpublish or delete. Flattening is
  `BoardImage#flatten_navigation!`, which clears `NAVIGATION_DATA_KEYS` as well
  as the pointer: `door_tile?` is true on `mute_name`/`nav_tile` ALONE, so
  dropping the pointer while leaving a flag behind strands a silent tile with
  nowhere to go, worse than the broken link.
- **Assigning a board ATTACHES it to a dashboard; it never copies it.** A board
  on N communicators is ONE board — edit it once and every one of them sees it —
  which is the whole reason the copy is gone. Assignment used to run
  `Boards::SetCloner` with `template_root: true`, minting a per-communicator
  clone that was excluded from `user.boards`, and so invisible in its owner's
  board list, uncountable, and unreachable by any edit made to the source: the
  board you edited and the board the child used were different rows, with no
  sync and nothing in the codebase that could have provided one. Attachment
  costs no board slot and consults no board limit, so a Free user's one board
  still goes on their one communicator. `Boards::AssignableSource` is the single
  allowlist — the actor's own boards, the communicator OWNER's own boards (a
  supervisor curates on the owner's behalf), `Board.public_boards`, and the
  communicator's team boards — and a refusal is generic, because naming the id
  would say whether a board the caller cannot see exists. `assign_boards` had no
  check at all, which was survivable only while the result was an invisible
  copy. Two consequences to hold onto. **Per-communicator VOICE now resolves at
  READ time** — see the next bullet — because `boards.voice` is one column on a
  shared row. And a detach is pure detach: the `is_template` gate inside
  `Boards::AssignmentTemplateSweep` is what keeps the hard-delete path for
  LEGACY clones only. Those legacy rows are migrated by
  `rake board_assignments:consolidate` (dry run by default), which re-points the
  tile at its source and deletes the clone tree — but only when the clone is
  provably unedited, since `boards` has no soft delete and every check has to
  fail closed. `is_template` survives on the column for those rows and for
  `Boards::GlpTemplates`; nothing mints new ones, and `template_root:` /
  `force_template:` are gone. Do not reintroduce a mode that hides a board from
  the person who owns it.
- **A copied set costs ONE BOARD SLOT PER BOARD, and the budget is
  `Boards::CloneSetPlanner`.** `Boards::SetCloner`'s two remaining callers — the
  MySpeak starter and `POST /boards/:id/clone` — produce real, listed, editable
  boards throughout. The sub-clones used to be forced to templates
  regardless, which made a six-board set cost exactly one slot and hid its five
  pages from the board list entirely: reachable by tapping a folder tile, and
  impossible to find in order to edit. `Boards::CloneSetPlanner` budgets the
  copy against `User#board_limit_remaining` and is the SINGLE source of truth
  shared by `GET /boards/:id/clone_plan` (which sizes the copy so the client can
  confirm the cost) and the copy itself — a confirm dialog that could disagree
  with what gets created is worse than no dialog. Over budget the copy is
  breadth-first and PARTIAL: the pages nearest the root survive and the tiles
  that opened the rest are flattened, reported as `boards_created` /
  `boards_in_set` / `flattened_tiles` / `limited_by`. Only
  `limited_by: "board_limit"` earns an upgrade prompt; `"set_size"` names the
  per-copy ceiling (`BOARD_CLONE_SET_MAX_BOARDS`, a request-timeout guard, since
  a Pro user has 300 slots) and paying more would not lift it.
  `include_linked_boards: false` is the user asking for the ROOT ONLY — a set
  they have room for is still a set they may not want — which caps the copy at
  one board and clears `limited_by` entirely, because nothing was withheld and
  there is nothing to offer an upgrade against. `assignment_root_id` is stamped
  on EVERY sub-clone because `Boards::PublishCascade` walks it with no
  `is_template` filter — without it a published MySpeak starter leaves every
  folder tile 404ing. (Its old companion `assignment_child` marked a throwaway
  per-communicator page; nothing writes it since assignment stopped cloning, and
  legacy rows still carry it for `lib/tasks/myspeak.rake`.)
- **A communicator's VOICE is a read-time argument, not a column on the board.**
  A board can be on several dashboards, so `boards.voice` and
  `board_images.voice` — single-valued columns on a shared row — cannot answer
  "what does this communicator hear". Every communicator read path passes
  `child_account.voice` into `Board#api_view_with_images` /
  `#api_view_with_predictive_images`, which resolves per-voice audio through
  `BoardImage#audio_url_for_voice` and enqueues a render when that voice has not
  been spoken yet; the voice must also be in the `stale?` ETag, or two
  communicators sharing a board serve each other 304s. The write side is the
  other half: `ChildAccount#update_audio` fans out `UpdateBoardsVoiceJob`, which
  does `boards.update_all(voice:)` and then rewrites EVERY tile, so
  `#rewritable_voice_board_ids` excludes any board the account's owner does not
  own and any board on more than one dashboard. Rewriting one of those is not a
  preference change, it is destroying somebody else's audio.
- **Which voice a communicator gets when NOBODY picked one is
  `VoiceService.default_for_age_band`, and `voice_settings` may not write.**
  The communicator form collects `age_band` and stores it in `details`; nothing
  downstream read it, so every communicator was defaulted to `polly:kevin` — a
  voice tagged `kid` whose own description said it was for kids, which on Free
  is the ONLY option in the picker. The map keys on the band, and an
  UNRECOGNIZED band resolves to the adult voice rather than the app default:
  blank means "never asked", but an unknown value means the question was
  answered in a form the table doesn't hold, and falling back to a child voice
  there is the exact failure the map exists to prevent. `ChildAccount#voice_settings`
  used to ASSIGN its default blob into `settings`, so merely reading a voice was
  a pending write — the next save from any cause persisted it, and from then on
  the value was a "choice" no default could improve. It now returns a merged
  hash and writes nothing (`voice=` and the settings param are the writers), and
  the blob is STRING-keyed because the column is jsonb and every reader indexes
  it that way; the symbol-keyed seed meant an unsaved record answered
  `voice_settings["name"]` with nil. The `kid` TAG stays on Kevin — it is what
  the map and any future filter read — but no voice's `description` may say a
  voice is for children, since that string is what the family reads. The server
  can only fill an ABSENCE: a picker that seeds itself with a hardcoded voice
  submits that value and is indistinguishable from a deliberate pick, which is
  why `GET /api/voices?age_band=` serves `default_voice` for the picker to seed
  from. **Corollary: every band in `CommunicatorProfile::AGE_BANDS` needs a row
  in `DEFAULT_VOICE_BY_AGE_BAND`.** An unmapped band is not "no answer" — it
  takes `DEFAULT_VOICE_FOR_UNKNOWN_BAND`, the ADULT voice — so adding a band and
  forgetting the map hands the exact communicator the band was added for the
  wrong voice. `under-4` exists because early intervention routinely starts AAC
  at 2 and `4-6` was the floor; it is `young?` (so core-vocabulary-first
  guidance) and takes the kid voice, and `band_for_age` splits `0..3` off the
  `0..6` case that used to report every toddler as `4-6`.
- **A communicator username is globally unique, so the create form has to be
  able to ASK before it commits.** `GET /api/child_accounts/username_available`
  is that question: signed-in only (it reveals whether a username exists),
  throttled per caller, and it answers about the PARAMETERIZED name — the same
  shape `ChildAccount#set_username_if_missing` derives — echoing back what it
  actually checked so the client submits that. It suggests alternatives it has
  confirmed free in ONE query, and nothing auto-suffixes on the create path: a
  parent should see and choose, never discover later that the app quietly
  renamed their child's account to `leo2`.
- **`field_errors` is ADDITIVE and `error`/`errors` keep their exact shape.**
  Both still carry the same flat `full_messages.join(", ")` string, because
  that is what the frontend that ships today reads; `field_errors`
  (`errors.to_hash(true)`, full sentences keyed by field) is what lets a taken
  username be shown ON the username input. It is added only where a RECORD
  failed validation — `account_error_payload` takes the record explicitly,
  since most of its callers pass a hand-written sentence with no validation
  behind it, and since it `reload`s `@child_account`, which discards the errors
  the key is built from.
- **A slug is derived from the name once, at creation, and a rename never
  changes it.** `slug` is the `/pb/<slug>` key that a shared link, a MySpeak
  tile and a printed QR code all resolve through; the name is just a label.
  BoardForm used to re-derive the slug on every keystroke of the name field, so
  renaming an unpublished board silently moved its public URL. `Api::BoardsController#update`
  now leaves the slug alone unless the caller asks for a change:
  `regenerate_slug: true` (the "Generate slug from name" toggle), a blank
  `slug` (clearing the field), or an explicit new `slug`. A blank *stored* slug
  is always backfilled — `validates :slug, uniqueness: true` does not skip
  blanks and the column is `default: ""`, so two slug-less rows collide.
- **`slug` and `regenerate_slug` are admin-only params**, stripped from
  `board_params` for non-admins exactly like `predefined`. Owners rename their
  boards freely; re-keying a live URL is an admin act.
- **`Board.create_slug` strips copy markers from both ends.** `COPY_MARKERS`
  handles "Copy of X" (the API clone path) and "X Copy" / "X (copy)" / "X copy 2"
  (what CloneBoardModal pre-fills). The trailing pattern requires a separator
  before "copy" so "Photocopy Board" survives, and a name that strips to nothing
  ("Copy") falls back to the un-stripped name rather than a blank slug.
- **A published board's slug is frozen** — the stricter rule on top of all of
  that. `/pb/<slug>` is printed into QR codes and pasted into IEPs, with no
  redirect behind it. `Board#freeze_published_slug` silently reverts any slug
  change on a published board (reverts, never raises, so a slug in the payload
  can't 422 an otherwise-valid update). Deliberate renames go through
  `Board#rename_slug!` — the internal API's `force_slug` or the
  `boards:rename_slug` rake task.
- **A board that backs a marketplace listing can't be deleted, unpublished or
  renamed.** Same reason as the frozen slug, one step further: the board's
  content was sold as a PDF and every printed page carries a QR pointing at its
  own `/pb/<slug>`. `Boards::MarketplaceProtection` is the single authority and
  covers the whole printed tree (`board_printables.board_ids`), not just the
  printable's root — deleting an interior page breaks the product just as badly.
  It keys on having EVER reached Etsy, never on a hand-maintained listing state:
  ending an Etsy listing doesn't un-print paper, and such a column would only
  ever drift in the unsafe direction. Since a printable can carry SEVERAL
  listings, the predicate is a union — the `etsy_published_at` watermark, the
  legacy scalar id, OR any `board_printable_listings` row that reached Etsy —
  and it is deliberately not filtered on `superseded_at`, because a detached
  listing's paper is still on someone's fridge. Widening can only over-protect;
  narrowing is unrecoverable. Release is the audited
  `BoardPrintable#waive_protection!`. Details:
  `.claude-notes/board-printables-etsy.md`.
- **A printable can carry several Etsy listings, and the ROW is the publish
  token.** `board_printable_listings` holds one row per listing — its own copy
  overrides, gallery selection (`image_variants`), download subset
  (`pdf_variants`), clip and `video_pushed_at` — so a standalone and a bundle
  can sell the same document. Three rails. The row is created `pending` BEFORE
  anything touches Etsy and claimed by a compare-and-set on `state` in the
  request thread, so a double-click enqueues exactly one job; `retry: 0` still
  stays, because the claim gates the enqueue and not the non-transactional
  window around `create_listing`. The listing id is persisted the INSTANT Etsy
  returns it, before any upload, so a draft whose gallery failed partway is
  `#assets_incomplete?` rather than an orphan nobody can name. And detaching
  SUPERSEDES the row, keeping the id — the app implements no delete call, so the
  row is the only record that a draft exists in a real shop, and a row that
  reached Etsy is never deletable from the admin. Every per-listing asset is an
  ALLOWLIST over the printable's shared set (empty = all), never an exclusion —
  the same rule `pdf_files` holds.
- **Downgrades retain, never delete.** Over-limit boards become read-only;
  over-limit communicators enter fallback mode (public MySpeak page stays
  up). No plan change destroys user content.
- **A trial-end warning must be computed against the plan the user is about to
  LAND on, not the one they hold.** Mid-trial a Basic/Pro limit means nothing is
  over it, so any naive "boards over the limit" count reads 0 for the entire
  trial and the warning fires with nothing to say.
  `User#boards_locking_at_trial_end` resolves Free's limit explicitly and
  compares against that; it returns 0 whenever nothing will lock (card on file,
  RevenueCat, admin, or a set that already fits). It rides on
  `trial_api_view[:boards_locking]` and on the trial-wrap journey's `LOCKING`
  merge field. The webhook that fires it (`customer.subscription.trial_will_end`,
  ~3 days out) is the same one that recomputes `has_payment_method`, so the
  count is calculated after that correction, not before.
- **How many boards you may CREATE and how many stay WRITABLE are two
  different numbers.** `board_limit` gates creation; `editable_slot_count`
  (`max(board_limit, User::EDITABLE_BOARD_FLOOR)`) is how much of what you
  already own stays editable once you are over it. They were the same number
  until #801 made Board Builder boards count — at which point a lapsed trial
  could land 23-35 boards over a limit of 1, and the lock collapsed to a single
  editable board. The floor makes Free behave like every other locked plan
  (Clinician already kept its `board_limit` most-recent boards) instead of
  being a special case, and it grants nothing: `at_board_limit?` is untouched,
  so Free still creates exactly one board and the pricing page stays true.
  `EDITABLE_BOARD_FLOOR` is ENV-overridable — retune from Hatchbox, no deploy.
  Note the lock is inert at or below the floor; that is the trade, and the
  upgrade lever there is that creation is still blocked.
- **External-service failures fail soft.** Redis blips, PostHog, Mailchimp,
  and geolocation errors are rescued and logged — they can never 500 a
  request or a webhook.
- **Every admin page is gated by inheritance, never by an inline check.** HTML
  admin controllers inherit `Admin::ApplicationController`
  (`authenticate_user!` + `require_admin!`); JSON ones inherit
  `API::Admin::ApplicationController` (admin-role token). A controller routed
  under `/admin` that does not descend from the base fails
  `spec/requests/admin/access_control_spec.rb`, which sweeps the whole
  namespace. Gate in a `before_action`, not inline in the action body — a bare
  `redirect_to … unless current_user.admin?` mid-action still runs every query
  below it, and the next person to add an early `render` turns it into a leak.
  The legacy HTML admin listings under `/users` are gone; what survives there
  is the self-service profile (`/users/:id`), outside the `Admin::` namespace
  and carrying its own self-or-admin gate.
- **Safety-profile emergency info is only served by the gated `safety_view`
  POST** — never on public page-open. It is also never sent to OpenAI: no
  `Profile::SAFETY_SENSITIVE_KEYS` entry may appear in a
  `Suggestions::Registry` context allow-list (enforced by spec).
- **A MySpeak page has two gated reveals, and only one may notify.**
  `safety_view` (emergency info) logs a `ProfileView` **and** alerts the parent;
  `care_view` (`settings["care"]` — communication, personal care, meals,
  transportation) logs with `view_kind: "care"` and returns before the throttle
  claim, geolocation, and notifier. Care sections are day-to-day support info a
  substitute teacher reads routinely; routing them through the emergency alert
  would train parents to ignore it. Care fields are equally never sent to
  OpenAI. Details: `.claude-notes/safety-profiles.md`.
- **A communicator's MySpeak slug is never derived from their name — every
  creation path leaves `slug` BLANK and lets `Profile#ensure_slug` assign the
  random one.** `safety_profile?` is true for any ChildAccount-owned Profile, so
  the rule is already written down in one place; a path that passes `slug:`
  simply skips it, because `ensure_slug` returns on a present slug. That is how
  the dashboard shipped `/my/river-stone` while the wizard shipped
  `/my/s-k8x2mf` — and nothing re-slugs a page afterwards, so the emergency info
  a parent fills in later lands behind whichever URL that first write chose. A
  readable `username` is fine and wanted (it is the handle on a page a responder
  has already scanned); the URL is the part that must not be guessable. Existing
  rows: `rake profiles:migrate_to_random_slugs`, dry-run by default, which keeps
  the old slug resolving via `legacy_slug` + 301 — so it moves the canonical URL
  but does not make an already-exposed page unfindable.
- **A profile has THREE resolvable addresses and they mean different things;
  `Profile.resolve_slug` is the only place that knows all of them.** `slug` is
  the address a person reads and may have to change; `permanent_slug` is what a
  printed QR resolves through, assigned once at create and NEVER rewritten;
  `legacy_slug` is a deprecated address kept alive by a 301. Keeping the first
  two in one column is what forced the slug to be frozen at all — paper needs
  stability, people need revocability, and one column can only serve one of
  them. So the device tag, safety card and care plan all render
  `Profile#permanent_url`, never `public_url`, and a `permanent_slug` match is
  served DIRECTLY rather than redirected: the printed address must never depend
  on what `slug` happens to hold today. Every public surface has to resolve all
  three or a link half-works — the page opens and the Emergency Info reveal
  404s — which is why `#public`, `#safety_view`, `#care_view` and
  `#check_placeholder` all go through the one resolver. The column is nullable
  and `printable_slug` falls back to `slug`, so a row the backfill
  (`rake profiles:backfill_permanent_slugs`) hasn't reached still works, and
  `ensure_permanent_slug` runs on every save so such a row self-heals when
  touched. **Per-column unique indexes do NOT make these safe on their own** —
  nothing at the DB level stops one profile's `slug` equalling another's
  `permanent_slug`, and because `resolve_slug` prefers `slug` the claimant WINS
  and the victim's printed QR resolves to the claimant's page. So the generated
  shape itself (`Profile::RANDOM_SLUG_PATTERN`) is reserved from user-chosen
  slugs, allowed only alongside `slug_type: "random"`, and reported as
  `:reserved` **before** any availability lookup — answering `:taken` would make
  `check_slug` an oracle for which generated slugs exist, and a permanent one
  can never be rotated away once known. Cross-column availability is validated
  on the MODEL (`slug_available_across_columns`), because `#update` asked
  before saving and `#create` never did — a controller-side check is one write
  path remembering, not an invariant.
- **`public_url` is for SHARING; `permanent_url` is for PRINTING.** The corollary
  of the bullet above, and the rule any NEW surface has to be checked against.
  `slug` is meant to be renameable and revocable — `rotate_slug!` exists so a
  shared link can be burned — so anything that ends up on paper, or inside a QR
  code, resolves through `permanent_url` instead: the device tag, the care plan,
  and now the link a user pastes into Canva's QR Code app to finish a MySpeak ID
  card themselves. Printing `public_url` produces paper that dies silently the
  first time its owner rotates. The mistake runs both ways, so the test is what
  the link is FOR, not which one is handier: `MySpeakOnboardingPage`'s
  copy-your-page button is a *share* action and correctly copies `public_url`,
  while the Print & share section's copy button and `QRCodePage`'s code are
  *print* surfaces and use `permanent_url`. `permanent_url` falls back to `slug`
  via `printable_slug`, so it is always safe to read.
- **An unguessable link is still a bearer token — revocation is `rotate_slug!`,
  and it is NOT renaming.** Whoever a `/my/s-k8x2mf` link was shared with keeps
  access until the address changes, and a permanently-frozen slug had no answer
  for that. `POST /api/profiles/:id/rotate_slug` mints a fresh random slug and
  deliberately does **not** keep the old one — `legacy_slug` exists to stop a
  rename breaking shared links, and here breaking them IS the request, so any
  stored legacy slug is cleared too. It is not gated on `slug_editable?`: that
  governs choosing a *name*, and refusing to revoke until a 7-day window opens
  would be backwards. Rotation costs no reprint because the QR resolves through
  `permanent_slug`; it regenerates the card once for a tag rendered before that
  column existed.
- **A communicator's MySpeak page is FREE on every plan — the communicator SLOT
  is the quota, never a Profile count.** Every communicator auto-mints exactly
  one `Profile` at create time (`ChildAccount#create_profile!`, called from
  `API::ChildAccountsController#create`), so counting Profiles charges
  `Permissions::CommunicatorLimits` a second time for the same communicator —
  and it does so from a path that doesn't know the limit exists, so the slot is
  consumed silently. That is how a Free user with one communicator was refused
  the page five places of frontend copy promise is "free on every plan,
  including Free", having never knowingly created one. `FREE_MYSPEAK_ID_LIMIT`
  and `User#myspeak_id_count` are gone; do not reintroduce a per-Profile quota.
  The user-level **Public page** is a different product — one per user
  (`User has_one :profile`), plan-independent, and a duplicate create is a
  **409 `public_page_exists`**, not a 403, because it is a state conflict rather
  than a plan gate.
  Removing the double-count was not enough on its own: a Free user gets exactly
  ONE self-create, so adding a communicator from the dashboard spends the slot
  AND mints the blank page, and the MySpeak wizard — whose only move was to
  create a NEW communicator — still refused the user whose page already existed.
  **When a create is refused, the wizard ADOPTS a never-set-up page rather than
  demanding a slot the user can never have.** `Profile#never_set_up?` is the
  predicate, and it authorizes an overwrite, so it must stay conservative — any
  bio, pronoun, contact, intro or rich-text section makes it a page someone set
  up. Two rails: adoption **re-slugs** a page that isn't already random (one
  minted before #774 carries a name-derived slug, because `create_profile!`
  passed `slug:` and so `ensure_slug`'s random-slug rule never ran — and
  adoption is about to put emergency contacts behind that URL), and it **never
  guesses between
  candidates**, answering 422 `communicator_selection_required` instead. An
  adopt reports as `myspeak_page_adopted`, never as an account create.
  Details: `.claude-notes/myspeak-onboarding.md`, `.claude-notes/safety-profiles.md`.
- **A board on a communicator's MySpeak page is a PUBLISHED board.** The public
  grid selects on `child_boards.favorite`, but the board behind each card is
  gated on `Board#viewable_by?`, which refuses an anonymous visitor an
  unpublished board — so favoriting alone served a working card that 404'd on
  tap, and that was the DEFAULT state (Board Builder roots and
  `SetCloner` clones are both born unpublished). Both halves are
  required. WRITE: `Boards::MySpeakPublisher`, hooked on `ChildBoard`'s
  `favorite` transition so no call site can forget it, publishes the board and
  cascades to its set. READ: `Profile#communication_boards` and
  `Profile#user_boards` filter on `published`. Three rails on the write half —
  it is **one-way** (unfavoriting never unpublishes; `/pb/<slug>` may already be
  printed into an IEP), it publishes **only boards owned by the page's owner**
  (a parent's favorite tap is not an SLP's consent to publish their shared
  board — such a board is left private and the read filter hides it), and a
  Board Builder set is synced again in `BuildBoardSetJob` because at favorite
  time the set is still empty. `child_boards.published` is a dead column that
  nothing writes; read `board.published?`.
- **The MySpeak wizard's starter board is the PARENT'S OWN board, and it is
  gated like any other board create.** Assignment attaches an EXISTING board and
  spends no slot; the wizard CREATES one, so it is a board create and pays for
  itself. The board it attaches is the one the child's PUBLIC page links to, so
  an owner who cannot see it edits a different copy and the two diverge
  permanently, with the world reading the one she can't reach. It is refused by
  `at_board_limit?` — which
  it must read off a freshly-refetched `User`, since `countable_board_count` is
  memoized. At the limit the wizard **skips the board and reports the reason**
  rather than substituting a board of its own choosing: favoriting PUBLISHES,
  one-way, so a guess publishes a board the parent never picked. A `board_id`
  naming a board she already owns is attached with no clone, looked up through
  `current_user.boards` (the association's `is_template: false` filter is what
  stops a stale invisible clone being re-attached). The board step never blocks
  setup, so every refusal rides back in the response's `starter_board` — a
  silent skip is indistinguishable from success to the client. That report also
  carries `boards_created` / `flattened_tiles`, because a starter with folder
  tiles now brings its pages along at one slot each and "we set up her board"
  should say what it actually made. Two more things the wizard has to respect:
  the per-communicator cap applies to BOTH branches (a board she already owns
  fills a dashboard exactly as much as a fresh clone, and the check used to sit
  inside the clone branch only), and `favorite_starter!` must publish when the
  board is not published rather than relying on the favorite TRANSITION — an
  already-favorited row saved nothing, never reached `MySpeakPublisher`, and
  left a card on a public page that 404s on tap.
- **An unauthenticated endpoint never serializes a board with `api_view`.**
  `Board#api_view` publishes `in_use_by` (every communicator NAME using the
  board) and `communicator_account_data` (their ids, names, avatars);
  `ChildBoard#api_view` publishes `added_by`, the assigning user's EMAIL. Both
  models carry a `public_card_view` for public pages, matching the frontend's
  `PublicBoardCard` type; `Board#public_page_card_view` is the slightly wider
  card the User public page's grids need. **All three** board lists in the
  public profile payload are carded — `general_public_boards`, `public_boards`,
  and `user_boards` (a User's own page, where `in_use_by` is that user's own
  communicators' names). The frontend gates every one of these fields behind
  `!isPublicGrid && can_edit`, so they were never rendered — only transmitted,
  which is why the leak survived so long. `api_view` is also the expensive one
  — it runs three `rows_for_screen_size` passes per board — so reaching for it
  on a public list leaks and is slow at the same time. **`ChildBoard#public_card_view`
  delegates to `Board#public_card_view`** rather than rebuilding the hash: both
  cards feed one frontend component and one `PublicBoardCard` type, and
  maintaining them in parallel silently dropped `preset_display_image_url` and
  `slug` from the communicator card — so a communicator's board couldn't reach a
  cover fallback its library twin resolved fine. `Profile#communication_boards`
  is polymorphic in RETURN TYPE (ChildAccount → ChildBoard rows, User → Boards),
  which is why one grid can drift from the other unnoticed. Details:
  `.claude-notes/safety-profiles.md`.
- **`general_public_boards` is a curated STARTING POINT, not the library.** It
  is what a public page offers when its owner has starred no boards of their
  own — the page a parent hands to a kindergarten teacher — and it used to be
  every row in `Board.public_boards`: ~75 unordered cards, duplicates and all.
  `Board.public_starter_boards` orders and caps it in three passes so it
  degrades rather than empties where the starter seed never ran:
  `myspeak`-tagged boards (`MYSPEAK_STARTER_ORDER`, then alphabetically), then
  `category: "welcome"`, then the rest — de-duplicated on a normalized name and
  capped at `PUBLIC_STARTER_BOARD_LIMIT` (6, ENV-tunable, read at call time).
  **Curation is by TAG**, so the list changes from the admin without a deploy;
  the cache key spans the whole public library for exactly that reason, and it
  is folded into `profile_public_etag` or a client is served a stale 304. The
  name normalizer folds case and punctuation only — it never reorders or stems
  words, since `Letters, Colors, Numbers` and `Letters-Numbers-Colors` really
  are two boards and guessing would hide one somebody curated. Retiring a true
  duplicate from the library is `rake public_boards:dedupe` (dry run by
  default), and it clears `predefined` — **never `published`**, which is the
  marketplace-protection raise path and the `/pb/<slug>` a printed QR resolves
  through, and never a destroy, since `boards` has no soft delete.
- **`print_grid_layout_for_screen_size` must build a DENSE list.** It once
  assigned into a plain Array at `layout_to_set[bi.id]` — the global
  `board_images` primary key — then compacted the holes away, so serializing a
  30-tile board allocated an array sized to `MAX(board_images.id)` and the cost
  of every `Board#api_view` grew with the whole table. Nothing reads the index
  positions; every consumer reads each cell's own `x`/`y`. The memo it now
  keeps is cleared wherever tile layouts are rewritten (`board_images.reset`).
- **A grid's fullness is only as trustworthy as its layout, and navigation
  chrome never displaces vocabulary.** `Board#open_grid_cells` counts
  `occupied.uniq.size`, so two tiles STACKED on one cell make a completely full
  84-tile Core 84 board report a phantom free cell — and every builder
  placement guard is written as `open_grid_cells >= 1`, so that phantom gets
  spent. The seeded core-84 board carried exactly that (`all done` parked on
  `again`, its own cell empty) because `VocabSets.repair_layout!` matched tiles
  by `data["obf_button_id"]` and that tile had none, so no re-seed could ever
  move it; the repair now falls back to a UNIQUE authored-label match, stamps
  the id, and `unstack_layout!` (`Boards::LayoutRepacker.unstack!`) is the net
  behind it — `unstack!`, never `repack!`: an authored grid holds exactly as
  many cells as tiles, so a displaced tile belongs in the gap its twin left, and
  `repack!` shelf-packs it onto a NEW ROW (it mirrors the frontend
  `repackLayout`), which is the extra row this whole bullet is about.
  A seed ships its layout verbatim into every clone, so one stacked seed cell is
  a stacked cell in every set ever built from it — hence the same net on the
  read side: `Boards::SeededSetCloner` repacks every cloned board after its
  transaction commits, so a source corrupted since it was seeded can't hand the
  defect on. The other half is the write
  side: `Boards::NavRowSync#ensure_home_tile!` skips the way-home anchor when a
  page LOCKED to one screen has no genuinely free cell (counted as DISTINCT
  cells, so a double-booked cell reads as full rather than offering a hole).
  `settings["disable_scroll"]` is the lock, and it is the whole test: growing
  such a board past its authored rows is what silently defeats it, while a page
  that may scroll takes the extra row and loses nothing — so it keeps its
  anchor. "Every page in a built set has a one-tap way home" is the older
  invariant; narrow it no further than the lock. And a board that is itself the TOP
  of a set (a `Boards::RobustSets::ROOT_MARKER` root, or another set's
  `builder_root`/`builder_child`) is never walked into as a PAGE by
  `Boards::SeededSetCloner`: cloning one drops a second full core board into the
  set, which — having no nav cell bearing its name — is then handed an anchor
  labelled with the core set's own name. Repair: `rake
  board_builder:repair_stray_core_pages`.
  **And `open_grid_cells` is a WRITE, so it can never be called from a read
  path.** It opens with `update_board_layout`, which does `self.save` and rewrites
  every tile's `layout` — fine for a builder about to place tiles, fatal for an
  admin index that renders sixty template boards and would mass-write on a GET.
  Read-only substitutes: count DISTINCT cells off each tile's own
  `layout["lg"]` (what `Boards::TemplateHealth` does), or
  `Boards::LayoutRepacker.unstack_screen!(board, "lg", dry_run: true)`, which
  returns the displaced count before any save.
- **The robust-set marker is IDENTITY, so a clone must never inherit it and a
  built set's NAME must never be read off the seed row.** `Boards::RobustSets`
  decides which board IS the Core 60/84 seed from two `settings` keys alone —
  and `settings` rides `Board#clone_with_images`, so every clone of a seed
  became a rival root for that slug. `all_roots` ordered by `:name` and took
  `.first`, and `resolve_root_name` returned `find_root(slug)&.name`, which
  names the root Board *and* its BoardGroup. A marketing clone called
  "Classroom — Core Words Poster" (`Cl` < `Co`) therefore won the Core 84 lookup
  and supplied both the name and the GRID for every Extended build; starter and
  standard had the identical exposure one Core 60 clone away, since all three
  levels resolve through the same call. Three rails now. `all_roots` is scoped
  to the seeder — `user_id: User::DEFAULT_ADMIN_ID` **and** `predefined: true`,
  either of which a clone fails — and ordered by `:id`, so the winner is the
  oldest row rather than an alphabetical accident. `clone_with_images` strips
  both keys alongside the cover-snapshot keys it already dropped, which covers
  every clone path (`POST /api/boards/:id/clone`, `SetCloner`,
  `BoardSnapshotService`, MySpeak onboarding, `from_vocab_set`) at once; where a
  caller can supply `settings`, strip AFTER the merge or the caller puts them
  back. And the name comes from `RobustSets.display_name_for(slug)` — a
  constant keyed on the SLUG — so a renamed seed cannot rename a user's board;
  `find_root` still decides whether the set is seeded here, only the string
  moved. Cleanup for rows cloned before the strip: `rake
  board_builder:unmark_stray_vocab_roots` (dry run by default; unmarks only —
  it never renames, unpublishes, or destroys, and it reports the built sets that
  took a stray's name rather than renaming them). The admin registry at
  `/admin/board_builder_templates` therefore exposes NO write path to either
  marker — a board becomes a root only through `VocabSets.seed_slug!` from
  authored source, and strays are reported read-only with the rake command. The
  fringe marker rides the same rule one column over: `clone_with_images` strips
  `Boards::FringeTemplates::TEMPLATE_MARKER` too, because `FringeTemplates.find`
  is scoped to the seed admin and so an ADMIN-owned clone of a template would
  become a rival for that category. `find` orders by `:id` for the same reason
  `all_roots` does — oldest row wins, never an unordered `.first`.
- **A Board Builder template is EDITABLE, but a re-seed reverts it.**
  `VocabSets.seed_slug!` and `Boards::FringeTemplates.seed_obf!` are destructive
  syncs against the authored `.obf` in `db/seeds/board_builder_sets/`: they
  destroy tiles (and pages) that are not in the source and re-pin the rest. That
  is how a content revision fully applies, and it is why an edit made in the
  board editor is not permanent — the loop is edit → `Boards::SeedSourceExporter`
  → commit the file → re-seed. Corollary for the fringe marker:
  `Board.not_builder_seed` keys on it and is the ONLY thing keeping an
  admin-owned, published, predefined board out of `Board.public_boards`, so
  un-registering a template must clear `predefined` as well — and must NOT touch
  `published`, which is the marketplace-protection raise path and the `/pb/<slug>`
  a printed sheet resolves through.
- **"Format with AI" is a PERMUTATION at a uniform 1x1.** `AiBoardFormatter`
  chooses an ORDER and nothing else: no tile size, no x/y, no column count, and
  it never adds or drops a word. `Board#pack_layout_row_major` is the single
  enforcement point — it writes `w: 1, h: 1` for every cell, so a size a model
  or an older layout asked for cannot survive a format. It used to permit "up to
  2" tiles at `[2, 1]`, which the model took on every run, and the damage was
  never local to those two tiles: `rows_for_screen_size` is `max(y + h)`, so two
  wide tiles turned a 48-tile / 8-column board from 6 exact rows into 7. That
  inflated row count is what silently defeats `settings["disable_scroll"]` — the
  frontend locks a board to the screen only while a row stays readable
  (`max(56px, cellWidth / 2)`), and an extra row pushes it under the floor, so
  the board starts scrolling with the setting still true. Never let a model pick
  a tile size: it is a grid-wide decision. A partial last row is a WORD-COUNT
  problem — `Prompts::Aac::SYSTEM_PROMPT` already says the grid is fixed —
  never a reason to re-pick the column count, which would re-flow the board and
  stale every cached cover and printable render. Repair for boards formatted
  before the fix: `rake board_layouts:normalize_tile_sizes`.
  **A set's NAV STRIP is reserved from the permutation**, because a format run
  touches ONE board while `Boards::NavRowSync` reproduces that strip
  cell-for-cell on every other page — so permuting it desyncs pages nobody asked
  to change. `Boards::NavRegion.for_board` is the single answer to "which cells
  are navigation here": a synced PAGE by the `nav_tile`/`nav_word` flags the sync
  owns, a set ROOT by geometry gated on `builder_root?` / `pinned_main_board?`,
  and EMPTY for everything else — an ordinary board holding a folder tile must
  not have an arbitrary row pinned. Banding was never enough on its own: a
  nav-row WORD (`this`, `that`) is correctly not a door, so `LINK_BAND` doesn't
  catch it and flagging it `nav_tile` to make it one is the mistake `NavRowSync`
  already made. Only `lg` can honour the region's exact cells (it is the only
  screen the region is expressed in); md/sm pack the strip last so it stays
  bottom-pinned, the same rule `Boards::ScreenReflow`'s `pinned_rows` uses.
- **Word suggestions have ONE prompt path, and the AAC rules that reach it
  depend on the JOB.** `Api::BoardsController#words` used to fork on
  `prompt == @board.name` into a second, much weaker prompt builder — and since
  the editor seeds the override field with the board name and sends it verbatim,
  "left the field alone" was indistinguishable from "typed the board name", so
  the default case took the weak branch every time. One path now
  (`get_word_suggestions_from_default_prompt`), whatever the prompt says; it
  already special-cases a menu board internally, so there is no separate menu
  branch to disagree with it. The second half is the AAC one:
  `Prompts::Aac::WORD_RULES` is `BOARD_COVERAGE_RULES + WORD_CRAFT_RULES`, and
  **only a caller laying out a WHOLE board may send the coverage half.** Those
  rules ("include at least one of: again, different, something else, all done";
  "skip nouns that exist to be labelled") are right for a core board and wrong
  for an incremental add to a fringe page — a board called "Places" came back
  with four strings copied verbatim out of the rule while its place names were
  suppressed. `Prompts::Aac.incremental_word_rules` sends craft rules always and
  **re-adds** the objection/redirect ask only when `can_object_or_redirect?`
  says the board's own tiles cannot yet do it: a board that cannot refuse is an
  autonomy failure, so the principle is preserved, not dropped. `WORD_RULES`
  stays byte-identical so the whole-board callers are untouched — never "tidy"
  the split by rewrapping it. Details: `.claude-notes/ai-prompting.md`.
- **`Boards::TileArrangement` is the ONE part-of-speech band order, and it is
  shared.** It was `Boards::AdminBuilder::TileArrangement` until "Format with
  AI" started using it too; the old constant is a Zeitwerk-visible alias at the
  old path, so drafters keep resolving it. Both callers turn a position straight
  into a cell, so the arranged order IS the layout. Two things ride on it. The
  sort is STABLE, which is what preserves whatever order the model chose inside
  a band — that is how `up`/`down`, `hot`/`cold` and `here`/`there` stay
  adjacent, and it is the only pairing the app does: a cross-band pair
  (`stop` is `important_function`, `go` is a verb) is deliberately NOT kept
  together, because contiguous colour blocks beat antonym adjacency on a
  Fitzgerald board. And `arrange` corrects the part of speech through
  `AacWordCategorizer::OVERRIDES` (a table lookup, never the paid per-word
  `categorize`) before banding — so the value a tile is COLOURED by must be the
  one it was SORTED by, or a red protest word ends up green in the verb block.
  Feed it `links_to` from `BoardImage#door_tile?`, never from
  `predictive_board_id`: predictive and dynamic WORD tiles carry that column
  too, and banding one as navigation drags a spoken word to the bottom row.
- **Never seed `profiles.bio` or `profiles.intro` with instructional copy.**
  Both are PUBLIC — `/my/:slug` prints the bio as "About me" and speaks the
  intro aloud on "Hear my intro" — so placeholder text stored there is
  published to visitors *in the communicator's own voice*, and `bio.present?`
  stops meaning "the owner wrote something". Every creation path used to do it
  (`set_defaults`, `.create_for_user`, `.generate_with_username`,
  `.create_placeholders`); blank is the honest state, and the frontend supplies
  its own copy when there is nothing to show. `Profile::SEEDED_TEXT` /
  `.seeded_text?` exist only to recognize the historical strings — match whole
  strings, never a substring, since a real bio may quote the phrase. Note
  `claim!` keeps whatever is stored, so anything seeded onto a placeholder
  follows it onto a real, claimed page.
- **Third-party sends are env-gated to production** (Mailchimp journeys,
  PostHog captures; staging excluded via `AppEnv.staging?`) so non-prod can't
  email or track real users. Transactional mail is covered by the same rule at
  the delivery layer: `StagingMailInterceptor` drops every message on staging
  unless the recipient is in `STAGING_MAIL_ALLOWLIST`.
- **Rails creates marketplace DRAFTS and never activates one.**
  `Etsy::Client#create_listing` hardcodes `state: "draft"` and the client
  implements no activate call — the absence is the guarantee. Publishing a
  board printable to Etsy means creating a draft; going live stays a deliberate
  click in the Etsy seller UI. The line the invariant draws is between ADDING
  media and UPDATING a listing: `upload_image`/`upload_file`/`upload_video` all
  run against listings and always have, so sending a video to a listing that has
  none (`Etsy::PushListingVideo`) is in bounds, while replacing a gallery needs a
  DELETE and stays out — that path lives in `speakanyway-printables`. Relatedly,
  Etsy's refresh token is single-use and
  rotates on every exchange, so it lives in `oauth_credentials` (not ENV) and
  Rails holds a **separate authorization** from the one `speakanyway-printables`
  uses — a shared grant makes the two invalidate each other.
- **A `board_printables` blob is a download, a gallery image, or the listing
  video — and `pdf_files` is the ALLOWLIST that keeps them apart.** The three
  share one `has_many_attached :files`, separated by blob metadata `kind`
  (`pdf`/`image`/`video`, with a missing `kind` meaning PDF for everything
  written before the split existed). `pdf_files` once selected by EXCLUSION
  (`kind != "image"`), which was correct only while "not an image" and "is a
  PDF" were the same thing; adding video made that false and the video then read
  as a buyer download everywhere — served by `files_view`, uploaded to Etsy as
  `application/pdf` against the five-file cap, and, silently, destroyed by
  `purge_stale_pdfs!` on every "Regenerate", which is handed only the keys of
  the PDFs that run just wrote. A new kind gets its own reader and stays out of
  `KIND_DOWNLOADABLE`; never widen the partition by negation.
- **`child_accounts.settings` MERGES on update; `details` REPLACES.** The two
  jsonb blobs have opposite semantics on purpose, and both are load-bearing.
  Several frontend surfaces save `settings` as a fresh literal holding only
  their own slice, so a wholesale assignment dropped every key the saving
  screen didn't know about — dashboard layout columns, `primary_team_id`,
  archive/reclaim/fallback state. `details` stays a replace because the AAC
  profile clears a field by DELETING its key, so merging would make "Not set"
  a no-op. Two corollaries: clearing a settings key means sending an explicit
  blank/nil, never omitting it; and anything the replace used to remove as a
  side effect must now be removed deliberately (`demo_board_limit` on
  sandbox→active, mirroring `ChildAccount#promote_to_active!`). Note the
  column has **no DB default**, so `settings` can be `nil` on any row — every
  reader and writer needs `self.settings ||= {}`.
- **An ABSENT settings key is not `false`, and the defaults live in ONE place.**
  `DisplaySettingsDefaults` (included by both `User` and `ChildAccount`) owns
  the boolean display flags and what each defaults to — `enable_image_display`,
  `show_labels`, `show_tutorial` true; `wait_to_speak`,
  `disable_audit_logging`, `enable_text_display` false. Two rules ride on it.
  A WRITER guards on `key?`, never on truthiness: the admin form submits only
  the fields an admin touched, so `params[:x] || false` wrote `false` to every
  flag it omitted — turning off the symbol strip for any user whose plan an
  admin edited, and `ensure_settings` never repaired it because it only fills a
  `nil`, never a stored `false`. And a flag the models default must be a flag
  an admin can SET (`show_labels`/`show_tutorial` were defaulted but permitted
  nowhere), which is why both admin paths and both models read the one list.
  The communicator blob stays unwhitelisted — each tab sends its own slice —
  but these keys are boolean-cast on the way in, since a string `"false"` is
  truthy in Ruby and would read as "on" everywhere the flag is checked.
- **Email verification is keyed on `email_verified_at`, never `confirmed_at`.**
  `User#mark_email_verified!` is the only writer. Verified status may be
  conferred ONLY by a path where the user clicked a link delivered to their
  inbox: the verification link (`GET /api/verify_email`), temp-login, and
  email-change confirmation. `set_password` / invitation-accept must never
  confer it — `email_signup` signs the user in before any email is opened, and
  `devise_invitable` stamps `confirmed_at` on `accept_invitation!` for any model
  carrying that column, so `confirmed_at` cannot be a verification signal.
  **Verification does not gate AI, and must not be made to again.** Welcome
  tokens and the plan's AI credit allowance are granted at SIGNUP
  (`User#grant_signup_ai_allowance`, an `after_commit on: :create` — never
  `after_create`, since `grant_plan!`'s nested transaction would let a swallowed
  error turn the user's own COMMIT into a ROLLBACK). Deferring the grant until
  the link was clicked was a free abuse gate on paper — a zero balance is a
  check no future AI code path can forget — but the bill fell on every honest
  account that hadn't opened its email yet, and three separate places had to
  agree about it: the grant, `RefreshFreeTierCreditsJob` (which re-zeroed the
  free allowance a month later), and a bespoke 403 `email_verification_required`
  on `POST /api/images/generate`, needed only because the free first-fill path
  never calls `check_credits!` and so had no balance to stop it. All three are
  gone; the credit ledger is the only gate. `mark_email_verified!` still calls
  the two grants because both are idempotent — `ensure_initial_grant!` on an
  existing `plan_grant` row, `grant_welcome_tokens!` on its own
  `settings["welcome_tokens_granted_at"]` stamp — which is what heals an
  account created while the old gate was live (`rake
  credits:backfill_welcome_tokens` for the ones that never verify).
  Verification is still stamped, still emailed, and still means "this inbox was
  opened"; it just buys nothing. It never gated authentication either.
- **`users.tokens` is the LEGACY per-image counter; AI credits are the
  `CreditService` ledger. Two quantities, never one number.** `WELCOME_TOKENS`
  is 10 and is spent by `API::ImagesController#find_or_create`;
  `PLAN_MONTHLY_CREDITS["free"]` is 25 and is what every surface advertises.
  `User#api_view` published `tokens` and nothing else credit-shaped, so a client
  rendering an AI-credit meter from the user object had only the wrong number to
  read and reported 10 against copy promising 25 — with both sides correct about
  their own quantity, which is why it survived as a "the grant is broken" bug
  report. The payload now carries `ai_credits` (the balance) and
  `ai_credit_allowance` alongside it. The allowance is `CreditService.plan_allowance`,
  which reads the last `plan_grant` ROW rather than the plan-type constant, so a
  Stripe Price `monthly_credits` override reaches the gauge — never restate
  `PLAN_MONTHLY_CREDITS` at a call site, and never treat `tokens` as credits.
- **A blank `board_images.display_image_url` means "this tile has no picture"
  — resolve tile art with a bare `||`, never `.presence`.** The app stops on
  the blank because `""` is truthy in Ruby
  (`Board#api_view_with_predictive_images`), and every Grover render must agree
  with it: `Boards::BoardPdfLayoutNormalizer` feeds `Boards::RenderAssetData`,
  which is the sole input to the downloadable PDF, the board cover PNG
  (`Boards::GeneratePreviewAssets`), and the whole printables pipeline. Wrapping
  the chain in `.presence` treated the marker as absent and fell through to the
  underlying `Image`'s library art, so a Core Safety colour tile the app draws
  as the word "red" on a red square printed an apple. Note the print template
  needs no help here — a blank `image_url` already renders the label via the
  **transparent** `generate_placeholder_image` SVG, so the tile's `bg_color`
  shows through and the swatch matches the screen. Two related traps: covers are
  cached artifacts, so a renderer fix leaves them stale until reprocessed
  (`rake board_covers:refresh_blanked_tile_covers`); and `BoardImage#set_defaults`
  seeds `display_image_url` from `image.src_url` on create, so a spec must write
  the blank *after* creating the tile.
- **A Sidekiq job that names a row must not be pushed from inside the
  transaction that writes it.** `perform_async` hits Redis immediately and the
  worker reads on its own connection, so it can dequeue before the commit and
  die on `RecordNotFound` — and a rolled-back transaction leaves a job pointing
  at a row that will never exist. Nothing in the app enables transactional push,
  and these are plain `Sidekiq::Job`s, so `enqueue_after_transaction_commit`
  doesn't apply either. Wrap the push in
  `ActiveRecord.after_all_transactions_commit` (a no-op outside a transaction)
  or hoist it past the `end`, as `Boards::AdminBuilder::Build` does for art
  generation. The trap is that the enqueue is usually two or three calls deep
  and invisible from the transaction: `Board#apply_layout!` queues a cover
  render, and `BoardImage`'s create callback queues audio, so writing a board
  set inside one transaction fans out a job per page. **`RecordNotFound` is the
  loud failure; silence is the other one** — a job that resolves its row with
  `find_by` instead of `find` just skips the write. `SaveAudioJob` does exactly
  that: it logs "BoardImage with ID ... not found" and never fills in that
  tile's `audio_url`/`voice`, while the audio FILE still lands on the Image, so
  the board sounds right and only the tile's own columns are empty. Those tiles
  don't self-heal either — `Board#api_view_with_images` only re-enqueues when
  `board_image.voice != voice_to_play`, and `set_defaults` stamps the tile with
  the board's voice, so the serializer ships `audio_url: nil` forever
  (`rake tile_audio:missing_report` finds them). Never "fix" a not-found job by
  making it retry or tolerate the miss — that hides the ordering bug. Audio
  enqueues live behind `BoardImage#enqueue_voice_audio_job`, not at the call
  sites, so the guard can't be forgotten by the next caller.
- **An ActiveStorage variant must never be rendered inside an open
  transaction.** Rendering writes the variant's bytes from an `after_commit`
  callback, but image_processing's output tempfile is closed AND UNLINKED the
  moment the transform block returns (`Transformers::Transformer#transform`
  ends in `output.close!`). With a transaction open that callback is deferred
  to the OUTER commit, so `S3Service#upload` reads `io.size` on a path that is
  already gone and the job dies at commit time on `Errno::ENOENT @
  rb_file_s_size - /tmp/image_processing*.webp`. `Doc.variant_render_safe?` is
  the test (Rails' own `ActiveRecord.all_open_transactions`, which counts only
  JOINABLE transactions, so transactional fixtures don't make every spec
  defer); `Doc#ensure_tile_variant!` and `#queue_tile_variant_render!` are how
  a caller asks for a render. Same trap as the bullet above — the render is
  usually several frames deep and invisible from the transaction: `Image`'s
  `before_save :update_src_url` reads `doc.tile_url`, so merely SAVING an
  image inside a builder transaction renders a variant. When a render is
  deferred, `Doc#tile_url` serves the full-resolution original, which is
  correct, larger, and — the part that matters — never `""`, the marker for
  "this tile has no picture".

- **A kit landing page's public read carries no file URL.** `/kit/:slug` is a
  lead magnet: `KitPage#public_view` publishes copy plus a `downloadable`
  boolean, and the printable's URL is revealed only by `POST
  /api/kit_pages/:slug/download`, after a `DownloadLead` is written with
  `source = "kit_<slug>"`. That gate is SOFT on purpose and must not be
  "hardened" in place — production S3 is `public: true`, so every
  `board_printables` blob already sits behind a permanent unsigned CDN URL whose
  hex path segment is the only protection; making it real means moving
  printables to a private service, not adding a check to this controller. Two
  things ride on the `kit_` source prefix. `MailchimpUpsertLeadJob` resolves the
  tag from the `KitPage` row rather than from its frozen `SOURCE_TAGS` hash —
  that lookup is the whole reason a new landing page needs no deploy, and it may
  never raise, since a page deleted after its leads were captured must fall back
  to the default tag rather than strand the lead. And the download is PDFs and
  only PDFs from either source — `BoardPrintable#files_view` or
  `KitPage::DOCUMENT_CONTENT_TYPES` — both ALLOWLISTS, so a listing image or the
  listing video can never be handed to a visitor as the product.
- **A kit page's UPLOADED documents win outright over its printable — for the
  download and for the pictures alike.** `KitPage has_many_attached :documents`
  (the file) and `:preview_images` (rendered from it); while any document is
  attached, `#download_files` and `#gallery_images` both ignore
  `board_printable` completely. Serving half of one and half of the other would
  put a board's marketplace mockups above an unrelated document. Two named
  attachments rather than one bag keyed on blob metadata, deliberately: the
  `pdf_files` invariant above exists because `BoardPrintable` shares one `files`
  collection across three meanings and once partitioned it by exclusion. A
  document's admin-typed LABEL rides its blob metadata and is published as the
  row's `variant`, because that is the field the frontend prints on the button —
  which is why a multi-document kit needed no frontend change at all. Preview
  images come from `KitPages::DocumentPreviewRenderer`, libvips' `pdfload_buffer`
  (already the Active Storage variant processor, so no new gem and no new
  binary), gated on `.available?` in the `VideoTranscoder` style: where this
  host's libvips has no PDF loader the page simply shows no mockups and the
  admin is told so, because a gallery is marketing and the download is the
  product. Every blob is written to a VERSIONED key — CloudFront caches by path
  and ignores query strings, the same lesson
  `BoardPrintable#versioned_storage_key_for` records.
- **Every buyer-facing file carries TWO urls, and the split is load-bearing.**
  `files_view` serves `url` (CDN, cached, previews in the browser) *and*
  `download_url` (presigned, `Content-Disposition: attachment`, saves the file).
  The second exists because `/kit/:slug`'s Download button opened a PDF viewer
  instead of downloading: our CDN sends no `Content-Disposition`, and neither
  frontend workaround applies — an anchor's `download` attribute is ignored
  cross-origin and fetch+blob dies on CORS. Two traps behind it:
  - **`file.url(disposition: :attachment)` silently does nothing here.** The
    `amazon` service is `public: true`, and `ActiveStorage::Service#url` routes
    a public service to `public_url`, which drops `disposition` on the floor.
    `AttachedFileUrls#download_url_for_file` therefore presigns the object
    directly, mirroring what `S3Service#private_url` would have done. That pair
    (`url_for_file` / `download_url_for_file`) is a CONCERN, included by both
    `BoardPrintable` and `KitPage` — too subtle to keep two copies of.
  - **It addresses the BUCKET, not `CDN_HOST`.** CloudFront ignores query
    strings (the same fact that forces versioned keys in
    `#versioned_storage_key_for`), so a `response-content-disposition` sent
    through the distribution would never reach S3. A download link skipping the
    CDN is the deliberate trade.

  It is opt-in per call (`view_for(..., with_download_url: true)`) so
  `listing_images_view` — and `KitPage#preview_images_view` — don't sign a URL
  per gallery image that nothing follows, and it returns nil rather than raising — same contract as
  `url_for_file`, since a bad credential must not 500 the admin status poll.
  **Dev and test are the Disk service, which honours `disposition` through the
  ordinary URL builder and hides this entire problem** — verify on staging.
- **The PRODUCT is gated; a PICTURE of it is not.** `public_view` also carries
  `images`, the printable's rendered marketplace mockups, and that is not a hole
  in the bullet above — a lead magnet no one can see converts nothing, and these
  renders are marketing art on the same public CDN, not the document. For an
  uploaded-document page the pictures are the document's own first pages,
  capped at `KitPage::PREVIEW_PAGE_COUNT`; for a printable-backed one the line
  is drawn by `KitPage::KIT_IMAGE_ORDER`, a curated ALLOWLIST over
  `BoardPrintable#listing_images_view` (which has already dropped retired
  gallery designs). Narrow by allowlist, exactly as `pdf_files` does: a new
  image variant must be opted in before a visitor can see it, and `about` /
  `page_index` stay out because they are Etsy shop framing. Never widen this by
  excluding what you don't want.
- **A kit page's Canva TEMPLATE LINK is the product; its label and description
  are marketing.** A template is an editable Canva design a visitor gets their
  own copy of — the MySpeak ID card, where the QR can only be made by the person
  who owns the page. `public_view` carries `template_teasers` (label +
  description, no link); `#download` carries `template_links`, after the lead,
  exactly as it carries the PDF. The two reader names differ on purpose so the
  one holding the product is obvious at the call site. Three rails.
  `canva_templates` is its OWN COLUMN and not a key under `content`, because
  `public_view` ships `content` wholesale — parking a link there publishes it,
  and stripping it back out on the way through is the one-column-two-meanings
  trap `pdf_files` already records. The URL is checked against an ALLOWLIST
  — https, and either `CANVA_DESIGN_HOSTS` + a `/design/` path prefix or a
  `CANVA_SHORT_HOSTS` (`canva.link`) link naming something past the root, since
  Canva's own Share menu hands out both shapes and a short link is not
  rewritten on the way in. Never an exclusion, and a refusal must NAME the
  accepted shapes or the second one reads as a bug.
  And `downloadable?` keeps its narrow meaning — "a readable PDF exists" —
  while `offers_anything?` is what opens the gate, so a page may hand over
  templates and no PDF at all; the download response still carries `files: []`
  so a frontend that predates templates hits its existing dead end rather than
  throwing. Nothing health-checks a link: an unshared design is a dead button
  the admin must catch.
- **Kit-page autofill populates the form and nothing else.**
  `KitPages::CopySuggester` writes a whole page from the printable it gives
  away; `Admin::KitPagesController#autofill` merges it BLANKS-ONLY and never
  saves, so nothing typed is lost and a bad suggestion is discarded by
  navigating away. Two rails: the slug is derived only into a blank field (it is
  the `/kit/<slug>` URL a campaign links to — same rule boards got for renames),
  and `listing_copy["description"]` is never fed to the model, because Etsy
  checkout prose reads as a sales pitch on a page giving the thing away. The
  form needs `data: { turbo: false }` — the action renders a 200 instead of
  redirecting, and Turbo Drive silently no-ops such a response.

## Subsystem map (read the spoke before working in the area)

| Spoke | Covers |
|---|---|
| `.claude-notes/billing-and-plans.md` | Stripe + RevenueCat subscription paths, webhooks + idempotency, no-card reverse trial, soft trial, Partner Program (`partner_pro`), email-only (passwordless) signup, social sign-in (Google, Phase 1), plan-switch endpoints + error contract, `paid_plan?` details, MySpeak ID limit, downgrade rules (board read-only lock + `make_editable` cooldown, communicator fallback + `keep_signable`, sandbox→active promotion), Mission Control revenue metrics |
| `.claude-notes/credits.md` | AI credit ledger: `CreditService`, feature costs, `check_credits!` / 402 contract, grant lifecycle + refresh/expiry cron jobs, menu image budget + refunds, free first-fill image generation, credits rake tasks, beta entitlement audit, email verification's welcome-token/credit grant |
| `.claude-notes/marketing-integrations.md` | Mailchimp CRM sync + Customer Journeys (all journey keys + ENV wiring), dual-welcome design, plan-welcome idempotency, PostHog server-side events + `distinct_id` contract |
| `.claude-notes/safety-profiles.md` | MySpeak safety pages: gated emergency-info reveal, view logging + parent alerts + throttling, coarse IP geolocation, random slugs + legacy-slug fallback |
| `.claude-notes/boards-and-teams.md` | Team permissions / owner-pinning, SLP→family hand-off, board/set deep clone (`SetCloner`, `CloneSetPlanner`), non-destructive board removal, board deletion warn+confirm (409), frozen published slugs, Board Sets (BoardGroup) CRUD + limits, responsive layouts (sm/md derived from lg), OBF/OBZ import copyright policy, Make a Board From Screenshot |
| `.claude-notes/board-builder.md` | Board Builder wizard end-to-end: starter templates, complexity levels + `StructurePlanner`, Core 60/84 robust vocab sets + seed self-healing, communicator AAC profile, gestalt (GLP) support, all builder rake tasks, the `/admin/board_builder_templates` registry + health page |
| `.claude-notes/ops.md` | Monitoring/alerting details, AppSignal APM config, full Rack::Attack throttle rules + ENV vars |
| `.claude-notes/marketing-assets.md` | AAC Classroom Kit hosting: `MarketingAsset`, internal endpoints, marketing print style, QR scannability rule (do not re-add long UTMs to tag QRs) |
| `.claude-notes/internal-api.md` | Internal `/api/internal/` surface: bearer auth + admin identity, public-CDN download path (`src` vs `original_url`), image + board search endpoints, `Images::CommercialLicense` licensing rule |
| `.claude-notes/ai-prompting.md` | The shared AAC prompt kernel (`Prompts::Aac`): the two personas and when each applies, why `WORD_RULES` is opt-in per call, schema-over-prose, temperature and the retry ladder, what `AdminBuilder::Drafting` keeps to itself, and the sentinel/truthiness trap in next-words |
| `.claude-notes/library-image-dedupe.md` | Library dedupe end-to-end: the scan-then-apply split, the never-a-user-image scope, POS/language grouping, the associations a merge must carry (predictive boards, user docs, soft-deleted docs), the `image_merges` ledger + kill switch, and the admin default-art/doc-removal endpoints |
| `.claude-notes/image-generation.md` | AI tile art: `Images::PromptBuilder` (the single prompt source of truth, always-wrap rule), symbol vs illustrated style resolution, part-of-speech homograph disambiguation, transparency/quality API params + model fallback, refusal retry, variations via the edit endpoint, prompt provenance on docs |
| `.claude-notes/board-printables-etsy.md` | Publishing a board printable to a marketplace: the drafts-only rule, Etsy's rotating refresh token + why Rails holds a separate grant, the ported Etsy v3 API quirks, listing-copy rules (and their Ruby↔TypeScript drift), Grover-rendered gallery images, the TPT paste sheet |
| `.claude-notes/word-packs.md` | Quick-add word packs: the static catalog, the "client names a key / server owns the vocabulary" rule, why a pack costs no OpenAI (authored part_of_speech + `max_generate: 0`), the OVERRIDES-wins colour rule, and the read-only catalog endpoint |
| `.claude-notes/writing-suggestions.md` | Contextual writing suggestions (`POST /api/suggestions`): field registry + context allow-list, the no-safety-keys privacy invariant, OpenAI generator + fixtures, free/no-credit contract, user opt-out toggle |
| `.claude-notes/kit-landing-pages-handoff.md` | Kit landing pages (`/kit/:slug`): the `KitPage` model, the public read/download contract, the `kit_<slug>` lead source and its dynamic Mailchimp tag, the `/admin/kit_pages` CRUD and its Etsy give-away guard |

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
- That pinned-id insert is safe **because** `spec/support/users_id_sequence.rb`
  parks the `users` primary-key sequence above every hand-picked id (an
  explicit-id INSERT doesn't advance the Postgres sequence, and sequences
  aren't rolled back between examples, so without the guard the next
  `create(:user)` in the process is handed the admin's id and dies on
  `users_pkey`). Never "fix" an ordering collision by resetting the sequence
  down to `MAX(id) + 1` in a spec — that reinstates the zero-slack state the
  guard exists to avoid.

### Suite speed

- **Expensive, read-only setup goes in `before_all` / `let_it_be`**
  (test-prof, already required in `spec/rails_helper.rb`). Seeding a vocab set
  or a template tree per example is the single biggest source of slowness here
  — `build_board_set_job_grid_spec.rb` was 511s before its seed was hoisted.
  Each example still runs in its own savepoint, so a write inside an example
  is rolled back and can't leak forward; only put setup there, never mutation.
- **`before_all` runs outside the per-example hooks**, so rspec-mocks stubs
  (`allow(...)`) are NOT in effect inside it. If the setup would hit OpenAI,
  call `register_openai_webmock_stub!` directly — WebMock registration is plain
  code and survives out there.
- **Don't `allow(ENV).to receive(:[]).and_call_original`** in a request spec if
  you can avoid it: every ENV read in the request cycle then goes through a
  mock proxy. (Measured the opposite too — replacing it with a real ENV var in
  `internal/images_spec.rb` made that file *much* slower by changing which code
  path ran. Measure before "fixing" one of these.)
- **Test logging is `:warn`.** Set `VERBOSE_TEST_LOG=1` for full SQL in
  `log/test.log`; at `:debug` the suite fills the 50 MB cap in ~2 minutes.
- **Per-file timings, not filenames, drive CI sharding.** `bin/ci-shard` reads
  `spec/ci_timings.json` and greedily bin-packs slowest-first over
  `CI_NODE_TOTAL`. Files with no recorded timing get the median, so a new spec
  is never dropped; CI asserts the split covers every spec exactly once.
- **Refresh the timings from CI, not from a laptop run.** Every shard uploads
  its `spec/examples.txt` as an `rspec-timings-<n>` artifact. To refresh:
  ```bash
  gh run download <run-id> --dir /tmp/t && cat /tmp/t/*/examples.txt > spec/examples.txt && bundle exec rake ci:timings
  ```
  Laptop numbers mis-rank the suite badly — under local load `board_spec.rb`
  and `boards_publish_cascade_spec.rb` looked like the #2 and #3 slowest files
  and on CI they aren't in the top ten. `rake ci:timings` also works off a
  local full run, and warns when `spec/examples.txt` looks partial.
- Profile with `bundle exec rspec --profile 25`, and note that per-file numbers
  from a *full* run are inflated by machine load — confirm a suspect file
  standalone before optimizing it.

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
