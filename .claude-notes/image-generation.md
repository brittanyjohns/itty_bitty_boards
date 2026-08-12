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
3. **Style spec** — `STYLES[:symbol]` or `STYLES[:illustrated]`
4. **Hard constraints** — always: no text/letters/numbers, single centered
   subject, background rule

The only bypass is `raw_prompt: true`, gated to admins via the
`[[REPLACE_LABEL]]` marker in `images_controller#generate`.

## `image_prompt` stores intent, never the composed prompt

`Image#image_prompt` holds **the user's subject description**. The full prompt is
composed at call time and passed to `create_image_doc`. Persisting the composed
prompt would make each regeneration wrap the previous envelope inside a new one.
`GenerateImageJob` and `GenerateImagesJob` both follow this split — keep it.

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

## Prompt provenance

gpt-image models do **not** return `revised_prompt` (DALL·E 3 did), so without
recording what we sent there is no way to audit or A/B image quality. Every
generated doc carries `doc.data["prompt" | "model" | "quality" | "background"]`,
and `doc.processed` falls back to the sent prompt. This is the foundation for any
future quality work — keep it populated.

## Cross-user repointing is scoped

`Image#update_all_boards_image_belongs_to(url, override_existing, current_user_id)`
repoints tiles pointing at nothing or at a dead URL. **Images are shared library
records**, so callers in the generation path must pass `current_user_id`: without
it the sweep reaches into other users' boards. Admin-owned boards are still
filled so the shared library stays populated.

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
