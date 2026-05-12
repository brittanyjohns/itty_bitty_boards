# Changelog

All notable user-facing changes to this project will be documented here.
The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
- **Phase 4:** Plan-credit grants driven by `invoice.payment_succeeded` webhook so renewals top up automatically.
- **Phase 5 (optional):** Stripe Meter-based overage billing.
