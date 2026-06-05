# SpeakAnyWay — Backend

Ruby on Rails 7 app (hybrid: API + HTML views). Deployed on EC2 via Hatchbox.

## Documentation Accuracy Rules

When writing or updating backend CLAUDE.md, ALWAYS verify claims against the actual codebase before writing. Specifically:

- Read Gemfile, config/application.rb, and routes.rb first
- Do NOT claim 'API-only' without checking config.api_only
- Do NOT add compliance claims (FedRAMP, HIPAA, SOC2) unless explicitly evidenced in code
- List actual major dependencies, not assumed ones

## Stack

- **Framework:** Rails 7
- **Language:** Ruby
- **Database:** PostgreSQL
- **Auth:** Devise + devise-jwt
- **Authorization:** Pundit
- **Background jobs:** Sidekiq (v7) + Redis
- **Payments:** Stripe and RevenueCat (via webhook)
- **File storage:** S3 (Active Storage)
- **Email:** Action Mailer over Gmail SMTP. Both environments authenticate against `smtp.gmail.com` when `SMTP_USERNAME`/`SMTP_PASSWORD` are set (a Google Workspace account + App Password); production falls back to the `smtp-relay.gmail.com` IP-allowlisted relay when no credentials are present. `SMTP_ADDRESS` overrides the SMTP host. The `mailgun-ruby` gem is in the Gemfile but is not the active delivery transport. Diagnose delivery with `bin/rails 'mail:test[you@example.com]'`.
- **TTS/Audio:** AWS Polly
- **AI:** OpenAI API (`ruby-openai`) — board generation, scenario builder, image generation
- **Serializers:** jsonapi-serializer gem
- **Hosting:** Hatchbox / EC2
  - Production: `main` branch → `speakanyway.com` (Hatchbox app `670kd.hatchboxapp.com`)
  - Staging: `staging` branch → `https://ypk9e.hatchboxapp.com`. Long-lived branch — push experimental commits directly to it (deploys are handled by Hatchbox's own push hook on the `staging` branch). To resync `staging` to match `main` (or any ref) and trigger a deploy, run the `Deploy staging (manual)` workflow via `workflow_dispatch` (see `.github/workflows/staging-deploy.yml`). Staging-specific behavior is gated on `ENV["STAGING"] == "true"` — both envs run with `RAILS_ENV=production`. Use the `AppEnv.staging?` helper (`app/models/app_env.rb`) for this check in app code.
  - **Staging skips paid OpenAI image calls.** When `AppEnv.staging?`, `OpenAiClient#create_image` / `#create_image_variation`, `ImageVariationService`, and `ImageEditService` return the bundled `public/placeholder.jpeg` instead of calling OpenAI. The rest of the image pipeline runs normally.

## Frontend

- React/Ionic frontend served separately (not via Rails asset pipeline)
- Communicates with Rails backend via JSON API endpoints
- Some HTML views for auth flows and admin dashboard, but most user-facing UI is React
- Local development: Rails server on http://localhost:4000, React dev server on http://localhost:8100
- Frontend local repo is `../itty-bitty-frontend`

## Routing

- Routes are mixed: some at root level, some under `/api/`, some under `/api/v1/`
- JSON API routes are generally under `namespace :api` (with `defaults: { format: :json }`)
- Auth routes (`/api/v1/`) live in `app/controllers/api/v1/`
- Do not assume all routes follow a single convention — check `config/routes.rb`

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
- `bin/rails 'mail:test[you@example.com]'` — diagnose mail delivery: prints the resolved ActionMailer config and sends a test email, surfacing the real SMTP error

## Reading production logs (CLI)

Hatchbox runs Puma + Sidekiq as **user** systemd services on the deploy
user, so logs are in the user journal (no sudo needed).

- `bin/prod-logs` — tail production Puma (`itty-bitty-boards-server.service`) over SSH
- `bin/prod-logs worker` — tail production Sidekiq (`itty-bitty-boards-sidekiq.service`)
- `bin/prod-logs all` — tail every `itty-bitty-boards-*.service` unit
- `bin/prod-logs <unit-name>` — tail a specific unit (pass-through)
- `bin/staging-logs [web|worker|all]` — same shape for staging
- `bin/prod-disk-audit` — read-only snapshot of disk + journald + nginx
  - app `log/` and `tmp/` sizes. Run any time you suspect disk pressure.

Env overrides: `PROD_HOST`, `PROD_WEB_UNIT`, `PROD_WORKER_UNIT`,
`PROD_ALL_UNIT` (and `STAGING_*` equivalents). `LINES=N` controls the
backlog size (default 200).

## Monitoring / alerting

- `DiskSpaceAlertJob` (`app/sidekiq/`) runs hourly via sidekiq-cron and
  emails an admin (`ADMIN_EMAIL`) when the root disk crosses 80% (warn) or
  90% (critical). Alerts are debounced in Redis to once per severity per 6h.
  Skipped on staging, since staging shares the production EC2 box. Added
  after a disk-full outage wedged the box during a deploy.
- **External `/up` monitor (BetterStack):** HTTP monitor hits
  `https://670kd.hatchboxapp.com/up` (prod) every 3 min. Pages on failure
  via SMS to the on-call number + email to `ADMIN_EMAIL`. No Rails code
  backs this — `/up` is the stock `Rails::HealthController` route in
  `config/routes.rb`. Catches failure modes the in-app jobs can't: wedged
  puma (the 2026-05-30 outage), nginx/DNS/network, full-box down.
  Configured in BetterStack's UI; nothing in this repo to change when
  tuning the monitor. Staging is intentionally not monitored — it shares
  the prod box, so a prod alert covers both. Added after the 2026-05-30
  outage where puma was alive per systemd but all threads were wedged.

## Mailchimp integration

We use the Mailchimp **Marketing API** (`MailchimpMarketing` gem, official
GitHub build). Two distinct uses:

- **CRM sync (existing):** `MailchimpService` upserts contacts
  (`record_new_subscriber`), tags by plan tier, and records sign-in/sign-up
  events. Fired async via `MailchimpEventJob` (event types `sign_up` /
  `sign_in`) from `API::V1::AuthsController` and the Stripe checkout controller.
- **Customer Journey triggers (email):** `MailchimpService#trigger_journey`
  enrols a contact into a journey's **API-trigger step**
  (`@client.customer_journeys.trigger`), so Mailchimp sends the email designed
  in that journey. The contact is upserted-and-retried-once if Mailchimp 404s.
  Wired through the `MailchimpEventJob` `"journey"` event type, which takes a
  `journey_key`.

  - **Journey IDs are never hardcoded.** `MailchimpClient.journey(key)` resolves
    a symbolic key (e.g. `:welcome`) to `{ journey_id, step_id }` from
    `MAILCHIMP_JOURNEY_<KEY>_ID` / `_STEP` ENV vars; unconfigured keys no-op
    with a log line. Adding a new journey = new ENV pair + a
    `MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => "<key>" })`
    enqueue. The first wired journey is `welcome` (enqueued on signup).
  - **Env-gated to avoid emailing real users from non-prod.**
    `MailchimpClient.journeys_enabled?` returns true in production (and only
    production — staging is excluded via `AppEnv.staging?`); dev/staging fire
    only when `MAILCHIMP_JOURNEYS_ENABLED=true`. CRM sync is **not** gated.

App transactional email (welcome, password reset) still goes through
ActionMailer/Gmail SMTP, **not** Mailchimp. True 1:1 transactional via Mailchimp
would require the separate Transactional/Mandrill product (different gem + key +
paid add-on) — not integrated.

## Subscription model

- Most features are free
- Premium features (Menu Board Creator, AI image generation) require active subscription
- Subscription managed via Stripe/RevenueCat — check status before allowing access to premium endpoints

### No-card reverse trial (Basic/Pro)

Basic/Pro trials default to **no credit card** (issue #264). In
`API::Stripe::CheckoutSessionsController#create`, `payment_method_collection`
is `"if_required"` by default; the card-required A/B arm is forced via
`params[:require_card] == "true"` (PostHog-driven from the frontend) or the
`STRIPE_PAYMENT_METHOD_COLLECTION=always` env override. The legacy `NOCC` /
`bypass_payment_required` no-card path still wins over both.

The trial subscription is created with
`subscription_data.trial_settings.end_behavior.missing_payment_method =
"cancel"`, so a no-card trial that lapses **cancels cleanly** →
`customer.subscription.deleted` → `apply_free_plan` (Free + fallback mode,
#255). As a safety net, `API::WebhooksController#handle_subscription_upsert`
also routes terminal statuses (`unpaid`, `incomplete_expired` —
`TRIAL_LAPSED_STATUSES`) to `apply_free_plan`. **`past_due` is excluded** —
that's a real payer's failed renewal, left in Stripe dunning
(`handle_invoice_payment_failed`).

Trial→paid is measured via `AnalyticsEvent`: `trial_started` (checkout),
`trial_will_end` (Stripe pre-end webhook), `subscription_started` (fired on
the non-active→active transition in the upsert; guarded so renewals don't
double-count). Primary A/B metric is **net paid users per 100 signups**, not
trial→paid rate.

### `paid_plan?` semantics

`User#paid_plan?` is the single gate for paid-tier checks. It considers
**both** `plan_type` and `plan_status`:

- Returns `false` when `plan_type` is `nil` or `free`.
- Returns `false` when `plan_status` is `canceled`, `paused`,
  `incomplete_expired`, or `unpaid` — even if `plan_type` is a paid tier.
  This protects against a missed `subscription.deleted` webhook leaving
  a user as `plan_type=basic` + `plan_status=canceled` and silently
  passing paid gates.
- `basic_trial` (soft trial) and Stripe `trialing` count as paid while
  active — same rule as the MySpeak ID and credit gates.

If you're adding a new paid-feature gate, call `current_user.paid_plan?`
rather than reading `plan_type` directly.

### Soft-trial assignment (`set_soft_trial_plan`)

Soft-trial users start as `plan_type=basic_trial` for 14 days post-signup.
Assignment runs as a **`before_create`** callback (not `before_save`), with
an early-return guard: if the user already has a `paid_plan_type` set
(i.e. they picked Basic/Pro at signup), the trial assignment is skipped.

The earlier `before_save` version bounced users back to `basic_trial`
on every save within the 14-day window — even after a deliberate
downgrade (Stripe cancel, "Free" pick at checkout). If you touch this
callback, preserve both invariants: trial only on initial create, and
never overwrite an explicit paid_plan_type pick.

### MySpeak ID limit (Free = 1)

Free users are capped at **one MySpeak ID** (Profile). Basic/Pro/admin
are unlimited. A "MySpeak ID" counts a Profile attached to the user
directly *or* to one of their `communicator_accounts`. Implemented in
`User#myspeak_id_limit` / `#myspeak_id_count` / `#can_create_myspeak_id?`,
with limit env-tunable via `FREE_MYSPEAK_ID_LIMIT` (default `1`).

`POST /api/profiles` is gated up front and returns **HTTP 403** with
`{ error: "myspeak_id_limit_reached", message, limit, count }` when a
Free user is already at the cap. Trial users (`basic_trial`, Stripe
`trialing`) are treated as paid by `paid_plan?` and the gate doesn't
trigger — consistent with how credit gates work.

### Board access on downgrade (read-only rule)

When a paid user (Basic/Pro) cancels, `apply_free_plan` resets `plan_type` to
`free` and `settings["board_limit"]` to 1. Boards beyond that limit become
**read-only**, never deleted: still openable, tappable, and audio still plays
(SpeakAnyWay is an AAC app — usage must never break), but
**content-mutating endpoints return HTTP 403 `board_locked`**.

- Locked state is **computed**, not stored. A board is locked for its owner
  when the user is not admin, not on a paid plan, is over their board limit,
  and the board is not their designated editable board. See
  `User#board_editable?` (`app/models/user.rb`) and `Board#can_edit_for`
  (`app/models/board.rb`). The board's `api_view` exposes `can_edit`,
  `locked`, and `lock_reason` for the frontend.
- The user picks which single board keeps full edit access via
  `PATCH /api/boards/:id/make_editable`. The selection is persisted on
  `users.editable_board_id`. If none is set, `effective_editable_board_id`
  falls back to a favorite or most-recently-updated board so a freshly-
  downgraded user is never fully locked out.
- **Switch cooldown:** `make_editable` enforces a cooldown
  (`User::EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS`, default 14, ENV-tunable via
  `EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS`) between explicit picks. Without it,
  a free user could rotate the slot to edit every board one at a time and
  defeat the gate. Admins bypass. The initial auto-pin from
  `pin_default_editable_board!` does **not** start the clock — the user's
  first real `make_editable` call does. Returns HTTP 403
  `editable_board_cooldown` with `available_at` and `cooldown_days` when
  blocked. A no-op re-pick of the already-designated board doesn't start
  the clock either.
- On downgrade, both paths call `User#pin_default_editable_board!` so the
  frontend has a deterministic answer: `apply_free_plan` (Stripe
  cancel/pause) and `DowngradeSoftTrialJob` (soft-trial expiry). Trial users
  (`basic_trial` and Stripe `trialing`) are treated as paid by
  `User#paid_plan?` while the trial is active, so the gate doesn't trigger.
- The gate runs as a `check_board_editable!` `before_action` on the
  content-mutating actions in `API::BoardsController` and the matching set
  in `API::BoardImagesController`. Reads (`show`, `index`, `pdf`, audio
  playback) and `destroy` (let the user free up the slot) are never gated.
  `create`/`clone`/`create_from_template` stay on the existing
  `check_board_create_permissions`.
- Returns **HTTP 403** with `{ error: "board_locked", message, board_limit,
  editable_board_id }`. **Not 402** — 402 is reserved for credit exhaustion.
- **Assumes `FREE_BOARD_LIMIT == 1`.** The single `editable_board_id` only
  frees one board. If the ENV is ever raised above 1, revisit this to a
  per-board flag or join table.

### Communicator sign-in on downgrade (fallback mode)

Mirror of the board read-only rule, for communicators (issue #255). When a
paid account drops to Free, communicators **beyond the Free slot limit are
retained, never deleted/archived** — boards, MySpeak/profile, and `public_url`
all stay intact. The over-limit ones enter **fallback mode**: private passcode
sign-in is blocked, but the public MySpeak page stays open and read-only, so a
nonspeaking child is never stranded mid-use.

- **Marker is stored, not derived.** `ChildAccount#fallback_mode?` reads
  `settings["fallback_mode"]` (with `fallback_since` / `fallback_reason`). Set
  and cleared **only** by `User#reconcile_communicator_fallback!`, so a fresh
  Free signup (capped at 1) is never flagged — fallback is *only ever a
  consequence of downgrade*. Use `enter_fallback!` / `exit_fallback!`.
- **One reconciler, both directions.** `User#reconcile_communicator_fallback!`
  orders slotted (loaner+active) communicators **most-recently-active first**
  (`last_sign_in_at` desc, nulls last), keeps the top `slot_limit` signable,
  and flags the overflow. A downgrade flags the overflow; a re-upgrade restores
  them as slots free up (no manual re-claim); any still over the new limit stay
  in fallback. Idempotent; admins are never limited.
- **Trigger:** `after_save :reconcile_communicator_fallback!, if:
  :saved_change_to_plan_type?` on `User`. Every plan transition (Stripe
  cancel/pause via `apply_free_plan`, `DowngradeSoftTrialJob`, and upgrades via
  the subscription-upsert webhook) routes plan changes through `plan_type=` +
  `save`, so this one callback covers all of them.
- **Gate:** `ChildAccount#can_sign_in?` returns `false` for fallback
  communicators (a system-admin `user_context` still bypasses for support).
  `API::V1::ChildAuthsController#create` enforces it specifically for fallback:
  returns **HTTP 403** `{ error: "communicator_in_fallback", message,
  redirect_url, public_url }` so the frontend redirects to the public page
  (companion frontend issue itty-bitty-frontend#275). The older broad
  `can_sign_in?` controller check stays disabled — only fallback is enforced,
  so non-fallback Free communicators keep working (AAC "usage must never break").
- **API exposure:** `fallback_mode` + `fallback_since` on ChildAccount
  `api_view` / `index_api_view` / `vendor_api_view`, letting the frontend tell
  "exists but in fallback" from "doesn't exist."

## Team permissions — owner protection

Communicators (`child_account`) have an `owner_id` (the family/parent
post-claim, or the SLP pre-claim). That user is "**owner-pinned**" on the
communicator's team: they cannot be removed or have their role changed by
any non-owner. Full matrix in issue #166. Server-side rules:

- `ChildAccount#claim_by!` auto-adds the new owner to the team.
- `DELETE /api/teams/:id/remove_member` returns **HTTP 403
  `cannot_remove_owner`** if the target is owner-pinned and the caller is
  neither that user nor a system admin. The owner can remove themselves.
- `POST /api/teams/:id/invite`, when it would change an *existing*
  membership's role, returns **HTTP 403 `cannot_change_owner_role`** if
  the target is owner-pinned (and the caller isn't that user). It also
  returns **HTTP 403 `cannot_self_promote`** if a non-owner non-admin
  caller tries to set their own role to `admin`.
- Owner-pinned-ness is computed, not stored:
  `Team#account_owner_ids` / `Team#account_owner?(user)` and
  `TeamUser#account_owner?`. Team `show`/`index` `api_view` expose
  `account_owner_ids` and per-member `is_account_owner` so the frontend
  can hide destructive controls.

A real **transfer ownership** flow doesn't exist yet — it's out of scope
for #166 and will get its own endpoint (touches `child_account.owner_id`,
not just team membership).

**Full SLP→parent handoff contract** — including the permissions matrix
(who can do what to a claimed communicator), the lifecycle states, and
known backend-enforcement gaps — lives in
`marketing/.claude-notes/handoff-workflow.md`. Keep that doc and this
section in sync when the rules change.
### Editing the communicator object itself

`ChildAccount#editable_by?(user)` returns true iff the user is the
`owner_id` or a system admin. It's the helper that drives the
`can_edit_communicator` flag on both `api_view` and `vendor_api_view`
(issue #215). The frontend uses that flag to gate the Edit tab/form on a
communicator — i.e. who can change name, username, voice, layout, and
the safety profile.

`can_edit_communicator` is **distinct from `can_edit`** in the same
payload: `can_edit` answers "can this user curate boards on this
communicator" (board sharers, including team members on a paid plan).
`can_edit_communicator` answers "can this user mutate the communicator
object itself" (owner-only by default). Keep both — they back different
UI affordances.

Full permissions matrix and the rationale for the split lives in
`../speakanyway/marketing/.claude-notes/handoff-workflow.md`.

## AI gating: credit ledger (source of truth)

- AI features are gated by **weighted credits** held in two balances on `users`:
  `plan_credits_balance` (resets each billing period, doesn't roll over) and
  `topup_credits_balance` (additive from one-time purchases, doesn't expire).
- All credit movement is recorded in `credit_transactions` (immutable ledger).
  Webhook-driven grants are idempotent on `stripe_event_id`.
- Entry point: `CreditService.spend!(user, feature_key:, amount: nil)` raises
  `CreditService::InsufficientCredits` when out of credits. Per-feature costs
  live in `CreditService::FEATURE_COSTS`.
- AI controllers gate via `check_credits!(feature_key:, feature_name:)` in
  `API::ApplicationController`. On insufficient balance it renders **HTTP 402**
  with `{ error: "insufficient_credits", feature, needed, balance, plan_credits,
topup_credits, reset_at, topup_url }`. Admins (`current_user.admin?`) bypass.
- Reserve **HTTP 429** for true rate limiting (rapid-fire abuse), not credit
  exhaustion.
- `MonthlyFeatureLimiter` is no longer in the AI hot path. It remains in the
  codebase as a generic Redis-counter helper for any future non-AI rate
  limits, but no controller currently calls it.

Plan-credit lifecycle:

- **Signup:** `User#after_create` calls `CreditService.ensure_initial_grant!`
  to grant the tier's monthly allowance immediately. Soft-trial users
  (`plan_type = "basic_trial"`, set by `User#set_soft_trial_plan`) get the
  Basic-equivalent allowance with `expires_at = 14.days.from_now`. Other
  tiers get a 30-day expiry. Idempotent — safe to call again.
- **First paid period + every renewal:** `invoice.payment_succeeded` webhook
  → `CreditService.grant_plan!` with `period_end = subscription.current_period_end`.
  Reads `monthly_credits` from the subscription line's Stripe Price metadata
  (falls back to `CreditService::PLAN_MONTHLY_CREDITS[plan_type]`). Idempotent
  on Stripe event id.
- **Stripe trial start:** `customer.subscription.created` with status
  `trialing` grants credits with `period_end = subscription.trial_end`.
- **Cancel / pause:** `apply_free_plan` flips the user to `free` and
  calls `CreditService.grant_plan!` with the free-tier allowance, so
  canceled/paused subscribers land on free with 5 credits (not 0). The
  prior plan balance is expired in the ledger by `grant_plan!` itself.
  Top-up credits are preserved.
- **Soft-trial → free downgrade:** `DowngradeSoftTrialJob` (daily at 2am UTC)
  flips expired `basic_trial` users to `free` and grants the free-tier
  allowance immediately.
- **Monthly credit refresh:** `RefreshFreeTierCreditsJob` (daily at
  3am UTC) re-grants the tier allowance to **any user without a
  `stripe_subscription_id`** whose `plan_credits_reset_at` has passed —
  covers free/basic_trial users, App Store/RevenueCat subscribers, and
  admin/demo accounts on paid tiers (granting their actual plan_type's
  allowance, e.g. Pro = 1500). Stripe-driven paying users
  (`basic`, `pro`, `partner_pro` with an active
  `stripe_subscription_id`) refresh through `invoice.payment_succeeded`
  instead. Class name kept for cron stability; scope is broader than
  the name suggests.
- **Backstop:** `ExpirePlanCreditsJob` runs hourly and zeroes any plan
  balance whose `plan_credits_reset_at` has passed. Cheap and idempotent —
  safe to invoke any time.
- **Grant safety:** `CreditService.grant_plan!` clamps any `period_end`
  earlier than `Time.current + MIN_GRANT_WINDOW` (1 day) forward, and
  logs a `Rails.logger.warn` when it does. Prevents the
  "granted and expired same day" failure mode regardless of caller.
- **Free tier allowance:** 5 credits/month (was 10). Applied on signup,
  refresh, and post-cancellation.

Tasks:

- `bin/rails credits:backfill` — give every user an initial plan-credit grant
  based on their `plan_type`. Idempotent.
- `bin/rails credits:recompute_balances` — rebuild denormalized balances
  from the ledger if they drift.
- `bin/rails credits:regrant_stale_backfill` — one-off recovery for users
  zeroed out by the original `credits:backfill` bug (issue #110): finds
  users with a `plan_grant` row, a matching `period_ended` `expire` row,
  and `plan_credits_balance = 0`, then re-grants their tier allowance with
  `period_end = 30.days.from_now`.

## OBF/OBZ import — copyright policy

Imports via `POST /api/boards/import_obf` are gated to avoid silently
pulling licensed symbol artwork (SymbolStix, etc.) into the public
image pool:

- **Default (no opt-in):** board structure imports, `Image` rows are
  created **`is_private: true`**, but **no image binaries are downloaded
  or attached to `Docs`**. The `attach_image_doc` step is skipped.
- **With opt-in:** client must send `include_images=true` AND
  `image_license_acknowledged=true`. Without the ack, the controller
  returns **HTTP 400 `image_license_required`**. The importer then
  calls `Down.download` per OBF image entry and attaches Docs.
- **`is_private: true` is non-negotiable.** Set in
  `Board.find_or_create_image_for_button` on every newly-created Image,
  regardless of opt-in. Existing images matched by label are returned
  as-is — we don't downgrade visibility on something the user already
  owns. Admin can flip individual images public later via existing UI.
- **Audit trail** lives on `BoardGroup.settings["imported_from_obf"]`:
  `include_images`, `license_acknowledged`, `acknowledged_by_user_id`,
  `acknowledged_at`, `imported_by_user_id`, and the OBF root board's
  `license` block (author, source URL, license type) if present.
- Plumbed through `ObzImporter#initialize(import_options:)`,
  `Board.from_obf(... import_options:)`, and `ImportFromObfJob#perform`
  (4th positional arg). All default to `{}` for backward compat with
  callers that don't care.

## Board Builder wizard

Turns wizard input — a starter **template** + a few **interest words** — into
a real linked `Board` set attached to a communicator. **Standalone** feature,
*not* part of MySpeak onboarding. Full subsystem doc:
`.claude-notes/board-builder.md`.

Three seams (input contract tightens left→right):

- `Boards::StarterBlueprints` — `TEMPLATES` registry of label-only starter
  trees (`"home"`, `"daily_routine"`). Add a tree to the hash → instantly in
  the picker (`#catalog`) and buildable (`#for`). Core labels resolve
  **create-if-missing** (blank art, same path as interest words), so a template
  builds even when its curated symbols — including the capitalized folder labels
  (`Food`, `Feelings`, `Play`, `Bathroom`) — aren't seeded in this environment.
- `Boards::BlueprintAssembler` — the resolution + routing seam. Resolves every
  label to an `image_id` (create-if-missing for new interest words, blank art
  for v1), then **routes interests into category folders** via
  `Boards::InterestCategories` (apple→Food, trains→Play). Routing is dynamic
  by template (only into a folder the chosen template has); anything unmatched
  falls through to one appended **"My Favorites"** folder, deduped, nothing
  dropped. Interests are normalized + capped at 12.
- `Boards::BoardTreeBuilder` (#259) — persists the tree from a blueprint of
  **already-resolved `image_id`s only**. Keep it dumb; all resolution lives in
  the assembler.

Endpoints (`API::V1::BoardBuilderController`, both auth-gated):

- `GET /api/v1/board_builder/templates` — label-only picker catalog.
- `POST /api/v1/board_builder` `{ communicator_id, template, interests }` —
  ownership check (**404 `communicator_not_found`** for a communicator not in
  `current_user.communicator_accounts`), assemble → build → persist normalized
  interests to `child_account.details["interests"]` (jsonb merge), return the
  favorited root board's `api_view` (**201**). **422 `unknown_template`** /
  **422 `build_failed`** (the build is transactional — failure rolls back, no
  orphans). The frontend page ships separately in `itty-bitty-frontend`.

## Do not

- Do not install new gems without asking first
- Do not modify any deployment or server config files
- Do not log sensitive user data
- Do not expose internal errors in API responses — return generic messages to the client
- Do not hardcode any environment-specific values (use ENV variables)

## Testing preferences:

- Prefer FactoryBot.build over create where possible
- Add focused tests for changed behavior
- Avoid destructive S3/ActiveStorage behavior in tests
- New features and bug fixes always get tests (per `~/.claude/CLAUDE.md`). Don't backfill tests for _existing_ code unless asked.

## Testing Conventions

- Rails test environment uses `:null_store` for Rails.cache — stub `Rails.cache` in specs that depend on caching behavior
- Avoid `travel_to` with past timestamps for Redis keys (TTLs expire immediately); use future times or freeze time instead
- After spec changes, run the tests that depend on the changed code to ensure no regressions. Use `bin/rspec --only-failures` to rerun only failed specs.

## Rules for Editing This File

When reviewing or rewriting CLAUDE.md, ALWAYS verify claims against the actual codebase first: read Gemfile/package.json, config files, routes, and a sampling of controllers/models. Never fabricate framework claims (e.g., 'API-only', 'FedRAMP-aware') or invent dependencies. If unsure, state 'unverified' rather than asserting.

## Bash & Long-Running Commands

When running long bash commands (bundle update, migrations, test suites), use appropriate timeouts and check completion status explicitly rather than polling repeatedly.
