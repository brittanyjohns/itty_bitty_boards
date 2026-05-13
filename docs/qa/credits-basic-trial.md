# Smoke Test — AI Credits, New User (Basic Trial)

A short production smoke test that walks one user through the full
visible AI-credits loop. Suitable for a human QA run or for a
**Claude Cowork** agent driving the browser.

**Persona:** Brand-new signup. Lands in the 14-day Basic Trial soft
trial, granted **400 AI credits** by `User#after_create`.

**Run on:** production — `https://speakanyway.com`.

**⚠️ Production = real money.** Step 5 charges a real card $4.99. Use
a card you own and refund the charge afterward in the Stripe live
dashboard (Payments → find the charge → Refund), or use a $0/100%-off
promotion code if one's configured.

**Covers:** signup grant → balance widget → AI consumption → top-up
purchase → post-purchase refresh.

---

## Steps

### 1. Sign up

- Create an account with a **brand-new email** (one not already in
  production).
- **Expected:** lands in the app, signed in.

### 2. Check the balance widget

- Look at the side menu / account header.
- **Expected:** badge reads "Credits: 400" (or similar).

### 3. Visit the Billing page (`/billing`)

- **Expected:** Credits panel shows
  - Plan: **400**
  - Top-up: **0**
  - Total: **400**
  - Reset date: **~14 days from today**
  - Plan: **basic_trial**

### 4. Use one AI feature

- Generate an AI image (or any AI action — see the feature/cost table
  in the README's "AI credits" section).
- **Expected:** operation succeeds with no error; balance drops by the
  feature cost (AI image = 5 credits → **395 total**).

### 5. Buy a Small credit pack

- On `/billing`, click **Buy credits** → **Small ($4.99 / 100)**.
- **Expected:** redirected to `checkout.stripe.com/c/pay/...`.
- Enter a real card, real billing details, complete payment.
- **Expected:** redirected back to `/billing/success` (or similar).
- After verifying, refund the charge in the Stripe live dashboard if
  you don't actually want it on the books.

### 6. Confirm the top-up landed

- Refresh `/billing` (panel may refresh automatically).
- **Expected:** panel now shows
  - Plan: **395**
  - Top-up: **100**
  - Total: **495**

---

## Pass / fail

PASS if every "Expected" line is true.

## Common failure modes

| Symptom | Likely cause |
| --- | --- |
| Step 5 lands on `400 "Unknown or unconfigured pack_key"` instead of Stripe Checkout | `STRIPE_PRICE_TOPUP_*` env vars are unset or wrong on the production Hatchbox app |
| Step 5 lands on a Stripe error page | The configured Price IDs don't match what's in the Stripe live dashboard, or test-mode IDs leaked into live config |
| Balance widget never appears | Frontend release containing the credits UI hasn't deployed |
| Step 2 shows 10 instead of 400 | `set_soft_trial_plan` didn't run — user may have been created in an earlier `plan_type: "free"` state, or `basic_trial` is missing from `CreditService::PLAN_MONTHLY_CREDITS` |
| Step 4 returns 402 immediately | After-create grant didn't fire — check logs for `[CreditService]` errors |
| Step 6 still shows top-up: 0 after a successful Stripe payment | `invoice.payment_succeeded` / top-up `checkout.session.completed` webhook isn't reaching prod, or the production Stripe webhook endpoint is missing the `checkout.session.completed` event |
