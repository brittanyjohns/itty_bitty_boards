# Create a Board Group (map) for any linked board

## Problem

The Board Set "bird's-eye map" (`Boards::SetGraphBuilder`, `GET /api/board_groups/:id/graph`)
only works for boards already in an eligible `BoardGroup`. Board Builder boards
get one automatically (`builder: true`, created in
`Api::V1::BoardBuilderController#create`). Boards a user links together by
hand (folder buttons pointing at other boards, no wizard involved) never get a
`BoardGroup` at all, so they can never get a map.

## Goal

Given any board, let the owner (or admin) create a `BoardGroup` for it on
demand, auto-populated with every board reachable via folder links, so the
map becomes available immediately.

## Design

### `Boards::LinkedBoardsFinder`

Extract the existing BFS traversal out of
`Boards::SetGraphBuilder#bfs_boards_from_root` into a small shared service:

```ruby
Boards::LinkedBoardsFinder.new(root_board).call # => [Board, ...] reachable via
                                                 # board_images.predictive_board_id,
                                                 # root included, same MAX_BOARDS cap
```

`SetGraphBuilder#bfs_boards_from_root` becomes a thin call into this service
(no behavior change for the graph endpoint — same cap, same traversal).

### `Boards::BoardGroupCreator`

```ruby
Boards::BoardGroupCreator.new(board: board, user: user).call
# => BoardGroup (existing or newly created)
# raises Boards::BoardGroupCreator::LimitReached if user.at_board_group_limit?
```

Behavior:
1. If `board` already belongs to an eligible group (same rule the frontend
   uses: `builder: true` OR non-predefined owned group — i.e.
   `board.board_groups.where(predefined: [false, nil]).first || board.board_groups.builder.first`),
   return it. No duplicate is ever created.
2. Otherwise, check `user.at_board_group_limit?` — raise `LimitReached` if so
   (mirrors the existing 422 contract used by `BoardGroupsController#create`
   and `BoardBuilderController#create`).
3. BFS-discover boards via `Boards::LinkedBoardsFinder.new(board).call`.
4. In a transaction: create `BoardGroup.new(user: user, name: board.name,
   builder: false, root_board_id: board.id)`, then call `add_board` for each
   discovered board in BFS order. Membership order follows `add_board`'s own
   default behavior (it doesn't set an explicit `position`) — this is
   cosmetic and doesn't affect the graph endpoint, which builds its own
   edges rather than relying on `position`.
5. Return the group.

### Endpoint

`POST /api/boards/:id/create_board_group` (member route on `resources
:boards`, alongside `add_to_groups`) → `Api::BoardsController#create_board_group`.

- `set_board`, then 401 unless `@board.user_id == current_user.id ||
  current_user.admin?` (same pattern as `make_editable`).
- Calls the service; on `LimitReached` renders the standard 422 shape:
  `{ error: "...", limit: ..., count: ... }`.
- On success, renders `board_group.api_view_with_boards(current_user)`,
  status `:created` (201) if a new group was made, `:ok` (200) if an existing
  one was returned (lets the frontend distinguish "created" vs "reused" if it
  ever wants to, though it doesn't need to for v1 — it just navigates to the
  map either way).

### Out of scope

- Editing group membership after creation — existing add/remove-board UI
  covers that.
- Any change to the Board Builder's own `builder: true` group creation path.
- Frontend changes — handed off separately to `itty-bitty-frontend` (see
  `docs/superpowers/specs/2026-08-04-create-board-group-for-board-design.md`
  companion prompt delivered to the user).

## Testing

- `spec/services/boards/linked_boards_finder_spec.rb` — BFS traversal,
  cycles, cap.
- `spec/services/boards/board_group_creator_spec.rb` — creates a new group
  with correct members; returns existing eligible group instead of
  duplicating; raises `LimitReached` at the plan limit.
- `spec/requests/api/boards_create_board_group_spec.rb` (or added to the
  existing boards request spec) — 401 for non-owner, 422 at limit, 200/201
  happy path, idempotent re-call returns the same group.
