# Admin Board Builder — AI set drafting, description and tags

Design for the next round of `/admin/board_builds`
(`Admin::BoardBuildsController`). Three AI features plus four gaps closed in
the surrounding page.

## Background

The admin Board Builder authors a dense AAC board from a word list, shows the
symbol art for review, then builds. Three AI touch points exist today, all
governed by one rail:

> **AI only ever fills the form.** A human edits it, previews the art, then
> builds.

- `Boards::AdminBuilder::ContextSuggester` — infers name, topic, audience
- `Boards::AdminBuilder::WordListDrafter` — drafts the root word list
- Child pages exist, but their keys, names and word lists are typed by hand,
  and the `>key` link tokens on the root list are hand-added

Everything in this design keeps that rail. No new AI path writes a record.

### What the builder does not do today

- **Never sets `boards.tags`.** Tags are load-bearing for the public
  catalogue — `Api::BoardsController` exposes `Board.public_boards_tags` and
  filters with `with_any_tags` / `with_all_tags` — so every board the builder
  publishes is invisible to the tag filter.
- **Never sets `boards.description`.**
- **Never persists `audience`.** The form says so out loud: "Not saved on the
  board."
- **Offers no way back into the form.** Publish, unpublish and delete are the
  only member actions, so every revision is a full re-type.

## Constraints discovered in the code

These are not preferences; they decide the shape of the work.

1. **`PlanValidator` requires every page to exactly fill its grid**, and
   **every child page to share the root's grid**. A whole-set draft for a 6×4
   root with three pages is therefore 24 + 72 = 96 tiles, and children must
   carry no grid of their own. A short draft is survivable — `WordListDrafter`
   already treats it that way and the form's counter shows the gap — but the
   prompt must be given the exact per-page count.
2. **`board.description` renders as plain text on three of four frontend
   surfaces** (`ViewBoard.tsx:564`, `HelpScreen.tsx:199`,
   `MySpeakOnboardingPage.tsx:671`) and as raw HTML on one
   (`PresetBoardModal.tsx:110`). The existing `Board#get_description` produces
   semantic HTML, which would render as literal `<h2>Purpose</h2>` on three of
   them. Plain text is correct everywhere.
3. **No board tag vocabulary exists in code.** The only tag literals anywhere
   are `"myspeak"` and `"myspeak-recommended"`; the real vocabulary lives only
   as production data. A hardcoded allow-list would drift on day one.
4. **`Board.normalize_tag_value` lowercases and squeezes whitespace.** Any tag
   this feature writes goes through it.
5. **`PlanValidator` checks duplicate labels per page, not across the set.**
   The same word appearing on the root and on a child (`back`, `more`) is
   expected and stays legal.

## Feature 1 — `Boards::AdminBuilder::WordList` (enabling refactor)

A module with `.parse(text)` and `.render(tiles)`. `parse_tiles` moves out of
`Admin::BoardBuildsController` unchanged.

This is not housekeeping. Two features below need it:

- `SetDrafter` must **emit** `>key` link tokens into the textarea.
- Duplicate-into-form must round-trip `display_label` and `links_to`, both of
  which today's `tiles_to_words` silently drops — it emits only
  `label | part_of_speech`.

`.render` emits `label | part_of_speech | display text | >key`, omitting
trailing empty fields so a plain tile stays a plain line. Because `.parse`
finds the link field by its `>` prefix wherever it appears, a tile with a link
but no display text renders as `Food | noun | >food` and parses back
identically.

**Test:** a round-trip property spec — `parse(render(tiles)) == tiles` across
tiles with every combination of `display_label` and `links_to` present or
absent.

## Feature 2 — `Boards::AdminBuilder::SetDrafter`

A new service beside `WordListDrafter`, which stays for single-board drafts.
Surfaced as a new button with a page-count select (0–4).

**Input:** topic, audience, root columns and rows, page count. When topic is
blank it is inferred through `ContextSuggester` first, exactly as the existing
`draft` action does. A page count of 0 is legal and means a single-page set —
the service delegates to `WordListDrafter` rather than asking a second prompt
for the same thing.

**Output:** `{ root_tiles:, children: [{ key:, name:, tiles: }] }`. Children
carry **no** `columns` or `rows`, so `PlanValidator#grid_problems` is quiet by
construction rather than by luck.

**The prompt asks for:**

- exactly `columns × rows` tiles per page, root and children alike
- one folder tile on the root per requested page, carrying that page's
  `links_to`
- a "back" tile on every child pointing at `Plan::ROOT_KEY`
- page keys matching `/\A[a-z0-9_]+\z/`
- a `part_of_speech` for every tile from `ColorHelper::PARTS_OF_SPEECH`

**The response is never trusted.** After parsing:

- page keys are normalized; children with a blank key are dropped
- a `links_to` naming an unknown key is dropped from the tile
- tiles are deduped per page, case-insensitively (`images.label` is a
  lowercase matching key, so "Go" and "go" are one symbol)
- an unrecognized `part_of_speech` becomes `"default"`
- each page is truncated to its cell count

Only a response with nothing usable in it raises `GenerationError`. A short
draft fills the form and the counter shows the gap, matching `WordListDrafter`.

**Writes nothing.** The result populates the root textarea and the page blocks.

## Feature 3 — `Boards::AdminBuilder::MetadataSuggester`

Returns `{ description:, tags: [] }` for the board currently described by the
form.

**Deliberately a separate action rather than part of the draft.** The admin
edits the word list after drafting; a description generated from the pre-edit
list would be stale the moment it arrived. The button reads current form state
— name, topic, audience, page names, and the labels across the whole set.

**Description:** plain text, one to two sentences, capped at 300 characters,
no HTML, and it does not list the words on the board.

**Tags:** the prompt is handed the live `Board.public_boards_tags` as "reuse
these where they fit" — sorted alphabetically and truncated to the first 60, so
the prompt is deterministic and bounded. At most 2 genuinely
new tags. At most 6 total. Each is run through `Board.normalize_tag_value`,
capped at 30 characters, and dropped if blank after normalization.

**Form:** a description textarea and a comma-separated tags text field,
following the `Admin::VideoBoardsController` precedent for a tags string.

**Applied to the root board only.** Child pages are created with
`predefined: false`, so they are not in the public catalogue; tagging them
would fill `public_boards_tags` with folder-page noise. Description likewise.

### Migration

`admin_board_builds` gains:

| Column | Type | Default |
|---|---|---|
| `description` | `text` | — |
| `tags` | `varchar[]` | `[]`, not null |
| `audience` | `string` | — |

Columns rather than keys inside `plan`, matching how `name`, `topic` and
`voice` are already stored. Persisting `audience` is what makes a description
regenerable and a duplicated build faithful.

`Boards::AdminBuilder::Build#new_board` applies `description` and `tags` to the
root board only.

## Feature 4 — Duplicate an existing build into the form

`GET /admin/board_builds/:id/duplicate` renders `new` with the form rehydrated
from `build.pages` plus the three new columns. The word lists are produced by
`WordList.render`, so links and display text survive the trip.

The name is copied verbatim; Feature 6 catches the collision at preview rather
than forcing an edit up front.

## Feature 5 — Edit description and tags after a build

`PATCH /admin/board_builds/:id` updates **only** `description` and `tags`, on
the build row and on the root board. The board is reached through
`AdminBoardBuild.builder_boards`, the same scoping every other member action
uses, so a hand-edited `board_id` cannot turn this into a lever on an
unrelated board. The word list stays immutable — fixing words is still
delete-and-rebuild, or the main app's board editor.

Rendered as a small inline form on `show`.

## Feature 6 — Duplicate-name warning at preview

At preview, look for boards whose name matches the submitted name
case-insensitively, and render a non-blocking banner listing them with links.
Two scopes are searched: `Board.public_boards`, and
`AdminBoardBuild.builder_boards` — the second so a board built here last week
and still awaiting review is caught too, not just published ones.

**Never blocks.** Two boards with one name is sometimes correct; shipping it by
accident is the thing worth catching.

## Feature 7 — Re-queue missing art

`POST /admin/board_builds/:id/regenerate_art` recomputes the art-less image
ids across `build.set_boards` using the same `where.missing(:docs)` query
`missing_art_count` already uses, seeds `image_prompt` where blank from the
build's topic, and queues `GenerateImagesJob` in slices of
`Build::GENERATE_BATCH_SIZE`.

The seeding and batch-queueing move out of `Boards::AdminBuilder::Build` into
one small shared object so the two paths cannot drift. The `image_prompt`
carries **intent only** — `Images::PromptBuilder` composes the house style
envelope at generation time, and baking it in here would wrap it twice.

## Testing

- **Request spec per new action**, OpenAI stubbed: set draft, metadata
  suggest, duplicate, update, regenerate art.
- **Unit spec per service** off fixture JSON: happy path; malformed JSON
  raises `GenerationError`; unknown part of speech coerced to `default`; a
  `links_to` naming an unknown page dropped; tags normalized, capped at 6, and
  limited to 2 new values against a supplied vocabulary.
- **Round-trip property spec** for `WordList`.
- **Existing rails re-asserted:** preview still changes neither `Board.count`
  nor `Image.count`; duplicate, update and regenerate are each scoped through
  `AdminBoardBuild.builder_boards`.
- Specs that reach `User::DEFAULT_ADMIN_ID` follow the repo rule:
  `User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)`.

## Documentation

- `.claude-notes/board-builder.md` — the admin builder section gains the new
  services and the root-only tagging rule.
- `CHANGELOG.md` — one entry per PR.

## Phasing

Three PRs, each shippable on its own:

1. `WordList` extraction + `SetDrafter`
2. `MetadataSuggester` + migration + form fields + build wiring + post-build
   edit (Features 3 and 5)
3. Duplicate-into-form, duplicate-name warning, re-queue art (Features 4, 6, 7)

## Out of scope

- Editing a built board's word list from this page.
- Replacing `Board#get_description` or its HTML output anywhere else in the
  app — this design ignores it rather than changing it.
- A board thumbnail / `display_image_url` for admin-built boards. `Board`'s
  display-image callbacks are commented out (`app/models/board.rb:204`), so
  admin-built boards may reach the public catalogue with no cover image. Worth
  confirming separately; not part of this work.
