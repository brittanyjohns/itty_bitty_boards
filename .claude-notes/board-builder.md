# Board Builder wizard endpoint

The Board Builder turns a couple of wizard inputs — a chosen **starter
template** plus a few **interest words** — into a real, linked set of
`Board` records attached to a communicator (`child_account`). It exists so
a parent/SLP can stand up a usable board set in one round-trip instead of
hand-building boards tile by tile.

This is a **standalone** feature — it is *not* part of the MySpeak setup
wizard (`.claude-notes/myspeak-onboarding.md`). The frontend page ships
separately in `itty-bitty-frontend` (branch `feat/board-builder-ui`).

## The pipeline (three seams)

```
{ template, interests }
        │
        ▼
Boards::BlueprintAssembler   # label -> image_id resolution + interest routing
        │   (builder-ready blueprint: every tile has a resolved image_id)
        ▼
Boards::BoardTreeBuilder     # persists the linked Board tree (see #259)
        │
        ▼
root Board  ──ChildBoard──▶  communicator
```

The split is deliberate: `BoardTreeBuilder`'s input contract is
"already-resolved `image_id`s only" (#259), so **all** label→`Image`
resolution, interest routing, and the create-if-missing path for brand-new
interest words live in `BlueprintAssembler`. The builder stays dumb and
deterministic.

- `app/services/boards/board_tree_builder.rb` — persists the tree (a tile is
  a `BoardImage`; a tile becomes a folder when its `predictive_board_id`
  points at a child board). Single transaction; `MAX_DEPTH = 2`.
- `app/services/boards/blueprint_assembler.rb` — the resolution + routing seam.
- `app/services/boards/starter_blueprints.rb` — the `TEMPLATES` registry.
- `app/services/boards/interest_categories.rb` — the interest→category lexicon.
- `app/controllers/api/v1/board_builder_controller.rb` — the HTTP surface.

## Starter templates

`Boards::StarterBlueprints::TEMPLATES` maps a stable string key the wizard
sends (`"home"`, `"daily_routine"`) to a label-only tree. Add a tree to that
hash and it is instantly selectable in the picker (`#catalog`) and buildable
(`#for`) — no other wiring.

Templates are defined by **label** (DB-portable). `StarterBlueprints.for(key,
user)` resolves each label to an `Image#id` for that user at call time,
**creating a blank-art image if a core label has none** (same create-if-missing
path the interest words use) so a template builds even when its curated symbols
aren't seeded in this environment — including the capitalized folder labels
(`Food`, `Feelings`, `Play`, `Bathroom`), which are folder names rather than
seeded vocabulary. `#catalog` is label-only (no `Image` resolution), so the
picker grid is cheap and safe to serve even before symbols exist.

`HOME` carries category folders `Food`, `Feelings`, `Play`; `DAILY_ROUTINE`
carries `Bathroom`. Those folder labels are what interest routing targets.

## Interest routing (apple → Food, trains → Play)

Each normalized interest is routed by `Boards::InterestCategories.category_for`
into a matching **category folder the chosen template actually has**:

- The lexicon (`InterestCategories::KEYWORDS`) is keyed by folder label —
  `"Food" => [apple, juice, snack…]`, `"Play" => [trains, dinosaurs, ball…]`,
  etc. It's small and hand-curated for v1; extend the word lists as real
  usage shows what kids ask for.
- Routing is **dynamic by template**: an interest only lands in a folder if
  its category label matches a folder present in the resolved blueprint. A
  word mapped to `Bathroom` still falls through on `HOME` (no Bathroom there).
- A routed interest **adds** a tile to that folder's child board, deduped
  case-insensitively against the folder's seed tiles and earlier interests.
  The curated core is never rewritten — interests only ever append.
- Anything with no matching folder (a name like `grandma`, a brand-new word)
  falls through to a single appended **"My Favorites"** folder, so nothing
  the user typed is dropped. If every interest routes, no Favorites folder is
  created. If none do, Favorites holds them all (the pre-routing v1 behavior).

Interests are normalized first: trimmed, blanks dropped, deduped, lone `i` →
`I`, capped at `MAX_INTERESTS` (12). An interest word with no existing `Image`
gets a freshly-created one (`is_private: false`, **blank art** for v1 — art
can be generated later).

### Image resolution (`Boards::ImageResolver`) — prefer art

All three build paths (cloner, assembler, `BuildBoardSetJob`) resolve a tile
label to an `Image` through `Boards::ImageResolver.resolve(label, owner:)`,
which **prefers the curated "default" image — the one with the most artwork**:

1. the owner's own image for the label with the most `Doc`s,
2. the curated public/admin "default" image for the label — the admin
   (`DEFAULT_ADMIN_ID`) / unowned image with the **most `Doc`s attached**,
3. else any existing image for the label, else a freshly-created blank.

Three subtleties it fixes:

- **Most-docs default.** Several `Image` rows can share a label. The naive
  `find_by(label:)` (and the earlier `with_docs…first`) returned the lowest-id
  match — often a thin or blank image. We instead order art-bearing candidates
  by `COUNT(docs) DESC, id ASC`, so the canonical symbol the library has built
  the most artwork for (the admin's de-facto default) wins. `best_arted` /
  `best_arted_for` are the read-only query helpers behind this.
- **Art over blank.** `Image#display_doc` has no label fallback, so once a tile
  points at a blank image it stays blank. Resolution only ever returns an
  art-bearing image when one exists (folders like Animals/People/Feelings).
- **Case-insensitive matching.** Folder labels are capitalized ("Animals")
  while curated library art is often lowercase ("animals"); a case-sensitive
  match would miss it. Matching is case-insensitive, but a newly-created image
  keeps the normalized label's casing.

Because `BoardImage#set_defaults` derives the tile `label` from its image,
pointing a folder at a lowercase art image would rename the tile. So the
curated folder name is pinned explicitly: `SeededSetCloner#copy_tiles!` restores
the authored label/display_label post-save, and `BuildBoardSetJob#add_folder_tile!`
sets the tile text to the category name.

**Word tiles are NOT pinned — they inherit the seed's casing and are re-folded.**
A built set is a clone of an admin-owned seed board, so whatever casing that seed
stores is what the build would render. Both clone paths (`SeededSetCloner#copy_tiles!`
and `Board#clone_with_images`) therefore run the copied text back through
`BoardImage#cloned_display_label_from`, which folds everything except doors. The
practical consequence: a seed board with stale Title Case no longer poisons the
builds, but fixing the seed itself (`bin/rails labels:fold_casing`) is still worth
doing so the source and the clones read the same.

#### Fringe boards get the upgrade too (`upgrade_board_tiles!`)

Originally only the **root** board ran the blank→art upgrade (via
`SeededSetCloner#copy_tiles!`). The seed's **fringe sub-boards** and the
standalone **prebuilt fringe pages** are cloned through
`Board#clone_with_images`, which has **no** art upgrade — so "the main board had
images but the others didn't." `Boards::ImageResolver.upgrade_board_tiles!(board,
owner:)` extracts that per-tile upgrade (blank→art only, authored label pinned)
and is now called on every cloned fringe board:

- `SeededSetCloner#clone_all` runs it on each non-root clone (the adopted root
  still upgrades via `copy_tiles!`).
- `BuildBoardSetJob#clone_one_prebuilt_page!` runs it after cloning a prebuilt
  fringe template.

It uses `best_arted_for` (read-only), so it never creates a stray blank image —
it only re-points a tile when curated art for the label actually exists.

**Backfill for already-built sets:** the forward fix only affects new builds.
`rake board_builder:upgrade_tile_images` re-runs the upgrade across every
existing built set (`builder_root`/`builder_child` boards). Dry-run by default;
`DRY_RUN=false` to apply, `USER_ID=N` to scope to one owner.

## Endpoint contract

**Auth:** `Authorization: Bearer <token>` — inherited from
`API::ApplicationController#authenticate_token!`, same as every `api/`
controller. Both routes require auth.

### `GET /api/v1/board_builder/templates`

Label-only picker catalog. No `Image` resolution.

```json
{ "templates": [
  { "key": "home", "name": "Home", "tiles": ["I", "want", "more", "help", "yes", "no", "Food", "Feelings", "Play"] },
  { "key": "daily_routine", "name": "My Day", "tiles": ["morning", "school", "play", "bed", "Bathroom"] }
] }
```

### `POST /api/v1/board_builder`

```json
{ "communicator_id": 42, "template": "home", "interests": ["dinosaurs", "grandma"] }
```

- `communicator_id` must be one of `current_user.communicator_accounts`
  (`owner_id`), else **404 `communicator_not_found`**.
- On success: builds the tree, attaches a **favorited** root `ChildBoard`,
  persists the normalized interests to `child_account.details["interests"]`
  (jsonb merge, non-destructive — so the wizard can be re-run / pre-filled),
  and returns the root board's `api_view` with **HTTP 201**.
- **409 `board_builder_set_exists`** — re-run guard (issue #269). When the
  communicator already has a builder set, `create` returns
  `{ error, message, existing_root_id, existing_root_name, built_at }` and
  builds nothing, so the wizard never silently stacks a second favorited root.
  The client confirms and re-sends with **`confirm=true`** to build another set.
  Detection is `ChildAccount#board_builder_root`: each root is marked
  `settings["builder_root"] = true` by `BoardTreeBuilder`, and the helper finds
  one still attached to the communicator (deletion-safe — delete the set and a
  re-run is a fresh build). `builder_root` is the counterpart to `builder_child`
  and does **not** affect the board-limit count (only `builder_child` is
  excluded from `countable_board_count`). The gate runs after the board-limit
  check, so Free users at their limit still get the 422 below first.
- **422 `unknown_template`** — template key not in the registry (builds nothing).
- **422 `build_failed`** — `BoardTreeBuilder::BuildError` mid-build; the whole
  build rolls back in its transaction, so no orphan boards.
- **422 "Maximum number of boards reached"** — `current_user.at_board_limit?`
  when `create` is called. Gated like every other creation path, **but a built
  tree counts as ONE board**: `BoardTreeBuilder` marks sub-boards (depth > 0)
  `settings["builder_child"] = true`, and `User#countable_board_count`
  (the single source of truth for board counting) excludes them. So a Free user
  (limit 1) can build one tree, and the tree's own sub-boards never trip the
  read-only lock; a second build is blocked.

**Counting now lives in a builder `BoardGroup` (#407).** New builds write a real
`BoardGroup(builder: true, root_board_id: root)` whose members are the root +
every predictive child (`board_group_boards`). The set then counts as **one
Board Set** (`User#countable_board_group_count` / `board_group_limit`) and
**zero board slots** (`User#countable_board_count` excludes
`builder_grouped_board_ids`), and deleting the group cascade-deletes the whole
tree. "Set-ness" lives in the BoardGroup, not the fragile `builder_child`
JSONB marker. The `builder_root` marker on the root board is still the detection
key for re-runs and the backfill.

**A set stays whole after the build, too (#586).** At build time the group
membership and the reachable folder-tile graph are the same set, but they
diverge the moment a user hand-extends the set. `Api::ImagesController
#create_predictive_board` ("turn this tile into a folder") therefore adds the
page it creates to the parent board's builder group via
`Board#containing_builder_board_group` — which answers for any *member* of the
set, not just the root, since folder tiles are usually added on a child page.
`BuildBoardSetJob#set_board_ids` walks the link graph with no depth cap for the
same reason (it's owner-scoped and cycle-safe, so it still terminates). Escaped
pages don't publish, don't cascade-delete, and burn a board slot.

**Backfill for pre-#407 sets (#409):** existing builder sets predate the
BoardGroup, so `rake board_groups:backfill_builder_sets`
(`lib/tasks/board_groups.rake`) wraps each `builder_root` tree lacking a builder
BoardGroup into one — root + predictive descendants (BFS to `MAX_DEPTH` 2,
owner-scoped), mirroring the controller/job construction. Idempotent (a root
already wrapped by `root_board_id` is skipped, so re-runs add no duplicate
groups/join rows). **Applies by default; preview with `DRY_RUN=1`**, scope with
`USER_ID=N`. Logs each user's board-set count before/after and prints a report
of any user left over `board_group_limit` (e.g. a Free user with a hand-made set
+ a builder set reads 2/1) — those are left as-is per #409 since limits are
enforced only on create, so existing sets stay accessible. Deploy order:
deploy #407 → run `DRY_RUN=1` → review the over-limit report → run for real.

## Decisions & future work

- **Interests persisted** to `child_account.details` (not a new column) so the
  wizard is idempotent/re-runnable.
- **Re-running the wizard (open decision #3) — RESOLVED: detect + warn.** A
  re-run is non-destructive and never silently dupes: the backend returns
  **409 `board_builder_set_exists`** unless `confirm=true` is sent. We keep
  the prior set intact rather than replacing it (option 1 in issue #269), and
  the marker is `settings["builder_root"]` on the root board (not a `details`
  marker, which would go stale if the board were deleted). Frontend confirm UX
  is a small follow-up (frontend repo).
- **Blank-art interest images** are acceptable for v1.
- **Future:** per-tile voice/label overrides (today `add_image` derives the
  label from the `Image`); clinically-validated level recommendations (see
  below).

## Robust seeded sets (Core 60 / Core 84)

A second template kind: pre-authored, evidence-based **core vocabulary sets**
(a real core grid + fringe category pages), offered alongside the hardcoded
starter trees. Instead of building from label-only trees, a robust set is
**authored as OBF/OBZ**, **seeded** once as admin-owned predefined boards, then
**deep-cloned per user** on build — preserving the authored grid layout,
core-tile borders, and `part_of_speech` colors that a rebuild-from-labels would
lose.

**Authoring + seeding (reuses `ObzImporter`):**
- Source lives in `db/seeds/board_builder_sets/<slug>/` as editable OBF JSON
  (`manifest.json` + `boards/*.obf`). Format spec: that dir's `README.md`
  (share it with whoever authors the word content). Slugs: `core-60`, `core-84`.
- `bin/rails vocab_sets:seed` (logic in the `VocabSets` service) zips the JSON
  in memory and imports via `ObzImporter` as `User::DEFAULT_ADMIN_ID` with
  **`board_group: nil`** — this feature is **root-board only, no `BoardGroup`**.
  `ObzImporter` lays out the grid, colors tiles by `part_of_speech`, and wires
  `load_board` → `predictive_board_id`.
- The set is identified ENTIRELY by a marker on its **root board**:
  `settings["board_builder_robust"] = true` + `["board_builder_robust_slug"]`.
  `Boards::RobustSets` (`find_root` / `all_roots` / `slug_for` / `mark_root!`)
  is the single place that query lives. Idempotent: `Board.from_obf` upserts by
  `(user_id, obf_id)`.
- **Layout self-heal on re-seed (`VocabSets#repair_layout!`).** A clean
  first-time import is always correct (84/60 tiles, no overlaps). But the
  historical duplicate-tile bug could leave the surviving tile on the wrong cell
  — two tiles stacked on one cell (e.g. `wait` on `again` at `[10,5]`) while
  another sat empty, so the home board rendered with a tile hidden ("84 looks
  like 82"). `repair_layout!` runs LAST in `seed_slug!` and re-pins every tile to
  its authored `[x,y]` from the source OBF grid (matched by `obf_button_id`), so
  a single `bin/rails vocab_sets:seed` converges a corrupted source to clean.
  Existing **user clones** of a corrupted source are healed by
  `rake board_builder:repair_grid` — `Boards::LayoutRepacker` now un-stacks
  in-grid **overlapping** tiles in addition to off-grid ones.

**Per-user build (reuses `clone_with_images`):**
- `Boards::StarterBlueprints.catalog` merges the static trees (`kind:
  "starter"`) with seeded robust sets (`kind: "robust"`, found by root marker).
- `API::V1::BoardBuilderController#create` branches: if `template` resolves to a
  robust set via `RobustSets.find_root`, it runs **`Boards::SeededSetCloner`**
  instead of `BlueprintAssembler` + `BoardTreeBuilder`. Same guards, same
  response (synchronous **201** with the cloned root) — and the same
  `at_board_limit?` (422) and `board_builder_root` (409, unless `confirm=true`)
  gates, which work unchanged because the clone is marked `builder_root`.
- `SeededSetCloner` walks the source set (root + fringe via
  `predictive_board_id`, BFS bounded to `MAX_DEPTH = 2`, cycle-safe), clones
  each board with `clone_with_images` (no `communicator_account` arg → no fringe
  ChildBoards), **rewires** each cloned folder tile's `predictive_board_id` from
  the source sub-board to its clone (out-of-set pointers nulled), marks the root
  `builder_root` + the rest `builder_child` (so the whole set counts as **ONE**
  board), favorites the root as a ChildBoard, and routes interests into the
  cloned fringe pages by category name — unmatched → an auto-created, linked
  `builder_child` "My Favorites" page. Interest normalization/dedup/cap mirror
  `BlueprintAssembler`. A novel interest word with no existing public/admin
  symbol is created and **queued for AI art** (`GenerateImagesJob`), mirroring
  `Board#find_or_create_images_from_word_list` — words that resolve to existing
  art are skipped, so we never pay to regenerate. clone_with_images returns
  clones with a stale counter/association cache, so routing reloads boards
  before adding tiles.

**Synchronous (v1) — execution note.** The build runs in-request (the existing
contract). image_ids are pre-resolved so the work is DB-bound; previews, audio,
and AI art for brand-new interest words are already async jobs. A spike on a
worst-case ~600-tile set measured ~3s (test env); realistic Core 60/84 sets
(~120–200 tiles) are ~1s. **If a real set lands materially larger (>~300
tiles)** and request latency bites, move `SeededSetCloner` into a background job
with a `status: "building"` root + 202/polling — coordinated with the frontend.

## Phase 2: complexity levels + hybrid build

Phase 2 replaces raw template keys with **complexity levels** that control how
many fringe pages a built set includes and where the content comes from. The
`level` param is the intended wizard path; the legacy `template` param still
works unchanged.

### Complexity levels

| Level    | Core template | Fringe pages | Default categories                        |
|----------|---------------|--------------|-------------------------------------------|
| Starter  | core-60       | 4-6          | Food, Feelings                            |
| Standard | core-60       | 8-10         | Food, Feelings, Play, People              |
| Extended | core-84       | 10-15        | Food, Feelings, Play, People, Places, Body, Social |

### The planning service (`Boards::StructurePlanner`)

Takes `level`, `profile`, `interests`, `explicit_categories`, `user` and returns
a `Result` struct:

```
Result { level, core_template, fringe_pages, excluded_fringe_pages,
         catch_all_interests, ai_credits_needed }
```

Each fringe page entry has `{ name, source, interests }` where `source` is one
of:

- **`:seed_set`** — the category page already ships with the core template clone
  (Food, Feelings, People, etc.). The clone includes it natively.
- **`:prebuilt`** — a standalone OBF fringe template exists (Animals, Music,
  etc.). Cloned per user via `Board#clone_with_images`.
- **`:ai_generated`** — no pre-built content. `Boards::AiPageGenerator` creates
  a page of ~10 tiles via OpenAI, credit-gated at 2 credits per page.

**Seed set name mismatches:** InterestCategories uses "Family & People" and
"Health & Body", but seed sets use "People" and "Body". `CATEGORY_SEED_ALIASES`
resolves this without renaming either side.

**Credit downgrade:** when the user can't afford all AI-generated pages, the
planner moves their interests to `catch_all_interests` (→ "My Favorites")
instead of failing the build.

### Fringe page templates (`Boards::FringeTemplates`)

Standalone OBF boards seeded from `db/seeds/board_builder_sets/fringe-pages/`.
11 categories covering topics not in the core seed sets. Each board is:
- Owned by `DEFAULT_ADMIN_ID`, predefined, published
- Marked with `settings["fringe_template_category"]` (lowercase category name)
- Seeded via `bin/rails fringe_templates:seed` (also auto-runs after
  `vocab_sets:seed`)

To add a new fringe template: create a `.obf` file in the seed directory
following the existing format (see any `.obf` file), then run the seed task.

### AI page generation (`Boards::AiPageGenerator`)

Generates a `{ name, tiles }` blueprint from interests via OpenAI chat
completion. Profile-aware: when a `CommunicatorProfile` is provided, the prompt
includes AAC-level and age-appropriate vocabulary guidance. Validations:
- At least 1 interest required
- Response must be parseable JSON with a `name` and `tiles` array
- At least `MIN_TILES` (6) tiles required
- Tiles capped at the requested count (default `TARGET_TILES` = 10)
- Blank labels filtered

Cost: 2 credits per page (`ai_board_page` feature key in `CreditService`).

### Hybrid build path (`BuildBoardSetJob`)

When the build key is a StructurePlanner level (starter/standard/extended), the
job runs the hybrid path:

1. **Plan** via `StructurePlanner` → fringe page list (+ catch-all)
2. **Clone seed set INTACT** via `SeededSetCloner` with `exclude_fringe: []`.
   The authored core set is cloned whole — every authored folder tile
   (People…Describe, including **More**) stays linked to a real board, and
   seed-category interests route into the matching cloned folders.
3. **Add prebuilt / AI fringe pages within the grid** — `add_fringe_pages_within_grid!`.
   Each `:prebuilt`/`:ai_generated` page becomes a *new* top-level folder tile,
   but only while open cells remain on the authored grid (see the grid-cap note
   below). `:prebuilt` clones the admin template + routes interests; `:ai_generated`
   checks credits → generates → builds → links (falls back when out of credits).
4. **Catch-all** — interests with no fitted page (initial unmatched + any pages
   that didn't fit the grid + AI pages that fell back) → a single "My Favorites".

#### Overflow goes into the "More" drawer, never onto a stray row

**The authored core grids are completely full**: Core 60 is 60 tiles in a 6×10
grid, Core 84 is 84 tiles in a 7×12 grid. Zero reserved cells, in both.
`Board#add_image` drops a tile into the first open cell and only starts a **new
row** once the grid is full (`BoardsHelper#next_available_cell`), so every page
a build adds past the seed set used to land on a row of its own — and
`Boards::NavRegion` then rotates the authored nav row back underneath it. The
visible result on a Core 60 build was a home board reading "61 tiles" with one
lone `Bathroom` folder stranded between the core words and the nav row, plus the
loss of the seed's one-page `disable_scroll`.

**`Boards::FolderPlacer` is the single authority on where a top-level folder
tile goes.** In order:

1. a genuine open cell on the home grid — `Board#open_grid_cells`;
2. else the set's **"More" drawer** — the board the root's `More` folder tile
   opens, owner-scoped (`FolderPlacer.drawer_for`). More is on the nav row of
   every page in the set, so the page stays two taps from anywhere, and it ships
   mostly empty (Core 60's More: 31 tiles in 60 cells);
3. else grow the home grid, as before. Only the legacy label-only starter trees
   (`home`, `daily_routine`) have no `More`, so in practice this is the
   drawer-is-full case.

Every top-level tile-adder routes through it: `BuildBoardSetJob#add_folder_tile!`
(so prebuilt fringe, AI pages, and `#add_to_favorites!` all inherit it) and
`SeededSetCloner#create_favorites_board!`. The Phrases layer is the exception in
practice, not by special-casing — `build_phrases_layer!` still bails when the
home grid has no open cell, so it never reaches step 2. Two placement rules
inside the drawer are load-bearing:

- **Tiles pack into a band, not into authored gaps.** Placement takes the first
  row above the drawer's nav row that already holds nothing but folder tiles
  (the band a previous page started), else the first fully-empty row. Core 60's
  More has two open cells mid-way through its top word row, between `for` and
  `here`; `next_available_cell` would drop `Bathroom` there.
- **The drawer's nav row is its BOTTOM row** — deliberately not
  `NavRegion.authored_nav_y`, which picks whichever row holds the most folder
  tiles. A band that grew to the nav row's size would win that tie (lower `y`)
  and the next placement would start overwriting nav cells.

`FolderPlacer` also refuses the drawer for a page whose name matches a nav-region
label: `NavRowSync#evict_occupants!` destroys any folder tile on a child page
carrying a nav category's label, so such a page would be silently orphaned
inside the drawer. It stays on the home board instead.

Because a page can now live one level down, `BuildBoardSetJob
#set_top_level_boards_by_name` reads the root's folder targets **plus the
drawer's** — otherwise a leftover interest word wouldn't find its category page —
and `#add_to_favorites!` looks for an existing "My Favorites" through the same
map, so the cloner's drawer-tucked Favorites isn't duplicated. `set_board_ids`
already walks the link graph unbounded, so BoardGroup membership, group
attachment, reflow, and cascade-delete need no change.

**Every page in a built set keeps a one-tap way home** — that invariant predates
the drawer and had to be carried into it. A page whose name sits in the nav
region gets home from its SELF tile (`NavRowSync#upsert_nav_tile!`); a
drawer-tucked page has no nav cell of its own, so `NavRowSync#ensure_home_tile!`
gives it the same anchor explicitly — a tile carrying the page's name that opens
the root, unmuted so it speaks like a self tile. It has to run *after*
`evict_occupants!`, which destroys any child folder tile pointing back at the
root, so an anchor written earlier in the build would not survive.

**The way home goes WHERE THE WAY IN WAS.** A subboard's back tile occupies the
same `lg` cell as the folder tile that opens it — muscle memory only works if
the way back is where the way in was, and re-scanning the grid on every page is
exactly what an AAC layout exists to prevent. A nav-region page gets this for
free (`upsert_nav_tile!` writes the self tile at the root's own cell); a
drawer-tucked page gets it from `NavRowSync#place_home_tile!`, which mirrors the
cell of the tile that links to it — usually on the **drawer**, not the root.
Two rails there: the move is a **swap**, so the occupant takes the cell the
anchor would otherwise have been given and no hole opens; and a mirrored `y`
inside the nav region is **refused, never clamped into it** (a drawer's content
area can be taller than the page it opens, and clamping would put the anchor in
a cell `upsert_nav_tile!` owns). The link target stays the root either way — the
anchor mirrors the drawer tile's *position*, not its destination.

`allow_scroll_if_grown!` remains the safety net for case 3: a home board that
did grow clears the seed's one-page `disable_scroll` so the new row isn't
clipped.

> Default (no-interest) fringe pages still fill only genuine open cells — they
> are never tucked into the drawer just to surface content the child didn't ask
> for, so a no-interest build stays one clean page.

> `SeededSetCloner#fringe_for_category` applies `CATEGORY_SEED_ALIASES`
> ("Family & People" → People, "Health & Body" → Body) so those seed-set
> interests reach the cloned page instead of spawning an extra "My Favorites"
> folder — one of the original overflow triggers.

> The old hybrid path *excluded* "unplanned" seed pages via
> `StructurePlanner#excluded_fringe_pages` + `SeededSetCloner(exclude_fringe:)`.
> That stripped authored sub-boards while leaving their root folder tiles
> behind — dead tiles (More/School/Time/Describe) that opened nothing. The job
> no longer excludes; `excluded_fringe_pages` is still computed on the plan but
> unused by the build.

Legacy template keys (`core-60`, `home`, etc.) route to the original
clone-only or blueprint-only paths, unchanged.

### Level recommendation heuristic

The controller's `recommend_level` maps communicator profile to a level:

| Condition                                  | Level    |
|--------------------------------------------|----------|
| `profile.young?` (age ≤ 10) OR `emerging?` | Starter  |
| `profile.developing?` OR `young_teen?` (11-14) | Standard |
| Everything else (proficient, older, etc.)  | Extended |

**These are reasonable heuristics, not clinically validated.** They're based on
general AAC principles (younger/emerging communicators benefit from fewer,
focused categories; proficient/older communicators can handle broader vocabulary)
but have no specific clinical research or product usage data backing the exact
thresholds. Revisit when real usage data or SLP feedback is available.

### New CreditService additions

- `CreditService::FEATURE_COSTS["ai_board_page"] = 2`
- `CreditService.can_spend?(user, feature_key:, amount:)` — balance check
  without locking or spending. Used by the planner's credit downgrade logic.

### Endpoint changes

- `GET /api/v1/board_builder/templates` — now returns `levels` (array),
  `recommended_level`, and `recommendation_reason` alongside the existing
  `templates`/`recommended_template` fields.
- `POST /api/v1/board_builder` — accepts `level` (new, preferred) OR `template`
  (legacy). `level` takes precedence when both are sent.

## Tests

- `spec/services/boards/blueprint_assembler_spec.rb` — routing, catch-all,
  dedup, normalization, image create/reuse, unknown template.
- `spec/services/boards/interest_categories_spec.rb` — lexicon contract.
- `spec/services/boards/board_tree_builder_spec.rb` — the persistence half (#259).
- `spec/services/boards/seeded_set_cloner_spec.rb` — deep clone: rewire,
  builder markers, favorite ChildBoard, cycle-safety, interest routing +
  My Favorites, counts-as-one, source untouched, `exclude_fringe:`.
- `spec/services/boards/structure_planner_spec.rb` — level normalization,
  core_template mapping, fringe page planning (seed_set/prebuilt/ai_generated),
  capping, excluded pages, catch-all, credit downgrade, explicit categories.
- `spec/services/boards/fringe_templates_spec.rb` — find, all_templates,
  seed_obf!.
- `spec/services/boards/folder_placer_spec.rb` — placement order (open cell →
  drawer → grow), band packing, the authored-gap and nav-label refusals,
  drawer-full fallback, `drawer_for` ownership scoping.
- `spec/services/boards/ai_page_generator_spec.rb` — happy path, error cases,
  tile capping, profile guidance, blank label filtering.
- `spec/services/communicator_profile_spec.rb` — developing?, young_teen?.
- `spec/services/credit_service_spec.rb` — can_spend?, ai_board_page feature
  key.
- `spec/services/vocab_sets_spec.rb` — seeder: OBZ import, root marker,
  predefined/published, no BoardGroup, idempotent.
- `spec/sidekiq/build_board_set_job_spec.rb` — starter template, robust set,
  hybrid path (standard level, starter exclusions, no-credits fallback, legacy
  passthrough), failure, retry idempotency.
- `spec/requests/api/v1/board_builder_spec.rb` — endpoint happy path
  (routing + favorites), auth, ownership, unknown template, build failure,
  the board-limit gate (tree counts as one; set stays editable), the robust
  clone path, and the complexity level path (levels in response,
  recommended_level, level param in create).

Run: `RAILS_ENV=test bundle exec rspec spec/services/boards spec/services/vocab_sets_spec.rb spec/services/communicator_profile_spec.rb spec/services/credit_service_spec.rb spec/sidekiq/build_board_set_job_spec.rb spec/requests/api/v1/board_builder_spec.rb`

---

# Consolidated current-state summary (moved from CLAUDE.md, 2026-07-11)

> This section was CLAUDE.md's Board Builder documentation, moved here in the
> hub-and-spoke restructure. It is the NEWEST description of the system — where
> it conflicts with the older sections above, this section wins.

## Board Builder wizard

Turns wizard input — a starter **template** + a few **interest words** — into
a real linked `Board` set attached to a communicator. **Standalone** feature,
*not* part of MySpeak onboarding. Full subsystem doc:
`.claude-notes/board-builder.md`.

Three seams (input contract tightens left→right):

- `Boards::StarterBlueprints` — `TEMPLATES` registry of label-only starter
  trees (`"home"`, `"daily_routine"`). Add a tree to the hash → instantly in
  the picker (`#catalog`) and buildable (`#for`). Core labels resolve
  **create-if-missing** (blank art, same path as interest words), so a template
  builds even when its curated symbols — including the capitalized folder labels
  (`Food`, `Feelings`, `Play`, `Bathroom`) — aren't seeded in this environment.
- `Boards::BlueprintAssembler` — the resolution + routing seam. Resolves every
  label to an `image_id` (create-if-missing for new interest words, blank art
  for v1), then **routes interests into category folders** via
  `Boards::InterestCategories` (apple→Food, trains→Play). Routing is dynamic
  by template (only into a folder the chosen template has); anything unmatched
  falls through to one appended **"My Favorites"** folder, deduped, nothing
  dropped. Interests are normalized + capped at 20. When the frontend sends
  `[{ word, category }]` entries, the explicit category overrides the dictionary
  lookup — so the categorized picker's selections route deterministically.
- `Boards::BoardTreeBuilder` (#259) — persists the tree from a blueprint of
  **already-resolved `image_id`s only**. Keep it dumb; all resolution lives in
  the assembler.

### Complexity levels (Phase 2)

Phase 2 replaces raw template keys with **complexity levels** — Starter,
Standard, Extended — that control how many fringe pages a built set includes and
where they come from. The `level` param is the intended path forward; `template`
still works for backward compat.

- **`Boards::StructurePlanner`** — the planning service. Takes a level + profile
  + interests → decides which fringe pages to include, resolving each to one of
  three source types:
  - `:seed_set` — already in the core template clone (Food, Feelings, etc.)
  - `:prebuilt` — standalone OBF fringe template, cloned per user
  - `:ai_generated` — built on the fly via `Boards::AiPageGenerator` (OpenAI)
  Constants: `LEVELS` (starter→core-60/4-6 pages, standard→core-60/8-10,
  extended→core-84/10-15), `SEED_SET_PAGES`, `CATEGORY_SEED_ALIASES` (maps
  InterestCategories names like "Family & People" to seed set page names like
  "People").
  - **No-interest defaults must be a subset of the level's seed pages.**
    `STARTER_/STANDARD_/EXTENDED_DEFAULTS` are the categories seeded when the
    child gives no interests. They **must** all be `SEED_SET_PAGES` of that
    level's core template — a default that isn't a seed page resolves to
    `:prebuilt`/`:ai_generated` and `add_fringe_pages!` adds it as an **extra
    top-level folder**, which on the full authored Core 84 grid (84 tiles, no
    open cells) spills onto a stray extra row. That was the "Core 84 builds an
    unrequested `Social` folder + orphans a tile onto row 8" bug: `Social` sat
    in `EXTENDED_DEFAULTS` but isn't a core-84 seed page, so a no-interest
    Extended build injected it whenever the seed root reported a phantom open
    cell (a latent tile overlap inflating `open_grid_cells`). Core 60 was
    unaffected because its defaults are all seed pages. Invariant enforced by a
    `structure_planner_spec` test; if you add a level or default, keep defaults
    ⊆ seed pages.
- **`Boards::FringeTemplates`** — module for standalone fringe page templates.
  Seeded from `db/seeds/board_builder_sets/fringe-pages/*.obf` via
  `bin/rails fringe_templates:seed` (also auto-runs after `vocab_sets:seed`).
  11 categories: Animals, Art & Craft, Bathroom, Clothing, Home, Music,
  Nature & Outdoors, Social, Sports, Technology, Transportation. Boards are
  marked with `settings["fringe_template_category"]` and owned by
  `DEFAULT_ADMIN_ID`.
- **`Boards::AiPageGenerator`** — OpenAI-powered page generation for niche
  interests with no pre-built source. Returns a `{ name, tiles }` blueprint.
  Profile-aware prompts. Credit-gated: costs 2 credits (`ai_board_page` feature
  key). Falls back to "My Favorites" catch-all when user lacks credits or
  generation fails.
- **AI pages need ≥ `MIN_AI_PAGE_INTERESTS` interests
  (`BOARD_BUILDER_MIN_AI_PAGE_INTERESTS`, default 2).** `StructurePlanner#drop_sparse_ai_pages`
  removes any `:ai_generated` page whose category has fewer interests, so a lone
  interest (e.g. "backpack" → School, which is neither a seed nor prebuilt page in
  core-60) doesn't spawn — and pay for — a whole AI board named after that one
  word. Its words fall to `catch_all_interests` instead. **Seed/prebuilt pages are
  not gated** (they're curated/default content; gating them would drop a
  zero-interest default like the prebuilt "Social" in Extended).
- **`BuildBoardSetJob`** routes between the hybrid path (when `level` is a
  `StructurePlanner::LEVELS` key) and the legacy path (direct template keys like
  `core-60`, `home`). The hybrid path: plan → clone seed set **intact** →
  add prebuilt/AI fringe pages **within the authored grid** →
  `route_catch_all_to_existing_boards!` (place each leftover interest on an
  **existing matching board** in the set — e.g. a capped seed page, since the seed
  set always clones intact — matched by category with the seed aliases) → route the
  rest to **"My Favorites"**.
- **Grid growth (interests grow; defaults don't) + no dead tiles.** The authored
  core boards are now **full** (Core 60 = 6×10 = 60 tiles; Core 84 = 7×12 = 84
  tiles — no reserved gaps). `Board#add_image` fills the next open cell and only
  starts a new row once the grid is full. `BuildBoardSetJob#add_fringe_pages!`
  uses that deliberately: **interest-driven content is allowed to GROW the grid
  onto new rows** so a child never loses a page — or a word — they asked for.
  - **What grows vs. what doesn't.** Interest-bearing fringe pages and a
    non-empty "My Favorites" catch-all grow the grid (added as real, working
    folder tiles). **Default (no-interest) fringe pages, the Phrases folder, and
    the early-stage quick-phrase strip do NOT grow the grid** — they fill only
    genuine open cells (`root_open_cells` / `Board#open_grid_cells`), so a
    no-interest build stays one clean page (Core 84 = 84 tiles). Trade-off: on a
    full authored grid those default/gestalt extras are simply omitted (no room
    without growth, and we don't grow for empty default content).
  - **Grown sets may scroll.** A cloned root inherits the seed's one-page
    `disable_scroll`. When the build grows past the authored rows,
    `allow_scroll_if_grown!(root, authored_rows)` clears `disable_scroll` so the
    new rows aren't clipped by the native one-page layout.
  - **No dead tiles, controlled growth.** Every added tile links a real board;
    growth is bounded by the number of interest categories (a couple of extra
    rows at most), never a runaway stack. The job clones the seed set **intact**
    (`exclude_fringe: []`) so every authored folder — People…Describe, **including
    More** — stays linked to a real board.
  - **History:** the authored grids previously shipped with 3 empty cells
    reserved for the builder, and `add_fringe_pages_within_grid!` capped tile
    placement to those cells (the "85th/86th tile" hard cap). #416/#424 filled
    the grids to a true 60/84 (the cells read as "missing tiles" to users), so
    the reserved-cell reservation was replaced with this controlled-growth model.
  - **Alias-aware interest routing in the cloner.** `SeededSetCloner` matches an
    interest's category to a cloned fringe board via `fringe_for_category`,
    applying `StructurePlanner::CATEGORY_SEED_ALIASES` ("Family & People" →
    People, "Health & Body" → Body). Without it those (planner-classified
    seed-set) interests missed the cloned People/Body page and fell through to a
    spurious extra "My Favorites" folder tile — one of the overflow triggers.
- **`SeededSetCloner`** accepts `exclude_fringe:` — a list of page names to skip
  during the clone. Still used by callers that want a trimmed clone; the hybrid
  build now passes `[]` (clone intact). `StructurePlanner#excluded_fringe_pages`
  is still computed on the plan but no longer consumed by the build.
- **Folder/dynamic tiles default to muted names.**
  `BuildBoardSetJob#mute_dynamic_tile_names!` runs at the end of every build
  (the single chokepoint before `generate_preview!`) and sets
  `board_image.data["mute_name"] = true` on every dynamic tile
  (`is_dynamic?` → `predictive_board_id` present and not a self-link) across the
  whole set — root + linked sub-boards, walked via `set_board_ids` (BFS over
  predictive links, scoped to the owner's boards). So tapping a folder navigates
  without speaking the folder's own label; word tiles are untouched.
  `update_column` skips the audio hook/validations. Idempotent.
- **Scope classification.** `BuildBoardSetJob#classify_sub_boards!` runs at the
  same end-of-build chokepoint (beside `mute_dynamic_tile_names!`) and re-saves
  every `builder_child` board in the set (everything but the root, walked via
  `set_board_ids`) so `Board#check_is_sub_board` recomputes against the now-wired
  `predictive_board_id` links and sets the `sub_board` column **true**. Without
  it child pages leak into the **`main_boards`** scope (`sub_board: [false, nil]`)
  because their last save happened before the parent linked them. The **root
  keeps `sub_board: false`** so it stays a main board. Idempotent.
  - **Builder pages are NOT frozen.** They behave like any other board — a word
    tap returns to home. (Freezing is still available per-board; builder sets
    just don't opt into it. There is no separate `return_home` setting:
    `freeze_board: true` is what stops auto-return, and the
    `frozen`/`freeze_parent_board`/`board_frozen` flags the api_view exposes are
    what the frontend's return-home affordance keys off.) Sets built before this
    was true are unfrozen by `rake board_builder:reclassify_builder_sets`.
  - **The root is pinned as a main board in the model, not just by being skipped
    here.** Every child page carries an authored tile whose `predictive_board_id`
    points back at the root (the **self tile** — see the nav-row rule below), so
    once those links are wired the root *has* parent boards, and any later
    `root.save!` (e.g. `allow_scroll_if_grown!`) would flip it to
    `sub_board: true` and drop it out of the `main_boards` scope / the
    communicator dashboard. `Board#check_is_sub_board` **short-circuits to
    `sub_board: false` for any `settings["builder_root"]` board**, regardless of
    inbound links, so the back-links keep working as navigation while the root
    stays a main board. `rake board_builder:reclassify_builder_sets` re-saves
    existing roots, so the guard heals already-built sets too.
- **A fringe page fills whole rows, and `More` deliberately does not.** The
  authored root grids are 100% full, so a page carrying twenty words in a
  sixty-cell grid reads as broken next to them. Core 60 fringe pages are 40
  words (rows 0–3 of 50 content cells), Core 84's are 60 (rows 0–4 of 71), and
  the standalone `fringe-pages/*.obf` templates are 40 in a 10×4 grid. A partial
  final row is worse than a short board — rows are derived from the tiles, so
  the leftover cells sit at the right end of the last row instead of shortening
  the page. **`More` is the exception**: it is the drawer `Boards::FolderPlacer`
  tucks every build-added page into, so it keeps **two** spare rows (30 words on
  Core 60, 48 on Core 84). Filling it leaves one row for up to `max_pages` (15
  on `extended`) additions and silently pushes the overflow back onto the home
  grid, losing `disable_scroll`. Table and authoring rules:
  `db/seeds/board_builder_sets/README.md`.
- **The nav row is identical on every board in a set (motor planning).** The
  seeded set's root authors a bottom **nav row** of folder tiles; every child
  reproduces it **cell-for-cell** at the root's grid dimensions, so a category is
  the same reach from any page. The tile for the page you're on links back to the
  **root** rather than at itself — it's both the you-are-here anchor and the way
  home, which is why there's no separate `Home` tile. The rule, its two authoring
  traps (button-id stability, `TileDeduper` label collisions), and the enforcing
  spec (`spec/db/seeds/board_builder_sets_spec.rb`) are documented in
  `db/seeds/board_builder_sets/README.md`.
  - **`Boards::NavRowSync` is the enforcement mechanism; authoring is a
    convenience.** Authoring the row in the seed `.obf` files only covers the
    pages that ship *in* the seed set, and a build that adds a page (prebuilt
    fringe, AI-generated, My Favorites, Phrases) grows the **root's** grid alone
    — which is what pushed the seeded pages out of alignment. `BuildBoardSetJob`
    calls `Boards::NavRowSync` at the end-of-build chokepoint (before muting,
    reflow, and previews, so all three see the final grid) to project the root's
    **final** row onto every page, walking `PredictiveLinkSet` to depth 2 so the
    GLP function boards are covered. Idempotent: tiles it owns carry
    `data["nav_tile"] = true`.
  - **`Boards::NavRegion`** derives the region: the bottom row, plus at most
    **one** row above it whose occupied cells are *all* folder tiles (the
    build's added pages). A content row holding a lone folder tile — Core 84's
    `More` — is **not** a nav row; that tile is pinned at its own cell instead.
    `NavRegion.align` first rotates the authored nav row back to the bottom,
    since `Board#add_image` appends growth *below* it.
  - **A nav region holds WORDS as well as folders.** The authored row is
    `this | People | … | More | that`: the two determiners at its ends are
    vocabulary that happens to live in the nav row, reproduced on every page for
    the same motor-planning reason the folders are. `NavRowSync` treated every
    region cell as a folder, so on each child it relocated the authored `this`
    into the content area as a colliding occupant and then created a **second**
    one at the nav cell — and the copy carried `mute_name`, which is what makes
    `BoardImage#door_tile?` true, so the tile sitting in the nav row was a silent
    door while the speaking one had wandered. Every page of every built set
    carried two `this` and two `that` (a seeded Core 60 is 221 authored words; a
    built one reported 237 = 221 + 2 × 8 pages).
    A word cell is now **adopted** — matched by label, kept as a plain word tile
    (`predictive_board_id` nil, no `mute_name`) and flagged `data["nav_word"]`
    rather than `data["nav_tile"]`, which is the same ownership and idempotency
    without the door/back semantics. `#collapse_nav_word_duplicates!` removes the
    copies an earlier sync left, keeping the authored (lowest-position) tile, so
    `rake board_builder:sync_nav_rows` heals sets already in the wild.
  - **Only a legacy nav tile is replaced.** A folder tile is destroyed only when
    it carries a nav category's label (the pre-sync copy, often shifted a cell
    left) or links back to the root (the old `Home` way-home tile). A page's own
    folder tiles are its content — the Phrases page links the six gestalt
    function boards — so anything else merely colliding with a nav cell is
    **relocated** into the content area, never dropped.
  - **Robust sets only.** The legacy label-only starter trees (`home`,
    `daily_routine`) have no nav row concept and are skipped; the guard reads the
    job's own `level_or_template` argument.
  - The **self tile is the one folder tile that speaks** — `NavRowSync` leaves
    `mute_name` off it, and `mute_dynamic_tile_names!` independently exempts a
    dynamic tile whose label matches its own board's name.
  - **Bottom-pinned on every screen.** `Boards::ScreenReflow.reflow!` takes
    `pinned_rows:` (default `0` — the original path, byte-identical for every
    non-builder caller); the job passes the region's row count so content packs
    first and the nav strip stays at the bottom on md/sm/xs. At a narrow column
    count the strip spans more rows — still bottom-pinned, still identical on
    every page of the set.
  - **Backfill:** `rake board_builder:sync_nav_rows` re-projects the row across
    every existing `builder_root` set (dry-run by default; `DRY_RUN=false` to
    apply, `USER_ID=N` to scope).
  - Built sets are **clones taken at build time**, so reseeding an aligned
    template only affects **new** builds — the rake task is what heals sets
    already in the wild.
- **Built roots register as `in_use`.** The set's root lives **directly** on the
  communicator (the `ChildBoard` has `board_id = root.id`, `original_board_id =
  nil` — unlike the clone-source `assign_boards`/`assign_accounts` path). So
  `Board#check_in_use` was broadened to mark a board `in_use` when **either** a
  `ChildBoard` points at it via `original_board_id` (clone source) **or** via
  `board_id` (direct attach) — i.e. "the board is on a communicator." Without
  this the builder root never surfaced under the `in_use` scope even though it's
  literally assigned. The clone-source path is unaffected (clones are
  `is_template: true`, excluded from the index anyway).
  - `in_use` is refreshed by **`ChildBoard` `after_create`/`after_destroy`**
    (`recalculate_boards_in_use` → `Board#recalculate_in_use!`), not just by
    Board's own `before_save` — the builder attaches the root **after** its
    last save and detach never saves the board, so the save-time hook alone
    left builder roots stuck at `false`.
  - `Board#assigned_to_communicator?` guards against a **nil id** (unsaved
    record): without it, `where(original_board_id: nil)` matched every
    direct-attach row and flagged every brand-new board `in_use = true`.
  - Communicator lists in the API views (`communicator_accounts`,
    `communicator_account_data`, `child_boards` on the show payload;
    `in_use_by` on the index; `ChildAccount#index_api_view`'s
    `communicator_board_ids`) all read **both join paths** via
    `Board#communicator_child_boards` — never only `original_child_boards`,
    or builder boards vanish from "assigned to" UI (the Assign-to-communicator
    popup pre-check matches the viewed board id against
    `communicator_board_ids`).
- **Backfill for pre-fix sets:** `rake board_builder:reclassify_builder_sets`
  (dry-run by default; `DRY_RUN=false` to apply, `USER_ID=N` to scope) re-saves
  each existing built set so the root recomputes `in_use` and every child page
  gets `sub_board` and has `freeze_board` **cleared**. For the `in_use` flag alone (both
  directions, including boards wrongly stuck at `true` from the nil-id bug),
  `rake boards:recalculate_in_use` (dry-run by default; `DRY_RUN=false` to
  apply) recomputes the flag straight from the `child_boards` rows.
- **Tile images prefer the curated "default" image (`Boards::ImageResolver`).**
  All three build paths (cloner, `BlueprintAssembler`, `BuildBoardSetJob`)
  resolve a tile label via `Boards::ImageResolver.resolve(label, owner:)`. When
  several `Image` rows share a label, it picks the one with the **most `Doc`s
  attached** (`COUNT(docs) DESC, id ASC`) — the admin's de-facto default symbol
  — preferring the owner's own art, then the `DEFAULT_ADMIN_ID`/unowned public
  library. Matching is **case-insensitive** (folder labels are capitalized,
  curated art is often lowercase). Without this, category folder tiles (Animals,
  People, Feelings…) rendered blank because resolution grabbed a label-only
  image the OBF seed created. Because `BoardImage#set_defaults` derives the tile
  label from its image, the curated folder name is pinned explicitly so an
  upgraded lowercase art image doesn't rename the tile (`copy_tiles!` restores
  the authored label; `BuildBoardSetJob#add_folder_tile!` sets the category name).
- **Fringe boards get the same art upgrade as the root.** Only the root board
  ran the blank→art upgrade originally; the seed's fringe sub-boards and
  standalone prebuilt fringe pages clone through `Board#clone_with_images`
  (no upgrade), so they rendered blank while the root had pictures.
  `Boards::ImageResolver.upgrade_board_tiles!(board, owner:)` re-points every
  blank tile to the curated default image for its label (blank→art only,
  authored label preserved, never creates a stray image) and runs on each
  cloned fringe board (`SeededSetCloner#clone_all`,
  `BuildBoardSetJob#clone_one_prebuilt_page!`). Backfill existing built sets
  with `rake board_builder:upgrade_tile_images` (dry-run by default;
  `DRY_RUN=false` to apply, `USER_ID=N` to scope).
- **Level recommendation heuristic:** young/emerging → Starter,
  developing/young_teen → Standard, proficient/older → Extended. Based on
  `CommunicatorProfile` helpers (`developing?`, `young_teen?`). **Not clinically
  validated** — reasonable defaults that should be revisited with AAC research or
  user data.

Endpoints (`API::V1::BoardBuilderController`, all auth-gated):

- `GET /api/v1/board_builder/templates` — label-only picker catalog. Returns
  `levels` (array of `{ key, name, description, fringe_page_range }`),
  `recommended_level` (profile-based, null without a communicator), and
  `recommendation_reason`. Also returns legacy `templates` array and
  `recommended_template` for backward compat. Accepts an optional
  `communicator_id` (scoped to `current_user.communicator_accounts`).
- `GET /api/v1/board_builder/interest_categories` — returns the full category
  dictionary (`{ categories: [{ name, words }], max_interests }`) for the
  frontend's categorized interest picker. 18 categories, ~504 words.
- `POST /api/v1/board_builder` `{ communicator_id, level, interests }` or
  `{ communicator_id, template, interests }` — `level` is preferred; `template`
  is the legacy path. `level` takes precedence when both are sent.
  `interests` accepts plain strings or `[{ word, category }]` hashes; explicit
  categories override the dictionary lookup. Ownership check (**404
  `communicator_not_found`** for a communicator not in
  `current_user.communicator_accounts`), plan → build → persist normalized
  interests to `child_account.details["interests"]` (jsonb merge), return the
  favorited root board's `api_view` (**201**). **422 `unknown_template`** /
  **422 `build_failed`** (the build is transactional — failure rolls back, no
  orphans). The frontend page ships separately in `itty-bitty-frontend`.
  - **`communicator_id` is OPTIONAL — omit it to build an UNATTACHED set.**
    A **present but unresolvable** id is still a 404; only an **absent** one
    takes the unattached path, so every existing client is unaffected. The
    requirement was never structural: `BoardGroup` (the set — what the plan
    limit counts and what cascade-deletes the tree) is user-owned and has no
    `child_account` at all. The single hard dependency is the `ChildBoard` join
    (`child_accounts.child_account_id` is NOT NULL), so an unattached build
    simply **doesn't create one** — no migration, no schema change. What
    differs without a communicator:
    - No `ChildBoard`, so no favorited root and the set isn't on anyone's
      dashboard; it still lives in the user's Board Sets via its BoardGroup.
    - `owner` is `current_user` instead of `communicator.owner || .user`.
    - Voice falls back to the **owner's** default (`User#voice`);
      `VoiceService.normalize_voice(nil)` would otherwise force `polly:kevin`.
    - **No 409 re-run guard** — detection is inherently per-communicator
      (`ChildAccount#builder_roots`), so each unattached build is just another
      Board Set, capped by `at_board_group_limit?` (422). That 422 still
      applies to both paths.
    - Interests persist to `board_group.settings["interests"]` (the existing
      jsonb) instead of `child_account.details["interests"]`.
    - `CommunicatorProfile.for(communicator: nil)` returns nil, and every
      consumer already treats "no profile" as "no personalization" — so an
      unattached build gets no level recommendation, no GLP stage, and no
      profile-guided AI prompts. `GET .../templates` needed no change: it
      already returns nil recommendations when `communicator_id` is blank.
    - `BuildBoardSetJob` receives a **nil** `communicator_id`; it fails the root
      only when an id is **present and unresolvable** (a real dangling ref).
  - **Board-limit gated, but a tree counts as ONE board.** `create` returns
    **422 "Maximum number of boards reached"** when `current_user.at_board_limit?`
    (see the board read-only rule in `.claude-notes/billing-and-plans.md`). Because one wizard run persists a whole
    linked tree, `BoardTreeBuilder` marks every sub-board (depth > 0)
    `settings["builder_child"] = true`, and `User#countable_board_count` excludes
    them — so the tree counts as its single root, not ~5. This also keeps the
    whole built set editable (the read-only lock keys off the same count).
  - **Re-run guard (issue #269) + replace flow: detect + warn, never silently
    dupe.** If the communicator already has a builder set, `create` returns
    **409 `board_builder_set_exists`** (`{ existing_root_id,
    existing_root_name, built_at, can_replace: true, existing_sets: [{
    root_id, name, built_at }] }` — the legacy top-level keys are kept for
    the shipped frontend) instead of stacking a second favorited root. Two
    ways past it: **`replace=true`** (preferred; takes precedence) destroys
    **every** existing builder set on the communicator first — each root's
    builder BoardGroup cascades via #407 (`destroy_existing_builder_sets!`;
    a group-less legacy root is destroyed directly) — then builds fresh;
    **`confirm=true`** keeps its legacy "stack another set" meaning
    (repurposing it would destroy data on old clients). Detection is
    `ChildAccount#builder_roots` (plural; `board_builder_root` = newest) —
    each root is marked `settings["builder_root"] = true` (does **not**
    affect the board-limit count). Deletion-safe: delete the set and a
    re-run is a fresh build. **Ordering:** the existing-set handling runs
    *before* the board-set-limit gate, so a user at their set cap can still
    REPLACE (the destroy frees the slot); a plain re-run 409s first, and a
    confirmed STACK at the cap still gets the 422.
  - **ChildBoard is unique per (board, communicator)** — model validation +
    unique index (`index_child_boards_on_board_and_child_account`); the
    ad-hoc `.exists?` guards at call sites remain as fast paths.

### Robust vocabulary sets (Core 60 / Core 84)

A second template **kind** beside the label-only starter trees: pre-authored
core vocabulary sets, **authored as OBF/OBZ** and seeded as admin-owned
predefined boards, then **deep-cloned per user** on build (so authored grid
layout + `part_of_speech` colors survive). Reuses `ObzImporter` (seed) and
`Board#clone_with_images` (build). SpeakAnyWay content only.

- **Seed:** `bin/rails vocab_sets:seed` (logic in the `VocabSets` service)
  zips the editable OBF-JSON under `db/seeds/board_builder_sets/<slug>/` and
  imports it via `ObzImporter` as `User::DEFAULT_ADMIN_ID` with
  **`board_group: nil`**. **No `BoardGroup`** — a set is identified by a marker
  on its **root board** (`settings["board_builder_robust_slug"]`), queried via
  `Boards::RobustSets`. Idempotent (`Board.from_obf` upserts by
  `(user_id, obf_id)`). Format spec: `db/seeds/board_builder_sets/README.md`.
  Slugs `core-60` (authored as a full 60-tile home: 50 core words + 8 category
  folders — People, Feelings, Food, Drinks, Play, Places, Body, More — wired in
  the bottom row, flanked by `this`/`that`), `core-84` (a full 84-tile home:
  73 core words + 11 category folders — the Core 60 eight plus School, Time,
  Describe — with `this`/`that` filling the folder row to a true 84).
  - **Tile upserts are keyed on the authored OBF button id, not the resolved
    `image_id`.** `Board.upsert_board_image` matches an existing tile by the
    button id stamped on `board_image.data["obf_button_id"]` (falling back to
    `image_id` for tiles seeded before stamping existed). Before this, the upsert
    keyed on `image_id` alone, so when `find_or_create_image_for_button` resolved
    the **same** authored button to a **different** `Image` across re-seeds (the
    OBF button's `image_id` drifted, so the `obf_id` branch missed and the
    label-only fallback picked a different match), it **appended a duplicate
    tile** instead of updating the existing one. That's how the Core 60 source
    grew a second `all done` word tile (2026-06-17 re-seed), which
    `SeededSetCloner` then copied into every built set (the "extra all done"
    bug). As a backstop, `VocabSets#dedupe_tiles!` (via
    `Boards::TileDeduper.collapse_duplicates!`) runs in the seed sync pass and
    collapses any surviving same-label/same-kind duplicate on each seeded board
    — a word tile and its same-named category folder (`play` vs `Play`) are
    **not** merged. Re-seeding is now self-healing for this case.
  - **Layout self-heal on re-seed (`VocabSets#repair_layout!`).** The same
    duplicate bug could also leave the surviving tile on the **wrong cell**: the
    upsert set the matched tile's coords but a leftover copy kept stale ones, and
    dedupe could keep the wrong copy — so two tiles ended up on **one cell** (e.g.
    Core 84 `wait` parked on `again` at `[10,5]`) while another cell sat empty,
    rendering one tile hidden behind another ("84 looks like 82"). Neither dedupe
    (different labels, not duplicates) nor `LayoutRepacker` (the cell is in-grid,
    not off-grid) catches that. `repair_layout!` runs **last** in `seed_slug!`
    and re-pins every surviving tile to its **authored** `[x,y]` read straight
    from the source OBF grid (matched by `data["obf_button_id"]`), so a single
    `bin/rails vocab_sets:seed` now converges a corrupted source back to a clean
    84/60 with zero overlaps. A clean re-seed is a no-op. A clean **first-time**
    import was always correct; this only heals sources mangled by the historical
    re-seed bug.
  - **Remediation:** `rake board_builder:dedupe_seed_tiles` (dry-run by default,
    `DRY_RUN=false` to apply, `USER_ID=N` to scope) collapses the duplicate on
    the robust seed sources **and** every already-built user set
    (`settings["builder_root"]/["builder_child"]`) — re-seeding only heals the
    admin sources, not the user clones, so run this for the live sets built
    between the bad re-seed and the fix.
  - **Off-grid tiles + the Speak-view divergence — `rake board_builder:repair_grid`.**
    A duplicate folder tile could be parked PAST the grid edge (e.g. a Core 84
    `More` folder at `x=13` on a 12-column board). The editor renders through
    react-grid-layout, which clamps to the configured `cols`, but the native
    **Speak** view sized the grid by the tile extent and silently widened to 14
    columns — so the same board looked different in Speak than in every editor
    view. Two layers fix it: **(1)** `Boards::TileDeduper` now keeps the
    **in-grid** copy of a duplicate (not blindly the lowest-position one), so it
    no longer preserves the off-grid twin and delete the authored in-grid tile;
    **(2)** `Boards::LayoutRepacker` is the safety net for a genuine
    *non-duplicate* **displaced** tile — one that's either **off-grid** (`x+w >
    cols`) **or overlapping** a cell an earlier (reading-order) tile already
    claims. It moves only the displaced tiles into the first empty rows below the
    fitting tiles (per screen size, then resyncs `board.layout`), a Ruby port of
    the frontend `repackLayout`. The overlap case is what heals **user clones**
    built from a corrupted source — `repair_layout!` fixes the admin seed, but
    existing user sets need this. The combined
    `rake board_builder:repair_grid` (dry-run by default; `DRY_RUN=false`,
    `USER_ID=N`) runs dedupe + repack across the seed sources and every built
    set and regenerates the preview for any board it changes. The companion
    frontend fix (itty-bitty-frontend `NativeLayoutGrid` repacks to the
    configured columns) means Speak matches the editor even before this data
    cleanup runs.
- **Build:** `#create` branches on `Boards::RobustSets.find_root(template)`.
  A match runs `Boards::SeededSetCloner` (walks the linked set to depth 2,
  clones each board, **rewires** `predictive_board_id` to the clones, marks
  root `builder_root` / rest `builder_child`, favorites the root ChildBoard,
  routes interests into the cloned fringe pages / "My Favorites"). Same
  synchronous **201** response and the **same** limit (422) and re-run (409)
  guards as the starter path — counts as ONE board.
- `GET /board_builder/templates` entries now carry `kind: "starter" | "robust"`.
- v1 is **synchronous** (DB-bound work; previews/audio/AI art already async).
  If a finalized set is materially larger than the placeholder, move the clone
  to a background job + "building" state — see `.claude-notes/board-builder.md`.

### Stored communicator profile (AAC personalization)

`aac_level` / `vocab_type` / `age_band` live in **`child_accounts.details`**
(jsonb, same pattern as `details["interests"]` — no columns). `ChildAccount`
defines typed accessors over them, normalizes (downcase/strip, blank clears the
key), and validates against `CommunicatorProfile::AAC_LEVELS / VOCAB_TYPES /
AGE_BANDS` on every save — including the wholesale `details=` assignment in the
communicator update controller. Exposed top-level (next to `details`) in the
ChildAccount `api_view` / `vendor_api_view`.

`CommunicatorProfile.for(params:, communicator:)` is the merge constructor:
explicit request params override stored fields **field by field**; returns nil
when both sources are empty (no profile = unchanged behavior). Consumers:
`boards#words`, `boards#additional_words`, and `GenerateBoardJob` all accept an
optional `communicator_id` — always resolved via
`current_user.communicator_accounts` (controller-side for the job; the id in
job options is pre-validated), never a bare `ChildAccount.find`. An id the
caller doesn't own is silently ignored. Personalization reaches **AI
word-suggestion prompts and the template recommendation only** — the Board
Builder's deterministic build path is unchanged.

### Gestalt language support (GLP)

A communicator may also carry an optional **NLA stage** for gestalt language
processors: `glp_stage` (integer 1–6), stored in `child_accounts.details` next
to the AAC fields. It **measures something different from `aac_level`** — it
doesn't replace it; both can be set independently. Wiring:

- `glp_stage` is in `ChildAccount::AAC_PROFILE_FIELDS` (so it rides the same
  typed accessor + wholesale-`details=` validation), but listed in
  `INTEGER_PROFILE_FIELDS` so normalization coerces it to an **integer** instead
  of downcasing it to a string (which would fail the `GLP_STAGES` inclusion
  check). Validated against `CommunicatorProfile::GLP_STAGES` (`(1..6)`). Exposed
  on the ChildAccount `api_view` / `vendor_api_view`.
- `CommunicatorProfile` gains `glp_stage`, the predicates `gestalt_early?`
  (1–2) / `gestalt_emerging?` (3–4) / `gestalt_advanced?` (5–6), and appends
  stage-specific `prompt_guidance` (whole phrases at early stages → full
  sentences at advanced). A glp-only profile is `present?`, so `.for` returns
  it. No `glp_stage` ⇒ no gestalt guidance (backward compatible).
- **GLP board templates** (`Boards::GlpTemplates`): six predefined, admin-owned
  whole-phrase function boards (Greetings/Requests/Protests/Comments/Feelings/
  Transitions), identified by `category: "glp"` + `is_template: true`. `TEMPLATES`
  is the single source of truth for the idempotent seed (`bin/rails
  glp_templates:seed`, via `.seed!`) and the stage-aware recommendation
  (`.recommended_for`). They surface in `GET /api/v1/board_builder/templates`
  (`kind: "glp"`, a `glp_templates` array, and a stage-driven
  `recommended_template`) for **recommendation/badge display only** —
  `?template_type=glp` still filters to them. **A GLP slug is NOT a build target**
  (`POST /api/v1/board_builder` with `template=glp-*` → 422 `unknown_template`).
- **Gestalts ride every build as an integrated Phrases layer** (the either/or
  was retired). `Boards::StructurePlanner` adds a `phrases_page` to the plan
  (folder-prominence by default; `:strip` for an early-stage `gestalt_early?`
  communicator; `nil` only when `include_phrases: false` AND no `glp_stage`).
  `BuildBoardSetJob#build_with_structure_planner` then builds it via
  `Boards::PhrasesPageBuilder` (a "Phrases" board linking the six function pages,
  cloned from `GlpTemplates.function_boards`), links it from the home board, and
  for `gestalt_early?` surfaces a personalized quick-phrase strip on the home
  board (capped to open grid cells — degrades to folder-only, never overflows).
  The strip **dedupes against the home board's existing labels**, so a phrase
  that's already an authored core word (e.g. "all done", which is also a
  Transitions gestalt) isn't added a second time. The wizard sends an optional
  `include_phrases` boolean (default-on in the planner). `build_glp` and the
  GLP-slug build branch were removed.
- **Phrase-board wiring.** The new Phrases board doubles as the communicator's
  **phrase board** (the sentence-builder save target + quick-phrase source,
  `settings["phrase_board_id"]`). After a build, `wire_phrase_board!` sets it on
  the communicator and backfills the owner **only when blank** — never clobbering
  a phrase board the user already picked. Build-time only; existing sets aren't
  retroactively given one.
- **Whole-phrase tiles:** `part_of_speech: "phrase"` marks a gestalt script
  tile. `Image#ensure_defaults` preserves an explicit `"phrase"` POS instead of
  re-categorizing it as a single word (every other label is still categorized as
  before). Script Collector adds tiles via `POST /api/boards/:id/add_image` with
  `image[part_of_speech]=phrase` and optional free-form `data[gestalt_source]` /
  `data[utterance_function]`, stored on `board_images.data`.

- **Publishing:** a built set publishes and unpublishes as a unit, behind a 409
  warn+confirm. See "Publish cascade (warn + confirm)" in
  `.claude-notes/boards-and-teams.md`.

## Not this: the admin Board Builder (`/admin/board_builds`)

Everything above is the **user-facing wizard** — communicator-scoped, template
plus interest words, `POST /api/v1/board_builder`. There is a second, unrelated
builder in the ERB admin, added in Phase 1 of
`.claude-notes/admin-board-builder-handoff.md`. Don't confuse them.

`Admin::BoardBuildsController` authors a single **dense public board** from a
typed word list, owned by `User::DEFAULT_ADMIN_ID`. It shares the wizard's
image-resolution seam (`Boards::ImageResolver`) and nothing else — no
communicator, no templates, no interest routing, no `ChildBoard`.

Its own invariants:

- **Preview writes nothing.** `Boards::AdminBuilder::ArtPreview` resolves art
  through `Images::LabelSearch` (whose `resolve` tier calls the read-only
  `best_arted_for`), never `ImageResolver.resolve`/`resolve_all` — those create
  a blank `Image` for any unmatched label, so a read-only path must not call
  them. `resolve_all` runs only inside `Boards::AdminBuilder::Build`'s
  transaction, where creating blanks is the intended outcome. Asserted by spec
  on both `Board.count` and `Image.count`.
- **The review screen's two per-tile controls are decided at BUILD time, not on
  the screen.** "Regenerate with AI" (`plan["regenerate"]`, a list of labels)
  and the picture picker (`plan["display_docs"]`, label => `docs.id`) both ride
  the hidden-field resubmit through the HTML5 `form="build-form"` attribute, and
  both are re-filtered against the plan in `create` rather than trusted — a
  hand-edited field must not be able to name an arbitrary label, and a picked
  doc is additionally checked to be library-owned (`user_id` nil or the default
  admin) so a real user's upload can't be published onto a public board. Labels
  are normalized through `Boards::ImageResolver.normalize` on the way in, which
  is the form `Build#resolved` looks them up by.
  **A pick beats a mark**: they are the same decision made two ways, and keeping
  both would pin the chosen picture and then generate over it —
  `Build#regenerate_image_ids` subtracts the picks, because
  `unpin_regenerated_tiles!` would otherwise clear the very
  `display_image_url` that carries the choice.
  A pick moves the PICTURE only: the tile still resolves to its own `Image`, so
  the word it speaks, its audio, and every other board using that word are
  untouched. `ArtPreview` offers the alternatives by raising its
  `Images::LabelSearch` limit to `CANDIDATE_LIMIT` — the `resolve` tier still
  comes first, so result 1 is what gets attached and the rest are the offer.
  Doc ids, not image ids: which doc an image resolves to moves as art is added.
- **A board is authored as columns + a tile count, never rows.** Rows aren't
  stored anywhere — `Board#rows_for_screen_size` derives them from the tiles —
  so `admin_board_builds.tile_count` (and a child page's `tile_count` override
  inside `plan`) is the size. `Boards::AdminBuilder::PlanValidator` enforces two
  separate things: the word list must be **exactly** `tile_count` long, and
  `tile_count` must be a whole number of rows for the column count. Only the
  second has an escape hatch ("allow a partial row") — a tile count that isn't a
  multiple of the columns leaves dead cells at the right end of the last row.
  Shrinking the board is the fix for a short word list, not ticking the box.
- **A page's back tile is placed by mirroring, not by authored order.** Tiles
  otherwise land in pure reading order (`Build#apply_reading_order!`:
  `x = i % columns`, `y = i / columns`), and both drafters ask the model for
  "one tile that goes back" — which it reliably writes **last**, parking every
  page's way home in the bottom-right corner.
  `Boards::AdminBuilder::BackTileAlignment` swaps it into the cell its parent's
  folder tile occupies, at every depth. It is a **pure function over the plan**
  with no database reads: reading-order positions are derivable from a tile's
  index, so the parent's cell is known from the plan alone. That is what lets
  `ArtPreview` render the same permutation — otherwise the admin approves a grid
  the build won't produce. Parentage is BFS from `ROOT_KEY`, so the *shallowest*
  parent wins when two pages open the same child; x and y are clamped into the
  child's own grid (pages may carry their own `columns`). A ragged last row is
  resolved **by backing up a row in the same column, never by sliding along the
  row** — the column is what muscle memory is anchored to, and clamping to the
  last occupied cell made the alignment a no-op for the common case where the
  parent's folder tile sits at the far right of its own last row (the back tile
  was already written last, i.e. in that corner). A **swap, not an insert** — both tiles are 1×1, so
  the grid stays packed and the displaced word takes the corner.
  `Board#apply_layout!` sorts by `[y, x]` and renumbers `position`, so reading
  order downstream follows the aligned layout for free.
  **Gap:** nothing guarantees a page *has* a back tile — `FolderTiles` and
  `PlanValidator#orphan_problems` only enforce the forward direction (a door
  *into* every child), and there is no admin-side `ensure_home_tile!`. Alignment
  moves a back tile that exists; it does not create a missing one.
- **Boards are marked `settings["admin_builder"] = true`** and every member
  action is scoped through `AdminBoardBuild.builder_boards`, the same rail
  `Admin::VideoBoardsController` runs on. Boards are created unpublished;
  publishing is a separate confirmed POST that refuses an empty board.
- **The set and the build's pointer at it commit together, under a row lock on
  the build** (`Build#create_and_claim!`), and `art_report["boards"]` is written
  in that same transaction — every page, not just the root. Both halves are
  load-bearing. `BuildAdminBoardJob` is `retry: 2`, so a claim written *after*
  the creating transaction left the boards committed with `board_id` still blank
  whenever anything in between raised (the two art queries, the jsonb write) —
  and the retry sailed past the "already built" guard and produced a second full
  set. A stranded set stays `published: true` and appears in no build's
  `art_report`, so `AdminBoardBuild#set_boards` can't see it: not listed on the
  build page, skipped by publish/unpublish, left behind by destroy. The row lock
  is the other half, because Sidekiq delivers at least once and two workers can
  both read a blank `board_id` before either writes one.
  `rake admin_board_builds:orphans` finds sets already stranded this way
  (`UNPUBLISH=1` / `APPLY=1` to act). The other duplication route is two POSTs
  to `create` — that makes two *builds*, and the preview page's submit guard is
  what stops a double click causing it.
- **A failure once the set is committed is a WARNING, not a failed build.**
  `Build#call` splits on whether `board_id` is committed: `mark_failed!` means
  nothing was produced, `mark_finished_with_warning!` means the boards exist,
  are published and are correct and only the recoverable tail
  (`finish!` — art report, unpin, art queueing) is outstanding.
  `AdminBoardBuild#warning?` / `#needs_finishing?` are the two predicates, and
  `finish!` clears `error_message` on the run that makes good on it. The trap
  this closes: **`create_and_claim!` can raise from the commit itself** —
  after_commit callbacks run inside `with_lock`, so a transient
  ActiveStorage/vips failure in one of them propagates out with every board
  already written (a real ENOENT on an image_processing tempfile did exactly
  this). Paired with `call`'s unconditional "already built" early return, that
  made `BuildAdminBoardJob`'s `retry: 2` a no-op: the build kept a red badge
  forever, `art_report` stayed the claim-time stub, and no AI art was ever
  queued for its blank tiles. `call` now re-runs `finish!` for a set it already
  owns (never `create_set!`), and `POST /admin/board_builds/:id/finish`
  re-queues the job by hand for a row already stuck this way. `finish!` reads
  `built_boards` / `linked_boards` back from `art_report` when there was no
  create pass, which is what makes a repair run possible at all.
- **A page can LINK an existing published admin board instead of building one.**
  `children[i][existing_board_id]`, offered by `Boards::AdminBuilder::ExistingBoards`
  whenever a published admin board carries the page's name (name match, ranked
  same-grid-first; predictive and menu boards excluded because
  `BoardImage#door_tile?` wouldn't read a tile pointing at one as a folder).
  Creating a new page stays the default. Three rails:
  `Plan.child_page` blanks a linked page's tiles at the single point every
  consumer reads a page from, so validation, art resolution, preview and build
  agree without each remembering the rule; the linked board is recorded under
  `art_report["linked_boards"]` and **never** `["boards"]`, since that key is
  what publish/unpublish/destroy iterate; and `Build#pin_as_main_board!` sets
  `settings["builder_root"] = true` on it, because `check_is_sub_board` is a
  `before_save` that would otherwise demote the board out of `main_boards` (and
  out of `Boards::AdminSearch.base_scope`, so out of admin board search) on its
  next unrelated save. The id is always re-resolved through
  `ExistingBoards.find`, never `Board.find` — it arrives on a form post.
  **Known gap:** a linked board keeps whatever back tile it already had, so it
  has no way back to the new root. `data["back_tile"]` is not a runtime
  behaviour — navigation is the static `predictive_board_id` — so a shared board
  can only ever have one home until a "return to caller" nav exists.
- **md/sm column counts are derived** via `Boards::ScreenColumns`, explicitly —
  `Board#set_screen_sizes` only fills them when nil, and
  `boards.medium/small_screen_columns` carry non-nil database defaults (8 and
  3), so "set lg and let Rails handle it" silently gives a 6-column board an
  8-column tablet layout.
- **AI art for uncovered labels is queued after the commit**, in slices of 3,
  matching `API::Internal::BoardImagesController#queue_missing_art!`. The
  board's topic is written to `Image#image_prompt` as intent only — "swing in
  the context of the playground" — because `Images::PromptBuilder` composes the
  house style envelope at generation time and must not have it baked in twice.

- **AI drafting only ever populates the form.** `POST .../board_builds/draft`
  runs `Boards::AdminBuilder::WordListDrafter` and re-renders `new` with the
  textarea filled — it never feeds a preview or a build. The draft is a starting
  point a human edits; everything downstream still validates it from scratch.
  Deliberately one new prompt rather than a composition of the existing pieces:
  `Board#get_words_for_scenario` needs a persisted Board and returns bare
  strings, and `AacWordCategorizer.categorize` is one OpenAI call *per word*, so
  chaining them is an N+1 against a paid API. No credit charge — the boards are
  admin-owned. Short drafts are returned rather than raised on, since the form
  can absorb them; only an unusable response is an error.

- **The DRAFTED ORDER IS THE LAYOUT, so drafters arrange before the form sees
  the words.** `Build#apply_reading_order!` is nothing but
  `x = i % columns, y = i / columns` — whatever order a drafter puts in the
  textarea is what an admin sees laid out and what a communicator scans. Left to
  the model's own ordering, the Modified Fitzgerald colours the builder already
  applies per tile came out as confetti: verb, noun, pronoun, noun.
  `Boards::TileArrangement` is the single authority on that order —
  a stable sort into `BAND_ORDER` (quick words first: pronoun, social,
  important_function, question; then the sentence: verb, adverb, adjective,
  preposition, determiner, conjunction, noun, default), with anything carrying
  `links_to` sorted after every word band so doors and back tiles land on the
  bottom rows like the rest of the app's navigation. `BAND_ORDER` must stay a
  permutation of `ColorHelper::PARTS_OF_SPEECH` (spec'd), and the arrangement
  itself must stay a **permutation only**: no tile added, dropped, relabelled or
  relinked, so nothing downstream — `PlanValidator` counts, `FolderTiles` links,
  `BackTileAlignment` mirroring — has to re-check it. Column-free on purpose:
  bands can't be made to break on row boundaries without padding, and the grid
  must be exactly full.
  - It lives at `Boards::TileArrangement` now, not
    `Boards::AdminBuilder::TileArrangement`: the user-facing "Format with AI"
    path (`Board#format_board_with_ai`) bands its tiles with the same module, so
    the admin namespace was a lie. The old constant survives as an alias in a
    stub file at the old path — Zeitwerk needs the file to exist for the name to
    autoload — and every drafter still says the old name.
  - Arrangement runs **inside the drafters**, never in the controller.
    `FolderTiles.link` runs on every form round-trip, and re-sorting a
    hand-edited list because the admin pressed a button is not the deal. For the
    same reason `add_words` arranges only the NEW tiles it appends.
  - `SetDrafter` arranges **after** `top_up`, or a follow-up call's words sit as
    an ungrouped block on the end of a grouped board.
  - Known limit: `FolderTiles.link` can *promote* an existing noun tile into a
    door in place after drafting, and that one tile stays in the noun band.
    Appended doors land last, which is correct.
  - `TileArrangement` also corrects the part of speech from
    `AacWordCategorizer::OVERRIDES` before sorting — a wrong POS is a wrong
    colour and now a wrong band, and that table is already the app's authority
    on the words models reliably miscall ("stop" as a verb, "more" as an
    adjective). The OVERRIDES table **only**, never `.categorize`, which is one
    paid call per word. Doors are exempt: a door's label is a page name, so
    "Play" must not be recoloured because a word table knows the verb.

- **Every drafter shares one system prompt, one set of word rules, and a JSON
  schema — and so does every user-facing word path now.** The TEXT moved out to
  `Prompts::Aac` (see `.claude-notes/ai-prompting.md`); `Drafting::SYSTEM_PROMPT`
  and `::WORD_RULES` are delegating aliases, and a spec asserts they still match,
  so everything below reads the same. What did NOT move is the model,
  temperature, reasoning effort and timeout — those are measured decisions about
  this path specifically and stay in `Drafting`.
  `AdminBuilder::Drafting` owns all three: `SYSTEM_PROMPT` (sent as a
  `system` message ahead of each drafter's own `user` message), `WORD_RULES` (the
  rules that separate a board from a word list — combinatorial value, a way to
  object and a way to redirect, no single-use nouns, no closed-set filler,
  register follows the audience), and `tile_schema`. Each drafter defines its own
  Structured Outputs schema from `tile_schema`, which pins `part_of_speech` to
  a real enum instead of hoping prose holds. Strict mode requires every property
  in `required` and forbids extras, so an optional field is **nullable**, not
  absent. `Drafting.chat` retries down a ladder — schema+temperature → schema →
  no schema — because `MODEL` is ENV-tunable and `create_chat` swallows an API
  error into a debug log and returns nil, so a rejected parameter is
  indistinguishable from "the AI had nothing to say" and would take drafting
  down silently. `OpenAiClient#create_chat` now prefers an explicit
  `response_format` over its `json_object` default, mirroring `create_completion`.

- **A build can be a linked set, not just one board.** `plan["children"]` holds
  child pages (`key`, `name`, optional grid, tiles) and any tile may carry
  `links_to`, which becomes `predictive_board_id` — the same one-line link
  `Boards::BoardTreeBuilder` makes. `Boards::AdminBuilder::Plan` normalizes the
  root and its pages into one list so validation, preview and build never
  special-case the root; the root's key is `Plan::ROOT_KEY` (`__root__`), which
  is also what a "back to home" tile links to.
- **A page nothing opens is never authored on purpose, so the door is written
  for you.** `Boards::AdminBuilder::FolderTiles.link` runs on EVERY form
  round-trip (`submitted_form`, and again after each drafting action rewrites
  part of the form) and gives any keyed page with no inbound link a folder tile
  on the root. It has to run on every round-trip because every drafter replaces
  something after the fact: `WordListDrafter` rewrites the whole root list —
  wiping the `>key` tokens a set draft had put there — and `PageDrafter` knows
  about one page and can't name a sibling, so only `SetDrafter` ever emitted a
  link at all. A tile already saying the page's word is *promoted* rather than
  duplicated, including one whose `links_to` names a page that doesn't exist (a
  mistyped `>fod` next to a page called Food is a door meant for that page).
  Root drafting asks for `tile_count - reserved_count` words so the folder tiles
  land inside the grid; when the root is already full, trailing plain words are
  displaced to make room and named in the banner — a word is regenerable, a door
  is not, and an overflowing board can't be built at all. Folder tiles carry a
  `display_label` because a category tile's label is authored ("Food" opens a
  page, "food" says the word) and `Image#set_label` would otherwise fold the
  capital. `PlanValidator#orphan_problems` is the backstop, not the mechanism —
  it only fires for a page whose key never got far enough to link.
- **Linking is a three-pass write, NOT a topological build order.** Every page's
  Board row is created first, then tiles, then the links. `build_board.py` needs
  `build_order()` with cycle-breaking because its HTTP API creates a board
  *together with* its tiles and so can't name a board that doesn't exist yet —
  the same class of remote-client workaround the rest of this page deliberately
  didn't port. In-process, linking is already a separate `update!`, so creating
  the shells up front makes cycles (a page's back-link to the root, two pages
  linking to each other) structurally impossible to get wrong instead of
  something a heuristic has to guess its way out of.
- **Every page shares the root's grid.** A page with no authored grid inherits
  it; a page that authors a different one is rejected unless "allow mixed grids"
  is ticked. A communicator moving into a folder page shouldn't have the cell
  size change under their finger.
- **Only the root is `predefined`.** `Board.public_boards` keys on it, so a set
  whose every folder page appeared there as a standalone board would bury the
  board it belongs to. Pages stay reachable because `Board#viewable_by?` gates on
  `published` alone. The root also carries `settings["builder_root"]` when it has
  pages, so a back-link can't make `check_is_sub_board` demote it; pages carry
  `settings["builder_child"]`.
- **Publish and unpublish move the whole set**, for the reason spelled out in
  `.claude-notes/boards-and-teams.md`: `viewable_by?` is per board, so publishing
  only the root leaves every folder tile 404ing for a visitor. The set is read
  from `art_report["boards"]` (key → board id, recorded at build time) and
  re-scoped through `builder_boards`, so a hand-edited id can't widen the blast
  radius. Publishing refuses a set with any empty page; delete removes pages
  before the root.
- **Both review grids render the authored column count**, via the `.builder-grid`
  class in the admin layout plus an inline `--cols`. Tailwind can't compile a
  class assembled at runtime, so a hardcoded six-across grid was showing every
  board — 4-wide, 8-wide — at a width it would never be used at, which defeats
  the point of reviewing before publishing.
- **The review page links out with `board_app_url`, not the `/pb/` page.**
  `Admin::BoardBuildsHelper#board_app_url` points at `FRONT_END_URL/boards/:id`,
  which resolves for an unpublished board — the whole point of the review step.
  `board_published_page_url` (`/pb/<slug>`) is only rendered once
  `board.published?`, because `Board#viewable_by?` gates the public page on that
  flag and an unpublished link would 404 the admin who clicked it.

- **Name, topic and audience are inferred, not typed.**
  `Boards::AdminBuilder::ContextSuggester` reads whichever of a name, a topic
  and the words already in the form it is given, and returns
  `{ name:, topic:, audience: }` in one OpenAI call — same shape as
  `WordListDrafter`. `POST .../board_builds/suggest` fills every blank field;
  `draft` calls it first whenever the name **or** topic is blank, so a build can
  start from a name, a topic, or a pasted word list alone. A value the admin
  typed is never overwritten, the name included.
  - **Not gated on a blank audience.** Audience is optional to the drafter, so
    it isn't worth a round trip of its own — but name and topic both are
    (preview and build require a name; topic steers every art prompt), and the
    one call answers all three anyway.
  - Topic and audience are prompt fragments, not display copy — `topic`
    completes "`<label>` in the context of ___" for every generated tile on the
    board — so the response is stripped of a trailing full stop and
    length-capped. A runaway answer would otherwise end up inside every art
    prompt. `name` is capped too: it is user-facing and seeds the slug.
  - The board name input is `required`, which is right for preview and build but
    would have the browser block a draft before the server could infer one — so
    the draft and suggest buttons both carry `formnovalidate`. A request spec
    can't catch that; it bypasses HTML validation.

AI drafting (Phase 2) fills the main word list only — pages are authored by hand.

- **`Boards::AdminBuilder::SetDrafter` drafts a whole linked set in one call**
  — root word list with its folder tiles already carrying `links_to`, plus each
  page's key, name and words. It honours the two `PlanValidator` rules by
  construction: it states the exact per-page tile count in the prompt, and it
  never gives a child a grid of its own. Like every other AI path here it only
  fills the form. `Boards::AdminBuilder::WordList` is the single parser/renderer
  for the textarea format; `.render` is the exact inverse of `.parse`.
  Two behaviours worth knowing before reading its output: a page's words are
  deduped against the ROOT's as a hard filter (a word the main board carries is
  reachable from every page, so a repeat spends a cell and buys nothing), and a
  board more than `TOPUP_THRESHOLD` tiles short triggers ONE follow-up call
  through `WordListDrafter`'s top-up prompt, capped at `MAX_TOPUPS` for the
  whole draft. That means a single "Draft the whole set" click can make more
  than one OpenAI call — specs that capture "the prompt" must take the *first*.

- **Drafted labels are folded to lowercase; hand-typed ones are not.**
  `Boards::AdminBuilder::LabelCasing` is the one place this happens, and it only
  decides *which* labels are `Labels::CaseNormalizer`'s business — the casing
  rules themselves stay in that single authority. The model answers in Title
  Case no matter what the prompt says, and nothing downstream was catching it:
  `Image#set_label` folds a plain leading capital only for a NEW image, and
  never for a tile whose plan carries an explicit `display_label`. Two
  carve-outs: a tile with `links_to` is a door and keeps its authored capital
  ("Food", "Snack Time"), matching what `FolderTiles` already pins on the doors
  it writes; and the model may set `"proper_noun": true`, honoured only when the
  label actually carries a capital, because `CaseNormalizer` has no proper-noun
  detection and would otherwise fold "Sarah". Words an admin types in the
  textarea are authored input and are never folded.

- **All three drafters share `Boards::AdminBuilder::Drafting`** for the OpenAI
  call — model (`OPENAI_ADMIN_BUILDER_MODEL`, defaulting to `GTP_5_MODEL`) and
  temperature (`OPENAI_ADMIN_BUILDER_TEMPERATURE`, `""` to send none) in one
  place, because three copies of that call is how they drifted onto different
  settings by accident. It retries once without the temperature if the first
  attempt comes back empty: both knobs are ENV-tunable, not every model accepts
  a custom temperature, and `create_chat` swallows an API error into a debug log
  and returns nil — so a rejected temperature would look exactly like "the AI
  had nothing to say". Note it calls `OpenAiClient.new(**opts)`, splatted: a
  bare positional Hash moves the argument out of kwargs and breaks every spec
  that stubs the constructor.

- **A reasoning model gets no temperature, a low reasoning effort and a longer
  timeout — all three or drafting does not work at all.** `Drafting` decides by
  model NAME (`REASONING_MODEL`, matching `gpt-5`/`o<n>`), so an ENV override to
  another variant is covered. gpt-5 and the o-series 400 on any temperature but
  the default, which the retry ladder can only recover from by spending a whole
  extra call; and at the provider's default effort a 24-tile draft against a
  json schema does not finish inside `OpenAiClient`'s 60s client timeout, so
  both surviving attempts died on the timeout and every draft returned 422 after
  two minutes. `REASONING_EFFORT` (default `minimal`) and `REQUEST_TIMEOUT`
  (default 120s, passed through as the ruby-openai CLIENT option it is) are what
  make it land. Measured on the same prompt: minimal 9s, low 48s, provider
  default timed out — and minimal's list was the better board, so effort here
  buys latency, not quality. The biggest single call is a set draft (root plus
  four pages): 55s at minimal, 83s at low, which is what the 120s is sized for.

- **`Boards::AdminBuilder::MetadataSuggester` fills the catalogue listing** —
  a plain-text description (`boards.description` renders as text on three of
  four frontend surfaces, so HTML would show up literally) and tags steered by
  the live `Board.public_boards_tags`, rationing genuinely new tags so the
  public filter chips don't fragment. **Description and tags are applied to the
  ROOT board only** — child pages are `predefined: false` and never enter
  `Board.public_boards`. `PATCH /admin/board_builds/:id` can fix both after a
  build; nothing else about a finished build is editable.

- **`Boards::AdminBuilder::ArtQueue` is the single art-queueing path** — the
  build and the build page's "generate the missing art" button both go through
  it, so the batch size, the topic-flavoured `image_prompt` seed, and the rule
  that an existing prompt is never rewritten are stated once. The button
  recomputes what has no picture from the boards rather than replaying
  `art_report`, so a tile whose art arrived since isn't generated twice.
- **`GET /admin/board_builds/:id/duplicate`** loads a past build back into the
  form (writes nothing), and `preview` warns — never blocks — when a board of
  the same name already exists in `Board.public_boards` or
  `AdminBoardBuild.builder_boards`.
