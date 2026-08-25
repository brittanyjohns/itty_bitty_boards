# Handoff: Gestalt Language Support (backend)

**Date:** 2026-06-18 · **Status:** shipped (backend complete; frontend shipped admin-gated)
**Full plan:** `speakanyway/drafts/gestalt-language-support-plan.md` (this doc is self-contained; the plan adds context)
**Counterpart:** `itty-bitty-frontend/.claude-notes/gestalt-language-support-handoff.md` (shipped; no longer blocked on this repo)

## Decisions (already made — don't re-litigate)

- New `glp_stage` field (integer 1–6, nullable) in `child_accounts.details` jsonb — alongside existing `aac_level`, NOT replacing it. They measure different things.
- GLP is ADMIN-ONLY until launch, and the gate lives entirely in the frontend:
  the single predicate `isGlpEnabled(user) => !!user.admin` in
  `itty-bitty-frontend/src/data/glp.ts`. Every GLP surface routes through it —
  the Script Collector FAB, the NLA stage tracker, the Board Builder gestalt
  phrases layer, and the GLP help articles — so opening the feature up to all
  users is a one-line change there. Those gates are pinned by render-level
  regression tests (frontend PR #757); don't remove a gate without them.
  **There is no backend gate, and that is deliberate:** `boards#add_image`
  accepts `part_of_speech: "phrase"` and `data.gestalt_source` /
  `data.utterance_function` from any user who can edit the board — they are
  writing to their own board. No "language processing type" toggle. Stage
  tracker is optional metadata.
- GLP board templates available on all plans including Free. The 1-board limit on Free self-gates.
- No migration needed — uses existing `details` jsonb column.

## Current state

- **`app/models/child_account.rb`**: `AAC_PROFILE_FIELDS` hash maps field names → allowed values from `CommunicatorProfile`. Dynamic getter/setter via `define_method`. Validation in `validate_aac_profile_fields`. Normalization in `normalize_aac_profile_fields`.
- **`app/services/communicator_profile.rb`**: `AAC_LEVELS`, `VOCAB_TYPES`, `AGE_BANDS` constants. `.for(params:, communicator:)` merges request params + stored profile. `prompt_guidance` generates AI prompt text. Predicates: `emerging?`, `developing?`, `young?`, `young_teen?`.
- **`app/controllers/api/child_accounts_controller.rb`**: PATCH/PUT update permits `details` — follows existing interests pattern.
- **`app/controllers/api/v1/board_builder_controller.rb`**: `templates` action (line ~22) returns catalog from `Boards::StarterBlueprints.catalog`; already accepts optional `communicator_id`. `create` persists interests to `communicator.details["interests"]`.
- **Board model**: `is_template` boolean, `tags` string array, `category` string, `predefined` boolean — all exist and are indexed.
- **`db/seeds/myspeak_starter_boards.rb`**: existing seed pattern for pre-built boards.
- **Routes**: `GET v1/board_builder/templates`, `POST v1/board_builder` — both exist.

### Known state from prior work
- PR #311 (`feat/board-builder-stored-profile`) added the `.for(params:, communicator:)` merge constructor and `aac_level`/`vocab_type`/`age_band` accessors. **Verify this is merged to main before starting.** If not, base your branch on it or coordinate with Brittany.

## Work items

### 1. Add `glp_stage` to communicator profile system

**`app/services/communicator_profile.rb`:**
```ruby
GLP_STAGES = (1..6).to_a.freeze
```
Add `glp_stage` to the initialization/merge logic in `.for()` and `from_params`. Store as integer, not string.

Add stage-aware helpers:
```ruby
def gestalt_early?    = glp_stage.present? && glp_stage <= 2
def gestalt_emerging? = glp_stage.present? && glp_stage.between?(3, 4)
def gestalt_advanced? = glp_stage.present? && glp_stage >= 5
```

Extend `prompt_guidance` to include GLP-specific guidance when `glp_stage` is set:
- Stage 1–2: "This communicator is a gestalt language processor at NLA Stage #{glp_stage}. Use whole familiar phrases and scripts, not single words. Prioritize phrases from their daily routines, favorite shows, and songs. Avoid isolated vocabulary."
- Stage 3–4: "This communicator is a gestalt language processor at NLA Stage #{glp_stage}. Mix single words with short phrases. Support novel 2-3 word combinations. Include both whole phrases and individual high-frequency words."
- Stage 5–6: "This communicator is a gestalt language processor at NLA Stage #{glp_stage}. Use full sentences with varied grammar. Support complex sentence construction with verb tenses and modifiers."

**`app/models/child_account.rb`:**
Add to `AAC_PROFILE_FIELDS`:
```ruby
"glp_stage" => CommunicatorProfile::GLP_STAGES,
```

The existing `define_method` loop + validation will handle the rest. **But note**: `glp_stage` is an integer while existing fields are strings. Check that `validate_aac_profile_fields` handles integer comparison correctly (it currently does `.include?` which works for both, but verify the normalization step doesn't `.downcase` an integer).

**`app/controllers/api/child_accounts_controller.rb`:**
Ensure `glp_stage` is included in the permitted details params. Follow the pattern used for `aac_level`. Verify the serializer exposes it in the API response.

### 2. Create GLP board templates

Create a new seed file: `db/seeds/glp_templates.rb` (or a rake task `lib/tasks/glp_templates.rake`).

Create 6 template boards. Each board should have:
- `is_template: true`
- `predefined: true`
- `board_type: "glp_template"` (or use tags — check which pattern the Board Builder `templates` action filters on)
- Appropriate `tags` array: `["glp", "stage_1", "stage_2", "communicative_function:request"]`
- `category: "glp"`

**Template boards to create:**

| Board Name | Function | Stages | Example Tiles (whole phrases) |
|---|---|---|---|
| Greetings & Social | greetings | 1–2 | "hi there!", "see you later", "how are you?", "I love that!", "nice to see you", "good morning" |
| Requests & Wants | requests | 1–2 | "I want more", "can I have that?", "let's go!", "help me please", "I need a break", "give me that" |
| Protests & Boundaries | protests | 1–2 | "no thank you", "stop please", "I don't want that", "not right now", "go away", "leave me alone" |
| Comments & Observations | comments | 1–3 | "look at that!", "that's so funny", "I see it", "wow!", "that's cool", "what happened?" |
| Feelings & Emotions | feelings | 2–3 | "I'm happy", "that makes me sad", "I feel mad", "I'm scared", "I'm excited", "I don't feel good" |
| Transitions & Routines | transitions | 1–2 | "time to go", "all done", "what's next?", "first this then that", "almost time", "let's clean up" |

Each tile: create an `Image` with `label` = the phrase, `part_of_speech` = "phrase", and link via `BoardImage`. Use age-appropriate colors — follow existing seed patterns.

Make the seed task idempotent: check for existing boards with matching names + `is_template: true` before creating.

### 3. Board Builder template integration

**`app/controllers/api/v1/board_builder_controller.rb` → `templates` action:**

When the communicator has a `glp_stage` set:
- Include GLP templates in the response (query `Board.where(is_template: true, category: "glp")` or filter by tags)
- Set `recommended_template` to the most stage-appropriate GLP template
- Set `recommendation_reason` to something like "Recommended for gestalt language processors at Stage #{stage}"

Add an optional `template_type` query param to filter: `?template_type=glp` returns only GLP templates; omit returns all (backward compatible).

**Response shape** (extend existing):
```json
{
  "templates": [...existing..., ...glp_templates...],
  "glp_templates": [...glp_only...],
  "recommended_template": "greetings-social",
  "recommendation_reason": "Recommended for Stage 1–2 gestalt processors"
}
```

### 4. Script Collector API support

The Script Collector frontend will use existing endpoints:
- `POST /api/images/find_or_create` — create the Image for the phrase
- `POST /api/boards/:id/add_image` — add it to the board

**But** we should add gestalt-specific metadata support to `BoardImage.data`:

**`app/controllers/api/boards_controller.rb` → `add_image` action:**
Permit additional `data` fields in the image params:
- `gestalt_source` (string, optional) — where the phrase came from ("Bluey S3E4", "bedtime routine")
- `utterance_function` (string, optional) — communicative function ("request", "protest", "comment", "greeting", "feeling", "transition")

These are stored in `board_images.data` jsonb. No validation needed beyond type — they're free-form metadata.

**`app/models/image.rb` or `app/controllers/api/images_controller.rb`:**
When creating an image via `find_or_create`, support `part_of_speech: "phrase"` to distinguish gestalt phrase tiles from single-word tiles. This already works if `part_of_speech` is in permitted params — verify.

## Testing

| Case | Expect |
|---|---|
| Update child_account with `details: { glp_stage: 3 }` | Saves, returns in API response |
| Update with `details: { glp_stage: 7 }` | Validation error (out of range) |
| Update with `details: { glp_stage: nil }` | Clears stage, no error |
| Update with `details: { glp_stage: 2, aac_level: "developing" }` | Both fields save independently |
| `CommunicatorProfile.for(params: {}, communicator: child_with_stage_2)` | Profile includes `glp_stage: 2`, `gestalt_early?` = true |
| `prompt_guidance` with `glp_stage: 1` | Includes gestalt-specific guidance about whole phrases |
| `prompt_guidance` with no `glp_stage` | No gestalt guidance (backward compatible) |
| `board_builder/templates?communicator_id=X` (communicator has glp_stage) | Response includes GLP templates + recommendation |
| `board_builder/templates` (no communicator) | GLP templates included but no recommendation |
| `board_builder/templates?template_type=glp` | Only GLP templates returned |
| `add_image` with `data: { gestalt_source: "Bluey", utterance_function: "request" }` | Metadata saved in board_images.data |
| GLP template seed task run twice | Idempotent — no duplicates |

Commands: `bundle exec rspec`. No new ENV vars, no migrations.

## Deploy notes

- After merge, run `bundle exec rails glp_templates:seed` (or `rails db:seed:glp_templates` depending on implementation) to create the 6 GLP template boards
- No ENV vars needed
- No migrations — all data in existing jsonb columns
- Backward compatible — existing API contracts unchanged, new fields are additive
- Ships independently — frontend GLP features depend on this PR but this PR works alone

## Git rules (Brittany's)

Branch off origin/main in a worktree. Never push to main or merge PRs — open the PR and stop.
```
git fetch origin && git worktree add -b feat/gestalt-language-support .claude/worktrees/glp origin/main
```
