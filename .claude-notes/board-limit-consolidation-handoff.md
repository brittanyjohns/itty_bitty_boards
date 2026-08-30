# Board limit consolidation (backend) — SHIPPED

**Issue:** #796 · **Status:** implemented
**Supersedes** the 2026-06-25 draft of this doc, which prescribed a different
design (count MAIN boards only, a builder set costs 1, Free becomes 3). None of
that shipped — do not implement it. What follows is what the code does.

## The shape

One creation cap, and it is **boards**. `board_group_limit` is gone.

- `User#countable_board_count` — own, `predefined: false`. Nothing else is
  excluded: a Board Builder set's boards count exactly like any others.
- `User#at_board_limit?` / `#can_create_boards` — the gate. Admins exempt.
- `User#countable_board_group_count` — still here, still correct, no longer a
  gate. Board Sets are uncapped: a set is a container, and its boards already
  count.

Why boards and not sets: a Board Set cannot exist without boards, so two caps
for one resource is what let a user at their board limit run the Board Builder,
receive a 20–35 board tree, and still be told "1 of 1 boards" — the builder
gated on `at_board_group_limit?` while the dashboard reported `board_count` and
neither matched `can_create_boards`.

## `board_limit` resolves at READ time

`User.plan_limits_for(plan_type)` (backed by `User::PLAN_LIMITS_BY_TYPE`) is the
one plan → limits map; three hand-rolled copies of that case statement used to
exist and they disagreed about `clinician`, `basic_5yr` and `pro_5yr`.

```ruby
def board_limit
  override = (settings || {})["board_limit"]
  return override.to_i if override.present?

  self.class.plan_limits_for(plan_type)["board_limit"]
end
```

- The five `setup_*_limits` setters **no longer stamp** `board_limit`. They used
  to, so every user who ever changed plans carried a frozen copy and moving a
  constant (or an ENV override) reached nobody.
- `settings["board_limit"]` means exactly one thing now: a **deliberate admin
  override**. Coerced with `.to_i` because `API::Admin::UsersController` stored
  the param uncoerced, and a String there made
  `countable_board_count >= board_limit` raise on every board create.
- A stored `0` is a real override ("no new boards"), not a missing value.
  Removing the key is what restores the plan default.
- Unknown / blank `plan_type` resolves to FREE — the safe direction, and what
  the old `board_group_limit` else-branch already did.
- Both admin write paths are `key?`-guarded now, and a **blank clears** the
  override. The admin form renders the override with the plan value as
  placeholder; rendering the resolved value would make every save stamp one.

**Cleanup for historical stamps:** `rake plans:clear_stamped_board_limits`
(`DRY_RUN=true` by default). It clears only values a setter for that user's
*current* plan could have written — the current constant, the pre-#796 defaults,
plus `EXTRA_STAMPED_VALUES` for environments that ran with non-default ENV —
keeps and reports anything else as an override, and **never touches a user with
a blank or unknown `plan_type`** (they resolve to FREE, so wiping a stranded
paid user's stamped 300 would silently drop them to 1). `board_limit` is also
out of `plans.rake`'s `BACKFILL_LIMIT_KEYS`, or the backfill would re-stamp
exactly what this removes.

## The Board Builder gate

A build has to fit **entirely** — the job has no coherent way to stop halfway,
and a half-built set is worse than no set. `Boards::BuilderSetSize.worst_case`
answers "how many boards will this run persist?" before the async job starts,
derived from constants so a new seed page or GLP board moves the bound:

| component | source |
|---|---|
| root | created by the controller |
| seed pages | `SeededSetCloner` runs `exclude_fringe: []` — the whole authored tree clones regardless of the plan (`SEED_SET_PAGES`: 8 for core-60, 11 for core-84) |
| planned pages | `StructurePlanner#cap_pages` caps the fringe list at the level's `max_pages` |
| phrases layer | `PhrasesPageBuilder`: 1 + `GlpTemplates::TEMPLATES.size` |
| favorites | "My Favorites", created once |

Today: **starter 23 / standard 27 / extended 35**; a legacy `template:` build
never reaches `StructurePlanner`, so it uses `legacy_worst_case` (the max over
the levels). Free's cap of 1 can never hold a set, which is what makes the
Board Builder a paid feature — by arithmetic, not by a flag.

Two orderings are load-bearing in `API::V1::BoardBuilderController#create`:

- `resolve_build_key` is hoisted **above** the gate (the gate needs the level).
  Its `UnknownTemplate` raise is still caught by the method-level rescue, so a
  bad `level` 422s as `unknown_template` even for a capped user — the better
  answer than a limit error about a build they couldn't have run.
- The gate stays **after** the existing-set handling, so `replace=true` destroys
  the old set before the check. That is the only move a capped user has.

## The error contract

Every limit 422 carries `error_code: "board_limit_reached"`. Existing `error`
strings are **byte-identical** — several are human sentences the frontend
renders verbatim (`cloneBoardWithResult`, `FirstBoardPage`), and flipping one to
a code would be a silent break. Bodies also carry `limit`, `count`, `required`,
`remaining`, and a `message`.

`app/controllers/concerns/board_creation_limit.rb` is the single implementation,
included by `API::BoardsController`, `API::MenusController`,
`API::GeneratedBoardsController` and `API::V1::BoardBuilderController`. The four
copies it replaced had drifted: menus had no fresh re-read and no Mailchimp
notify, generated_boards had no notify, and the builder gated on the other cap.
`User.find(current_user.id)` rather than `current_user.reload` is deliberate —
`countable_board_count` memoizes into a plain ivar and `reload` doesn't clear
it, which matters on the builder's `replace=true` path.

`board_builder#create` is the one caller that puts the CODE in `error` and the
prose in `message`, matching its own siblings (`board_builder_set_exists`,
`unknown_template`, `build_failed`).

## `api_view`

`board_count` is `countable_board_count` and `board_limit_reached` is
`at_board_limit?`, so the three usage numbers can no longer disagree in one
payload. `has_boards` is `boards.exists?` on purpose — it drives the dashboard
empty state and must keep meaning "owns any board at all", so a user whose only
boards are predefined isn't shown the empty state. `board_group_limit` is gone
from the payload; `board_group_count` stays. `admin_api_view` matches, and adds
`board_limit_source` (`"override"` / `"plan"`).

## Accepted consequences

- **A Free user's existing builder set becomes read-only.** Their
  `countable_board_count` jumps past 1, so `board_limit_locks?` applies and only
  the designated board stays editable. Deliberate, not grandfathered — the same
  lock any over-limit user gets. AAC usage never breaks: the boards stay fully
  viewable, tappable and audible.
- **Plan constants were not retuned.** Free 1 / Basic 100 / Pro 300 /
  Clinician 100, unchanged. At those numbers Basic fits ~2 extended sets. All
  four are ENV-overridable (`FREE_/BASIC_/PRO_/CLINICIAN_BOARD_LIMIT`), so
  retuning is a Hatchbox env change rather than a deploy.
- `top_editable_board_ids` dropped the builder exclusion too: once builder
  boards consume slots they have to be eligible to fill one, or an over-limit
  user has boards eating slots they can never edit.

## Follow-ups (not in this change)

- **Frontend** (`itty-bitty-frontend`): `boardBuilderCapacity.ts` pre-checks
  against `board_group_limit`/`board_group_count`, which the payload no longer
  ships — it resolves to `{status: "unknown"}` and never blocks, so nothing is
  broken, but it should read `board_limit`/`board_count`. The Free funnels
  (`/start`, MySpeak onboarding, `FreeDashboard`, `SideMenu`) route into a
  builder Free can no longer use and should say so.
- **Three authenticated endpoints create countable boards with no gate at all**:
  `images#create_predictive_board`, `scenarios#answer`,
  `board_images#update_multiple` (which also uses a non-bang `Board.create`
  behind a truthiness check that passes for an invalid record).
- `attr_accessor :skip_plan_setup` is written by both admin controllers and read
  by nothing.
