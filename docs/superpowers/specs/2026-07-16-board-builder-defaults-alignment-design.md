# Board Builder: unfrozen sub-boards + nav-row alignment

Date: 2026-07-16
Branch: `claude/board-builder-defaults-alignment-f10d86`

## Problem

Two independent defects in Board Builder output.

**1. Built sub-boards are frozen.** `BuildBoardSetJob#finalize_sub_boards!` sets
`settings["freeze_board"] = true` on every child of a built set. Frozen means
"tapping a tile keeps you on this board" — the child never auto-returns home
after a word tap. Builder sets should behave like any other board.

**2. The nav row does not line up across a set.** Every board in a seeded
robust set (Core 60 / Core 84) carries a bottom nav row of category folder
tiles. For motor planning, a given category must sit in the same grid cell on
every page of the set. It does not.

Core 60 root bottom row (6×10 grid, row 5):

```
this  People  Feelings  Food  Drinks  Play  Places  Body  More  that
```

Its children today:

| child   | row 5 |
|---------|-------|
| people  | `Home · (blank) · Feelings · Food · Play · Places · Body · More · · ` |
| food    | `Home · People · Feelings · (blank) · Play · Places · Body · More · · ` |
| play    | `Home · People · Feelings · Food · (blank) · Places · Body · More · · ` |

`Drinks` is absent from every child, so every tile after column 3 shifts one
cell left. The self-tile is a blank gap, and on `play.obf` even the gap is
wrong (column 4; the root's `Play` is column 5).

Core 84 is worse. Children drop `Drinks`, `Time`, `Describe` and `School`, add
a `More` that lives on a different row on the root, and are **6 rows** against
the root's **7** — so the nav row is not even at the same height on screen.

## Decisions

| Question | Decision |
|---|---|
| Self-tile (the tile for the page you're on) | Same tile, same cell, **not muted**, links back to the root. Speaks its label, then navigates. |
| Nav coverage | **Full mirror** of the root's nav row — every category, every column. |
| `this` / `that` / `Home` | Identical row on every page. `Home` is dropped; the self-tile is the way back. |
| Screen sizes | Large layout only. sm/md are out of scope. |
| Existing frozen sets | Backfill via rake. |

## Design

### Part 1 — unfreeze

`BuildBoardSetJob#finalize_sub_boards!` does double duty: it freezes children,
and its `save!` is what makes `Board#check_is_sub_board` recompute and set
`sub_board: true` (which keeps children out of the `main_boards` scope). Drop
only the freeze; keep the save.

- Rename to `classify_sub_boards!` — freezing was half its purpose.
- Guard becomes `next if board.sub_board == true`.
- The doc comment currently sitting above `reflow_screen_layouts!` actually
  describes this method (pre-existing misplacement). Move and rewrite it.
- `lib/tasks/board_builder.rake:179` freezes children in a backfill task. Invert
  it to clear `freeze_board`, keeping the `sub_board` recompute. This is the
  task to run on production for already-built sets.

`Board#is_frozen?`, the `frozen` api_view field, and the frontend's freeze
affordances are untouched — freezing stays available, builder sets just don't
opt into it.

### Part 2 — nav-row alignment

Rule to document in `db/seeds/board_builder_sets/README.md`:

> The root's bottom row is the **nav row**. Every child board in the set has the
> same grid dimensions as the root and reproduces that row cell-for-cell. On the
> page you are currently on, that page's own tile links back to the root instead
> of to itself. Any folder tile the root places outside the nav row sits at the
> same cell on every child.

**Core 60** — children are already 6×10 with the nav row at row 5. Row 5 becomes:

```
this  People  Feelings  Food  Drinks  Play  Places  Body  More  that
```

**Core 84** — children grow 6 → 7 rows. Rows 2–4 are empty on every child, so
nothing moves except the nav row sliding r5 → r6. Row 6 becomes:

```
this  People  Feelings  Food  Drinks  Play  Places  Body  Time  Describe  School  that
```

plus `More` at r5c10, mirroring the root.

Self-tile: `load_board` points at the set root (`boards/core-60.obf` /
`boards/core-84.obf`) rather than at its own file.

**TileDeduper hazard.** `Boards::TileDeduper.collapse_duplicates!` runs during
seeding (`app/services/vocab_sets.rb:198`) and removes tiles sharing a label and
kind, keeping the lowest position. Both `more.obf` files already carry `this`
and `that` as word tiles in row 0, so the new nav-row copies would be silently
deleted and alignment would break on that page only. Remove `this`/`that` from
those two content rows — the nav row is their home now.

**Mute exception.** `BuildBoardSetJob#mute_dynamic_tile_names!` mutes every
dynamic tile, which would silence the self-tile. Skip tiles whose label matches
their own board's name.

### Why the root stays a main board

Children link back to the root, which would normally make the root look like a
sub-board. `Board#check_is_sub_board` already pins a `builder_root?` as a main
board for exactly this reason (the existing `Home` tile creates the same
back-link), so replacing `Home` with the self-tile changes nothing structurally.

## Testing

- **Seed-data spec** — reads the `.obf` JSON directly (no DB): for both sets,
  every child has the root's grid dimensions and its nav row matches the root's
  cell-for-cell, with the self cell linking to the root. Guards future template
  edits.
- **Job spec** — children are not frozen but are still `sub_board: true`; the
  self-tile escapes `mute_name`; other dynamic tiles are still muted.
- Invert the existing frozen expectation at
  `spec/sidekiq/build_board_set_job_spec.rb:163`.

## Out of scope (follow-up issues)

- **Existing built sets keep the misaligned nav row.** Sets are cloned from the
  seed at build time, so reseeding only affects new builds. Realigning existing
  user sets is a separate migration.
- **sm/md alignment.** `Boards::ScreenReflow` repacks smaller screens from the
  lg reading order and compacts gaps, so the nav row will not stay pinned to the
  bottom on phones/tablets. Making it gap-preserving touches a service that
  non-builder boards also use.
