# Handoff: board limit consolidation (backend)

**Date:** 2026-06-25 · **Status:** not started
**Full plan:** `speakanyway/drafts/board-limit-consolidation-plan.md` (this doc is self-contained; the plan adds context)
**Counterpart:** `itty-bitty-frontend/.claude-notes/board-limit-consolidation-handoff.md` (blocked on this PR)

## Decisions (already made — don't re-litigate)

- **One enforced cap: `board_limit`.** Delete the second cap (`board_group_limit`).
- **Count rule: non-predefined MAIN boards only** (`sub_board: false/nil`).
  Sub-pages never count — builder children and manual sub-pages alike. So a
  Board Builder set counts as **1** (its top-level board), regardless of size.
- A **manual Board Set** (`BoardGroup`) counts **0 extra**. No cap on creating sets.
- **Displayed count = enforced count.** `api_view`'s `board_count` must report the
  same number the cap enforces (today it counts every board, incl. sub-pages).
- **Edit-lock: N-editable when over limit.** When a user is over their board
  limit (post-downgrade), the **N most-recently-updated main boards are editable**
  (N = `board_limit`), not a single pinned board — so a downgraded free user gets
  all 3 editable. See Work item 7.
- **`FREE_BOARD_LIMIT` default = 3.** Builder set is 1 of the 3, not 3 on top.
- Basic (100) / Pro (300) board limits unchanged.

## Current state (what exists today)

All in `app/models/user.rb` unless noted.

- **Plan hashes** (~L309–328): `FREE/BASIC/PRO_PLAN_LIMITS` each carry both
  `board_limit` and `board_group_limit` (the latter ENV `*_BOARD_GROUP_LIMIT`,
  defaults 1 / 25 / 50).
- **`countable_board_count`** (~L1367): counts own, non-predefined boards
  `where.not(id: builder_grouped_board_ids)` — i.e. excludes the **entire**
  builder tree (root + children). This makes a builder set count as **0** boards.
- **`builder_grouped_board_ids`** (~L1377): board ids in any `builder: true`
  BoardGroup the user owns.
- **`at_board_limit?`** (~L1385) wraps `countable_board_count >= board_limit`.
- **`board_group_limit`** (~L460), **`countable_board_group_count`** (~L1397)
  (`board_groups.where(predefined: [false, nil]).count`), **`at_board_group_limit?`**
  (~L1402) — the second cap and its gate.
- **`api_view`** exposes `board_group_limit` (grep to confirm the exact line in the
  groups payload / user view).
- **Builder gate:** `app/controllers/api/v1/board_builder_controller.rb` L77 —
  `if current_user.at_board_group_limit?` → 422 "You've reached your plan's board
  set limit (N/M)…".
- **Manual set gate:** `app/controllers/api/board_groups_controller.rb` L59–63 —
  `def create` gates on `current_user.at_board_group_limit?` → 422 "board set limit".

## Work items

1. **Count main boards only.** Change `countable_board_count` to count
   non-predefined **main boards** — `boards.where(predefined: false).main_boards`
   (the `main_boards` scope = `non_menus.where(sub_board: [false, nil])`). This
   makes a builder set count as **1** (its top-level board; the linked sub-pages
   are `sub_board: true` and drop out) and also stops manual sub-pages from
   counting — one consistent rule. Drop the `builder_grouped_board_ids` exclusion
   (no longer needed) and update the method comment (it currently says the tree
   costs ZERO board slots).
   - **Verify** in a spec that a freshly built set's children are actually
     `sub_board: true` (set via `Board#check_is_sub_board`, which keys off
     `parent_boards`). If any child isn't flagged, fall back to also excluding
     `settings["builder_child"] = true` boards so no set member leaks into the count.

2. **Re-gate the builder on the board limit.** In
   `board_builder_controller.rb` L77, change `at_board_group_limit?` →
   `at_board_limit?`. Replace the "board set limit" 422 body with the board-limit
   message + fields (`limit: current_user.board_limit`,
   `count: current_user.countable_board_count`). Match the copy other board-limit
   422s use (grep "board limit" / "Maximum number of boards").

3. **Drop the manual-set cap.** In `board_groups_controller.rb` `create`, remove
   the `at_board_group_limit?` gate and its 422 branch. Manual sets group
   already-counted boards, so no cap is needed.

4. **Delete the second cap.** Remove `board_group_limit`,
   `countable_board_group_count`, `at_board_group_limit?`, and the
   `board_group_limit` keys from `FREE/BASIC/PRO_PLAN_LIMITS`. Remove the
   `*_BOARD_GROUP_LIMIT` ENV fetches. Grep the whole repo for `board_group_limit`
   / `at_board_group_limit` and clear every reference (api_view, serializers,
   any policy). Leave `builder: true` BoardGroups themselves intact — they still
   group boards, they just stop being a counting mechanism.

5. **Set Free = 3.** `FREE_PLAN_LIMITS["board_limit"]` →
   `ENV.fetch("FREE_BOARD_LIMIT", 3).to_i`.

6. **Align the displayed count with the enforced count.** In `api_view`,
   `board_count` is currently `memoized_boards.count` (every board, incl.
   sub-pages and builder children) while the cap uses `countable_board_count`.
   They must match or the UI shows e.g. "13 boards" against a cap of 3. Set the
   user-facing count to `countable_board_count` (and `board_limit_reached`/
   `has_boards` derived from it). Grep for `board_count` in serializers /
   `user_api_view` and make them consistent.

7. **Fix the edit-lock: make N boards editable when over limit.** Today
   `board_editable?` (in `app/models/user.rb`) reads:
   ```ruby
   def board_editable?(board)
     return true if admin?
     return true if board.nil? || board.user_id != id
     return true if paid_plan?
     return true if countable_board_count <= board_limit
     board.id == effective_editable_board_id   # <-- single editable board
   end
   ```
   Replace the final line so that, when over limit, the **N most-recently-updated
   main boards are editable** (N = `board_limit`). Compute the editable set once
   (memoize) — e.g. the ids of `boards.where(predefined: false).main_boards
   .order(updated_at: :desc).limit(board_limit)` — and return
   `editable_ids.include?(board.id)`. Keep `effective_editable_board_id` /
   `editable_board_id` as the user's *preferred* board (still pin it into the
   editable set first if set), but the test is now count-based, not single-id.
   Update the "Assumes FREE_BOARD_LIMIT == 1" comment — that assumption is gone.
   - Check callers of `effective_editable_board_id` / `make_editable` so nothing
     still assumes exactly one editable board (grep both; the `make_editable`
     endpoint and cooldown still work — they just set the *preferred* board now).

8. **Docs in this repo.** Rewrite the README "Plans & limits: boards vs. Board
   Sets" section and the CLAUDE.md Board Builder / board-limit sections to the
   single-cap model (builder set = 1 board; no `board_group_limit`). Add a
   CHANGELOG entry: builder sets count as one board; Free now includes 3 boards.
   (Note: PR #420 documented the old two-cap model and is being closed — don't
   build on it.)

## Testing

- `bundle exec rspec` — focus:
  - `spec/models/user_spec.rb` — main-board counting (top-level boards count;
    sub-pages and builder children don't), `at_board_limit?`, Free limit = 3,
    and `api_view` `board_count` == `countable_board_count`. Remove/blow away
    `board_group_limit` / `at_board_group_limit?` specs.
  - `spec/requests/api/v1/board_builder*` — 422 now fires on `at_board_limit?`
    with board-limit copy; a built set (standard AND extended/Core 84) consumes
    exactly 1 slot.
  - `spec/requests/api/board_groups*` — manual set creation no longer 422s on a
    set cap.
  - Edit-lock: a Free user at/under limit edits all their boards; a user OVER
    limit (simulate a downgrade with >3 main boards) gets exactly
    `board_limit` (3) editable — the 3 most-recently-updated — and the rest
    read-only. Update/extend existing `board_editable?` specs accordingly.
- Manual sanity: a Free user (limit 3) can build one builder communicator (1 slot)
  and still create 2 more top-level boards; the 3rd extra top-level board is
  blocked with 422; a multi-page manual board still counts as 1.

## Deploy notes

- **ENV:** set `FREE_BOARD_LIMIT=3` default (in code). Remove
  `FREE/BASIC/PRO_BOARD_GROUP_LIMIT` from code and any deploy env config.
- **No migration.** Nothing was a DB column. Stray per-user
  `settings["board_group_limit"]` keys become dead/harmless — optional cleanup.
- Safe to deploy alone; the frontend tolerates the now-absent `board_group_limit`
  field (it's null-guarded) until Phase 2 lands.

## Git rules (Brittany's)

Run `bin/install-hooks` once at session start. Branch off `origin/main` in a
worktree (`git fetch origin && git worktree add -b <branch> .claude/worktrees/<name> origin/main`).
Code changes get tests. Conventional Commit prefixes. Never push to main or merge —
open the PR and stop.
