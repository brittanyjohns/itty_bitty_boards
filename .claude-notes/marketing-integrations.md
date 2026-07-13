# Marketing integrations — Mailchimp + PostHog (server-side)

> Extracted from CLAUDE.md on 2026-07-11 (hub-and-spoke restructure).
> This file is the authoritative doc for this subsystem — update it (not CLAUDE.md)
> when behavior changes. CLAUDE.md keeps only the cross-cutting invariants.

## Mailchimp integration

We use the Mailchimp **Marketing API** (`MailchimpMarketing` gem, official
GitHub build). Two distinct uses:

- **CRM sync (existing):** `MailchimpService` upserts contacts
  (`record_new_subscriber`), tags by plan tier, and records sign-in/sign-up
  events. Fired async via `MailchimpEventJob` (event types `sign_up` /
  `sign_in`) from `API::V1::AuthsController` and the Stripe checkout controller.
  **Tags apply to existing contacts too:** `record_new_subscriber` early-returns
  when the contact is already in the audience, but it applies the passed tags
  first — this is what lets a tag-triggered journey (e.g. the Partner journey's
  "Partner Program" trigger tag) fire for users who were synced at signup and
  promoted later. Don't reintroduce a pre-tag early return.
- **Customer Journey triggers (email):** `MailchimpService#trigger_journey`
  enrols a contact into a journey's **API-trigger step** so Mailchimp sends the
  email designed in that journey. The accessor is resolved via
  `MailchimpService#customer_journeys_api`: the gem exposes it as camelCase
  `customerJourneys` (there is **no** snake_case `customer_journeys` alias
  today), so the helper prefers camelCase and falls back to snake_case only if a
  future gem adds it — never calling a method the client lacks. A `NoMethodError`
  from the trigger (the historical snake_case bug that flooded the Sidekiq dead
  set) is **caught, logged, and swallowed** so `MailchimpEventJob` doesn't
  exhaust its retries into Dead. The contact is upserted-and-retried-once if
  Mailchimp 404s.
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
    - `subscription_started` — enqueued from
      `API::WebhooksController#handle_subscription_upsert` on the non-active→active
      transition (the same Stripe seam as the `subscription_started`
      AnalyticsEvent/PostHog events). The paid-tier onboarding nurture — the
      **marketing counterpart** to the transactional plan welcome
      (`send_plan_welcome_email_once!`), mirroring the Free dual-welcome (#293).
      The transition guard (`previous_status != "active"`) makes it fire **once
      per conversion** (renewals don't re-fire), so no dedupe is needed.
      **Apple/IAP parity:** `RevenueCat::WebhookProcessor#fire_subscription_started`
      (the single conversion seam — paid start or trial→paid) enqueues the same
      journey, so mobile subscribers get it too. The webhook's event-idempotency
      gate prevents double-sends.
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

`PosthogService` (`app/models/posthog_service.rb`) captures events that must
be reliable regardless of whether the frontend JS SDK loads (ad blockers, JS
errors, etc.), via the `posthog-ruby` gem. These complement the frontend's own
PostHog events; the backend ensures the full funnel is always captured
(itty-bitty-frontend#307).

**Auth events** — fired from `API::V1::AuthsController`:

- **`user_signed_up`** `{ signup_method, plan_type, platform }` — on successful
  `sign_up` (`signup_method: "standard"`) or `email_signup`
  (`signup_method: "email_only"`). `platform` is `"web"`, `"ios"`, or
  `"android"`. Ensures signups are tracked even when the frontend PostHog JS is
  blocked by ad blockers.
- **`user_signed_in`** `{ plan_type }` — on successful password login
  (`#create`). Same ad-blocker-resilience rationale.

**Subscription lifecycle events** — fired from `API::WebhooksController`
(unless noted):

- **`checkout_started`** `{ plan, billing_interval, kind, source }` (subscription)
  / `{ plan, kind, pack_key, source }` (topup) — fired from
  `API::Stripe::CheckoutSessionsController#create` / `#topup` when a Stripe
  Checkout Session is **created** (itty_bitty_boards#452 / frontend #505). The
  frontend fires this too, but it's routinely dropped when the page unloads to
  Stripe before PostHog's batch flushes — so this server-side capture is the
  reliable one; the client event stays a best-effort earlier signal. `plan` is
  the base tier (`pro_yearly` → `pro`) with a separate `billing_interval` to
  match the frontend + `subscription_started` shape; `kind` is `"subscription"`
  or `"topup"` (mirroring `checkout_completed`); `source` is the CTA/page the
  frontend threads through (`params[:source]`, default `"web_checkout"`). Both
  checkout paths also set the Session's `client_reference_id = user.id` and add
  `source` to metadata so Stripe-originated events attribute to the same person.
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

