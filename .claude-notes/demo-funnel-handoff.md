# Handoff: Demo Funnel (backend / itty_bitty_boards)

**Date:** 2026-06-26 · **Status:** not started
**Full plan:** `speakanyway/drafts/demo-funnel-plan.md` (this doc is self-contained; the plan adds context)
**Counterpart:** `itty-bitty-frontend/.claude-notes/demo-funnel-handoff.md` (depends on this PR — ship backend first)

## What this is

A reusable demo landing funnel. This repo provides: a `demo_campaigns` table (so campaigns are self-serve, no deploy), a public endpoint to read a campaign's copy, and a public endpoint to capture a lead email into Mailchimp tagged by campaign. The frontend builds the page that calls these.

## Decisions (already made — don't re-litigate)

- **Do NOT touch the trial or checkout/billing code.** No changes to `app/controllers/api/stripe/checkout_sessions_controller.rb` or `app/controllers/api/webhooks_controller.rb` in this phase. Trial stays 14 days, no-card, exactly as it is.
- Campaigns are **database-backed** (not ENV), so Brittany can add a conference via console/seed without a deploy, and page copy varies per campaign.
- Leads go to **Mailchimp** (tagged), not a new leads table.
- Both new endpoints are **public/unauthenticated** by design.
- Conversion attribution in this phase is via PostHog (frontend) + the Mailchimp campaign tag. Hard Stripe-based attribution is a deliberate Phase 2 and is out of scope here.

## Current state (verified 2026-06-26)

- **Checkout:** `app/controllers/api/stripe/checkout_sessions_controller.rb` — `create` requires `before_action :authenticate_token!` (line 3); trial hardcoded `trial_days = 14` (line 71). **Leave all of this alone.**
- **Mailchimp:** `app/models/mailchimp_service.rb`
  - `subscriber_hash(email)` (lines 6–8) — MD5 of downcased email.
  - `update_subscriber_tags(email, tags_to_add = [], tags_to_remove = [])` (lines 176–203) — **works on a bare email, no User needed.** This is the method to use for lead tagging. Note: in Mailchimp, tagging an email that isn't yet a list member may require adding the member first — verify against the Mailchimp client used here (`MailchimpMarketing`); if `update_list_member_tags` 404s on unknown members, upsert the member first via the same client (see `record_new_subscriber` lines 48–101 for the add-member call shape) then tag.
  - `record_new_subscriber(user, tags:)` (lines 48–101) — requires a full User; **don't** use it for leads.
- **No `Lead`/`DemoCampaign` model exists.** No campaign/attribution columns on `users` (confirmed against `db/schema.rb`).
- **Routes:** `config/routes.rb` — everything under the `api` namespace is behind `authenticate_token!`. There is no public endpoint pattern yet; these two will be the first. Stripe routes live at lines ~81–88.
- **Tests:** rspec. Checkout specs at `spec/requests/api/stripe/checkout_sessions_spec.rb`. Request specs use an `auth_headers(user)` helper — your new public endpoints should test the **no-auth** path.

## Work items

1. **Migration + model: `demo_campaigns`.**
   Columns: `slug:string` (NOT NULL, unique index), `active:boolean` (default false, NOT NULL), `heading:string`, `subhead:text`, `plan_key:string` (default `"pro"`), `trial_days:integer` (nullable — reserved for Phase 2, unused now), timestamps.
   Model: validate presence + uniqueness of `slug`; normalize slug to lowercase-with-dashes; scope `active`.

2. **Public read endpoint: `GET /api/demo_campaigns/:slug`.**
   New `API::DemoCampaignsController` **without** `authenticate_token!` (skip the before_action or place outside the authed concern — match however the app allows public actions; if all controllers inherit auth via `API::ApplicationController`, add `skip_before_action :authenticate_token!`).
   Returns `{ slug, heading, subhead, plan_key, active }` for an active campaign; `404` for missing or `active:false`. No secrets in the payload.

3. **Public write endpoint: `POST /api/demo_leads`.**
   Body: `{ email, campaign }`. New `API::DemoLeadsController` (public, same auth-skip approach).
   - Validate/normalize email (downcase, strip, basic format check). Reject invalid with `422`.
   - Tag in Mailchimp: `MailchimpService.new.update_subscriber_tags(email, ["demo-lead", "campaign:#{slug}"])` — handle the "member not found" case noted above.
   - Best-effort: do the Mailchimp call in a background job (Sidekiq — see `app/sidekiq/`) so a slow/down Mailchimp doesn't block the response. Return a generic `{ ok: true }` regardless of whether the email already existed (don't leak existence).
   - Add basic abuse protection if there's an existing rate-limit pattern (Rack::Attack?); if not, note it and move on — don't build a framework.

4. **Seed a campaign** so the frontend renders something:
   `closing-the-gap` → `active: true`, `heading`/`subhead` in SpeakAnyWay brand voice (warm, plain, "I can actually do this"; never overpromise). Put it in `db/seeds.rb` (guarded/idempotent) or a `seeds/` partial matching the repo's convention.

## Testing

- `bundle exec rspec spec/requests/api/demo_campaigns_spec.rb spec/requests/api/demo_leads_spec.rb`
- Cover, at minimum:

| Case | Endpoint | Expect |
|---|---|---|
| Active campaign | `GET /api/demo_campaigns/:slug` | 200 + copy, **no auth header** |
| Inactive/missing campaign | `GET /api/demo_campaigns/:slug` | 404 |
| Valid lead | `POST /api/demo_leads` | 200/ok, **no auth header**, Mailchimp tag enqueued (stub the service) |
| Invalid email | `POST /api/demo_leads` | 422 |
| Existing email | `POST /api/demo_leads` | generic ok (no existence leak) |

- Stub/mok `MailchimpService` in specs — don't hit the real API.
- Run the full checkout spec too (`spec/requests/api/stripe/checkout_sessions_spec.rb`) to prove you didn't disturb billing.

## Deploy notes

- One migration (`create demo_campaigns`). No new ENV vars (Mailchimp creds already set).
- Safe to ship **independently** of the frontend — adds a table + two public endpoints; nothing existing changes.
- Run seeds in the deploy so `closing-the-gap` exists in prod.

## API contract the frontend relies on (after this merges)

- `GET /api/demo_campaigns/:slug` → `200 { slug, heading, subhead, plan_key, active }` | `404`
- `POST /api/demo_leads` `{ email, campaign }` → `200 { ok: true }` | `422 { error }`
- Both are public (no `Authorization` header). Base path is the same `…/api/` the frontend already uses.

## Git rules (Brittany's)

- Run `bin/install-hooks` once at session start (installs the block-main pre-commit guard).
- `git fetch origin && git worktree add -b feat/demo-funnel-backend .claude/worktrees/demo-funnel origin/main` — branch off **origin/main**, never local main.
- Conventional Commits (`feat:`, `test:`, etc.). PR = short summary + test plan (what you ran, what passed), one concern.
- **Never push to main or merge.** Open the PR and stop.
- Commit this `.claude-notes/` doc in the PR so it survives.
