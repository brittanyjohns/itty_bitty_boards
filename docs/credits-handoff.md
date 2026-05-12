# SpeakAnyWay AI Credits — UI + Marketing Handoff

**Audience:** Design, Frontend, Marketing
**Status:** Phase 1 (backend ledger) shipped; UI work begins Phase 2
**Owner:** Brittany Johns

---

## 1. What's changing in one paragraph

AI features (image generation, scenario builder, menu builder, screenshot
imports, word suggestions, board formatting, image edits and variations) now
run on **credits** instead of a flat monthly action cap. Every subscription
tier includes a monthly credit allowance, and users can buy ad-hoc credit
packs anytime — like adding minutes to a prepaid phone. Different AI
features cost different amounts of credits, weighted by how expensive they
actually are to run, so big jobs (full menu generation) cost more than
small ones (a single word suggestion).

---

## 2. Plan tiers (proposed)

| Plan | Monthly credits | Approx. usage |
|---|---|---|
| **Free** | 10 | 2 AI images, or 10 word suggestions |
| **MySpeak** | 50 | 10 AI images, or 50 word suggestions |
| **Basic** | 400 | 80 AI images, or one full menu + 30 images |
| **Pro** | 1,500 | 300 AI images, or many full menus |

> Dollar prices unchanged from current pricing — credit amounts are the new
> dimension. **Final numbers are a marketing/leadership decision; the engine
> reads `monthly_credits` from each Stripe Price's metadata, so we can tune
> without a redeploy.**

---

## 3. Top-up credit packs (proposed)

| Pack | Credits | Price | Effective $/credit |
|---|---|---|---|
| **Small** | 100 | $4.99 | $0.0499 |
| **Medium** | 500 | $19.99 | $0.0400 |
| **Large** | 1,500 | $49.99 | $0.0333 |

- Top-ups are **one-time purchases** (Stripe Checkout, mode=payment).
- Top-up credits **do not expire** (or expire after 12 months — decision
  pending).
- Top-ups are spent **after** plan credits run out.

---

## 4. Feature credit costs

These are the costs the server charges per AI call. Frontend cannot pick the
cost — it's authoritative server-side in `CreditService::FEATURE_COSTS`.

| Feature | Credits | Plain English |
|---|---|---|
| Word suggestion | **1** | A single AI-suggested word for a board |
| Board formatting | **2** | AI cleanup of an existing board's layout |
| Image edit | **3** | Modify an existing image with AI |
| Image variation | **3** | Generate a variation of an existing image |
| AI image generation | **5** | A new image from a text prompt |
| Screenshot import | **5** | Import a board from a screenshot via AI |
| Scenario builder | **10** | Generate a full board from a scenario description |
| Menu builder | **10** | Generate a board from a restaurant menu photo |

---

## 5. Plain-English rules

- **Plan credits reset every billing period.** They do not roll over. If a
  Pro user uses 200 of 1,500, the other 1,300 are gone on renewal day.
- **Top-up credits do not expire** (or expire after 12 months — TBD).
- **Plan credits are spent first**, then top-up credits. Top-ups are a
  safety net for heavy months.
- **No surprise charges.** Once a user is out of credits, AI features block
  with a "Buy more" prompt. Nothing is auto-billed.
- **Canceling a subscription** keeps any unused top-up credits but
  immediately expires plan credits.
- **Refunds for failed AI calls** are automatic (e.g. if OpenAI errors mid-
  job, the credits come back to the same bucket they were spent from).

---

## 6. UX flows that need design

### a. Credits balance widget (persistent)
Visible in the account header / sidebar. Shows total balance, plan vs. top-up
breakdown on hover, link to billing page.

> Backend source: `GET /api/me/credits` →
> `{ plan: 250, topup: 100, total: 350, reset_at: "2026-06-01T00:00:00Z", plan_type: "basic" }`

### b. "Out of credits" modal
Triggered when the API returns `HTTP 402` with
`{ error: "insufficient_credits", needed: 5, balance: 2 }`. Two CTAs:
- **Buy credits** (primary) → opens top-up picker
- **Upgrade plan** (secondary) → opens existing plan picker

Show what they were trying to do and how many credits they need.

### c. Billing page additions
- **Credits panel** at top: large balance number, breakdown, reset date.
- **Buy credits** button → picker with the three pack sizes from §3.
- **Transaction history** table — credit grants, purchases, spends, expiries,
  refunds. Filterable by type. Backend: `GET /api/me/credit_transactions`.
- **Plan comparison** — credit allowance becomes a column in the existing
  plan-comparison table on the pricing page.

### d. Post-purchase success screen
After a successful top-up Checkout, land on a screen that shows the new
balance and a "Back to where I was" link (carry the redirect through
metadata).

### e. Low-balance warning (email + in-app)
Triggered when plan balance drops below 10% of allowance. Surfaces same
"Buy credits" / "Upgrade" choice.

---

## 7. Marketing message suggestions

> **Pricing-page hero**
> "Pay for what you use. Every plan includes a monthly allowance of AI
> credits — and when you need more, buy a pack. No surprise charges, ever."

> **Upsell modal (out of credits)**
> "You're out of AI credits for this month. Grab a credit pack to keep
> going, or upgrade your plan for a bigger monthly allowance."

> **Renewal-day email**
> "Your monthly credits have refreshed. You have [N] AI credits to use
> through [date]. Heavy month coming up? You can top up anytime."

> **Low-balance email (10% remaining)**
> "Heads up — you have [N] AI credits left this month. They reset on
> [date], or you can top up now."

> **Top-up purchase receipt**
> "Thanks! [N] credits have been added to your account. Top-up credits
> never expire."

---

## 8. FAQs the support team will get

**Do unused plan credits roll over?**
No. Plan credits reset at the start of each billing period to keep accounting
predictable. If you want to save credits for a heavy month, buy a top-up pack
— those don't expire.

**What happens to my top-up credits if I cancel my subscription?**
You keep them. They don't expire when your subscription ends.

**Can I get a refund on a credit pack?**
Within 14 days of purchase, yes, if the credits are unused. After that,
case-by-case via support.

**Why did that AI image cost 5 credits and a word suggestion only 1?**
Different features cost different amounts of compute and OpenAI tokens
behind the scenes. Generating a full image is more expensive than suggesting
a single word, so we pass that through.

**If an AI image fails to generate, do I lose the credits?**
No — the system automatically refunds credits for any failed AI call.

**How do I see where my credits are going?**
Account → Billing → Transaction History. Every grant, spend, and refund is
listed there.

---

## 9. Rollout timeline (phased)

| Phase | What ships | User-visible? |
|---|---|---|
| **1** ✅ | Backend ledger, service, shadow mode telemetry | No |
| **2** ✅ backend | Top-up Checkout endpoint + webhook handler. Frontend "Buy credits" UI still needed. | Yes (additive) once UI lands |
| **3** | Switch AI gating from Redis counter → credits. `402` responses. | Yes — change of behavior |
| **4** | Plan grants on invoice renewal webhook | No (internal) |
| **5** | Optional: Stripe metered overage | Decision pending |

---

## 10. Open decisions for marketing / leadership

- [ ] Final dollar prices for the three top-up packs
- [ ] Final per-tier monthly credit amounts (the §2 table above is a draft)
- [ ] Do top-up credits expire after 12 months, or never?
- [ ] Launch promo? (e.g. "First top-up: double credits")
- [ ] Should Pro users get a "soft overage" (auto-bill) instead of a hard
  block, or is the same buy-a-pack flow fine?
- [ ] Mobile (RevenueCat) top-up SKUs — Apple/Google's IAP cuts will affect
  these prices. Out of scope for v1.
- [ ] In-app messaging when a heavy power user hits zero mid-session — copy
  + frequency cap.

---

**Engineering contact:** see `app/services/credit_service.rb` for the
authoritative cost table and `README.md` → "AI credits" for the technical
overview. The credit ledger is `credit_transactions`; balances are denormalized
onto `users` for fast reads.
