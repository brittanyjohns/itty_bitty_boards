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
- **Payments:** Stripe and RevenueCat (via webhook). Admin revenue metrics combine both via `MissionControl::RevenueMetrics` (see "Mission Control revenue metrics" under the RevenueCat / Apple IAP section).
- **File storage:** S3 (Active Storage)
- **Email:** Action Mailer over Gmail SMTP. Both environments authenticate against `smtp.gmail.com` when `SMTP_USERNAME`/`SMTP_PASSWORD` are set (a Google Workspace account + App Password); production falls back to the `smtp-relay.gmail.com` IP-allowlisted relay when no credentials are present. `SMTP_ADDRESS` overrides the SMTP host. The `mailgun-ruby` gem is in the Gemfile but is not the active delivery transport. Diagnose delivery with `bin/rails 'mail:test[you@example.com]'`.
- **TTS/Audio:** AWS Polly
- **AI:** OpenAI API (`ruby-openai`) — board generation, scenario builder, image generation
- **Serializers:** jsonapi-serializer gem
- **Hosting:** Hatchbox / EC2
  - Production: `main` branch → `speakanyway.com` (Hatchbox app `670kd.hatchboxapp.com`)
  - Staging: `staging` branch → `https://ypk9e.hatchboxapp.com`. **Deploy branch, not a development branch** — it mirrors `main`. Promote by force-pushing `origin/main` onto `staging` and then running the `Deploy staging (manual)` workflow via `workflow_dispatch` (see `.github/workflows/staging-deploy.yml`) — pushing to `staging` alone does NOT trigger a deploy; the workflow is what fires the Hatchbox deploy. (Brittany's `deploy-staging` skill does both steps.) Any commits on `staging` that aren't on `main` are treated as drift and will be wiped by the next promotion's force-push — don't push experimental work there expecting it to survive. Staging-specific behavior is gated on `ENV["STAGING"] == "true"` — both envs run with `RAILS_ENV=production`. Use the `AppEnv.staging?` helper (`app/models/app_env.rb`) for this check in app code.
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
  (`@client.customerJourneys.trigger` — the gem accessor is camelCase; there is
  **no** snake_case `customer_journeys` alias, so it raises NoMethodError), so
  Mailchimp sends the email designed in that journey. The contact is
  upserted-and-retried-once if Mailchimp 404s.
  Wired through the `MailchimpEventJob` `"journey"` event type, which takes a
  `journey_key`.

  - **Journey IDs are never hardcoded.** `MailchimpClient.journey(key)` resolves
    a symbolic key (e.g. `:welcome`) to `{ journey_id, step_id }` from
    `MAILCHIMP_JOURNEY_<KEY>_ID` / `_STEP` ENV vars; unconfigured keys no-op
    with a log line. Adding a new journey = new ENV pair + a
    `MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => "<key>" })`
    enqueue. Wired journey keys:
    - `welcome` — enqueued from `API::V1::AuthsController#sign_up` and
      `API::Stripe::CheckoutSessionsController` on signup.
    - `hit_limit` — enqueued from `API::BoardsController#check_board_create_permissions`
      when a Free user trips the board cap on create/clone/create_from_template.
      Free-only; deduped per user for 14 days via `Rails.cache` so a user
      mashing the create button isn't spammed.
    - `first_board_nudge` — enqueued by `MailchimpFirstBoardNudgeJob` (daily
      at 4am UTC) for non-admin users who signed up 48-72h ago with no boards.
      The `user.settings["first_board_nudge_sent"]` flag prevents re-nudging
      across runs. Window has 24h slop so a single missed cron run doesn't
      permanently skip users.
    - `legacy_signup_nudge` — enqueued by `MailchimpLegacySignupNudgeJob`
      (monthly, 5am UTC on the 1st) re-engaging cold legacy signups: non-admin
      users created over `LEGACY_SIGNUP_NUDGE_AGE_DAYS` (default 30) ago, no
      boards, no sign-in within `LEGACY_SIGNUP_NUDGE_INACTIVE_DAYS` (default 30).
      The `user.settings["legacy_signup_nudge_sent"]` flag makes it once-only.
      It's a **second touch** distinct from `first_board_nudge` — different copy
      ("a while back you said yes…") and it *may* fire for a user who got the 48h
      nudge weeks earlier (the two flags are independent), but only ever once.
    - `trial_wrap` — enqueued by `MailchimpTrialWrapJob`, triggered from the
      `customer.subscription.trial_will_end` Stripe webhook (~3 days before a
      Stripe no-card reverse trial ends; soft `basic_trial` was retired). The
      **iOS/Apple equivalent** is `RevenueCatTrialEndingJob` (daily cron) — Apple
      sends no trial_will_end webhook, so it computes the ~3-day reminder from
      `settings["trial_ends_at"]` and enqueues this same job.
      **Personalized:** the job first pushes merge fields `TRIAL_END` (formatted
      date) / `BOARDS` (`countable_board_count`) / `COMMS`
      (`communicator_accounts.count`) via `MailchimpService#update_merge_fields`,
      then triggers — so the copy can say "you made N boards, M communicators;
      keep them by continuing." Requires those 3 merge fields to exist in the
      Mailchimp audience (tag names ≤10 chars: `TRIAL_END`, `BOARDS`, `COMMS`).
    - `win_back` — enqueued by `MailchimpWinBackJob` (daily, 4:30am UTC)
      re-engaging recently-dormant active users: non-admin, **≥1 board**, last
      sign-in `WIN_BACK_DORMANT_MIN_DAYS`–`WIN_BACK_DORMANT_MAX_DAYS` (default
      14–30) days ago. The `user.settings["win_back_nudge_sent"]` flag makes it
      once-only. Requiring ≥1 board keeps it distinct from `legacy_signup_nudge`
      (never made a board).
  - **Env-gated to avoid emailing real users from non-prod.**
    `MailchimpClient.journeys_enabled?` returns true in production (and only
    production — staging is excluded via `AppEnv.staging?`); dev/staging fire
    only when `MAILCHIMP_JOURNEYS_ENABLED=true`. CRM sync is **not** gated.
  - **Demo/internal accounts currently DO get journey emails (temporary).**
    The #297 `user.demo_user?` guards were reverted on 2026-06-10 so Brittany
    can end-to-end test the journeys with demo accounts. When testing is done,
    restore by reverting the revert commit (`git log --grep "Revert.*demo"`).
    CRM sync was never gated either way — demo contacts stay in the audience,
    tagged via the `DEMO_USER` merge field.

App transactional email (welcome, password reset) still goes through
ActionMailer/Gmail SMTP, **not** Mailchimp. True 1:1 transactional via Mailchimp
would require the separate Transactional/Mandrill product (different gem + key +
paid add-on) — not integrated.

**Dual welcome (decision #293, option A).** A new Free signup gets **two**
emails by design: (1) the transactional `UserMailer.welcome_free_email` over SMTP
— deliberately slimmed to a short **receipt** (account-ready + sign-in link, no
marketing sections), and (2) the Mailchimp `welcome` Customer Journey, which
carries the warm "let's make your first board" story. The receipt's closing line
("we'll follow up in a moment with where to start") hands off to the journey, so
they complement rather than duplicate. If you ever want only one, gate the
transactional send in `auths#sign_up` or unset the welcome journey ENV vars.

**Paid-intent welcome — two-stage.** `email_signup` (the PR #312 path) runs
**before** Stripe checkout, so the plan isn't known. It sends a **plan-neutral
receipt** (`UserMailer.welcome_email_receipt`, "your account is ready / sign
in") and tracks it under `settings["receipt_email_sent"]` — distinct from the
`welcome_email_sent` flag so the later plan welcome isn't suppressed. The
**plan-correct welcome** (`welcome_basic_email` / `welcome_pro_email`) ships
from `API::WebhooksController#handle_subscription_upsert` on the first
transition into `trialing` or `active`, via `User#send_plan_welcome_email_once!`.
That helper is idempotent per `plan_type` (recorded in
`settings["plan_welcome_sent_for"]`), so `subscription.updated` re-fires and
`trialing→active` for the same plan don't re-email, but a real plan change
(`basic → pro`) still re-welcomes. This is the only path that delivers the
Basic/Pro welcome to **web** subscribers. **Mobile IAP delivers the same
plan-correct welcome from `RevenueCat::WebhookProcessor#handle_purchase`** (also
via `send_plan_welcome_email_once!`), so the RC **webhook** is the source of
truth — a dropped `BillingController#update_subscription` client call no longer
strands a paying user without a welcome. That client endpoint also calls
`send_plan_welcome_email_once!` (was the non-idempotent `send_welcome_email`),
so the webhook + client paths can't double-email. The Mailchimp `welcome`
journey is still enqueued from `email_signup` today (Free-flavored copy) —
making the journey plan-aware is tracked as a follow-up.

**Stripe webhook idempotency gate.** `API::WebhooksController#webhooks` records
each handled event in `processed_webhook_events` (`provider: "stripe"`) and
short-circuits a replayed event id with `{ status: "already_processed" }` —
mirroring the RevenueCat processor. The record is written **only after a clean
run**, so a handler that raises still returns 4xx and lets Stripe retry. Credit
grants were already deduped on `stripe_event_id`; this extends idempotency to
the non-credit handlers (`apply_free_plan` on delete/pause, `past_due` on
`payment_failed`) so retries/dashboard replays don't pollute the credit ledger.

## PostHog server-side analytics

`PosthogService` (`app/models/posthog_service.rb`) captures the
**subscription lifecycle events that are only knowable server-side** (Stripe
webhooks), via the `posthog-ruby` gem. These complement the frontend's own
PostHog events (which fire intent + `checkout_started`); the backend completes
the money-path funnel (itty-bitty-frontend#307). Fired from
`API::WebhooksController`:

- **`checkout_completed`** `{ plan, kind, amount_total, currency, source }` —
  on `checkout.session.completed`, the **authoritative** purchase-completion
  event (fires even if the user never returns to the success page; the frontend
  adds a client-side echo separately). Subscription checkouts capture in
  `handle_checkout_completed` (`plan` from `paid_plan_type` — the plan picked at
  session create, since the subscription upsert may not have run yet;
  `kind: "subscription"`); topups capture in `handle_topup_completed` after the
  credit grant succeeds (`kind: "topup"`, `plan` = current `plan_type`). No
  event-id guard (matching the handler), so a Stripe webhook retry may
  re-capture — acceptable for analytics; the topup credit grant itself stays
  idempotent.
- **`trial_started`** `{ plan }` — `handle_trial_started_analytics`, on
  `customer.subscription.created` when `status == "trialing"`. PostHog-only —
  the internal `trial_started` AnalyticsEvent already fires at checkout, so we
  don't double-count.
- **`subscription_started`** `{ plan, billing_interval }` — in
  `handle_subscription_upsert`, on the non-active→active transition (alongside
  the existing `subscription_started` AnalyticsEvent). `billing_interval` is
  derived from the Stripe Price's `recurring.interval` (`month`→`monthly`,
  `year`→`yearly`) to match the frontend's `checkout_started` values.
- **`subscription_cancelled`** `{ plan, reason? }` — in
  `handle_subscription_deleted`, capturing the plan being left *before*
  `apply_free_plan` resets it; `reason` from Stripe's `cancellation_details`.
  Also records an internal `subscription_canceled` AnalyticsEvent for parity.

Key contracts:

- **`distinct_id = user.id.to_s`.** The frontend identifies people as
  `String(user.id)` (`posthog.identify`), so the backend must use the same id
  for events to land on the same person. `capture_for_user` enforces this.
- **Person `plan` stays in sync.** Every capture `$set`s the `plan` property
  (defaults to `user.plan_type`; cancellation explicitly `$set`s `plan: free`).
- **Env-gated, prod-only.** `PosthogClient.enabled?` (`config/initializers/
  posthog.rb`) returns true in production only (staging excluded via
  `AppEnv.staging?`); dev/staging fire only when `POSTHOG_CAPTURE_ENABLED=true`.
  Requires `POSTHOG_API_KEY`; `POSTHOG_HOST` defaults to
  `https://us.i.posthog.com`. Mirrors the Mailchimp-journeys gate.
- **Never breaks the webhook.** `capture_for_user` rescues and logs — a PostHog
  outage can't 500 a Stripe webhook. Captures are async (the SDK enqueues to its
  own background flush thread), so no Sidekiq job is needed.

## Subscription model

- Most features are free
- Premium features (Menu Board Creator, AI image generation) require active subscription
- Subscription managed via Stripe/RevenueCat — check status before allowing access to premium endpoints

### RevenueCat / Apple IAP path (parity with Stripe)

Native iOS/Android purchases go through RevenueCat, not Stripe. The path mirrors
the Stripe webhook semantics in `API::WebhooksController`. **RevenueCat's
`app_user_id` IS the Rails `user.id`** (the app configures Purchases with
`String(user.id)`), so webhook user lookup is `User.find_by(id:)`.

- **`update_subscription` is not client-trusted.** `POST /api/billing/update_subscription`
  verifies the entitlement against RevenueCat's REST API (`RevenueCat::Client#verified_plan_for`)
  before flipping `plan_type`; returns **403 `Subscription could not be verified`**
  on mismatch or when the REST key is unset. It sets `plan_type`/`plan_status`
  only — the webhook is the sole credit-grant authority (matches Stripe).
- **`POST /api/billing/webhooks`** (`RevenueCat::WebhookProcessor`): verifies a
  shared-secret `Authorization` header (`ENV["REVENUECAT_WEBHOOK_AUTH_HEADER"]`,
  401 on mismatch — RevenueCat uses a shared secret, not HMAC). Event map:
  `INITIAL_PURCHASE`/`NON_RENEWING_PURCHASE`/`RENEWAL`/`PRODUCT_CHANGE` →
  `CreditService.grant_plan!`; `EXPIRATION`/`SUBSCRIPTION_PAUSED` →
  `Billing::PlanTransitions.apply_free_plan`; `CANCELLATION` → analytics only,
  **no downgrade** (still entitled until expiry); `BILLING_ISSUE` →
  `plan_status="past_due"`, access kept; `UNCANCELLATION` → back to active;
  `TRANSFER` → downgrade losing ids, REST-re-verify gaining ids.
- **Trials (period_type).** A 14-day App Store free trial arrives as
  `INITIAL_PURCHASE` with `period_type=TRIAL` (`TRIAL_PERIOD_TYPES = TRIAL/INTRO`).
  `handle_purchase` then sets `plan_status="trialing"` (not `active`; `paid_plan?`
  treats both as paid, so gating is unaffected), persists `settings["trial_ends_at"]`
  (ISO8601, from `expiration_at_ms`), and fires **`trial_started`** analytics
  (internal `AnalyticsEvent` + PostHog — both, since IAP has no checkout to
  originate the internal one) **instead of** `subscription_started`.
  `subscription_started` fires on **conversion**: a normal-period `RENEWAL`/
  `PRODUCT_CHANGE` when the user was `trialing` (status → `active`,
  `trial_ends_at` cleared). An unconverted `EXPIRATION` of a `trialing` user tags
  its `subscription_canceled` analytics `reason: "trial_expired"` (vs
  `"expiration"` for paid churn). The client `update_subscription` call preserves
  an in-progress `trialing` status for the same plan so it can't clobber the
  trial the webhook recorded. **Trial-ending reminder:** Apple/RevenueCat send no
  `trial_will_end` webhook (unlike Stripe), so `RevenueCatTrialEndingJob` (daily,
  5am UTC) computes it from `settings["trial_ends_at"]` and enqueues the shared
  `MailchimpTrialWrapJob` ~`REVENUECAT_TRIAL_REMINDER_LEAD_DAYS` (default 3) out.
  Flags `settings["rc_trial_wrap_sent"]` (once per trial; re-armed when a new
  trial starts). Keying on `trial_ends_at` scopes it to RC trials — Stripe
  trialists never have it set, so they can't be double-nudged.
- **Idempotency + audit:** `processed_webhook_events` (unique `provider`+`event_id`)
  gates the whole handler (covers non-credit events); the credit grant also
  reuses `credit_transactions.stripe_event_id` with an `rc_<event_id>` token.
- **Sandbox gating:** SANDBOX events are ignored only in real production
  (`Rails.env.production? && !AppEnv.staging?`); honored in dev/test/staging.
- **Mapping:** `RevenueCat::PlanMapping` (entitlement/product → normalized
  `basic`/`pro`). Entitlement ids (`basic`/`pro`) are the primary signal; the
  store product id is a fallback (and the only source of `billing_interval`).
  `PRODUCT_TO_PLAN` keys are the **real reverse-DNS App Store ids** confirmed
  against the RevenueCat catalog (`com.speakanyway.{basic,pro}.{monthly,yearly}`),
  plus the legacy bare package names (`basic_monthly`, …) kept as a defensive
  fallback and a `com.test.basic.monthly` QA product. MySpeak products
  (`com.speakanyway.myspeak.*`) are intentionally **unmapped** (separate feature,
  not a plan tier). Confirm Google Play ids when that store goes live.
- **Timestamps differ by surface:** webhooks send epoch **ms**
  (`expiration_at_ms`); the v1 REST API sends ISO8601 strings.
- `Billing::PlanTransitions.apply_free_plan` is the shared downgrade path for
  both Stripe (`WebhooksController#apply_free_plan` delegates to it) and RevenueCat.

### Mission Control revenue metrics (Stripe + RevenueCat)

Admin Mission Control revenue is computed by `MissionControl::RevenueMetrics`
(`app/services/mission_control/`), which combines two sources and **no longer
reads the local `subscriptions` table** (that table is sparsely populated — the
webhooks write plan state onto the `User` row, not into `subscriptions`). Added
in PR #333 / issue #331.

- **`MissionControl::StripeRevenueSource`** — live `Stripe::Subscription.list`
  for **active + trialing** subs (paginated). Computes active-sub count, MRR
  (yearly normalized to monthly), and a plan breakdown from price metadata.
  Cached 10 min via `Rails.cache` (key `mission_control/stripe_revenue`).
  Rescues `Stripe::StripeError` gracefully (nil values + error message).
- **`MissionControl::RevenuecatRevenueSource`** — estimates App Store /
  RevenueCat subscriber revenue **from the local DB, not the RevenueCat API**:
  paid users (`basic`/`pro`, active/trialing, non-admin) with **no**
  `stripe_subscription_id`. MRR is estimated from `plan_type` +
  `settings["billing_interval"]` using ENV-tunable price fallbacks:
  `RC_ESTIMATED_BASIC_MONTHLY_CENTS` (499), `RC_ESTIMATED_PRO_MONTHLY_CENTS`
  (999), `RC_ESTIMATED_BASIC_YEARLY_CENTS` (4999), and
  `RC_ESTIMATED_PRO_YEARLY_CENTS` (9999). Excludes admins.
- **`MissionControl::RevenueMetrics`** — combines both: top-level
  `:active_subscriptions`, `:estimated_mrr_cents`, `:mrr_usd`, with per-source
  breakdowns nested under `:stripe` and `:revenuecat`; `revenue_source` is
  `"stripe+revenuecat"`. The admin Mission Control view shows the Stripe/App
  Store sub split, per-source plan breakdowns, and an error state.

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

### Email-only (passwordless) signup — paid-intent path

`POST /api/v1/users/email_signup` (itty-bitty-frontend#367): a paid-intent
visitor types just an email → passwordless account via
`User.invite!(skip_invitation: true)` → signed in (same `{ token, user }`
envelope as `sign_up`) → frontend proceeds to Stripe Checkout. Free/partner/
demo/myspeak signups keep using `sign_up`. Key invariants:

- **"Passwordless" = pending invitation, NOT blank `encrypted_password`.**
  devise_invitable assigns a random password inside `invite!`; what makes the
  account passwordless is that `valid_password?` returns nil while
  `invitation_token` is present. `user.api_view`'s `needs_password` flag is
  `invited_to_sign_up?` for this reason.
- **Setting the initial password must go through `accept_invitation!`** — a
  naive `update(password:)` on an invited user stores a password that can
  never sign in. Both `POST /api/v1/users/set_password` (new, 422
  `password_already_set` for non-invited users) and the legacy
  `POST /api/set-password` honor this.
- **Welcome-email magic link:** the raw invitation token must be passed as an
  explicit String argument down the
  `send_welcome_email(raw_invitation_token:)` → `UserMailer.welcome_*_email`
  chain — the virtual attr on User is nil after `deliver_later`'s GlobalID
  round-trip (this bug made the `/welcome/token/` link never render).
- **`customer.created` webhook** matches existing users by email before
  inviting, so it can't rotate a just-issued invitation token when the
  webhook races email_signup's `stripe_customer_id` save. It then **links**
  the customer (`update_columns(stripe_customer_id:)` when blank — never
  repoints an existing id; `update_columns` avoids touching the token), so the
  link is self-healing rather than depending on email_signup's separate save.
  The invite! fallback is race-safe: a unique-violation re-finds by email
  instead of duplicating.
- **`POST /api/stripe/update_user_from_session`** is a best-effort fast-path the
  frontend hits on the Stripe success redirect; the webhook stays the source of
  truth for plan + credits. It **only reflects a plan when the session actually
  completed** (`session.status == "complete"`) — an abandoned/expired session
  can't grant a paid tier without payment — and only the authenticated **owner**
  of the session may call it (403 otherwise). It reads the real subscription
  status (`trialing`/`active`) so a no-card trial isn't recorded as `active`
  (and can't clobber the webhook's `trialing`); it grants **no credits** (webhook
  authority).
- `email_signup` never sets `paid_plan_type` (checkout owns it) and skips
  Stripe-customer creation for `platform=ios/android`, like `sign_up`.
- **Billing portal for everyone:** `POST /api/subscriptions/billing_portal`
  lazily creates the Stripe customer via `User#ensure_stripe_customer!`
  (shared with checkout's `ensure_customer!`) and rescues `Stripe::StripeError`
  → 400 generic message. Requires a saved Customer-portal default config in
  the Stripe dashboard (test + live) — see `docs/stripe-setup.md` §4b.
  Optional `STRIPE_PORTAL_CONFIG_ID` pins a dedicated config.
- **Promo-aware plan switch for existing subscribers (#308):**
  `POST /api/subscriptions/change_plan_portal_session` (`plan_key` required,
  `promo_code` optional) lets a current subscriber switch plans with a promo
  pre-applied — the path free users get via a fresh Checkout session, which
  existing subscribers can't use (a new checkout on an active sub double-bills).
  It resolves `plan_key` via the shared `API::Stripe::CheckoutSessionsController::PLAN_PRICE_IDS`,
  looks up the active promotion code the same graceful way checkout does, finds
  the user's own active/trialing/past_due subscription, and opens a portal
  **deep link** (`flow_data.subscription_update_confirm`) pre-selecting the new
  price + discount. Stripe renders its own confirm page (price change +
  proration) — we never call `Stripe::Subscription.update` directly — and the
  resulting `customer.subscription.updated` webhook applies entitlements exactly
  like a manual portal switch (`Price.metadata["plan_type"]` → `handle_subscription_upsert`).
  422 when there's no active subscription (those users belong in checkout) or an
  unknown/`free` plan; 400 generic on Stripe error; honors `STRIPE_PORTAL_CONFIG_ID`.
  The Stripe portal config must permit subscription updates for the relevant
  products for the flow to render. Frontend CTA wiring is a separate PR
  (itty-bitty-frontend#369 keeps the portal fallback until it lands).

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
- "Over their board limit" is computed by `User#countable_board_count` (own,
  non-predefined, non-`builder_child` boards) vs `User#board_limit`. This is the
  **single source of truth** for board counting — `User#at_board_limit?` wraps
  it (admins never limited), and every creation gate (create, clone,
  `create_from_template`, `import_obf`, menus, generated-board claim,
  Board Builder) plus the `can_create_boards` api_view flag and this read-only
  rule all route through it. Board Builder sub-boards are excluded so a built
  tree counts as one (see the Board Builder section).
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
- **`image_generation` is free for first-time fills.** `API::ImagesController#generate`
  (`POST /api/images/generate`) only calls `check_credits!` when the image **already
  has a displayable picture** for the user (`Image#display_image_url(user).present?` —
  the same "is there a doc to set?" notion as `Board#find_or_create_images_from_word_list`).
  Generating an image for an empty tile/label (no doc yet) still enqueues
  `GenerateImageJob` but is **not billed** — we don't charge users to build the shared
  image library. Charging only applies when they're replacing/customizing an existing
  image. `regenerate_images`, `create_image_edit`, and `create_image_variation` act on
  images that already have a picture, so they keep charging unconditionally.
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
  3am UTC) re-grants the tier allowance to users whose
  `plan_credits_reset_at` has passed and who are **either** without a
  `stripe_subscription_id` (free/basic_trial, App Store/RevenueCat
  subscribers, admin/demo accounts on paid tiers) **or** on a **yearly**
  Stripe sub (`settings["billing_interval"] == "yearly"`). It grants the
  user's actual plan_type allowance (e.g. Pro = 1500). **Monthly** Stripe
  payers refresh through `invoice.payment_succeeded` instead, so they're
  excluded. Class name kept for cron stability; scope is broader than the
  name suggests.
- **Monthly bucket, any billing cadence:** plan credits are a monthly
  allowance, so `grant_plan!` caps `period_end` at
  `MAX_GRANT_WINDOW` (35 days). Without this, a **yearly** subscriber's
  grant would set `plan_credits_reset_at` a year out and they'd get one
  month's credits stretched across the year. The cap pulls the reset back
  to ~1 month; the monthly re-grant then comes from
  `invoice.payment_succeeded` (monthly Stripe), the RevenueCat `RENEWAL`
  webhook, or `RefreshFreeTierCreditsJob` (yearly Stripe + all RevenueCat).
  Monthly subs (period ≤ 35d) are never capped. `billing_interval` is
  persisted on `users.settings` by both the Stripe upsert and the
  RevenueCat purchase handler.
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

## Beta-end entitlement audit

- `bin/rails beta:audit_entitlements` — **read-only** sweep comparing every
  user's persisted `settings` limits (`board_limit`, effective communicator
  slot limit, `ai_monthly_limit`) and actual usage (`countable_board_count`,
  owned loaner+active communicators) against the entitlement for their
  `plan_type` (the `FREE/BASIC/PRO_PLAN_LIMITS` hashes). Prints summary counts
  and writes flagged users to `tmp/beta_audit_<date>.csv` (path overridable
  via `BETA_AUDIT_CSV`). Admin/partner accounts are listed but marked
  `exempt`. Closes the gap where beta-era users kept Pro-level `settings`
  while `plan_type` stayed `free` (enforcement reads `settings`; the
  reconcile callback only fires on `plan_type` change). Phase 2 — a
  reconciliation task (`beta:end_beta`) — gets built only if this audit
  finds over-entitled users. See
  `.claude-notes/beta-end-founding-rate-handoff.md`.

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

## Board Sets (BoardGroup) — user CRUD + limits

Board Sets (`BoardGroup`, user-facing name "Board Sets") are user-owned
collections of boards. CRUD is open to any signed-in user;
`predefined: true` sets stay admin-curated. Viewing is **public by link** —
`index`, `show`, `show_by_slug`, and `preset` keep
`skip_before_action :authenticate_token!`.

- **Owner-or-admin authorization.** Every mutating action in
  `API::BoardGroupsController` (`update`, `destroy`, `rearrange_boards`,
  `save_layout`, `remove_board`, `add_board`) routes through the private
  `authorize_board_group!` helper: admins always pass; everyone else is
  blocked (**HTTP 403** `"You don't have permission to modify this board
  set."`) unless they own the set *and* it isn't `predefined`. Before this
  work, `rearrange_boards`/`save_layout`/`remove_board` had **no** auth at all
  — any user could mutate anyone's set. `create` is open to all authed users.
- **Protected flags.** `board_group_params` strips `predefined` and `featured`
  for non-admins, so a regular user can't self-promote their set into the
  curated/featured pools.
- **Per-plan creation limits.** Mirrors the board-limit pattern.
  `User#board_group_limit` resolves from the plan hash by `plan_type` (Free 1,
  Basic 25, Pro 50; ENV-overridable via `FREE_/BASIC_/PRO_BOARD_GROUP_LIMIT`),
  with a `settings["board_group_limit"]` override. `User#countable_board_group_count`
  counts own non-predefined sets; `User#at_board_group_limit?` is the gate
  (admins exempt). `create` returns **HTTP 422** `{ error, limit, count }` at
  the cap. **Not 402** — 402 is reserved for credit exhaustion.
- **`add_board` route.** `POST /api/board_groups/:id/add_board/:board_id`
  (`BoardGroup#add_board` does the join + layout init). Beyond the owner-or-admin
  set check, the *board* must belong to the caller or be predefined/public.

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

- `GET /api/v1/board_builder/templates` — label-only picker catalog. Accepts an
  optional `communicator_id` (scoped to `current_user.communicator_accounts`);
  when that communicator has a usable stored profile, the response includes
  `recommended_template` (Core 60's slug for young/emerging, else Core 84's —
  only if that set is seeded here) and a `recommendation_reason` string. No
  profile → both `null`.
- `POST /api/v1/board_builder` `{ communicator_id, template, interests }` —
  ownership check (**404 `communicator_not_found`** for a communicator not in
  `current_user.communicator_accounts`), assemble → build → persist normalized
  interests to `child_account.details["interests"]` (jsonb merge), return the
  favorited root board's `api_view` (**201**). **422 `unknown_template`** /
  **422 `build_failed`** (the build is transactional — failure rolls back, no
  orphans). The frontend page ships separately in `itty-bitty-frontend`.
  - **Board-limit gated, but a tree counts as ONE board.** `create` returns
    **422 "Maximum number of boards reached"** when `current_user.at_board_limit?`
    (see the board-limit section below). Because one wizard run persists a whole
    linked tree, `BoardTreeBuilder` marks every sub-board (depth > 0)
    `settings["builder_child"] = true`, and `User#countable_board_count` excludes
    them — so the tree counts as its single root, not ~5. This also keeps the
    whole built set editable (the read-only lock keys off the same count).
  - **Re-run guard (issue #269): detect + warn, never silently dupe.** If the
    communicator already has a builder set, `create` returns **409
    `board_builder_set_exists`** (`{ existing_root_id, existing_root_name,
    built_at }`) instead of stacking a second favorited root; the client
    re-sends with **`confirm=true`** to build another. Detection is
    `ChildAccount#board_builder_root` — each root is marked
    `settings["builder_root"] = true` by `BoardTreeBuilder` (counterpart to
    `builder_child`; does **not** affect the board-limit count). It's
    deletion-safe: delete the set and a re-run is a fresh build. The 409 check
    runs *after* the board-limit gate, so a Free user at their limit gets the
    422 first.

### Robust vocabulary sets (Core 60 / Core 84)

A second template **kind** beside the label-only starter trees: pre-authored
core vocabulary sets, **authored as OBF/OBZ** and seeded as admin-owned
predefined boards, then **deep-cloned per user** on build (so authored grid
layout + `part_of_speech` colors survive). Reuses `ObzImporter` (seed) and
`Board#clone_with_images` (build). SpeakAnyWay content only.

- **Seed:** `bin/rails vocab_sets:seed` (logic in the `VocabSets` service)
  zips the editable OBF-JSON under `db/seeds/board_builder_sets/<slug>/` and
  imports it via `ObzImporter` as `User::DEFAULT_ADMIN_ID` with
  **`board_group: nil`**. **No `BoardGroup`** — a set is identified by a marker
  on its **root board** (`settings["board_builder_robust_slug"]`), queried via
  `Boards::RobustSets`. Idempotent (`Board.from_obf` upserts by
  `(user_id, obf_id)`). Format spec: `db/seeds/board_builder_sets/README.md`.
  Slugs `core-60` (ships a placeholder), `core-84` (TBD).
- **Build:** `#create` branches on `Boards::RobustSets.find_root(template)`.
  A match runs `Boards::SeededSetCloner` (walks the linked set to depth 2,
  clones each board, **rewires** `predictive_board_id` to the clones, marks
  root `builder_root` / rest `builder_child`, favorites the root ChildBoard,
  routes interests into the cloned fringe pages / "My Favorites"). Same
  synchronous **201** response and the **same** limit (422) and re-run (409)
  guards as the starter path — counts as ONE board.
- `GET /board_builder/templates` entries now carry `kind: "starter" | "robust"`.
- v1 is **synchronous** (DB-bound work; previews/audio/AI art already async).
  If a finalized set is materially larger than the placeholder, move the clone
  to a background job + "building" state — see `.claude-notes/board-builder.md`.

### Stored communicator profile (AAC personalization)

`aac_level` / `vocab_type` / `age_band` live in **`child_accounts.details`**
(jsonb, same pattern as `details["interests"]` — no columns). `ChildAccount`
defines typed accessors over them, normalizes (downcase/strip, blank clears the
key), and validates against `CommunicatorProfile::AAC_LEVELS / VOCAB_TYPES /
AGE_BANDS` on every save — including the wholesale `details=` assignment in the
communicator update controller. Exposed top-level (next to `details`) in the
ChildAccount `api_view` / `vendor_api_view`.

`CommunicatorProfile.for(params:, communicator:)` is the merge constructor:
explicit request params override stored fields **field by field**; returns nil
when both sources are empty (no profile = unchanged behavior). Consumers:
`boards#words`, `boards#additional_words`, and `GenerateBoardJob` all accept an
optional `communicator_id` — always resolved via
`current_user.communicator_accounts` (controller-side for the job; the id in
job options is pre-validated), never a bare `ChildAccount.find`. An id the
caller doesn't own is silently ignored. Personalization reaches **AI
word-suggestion prompts and the template recommendation only** — the Board
Builder's deterministic build path is unchanged.

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
- New features and bug fixes always get tests (per `~/.claude/CLAUDE.md`). Don't backfill tests for _existing_ code unless asked.
- Rails test environment uses `:null_store` for Rails.cache — stub `Rails.cache` in specs that depend on caching behavior
- Avoid `travel_to` with past timestamps for Redis keys (TTLs expire immediately); use future times or freeze time instead
- After spec changes, run the tests that depend on the changed code to ensure no regressions. Use `bin/rspec --only-failures` to rerun only failed specs.

## Rules for Editing This File

When reviewing or rewriting CLAUDE.md, ALWAYS verify claims against the actual codebase first: read Gemfile/package.json, config files, routes, and a sampling of controllers/models. Never fabricate framework claims (e.g., 'API-only', 'FedRAMP-aware') or invent dependencies. If unsure, state 'unverified' rather than asserting.

## Bash & Long-Running Commands

When running long bash commands (bundle update, migrations, test suites), use appropriate timeouts and check completion status explicitly rather than polling repeatedly.
