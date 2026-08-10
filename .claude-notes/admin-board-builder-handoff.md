# Handoff: Admin Board Builder (backend)

**Date:** 2026-08-07 · **Status:** not started
**Full plan:** `../drafts/admin-board-builder-plan.md` (this doc is self-contained; the plan adds context)
**Counterpart:** none — this is backend-only, server-rendered `/admin`
**Issue:** none filed

## Baseline

Planned against `origin/main` as of 2026-08-07. Four merged PRs are load-bearing
for the decisions below — `#570` (`predictive_board_id` permitted on internal
board_images), `#573` (`ImageResolver` on the bulk path), `#584` (`board_images`
update/destroy), `#585` (label search tiers). If you're on anything older, these
notes will read as wrong.

## What we're building

An admin page at `/admin/board_builds` that authors a **dense** AAC board — every
grid cell filled, real symbol art on every tile, Fitzgerald colors, `polly:kevin`
— with a **mandatory art-review step before anything is written**.

This ports the `speakanyway-board-build` skill
(`marketing/skills/speakanyway-board-build/scripts/build_board.py` in the
workspace, ~816 lines) out of a Python script that drives the internal HTTP API
and into the app itself.

**The key insight: don't port the HTTP client.** The script pins `image_id`s,
double-searches labels, tolerates 500-after-commit, and reports unlinked tiles
because it is a remote client working around API limits that no longer exist.
This page is in-process Rails. Call `Boards::ImageResolver`, `Images::LabelSearch`
and the models directly. Do **not** have Rails HTTP-call `/api/internal/*`.

## Decisions (already made — don't re-litigate)

1. **Server-rendered ERB admin**, not the React admin. `Admin::VideoBoardsController`
   and `Admin::BoardPrintablesController` both live there; this is the third.
2. **Two-step build: preview, then confirm.** Submitting the form resolves art
   and shows coverage, fuzzy matches, and license flags. **Nothing is written
   until a second, explicit Build click.** This is the single most valuable
   behaviour being ported — a wrong symbol is expensive to fix after the fact.
3. **Boards are created published but NOT `predefined`.** Published so the set is
   live at `/pb/<slug>` and shows up on the printables page the moment it builds;
   not `predefined` so it stays out of `Board.public_boards` — the catalogue is a
   curated surface, and dropping every build into it would bury the library.
   `Admin::BoardPrintablesController` reaches builder boards through
   `AdminBoardBuild.builder_boards` instead. Unpublish is the way back, and it is
   still a set-wide operation. (Originally the reverse — created unpublished,
   published by a separate confirmed action — changed once the printables page
   became the main consumer.)
4. **Boards are owned by `User::DEFAULT_ADMIN_ID`**, not `current_user` — same as
   `Admin::VideoBoardsController#seed_admin`.
5. **Phase 1 is a single board. Phase 3 adds linked child pages.** Build them in
   that order.
6. **AI word-list drafting (Phase 2) only ever populates the form.** It never
   feeds the build directly; a human edits before preview.
7. No new gems, no new ENV vars.

## Current state — what already exists

### The pattern to copy: `Admin::VideoBoardsController`

`app/controllers/admin/video_boards_controller.rb` (~176 lines) is the closest
precedent and its two rails are stated in its own class comment. Copy both:

- **A `SEEDER_SETTING` marker + a scoped finder.** It sets
  `settings["video_seeder"] = true` and every member action goes through
  `seeded_boards` (`Board.where("(settings ->> :key) = 'true'", key: SEEDER_SETTING)`),
  so `destroy`/`publish` can never reach an unrelated board by id. Use
  `settings["admin_builder"] = true` the same way.
- **Nothing is written until every row parses.** `validation_error(form)` returns
  a string or nil; `create` renders `:new` with `:unprocessable_entity` and the
  raw submitted values preserved (`submitted_form`) so the admin doesn't retype.
  It reads raw `params[:...]` rather than strong params — match that.

Its service, `app/services/video_boards/board_seeder.rb`, is `module_function`
style with a `build_board!(cfg, admin:)` entry point. Same shape here.

### The pattern for a long job from ERB admin: `Admin::BoardPrintablesController`

`create` builds a status record, calls `GenerateBoardPrintableJob.perform_async(id)`,
and redirects to `show`, which renders status. Jobs live in **`app/sidekiq/`**
(not `app/jobs/`), plain classes with `include Sidekiq::Job`.

### Image resolution — all of it already exists

- **`Boards::ImageResolver`** (`app/services/boards/image_resolver.rb`).
  `resolve_all(labels, owner:)` batches in 2 queries; `best_arted_for(label, owner)`
  prefers art-bearing images, case-insensitively, owner's first then
  `Image.public_img.where(user_id: [User::DEFAULT_ADMIN_ID, nil])`.
- **🚨 `resolve` and `resolve_all` CREATE a blank `Image` row for any label with
  no match.** The source says so explicitly: *"never call it from a read-only
  path."* **Your preview step must not use them.** Use `Images::LabelSearch` (or
  `best_arted_for`, which is read-only) for the preview, and `resolve_all` only
  inside the build transaction.
- **`Images::LabelSearch`** (`app/services/images/label_search.rb`).
  `new(match:, limit:, commercial_safe:, include_share_alike:, resolve:)`.
  Its `tiers` are lazy and best-first: `resolve` → `literal_matches`
  (`LOWER(label) = LOWER(?)`, ordered by doc count) → `search_by_exact_label` →
  `search_by_label`.
  - **`resolve: true` is exactly what you want for the preview** — it prepends
    "what the resolver would actually attach," and a resolve row is never dropped
    by the `commercial_safe` filter (deliberate: it answers "does art exist at
    all", separately from "may we sell it").
  - `serialize` returns `source_type, license, commercial_safe,
    attribution_required, share_alike, src, original_url, match`.
  - **`src` is nil until the 288px variant is processed.** Never treat nil `src`
    as "no art" — check `original_url`.

The skill's belief that bulk POST and GET search disagree on exact matches is
**stale**; `#585` routed both through `tiers`. Don't port the second-pass loop.

### Colors

`app/helpers/color_helper.rb` — `PRESET_DATA` is the Modified Fitzgerald key
(`part_of_speech` → hex), `PARTS_OF_SPEECH` is the canonical 12-value list, and
`ColorHelper.to_hex(value, default:)` normalizes. `module_function`, so call
`ColorHelper.to_hex(...)`.

**Don't port the script's `bg_color` computation.** It builds Fitzgerald hexes
by hand only because the internal API won't accept `part_of_speech`. In-process
you can set the real attribute and get the color for free — but the timing
matters:

```ruby
board_image = board.add_image(image_id)
raise "image #{image_id} not found" if board_image.nil?   # add_image returns nil on failure
board_image.update!(part_of_speech: pos)                  # fires set_colors
```

`BoardImage#set_colors` is declared `before_update :set_colors, if:
:part_of_speech_changed?` — **`before_update`, so it does not fire on create.**
On the create path colors come from `before_create :set_defaults`, which uses the
*Image's* `bg_color`, not the part of speech. (`Board#add_image` works around
this by calling `set_colors` explicitly before save.) So setting
`part_of_speech` as a separate `update!` after the tile exists is what actually
applies the Modified Fitzgerald color. Don't also pass `bg_color` — the callback
would overwrite it.

Note `Board#add_image(image_id, layout = nil)` returns `nil` rather than raising
on a missing image or a failed save. `Boards::BoardTreeBuilder` guards this with
a raise; do the same, inside the transaction, so a bad id aborts the build
instead of silently producing a short board.

### Columns, rows, layout

- **Rows are never stored.** `Board#rows_for_screen_size` returns `max(y + h)`
  across tiles. So a short final row doesn't create an empty row — it creates
  conspicuous empty cells at the right end of the last one. That is the entire
  reason for the tile-count rule below.
- `Boards::ScreenColumns.derive(lg, screen_size)` — `md ≈ round(lg × 2/3)`,
  `sm ≈ round(lg / 3)` floored at 2. **Set only `large_screen_columns`.** Hand-
  setting md/sm writes `settings["custom_screen_layouts"]` and permanently stops
  reflow. (Note `VideoBoards::BoardSeeder` sets all four equal — do *not* copy
  that part.)
- `Board#set_screen_sizes` (`before_create`) defaults `large_screen_columns` to
  **8** when nil. Always set it explicitly.
- `Board#apply_layout!(layout:, screen_size:, columns:, margins:, settings:)` —
  `layout` items are **string-keyed** (`"i"`, `"x"`, `"y"`, `"w"`, `"h"`) where
  `"i"` is the **BoardImage** id, but `columns:`/`margins:` are read with
  **symbol** keys. It sorts by `[y, x]` and rewrites each tile's `position`, so
  the layout — not creation order — determines final tile order.
- `Board#open_grid_cells(screen_size)` is the existing density primitive.

### Other behaviour worth knowing before it surprises you

- **Linked children drop out of internal board search.** Setting
  `predictive_board_id` flips `Board#check_is_sub_board`, and
  `Boards::AdminSearch.base_scope` filters both `sub_board: [false, nil]` and
  `.not_builder_child`. Expected; fetch children by id, and don't build the
  admin index page on top of `AdminSearch` or Phase 3's children will vanish
  from it.
- **Slug collisions get a hex suffix** — `generate_unique_slug` appends
  `SecureRandom.hex(4)` rather than erroring, so building "At the Park" twice
  silently produces `at-the-park-a1b2c3d4`. Surface the final slug in the UI;
  a printed QR target depends on it. (It assigns only — the caller saves.)
- **`VoiceService.normalize_voice` passes through any string containing a colon
  without validating it.** `polly:kevn` saves fine and only fails later at audio
  synthesis. Constrain voice to a select box; don't take free text.
- Setting `voice` on a Board cascades to tiles and re-queues audio — set it at
  create time rather than patching after.
- **The authoring form must stay `data: { turbo: false }`.** `suggest`, `draft`
  and `preview` all answer a POST with a rendered 200, because each hands the
  admin's own submission back to them. Turbo Drive refuses a 2xx form response
  that isn't a redirect (`Form responses must redirect to another location`),
  throws, and leaves the page untouched — so with Turbo on, every button on the
  form is a silent no-op. Request specs can't see this: they assert the rendered
  body and never run Turbo. A spec asserts the attribute is present instead.

## Work items

### Phase 1 — single board, manual word list

#### 1. `AdminBoardBuild` model + migration

```ruby
create_table :admin_board_builds do |t|
  t.references :board, foreign_key: true                 # null until built
  t.references :created_by, foreign_key: { to_table: :users }
  t.string  :status, null: false, default: "pending"     # pending/building/complete/failed
  t.string  :name, null: false
  t.string  :topic
  t.integer :columns_count, null: false
  t.integer :rows_count, null: false
  t.boolean :commercial_safe_only, null: false, default: true
  t.jsonb   :plan, null: false, default: {}              # the authored tiles
  t.jsonb   :art_report, null: false, default: {}        # coverage at build time
  t.text    :error_message
  t.timestamps
end
add_index :admin_board_builds, [:status, :created_at]
```

Persisting `plan` and `art_report` is what makes a failed build re-runnable
without re-authoring, and gives the `show` page something to render.

#### 2. `Boards::AdminBuilder::PlanValidator`

Port of the script's `validate()` (build_board.py:103–173). Returns an array of
human-readable problem strings; empty means safe to build.

- **`tiles.length` must equal `columns × rows`.** Reject otherwise with a message
  naming how many to add or remove. This is the rule the whole feature exists
  for — a partial final row reads as broken on a classroom TV. Provide an
  explicit "allow a partial row" checkbox as the escape hatch, unchecked.
- Every tile needs a non-empty label.
- Duplicate labels are an error, not a warning — each one costs a cell and buys
  nothing.
- `part_of_speech` must be in `ColorHelper::PARTS_OF_SPEECH`.

#### 3. `Boards::AdminBuilder::ArtPreview` — **read-only**

Input: labels + `commercial_safe_only`. Output per label:
`{ label, image_id, matched_label, exact:, license:, commercial_safe:, src: }`
plus aggregate `coverage_pct`, `missing[]`, `inexact[]`.

- Use `Images::LabelSearch.new(commercial_safe:, resolve: true).call(label)`.
- **Exact vs. fuzzy is the point.** A hit whose own label differs from the
  requested word is a judgment call, not a match — the classic failure is `my`
  resolving to art labeled *"too tired to speak as it uses a lot of my energy…"*.
  Surface every one for review; don't silently accept.
- **Write nothing.** No `ImageResolver.resolve`, no `Image.create`.
- Render the resolved symbols as an actual image grid, not just a table of
  labels. Coverage numbers don't show that a symbol is technically correct and
  visually wrong.

#### 4. `Boards::AdminBuilder::Build` + `BuildAdminBoardJob`

Inside one transaction:

1. `Boards::ImageResolver.resolve_all(labels, owner: seed_admin)` — here it's
   correct that misses create blank Images; those are what generation targets.
2. Create the board: `board_type: "static"`, `voice`, `large_screen_columns`,
   `settings: { "admin_builder" => true, "disable_scroll" => true }`,
   `user: seed_admin`, `published: true`, `predefined: false`.
3. Add tiles in authored order via `Board#add_image(image_id)` (guarding the nil
   return), then `update!(part_of_speech:)` per the Colors section above, plus
   `display_label` when given.
4. `apply_layout!` with reading-order coordinates:
   `{ "i" => board_image.id.to_s, "x" => idx % cols, "y" => idx / cols, "w" => 1, "h" => 1 }`.

After commit (not inside it), queue art for labels that resolved to a blank
Image: `Image.where(id: ids).where.missing(:docs)`, in slices of 3, via
`GenerateImagesJob.perform_async(batch, board.id)` — matching
`API::Internal::BoardImagesController#queue_missing_art!`.

**Use a topic-aware prompt**, not a bare label. This is the difference between
*swing* on a playground board and a mood swing. The script's prompt
(build_board.py:424–428) is worth lifting near-verbatim.

Set `status: "failed"` with `error_message` on rescue, then re-raise so Sidekiq
retries.

#### 5. `Admin::BoardBuildsController`

Routes go inside the existing `namespace :admin` block, following the local
`as: :dashboard_*` convention:

```ruby
resources :board_builds, only: [:index, :new, :create, :show, :destroy],
          as: :dashboard_board_builds do
  collection { post :preview }
  member     { post :publish; post :unpublish }
end
```

| Action | Does |
|---|---|
| `new` | blank form: name, topic, columns select, voice select, word rows |
| `preview` | validate → resolve art read-only → render the review screen. **No writes.** |
| `create` | re-validate, create the `AdminBoardBuild`, `perform_async`, redirect to `show` |
| `show` | status, resulting board link + slug, art coverage |
| `publish` | separate + confirmed; refuse if the board has no tiles |

Re-validate in `create`. The preview round-trip is a hidden-field resubmit and
must not be trusted.

Add a nav link in `app/views/layouts/admin.html.erb` and a card on
`app/views/admin/dashboard/index.html.erb`. Design tokens are already defined in
the admin layout: `admin-card`, `admin-card-alt`, `admin-input`, `text-t1/t2/t3`,
`text-accent`, `admin-hover-row`, `admin-flash-ok/err`. Active nav state idiom is
`request.path.start_with?("/admin/…")`.

### Phase 2 — `Boards::AdminBuilder::WordListDrafter`

Topic + `columns × rows` + optional audience → `[{ label:, part_of_speech: }]`.

**Write a new prompt; don't compose the existing pieces.**
`Board#get_words_for_scenario` needs a persisted Board and returns bare strings,
and `AacWordCategorizer.categorize` is one OpenAI call *per word* — composing
them is an N+1 against an API. One call returning both fields is the whole job.

Use `OpenAiClient` (it's at **`app/models/open_ai_client.rb`**, not
`app/services/`) with `GTP_MODEL`. Follow `Boards::AiPageGenerator`'s shape
exactly — `OpenAiClient.new(messages: [...])`, `create_chat(true)` for a JSON
response, `JSON.parse`, and a `GenerationError` raised on both a blank response
and a parse failure. Tolerate `"word"` as an alias for `"label"` in the response
the way its `parse_response` does.

The prompt must carry the skill's actual authoring rules, or the output will be
a noun list: the core spine (`I, you, it, want, go, stop, more, help, like, not,
yes, all done, look, my turn, what, where`) placed first; a rough balance of
30–40% verbs and core function words, 15–20% pronouns/determiners, 15–20%
describing words, 25–35% topic nouns; no near-duplicates; and **exactly**
`columns × rows` entries.

No credit charge — admin-owned. Populate the form; never build from it directly.

#### Per-page drafting — `Boards::AdminBuilder::PageDrafter`

Page title + tile count (+ board topic/audience as optional context) →
`[{ label:, part_of_speech:, links_to: }]` for **one** child page. Backs the
`Draft this page with AI` button in each page block; `draft_page` merges the
result into `children[page_index]` only, so the root and every sibling survive.

Not `WordListDrafter` with a different topic, and not a slice of `SetDrafter`:

- The page title is the subject, and it's the one input that can't be inferred —
  `draft_page` rejects a nameless page rather than guessing. The `key` stands in
  only when there's no title, underscores folded back to spaces.
- **No `CORE_SPINE`.** The root carries the core words the whole set leans on; a
  page that repeats "I / want / more / help" spends its cells twice.
- **Exactly one `back` tile linking to `Plan::ROOT_KEY`**, counted toward the
  page's tile count. `link_for` drops every other target: this drafter is given
  one page and knows no other page's key, and `PlanValidator` rejects a link to
  a key that isn't in the set.
- Tile count is the page's own override when set, else the root's — what the
  page will actually be built at.

**No `MAX_PAGES` ceiling here**, unlike `SetDrafter`. One page per call is the
accurate way to draft a set larger than `SetDrafter::MAX_PAGES`, where a single
long response starts dropping per-page tile counts.

The button posts its index as the submit's `name="page_index"` value rather than
a field, so `reindexPages()` has to rewrite that `value` alongside the field
`name`s — renumbering names alone leaves a moved block drafting into whichever
page took its old position.

#### Page names are authored input — `Boards::AdminBuilder::PageNamesSuggester`

**A page key or name on the form is never overwritten by a drafter.** It decides
what `SetDrafter` writes and, once built, it is the sub-board's name — so
`draft_set` passes the named pages through as `pages:` and the model only names
the blanks. Two consequences to keep:

- The pinned keys go **into the prompt**, not merged in afterwards: the root's
  folder tiles carry `links_to` per page, so a key invented by the model and
  renamed later would leave the root linking at nothing. `apply_pinned` is the
  backstop for a paraphrased answer — it matches on key, falls back to position,
  and forces the admin's key/name back on.
- Naming more pages than `page_count` **raises the count** (capped at
  `MAX_PAGES`) rather than dropping the extra names; the drafter echoes the
  count it actually used back as `page_count:` so the notice and the select
  follow it.

`PageNamesSuggester` is the names-only half: topic/name/audience + a count →
`[{ key:, name: }]`, no words, `ContextSuggester`'s shape throughout. Pages the
admin already named are repeated back in place and never duplicated, and the
call is skipped entirely when they already fill the count. `suggest_pages` drops
the suggestions onto blank blocks **where they sit** — assigning by position in
the suggestion would land a name on a block that already holds another page's
word list.

`Keys.normalize` is the one slugifier for all of this; a second copy is how a
`>key` link silently resolves to nothing.

### Phase 3 — linked child pages

- Plan gains `children: [{ key, name, tiles }]` and tiles gain `links_to`.
- **Every board in the set shares the root's grid.** A communicator shouldn't
  have cell size change under their finger mid-navigation. `--allow-mixed-grids`
  becomes a checkbox needing an explicit tick.
- Build order: create a board only after everything it links to exists. Cycles
  are normal — a child usually has a "back to home" tile. Break cycles at the
  **back** edge, never at a root→child edge. Port `build_order()`
  (build_board.py:176–215) rather than re-deriving it.
- Set the link with `board_image.update!(predictive_board_id: child.id)` —
  `Boards::BoardTreeBuilder` already does exactly this.

### Phase 4 — verify + publish

`status: "complete"` means the board record finished writing. It says nothing
about whether any tile has a picture, which is the failure this whole feature
exists to prevent. On `show`, report tiles whose Image has no doc
(`Image.where(id: board.board_images.select(:image_id)).where.missing(:docs)`)
and surface `Board#has_generating_images?` so a half-generated board is
obviously mid-flight rather than broken.

## Testing

Request specs in `spec/requests/admin/`. **`spec/requests/admin/video_boards_spec.rb`
is the direct precedent — read it first.** Note its required setup:

```ruby
include Devise::Test::IntegrationHelpers
let!(:seed_admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

before do
  allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
  allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
end
```

(The asset stubbing is required — the admin layout calls `stylesheet_link_tag`.)

Authorization matrix — prove every row:

| Caller | Expect |
|---|---|
| signed out | redirect to sign-in, nothing written |
| `role: "user"` | redirect to `root_path`, nothing written |
| `role: "admin"` | 200 |
| admin, `publish` on a board this page didn't create | not found / redirect — prove the `admin_builder` scoping holds |

Behaviour to prove:

- **`preview` writes nothing** — assert `.not_to change(Board, :count)` *and*
  `.not_to change(Image, :count)`. The `Image` half is the one that will actually
  catch a regression, since `ImageResolver.resolve_all` creates rows.
- tile count ≠ `columns × rows` → re-renders `:new`, 422, nothing written, and
  the submitted values are still in the form
- duplicate labels rejected; unknown `part_of_speech` rejected
- happy path → `published == true`, `predefined == false`, `user_id == DEFAULT_ADMIN_ID`,
  `settings["admin_builder"] == true`, `large_screen_columns` as chosen, and
  md/sm derived by `ScreenColumns` rather than set equal to lg
- tiles land in authored reading order after `apply_layout!`
- a label with no art → blank Image created, generation queued **after** commit,
  in slices of 3
- job failure → `status: "failed"` with `error_message`
- publish refuses a board with no tiles
- Phase 3: children created before root; a back-edge to root doesn't deadlock;
  child grid ≠ root grid rejected unless the override is ticked

Add a service spec for `PlanValidator` and for the Phase 3 build ordering
specifically — both are pure, cheap to test in isolation, and the likeliest to
regress.

Stub OpenAI in Phase 2 specs; never let a spec make a real call.

Run `bundle exec rspec spec/requests/admin spec/services/boards` before opening
the PR.

## Deploy notes

- One migration (`admin_board_builds`). No backfill.
- No new gems. No new ENV vars.
- Ships in phases; Phase 1 is independently useful and independently
  releasable.
- Requires `User::DEFAULT_ADMIN_ID` to exist in every environment it runs in —
  `Admin::VideoBoardsController#require_seed_admin!` already guards this; copy it.

## Wrap-up

Follow this repo's CLAUDE.md for git workflow and conventions. Open the PR and
stop — never merge. Commit this doc in the PR so it survives the session.
Consider a short entry in `.claude-notes/board-builder.md` noting that an
admin-side builder now exists alongside the user-facing wizard, so the two don't
get confused later.
