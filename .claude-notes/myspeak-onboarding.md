# MySpeak onboarding endpoint

The `POST /api/v1/onboarding/myspeak` endpoint backs the 6-step
"set up MySpeak" wizard in the frontend. It exists so the wizard can
post everything it collected in one round-trip and let the server
fan it out into the right places — no chatty per-step API.

Frontend lives in `itty-bitty-frontend` at
`src/pages/MySpeakOnboardingPage.tsx`, route `/onboarding/myspeak`.

## What the wizard collects → where it lands

| Wizard field        | Lands on                                                                                  |
|---------------------|-------------------------------------------------------------------------------------------|
| `name`              | `ChildAccount#name`. On a **create**, also `ChildAccount#username` (parameterized) mirrored to `Profile#username`; the slug is random, never name-derived. On an **adopt**, only `#name` — the username is left alone (see Adoption below) |
| `pronouns`          | `Profile#settings["pronouns"]` (jsonb)                                                    |
| `photo_data_url`    | `Profile#avatar` via Active Storage (data URL → `StringIO`)                              |
| `board_id`          | One of `basics` / `feelings` / `social` → favorited `ChildBoard`; `later` → skip          |
| `about_me`          | `Profile#bio` — PUBLIC, printed as About Me on the open page                              |
| `emergency_notes`   | `Profile#settings["emergency_notes"]` — PRIVATE, behind the gated safety reveal           |
| `care_notes`        | Legacy clients only. Framed as safety info, so it routes to the PRIVATE `emergency_notes`, never the public bio |
| `contacts[]`        | `Profile#settings["ice_contact_1..5"]` jsonb, **blank entries filtered out**              |
| `communicator_id`   | Optional. Names which communicator to adopt when several are adoptable (see Adoption)     |

`pronouns` was added to `Profile::SAFETY_PUBLIC_KEYS` so it actually
shows on the public `/my/<slug>` safety view — without that it would
have been stored but invisible.

## Endpoint contract

**Path:** `POST /api/v1/onboarding/myspeak`
**Auth:** `Authorization: Bearer <User#authentication_token>` (the
same Devise-token pattern as every other `api/` controller — handled
by `API::ApplicationController#authenticate_token!`)
**Content-Type:** `application/json`

**Body:**

```json
{
  "name": "River Stone",
  "pronouns": "they/them",
  "photo_data_url": "data:image/png;base64,...",
  "board_id": "basics",
  "care_notes": "Loves big hugs...",
  "contacts": [
    { "name": "Sam", "relationship": "Parent", "phone": "555-0101" }
  ]
}
```

**Responses:**

| Status | Body shape                                                                       | When                                          |
|--------|----------------------------------------------------------------------------------|-----------------------------------------------|
| 201    | `Profile#safety_view` + `adopted: <bool>`                                        | success (created **or** adopted)              |
| 401    | `{ error: "Unauthorized" }`                                                      | no/bad bearer token                           |
| 403    | `{ error: "communicator_slot_unavailable", message }`                            | plan has 0 communicator slots                 |
| 422    | `{ error: "communicator_slot_unavailable", message }`                            | out of slots, nothing adoptable               |
| 422    | `{ error: "communicator_selection_required", message, communicators: [...] }`    | out of slots, **several** adoptable pages     |
| 422    | `{ error: "Onboarding failed", details: [...] }`                                 | blank `name`, validation errors               |

`adopted: true` means the page was set up on a communicator the user already
had rather than a new one — the difference the confirmation copy needs. The
status stays 201 either way: from the caller's side the MySpeak page did not
exist before the request.

The `myspeak_id_limit_reached` 403 is **gone** — #764 deleted the Profile
counter that produced it (`User#can_create_myspeak_id?` and friends no longer
exist). A communicator's MySpeak page is free on every plan; the communicator
slot is the only quota.

**Not 402.** 402 is reserved for credit exhaustion in this codebase.

## Adoption — the wizard's second mode

A Free user gets exactly **one** self-create (`demo_communicator_limit` = 1,
and `self_create_status` forces every Free self-create to `sandbox`). Adding a
communicator from the dashboard spends it — and silently mints that
communicator's MySpeak page via `ChildAccount#create_profile!`, blank. So the
user most likely to be refused here is the user whose page already exists.

#761 stopped that page being double-counted. It did not give the wizard a
second move, so the original reporter was still refused at the final step, one
slot short of a page she already owned. She retried five times
(`communicator_slot_limit_reached`, 2026-08-25).

So: **when a create is refused, the wizard sets up an existing blank page
instead.** Adoption never runs on the ordinary path.

- **Adoptable** = a communicator this user owns with either no `Profile` at
  all, or one where `Profile#never_set_up?` is true. That predicate authorizes
  an overwrite, so it is deliberately conservative — a bio someone wrote,
  pronouns, one emergency contact, an intro, or any rich-text section all make
  it a page that was set up, and the wizard leaves it alone.
- **Exactly one candidate** → adopt it.
- **Several candidates** → 422 `communicator_selection_required` with the ids.
  Guessing would write one child's emergency contacts onto another child's
  page. Pass `communicator_id` to answer it.
- **None** → the original 422 `communicator_slot_unavailable`, and
  `Analytics::CommunicatorEvents.slot_limit_reached` still fires.

Adoption **re-slugs** a page whose slug isn't already random. A Profile minted
before #774 carries a name-derived slug — back then `create_profile!` passed
`slug:` explicitly, so `Profile#ensure_slug` and its random-slug rule never ran
— and adoption is about to put emergency contacts behind that URL.
`never_set_up?` is what makes the re-slug safe: nobody has shared the old link
yet. Since #774 every creation path leaves the slug blank, so a newly minted
page is already `slug_type: "random"` and the guard skips it — adoption doesn't
churn a URL that was never guessable. Keep the guard rather than dropping it:
legacy rows still exist until `rake profiles:migrate_to_random_slugs` is run.

Adoption **renames** the communicator to the name typed in the wizard, because
`safety_view[:name]` reads `profileable.name`; without it the name the parent
just typed vanishes from her own page. It does **not** touch `username` — that
is the account handle, and on an active communicator it backs a private
sign-in.

Analytics: an adopt fires `myspeak_page_adopted`, never `communicator_account_created`
or `myspeak_page_created`. No account was created; folding it into a create
count would report growth that never happened.

**Still open (frontend, chunk C):** the wizard has no pre-check. It reads
`currentUser` only to compute a dashboard link, so create-vs-adopt is still
decided at the final POST after six steps, and there is no picker to send
`communicator_id`.

## Transactional shape

**Pre-transaction gates** (in order):

1. `name.present?` — **422** if blank. First, because a blank name fails on
   every path and answering it with a slot or picker error sends the user
   hunting for the wrong problem.
2. `Permissions::CommunicatorLimits.self_create_status(user:, requested: ACTIVE)`
   — plan-driven. A Free user's MySpeak account is a no-login `sandbox`; paid
   plans get a full `active` communicator.
3. `Permissions::CommunicatorLimits.can_create?(user:, status:)` — the slot cap
   for that status (`demo_communicator_limit` for sandbox,
   `paid_communicator_limit` + add-ons for active). **A refusal here is not the
   end** — see Adoption above. Only when nothing is adoptable does it return
   403/422 `communicator_slot_unavailable`.

**Inside `ActiveRecord::Base.transaction`:**

1. Branch on create-vs-adopt:
   - **create** (`build_communicator`) — compute a unique username from
     `name.parameterize`, falling back to `<base>-2`, `<base>-3`, … up to 50
     tries, then a random suffix; checks `Profile.slug`, `Profile.username`,
     AND `ChildAccount.username`. Then
     `current_user.communicator_accounts.create!(name:, username:, user: current_user, status:)`
     — `user:` is explicit (see footgun below) and `status:` is the plan-driven
     value from gate 2. Build `Profile.new(profileable:, username:)` with **no
     `slug:`**, so `Profile#ensure_slug` assigns the random `s-xxxxxx` safety
     slug.
   - **adopt** (`adopt_communicator`) — rename the communicator, reuse its
     `Profile` (or build one), re-slug to a random safety slug.
2. `profile.assign_attributes(profile_kind: "safety", bio: about_me, settings: ...)`.
   Settings are **merged**, not replaced: `never_set_up?` guarantees the keys
   the wizard writes are empty, but says nothing about theme settings someone
   picked, and those are not this wizard's to discard.
3. If `photo_data_url` matches `data:<ct>;base64,<payload>`, decode
   and `avatar.attach`.
4. `profile.save!`.
5. If `board_id` ∈ `{basics, feelings, social}`, look up
   `Board.find_by(slug: "myspeak-#{board_id}")` and create a favorited
   `ChildBoard`. **Silently skipped** if the board isn't seeded —
   logs a `Rails.logger.warn`, doesn't 422.
6. `ensure_team_for(child)` — mirrors `API::ChildAccountsController#create`:
   creates a `Team` named `"<name>'s Communication Team"`, attaches
   the child via `TeamAccount`, and adds `current_user` as admin
   (or `"professional"` if `current_user.professional?`).

After the transaction commits, `profile.generate_attachments!` runs
synchronously (Grover-based PDF/PNG generation) — same as
`API::ProfilesController#create`. Stubbed in specs because it's
heavy and not relevant to the wire-up.

## Starter boards

Three predefined boards back the `board_id` picker. Seed them with:

```bash
bin/rails runner db/seeds/myspeak_starter_boards.rb
```

| Wizard `board_id` | Board slug          | Name              |
|-------------------|---------------------|-------------------|
| `basics`          | `myspeak-basics`    | Basic needs       |
| `feelings`        | `myspeak-feelings`  | Feelings & needs  |
| `social`          | `myspeak-social`    | Out & about       |
| `later`           | (no attachment)     | —                 |

The seed creates **empty** boards (no tiles). Admin populates tiles
in the editor when ready. If you raise this to full seeded tiles
later, the existing `Board#find_or_create_images_from_word_list`
helper is the right entry point — it enqueues image-gen jobs, so
**don't** call it from tests.

The seed is idempotent — `find_by(slug:)` then `assign_attributes` +
`save!`. Safe to re-run.

## Footguns you'll hit

### `communicator_accounts` uses `owner_id`, not `user_id`

The `User#communicator_accounts` association is
`class_name: "ChildAccount", foreign_key: "owner_id"`. So
`current_user.communicator_accounts.create!(...)` sets `owner_id`
but **leaves `user_id` nil** unless you pass it explicitly.

`ChildAccount#api_view` reads `cached_user = user` and calls
`cached_user.pro?` — nil → `NoMethodError`. `Profile#safety_view`
calls `child.api_view` at the end, so a 200 OK turns into a 500
without the explicit `user:`.

The controller sets `user: current_user` on create. There's a
matching `Profile.generate_with_username` (`app/models/profile.rb`)
that uses the same association without setting `user` — pre-existing,
out of scope here, worth fixing separately.

### `Profile#set_kind` only overrides for `User` profileables

`Profile#set_kind` flips `profile_kind` to `"public_page"` when
`profileable_type == "User"`. Our profileable is `ChildAccount`, so
the explicit `profile_kind: "safety"` we set is preserved. Don't
change the callback without re-checking this.

### `Profile#generate_attachments!` is synchronous

Calls Grover (HTML → PDF/PNG). Cheap in dev, can stall under load.
If you see onboarding latency spikes, this is the first place to
look — move it to a Sidekiq job and return faster.

## Tests

`spec/requests/api/v1/onboarding/myspeak_spec.rb` covers the create path
(happy path, 401, blank name, username collision, random slug, board attach,
contact filtering, avatar fallback, paid vs Free status) and the adoption
path — adopt a blank page, adopt a communicator with no page, re-slug on
adopt, rename on adopt, adopt-not-create analytics, refuse to overwrite a
page that was set up, `communicator_selection_required` with several
candidates, and `communicator_id` picking one.

`Profile#never_set_up?` has its own unit coverage in
`spec/models/profile_spec.rb` — the "no" cases are the ones that matter,
since a false positive there overwrites someone's page.

`Profile#generate_attachments!` is stubbed globally in the request spec.
The 1×1 PNG fixture is inlined as a base64 data URL constant. Build the
auto-minted page with `Profile.create!` rather than
`ChildAccount#create_profile!` — the latter calls `set_fake_avatar`, which
fetches from ui-avatars.com.

## Related code

- Controller: `app/controllers/api/v1/onboarding/myspeak_controller.rb`
- Route: `config/routes.rb` (inside `namespace :api { namespace :v1 { namespace :onboarding } }`)
- Profile public keys: `app/models/profile.rb` — `SAFETY_PUBLIC_KEYS`
- Adoption predicate: `Profile#never_set_up?` (`app/models/profile.rb`)
- Slot caps: `Permissions::CommunicatorLimits`
  (`app/helpers/permissions/communicator_limits.rb`), plan defaults in
  `User::FREE_PLAN_LIMITS` and friends (`app/models/user.rb`)
- Analytics: `Analytics::CommunicatorEvents`
  (`app/models/analytics/communicator_events.rb`)
- Seed: `db/seeds/myspeak_starter_boards.rb`
