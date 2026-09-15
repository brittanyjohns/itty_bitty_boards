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
| `SceneComposition` | polymorphic `owner` (a `BoardPrintable` today), optional `board_printable_listing`, `scene_template`, `slot_art` jsonb, `render_digest`, `rendered_at`, `error`. Named attachments `slot_uploads` (many), `render` (one JPEG). |

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

## Art sources (`slot_art` entries)

| source | entry | rendered by |
|---|---|---|
| `page_thumbnail` | `{board_id, ink: color\|low_ink, header: bool}` | `RenderPageThumbnails`, one pass per distinct `(ink, header)`, covering only the boards that ask for it |
| `device_screen` | `{board_id}` | the colour header-LESS thumbnail wrapped in `RenderDeviceScreen`, shell sized to the slot's aspect |
| `upload` | `{blob_id}` | a blob in THIS composition's `slot_uploads` (png/jpeg/webp ≤ 10 MB) |

A `board_id` must be in the owner's `board_ids`, and a `blob_id` must be one of
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
  (`SceneComposition::CATEGORY_FOR_OWNER`).
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
- Nothing uploads to Etsy. The curated gallery (#953) will add a
  `composition:<id>` ref.

## Vendored seed

`bin/rails scenes:import_vendored` creates one `source: vendored`, calibrated,
single-slot template per `TabletScene`/`PaperScene` constant from its JPG
(`vendored-<slug>`, slot key `screen`/`sheet`). The quads are copied verbatim;
the task refuses a JPG whose size disagrees with the constant. It is
**idempotent** and leaves existing templates alone, since an admin may have
recalibrated one. `FORCE=1` re-syncs name and slots, and never re-uploads the image.
