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
