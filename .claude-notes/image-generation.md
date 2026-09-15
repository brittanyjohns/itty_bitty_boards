# Reference: AI image generation (tile art)

**Type:** durable subsystem reference (spoke of the root `CLAUDE.md` hub)

Covers how a word becomes tile art: prompt composition, the OpenAI call, and
where the result lands. Board *content* generation (which words go on a board)
is a different subsystem — see `.claude-notes/board-builder.md`.

## The invariant: one prompt builder, always wrapping

`Images::PromptBuilder` (`app/services/images/prompt_builder.rb`) is the **single
source of truth** for every text-to-image prompt. Before it existed, six methods
each defined their own contradictory house style ("no stylization" vs
"clipart-style" vs "simple cartoon illustration" vs "avoid cartoonish styles"),
so tiles on one board could not look like a set. Do not add a seventh — extend
the builder.

The builder **always wraps**. A user's typed prompt is the *subject*; it never
replaces the envelope. There used to be a length heuristic in
`images_controller#generate` that let any prompt longer than the label escape
styling entirely — that is the failure mode this design exists to prevent.

Prompt layers, in order:

1. **Subject** — `user_input` if given, else `label`
2. **Disambiguation** — from `part_of_speech`, only when it adds information
3. **Appearance modifiers** — the bulk editor's "apply to every selected tile"
   field, when one was sent
4. **Style spec** — `STYLES[:symbol]` or `STYLES[:illustrated]`
5. **Hard constraints** — always: no text/letters/numbers, single centered
   subject, background rule

The only bypass is `raw_prompt: true`, gated to admins via the
`[[REPLACE_LABEL]]` marker in `images_controller#generate`.

### Modifiers never replace the subject, and never come last

`modifiers` describes how a picture LOOKS — skin tone, contrast, line weight —
and is a separate layer precisely because `user_input` is the *subject*. Bulk
text sent down the subject path regenerates every selected tile as a picture of
the phrase itself instead of its own word, which is the whole failure the layer
exists to avoid. `MODIFIERS_GUARD` restates that to the model in the prompt, for
the same reason: a modifier phrased as a noun ("a brown-skinned child") reads as
a subject without it.

It sits **before** the style spec so the house style stays the last and
therefore most authoritative instruction. A modifier that contradicts it
("watercolor", "photorealistic") loses — a board whose tiles no longer match
each other is worse than an instruction the model only partly honours.

### `sanitize_user_text` is where non-admin free text is made safe

`Images::PromptBuilder.sanitize_user_text` strips `[[...]]` and control
characters, squishes, truncates and terminates. The `[[...]]` strip is the
load-bearing part: `[[REPLACE_LABEL]]` is the admin-only raw-prompt escape
hatch above, and the bulk fields are the first place a NON-admin's free text
reaches the composer — in bulk, across a whole board. Control characters go for
the same reason a newline is dangerous in any templated prompt: it lets a user
visually "end" ours and start their own.

Truncation, not refusal: `regenerate_images` charges before composing, so
refusing an over-long field would fail a batch the caller has already paid for.
The response reports `modifiers_applied` so the client can show what went out.

## `image_prompt` stores intent, never the composed prompt

`Image#image_prompt` holds **the user's subject description**. The full prompt is
composed at call time and passed to `create_image_doc`. Persisting the composed
prompt would make each regeneration wrap the previous envelope inside a new one.
`GenerateImageJob` and `GenerateImagesJob` both follow this split — keep it.

Modifiers follow the same split one step further: they are **request-scoped and
never persisted at all**, not even as intent. Storing them would re-wrap one
run's styling into every future regeneration of that tile. The visible
consequence is that a later single-tile regenerate drops them and that tile
falls out of the set — deliberate, and the reason a board-level sticky setting
(`board.settings["image_modifiers"]`) is the eventual answer rather than a
persisted column.

Menu items are the exception: they carry their own complete prompt in
`image_prompt` (set from the vision parse in `Menu#create_images_from_description`)
and bypass the builder. A dish should look like appetizing food photography, not
a flat AAC symbol.

## Part of speech is the homograph fix

`AacWordCategorizer` already computes `part_of_speech` to color the tile. The
builder puts that signal to work a second time via `POS_CLAUSES`: without it,
*can / orange / watch / left / back / second / fly / ring* render as the wrong
concept. Categories carrying no useful visual instruction (conjunction,
determiner, default) are deliberately absent — a nil clause is dropped.

The POS clause is **skipped when the user wrote their own description** — their
words are more specific, and stacking both yields contradictory instructions.

## Communicator likeness (how the people in the art look)

A communicator can carry a **likeness**: skin tone, hair color and style, gender
presentation, and extras (glasses, hearing aids, wheelchair, walker, hijab,
turban, kippah, braces, AAC device). `CommunicatorLikeness`
(`app/services/communicator_likeness.rb`) owns all of it.

- **Tokens in, prose out.** Storage and the API carry allowlisted tokens only;
  every sentence the image model sees comes from phrases the class owns
  (`#prompt_clause(age_band:)`). Unknown tokens are dropped, not rejected, like
  `resolve_style`. Labels live in `config/locales/likeness.{en,es}.yml` and are
  served on `GET /api/likeness_options` (no auth, like `/api/age_bands`); a
  label can change without changing a single generated picture.
- **The one write-in: `custom_extras`.** Up to `CUSTOM_EXTRAS_MAX_ITEMS` (3)
  short descriptions for a look the preset extras don't cover ("cochlear
  implant"). They are the only user words in the clause, appended as their own
  sentence ("Their look also includes: …") before `PROMPT_GUARD`. Each must be
  ≤ `CUSTOM_EXTRA_MAX_LENGTH` (40) characters from `CUSTOM_EXTRA_CHARACTERS`
  (letters, marks, digits, space, apostrophe, period, hyphen — no comma, since
  the clause joins on one) and contain a letter; a failing value is DROPPED
  whole, never trimmed. A write-in naming a preset becomes the preset token.
  The options endpoint serves the caps and the character class verbatim
  (`custom_extras`), so the picker enforces exactly what the save keeps. They
  count toward `#fingerprint` and appear in `#label`. The refusal retry in
  `GenerateImageJob` strips them (`Result#without_custom_extras`) and stamps the
  doc with the look it actually drew — nil when the write-ins were the whole
  look.
- **Where it lives.** `child_accounts.settings["likeness"]` — `settings` merges
  on update, and the picker replaces this one sub-hash whole.
  `boards.settings["likeness"]` is a per-board override: a likeness,
  `{"mode" => "none"}` to switch it off, or no key to inherit. Both are
  normalized in a model callback (`boards#update` merges `settings` unfiltered).
- **Who sees it.** It describes what a person looks like, so payloads only carry
  it to an editor: `ChildAccount#settings_for` (gated on `editable_by?`, like the
  passcode) and `Board#settings_for` (gated on `can_edit_for` — a published
  board is served to anyone). Use `settings_for(viewing_user)`, never bare
  `settings`, in any new serializer.
- **Never copied.** `Board#clone_with_images` strips `likeness` alongside the
  robust-set markers: a copy in another account must not draw that account's
  tiles to look like the source owner's communicator.
- **The prompt clause** — "Draw the person in this picture as…" followed by
  `PROMPT_GUARD` ("Do not add any other people the subject does not need"). It
  is NOT conditional prose: an earlier "If the picture shows a person…" version
  rode every prompt, and the model drew the person it described into "dog" and
  "she" alike. Whether it is sent at all is decided per word (below). The noun
  comes from the communicator's age band and stays age-neutral without one:
  communicators are not all children.
- `#fingerprint` is stable across key/extras order, so two communicators who look
  the same can share generated art.

### How generation uses it

- **Resolution** — `Images::LikenessResolver.for(board:, communicator:)`: board
  override → a named communicator the board's owner owns → the one owner-owned
  communicator attached to the board → nil. Two attached communicators, a
  foreign one, or a menu board all resolve to nil. The result carries the
  communicator's `age_band` for the noun, even when the look came from the
  board override.
- **Which words take it** — `Images::LikenessApplicability.applies?(label:,
  part_of_speech:, user_input:)`, deterministic, checked in order:
  1. names another person (she, his, girl, mom, teacher, friend, we, us, …) →
     no, even beside "me". "you" counts only as a subject: it is fine in
     something said to someone (social/question POS, or with a first-person word).
  2. first person (i, me, my, mine, myself; contractions reduced) → yes.
  3. part of speech: `verb`, `social`, `question`, `important_function` → yes;
     `adjective` only for `FEELING_WORDS`; everything else (nouns, prepositions,
     determiners, adverbs, nil) → no.

  It reads the typed description too, so "a girl feeding a dog" stays
  unpersonalized. `Result#applies_to?(image, user_input:)` is the per-image
  entry point: `GenerateImagesJob` / `GenerateImageJob` compute it once per
  image for the prompt, the fingerprint and `replace_current`;
  `PromptBuilder.for_image` re-checks it; `LikenessArt.reusable_url` refuses
  reuse without it.
- **The prompt layer** sits after the part-of-speech clause and before
  `modifiers` and the style spec (`PromptBuilder.for_image(likeness:)`). The
  refusal retry in `GenerateImageJob` keeps its server-owned phrases and drops
  its write-ins.
- **Only where art is generated anyway.** Library art and the owner's own
  ordinary art are kept; `Images::LikenessArt.art_present?` is the test every
  fill path shares, and it ignores likeness docs.
- **Naming the communicator.** `GenerateBoardJob` →
  `Board#find_or_create_images_from_word_list(communicator:)`,
  `BuildBoardSetJob#generate_art_if_blank` and
  `Boards::SeededSetCloner#generate_art_if_blank` all enqueue with
  `{"communicator_id" => …}`, because builder sub-pages carry no ChildBoard. With
  no communicator the job args are unchanged.
- **Reuse.** A fill path that would generate first looks for a doc on the same
  Image with the same owner and fingerprint (`Image#likeness_doc_for`) and
  points the tile at it for free. `regenerate_images` never reuses — asking for
  a new picture means a new picture.
- **The doc.** `create_image_doc(likeness:)` takes the resolver `Result` and
  the save merges `Doc.likeness_data`: `data["likeness_fingerprint"]` (reuse),
  plus the TAG — `data["likeness_traits"]` (the allowlisted tokens) and
  `data["likeness_age_band"]`. Never a communicator id or name. `Doc#likeness_tag`
  serializes it as `{traits, age_band, label}` on `api_view`/`list_api_view`
  (`CommunicatorLikeness#label`, from the picker's locale labels); docs generated
  before the tag carry only the fingerprint and serialize `likeness: nil`.
- **Pickable, never a default.** An ADMIN-owned likeness doc is library
  (`Doc#library?`, `for_user`) — listed for every account, and a user's explicit
  `UserDoc` pick of it resolves (`Doc#shared_likeness?`). Nothing resolves to one
  on its own: `display_doc`'s fallback filters `Doc::NOT_LIKENESS_SQL`,
  `set_library_default_doc!` refuses it, `update_to_src_url!` won't follow a
  pick of it, the `src_url` fallbacks in the admin/images controllers filter it,
  it gets no automatic `UserDoc`, is never fanned out, `replace_current` skips
  it, and `LikenessArt.art_present?` doesn't count it as the word's art. A
  likeness doc owned by anyone else is private and listed for its owner only.
- **Known gap:** a later single-tile generate on a builder sub-page has no
  communicator to name, so it resolves only through the board's own override.

## Style resolution

Two specs: `symbol` (flat vector AAC symbol) and `illustrated` (soft flat colors).
`Images::PromptBuilder::DEFAULT_STYLE` is **`symbol`** — the AAC-correct look and
the most legible at the 288px tile variant. Changing that constant changes the
default for every future generation; it never touches existing images.

Resolution order (`PromptBuilder.resolve_style`):
request param → `board.settings["image_style"]` → `user.settings["image_style"]`
→ `DEFAULT_STYLE`. Both `settings` columns are existing jsonb — no migration.
Unknown values fall through rather than raising, so a stale client can't break
generation.

## API params, not prose

Transparency and quality are **request parameters**, not sentences in the prompt.
Asking for a transparent background in prose reliably produces a white box, which
looks wrong on the colored part-of-speech tile backgrounds.

- `background: "transparent"` — sent when transparency is requested **and** the
  output format has an alpha channel (`png`/`webp`; we default to webp).
- `quality` — `OPENAI_IMAGE_QUALITY`, default `medium`. Tiles render at 288px and
  are re-encoded to webp q65, so `high` buys nothing visible and costs real money.

**Model-portability rail:** not every image model accepts `background` —
gpt-image-2 rejects `transparent` outright. `OpenAiClient#generate_with_background_fallback`
drops the param and retries once, so swapping `OPENAI_IMAGE_MODEL` can't take
generation down. Keep that fallback if you touch the call.

## Refusal retry

AAC vocabulary legitimately includes body parts, medical, and bathroom/safety
words that trip the content moderator. Moderation stays at the API default; when
a generation is refused, `GenerateImageJob#generate_with_refusal_retry` retries
once with the clean label-only house prompt. It gives up (rather than looping)
when the default prompt is itself what was refused.

## Variations go through the edit endpoint

`/images/variations` only ever supported **dall-e-2**, so every "make a
variation" used to emit visibly off-style art next to gpt-image tiles.
`Image#generate_image_variation` now routes to `ImageEditService` (the
`images.edit` endpoint) with `Image#variation_prompt` — same subject, same style
spec, different composition. `ImageVariationService` was deleted. Do not
reintroduce the variations endpoint.

## Who can see a generated doc

A doc owned by nil or `DEFAULT_ADMIN_ID` is **library** art; any other doc is
**private to its owner**. `Doc.for_user` / `Doc#visible_to?` are the definition;
full rule in the doc-visibility invariant in `CLAUDE.md`.

Generation decides ownership, so it decides visibility:

- `GenerateImageJob` — the requesting user.
- `GenerateImagesJob` — the **board's owner** (`#generating_user_id`), falling
  back to `image.user_id` only with no board. Never `image.user_id` first: it is
  nil on every word-list image, which made a regular user's board fill public
  library art. Never the enqueuer either: an admin regenerating a family's board
  for support must not publish it, and a curator's regenerate is the family's
  picture.
- `replace_current` only demotes siblings when that user `can_edit?` the Image —
  the same gate as `set_library_default_doc!`.

So library art grows only from admin-owned boards and system imports. A regular
user's generation is theirs and reaches their own tiles directly.

## Bulk edit vs. bulk regenerate

Two bulk actions off the same drawer, and the differences between them are all
deliberate:

|  | `regenerate_images` | `edit_images` |
|---|---|---|
| What runs | `images/generations` — a new picture from the tile's word | `images/edits` — img2img over the art the tile already shows |
| Free text | `modifiers`, **optional**, one layer of a composed prompt | `prompt`, **required**, the whole instruction to the edit endpoint |
| Billed per | distinct **Image** (deduped) | **BoardImage** (not deduped) |
| Charge order | validate → count → charge | validate → **partition** → charge |

The billing unit differs because the writes differ: a generation writes the
shared `Image`, so two tiles on one library Image are one picture; an edit
writes each tile's own `display_image_url`, so they are two.

The extra partition step is the picture-less-tile filter. A tile whose picture
is hidden has nothing to edit, so billing for it would take money for work that
can never run — hence it happens before `check_credits!`, which spends rather
than checks. `BoardImage#edit_source_image_url` is that filter, and it asks
`picture_hidden?` first: a blank `display_image_url` means "this tile
deliberately has no picture", so falling through to the shared Image's art would
silently un-hide the tile by editing art it isn't showing.

`EditBoardImagesJob` exists rather than a loop over `EditBoardImageJob` because
that one reports no per-image outcome — it swallows its own failures — which
makes a per-image refund impossible. Both refund through `Credits::TxnRefunds`
against the reservation the controller hands them, under distinct reasons
(`image_edit_failed` vs `image_generation_failed`) since the two name different
spend transactions.

## Prompt provenance

gpt-image models do **not** return `revised_prompt` (DALL·E 3 did), so without
recording what we sent there is no way to audit or A/B image quality. Every
generated doc carries `doc.data["prompt" | "model" | "quality" | "background"]`,
and `doc.processed` falls back to the sent prompt. This is the foundation for any
future quality work — keep it populated.

## Cross-user repointing is scoped

`Images::TileArtFanout` (`app/services/images/tile_art_fanout.rb`) is the
**single implementation** of that scoping — every library→tile write goes
through it, including the `after_save` cascade on `src_url`.
`Image#update_all_boards_image_belongs_to(url, override_existing,
current_user_id)` is a thin legacy delegator kept for its existing callers; do
not add logic there.

**Images are shared library records**, so callers in the generation path must
pass `current_user_id`: without it the sweep reaches into other users' boards.
With no actor the fan-out reaches **admin-owned boards only**, which keeps the
shared library populated without guessing. A regular actor never reaches an
admin board: those are the catalogue other users clone, and a regular user's
URL is a private picture. `override_existing` means "all of MY
boards, including my own pins" — it has never meant, and must never mean, "all
boards".

A tile whose `display_image_url` is `""` — the "this tile has no picture" marker
— is **never** touched by any mode, `override_existing` included. `.blank?` is
true for it and `.present?` is false for it, so both of the guards this code
used to use got it wrong and silently un-hid deliberately blanked tiles; ask
`BoardImage#picture_hidden?` instead. Full rule: the tile-ownership invariant in
`CLAUDE.md`.

`authorized_to_view_url?` uses **HEAD**, not GET — this runs once per BoardImage
inside the generation path, and a popular label ("more", "help") has hundreds of
placements. The freshly minted URL is known-good and is never re-validated.

## Entry points

| Path | Job | Notes |
|---|---|---|
| `POST api/images/generate` | `GenerateImageJob` | Single tile; accepts `style`, `transparent_background` |
| `POST api/internal/images/generate` | `GenerateImageJob` | Same, bearer-auth internal surface |
| `api/account/images#run_generate` | `GenerateImageJob` | Account-scoped |
| `Board#find_or_create_images_from_word_list` | `GenerateImagesJob` | Board fill; branches menu vs. everything else |
| `BoardImage#create_image_variation!` | inline | Routes to `ImageEditService` |
| `BoardImage#create_image_edit!` | inline | User-supplied edit prompt |
| `POST api/boards/:id/regenerate_images` | `GenerateImagesJob` | Bulk redraw; accepts `modifiers` |
| `POST api/boards/:id/edit_images` | `EditBoardImagesJob` | Bulk img2img; `prompt` required, billed per tile |

## Staging

All paid image calls are stubbed when `AppEnv.staging?` — `OpenAiClient#create_image`
and `ImageEditService` return the bundled `public/placeholder.jpeg`. The rest of
each pipeline runs normally.

---

# Text tiles (`Images::TextTile`)

A tile picture rendered from **typed text** instead of generated. It is a third
option in the editor's IMAGE STYLE picker, but it is not an AI style: there is
no prompt, no OpenAI call, and no credit charge. Everything downstream —
tile variants, print, OBF/OBZ export, offline cache — treats the result as an
ordinary tile image, which is the whole point.

## The rules that must not drift

- **Free, and that is load-bearing.** `create_text_image` deliberately does not
  call `check_credits!`. The button copy says "Free — no credits used" and
  `spec/requests/api/board_images_text_image_spec.rb` asserts the balance is
  untouched. Adding a credit gate means changing the copy in the same PR.
- **`"text"` is not a `PromptBuilder` style.** `resolve_style` ignores values it
  doesn't recognize, so a `style=text` reaching `images#generate` would bill the
  user for an AAC symbol they didn't ask for. That path 422s `invalid_style`
  instead. On the frontend the same split is a type: `ImageStyle` stays the
  prompt contract, `TileArtStyle` is the per-tile UI union, and only the tile
  editor sees the wider one.
- **No fan-out.** `Images::TextTile::Creator` does NOT call
  `update_all_boards_image_belongs_to`. An AI picture of "more" is the same
  picture wherever that Image appears; one board's typography is not. The Doc
  still hangs off the shared `Image` (so it gets `tile_variant`/`tile_url` and
  shows in that tile's picture gallery), but only the originating BoardImage is
  repointed. It also leaves `image.status` alone.
- **`Options` is the only trust boundary.** No raw CSS from the client ever
  reaches the rendered HTML: the client sends *tokens* (`"m"`, `"upper"`,
  `"center"`) and a font *key*, and the server owns every CSS value. Colors must
  match a hex pattern or they're discarded; the text is escaped and capped.
  `to_h` emits only whitelisted keys, so the persisted blob is safe to feed
  straight back through `from_params` when the editor reopens.
- **`Doc::SOURCE_TYPE_TEXT_TILE` must stay in both license services.**
  `Images::RedistributionLicense` and `Images::CommercialLicense` both fail
  *closed*: an unrecognized `source_type` resolves to "no redistributable
  license on record" and the tile is **silently dropped from exports**. Text
  tiles are in each service's `OWNED_SOURCE_TYPES` — the OFL licenses the font
  software, not the pixels it draws.

## Rendering

Grover (headless Chrome), not vips/pango and not a stored SVG.

- **SVG is disqualified, not merely worse.** `Doc#tile_variant` returns `nil`
  unless `image.variable?`, and Rails' default `variable_content_types` excludes
  `image/svg+xml` — an SVG doc silently bypasses the 288px pipeline every other
  tile goes through.
- **Grover is Blink, and so is the preview.** The editor previews with CSS in
  the browser; using anything else server-side would put preview and result out
  of sync on shaping, fallback, `text-transform`, and line breaking. That is the
  most damaging bug this feature can ship.
- Rendered at 576px and downsampled by the existing `resize_to_limit [288,288]`.
  `HtmlToPng` (`app/services/html_to_png.rb`) is the one Chrome call site;
  `Communicators::BaseAssetGenerator` delegates to it.
- `omit_background` is **verified working** on the installed Grover/Puppeteer —
  a transparent tile renders RGBA. A transparent background must leave the body
  unpainted (`background: none`), since omitBackground only shows through where
  the page paints nothing.

## Fonts

`Images::TextTile::Fonts` vendors woff2 under `app/assets/fonts/text_tiles/`
(Nunito reuses the printables copy), base64-inlined per render — same hermetic
rule as `Boards::Printables::Fonts`, and `OFL.txt` ships beside each family.

- **Normal style only.** Italic is Chrome's synthetic oblique, and the frontend
  requests the same axes (no `ital`) from Google Fonts in `index.html`, so both
  sides slant identically. Shipping a real italic on one side only breaks parity.
- **`face_css` emits one family**, never all five — that would be ~400 KB of
  base64 per render for faces nobody asked for.
- The key list is a **cross-repo contract** with `TEXT_TILE_FONTS` in
  `itty-bitty-frontend/src/data/text_tile.ts`. Both sides have a test asserting
  it and naming the other file.

## Layout parity

`Options#lines` / `#font_size_px` are ported from
`BoardsHelper#generate_placeholder_image` and have a TypeScript twin,
`computeTextTileLayout`. Both are tested against the same fixture table.

- Sizes are in **`REFERENCE_CANVAS` (300px) units**; each renderer scales to its
  own box (576 server, 288 preview). Keeping the numbers in one space is what
  lets one fixture table test all three.
- The width fit is capped by a **height fit** (`LINE_HEIGHT`, `PADDING_RATIO`) —
  without it three wrapped lines at max size clip their descenders.
- The size token (S/M/L/XL) is a **multiplier**, never an absolute px, so a long
  label can't overflow whatever size the user picked.
- The wrap is Latin-centric by construction (characters-per-line). Revisit with
  `board_image.language` rather than tuning the constants.

## Endpoint

`POST /api/board_images/:id/create_text_image` → `RenderTextTileJob` (queue
`:text_images`, deliberately **not** `:ai_images` — a ~1s local render must not
sit behind minute-long OpenAI calls). Sets `status: "generating"` and
`data["text_image"]`, so the existing realtime refresh path works unchanged.

- The config is written **before** the enqueue, so the editor restores the
  controls even while the render is in flight or if the job fails.
- `hide_label` is assigned **both ways** — the form shows the tile's current
  state, so unchecking the box has to put the label back.
- **Unchanged-render short circuit:** an identical request (compared on
  `Options#render_digest`, which excludes `hide_label`) with its Doc still
  present returns `complete` without forking Chrome. Free and instant invites
  tweak-and-retry; this is what stops that costing a render each time.
- Throttled by its own Rack::Attack bucket (`RACK_ATTACK_TEXT_IMAGE_LIMIT`,
  default 60/min), not the AI one — free renders shouldn't consume a budget the
  user paid for, but each is still a Chrome fork.
- Nothing is staging-gated: there are no paid calls on this path.

## Dedupe and batching

A render is deterministic, and `Options#render_digest` is defined as everything
that changes the pixels and nothing that doesn't — so two tiles with the same
digest are byte-identical no matter whose board they sit on. That digest is the
dedupe key, stored on the Doc as `data["render_digest"]` (partial index
`index_docs_on_text_tile_render_digest`).

- **`Creator` looks the digest up before forking Chrome**, in two tiers. Same
  Image + same user + same digest reuses the **Doc row** outright (a second row
  is just a duplicate thumbnail in that tile's gallery). Any other match creates
  this Image's own Doc row — the row is per-Image/per-user, since docs carry
  `user_id` and seed `UserDoc` — but attaches the **same blob**: no render, no
  upload.
- **Sharing a blob across Doc rows is safe because of the FK.**
  `active_storage_attachments.blob_id` has a foreign key and
  `ActiveStorage::Blob#purge` rescues `InvalidForeignKey`, so hard-deleting one
  Doc (`docs#destroy?hard_delete=1`, or `ConvertDocToWebpJob` purging the
  original) can't take the bytes out from under the others. Don't drop that FK,
  and don't "fix" a dedupe miss by copying bytes into a fresh blob.
- A doc whose blob was purged is not a reuse source — the lookup joins
  `image_attachment`.
- The controller's unchanged-render short circuit is still worth keeping: it
  answers without touching the queue at all. The `Creator` dedupe is the second
  net, for tiles that have never carried this render.

**Bulk is one job, not one per tile.** `create_text_images` enqueues a single
`RenderTextTilesJob` carrying `[[board_image_id, options], ...]`.

- The queue runs three workers, so a select-all used to park everyone else's
  single-tile render behind thirty Chrome forks.
- Sequential inside the job **on purpose**: rendering the selection in parallel
  would race the digest lookup and fork Chrome N times for the same picture.
- One tile's failure marks only that tile `failed`; the batch still raises at
  the end so Sidekiq retries, which is cheap because every tile that succeeded
  now dedupes to its own Doc instead of re-rendering.
- The board is broadcast once per board at the end, not once per tile —
  `Creator.call(broadcast: false)` is what the batch passes.
