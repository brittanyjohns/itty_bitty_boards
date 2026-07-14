# Boards & teams — permissions, assignment, deletion, sets, layouts, imports

> Extracted from CLAUDE.md on 2026-07-11 (hub-and-spoke restructure).
> This file is the authoritative doc for this subsystem — update it (not CLAUDE.md)
> when behavior changes. CLAUDE.md keeps only the cross-cutting invariants.

## Team permissions — owner protection

Communicators (`child_account`) have an `owner_id` (the family/parent
post-claim, or the SLP pre-claim). That user is "**owner-pinned**" on the
communicator's team: they cannot be removed or have their role changed by
any non-owner. Full matrix in issue #166. Server-side rules:

- `ChildAccount#claim_by!` (the SLP→family hand-off) updates the
  communicator's **own** team: new owner → `admin`, previous owner →
  `supervisor`, and **team ownership (`created_by_id`) transfers to the new
  owner** so they get `is_owner` / `can_invite` (the "Manage team" controls).
- **"Own team" is resolved deterministically, not `teams.first`.** A
  communicator can belong to several teams (its own + shared/board teams it's
  added to), so `ChildAccount#primary_team` resolves: (1) the team pinned in
  `settings["primary_team_id"]`, (2) the namesake team
  (`"<name>'s Communication Team"`, the creation convention), (3) the oldest
  team as a legacy fallback. `ensure_team!` and `claim_by!` pin
  `primary_team_id` so resolution stays stable across renames and join order.
  Before this, `claim_by!` acted on `teams.first` and could update the wrong
  team — leaving the communicator's own team without the new owner.
  Existing stale data is repaired by `rake communicators:repair_handoff_teams`
  (dry-run by default; `DRY_RUN=false` to apply, `USER_ID=N` to scope). It only
  touches a communicator's identifiable own team — never a shared one.
- **Lending / hand-off is Pro-only, enforced server-side.**
  `API::ChildAccountsController#require_pro_for_lending!` gates `lend` and
  `promote_to_loaner` (after the ownership check, so a non-owner still gets the
  generic Unauthorized) and returns **HTTP 403 `pro_required`** for non-Pro
  non-admin callers. Covers the `active→loaner` lend path too, which skips the
  slot check. The frontend `LoanerControls` Pro gate is now defense-in-depth,
  not the only guard.
- `DELETE /api/teams/:id/remove_member` returns **HTTP 403
  `cannot_remove_owner`** if the target is owner-pinned and the caller is
  neither that user nor a system admin. The owner can remove themselves.
- `DELETE /api/teams/:id/leave` — self-scoped: a member removes their own
  membership (uses `current_user`, never an email param, so it can't remove
  anyone else). Returns **HTTP 403 `creator_cannot_leave`** for the team
  creator (`created_by_id`) — they use "Delete team" instead, since leaving
  would orphan the team. Destroying the `TeamUser` fires the same
  `before_destroy` board-snapshot safety net as `remove_member`, so the
  departing member's shared boards stay with the family.
- `POST /api/teams/:id/invite`, when it would change an *existing*
  membership's role, returns **HTTP 403 `cannot_change_owner_role`** if
  the target is owner-pinned (and the caller isn't that user). It also
  returns **HTTP 403 `cannot_self_promote`** if a non-owner non-admin
  caller tries to set their own role to `admin`.
- Owner-pinned-ness is computed, not stored:
  `Team#account_owner_ids` / `Team#account_owner?(user)` and
  `TeamUser#account_owner?`. Team `show`/`index` `api_view` expose
  `account_owner_ids` and per-member `is_account_owner` so the frontend
  can hide destructive controls.

The SLP→family **hand-off** (loaner → claim) is the supported ownership
transfer: `claim_by!` moves both `child_account.owner_id` and the own team's
`created_by_id` to the new owner. A standalone **transfer ownership** endpoint
(active → another user directly, outside the loaner flow) still doesn't exist —
out of scope for #166.

**Full SLP→parent handoff contract** — including the permissions matrix
(who can do what to a claimed communicator), the lifecycle states, and
known backend-enforcement gaps — lives in
`marketing/.claude-notes/handoff-workflow.md`. Keep that doc and this
section in sync when the rules change.

### Board assignment is a DEEP clone (`Boards::AssignmentCloner`)

Putting a board on a communicator (`assign_boards`, `assign_accounts`, the
MySpeak starter attach) goes through **`Boards::AssignmentCloner`**
(`app/services/boards/`), not a bare `clone_with_images`. The old shallow
clone copied `predictive_board_id` verbatim, so an assigned board's folder
tiles kept opening the **source owner's live sub-boards** — shared state that
changed/broke when the source owner edited or deleted them.

- The cloner BFS-collects the linked set (**`Boards::PredictiveLinkSet`**,
  extracted from `SeededSetCloner` and shared with it), depth-capped by
  `BOARD_ASSIGN_CLONE_DEPTH` (default 3), clones each sub-board for the same
  owner, and rewires the folder tiles to the clones. Pointers past the depth
  cap are **kept verbatim** (assignment sets are arbitrary user boards —
  nulling would break deep sets), unlike the builder's `:null` policy.
- Root clone contract unchanged: `is_template: true` + ChildBoard on the
  communicator (created inside `clone_with_images`). Sub-clones are also
  `is_template` (via the new `force_template:` kwarg on `clone_with_images`),
  get **no ChildBoard rows**, and carry `settings["assignment_child"]` +
  `["assignment_root_id"]` so `ChildBoardsController#destroy`'s **orphan
  sweep** can delete them when the root clone is removed and hard-deleted
  (same `orphan_template?` guards per sub-board; iterates until a pass
  deletes nothing so nested folders unwind).
- **Per-communicator assigned-board cap** (`ChildAccount.max_assigned_boards`,
  ENV `MAX_ASSIGNED_BOARDS_PER_COMMUNICATOR`, default 80 — matches the
  favorites cap): assigned clones are deliberately uncounted toward the
  owner's board limit (the original already counted), so this cap is what
  stops assignment minting unlimited board rows. `assign_boards` returns
  **422 `assigned_board_limit`** `{ error, message, limit, count }`;
  `assign_accounts` appends a per-communicator message to its existing
  `record_errors` 422 array.
- Legacy shallow clones (no `assignment_root_id` marker) behave as before —
  nothing migrates them; the delete-safety 409 now correctly warns source
  owners that their sub-boards are still referenced.

### Board removal after hand-off (non-destructive)

Boards put on a communicator via `assign_boards` are **cloned** (a new
`Board` marked `is_template: true`, owned by the user who added them — the
SLP), referenced by a `ChildBoard` join. After a hand-off the new owner
should be able to clear/curate the dashboard **without losing boards**.

- **On claim, `claim_by!` registers the communicator's current dashboard
  boards as team boards** (`register_dashboard_boards_on_team!`) on its own
  team. While a board is on the dashboard it's excluded from
  `available_teams_boards` (no duplicate); once removed it reappears there,
  re-addable. The `repair_handoff_teams` rake task backfills this for
  already-claimed communicators.
- **Removal is non-destructive.** `DELETE /api/child_boards/:id`
  (`ChildBoardsController#destroy`) always detaches the `ChildBoard`, and
  only hard-deletes the underlying `Board` when it's an **orphan template**
  (`is_template` AND no `team_boards` AND not on another communicator AND
  owned by the remover — `orphan_template?`). So a hand-off owner removing
  an inherited board (a team board / SLP-owned clone) detaches it but keeps
  it; the old "delete the board whenever `is_template`" behavior only still
  applies to a true throwaway clone on your own communicator.
- **Detach stays owner-gated; the api_view exposes `can_remove`.** Detach
  authorization is communicator-ownership (`editable_by?`), not board
  ownership, so the new owner is allowed. The dashboard board entries now
  carry **`can_remove`** (keyed to communicator ownership) alongside
  `can_edit` (board ownership, gates clone-to-edit), so the frontend can
  show the remove control to a hand-off owner who doesn't own the board.
  (Frontend wiring to consume `can_remove` is a companion change.)
- **`Board#communicator_child_boards` filters orphaned join rows.** It unions
  `original_child_boards` (FK `original_board_id`, `dependent: :nullify`) with
  `child_boards`, then `.select(&:child_account)` — a `ChildBoard` whose
  `child_account` was deleted (account teardown, or older DBs lacking an
  enforced `child_account_id` FK) is dropped. The `api_view` /
  `api_view_with_predictive_images` serializers read `cb.child_account.id`
  directly, so a single orphan otherwise 500s the whole `/api/boards` index.
  Filter at this one chokepoint, not per call site.
### Editing the communicator object itself

`ChildAccount#editable_by?(user)` returns true iff the user is the
`owner_id` or a system admin. It's the helper that drives the
`can_edit_communicator` flag on both `api_view` and `vendor_api_view`
(issue #215). The frontend uses that flag to gate the Edit tab/form on a
communicator — i.e. who can change name, username, voice, layout, and
the safety profile.

`can_edit_communicator` is **distinct from `can_edit`** in the same
payload: `can_edit` answers "can this user curate boards on this
communicator" (board sharers, including team members on a paid plan).
`can_edit_communicator` answers "can this user mutate the communicator
object itself" (owner-only by default). Keep both — they back different
UI affordances.

Full permissions matrix and the rationale for the split lives in
`../speakanyway/marketing/.claude-notes/handoff-workflow.md`.


## Make a Board From Screenshot

Turns an uploaded screenshot of an existing AAC/communication board into a real
SpeakAnyWay `Board` using OpenAI vision. Three-step flow, async in the middle:

- **Upload** — `POST /api/board_screenshot_imports` (`name`, optional `columns`,
  and either `cropped_image` base64 data URL or multipart `image`). Creates a
  `BoardScreenshotImport` (`status: queued`), **spends 3 credits**
  (`screenshot_import` feature key) via `check_credits!`, stashes the spend
  transaction id on `import.metadata["credit_txn_id"]`, then enqueues
  `BoardScreenshotImportJob`. `columns` is sanitized to a positive Integer or
  `nil` (auto-detect) so a bad value can't fail the job after charging.
- **Analyze (async)** — `BoardScreenshotImportJob` (queue `:ai_images`,
  `retry: 1`): `ImagePreprocessor` resizes/deskews/contrast-boosts to a `tmp/`
  file → `BoardScreenshotVisionService#parse_board` (OpenAI **Responses API**,
  JSON mode, model `BOARD_SCREENSHOT_VISION_MODEL`, default `gpt-4.1-mini`)
  returns a full `rows × cols` grid → one `BoardScreenshotCell` per cell →
  `status: needs_review`. The preprocessed temp file is always unlinked in an
  `ensure`. On any failure the import goes `status: failed` **and the 3 credits
  are refunded** to their original plan/topup split (idempotent across the retry
  via a `refund_for_txn` marker).
- **Review + commit** — `PATCH /api/board_screenshot_imports/:id` lets the user
  fix detected `label_norm`/`bg_color`/`row`/`col` per cell (and `cols`); then
  `POST /api/board_screenshot_imports/:id/commit` runs `BoardFromScreenshot`,
  which builds a static `Board` (col→`x`, row→`y` explicit grid layout),
  resolves an `Image` per label, and links it back to the import. `commit`
  returns **422 `import_not_ready`** unless the import is
  `needs_review`/`committed`/`completed`.

**Staging:** `BoardScreenshotVisionService#parse_board` returns a deterministic
placeholder grid when `AppEnv.staging?` — no paid OpenAI call, no real credits
burned — mirroring the image-generation placeholder short-circuit. (The vision
call is **not** gated in real production.)


## OBF/OBZ import — copyright policy

Imports via `POST /api/boards/import_obf` are gated to avoid silently
pulling licensed symbol artwork (SymbolStix, etc.) into the public
image pool:

- **Default (no opt-in):** board structure imports, `Image` rows are
  created **`is_private: true`**, but **no image binaries are downloaded
  or attached to `Docs`**. The `attach_image_doc` step is skipped.
- **With opt-in:** client must send `include_images=true` AND
  `image_license_acknowledged=true`. Without the ack, the controller
  returns **HTTP 400 `image_license_required`**. The importer then
  calls `Down.download` per OBF image entry and attaches Docs.
- **`is_private: true` is non-negotiable.** Set in
  `Board.find_or_create_image_for_button` on every newly-created Image,
  regardless of opt-in. Existing images matched by label are returned
  as-is — we don't downgrade visibility on something the user already
  owns. Admin can flip individual images public later via existing UI.
- **Audit trail** lives on `BoardGroup.settings["imported_from_obf"]`:
  `include_images`, `license_acknowledged`, `acknowledged_by_user_id`,
  `acknowledged_at`, `imported_by_user_id`, and the OBF root board's
  `license` block (author, source URL, license type) if present.
- Plumbed through `ObzImporter#initialize(import_options:)`,
  `Board.from_obf(... import_options:)`, and `ImportFromObfJob#perform`
  (4th positional arg). All default to `{}` for backward compat with
  callers that don't care.
- **`Board.from_obf` returns a tuple** `[board, dynamic_data]`, not a bare
  `Board`. Callers must destructure: `board, _dynamic = Board.from_obf(...)`.
  Signature: `from_obf(data, current_user, board_group = nil, board_id = nil,
  import_options: {})` — don't swap `current_user` and `board_group`.

## Board deletion safety (warn + confirm)

`DELETE /api/boards/:id` is a **warn+confirm** flow. `Boards::UsageCheck`
(`app/services/boards/`) reports what still references the board: folder tiles
on other boards (`board_images.predictive_board_id`, self-links excluded),
communicator dashboards (`child_boards`), team shares (`team_boards`), and
whether it's a Board Builder root. When anything matches and the request lacks
`confirm=true`, destroy returns **409** `{ error: "board_in_use", message,
board: { id, name }, usage: { referencing_boards, communicators, teams,
builder_set } }` (counts exact, name lists capped at 10). Unreferenced boards
delete in one step as before.

- **Builder roots cascade the whole set.** A confirmed delete of a
  `builder_root` board routes through its builder BoardGroup
  (`Board#builder_board_group` → `group.destroy!`), so the #407 cascade
  destroys every member board instead of orphaning the hidden children. This
  routing lives **only in the controller** — a Board `before_destroy` that
  destroyed the group would recurse with the group's `destroy_all` of members.
  A root whose group is gone (legacy data) falls back to a plain destroy.
- **Cleanup on destroy.** Folder tiles pointing at the deleted board are
  nullified by the `predictive_board_images dependent: :nullify` association
  (the old manual loop in `#destroy` was redundant and only covered
  `board_type == "predictive"`). `docs.board_id` is nullified
  (`dependent: :nullify`; docs are user content owned via `documentable`).
  `BoardDestroyCleanupJob` (`app/sidekiq/`, enqueued `after_destroy`, rescue-
  wrapped so a Redis blip can't fail the destroy) scrubs the pointers
  `dependent:` can't reach: `users.editable_board_id`, the
  `dynamic_board_id`/`phrase_board_id` keys in users' and child_accounts'
  settings JSONB, and `Scenario` rows for the board. `word_events` keep their
  `board_id` deliberately (analytics history).
- **`orphan_template?`** (`ChildBoardsController`) also refuses to hard-delete
  a detached template that another board's folder tile still opens
  (`predictive_board_id` reference check) — detach-only in that case.
- Frontend companion: handle the 409 with a confirm dialog and re-send with
  `confirm=true` (special copy for builder roots — it deletes the whole set).

## Board Sets (BoardGroup) — user CRUD + limits

Board Sets (`BoardGroup`, user-facing name "Board Sets") are user-owned
collections of boards. CRUD is open to any signed-in user;
`predefined: true` sets stay admin-curated. Viewing is **public by link** —
`index`, `show`, `show_by_slug`, and `preset` keep
`skip_before_action :authenticate_token!`.

- **Owner-or-admin authorization.** Every mutating action in
  `API::BoardGroupsController` (`update`, `destroy`, `rearrange_boards`,
  `save_layout`, `remove_board`, `add_board`) routes through the private
  `authorize_board_group!` helper: admins always pass; everyone else is
  blocked (**HTTP 403** `"You don't have permission to modify this board
  set."`) unless they own the set *and* it isn't `predefined`. Before this
  work, `rearrange_boards`/`save_layout`/`remove_board` had **no** auth at all
  — any user could mutate anyone's set. `create` is open to all authed users.
- **Protected flags.** `board_group_params` strips `predefined` and `featured`
  for non-admins, so a regular user can't self-promote their set into the
  curated/featured pools.
- **Per-plan creation limits.** Mirrors the board-limit pattern.
  `User#board_group_limit` resolves from the plan hash by `plan_type` (Free 1,
  Basic 25, Pro 50; ENV-overridable via `FREE_/BASIC_/PRO_BOARD_GROUP_LIMIT`),
  with a `settings["board_group_limit"]` override. `User#countable_board_group_count`
  counts own non-predefined sets; `User#at_board_group_limit?` is the gate
  (admins exempt). `create` returns **HTTP 422** `{ error, limit, count }` at
  the cap. **Not 402** — 402 is reserved for credit exhaustion.
- **`add_board` route.** `POST /api/board_groups/:id/add_board/:board_id`
  (`BoardGroup#add_board` does the join + layout init). Beyond the owner-or-admin
  set check, the *board* must belong to the caller or be predefined/public.

## Responsive board layouts (sm/md derived from lg)

A board stores a per-tile `layout` for each screen size (`lg`/`md`/`sm`, plus
`xs`/`xxs` mirrors of `sm`). `lg` is the **authored** layout; md/sm are
**derived** from it so a board reads well on tablets and phones without ever
losing a tile.

- **Column counts — `Boards::ScreenColumns.derive(large_columns, screen)`** is
  the single source of truth: `md ≈ ⅔·lg`, `sm ≈ ⅓·lg`, rounded and clamped so
  `sm ≤ md ≤ lg` with a 2-column floor for phones. `Board#set_screen_sizes`
  (before_create) and `get_number_of_columns` (BoardsHelper) both derive md/sm
  from lg when not explicitly set; `Boards::LayoutRepacker` uses the same rule.
  The frontend mirrors it (`deriveColumns`/`resolveColumns` in
  `nativeLayoutMath`) so viewer, editor, and backend agree.
- **Tile reflow — `Boards::ScreenReflow.reflow!(board, screens:)`** rebuilds the
  md/sm (and xs/xxs) per-tile layouts from the **lg reading order** (sorted by lg
  y,x), width-aware row-major packed into each screen's column count, then
  resyncs `board.layout` via `LayoutRepacker.resync_board_layout!`. lg is never
  modified; every tile is placed (nothing dropped). This is distinct from
  `LayoutRepacker` (which only nudges overflow tiles back inside an existing
  grid — a data-repair net); reflow is the intentional responsive layout.
- **When it runs.** `Board#apply_layout!` calls `sync_derived_screen_layouts!`:
  editing **lg** reflows the non-customized md/sm; editing **md/sm** records that
  screen in `settings["custom_screen_layouts"]` so a later lg edit leaves the
  hand-arranged screen alone. `BuildBoardSetJob` reflows every board in a built
  set at the finalize chokepoint (before `generate_preview!`).
- **Backfill:** `rake board_layouts:reflow_sm_md` (dry-run by default;
  `DRY_RUN=false` to apply, `USER_ID=N` to scope, `KEEP_COLUMNS=true` to reflow
  without recomputing column counts) recomputes proportional md/sm columns and
  reflows existing boards, skipping fully-customized screens.


## Keyboard boards & action tiles

Predefined keyboard template boards ("ABC Keyboard" / "QWERTY Keyboard",
slugs `keyboard-abc` / `keyboard-qwerty`) are seeded by
`db/seeds/keyboard_boards.rb` (`rake keyboard_boards:seed`, idempotent):
`board_type: "keyboard"` (also `Board.keyboards` / `#keyboard?`), 26 letter
tiles + Space/Delete.

- **Tile behavior contract (frontend keys off this, not board_type):** letter
  tiles carry `board_images.data["tile_type"] == "letter"`; action tiles carry
  `data["tile_type"] == "action"` and `data["tile_action"] == "space" |
  "backspace"`. Future action tiles (e.g. play-a-video) add new `tile_action`
  string values plus an optional `data["action_params"]` object — keep
  `tile_action` a bare string. `data` already flows through
  `api_view_for_native_grid`, `BoardImage#api_view`, and `clone_with_images`
  (tiles are `dup`ed), so no serializer/clone changes are needed for new flags.
- **Publish gate:** the seeds create the boards `published: false` because
  frontends without keyboard support render Space/Delete as ordinary speakable
  word tiles. Flip `published: true` only after the frontend keyboard support
  deploys; re-running the seed never unpublishes.
- **Layouts:** authored identically for all screen sizes with equal column
  counts (6 ABC / 10 QWERTY), and `settings["custom_screen_layouts"] = ["md",
  "sm"]` so an lg edit doesn't reflow away the QWERTY stagger or wide space bar.
- Word-as-written playback needs no backend work: the frontend composes the
  string and uses the existing `POST /api/images/generate_audio`.
