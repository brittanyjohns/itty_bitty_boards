# Ops — monitoring, APM, rate limiting

> Extracted from CLAUDE.md on 2026-07-11 (hub-and-spoke restructure).
> This file is the authoritative doc for this subsystem — update it (not CLAUDE.md)
> when behavior changes. CLAUDE.md keeps only the cross-cutting invariants.

## Monitoring / alerting

- `DiskSpaceAlertJob` (`app/sidekiq/`) runs hourly via sidekiq-cron and
  emails an admin (`ADMIN_EMAIL`) when the root disk crosses 80% (warn) or
  90% (critical). Alerts are debounced in Redis to once per severity per 6h.
  Skipped on staging, since staging shares the production EC2 box. Added
  after a disk-full outage wedged the box during a deploy.
- **External `/up` monitor (BetterStack):** HTTP monitor hits
  `https://670kd.hatchboxapp.com/up` (prod) every 3 min. Pages on failure
  via SMS to the on-call number + email to `ADMIN_EMAIL`. No Rails code
  backs this — `/up` is the stock `Rails::HealthController` route in
  `config/routes.rb`. Catches failure modes the in-app jobs can't: wedged
  puma (the 2026-05-30 outage), nginx/DNS/network, full-box down.
  Configured in BetterStack's UI; nothing in this repo to change when
  tuning the monitor. Staging is intentionally not monitored — it shares
  the prod box, so a prod alert covers both. Added after the 2026-05-30
  outage where puma was alive per systemd but all threads were wedged.

### APM — AppSignal (issue #391)

Per-request performance visibility (p95/p99 latency, slow queries/N+1, host
CPU/memory/disk, Sidekiq queue latency) on the shared t3.medium. Added as
Phase 1 of the scaling roadmap (#390) so the later sizing decisions are
data-driven. Complements — does not replace — PostHog (product analytics) and
BetterStack (uptime). This is the first true APM in the app.

- **Gem:** `appsignal` (~> 4.8). Config in `config/appsignal.yml` (ERB, all
  values from ENV — nothing hardcoded). **Active only in production/staging**
  (`active: true` there, `false` in dev/test), so it's a no-op locally and in
  CI and makes no outbound calls there.
- **Covers both processes automatically.** Sidekiq boots the full Rails app
  here, so the AppSignal Railtie starts the agent in **both** the Puma web
  process and the Sidekiq worker process — no `puma.rb`/`sidekiq.rb` edits.
  Rack middleware instruments web requests; the Sidekiq integration instruments
  jobs; `enable_minutely_probes` reports Sidekiq **queue latency** and Puma
  worker/thread stats; `enable_host_metrics` reports box-level CPU/memory/disk.
- **Prod vs staging share one box and both run `RAILS_ENV=production`**, so they
  are split by **`APPSIGNAL_APP_ENV`**, not Rails env. Prod leaves it unset
  (falls through to the `production` block); **staging must set
  `APPSIGNAL_APP_ENV=staging`** to report as a distinct environment under the
  same AppSignal app. (Mirrors the `STAGING`/`AppEnv.staging?` split used
  elsewhere, but AppSignal reads its own var.)
- **ENV vars (set in Hatchbox):**
  - Both apps: `APPSIGNAL_PUSH_API_KEY` (org Push API key — same value for both).
  - Staging only: `APPSIGNAL_APP_ENV=staging`.
  - Optional: `APPSIGNAL_APP_NAME` (defaults to `SpeakAnyWay`).
  - Local dev (optional, normally unneeded since inactive): set in
    `config/application.yml` (figaro) if you ever flip `active: true` to debug.
- **`/up` is excluded** (`ignore_actions`) so the 3-min BetterStack health
  pings don't skew throughput/latency percentiles. Params/session filtering
  drops `password`/`token`/`secret`/`jwt` so no PII/secrets reach AppSignal.

## Rate limiting (Rack::Attack, issue #30)

`config/initializers/rack_attack.rb` throttles the abuse-prone surfaces. The
middleware is inserted automatically by the gem's Railtie — there is **no**
`config.middleware.use Rack::Attack` (a manual insert would double-count).
Scope is deliberately narrow: only **WRITE / auth / AI-generation** paths are
throttled. **The AAC read / board-load / audio-PLAYBACK paths are never
throttled** (`GET /api/audio/play`, board reads) so speech output can't break —
"usage must never break." When unsure whether a route is read-critical, it's
left unthrottled.

- **Throttles (all ENV-tunable):**
  - **Auth** — sign-in (`POST /users/sign_in`, `/api/v1/users/sign_in`,
    `/api/v1/child_accounts/login`) per **IP** (`RACK_ATTACK_LOGIN_LIMIT`, 20)
    and per **email** (`RACK_ATTACK_LOGIN_EMAIL_LIMIT`, 10), window
    `RACK_ATTACK_LOGIN_PERIOD` (60s). Email is read from form-encoded (`user[email]`)
    or JSON body (rewound, rescued).
  - **Password reset** — `forgot_password`/`reset_password`/`reset_password_invite`
    per IP (`RACK_ATTACK_PASSWORD_RESET_LIMIT`, 5 per
    `RACK_ATTACK_PASSWORD_RESET_PERIOD`, 3600s).
  - **Token-access lookups** — `/api/temp-login/:token`,
    `/api/communicator_claims/:token` per IP (`RACK_ATTACK_TOKEN_LIMIT`, 20 per
    `RACK_ATTACK_TOKEN_PERIOD`, 60s). **`GET /api/generated_boards/:token` is
    intentionally NOT throttled** — the frontend polls it while a board renders.
  - **AI / audio generation** — `POST /api/*/generate*`, `generate_audio`,
    `regenerate_images`, `generate_preview_image`, and `POST /api/generated_boards`,
    per **user** (`RACK_ATTACK_AI_LIMIT`, 30 per `RACK_ATTACK_AI_PERIOD`, 60s).
    These gate on credit balance only; this adds a request-frequency ceiling.
    `/api/internal/*` is excluded (server-to-server, `INTERNAL_API_KEY`-gated).
  - **Public profile enumeration** (pre-existing) — `public_profile/ip` and
    `check_slug/ip`, now ENV-tunable via `RACK_ATTACK_PROFILE_*`.
- **Per-user discriminator** = SHA256 of the `Authorization` header token
  (the stable `authentication_token` the API auths on — see
  `API::ApplicationController#token`), hashed so no secret hits a Redis key/log;
  falls back to `ip:<addr>` when unauthenticated.
- **Safelist:** `/up` (BetterStack health check every 3 min) is never throttled.
- **429 response** is generic: `{ "error": "rate_limited", "retry_after": N }`
  with a `Retry-After` header, no rule name / internals leaked.
- **Counter store is Redis, set explicitly** — `Rack::Attack.cache.store` is a
  `RedisCacheStore` (`RACK_ATTACK_REDIS_URL` → `REDIS_URL`), **not** `Rails.cache`,
  which is `:null_store` in test and would silently disable every throttle. The
  store's `error_handler` fails open (a Redis blip can't 500 a request).
- **Disabled in the test env by default** (`Rack::Attack.enabled = !Rails.env.test?`)
  so it doesn't perturb other request specs; `spec/requests/rack_attack_spec.rb`
  opts in and swaps a `MemoryStore` per example.

