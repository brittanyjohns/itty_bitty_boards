# Stripe setup — AI credits

Every environment (test, live) needs these Stripe objects configured the
same way. The webhook and `CreditService` read metadata from Stripe — there
are no hard-coded plan or pack values in the app.

## Quickstart: seeding a fresh Stripe Sandbox

When you spin up a new Stripe Sandbox workspace, you don't need to click
through the dashboard. Run the seed rake task — it's idempotent and
creates every Product, Price, and the `PARTNERPILOT26` promotion code:

```bash
export STRIPE_API_KEY=sk_test_...   # SECRET key from the new sandbox
bundle exec rake stripe:seed_sandbox
```

The task refuses to run against a live-mode key (`sk_live_...`) unless you
also set `ALLOW_LIVE=true`. At the end it prints an env-var block to paste
into Hatchbox (or your local `.env`). Rerunning prints `[skip]` lines for
existing objects — safe to repeat.

The sections below explain what those objects are and how the app reads
them, in case you need to set anything up by hand.

## 1. Subscription Prices (existing tiers)

For each tier — Free, MySpeak, Basic, Pro, Partner Pro — open the Price in
the Stripe Dashboard and set its **metadata**:

| Key | Value | Notes |
|---|---|---|
| `plan_type` | `free` / `myspeak` / `basic` / `pro` / `partner_pro` | Webhook reads this to set `users.plan_type` |
| `monthly_credits` | integer | Number of AI credits granted each billing period; overrides `CreditService::PLAN_MONTHLY_CREDITS` |

Existing env vars stay as they are (`STRIPE_PRICE_MYSPEAK`,
`STRIPE_PRICE_BASIC`, `STRIPE_PRICE_PRO`, yearly variants, partner pro).

## 2. Top-up credit pack Products (new)

Create three **one-time** Products in Stripe:

| Product name | Price | Price metadata |
|---|---|---|
| Credit Pack — Small | $4.99 USD | `kind: topup`, `credit_amount: 100` |
| Credit Pack — Medium | $19.99 USD | `kind: topup`, `credit_amount: 500` |
| Credit Pack — Large | $49.99 USD | `kind: topup`, `credit_amount: 1500` |

Each Price must be `type: one_time` (not recurring).

Then set env vars to the resulting Price IDs:

```
STRIPE_PRICE_TOPUP_SMALL=price_...
STRIPE_PRICE_TOPUP_MEDIUM=price_...
STRIPE_PRICE_TOPUP_LARGE=price_...
```

> Final dollar prices and credit amounts are a marketing call —
> see `docs/credits-handoff.md` §3. The table above is the working proposal.

## 2b. Extra communicator add-on Prices (Pro-only)

Pro users can buy communicator slots on top of the base 5. Create one Product
("Extra Communicator") with three Prices — tag each with
`metadata.kind = extra_communicator` so the app can identify the charge even if
a Price id rotates:

| Price | Type | Metadata |
|---|---|---|
| $5.00 USD / month | recurring (monthly) | `kind: extra_communicator` |
| $50.00 USD / year | recurring (yearly) | `kind: extra_communicator` |
| $125.00 USD one-time | one_time (bundled with a `pro_5yr` license) | `kind: extra_communicator` |

Then set env vars to the resulting Price IDs:

```
STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY=price_...
STRIPE_PRICE_PRO_EXTRA_COMM_YEARLY=price_...
STRIPE_PRICE_PRO_EXTRA_COMM_5YR=price_...
# optional: cap per-account extras (default 20)
MAX_EXTRA_COMMUNICATORS=20
```

The recurring prices back `POST /api/subscriptions/communicator_addon`; the
one-time price is added as a second line item by
`POST /api/stripe/checkout_sessions/license` when `extra_communicators > 0` on a
`pro_5yr` license. See `.claude-notes/billing-and-plans.md` → "Extra communicator
add-on slots".

## 3. Webhook endpoint

There's already a Stripe webhook configured at `/api/webhooks` that uses
`STRIPE_WEBHOOK_SECRET`. The following events must be enabled:

- `checkout.session.completed`
- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `customer.subscription.paused`
- `customer.created`
- `invoice.payment_succeeded` *(triggers plan-credit grants on first paid period and every renewal — Phase 4)*

## 4. Redirect URLs (success_url / cancel_url)

`API::Stripe::CheckoutSessionsController#frontend_base_url` derives the
host for Stripe Checkout's `success_url` / `cancel_url` from the incoming
request's `Origin` (or `Referer`) header, _when that header points at a
trusted host_. The trust allowlist lives in `ALLOWED_FRONTEND_HOSTS` on
the controller and currently covers:

- `localhost` / `127.0.0.1`
- `*.speakanyway.com`
- `*.netlify.app` (so any Netlify preview deploy works automatically)
- `*.hatchboxapp.com`

When the request doesn't carry a recognized origin, the controller falls
back to `ENV["FRONT_END_URL"]`, then to `http://localhost:8100`. This is
why staging doesn't need a per-preview env var — the redirect follows the
browser, not the server config. Keep `FRONT_END_URL` set as a sensible
fallback anyway (production points at the live frontend; staging can
point at the staging marketing site).

If you add a new trusted frontend host, update both the allowlist and
this section.

## 4b. Customer portal configuration (billing portal for free accounts)

`POST /api/subscriptions/billing_portal` works for **every** account —
free users included (the backend lazily creates a Stripe customer on
first billing touch). `Stripe::BillingPortal::Session.create` requires a
**default portal configuration** saved in the dashboard, in **both test
and live mode** — a mode with no saved default errors until you save one
once.

Checklist (Settings → Billing → Customer portal, each mode):

- Invoice history: **ON** (receipts are the main value for free users)
- Customer information update: **ON**
- Payment method update: **ON**
- Don't regress paid users' cancel/update-subscription settings — the
  portal config is shared by free and paid customers.

Optional: a dedicated portal configuration can be pinned via
`STRIPE_PORTAL_CONFIG_ID` (Hatchbox env). Default unset — the dashboard
default config is used.

## 5. Staging-specific setup (Stripe Sandbox)

Staging has its own webhook endpoint pointing at the staging app. To set
it up from scratch in a Sandbox workspace:

1. Stripe Sandbox dashboard → Developers → Webhooks → Add endpoint.
2. **URL:** `https://ypk9e.hatchboxapp.com/api/webhooks`
3. **Events to send** — at minimum the events listed in §3 above.
4. Save, then reveal and copy the endpoint's signing secret.
5. In Hatchbox staging env vars, set:
   - `STRIPE_API_KEY` = the sandbox `sk_test_...` secret key
   - `STRIPE_WEBHOOK_SECRET` = the signing secret from step 4 (NOT the
     production endpoint's signing secret — they're different)
   - `STRIPE_PRICE_*` env vars from `rake stripe:seed_sandbox` output
6. Send a test event from the endpoint page (`checkout.session.completed`).
   `bin/staging-logs web | grep StripeWebhook` should show
   `Received event evt_...`. If you see `Signature error` instead, the
   signing secret doesn't match.

## 6. Verifying

```bash
stripe listen --forward-to localhost:4000/api/webhooks
stripe trigger checkout.session.completed --add checkout_session:metadata.kind=topup
```

Then check that a `credit_transactions` row was written with the matching
`stripe_event_id` and that `users.topup_credits_balance` increased.
