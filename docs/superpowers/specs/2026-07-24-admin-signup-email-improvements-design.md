# Admin signup + plan-change notification emails

Date: 2026-07-24
Status: approved, ready for implementation plan

## Problem

`AdminMailer#new_user_email` is the "SpeakAnyWay has a new user!" alert sent to
`ADMIN_EMAIL`. Two things are wrong with it.

**It fires on things that are not new users.** The mailer is invoked from three
places inside `User`:

| Call site | Line |
|---|---|
| `send_general_welcome_email` | `app/models/user.rb:1016` |
| `send_welcome_email` | `app/models/user.rb:1056` |
| `send_welcome_receipt_email` | `app/models/user.rb:1338` |

`send_plan_welcome_email_once!` calls `send_welcome_email`, so a Stripe
trial→active transition, a RevenueCat in-app purchase, and a `basic`→`pro`
upgrade each send an email subjected "New user signed up for SpeakAnyWay AAC!!".
The admin dashboard's "Send welcome email" button
(`app/controllers/admin/users_controller.rb:136`) does the same for accounts
that are months old.

**It carries almost no information.** The body is name, email, role, plan_type,
plan_status, and `tokens`. There are no links, no indication of which signup
flow or platform the account came from, and `tokens` is the legacy field —
credits are the real balance now, so that number actively misleads.

Signup platform is already sent by the frontend on both signup endpoints
(`app/controllers/api/v1/auths_controller.rb:8` and `:63`), used to skip Stripe
customer creation and to tag the PostHog event, and then discarded. It is never
persisted, so the email cannot report it today.

## Goals

1. The new-user alert fires exactly once per genuinely new account, and never
   for an upgrade or a manual welcome-email resend.
2. The alert carries enough context to act on without opening the admin
   dashboard first — and links straight to the dashboard and to Stripe when it
   is not enough.
3. Upgrades get their own, correctly-labelled email.

## Non-goals

- Team invitees do not trigger a new-user alert. The call is already
  deliberately commented out at `app/models/user.rb:1115`; this design keeps
  that behavior and leaves it as a one-line change if it is wanted later.
- Downgrades, cancellations, and expirations send no admin email.
- No backfill of signup context onto existing accounts.
- No change to any user-facing welcome email.

## Design

### 1. Persist signup context

Add to `User`:

```ruby
def record_signup_context!(platform: nil, method: nil)
  settings["signup_platform"] = platform.presence || "web"
  settings["signup_method"]   = method
  save
end
```

It persists on its own rather than relying on a later save, so the values are
durable even when `notify_admin_of_signup!` returns early.

`settings` (jsonb) rather than columns: no migration, no backfill decision, and
nothing downstream needs to query it. Called from the three account-creation
points:

| Creation point | `method` |
|---|---|
| `API::V1::AuthsController#sign_up` | `"standard"` |
| `API::V1::AuthsController#email_signup` | `"email_only"` |
| `User.create_from_email` | `"myspeak"` when a slug is present, else `"email_import"` |

`create_from_email` receives no platform, so it stores the `"web"` default.
Accounts created before this ships have neither key; the template renders
"unknown" for both.

### 2. One notifier, fired once, at account creation

Remove the `AdminMailer.new_user_email` call from all three welcome-email
methods. Add:

```ruby
def notify_admin_of_signup!
  return if admin?
  return if settings["admin_new_user_notified"]
  AdminMailer.new_user_email(self).deliver_later
  settings["admin_new_user_notified"] = true
  save
rescue => e
  Rails.logger.error("Admin new-user notification failed for #{id}: #{e.message}")
end
```

Rescued and logged, per the cross-cutting invariant that side-channel failures
never break a request. Called immediately after `record_signup_context!` at each
of the three creation points, so the settings the email reads are already
written when the job runs.

The `admin_new_user_notified` flag makes this idempotent: an account that
somehow reaches two creation paths still produces one alert.

Consequences: upgrades no longer send a new-user email; the admin dashboard's
"Send welcome email" button no longer fires a false new-signup alert;
overlapping welcome paths cannot double-send.

### 3. Rewrite `new_user_email`

**Subject:** `New signup: jane@example.com (Free · ios)` — plan and platform in
the subject so the inbox is scannable without opening anything. On staging
(`AppEnv.staging?`) the subject is prefixed `[STAGING]` rather than suppressed,
so the change can be verified end-to-end before it reaches production.

**Body**, as a table styled after `partner_pilot_review.html.erb`:

- **Who** — name, email, user ID, role
- **How** — `settings["signup_method"]`, `settings["signup_platform"]`,
  `created_at`
- **Plan** — `plan_type`, `plan_status`
- **Where** — coarse city/region/country from
  `IpGeolocation.coarse(current_sign_in_ip)`
- **Links** — admin dashboard (`/admin/users/:id`), Stripe customer, and Stripe
  subscription when `stripe_subscription_id` is present

`tokens` is dropped from the body entirely.

The geolocation lookup resolves in the mailer method, not the view. It runs
inside the `deliver_later` job, so it is off the request path.
`IpGeolocation.coarse` already returns `nil` on any provider error, timeout, or
private/loopback IP; the template omits the whole row when it is `nil`.

### 4. New `plan_change_email`

```ruby
AdminMailer#plan_change_email(user, from_plan:, to_plan:, source:)
```

Fired from `User#send_plan_welcome_email_once!` (`app/models/user.rb:1350`),
which is the single choke point covering all three upgrade paths:

| Caller | `source` |
|---|---|
| `API::WebhooksController` (Stripe) `:516` | `"stripe"` |
| `RevenueCat::WebhookProcessor` `:144` | `"revenuecat"` |
| `API::BillingController` `:48` | `"billing_api"` |

`source` is a new optional keyword argument on `send_plan_welcome_email_once!`,
defaulting to `"unknown"`, passed explicitly by those three callers.

Two properties come for free from firing here:

- **Idempotency** — the method already returns early when
  `settings["plan_welcome_sent_for"]` includes the plan, so webhook re-deliveries
  and renewals do not re-email while a real plan change does.
- **Upgrades only** — the Stripe and RevenueCat callers only reach it on a
  transition into `trialing` or `active`, so downgrades never trigger it.

A guard skips the email when `to_plan` is a free tier, so the billing-API path
cannot produce a "plan change" alert for a free account.

`from_plan` is derived from `Array(settings["plan_welcome_sent_for"]).last`,
falling back to `"free"`. **Known limitation, accepted:** for an account that
upgraded before this ships, that array may be empty, so the email will read
"free" even if the user was on Basic. This is an alert, not a ledger; a real
`previous_plan_type` column is the fix if it ever matters.

**Subject:** `Upgrade: jane@example.com → Pro (Stripe)`

**Body:** plan from→to, `settings["billing_interval"]`,
`settings["trial_ends_at"]` when present, `monthly_price` / `yearly_price`, and
the same admin dashboard + Stripe customer + Stripe subscription links as the
new-user email. Same `[STAGING]` subject prefix rule.

### 5. Drive-by fix

`app/views/admin_mailer/new_feedback_email.erb:5` renders the header
"SpeakAnyWay has a new user! 🎉" on the feedback email — a copy-paste from
`new_user_email`. One-line copy correction.

## Testing

- `spec/mailers/admin_mailer_spec.rb` — for both mailers: subject shape,
  recipient, admin and Stripe links present, Stripe subscription link omitted
  when there is no subscription, location row omitted for a private IP,
  `[STAGING]` prefix when `AppEnv.staging?` is stubbed true.
- `spec/models/user_spec.rb` — `record_signup_context!` writes both keys and
  defaults platform to `"web"`; `notify_admin_of_signup!` sends once, is a no-op
  on a second call, and is a no-op for an admin.
- Request specs on `sign_up` and `email_signup` — exactly one admin email
  enqueued, and `settings["signup_platform"]` / `["signup_method"]` written with
  the values the request supplied.
- Regression specs — `send_welcome_email` and `send_plan_welcome_email_once!` no
  longer enqueue `new_user_email`; `send_plan_welcome_email_once!` enqueues
  `plan_change_email` for a paid plan and does not for a free one.
- New `spec/mailers/previews/admin_mailer_preview.rb` covering both templates,
  matching the existing preview files, so the rendering can be eyeballed
  locally.

## Documentation

- `.claude-notes/ops.md` — a short "admin notification emails" section. That
  spoke already owns `disk_space_alert`, so the admin alert surface belongs
  there rather than in a new spoke.
- `CHANGELOG.md` — entry under `[Unreleased]`.

## Files touched

| File | Change |
|---|---|
| `app/models/user.rb` | add `record_signup_context!`, `notify_admin_of_signup!`; remove three `AdminMailer.new_user_email` calls; add `source:` kwarg + `plan_change_email` call to `send_plan_welcome_email_once!` |
| `app/mailers/admin_mailer.rb` | rewrite `new_user_email`, add `plan_change_email`, staging subject prefix, geolocation lookup |
| `app/views/admin_mailer/new_user_email.html.erb` | rewrite |
| `app/views/admin_mailer/plan_change_email.html.erb` | new |
| `app/views/admin_mailer/new_feedback_email.erb` | header copy fix |
| `app/controllers/api/v1/auths_controller.rb` | call the two new model methods in `sign_up` and `email_signup` |
| `app/controllers/api/webhooks_controller.rb` | pass `source: "stripe"` |
| `app/services/revenue_cat/webhook_processor.rb` | pass `source: "revenuecat"` |
| `app/controllers/api/billing_controller.rb` | pass `source: "billing_api"` |
| specs, preview, `.claude-notes/ops.md`, `CHANGELOG.md` | as above |
