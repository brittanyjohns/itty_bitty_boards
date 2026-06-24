# Changelog

All notable user-facing changes to this project will be documented here.
The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added — AppSignal APM (per-request + host visibility)
- Added the `appsignal` gem and `config/appsignal.yml` to capture per-request
  latency (p95/p99), slow queries/N+1, host CPU/memory/disk, and Sidekiq queue
  latency — Phase 1 of the scaling roadmap (#391 / #390), so later sizing
  decisions are data-driven. Instruments both the Puma web process and the
  Sidekiq worker process automatically; **active in production/staging only**
  (no-op in dev/test). Requires `APPSIGNAL_PUSH_API_KEY` in Hatchbox for both
  apps, plus `APPSIGNAL_APP_ENV=staging` on staging so it reports as a distinct
  environment (both run `RAILS_ENV=production` on the shared box). `/up` health
  pings are excluded from metrics; secrets/PII are filtered from traces.

### Changed — Safety info (and its parent alert) is now behind the Emergency Info action
- The public MySpeak page (`GET /api/profiles/public/:slug`) is the everyday
  social surface and **no longer ships medical info or emergency contacts** —
  those keys (`allergies`, `medical_conditions`, `medications`,
  `other_conditions`, `other_conditions_notes`, `emergency_notes`,
  `emergency_contacts`, `ice_contact_*`) are withheld from the page payload.
  Only page-safe settings (`pronouns`, `device_notes`) plus a `has_safety_info`
  boolean come down on load.
- The sensitive data is revealed only by the new gated endpoint
  `POST /api/profiles/public/:slug/safety_view`, which is also the **single
  place that records the access and (throttled, ≤1 email/hour) alerts the
  parent**. Opening the page no longer logs a view or notifies anyone — only a
  deliberate "Emergency Info" open does. Every reveal is still recorded in
  `profile_views` for the audit trail; only the email is throttled. Parent-alert
  email copy updated from "safety page was viewed" to "emergency info was
  opened" (en + es). Issue #384 follow-up.
### Fixed — Communicator hand-off now updates the right team
- When a family claimed a loaned communicator, the new owner was sometimes added
  to the wrong team (the communicator's *own* team was left with only the
  previous owner). `ChildAccount#claim_by!` now resolves the communicator's own
  team deterministically instead of using `teams.first`, adds the new owner as
  **admin**, keeps the previous owner as **supervisor**, and **transfers team
  ownership** to the new owner so they can manage the team. Existing accounts can
  be repaired with `rake communicators:repair_handoff_teams` (dry-run by
  default).

### Changed — Lending a communicator is enforced as Pro-only
- The `lend` and `promote_to_loaner` endpoints now return **HTTP 403
  `pro_required`** for non-Pro callers (admins bypass), matching the frontend's
  existing Pro-only "Lend to a family" controls. Closes a gap where a Basic user
  — or a direct API call — could lend a communicator.

### Changed — New MySpeak communicators get an unguessable safety slug
- MySpeak onboarding (`POST /api/v1/onboarding/myspeak`) no longer creates a
  name-derived public slug. The safety profile now gets a random `s-xxxxxx`
  slug (via `Profile#ensure_slug`), so a child's public emergency page can't be
  found by guessing their name. The account's **username** stays readable. Any
  client-supplied `slug` is ignored — random is enforced server-side. Completes
  the random-slug work from the prior release for *new* signups (the "Pick your
  link" wizard step is being removed in the frontend).

### Fixed — Mailchimp journey triggers can't flood the Sidekiq dead set
- `MailchimpService#trigger_journey` resolves the gem's Customer Journeys
  accessor defensively (camelCase `customerJourneys`, falling back to snake_case
  only if a future gem adds it) and now **catches/​logs/​swallows a
  `NoMethodError`** instead of letting it crash `MailchimpEventJob`. Previously a
  gem-shape mismatch raised on every trigger, exhausted the job's retries, and
  piled hundreds of jobs into the Sidekiq dead set. `ApiError` 404-retry
  behavior is unchanged.

### Fixed — User settings hardening & cleanup
- The `PUT /api/users/:id/update_settings` endpoint now only persists a
  whitelist of real preference keys (voice, display toggles, board pointers,
  etc.) and requires the caller to be the account owner or an admin. Previously
  it wrote **every** request parameter into the settings blob (leaking Rails'
  `controller`/`action`/`id`/`format`) and performed no ownership check.
- Removed the dead `ai_monthly_limit` plan-limit setting and the unused
  monthly AI action-counter (`MonthlyFeatureLimiter`, `ai_limit_reached?`).
  AI has been gated by the credit ledger for a while; this setting was written
  but never read on the enforcement path.
- Added `rake settings:cleanup` (dry-run by default; `DRY_RUN=false` to apply,
  `USER_ID=N` to scope) to scrub the leaked junk keys and the dead
  `ai_monthly_limit` key from existing users' settings.

## [1.2.1] — 2026-06-23

### Added — Random, unguessable slugs for safety profiles
- A communicator's public safety page (`/my/<slug>`) now uses an unguessable
  random slug (`s-` + 6 unambiguous characters, e.g. `s-k8x2mf`) instead of a
  name-derived one, so a child's emergency page can't be found by guessing
  their name. Only safety profiles are affected — vendor/SLP/user pages keep
  readable slugs.
- Existing safety profiles migrate via `rake profiles:migrate_to_random_slugs`
  (dry-run by default; `DRY_RUN=false` to apply, `USER_ID=N` to scope), which
  preserves the old slug as `legacy_slug`. The public endpoint
  (`GET /api/profiles/public/:slug`) 301-redirects an old legacy slug to the
  current random slug, so printed cards, bookmarks, and shared links keep
  working.
- The migration enqueues `RegenerateSafetyCardsJob` per profile to rebuild the
  safety ID card + device tag (new QR code) and email the parent that fresh
  cards are ready to download. Random slugs are not user-editable.

### Added — Parents are alerted when their child's safety page is viewed (#384)
- When someone opens a public safety (MySpeak) profile page
  (`GET /api/profiles/public/:slug`), the parent now gets an email letting them
  know their child's emergency info was accessed, with the timestamp and an
  approximate (city-level) location of the viewer. Zero friction for the
  viewer — no login, no gate.
- Every public safety-page view is logged to a new `profile_views` table
  (IP + user agent + timestamp) so unexpected access patterns are visible.
- Alerts are **on by default** and throttled to **at most one per profile per
  hour** so a parent checking their own page isn't spammed. A parent can turn
  them off per-profile via `settings["view_alerts_enabled"] = false`
  (surfaced as `view_alerts_enabled` on the profile `api_view`), and the global
  `settings["disable_notifications"]` flag is also respected.
- Backend-only; no frontend changes required. All work (geolocation, throttle,
  email) runs in `RecordProfileViewJob` so the public emergency page is never
  slowed or broken by it. Email is the v1 channel; a push channel is stubbed in
  `Notifications::SafetyViewNotifier` for when device-token infra lands.
- Coarse IP→location uses the new `geocoder` gem (provider/key ENV-tunable:
  `GEOCODER_IP_LOOKUP`, `IPINFO_API_KEY`); location is simply omitted if the
  lookup is unconfigured or fails.

### Changed — Screenshot board import commits faster (deferred AAC categorization)
- Committing a board imported from a screenshot
  (`POST /api/board_screenshot_imports/:id/commit`) created a new `Image` for
  every tile label with no existing match. Each novel label triggered a
  **synchronous OpenAI call** inside the commit transaction (via
  `Image#ensure_defaults` → `AacWordCategorizer.categorize`), adding latency and
  cost to a user-facing action. `ensure_defaults` now honors the existing
  `skip_categorize` / `do_not_categorize?` flag: such images get sensible
  neutral defaults immediately (part_of_speech `default`, gray colors) and the
  real categorization is finished off-thread by the new `CategorizeImageJob`
  after commit, so tiles still get correct AAC colors/POS shortly after. Normal
  image creation (no `skip_categorize`) is unchanged. Specs added in
  `spec/services/board_from_screenshot_spec.rb` and
  `spec/sidekiq/categorize_image_job_spec.rb`.

### Fixed — Board Builder "Extended" no longer produces an over-full board
- An **Extended** Board Builder set built on a fuller Core 84 grid (e.g. one
  carrying the new Phrases layer with fewer reserved empty cells) could exceed
  the authored 7×12 (84-cell) grid, spilling tiles onto a stray extra row — the
  reported **86 tiles instead of 84**. The grid cap is now a hard guarantee:
  the grid math lives in one place (`Board#open_grid_cells`) and **every**
  top-level tile-adder honors it — the "My Favorites" catch-all in both
  `BuildBoardSetJob` and `SeededSetCloner`, plus the existing Phrases folder and
  quick-phrase strip — so a built set never overflows regardless of how little
  slack the seed leaves. Aliased interest categories ("Family & People",
  "Health & Body") now route into the cloned People/Body pages instead of
  spawning a spurious extra "My Favorites" folder. The early-stage quick-phrase
  strip also **dedupes against the home board** so it can't surface a phrase the
  home board already carries — e.g. "all done" is both an authored core word and
  a Transitions gestalt, which previously produced a duplicate "all done" tile.
  Regression coverage added in `spec/sidekiq/build_board_set_job_grid_spec.rb`.

### Fixed — "Make a Board From Screenshot" robustness
- A failed screenshot import now **refunds** the 3 credits charged at upload —
  previously a user whose AI analysis failed was out the credits with nothing to
  show. The refund returns credits to the exact plan/topup split they came from
  and is idempotent across Sidekiq retries.
- Editing detected cells via `PATCH /api/board_screenshot_imports/:id` no longer
  drops `row`/`col` changes (they weren't permitted) and no longer 500s when the
  request omits the `board_screenshot` key.
- Committing an import that isn't ready (still processing/failed) returns a clean
  **422 `import_not_ready`** instead of a raw 500.
- The preprocessed temp image is always cleaned up, even on failure (it was
  leaking into `tmp/` on every import).
- On **staging**, screenshot analysis now returns a deterministic placeholder
  grid instead of calling paid OpenAI vision — mirroring the existing
  image-generation placeholder, so QA doesn't incur API cost or burn credits.

### Fixed — Sandbox communicators no longer advertise a sign-in
- A **sandbox** (no-login demo) communicator owned by a paid or free-trial user
  was returning `can_sign_in: true` and a real `startup_url`
  (`/accounts/sign-in?username=…`) in its API payload — even though a sandbox
  has no passcode and cannot be signed into. `ChildAccount#can_sign_in?` now
  short-circuits to `false` for any sandbox (before the admin/plan checks), and
  `ChildAccount#startup_url` returns `nil` for a sandbox, so the contradiction
  no longer reaches the frontend. Active and loaner communicators are
  unchanged. Specs added in `spec/models/child_account_spec.rb`.

### Fixed — Board Builder fringe pages now show tile artwork
- A built board set's **main board** showed pictures on its tiles, but the
  **fringe/category pages** (Food, Feelings, Animals…) often rendered blank. The
  blank→art upgrade only ran on the root board; fringe pages cloned through a
  path with no upgrade. Every cloned fringe page now gets the same upgrade, so
  the whole set renders with images.
- Image resolution now picks the **curated "default" image** — the admin library
  image with the **most artwork attached** — when several images share a label,
  instead of grabbing the lowest-id (often blank) one.
- Existing built sets can be backfilled with the idempotent
  `rake board_builder:upgrade_tile_images` (dry-run by default; `DRY_RUN=false`
  to apply, `USER_ID=N` to scope to one owner).

### Fixed — Paid users' communicators stuck in sandbox mode (#359)
- A communicator created while a user was on the Free plan was forced into
  no-login **sandbox** mode, and upgrading to Basic/Pro never converted it — so
  paying users could be walled off with "Sign-in disabled for Sandbox
  Communicators". Upgrading to **Basic** (which grants no sandbox slots) now
  automatically promotes those leftover sandbox communicators to full **active**
  accounts (with sign-in), up to the plan's slot limit, most-recently-active
  first. **Pro** is left alone — it includes an intentional sandbox/demo slot.
- Existing affected users can be fixed with the idempotent
  `rake communicators:promote_paid_sandboxes` (dry-run by default; `DRY_RUN=false`
  to apply, `USER_ID=N` to scope to one user).

### Added — Gestalt language (GLP) support
- Communicators can now carry an optional **NLA stage** (`glp_stage`, 1–6),
  stored in `child_accounts.details` alongside the existing AAC profile fields
  (`aac_level`/`vocab_type`/`age_band`) — it measures something different, so it
  doesn't replace them. Set it via the existing communicator-update `details`
  param; it's exposed on the communicator `api_view`. Drives gestalt-aware AI
  word-suggestion prompts (whole phrases at early stages → full sentences at
  advanced stages) via `CommunicatorProfile`.
- Six predefined **GLP board templates** of whole-phrase tiles — Greetings &
  Social, Requests & Wants, Protests & Boundaries, Comments & Observations,
  Feelings & Emotions, Transitions & Routines — available on all plans. Seed
  with `bin/rails glp_templates:seed` (idempotent). They surface in
  `GET /api/v1/board_builder/templates` (with `glp_templates` + a stage-aware
  `recommended_template`), and `?template_type=glp` narrows the picker to GLP
  only.
- **Script Collector** support on `POST /api/boards/:id/add_image`: a tile can
  be marked `part_of_speech: "phrase"` (a whole-phrase gestalt tile, no longer
  re-categorized as a single word) and carry free-form `gestalt_source` /
  `utterance_function` metadata, stored on `board_images.data`.

### Fixed — Board Builder: category folder tiles render blank
- Category folder tiles (Animals, People, Feelings, Food…) on a built set now
  show a curated symbol by default instead of a blank tile. Resolution grabbed
  the first image matching the label, which was often a blank, art-less image
  the OBF seed created for that label — even though a curated image with art
  existed. New `Boards::ImageResolver` prefers an art-bearing image (matching
  the label **case-insensitively**, since folder labels are capitalized while
  library art is often lowercase), used by the cloner, blueprint assembler, and
  `BuildBoardSetJob`. The authored/curated folder name ("Animals") is preserved
  as the tile text even when the art image is stored lowercase ("animals").

### Fixed — Board Builder: extra "85th tile" and dead folder tiles on built sets
- A built robust set (e.g. Extended / Core 84) no longer overflows its authored
  grid. The build added one folder tile per fringe page via `Board#add_image`,
  which fills the authored grid's open cells and then spills onto a stray extra
  row — so a 7×12 (84-cell) Core 84 came out with 85+ tiles. The build now caps
  the top-level folder tiles it adds to the open cells on the authored grid and
  folds the remainder into a single "My Favorites" page (nothing the child
  selected is dropped).
- Authored folders are no longer left **dead** (unlinked). The hybrid path used
  to *exclude* "unplanned" seed pages from the clone while leaving their folder
  tiles on the root, so **More / School / Time / Describe** opened nothing when
  tapped. The build now clones the authored core set intact — every folder links
  to a real board.

### Added — Board Builder: complexity levels, AI fringe pages, hybrid build (Phase 2)
- **Complexity levels** replace raw template keys in the wizard: Starter (4-6
  fringe pages), Standard (8-10), Extended (10-15). Legacy `template` param
  still works; new `level` param is the intended path forward.
- `GET /api/v1/board_builder/templates` now returns a `levels` array with key,
  name, description, and fringe_page_range for each level, plus a
  `recommended_level` based on the communicator's stored profile.
- **StructurePlanner** decides which fringe pages to include per level, resolving
  each to one of three sources: `:seed_set` (already in the core clone),
  `:prebuilt` (standalone OBF template), or `:ai_generated` (OpenAI).
- **11 standalone fringe page OBF templates** seeded via
  `bin/rails fringe_templates:seed`: Animals, Art & Craft, Bathroom, Clothing,
  Home, Music, Nature & Outdoors, Social, Sports, Technology, Transportation.
- **AiPageGenerator** service generates niche interest pages via OpenAI when no
  pre-built content exists (e.g., a user's unique hobby). Profile-aware prompts
  tailor vocabulary to the communicator's AAC level and age.
- **`ai_board_page` credit feature key** (cost: 2 credits per AI-generated page).
  Graceful fallback: if the user lacks credits, niche interests route to the
  "My Favorites" catch-all instead of failing.
- `CreditService.can_spend?` — balance check without locking/spending.
- `SeededSetCloner` now supports `exclude_fringe:` to skip seed set pages the
  planner doesn't need for the chosen level.
- Level recommendation heuristics: young/emerging → Starter,
  developing/young-teen → Standard, proficient/older → Extended. **These are
  reasonable defaults, not clinically validated** — revisit with AAC research
  or user data before treating them as authoritative.

### Added — Board Builder: expanded interest categories + categorized picker endpoint
- Expanded interest dictionary from 4 categories (~120 words) to 18 categories
  (~504 words). New categories: Animals, Art & Craft, Clothing, Family & People,
  Health & Body, Home, Music, Nature & Outdoors, Places, School, Social, Sports,
  Technology, Transportation.
- New `GET /api/v1/board_builder/interest_categories` endpoint returns the full
  category dictionary for the frontend's categorized interest picker.
- Interest cap raised from 12 to 20.
- `create` now accepts interests as `[{ word, category }]` hashes for explicit
  routing from the picker (plain strings still work via dictionary lookup).

### Improved — Admin dashboard: light/dark toggle + engagement metrics
- **Light mode default** with a toggle in the top-right nav. Preference persists
  in localStorage. All admin pages (Dashboard, Mission Control, Users) use CSS
  variable theming that works in both modes.
- **New Engagement section** on Mission Control: Active Users (7d), Active Users
  (30d), Trial Users (currently trialing), and Communicator accounts.
- **Signup Trend chart** showing daily signups for the last 7 days as a bar chart.
- All admin views (Dashboard, Mission Control, Users list, User detail) updated
  from hard-coded dark-only colors to CSS-variable theming.

### Added — Expose plan_status and persist Stripe trial_ends_at (#324, #325)
- `User#api_view` now includes `plan_status` so the frontend can distinguish a
  payment-provider trial (`"trialing"`) from an active paid plan.
- Stripe webhook (`handle_subscription_upsert`) persists
  `settings["trial_ends_at"]` (ISO8601) when a subscription is trialing, and
  clears it on conversion or cancellation — matching the RevenueCat path.
  The frontend's trial countdown now works for both web and iOS trials.
- `GET /api/v1/users/current` calls `reconcile_stranded_plan!` so a stale
  plan_status self-heals on the user-fetch path, not only at sign-in.

### Added — Promo-aware one-click plan switch for existing subscribers (#308)
- **`POST /api/subscriptions/change_plan_portal_session`** lets an existing
  subscriber switch plans (e.g. basic-monthly → the yearly Founding rate) with
  the promo pre-applied — no fresh checkout (which would double-bill an active
  sub), no manually typed code. Params: `plan_key` (required), `promo_code`
  (optional). It resolves the plan to a Stripe price (shared `PLAN_PRICE_IDS`),
  looks up the active promotion code the same graceful way checkout does, finds
  the user's own active/trialing/past_due subscription, and opens a Stripe
  Customer-portal **deep link** (`flow_data.subscription_update_confirm`) that
  pre-selects the new price + discount. Stripe renders its own confirm page
  (price change + proration), so we never mutate the subscription directly; the
  resulting `customer.subscription.updated` webhook applies the new entitlements
  exactly like a manual portal switch. Returns 422 when the user has no
  active subscription (those users belong in checkout) or an unknown plan, and
  400 (generic message) on any Stripe error. Frontend wiring lands separately.

### Fixed — Stripe checkout/signup hardening (entitlement bypass + customer linking)
- **`POST /api/stripe/update_user_from_session` could grant a paid plan for an
  unpaid checkout.** It set `plan_type`/`plan_status=active` straight from the
  session's `plan_key` metadata without checking the checkout completed, so
  hitting the success URL with an abandoned/expired session's id flipped the
  user to a paid tier for free. It now requires `session.status == "complete"`,
  only lets the authenticated **owner** of the session reconcile from it (403
  otherwise), and reads the **real subscription status** (`trialing`/`active`)
  so a no-card trial is no longer recorded as `active` (and can't clobber the
  webhook's `trialing`). Credits remain webhook-only.
- **`customer.created` webhook now links the Stripe customer to the user**
  (fills a blank `stripe_customer_id`, never repoints an existing one) instead
  of relying on `email_signup`'s separate save winning the race, and the
  invite-fallback is race-safe (re-finds by email on a unique violation rather
  than duplicating the account).

### Added — iOS/Apple trial-ending reminder email
- New `RevenueCatTrialEndingJob` (daily cron, 5am UTC) sends the "trial wrapping
  up" reminder to RevenueCat trialists ~`REVENUECAT_TRIAL_REMINDER_LEAD_DAYS`
  (default 3) before their trial ends. Apple/RevenueCat send no `trial_will_end`
  webhook (unlike Stripe), so this computes the reminder from the
  `settings["trial_ends_at"]` the webhook persists and enqueues the shared
  `MailchimpTrialWrapJob` (same `trial_wrap` journey + merge fields as web).
  Flags `settings["rc_trial_wrap_sent"]` so each trial is nudged once (re-armed
  when a new trial starts). Keying on `trial_ends_at` scopes it to RC trials, so
  Stripe trialists are never double-nudged. This completes iOS/Stripe trial
  parity.

### Added — RevenueCat (iOS/Apple) free trials are now first-class
- The RevenueCat webhook reads `period_type`: a `TRIAL`/`INTRO`
  `INITIAL_PURCHASE` now marks the user `plan_status="trialing"` (was always
  `active`), persists `settings["trial_ends_at"]`, and fires a distinct
  `trial_started` analytics event (internal + PostHog) instead of
  `subscription_started`. `subscription_started` now fires on **conversion**
  (a normal-period renewal/product-change out of a trial), and an unconverted
  trial `EXPIRATION` is tagged `reason: "trial_expired"` — so iOS trial→paid
  conversion is measurable, matching the Stripe path.
- `BillingController#update_subscription` (the client confirmation call)
  preserves an in-progress `trialing` status for the same plan so it can't
  race-clobber the trial the webhook recorded.
- The 3-days-before trial-ending reminder is delivered by the new
  `RevenueCatTrialEndingJob` (see the entry above).

### Fixed — RevenueCat product-id mapping didn't match the real App Store ids
- `RevenueCat::PlanMapping::PRODUCT_TO_PLAN` keyed on bare package names
  (`basic_monthly`, `pro_yearly`), but Apple/RevenueCat emit reverse-DNS product
  ids (`com.speakanyway.basic.monthly`, …). As a result the product-id fallback
  for plan resolution never matched, and `settings["billing_interval"]` was never
  set for IAP subscribers (analytics gap + a latent failure if a webhook ever
  arrived without entitlement ids). Added the real App Store ids (confirmed
  against the RevenueCat catalog) while keeping the bare names as a defensive
  fallback. MySpeak products are intentionally left unmapped.

### Fixed — iOS/Apple (RevenueCat) buyers could get no welcome email; Stripe webhook replays polluted the credit ledger
- **IAP welcome email is now webhook-driven.**
  `RevenueCat::WebhookProcessor#handle_purchase` now sends the plan-correct
  welcome (`User#send_plan_welcome_email_once!`) on purchase/upgrade. Previously
  the welcome only fired from the client's `POST /api/billing/update_subscription`
  call, so a dropped request (backgrounded app, crash, flaky network) after a
  completed App Store purchase left a paying user with no welcome email. The
  webhook is now the source of truth, matching the Stripe path.
- **IAP welcome is now idempotent.** `BillingController#update_subscription`
  switched from `send_welcome_email` to the idempotent
  `send_plan_welcome_email_once!`, so a retried client call (or the webhook +
  client both firing) can't double-email.
- **Stripe webhook is now idempotent end-to-end.**
  `API::WebhooksController#webhooks` records each handled event in
  `processed_webhook_events` and skips a replayed event id. Credit grants were
  already deduped on `stripe_event_id`; this extends the guard to non-credit
  handlers (downgrade on delete/pause, `past_due` on payment failure) so Stripe
  retries and dashboard replays no longer add duplicate ledger rows. The event
  is recorded only after a clean run, so genuine failures still get retried.

### Fixed — Paid-trial signups got the "Free account" welcome email
- `email_signup` (paid-intent path) was hardcoded to send `welcome_free_email`
  ("You're on the Free plan") before the user reached Stripe checkout, so
  Basic/Pro trialists got the wrong email. It now sends a plan-neutral
  `welcome_email_receipt` ("Your account is ready") tracked under
  `settings["receipt_email_sent"]`.
- The plan-correct `welcome_basic_email` / `welcome_pro_email` now ship from
  `API::WebhooksController#handle_subscription_upsert` on the first transition
  into `trialing` or `active`, via the new
  `User#send_plan_welcome_email_once!` (idempotent per `plan_type` via
  `settings["plan_welcome_sent_for"]`). This is the first path that delivers a
  Basic/Pro welcome to web subscribers; mobile IAP is unchanged.
- The Mailchimp `welcome` journey enqueue at signup is unchanged here — a
  plan-aware journey is tracked as a follow-up.

### Added — Email-only signup API + billing portal for free accounts (frictionless paid signup)
- `POST /api/v1/users/email_signup`: paid-intent visitors create an account with
  just an email (passwordless via invitation), get signed in immediately, and
  proceed to Stripe Checkout. Duplicate emails return 422 `email_taken`.
- `POST /api/v1/users/set_password` (authenticated): sets the initial password on
  a passwordless account, routed through `accept_invitation!` so the password
  actually works (devise_invitable ignores `valid_password?` while an invitation
  is pending). The legacy `POST /api/set-password` endpoint got the same fix.
- `user.api_view` now exposes `needs_password` (pending-invite accounts), driving
  the frontend's post-checkout "set a password" prompt.
- `POST /api/subscriptions/billing_portal` now works for accounts with no Stripe
  customer (lazily creates one) and returns 400 with a generic message on Stripe
  errors instead of 500. Optional `STRIPE_PORTAL_CONFIG_ID` env pins a dedicated
  portal configuration.

### Fixed — Welcome email magic link never rendered
- `UserMailer.welcome_free_email` / `welcome_basic_email` / `welcome_pro_email`
  always fell back to the `/users/sign-in` link: the raw invitation token is a
  virtual attribute that doesn't survive `deliver_later`'s GlobalID round-trip.
  The token now travels as an explicit argument, so invited users get the
  `/welcome/token/<token>` one-click sign-in link.
- The `customer.created` Stripe webhook now matches existing users by email
  before inviting, so it can no longer rotate a just-issued invitation token
  (which invalidated the magic link emailed seconds earlier).

### Changed — Demo/internal accounts receive Mailchimp journey emails again (temporary)
- Reverted #297 for now: the `user.demo_user?` guards in `MailchimpEventJob`,
  `MailchimpTrialWrapJob`, and the cohort-sweep jobs are removed, so demo
  accounts (`bhannajohns+` / `@speakanyway.com` emails) can receive lifecycle
  journey emails — useful for end-to-end testing of the journeys. Re-apply by
  reverting this revert when testing is done.

### Changed — AI image generation no longer charges credits for first-time fills
- `POST /api/images/generate` only spends `image_generation` credits when the image
  **already has a picture** (the user is replacing/customizing it). Generating an image
  for a tile/label that has **no picture yet** now generates the image for **free** — we
  don't charge users to build the shared image library. The credit gate moved from an
  unconditional check at the top of the action to `Image#display_image_url(user).present?`.
  Regenerate / image-edit / image-variation are unchanged (they always act on an existing
  image, so they keep charging).
### Added — Server-side `checkout_completed` PostHog event (upgrade funnel)
- The Stripe `checkout.session.completed` webhook now captures a
  `checkout_completed` PostHog event `{ plan, kind, amount_total, currency,
  source: "stripe_webhook" }` for both subscription checkouts and credit
  topups (`kind: "topup"`), making checkout outcomes visible in the upgrade
  funnel even when the user never returns to the success page. No new ENV
  vars — activates in production via the existing PostHog gate.

### Fixed — Dead `POST /api/v1/users/sign_in` route
- The route pointed at a non-existent `auths#sign_in` action, so any caller
  got a server error. It now routes to `auths#create`, identical to
  `POST /api/v1/login`.

### Changed — Transactional free welcome slimmed to a receipt (dual-welcome, #293 option A)
- `UserMailer.welcome_free_email` is now a short **receipt** — account-ready
  confirmation + sign-in link, with a closing line that hands off to the
  Mailchimp `welcome` Customer Journey ("we'll follow up with where to start").
  Removed the marketing sections (what-you-can-do, quick-start, MySpeak ID,
  upgrade box) that duplicated the journey's content. Subject, the "Free plan"
  badge, and the sign-in CTA are unchanged. EN + ES both updated. This lets the
  transactional receipt and the warm Mailchimp welcome coexist without
  overlapping (issue #293, option A).

### Added — Mailchimp trial-wrap (#5) and win-back (#6) lifecycle journeys
- **Trial wrapping up (#5).** The `customer.subscription.trial_will_end` Stripe
  webhook now enqueues `MailchimpTrialWrapJob`, which **personalizes** the email
  before triggering: it pushes the contact's `TRIAL_END` (formatted date),
  `BOARDS` (board count), and `COMMS` (communicator count) merge fields via the
  new `MailchimpService#update_merge_fields`, then fires the `trial_wrap`
  Customer Journey — so the copy can say "you made N boards and M communicators;
  keep them by continuing." Fires ~3 days before a Stripe no-card reverse trial
  ends (soft `basic_trial` was retired, so all trials are Stripe trials).
- **Win-back (#6).** New `MailchimpWinBackJob` (Sidekiq-cron, daily at 4:30am
  UTC) re-engages recently-dormant active users: non-admin, **≥1 board**, last
  sign-in 14–30 days ago (`WIN_BACK_DORMANT_MIN_DAYS` / `_MAX_DAYS`, tunable).
  Per-user dedupe via `user.settings["win_back_nudge_sent"]`. Requiring ≥1 board
  keeps it cleanly distinct from the legacy never-made-a-board journey (#7).
- Inert until configured: both no-op until `MAILCHIMP_JOURNEY_TRIAL_WRAP_ID` /
  `_STEP` and `MAILCHIMP_JOURNEY_WIN_BACK_ID` / `_STEP` are set, and journeys
  stay prod-only by default. #5 also needs the 3 merge fields created in the
  Mailchimp audience. (Issue #291.)

### Added — Mailchimp legacy stalled-signup re-engagement journey (#7)
- **Monthly re-engagement.** New `MailchimpLegacySignupNudgeJob` (Sidekiq-cron,
  5am UTC on the 1st of each month) finds non-admin users who created an account
  a while ago (`LEGACY_SIGNUP_NUDGE_AGE_DAYS`, default 30), never made a board,
  and haven't signed in recently (`LEGACY_SIGNUP_NUDGE_INACTIVE_DAYS`, default
  30), then enqueues the Mailchimp `legacy_signup_nudge` Customer Journey.
  Per-user dedupe via `user.settings["legacy_signup_nudge_sent"]` so each user
  is nudged once, ever.
- **Second touch, not a duplicate.** Distinct from the 48h `first_board_nudge`
  (#2) — different copy and a separate flag, so a long-dormant user who got the
  48h nudge weeks earlier may receive this once. Catches both the current
  backlog of cold signups and future stalls as they age past the threshold.
- Inert until configured: no-ops until `MAILCHIMP_JOURNEY_LEGACY_SIGNUP_NUDGE_ID`
  / `_STEP` ENV vars are set; journeys stay prod-only by default
  (`MAILCHIMP_JOURNEYS_ENABLED=true` to override in staging/dev). (Issue #294.)

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
