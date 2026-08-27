# Handoff: checkout revenue fixes (backend)

**Date:** 2026-08-27 · **Status:** not started · ships independently, no ordering dependency
**Full plan:** `../drafts/checkout-revenue-fixes-plan.md` (this doc is self-contained; the plan adds context)
**Counterpart:** `../itty-bitty-frontend/.claude-notes/checkout-revenue-fixes-handoff.md`
**Issue:** none filed yet

Context: the frontend's signed-out flow silently coerces 5-year-license intents into monthly subscriptions (frontend is fixing its side). The backend currently *cooperates* with that bug instead of refusing it, and its analytics mislabel the result. This PR is defense in depth + honest telemetry. Small, one concern.

## Decisions (already made — don't re-litigate)

- The subscription checkout endpoint must **hard-reject** license plan keys, not fall through on a missing price lookup.
- `billing_interval` in analytics events must report `five_year` for license checkouts — never `monthly`.

## Current state

- `app/controllers/api/stripe/checkout_sessions_controller.rb:24` — `PLAN_PRICE_IDS` maps `pro` → `STRIPE_PRICE_PRO`; line 99 rejects on `price_id.blank?` — so `pro_5yr` *happens* to 400 today only because it's absent from the map. That's an accident, not a guard; a future map addition would silently sell a 5-yr key as a subscription.
- Line 148: `mode: "subscription"`; lines 191-205 attach a 14-day trial — this is what a mis-routed license buyer was actually sold.
- Lines 215-224: server-side `checkout_started` event; `billing_interval_for` has no `five_year` concept.
- `#license` action (lines ~337-356) is the correct 5-yr path and also accepts `extra_communicators` — no changes needed there.
- Related but separate (do NOT fold into this PR): duplicate checkout-session spawning observed in prod (4 sessions in 73s for one buyer, 2 in 20s for another) — if you spot an obvious client-retry or idempotency gap while in this controller, note it in the PR description; don't fix blind.

## Work items

1. `checkout_sessions#create`: explicit guard — if the requested plan key ends in `_5yr` (or otherwise denotes a one-time license), return 400 with a clear error body (e.g. `{"error":"license plans use /api/stripe/checkout_sessions/license"}`) *before* price lookup. Keep the existing blank-price 400 as backstop.
2. `billing_interval_for` (or equivalent): report `"five_year"` for license checkouts; verify what the `#license` action currently emits and align.
3. PostHog test-account hygiene: `bhannajohns+aug10@gmail.com` slipped past the project's internal-user filters. If test-account patterns are managed in code/config here, add the `bhannajohns+*@gmail.com` pattern; if it's PostHog-UI-only config, skip and say so in the PR description.

## Testing

- Request spec: POST subscription checkout with `plan_key: "pro_5yr"` → 400 with the explicit error (not the generic blank-price path).
- Request spec: license checkout event payload carries `billing_interval: "five_year"`.
- Run the checkout/billing request specs (`bundle exec rspec` scoped to the touched controllers) and report results in the PR.

## Deploy notes

No migrations, no ENV changes. Safe to ship before or after the frontend PRs.

## Wrap-up

Follow this repo's CLAUDE.md for git workflow and conventions (check the billing topic doc it points to before editing). Open the PR and stop — never merge. Commit this doc in the PR so it survives the session.
