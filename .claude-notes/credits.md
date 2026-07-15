# AI credits — ledger, gating, lifecycle

> Extracted from CLAUDE.md on 2026-07-11 (hub-and-spoke restructure).
> This file is the authoritative doc for this subsystem — update it (not CLAUDE.md)
> when behavior changes. CLAUDE.md keeps only the cross-cutting invariants.

## AI gating: credit ledger (source of truth)

- AI features are gated by **weighted credits** held in two balances on `users`:
  `plan_credits_balance` (resets each billing period, doesn't roll over) and
  `topup_credits_balance` (additive from one-time purchases, doesn't expire).
- All credit movement is recorded in `credit_transactions` (immutable ledger).
  Webhook-driven grants are idempotent on `stripe_event_id`.
- Entry point: `CreditService.spend!(user, feature_key:, amount: nil)` raises
  `CreditService::InsufficientCredits` when out of credits. Per-feature costs
  live in `CreditService::FEATURE_COSTS`. `CreditService.can_spend?(user,
  feature_key:, amount:)` checks balance without locking/spending (used by
  `StructurePlanner`'s credit downgrade logic).
- AI controllers gate via `check_credits!(feature_key:, feature_name:)` in
  `API::ApplicationController`. On insufficient balance it renders **HTTP 402**
  with `{ error: "insufficient_credits", feature, needed, balance, plan_credits,
topup_credits, reset_at, topup_url }`. Admins (`current_user.admin?`) bypass.
- Reserve **HTTP 429** for true rate limiting (rapid-fire abuse), not credit
  exhaustion.
- **Menu boards have a user-picked image budget.** `POST /api/menus` (and
  `POST /api/menus/:id/rerun`, which is owner-gated: 403 for non-owners) spends
  **one** up-front transaction: the flat `menu_create` fee (5) + `token_limit` ×
  `menu_image` (3, matching standalone image_generation) — `token_limit` now means "max AI images to generate for this
  build" (default 10, clamped to `MENU_MAX_IMAGES`, default 30; 0 = reuse
  existing art only). The reservation (`txn_id`/`per_image`/`reserved`) is
  stashed on `board.settings["menu_credit"]`;
  `Board#find_or_create_images_from_word_list` takes `max_generate:` and marks
  over-budget tiles `status: "skipped"` (every menu item still becomes a tile —
  the cap only limits paid OpenAI generation). `Menus::CreditRefunds` refunds
  idempotently against that txn: the unused budget after the build
  (`Menu#create_images_from_description`), the per-image cost per failed generation
  (`GenerateImagesJob`), and the full spend — flat fee included — when the
  vision extraction produces nothing (`EnhanceImageDescriptionJob`, or inline
  in `menus#rerun`). Admin builds spend nothing (`check_credits!` bypasses, so
  no reservation is stashed) but the budget still caps generation via
  `board.token_limit`.
- **`image_generation` is free for first-time fills.** `API::ImagesController#generate`
  (`POST /api/images/generate`) only calls `check_credits!` when the image **already
  has a displayable picture** for the user (`Image#display_image_url(user).present?` —
  the same "is there a doc to set?" notion as `Board#find_or_create_images_from_word_list`).
  Generating an image for an empty tile/label (no doc yet) still enqueues
  `GenerateImageJob` but is **not billed** — we don't charge users to build the shared
  image library. Charging only applies when they're replacing/customizing an existing
  image. `regenerate_images`, `create_image_edit`, and `create_image_variation` act on
  images that already have a picture, so they keep charging unconditionally.
- **`MonthlyFeatureLimiter` was removed** (along with `User#ai_limit_reached?`,
  `#reset_ai_limits!`, and the dead `ai_monthly_limit` plan-limit key). AI is
  gated solely by the credit ledger now; the old monthly action-counter was
  never on the enforcement path. `User#can_use_ai?` now means simply `!locked?`
  (the api_view flag the frontend reads to enable/disable AI buttons); the
  `ai_limit_reached` api_view field was dropped (unconsumed).

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
  canceled/paused subscribers land on free with 25 credits (not 0). The
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
- **Free tier allowance:** 25 credits/month
  (`CreditService::PLAN_MONTHLY_CREDITS["free"]`). Applied on signup,
  refresh, and post-cancellation.
- **No-subscription paid plans ride the refresh job.** 5-Year licenses
  (`basic_5yr` 400 / `pro_5yr` 1500) and `clinician` (400) have no Stripe
  subscription, so their monthly re-grant comes from `RefreshFreeTierCreditsJob`
  (all three are in `PLAN_MONTHLY_CREDITS` + `REFRESHABLE_PLAN_TYPES`). Their
  **first** grant is synchronous, not from a webhook invoice: licenses grant in
  `handle_license_completed` (idempotent on the Stripe event id), clinician
  grants at admin approval, and the partner fold grants at conversion — the same
  "comp plan, granted outside webhooks" pattern as `partner_pro`. See
  `.claude-notes/billing-and-plans.md` for the plan mechanics.

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

