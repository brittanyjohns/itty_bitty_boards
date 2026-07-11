# Handoff: Beta End + Founding Family Rate (backend)

**Date:** 2026-06-10 · **Status:** not started
**Full plan:** `speakanyway/drafts/beta-end-founding-rate-plan.md` (this doc is self-contained; the plan adds context)
**Counterpart:** `itty-bitty-frontend/.claude-notes/beta-end-founding-rate-handoff.md` (independent — no API contract change; either can ship first)

## Decisions (already made — don't re-litigate)

- Beta "ends" **July 15, 2026** (date used in comms; the reconciliation task is run manually, not cron-scheduled).
- **Audit first**: Phase 1 is a read-only audit. Phase 2 (reconciliation) is only built/run if the audit finds over-entitled users.
- Founding Family discount = **Stripe forever-duration coupon + promotion code on the EXISTING yearly prices** (`STRIPE_PRICE_BASIC_YEAR` / `STRIPE_PRICE_PRO_YEAR`). No new Prices, no new plan keys, no webhook changes.
- Pricing detail pending (does not block Phase 1/2): one 50% code (Pro $100/yr, Basic $40/yr) vs. two amount-off codes ($99/$49). Stripe dashboard work, not code.

## Current state (verified on origin/main, 2026-06-10)

**There is no beta override in code.** "All users get temporary Pro during beta" survives only as a frontend settings notice.

- New users default Free: `app/models/user.rb:222-224` (`setup_new_user_free_plan`); `pro?` is a plain equality check (`user.rb:1032-1034`).
- **Enforcement reads the persisted `settings` hash, not plan entitlement**: `board_limit` → `settings["board_limit"] || FREE_PLAN_LIMITS` (`user.rb:434-435`); board creation gated in `app/controllers/api/v1/board_builder_controller.rb:38-40`; communicator slots via `Permissions::CommunicatorLimits.slot_limit_for(settings)` (`app/helpers/permissions/communicator_limits.rb:65-75`).
- Over-limit machinery is built: `reconcile_communicator_fallback!` (`user.rb:1376-1391`) fires on `saved_change_to_plan_type?` (`user.rb:178`); `ChildAccount` fallback mode (`app/models/child_account.rb:150-172`); Free transitions pin one editable board (`app/services/billing/plan_transitions.rb` → `apply_free_plan`, `pin_default_editable_board!`).
- **The gap this handoff closes:** beta-era users may have Pro-level values written into `settings` while `plan_type` stayed `"free"`. Since enforcement reads `settings` and the reconcile callback only fires on `plan_type` *change*, those users keep Pro limits forever unless we re-apply entitlements.
- Stripe checkout: plan_key → ENV price IDs (`app/controllers/api/stripe/checkout_sessions_controller.rb:21-27`); `promo_code` param looked up as a Stripe PromotionCode and applied as a discount (`:71-90`); when no promo passed, `allow_promotion_codes = true` (~`:114`) — so codes typed at checkout already work with **zero backend change**.
- Webhook plan assignment reads `Price.metadata["plan_type"]` with a safe keep-current fallback (`app/controllers/api/webhooks_controller.rb:258-350`). Coupons don't touch this path — another reason promo codes are the right mechanism.
- Existing jobs (`config/initializers/sidekiq.rb`): `downgrade_soft_trial` (2am), `expire_plan_credits` (hourly), `refresh_free_tier_credits` (3am). None handles a beta-end sweep.

## Work items

### 1. Audit task (read-only — ship this alone first)

`lib/tasks/beta_audit.rake` → `rake beta:audit_entitlements`

For every user, compare against the entitlement for their `plan_type` (use the `FREE/BASIC/PRO_PLAN_LIMITS` hashes in `user.rb`):

- persisted `settings["board_limit"]`, `settings["paid_communicator_limit"]`, AI monthly limit vs. entitled values
- actual `countable_board_count` and slotted communicator count vs. entitled values

Output: summary counts to stdout (over-entitled-settings users by plan; over-actual-usage users by plan) + a CSV (`tmp/beta_audit_<date>.csv`) with user id, email, plan_type, each persisted vs. entitled limit, actual counts. **No writes.** Guard with `puts` not logger so it's console-friendly.

### 2. Reconciliation task (build after audit results; idempotent)

`rake beta:end_beta[dry_run]` — default dry-run, explicit `false` to apply.

For each over-entitled user from the audit query:
- Re-apply entitlements: `user.setup_limits` + save (for paid plans this corrects inflated settings).
- For `plan_type == "free"` users, route through `Billing::PlanTransitions.apply_free_plan(user)` so board pinning + communicator fallback run through the existing, tested machinery rather than reimplementing it.
- Log one line per user (id, what changed). Idempotent: running twice is a no-op.
- Do NOT touch users whose settings already match entitlement, and do NOT touch `partner_pro` / admin accounts.

### 3. Stripe dashboard (Brittany does this, document the steps in the PR description)

Test mode first: Coupon (50% off, duration **forever**) → Promotion code `FOUNDING` → restrict to first-time-order off? No — existing subscribers upgrading must be able to use it. Verify a checkout session on `pro_yearly` with `promo_code=FOUNDING` shows the discount and that the discount persists on renewal preview. Then repeat in live mode. No code change needed — `checkout_sessions_controller` already passes promo codes through.

## Testing

| Case | Expect |
|---|---|
| Audit on seeded users (free user with pro limits in settings) | Listed in CSV, counted; zero writes (verify with query before/after) |
| `beta:end_beta` dry-run | Logs intended changes, DB untouched |
| `beta:end_beta` apply on free user w/ 5 boards + 3 communicators | settings → Free limits; 1 editable board pinned, others locked; communicators beyond slot 1 in `fallback_mode` |
| Re-run apply | No-op, no duplicate logs |
| Paid (basic) user w/ inflated settings | settings corrected to Basic limits; no fallback churn for in-limit communicators |
| Checkout w/ `promo_code=FOUNDING` (Stripe test) | Discount applied; subscription created at discounted recurring amount |

Write specs for the tasks (under `spec/tasks/` or `spec/lib/`). **Don't run the rspec suite locally — open the PR and let CI run it.** If you changed something risky, you may run just your new spec files locally, but never block the PR on a full local suite run.

## Deploy notes

- No migrations. No new ENV vars.
- Run order in production: deploy → `rake beta:audit_entitlements` → review CSV with Brittany → (if needed) `rake beta:end_beta[dry_run]` → review → `rake beta:end_beta[false]` on July 15.
- Stripe live-mode coupon must exist before the Founding Family email sends (see `marketing/drafts/founding-family-beta-end-email.html`).

## Git rules (Brittany's)

Branch off origin/main in a worktree. Never push to main or merge PRs — open the PR and stop.
