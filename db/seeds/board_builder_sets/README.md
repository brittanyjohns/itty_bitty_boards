# Board Builder — robust vocabulary set seed format

This directory holds the **authored source** for the Board Builder's "robust
vocabulary set" templates (Core 60, Core 84). Each set is a small linked board
tree authored as **OpenBoard (OBF/OBZ)** JSON, seeded into the database as
admin-owned, predefined boards by `bin/rails vocab_sets:seed`, then **cloned
per user** by the wizard.

> **Share this file with the vocabulary session.** It defines the exact format,
> the slugs, and the conventions the word content must follow. Both Core 60 and
> Core 84 are now authored (below); the `.obf` JSON in each set dir is the source
> of truth — edit it in place to revise the word content.

## Slugs (stable identifiers)

| slug      | name    | status                          |
|-----------|---------|---------------------------------|
| `core-60` | Core 60 | **authored** (home 10×6 + 9 fringe pages) |
| `core-84` | Core 84 | **authored** (home 12×7 superset + fringe + School/Time/Describe) |

The slug is the key the wizard sends as `template` and the identifier stamped on
the seeded **root board** (`settings["board_builder_robust_slug"]`). It must be
URL-safe and stable — don't rename it once shipped.

## Directory layout

```
db/seeds/board_builder_sets/
  README.md                      <- this file
  core-60/
    manifest.json                <- OBZ manifest (root + path map)
    boards/
      core-60.obf                <- root core board (home 10×6)
      people.obf  feelings.obf  food.obf  drinks.obf   <- fringe category pages
      play.obf  places.obf  body.obf  more.obf
  core-84/                       <- same shape: home 12×7 superset + the core-60
    manifest.json                   fringe + School / Time / Describe pages
    boards/
      core-84.obf
      people.obf  feelings.obf  food.obf  drinks.obf  play.obf  places.obf
      body.obf  more.obf  school.obf  time.obf  describe.obf
  fringe-pages/                  <- standalone interest templates, one directory
    core-60/                        per core set (see "Fringe page templates")
      animals.obf  art-craft.obf  bathroom.obf  clothing.obf  home.obf
      music.obf  nature-outdoors.obf  social.obf  sports.obf
      technology.obf  transportation.obf
    core-84/                     <- the same eleven categories, widened
      animals.obf  ...
```

The seeder reads this directory, zips it **in memory** into an `.obz`, and feeds
it to `ObzImporter`. You never commit a binary `.obz` — the JSON is the source
of truth, so diffs stay reviewable. `bin/rails vocab_sets:build[core-60]` can
emit a distributable `.obz` if you need the binary for an external tool.

## OBF file format (OpenBoard 0.1)

One `.obf` per board. Minimal shape:

```jsonc
{
  "format": "open-board-0.1",
  "id": "core-60:food",          // MUST be namespaced "<slug>:<name>" — see "OBF id namespacing"
  "locale": "en",
  "name": "Food",                // see "Fringe board names" below — load-bearing
  "grid": { "rows": 2, "columns": 3, "order": [[1,2,3],[4,5,6]] },
  "buttons": [
    { "id": 1, "label": "apple", "part_of_speech": "noun" },
    { "id": 2, "label": "Play",  "part_of_speech": "noun",
      "load_board": { "path": "boards/play.obf" } }   // folder tile -> fringe page
  ],
  "images": [],
  "sounds": []
}
```

- **`grid.order`** is a `rows × columns` matrix of button `id`s (`null` = empty
  cell). `ObzImporter` lays the tiles out from this — no manual layout needed.
- **`buttons[].label`** — the word/phrase. Symbols resolve like normal board
  creation: lowercased lookup against existing public/admin images (proper nouns
  and `"I"` keep their casing); a miss creates a blank-art image and AI art is
  generated later. **Use our own labels only — never copy a commercial pageset
  (CommuniKate, SymbolStix word lists, etc.).**
- **`buttons[].part_of_speech`** — drives tile color via the modified Fitzgerald
  key (`ImageHelper`/`BoardImage#set_colors`). Supported values:
  `pronoun` (yellow), `verb` (green), `adjective` (blue), `noun` (orange),
  `preposition`/`social` (pink), `question` (purple), `adverb` (brown),
  `conjunction` (white), `determiner` (gray), `important_function` (red).
  Omit for default (gray).
- **`buttons[].load_board.path`** — makes a button a **folder tile** that opens
  another board in the set (relative path into `boards/`). The importer wires
  this to `BoardImage#predictive_board_id`. This is how the root core board
  links to its fringe pages.
- **`ext_saw_image_id`** (optional) — pin a button to a specific SpeakAnyWay
  `Image#id` instead of resolving by label. Use sparingly.
- **Do NOT include a top-level `board_group` key.** This feature is deliberately
  **root-board only** (no `BoardGroup`); a `board_group` block would make the
  importer create one.

## manifest.json

```jsonc
{
  "format": "open-board-0.1",
  "root": "boards/core-60.obf",   // path, NOT an id — never namespaced
  "paths": {
    "boards": {
      "core-60:core-60": "boards/core-60.obf",
      "core-60:food":    "boards/food.obf"
      // one entry per namespaced board id -> path
    }
  }
}
```

## OBF id namespacing (one rule, non-negotiable)

Every board's top-level **`id`** MUST be prefixed with its set slug:
`"<slug>:<name>"` (e.g. `"core-60:people"`, `"core-84:people"`,
`"core-60:core-60"`). The `paths.boards` **keys** in `manifest.json` use the
same namespaced ids.

Why: `Board.from_obf` resolves the target board by `(user_id, obf_id)`, and both
sets seed as the same admin user. Before namespacing, Core 60 and Core 84 shared
the bare ids (`people`, `food`, …), so both roots ended up linked to **one**
shared fringe board and the last set seeded won that page's back-link to its root
— leaving the other set's cloned pages with a dead way home (#278).

What is NOT namespaced:

- **Button `id`s** stay local integers (`1`, `2`, …) — they're scoped to one board.
- **`load_board.path`** stays a zip path (`"boards/play.obf"`) — links resolve by
  path, so they're unaffected by the namespace. Don't use `load_board.id`.
- **`manifest.root`** is a path, not an id.

Adding a board to a set = give its `.obf` a `"<slug>:<name>"` id and add the same
key to the manifest. The seeder's destructive sync (below) cleans up any board or
tile you remove.

## The nav row must be identical on every board in a set

The root's **bottom row** is the set's **nav row** — the strip of folder tiles
that reaches every page. It is authored under one rule, enforced by
`spec/db/seeds/board_builder_sets_spec.rb`:

> Every child board has the **same grid dimensions as the root** and reproduces
> the root's nav row **cell-for-cell**. On the page you are currently on, that
> page's own tile links back to the **root** instead of at itself. Any folder
> tile the root places **outside** the nav row (Core 84's `More`) sits at that
> same cell on every child.

Why: motor planning. An AAC user learns *where* a word is, not what it looks
like — `Food` must be the same cell on every page of the set, so the reach is
the same everywhere. The tile you just tapped stays put under your finger and
becomes the way back.

This is why there is no `Home` tile: the self-tile is home. On the People page,
`People` is both the you-are-here anchor and the way back to the root. It is the
one nav tile that speaks its label (`BuildBoardSetJob#mute_dynamic_tile_names!`
mutes folder tiles, but exempts a tile whose label matches its own board's name).

Two traps when editing a nav row:

- **Don't renumber existing buttons.** The seeder upserts tiles on the authored
  button `id` (`obf_button_id`) and re-pins their cells by it, so *moving* a
  button = keep its id, change only `grid.order`. A new id forks a new tile.
- **Don't author the same label twice with the same kind** (word vs folder) on
  one board — `Boards::TileDeduper` collapses those on seed, keeping the
  lowest-position copy, which silently deletes the nav-row one. That's why
  `more.obf` carries `this`/`that` only in the nav row, and why `food.obf`'s
  `Drinks` link lives in the nav row rather than in the content grid.

**Authoring covers the admin templates; the build enforces the rule.** These
`.obf` files are seeded as admin-owned boards and browsed on their own, so keep
authoring the nav row here — `spec/db/seeds/board_builder_sets_spec.rb` still
guards it. But a *built* set gets its nav row projected at build time by
`Boards::NavRowSync`, because the final row isn't knowable until the build
finishes adding pages (prebuilt fringe, AI-generated, My Favorites, Phrases).
That is also why the standalone `fringe-pages/*.obf` templates carry **no** nav
row: they're cloned into arbitrary sets and can't know their future root's.

## How full a page should be

A page that fills two rows of a six-row grid reads as broken on a classroom TV,
and it wastes the thing the set is for — the authored root grids are 100% full,
so a fringe page ought to look like it belongs to them. Every page therefore
fills **whole rows from the top**, with the last content row left empty:

| page | grid | content cells | authored words |
|---|---|---|---|
| Core 60 fringe | 10×6, nav row 5 | 50 | **40** (rows 0–3) |
| Core 84 fringe | 12×7, nav row 6 + pinned `More` | 71 | **60** (rows 0–4) |
| `fringe-pages/core-60/*` | authored 10×4 | — | **40** |
| `fringe-pages/core-84/*` | authored 12×5 | — | **60** |

A partial final row is worse than a short board: rows aren't stored
(`Board#rows_for_screen_size` derives them from the tiles), so the leftover
cells sit at the right end of the last row rather than shortening the page.
Fill whole rows or don't fill the row.

The Core 84 page for a category is a **superset** of the Core 60 one, and the
same word sits in the same part-of-speech block on both — moving up a set is a
widening, not a relearn.

### `More` is the exception: it is the build's overflow drawer

`Boards::FolderPlacer` tucks every page a build ADDS (prebuilt fringe,
AI-generated, My Favorites, Phrases, the GLP function boards) into the set's
`More` page, because the authored home grid has no open cell and growing it
loses the seed's single-screen `disable_scroll`. A build can add up to
`max_pages` (15 on `extended`) of them.

So `More` keeps **two** spare rows, not one — Core 60's More is 30 words, Core
84's is 48. Filling it like any other page leaves one row for fifteen pages and
silently pushes the overflow back onto the home grid. This is the one page
where white space is load-bearing.

## Fringe page templates (`fringe-pages/`)

These are the **standalone** interest templates, separate from the pages that
ship inside a set. `Boards::StructurePlanner` reaches for one only when a
category is NOT a page of the level's core set — `source_for_category` returns
`:seed_set` first and short-circuits — and `BuildBoardSetJob` then clones it and
hangs a folder tile off the home board. Without a template, that category costs
the user AI credits every build.

**One template per category PER CORE SET.** A Core 60 page is 10 columns and a
Core 84 page is 12, and `Boards::NavRowSync` force-widens a clone's
`large_screen_columns` to the root's **without moving a single tile** — so a
10-wide template dropped into a Core 84 set renders with two dead columns and
two thirds of a sibling page's vocabulary. Hence `core-60/` and `core-84/`.

Three rules:

- **`ext_saw_core_template`** (`"core-60"` or `"core-84"`) is a required
  top-level key. It — not the directory — is what
  `Boards::FringeTemplates.seed_data!` stamps into
  `settings["fringe_template_core_template"]`, so an .obf pasted into
  `/admin/board_builder_templates` carries the same authority a file does. A
  spec asserts the key and the directory agree.
- **Ids are namespaced like everything else**, and core-60 keeps the bare
  `fringe:<slug>` it shipped with so existing rows upsert in place; core-84 uses
  `fringe:core-84:<slug>`. Sharing an id would make one variant overwrite the
  other — #278, one directory over.
- **core-84 is a SUPERSET of core-60**, same word in the same part-of-speech
  block, for the same reason the core sets are: moving up a set is a widening,
  not a relearn.

Resolution at build time is `Boards::FringeTemplates.find(category,
core_template:)`: the exact variant, then a row carrying no variant (seeded
before variants existed, or hand-registered), then the other variant as a last
resort — a page needing a repack still beats charging AI credits for one we have
authored. `/admin/board_builder_templates` names the missing variant rather than
absorbing it silently.

### Re-seeding is not automatic

```bash
bin/rails fringe_templates:seed     # or the registry's "Re-seed all" button
```

Editing an `.obf` changes nothing already in the database. The eleven templates
were re-authored from 3×4/12 words to 4×10/40 in #747 and the production rows
were never re-seeded, so builds cloned a page a quarter of the intended size for
months — and the registry reported them healthy, because the only source check
asked whether a FILE existed. `Boards::TemplateHealth#stale_vs_source?` now
compares the row's grid and tile count against its authored file and flags the
mismatch, so **re-seed after every content revision** and check the registry is
green.

## Fringe board names are load-bearing

A child's interest words are routed into fringe pages by **board name**. The
wizard maps each interest to a category via `Boards::InterestCategories`
(`Food`, `Feelings`, `Play`, `Bathroom`, …) and drops it into the cloned fringe
board whose name matches that category. So:

- Name a fringe page exactly after its category (`"Food"`, `"Feelings"`,
  `"Play"`) for interest routing to land there.
- Anything with no matching fringe page falls through to an auto-created
  **"My Favorites"** page — nothing the child typed is ever dropped.
- To add routing for a new category, add its words to
  `Boards::InterestCategories::KEYWORDS` and give the set a fringe page with
  that category's name.

## Depth limit

The clone walks the linked tree to **depth 2** (root + fringe + one more level),
matching `Boards::BoardTreeBuilder::MAX_DEPTH`. Keep sets to a core board + one
layer of fringe pages.

## Seeding & rebuilding

```bash
bin/rails vocab_sets:seed                 # seed all known slugs
bin/rails vocab_sets:seed SLUGS=core-60   # seed one
DRY_RUN=1 bin/rails vocab_sets:seed       # report only, no writes
bin/rails 'vocab_sets:build[core-60]'     # emit a distributable .obz
```

Seeding is **idempotent**: re-running finds the existing set by its root
`board_builder_robust_slug` and updates in place (no duplicates).

Seeding is also a **destructive sync** (admin-owned set boards only — user clones
are deep copies and never touched): after upserting, the seeder

- destroys any tile (`board_image`) on a seeded board whose label is no longer in
  the source OBF (so removing a tile from the JSON removes it on re-seed), and
- destroys any admin-owned board whose `obf_id` belonged to this set but is no
  longer in the manifest — including the legacy **un-namespaced** ids
  (`people`, `food`, …) and fully-removed boards (`keyboard`).

That last step makes the migration off the pre-namespacing collision era (#278)
and the #276 content revisions **self-healing**: one `bin/rails vocab_sets:seed`
after deploy cleans up the old shared boards — no manual console work needed.
