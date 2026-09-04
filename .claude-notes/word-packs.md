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
