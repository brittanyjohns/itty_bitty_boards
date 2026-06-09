# Changelog

All notable user-facing changes to this project will be documented here.
The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added — Mailchimp Customer Journey triggers for first-board nudge (#2) and hit-your-limit (#3) emails
- **First-board nudge.** New `MailchimpFirstBoardNudgeJob` (Sidekiq-cron,
  daily at 4am UTC) finds non-admin users who signed up 48-72h ago with no
  boards and enqueues the Mailchimp `first_board_nudge` Customer Journey.
  Per-user dedupe via `user.settings["first_board_nudge_sent"]` so the
  same user isn't nudged across runs; the 24h window gives a missed cron
  run a chance to catch up. (Issue #291, journey #2.)
- **Hit-your-limit.** `API::BoardsController#check_board_create_permissions`
  now enqueues the Mailchimp `hit_limit` Customer Journey when a Free user
  trips the board cap on `create` / `clone` / `create_from_template`. Free
  users only; deduped per user for 14 days via `Rails.cache` so a user
  mashing the create button isn't spammed. Guarded so a Mailchimp/Redis
  blip can't 500 the API request. (Issue #291, journey #3.)
- Inert until configured: both keys no-op until
  `MAILCHIMP_JOURNEY_FIRST_BOARD_NUDGE_ID/_STEP` and
  `MAILCHIMP_JOURNEY_HIT_LIMIT_ID/_STEP` ENV vars are set, and journeys
  remain prod-only by default (`MAILCHIMP_JOURNEYS_ENABLED=true` to
  override in staging/dev).

### Added — RevenueCat / Apple IAP subscription path reaches Stripe parity
- **Closed a self-upgrade hole.** `POST /api/billing/update_subscription` no
  longer trusts the native client's claimed plan. It now verifies the user's
  entitlement against RevenueCat's REST API (`RevenueCat::Client`) and returns
  **403 `Subscription could not be verified`** unless the claimed tier matches
  an active entitlement. Requires `REVENUECAT_REST_API_KEY`.
- **Real RevenueCat webhook.** `POST /api/billing/webhooks` (previously a no-op
  stub) now verifies a shared-secret `Authorization` header
  (`REVENUECAT_WEBHOOK_AUTH_HEADER`, 401 on mismatch) and handles the full
  lifecycle, mirroring the Stripe webhook: `INITIAL_PURCHASE`/`RENEWAL`/
  `PRODUCT_CHANGE` grant the tier's credits, `EXPIRATION`/`SUBSCRIPTION_PAUSED`
  downgrade to free, `CANCELLATION` is analytics-only (access kept until
  expiry), `BILLING_ISSUE` keeps access during the grace period, plus
  `UNCANCELLATION` and `TRANSFER`. Fires the same `subscription_started` /
  `subscription_canceled` analytics + PostHog events as Stripe.
- **Idempotent & sandbox-safe.** Events are de-duped via a new
  `processed_webhook_events` table (unique on `provider`+`event_id`), so replays
  no-op; SANDBOX events are ignored in real production.
- Downgrade-to-free logic is now shared (`Billing::PlanTransitions`) so Stripe
  and RevenueCat cancellations land a user on free identically.

### Fixed — Yearly subscribers now get monthly AI credits, not one annual lump
- Plan credits are a **monthly** allowance, but a yearly subscription's grant
  previously set `plan_credits_reset_at` a full year out — so a yearly Basic/Pro
  subscriber received a single month's credits to last 12 months (this affected
  both Stripe and the new RevenueCat path). `CreditService.grant_plan!` now caps
  the grant window at `MAX_GRANT_WINDOW` (35 days), and `RefreshFreeTierCreditsJob`
  re-grants monthly for yearly Stripe subs (`settings["billing_interval"] ==
  "yearly"`) and all RevenueCat subs. Monthly subscribers are unchanged.

### Changed — Core 84 home reflowed to 14×6 with a right-side nav rail
- The Core 84 home board is now **14 columns × 6 rows** (was 12×7): on the
  one-page (no-scroll) layout, a 7th row rendered below the fold on iPad — the
  design baseline. Core word rows 1–5 are unchanged; row 6 absorbs `mine` and
  `wait`; all 10 fringe folders (People, Feelings, Food, Play, Places, Body,
  School, Time, Describe, More) now live in a 2-column rail on the right edge
  instead of being scattered through rows 6–7. Re-running
  `bin/rails vocab_sets:seed` applies the new layout to the seeded set.
  Seed-content rule going forward: **max 6 rows** on one-page boards.

### Added — Per-board thumbnails in the "Active · N" linked-boards list
- `api_view_with_predictive_images` now exposes `display_image_url` and
  `preview_image_url` on each `parent_boards` entry, so the frontend's branded
  LinkedBoardsModal (itty-bitty-frontend#320) can show a real thumbnail per
  linked board instead of only the colored initial chip. `display_image_url`
  resolves the board's stored cover with a live-preview fallback (mirrors how a
  board's own thumbnail is computed). The `parent_boards` query preloads the
  preview-image attachment to avoid an N+1 across linked boards.

### Fixed — Board Builder seeded sets: tile colors + one-page display (#279)
- **Tile colors now follow the authored Fitzgerald key.** `Board.from_obf`
  gained an opt-in `import_options[:apply_button_attributes]` (used by the
  `vocab_sets:seed` seeder only): each OBF button's authored `part_of_speech`
  is applied to the BoardImage and its background color derived via
  `ColorHelper::PRESET_DATA` (e.g. pronouns yellow `#FFEA75`, verbs green
  `#A1F571`, questions purple `#A07AFF`). OBF-standard explicit
  `background_color`/`border_color` win when authored. The shared Image's
  `part_of_speech` is backfilled only when blank — never overwritten. Re-seed
  heals mangled colors; user OBZ imports are unchanged.
- **Clones keep the authored colors.** `BoardImage#set_defaults` now respects a
  part_of_speech already present on the record (e.g. set by
  `Board#clone_with_images`' dup) instead of always re-reading the shared Image.
- **Seeded boards display on one page.** The seeder stamps
  `settings["disable_scroll"] = true` on every set board; the native board page
  reads this and fits the whole authored grid (Core 60: 10×6, Core 84: 12×7)
  on screen without scrolling. Cloned user sets inherit it.
- Run `bin/rails vocab_sets:seed` once after deploy to apply colors and
  one-page settings to existing seeded sets (already-cloned user sets keep
  their old colors).
### Added — Bulk display-label case transform
- `PUT /api/board_images/update` now accepts `payload[:label_case]`
  (`"upper"`, `"lower"`, or `"sentence"`). When present, each selected board
  image's `display_label` is rewritten in that case (sentence = first letter
  up, rest down). Falls back to the image's `label` when `display_label` is
  blank. Powers the "Aa" case buttons in the frontend bulk-edit drawer.
### Changed — Board Sets (BoardGroup) CRUD opened to all users
- Creating, editing, and organizing **Board Sets** is no longer admin-only.
  Any signed-in user can now create their own sets and manage the boards in
  them. Viewing stays public-by-link (`show` / `show_by_slug` / `preset`).
- **Security fix:** `rearrange_boards`, `save_layout`, and `remove_board` had
  **no authorization** — any signed-in user could modify (or empty out)
  anyone's set, including admin-curated predefined ones. All mutating actions
  (`update`, `destroy`, `rearrange_boards`, `save_layout`, `remove_board`, and
  the new `add_board`) now require the caller to be the set's owner or an admin,
  returning **HTTP 403** otherwise. Predefined sets remain admin-only.
- Regular users can no longer create or flip a set to `predefined`/`featured`
  — those params are stripped for non-admins.
- **Per-plan creation limits** (mirrors the board limit): Free 1, Basic 25,
  Pro 50. At the cap, `create` returns **HTTP 422** with `{ error, limit,
  count }`. Admins are unlimited. New optional env vars (defaults are sane):
  `FREE_BOARD_GROUP_LIMIT`, `BASIC_BOARD_GROUP_LIMIT`, `PRO_BOARD_GROUP_LIMIT`.
- New route `POST /api/board_groups/:id/add_board/:board_id` adds a board the
  caller owns (or a predefined/public board) to one of their sets.

### Added — Server-side PostHog subscription lifecycle events
- The Stripe webhook now fires three **server-side** PostHog events so the
  money-path funnel (pricing page → `checkout_started` → `subscription_started`)
  is buildable, and so conversions aren't missed when a user closes the
  success tab (itty-bitty-frontend#307, backend half):
  - **`trial_started`** `{ plan }` — on `customer.subscription.created` when the
    subscription is `trialing`.
  - **`subscription_started`** `{ plan, billing_interval }` — on the
    non-active→active transition (trial→paid / first activation).
  - **`subscription_cancelled`** `{ plan, reason? }` — on
    `customer.subscription.deleted` (reason from Stripe's cancellation_details
    when present).
- Each event also updates the person's `plan` property (`$set`), and uses
  `distinct_id = user.id.to_s` to match the frontend's `posthog.identify`
  contract so events land on the same person.
- Capture is **production-only** by default (staging/dev opt in via
  `POSTHOG_CAPTURE_ENABLED=true`) and wrapped so a PostHog failure can never
  break a Stripe webhook. New env vars: `POSTHOG_API_KEY`, `POSTHOG_HOST`
  (default `https://us.i.posthog.com`), `POSTHOG_CAPTURE_ENABLED`.

### Added — Robust vocabulary sets for the Board Builder (Core 60/84)
- The Board Builder picker now offers pre-authored **core vocabulary sets** (a
  real core grid + fringe category pages) alongside the small starter templates.
  Picking one **deep-clones** the seeded set for the communicator and routes the
  child's interest words into the cloned fringe pages — same one-round-trip
  flow, same `POST /api/v1/board_builder` → **201** contract.
- **Authored as our own OBF/OBZ**, reusing existing infrastructure end to end:
  sets are seeded with `ObzImporter` (grid layout + `part_of_speech` colors +
  `load_board`→`predictive_board_id` links), then cloned per user with
  `Board#clone_with_images` — so authored layout/colors are preserved (a
  rebuild-from-labels would drop them). Uses **SpeakAnyWay content only**.
- **Seeder:** `bin/rails vocab_sets:seed` imports the editable OBF-JSON source
  under `db/seeds/board_builder_sets/<slug>/` as admin, **with no `BoardGroup`** —
  a set is identified by a marker on its **root board**
  (`settings["board_builder_robust_slug"]`, via `Boards::RobustSets`).
  Idempotent. `bin/rails 'vocab_sets:build[core-60]'` emits a distributable
  `.obz`. Format spec: `db/seeds/board_builder_sets/README.md`. Slugs:
  `core-60` and `core-84` (both now ship **authored** content — see below).
- **A cloned set counts as ONE board** (root marked `builder_root`, the rest
  `builder_child`) and respects the plan board limit (**422**) and the re-run
  guard (**409** `board_builder_set_exists` unless `confirm=true`) — the same
  gates as the starter-template path. New `GET /api/v1/board_builder/templates`
  entries carry `kind: "starter" | "robust"`.
- Build runs **synchronously** for v1 (the work is DB-bound; previews/audio/AI
  art are already backgrounded). If a finalized set lands materially larger than
  the placeholder, the clone can move to a background job + "building" state
  (see `.claude-notes/board-builder.md`).
- New: `Boards::SeededSetCloner`, `Boards::RobustSets`, `VocabSets` service +
  `lib/tasks/vocab_sets.rake`. No schema changes.
- **Real Core 60 / Core 84 content seeded.** Both sets now ship authored
  SpeakAnyWay vocabulary, replacing the Core 60 placeholder and adding Core 84:
  Core 60 is a 10×6 core home + 8 fringe category pages (People, Feelings, Food,
  Drinks, Play, Places, Body, More); Core 84 is the 12×7 superset home
  with the same fringe plus School, Time, and Describe pages. Every tile carries
  a `part_of_speech` color and fringe folders link via `load_board`. Run
  `bin/rails vocab_sets:seed` to seed both as predefined, root-marked sets.

### Fixed — Board Builder vocab-set seeder now syncs removals and isolates the two sets (#277, #278)
- **Re-seed now propagates content removals (#277).** `bin/rails vocab_sets:seed`
  previously only upserted, so tiles and boards removed from the OBF source
  survived a re-seed (e.g. after the Keyboard board and the please/thank-you/and
  home tiles were cut). The seeder now runs a **destructive sync over admin-owned
  set boards only**: it destroys tiles whose label is gone from the source OBF and
  destroys boards whose `obf_id` left the manifest. `Board.from_obf` semantics for
  user OBZ imports are unchanged; **user clones (deep copies) are never touched.**
- **Core 60 and Core 84 no longer share fringe boards (#278).** Both sets used the
  same bare OBF ids (`people`, `food`, …) and seed as the same admin, so both roots
  linked to one shared fringe board and the last-seeded set won the in-set Home
  pointer — leaving the other set's cloned pages with **dead Home tiles**. Every
  board id in the seed source is now namespaced `"<slug>:<name>"` (e.g.
  `core-60:people`), so each set seeds its own disjoint fringe tree with in-set
  Home links.
- **Migration is self-healing.** The same prune step destroys the legacy
  un-namespaced boards (`people`, `food`, …) and the removed `keyboard` board, so a
  single `bin/rails vocab_sets:seed` after deploy cleans up the collision-era
  boards — no manual console cleanup.

### Fixed — Board Builder no longer silently duplicates a board set on re-run
- Re-running the wizard for the same communicator used to silently create a
  **second board set** with another `favorite: true` root (issue #269). The
  board-limit gate (#270) already blocked Free users on a re-run, but paid
  users (Basic/Pro) could stack duplicates.
- `POST /api/v1/board_builder` now **detects an existing builder set and warns**:
  it returns **HTTP 409** `{ error: "board_builder_set_exists", message,
  existing_root_id, existing_root_name, built_at }` instead of building. The
  client confirms and re-sends with **`confirm=true`** to intentionally build
  another set.
- Detection is durable and deletion-safe: each builder **root** board is now
  marked `settings["builder_root"] = true` (the counterpart to the sub-board
  `builder_child` marker), and `ChildAccount#board_builder_root` looks for one
  still attached to the communicator. Delete the set and a re-run is treated as
  a fresh build. The root stays countable — `builder_root` does not affect the
  board-limit count.

### Fixed — Board limit now enforced on all creation paths
- Three board-creation paths previously bypassed the plan board limit entirely:
  the **Board Builder** (`POST /api/v1/board_builder`), **OBF/OBZ import**
  (`POST /api/boards/import_obf`), and **create from template**
  (`POST /api/boards/create_from_template`). A Free user (limit 1) could blow
  past the cap through any of them — worst with the Board Builder, where one
  wizard run persists a whole linked tree (~5+ boards). All three now return
  **HTTP 422** when the user is already at their limit.
- A **Board Builder tree counts as ONE board** against the limit: its folder
  sub-boards are marked `settings["builder_child"]` and excluded from the count,
  so the wizard's own output never trips the read-only lock.
- Board-limit counting is centralized on `User#countable_board_count` /
  `User#at_board_limit?` (excludes predefined + builder-child boards). All gates
  — create, clone, menus, generated-board claim, and the three above — and the
  `can_create_boards` api_view flag now share this one definition, fixing prior
  count drift (`boards.count` vs filtered count).

### Changed — No-card reverse trial for Basic/Pro (issue #264)
- Starting a Basic/Pro trial **no longer requires a credit card** by default.
  Checkout uses `payment_method_collection: "if_required"` (no-card reverse
  trial): 14 days of full access, and when the trial ends without an upgrade
  the account drops to **Free in fallback mode** (#255) — never an unexpected
  charge, never stuck `past_due`.
- The trial subscription is created with
  `trial_settings.end_behavior.missing_payment_method = "cancel"`, so a
  no-card trial lapses by cleanly canceling → `customer.subscription.deleted`
  → existing Free downgrade. As a safety net, the webhook also downgrades to
  Free when a subscription update arrives as `unpaid` / `incomplete_expired`.
  `past_due` is left in Stripe dunning (real payers' failed renewals).
- The card-required arm is kept for the A/B experiment: force it per-request
  with `require_card=true` (PostHog-driven) or globally via
  `STRIPE_PAYMENT_METHOD_COLLECTION=always`. The `NOCC` /
  `bypass_payment_required` no-card path still wins over both.
- New analytics events so trial→paid is measurable: `trial_started` (on
  checkout), `trial_will_end` (Stripe pre-end webhook), and
  `subscription_started` (on the trial→paid conversion).

### Added — Board Builder wizard endpoint
- New `POST /api/v1/board_builder` builds a complete, linked board set for a
  communicator from a starter **template** plus a few **interest words**, in
  one round-trip, and `GET /api/v1/board_builder/templates` serves the picker
  catalog. Standalone feature (separate from MySpeak onboarding); the React
  page ships in the frontend.
- **Interest routing:** each interest is placed into a matching category folder
  the chosen template has (`apple` → Food, `dinosaurs` → Play); anything with
  no match lands in a single **"My Favorites"** folder, deduped, so nothing the
  user typed is dropped. Interests are normalized, capped at 12, and saved to
  the communicator so the wizard can be re-run.
- Built on the deterministic `Boards::BoardTreeBuilder` (the linked-set
  persistence half). No schema changes. See `.claude-notes/board-builder.md`.

### Added — Mailchimp Customer Journey triggers
- The backend can now enrol a contact into a **Mailchimp Customer Journey**
  via its API-trigger step, so events in the app send real, on-brand emails
  designed in the Mailchimp UI (`MailchimpService#trigger_journey`). This
  reuses the existing `MailchimpMarketing` gem — no new dependency.
- New `MailchimpEventJob` event type `"journey"` (takes `journey_key`).
  The first wired journey is **`welcome`**, enqueued on signup alongside the
  existing welcome email.
- Journey IDs are resolved per-environment from ENV
  (`MAILCHIMP_JOURNEY_<KEY>_ID` / `_STEP`) via `MailchimpClient.journey`, so
  nothing is hardcoded. Triggers fire in production only; staging/dev stay off
  unless `MAILCHIMP_JOURNEYS_ENABLED=true`, so real users are never emailed
  from non-prod.
### Added — Communicator fallback mode on downgrade (#255)
- A paid account dropping to Free now **retains** its over-limit communicators
  instead of stranding them: boards, MySpeak/profile, and the public page all
  stay intact. The communicators beyond the Free slot limit enter "fallback
  mode" — private passcode sign-in is blocked, but the public MySpeak page
  stays open and read-only, so a nonspeaking child is never cut off mid-use.
- Sign-in attempts on a fallback communicator return HTTP 403
  `communicator_in_fallback` with a `redirect_url` to the public page (the
  frontend redirect lands in itty-bitty-frontend#275). `fallback_mode` is
  exposed on the communicator API so the client can tell "in fallback" from
  "doesn't exist."
- Re-upgrading to Basic/Pro **automatically restores** sign-in, most-recently-
  active communicators first; any still over the new plan's limit stay in
  fallback. No manual re-claim. New Free signups remain capped at 1 communicator
  and are never flagged — fallback only ever results from a downgrade.

### Changed — Reprice AI feature credit costs
- Adjusted per-feature credit costs in `CreditService::FEATURE_COSTS`:
  `image_edit` 3 → 5, `image_generation` 5 → 3, `screenshot_import` 5 → 3,
  `scenario_create` 10 → 5, and `menu_create` 10 → 5. (`word_suggestion`,
  `board_format`, and `image_variation` are unchanged.)
- Aligned the credit specs (`credit_service_spec`, `credit_enforcement_spec`,
  `board_images_rate_limit_spec`) with the new costs — the repricing landed
  without updating them, which had turned `main` red.

### Changed — Drop the no-CC `basic_trial` soft trial (Option A)
- Every new signup now starts on **Free** (5 credits, Free-tier limits)
  instead of the 14-day no-credit-card `basic_trial`. The credit-card
  Stripe trial is unchanged. This closes the loophole where a signup could
  stack ~28 days of premium-level access (no-CC trial + CC Stripe trial)
  before the first charge.
- Removed the `before_create :set_soft_trial_plan` callback (replaced with
  `setup_new_user_free_plan`, which applies Free limits on create) and the
  login-time re-apply in `API::V1::AuthsController#create`.
- Existing `basic_trial` users are migrated to Free via the one-off
  `bin/rails plans:migrate_basic_trial_to_free` task (run on production
  after deploy). The remaining `basic_trial` plumbing
  (`CreditService`, `setup_limits`, `RefreshFreeTierCreditsJob`,
  `DowngradeSoftTrialJob`) is kept as a harmless fallback.

### Changed — Board create accepts topic + word_list together (#246)
- `POST /api/boards` now accepts a situation (`topic`/`prompt`) and seed
  words (`word_list`) in the same request. The redesigned `/boards/new`
  merges "Create from Scratch" and "Create from Scenario" into one
  "Build a board" form; the `default` and `scenario` creation types now
  share a single code path in `API::BoardsController#create`.
- `word_count` is clamped server-side to `1..50` (accepts either
  `wordCount` or `word_count`), so an oversized client value can't drive
  a huge AI prompt.
- `age_range` (`ageRange`/`age_range`) is optional on both paths —
  `GenerateBoardJob` falls back to its own default when blank.
- `GenerateBoardJob`'s `default`/`scenario` strategy now combines the
  seed `word_list` with topic-generated words (deduped). A board with
  seed words but no topic just keeps the seed words.
- Affected files: `app/controllers/api/boards_controller.rb`,
  `app/sidekiq/generate_board_job.rb`.

### Changed — Background-queue all user-lifecycle emails (#207, phase 2)
- Every inline `deliver_now` in request and lifecycle paths is now
  `deliver_later`. Welcome, plan-change, team invitation, claim-link,
  setup, confirm-email-update, message notification, and admin
  feedback emails all enqueue to Sidekiq instead of blocking the
  request thread on SMTP.
- Affected files: `app/models/user.rb` (17 sites),
  `app/controllers/api/users_controller.rb` (2 sites),
  `app/models/message.rb`, `app/models/feedback_item.rb`,
  `app/models/child_account.rb`. `DiskSpaceAlertJob` still uses
  `deliver_now` — it already runs inside Sidekiq.
- Closes the last hot-path SMTP risk identified in the 2026-05-30
  outage (#207). Pairs with PR #208 (SMTP timeouts, OpenAI timeouts,
  puma cluster mode).
- User-visible: faster HTTP responses on signup, plan change, team
  invites, email-change confirmation. Email arrival time unchanged
  (Gmail-side delivery dominates).
- Added `spec/lib/no_inline_mailer_delivery_spec.rb` as a regression
  guard so a new `deliver_now` outside `app/sidekiq/` fails CI.

### Changed — OBF/OBZ import: opt-in for image binaries, private-by-default (#239)
- `POST /api/boards/import_obf` no longer downloads or stores image
  binaries from imported `.obz` / `.obf` files by default. Board
  structure imports as before; tiles render with their label and the
  user's existing matching images, but bundled symbol PNGs are not
  pulled into S3 unless the client opts in.
- Two new params:
  - `include_images` (bool, default `false`) — when `true`, the importer
    calls `Down.download` per OBF image entry and creates Docs.
  - `image_license_acknowledged` (bool, default `false`) — required to
    be `true` when `include_images=true`. Otherwise the request returns
    **HTTP 400 `image_license_required`**.
- Every `Image` row created via OBF/OBZ import is now `is_private: true`,
  unconditionally. They never enter the `public_img` scope or other
  users' search results. An admin can flip individual images public later.
- `BoardGroup.settings["imported_from_obf"]` now records the audit trail
  per import: `include_images`, `license_acknowledged`,
  `acknowledged_by_user_id`, `acknowledged_at`, `imported_by_user_id`,
  and the OBF root board's `license` block (if any).
- **Why:** previously, importing a CoughDrop / TouchChat `.obz` with
  proprietary symbol assets (e.g. SymbolStix) would land those PNGs in
  S3 with `is_private=false`, exposing licensed artwork to every user
  via `Image.searchable_images_for`.
- **Frontend impact:** existing upload modal continues to succeed
  without changes, but imports will be structure-only until the
  frontend adds an "Import images" + "I have permission" pair of
  checkboxes that send the new params.
- **Fixed alongside:** `GET /api/boards` (user's own listing) used to
  silently drop OBF-imported boards via `where(obf_id: nil)`, so
  `board_count` and the visible list disagreed (e.g. 6 vs 4).
  The filter belongs on cross-user discovery scopes
  (`Board.searchable`, `Board.public_boards`), not on a user's own
  index. Removed there; kept on the discovery scopes.
### Changed — Owners can archive active communicators (issue #237)
- `ChildAccount#archive!` now allows archiving owner-controlled active
  communicators in addition to sandboxes. Loaner is still excluded —
  callers get an `ArgumentError` pointing at `end_loan` / `reclaim!`.
- Archive stamps `settings["archive_reason"]` and
  `settings["archived_status"]` so support has an audit trail and
  `unarchive!` can restore the original status cleanly.
- `ChildAccount#unarchive!` re-checks the owner's slot limit when
  restoring a previously-active record (archive frees the slot via the
  default scope; the owner may have filled it). Raises
  `ChildAccount::SlotFull` when at-cap.
- `POST /api/child_accounts/:id/archive` now returns 200 for an active
  owner, 422 (`End the loan first via end_loan.`) for a loaner, and
  401 for non-owners. `POST /:id/unarchive` returns 422 with the slot
  message when the owner is at-cap.
- Frontend `LoanerControls.tsx` work is tracked separately in
  `rally25rs/itty-bitty-frontend`.

### Changed — Pro plan now includes 5 Communicators (was 3)
- `User::PRO_PLAN_LIMITS["paid_communicator_limit"]` default bumped
  from `3` → `5` in `app/models/user.rb`. Same `PRO_PAID_COMMUNICATOR_LIMIT`
  env var; if it's set in prod it now needs to be `5` (or unset to take
  the new default).
- Updated the slot-math comment block in
  `app/helpers/permissions/communicator_limits.rb` and the test in
  `spec/models/user_plan_limits_spec.rb`.
- `welcome_pro_email.html.erb` fallback and `pro_setup_email`
  locale string both updated to "5 Communicator Accounts".
- **Backfill:** new `rake plans:bump_pro_to_five_communicators` task in
  `lib/tasks/plans.rake`. Bumps any current Pro / `pro_yearly` /
  `partner_pro` user whose `paid_communicator_limit` is 3 (or missing)
  up to 5. Skips anyone already above 3 so admin-tuned values aren't
  clobbered. Run with `DRY_RUN=true` first.
- Decision rationale in `marketing/pricing-structure.md` (REVISED
  2026-05-31 entry).

### Fixed — Subscription lifecycle bugs (#199)
- `paid_plan?` now considers `plan_status`: a user with
  `plan_type=basic` + `plan_status=canceled` (e.g. a missed
  `subscription.deleted` webhook) no longer passes paid gates.
  Returns `false` for nil plan_type instead of raising.
- `set_soft_trial_plan` moved from `before_save` to `before_create` and
  guards on `paid_plan_type`. Users who deliberately downgraded to free
  or picked a paid tier at signup are no longer bounced back to
  `basic_trial` on subsequent saves within the 14-day window.
- `invoice.payment_failed` Stripe webhook is now handled — flips
  `plan_status` to `past_due`. Does not downgrade; Stripe dunning still
  drives the eventual `subscription.deleted`.
- `handle_subscription_upsert` no longer silently downgrades paid users
  to `free` when a Stripe Price is missing `plan_type` metadata; it
  preserves the user's existing plan_type and logs a warning.
- `handle_invoice_payment_succeeded` reads the new Stripe
  `invoice.parent.subscription_details.subscription` path in addition
  to the deprecated `invoice.subscription` field.
- `API::BillingController#update_subscription` no longer calls a
  nonexistent `setup_limits_for_plan` method.
### Changed — Harden production puma against silent outbound-call wedges (#207)
- **Puma cluster mode in production.** `config/puma.rb` now sets `workers 2`
  (overridable via `WEB_CONCURRENCY`), `worker_timeout 30`, and
  `preload_app!` for production. A worker that wedges no longer takes the
  whole site down — the other worker keeps serving at 50% capacity.
- **SMTP timeouts.** `config/environments/production.rb` `smtp_settings`
  now sets `open_timeout: 10` and `read_timeout: 20`. Previously a stalled
  Gmail SMTP session could hang a puma thread for the Net::SMTP default
  (much longer); on 2026-05-30 this contributed to a 38-minute outage where
  all 8 single-mode threads silently wedged after a deploy.
- **OpenAI request_timeout.** `OpenAiClient::OPENAI_REQUEST_TIMEOUT_SECONDS`
  (defaults to 60s, overridable via `OPENAI_REQUEST_TIMEOUT`) is now passed
  to every `OpenAI::Client.new` — the central wrapper and the nine direct
  call sites in `app/services/*` and `app/controllers/api/scenarios_controller.rb`.
- No user-facing behavior change; reliability/SLO improvement only.
- Net effect: a future hang in SMTP or OpenAI raises an exception after the
  cap instead of holding a thread; with cluster mode, even a deadlock that
  the timeouts don't catch only halves capacity instead of taking the site
  fully offline.

### Changed — MySpeak starter-board seed populates tiles + tags `myspeak` (#204)
- `db/seeds/myspeak_starter_boards.rb` now creates **5** starter boards
  (`myspeak-basics`, `myspeak-feelings`, `myspeak-social`,
  `myspeak-food`, `myspeak-school`), tags each with `myspeak` so they
  appear in `Board.myspeak_public_boards`, and seeds **6 starter tiles**
  per board via `Board#find_or_create_images_from_word_list`.
- Net effect: the MySpeak onboarding picker
  (`GET /api/public_boards?myspeak=true`) renders 5 cards with real
  tile previews instead of one empty card.
- Idempotent: per-board tile add is gated by an existing-label check,
  so re-running the seed will not duplicate `board_images`.
- Run after deploy: `bin/rails runner db/seeds/myspeak_starter_boards.rb`.
  Adding new tiles enqueues `GenerateImagesJob` for any image without an
  existing display doc — let Sidekiq drain before verifying the picker.

### Added — `has_boards` flag on `User#api_view`
- `User#api_view` now returns `has_boards: boolean` alongside
  `board_count`. Derived from the already-computed `board_count`
  (zero extra queries) so the new free-tier dashboard
  (`itty-bitty-frontend` PR #183) can branch on an explicit boolean
  instead of `(board_count ?? 0) > 0`. No behavior change for
  existing clients — additive field only.

### Added — Free = 1 MySpeak ID limit (#143)
- Free users are now capped at **one MySpeak ID** (Profile). Basic/Pro
  and admins remain unlimited. Trial users (`basic_trial`, Stripe
  `trialing`) are treated as paid by `User#paid_plan?` and the gate
  doesn't trigger.
- "MySpeak ID" counts a Profile attached to the user directly *or* to
  one of their `communicator_accounts`.
- `POST /api/profiles` returns **HTTP 403** with
  `{ error: "myspeak_id_limit_reached", message, limit, count }` when a
  Free user is already at the cap.
- Limit env-tunable via `FREE_MYSPEAK_ID_LIMIT` (default `1`).
- New helpers on `User`: `#myspeak_id_limit`, `#myspeak_id_count`,
  `#can_create_myspeak_id?`.

### Changed — CommunicationAccountMailer per-recipient i18n (#175)
- `CommunicationAccountMailer` now extends `BaseMailer` (was
  `ApplicationMailer`).
- `setup_email` and `claim_link_email` wrap `mail(...)` in
  `with_user_locale(@account.owner)` and resolve subjects + bodies through
  `I18n.t`. Locale keys under `communication_account_mailer:` in
  `config/locales/mailer.{en,es}.yml`.
- Recipient is the `ChildAccount.email` (or the parent email for the
  claim flow), not a `User` — so the **owner's** locale is used, with a
  safe fallback to `:en` when the account has no owner.
- Bundled `claim_link_email` along with the explicitly-scoped
  `setup_email` since they share the class — leaving one English would
  defeat the goal of making the class locale-aware.

### Changed — BaseMailer team_invitation_email per-recipient i18n (#174)
- `BaseMailer#team_invitation_email` now wraps `mail(...)` in
  `with_user_locale(@invitee)` and resolves subject + body through
  `I18n.t`. Locale keys under `base_mailer:` in
  `config/locales/mailer.{en,es}.yml`. Invitees whose `i18n_locale` is
  `:es` now receive team invitations in Spanish.
- Deleted the orphan template
  `app/views/base_mailer/invite_new_user_to_team_email.html.erb` —
  no mailer action referenced it anywhere in the codebase.

### Changed — PartnerMailer per-recipient i18n (#173)
- `PartnerMailer` now extends `BaseMailer` (was `ApplicationMailer`).
- `PartnerMailer#welcome_email` wraps `mail(...)` in
  `with_user_locale(@user)` and resolves subject + body through `I18n.t`.
- English and Spanish keys under `partner_mailer:` in
  `config/locales/mailer.{en,es}.yml`.
- Known limitation: `@start_date` / `@end_date` are still formatted in
  English (`strftime("%B %d, %Y")`) and interpolated into the dates
  string. Proper date localization would need `I18n.l` and `:date.formats`
  locale data, which isn't currently set up project-wide. Tracked as
  a follow-up.

### Changed — SetupMailer per-recipient i18n (#172)
- `SetupMailer#myspeak_setup_email`, `vendor_setup_email`, `pro_setup_email`,
  and `basic_setup_email` now wrap `mail(...)` in `with_user_locale(@user)`
  and resolve subject + body through `I18n.t`. English and Spanish keys live
  under `setup_mailer:` in `config/locales/mailer.{en,es}.yml`. Free users
  whose `i18n_locale` is `:es` now receive setup emails in Spanish.
- Vendor setup template now reads `@user.name` instead of the undefined
  `@vendor.name`. The previous reference would have raised `NoMethodError`
  whenever the vendor email actually rendered (the mailer action only ever
  assigned `@user`); the error was masked by the same `rescue` that masked
  #176.

### Fixed — SetupMailer free/SLP setup email actions (#176)
- `User#send_free_setup_email` was calling a non-existent
  `SetupMailer#free_setup_email` action with an empty template, swallowing
  a `NoMethodError` in a `rescue` and never delivering the email. It now
  delivers `UserMailer#welcome_free_email` (already i18n'd, free-tier
  appropriate). The admin "send setup email" action on
  `/api/admin/users/:id/send_setup_email` now works for Free users.
- Deleted the empty `setup_mailer/free_setup_email.html.erb` and
  `setup_mailer/slp_setup_email.html.erb` templates. The SLP template had
  no callers anywhere in the codebase.

### Changed — AI word suggestions respect `board.language`
- `GET /api/boards/words` and `GET /api/boards/:id/additional_words` now
  source the language for AI output as `params[:language] || board.language ||
  current_user.i18n_locale`. A board with `language: "es"` returns Spanish
  suggestions even when the requesting user's UI is in English. The new
  `params[:language]` query param lets the caller override the board's
  language for one-off requests.
- `POST /api/scenarios/suggestion` (the scenario description generator)
  now honors `params[:language]`, falling back to the requesting user's
  locale. Closes the last gap in #118 — the scenario suggestion path
  previously built its own English-only prompt that ignored language.
- Threading also reaches the social-story path (`OpenAiClient` and
  `Board#get_social_story_word_suggestions`), which previously had no
  language-aware prompt.

### Added — Multilingual backend content (i18n Phase 1)
- **AI generation now respects the user's language.** Word suggestions, board
  generation, and scenario word lists previously always came back in English.
  The AI word-suggestion paths (`GET /api/boards/words`,
  `POST /api/boards/:id/additional_words`, `GET /api/scenarios/get_words`, and
  the async board/scenario generators) now thread the requesting user's
  language through to OpenAI, which is instructed to "Respond in <language>".
  English users see byte-identical output.
- **New boards default to the creator's language.** `POST /api/boards` now sets
  `board.language` from the creator's language setting when no explicit
  `language` param is sent (an explicit param still wins).
- **Per-language TTS audio.** The audio pipeline previously wrote
  `_<lang>`-suffixed files but synthesized the *English* label with
  *English-only* Polly voices. It now synthesizes the translated label and
  picks language-appropriate voices (`VoiceService.voices_for_language`).
  `TranslateImageJob` chains a `CreateAllAudioJob` so localized audio is
  generated once a translation lands.

### Fixed — Translated tile labels were silently ignored
- `BoardImage#set_labels` looked up the `language_settings` jsonb with symbol
  keys, but the column stores string keys — so translated labels were never
  read and tiles always fell back to English. Now uses string keys.

### Added — B&W and QR options for board PDF downloads

- `GET /api/boards/:id/pdf` now accepts `bw=1` for a copier-friendly black-and-white render (no tile backgrounds, grayscale images, black borders) and `qr=0` to suppress the QR code in the header. Defaults preserve existing behavior: color render with QR included. Variants are streamed but not stored on the board's cached `pdf_file` attachment, so the default PDF stays canonical. B&W downloads are named `<slug>-board-bw.pdf` to disambiguate.

### Fixed — Team owner can't be removed or demoted by other team members

- After the SLP→parent claim hand-off, the parent (new owner) is protected on the communicator's team. An SLP supervisor — or any non-owner team member — can no longer remove the parent owner via `DELETE /api/teams/:id/remove_member`, demote the owner via the invite endpoint, or self-promote themselves to admin. Attempts return HTTP 403 with structured errors (`cannot_remove_owner`, `cannot_change_owner_role`, `cannot_self_promote`). The owner can still remove themselves; system admins retain an escape hatch.
- Team `show`/`index` `api_view` now exposes `account_owner_ids` and per-member `is_account_owner` so the frontend can hide destructive controls on the owner row.

### Changed — Downgraded users keep their boards (read-only, never deleted)
- When a paid user (Basic/Pro) cancels and lands back on Free, their existing boards are no longer all fully editable. Boards beyond the Free limit (1) become **read-only**: they still open, cells still tap, audio still plays — so a non-speaking user's communication never breaks — but content-editing (renaming, layout changes, image swaps, audio uploads) is blocked behind an upgrade prompt. Previously, a Pro user with dozens of boards who cancelled kept full edit access to every one of them forever; only *creating* a new board was blocked.
- Users pick which single board keeps full edit access via `PATCH /api/boards/:id/make_editable`. On downgrade the backend pins a sensible default (favorite or most-recent) so they're never fully locked out before they choose.
- Locked content-editing endpoints return HTTP 403 with `error: "board_locked"`. Reads, audio playback, and board deletion are never gated.
### Fixed — Menu board display image saved at full size

- A menu board's `display_image_url` was set to the 288×288 tile variant (`Doc#tile_url`) of the uploaded menu photo, so the menu looked blurry whenever it was shown at any meaningful size. It now stores the full-resolution image (`Doc#display_url`) — a menu has fine print and must stay legible on a full screen. Applies to both menu board creation and re-run.

### Added — `ai_credits` in admin user views

- `User#admin_api_view` and `User#admin_index_view` now include an `ai_credits` object (`CreditService.balance`: `plan`, `topup`, `total`, `reset_at`), so the admin user pages can display each user's AI credit balance.

### Changed — Menu boards are built from the image with AI vision

- Creating a "menu" board now sends the uploaded menu photo straight to an AI vision model (`MenuVisionService`, OpenAI Responses API) to extract the food and drink items. Previously the React app ran Tesseract.js OCR in the browser and sent the raw text; OCR on real-world menu photos (glare, angled shots, multi-column layouts) was unreliable, and the backend then stripped digits, punctuation, and line breaks before parsing — erasing the item boundaries the model needed.
- The menu form no longer runs in-browser OCR; it just uploads the image. The dead OCR text-parsing path (`OpenAiClient#clarify_image_description` / `#describe_menu` / `#strip_image_description`, `ImageHelper#clarify_image_description`, `Menu#describe_menu`) has been removed.
- New optional env var `MENU_VISION_MODEL` (default `gpt-4.1-mini`) selects the vision model.

### Fixed — Duplicate `SaveAudioJob` enqueued per board image

- `Board#add_image` enqueued `SaveAudioJob` twice for every image added to a board: once explicitly, and once via `BoardImage`'s `after_create :create_voice_audio_after_create` callback. Both jobs did the identical Polly audio lookup/creation and board-image update — wasted work and a mild race creating the same audio file concurrently. `add_image` now leaves audio generation entirely to the callback.

### Changed — MySpeak is now a free feature, the $3 MySpeak tier is retired

- The MySpeak ID (a demo communicator with a public profile, QR code, and emergency info) is now included on the **Free** plan. `FREE_DEMO_COMMUNICATOR_LIMIT` default is now `1` (was `0`), so every Free user can create one MySpeak demo communicator. That demo communicator is capped at one board (`ChildAccount::FREE_DEMO_BOARD_LIMIT`); Pro demo accounts keep the 3-board default.
- The `myspeak` / `myspeak_yearly` plan tier has been removed: dropped from `setup_limits`, Stripe checkout (`PLAN_PRICE_IDS`), `normalize_plan_key`, `BillingController` accepted plans, `CreditService::PLAN_MONTHLY_CREDITS`, `RefreshFreeTierCreditsJob`, and the Mailchimp tagging job. `User#myspeak?` is replaced by `User#has_myspeak_feature?` (true when the user has a demo-communicator slot).
- Run `bin/rails plans:migrate_myspeak_to_free` to move any existing `myspeak` / `myspeak_yearly` users onto the free plan (idempotent). Effective plan limits come from `config/application.yml` + host config, so `FREE_DEMO_COMMUNICATOR_LIMIT` must also be set there for the change to take effect outside CI.

### Fixed — Authenticated SMTP for production mail delivery

- Production mail now authenticates over SMTP when `SMTP_USERNAME`/`SMTP_PASSWORD` are set, instead of relying solely on `smtp-relay.gmail.com`'s IP-allowlist auth. The `mail:test` diagnostic showed production failing with `OpenSSL::SSL::SSLError: SSL_read: unexpected eof while reading` — the relay dropping unauthenticated connections from a non-allowlisted server IP, so every welcome email and team invite was silently failing.
- With credentials present, delivery uses authenticated `smtp.gmail.com` (IP-independent). With no credentials present, behavior is unchanged (the IP relay). `SMTP_ADDRESS` overrides the SMTP host — set it to `smtp-relay.gmail.com` to use the relay endpoint _with_ authentication.

### Fixed — Mail delivery diagnostics & production transport config

- Restored the explicit `config.action_mailer.delivery_method = :smtp` in `config/environments/production.rb` — it was dropped when the SMTP block was swapped to `smtp-relay.gmail.com`, leaving production reliant on the framework default. Documented the relay's IP-allowlist failure mode (delivery fails silently if the EC2/Hatchbox outbound IP is not registered in the Google Workspace SMTP relay console).
- Added `bin/rails 'mail:test[you@example.com]'`: prints the resolved ActionMailer config and attempts a real delivery, surfacing the actual SMTP error (credential failure, unallowlisted IP, connection refused) instead of letting it be swallowed by the `rescue` blocks in `User#send_welcome_email` and friends.

### Fixed — Demo account plan limits & legacy monthly-limit cleanup

- `MYSPEAK_DEMO_COMMUNICATOR_LIMIT` default changed from 1 to 0 and `PRO_DEMO_COMMUNICATOR_LIMIT` default from 10 to 1, so demo communicator accounts are granted to Pro only (1 account), matching the intended pricing model. `FREE` and `BASIC` were already 0.
- Removed the dead `API::ApplicationController#check_monthly_limit` helper — a legacy Redis-counter rate limit with no callers. AI features gate on `check_credits!` / `CreditService`. `MonthlyFeatureLimiter` and `User#monthly_limit_for` are intentionally kept: they still back the `can_use_ai?` / `ai_limit_reached?` path, whose cleanup is tracked separately.

### Changed — MySpeak quick-comm board now works on the Free tier

- `ChildAccount#favorite_boards` was plan-gated (`paid_plan?` / vendor), so a Free-tier user's MySpeak page showed an empty quick-comm board. Removed the gate — favorited boards now populate the MySpeak public page and `go_to_boards` for all tiers, including Free. Part of the MySpeak-goes-free rollout (itty_bitty_boards#142). MySpeak ID, profile, QR code, and safety/medical cards had no plan gate to begin with.

### Added — `core_boards:seed` rake task for public "Core + X" boards

- New `bin/rails core_boards:seed` task creates public, predefined boards modeled on the "Core + Lunch" board: an 8-column × 5-row, 40-tile grid with 20 fixed core words on the left half (black-bordered) and 20 topic words on the right half (borderless). Tiles are colored by part of speech via the modified Fitzgerald key.
- Topic words come from a curated list when the topic is known (`Lunch`, `Playground`, `Swimming`); otherwise they are AI-generated via `Board#get_words_for_scenario`. Controlled by env vars: `TOPICS="Playground,Swimming"`, `COUNT=n`, `AGE_RANGE`, and `DRY_RUN=1`.
- Reuses existing image artwork only — no image generation is queued, so the task incurs no image API cost. Words without artwork render as placeholders. Idempotent: boards that already have tiles are skipped.

### Added — Disable Audit Logging for communicator accounts

- Communicator (child) accounts now support a `settings["disable_audit_logging"]` flag, matching the existing flag on user accounts. When set, that communicator's word clicks are not recorded as `WordEvent` records. Toggled from the communicator account form.
- `API::Audits#word_click` and `#public_word_click` now skip `WordEvent.create` when the acting user or the communicator account has audit logging disabled (new `User#audit_logging_disabled?` / `ChildAccount#audit_logging_disabled?` helpers). Previously the user-level flag was honored only by the frontend; it is now enforced server-side as well.

### Added — Range-aware communicator stats endpoint

- New `GET /api/word_events/stats?account_id=X&days=N` (`API::Audits#communicator_stats`) returns a single bundled, range-filtered stats payload for a communicator account's Stats tab: `range`, `summary` (total events, unique words, active days, most active day, average per active day, top word), `heat_map`, `most_clicked_words`, `part_of_speech_breakdown`, and the word `events` list (capped at 500). `days` accepts 30/60/90/180/365 and falls back to 180 for any other value. Previously the Stats tab pulled an all-time `heat_map` and a fixed 7-day `most_clicked_words` from `child_accounts#show`, so its day-range selector had no effect on the data.
- `WordEventsHelper#heat_map` now takes an optional range argument; added `WordEventsHelper#word_events_summary(range)` and `#part_of_speech_breakdown(range)`. Existing no-arg `heat_map` callers are unchanged.

### Added — Communication Prompt Mode for caregivers

- New `CoachingPromptSet` model + `API::CoachingPrompts` controller (`GET/POST/PATCH/DELETE /api/coaching_prompts`). A caregiver opens a board in Caregiver Mode and the API returns a coaching prompt set with strategies + tappable example phrases. Curated SpeakAnyWay sets ship for Snack Time, Car Ride, Bedtime Story (matched against `Board#tags` / name tokens). For boards without a curated match, `CoachingPromptGenerator` calls OpenAI (`gpt-4o-mini`) once and caches the result on the board's `metadata` jsonb so the second visit costs nothing. Staging skips the paid call and returns the bundled fallback set, mirroring the existing OpenAI image staging stub.
- Users can create / edit / delete their own custom coaching sets via the same endpoint — owned sets are scoped by `user_id`. Editing SpeakAnyWay-shipped or another user's sets returns 403.
- New `users.settings["is_caregiver"]` flag — opt-in preference lives in the existing user settings jsonb (same pattern as `wait_to_speak`, `show_labels`, etc.). Flipped via the existing `POST /api/users/:id/update_settings` endpoint, exposed in the Settings page UI.
- Free for everyone — no `CreditService` gating. Cost is bounded by per-board caching of AI fallback generations.
- **Audio cache**: `GET /api/coaching_prompts/audio?text=...&voice=...&language=...` returns a stable mp3 URL for a coaching phrase + voice tuple. Backed by a new `CoachingPhraseAudio` model with an ActiveStorage attachment, keyed on `sha256(version|text|voice|language)`. First call synthesizes via the existing `VoiceService` (Polly / OpenAI) and uploads to S3; every subsequent caller for the same tuple — across the whole app — gets the same URL without hitting TTS. Race-safe via a unique-index `phrase_key` column. Skips synthesis in `Rails.env.test?` unless `ENV["ALLOW_COACHING_AUDIO_TTS"]` is set.

### Fixed — Pro users showing 0 AI credits ("granted and expired same day")

- `CreditService.grant_plan!` now clamps `period_end` to a minimum of
  `Time.current + 1.day` (`CreditService::MIN_GRANT_WINDOW`). A bad
  upstream value (stale `plan_expires_at`, `trial_end == 0`, etc.) was
  causing the new `plan_grant` row to land already-expired, and the
  hourly `ExpirePlanCreditsJob` would sweep it to 0 within the hour.
  Issue #110 patched the rake task; this patches the service so no
  caller can reintroduce it. A `Rails.logger.warn` fires on every clamp
  so we can find any upstream caller still writing bad dates.

### Changed — Free tier is now 5 AI credits/month (was 10)

- `PLAN_MONTHLY_CREDITS["free"]` lowered from 10 to 5. Applies to
  signup grants, the daily refresh job, and post-cancellation grants.

### Changed — Canceled/paused subscriptions keep 5 free credits (was 0)

- `customer.subscription.deleted` and `customer.subscription.paused`
  webhooks previously called `CreditService.expire_plan_credits!`,
  leaving the user at 0 until the next daily refresh. Now they call
  `CreditService.grant_plan!` with the free-tier allowance, so users
  land on free with 5 credits immediately. The prior balance is still
  expired (ledger trace preserved); top-ups are still untouched.

### Changed — Monthly credit refresh now covers non-Stripe paying users

- `RefreshFreeTierCreditsJob` (daily, 3am UTC) used to refresh only
  `free` and `basic_trial` users. It now also refreshes any user
  without a `stripe_subscription_id` — App Store / RevenueCat
  subscribers, admin/demo accounts on paid tiers — granting their
  actual plan_type's allowance (Pro = 1500, Basic = 400, etc.).
  Stripe-driven paying users continue to be refreshed by
  `invoice.payment_succeeded`. Class name unchanged for cron stability.

### Added — AI word suggestions adapt to the communicator

- Board generation now accepts an optional communicator profile — `age` / `age_band`,
  `aac_level` (`emerging` / `developing` / `proficient`), and `vocab_type` (`core` /
  `fringe` / `balanced`) — on the AI word-suggestion endpoints (`GET /api/boards/words`,
  `POST /api/boards/:id/additional_words`) and the scenario board create flow. For young
  or emerging communicators the prompt now leans on core vocabulary, verbs, and emotions
  instead of clinically literate adult nouns. All fields are optional; callers that send
  no profile get the same output as before. Normalization lives in the new
  `CommunicatorProfile` service object.

### Fixed — Private boards no longer viewable by anyone with the link

- `GET /api/boards/:id` (which backs the frontend `/pb/<slug>` route) is unauthenticated
  and previously rendered any board regardless of ownership or publish state — a
  logged-out visitor could view a private board with just its slug. It now returns a
  generic 404 unless the board is published, or the requester is the owner, an admin, or
  a member of a team the board is shared with (`Board#viewable_by?`).

### Changed — Staging no longer makes paid OpenAI image calls

- When `ENV["STAGING"] == "true"`, all OpenAI image operations (generation, variations, edits) are stubbed with the bundled `public/placeholder.jpeg` instead of hitting the paid API. The rest of the image pipeline (Doc creation, ActiveStorage attachment, board tiles, status transitions) runs normally, so staging can be exercised end-to-end without spending money. Production behavior is unchanged. Gated via the new `AppEnv.staging?` helper.

### Fixed — AI credits now actually grant on signup and refresh for free users

- **Signup grant.** New users land in `basic_trial` for 14 days (via `User#set_soft_trial_plan`) but the after-create flow never granted them any credits, so every AI call returned `402 insufficient_credits`. Added `User#grant_initial_plan_credits` (after_create) → `CreditService.ensure_initial_grant!(user)` which writes a `plan_grant` row sized to the tier (`basic_trial` = 400, matching Basic; `free` = 10; etc.) with `expires_at` of 14 days for trial users and 30 days for everyone else.
- **`basic_trial` plan_type was missing from `CreditService::PLAN_MONTHLY_CREDITS`** — it fell back to free (10 credits) instead of the intended Basic-equivalent (400). Fixed.
- **Soft-trial downgrade now grants free credits.** `DowngradeSoftTrialJob` (daily at 2am UTC) flips expired trial users to `free`; now also calls `CreditService.grant_plan!` for 10 credits with a 30-day expiry so they don't see balance=0 the moment they're downgraded.
- **Monthly refresh for non-subscription tiers.** New `RefreshFreeTierCreditsJob` runs daily at 3am UTC and re-grants the tier allowance to users on `free` / `basic_trial` whose `plan_credits_reset_at` has passed. Paid Stripe subscribers (MySpeak, Basic, Pro, Partner Pro) continue to be refreshed by `invoice.payment_succeeded`; the new job is just for users without a Stripe billing cycle.

### Added — Phase 4 of usage-based AI pricing (renewals + auto-grant)

- `invoice.payment_succeeded` webhook handler — fires on initial paid period and every renewal. Reads `monthly_credits` and `plan_type` from the subscription line's Price metadata (falls back to `CreditService::PLAN_MONTHLY_CREDITS`), then calls `CreditService.grant_plan!` with `period_end = subscription.current_period_end`. Idempotent on Stripe event id, so retried webhooks never double-credit.
- `customer.subscription.created` (status `trialing`) now grants trial credits with `period_end = subscription.trial_end`. Paid subscriptions still get their credits via the invoice path.
- `customer.subscription.deleted` / `.paused` now expire plan credits via `CreditService.expire_plan_credits!`. Top-up credits are preserved.
- `ExpirePlanCreditsJob` runs hourly as a backstop — zeroes out plan credits whose `plan_credits_reset_at` has passed and no webhook arrived to refresh them.
- **Fix:** `apply_free_plan` previously referenced `FREE_PLAN_LIMITS` unqualified in the controller, which raised `NameError` silently swallowed by the `rescue` — so cancellations never actually downgraded users. Now resolves `User::FREE_PLAN_LIMITS` correctly.

### Changed — Phase 3 of usage-based AI pricing (enforcement switched)

- **AI features now spend credits at request time.** The Redis monthly counter (`MonthlyFeatureLimiter`) is no longer in the AI hot path — `CreditService.spend!` is the source of truth.
- New API gating helper `check_credits!(feature_key:, feature_name:, amount: nil)` in `API::ApplicationController`. Admins bypass the check.
- AI endpoints now return **HTTP 402 `insufficient_credits`** with `{ feature, needed, balance, plan_credits, topup_credits, reset_at, topup_url }` when the balance is too low. HTTP 429 is reserved for true rate limiting and is no longer used by AI gating.
- All 10 AI controller callsites now charge weighted credits per their real feature (image_generation=5, image_edit=3, scenario_create=10, etc.) instead of a flat `ai_action=1`.
- Shadow-mode telemetry from Phase 1 has been removed. `check_monthly_limit` remains in the codebase as a generic Redis-counter helper but is no longer wired to AI endpoints.

### Added — Phase 2 of usage-based AI pricing

- `POST /api/stripe/checkout_sessions/topup` — creates a one-time Stripe Checkout Session for a credit pack (`pack_key`: `small` / `medium` / `large`, optional `quantity`).
- Stripe webhook now branches on `metadata.kind == "topup"` for `checkout.session.completed`. Top-up sessions call `CreditService.grant_topup!`, idempotent on the Stripe event id.
- Webhook falls back to expanding `line_items.data.price.metadata.credit_amount` when the session metadata is missing — keeps the system working even if the frontend was on an older build that didn't pass `credit_amount` through.
- New env vars: `STRIPE_PRICE_TOPUP_SMALL`, `STRIPE_PRICE_TOPUP_MEDIUM`, `STRIPE_PRICE_TOPUP_LARGE` (Stripe Price IDs for the three pack sizes).

### Added — Phase 1 of usage-based AI pricing

- AI credit ledger (`credit_transactions` table) — immutable record of every grant, spend, expire, and refund of AI credits.
- `users.plan_credits_balance`, `users.topup_credits_balance`, `users.plan_credits_reset_at` columns — denormalized balances and current-period end.
- `CreditService` — single entry point for credit operations (`spend!`, `grant_plan!`, `grant_topup!`, `expire_plan_credits!`, `refund!`, `shadow_spend`). Spends drain plan credits first, then top-up.
- `CreditService::FEATURE_COSTS` — weighted costs per AI feature (image generation = 5, scenario builder = 10, word suggestion = 1, etc.). Server-authoritative.
- `GET /api/me/credits` — returns `{ plan, topup, total, reset_at, plan_type }` for the current user.
- `GET /api/me/credit_transactions` — paginated transaction ledger for the current user.
- `bin/rails credits:backfill` — gives every existing user an initial plan-credit grant based on their `plan_type`. Idempotent.
- `bin/rails credits:recompute_balances` — rebuilds denormalized balances from the ledger.
- Shadow-mode telemetry — `check_monthly_limit` in the API base controller now also runs `CreditService.shadow_spend` and logs divergences between the Redis-counter decision and the credit-ledger decision. **No user-visible change yet** — the Redis limiter remains the source of truth in Phase 1.

### Coming next

- **Phase 5 (optional):** Stripe Meter-based overage billing.
