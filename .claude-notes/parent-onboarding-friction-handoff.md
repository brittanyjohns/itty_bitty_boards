# Handoff: parent onboarding friction (backend)

**Date:** 2026-09-03 · **Status:** shipped (backend) — all three work items implemented
**Full plan:** `../drafts/parent-onboarding-friction-plan.md` (this doc is self-contained; the plan adds context)
**Counterpart:** `../itty-bitty-frontend/.claude-notes/parent-onboarding-friction-handoff.md`
**Issue:** none filed — GitHub PAT expired at time of writing. Body ready at `../drafts/create-a-communicator-parent-new-be-issue-draft.md`

## Why this exists

A persona walkthrough as a first-time AAC parent hit a hard stop: she named her son Leo, the frontend auto-filled the username `leo`, and creation 422'd because `leo` belongs to a stranger's communicator. She had zero communicators of her own. Every common child's first name is already taken, and it gets worse with every signup — this lands at the exact moment of activation on the least technical user we have.

## Decisions (already made — don't re-litigate)

- **Username uniqueness stays global.** Scoping it per-owner was considered and rejected *for now*: communicator sign-in is `ChildAccount.find_by(username:, passcode:)` with no owner context (`app/models/child_account.rb:321-325`), and `app/controllers/api/v1/child_auths_controller.rb:5` captures a `parent_id` param it never uses. Scoping uniqueness without first adding owner context to the login form and the lookup would make that query ambiguous across owners and break sign-in. That's a separate project.
- **No auto-suffixing on collision.** Don't silently turn `leo` into `leo2` — the parent should see and choose.
- **Error payload changes are additive.** Add a new key; don't change the type of `error` or `errors`, which the current frontend reads.

## Current state

### Username uniqueness
- `app/models/child_account.rb:87` — `validates :username, presence: true, uniqueness: true`. No `scope:`.
- `db/schema.rb:385` — `t.index ["username"], unique: true`. A plain unique index on `username` alone.
- `spec/models/child_account_spec.rb:39-43` covers uniqueness but creates both records under the **same** `user:`, so nothing currently proves cross-owner behaviour either way.

### Create-failure error shape
`app/controllers/api/child_accounts_controller.rb:430-434`:
```ruby
else
  Rails.logger.info "Invalid Child Account: errors: #{@child_account.errors.inspect}"
  message = @child_account.errors.full_messages.join(", ")
  render json: { error: message, errors: message }, status: :unprocessable_content
end
```
`full_messages.join(", ")` flattens `ActiveModel::Errors` to one string, duplicated under both keys. No field keys, so the frontend can't attach the error to an input — it just prints the string.

The controller has a local helper `account_error_payload` (lines 680-683) with the same flat shape, used by `update` and the other mutations but **not** by `create`.

There is **no shared error-rendering concern** in this codebase; shape varies per controller. Field-keyed precedent to follow: `app/controllers/api/internal/boards_controller.rb:50` and `:195` render `@board.errors` directly, which serializes as `{"username":["has already been taken"]}`.

### Routes
`config/routes.rb:424-445` — the `child_accounts` block has `keep_signable` on `collection` and a set of `member` routes (`assign_boards`, `lend`, `claim_link`, …). **No availability endpoint exists** — grepping `routes.rb` for `username` returns nothing. Communicator auth lives separately at `config/routes.rb:539-541` → `child_auths#*`.

### `age_band` and the AAC profile
- Allowed values: `app/services/communicator_profile.rb:12` — `AGE_BANDS = %w[4-6 7-10 11-14 15-18 adult].freeze`.
- **Not** a Rails enum, **not** a column, **not** a DB constraint. `age_band` lives in the `details` jsonb column (`db/schema.rb:364`, no default), exposed via metaprogrammed accessors at `app/models/child_account.rb:141-158`, normalized at `:175-199`, validated by a hand-rolled inclusion check at `:201-212`.
- `CommunicatorProfile#band_for_age` case starts `when 0..6 then "4-6"` (`communicator_profile.rb:148-158`); `young?` checks `%w[4-6 7-10]` (`:80`).
- Adding a band needs **no migration** — it's a constant plus two method updates.
- Existing coverage: `spec/models/child_account_aac_profile_spec.rb` (e.g. asserts `age_band = "99-100"` is invalid).

### Things that are already fine — don't "fix" them
- **The AAC profile fields are consumed.** `age_band`, `aac_level`, `vocab_type` and `glp_stage` all feed `CommunicatorProfile#prompt_guidance` (`communicator_profile.rb:111-116`), which shapes AI prompts — core-vocabulary weighting (`:168-182`), vocab balance (`:184-193`), GLP staging (`:198-213`). Consumers: `app/sidekiq/generate_board_job.rb:17`, `app/sidekiq/build_board_set_job.rb:122`, `app/controllers/api/boards_controller.rb:947,980`, `app/controllers/api/v1/board_builder_controller.rb:273,298,311`, `app/models/board.rb:3028`.
- `age` is read at `communicator_profile.rb:47` from `details["age"]`. It has no typed accessor or validation, but it works.
- `gender` is written into `details` by the client and never read by this backend (`grep -ri gender app/` → zero matches). Harmless passthrough; leave it.

## Work items

### 1. Username availability endpoint

Add to the `collection` block at `config/routes.rb:424-445`:
```ruby
get "username_available"
```

New action on `app/controllers/api/child_accounts_controller.rb`. Follow the controller's existing auth pattern — a signed-in user is fine; this must not be public.

```ruby
def username_available
  raw = params[:username].to_s.strip.downcase
  taken = ChildAccount.exists?(username: raw)
  render json: {
    username: raw,
    available: raw.present? && !taken,
    suggestions: taken ? username_suggestions(raw) : []
  }
end
```

`username_suggestions` should return **up to 3** candidates that are themselves confirmed free — e.g. `leo2`, `leo-r` (owner's last initial where available), `leo-2026`. Query once with `ChildAccount.where(username: candidates).pluck(:username)` rather than N `exists?` calls.

Guard against enumeration: this reveals whether an arbitrary username exists. Requiring auth is the mitigation; also rate-limit if the app has a pattern for it, and do **not** return anything about who owns a taken name.

### 2. Field-keyed errors on the create failure branch

`app/controllers/api/child_accounts_controller.rb:430-434` — keep both existing keys exactly as they are, add one:
```ruby
message = @child_account.errors.full_messages.join(", ")
render json: {
  error: message,
  errors: message,
  field_errors: @child_account.errors.to_hash(true)
}, status: :unprocessable_content
```
`to_hash(true)` gives `{username: ["has already been taken"]}` — full sentences keyed by field.

Do the same in `account_error_payload` (lines 680-683) so `update` benefits too. **Additive by design**: the frontend prefers `field_errors` when present and falls back to the old string, so the two repos ship in either order.

### 3. Add an `under-4` age band

Early intervention routinely starts AAC at 2. A parent of a 2- or 3-year-old — the most common brand-new-AAC-parent profile — currently has no correct option and either leaves it blank or picks `4-6` and pollutes the data.

- `app/services/communicator_profile.rb:12` — prepend `under-4` to `AGE_BANDS`.
- `:148-158` `band_for_age` — the case currently opens `when 0..6 then "4-6"`. Split it: `when 0..3 then "under-4"`, `when 4..6 then "4-6"`.
- `:80` `young?` — decide whether `under-4` counts as young. It should; a 3-year-old is at least as young as a 5-year-old. Add it to the array.
- Check `prompt_guidance`'s age handling (`:111-116` and the guidance builders below it) for anything that assumes `4-6` is the floor.

The frontend renders the band list from its own locale strings, so the counterpart handoff covers adding the label — the two need to agree on the value string `under-4`.

## Not in this handoff

- **Voice defaulting from `age_band`.** `polly:kevin` is a lazy default at `app/models/child_account.rb:1054-1058` that never consults `age_band` — a 15–18 communicator gets the same voice as a 4-year-old. That belongs to **#840**, and this walkthrough sharpens it: the claim isn't "nothing reads `age_band`" (it does, for AI prompts) but specifically "voice defaulting ignores it." Worth editing #840 to say that.
- **Starter board descriptions.** Three of the four `/start` starters have no `description`; "SpeakAnyWay Core 2026" carries a clinical paragraph written for an SLP. These are `public_boards` DB content, not code — a content fix for whoever owns that data.

## Testing

| Case | Expect |
|---|---|
| `GET username_available?username=<free>` | `available: true`, `suggestions: []` |
| `GET username_available?username=<taken>` | `available: false`, 1–3 suggestions, each confirmed free |
| `GET username_available?username=` (blank) | `available: false`, no crash |
| `GET username_available` unauthenticated | rejected per the controller's existing auth pattern |
| `POST /api/child_accounts` with a taken username | 422; `error` and `errors` unchanged flat strings; `field_errors == {"username" => ["has already been taken"]}` |
| `POST` with two invalid fields | `field_errors` has both keys |
| `age_band: "under-4"` | valid |
| `band_for_age(3)` / `(4)` | `"under-4"` / `"4-6"` |
| `young?` with `under-4` | true |

Add a request spec for the endpoint and for the `field_errors` shape — neither exists today. Extend `spec/models/child_account_aac_profile_spec.rb` for the band. Run the `child_accounts` request specs and the AAC profile specs.

## Deploy notes

No migration. No new ENV vars. No seed changes. Ships independently of the frontend in either order — every change here is additive.

## Wrap-up

Follow this repo's CLAUDE.md for git workflow and conventions. Open the PR and stop — never merge. Commit this doc in the PR so it survives the session.

## Implementation notes (what actually shipped)

All three work items landed as specified. Deltas worth knowing:

- **The endpoint parameterizes, it doesn't just downcase.**
  `normalized_username` is `strip.downcase.parameterize`, matching
  `ChildAccount#set_username_if_missing` — so "Leo Rivera" answers about
  `leo-rivera`, the same string the create path would derive. The response
  echoes `username` as the normalized value; the client should submit that.
- **Throttled as `username_available/user`, not per IP.**
  `config/initializers/rack_attack.rb` uses the existing `user_discriminator`
  (SHA256 of the auth token) — a school or clinic puts many legitimate parents
  behind one address. `RACK_ATTACK_USERNAME_CHECK_LIMIT` (20) over
  `RACK_ATTACK_PROFILE_PERIOD` (60s). Documented in `.claude-notes/ops.md`.
- **`account_error_payload` takes the record explicitly** (`record:`), because
  it `reload`s `@child_account` — which discards the very errors `field_errors`
  is built from. It is therefore also correctly ABSENT from the controller's
  many hand-written refusals ("Passwords do not match", "End the loan first"),
  which have no validation behind them. `promote_to_loaner` and `lend` pass
  `record: e.record` from their `RecordInvalid` rescues.
- **`under-4` also needed a `VoiceService::DEFAULT_VOICE_BY_AGE_BAND` row.**
  Not in the original work item, but required: an unmapped band takes
  `DEFAULT_VOICE_FOR_UNKNOWN_BAND`, the ADULT voice, so adding the band without
  the map would have handed a 3-year-old an adult voice — the exact failure
  that map exists to prevent. `under-4` maps to `polly:kevin`, and a spec
  asserts the map covers every band in `AGE_BANDS`. This does not reopen #840.
- `prompt_guidance` needed no change: `under-4` is `young?`, therefore
  `emerging?` with no explicit `aac_level`, therefore core-vocabulary-first.

Specs: `spec/requests/api/child_accounts_username_available_spec.rb`,
`spec/requests/api/child_accounts_field_errors_spec.rb`, plus additions to
`spec/models/child_account_aac_profile_spec.rb` and
`spec/services/communicator_profile_spec.rb`.

**Still open — the frontend counterpart**
(`../itty-bitty-frontend/.claude-notes/parent-onboarding-friction-handoff.md`):
call the endpoint from the create form, prefer `field_errors` over the flat
string, and add the `under-4` label. The value string is `under-4`.
