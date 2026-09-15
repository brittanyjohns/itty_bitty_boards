# Scene engine: multi-slot mockup templates

A shared admin library of **scene templates** (a blank base photo, an optional
transparent front layer, N calibrated slots), and per-product **scene
compositions** that warp the product's REAL art into each slot. Issue #954.
Later: text slots (#955), AI scene generation (#956), device-tag products (#957),
and the curated per-listing gallery that references a composition (#953).

The single-quad listing mockups (`MockupScene`, `TabletScene`, `PaperScene`,
see `board-printables-etsy.md` → "The mockups") are unchanged and still drive the
ten-slide Etsy gallery. The engine sits beside them and shares their maths.

## The rule that doesn't bend

**Product art is RENDERED and composited, never sent to an image model.** A slot
takes this app's own page render, its own app-chrome screenshot, or a picture an
admin uploaded. The warp is a CSS `matrix3d` in the same Grover render every
listing slide uses. An image model may one day draw the *scene* (#956); it never
sees, redraws or "improves" the product.

## Models

| | |
|---|---|
| `SceneTemplate` | `slug` (unique), `name`, `category` (`board`/`device_tag`), `source` (`canva`/`ai`/`vendored`), `status` (`draft`/`calibrated`/`archived`), `width`/`height` (read from the base image with libvips), `calibration_version`, `slots` jsonb, `notes`/`prompt`. Named attachments `base_image`, `front_layer`. |
| `SceneComposition` | polymorphic `owner` (a `BoardPrintable`, or a `PrintableProduct`, see `printable-products.md`), optional `board_printable_listing` (board printables only), `scene_template`, `slot_art` jsonb, `render_digest`, `rendered_at`, `error`. Named attachments `slot_uploads` (many), `render` (one JPEG). |

Both use **named attachments** and **versioned storage keys**
(`scene_templates/<hex>/<file>`, `scene_compositions/<id>/<hex>/<file>`), same
reason as `BoardPrintable#versioned_storage_key_for`: CloudFront caches by path.
Nothing here touches `board_printables.files`.

## Slot shape

```json
{"key":"fridge","label":"Fridge sheet","kind":"paper","quad":[[x,y],[x,y],[x,y],[x,y]],
 "orientation":"portrait","accepts":["page_thumbnail","upload"],"finish":"shadow","bleed_px":2}
```

- `quad` is in the **base image's pixels, clockwise from top-left**.
- `kind`: `paper|tablet|frame|clipboard|stack|tag` (descriptive; drives the default finish).
- `orientation`: `portrait|landscape|any`. Validated against the quad's own
  aspect. A homography maps ANY rectangle onto the quad, so a slot filed under
  the wrong orientation doesn't fail; it lies.
- `accepts`: an allowlist of art sources (below).
- `finish`: `shadow` (drop shadow, an object sitting on something), `glare`
  (a lit screen), or `none`. Defaults by kind (`tablet` → `glare`, else `shadow`).
- `bleed_px` (0–20): pushes each corner outward from the centroid, so art runs
  proud of the placeholder's edge instead of leaving a sliver of it showing.

`SceneTemplate` normalizes slots on write (unknown keys dropped, form strings
cast to numbers) and validates each one. Every corner must be inside the image.
The quad must not be degenerate (`Homography::DegenerateQuadError`), and it must
be **clockwise and convex** (`SceneSlot#clockwise_convex?`). A bow-tie or
counter-clockwise quad solves to a valid matrix and renders folded or mirrored
art, so it has to be refused by shape. Keys must be unique, and there are at
most 8 slots. A front layer must match the base image's size.

## The geometry: `Boards::Printables::SceneSlot`

The quad maths extracted from `MockupScene`: `target_width`/`target_height` (the
letterbox rectangle at the quad's own proportions), `matrix3d`, `with_bleed`, and
the shape checks. `MockupScene` delegates to it, and `scene_slot_spec` asserts
the numbers for every vendored scene match the pre-extraction formula. The
calibrator's `app/javascript/src/scene/homography.js` is the JS twin, and it has
to agree exactly: the preview must warp the way the render will.

## `calibration_version`

Bumped (on a persisted template) whenever what a slot renders onto changes: the
slots, the base image, or the front layer. A rename or a no-op slot save does
not bump it. It feeds every composition's digest, so recalibrating marks their
renders stale.

## Layer order

`RenderSceneComposition` renders `api/board_printables/scene/composition` in
`layouts/scene_composition`:

1. **base image**, full stage
2. each **filled slot's art**, in slot order: a `.scene-art.finish-<finish>`
   element of `target_width × target_height`, `transform: matrix3d(...)`,
   `transform-origin: 0 0`, white background, the art `object-fit: contain`
   (**letterboxed on white, never stretched**)
3. **front layer**, full stage, above everything

DOM order and z-index agree, so neither can be changed alone. An unfilled slot
contributes nothing and the base image shows through.

The output keeps the **template's aspect**: 1200 CSS px wide, height by aspect,
the stage a plain `scale()` of the base image's pixels.
`viewport: { width:, height:, device_scale_factor: 2 }`, with the scale
**nested** (Grover drops a top-level one). JPEG, quality 90. Everything is
inlined as data URIs; the only network fetches are board symbol art inside page
renders, as for the listing gallery.

Then, on top of all three: **text slots**, then **overlay regions** (#955),
z-index 3, **above the front layer**. A front layer is rings, clips and hands
over the product; words the scene prints are meant to be read, not tucked under
a ring. A template that wants words behind something draws that into the base
image.

## Text slots and overlay regions (#955)

The template sets the **look**; a composition supplies only the **words**.

```json
{"key":"headline","label":"Headline","box":[x,y,w,h],"rotation":-2,"font":"fredoka","weight":600,
 "color":"#17385c","align":"center","max_px":110,"min_px":28,"max_chars":80,"default":"Printable AAC"}
{"key":"facts","box":[x,y,w,h],"partial":"feature_list"}
```

- `box` is in base-image px and must sit wholly inside the image. `rotation` is
  in degrees (±180), about the box's centre.
- `font` is an allowlist (`SceneTemplate::TEXT_FONTS`: `nunito`, `fredoka`,
  `caveat`), exactly the faces `Fonts.styled_face_css` inlines, and `weight`
  must be a multiple of 100 inside the range that font's vendored file covers
  (Fredoka stops at 600). `color` is a `#rrggbb` hex. `align` is
  left/center/right. `min_px` ≤ `max_px`, both 6–400. `max_chars` is 1–280, and
  the default must fit it.
- Keys are **one namespace** across `slots`, `text_slots` and
  `overlay_regions`. At most 8 text slots and 4 overlays.
- Text and overlay changes bump `calibration_version`, as a quad change does.
- `SceneComposition#text_values` is `{key => words}`. Words are squished, and a
  blank value is **not stored**: blank means the slot's default, and an empty
  default draws nothing. Validated against the template's keys and
  `max_chars` on save, and `max_chars` is re-asserted at render time (a limit
  lowered since the words were saved raises `RenderSceneComposition::Error`).
- **Words are user input.** They reach the page only through ERB's escaping
  output tag; never `raw`/`html_safe`, never interpolated into the script.
- `partial` is an allowlist (`OVERLAY_PARTIALS`: `feature_list`, `badges`,
  `steps_row`, `check_pills`, in `api/board_printables/scene/overlays/`). Each
  renders from `Printables::GalleryFacts` for the composition's printable
  (narrowed to its listing when it has one) via `StyledSlideCopy.overlay_*`.
  There is no free text in an overlay. The partials claim nothing GalleryFacts
  doesn't back: no "free", no "no sign-in" until a fact supports them.
  `feature_list` and `badges` reuse the styled slides' partials, and their CSS is
  the shared `styled/_component_css` partial so the two can't drift.
- The digest includes the sorted `text_values`, and `GalleryFacts#digest` when
  the template has overlays, so a changed word count marks the render stale.
  `RENDER_SPEC_VERSION` is 2.

### Fitting

Grover 1.2.3 forwards `wait_for_function` to Puppeteer's `page.waitForFunction`
(checked in the gem's `processor.cjs`). When anything styled is drawn, the page
carries `scene/_fit_script`: it loads each face with `document.fonts.load`,
awaits `document.fonts.ready`, bisects each text box's font size from `max_px`
down to `min_px` until the words fit (normal word wrapping, so a long word
overflows and shrinks rather than breaking at max size), scales each overlay's
natural layout to contain in its box, then sets `window.__scene_fit = true`.
Grover waits on that flag (`FIT_TIMEOUT_MS`, 15 s) before the screenshot, so a
stuck fit fails the render instead of shipping unfitted text.

If even `min_px` overflows, the box gets `data-overflow` and the words may break
mid-word. `max_chars` is what keeps that rare. Ruby also seeds a pre-script
size (`estimate_font_px`, an average-glyph estimate) and an overlay scale, so
the markup is close even before the script runs.

Fonts, the component CSS and the script are emitted **only** when a text slot
has words or a template has an overlay. A plain scene render carries none of
them. The faces are emitted with `<%==` (see "Styled slides" in
`board-printables-etsy.md`).

The calibrator's `app/javascript/src/scene/text_fit.js` is the JS twin of the
fit. Change both together.

### Calibrator and form

The calibrator adds, removes, drags (move) and resizes (bottom-right handle)
text and overlay boxes. The handles edit the **unrotated** box; the preview
rotates the text about the box centre. Each box has a small form (font, weight,
colour, align, sizes, max_chars, rotation, default, or partial). The preview
draws the default words in the chosen face, fitted as the render fits them,
above the checkerboard warp and the front layer. An overlay previews as a
labelled placeholder, because a template has no printable to take facts from.
The page inlines the styled faces so it measures real glyphs. The documents
save as `text_slots_json` and `overlay_regions_json`; a request that omits one
leaves that column alone.

The composition form has one text input per text slot (`maxlength` =
`max_chars`, the default as placeholder), saved with the art. A request without
`text_values` leaves the words alone.

## Art sources (`slot_art` entries)

| source | entry | rendered by |
|---|---|---|
| `page_thumbnail` | `{board_id, ink: color\|low_ink, header: bool}` | `RenderPageThumbnails`, one pass per distinct `(ink, header)`, covering only the boards that ask for it |
| `device_screen` | `{board_id}` | the colour header-LESS thumbnail wrapped in `RenderDeviceScreen`, shell sized to the slot's aspect |
| `upload` | `{blob_id}` | a blob in THIS composition's `slot_uploads` (png/jpeg/webp ≤ 10 MB) |
| `product_artwork` | `{blob_id}` | one of the owning `PrintableProduct`'s `artworks` |

**Which sources an owner may use is an allowlist**
(`SceneComposition::SOURCES_FOR_OWNER`). A `BoardPrintable` gets
`page_thumbnail`, `device_screen` and `upload`. A `PrintableProduct` gets
`product_artwork` and `upload`. A slot's `accepts` is what the *photo* can hold,
and the owner list is what the *product* has. The form offers the intersection,
and both lists are enforced on save and at render. The `accepts` default for a
new slot includes `product_artwork`. A slot calibrated before it existed has to be
recalibrated to take one.

A `board_id` must be in the owner's `board_ids`, a `product_artwork` `blob_id`
must be one of the owner's artworks, and an `upload` `blob_id` must be one of
the composition's own uploads. Both are validated on save and **re-asserted at
render time**, because a Regenerate re-walks the printable's tree after the
composition was saved. A filled slot whose art can't be produced raises
`RenderSceneComposition::Error` rather than rendering a blank placeholder.
`RenderSceneCompositionJob` (retry 2) records that error on the row and stops.
Any other exception records a generic message and re-raises so Sidekiq retries.
Uploads no slot points at are pruned on save.

## Digest and staleness

`current_render_digest` = SHA256 of `RENDER_SPEC_VERSION`, the template id and
`calibration_version`, the sorted `slot_art`, and the `updated_at` of each board
a slot draws. It is computed **before** rendering, so an edit made while Chrome
is busy still reads stale. `stale?` is "no render, or digest differs". Board
`updated_at` is a proxy: a tile edit that doesn't touch the board row won't
move it, the same trade as the listing gallery. Bump `RENDER_SPEC_VERSION` when
the template or its CSS changes what a render looks like.

## Lifecycle

- A new composition needs a **calibrated** template in its owner's category
  (`SceneComposition.template_category_for`: `CATEGORY_FOR_OWNER` for a board
  printable, and the product's own `category` for a `PrintableProduct`).
- `SceneTemplate` `has_many :scene_compositions, dependent: :restrict_with_error`.
  **Archive, don't destroy, a template in use.** `retire!` destroys an unused
  template and archives a used one, and an archived template keeps rendering for
  the compositions that already point at it.
- A composition is destroyed with its printable. Its listing FK nullifies.
- Renders are enqueued with `enqueue_render!`, which uses
  `ActiveRecord.after_all_transactions_commit`, never inside a transaction.

## Admin

- `/admin/scene_templates` (Content menu): index (archived hidden by default),
  new/create (base + optional front layer upload), edit/update (replace or
  remove the front layer, change status), `archive`, destroy (falls back to
  archive when in use).
- `/admin/scene_templates/:id/calibrate`: the Stimulus
  `scene_calibrator_controller.js`, ported from speakanyway-printables'
  `calibrate-mockup-scene.html`. Add or remove slots, drag corners, or drag
  inside a quad to move it. Edit key/label/kind/orientation/accepts/finish/bleed
  and corner numbers. The **live preview** warps a numbered checkerboard into
  each quad with the JS homography, with the front layer drawn over it. Saves
  the slots JSON to `save_calibration`; the model is the gate, not the page's
  warnings.
- `/admin/board_printables/:id/scene_compositions/...`: pick a calibrated
  template, then per slot pick blank / printed page (board × ink × header) /
  app screen (board) / upload. "Save & render" enqueues. The printable's show
  page has a "Scene mockups" card.
- `/admin/printable_products/:id/scene_compositions/...`: the same controller,
  subclassed as `PrintableProductSceneCompositionsController` (it overrides only
  owner lookup and path helpers) with the **same views**. The picker shows
  templates in the product's category, and each slot picks one of the product's
  artworks by label. See `printable-products.md`.
- Nothing uploads to Etsy. The curated gallery (#953) will add a
  `composition:<id>` ref.

## Vendored seed

`bin/rails scenes:import_vendored` creates one `source: vendored`, calibrated,
single-slot template per `TabletScene`/`PaperScene` constant from its JPG
(`vendored-<slug>`, slot key `screen`/`sheet`). The quads are copied verbatim;
the task refuses a JPG whose size disagrees with the constant. It is
**idempotent** and leaves existing templates alone, since an admin may have
recalibrated one. `FORCE=1` re-syncs name and slots, and never re-uploads the image.
