# Handoff: Frictionless paid signup + billing portal for free accounts (backend)

**Date:** 2026-06-10 · **Status:** IMPLEMENTED 2026-06-11 (this PR) — frontend counterpart is now unblocked
**Full plan:** `speakanyway/drafts/frictionless-paid-signup-plan.md` (this doc is self-contained; the plan adds context)
**Counterpart:** `itty-bitty-frontend/.claude-notes/frictionless-paid-signup-handoff.md` (blocked on THIS repo's PR)
**Issue:** itty-bitty-frontend#367

## Implementation deviations (discovered while building — the contract is unchanged)

1. **`needs_password` is `invited_to_sign_up?`, not `encrypted_password.blank?`.**
   devise_invitable assigns a *random password* inside `invite!` (`_invite`,
   models.rb:314-315), so `encrypted_password` is never blank for invited users.
   The real "passwordless" signal is the pending invitation — `valid_password?`
   returns nil until it's accepted, so no password works anyway. Same change in
   `set_password`'s already-set gate: it rejects anyone NOT `invited_to_sign_up?`.
   The API contract is unaffected (`needs_password: true` after email_signup,
   self-clears after set_password / magic link).
2. **The legacy `POST /api/set-password` (`API::UsersController#set_password`,
   force-password-reset flow) had the same invited-user trap** — naive `save`
   stored a password that could never sign in. Patched to route invited users
   through `accept_invitation!` (Brittany approved including it).
3. The basic/pro welcome mailers got the same magic-link fix as free
   (Brittany approved including them).
4. The welcome email is sent through the `User#send_welcome_email` wrapper (with
   a `raw_invitation_token:` kwarg), not the mailer directly — preserving the
   `welcome_email_sent` guard, AdminMailer notification, and Mailchimp upsert.

## Decisions (already made — don't re-litigate)

- **Email-only signup** for paid-intent visitors: they type just an email, get a passwordless account via `User.invite!`, are signed in immediately, and proceed to Stripe Checkout. Name/password/confirmation are NOT collected.
- Password is set later: optional prompt on the frontend's `/billing/success` page (new authenticated endpoint below) or via the welcome email's magic link.
- **Lazy** Stripe-customer creation at the billing-portal endpoint — no backfill task.
- Default-on, no feature flag. Free signups, partner/demo/myspeak variants, RevenueCat/IAP, and the 14-day no-card reverse trial are all unchanged.
- This PR ships independently: the new endpoints are inert until the frontend calls them.

## Current state

- `app/controllers/api/v1/auths_controller.rb#sign_up` (lines 6-49): requires email+password+confirmation; creates a Stripe customer unless `platform` is ios/android (lines 21-26); partner_pro special-casing; sends `welcome_free_email` + Mailchimp `welcome` journey + `sign_up` event; renders `{ token: user.authentication_token, user: user.api_view }`.
- `User` has Devise `:invitable` (among others). `User.invite!(email:, skip_invitation: true)` is a proven pattern — 3 call sites: `app/controllers/api/webhooks_controller.rb#handle_customer_created` (~line 118), `User.create_from_invitation` (user.rb:411), and user.rb:~372. `invite!` saves with `validate: false` (`config.validate_on_invite` unset in `config/initializers/devise.rb`), and runs `before_create :setup_new_user_free_plan`, generates `authentication_token`, and fires the `after_create` credit grant (`CreditService.ensure_initial_grant!`) — so an invited user has a usable token, free plan, and credits. devise_invitable does NOT override `active_for_authentication?`, so `sign_in user` works on a pending-invite user.
- `User.create_stripe_customer(email)` — user.rb:547.
- `reset_password_invite` (auths_controller.rb:95-117) already accepts `invitation_token` + password via `accept_invitation!` — this backs the frontend's existing `/welcome/token/:token` route. Don't change it.
- `forgot_password` works for passwordless users too: devise_invitable's `clear_reset_password_token` override auto-accepts a valid invitation after a password reset, and invitations never expire (`invite_for` unset).
- Billing portal: `app/controllers/api/subscriptions_controller.rb#billing_portal` (lines 11-18) passes `current_user.stripe_customer_id` blindly with no rescue.
- Checkout: `app/controllers/api/stripe/checkout_sessions_controller.rb` — private `ensure_customer!` at lines 227-232 lazily creates a customer; line 131 sets `paid_plan_type` (checkout owns that — email_signup must NOT).

### Known bugs being fixed here

1. **(High — plan depends on it) Dead welcome-email magic link.** `UserMailer#welcome_free_email` (`app/mailers/user_mailer.rb:55-76`) branches on `@user.raw_invitation_token`, but all callers use `deliver_later`; ActiveJob round-trips the User through GlobalID, so the virtual attribute is always nil → the `/welcome/token/<token>` link NEVER renders; everyone gets the `/users/sign-in` fallback. (Same latent bug in `welcome_basic_email`/`welcome_pro_email` — out of scope, leave them.)
2. **devise_invitable `valid_password?` trap** (gem 2.0.11, verified in vendored source): while `invitation_token` is present, `valid_password?` returns nil. A naive `current_user.update(password:)` stores a password the user can never sign in with. Set-password MUST route through `accept_invitation!`.
3. **`billing_portal` 500s** on nil `stripe_customer_id` or any `Stripe::StripeError`.
4. **`handle_customer_created` re-invite race** (`webhooks_controller.rb:113-127`): looks up by `stripe_customer_id` only, then `User.invite!(email:)`. When email_signup creates the Stripe customer, the `customer.created` webhook can race the `stripe_customer_id` save; `invite!` on an existing pending-invite user RE-invites — regenerating `invitation_token` and invalidating the magic link just emailed.

## Work items

### 1. `POST /api/v1/users/email_signup`

`config/routes.rb` (next to `post "users", to: "auths#sign_up"`, ~line 403):

```ruby
post "users/email_signup", to: "auths#email_signup"
```

`auths_controller.rb`: add `:email_signup` to the `skip_before_action :authenticate_token!` list (line 4). Implementation:

1. `email = params[:email].to_s.strip.downcase`. Reject blank or `!Devise.email_regexp.match?(email)` → 422 (invite! skips validations, so format must be checked here).
2. Duplicate: `User.exists?(email: email)` → 422 `{ error: "Email has already been taken", error_code: "email_taken" }` (the `error_code` is the frontend's contract — keep it exact). Also `rescue ActiveRecord::RecordNotUnique` around the create, rendering the same body (DB has a unique index).
3. `user = User.invite!(email: email, skip_invitation: true)`; capture `raw = user.raw_invitation_token` immediately (in-memory only — never render it to the client).
4. Stripe customer with the same platform gate as `sign_up` lines 21-26: skip when `params[:platform]` is `"ios"`/`"android"`, else `user.update(stripe_customer_id: User.create_stripe_customer(user.email))`.
5. Mirror `sign_up`'s bookkeeping: `sign_in user`; `user.update(last_sign_in_at: Time.now, last_sign_in_ip: request.remote_ip)`; `user.ensure_minimum_communicator_slot!`.
6. Emails/CRM (guarded by `user.should_send_welcome_email?` like sign_up): `welcome_free_email` **passing `raw`** (see item 2), Mailchimp `welcome` journey + `sign_up` event:
   ```ruby
   MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => "welcome" })
   MailchimpEventJob.perform_async(user.id, "sign_up")
   ```
7. Render `{ token: user.authentication_token, user: user.api_view }` — identical envelope to `sign_up`.
8. Do NOT set `paid_plan_type` (checkout_sessions#create line 131 owns it). No partner_pro/myspeak handling — this endpoint serves the paid-intent path only.

### 2. Fix the mailer magic link (bug 1)

`app/mailers/user_mailer.rb`: change to `welcome_free_email(user, raw_invitation_token = nil)`; prefer the argument when present (build `/welcome/token/#{raw_invitation_token}` link), keep the existing nil fallback to `/users/sign-in`. A String arg survives ActiveJob serialization, unlike the virtual attr. Existing callers (`user.rb:841`, `user.rb:893`) pass nothing → behavior unchanged. Delete the now-pointless `User.find(user.id)` reload and the dead `raw_invitation_token` branch logging. Check how `send_welcome_email` (user.rb:~841/893) wraps the mailer — pass the token through whichever seam is cleanest (an optional arg on the wrapper is fine), preserving the `should_send_welcome_email?` / `settings["welcome_email_sent"]` guard.

### 3. `POST /api/v1/users/set_password` (authenticated)

`config/routes.rb`: `post "users/set_password", to: "auths#set_password"` — do NOT add to `skip_before_action`, so `authenticate_token!` guards it.

```ruby
def set_password
  if current_user.encrypted_password.present?
    render json: { error: "Password already set", error_code: "password_already_set" }, status: :unprocessable_entity
    return
  end
  current_user.password = params[:password]
  current_user.password_confirmation = params[:password_confirmation]
  saved = current_user.invited_to_sign_up? ? current_user.accept_invitation! : current_user.save
  if saved && current_user.errors.empty?
    render json: { user: current_user.api_view }
  else
    render json: { error: current_user.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end
end
```

The `accept_invitation!` call is load-bearing (bug 2): it clears `invitation_token`, sets `invitation_accepted_at`, and runs validations (length/confirmation). Verify the exact return semantics of `accept_invitation!` in the vendored gem and adjust the success check accordingly.

### 4. `needs_password` on `api_view`

`app/models/user.rb` `api_view` hash (~line 1488): add `needs_password: encrypted_password.blank?`. Drives the frontend's success-page prompt; self-clears after set_password.

### 5. Billing portal: lazy customer + rescue (bug 3)

- New `User#ensure_stripe_customer!` next to `create_stripe_customer` (user.rb:547):
  ```ruby
  def ensure_stripe_customer!
    return stripe_customer_id if stripe_customer_id.present?
    update!(stripe_customer_id: User.create_stripe_customer(email))
    stripe_customer_id
  end
  ```
- Delegate the checkout controller's private `ensure_customer!` (checkout_sessions_controller.rb:227-232) to it — two callers, one implementation.
- `subscriptions_controller.rb#billing_portal`: call `current_user.ensure_stripe_customer!` first; pass `configuration: ENV["STRIPE_PORTAL_CONFIG_ID"]` only when that env is present; wrap in `rescue Stripe::StripeError` → log + 400 `{ error: "Failed to create billing portal session" }` (don't leak the Stripe message — repo rule: no internal errors in API responses).

### 6. Webhook re-invite race fix (bug 4)

`webhooks_controller.rb#handle_customer_created`: before `User.invite!`, also try `User.find_by(email: customer.email&.downcase)`; invite only if BOTH the customer-id and email lookups miss.

## Testing

Patterns: `spec/requests/api/auth_spec.rb` (auth flows), `spec/requests/api/stripe/checkout_sessions_spec.rb` (Stripe stubbing). FactoryBot.build over create where possible. Run `bundle exec rspec` — zero failures before PR.

| Spec | Cases |
|---|---|
| `spec/requests/api/v1/email_signup_spec.rb` (new) | passwordless user created (`encrypted_password` blank, `invitation_token` present, plan_type free, initial credits granted); response has `token` + `user`; Stripe customer created+persisted; skipped for `platform=ios`/`android`; `welcome_free_email` enqueued WITH a raw-token arg; Mailchimp journey + sign_up jobs enqueued; duplicate email → 422 `email_taken`; `RecordNotUnique` race → 422 `email_taken`; invalid format → 422 |
| set_password spec | 401 unauthenticated; success → password works (`User.valid_credentials?(email, pw)` returns the user — THE regression guard for the `valid_password?` trap), `invitation_accepted_at` set, `invitation_token` nil; mismatch/short password → 422 AND user still passwordless+invited; existing password → 422 `password_already_set` |
| billing portal spec (new) | existing customer → session URL, no `Stripe::Customer.create`; nil customer → created once, id persisted, session created; `Stripe::InvalidRequestError` → 400 not 500; `STRIPE_PORTAL_CONFIG_ID` set → passed as `configuration:` |
| mailer spec | `welcome_free_email(user, raw)` body contains `/welcome/token/<raw>`; without arg → `/users/sign-in` (pins current behavior) |
| webhook spec | `customer.created` whose email matches an existing user does NOT regenerate `invitation_token` |

## Deploy notes

- No migrations. No required ENV. Optional: `STRIPE_PORTAL_CONFIG_ID` (Hatchbox, prod + staging) if a dedicated portal config is wanted — default unset uses the dashboard default config.
- **Stripe dashboard prerequisite (manual, Brittany):** save a Customer-portal default configuration in BOTH test and live mode — invoice history ON, customer info update ON, payment-method update ON; don't regress paid users' cancel/update-subscription settings (shared portal). Test mode likely has no default config saved → `BillingPortal::Session.create` errors there until saved once. Document the checklist in `docs/stripe-setup.md`.
- Ships independently of the frontend; deploy staging → prod whenever green.
- `CHANGELOG.md` entry (user-facing: billing portal for free accounts; email-only signup API).

## Git rules (Brittany's)

Branch off origin/main in a worktree. Never push to main or merge PRs — open the PR and stop.
