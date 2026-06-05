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
can be generated later). Resolution order mirrors
`Board#find_or_create_images_from_word_list`: the user's own image → a
public/admin image → create.

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
- **Future:** richer lexicon + more category folders across templates; AI
  symbol generation for new interest words; per-tile voice/label overrides
  (today `add_image` derives the label from the `Image`).

## Tests

- `spec/services/boards/blueprint_assembler_spec.rb` — routing, catch-all,
  dedup, normalization, image create/reuse, unknown template.
- `spec/services/boards/interest_categories_spec.rb` — lexicon contract.
- `spec/services/boards/board_tree_builder_spec.rb` — the persistence half (#259).
- `spec/requests/api/v1/board_builder_spec.rb` — endpoint happy path
  (routing + favorites), auth, ownership, unknown template, build failure,
  and the board-limit gate (tree counts as one; set stays editable).

Run: `RAILS_ENV=test bundle exec rspec spec/services/boards spec/requests/api/v1/board_builder_spec.rb`
