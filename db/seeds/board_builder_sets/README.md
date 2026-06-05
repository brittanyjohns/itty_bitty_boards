# Board Builder — robust vocabulary set seed format

This directory holds the **authored source** for the Board Builder's "robust
vocabulary set" templates (Core 60, Core 84). Each set is a small linked board
tree authored as **OpenBoard (OBF/OBZ)** JSON, seeded into the database as
admin-owned, predefined boards by `bin/rails vocab_sets:seed`, then **cloned
per user** by the wizard.

> **Share this file with the vocabulary session.** It defines the exact format,
> the slugs, and the conventions the word content must follow. The finalized
> word lists live in the workspace `drafts/` folder; drop them in here by
> overwriting the placeholder `.obf` JSON.

## Slugs (stable identifiers)

| slug      | name    | status                          |
|-----------|---------|---------------------------------|
| `core-60` | Core 60 | **placeholder** (this dir)      |
| `core-84` | Core 84 | not yet authored                |

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
      core-60.obf                <- root core board
      food.obf                   <- fringe category page
      feelings.obf
      play.obf
  core-84/                       <- same shape, when authored
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
  "id": "food",                  // unique within the set; matches manifest paths key
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
  "root": "boards/core-60.obf",   // the core board the user lands on
  "paths": {
    "boards": {
      "core-60": "boards/core-60.obf",
      "food":    "boards/food.obf"
      // one entry per board id -> path
    }
  }
}
```

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
