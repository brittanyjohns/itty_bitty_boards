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
  Mailchimp says it isn't in the audience.
  Wired through the `MailchimpEventJob` `"journey"` event type, which takes a
  `journey_key`.

  - **A journey can only be triggered for a contact that already exists, and at
    signup it usually doesn't yet.** The signup actions enqueue the audience
    upsert (`"sign_up"`) and the journey trigger as sibling Sidekiq jobs, so they
    race. Mailchimp reports the miss as a **400** (`"This request can only be
    made with existing emails in the audience"`), *not* a 404 —
    `MailchimpService#contact_missing?` treats both as the same condition, and
    `trigger_journey` upserts and retries once. The retry fires **regardless of
    what the upsert returns**: when the sibling job wins the race our upsert
    comes back `Member Exists` (nil), but the contact exists and the retry
    succeeds. Retrying only on 404 silently dropped the welcome email for
    essentially every new signup. Signup actions enqueue `"sign_up"` before the
    journey as belt-and-braces; enqueue order is not a guarantee.

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
      at 4am UTC) for non-admin users who signed up between
      `FIRST_BOARD_NUDGE_MIN_AGE_HOURS` (48) and `FIRST_BOARD_NUDGE_MAX_AGE_DAYS`
      (14 days) ago with no boards, capped at `FIRST_BOARD_NUDGE_MAX_PER_RUN`
      (100) per run. **The window is a catch-up sweep, not a one-day band, and
      once-only delivery comes from the `first_board_nudge_sent` flag — never
      from the window's narrowness.** The original 72h..48h band gave each user
      a single day of eligibility, so two missed runs aged that day's cohort
      out permanently with nothing sweeping for them afterwards. Don't narrow
      it back; the flag is what prevents a second send.
    - `legacy_signup_nudge` — enqueued by `MailchimpLegacySignupNudgeJob`
      (monthly, 5am UTC on the 1st) re-engaging cold legacy signups: non-admin
      users created over `LEGACY_SIGNUP_NUDGE_AGE_DAYS` (default 30) ago, no
      boards, no sign-in within `LEGACY_SIGNUP_NUDGE_INACTIVE_DAYS` (default 30).
      The `user.settings["legacy_signup_nudge_sent"]` flag makes it once-only.
      **Capped at `LEGACY_SIGNUP_NUDGE_MAX_PER_RUN` (default 100) sends per
      run** — it's the only nudge whose window has no upper bound, so an
      uncapped run could email every cold account ever in one burst (spam
      complaints → sending-domain reputation → transactional mail). The flag
      makes the backlog resumable, so the cap just spreads it across monthly
      runs; `0` disables it deliberately.
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
    - `partner_pilot_wrap` — the **partner** variant of `trial_wrap`. Same
      `MailchimpTrialWrapJob`, same `trial_will_end` seam, same merge fields —
      but when `user.partner_pro?` the job triggers this key instead, so
      partners get pilot-specific copy (names the $10/mo Partner Pro rate, offers
      "reply to re-up your partner program" alongside "add a card to continue")
      rather than the generic reverse-trial nudge. Wire
      `MAILCHIMP_JOURNEY_PARTNER_PILOT_WRAP_ID` / `_STEP`; unset = no-op (partners
      simply get no wrap email until the journey is built).
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
  - **No two journey emails to the same person inside
    `MAILCHIMP_JOURNEY_MIN_GAP_HOURS` (default 4).** Enforced in
    `MailchimpEventJob`'s `"journey"` branch — the single seam every trigger
    passes through — because the triggering seams are independent and routinely
    coincide (`email_signup` fires `welcome`, then the Stripe webhook fires
    `subscription_started` minutes later; the nudge crons run 04:00 and 04:30).
    A throttled trigger is **re-enqueued with jitter, not dropped**, so the
    email still arrives; after `MAX_DEFERS` (3) attempts it's abandoned with a
    warn rather than deferred forever. The quiet period starts only on a
    trigger that actually reached Mailchimp — a failed one must not suppress
    the next journey. Backed by `Rails.cache` (Redis, fail-open: a blip means
    sending on time, never swallowing the email), so specs need a real store
    stubbed in — `:null_store` can't see its own writes.
  - **Two rules every nudge cron (`first_board_nudge`, `legacy_signup_nudge`,
    `win_back`) must follow:**
    1. **Scope with `User.non_admin`, never `where.not(role: "admin")`.**
       `users.role` is nullable and the password-signup path never sets it (only
       `User.create_from_email` does), so a plain `!=` is NULL-false and drops
       the majority of real users. That bug ran the first-board nudge and
       win-back at literally 0 users/day for months without erroring. Specs
       don't catch it on their own — the `:user` factory hardcodes
       `role { "user" }`, so any new nudge job needs an explicit `role: nil`
       case.
    2. **Check `MailchimpClient.journey_deliverable?(key)` before flagging.**
       The per-user `settings["..._sent"]` flags are permanent, so flagging
       while the journey's ENV pair is missing (or journeys are off for the env)
       burns the entire backlog — those users can never be nudged again. The
       jobs return early, unflagged, when the journey can't be delivered.
       Repair a burned backlog with `mailchimp:nudge_flags:report` (counts per
       flag + whether each journey is deliverable) and
       `mailchimp:nudge_flags:clear[<flag>]` (dry-run by default, `DRY_RUN=false`
       to apply, `EMAIL=` to scope). Clearing removes the key rather than
       setting it false. Trial-reminder flags are deliberately out of scope —
       they're keyed to a specific trial, so re-clearing one emails "your trial
       is ending" to someone whose trial already ended.
  - **Env-gated to avoid emailing real users from non-prod.**
    `MailchimpClient.journeys_enabled?` returns true in production (and only
    production — staging is excluded via `AppEnv.staging?`); dev/staging fire
    only when `MAILCHIMP_JOURNEYS_ENABLED=true`. CRM sync is **not** gated.
  - **Demo/internal accounts get no journey email.** `MailchimpEventJob`'s
    `"journey"` branch — the single choke point every journey trigger passes
    through — returns early for `user.demo_user?`, so demo traffic can't pull
    real campaign sends or skew a journey's open/click stats.
    **`demo_user?` is not email patterns alone.** Patterns
    (`User::DEMO_EMAIL_PATTERNS`, extensible without a deploy via the
    `DEMO_EMAIL_PATTERNS` ENV) miss most real test accounts — a July 2026
    testing session produced `speakanyway@gmail.com`, `testaria@gmail.com`,
    `speak@test.com` and a dozen more, none matching `@speakanyway.com`, and
    they were about to consume journey sends and hard-bounce. So there is also
    an explicit `settings["internal_account"]` marker, set with
    `users:internal:mark[<ids-or-emails>]` (`:unmark` reverses, `:list` shows
    everything currently treated as internal). **Prefer marking to widening the
    patterns** — a pattern broad enough to catch `arias@gmail.com` will
    eventually catch a paying customer.
    `User.demo_accounts` (the SQL scope behind admin/Mission Control metrics)
    and `demo_user?` (the send gate) derive from the same patterns + flag and
    **must stay in agreement**, or the dashboards and the emails disagree about
    who is real. The scope's columns are table-qualified because Mission
    Control joins `boards`, which has its own `settings` column.
    The #297 guards were reverted on 2026-06-10
    to allow end-to-end testing and reinstated at this single seam instead;
    **set `MAILCHIMP_JOURNEYS_ALLOW_DEMO=true` to test with a demo account
    rather than removing the guard again.** CRM sync is deliberately NOT gated
    — demo contacts stay in the audience, tagged via the `DEMO_USER` merge
    field.

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

**Anonymous lead capture → Mailchimp tags.** `POST /api/download_leads`
(public, no auth) creates a `DownloadLead` from a bare email and enqueues
`MailchimpUpsertLeadJob`, which upserts the contact via
`MailchimpService#record_lead` and tags it. There are two tagging paths, both
in `MailchimpUpsertLeadJob#tags_for`:

- **Hardcoded funnels** — `SOURCE_TAGS`, keyed on the lead's free-form `source`
  string (`"classroom_kit"` → `ClassroomKitLead`, `"ctg"` → `ctg-2026`,
  `"playground_nomination"` → `PlaygroundNomination`). One tag each.
- **`/kit/:slug` landing pages** — a `kit_<slug>` source resolves its tag off the
  `KitPage` row via `KitPage#resolved_mailchimp_tag` (the admin-set
  `mailchimp_tag` column, else one derived from the slug: `at-school` →
  `AtSchoolLead`). **This is why a new landing page needs no deploy.** Kit leads
  get a *second*, shared tag — `KIT_UMBRELLA_TAG` (`KitLead`) — so "has ever
  downloaded a kit" is one durable segment instead of an ever-growing list of
  per-page tags. The umbrella is keyed on the `kit_` source prefix, not on the
  page lookup succeeding, so a lead whose page was later deleted still counts.

Anything unmatched falls back to `DEFAULT_LEAD_TAG`. `source` is not validated
against a whitelist — a typo'd source degrades to the default tag rather than
erroring. Campaign UTMs ride along in the lead's `data` jsonb.

**Derived tags are not brand-safe.** `resolved_mailchimp_tag` camelizes the
slug, so `speakanyway-core-2026` becomes `SpeakanywayCore2026Lead` — which
violates the SpeakAnyWay capitalization rule. Set `mailchimp_tag` explicitly in
the admin for any page whose slug contains the brand name. Setting it explicitly
is worth doing regardless: the derived tag is a function of the slug, so renaming
a slug silently splits the segment (old contacts keep the old tag, new ones get
a new one, and nothing errors).

**`record_lead` only ever sends `EMAIL` + `FNAME`**, so every required merge
field on the audience is a silent break: a permanent 4xx marks the lead
`failed` and is deliberately *not* re-raised (it would fail identically on
every retry), so a misconfigured audience kills capture without surfacing an
exception. Before launching a capture funnel, confirm the audience has no
required merge fields beyond EMAIL — the production audience requires none,
and `ADDRESS` is present but optional.

**Audience IDs — don't confuse these.** The audience is read at call time from
`ENV["MAILCHIMP_AUDIENCE_ID"]`, which differs per environment:

| List ID | Name | Where it's used |
|---|---|---|
| `8ed478c93c` | SpeakAnyWay AAC Users - Production | **Production.** Also the default in `marketing/tools/mailchimp-api.py`. |
| `b7456c33f9` | Development Users | Local dev — this is what checked-in `config/application.yml` points at. |
| `602195e1ab` | SpeakAnyWay AAC | Legacy, no longer written to. |

An earlier revision of this file named `b7456c33f9` as the production audience.
That was wrong — it is the dev list, read out of local `application.yml`.
Verified 2026-08-27 against the Mailchimp API: the lead tags (`ClassroomKitLead`,
`PlaygroundNomination`, `BoardDownloadLead`, and the derived kit-page tags) all
live in `8ed478c93c`.

## PostHog server-side analytics

`PosthogService` (`app/models/posthog_service.rb`) captures events that must
be reliable regardless of whether the frontend JS SDK loads (ad blockers, JS
errors, etc.), via the `posthog-ruby` gem. These complement the frontend's own
PostHog events; the backend ensures the full funnel is always captured
(itty-bitty-frontend#307).

**Auth events** — fired from `API::V1::AuthsController`:

- **`user_signed_up`** `{ signup_method, plan_type, platform, signup_ref }` — on
  successful `sign_up` (`signup_method: "standard"`) or `email_signup`
  (`signup_method: "email_only"`). `platform` is `"web"`, `"ios"`, or
  `"android"`. `signup_ref` is the sanitized `?ref=` attribution and is `nil`
  for unattributed signups. Ensures signups are tracked even when the frontend
  PostHog JS is blocked by ad blockers.
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

**Communicator + page funnel events** — `Analytics::CommunicatorEvents`
(`app/models/analytics/communicator_events.rb`), a thin wrapper over
`capture_for_user` so both creation routes stay one-liners and the event names
live in one place. Every one of these is server-side *because* the frontend SDK
is consent-gated (`opt_out_capturing_by_default` + `person_profiles:
"identified_only"`, #312): a user who never accepts the cookie banner produces
no frontend events at all, and that is exactly the user who then emails support
about a limit they hit (#766).

- **`communicator_slot_limit_reached`** `{ status, limit, count, source }` —
  when `Permissions::CommunicatorLimits.can_create?` refuses, at both
  `API::ChildAccountsController#create` (`source: "child_accounts"`) and
  `API::V1::Onboarding::MyspeakController#create`
  (`source: "myspeak_onboarding"`). `limit`/`count` come from
  `CommunicatorLimits.usage_for`, which exists only for this event —
  `can_create?` returns a message, so without the numbers the event can't tell
  "plan has no slots" from "all slots full". It costs a count query, so it runs
  on the **refusal path only**.
- **`communicator_account_created`** `{ status, communicator_id, source }` — on
  every successful create, from both routes. `source` is the whole point: the
  MySpeak wizard creates its communicator entirely server-side and never touches
  the frontend form component the legacy `communicator account created` event
  lives in, so onboarding-created communicators were silently uncounted. The
  legacy spaced name is retired in itty-bitty-frontend#750; the two names are
  distinct in PostHog, so they can't double-count against each other while both
  exist.
- **`myspeak_page_created`** `{ profile_id, communicator_id, source }` — when a
  create **mints** the communicator's Profile. Deliberately not fired when a
  `profile_id` hand-off links an existing page — that's a claim, not a new page.
- **`public_page_created`** `{ profile_id }` / **`public_page_create_blocked`**
  `{ reason }` — `API::ProfilesController#create`. The user-level Public page is
  a different product from a communicator's MySpeak page; the block is the 409
  `public_page_exists` state conflict.

Key contracts:

- **`distinct_id = user.id.to_s`.** The frontend identifies people as
  `String(user.id)` (`posthog.identify`), so the backend must use the same id
  for events to land on the same person. `capture_for_user` enforces this.
- **Person identity stays in sync, and an explicit `set:` MERGES over it.**
  Every capture `$set`s `plan` + `email` + `name` (`default_person_props`).
  Email/name are there so a support request can be joined to PostHog activity —
  for a non-consenting user the server-side capture is the *only* thing that
  ever reaches the person record, so without them it's an unlabelled id. A
  caller correcting one property (cancellation's `set: { plan: "free" }`) merges
  over the defaults rather than replacing them, so it can't silently drop the
  identity half.
- **`$geoip_disable: true` on every server-side capture.** posthog-ruby sends
  the *app server's* IP, so without this every backend event geo-resolves to the
  EC2 box's city and overwrites the person's real location with it. Geo comes
  from the frontend SDK or from nowhere.
- **Env-gated, prod-only.** `PosthogClient.enabled?` (`config/initializers/
  posthog.rb`) returns true in production only (staging excluded via
  `AppEnv.staging?`); dev/staging fire only when `POSTHOG_CAPTURE_ENABLED=true`.
  Requires `POSTHOG_API_KEY`; `POSTHOG_HOST` defaults to
  `https://us.i.posthog.com`. Mirrors the Mailchimp-journeys gate.
- **Never breaks the webhook.** `capture_for_user` rescues and logs — a PostHog
  outage can't 500 a Stripe webhook. Captures are async (the SDK enqueues to its
  own background flush thread), so no Sidekiq job is needed.

