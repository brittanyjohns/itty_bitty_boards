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

#### Grid cap: never overflow the authored core grid

The authored core board fills its grid with a few intentional empty cells
(Core 84 = 7×12 = 84 cells, 81 tiles, 3 gaps). `Board#add_image` drops a tile
into the first open cell and only starts a **new row** once the grid is full
(`BoardsHelper#next_available_cell`). So naively adding one folder tile per
fringe page overflowed onto a stray extra row — the "85th tile" bug.

`add_fringe_pages_within_grid!` caps the top-level folder tiles it adds to the
number of open cells (`root_open_cells`, which delegates to the shared
`Board#open_grid_cells`), reserving one cell for "My Favorites" whenever
leftovers are expected. Interest-bearing pages are placed first, so a
nearly-full grid still gets the pages the child actually asked for; anything
that doesn't fit folds into My Favorites — nothing typed is dropped. Net result:
a built robust set never exceeds its authored grid and never leaves a dead
(unlinked) folder tile behind.

> **Hard cap (the "86 tiles instead of 84" fix).** The reservation alone wasn't
> enough once the Phrases layer started riding every build: a fuller authored
> grid (fewer reserved gaps than the repo's Core 84) left no cell for the
> catch-all, yet the catch-all tile was added **unconditionally** — so it (and
> a fringe page) spilled onto a stray 8th row → 86 tiles. The cap is now a hard
> guarantee enforced by **every** top-level tile-adder via `open_grid_cells`:
> the Phrases folder + quick-phrase strip (`build_phrases_layer!`/
> `add_phrase_strip!`), `BuildBoardSetJob#add_to_favorites!`, **and**
> `SeededSetCloner#create_favorites_board!`. When there's genuinely no open
> cell the catch-all tile is skipped (logged), never spilled. Separately,
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
