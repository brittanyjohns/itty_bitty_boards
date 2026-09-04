# Quick-add word packs

Curated static sets of words a user drops onto a board in one action from the
frontend's Add-tiles modal: pronouns, action words, greetings, numbers, plus
menu-only sets (sizes, condiments, ordering phrases) on a restaurant-menu board.

- Catalog: `app/services/boards/word_packs.rb`
- Read: `GET /api/word_packs[?board_id=]` — `API::WordPacksController`
- Write: `POST /api/boards/:id/add_word_pack` — `API::BoardsController#add_word_pack`
- Frontend mirror: `itty-bitty-frontend/src/data/word_packs.ts`

## The contract: a pack costs nothing

Adding a word normally fires OpenAI **twice**, and neither call is
credit-gated:

1. `Image#ensure_defaults` calls `AacWordCategorizer.categorize` for a new image
   with no authored `part_of_speech` — a **synchronous** chat call, inside the
   request, per novel word. `OVERRIDES` covers 37 words, so `he`, `medium` and
   `ketchup` all miss it.
2. `Board#find_or_create_images_from_word_list` queues `GenerateImagesJob`
   (DALL·E) for every word with no art in the library.

Packs avoid both, and the result is *better* than the paid path, not just
cheaper:

- The pack declares its own `part_of_speech`, passed through the new
  `parts_of_speech:` kwarg (same `normalized word => value` shape as the
  existing `menu_prompts:`). `ensure_defaults` takes the explicit-POS branch, so
  no categorizer call — and `Board#add_image` copies that POS onto the tile and
  runs `set_colors`, giving the *authored* Fitzgerald colour rather than an LLM
  guess.
- The controller passes `max_generate: 0`, so no `GenerateImagesJob` is ever
  enqueued. A word with no library art lands as a picture-less tile; the client
  says which words those are before the add.

`spec/requests/api/boards_add_word_pack_spec.rb` pins all of it — no
`CreditTransaction`, no `GenerateImagesJob`, no `AacWordCategorizer.categorize`.
If that spec blocks a change, the spec is right.

## Invariants

- **The client names a pack KEY; the server owns the vocabulary and the part of
  speech.** `WordPacks.requested_words` intersects the caller's word list with
  the pack's own, dropping anything else — so a caller can neither invent labels
  nor smuggle a `part_of_speech` past the categorizer. Same rule
  `Suggestions::Registry` follows (`.claude-notes/writing-suggestions.md`).
- **`AacWordCategorizer::OVERRIDES` wins over a pack's declared POS.** That
  table encodes deliberate AAC-functional choices a grammatical label gets wrong
  — `stop` and `no` are protests (`important_function`), not a verb and not a
  social word — and an authored POS silently beats the categorizer. Deferring to
  it in `part_of_speech_map` makes a contradiction impossible to author, rather
  than something a spec has to catch. Same table, same reason,
  `Boards::TileArrangement` already consults before banding.
- **`VALID_PARTS_OF_SPEECH` is `ColorHelper::PARTS_OF_SPEECH` plus `"phrase"`,
  interpolated and never restated.** The colour switch ends in `else "gray"`, so
  an unrecognised value miscolours silently instead of failing. `"phrase"` is
  the one legitimate non-Fitzgerald value — `ensure_defaults` has a branch for
  it, and it is what keeps the multi-word ordering pack off the categorizer.
- **The catalog GET creates nothing.** It fires on every open of the modal, so
  art lookup goes through `Boards::ImageResolver.arted_all_for` — the read-only
  batch form, two queries however many words — never `resolve_all`, which
  creates a blank `Image` for a label with no match anywhere.
- **Thumbnails read the `src_url` COLUMN first.** `display_image_url` is two
  queries an image (`user_docs`, then `docs.for_user`); across every word of
  every pack that is ~200 on one modal open. `update_src_url` is a `before_save`
  guarded on the column being blank, so a row with art that has never been
  re-saved falls back to the real lookup rather than being reported
  picture-less.
- **On a menu board the authored part of speech is deliberately ignored.** A
  menu board is not an AAC board — its tiles are white and look up no part of
  speech — so a word with no library match takes
  `find_or_create_images_from_word_list`'s `is_a_menu?` branch and becomes a
  private `image_type: "menu"` image instead. That path skips the categorizer
  too (`ensure_defaults` short-circuits menu images to `"noun"`), so packs stay
  free either way; only the colour differs.
- **The authored part of speech lands on the TILE, not just on a new Image.**
  A matched library image can carry a stale or blank POS — `she` was stored
  `default`, so it came out grey next to a yellow `he` — and `Board#add_image`
  copies `@image.part_of_speech || "default"` onto the tile.
  `Board#apply_authored_part_of_speech!` pins the pack's value on the tile and
  re-runs `set_colors`, and never writes it back to the shared `images` row:
  that row is on thousands of other boards, so a per-board answer belongs to the
  tile. `set_colors` reads `effective_part_of_speech` and already resolves a
  menu tile to white, so the menu rule survives untouched.
- **"Already on this board" is `WordPacks.placed_keys`, never
  `Board#current_word_list`.** That reader serves a cached
  `data["current_word_list"]` whenever one is present, and **nothing invalidates
  it when a tile is destroyed** — so a word the user deleted still reads as
  placed. Through this feature that greys the word out in the picker AND makes
  the add skip it, with no way to get it back. `placed_keys` reads the tiles in
  one query. The catalog and the add MUST use the same answer, or the picker
  offers a word the add drops on the floor.
- **Ownership needs its own gate.** `User#board_editable?` returns **true** for
  a board you don't own — it measures the PLAN lock, not permission — so
  `add_word_pack` is in `check_board_view_edit_permissions` (declared before
  `check_board_editable!`), the same gate `update` and `destroy` use.

## Known, pre-existing, not fixed here

Both predate this feature and are worth their own issues:

- `PUT /api/boards/:id` with a `word_list` fires `GenerateImagesJob` **and** a
  per-word synchronous `AacWordCategorizer.categorize`, with no `check_credits!`
  anywhere. Real spend on a path with no ceiling.
- `Image.create(label: word)` in `find_or_create_images_from_word_list` creates
  images with **no `user_id`**, unlike `ImageResolver.resolve` which sets one —
  orphan rows in the shared library.
- `Board#current_word_list`'s cached `data["current_word_list"]` is never
  invalidated when a tile is destroyed. `boards#update`'s own `word_list` dedupe
  reads it, so the same "can't re-add a deleted word" bug is live on the
  textarea path. `placed_keys` sidesteps it here rather than fixing it
  everywhere.
- `Board#api_view_with_images` / `#api_view_for_native_grid` serialize
  `part_of_speech: @image.part_of_speech` — the SHARED image's, sitting among
  `@board_image.*` fields — so the payload reports `default` for a tile stored
  and rendered as `pronoun`. App-wide and pre-existing; the tile row and its
  colour are correct.
