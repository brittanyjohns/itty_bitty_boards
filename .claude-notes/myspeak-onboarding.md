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
| `name`              | `ChildAccount#name` AND `ChildAccount#username` (parameterized), mirrored to `Profile#username` + `#slug` |
| `pronouns`          | `Profile#settings["pronouns"]` (jsonb)                                                    |
| `photo_data_url`    | `Profile#avatar` via Active Storage (data URL → `StringIO`)                              |
| `board_id`          | One of `basics` / `feelings` / `social` → favorited `ChildBoard`; `later` → skip          |
| `care_notes`        | `Profile#bio`                                                                             |
| `contacts[]`        | `Profile#settings["ice_contact_1..3"]` jsonb, **blank entries filtered out**              |

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

| Status | Body shape                                                                | When                              |
|--------|---------------------------------------------------------------------------|-----------------------------------|
| 201    | `Profile#safety_view` hash (same payload the public `/my/:slug` returns)  | success                           |
| 401    | `{ error: "Unauthorized" }`                                               | no/bad bearer token               |
| 403    | `{ error: "myspeak_id_limit_reached", limit, count, message }`            | Free user at the 1-profile cap    |
| 403    | `{ error: "communicator_slot_unavailable", message }`                     | plan has 0 communicator slots     |
| 422    | `{ error: "communicator_slot_unavailable", message }`                     | all communicator slots in use     |
| 422    | `{ error: "Onboarding failed", details: [...] }`                          | blank `name`, validation errors   |

**Not 402.** 402 is reserved for credit exhaustion in this codebase.

## Transactional shape

**Pre-transaction gates** (in order):

1. `User#can_create_myspeak_id?` — Profile-count cap (Free = 1).
   Returns **403 `myspeak_id_limit_reached`** if hit.
2. `Permissions::CommunicatorLimits.can_create?(user:, status: ACTIVE)`
   — slot cap from `user.settings["paid_communicator_limit"]`.
   Returns **403/422 `communicator_slot_unavailable`** if hit.
3. `name.present?` — **422** if blank.

**Inside `ActiveRecord::Base.transaction`:**

1. Compute a unique slug from `name.parameterize`, falling back to
   `<base>-2`, `<base>-3`, … up to 50 tries, then a random suffix.
   Checks `Profile.slug`, `Profile.username`, AND
   `ChildAccount.username`.
2. `current_user.communicator_accounts.create!(name:, username:, user: current_user, status: ChildAccount::ACTIVE)`
   — note `user:` is explicit (see footgun below), and **`status:`
   must be `ACTIVE`** so the communicator appears on the family
   dashboard. The model default is `sandbox`, which is the Pro
   no-login scratch space — sandbox communicators are filtered out
   of the standard dashboard view.
3. `Profile.new(profileable: child, profile_kind: "safety", username:, slug:, bio: care_notes, settings: ...)`.
4. If `photo_data_url` matches `data:<ct>;base64,<payload>`, decode
   and `avatar.attach`.
5. `profile.save!`.
6. If `board_id` ∈ `{basics, feelings, social}`, look up
   `Board.find_by(slug: "myspeak-#{board_id}")` and create a favorited
   `ChildBoard`. **Silently skipped** if the board isn't seeded —
   logs a `Rails.logger.warn`, doesn't 422.
7. `ensure_team_for(child)` — mirrors `API::ChildAccountsController#create`:
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

`spec/requests/api/v1/onboarding/myspeak_spec.rb` — 8 examples:

- happy path (child + profile + avatar + settings)
- 401 without auth
- 422 on blank name
- slug collision → `-2` suffix
- `board_id: "later"` → no `ChildBoard`
- `board_id: "basics"` with seeded board → favorited `ChildBoard`
- blank contacts filtered, numbering stays sequential
- Free user at limit → 403 `myspeak_id_limit_reached`

`Profile#generate_attachments!` is stubbed globally in the spec.
The 1×1 PNG fixture is inlined as a base64 data URL constant.

## Related code

- Controller: `app/controllers/api/v1/onboarding/myspeak_controller.rb`
- Route: `config/routes.rb` (inside `namespace :api { namespace :v1 { namespace :onboarding } }`)
- Profile public keys: `app/models/profile.rb` — `SAFETY_PUBLIC_KEYS`
- Free-tier cap: `User#can_create_myspeak_id?`, `#myspeak_id_limit`,
  `#myspeak_id_count` (`app/models/user.rb`)
- Seed: `db/seeds/myspeak_starter_boards.rb`
