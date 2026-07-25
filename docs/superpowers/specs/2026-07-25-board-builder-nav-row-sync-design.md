# Board Builder — nav row sync across every page in a set

**Date:** 2026-07-25
**Status:** approved, ready for implementation planning

## Problem

The Board Builder's motor-planning rule is already documented in
`db/seeds/board_builder_sets/README.md`:

> Every child board has the same grid dimensions as the root and reproduces the
> root's nav row cell-for-cell. On the page you are currently on, that page's own
> tile links back to the root instead of at itself.

It is authored correctly in the Core 60 / Core 84 seed OBFs (#521) and enforced
against those files by `spec/db/seeds/board_builder_sets_spec.rb`. But authoring
can only ever cover the pages that ship *in* the seed set. Everything a build
adds is uncovered, and a build that adds anything also breaks the pages that
were covered.

Observed on production (`/dynamic/core-60-2d7d1034`): the Drinks page shows the
pre-#521 layout — a `Home` tile followed by 8 shifted category tiles, with no
`Drinks` tile in its own cell. Built sets are clones taken at build time, so
re-seeding the authored templates never reaches them.

### The six gaps

| Page type | Nav row today |
|---|---|
| Core 60 / Core 84 authored fringe pages | correct (9 + 11 pages verified) |
| Prebuilt fringe templates (`fringe-pages/*.obf`) | none — 3x4 boards |
| AI-generated pages (`generate_one_ai_page!`) | none |
| "My Favorites" catch-all | none |
| Phrases page + the 6 GLP function boards | none |
| Any build that adds a page | root-only drift (see below) |

The last row is the structural one. `BuildBoardSetJob#add_folder_tile!` calls
`root.add_image`, which fills the first open cell; the authored Core 60/84 grids
are **full** (60 / 84 tiles, no reserved gaps), so every added page lands on a
**new row below the nav row, on the root alone**. The seeded children's nav rows
go stale the moment a set has interests or GLP phrases. The final nav row is not
knowable until the build finishes, so it cannot be authored — it has to be
projected after the fact.

Additionally, `Boards::ScreenReflow` repacks md/sm/xs from the lg reading order,
so the nav row holds its shape on large screens only. On a tablet or phone it
wraps into whatever rows the packer produces, mid-board.

## Decisions

Settled during design:

1. **Build-time sync + backfill.** Fix new builds *and* heal already-built sets.
2. **Nav region is capped at two rows.** The authored nav row stays pinned to the
   very bottom (so `People` never moves); build-added pages get **one** row
   directly above it. Anything past that stays root-only.
3. **Backfill clears folder tiles only.** Stale *folder* tiles (the old `Home`,
   the shifted categories) are deleted. User-added *word* tiles occupying a
   target cell are relocated into the content area, never dropped.
4. **Coverage includes the Phrases page (depth 1) and the GLP function boards
   (depth 2).** Legacy label-only starter templates (`home`, `daily_routine`) are
   **out of scope** — they are superseded by complexity levels.
5. **"All sizes" means both.** Core 60 and Core 84, *and* the nav region stays
   bottom-pinned on md / sm / xs.

## Design

### The invariant

**Nav region** = the bottom rows of the root board, mirrored cell-for-cell onto
every page in the set. On any given page, the tile whose label matches that
page's own name links to the **root** and speaks its label — the you-are-here
anchor and the way home. Folder tiles the root places outside the nav row
(Core 84's `More` at `[6,11]`) stay pinned at their exact cell.

Rationale: an AAC user learns *where* a word is, not what it looks like. `Food`
must be the same reach from every page in the set.

### `Boards::NavRegion` (new — pure query)

Derives the region from a root board. Used identically at build time and against
an already-built set, so forward-fix and backfill share one definition.

- `nav_y` — the row with the most folder tiles (ties resolve to the lowest row).
  Core 60 → row 6; Core 84 → row 7.
- `added_row` — rows below `nav_y`, capped at 1, folder tiles only.
- `pinned` — folder tiles above `nav_y`, held at their own cells (Core 84 `More`).

A "folder tile" is a `BoardImage` whose `predictive_board_id` points at a board
in the set and is not a self-link.

### `Boards::NavRowSync` (new — the projector)

For every board in the set except the root (BFS via the existing
`BuildBoardSetJob#set_board_ids`, depth 2 so GLP function boards are included):

1. Adopt the root's lg grid dimensions.
2. Evict occupants of target cells. Stale **folder** tiles are deleted. User
   **word** tiles are relocated into the content area.
3. Upsert each nav tile: image resolved via `Boards::ImageResolver`, label and
   `display_label` pinned to the authored name, `predictive_board_id` set to its
   page — or to the **root** when the label matches this board's own name
   (reusing `BuildBoardSetJob#self_tile?` semantics).
4. Stamp `data["nav_tile"] = true` so re-runs know exactly which tiles they own.

Idempotent: a second run over a synced set is a no-op.

### `BuildBoardSetJob` wiring

- New `bottom_align_nav_row!` step. Growth rows currently land *below* the nav
  row; swap so the authored nav row remains last and added pages sit above it.
- Call `NavRowSync` at the existing end-of-build chokepoint, **before**
  `mute_dynamic_tile_names!`, `reflow_screen_layouts!`, `classify_sub_boards!`,
  `set_sub_board_previews_from_tiles!`, and `generate_preview!` — so muting,
  responsive layouts, and previews all observe the final grid.

### `Boards::ScreenReflow` change

Gains `pinned_rows:` (default `0`). When zero, behavior is byte-identical for
every existing caller — this is asserted by spec, not assumed. When set, content
tiles pack into the derived column count and the nav region is appended
bottom-aligned, reflowed to that narrower width.

Accepted limitation: at 4 columns a 10-tile nav row becomes 3 nav rows. It is
still bottom-pinned and still identical on every page in the set.

### Backfill

`rake board_builder:sync_nav_rows` runs `NavRegion` + `NavRowSync` over every
`settings["builder_root"]` set. Dry-run by default; `DRY_RUN=false` to apply,
`USER_ID=N` to scope. Regenerates previews only for boards it changed. Reports
per-set counts of tiles written, folder tiles deleted, and word tiles relocated.

### What is deliberately not changed

The seed OBFs are **not** re-authored. A standalone 3x4 fringe template cannot
know its future root's nav row. The authored Core 60/84 nav rows and
`spec/db/seeds/board_builder_sets_spec.rb` stay exactly as they are — they keep
the admin templates correct and browsable on their own, and `NavRowSync` is a
no-op over them.

## Coverage after this change

| Page type | Before | After |
|---|---|---|
| Core 60/84 authored fringe | yes | yes |
| Prebuilt fringe (Animals, Music, ...) | no | yes |
| AI-generated pages | no | yes |
| My Favorites | no | yes |
| Phrases page (depth 1) | no | yes |
| GLP function boards (depth 2) | no | yes |
| Interest / GLP builds (root drift) | no | yes |
| md / sm / phone layouts | no | yes, bottom-pinned |
| Already-built sets | no | yes, via rake |

## Testing

New specs:

- `spec/services/boards/nav_region_spec.rb` — derivation across Core 60 and
  Core 84 shapes, including the out-of-row `More` tile and a grown grid.
- `spec/services/boards/nav_row_sync_spec.rb` — projection onto a fringe page;
  self-tile links the root and is exempt from muting; idempotency; a user word
  tile is relocated not deleted; a stale folder tile is deleted; depth-2
  coverage; the one-added-row cap.
- Rake task spec — dry-run writes nothing; `DRY_RUN=false` applies.

Extended:

- `spec/services/boards/screen_reflow_spec.rb` — nav rows stay bottom-pinned at
  md/sm/xs; `pinned_rows: 0` output is unchanged from today.
- `spec/sidekiq/build_board_set_job_spec.rb` — a nav row is present on every page
  type across core-60 x core-84, with and without interests, with and without a
  GLP stage.

Unchanged: `spec/db/seeds/board_builder_sets_spec.rb`.

## Risks

- A 3x4 prebuilt fringe page becomes a 10x6 page that is mostly empty above the
  nav region. This is inherent to "same dimensions as the root," which is already
  the documented rule, but it is the most visible change to existing content.
- `Boards::ScreenReflow` is shared with non-builder boards. `pinned_rows:`
  defaults to `0` so nothing outside builder sets changes; a spec asserts the
  default path is unchanged rather than relying on review.
- The backfill mutates live production sets. Dry-run is the default and the task
  reports every deletion and relocation before anything is applied.

## Documentation to update in the same PR

- `.claude-notes/board-builder.md` — the nav-row bullet, describing sync as the
  enforcement mechanism and authoring as the seed-time convenience.
- `db/seeds/board_builder_sets/README.md` — note that the nav row is now
  projected at build time, so authoring covers the admin templates only.
- `CHANGELOG.md` — user-facing entry.
