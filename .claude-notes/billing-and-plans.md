# Billing, plans, and entitlements

> Extracted from CLAUDE.md on 2026-07-11 (hub-and-spoke restructure).
> This file is the authoritative doc for this subsystem — update it (not CLAUDE.md)
> when behavior changes. CLAUDE.md keeps only the cross-cutting invariants.

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

**Promo checkouts skip the trial (`apply_trial = promo.blank?`).** When a
promotion code is applied (`params[:promo_code]`, or the auto-applied
`partner_pro` pilot code), `#create` omits `subscription_data` entirely — the
user subscribes at the discounted rate now (a card is collected if there's an
amount due). This is required for correctness: a promotion code with a
minimum-amount restriction — e.g. the **FOUNDING** coupon's `$50` floor, the
mechanism gating it to the yearly plans — is validated against the Checkout
Session's amount, and the 14-day trial zeroes that to `$0`, so Stripe rejects
the code with *"This promotion code cannot be redeemed because the associated
purchase does not meet the minimum amount requirement"* (prod 400s on the beta-
end Founding Family launch, 2026-07-07). Without the trial the checkout carries
the plan's real price (yearly `$80`/`$200` ≥ `$50`) and the discount applies.
The `trial_started` AnalyticsEvent is likewise gated on `apply_trial`, so promo
conversions don't pollute the trial→paid metric. Non-promo checkouts are
unchanged (full no-card reverse trial).

### Partner Program (`partner_pro`)

The `/sign-up/partner` flow (frontend `viewType="partner"`) posts to the normal
`POST /api/v1/users` with `plan_type=partner_pro`. `API::V1::AuthsController#sign_up`
then sets `plan_type=partner_pro`, `plan_status=active`, `role=partner`, and calls
`User.handle_new_partner_pro_subscription`, which sets
`plan_expires_at = now + PARTNER_PILOT_TRIAL_MONTHS.months` (3, ENV-overridable;
only if nil), tags Mailchimp, and sends `PartnerMailer.welcome_email` (the free
welcome + welcome journey are skipped). Entitlements equal Pro
(`setup_partner_pro_plan` → 300 boards / 5 communicators / 1500 credits).

**A real no-card Stripe trial backs the pilot (Phase 2, built).**
`handle_new_partner_pro_subscription` calls
`user.ensure_partner_pro_trial_subscription!(trial_end:)`, which creates a
`Stripe::Subscription` on the **Partner Pro price** (`STRIPE_PRICE_PARTNER_PRO`,
$10/mo, `metadata.plan_type=partner_pro`) with `trial_end = plan_expires_at`,
`trial_settings.end_behavior.missing_payment_method: "cancel"`, and no card
collected. This reuses the #264 reverse-trial machinery: the subscription rides
`trialing` for 3 months, fires `trial_will_end` ~3 days out, and — if no card is
ever added — cancels cleanly at the end → `customer.subscription.deleted` →
`apply_free_plan` → **Free (content retained via fallback mode)**. Because the
price metadata is `partner_pro`, the `handle_subscription_upsert` webhook keeps
the user on `partner_pro` (not plain `pro`) and grants the 1500 allowance.
Creation is **fail-soft**: a Stripe error is logged and swallowed so signup
never 500s — the synchronous local grant (below) still provisions the partner,
and the subscription can be backfilled later. `partner_pro` is in
`RefreshFreeTierCreditsJob`'s refreshable set, so credits re-grant monthly.

To avoid a double welcome, onboarding pre-seeds
`settings["plan_welcome_sent_for"] = ["partner_pro"]` so the subscription
webhook's `send_plan_welcome_email_once!` is a no-op (partners get
`PartnerMailer.welcome_email`, not the generic Pro welcome).

**Partner Pro is Pro-equivalent everywhere — `User#pro?` returns true for it.**
`pro?` is `%w[pro pro_yearly partner_pro].include?(plan_type)`, so a partner is
treated as Pro by `paid_plan?`, `partner_pro?` (`pro? && role == "partner"`),
`supporter_limit` (5), the lending gate (`require_pro_for_lending!`), and the
api_view `pro` flag. Before this, `pro?` was the exact string `"pro"`, so
partners silently fell through to Free-level treatment on those checks (and
`partner_pro?` was always false). Limits already came from `setup_partner_pro_plan`
/ `board_group_limit` (both mirror `PRO_PLAN_LIMITS`); this fixes the boolean
permission gates to match.

**Credits are granted at signup, synchronously — not by cron.** The
`after_create :grant_initial_plan_credits` hook runs while the account is still
`free` (it's created before the controller flips it to `partner_pro`), granting
the *free* allowance; `ensure_initial_grant!` then no-ops because a `plan_grant`
already exists. So `handle_new_partner_pro_subscription` calls
`CreditService.grant_plan!` with the `partner_pro` amount (1500) right after
`user.save`, resetting the balance immediately. Backfill the pre-fix cohort
(partners stuck on the free allowance) with `rake partners:grant_pro_credits`
(dry-run by default; `DRY_RUN=false` to apply, `USER_ID=N` to scope).

**Expiry is enforced by Stripe now; `PartnerPilotEndingJob` is digest-only.**
The trial subscription auto-downgrades at the end (above), so the daily job
(5:30am UTC, sidekiq-cron) no longer needs to police `plan_expires_at`. It stays
as an **admin heads-up** so Brittany can convert/extend before the auto-drop:

- **Reminder pass** — partners within `PARTNER_PILOT_REMINDER_LEAD_DAYS` (default
  14) of `plan_expires_at` are added to the admin digest once (flagged
  `settings["partner_pilot_ending_notified"]`). The **partner-facing** nudge is
  now owned by Stripe's `trial_will_end` webhook → `MailchimpTrialWrapJob`, which
  fires the **`partner_pilot_wrap`** journey for partners (names the $10/mo rate,
  offers "add a card to continue" or "reply to re-up") instead of the generic
  `trial_wrap`. So the job no longer emails the partner unless
  `PARTNER_PILOT_LEGACY_REMINDER=true` (kept as an escape hatch).
- **Expired pass** — partners past `plan_expires_at`, still `partner_pro` (i.e.
  Stripe's cancel webhook hasn't landed yet), get flagged
  `settings["partner_pilot_expired"]` + `partner_pilot_expired_at`. Once-only.
- Both feed a single `AdminMailer.partner_pilot_review` digest to `ADMIN_EMAIL`
  (only sent when there's something) so Brittany can convert/extend/downgrade.
- `rake partners:pilot_status` — read-only list of pilots by status (ended /
  ending-soon / active / no-date), respects the lead-days ENV.
- `rake partners:extend USER_ID=N [MONTHS=3] [DRY_RUN=false]` — Stripe-aware
  extension: moves **both** `plan_expires_at` and the subscription's `trial_end`
  (via `User#extend_partner_pro_trial!`) so Stripe re-arms the reminder +
  auto-cancel, and clears the once-flags. Dry-run by default.
- **Admin dashboard surface.** `Admin::MissionControlHelper#partner_pilot_status`
  computes the same status (never mutates). The server-rendered admin
  (`/admin/users`) has a **Partner** filter and chips non-active pilots
  (`Pilot ended` / `Ending soon`) on the row; the user detail page
  (`/admin/users/:id`) shows a **Partner Pilot** card (end date, days left,
  reminder-sent, expired-flagged) so you can action a partner in one place —
  extend with `rake partners:extend` (Stripe-aware), or adjust plan by hand.
- **Admin plan changes.** The user detail page can change plans directly
  (`Admin::UsersController#change_plan`). Most changes are **local-only** (Stripe
  untouched), so an active Stripe subscription's webhooks can later overwrite
  them. Semantics: `free` runs `Billing::PlanTransitions.apply_free_plan` (full
  cancellation); `partner_pro` runs `User.handle_new_partner_pro_subscription`
  (full partner onboarding — this **does** create a Stripe trial subscription,
  the one exception to local-only); other paid plans set `plan_type` **and
  `plan_status: "active"`**
  (without the status reset, a previously-canceled user would be
  `plan_stranded?` and auto-reverted to free). `basic_trial` is not
  admin-assignable — trials belong to the soft-trial flow. The page also
  edits identity/flags and the manual `settings` limit overrides
  (board/paid-communicator/demo-communicator), and has queue-only email
  actions (welcome / setup / temp-login).

**Phase 2 (built):** the pilot now runs on a real Stripe no-card trial (see the
signup section above) — auto-expiry to Free, `trial_will_end` reminder, clean
cancel, one-click conversion (add a card → $10/mo Partner Pro). Two pieces are
deliberately retained for the transition rather than retired: the synchronous
local credit grant (instant credits + fail-soft when Stripe is down) and
`PartnerPilotEndingJob` (now digest-only). A follow-up will **backfill** existing
`partner_pro` users (no `stripe_subscription_id`) onto trial subscriptions using
their current `plan_expires_at` as `trial_end`.

**Requires `STRIPE_PRICE_PARTNER_PRO` to point at a $10/mo price with
`metadata.plan_type=partner_pro`.** The old value was a **$0** price
(`metadata.plan_type=pro`) — a $0 subscription never lapses and would never
downgrade, so it must be repointed to the paid Partner Pro price for the trial to
expire correctly.

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
- **In-app plan switch error contract (`change_plan` / `preview_plan_change`):**
  the direct in-app switch (`Stripe::Subscription.update`, no portal redirect)
  maps Stripe failures to actionable codes so the modal can respond, not just
  show a dead end. `change_plan` returns **402 `payment_failed`** on a
  `Stripe::CardError` (declined card), **402 `payment_method_required`** on a
  `Stripe::InvalidRequestError` whose message indicates the customer has **no
  payment method on file** (detected via `missing_payment_method_error?` — Stripe
  exposes no stable code, so we match the message), and the generic **400
  "Failed to change plan"** for any other Stripe error. `preview_plan_change`
  returns a **`payment_method_required`** boolean — true only when the switch
  bills today (`upcoming.amount_due > 0`) **and** `customer_has_payment_method?`
  is false — so the frontend can prompt for a card before the user confirms.
  Credit-only downgrades (nothing due today) are never flagged. A no-payment-
  method user is steered to the billing portal (`billing_portal`).

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
  when the user is not admin, is on a **board-limited plan**
  (`User#board_limit_locks?` — any non-paid plan, **plus the free Clinician
  plan**), is over their board limit, and the board is not in their **editable
  set** (`User#editable_board_ids`). See `User#board_editable?`
  (`app/models/user.rb`) and `Board#can_edit_for` (`app/models/board.rb`). The
  board's `api_view` exposes `can_edit`, `locked`, and `lock_reason`
  (`Board#lock_reason_for` — `free_plan_board_limit` for Free, `plan_board_limit`
  for a limited paid plan like Clinician) for the frontend.
- **The editable set generalizes to the board limit.** Free (limit 1) keeps the
  single board the user designates (`editable_board_id`, the make_editable pick +
  cooldown below); a higher-limit locked plan (**Clinician**, 100) keeps its
  `board_limit` most-recently-updated owned boards (favorites first,
  `User#top_editable_board_ids`) — active work stays editable, stale boards lock.
  Full paid plans (Basic/Pro/licenses/Partner Pro) are never board-locked; their
  limit only gates creation.
- "Over their board limit" is computed by `User#countable_board_count` (own,
  non-predefined, non-`builder_child` boards) vs `User#board_limit`. This is the
  **single source of truth** for board counting — `User#at_board_limit?` wraps
  it (admins never limited), and every creation gate (create, clone,
  `create_from_template`, `import_obf`, menus, generated-board claim,
  Board Builder) plus the `can_create_boards` api_view flag and this read-only
  rule all route through it. Board Builder sub-boards are excluded so a built
  tree counts as one (see `.claude-notes/board-builder.md`).
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
- **Free's editable slot assumes `FREE_BOARD_LIMIT == 1`.** The single
  `editable_board_id` + make_editable pick only frees one board, so it's used
  only for the limit≤1 case. Higher-limit locked plans (Clinician) don't use a
  user pick at all — `editable_board_ids` computes the top-`board_limit` set by
  recency (see above), so there's nothing to pin or rotate. The `make_editable`
  cooldown machinery is therefore Free-only in practice.

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
  orders slotted (loaner+active) communicators **owner-pinned first, then
  most-recently-active** (`last_sign_in_at` desc, nulls last), keeps the top
  `slot_limit` signable, and flags the overflow. A downgrade flags the overflow;
  a re-upgrade restores them as slots free up (no manual re-claim); any still
  over the new limit stay in fallback. Idempotent; admins are never limited.
- **Owner picks which stay signable (#439).** The mirror of the board
  `make_editable` pick. `User#kept_communicator_ids` (stored on
  `settings["kept_communicator_ids"]`) is the owner's explicit "keep these
  signable" set; reconcile moves those to the front (in the order chosen) before
  the recency rule, so the owner — not just last-sign-in — decides which N stay
  full when over the limit. Empty ⇒ recency only (unchanged behavior).
  `User#set_kept_communicator_ids!(ids)` persists the set (owner-owned ids only,
  capped at `slot_limit`) and re-runs reconcile immediately. Endpoint:
  **`POST /api/child_accounts/keep_signable`** `{ communicator_ids: [...] }` →
  `{ kept_communicator_ids, communicator_slot_limit, communicators: [...] }`.
  `communicator_slot_limit` + `kept_communicator_ids` are also on the user
  `api_view` so the over-limit picker can pre-check the right toggles.
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

### Sandbox → active promotion on upgrade (issue #359)

The upgrade-direction counterpart to fallback mode. A Free user's self-creates
are **forced to `sandbox`** (`Permissions::CommunicatorLimits.self_create_status`
hard-returns SANDBOX when `user.free?`), so a communicator created before
upgrading was left stuck in sandbox mode — sign-in disabled, "Promote this
sandbox" UI — even after the user became a paying Basic/Pro subscriber.

- **Reconciler:** `User#reconcile_paid_sandbox_promotions!` runs on the **same**
  `after_save … if: :saved_change_to_plan_type?` trigger as the fallback
  reconciler. When the user is now `paid_plan?` **and their plan grants zero
  sandbox slots** (admins skipped), it promotes sandbox communicators →
  `active`, **most-recently-active first**, up to the free paid slots
  (`slot_limit_for(settings) - owned_slot_count`). Idempotent. Because the
  subscription-upsert webhook does `plan_type=` → `setup_limits` → one `save!`,
  the new slot limit is already in `settings` when the callback fires.
- **Basic-only by design.** `BASIC_PLAN_LIMITS["demo_communicator_limit"] == 0`
  (no sandbox entitlement), so a Basic user's sandbox is always a stuck Free-era
  leftover and is promoted. **Pro grants 10 sandbox slots**
  (`PRO_PLAN_LIMITS["demo_communicator_limit"] == 10`, ENV
  `PRO_DEMO_COMMUNICATOR_LIMIT`; raised from 1 in 2026-07, backfilled onto
  existing Pro users by `plans:bump_pro_sandbox_to_ten`), so a Pro user's
  sandboxes are intentional scratch/demo accounts and are left untouched — the
  guard is `sandbox_limit_for(settings) > 0 → skip`.
- **`ChildAccount#promote_to_active!`** — mirror of `promote_to_loaner!`: flips
  status to `active`, **mints a passcode if blank** (so sign-in actually works),
  and deletes the per-account `demo_board_limit` cap. Idempotent on an active
  account; never demotes a loaner.
- **Backfill:** the forward fix only fires on a plan change, so existing
  affected users need `rake communicators:promote_paid_sandboxes` (dry-run by
  default; `DRY_RUN=false` to apply, `USER_ID=N` to scope to one user). It
  promotes paid users' stuck sandboxes exactly like the callback.

### 5-Year licenses (`basic_5yr` / `pro_5yr`)

One-time-payment entitlements (Basic $199 / Pro $499, web only) that last 5
years via `plan_expires_at`. Not a subscription — there is **no**
`stripe_subscription_id`.

- **Plan plumbing:** `basic_5yr` maps to Basic limits/credits, `pro_5yr` to Pro
  (`setup_limits`, `board_group_limit`, `PLAN_MONTHLY_CREDITS`). `basic?` already
  matches `basic_5yr` (substring); `pro?` was extended to include `pro_5yr`
  (exact-list). `paid_plan?` passes both.
- **Checkout:** `POST /api/stripe/checkout_sessions/license` (`#license`, modeled
  on `#topup`): `mode: "payment"`, `allow_promotion_codes: true`, metadata
  `{ kind: "license", plan_type, license_years: 5, monthly_credits, user_id }`.
  **No `payment_method_collection`** — Stripe rejects it on `mode: payment`.
  Prices from `LICENSE_PRICE_ENV_KEYS` (`STRIPE_PRICE_BASIC_5YR` /
  `STRIPE_PRICE_PRO_5YR`), resolved at request time.
- **Grant:** a one-time payment only fires `checkout.session.completed` (no
  subscription upsert), so `handle_license_completed` (`kind == "license"`) is the
  **sole** grant path — without it a license would silently do nothing. It
  whitelists `plan_type` (`LICENSE_PLAN_TYPES`), sets `plan_status="active"` +
  `plan_expires_at = license_years.years.from_now`, clears any stale
  `renewal_notice_sent_at`, and grants the first month's credits
  (`CreditService.grant_plan!`, idempotent on the Stripe event id). The
  `update_user_from_session` fast-path mirrors the plan/expiry (no credits) with
  the same `status=="complete"` + owner checks.
- **Monthly credits:** licensees have no subscription, so
  `RefreshFreeTierCreditsJob` re-grants their allowance monthly (both plan types
  are in `REFRESHABLE_PLAN_TYPES`).
- **Expiry:** enforced by **`PlanExpiryJob`** (daily, 6am UTC) — the enforcer for
  `plan_expires_at`, which nothing previously read. Scoped to
  `ENFORCED_PLAN_TYPES = [basic_5yr, pro_5yr]`. Renewal pass: sends
  `UserMailer.license_renewal_offer_email` once ~`LICENSE_RENEWAL_NOTICE_LEAD_DAYS`
  (default 60) before expiry, flagged `settings["renewal_notice_sent_at"]`. Expiry
  pass: past `plan_expires_at`, routes through
  `Billing::PlanTransitions.apply_free_plan` (data retained, over-limit boards
  read-only, over-limit communicators in fallback, free credits granted, editable
  board pinned) + `license_ended_email`. Idempotent — `apply_free_plan` resets
  `plan_type` to `free`, so the user leaves the scope. `partner_pro`/`clinician`
  are deliberately excluded.

### Extra communicator add-on slots (Pro-only)

Pro users can buy communicator slots **on top of** their plan's base 5 —
$5/mo or $50/yr recurring, or $125 one-time bundled with a `pro_5yr` license.
`Billing::ExtraCommunicators` is the single home for the add-on (price ENV keys,
`clamp`, item-matching). The whole feature funnels into **one settings key**,
`settings["extra_communicator_slots"]`, which
`Permissions::CommunicatorLimits.slot_limit_for` **adds to the base limit** —
so a purchased slot is finally creatable through the one creation gate. Before
this, the gate read a `communicator_slot_limit` override that no code ever
wrote, so the half-built `basic_extra_comm` path granted nothing.

- **Additive everywhere.** `slot_limit_for` = base + `extra_communicator_slots`.
  `User#comm_account_limit`, `#comm_account_limit_reached`, and the api_view
  `comm_limit`/`communicator_slot_limit` all include the extras so the client
  sees consistent numbers. `User#apply_extra_communicator_slots!(n)` clamps
  (`MAX_EXTRA_COMMUNICATORS`, default 20), persists, and re-runs
  `reconcile_communicator_fallback!` so buying slots restores over-limit
  communicators out of fallback. It's a no-op when unchanged.
- **Pro-only.** Every writer gates on `User#pro?` (which already covers
  `pro`/`pro_yearly`/`pro_5yr`/`partner_pro`). A non-Pro plan always resolves to
  0 extras.
- **Monthly / yearly (subscription).** `POST /api/subscriptions/communicator_addon`
  `{ quantity: N }` upserts a recurring add-on **subscription item** on the
  user's active Pro subscription to exactly N (0 removes it), interval matched to
  the plan price. Prices: `STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY` /
  `STRIPE_PRICE_PRO_EXTRA_COMM_YEARLY`. Entitlement is then **re-derived from the
  live subscription** in `handle_subscription_upsert` (via
  `ExtraCommunicators.quantity_from_subscription`), so add / remove / cancel /
  downgrade self-heals on the next `customer.subscription.updated`.
  `first_price_from_subscription` skips the add-on item so it can never be read
  as the plan price.
- **One-time (license bundle).** `POST /api/stripe/checkout_sessions/license`
  accepts `extra_communicators: N` **only** for `pro_5yr` (400 otherwise, or if
  `STRIPE_PRICE_PRO_EXTRA_COMM_5YR` is unset). The count rides the checkout
  metadata; `handle_license_completed` applies it. It expires with the license.
- **Cleared on downgrade.** `Billing::PlanTransitions.apply_free_plan` deletes
  `extra_communicator_slots`, so a cancelled subscription or an expired license
  takes its extras with it (over-limit communicators retained in fallback, per
  the downgrade invariant). **Known gap:** a Stripe *plan* downgrade (Pro→Basic
  via portal/`change_plan`) drops the entitlement to 0 but does **not** auto-
  remove a lingering add-on subscription item — the item should be cleaned up in
  that flow (follow-up; noted on the frontend issue).

### SpeakAnyWay for Clinicians (`clinician`)

A **free**, manually-approved plan for verified SLPs/OTs/AT specialists.
**Basic-shaped limits** (`board_limit: 100`, `board_group_limit: 25`, revised
2026-07-15 — NOT Pro's 300/50) with premium features unlocked, plus a small
**`paid_communicator_limit: 2`** loaner cap (protects school pricing) and
`demo_communicator_limit: 2`; 400 credits/mo. All ENV-overridable via
`CLINICIAN_*` (`CLINICIAN_PLAN_LIMITS`). The free account is for evaluating the
product and seeding 2 families — Pro-only tools (caseload dashboard, bulk export)
stay Pro-only. The ladder: free Clinician (100/2/400) → Partner Pro $10/mo
(300/5/1500, invite-only) → Pro $20 (families) → school $180/clinician/yr.

- **Not Pro.** `clinician?` is folded into `paid_plan?` (a granted plan — usage +
  Pro-level features must not break) but deliberately **not** into `pro?` — the
  2-slot cap is the product, and widening `pro?` would hand clinicians Pro's 5
  slots. `professional?` stays false too.
- **Board-limited despite being paid.** Clinician is the one paid plan the
  read-only board lock applies to (`User#board_limit_locks?`): a clinician over
  their 100-board limit (e.g. a partner who landed here with 300 boards) keeps
  the 100 most-recently-updated boards editable and the rest go **read-only**
  (retained, never deleted). See "Board access on downgrade (read-only rule)".
- **Application:** `POST /api/clinician_applications` (authenticated; one *pending*
  application per user, enforced by a partial unique index + model validation).
  `GET /api/clinician_applications/mine` returns the latest. Fields: `full_name`,
  `credential_type` (slp/ot/at_specialist/other), `license_id`, `workplace`.
- **Admin review — two entry points, one code path.** Approve/deny logic lives in
  `ClinicianApplications::Reviewer` (`app/services/`): `approve!` flips
  `plan_type="clinician"` (callbacks set limits + reconcile) and **synchronously
  grants** the 400-credit allowance (clinician is free / no Stripe invoice, same
  pattern as the partner_pro comp grant); `deny!` records a note; both send
  `ClinicianMailer` emails (never "Professional"). Two controllers call it:
  - **Server-rendered dashboard** — `Admin::ClinicianApplicationsController` at
    `/admin/clinician_applications` (nav "Clinicians" with a pending-count badge).
    Pending list + Approve / Deny buttons, admin-authenticated via
    `Admin::ApplicationController` (non-admins redirected). This is the click-to-
    approve UI; no frontend deploy needed.
  - **JSON API** — `API::Admin::ClinicianApplicationsController`
    (`/api/admin/clinician_applications`), built on `API::ApplicationController` +
    a `require_admin!` that renders **403** for a signed-in non-admin, **401**
    unauthenticated. For the React admin / programmatic use.

### Partner Pro trial landing path (`partner_pro` → `clinician` at trial end)

**Partner Pro STAYS** as launched (decided 2026-07-15 — supersedes the earlier
"fold everyone" idea): the $10/mo invite-only plan continues (3 free months, full
Pro limits). The **only** change (must be live in prod before **Oct 14, 2026** —
the first live partner trials end Oct 14–20) is the *destination* when a no-card
trial lapses.

- **Landing guard:** `handle_subscription_deleted` — when the cancelled sub
  belongs to a `partner_pro` user, `land_partner_on_clinician!` transitions them
  to a free **`clinician`** account instead of calling `apply_free_plan`. It sets
  `plan_type="clinician"` + `plan_status="active"`, clears `stripe_subscription_id`
  (so `RefreshFreeTierCreditsJob` resumes monthly grants), grants the 400-credit
  clinician allowance, and records an **auto-approved `ClinicianApplication`**
  (partners were vetted at invite time). Plan-change callbacks apply the Clinician
  limits and reconcile moves over-limit communicators into fallback — content
  retained, never deleted. A partner who added a card converts to paying and never
  reaches this missing-payment-method cancel.
- **Idempotency:** an early `return if user.clinician?` guards webhook
  re-delivery (and the whole handler is event-id gated), so a re-fired
  `subscription.deleted` never re-runs the landing or dumps a clinician to Free.
  `ensure_approved_clinician_application!` also skips if an approved application
  already exists.
- **No fold rake task** — the earlier `partners:fold_into_clinicians` idea was
  dropped; partners are converted individually, at their own trial end, by this
  webhook path.
- **Trial-end messaging:** `PartnerMailer.pilot_ending_email` (and the Mailchimp
  `partner_pilot_wrap` journey, edited in Mailchimp) present the choice plainly —
  "add a card to keep Partner Pro at $10/mo, or continue free on a Clinician
  account; your boards stay either way (over-limit content becomes view-only,
  never deleted)."

