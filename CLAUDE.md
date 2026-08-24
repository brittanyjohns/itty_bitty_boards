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
  environment.
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
  `communicator_in_fallback`, `myspeak_id_limit_reached`, …). **409** = state
  conflicts, some confirmable (`board_in_use`,
  `publish_cascade_confirmation_required`,
  `board_marketplace_edit_confirmation_required`) and some not
  (`board_marketplace_protected`) — an unconfirmable conflict is always
  answered FIRST, or the client learns to retry into a wall. Never leak
  internals in API errors — generic messages only.
- **`User#paid_plan?` is the single paid-tier gate.** It checks both
  `plan_type` and `plan_status`; `basic_trial` and Stripe `trialing` count as
  paid while active. Never read `plan_type` directly for a paid-feature check.
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
- **`User#countable_board_count` / `at_board_limit?` is the single source of
  truth for board counting.** Builder sub-boards (`builder_child`) are
  excluded so a built tree counts as one; every creation gate routes through
  it.
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
- **A board on a communicator's MySpeak page is a PUBLISHED board.** The public
  grid selects on `child_boards.favorite`, but the board behind each card is
  gated on `Board#viewable_by?`, which refuses an anonymous visitor an
  unpublished board — so favoriting alone served a working card that 404'd on
  tap, and that was the DEFAULT state (Board Builder roots and
  `AssignmentCloner` clones are both born unpublished). Both halves are
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
- **`print_grid_layout_for_screen_size` must build a DENSE list.** It once
  assigned into a plain Array at `layout_to_set[bi.id]` — the global
  `board_images` primary key — then compacted the holes away, so serializing a
  30-tile board allocated an array sized to `MAX(board_images.id)` and the cost
  of every `Board#api_view` grew with the whole table. Nothing reads the index
  positions; every consumer reads each cell's own `x`/`y`. The memo it now
  keeps is cleared wherever tile layouts are rewritten (`board_images.reset`).
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
- **Email verification is keyed on `email_verified_at`, never `confirmed_at`.**
  `User#mark_email_verified!` is the only writer. Verified status may be
  conferred ONLY by a path where the user clicked a link delivered to their
  inbox: the verification link (`GET /api/verify_email`), temp-login, and
  email-change confirmation. `set_password` / invitation-accept must never
  confer it — `email_signup` signs the user in before any email is opened, and
  `devise_invitable` stamps `confirmed_at` on `accept_invitation!` for any model
  carrying that column, so `confirmed_at` cannot be a verification signal.
  Unverified accounts hold zero welcome tokens and zero AI credits and are
  refused image generation (403 `email_verification_required`); they can still
  sign in and use the app — **verification never gates authentication**.
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
  to the default tag rather than strand the lead. And the download always comes
  from `BoardPrintable#files_view`, the PDF ALLOWLIST, so a listing image or the
  listing video can never be handed to a visitor as the product.
- **The PRODUCT is gated; a PICTURE of it is not.** `public_view` also carries
  `images`, the printable's rendered marketplace mockups, and that is not a hole
  in the bullet above — a lead magnet no one can see converts nothing, and these
  renders are marketing art on the same public CDN, not the document. The line
  is drawn by `KitPage::KIT_IMAGE_ORDER`, a curated ALLOWLIST over
  `BoardPrintable#listing_images_view` (which has already dropped retired
  gallery designs). Narrow by allowlist, exactly as `pdf_files` does: a new
  image variant must be opted in before a visitor can see it, and `about` /
  `page_index` stay out because they are Etsy shop framing. Never widen this by
  excluding what you don't want.
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
| `.claude-notes/boards-and-teams.md` | Team permissions / owner-pinning, SLP→family hand-off, board assignment deep clone (`AssignmentCloner`), non-destructive board removal, board deletion warn+confirm (409), frozen published slugs, Board Sets (BoardGroup) CRUD + limits, responsive layouts (sm/md derived from lg), OBF/OBZ import copyright policy, Make a Board From Screenshot |
| `.claude-notes/board-builder.md` | Board Builder wizard end-to-end: starter templates, complexity levels + `StructurePlanner`, Core 60/84 robust vocab sets + seed self-healing, communicator AAC profile, gestalt (GLP) support, all builder rake tasks |
| `.claude-notes/ops.md` | Monitoring/alerting details, AppSignal APM config, full Rack::Attack throttle rules + ENV vars |
| `.claude-notes/marketing-assets.md` | AAC Classroom Kit hosting: `MarketingAsset`, internal endpoints, marketing print style, QR scannability rule (do not re-add long UTMs to tag QRs) |
| `.claude-notes/internal-api.md` | Internal `/api/internal/` surface: bearer auth + admin identity, public-CDN download path (`src` vs `original_url`), image + board search endpoints, `Images::CommercialLicense` licensing rule |
| `.claude-notes/image-generation.md` | AI tile art: `Images::PromptBuilder` (the single prompt source of truth, always-wrap rule), symbol vs illustrated style resolution, part-of-speech homograph disambiguation, transparency/quality API params + model fallback, refusal retry, variations via the edit endpoint, prompt provenance on docs |
| `.claude-notes/board-printables-etsy.md` | Publishing a board printable to a marketplace: the drafts-only rule, Etsy's rotating refresh token + why Rails holds a separate grant, the ported Etsy v3 API quirks, listing-copy rules (and their Ruby↔TypeScript drift), Grover-rendered gallery images, the TPT paste sheet |
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
