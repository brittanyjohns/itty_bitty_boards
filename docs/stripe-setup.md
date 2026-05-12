# Stripe setup — AI credits

Every environment (test, live) needs these Stripe objects configured the
same way. The webhook and `CreditService` read metadata from Stripe — there
are no hard-coded plan or pack values in the app.

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

## 3. Webhook endpoint

There's already a Stripe webhook configured at `/api/webhooks` that uses
`STRIPE_WEBHOOK_SECRET`. The following events must be enabled:

- `checkout.session.completed`
- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `customer.subscription.paused`
- `customer.created`
- `invoice.payment_succeeded` *(Phase 4 — for plan-credit renewal grants)*

## 4. Verifying

```bash
stripe listen --forward-to localhost:4000/api/webhooks
stripe trigger checkout.session.completed --add checkout_session:metadata.kind=topup
```

Then check that a `credit_transactions` row was written with the matching
`stripe_event_id` and that `users.topup_credits_balance` increased.
