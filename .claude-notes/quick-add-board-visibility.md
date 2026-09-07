# Quick-add board visibility

How the quick-add picker decides which boards to offer, and how it labels the
ones somebody else also sees. Covers `Boards::QuickAddScope`,
`GET /api/account/quick_add_targets`, the `add_image` gate, and the two new
fields on `GET /api/boards/list`.

## The problem it solves

Assignment **attaches** a board rather than copying it, and it attaches the
**root** of a set. A set's folder pages are reachable by tapping a tile but
carry no `child_boards` row of their own. So `ChildAccount#boards` — the
dashboard association — answers "which boards were attached", never "which
boards is this communicator actually looking at".

Both halves of quick-add were built on that association, so a child standing on
the "Food" page of their Core 84 set could not pick it, and the write gate would
have refused it anyway.

## One object, both halves

`Boards::QuickAddScope` (`app/services/boards/quick_add_scope.rb`) is the single
answer, and **the picker and the write gate instantiate it**:

| surface | reads |
|---|---|
| `API::Account::QuickAddTargetsController#index` | `board_ids`, `shared?`, `root_ids_for`, `truncated?` |
| `Api::BoardsController#check_communicator_board_access!` | `include?` |
| `Api::BoardsController#list` | `state_for` |

A board the picker offers therefore cannot 403, and one it withholds is always
refused — that agreement is structural, not two copies of the same arithmetic
(the reasoning behind `Permissions::CommunicatorLimits.slots_for`). Pinned by
the "picker and the gate agree" example in
`spec/requests/api/boards_quick_add_spec.rb`.

**Anything that widens one widens the other.** Do not add a membership shortcut
to the gate; the whole point of the change was removing the second code path.

## Two questions, and only one of them is enforced

- **Membership (`include?`) is ENFORCED.** A board reached only through a folder
  tile aimed at another account is refused.
- **Sharing (`shared?`) is ADVISORY.** Nobody is blocked for it. It drives a
  badge, and on the user side a confirm-once-per-board dialog. Boards on several
  dashboards are the *normal* setup (siblings, a classroom set on five kids), and
  quick-add exists so a nonspeaking person can add a word when they need it —
  refusing there would disable the feature on exactly the boards people use most.

## The entitlement filter is a SECURITY CONTROL

`QuickAddScope#entitled_ids` is passed to `ReachableBoardIds` as `admit:`, and it
is the reason expanding to reachability is safe. Do not remove it, and do not
relax it into a post-filter on the results — it must veto a board *before* the
walk expands through it.

`API::BoardImagesController` permits `predictive_board_id` in
`board_image_params` while `owned_board_image` validates only the **tile's**
board, never the target. Board ids are sequential. So a tile on a board you own
can point at anyone's board. Attachment-based access made that inert;
reachability does not. The walk refuses to *follow* a pointer it has no right to
rather than trusting the pointer. (Contrast `Api::BoardsController#linkable_board`,
which does scope its target — the two write paths for that one column disagree,
and the loose one is the generic tile update. Tracked separately.)

Admitted: boards owned by `[account.user_id, account.owner_id]` (the family plus
a lending SLP), or shared to one of the communicator's teams — the same
allowlist `Boards::AssignableSource` used to let the board reach the dashboard.
For a `User` context, their own non-template boards (admins unfiltered), so the
picker can never offer what `check_board_view_edit_permissions` would refuse.

**Public/predefined library boards are deliberately NOT admitted.** They are
admin-owned and assignment attaches the real row, so a tile added there lands on
the board every account sees — `add_image` has no `predefined` guard, though its
sibling `associate_image` does. The owner-or-admin gate already refuses the
parent, so excluding them makes the communicator match the adult. This is a
behavior change: a communicator with an attached public board loses quick-add on
it.

## Sharing follows reachability, and inherits from the root

`ReachableBoardIds` gained `track_origins:`, which records the seed(s) each board
descends from. A page's audience is its own `child_boards` rows unioned with
those of every root that reaches it, minus the acting communicator. Sub-page
inheritance is therefore a property of the propagation, not a hand-written rule —
a root on two dashboards makes every page of that set shared.

BFS alone under-propagates across a diamond (a node first reached at depth 2
never re-walks its links when a second seed arrives at depth 3), so
`ReachableBoardIds#propagate_origins` settles the edge set to a fixpoint. Cheap:
the edges are already in memory.

**Audience queries JOIN `child_accounts`**, never `pluck(:child_account_id)`
alone. `ChildAccount` default-scopes to `archived_at: nil` while `ChildBoard`
does not, and `original_child_boards` is `dependent: :nullify` so orphan rows
exist. Without the join an **archived** sibling marks a board shared forever and
the badge never comes off.

Seeds use `board_id` only, never `original_board_id` — that column points at the
source a legacy clone was made from, and the source board is on nobody's screen.
`Board#in_use_by` unions both and so can name one more communicator than
`communicator_dashboard_count` reports. **That divergence is deliberate; do not
change either side to match.**

Sharing is advisory, so it can under-report by one exotic path: a *stranger's*
board that folder-links **into** one of your pages is invisible without an upward
ancestor walk. That walk is what the first draft of this feature carried and it
existed only to justify refusing someone. Don't add it back without a reason.

## Caps and truncation

`QUICK_ADD_MAX_BOARDS` (default 800, read at call time) bounds nodes;
`MAX_DEPTH` (12) bounds levels, which is what actually multiplies queries — one
per level. On truncation `board_ids` is a prefix and the endpoint reports
`truncated: true`. The picker and the gate still agree, because both read the
same prefix. Never an error and never a wholesale refusal: usage must never break.

Cost is `O(depth)`, flat in board count. Pinned as a property (same query count
for a wide set as a narrow one) rather than a magic number, in
`spec/requests/api/account/quick_add_targets_spec.rb`.

## The leak rule

`Board#quick_add_card_view` exists because neither existing serializer is safe
here. `api_view` publishes `in_use_by` (communicator names) and
`communicator_account_data` (ids, names, avatars) — exactly what a communicator
must never learn about another family — and is expensive. `list_api_view`
resolves `can_edit`/`locked` for a *User* viewer and pays
`tiles_awaiting_art_count` per board.

**`shared` on the communicator card is a bare boolean.** No count, no names, no
owner. `audience_count` returns 0 for a `ChildAccount` context and is not
serialized there.

Hydration preloads **both** cover attachments
(`with_attached_preview_image`, `with_attached_preset_display_image`):
`Board#display_image_url` consults both and `#preview_image_url` consults one, so
a missing preload is a silent N+1 per card.

## `shared_with_communicators` vs `in_use_by` — both ship, neither derives the other

#877 added `in_use` / `in_use_by` to `list_api_view` for a neighbouring reason:
a source board and a copy on a communicator share a name, so the picker needed
to say "Assigned to Austin". `Board.communicator_names_for` answers it batched,
scoped to communicators **the caller owns** (deliberately narrower than
`visible_communicator_child_boards`, which widens for admins).

`shared_with_communicators` answers the safety question instead: does a word
added here reach **any** dashboard but the acting one, *including one belonging
to somebody else*. `in_use_by` deliberately hides those, so a published board a
stranger assigned reads `in_use_by: nil, shared_with_communicators: true` —
which is precisely the case the warning exists for.

There is **no count field.** One was dropped on the merge: over the viewer's own
communicators it would have been `in_use_by`'s names re-counted, and two fields
that must agree eventually don't. Frontend that wants a number should count the
names in `in_use_by`.

## The ETag (`boards-list-v3`)

`Board#recalculate_in_use!` writes with `update_column`, which does **not** bump
`updated_at` — so attaching or detaching a board changed nothing the original
tuple could see, and a flag derived from it sits frozen behind a 304.

The tuple therefore carries **two** independent sets of terms, and neither
replaces the other:

- #877's, keyed on the caller's **communicators** (`child_boards` joined to the
  caller's accounts, plus `ChildAccount.maximum(:updated_at)` so a rename
  invalidates). Full precision `to_f`, so an assign-then-rename inside one
  second still invalidates.
- `boards_list_share_fingerprint`, keyed on the caller's **boards**. A stranger
  attaching one of this user's published boards flips
  `shared_with_communicators` while touching no communicator of the caller's —
  invisible to the terms above. Pinned by a spec.

Adding a folder tile was already covered (`BoardImage belongs_to :board,
touch: true`).

Known gap: a folder tile added on **somebody else's** board that newly makes one
of this user's pages reachable elsewhere is not fingerprinted. Covering it means
fingerprinting an unbounded ancestor set. The badge is advisory and the write
gate recomputes from scratch, so the gap is a stale badge, never a wrong
permission.

`sub_board` on the card is the **stored column**, written by a `before_save`
hook — a board linked into a set after creation still reads `false` until
something re-saves it. **Group by `root_board_id`** (which comes from the walk),
never by that flag.

---

## Frontend handoff

### `GET /api/account/quick_add_targets` (communicator token)

```jsonc
{
  "boards": [
    {
      "id": 12, "board_id": 12, "name": "Food", "slug": "food",
      "bg_color": "...", "text_color": "...",
      "display_image_url": "...", "preview_image_url": "...",
      "sub_board": true,
      "root_board_id": 7,     // group pages under their dashboard root
      "shared": true          // badge only — never blocks, never names anyone
    }
  ],
  "truncated": false,
  "limit": 800
}
```

Replaces `currentAccount.boards` as the source for `quickAddOptions` in
`AccountDashboard.tsx` and `BoardNativeGridPage.tsx` — that association only ever
held roots, which is why a communicator could not pick the page they were on.
`shared: true` renders the badge; **do not disable the option.** When
`truncated`, tell the user some boards aren't listed rather than failing.

### `GET /api/boards/list` (user token)

- `shared_with_communicators` (boolean, new here) — show the icon, and gate the
  confirm-once-per-board dialog on it (mirror `confirmedBoardIds` in
  `data/marketplaceProtection.ts`).
- `in_use_by` (string or nil, from #877) — the communicators **you own** that
  use this board, for the confirm copy: *"Maya uses this board too."* It can be
  nil while `shared_with_communicators` is true, when the other dashboard
  belongs to somebody else — say "someone else uses this board" there rather
  than naming nobody. Don't treat nil as "not shared".

There is no count field; count the names in `in_use_by` if you need one.

Optional `?communicator_id=<id>` scopes the boolean to "shared beyond THIS
communicator". An id the caller doesn't own or supervise is ignored, not
honoured as a filter.

Bump any cached copy: the ETag is now `boards-list-v3`, so every client
revalidates once.

### Also worth fixing while in there

`QuickAddModal.handleSave` catches everything into a plain red banner, so a
marketplace-protected board shows a dead end instead of the confirm that
`quickAdd.ts` already prepares via `guardMarketplaceConflict`. Wire
`useMarketplaceGuard`'s `runGuarded` in at the same time.
