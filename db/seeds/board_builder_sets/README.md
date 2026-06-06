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
shared fringe board and the last set seeded won the in-set Home pointer — leaving
the other set's cloned pages with dead Home tiles (#278).

What is NOT namespaced:

- **Button `id`s** stay local integers (`1`, `2`, …) — they're scoped to one board.
- **`load_board.path`** stays a zip path (`"boards/play.obf"`) — links resolve by
  path, so they're unaffected by the namespace. Don't use `load_board.id`.
- **`manifest.root`** is a path, not an id.

Adding a board to a set = give its `.obf` a `"<slug>:<name>"` id and add the same
key to the manifest. The seeder's destructive sync (below) cleans up any board or
tile you remove.

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
