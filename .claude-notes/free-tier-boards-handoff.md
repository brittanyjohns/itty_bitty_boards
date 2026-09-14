# Handoff: Free tier gets 5 boards and a buildable builder set (backend)

**Date:** 2026-09-14 · **Status:** not started
**Full plan:** `../drafts/free-tier-boards-plan.md` (this doc is self-contained; the plan adds the PostHog numbers and the why)
**Counterpart:** `../itty-bitty-frontend/.claude-notes/free-tier-boards-handoff.md` (blocked on this PR)
**Issue:** none filed

## Decisions (already made — don't re-litigate)

1. `FREE_BOARD_LIMIT` goes **1 → 5**.
2. `Boards::StarterBlueprints::HOME` (root + Food + Feelings + Play = 4 boards,
   5 with a "My Favorites" page) becomes a fourth board-builder picker option,
   labelled **Quick Start**. Do not author a new blueprint.
3. **No plan flag on the builder.** Free (5 boards) fits Quick Start (5) and
   cannot fit starter/standard/extended (23/27/35). Arithmetic is the gate, as
   `board-limit-consolidation-handoff.md` intended. Do not add `paid_plan?`
   checks to `board_builder_controller`.
4. Free's limit is **5, not 4**, specifically because `route_interests!` can add
   a "My Favorites" board. 4 would make Quick Start fail on the exact path we
   are opening.
5. MySpeak slots and AI credits are unchanged. Don't touch `CreditService` or
   `Permissions::CommunicatorLimits`.

## Current state

**The limit constant** — `app/models/user.rb:409-414`:
```ruby
FREE_PLAN_LIMITS = {
  "plan_type" => "free",
  "board_limit" => ENV.fetch("FREE_BOARD_LIMIT", 1).to_i,
  ...
}.freeze
```
Also set explicitly at `config/application.yml:77` (`FREE_BOARD_LIMIT: "1"`).
`User#board_limit` (`user.rb:627-631`) prefers `settings["board_limit"]` when
present, else `User.plan_limits_for(plan_type)["board_limit"]`.

Constants are frozen at class-load, so `ENV.fetch` runs once per process boot.
**An env change alone does not take effect — this needs a deploy.**
`.claude-notes/board-limit-consolidation-handoff.md:100-104` says otherwise;
that prose is wrong and is corrected as a work item below.

**The sizing chokepoint** — `app/services/boards/builder_set_size.rb:30-45`:
```ruby
def self.worst_case(build_key)
  level = Boards::StructurePlanner::LEVELS[build_key.to_s.downcase]
  return legacy_worst_case unless level
  seed_pages = Boards::StructurePlanner::SEED_SET_PAGES.fetch(level[:core_template], []).size
  ROOT_BOARDS + seed_pages + level[:max_pages] + PHRASES_LAYER_BOARDS + FAVORITES_BOARDS
end

def self.legacy_worst_case
  Boards::StructurePlanner::LEVEL_KEYS.map { |key| worst_case(key) }.max
end
```
`LEVELS` has only `starter`/`standard`/`extended`
(`app/services/boards/structure_planner.rb:3-9`). Every other key — including
the real 4-board `"home"` blueprint — falls to `legacy_worst_case`, which
returns **35**. This one fallback is why HOME is unbuildable on any plan below
Pro. It is the single most important line in this PR.

**The gate that consumes it** — `app/controllers/api/v1/board_builder_controller.rb:137-154`:
```ruby
builder = board_limit_user(owner)
required = Boards::BuilderSetSize.worst_case(build_key)
if board_limit_exceeded?(builder, required: required)
  ...
  message: "Building this set needs room for #{required} boards, but your plan " \
           "has #{remaining} of #{builder.board_limit} left. ..."
```

**The picker catalog** — `board_builder_controller.rb:24-55` (`#templates`,
routed at `config/routes.rb:627`). Returns `levels: COMPLEXITY_LEVELS`
(hardcoded at `:9-22`, three entries) and
`templates: Boards::StarterBlueprints.catalog + Boards::GlpTemplates.catalog`.
Not plan-aware; nothing in it reads `current_user`'s plan.

**Why `templates[]` is not enough.** The frontend does
`useLevels = levels.length > 0`, and `levels` is always the three hardcoded
entries — so the templates-flow picker (`StepTemplate`) never renders in
production and HOME is currently **unreachable in the UI**. Adding the option to
`COMPLEXITY_LEVELS` is what actually exposes it.

**Key resolution** — `board_builder_controller.rb:244-268`:
```ruby
def resolve_build_key
  if params[:level].present?
    level = params[:level].to_s.downcase
    unless Boards::StructurePlanner::LEVELS.key?(level)
      raise Boards::BlueprintAssembler::UnknownTemplate, "unknown level #{params[:level].inspect}"
    end
    level
  elsif params[:template].present?
    ...
```
A `level: "home"` from the picker would 422 as `unknown_template` today.

**The job dispatch already works.** `build_board_set_job.rb:65-69` branches on
`complexity_level?(key)` → `LEVELS.key?(key)`. `"home"` is not a level, so it
takes `build_legacy` (`:665-688`) → `Boards::BlueprintAssembler` →
`Boards::BoardTreeBuilder`. **No job changes needed.**

**Why HOME's worst case is 5, not 4.** `Boards::BlueprintAssembler#call`
(`app/services/boards/blueprint_assembler.rb:46-52`) calls `route_interests!`
(`:58-69`), which appends a "My Favorites" folder (`:90-99`) for interests that
don't route into Food/Feelings/Play. That is one extra board.

**Stamped overrides.** Only two code paths write `settings["board_limit"]`:
`app/controllers/admin/users_controller.rb:117-123` and
`app/controllers/api/admin/users_controller.rb:113-120`. Plan changes no longer
stamp it (#796), and `Billing::PlanTransitions` only touches `plan_type` — so
clearing legacy stamps is safe and nothing re-stamps them.

## Work items

### 1. Raise the Free board limit

- `app/models/user.rb:411` — `ENV.fetch("FREE_BOARD_LIMIT", 1)` → `5`.
- `config/application.yml:77` — `FREE_BOARD_LIMIT: "1"` → `"5"`.

### 2. Size blueprint templates honestly

In `app/services/boards/builder_set_size.rb`, teach `worst_case` about
blueprint templates before falling back. Derive the count from the tree so
`DAILY_ROUTINE` and any future blueprint size themselves — do not hardcode a
per-template table:

```ruby
def self.worst_case(build_key)
  key = build_key.to_s.downcase
  level = Boards::StructurePlanner::LEVELS[key]
  return level_worst_case(level) if level

  tree = Boards::StarterBlueprints.tree_for(key)
  return blueprint_worst_case(tree) if tree

  # Robust sets (core-60 / core-84) clone a whole authored tree whose size
  # isn't knowable here; keep the roomy bound for those.
  legacy_worst_case
end

# A blueprint's boards are its root, one per folder tile, plus the
# "My Favorites" page BlueprintAssembler#route_interests! can append.
def self.blueprint_worst_case(tree)
  ROOT_BOARDS +
    Array(tree[:tiles]).count { |tile| tile[:children] } +
    FAVORITES_BOARDS
end
```

Extract the existing level arithmetic into `level_worst_case(level)` unchanged.
Expected results: `home` → **5**, `daily_routine` → **3**, `core-60`/`core-84` →
35 (unchanged), `starter`/`standard`/`extended` → 23/27/35 (unchanged).

### 3. Add Quick Start to the picker, and a board cost to every entry

`board_builder_controller.rb:9-22` — add the new entry and a `board_cost` on all
four, sourced from `BuilderSetSize` so the number can never drift from the gate:

```ruby
COMPLEXITY_LEVELS = [
  { key: "home", name: "Quick Start",
    description: "One home board plus Food, Feelings, and Play — enough to start today.",
    fringe_page_range: "3",
    grid_rows: 4, grid_columns: 4 },
  { key: "starter", ... },
  ...
].freeze
```

Serve it with the cost attached rather than hardcoding numbers in the constant:

```ruby
levels: COMPLEXITY_LEVELS.map { |lvl|
  lvl.merge(board_cost: Boards::BuilderSetSize.worst_case(lvl[:key]))
},
```

Put `home` **first** — it is the smallest and the only one a Free account can
build. Check `recommend_level` (same controller) still behaves sensibly with a
fourth entry; it should keep recommending by communicator profile, not by plan.

`board_cost` is what unblocks the frontend's pre-check (its
`resolveBuilderCapacity` currently defaults `required` to 1 and no caller passes
anything else, so a Free user passes the client check and is refused at POST).

### 4. Accept a blueprint key arriving as `level`

`resolve_build_key` (`:244-268`) — the picker sends every option as `level`, so
`level: "home"` must resolve. Accept a `params[:level]` that is either a
`StructurePlanner::LEVELS` key **or** a `StarterBlueprints.tree_for` hit; keep
raising `UnknownTemplate` for anything else. Leave the `params[:template]`
branch alone (legacy callers).

Also check `resolve_root_name(build_key)` (`:285-295`) — it keys off `LEVELS`
and needs a sensible name for `home` (the blueprint's own `tree[:name]`,
"Home", is the right answer).

### 5. Fix the stale `.claude-notes`

These describe deleted code and will mislead the next session:

- `billing-and-plans.md:734-745` — documents `FREE_MYSPEAK_ID_LIMIT` /
  `myspeak_id_count` / `can_create_myspeak_id?`. All deleted by #764. Replace
  with the current model: a communicator's MySpeak page is free on every plan
  with no quota; the user-level public page is capped at 1 on every plan and
  409s as `public_page_exists`.
- `billing-and-plans.md:823` — "Free (`FREE_BOARD_LIMIT == 1`)" → 5.
- `board-limit-consolidation-handoff.md:100-104` — the claim that retuning is
  "a Hatchbox env change rather than a deploy" is wrong; constants load once per
  boot. Also its "Follow-ups" section lists `images#create_predictive_board`,
  `scenarios#answer`, and `board_images#update_multiple` as ungated; all three
  are gated now. Mark that section resolved.
- `builder-boardgroup-handoff.md` — still describes the removed
  `board_group_limit` as the plan. Mark superseded by #796.
- `activation-gap-handoff.md` — states as a settled decision that clone is
  root-only; `Boards::CloneSetPlanner` deep-clones the linked set within the
  slot budget. Correct or mark stale.

## Testing

Run: `bundle exec rspec spec/services/boards/builder_set_size_spec.rb spec/requests/api/v1/board_builder_spec.rb spec/models/user_board_limit_spec.rb spec/models/user_plan_limits_spec.rb spec/models/user_editable_board_floor_spec.rb spec/sidekiq/build_board_set_job_spec.rb`

| Case | Expected |
|---|---|
| `BuilderSetSize.worst_case("home")` | 5 |
| `BuilderSetSize.worst_case("daily_routine")` | 3 |
| `BuilderSetSize.worst_case("core-60")` | 35 (unchanged fallback) |
| `worst_case` for starter / standard / extended | 23 / 27 / 35 (unchanged) |
| Free user, 0 boards, `POST` with `level: "home"` | 201, job enqueued |
| Free user, 1 board, `level: "home"` | 201 (5 needed, 4 remaining → refused; assert the **422** here — 1+5 > 5) |
| Free user, 0 boards, `level: "starter"` | 422, `error_code: board_limit_reached`, message quotes 23 |
| Basic user, `level: "home"` | 201 |
| `GET /api/v1/board_builder/templates` | 4 levels, `home` first, each carrying `board_cost` |
| `level: "nonsense"` | 422 `unknown_template` (unchanged) |
| A `home` build with off-topic interests | produces ≤ 5 boards; My Favorites appears |

Correct the second row's expectation when you write it — a Free user with 1
existing board has 4 slots and a 5-board set does not fit. That is intended
behaviour and worth an explicit spec, since it is the one case where Quick Start
refuses on Free.

**Specs needing edits:** `spec/models/user_editable_board_floor_spec.rb:14` and
`:56` assert `eq(1)` literally. Change them to derive from
`User::FREE_PLAN_LIMITS["board_limit"]` like the surrounding specs do, so they
never need touching again. Its 24-board fixture still exercises the
`board_limit < EDITABLE_BOARD_FLOOR (5)` case correctly at 5 — re-read that spec
and confirm, since Free's limit now **equals** the floor rather than sitting
under it. If that collapses the scenario the spec exists to test, adjust the
fixture, not the floor.

Everything else that references `board_limit` already derives from the
constant and will track automatically.

## Deploy notes

- No migration.
- `FREE_BOARD_LIMIT` must change in the environment **and** the app must boot —
  a live env edit alone is inert.
- **After the deploy**, backfill legacy stamped limits:
  `DRY_RUN=true rake plans:clear_stamped_board_limits` first. It prints
  `cleared` / `kept_as_override` / `skipped_admin` / `skipped_unknown_plan` plus
  a line per kept row. Report those counts to Brittany, then re-run with
  `DRY_RUN=false`. Users whose stored value isn't a recognised legacy stamp are
  treated as genuine admin overrides and left alone — that is correct.
- `rake boards:limit_audit USER_ID=... ` (read-only) is the tool for spot-checking
  an individual afterwards.
- Ships independently of the frontend.

## Wrap-up

Follow this repo's CLAUDE.md for git workflow and conventions. Open the PR and
stop — never merge. Commit this doc in the PR so it survives the session.
