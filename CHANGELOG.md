# Changelog

All notable user-facing changes to this project will be documented here.
The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added — Communication Prompt Mode for caregivers
- New `CoachingPromptSet` model + `API::CoachingPrompts` controller (`GET/POST/PATCH/DELETE /api/coaching_prompts`). A caregiver opens a board in Caregiver Mode and the API returns a coaching prompt set with strategies + tappable example phrases. Curated SpeakAnyWay sets ship for Snack Time, Car Ride, Bedtime Story (matched against `Board#tags` / name tokens). For boards without a curated match, `CoachingPromptGenerator` calls OpenAI (`gpt-4o-mini`) once and caches the result on the board's `metadata` jsonb so the second visit costs nothing. Staging skips the paid call and returns the bundled fallback set, mirroring the existing OpenAI image staging stub.
- Users can create / edit / delete their own custom coaching sets via the same endpoint — owned sets are scoped by `user_id`. Editing SpeakAnyWay-shipped or another user's sets returns 403.
- New `profiles.is_caregiver` boolean (default false) — opt-in flag that lights up the Caregiver Mode entry point in the frontend. Exposed via the existing `profiles` API (`PATCH /api/profiles/:id`).
- Free for everyone — no `CreditService` gating. Cost is bounded by per-board caching of AI fallback generations.

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
