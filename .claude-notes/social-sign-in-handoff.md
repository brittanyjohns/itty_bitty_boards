# Handoff: Social sign-in — Google (backend, Phase 1)

**Date:** 2026-07-29 · **Status:** implemented, PR open (not merged) — see branch `claude/social-sign-in-impl-8d5a17`

## Implementation notes (added post-implementation)

- Token verification uses `GoogleIdTokenVerifier` (`app/services/google_id_token_verifier.rb`),
  a direct call to Google's `tokeninfo` endpoint — checked `omniauth-google-oauth2`
  first (per the plan below) but its verification logic is wired into the full
  OmniAuth request/callback middleware, which this app's bearer-token API auth
  doesn't use, so hand-rolling a plain HTTP call to `tokeninfo` (Google's own
  documented low-volume verification path) was simpler and gem-free beyond the
  two already approved.
- New-account creation reuses `User.invite!(skip_invitation: true)` (the
  `email_signup` passwordless-account mechanism) rather than `User.new.save`,
  since Devise's `:validatable` requires a password on any non-persisted
  record unless bypassed — `invite!` already handles this safely and is the
  established precedent in this codebase.
- Full details: `.claude-notes/billing-and-plans.md` § "Social sign-in — Google (Phase 1)".
**Full plan:** `../drafts/social-sign-in-plan.md` (this doc is self-contained; the plan adds context on Phase 2/3 sequencing)
**Counterpart:** `../itty-bitty-frontend/.claude-notes/social-sign-in-handoff.md`
**Issue:** none filed for the feature itself; bundles a fix for open issue #32

## Decisions (already made — don't re-litigate)

- Scope is Phase 1 only: **Google** sign-in for the parent `User` model. `ChildAccount` is untouched — it has no email/password to federate.
- Schema is generic (`provider`, `uid`) so Phase 2 (Apple) and Phase 3 (Facebook) reuse it — don't scope the migration to Google-only column names.
- Email collision with an existing password-based `User`: **auto-link by email**. Find the `User` by email, attach `provider`/`uid` to that row, sign them in — do not add a confirmation step or block. This mirrors the existing self-healing email-match pattern used for the Stripe `customer.created` webhook.
- A Google-verified email auto-marks `email_verified_at` via `mark_email_verified!` — Google's own verification counts as sufficient proof. Do not invent a new verification path; use the existing sanctioned writer.
- Bundle in this PR: remove the debug `puts "CREATE SESSIONS CONTROLLER"` at `app/controllers/users/sessions_controller.rb:14` (closes #32) since you're already touching auth code.
- New gems require asking Brittany first per this repo's CLAUDE.md — ask before adding `omniauth-google-oauth2` and `omniauth-rails_csrf_protection`, but proceed with the plan assuming she says yes (already scoped/agreed in this session).

## Current state

- Auth stack is **Devise** (`Gemfile:83,85,151`: `devise`, `devise-jwt`, `devise_invitable`). `devise-jwt` is installed but **not actually used** for API auth — don't wire OAuth through it.
- Real API auth is a static bearer token: `app/controllers/api/application_controller.rb:119-121,136-138` — `authenticate_token!` looks up `User.find_by(authentication_token: token)`. `has_secure_token :authentication_token` on `User` (`app/models/user.rb:89`) is the real credential, not a JWT.
- Real login/signup logic lives in `app/controllers/api/v1/auths_controller.rb` — NOT the Devise-generated `Users::SessionsController`/`Users::RegistrationsController`, which are near-untouched boilerplate. Existing actions to match the response shape of: `sign_up`, `email_signup` (passwordless — good precedent for OAuth-only accounts with no password), `create` (login). They all return `{ token: user.authentication_token, user: user.api_view }`.
- Routes: `config/routes.rb:481-494`, under `namespace :api { namespace :v1 { resource :auth ... } }`. `devise_for :users` is at line 33, `devise_for :child_accounts` at line 4 — leave both alone.
- `User` model Devise modules (`app/models/user.rb:65-67`): `:database_authenticatable, :registerable, :recoverable, :rememberable, :validatable, :invitable, :trackable, :jwt_authenticatable`. Not `:omniauthable` — there's dead Devise boilerplate referencing omniauth in `config/initializers/devise.rb:321-347` and `app/views/devise/shared/_links.html.erb:21-23`, but the module was never enabled and the gem was never added. Nothing to build on there; treat it as noise, not a starting point.
- `db/schema.rb:951-1013` — `users` table has no `provider`/`uid` columns. Unique indexes already exist on `email`, `authentication_token`, etc. — follow that pattern for the new composite index.
- `encrypted_password` on OAuth-only signups: Devise defaults it to `""` not null already, matching how `email_signup`'s passwordless `invite!` accounts work today — no special-casing needed.

## Work items

1. **Ask Brittany**, then add gems: `omniauth-google-oauth2`, `omniauth-rails_csrf_protection` to `Gemfile`.
2. **Migration** on `users`: add `provider` (string, nullable), `uid` (string, nullable), composite unique index `[:provider, :uid]` (partial/nullable-safe — most rows will have both nil).
3. **New endpoint** `POST /api/v1/auths/google` in `auths_controller.rb` (or a new controller if that file is getting large — match existing file size/convention). Accepts a Google ID token from the frontend, verifies it server-side (via the omniauth gem's token verification or a direct call to Google's tokeninfo endpoint — check what `omniauth-google-oauth2` exposes before hand-rolling verification).
   - Find `User` by `provider: "google", uid: <google sub>`.
   - If not found, find by `email` — if found, attach `provider`/`uid` to that row (auto-link) and proceed.
   - If neither found, create a new `User` with `provider`/`uid` set, no password, following the same post-signup side effects as `email_signup` (Stripe customer creation timing, `ensure_minimum_communicator_slot!`, `record_signup_context!`, Mailchimp/PostHog signup events — check `auths_controller.rb`'s `email_signup` action for the exact list and call the same helpers).
   - Call `mark_email_verified!` for the Google-verified email.
   - Return `{ token: user.authentication_token, user: user.api_view }` — same shape as every other auth action.
4. **Route**: add `post "auths/google"` (or similar, matching existing route naming) under the existing `namespace :api { namespace :v1 { ... } }` block near `config/routes.rb:481-494`.
5. **Cleanup**: delete `puts "CREATE SESSIONS CONTROLLER"` at `app/controllers/users/sessions_controller.rb:14`. Close #32 in this PR.
6. **ENV vars**: `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` — add to whatever ENV documentation this repo keeps (check CLAUDE.md for where ENV vars are tracked) and to Hatchbox/deploy config as a separate manual step (flag to Brittany, don't try to set production secrets yourself).

## Testing

| Scenario | Expected |
|---|---|
| New Google sign-in, no existing account | Creates `User` with `provider`/`uid`, no password, `email_verified_at` set, returns token |
| Google sign-in, email matches existing password account | Auto-links `provider`/`uid` onto existing `User`, signs in, does not create a duplicate |
| Google sign-in, `provider`+`uid` already on file | Straight login, returns token, no side effects re-run |
| Invalid/expired Google ID token | 401/422, no `User` created or modified |
| Existing password login still works | Unaffected — regression check on `auths_controller#create` |
| `ChildAccount` login | Unaffected — regression check, this feature must not touch child-account auth |

Run `bundle exec rspec spec/requests/api/v1/auths_spec.rb` (or wherever existing auth specs live — check for the actual path) plus the new Google-flow specs before opening the PR.

## Deploy notes

- Migration is additive (nullable columns, no backfill) — safe to run without downtime.
- `GOOGLE_OAUTH_CLIENT_ID`/`GOOGLE_OAUTH_CLIENT_SECRET` must exist in the target environment before the frontend PR (which depends on this one) can be tested end-to-end against staging.
- Ships independently of the frontend PR — merging this alone changes no existing behavior (new endpoint only, plus the #32 log-statement removal).

## Wrap-up

Follow this repo's CLAUDE.md for git workflow and conventions. Open the PR and stop — never merge. Commit this doc's updates (if any decisions changed during implementation) in the PR so it survives the session. Close #32 in the same PR.
