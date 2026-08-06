# Publish cascade for Board Builder sets

**Date:** 2026-08-05
**Repos:** `itty_bitty_boards` (backend), `itty-bitty-frontend` (frontend)
**Status:** Approved design

## Problem

`Board#viewable_by?` gates every board independently — it returns true for a
published board and otherwise falls through to owner/admin/team checks. Publishing
a board sets exactly one `boards.published` flag; nothing propagates that flag to
any other board.

For a Board Builder set this produces a broken public page. An admin publishes the
root board, a member of the public opens `/pb/<slug>`, taps a folder tile pointing
at a sub-page, and `Api::BoardsController#show` runs `viewable_by?` against the
*sub-board* — which is still unpublished — and returns the deliberately vague 404.
The set looks published but only its first page works.

The inverse leaks the other way: unpublishing the root leaves every sub-page
publicly reachable by its own `/pb/<slug>` URL.

## Scope

Publishing and unpublishing a Board Builder root cascades to that set's member
boards, behind a confirmation prompt.

**In scope**
- Cascade over Board Builder `BoardGroup` membership, both directions.
- Warn-then-confirm before any write.
- Admin-only, matching the current server-side permission on `published`.

**Out of scope**
- Folder-tile (`board_images.predictive_board_id`) descendants that are not
  Board Builder set members.
- The `BoardForm` publish toggle being shown to non-admins while
  `board_params` discards `:published` for them. Filed separately.
- `ChildBoard#published`, which is a distinct communicator-dashboard flag.

## What defines the set

A board is a cascade root when both hold:

- `Board#builder_root?` (`app/models/board.rb:230`) — checks
  `settings["builder_root"]`.
- `Board#builder_board_group` (`app/models/board.rb:237`) resolves a
  `BoardGroup` with `builder: true, root_board_id: <board>.id`.

Members are that group's `board_group_boards` boards. This is the same group
`Boards::UsageCheck#builder_group` already uses to cascade deletion, so the
cascade set is identical in both directions and no new graph traversal is
introduced. `Boards::PredictiveLinkSet` is deliberately not used.

## Backend design

### `Boards::PublishCascade`

New read-plus-apply service in `app/services/boards/`, a sibling to
`Boards::UsageCheck` and following its shape (constructor takes the board,
memoizes the builder group, caps name lists).

```ruby
Boards::PublishCascade.new(board)
  #needed?(published:)  # -> Boolean
  #summary(published:)  # -> Hash for the 409 body
  #apply!(published:)   # -> Integer count of member boards changed
```

`#needed?` is true when the board is a builder root with a group **and** at
least one member board other than the root has `published != published`.
Members that already match the target do not count, so re-saving an
already-cascaded set never prompts.

`#summary` returns:

```ruby
{
  action: "publish",              # or "unpublish"
  board_group: { id:, name: },
  affected: { count: 12, names: ["Food", "Feelings", ...] }  # names capped at 10
}
```

The name cap reuses `UsageCheck::NAME_SAMPLE_LIMIT`'s rationale: counts are
exact, name lists are sampled so a large set cannot blow up the payload.

`#apply!` writes members with
`Board.where(id: member_ids).update_all(published:, updated_at: Time.current)`.
Callbacks are skipped intentionally — a built tree can be dozens of boards and
only one boolean column is changing. `updated_at` is set explicitly because
`update_all` does not touch it. The root board is **not** written by this
method; the controller saves it through the normal update path.

### Controller guard

Publishing has no dedicated endpoint. It rides `PATCH/PUT /boards/:id` →
`Api::BoardsController#update` (`app/controllers/api/boards_controller.rb:451`),
which assigns `@board.published` from `board_params`.

The guard runs at the **top of `#update`, before any attribute is assigned**, and
fires only when all of the following hold:

1. `:published` survived `board_params` (i.e. `current_user` is an admin — the
   non-admin strip at lines 1462–1468 is unchanged).
2. The requested value differs from `@board.published`.
3. `Boards::PublishCascade#needed?` is true for that target value.
4. `params[:confirm]` is not truthy.

When it fires, the controller returns **409** with:

```json
{
  "error": "publish_cascade_confirmation_required",
  "cascade": { "action": "publish", "board_group": {...}, "affected": {...} }
}
```

Failing before assignment means a rejected save writes nothing at all — the
user's unrelated edits in the same payload are neither applied nor lost, because
the client resends the identical payload with `confirm=true`. This is the exact
protocol the delete flow already uses (`#destroy` → `Boards::UsageCheck` → 409
`board_in_use` → resend with `confirm=true`), which is why no new route is added.

With `confirm=true`, the root board's update and `PublishCascade#apply!` run
inside a single `ActiveRecord::Base.transaction`, so a failed root save cannot
leave members flipped.

## Frontend design

`BoardForm.tsx` already seeds `publishBoard` from `board.published` and sends
`published: publishBoard` in the save payload. The change is the two-step
warn-then-confirm that `BoardEditorHeader.tsx` uses for delete:

1. Save throws on the 409. Catch it, read the `cascade` payload.
2. Build the message with a new `publishCascadeDescription()` helper placed
   alongside `src/components/utils/boardUsage.ts`, which turns the payload into
   a sentence.
3. Open the existing `ConfirmAlert` (`src/components/utils/ConfirmAlert.tsx` —
   generic despite its `ConfirmDeleteAlert` default-export name).
4. On confirm, resend the same payload with `confirm: true`.

Copy, keyed on `cascade.action`:

- **publish** — "This board set has 12 pages. Publishing will also make all 12
  publicly visible."
- **unpublish** — "This will also remove 12 pages from public view."

The publish wording frames the cascade as what makes the public page work; the
unpublish wording frames it as closing the direct-link leak. Neither dialog is
reachable by non-admins, since the 409 can only fire when `:published` survived
`board_params`.

## Testing

**Backend** (request specs on `PATCH /boards/:id`, plus a unit spec for the
service):

- Builder root with unpublished members → 409, and no board's `published`
  changed.
- Same request with `confirm=true` → root and all members published.
- Published builder root → unpublish with `confirm=true` → root and all members
  unpublished.
- Builder root whose members already match the target → no 409, normal update.
- Non-builder-root board → no 409, normal update, no other board touched.
- Non-admin sending `published` → still stripped, no cascade, no 409.
- A 409'd request carrying other changed attributes (e.g. `name`) leaves those
  unwritten.

**Frontend** (`BoardForm`): 409 opens the confirm dialog with the affected count;
confirming resends with `confirm: true`; cancelling sends nothing further and
leaves the toggle reflecting the unsaved intent.

## Documentation

- `.claude-notes/boards-and-teams.md` — a "Publish cascade (warn + confirm)"
  section next to the existing board-deletion warn+confirm section, documenting
  the invariant: a Board Builder set publishes and unpublishes as a unit.
- `.claude-notes/board-builder.md` — pointer to the above.
- `CHANGELOG.md` in both repos.

## Follow-up filed separately

`BoardForm.tsx` presents the publish toggle, public URL, and QR code to every
signed-in user, but `board_params` deletes `:published` for non-admins. Either
the toggle should be admin-gated or board owners should be allowed to publish
their own boards. Resolving that is a permissions decision independent of this
cascade work.
