# QA — AI Credits, New User (Basic Trial)

**Persona:** Brand-new signup. Lands in the 14-day Basic Trial soft trial,
granted **400 AI credits** by `User#after_create`.

**Run on:** staging — `https://ypk9e.hatchboxapp.com`. Staging Stripe is in
test mode, so all payments are fake. Use a fresh email each run.

**Covers:** signup grant → balance widget → AI consumption → top-up purchase
→ post-purchase refresh. The full Phase 2–4 user-visible loop for a trial
user.

---

## Steps

### 1. Sign up

- Create an account with a **brand-new email**.
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

- Generate an AI image (or any AI action — see the feature/cost table in
  the README's "AI credits" section).
- **Expected:** operation succeeds with no error; balance drops by the
  feature cost (AI image = 5 credits → **395 total**).

### 5. Buy a Small credit pack

- On `/billing`, click **Buy credits** → **Small ($4.99 / 100)**.
- **Expected:** redirected to `checkout.stripe.com/c/pay/...`.
- Enter test card `4242 4242 4242 4242`, any future expiry, any CVC, any
  ZIP. Complete payment.
- **Expected:** redirected back to `/billing/success` (or similar).

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
| Step 5 lands on `400 "Unknown or unconfigured pack_key"` instead of Stripe Checkout | `STRIPE_PRICE_TOPUP_*` env vars are unset or wrong on Hatchbox |
| Step 5 lands on a Stripe error page | The configured Price IDs don't match what's in the Stripe dashboard, or they're test-mode IDs on a live-mode app |
| Balance widget never appears | Frontend release containing the credits UI hasn't deployed |
| Step 2 shows 10 instead of 400 | `set_soft_trial_plan` didn't run — user might have been created in an earlier `plan_type: "free"` state, or `basic_trial` is missing from `CreditService::PLAN_MONTHLY_CREDITS` |
| Step 4 returns 402 immediately | After-create grant didn't fire — check logs for `[CreditService]` errors |
