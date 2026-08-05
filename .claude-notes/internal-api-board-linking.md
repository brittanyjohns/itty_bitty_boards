# Internal API — linking boards (folder tiles)

## The field

`board_images.predictive_board_id` is the only thing that makes a tile open
another board. `BoardImage#is_dynamic?` derives the frontend's "opens another
board" badge from it, and every tree walk in the codebase —
`Boards::PredictiveLinkSet`, `Boards::SetGraphBuilder`, the printables repo's
`walkBoardTree` — follows this one column.

## Where it can be set

| Path | Auth |
|---|---|
| `POST /api/internal/boards/:id/board_images` and `.../bulk` | internal key |
| `PATCH /api/board_images/:id` | user token |
| `POST /api/images/:id/create_predictive_board` | user token |
| `POST /api/board_screenshot_imports/:id/commit` | user token |
| `POST /api/boards/import_obf` (.obz) | user token |
| `POST /api/v1/board_builder` → `BuildBoardSetJob` | user token |

The internal rows are new. Before them, an internal-key caller could create
boards and tiles and set layout but never connect anything, so a multi-page set
could not be assembled unattended.

## Why the attribute needs no validation in the controller

The model already guards both bad cases:

- `check_predictive_board` (before_save) nulls an id that points at nothing
  rather than raising, so a stale id degrades to a plain word tile instead of
  500ing — which matters because `#bulk` is atomic and one bad cell would
  otherwise roll back the whole board.
- `is_dynamic?` requires `predictive_board_id != board_id`, so a self-link is
  inert.

Internal calls run as `User::DEFAULT_ADMIN_ID`, so the worst case is admin
linking to an admin board.

## Gotcha: linked children disappear from board search

`Board#check_is_sub_board` (before_save) sets `sub_board = true` and adds the
`"sub-board"` tag on any board something points at. `Boards::AdminSearch`
filters `sub_board: [false, nil]`, so a newly-linked child drops out of
`GET /api/internal/boards/search`. That's intended — it keeps fringe pages out
of the catalog — but fetch children by id afterward, not by name.

## Consumer

The `speakanyway-board-build` skill (source in `marketing/skills/`) builds a
root plus linked child pages in one pass. It creates children first so folder
tiles can carry `predictive_board_id` in the same bulk call, and it verifies
the link took by checking `dynamic` on the response — falling back to printing
manual wiring instructions if this permit ever regresses.

## Not done here

`part_of_speech` is still absent from `apply_optional_attributes!`, so callers
must send explicit `bg_color` hexes to get Fitzgerald colors. Adding it
interacts with `BoardImage#set_colors` (`before_update if:
:part_of_speech_changed?`), which would overwrite an explicit `bg_color` —
needs its own decision about precedence.
