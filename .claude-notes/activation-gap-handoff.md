# Handoff: activation gap — clone flattening (backend)

**Date:** 2026-08-27 · **Status:** not started
**Full plan:** `../drafts/activation-gap-plan.md` (this doc is self-contained; the plan adds funnel data)
**Counterpart:** `../itty-bitty-frontend/.claude-notes/activation-gap-handoff.md`
**Issue:** none filed

⚠️ The workspace checkout this was written from was stale (local main at
PR #719; origin/main at #783). Line numbers below were verified against
origin/main where noted — re-verify after your fetch.

## Decisions (already made — don't re-litigate)

- Cloning a board clones **only the root board**. No deep subboard-tree
  clone, no extra board slots consumed.
- Dynamic (folder) tiles in the clone are **flattened to regular speak
  tiles** when their target board doesn't belong to the cloning user. The
  clone response reports how many, so the frontend can show a notice.
- Free `board_limit` stays 1. The existing `check_board_create_permissions`
  gate on clone is correct and unchanged.

## Current state

- `POST /api/boards/:id/clone` → `app/controllers/api/boards_controller.rb`
  `clone` action (origin/main ~:1411-1419). Optional `name` param. Gated by
  `before_action :check_board_create_permissions` (`:6`, impl ~:1513-1526 —
  422 with upgrade message at board limit).
- `Board#clone_with_images` (`app/models/board.rb` ~:1368-1495) already
  clones one board only, but the tile loop copies the folder pointer
  verbatim: `new_board_image.predictive_board_id =
  board_image.predictive_board_id`. So a cloned public board's folder tiles
  navigate into the **source owner's** boards — which the cloner doesn't
  own and which may be unpublished later, silently breaking the tile.
- The deep cloner (`app/services/boards/assignment_cloner.rb`) is used by
  MySpeak onboarding's starter-board attach and is NOT part of this work.
- `clone` has no ownership/public check on the source board — any board id
  reachable by the user is clonable. Pre-existing; note it, don't fix it
  here unless trivial (a `predefined? || published? || owned?` guard).

## Work items

1. **Flatten foreign folder pointers in `clone_with_images`.** In the tile
   loop, when `board_image.predictive_board_id` is present and that target
   board's `user_id` is neither the cloning user nor covered by the clone
   context (same-owner template clone via `communicator_account` /
   `force_template` paths must keep behaving as today — check existing
   callers: onboarding starter boards, vendor flows), set
   `new_board_image.predictive_board_id = nil` and increment a counter.
   Keep the pointer when the target board belongs to the cloning user.
2. **Return the count.** `clone` action response merges
   `flattened_tiles: <n>` into `api_view_with_images(current_user)`. 0 when
   nothing was flattened.
3. **Don't regress existing callers.** `clone_with_images` is called from
   more places than the controller (search for it) — the flatten rule keys
   off the *cloning user's* ownership of each tile's target, so same-owner
   clones are naturally unaffected. Confirm with specs.

## Testing

| Case | Expect |
|---|---|
| Clone public board with folder tiles into other user's account | folder tiles become regular (nil predictive_board_id), `flattened_tiles` = count, one new board only |
| Clone own board with folder tiles into own account | pointers preserved, `flattened_tiles: 0` |
| Clone at Free board limit | existing 422 upgrade message unchanged |
| MySpeak onboarding starter-board attach | unchanged (AssignmentCloner path untouched) |
| Clone response shape | `api_view_with_images` fields intact + `flattened_tiles` |

Specs: extend the boards request specs covering `clone`; run the boards
controller/model specs plus anything touching `clone_with_images`.

## Deploy notes

No migration, no ENV. Ships alone safely — the new response field is
additive; current frontend ignores it.

## Wrap-up

Follow this repo's CLAUDE.md for git workflow and conventions. Open the PR
and stop — never merge. Commit this doc in the PR so it survives the session.

---

**Implemented** 2026-08-27 on `claude/activation-gap-handoff-6c8a66`. Work items 1–3
landed as `Board#clone_with_images(flatten_foreign_links:)` +
`BoardImage#flatten_navigation!` + `flattened_tiles` on the clone response.
The flatten is OPT-IN rather than unconditional: `Boards::AssignmentCloner` and
`Boards::SeededSetCloner` both rely on the verbatim pointer and rewire it after
their own sub-board clones, so an ownership test alone would have cut those
links before the rewire ran. The pre-existing "no ownership/public check on the
source board" note in Current state is still open — left alone as instructed.
